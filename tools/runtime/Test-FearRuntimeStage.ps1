[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$SteamRetailRoot,
    [string]$SteamEchoPatchedStageRoot,
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

function Get-ShallowDirectorySnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    return (@(Get-ChildItem -LiteralPath $Root -Force | Sort-Object Name | ForEach-Object {
        $target = if (($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { @($_.Target) -join ',' } else { '' }
        $hash = if (-not $_.PSIsContainer) { (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash } else { '' }
        $linkTypeProperty = $_.PSObject.Properties['LinkType']
        $linkType = if ($linkTypeProperty) { $linkTypeProperty.Value } else { '' }
        "$($_.Name)|$([int]$_.Attributes)|$linkType|$target|$hash"
    }) -join "`n")
}

function Set-TestLaaHeaderOnly {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or ($peOffset + 92) -ge $bytes.Length -or
        $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45) {
        throw "Test fixture is not a valid PE image: $Path"
    }

    $characteristics = [BitConverter]::ToUInt16($bytes, $peOffset + 22)
    ([BitConverter]::GetBytes([uint16]($characteristics -bor 0x20))).CopyTo($bytes, $peOffset + 22)
    for ($index = 0; $index -lt 4; $index++) {
        $bytes[$peOffset + 88 + $index] = 0
    }
    [IO.File]::WriteAllBytes($Path, $bytes)
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
$runtimeExecutableModule = Join-Path $PSScriptRoot 'FearRuntimeExecutable.psm1'
$stageSafetyModule = Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1'
$stagePlanModule = Join-Path $PSScriptRoot 'FearRuntimeStagePlan.psm1'
$stageOwnershipModule = Join-Path $PSScriptRoot 'FearRuntimeStageOwnership.psm1'
Import-Module $runtimeExecutableModule -Force -ErrorAction Stop
$steamRetailRootExplicit = $PSBoundParameters.ContainsKey('SteamRetailRoot')
$steamPatchedStageExplicit = $PSBoundParameters.ContainsKey('SteamEchoPatchedStageRoot')
if ($steamRetailRootExplicit -xor $steamPatchedStageExplicit) {
    throw 'Pinned Steam .bind coverage requires both -SteamRetailRoot and -SteamEchoPatchedStageRoot.'
}
if (-not $steamRetailRootExplicit) {
    $localPatchedStageCandidate = Join-Path $RepositoryRoot 'local-runtime\fearmore-stock-echopatch'
    $localPatchedStageManifest = Join-Path $localPatchedStageCandidate 'fearmore-stage.json'
    if (Test-Path -LiteralPath $localPatchedStageManifest -PathType Leaf) {
        $localPatchedManifest = Get-Content -LiteralPath $localPatchedStageManifest -Raw | ConvertFrom-Json
        $retailRootProperty = $localPatchedManifest.PSObject.Properties['RetailRoot']
        $laneProperty = $localPatchedManifest.PSObject.Properties['Lane']
        if ($retailRootProperty -and $laneProperty -and
            [string]$laneProperty.Value -ceq 'StockEchoPatch' -and
            [IO.Path]::IsPathRooted([string]$retailRootProperty.Value)) {
            $localSteamCandidate = [IO.Path]::GetFullPath([string]$retailRootProperty.Value).TrimEnd('\')
            if ((Test-Path -LiteralPath (Join-Path $localSteamCandidate 'FEAR.exe') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $localPatchedStageCandidate 'FEAR.exe') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $localPatchedStageCandidate 'FEAR.exe.bak') -PathType Leaf)) {
                $SteamRetailRoot = $localSteamCandidate
                $SteamEchoPatchedStageRoot = $localPatchedStageCandidate
            }
        }
    }
}
$runtimeUserDirectoryDocs = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'FEAR\Dev\Runtime\serverreadme.txt') -Raw
$gameClientShellSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'FEAR\Dev\Source\FEAR\ClientShellDLL\GameClientShell.cpp') -Raw
$profileUtilsSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'FEAR\Dev\Source\FEAR\Shared\ProfileUtils.cpp') -Raw
if ($runtimeUserDirectoryDocs -notmatch '(?i)-userdirectory\s+\(path\)' -or
    $runtimeUserDirectoryDocs -notmatch '(?i)FEARServerXP\.exe\s+-userdirectory\s+c:\\fearxp\\user') {
    throw 'Checked-in runtime documentation no longer proves the engine-level -userdirectory command-line switch.'
}
if ($gameClientShellSource -notmatch 'GetConsoleVariable\("UserDirectory"\)' -or $gameClientShellSource -notmatch 'SetUserDirectory\(pszUserDirectory\)' -or $gameClientShellSource -notmatch 'strSaveDirectory\s*\+=\s*"Save"') {
    throw 'Checked-in game source no longer proves UserDirectory selection and the stage-local Save root.'
}
if ($profileUtilsSource -notmatch 'GetAbsoluteUserFileName' -or $profileUtilsSource -notmatch 'directory\s*\+=\s*PROFILE_DIR') {
    throw 'Checked-in profile source no longer proves that profiles are rooted under UserDirectory.'
}

$sdkRoot = Join-Path $RepositoryRoot 'vendor-local\fear-sdk-108'
$buildRoot = Join-Path $RepositoryRoot "build\fear-win32\bin\$Configuration"
$echoPatchArchive = Join-Path $RepositoryRoot 'vendor-local\EchoPatch-4.2.1.zip'
$rendererPackageModule = Join-Path $PSScriptRoot 'FearRendererPackage.psm1'
$enginePatchPackageModule = Join-Path $PSScriptRoot 'FearEnginePatchPackage.psm1'
$controllerPackageModule = Join-Path $PSScriptRoot 'FearControllerPackage.psm1'
$controllerArchive = Join-Path $RepositoryRoot 'vendor-local\controller-deps\SDL3-3.4.10-win32-x86.zip'
$fixtureRoot = Join-Path $RepositoryRoot 'local-runtime\runtime-tool-fixture-retail'
$runId = [Guid]::NewGuid().ToString('N')

$protectedInputs = @(
    $stageScript,
    (Join-Path $sdkRoot 'Runtime\FEARDevSP.exe'),
    (Join-Path $buildRoot 'GameClient.dll'),
    (Join-Path $buildRoot 'GameServer.dll'),
    (Join-Path $buildRoot 'ClientFx.fxd'),
    $runtimeExecutableModule,
    $stageSafetyModule,
    $stagePlanModule,
    $stageOwnershipModule,
    $rendererPackageModule,
    $enginePatchPackageModule,
    $controllerPackageModule,
    $controllerArchive,
    $echoPatchArchive
)
foreach ($inputPath in $protectedInputs) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "Runtime staging test input is missing: $inputPath"
    }
}

$beforeHashes = @{}
foreach ($inputPath in $protectedInputs) {
    $beforeHashes[$inputPath] = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
}

# A synthetic retail-shaped fixture tests staging mechanics only. The executable is
# the official 1.08 FEARDevSP binary so version validation remains real; nothing is launched.
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $sdkRoot 'Runtime\FEARDevSP.exe') -Destination (Join-Path $fixtureRoot 'FEAR.exe') -Force
foreach ($fileName in @('EngineServer.dll', 'GameDatabase.dll', 'LTMemory.dll', 'SndDrv.dll', 'StringEditRuntime.dll')) {
    $fixturePath = Join-Path $fixtureRoot $fileName
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        [IO.File]::WriteAllBytes($fixturePath, [byte[]](0x46, 0x45, 0x41, 0x52))
    }
}
$fixtureArchive = Join-Path $fixtureRoot 'FEAR.Arch00'
if (-not (Test-Path -LiteralPath $fixtureArchive -PathType Leaf)) {
    [IO.File]::WriteAllBytes($fixtureArchive, [byte[]](0x46, 0x45, 0x41, 0x52))
}
[IO.File]::WriteAllLines((Join-Path $fixtureRoot 'Default.archcfg'), @('FEAR.Arch00'), [Text.ASCIIEncoding]::new())

$sdkSmokeStage = Join-Path $RepositoryRoot "local-runtime\runtime tool test sdk smoke safe $($Configuration.ToLowerInvariant())"
$rebuiltStage = Join-Path $RepositoryRoot "local-runtime\runtime tool test rebuilt retail $($Configuration.ToLowerInvariant())"
$stockStage = Join-Path $RepositoryRoot 'local-runtime\runtime tool test stock echopatch'
$stockLaaStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-stock-laa-$runId"
$unknownStockStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-stock-unknown-$runId"
$interruptedRefreshStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-stock-interrupted-refresh-$runId"
$rollbackRefreshStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-stock-refresh-rollback-$runId"
$steamLibraryFixture = Join-Path $RepositoryRoot "local-runtime\runtime-tool-steam-library-$runId"
$steamFixtureRoot = Join-Path $steamLibraryFixture 'steamapps\common\FEAR Steam Fixture'
$steamRebuiltStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-steam-rebuilt-$runId"
$steamStockStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-steam-stock-$runId"
$steamHintCreateRollbackStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-steam-hint-create-rollback-$runId"
$steamHintRemoveRollbackStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-steam-hint-remove-rollback-$runId"
$ownershipRecoveryStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-ownership-recovery-$runId"
$missingRetailStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-missing-retail-$runId"
$unownedNonSteamStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-unowned-nonsteam-$runId"
$unownedSteamStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-unowned-steam-$runId"
$unownedSdkStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-unowned-sdk-$runId"
$ownedStaleHintStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-test-owned-stale-hint-$runId"
$missingSdkRoot = Join-Path $RepositoryRoot "local-runtime\runtime-tool-fixture-missing-sdk-$PID"
$validateOnlyStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-validate-only-$runId-$($Configuration.ToLowerInvariant())"
$whatIfNewStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-whatif-new-$runId-$($Configuration.ToLowerInvariant())"

New-Item -ItemType Directory -Path $steamFixtureRoot -Force | Out-Null
foreach ($fixtureFile in @(Get-ChildItem -LiteralPath $fixtureRoot -File)) {
    Copy-Item -LiteralPath $fixtureFile.FullName -Destination (Join-Path $steamFixtureRoot $fixtureFile.Name) -Force
}
$steamManifest = @'
"AppState"
{
	"appid"		"21090"
	"installdir"		"FEAR Steam Fixture"
}
'@
[IO.File]::WriteAllText((Join-Path $steamLibraryFixture 'steamapps\appmanifest_21090.acf'), $steamManifest, [Text.ASCIIEncoding]::new())

$sdkResult = & $stageScript -Lane SdkSmoke -Configuration $Configuration -RepositoryRoot $RepositoryRoot -SdkRoot $sdkRoot -BuildRoot $buildRoot -StageRoot $sdkSmokeStage
$rebuiltResult = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -SdkRoot $missingSdkRoot -BuildRoot $buildRoot -StageRoot $rebuiltStage
$saveSentinel = Join-Path $rebuiltResult.UserDirectory 'preserve-existing-save.bin'
[IO.File]::WriteAllBytes($saveSentinel, [byte[]](0x53, 0x41, 0x56, 0x45))
$saveSentinelHash = (Get-FileHash -LiteralPath $saveSentinel -Algorithm SHA256).Hash
# A rerun must migrate known SDK files produced by the earlier Rebuilt-lane owner.
foreach ($obsoleteSdkFile in @('FEARDevSP.exe', 'AssertWin32DLL.dll', 'FEAR.proj00', 'msvcp71.dll', 'msvcr71.dll')) {
    [IO.File]::WriteAllBytes((Join-Path $rebuiltStage $obsoleteSdkFile), [byte[]](0x53, 0x44, 0x4B))
}
$rebuiltResult = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -SdkRoot $missingSdkRoot -BuildRoot $buildRoot -StageRoot $rebuiltStage
$whatIfNewResult = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -SdkRoot $missingSdkRoot -BuildRoot $buildRoot -StageRoot $whatIfNewStage -WhatIf
if ((Test-Path -LiteralPath $whatIfNewStage) -or -not $whatIfNewResult.InputsValidated -or
    $whatIfNewResult.LayoutValidated -or $whatIfNewResult.LaunchPermitted) {
    throw 'WhatIf created a new stage or claimed layout/launch completion.'
}
$existingStageBeforeWhatIf = Get-DirectorySnapshot -Root $rebuiltStage
$whatIfExistingResult = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -SdkRoot $missingSdkRoot -BuildRoot $buildRoot -StageRoot $rebuiltStage -WhatIf
if ((Get-DirectorySnapshot -Root $rebuiltStage) -cne $existingStageBeforeWhatIf -or
    -not $whatIfExistingResult.InputsValidated -or $whatIfExistingResult.LayoutValidated -or
    $whatIfExistingResult.LaunchPermitted) {
    throw 'WhatIf mutated an existing owned stage or claimed layout/launch completion.'
}
$missingRetailResult = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -SdkRoot $missingSdkRoot -BuildRoot $buildRoot -StageRoot $missingRetailStage
$missingRetailPath = Join-Path $missingRetailResult.StageRoot 'Retail'
[IO.Directory]::Delete($missingRetailPath, $false)
$missingRetailBefore = Get-DirectorySnapshot -Root $missingRetailStage
$missingRetailRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -SdkRoot $missingSdkRoot -BuildRoot $buildRoot -StageRoot $missingRetailStage | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('Intentional read-only Retail junction is missing')) {
        throw "Missing-Retail ownership guard failed without precise evidence: $($_.Exception.Message)"
    }
    $missingRetailRejected = $true
}
if (-not $missingRetailRejected -or (Get-DirectorySnapshot -Root $missingRetailStage) -cne $missingRetailBefore) {
    throw 'An owned retail-backed stage recreated or otherwise mutated a missing Retail junction instead of failing closed.'
}
$stockDefaultValidation = & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $validateOnlyStage -EchoPatchArchive $echoPatchArchive -ValidateOnly
$stockResult = & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $stockStage -EchoPatchArchive $echoPatchArchive -SSAAScale 2.0
$steamRebuiltResult = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $steamFixtureRoot -BuildRoot $buildRoot -StageRoot $steamRebuiltStage
$steamStockResult = & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $steamFixtureRoot -StageRoot $steamStockStage -EchoPatchArchive $echoPatchArchive

foreach ($stage in @($sdkResult, $rebuiltResult, $stockResult, $steamRebuiltResult, $steamStockResult)) {
    if (-not (Test-Path -LiteralPath $stage.RuntimeExecutable -PathType Leaf)) {
        throw "Staged runtime executable is missing: $($stage.RuntimeExecutable)"
    }
    if (-not (Test-Path -LiteralPath $stage.ArchiveConfig -PathType Leaf)) {
        throw "Staged archive config is missing: $($stage.ArchiveConfig)"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $stage.StageRoot 'fearmore-stage.json') -PathType Leaf)) {
        throw "Stage manifest is missing: $($stage.StageRoot)"
    }
}
if ($sdkResult.LaunchPermitted) {
    throw 'SdkSmoke must remain explicitly launch-forbidden without retail bootstrap DLLs.'
}
if (-not $rebuiltResult.LaunchPermitted -or $stockResult.LaunchPermitted -or
    -not $steamRebuiltResult.LaunchPermitted -or $steamStockResult.LaunchPermitted) {
    throw 'Only Rebuilt is immediately launchable; unbootstrapped StockEchoPatch stages must fail closed.'
}
$sdkManifest = Get-Content -LiteralPath (Join-Path $sdkSmokeStage 'fearmore-stage.json') -Raw | ConvertFrom-Json
$rebuiltManifest = Get-Content -LiteralPath (Join-Path $rebuiltStage 'fearmore-stage.json') -Raw | ConvertFrom-Json
$stockManifest = Get-Content -LiteralPath (Join-Path $stockStage 'fearmore-stage.json') -Raw | ConvertFrom-Json
$steamRebuiltManifest = Get-Content -LiteralPath (Join-Path $steamRebuiltStage 'fearmore-stage.json') -Raw | ConvertFrom-Json
$steamStockManifest = Get-Content -LiteralPath (Join-Path $steamStockStage 'fearmore-stage.json') -Raw | ConvertFrom-Json
if ($sdkManifest.LaunchPermitted -or -not $rebuiltManifest.LaunchPermitted -or $stockManifest.LaunchPermitted -or
    -not $steamRebuiltManifest.LaunchPermitted -or $steamStockManifest.LaunchPermitted) {
    throw 'Persisted stage manifests do not preserve the launch-permission boundary.'
}
if ($sdkResult.RuntimeExecutableState -ne 'SdkDiagnostic' -or $sdkManifest.RuntimeExecutableState -ne 'SdkDiagnostic' -or
    $rebuiltResult.RuntimeExecutableState -ne 'RetailOriginal' -or $rebuiltManifest.RuntimeExecutableState -ne 'RetailOriginal' -or
    $stockResult.RuntimeExecutableState -ne 'RetailOriginal' -or $stockManifest.RuntimeExecutableState -ne 'RetailOriginal') {
    throw 'Runtime results and manifests do not preserve their executable provenance state.'
}
if ($sdkResult.BootstrapRequired -or $sdkManifest.BootstrapRequired -or
    $rebuiltResult.BootstrapRequired -or $rebuiltManifest.BootstrapRequired -or
    -not $stockResult.BootstrapRequired -or -not $stockManifest.BootstrapRequired) {
    throw 'Only the unpatched StockEchoPatch fixture should require its first-launch LAA bootstrap.'
}
if (-not $stockResult.BootstrapNote -or $stockResult.BootstrapNote -ne $stockManifest.BootstrapNote -or
    $stockResult.BootstrapNote -notmatch 'StockEchoPatch executable still requires EchoPatch LAA bootstrap' -or
    $stockResult.BootstrapNote -notmatch 'Launch is blocked' -or
    $sdkResult.BootstrapNote -or $sdkManifest.BootstrapNote -or $rebuiltResult.BootstrapNote -or $rebuiltManifest.BootstrapNote) {
    throw 'BootstrapRequired must carry the generic StockEchoPatch warning and no other lane may claim it.'
}
$stockBootstrapLaunchRejected = $false
try {
    & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $stockStage -EchoPatchArchive $echoPatchArchive -SSAAScale 2.0 -Launch | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('launch is blocked while EchoPatch LAA bootstrap is required')) {
        throw
    }
    $stockBootstrapLaunchRejected = $true
}
if (-not $stockBootstrapLaunchRejected) {
    throw 'Unbootstrapped StockEchoPatch stage was allowed to launch and risk the shared public profile.'
}
foreach ($nonSteamLane in @(
    [pscustomobject]@{ Name = 'SdkSmoke'; Result = $sdkResult; Manifest = $sdkManifest },
    [pscustomobject]@{ Name = 'Rebuilt fixture'; Result = $rebuiltResult; Manifest = $rebuiltManifest },
    [pscustomobject]@{ Name = 'StockEchoPatch fixture'; Result = $stockResult; Manifest = $stockManifest }
)) {
    if ($nonSteamLane.Result.SteamAppId -or $nonSteamLane.Result.SteamAppIdFile -or
        $nonSteamLane.Manifest.SteamAppId -or $nonSteamLane.Manifest.SteamAppIdFile -or
        $nonSteamLane.Result.SteamAppIdHintManaged -or $nonSteamLane.Manifest.SteamAppIdHintManaged -or
        $nonSteamLane.Result.SteamAppIdFileSha256 -or $nonSteamLane.Manifest.SteamAppIdFileSha256 -or
        (Test-Path -LiteralPath (Join-Path $nonSteamLane.Result.StageRoot 'steam_appid.txt'))) {
        throw "$($nonSteamLane.Name) must not claim or create a Steam App ID hint."
    }
}
foreach ($steamLane in @(
    [pscustomobject]@{ Name = 'Steam Rebuilt'; Result = $steamRebuiltResult; Manifest = $steamRebuiltManifest },
    [pscustomobject]@{ Name = 'Steam StockEchoPatch'; Result = $steamStockResult; Manifest = $steamStockManifest }
)) {
    $expectedSteamAppIdFile = Join-Path $steamLane.Result.StageRoot 'steam_appid.txt'
    if ($steamLane.Result.SteamAppId -ne '21090' -or $steamLane.Manifest.SteamAppId -ne '21090' -or
        $steamLane.Result.SteamAppIdFile -ne $expectedSteamAppIdFile -or $steamLane.Manifest.SteamAppIdFile -ne $expectedSteamAppIdFile -or
        -not $steamLane.Result.SteamAppIdHintManaged -or -not $steamLane.Manifest.SteamAppIdHintManaged -or
        $steamLane.Result.SteamAppIdFileSha256 -ne 'AD63AE7E99775887985974467E5FD52CCE63C0AA631494BA753D34CFA99CF5EA' -or
        $steamLane.Manifest.SteamAppIdFileSha256 -ne 'AD63AE7E99775887985974467E5FD52CCE63C0AA631494BA753D34CFA99CF5EA') {
        throw "$($steamLane.Name) does not report its positively identified Steam App ID hint."
    }
    $steamAppIdBytes = [IO.File]::ReadAllBytes($expectedSteamAppIdFile)
    if ($steamAppIdBytes.Length -ne 5 -or [Text.Encoding]::ASCII.GetString($steamAppIdBytes) -ne '21090') {
        throw "$($steamLane.Name) steam_appid.txt must contain only ASCII App ID 21090."
    }
}

# A hint is tool-owned only when the prior manifest records its exact path and
# hash. Unowned or externally changed files must fail before any stage update.
$unownedNonSteamSeed = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $unownedNonSteamStage
[IO.File]::WriteAllText((Join-Path $unownedNonSteamStage 'steam_appid.txt'), 'user-owned', [Text.ASCIIEncoding]::new())
$unownedNonSteamBefore = Get-DirectorySnapshot -Root $unownedNonSteamStage
$unownedNonSteamRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $unownedNonSteamStage | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('unowned or changed steam_appid.txt') -or
        -not $_.Exception.Message.Contains('No stage files were changed')) {
        throw
    }
    $unownedNonSteamRejected = $true
}
if (-not $unownedNonSteamRejected -or (Get-DirectorySnapshot -Root $unownedNonSteamStage) -ne $unownedNonSteamBefore) {
    throw 'Non-Steam staging deleted or otherwise mutated an unowned steam_appid.txt before failing.'
}

$unownedSteamSeed = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $steamFixtureRoot -BuildRoot $buildRoot -StageRoot $unownedSteamStage
[IO.File]::WriteAllText($unownedSteamSeed.SteamAppIdFile, 'changed', [Text.ASCIIEncoding]::new())
$unownedSteamBefore = Get-DirectorySnapshot -Root $unownedSteamStage
$changedSteamHintRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $steamFixtureRoot -BuildRoot $buildRoot -StageRoot $unownedSteamStage | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('unowned or changed steam_appid.txt')) {
        throw
    }
    $changedSteamHintRejected = $true
}
if (-not $changedSteamHintRejected -or (Get-DirectorySnapshot -Root $unownedSteamStage) -ne $unownedSteamBefore) {
    throw 'Steam staging overwrote or otherwise mutated a changed tool-owned hint before failing.'
}

$unownedSdkSeed = & $stageScript -Lane SdkSmoke -Configuration $Configuration -RepositoryRoot $RepositoryRoot -SdkRoot $sdkRoot -BuildRoot $buildRoot -StageRoot $unownedSdkStage
[IO.File]::WriteAllText((Join-Path $unownedSdkStage 'steam_appid.txt'), '21090', [Text.ASCIIEncoding]::new())
$unownedSdkBefore = Get-DirectorySnapshot -Root $unownedSdkStage
$unownedSdkHintRejected = $false
try {
    & $stageScript -Lane SdkSmoke -Configuration $Configuration -RepositoryRoot $RepositoryRoot -SdkRoot $sdkRoot -BuildRoot $buildRoot -StageRoot $unownedSdkStage | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('unowned or changed steam_appid.txt')) {
        throw
    }
    $unownedSdkHintRejected = $true
}
if (-not $unownedSdkHintRejected -or (Get-DirectorySnapshot -Root $unownedSdkStage) -ne $unownedSdkBefore) {
    throw 'SdkSmoke deleted or otherwise mutated an unowned steam_appid.txt before failing.'
}

New-Item -ItemType Directory -Path $ownedStaleHintStage | Out-Null
$ownedStaleHintPath = Join-Path $ownedStaleHintStage 'steam_appid.txt'
[IO.File]::WriteAllText($ownedStaleHintPath, '21090', [Text.ASCIIEncoding]::new())
[ordered]@{
    SchemaVersion         = 5
    Lane                  = 'Rebuilt'
    SteamAppId            = '21090'
    SteamAppIdFile        = $ownedStaleHintPath
    SteamAppIdHintManaged = $true
    SteamAppIdFileSha256  = 'AD63AE7E99775887985974467E5FD52CCE63C0AA631494BA753D34CFA99CF5EA'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ownedStaleHintStage 'fearmore-stage.json') -Encoding UTF8
$ownedStaleHintManifestPath = Join-Path $ownedStaleHintStage 'fearmore-stage.json'
$ownedStaleHintParameters = @{
    Lane           = 'Rebuilt'
    Configuration  = $Configuration
    RepositoryRoot = $RepositoryRoot
    RetailRoot     = $fixtureRoot
    BuildRoot      = $buildRoot
    StageRoot      = $ownedStaleHintStage
}
$ownedStaleHintBeforeFailedMigration = Get-DirectorySnapshot -Root $ownedStaleHintStage
$legacyMinimalMigrationRollbackVerified = $false
$manifestLock = [IO.File]::Open(
    $ownedStaleHintManifestPath,
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read)
try {
    try {
        & $stageScript @ownedStaleHintParameters | Out-Null
    }
    catch {
        $isIoFailure = $_.Exception -is [IO.IOException] -or
            $_.Exception.InnerException -is [IO.IOException]
        if (-not $isIoFailure -or
            $_.ScriptStackTrace -notmatch '(?m)\bat Invoke-TransactionalStageOwnershipCommit,') {
            throw
        }
        $legacyMinimalMigrationRollbackVerified = $true
    }
}
finally {
    $manifestLock.Dispose()
}
if (-not $legacyMinimalMigrationRollbackVerified -or
    (Get-DirectorySnapshot -Root $ownedStaleHintStage) -ne $ownedStaleHintBeforeFailedMigration) {
    throw 'Failed minimal schema-5 Rebuilt migration did not restore the exact manifest, Steam hint, and core-file absence baseline.'
}
$ownedStaleHintResult = & $stageScript @ownedStaleHintParameters
if ((Test-Path -LiteralPath $ownedStaleHintPath) -or $ownedStaleHintResult.SteamAppIdHintManaged -or
    $ownedStaleHintResult.SteamAppIdFileSha256) {
    throw 'Non-Steam staging did not remove the exact previously recorded tool-owned Steam hint.'
}

# The hint and manifest are one ownership transaction. Force manifest replacement
# to fail after the hint operation and prove both create and remove paths restore
# the exact prior stage state without leaving recovery files.
$steamHintCreateSeed = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $steamFixtureRoot -BuildRoot $buildRoot -StageRoot $steamHintCreateRollbackStage
$steamHintCreateManifestPath = Join-Path $steamHintCreateRollbackStage 'fearmore-stage.json'
Remove-Item -LiteralPath $steamHintCreateSeed.SteamAppIdFile -Force
$steamHintCreateBefore = Get-DirectorySnapshot -Root $steamHintCreateRollbackStage
$steamHintCreateRollbackVerified = $false
$manifestLock = [IO.File]::Open($steamHintCreateManifestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    try {
        & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $steamFixtureRoot -BuildRoot $buildRoot -StageRoot $steamHintCreateRollbackStage | Out-Null
    }
    catch {
        $steamHintCreateRollbackVerified = $true
    }
}
finally {
    $manifestLock.Dispose()
}
if (-not $steamHintCreateRollbackVerified -or
    (Get-DirectorySnapshot -Root $steamHintCreateRollbackStage) -ne $steamHintCreateBefore) {
    throw 'Failed Steam-hint creation did not roll back to the exact prior stage state.'
}

$steamHintRemoveSeed = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $steamFixtureRoot -BuildRoot $buildRoot -StageRoot $steamHintRemoveRollbackStage
$steamHintRemoveManifestPath = Join-Path $steamHintRemoveRollbackStage 'fearmore-stage.json'
$steamFixtureManifestPath = Join-Path $steamLibraryFixture 'steamapps\appmanifest_21090.acf'
$steamFixtureManifestBytes = [IO.File]::ReadAllBytes($steamFixtureManifestPath)
Remove-Item -LiteralPath $steamFixtureManifestPath -Force
$steamHintRemoveBefore = Get-DirectorySnapshot -Root $steamHintRemoveRollbackStage
$steamHintRemoveRollbackVerified = $false
$manifestLock = [IO.File]::Open($steamHintRemoveManifestPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    try {
        & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $steamFixtureRoot -BuildRoot $buildRoot -StageRoot $steamHintRemoveRollbackStage | Out-Null
    }
    catch {
        $steamHintRemoveRollbackVerified = $true
    }
}
finally {
    $manifestLock.Dispose()
    [IO.File]::WriteAllBytes($steamFixtureManifestPath, $steamFixtureManifestBytes)
}
if (-not $steamHintRemoveRollbackVerified -or
    (Get-DirectorySnapshot -Root $steamHintRemoveRollbackStage) -ne $steamHintRemoveBefore) {
    throw 'Failed Steam-hint removal did not roll back to the exact prior stage state.'
}
if ((Get-FileHash -LiteralPath $steamHintRemoveSeed.SteamAppIdFile -Algorithm SHA256).Hash -ne
    'AD63AE7E99775887985974467E5FD52CCE63C0AA631494BA753D34CFA99CF5EA') {
    throw 'Steam-hint removal rollback did not restore the exact owned hint.'
}

$ownershipRecoverySeed = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $ownershipRecoveryStage
$ownershipManifestPath = Join-Path $ownershipRecoveryStage 'fearmore-stage.json'
$ownershipRecoveryPath = Join-Path $ownershipRecoveryStage 'fearmore-stage.json.ownership.previous'
[IO.File]::Move($ownershipManifestPath, $ownershipRecoveryPath)
$ownershipRecoveryBefore = Get-DirectorySnapshot -Root $ownershipRecoveryStage
$ownershipRecoveryRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $ownershipRecoveryStage | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('earlier stage-ownership commit left a recovery file') -or
        -not $_.Exception.Message.Contains('No stage files were changed')) {
        throw
    }
    $ownershipRecoveryRejected = $true
}
if (-not $ownershipRecoveryRejected -or
    (Get-DirectorySnapshot -Root $ownershipRecoveryStage) -ne $ownershipRecoveryBefore) {
    throw 'Interrupted stage-ownership recovery state was mutated before staging failed closed.'
}
foreach ($stageState in @(
    $sdkResult, $rebuiltResult, $stockResult, $steamRebuiltResult, $steamStockResult,
    $sdkManifest, $rebuiltManifest, $stockManifest, $steamRebuiltManifest, $steamStockManifest
)) {
    if (-not $stageState.InputsValidated -or -not $stageState.LayoutValidated -or $stageState.AcceptanceTested) {
        throw 'A completed stage must report validated inputs/layout without claiming gameplay acceptance.'
    }
    $legacyLaunchStateName = [string]::Concat('Launch', 'Rea', 'dy')
    if ($stageState.PSObject.Properties[$legacyLaunchStateName]) {
        throw 'Runtime results and manifests must not expose the ambiguous legacy launch-state field.'
    }
}
if (-not $stockDefaultValidation.InputsValidated -or $stockDefaultValidation.LayoutValidated -or
    $stockDefaultValidation.LaunchPermitted -or $stockDefaultValidation.AcceptanceTested) {
    throw 'ValidateOnly must validate inputs without claiming a staged layout, launch permission, or acceptance.'
}
if ($stockDefaultValidation.RuntimeExecutableState -ne 'NotStaged' -or $null -ne $stockDefaultValidation.BootstrapRequired -or
    $stockDefaultValidation.SteamAppId -or $stockDefaultValidation.SteamAppIdFile) {
    throw 'ValidateOnly must not mistake the portable fixture for a Steam installation or claim a staged executable.'
}
if (Test-Path -LiteralPath $validateOnlyStage) {
    throw 'ValidateOnly unexpectedly created or mutated its unique StageRoot.'
}
if ($stockResult.SSAAScale -ne 2.0 -or $stockManifest.SSAAScale -ne 2.0) {
    throw 'Stock stage result and manifest must preserve the requested EchoPatch supersampling scale.'
}
if ($stockDefaultValidation.SSAAScale -ne 1.0) {
    throw 'Stock stage default supersampling scale must remain the performance-preserving 1.0.'
}
if ((Split-Path -Leaf $rebuiltResult.RuntimeExecutable) -ne 'FEAR.exe' -or $rebuiltManifest.RuntimeExecutable -ne 'FEAR.exe') {
    throw 'Rebuilt lane must use the disposable retail FEAR.exe as the documented mod launcher.'
}
if ($rebuiltResult.PublicToolsRoot -or $rebuiltManifest.PublicToolsRoot) {
    throw 'Rebuilt lane must not retain a Public Tools runtime dependency.'
}
if ((Split-Path -Leaf $sdkResult.RuntimeExecutable) -ne 'FEARDevSP.exe' -or $sdkManifest.RuntimeExecutable -ne 'FEARDevSP.exe') {
    throw 'SdkSmoke must retain the Public Tools FEARDevSP.exe diagnostic runtime.'
}
if (-not $sdkResult.PublicToolsRoot -or -not $sdkManifest.PublicToolsRoot) {
    throw 'SdkSmoke must retain its explicit Public Tools dependency.'
}

foreach ($isolatedLane in @(
    [pscustomobject]@{ Name = 'Rebuilt'; Result = $rebuiltResult; Manifest = $rebuiltManifest },
    [pscustomobject]@{ Name = 'StockEchoPatch'; Result = $stockResult; Manifest = $stockManifest }
)) {
    $expectedUserDirectory = [IO.Path]::GetFullPath((Join-Path $isolatedLane.Result.StageRoot 'UserDirectory'))
    if ($isolatedLane.Result.UserDirectory -ne $expectedUserDirectory -or $isolatedLane.Manifest.UserDirectory -ne $expectedUserDirectory) {
        throw "$($isolatedLane.Name) does not preserve its exact stage-local UserDirectory in result and manifest."
    }
    if (-not $isolatedLane.Result.SaveIsolation -or -not $isolatedLane.Manifest.SaveIsolation) {
        throw "$($isolatedLane.Name) is not marked as save-isolated."
    }
    if (-not (Test-Path -LiteralPath $expectedUserDirectory -PathType Container)) {
        throw "$($isolatedLane.Name) stage-local UserDirectory was not created: $expectedUserDirectory"
    }
    $userDirectoryItem = Get-Item -LiteralPath $expectedUserDirectory -Force
    if (($userDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$($isolatedLane.Name) UserDirectory must not redirect through a junction or symbolic link."
    }

    $expectedArguments = @('-userdirectory', $expectedUserDirectory, '-archcfg', 'Default.archcfg')
    if ((@($isolatedLane.Result.LaunchArguments) -join "`n") -ne ($expectedArguments -join "`n") -or
        (@($isolatedLane.Manifest.LaunchArguments) -join "`n") -ne ($expectedArguments -join "`n")) {
        throw "$($isolatedLane.Name) launch arguments do not put the engine-level -userdirectory switch first."
    }
    $expectedArgumentString = "-userdirectory `"$expectedUserDirectory`" -archcfg Default.archcfg"
    if ($isolatedLane.Result.LaunchArgumentString -ne $expectedArgumentString -or $isolatedLane.Manifest.LaunchArgumentString -ne $expectedArgumentString) {
        throw "$($isolatedLane.Name) launch argument quoting does not preserve a UserDirectory path containing spaces."
    }
    if ($isolatedLane.Manifest.SchemaVersion -ne 9) {
        throw "$($isolatedLane.Name) manifest schema does not identify executable provenance, Steam launch state, and optional content mounts."
    }
}
if ($rebuiltResult.UserDirectory -eq $stockResult.UserDirectory) {
    throw 'Rebuilt and StockEchoPatch must never share a UserDirectory.'
}
if ($sdkResult.UserDirectory -or $sdkResult.SaveIsolation -or @($sdkResult.LaunchArguments).Count -ne 0 -or $sdkResult.LaunchArgumentString -ne '' -or
    $sdkManifest.UserDirectory -or $sdkManifest.SaveIsolation -or @($sdkManifest.LaunchArguments).Count -ne 0 -or $sdkManifest.LaunchArgumentString -ne '') {
    throw 'Non-launching SdkSmoke must not claim a profile/save root or launch arguments.'
}
if ($sdkManifest.SchemaVersion -ne 9) {
    throw 'SdkSmoke manifest schema must explicitly carry the non-launching validation state.'
}
if (-not (Test-Path -LiteralPath $saveSentinel -PathType Leaf) -or (Get-FileHash -LiteralPath $saveSentinel -Algorithm SHA256).Hash -ne $saveSentinelHash) {
    throw 'Updating an owned Rebuilt stage changed an existing stage-local save file.'
}
foreach ($defaultModeManifest in @($sdkManifest, $rebuiltManifest, $stockManifest, $steamRebuiltManifest, $steamStockManifest)) {
    if ($defaultModeManifest.RendererMode -ne 'NativeD3D9' -or $defaultModeManifest.EnginePatchMode -ne 'None') {
        throw 'Existing default lanes no longer preserve NativeD3D9 / no-engine-patch behavior.'
    }
}

foreach ($stageRoot in @($sdkSmokeStage, $rebuiltStage)) {
    foreach ($forbiddenProxyFile in @('dinput8.dll', 'EchoPatch.ini', 'd3d9.dll', 'dgVoodoo.conf', 'd3d8to9.dll', 'NvRemixLauncher32.exe', '.trex', 'rtx-remix', 'rtx.conf')) {
        if (Test-Path -LiteralPath (Join-Path $stageRoot $forbiddenProxyFile)) {
            throw "Default rebuilt stage incorrectly contains ${forbiddenProxyFile}: $stageRoot"
        }
    }
    foreach ($moduleName in @('GameClient.dll', 'GameServer.dll', 'ClientFx.fxd')) {
        $sourceHash = (Get-FileHash -LiteralPath (Join-Path $buildRoot $moduleName) -Algorithm SHA256).Hash
        $stagedHash = (Get-FileHash -LiteralPath (Join-Path (Join-Path $stageRoot 'Game') $moduleName) -Algorithm SHA256).Hash
        if ($sourceHash -ne $stagedHash) {
            throw "Staged rebuilt module hash mismatch: $moduleName"
        }
    }
}
foreach ($nativeStockStage in @($stockStage, $steamStockStage)) {
    foreach ($rendererFile in @('d3d9.dll', 'dgVoodoo.conf', 'd3d8to9.dll', 'NvRemixLauncher32.exe', '.trex', 'rtx-remix', 'rtx.conf')) {
        if (Test-Path -LiteralPath (Join-Path $nativeStockStage $rendererFile)) {
            throw "Native stock stage incorrectly contains renderer override ${rendererFile}: $nativeStockStage"
        }
    }
}
foreach ($bootstrapName in @('EngineServer.dll', 'GameDatabase.dll', 'LTMemory.dll', 'SndDrv.dll', 'StringEditRuntime.dll')) {
    if (-not (Test-Path -LiteralPath (Join-Path $rebuiltStage $bootstrapName) -PathType Leaf)) {
        throw "Rebuilt retail stage is missing dynamically loaded retail bootstrap file: $bootstrapName"
    }
}
foreach ($sdkOnlyArtifact in @('FEARDevSP.exe', 'AssertWin32DLL.dll', 'FEAR.proj00', 'SdkGame')) {
    if (Test-Path -LiteralPath (Join-Path $rebuiltStage $sdkOnlyArtifact)) {
        throw "Rebuilt retail stage unexpectedly contains an SDK-only runtime artifact: $sdkOnlyArtifact"
    }
}
foreach ($vc71File in @('msvcp71.dll', 'msvcr71.dll')) {
    if (Test-Path -LiteralPath (Join-Path $rebuiltStage $vc71File)) {
        throw "Rebuilt stage copied a VC71 file that is absent from the synthetic retail source: $vc71File"
    }
}
$fixtureFearHash = (Get-FileHash -LiteralPath (Join-Path $fixtureRoot 'FEAR.exe') -Algorithm SHA256).Hash
$rebuiltFearHash = (Get-FileHash -LiteralPath (Join-Path $rebuiltStage 'FEAR.exe') -Algorithm SHA256).Hash
if ($fixtureFearHash -ne $rebuiltFearHash) {
    throw 'Rebuilt lane did not preserve the disposable copy of the retail launcher.'
}

foreach ($echoPatchFile in @('dinput8.dll', 'EchoPatch.ini')) {
    if (-not (Test-Path -LiteralPath (Join-Path $stockStage $echoPatchFile) -PathType Leaf)) {
        throw "Stock stage is missing EchoPatch file: $echoPatchFile"
    }
}
if (Test-Path -LiteralPath (Join-Path $stockStage 'Game\GameClient.dll') -PathType Leaf) {
    throw 'Stock EchoPatch stage unexpectedly contains rebuilt game modules.'
}
$stagedEchoPatchIni = Get-Content -LiteralPath (Join-Path $stockStage 'EchoPatch.ini') -Raw
$requiredModernDisplaySettings = [ordered]@{
    FixNvidiaShadowCorruption = '1'
    FixAspectRatioBlur        = '1'
    HighResolutionReflections = '1'
    SSAAScale                 = '2.0'
    HUDScaling                = '1'
    AutoResolution            = '1'
    DisableLetterbox          = '0'
}
foreach ($setting in $requiredModernDisplaySettings.GetEnumerator()) {
    $settingPattern = '(?m)^{0}[ \t]*=[ \t]*{1}[ \t]*$' -f
        [regex]::Escape($setting.Key), [regex]::Escape($setting.Value)
    if ($stagedEchoPatchIni -notmatch $settingPattern) {
        throw "Stock stage does not preserve the modern-display baseline $($setting.Key) = $($setting.Value)."
    }
}

# EchoPatch's unwrapped-executable path changes exactly the LAA flag and PE
# checksum. Recreate that deterministic result, then prove a normal restage
# preserves it and only the explicit refresh option restores the retail copy.
$stockLaaSeed = & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $stockLaaStage -EchoPatchArchive $echoPatchArchive
$stockLaaExecutable = $stockLaaSeed.RuntimeExecutable
$stockLaaBackup = "$stockLaaExecutable.bak"
Copy-Item -LiteralPath $stockLaaExecutable -Destination $stockLaaBackup -Force
Set-TestLaaHeaderOnly -Path $stockLaaExecutable
$stockLaaHashBefore = (Get-FileHash -LiteralPath $stockLaaExecutable -Algorithm SHA256).Hash
$stockLaaBackupHashBefore = (Get-FileHash -LiteralPath $stockLaaBackup -Algorithm SHA256).Hash
$stockLaaPreserved = & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $stockLaaStage -EchoPatchArchive $echoPatchArchive
$stockLaaManifest = Get-Content -LiteralPath (Join-Path $stockLaaStage 'fearmore-stage.json') -Raw | ConvertFrom-Json
if ($stockLaaPreserved.RuntimeExecutableState -ne 'EchoPatchedLAA' -or $stockLaaManifest.RuntimeExecutableState -ne 'EchoPatchedLAA' -or
    $stockLaaPreserved.BootstrapRequired -or $stockLaaManifest.BootstrapRequired -or
    -not $stockLaaPreserved.LaunchPermitted -or -not $stockLaaManifest.LaunchPermitted -or
    $stockLaaPreserved.RuntimeExecutableSha256 -ne $stockLaaHashBefore -or $stockLaaManifest.RuntimeExecutableSha256 -ne $stockLaaHashBefore -or
    $stockLaaPreserved.RuntimeExecutableBackupSha256 -ne $stockLaaBackupHashBefore -or $stockLaaManifest.RuntimeExecutableBackupSha256 -ne $stockLaaBackupHashBefore) {
    throw 'Stock restage did not preserve and report the attested EchoPatch LAA executable pair.'
}
if ((Get-FileHash -LiteralPath $stockLaaExecutable -Algorithm SHA256).Hash -ne $stockLaaHashBefore -or
    (Get-FileHash -LiteralPath $stockLaaBackup -Algorithm SHA256).Hash -ne $stockLaaBackupHashBefore) {
    throw 'Stock restage silently changed the attested EchoPatch LAA executable pair.'
}

$stockLaaRefreshed = & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $stockLaaStage -EchoPatchArchive $echoPatchArchive -RefreshRuntimeExecutable
if ($stockLaaRefreshed.RuntimeExecutableState -ne 'RetailOriginal' -or -not $stockLaaRefreshed.BootstrapRequired -or
    $stockLaaRefreshed.LaunchPermitted -or
    (Get-FileHash -LiteralPath $stockLaaExecutable -Algorithm SHA256).Hash -ne $fixtureFearHash -or
    (Test-Path -LiteralPath $stockLaaBackup)) {
    throw 'Explicit stock runtime refresh did not restore the retail executable and remove its attested backup.'
}

$unknownStockSeed = & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $unknownStockStage -EchoPatchArchive $echoPatchArchive
$unknownBytes = [IO.File]::ReadAllBytes($unknownStockSeed.RuntimeExecutable)
$unknownBytes[100] = $unknownBytes[100] -bxor 0x01
[IO.File]::WriteAllBytes($unknownStockSeed.RuntimeExecutable, $unknownBytes)
$unknownBackup = "$($unknownStockSeed.RuntimeExecutable).bak"
[IO.File]::WriteAllBytes($unknownBackup, [byte[]](0x55, 0x4E, 0x4B, 0x4E, 0x4F, 0x57, 0x4E))
$unknownStageBefore = Get-DirectorySnapshot -Root $unknownStockStage
$unknownDerivativeRejected = $false
try {
    & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $unknownStockStage -EchoPatchArchive $echoPatchArchive | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('unknown FEAR.exe derivative')) {
        throw
    }
    $unknownDerivativeRejected = $true
}
if (-not $unknownDerivativeRejected) {
    throw 'Stock stage accepted an unknown FEAR.exe derivative without explicit refresh.'
}
if ((Get-DirectorySnapshot -Root $unknownStockStage) -ne $unknownStageBefore) {
    throw 'Unknown executable rejection mutated the stage before failing closed.'
}
$unknownStockRefreshed = & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $unknownStockStage -EchoPatchArchive $echoPatchArchive -RefreshRuntimeExecutable
if ($unknownStockRefreshed.RuntimeExecutableState -ne 'RetailOriginal' -or
    (Get-FileHash -LiteralPath $unknownStockRefreshed.RuntimeExecutable -Algorithm SHA256).Hash -ne $fixtureFearHash -or
    (Test-Path -LiteralPath $unknownBackup)) {
    throw 'Explicit runtime refresh did not recover the unknown ordinary executable pair.'
}
$runtimeRefreshRecoveryNames = @('FEAR.exe.refresh.new', 'FEAR.exe.refresh.previous', 'FEAR.exe.bak.refresh.previous')
foreach ($recoveryName in $runtimeRefreshRecoveryNames) {
    if (Test-Path -LiteralPath (Join-Path $unknownStockStage $recoveryName)) {
        throw "Successful runtime refresh left a transaction recovery path behind: $recoveryName"
    }
}
$unknownDerivativeRefreshed = $true

# A prior interrupted transaction must fail closed before the new run updates
# any other stage file. Recovery is deliberately manual so no ambiguous old
# executable is overwritten or deleted.
$interruptedRefreshSeed = & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $interruptedRefreshStage -EchoPatchArchive $echoPatchArchive
$interruptedRecoveryPath = Join-Path $interruptedRefreshStage 'FEAR.exe.refresh.previous'
Copy-Item -LiteralPath $interruptedRefreshSeed.RuntimeExecutable -Destination $interruptedRecoveryPath
$interruptedRefreshBefore = Get-DirectorySnapshot -Root $interruptedRefreshStage
$interruptedRefreshRejected = $false
try {
    & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $interruptedRefreshStage -EchoPatchArchive $echoPatchArchive -RefreshRuntimeExecutable | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('earlier runtime refresh left a recovery file') -or
        -not $_.Exception.Message.Contains('No stage files were changed')) {
        throw
    }
    $interruptedRefreshRejected = $true
}
if (-not $interruptedRefreshRejected -or
    (Get-DirectorySnapshot -Root $interruptedRefreshStage) -ne $interruptedRefreshBefore) {
    throw 'Interrupted runtime-refresh recovery state was mutated before staging failed closed.'
}

# Exercise the transaction catch path after it has already moved the old
# backup. A missing primary executable forces the next move to fail; rollback
# must restore the exact pre-run state and remove every temporary path.
$rollbackRefreshSeed = & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $rollbackRefreshStage -EchoPatchArchive $echoPatchArchive
$rollbackRefreshExecutable = $rollbackRefreshSeed.RuntimeExecutable
$rollbackRefreshBackup = "$rollbackRefreshExecutable.bak"
Copy-Item -LiteralPath $rollbackRefreshExecutable -Destination $rollbackRefreshBackup
Remove-Item -LiteralPath $rollbackRefreshExecutable -Force
$rollbackRefreshBefore = Get-DirectorySnapshot -Root $rollbackRefreshStage
$runtimeRefreshRollbackVerified = $false
try {
    & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $rollbackRefreshStage -EchoPatchArchive $echoPatchArchive -RefreshRuntimeExecutable | Out-Null
}
catch {
    $runtimeRefreshRollbackVerified = $true
}
if (-not $runtimeRefreshRollbackVerified -or
    (Get-DirectorySnapshot -Root $rollbackRefreshStage) -ne $rollbackRefreshBefore) {
    throw 'Failed runtime refresh did not roll back to the exact pre-transaction executable state.'
}

$rebuiltRejectedSsaa = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -SdkRoot $missingSdkRoot -BuildRoot $buildRoot -SSAAScale 2.0 -ValidateOnly | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('-SSAAScale is supported only by -Lane StockEchoPatch')) {
        throw
    }
    $rebuiltRejectedSsaa = $true
}
if (-not $rebuiltRejectedSsaa) {
    throw 'Rebuilt lane accepted the stock-only SSAAScale option.'
}

$rebuiltRejectedRuntimeRefresh = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -RefreshRuntimeExecutable | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('-RefreshRuntimeExecutable is supported only by -Lane StockEchoPatch')) {
        throw
    }
    $rebuiltRejectedRuntimeRefresh = $true
}
if (-not $rebuiltRejectedRuntimeRefresh) {
    throw 'Rebuilt lane accepted the stock-only runtime refresh option.'
}

foreach ($overrideCase in @(
        [pscustomobject]@{ Token = '+UserDirectory'; Arguments = @('+UserDirectory', 'C:\outside') },
        [pscustomobject]@{ Token = '-userdirectory'; Arguments = @('-userdirectory', 'C:\outside') },
        [pscustomobject]@{ Token = '+UserDirectory=C:\outside'; Arguments = @('+UserDirectory=C:\outside') },
        [pscustomobject]@{ Token = '-userdirectory=C:\outside'; Arguments = @('-userdirectory=C:\outside') },
        [pscustomobject]@{ Token = 'UserDirectory=C:\outside'; Arguments = @('UserDirectory=C:\outside') }
    )) {
    $userDirectoryOverrideRejected = $false
    try {
        & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $stockStage -EchoPatchArchive $echoPatchArchive -LaunchArguments $overrideCase.Arguments -ValidateOnly | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('LaunchArguments must not override the lane-isolated -userdirectory path')) {
            throw
        }
        $userDirectoryOverrideRejected = $true
    }
    if (-not $userDirectoryOverrideRejected) {
        throw "Stock lane accepted a UserDirectory override token: $($overrideCase.Token)"
    }
}

foreach ($overrideToken in @('+FearMoreHDTexturesActive', '+FearMoreHDTexturesActive=0')) {
    $hdTextureActivityOverrideRejected = $false
    try {
        & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -StageRoot $stockStage -EchoPatchArchive $echoPatchArchive -LaunchArguments $overrideToken -ValidateOnly | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('LaunchArguments must not override the launcher-owned FearMoreHDTexturesActive state')) {
            throw
        }
        $hdTextureActivityOverrideRejected = $true
    }
    if (-not $hdTextureActivityOverrideRejected) {
        throw "Stock lane accepted a FearMoreHDTexturesActive override token: $overrideToken"
    }
}

$nearCollisionArguments = @('+UserDirectoryBackup=C:\not-owned', '+FearMoreHDTexturesActiveBackup=0')
$nearCollisionResult = & $stageScript `
    -Lane StockEchoPatch `
    -RepositoryRoot $RepositoryRoot `
    -RetailRoot $fixtureRoot `
    -StageRoot $stockStage `
    -EchoPatchArchive $echoPatchArchive `
    -LaunchArguments $nearCollisionArguments `
    -ValidateOnly
if (@($nearCollisionResult.LaunchArguments)[-2] -cne $nearCollisionArguments[0] -or
    @($nearCollisionResult.LaunchArguments)[-1] -cne $nearCollisionArguments[1]) {
    throw 'Exact reserved-argument matching rejected or rewrote a non-owned prefix collision.'
}

$sdkConfigEntries = @(Get-Content -LiteralPath (Join-Path $sdkSmokeStage 'Default.archcfg') | Where-Object { $_ -and -not $_.StartsWith(';') })
if ($sdkConfigEntries.Count -ne 1 -or $sdkConfigEntries[0] -ne 'Game') {
    throw "SDK smoke archive order is incorrect: $($sdkConfigEntries -join ', ')"
}
if (Test-Path -LiteralPath (Join-Path $sdkSmokeStage 'SdkGame')) {
    throw 'SdkSmoke must not retain the former SDK content junction.'
}
$rebuiltConfigEntries = @(Get-Content -LiteralPath (Join-Path $rebuiltStage 'Default.archcfg') | Where-Object { $_ -and -not $_.StartsWith(';') })
if ($rebuiltConfigEntries[-1] -ne 'Game') {
    throw 'Rebuilt module overlay must be the final archive-config entry.'
}
$stockConfigEntries = @(Get-Content -LiteralPath (Join-Path $stockStage 'Default.archcfg') | Where-Object { $_ -and -not $_.StartsWith(';') })
if ($stockConfigEntries -contains 'Game') {
    throw 'Stock EchoPatch stage must not mount the rebuilt Game overlay.'
}

# An attacker-controlled Game junction must be rejected before removal, copy,
# or manifest rewrite can touch either the stage or the junction target.
$gameJunctionStage = Join-Path $RepositoryRoot "local-runtime\runtime-tool-adversarial-game-$runId"
$gameJunctionSentinel = Join-Path $RepositoryRoot "local-runtime\runtime-tool-adversarial-game-target-$runId"
New-Item -ItemType Directory -Path $gameJunctionStage | Out-Null
New-Item -ItemType Directory -Path $gameJunctionSentinel | Out-Null
[IO.File]::WriteAllBytes((Join-Path $gameJunctionSentinel 'sentinel.bin'), [byte[]](0x53, 0x41, 0x46, 0x45))
@{ Lane = 'Rebuilt' } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $gameJunctionStage 'fearmore-stage.json') -Encoding UTF8
$gameJunctionPath = Join-Path $gameJunctionStage 'Game'
New-Item -ItemType Junction -Path $gameJunctionPath -Target $gameJunctionSentinel | Out-Null
$gameTargetBefore = Get-DirectorySnapshot -Root $gameJunctionSentinel
$gameStageBefore = Get-ShallowDirectorySnapshot -Root $gameJunctionStage
$gameJunctionRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $gameJunctionStage | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('Unsafe reparse point') -or -not $_.Exception.Message.Contains($gameJunctionPath)) {
        throw "Game-junction guard failed without precise evidence: $($_.Exception.Message)"
    }
    $gameJunctionRejected = $true
}
if (-not $gameJunctionRejected) {
    throw 'Stage creation accepted an attacker-controlled Game junction.'
}
if ((Get-DirectorySnapshot -Root $gameJunctionSentinel) -ne $gameTargetBefore) {
    throw 'Game-junction rejection mutated the external sentinel target.'
}
if ((Get-ShallowDirectorySnapshot -Root $gameJunctionStage) -ne $gameStageBefore) {
    throw 'Game-junction rejection mutated the owned stage before failing closed.'
}

# A StageRoot junction is itself an unsafe path component and must fail before
# the target receives even a manifest or runtime file.
$stageRootJunction = Join-Path $RepositoryRoot "local-runtime\runtime-tool-adversarial-root-$runId"
$stageRootTarget = Join-Path $RepositoryRoot "local-runtime\runtime-tool-adversarial-root-target-$runId"
New-Item -ItemType Directory -Path $stageRootTarget | Out-Null
[IO.File]::WriteAllBytes((Join-Path $stageRootTarget 'sentinel.bin'), [byte[]](0x52, 0x4F, 0x4F, 0x54))
New-Item -ItemType Junction -Path $stageRootJunction -Target $stageRootTarget | Out-Null
$rootTargetBefore = Get-DirectorySnapshot -Root $stageRootTarget
$stageRootJunctionRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $stageRootJunction | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('Unsafe reparse point') -or -not $_.Exception.Message.Contains($stageRootJunction)) {
        throw "StageRoot-junction guard failed without precise evidence: $($_.Exception.Message)"
    }
    $stageRootJunctionRejected = $true
}
if (-not $stageRootJunctionRejected) {
    throw 'Stage creation accepted a StageRoot junction.'
}
if ((Get-DirectorySnapshot -Root $stageRootTarget) -ne $rootTargetBefore) {
    throw 'StageRoot-junction rejection mutated the external sentinel target.'
}

foreach ($inputPath in $protectedInputs) {
    $afterHash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
    if ($afterHash -ne $beforeHashes[$inputPath]) {
        throw "Protected staging input changed during the test: $inputPath"
    }
}

foreach ($stageRoot in @($sdkSmokeStage, $rebuiltStage, $stockStage, $fixtureRoot)) {
    & git -C $RepositoryRoot check-ignore -q $stageRoot
    if ($LASTEXITCODE -ne 0) {
        throw "Local runtime path is not ignored by Git: $stageRoot"
    }
}

# Guard against accepting an x64 DLL from System32 merely because its filename
# matches an x86 dependency. The staging script must inspect the PE machine.
$architectureFixture = Join-Path $RepositoryRoot "local-runtime\runtime-tool-fixture-windir-$PID"
$fakeSystem32 = Join-Path $architectureFixture 'System32'
New-Item -ItemType Directory -Path $fakeSystem32 -Force | Out-Null
$nativeSystemDirectory = if ([Environment]::Is64BitProcess) {
    Join-Path $env:SystemRoot 'System32'
}
else {
    Join-Path $env:SystemRoot 'Sysnative'
}
Copy-Item -LiteralPath (Join-Path $nativeSystemDirectory 'kernel32.dll') -Destination (Join-Path $fakeSystem32 'd3dx9_27.dll') -Force
$wrongArchFixture = Join-Path $fakeSystem32 'd3dx9_27.dll'
$wrongArchIdentity = Get-FearPeRuntimeIdentity -Path $wrongArchFixture
if (Test-FearX86Pe32Identity -Identity $wrongArchIdentity) {
    throw 'The x64 PE fixture was misidentified as an x86 PE32 executable.'
}
$wrongArchRuntimeRejected = $false
try {
    Get-FearStockRuntimeExecutableAssessment -RetailExecutable $wrongArchFixture -StageRoot (Join-Path $architectureFixture 'stock-stage') | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('not a 32-bit x86 PE image')) {
        throw
    }
    $wrongArchRuntimeRejected = $true
}
if (-not $wrongArchRuntimeRejected) {
    throw 'Stock executable assessment accepted an x64 retail fixture.'
}

$originalWindir = $env:WINDIR
try {
    $env:WINDIR = $architectureFixture
    $architectureGuardTriggered = $false
    try {
        & $stageScript -Lane SdkSmoke -Configuration $Configuration -RepositoryRoot $RepositoryRoot -SdkRoot $sdkRoot -BuildRoot $buildRoot -ValidateOnly | Out-Null
    }
    catch {
        $message = $_.Exception.Message
        $expectedSysWow64Path = Join-Path $architectureFixture 'SysWOW64\d3dx9_27.dll'
        $expectedSystem32Path = Join-Path $architectureFixture 'System32\d3dx9_27.dll'
        if (-not $message.Contains($expectedSysWow64Path) -or -not $message.Contains($expectedSystem32Path) -or -not $message.Contains('machine 0x8664')) {
            throw "x86 dependency guard failed without the expected searched-path and PE-machine evidence: $message"
        }
        $architectureGuardTriggered = $true
    }
    if (-not $architectureGuardTriggered) {
        throw 'x86 dependency guard accepted an x64-only System32 fixture.'
    }
}
finally {
    $env:WINDIR = $originalWindir
}

$pinnedSteamBindPairVerified = $false
$pinnedSteamBindPairSkipped = $true
if ($SteamRetailRoot -and $SteamEchoPatchedStageRoot) {
    $steamRetailExecutable = Join-Path $SteamRetailRoot 'FEAR.exe'
    $steamRetailIdentity = Get-FearPeRuntimeIdentity -Path $steamRetailExecutable
    $steamPairAssessment = Get-FearStockRuntimeExecutableAssessment `
        -RetailExecutable $steamRetailExecutable `
        -StageRoot $SteamEchoPatchedStageRoot
    if (-not $steamRetailIdentity.HasBindSection -or $steamPairAssessment.State -ne 'EchoPatchedLAA' -or
        $steamPairAssessment.BootstrapRequired) {
        throw 'The opt-in/local Steam coverage did not exercise the pinned .bind -> EchoPatchedLAA attestation branch.'
    }
    $pinnedSteamBindPairVerified = $true
    $pinnedSteamBindPairSkipped = $false
}
elseif ($SteamRetailRoot -or $SteamEchoPatchedStageRoot) {
    throw 'Pinned Steam .bind coverage requires both -SteamRetailRoot and -SteamEchoPatchedStageRoot.'
}

[pscustomobject]@{
    Status                 = 'PASS'
    TestedLanes            = @('SdkSmoke', 'Rebuilt', 'StockEchoPatch')
    Configuration          = $Configuration
    ProtectedInputsUnchanged = $true
    WhatIfNewStageNonMutating = $true
    WhatIfExistingStageNonMutating = $true
    GameJunctionRejected   = $gameJunctionRejected
    StageRootJunctionRejected = $stageRootJunctionRejected
    MissingRetailJunctionRejected = $missingRetailRejected
    ModernDisplayBaselinePreserved = $true
    EarlyUserDirectorySwitchVerified = $true
    ReservedLaunchArgumentsVerified = $true
    LaunchArgumentPrefixCollisionsAllowed = $true
    SteamAppIdHintVerified = $true
    NonSteamAppIdHintExcluded = $true
    StockBootstrapLaunchRejected = $stockBootstrapLaunchRejected
    SteamHintCreateRollbackVerified = $steamHintCreateRollbackVerified
    SteamHintRemoveRollbackVerified = $steamHintRemoveRollbackVerified
    OwnershipRecoveryRejected = $ownershipRecoveryRejected
    EchoPatchedLaaPreserved = $true
    UnknownRuntimeDerivativeRejected = $unknownDerivativeRejected
    UnknownDerivativeStageUnchanged = $true
    UnknownRuntimeDerivativeRefreshed = $unknownDerivativeRefreshed
    RuntimeRefreshRecoveryRejected = $interruptedRefreshRejected
    RuntimeRefreshRecoveryStageUnchanged = $true
    RuntimeRefreshRollbackVerified = $runtimeRefreshRollbackVerified
    UnownedSteamHintRejected = $unownedNonSteamRejected
    ChangedSteamHintRejected = $changedSteamHintRejected
    SdkUnownedSteamHintRejected = $unownedSdkHintRejected
    OwnedStaleSteamHintRemoved = $true
    LegacyMinimalMigrationRollbackVerified = $legacyMinimalMigrationRollbackVerified
    WrongArchRuntimeRejected = $wrongArchRuntimeRejected
    PinnedSteamBindPairVerified = $pinnedSteamBindPairVerified
    PinnedSteamBindPairSkipped = $pinnedSteamBindPairSkipped
    RuntimeLaunched        = $false
    Note                   = 'Synthetic retail fixture verifies staging mechanics only; user-owned retail runtime acceptance remains required.'
}
