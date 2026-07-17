[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-StageSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $canonicalRoot -PathType Container)) {
        return 'ABSENT'
    }
    $pending = [Collections.Generic.Queue[string]]::new()
    $pending.Enqueue($canonicalRoot)
    $entries = [Collections.Generic.List[string]]::new()
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            $relativePath = $item.FullName.Substring($canonicalRoot.Length).TrimStart('\')
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $targets = @($item.Target | ForEach-Object {
                    [IO.Path]::GetFullPath([string]$_).TrimEnd('\')
                }) -join ','
                $entries.Add("MOUNT|$relativePath|$($item.LinkType)|$targets")
                continue
            }
            if ($item.PSIsContainer) {
                $entries.Add("DIR|$relativePath|$([int]$item.Attributes)")
                $pending.Enqueue($item.FullName)
                continue
            }
            $entries.Add("FILE|$relativePath|$([int]$item.Attributes)|$($item.Length)|$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)")
        }
    }
    return @($entries | Sort-Object) -join "`n"
}

function Assert-ExactSequence {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [AllowNull()][object[]]$Actual,
        [AllowNull()][object[]]$Expected
    )

    $actualText = @($Actual | ForEach-Object { [string]$_ }) -join "`n"
    $expectedText = @($Expected | ForEach-Object { [string]$_ }) -join "`n"
    if ($actualText -cne $expectedText) {
        throw "$Description mismatch. Expected [$(@($Expected) -join ', ')] but found [$(@($Actual) -join ', ')]."
    }
}

function Assert-LateManifestCommitFailure {
    param(
        [Parameter(Mandatory = $true)][Management.Automation.ErrorRecord]$Failure,
        [Parameter(Mandatory = $true)][string]$TransitionName
    )

    $isIoFailure = $Failure.Exception -is [IO.IOException] -or
        $Failure.Exception.InnerException -is [IO.IOException]
    if (-not $isIoFailure -or
        $Failure.ScriptStackTrace -notmatch '(?m)\bat Invoke-TransactionalStageOwnershipCommit,') {
        throw "$TransitionName failed before the intended locked-manifest commit point: $($Failure.Exception.Message)"
    }
}

function Remove-PostProcessTestPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$LocalRuntimeRoot,
        [Parameter(Mandatory = $true)][string[]]$AllowedPaths
    )

    $rootFull = [IO.Path]::GetFullPath($LocalRuntimeRoot).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowedFull = @($AllowedPaths | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
    if ($pathFull -notin $allowedFull -or
        -not $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing post-process-test cleanup outside its exact local-runtime output set: $pathFull"
    }
    if (-not (Test-Path -LiteralPath $pathFull)) {
        return
    }

    $item = Get-Item -LiteralPath $pathFull -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing post-process-test cleanup through a top-level reparse point: $pathFull"
    }
    if (-not $item.PSIsContainer) {
        Remove-Item -LiteralPath $pathFull -Force
        return
    }

    foreach ($topLevelItem in @(Get-ChildItem -LiteralPath $pathFull -Force)) {
        if (($topLevelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            continue
        }
        if ($topLevelItem.Name -cne 'Retail' -or
            -not $topLevelItem.PSIsContainer -or
            $topLevelItem.LinkType -cne 'Junction') {
            throw "Refusing post-process-test cleanup through an unexpected reparse point: $($topLevelItem.FullName)"
        }
        [IO.Directory]::Delete($topLevelItem.FullName, $false)
    }
    $nestedReparse = Get-ChildItem -LiteralPath $pathFull -Force -Recurse |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($nestedReparse) {
        throw "Refusing post-process-test cleanup through a nested reparse point: $($nestedReparse.FullName)"
    }
    Remove-Item -LiteralPath $pathFull -Recurse -Force
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
$runtimeExecutableModule = Join-Path $PSScriptRoot 'FearRuntimeExecutable.psm1'
$postProcessPackageModule = Join-Path $PSScriptRoot 'FearPostProcessPackage.psm1'
$stageSafetyModule = Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1'
$stagePlanModule = Join-Path $PSScriptRoot 'FearRuntimeStagePlan.psm1'
$stageOwnershipModule = Join-Path $PSScriptRoot 'FearRuntimeStageOwnership.psm1'
$postProcessAssetRoot = Join-Path $PSScriptRoot 'postprocess'
$sdkRuntimeExecutable = Join-Path $RepositoryRoot 'vendor-local\fear-sdk-108\Runtime\FEARDevSP.exe'
$buildRoot = Join-Path $RepositoryRoot "build\fear-win32\bin\$Configuration"
$dgVoodooArchive = Join-Path $RepositoryRoot 'vendor-local\renderer-deps\dgVoodoo2_87_3.zip'
$reShadeSetup = Join-Path $RepositoryRoot 'vendor-local\postprocess-deps\ReShade_Setup_6.7.3.exe'
$runId = [Guid]::NewGuid().ToString('N')
$localRuntimeRoot = Join-Path $RepositoryRoot 'local-runtime'
$fixtureRoot = Join-Path $localRuntimeRoot "postprocess-tool-fixture-retail-$runId"
$stageRoot = Join-Path $localRuntimeRoot "postprocess-stage-transaction-$runId"
$badSetup = Join-Path $localRuntimeRoot "postprocess-bad-setup-$runId.exe"
$cleanupPaths = @($fixtureRoot, $stageRoot, $badSetup)

$assetRelativePaths = @(
    'config\FearMore-CAS.seed.ini',
    'config\ReShade.seed.ini',
    'licenses\AMD-CAS-MIT.txt',
    'licenses\ReShade-BSD-3-Clause.txt',
    'Shaders\FearMoreCAS.fx'
)
$immutableRelativePaths = @('dxgi.dll') + @($assetRelativePaths | ForEach-Object { ".fearmore\postprocess\$_" })
$protectedInputs = @(
    $stageScript,
    $runtimeExecutableModule,
    $postProcessPackageModule,
    $stageSafetyModule,
    $stagePlanModule,
    $stageOwnershipModule,
    $sdkRuntimeExecutable,
    (Join-Path $buildRoot 'GameClient.dll'),
    (Join-Path $buildRoot 'GameServer.dll'),
    (Join-Path $buildRoot 'ClientFx.fxd'),
    $dgVoodooArchive,
    $reShadeSetup
) + @($assetRelativePaths | ForEach-Object { Join-Path $postProcessAssetRoot $_ })
foreach ($inputPath in $protectedInputs) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "Post-process stage test input is missing: $inputPath"
    }
}
$protectedHashes = @{}
foreach ($inputPath in $protectedInputs) {
    $protectedHashes[$inputPath] = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
}

Import-Module $runtimeExecutableModule -Force -ErrorAction Stop
Import-Module $postProcessPackageModule -Force -ErrorAction Stop

$stagePayloadIdentity = Get-FearPostProcessPackageIdentity -SetupPath $reShadeSetup -AssetRoot $postProcessAssetRoot
if ($stagePayloadIdentity.ReShadeVersion -cne '6.7.3' -or
    $stagePayloadIdentity.ProxySha256 -cne 'B63DF921946967D2CD8DDB1BF8A5F66B4F3C9B269A5F4EA8BA49B6DBA330658B' -or
    $stagePayloadIdentity.SeedPolicy -cne 'FirstEnableOnly') {
    throw 'Pinned ReShade package identity changed before focused stage verification.'
}

New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
Copy-Item -LiteralPath $sdkRuntimeExecutable -Destination (Join-Path $fixtureRoot 'FEAR.exe') -Force
foreach ($fileName in @('EngineServer.dll', 'GameDatabase.dll', 'LTMemory.dll', 'SndDrv.dll', 'StringEditRuntime.dll')) {
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot $fileName), [byte[]](0x46, 0x45, 0x41, 0x52))
}
[IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'FEAR.Arch00'), [byte[]](0x46, 0x45, 0x41, 0x52))
[IO.File]::WriteAllLines((Join-Path $fixtureRoot 'Default.archcfg'), @('FEAR.Arch00'), [Text.ASCIIEncoding]::new())

$commonParameters = @{
    Lane             = 'Rebuilt'
    Configuration    = $Configuration
    RepositoryRoot   = $RepositoryRoot
    RetailRoot       = $fixtureRoot
    BuildRoot        = $buildRoot
    StageRoot        = $stageRoot
    RendererMode     = 'DgVoodooD3D11'
    DgVoodooArchive  = $dgVoodooArchive
}
$casParameters = @{} + $commonParameters
$casParameters.PostProcessMode = 'ReShadeCas'
$casParameters.ReShadeSetup = $reShadeSetup

$legacyStateRejections = [Collections.Generic.List[string]]::new()
$fullToNoneRollback = $false
$noneToFullRollback = $false
$sameModeRefreshRollback = $false
$malformedHistoryBooleanRejected = $false
$tamperRejections = [Collections.Generic.List[string]]::new()

try {
    $none = & $stageScript @commonParameters -PostProcessMode None
    $noneManifest = Get-Content -LiteralPath (Join-Path $stageRoot 'fearmore-stage.json') -Raw | ConvertFrom-Json
    if ($none.PostProcessMode -cne 'None' -or $noneManifest.SchemaVersion -ne 9 -or
        $noneManifest.PostProcessMode -cne 'None' -or [bool]$noneManifest.PostProcessEverEnabled -or
        @($noneManifest.PostProcessOwnedFiles).Count -ne 0 -or
        [string]$noneManifest.PostProcessConfigSeedPolicy -cne 'FirstEnableOnly') {
        throw 'Initial None stage did not declare the schema-9 disabled post-process contract.'
    }
    foreach ($relativePath in $immutableRelativePaths + @('ReShade.ini', 'FearMore-CAS.ini')) {
        if (Test-Path -LiteralPath (Join-Path $stageRoot $relativePath)) {
            throw "Initial None stage unexpectedly contains post-process path '$relativePath'."
        }
    }

    $beforeWhatIf = Get-StageSnapshot -Root $stageRoot
    $whatIf = & $stageScript @casParameters -WhatIf
    if ($whatIf.PostProcessMode -cne 'ReShadeCas' -or
        $whatIf.PostProcessCompatibilityStatus -cne 'LiveAcceptedDgVoodooDxgiChain' -or
        $whatIf.LayoutValidated -or
        (Get-StageSnapshot -Root $stageRoot) -cne $beforeWhatIf) {
        throw 'ReShadeCas -WhatIf did not validate the package without mutating the existing None stage.'
    }

    $legacyCases = @(
        [pscustomobject]@{ RelativePath = 'ReShade.ini'; Kind = 'File' },
        [pscustomobject]@{ RelativePath = 'FearMore-CAS.ini'; Kind = 'File' },
        [pscustomobject]@{ RelativePath = 'ReShade.log'; Kind = 'File' },
        [pscustomobject]@{ RelativePath = '.fearmore\postprocess\Cache'; Kind = 'Directory' }
    )
    foreach ($legacyCase in $legacyCases) {
        $legacyPath = Join-Path $stageRoot $legacyCase.RelativePath
        if ($legacyCase.Kind -eq 'Directory') {
            New-Item -ItemType Directory -Path $legacyPath -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $legacyPath 'unowned.bin'), [byte[]](0x55, 0x4E, 0x4F, 0x57, 0x4E, 0x45, 0x44))
        }
        else {
            [IO.File]::WriteAllBytes($legacyPath, [byte[]](0x55, 0x4E, 0x4F, 0x57, 0x4E, 0x45, 0x44))
        }
        $beforeLegacyRejection = Get-StageSnapshot -Root $stageRoot
        $legacyRejected = $false
        try {
            & $stageScript @commonParameters -PostProcessMode None | Out-Null
        }
        catch {
            if (-not $_.Exception.Message.Contains('First ReShadeCas enable cannot adopt a pre-existing unowned')) {
                throw
            }
            $legacyRejected = $true
        }
        if (-not $legacyRejected -or (Get-StageSnapshot -Root $stageRoot) -cne $beforeLegacyRejection) {
            throw "Legacy first-enable state '$($legacyCase.RelativePath)' was accepted or the rejected stage was mutated."
        }
        $legacyStateRejections.Add([string]$legacyCase.RelativePath)
        if ($legacyCase.Kind -eq 'Directory') {
            Remove-Item -LiteralPath $legacyPath -Recurse -Force
            foreach ($parentRelativePath in @('.fearmore\postprocess', '.fearmore')) {
                $parentPath = Join-Path $stageRoot $parentRelativePath
                if ((Test-Path -LiteralPath $parentPath -PathType Container) -and
                    @(Get-ChildItem -LiteralPath $parentPath -Force).Count -eq 0) {
                    [IO.Directory]::Delete($parentPath, $false)
                }
            }
        }
        else {
            Remove-Item -LiteralPath $legacyPath -Force
        }
    }

    $enabled = & $stageScript @casParameters
    $enabledManifest = Get-Content -LiteralPath (Join-Path $stageRoot 'fearmore-stage.json') -Raw | ConvertFrom-Json
    if ($enabled.PostProcessMode -cne 'ReShadeCas' -or
        $enabled.PostProcessCompatibilityStatus -cne 'LiveAcceptedDgVoodooDxgiChain' -or
        $enabled.PostProcessExperimental -or $enabled.PostProcessAcceptanceTested -or
        $enabled.PostProcessProxySha256 -cne $stagePayloadIdentity.ProxySha256 -or
        @($enabled.PostProcessOwnedFiles).Count -ne 6 -or
        $enabledManifest.SchemaVersion -ne 9 -or $enabledManifest.PostProcessMode -cne 'ReShadeCas' -or
        -not [bool]$enabledManifest.PostProcessEverEnabled -or
        -not [bool]$enabledManifest.PostProcessConfigSeedApplied -or
        [bool]$enabledManifest.PostProcessAcceptanceTested -or
        [string]$enabledManifest.AcceptanceNote -notmatch 'Project-level live acceptance verified' -or
        [string]$enabledManifest.AcceptanceNote -notmatch 'does not itself prove') {
        throw 'First ReShadeCas enable did not report its exact live-accepted package, per-stage acceptance, or ownership semantics.'
    }
    Assert-ExactSequence `
        -Description 'First-enable seed files' `
        -Actual @($enabledManifest.PostProcessConfigSeedAppliedFiles) `
        -Expected @('ReShade.ini', 'FearMore-CAS.ini')
    $proxyIdentity = Get-FearPeRuntimeIdentity -Path (Join-Path $stageRoot 'dxgi.dll')
    if (-not (Test-FearX86Pe32Identity -Identity $proxyIdentity) -or
        $proxyIdentity.Sha256 -cne $stagePayloadIdentity.ProxySha256 -or
        $proxyIdentity.Size -ne $stagePayloadIdentity.ProxySize) {
        throw 'First ReShadeCas enable did not stage the pinned x86 DXGI proxy.'
    }
    foreach ($assetRelativePath in $assetRelativePaths) {
        $sourcePath = Join-Path $postProcessAssetRoot $assetRelativePath
        $stagedPath = Join-Path $stageRoot ".fearmore\postprocess\$assetRelativePath"
        if (-not (Test-Path -LiteralPath $stagedPath -PathType Leaf) -or
            (Get-FileHash -LiteralPath $stagedPath -Algorithm SHA256).Hash -cne $protectedHashes[$sourcePath]) {
            throw "First ReShadeCas enable did not stage exact project asset '$assetRelativePath'."
        }
    }
    if ((Get-FileHash -LiteralPath (Join-Path $stageRoot 'ReShade.ini') -Algorithm SHA256).Hash -cne
        $protectedHashes[(Join-Path $postProcessAssetRoot 'config\ReShade.seed.ini')] -or
        (Get-FileHash -LiteralPath (Join-Path $stageRoot 'FearMore-CAS.ini') -Algorithm SHA256).Hash -cne
        $protectedHashes[(Join-Path $postProcessAssetRoot 'config\FearMore-CAS.seed.ini')] -or
        (Get-Content -LiteralPath (Join-Path $stageRoot 'ReShade.ini') -Raw) -notmatch '(?m)^TutorialProgress=4$') {
        throw 'First ReShadeCas enable did not apply the exact tutorial-skipping ReShade/CAS config seeds.'
    }

    $utf8NoBom = [Text.UTF8Encoding]::new($false)
    [IO.File]::WriteAllText((Join-Path $stageRoot 'ReShade.ini'), "[FearMoreTest]`r`nUserConfig=preserve`r`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $stageRoot 'FearMore-CAS.ini'), "[FearMoreCAS.fx]`r`nFearMoreSharpness=0.420000`r`n", $utf8NoBom)
    [IO.File]::WriteAllText((Join-Path $stageRoot 'ReShade.log'), "runtime log sentinel`r`n", $utf8NoBom)
    $cacheFile = Join-Path $stageRoot '.fearmore\postprocess\Cache\nested\runtime-cache.bin'
    New-Item -ItemType Directory -Path (Split-Path $cacheFile -Parent) -Force | Out-Null
    [IO.File]::WriteAllBytes($cacheFile, [byte[]](0x43, 0x41, 0x43, 0x48, 0x45))
    $mutableRelativePaths = @('ReShade.ini', 'FearMore-CAS.ini', 'ReShade.log', '.fearmore\postprocess\Cache\nested\runtime-cache.bin')
    $mutableHashes = @{}
    foreach ($relativePath in $mutableRelativePaths) {
        $mutableHashes[$relativePath] = (Get-FileHash -LiteralPath (Join-Path $stageRoot $relativePath) -Algorithm SHA256).Hash
    }

    $restaged = & $stageScript @casParameters
    $restagedManifest = Get-Content -LiteralPath (Join-Path $stageRoot 'fearmore-stage.json') -Raw | ConvertFrom-Json
    if ($restaged.PostProcessConfigSeedApplied -or
        [bool]$restagedManifest.PostProcessConfigSeedApplied -or
        @($restagedManifest.PostProcessConfigSeedAppliedFiles).Count -ne 0) {
        throw 'ReShadeCas restage unexpectedly reseeded user/runtime-owned mutable configuration.'
    }
    foreach ($relativePath in $mutableRelativePaths) {
        if ((Get-FileHash -LiteralPath (Join-Path $stageRoot $relativePath) -Algorithm SHA256).Hash -cne $mutableHashes[$relativePath]) {
            throw "ReShadeCas restage changed runtime-mutable path '$relativePath'."
        }
    }

    $max2xCasParameters = @{} + $casParameters
    $max2xCasParameters.RendererQuality = 'Max2x'
    $enabledBeforeFailedRefresh = Get-StageSnapshot -Root $stageRoot
    $manifestLock = [IO.File]::Open(
        (Join-Path $stageRoot 'fearmore-stage.json'),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        try {
            & $stageScript @max2xCasParameters | Out-Null
        }
        catch {
            Assert-LateManifestCommitFailure -Failure $_ -TransitionName 'same-mode ReShadeCas renderer-quality refresh'
            $sameModeRefreshRollback = $true
        }
    }
    finally {
        $manifestLock.Dispose()
    }
    if (-not $sameModeRefreshRollback -or
        (Get-StageSnapshot -Root $stageRoot) -cne $enabledBeforeFailedRefresh) {
        throw 'Failed same-mode ReShadeCas/renderer-quality refresh did not restore the exact prior stage tree and manifest.'
    }

    $enabledBeforeFailedNone = Get-StageSnapshot -Root $stageRoot
    $manifestLock = [IO.File]::Open(
        (Join-Path $stageRoot 'fearmore-stage.json'),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        try {
            & $stageScript @commonParameters -PostProcessMode None | Out-Null
        }
        catch {
            Assert-LateManifestCommitFailure -Failure $_ -TransitionName 'ReShadeCas-to-None transition'
            $fullToNoneRollback = $true
        }
    }
    finally {
        $manifestLock.Dispose()
    }
    if (-not $fullToNoneRollback -or (Get-StageSnapshot -Root $stageRoot) -cne $enabledBeforeFailedNone) {
        throw 'Failed ReShadeCas-to-None transition did not restore the exact prior stage tree and manifest.'
    }

    $disabled = & $stageScript @commonParameters -PostProcessMode None
    $disabledManifest = Get-Content -LiteralPath (Join-Path $stageRoot 'fearmore-stage.json') -Raw | ConvertFrom-Json
    if ($disabled.PostProcessMode -cne 'None' -or $disabledManifest.PostProcessMode -cne 'None' -or
        -not [bool]$disabledManifest.PostProcessEverEnabled -or
        @($disabledManifest.PostProcessOwnedFiles).Count -ne 0 -or
        $disabledManifest.PostProcessProxyFile -or $disabledManifest.PostProcessPackage -or
        [string]$disabledManifest.PostProcessConfigSeedPolicy -cne 'FirstEnableOnly') {
        throw 'Disabling ReShadeCas did not remove immutable ownership while retaining explicit mutable-state history.'
    }
    foreach ($relativePath in $immutableRelativePaths) {
        if (Test-Path -LiteralPath (Join-Path $stageRoot $relativePath)) {
            throw "Disabling ReShadeCas retained immutable path '$relativePath'."
        }
    }
    foreach ($relativePath in $mutableRelativePaths) {
        if ((Get-FileHash -LiteralPath (Join-Path $stageRoot $relativePath) -Algorithm SHA256).Hash -cne $mutableHashes[$relativePath]) {
            throw "Disabling ReShadeCas changed runtime-mutable path '$relativePath'."
        }
    }

    $disabledBeforeFailedEnable = Get-StageSnapshot -Root $stageRoot
    $manifestLock = [IO.File]::Open(
        (Join-Path $stageRoot 'fearmore-stage.json'),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read)
    try {
        try {
            & $stageScript @casParameters | Out-Null
        }
        catch {
            Assert-LateManifestCommitFailure -Failure $_ -TransitionName 'None-to-ReShadeCas transition'
            $noneToFullRollback = $true
        }
    }
    finally {
        $manifestLock.Dispose()
    }
    if (-not $noneToFullRollback -or (Get-StageSnapshot -Root $stageRoot) -cne $disabledBeforeFailedEnable) {
        throw 'Failed None-to-ReShadeCas transition did not restore the exact prior stage tree and manifest.'
    }

    $reEnabled = & $stageScript @casParameters
    $reEnabledManifest = Get-Content -LiteralPath (Join-Path $stageRoot 'fearmore-stage.json') -Raw | ConvertFrom-Json
    if ($reEnabled.PostProcessMode -cne 'ReShadeCas' -or
        $reEnabled.PostProcessConfigSeedApplied -or
        [bool]$reEnabledManifest.PostProcessConfigSeedApplied -or
        @($reEnabledManifest.PostProcessConfigSeedAppliedFiles).Count -ne 0) {
        throw 'Re-enabling ReShadeCas did not preserve FirstEnableOnly seed semantics.'
    }
    foreach ($relativePath in $mutableRelativePaths) {
        if ((Get-FileHash -LiteralPath (Join-Path $stageRoot $relativePath) -Algorithm SHA256).Hash -cne $mutableHashes[$relativePath]) {
            throw "Re-enabling ReShadeCas changed runtime-mutable path '$relativePath'."
        }
    }

    $proxyPath = Join-Path $stageRoot 'dxgi.dll'
    $originalProxyBytes = [IO.File]::ReadAllBytes($proxyPath)
    $tamperedProxyBytes = [byte[]]$originalProxyBytes.Clone()
    $tamperedProxyBytes[$tamperedProxyBytes.Length - 1] = $tamperedProxyBytes[$tamperedProxyBytes.Length - 1] -bxor 0x01
    [IO.File]::WriteAllBytes($proxyPath, $tamperedProxyBytes)
    $beforeProxyRejection = Get-StageSnapshot -Root $stageRoot
    $proxyTamperRejected = $false
    try {
        & $stageScript @commonParameters -PostProcessMode None | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('immutable payload was changed or removed')) { throw }
        $proxyTamperRejected = $true
    }
    if (-not $proxyTamperRejected -or (Get-StageSnapshot -Root $stageRoot) -cne $beforeProxyRejection) {
        throw 'Tampered ReShade DXGI proxy was accepted or the rejected stage was mutated.'
    }
    $tamperRejections.Add('dxgi.dll')
    [IO.File]::WriteAllBytes($proxyPath, $originalProxyBytes)

    $assetPath = Join-Path $stageRoot '.fearmore\postprocess\Shaders\FearMoreCAS.fx'
    $originalAssetBytes = [IO.File]::ReadAllBytes($assetPath)
    [IO.File]::WriteAllBytes($assetPath, $originalAssetBytes + [byte[]](0x0A))
    $beforeAssetRejection = Get-StageSnapshot -Root $stageRoot
    $assetTamperRejected = $false
    try {
        & $stageScript @commonParameters -PostProcessMode None | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('immutable payload was changed or removed')) { throw }
        $assetTamperRejected = $true
    }
    if (-not $assetTamperRejected -or (Get-StageSnapshot -Root $stageRoot) -cne $beforeAssetRejection) {
        throw 'Tampered CAS shader asset was accepted or the rejected stage was mutated.'
    }
    $tamperRejections.Add('.fearmore\postprocess\Shaders\FearMoreCAS.fx')
    [IO.File]::WriteAllBytes($assetPath, $originalAssetBytes)

    $rogueAssetPath = Join-Path $stageRoot '.fearmore\postprocess\Shaders\rogue.fx'
    [IO.File]::WriteAllBytes($rogueAssetPath, [byte[]](0x52, 0x4F, 0x47, 0x55, 0x45))
    $beforeRogueRejection = Get-StageSnapshot -Root $stageRoot
    $rogueAssetRejected = $false
    try {
        & $stageScript @commonParameters -PostProcessMode None | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('unowned immutable file')) { throw }
        $rogueAssetRejected = $true
    }
    if (-not $rogueAssetRejected -or (Get-StageSnapshot -Root $stageRoot) -cne $beforeRogueRejection) {
        throw 'Unowned post-process asset-tree file was accepted or the rejected stage was mutated.'
    }
    $tamperRejections.Add('.fearmore\postprocess\Shaders\rogue.fx')
    Remove-Item -LiteralPath $rogueAssetPath -Force

    & $stageScript @commonParameters -PostProcessMode None | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $stageRoot 'dxgi.dll'), [byte[]](0x55, 0x4E, 0x4F, 0x57, 0x4E, 0x45, 0x44))
    $beforeUnownedProxyRejection = Get-StageSnapshot -Root $stageRoot
    $unownedProxyRejected = $false
    try {
        & $stageScript @commonParameters -PostProcessMode None | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('unowned post-process proxy or immutable asset')) { throw }
        $unownedProxyRejected = $true
    }
    if (-not $unownedProxyRejected -or (Get-StageSnapshot -Root $stageRoot) -cne $beforeUnownedProxyRejection) {
        throw 'Disabled stage accepted an unowned DXGI proxy or mutated during rejection.'
    }
    $tamperRejections.Add('unowned dxgi.dll')
    Remove-Item -LiteralPath (Join-Path $stageRoot 'dxgi.dll') -Force

    $manifestPath = Join-Path $stageRoot 'fearmore-stage.json'
    $validDisabledManifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $malformedHistoryManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $malformedHistoryManifest.PostProcessEverEnabled = 'false'
    [IO.File]::WriteAllText(
        $manifestPath,
        ($malformedHistoryManifest | ConvertTo-Json -Depth 6),
        [Text.UTF8Encoding]::new($false))
    $beforeMalformedHistoryRejection = Get-StageSnapshot -Root $stageRoot
    try {
        & $stageScript @commonParameters -PostProcessMode None | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('PostProcessEverEnabled must be a JSON Boolean')) { throw }
        $malformedHistoryBooleanRejected = $true
    }
    if (-not $malformedHistoryBooleanRejected -or
        (Get-StageSnapshot -Root $stageRoot) -cne $beforeMalformedHistoryRejection) {
        throw 'Malformed string PostProcessEverEnabled ownership grant was accepted or mutated during rejection.'
    }
    [IO.File]::WriteAllBytes($manifestPath, $validDisabledManifestBytes)

    $invalidSelections = @(
        [pscustomobject]@{ Lane = 'Rebuilt'; RendererMode = 'NativeD3D9'; Expected = 'requires -RendererMode DgVoodooD3D11' },
        [pscustomobject]@{ Lane = 'StockEchoPatch'; RendererMode = 'NativeD3D9'; Expected = 'supported only by -Lane Rebuilt' },
        [pscustomobject]@{ Lane = 'Rebuilt'; RendererMode = 'RtxRemixProbe'; Expected = 'requires -RendererMode DgVoodooD3D11' }
    )
    foreach ($invalidSelection in $invalidSelections) {
        $invalidParameters = @{} + $commonParameters
        $invalidParameters.Lane = $invalidSelection.Lane
        $invalidParameters.RendererMode = $invalidSelection.RendererMode
        $beforeInvalidSelection = Get-StageSnapshot -Root $stageRoot
        $invalidRejected = $false
        try {
            & $stageScript @invalidParameters -PostProcessMode ReShadeCas -ValidateOnly | Out-Null
        }
        catch {
            if (-not $_.Exception.Message.Contains($invalidSelection.Expected)) { throw }
            $invalidRejected = $true
        }
        if (-not $invalidRejected -or (Get-StageSnapshot -Root $stageRoot) -cne $beforeInvalidSelection) {
            throw "Invalid ReShadeCas $($invalidSelection.Lane)/$($invalidSelection.RendererMode) selection was accepted or mutated the stage."
        }
    }

    $beforeSetupWithoutMode = Get-StageSnapshot -Root $stageRoot
    $setupWithoutModeRejected = $false
    try {
        & $stageScript @commonParameters -PostProcessMode None -ReShadeSetup $reShadeSetup -ValidateOnly | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('-ReShadeSetup requires -PostProcessMode ReShadeCas')) { throw }
        $setupWithoutModeRejected = $true
    }
    if (-not $setupWithoutModeRejected -or (Get-StageSnapshot -Root $stageRoot) -cne $beforeSetupWithoutMode) {
        throw 'Explicit ReShade setup without ReShadeCas mode was accepted or mutated the stage.'
    }

    Copy-Item -LiteralPath $reShadeSetup -Destination $badSetup -Force
    $badSetupBytes = [IO.File]::ReadAllBytes($badSetup)
    $badSetupBytes[$badSetupBytes.Length - 1] = $badSetupBytes[$badSetupBytes.Length - 1] -bxor 0x01
    [IO.File]::WriteAllBytes($badSetup, $badSetupBytes)
    $badSetupParameters = @{} + $casParameters
    $badSetupParameters.ReShadeSetup = $badSetup
    $beforeBadSetup = Get-StageSnapshot -Root $stageRoot
    $badSetupRejected = $false
    try {
        & $stageScript @badSetupParameters -ValidateOnly | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('ReShade setup hash mismatch')) { throw }
        $badSetupRejected = $true
    }
    if (-not $badSetupRejected -or (Get-StageSnapshot -Root $stageRoot) -cne $beforeBadSetup) {
        throw 'Changed ReShade setup was accepted or mutated the disabled stage.'
    }

    foreach ($inputPath in $protectedInputs) {
        if ((Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash -cne $protectedHashes[$inputPath]) {
            throw "Post-process stage verification changed protected input '$inputPath'."
        }
    }

    [pscustomobject]@{
        Status                         = 'PASS'
        PackageVersion                 = $stagePayloadIdentity.ReShadeVersion
        ProxySha256                    = $stagePayloadIdentity.ProxySha256
        ImmutableFileCount             = $immutableRelativePaths.Count
        FirstEnableSeeds               = @('ReShade.ini', 'FearMore-CAS.ini')
        FirstEnableUnownedStateRejected = @($legacyStateRejections)
        MutableStatePreserved          = @($mutableRelativePaths)
        ReShadeCasToNoneRollback       = $fullToNoneRollback
        NoneToReShadeCasRollback       = $noneToFullRollback
        SameModeRendererRefreshRollback = $sameModeRefreshRollback
        MalformedHistoryBooleanRejected = $malformedHistoryBooleanRejected
        TamperAndUnownedStateRejected  = @($tamperRejections)
        InvalidSelectionsRejected      = @('NativeD3D9', 'StockEchoPatch', 'RtxRemixProbe', 'SetupWithoutMode', 'ChangedSetup')
        SchemaVersion                  = 9
        CompatibilityStatus            = 'LiveAcceptedDgVoodooDxgiChain'
        ProjectLiveChainAccepted       = $true
        StageInvocationLiveTested      = $false
    }
}
finally {
    foreach ($path in $cleanupPaths) {
        Remove-PostProcessTestPath -Path $path -LocalRuntimeRoot $localRuntimeRoot -AllowedPaths $cleanupPaths
    }
}
