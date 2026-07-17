[CmdletBinding()]
param(
    [string]$RepositoryRoot,

    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DirectorySnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    return (@(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relativePath = $_.FullName.Substring([IO.Path]::GetFullPath($Root).TrimEnd('\').Length).TrimStart('\')
        if ($_.PSIsContainer) {
            "DIR|$relativePath|$([int]$_.Attributes)"
        }
        else {
            "FILE|$relativePath|$([int]$_.Attributes)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        }
    }) -join "`n")
}

function Remove-LauncherRendererQualityTestPath {
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
        throw "Refusing launcher renderer-quality cleanup outside its exact local-runtime output set: $pathFull"
    }
    if (-not (Test-Path -LiteralPath $pathFull)) {
        return
    }

    $item = Get-Item -LiteralPath $pathFull -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing launcher renderer-quality cleanup through a top-level reparse point: $pathFull"
    }
    foreach ($topLevelItem in @(Get-ChildItem -LiteralPath $pathFull -Force)) {
        if (($topLevelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            continue
        }
        if ($topLevelItem.Name -cne 'Retail' -or
            -not $topLevelItem.PSIsContainer -or
            $topLevelItem.LinkType -cne 'Junction') {
            throw "Refusing launcher renderer-quality cleanup through an unexpected reparse point: $($topLevelItem.FullName)"
        }
        [IO.Directory]::Delete($topLevelItem.FullName, $false)
    }
    $nestedReparse = Get-ChildItem -LiteralPath $pathFull -Force -Recurse |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($nestedReparse) {
        throw "Refusing launcher renderer-quality cleanup through a nested reparse point: $($nestedReparse.FullName)"
    }
    [IO.Directory]::Delete($pathFull, $true)
}

function Invoke-TestLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$LauncherPath,
        [Parameter(Mandatory = $true)][hashtable]$Parameters
    )

    $results = @(& $LauncherPath @Parameters 3>$null 6>$null)
    if ($results.Count -ne 1) {
        throw "Launcher renderer-quality test expected exactly one result; found $($results.Count)."
    }
    return $results[0]
}

function Set-TestModernSelectionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]
        [ValidateSet('EnhancedGore', 'FearMoreCorpsePersistence', 'FearMoreRendererQuality', 'FearMorePostProcess')]
        [string]$SettingName,
        [Parameter(Mandatory = $true)][string]$Record
    )

    $content = [IO.File]::ReadAllText($Path)
    $pattern = '(?im)^\s*"' + [regex]::Escape($SettingName) + '"\s+"[^"]*"\s*$'
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one launcher $SettingName record before editing the fixture; found $($matches.Count): $Path"
    }
    $updated = [regex]::Replace($content, $pattern, $Record)
    [IO.File]::WriteAllText($Path, $updated, [Text.UTF8Encoding]::new($false))
}

function Remove-TestModernSelectionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SettingName
    )

    $content = [IO.File]::ReadAllText($Path)
    $pattern = '(?im)^\s*"' + [regex]::Escape($SettingName) + '"\s+"[^"]*"\s*\r?\n?'
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one launcher $SettingName record before removing the fixture field; found $($matches.Count): $Path"
    }
    [IO.File]::WriteAllText($Path, [regex]::Replace($content, $pattern, ''), [Text.UTF8Encoding]::new($false))
}

function Add-TestModernSelectionRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$SettingName,
        [Parameter(Mandatory = $true)][string]$Record
    )

    $content = [IO.File]::ReadAllText($Path)
    if ([regex]::IsMatch($content, '(?i)' + [regex]::Escape($SettingName))) {
        throw "Refusing to add a duplicate launcher $SettingName fixture field: $Path"
    }
    $separator = if ($content.EndsWith("`n")) { '' } else { "`r`n" }
    [IO.File]::WriteAllText($Path, $content + $separator + $Record + "`r`n", [Text.UTF8Encoding]::new($false))
}

function Assert-LauncherStageQuality {
    param(
        [Parameter(Mandatory = $true)]$Result,
        [Parameter(Mandatory = $true)][ValidateSet('Native', 'Max2x')][string]$ExpectedQuality,
        [ValidateSet('None', 'ReShadeCas')][string]$ExpectedPostProcess = 'None',
        [bool]$ExpectedEnhancedGore = $true,
        [bool]$ExpectedCorpsePersistence = $true,
        [Parameter(Mandatory = $true)][string]$ExpectedStageRoot
    )

    $expectedRootFull = [IO.Path]::GetFullPath($ExpectedStageRoot)
    $expectedResolution = if ($ExpectedQuality -eq 'Max2x') { 'max_2x' } else { 'unforced' }
    $expectedPostProcessStatus = if ($ExpectedPostProcess -eq 'ReShadeCas') { 'LiveAcceptedDgVoodooDxgiChain' } else { 'NotApplicable' }
    $expectedAcceptanceScope = if ($ExpectedPostProcess -eq 'ReShadeCas') {
        'Project-level live acceptance verified'
    }
    else {
        'Runtime launch and gameplay acceptance have not been performed by the staging tool.'
    }
    if ($Result.Preset -cne 'Modern' -or
        $Result.RendererMode -cne 'DgVoodooD3D11' -or
        $Result.RendererQuality -cne $ExpectedQuality -or
        $Result.RendererResolution -cne $expectedResolution -or
        $Result.RendererResampling -cne 'lanczos-3' -or
        $Result.RendererCompatibilityStatus -cne 'LiveAcceptedDgVoodooD3D11' -or
        $Result.PostProcessMode -cne $ExpectedPostProcess -or
        $Result.PostProcessCompatibilityStatus -cne $expectedPostProcessStatus -or
        [bool]$Result.PostProcessAcceptanceTested -or [bool]$Result.AcceptanceTested -or
        [bool]$Result.EnhancedGoreEnabled -ne $ExpectedEnhancedGore -or
        [bool]$Result.CorpsePersistenceEnabled -ne $ExpectedCorpsePersistence -or
        [string]::IsNullOrWhiteSpace([string]$Result.AcceptanceNote) -or
        -not $Result.Prepared -or $Result.Launched -or
        -not $Result.StageRoot.Equals($expectedRootFull, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Modern launcher result did not report the requested $ExpectedQuality renderer-quality stage."
    }

    $manifestPath = Join-Path $expectedRootFull 'fearmore-stage.json'
    $configPath = Join-Path $expectedRootFull 'dgVoodoo.conf'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifestLaunchArguments = @($manifest.LaunchArguments)
    $enhancedGoreArgumentIndexes = @(
        for ($argumentIndex = 0; $argumentIndex -lt $manifestLaunchArguments.Count; $argumentIndex++) {
            if ([string]$manifestLaunchArguments[$argumentIndex] -ceq '+EnhancedGore') {
                $argumentIndex
            }
        }
    )
    $expectedEnhancedGoreArgument = if ($ExpectedEnhancedGore) { '1' } else { '0' }
    if ($enhancedGoreArgumentIndexes.Count -ne 1 -or
        $enhancedGoreArgumentIndexes[0] + 1 -ge $manifestLaunchArguments.Count -or
        [string]$manifestLaunchArguments[$enhancedGoreArgumentIndexes[0] + 1] -cne $expectedEnhancedGoreArgument) {
        throw "Modern launcher manifest does not own exactly one +EnhancedGore $expectedEnhancedGoreArgument argument pair."
    }
    $configIdentity = Get-FearDgVoodooConfigIdentity `
        -Path $configPath `
        -RendererQuality $ExpectedQuality
    if ($manifest.RendererMode -cne 'DgVoodooD3D11' -or
        $manifest.RendererQuality -cne $ExpectedQuality -or
        $manifest.RendererResolution -cne $expectedResolution -or
        $manifest.RendererResampling -cne 'lanczos-3' -or
        $manifest.RendererOutputAPI -cne 'd3d11_fl11_0' -or
        $manifest.RendererConfigFile -cne 'dgVoodoo.conf' -or
        $manifest.RendererConfigSha256 -cne $configIdentity.Sha256 -or
        $manifest.RendererCompatibilityStatus -cne 'LiveAcceptedDgVoodooD3D11' -or
        $manifest.PostProcessMode -cne $ExpectedPostProcess -or
        $manifest.PostProcessCompatibilityStatus -cne $expectedPostProcessStatus -or
        [bool]$manifest.PostProcessAcceptanceTested -or
        [string]$Result.AcceptanceNote -cne [string]$manifest.AcceptanceNote -or
        [string]$manifest.AcceptanceNote -notmatch [regex]::Escape($expectedAcceptanceScope) -or
        ($ExpectedPostProcess -eq 'ReShadeCas' -and
            [string]$manifest.AcceptanceNote -notmatch [regex]::Escape('does not itself prove')) -or
        $configIdentity.RendererQuality -cne $Result.RendererQuality -or
        $configIdentity.Resolution -cne $manifest.RendererResolution -or
        $configIdentity.Resampling -cne $manifest.RendererResampling) {
        throw "Modern launcher result, staged manifest, and dgVoodoo config disagree for $ExpectedQuality."
    }

    $postProcessProxy = Join-Path $expectedRootFull 'dxgi.dll'
    if (($ExpectedPostProcess -eq 'ReShadeCas') -ne (Test-Path -LiteralPath $postProcessProxy -PathType Leaf)) {
        throw "Modern launcher did not stage the exact $ExpectedPostProcess post-process proxy state."
    }
    if ([string]$Result.AcceptanceNote -cne [string]$manifest.AcceptanceNote) {
        throw 'Modern launcher result and staged manifest disagree about the per-invocation acceptance scope.'
    }
    if ($ExpectedPostProcess -eq 'ReShadeCas') {
        if ([string]$Result.AcceptanceNote -notmatch 'Project-level live acceptance verified' -or
            [string]$Result.AcceptanceNote -notmatch 'does not itself prove') {
            throw 'Modern CAS launcher result no longer distinguishes project-level acceptance from this staging invocation.'
        }
    }
    elseif ([string]$Result.AcceptanceNote -notmatch 'Runtime launch and gameplay acceptance have not been performed by the staging tool') {
        throw 'Modern no-CAS launcher result no longer reports its per-invocation acceptance scope.'
    }
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$localRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'local-runtime')).TrimEnd('\')
$launcherPath = Join-Path $PSScriptRoot 'Start-FearMore.ps1'
$settingsModule = Join-Path $PSScriptRoot 'FearLauncherSettings.psm1'
$rendererPackageModule = Join-Path $PSScriptRoot 'FearRendererPackage.psm1'
$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
$stagePlanModule = Join-Path $PSScriptRoot 'FearRuntimeStagePlan.psm1'
$rendererNativeConfig = Join-Path $PSScriptRoot 'config\dgVoodoo-d3d11.conf'
$rendererMax2xConfig = Join-Path $PSScriptRoot 'config\dgVoodoo-d3d11-max2x.conf'
$sdkRuntimeExecutable = Join-Path $RepositoryRoot 'vendor-local\fear-sdk-108\Runtime\FEARDevSP.exe'
$buildRoot = Join-Path $RepositoryRoot "build\fear-win32\bin\$Configuration"
$dgVoodooArchive = Join-Path $RepositoryRoot 'vendor-local\renderer-deps\dgVoodoo2_87_3.zip'
$postProcessSetup = Join-Path $RepositoryRoot 'vendor-local\postprocess-deps\ReShade_Setup_6.7.3.exe'
$postProcessAssetRoot = Join-Path $PSScriptRoot 'postprocess'
$enginePatchPackageRoot = Join-Path $RepositoryRoot 'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb'
$enginePatchManifest = Join-Path $RepositoryRoot 'vendor-local\echopatch-engine-only\manifest-b4a7074e4cbb.json'
$protectedInputs = @(
    $launcherPath,
    $settingsModule,
    $rendererPackageModule,
    $stageScript,
    $stagePlanModule,
    $rendererNativeConfig,
    $rendererMax2xConfig,
    $sdkRuntimeExecutable,
    (Join-Path $buildRoot 'GameClient.dll'),
    (Join-Path $buildRoot 'GameServer.dll'),
    (Join-Path $buildRoot 'ClientFx.fxd'),
    $dgVoodooArchive,
    $postProcessSetup,
    (Join-Path $postProcessAssetRoot 'config\FearMore-CAS.seed.ini'),
    (Join-Path $postProcessAssetRoot 'config\ReShade.seed.ini'),
    (Join-Path $postProcessAssetRoot 'licenses\AMD-CAS-MIT.txt'),
    (Join-Path $postProcessAssetRoot 'licenses\ReShade-BSD-3-Clause.txt'),
    (Join-Path $postProcessAssetRoot 'Shaders\FearMoreCAS.fx'),
    (Join-Path $enginePatchPackageRoot 'dinput8.dll'),
    (Join-Path $enginePatchPackageRoot 'EchoPatch.ini'),
    $enginePatchManifest
)
foreach ($inputPath in $protectedInputs) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "Launcher renderer-quality test input is missing: $inputPath"
    }
}
$beforeHashes = @{}
foreach ($inputPath in $protectedInputs) {
    $beforeHashes[$inputPath] = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
}

Import-Module $settingsModule -Force -ErrorAction Stop
Import-Module $rendererPackageModule -Force -ErrorAction Stop

$runId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path $localRuntimeRoot "launcher-renderer-quality-retail-$runId"
$stageRoot = Join-Path $localRuntimeRoot "launcher-renderer-quality-stage-$runId"
$nonModernStageRoot = Join-Path $localRuntimeRoot "launcher-renderer-quality-rejected-$runId"
$cleanupPaths = @($fixtureRoot, $stageRoot, $nonModernStageRoot)
$malformedValuesRejected = 0

try {
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    Copy-Item -LiteralPath $sdkRuntimeExecutable -Destination (Join-Path $fixtureRoot 'FEAR.exe') -Force
    foreach ($fileName in @('EngineServer.dll', 'GameDatabase.dll', 'LTMemory.dll', 'SndDrv.dll', 'StringEditRuntime.dll')) {
        [IO.File]::WriteAllBytes((Join-Path $fixtureRoot $fileName), [byte[]](0x46, 0x45, 0x41, 0x52))
    }
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'FEAR.Arch00'), [byte[]](0x46, 0x45, 0x41, 0x52))
    [IO.File]::WriteAllLines((Join-Path $fixtureRoot 'Default.archcfg'), @('FEAR.Arch00'), [Text.ASCIIEncoding]::new())

    $baseParameters = @{
        Preset      = 'Modern'
        RetailRoot  = $fixtureRoot
        StageRoot   = $stageRoot
        PrepareOnly = $true
    }
    $settingsPath = Join-Path $stageRoot 'UserDirectory\settings.cfg'
    if (Test-Path -LiteralPath $settingsPath) {
        throw "Fresh launcher fixture unexpectedly contains settings.cfg: $settingsPath"
    }

    $missingSettingResult = Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $baseParameters
    Assert-LauncherStageQuality -Result $missingSettingResult -ExpectedQuality Native -ExpectedStageRoot $stageRoot
    if ((Get-FearMoreRendererQualityFromSettings -Path $settingsPath) -cne 'Native' -or
        -not [IO.File]::ReadAllText($settingsPath).Contains('"FearMoreRendererQuality" "0.000000"') -or
        -not [IO.File]::ReadAllText($settingsPath).Contains('"EnhancedGore" "1.000000"') -or
        -not [IO.File]::ReadAllText($settingsPath).Contains('"FearMoreCorpsePersistence" "1.000000"')) {
        throw 'Fresh Modern launcher preparation did not seed and retain the Native quality setting.'
    }

    Remove-TestModernSelectionRecord `
        -Path $settingsPath `
        -SettingName FearMoreCorpsePersistence
    $existingMissingCorpseSettings = [IO.File]::ReadAllBytes($settingsPath)
    $existingMissingCorpseResult = Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $baseParameters
    Assert-LauncherStageQuality `
        -Result $existingMissingCorpseResult `
        -ExpectedQuality Native `
        -ExpectedCorpsePersistence $false `
        -ExpectedStageRoot $stageRoot
    if ([regex]::IsMatch([IO.File]::ReadAllText($settingsPath), '(?i)FearMoreCorpsePersistence')) {
        throw 'Launcher rewrote an existing profile to add a missing corpse-persistence field.'
    }
    $existingMissingCorpseSettingsAfter = [IO.File]::ReadAllBytes($settingsPath)
    if ($existingMissingCorpseSettings.Length -ne $existingMissingCorpseSettingsAfter.Length -or
        [Convert]::ToBase64String($existingMissingCorpseSettings) -cne [Convert]::ToBase64String($existingMissingCorpseSettingsAfter)) {
        throw 'Launcher changed an existing settings.cfg while resolving a missing corpse-persistence field.'
    }
    Add-TestModernSelectionRecord `
        -Path $settingsPath `
        -SettingName FearMoreCorpsePersistence `
        -Record '"FearMoreCorpsePersistence" "1.000000"'

    Set-TestModernSelectionRecord `
        -Path $settingsPath `
        -SettingName EnhancedGore `
        -Record '"EnhancedGore" "0.000000"'
    $savedGoreOffResult = Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $baseParameters
    Assert-LauncherStageQuality `
        -Result $savedGoreOffResult `
        -ExpectedQuality Native `
        -ExpectedEnhancedGore $false `
        -ExpectedStageRoot $stageRoot
    Set-TestModernSelectionRecord `
        -Path $settingsPath `
        -SettingName EnhancedGore `
        -Record '"EnhancedGore" "1.000000"'

    Set-TestModernSelectionRecord `
        -Path $settingsPath `
        -SettingName FearMoreCorpsePersistence `
        -Record '"FearMoreCorpsePersistence" "0.000000"'
    $savedCorpsePersistenceOffResult = Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $baseParameters
    Assert-LauncherStageQuality `
        -Result $savedCorpsePersistenceOffResult `
        -ExpectedQuality Native `
        -ExpectedCorpsePersistence $false `
        -ExpectedStageRoot $stageRoot
    Set-TestModernSelectionRecord `
        -Path $settingsPath `
        -SettingName FearMoreCorpsePersistence `
        -Record '"FearMoreCorpsePersistence" "1.000000"'

    $goreArgumentOverride = $baseParameters.Clone()
    $goreArgumentOverride.LaunchArguments = @('+EnhancedGore', '0')
    $beforeGoreOverrideRejection = Get-DirectorySnapshot -Root $stageRoot
    $goreArgumentOverrideRejected = $false
    try {
        Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $goreArgumentOverride | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('must not override the launcher-owned EnhancedGore state')) { throw }
        $goreArgumentOverrideRejected = $true
    }
    if (-not $goreArgumentOverrideRejected -or
        (Get-DirectorySnapshot -Root $stageRoot) -cne $beforeGoreOverrideRejection) {
        throw 'A free-form EnhancedGore launch override was accepted or staging began before its rejection.'
    }

    $savedZeroResult = Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $baseParameters
    Assert-LauncherStageQuality -Result $savedZeroResult -ExpectedQuality Native -ExpectedStageRoot $stageRoot

    Set-TestModernSelectionRecord `
        -Path $settingsPath `
        -SettingName FearMoreRendererQuality `
        -Record '"FearMoreRendererQuality" "1.000000"'
    if ((Get-FearMoreRendererQualityFromSettings -Path $settingsPath) -cne 'Max2x') {
        throw 'Launcher test fixture did not expose the saved Max2x setting before invocation.'
    }
    $savedOneResult = Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $baseParameters
    Assert-LauncherStageQuality -Result $savedOneResult -ExpectedQuality Max2x -ExpectedStageRoot $stageRoot

    $explicitParameters = $baseParameters.Clone()
    $explicitParameters.RendererQuality = 'Native'
    $explicitOverrideResult = Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $explicitParameters
    Assert-LauncherStageQuality -Result $explicitOverrideResult -ExpectedQuality Native -ExpectedStageRoot $stageRoot
    if ((Get-FearMoreRendererQualityFromSettings -Path $settingsPath) -cne 'Max2x') {
        throw 'Explicit CLI renderer quality unexpectedly rewrote the saved in-game selection.'
    }

    Set-TestModernSelectionRecord `
        -Path $settingsPath `
        -SettingName FearMorePostProcess `
        -Record '"FearMorePostProcess" "1.000000"'
    if ((Get-FearMorePostProcessModeFromSettings -Path $settingsPath) -cne 'ReShadeCas') {
        throw 'Launcher test fixture did not expose the saved ReShadeCas setting before invocation.'
    }
    $savedCasResult = Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $baseParameters
    Assert-LauncherStageQuality `
        -Result $savedCasResult `
        -ExpectedQuality Max2x `
        -ExpectedPostProcess ReShadeCas `
        -ExpectedStageRoot $stageRoot

    $explicitPostProcessParameters = $baseParameters.Clone()
    $explicitPostProcessParameters.PostProcessMode = 'None'
    $explicitPostProcessResult = Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $explicitPostProcessParameters
    Assert-LauncherStageQuality `
        -Result $explicitPostProcessResult `
        -ExpectedQuality Max2x `
        -ExpectedPostProcess None `
        -ExpectedStageRoot $stageRoot
    if ((Get-FearMorePostProcessModeFromSettings -Path $settingsPath) -cne 'ReShadeCas') {
        throw 'Explicit CLI post-process mode unexpectedly rewrote the saved in-game selection.'
    }

    foreach ($invalidRecord in @(
            '"FearMoreRendererQuality" "1.5"',
            '"FearMoreRendererQuality" "2.000000"',
            'FearMoreRendererQuality 1'
        )) {
        Set-TestModernSelectionRecord `
            -Path $settingsPath `
            -SettingName FearMoreRendererQuality `
            -Record $invalidRecord
        $beforeRejection = Get-DirectorySnapshot -Root $stageRoot
        $rejected = $false
        try {
            Invoke-TestLauncher -LauncherPath $launcherPath -Parameters $baseParameters | Out-Null
        }
        catch {
            if (-not $_.Exception.Message.Contains('FearMoreRendererQuality')) { throw }
            $rejected = $true
        }
        if (-not $rejected -or (Get-DirectorySnapshot -Root $stageRoot) -cne $beforeRejection) {
            throw "Malformed saved renderer quality was accepted or staging began before rejection: $invalidRecord"
        }
        $malformedValuesRejected++
    }

    $nonModernRejected = $false
    try {
        Invoke-TestLauncher -LauncherPath $launcherPath -Parameters @{
            Preset           = 'Stable'
            RetailRoot       = $fixtureRoot
            StageRoot        = $nonModernStageRoot
            RendererQuality  = 'Native'
            PrepareOnly      = $true
        } | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('-RendererQuality applies only to the Modern D3D11-wrapper preset.')) { throw }
        $nonModernRejected = $true
    }
    if (-not $nonModernRejected -or (Test-Path -LiteralPath $nonModernStageRoot)) {
        throw 'Non-Modern explicit renderer quality did not fail before creating a stage.'
    }

    $nonModernPostProcessRejected = $false
    try {
        Invoke-TestLauncher -LauncherPath $launcherPath -Parameters @{
            Preset          = 'Stable'
            RetailRoot      = $fixtureRoot
            StageRoot       = $nonModernStageRoot
            PostProcessMode = 'None'
            PrepareOnly     = $true
        } | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('-PostProcessMode applies only to the Modern D3D11-wrapper preset.')) { throw }
        $nonModernPostProcessRejected = $true
    }
    if (-not $nonModernPostProcessRejected -or (Test-Path -LiteralPath $nonModernStageRoot)) {
        throw 'Non-Modern explicit post-process mode did not fail before creating a stage.'
    }

    foreach ($inputPath in $protectedInputs) {
        if ((Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash -cne $beforeHashes[$inputPath]) {
            throw "Protected launcher renderer-quality input changed during the test: $inputPath"
        }
    }

    [pscustomobject]@{
        Status                         = 'PASS'
        MissingSettingDefaultsNative   = $true
        ModernEnhancedGoreDefaultsOn   = $true
        SavedEnhancedGoreOffHonored    = $true
        ModernCorpsePersistenceDefaultsOn = $true
        ExistingMissingCorpseDefaultsOff = $true
        SavedCorpsePersistenceOffHonored = $true
        EnhancedGoreOverrideRejected   = $goreArgumentOverrideRejected
        SavedZeroSelectsNative          = $true
        SavedOneSelectsMax2x            = $true
        ExplicitCliOverridesSavedValue  = $true
        NonModernExplicitRejected       = $nonModernRejected
        SavedCasSelectsReShadeCas        = $true
        ExplicitPostProcessOverride      = 'None'
        SavedPostProcessPreservedByCli   = $true
        NonModernPostProcessRejected     = $nonModernPostProcessRejected
        ProjectLiveChainAccepted         = $true
        StageInvocationLiveTested        = $false
        MalformedSavedValuesRejected    = $malformedValuesRejected
        ResultStageAgreementVerified    = $true
        SavedSettingPreservedByCli      = $true
        ProtectedInputsUnchanged        = $true
        RuntimeLaunched                 = $false
    }
}
finally {
    foreach ($cleanupPath in $cleanupPaths) {
        Remove-LauncherRendererQualityTestPath `
            -Path $cleanupPath `
            -LocalRuntimeRoot $localRuntimeRoot `
            -AllowedPaths $cleanupPaths
    }
}
