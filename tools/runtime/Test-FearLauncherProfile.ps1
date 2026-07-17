[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-ExactBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Expected,
        [Parameter(Mandatory = $true)][byte[]]$Actual,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($Expected.Length -ne $Actual.Length) {
        throw "$Description length changed from $($Expected.Length) to $($Actual.Length)."
    }
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        if ($Expected[$index] -ne $Actual[$index]) {
            throw "$Description byte $index changed."
        }
    }
}

function New-TestUserDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $stageRoot = Join-Path $Root $Name
    $userDirectory = Join-Path $stageRoot 'UserDirectory'
    [IO.Directory]::CreateDirectory($userDirectory) | Out-Null
    return [pscustomobject]@{
        StageRoot     = $stageRoot
        UserDirectory = $userDirectory
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$modulePath = Join-Path $PSScriptRoot 'FearLauncherProfile.psm1'
$launcherPath = Join-Path $PSScriptRoot 'Start-FearMore.ps1'
$screenMainPath = Join-Path $repositoryRoot 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenMain.cpp'
$gameClientShellPath = Join-Path $repositoryRoot 'FEAR\Dev\Source\FEAR\ClientShellDLL\GameClientShell.cpp'
foreach ($requiredPath in @($modulePath, $launcherPath, $screenMainPath, $gameClientShellPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Launcher profile test input is missing: $requiredPath"
    }
}

Import-Module $modulePath -Force -ErrorAction Stop
$exportedFunctions = @(
    Get-Command -Module FearLauncherProfile -CommandType Function |
        Select-Object -ExpandProperty Name |
        Sort-Object
)
$expectedFunctions = @(
    'Get-FearMoreInitialDisplaySeed',
    'Initialize-FearMoreSettings'
) | Sort-Object
if (@(Compare-Object $expectedFunctions $exportedFunctions).Count -ne 0) {
    throw "FearLauncherProfile exports changed. Found: $($exportedFunctions -join ', ')"
}

$launcherSource = (Get-Content -LiteralPath $launcherPath -Raw) -replace "`r`n", "`n"
foreach ($mapping in @(
        "[string]`$Preset = 'Modern'",
        "'Stable' {`n        `$stageParameters.RendererMode = 'NativeD3D9'`n        `$stageParameters.EnginePatchMode = 'None'",
        "'Modern' {`n        `$stageParameters.RendererMode = 'DgVoodooD3D11'`n        `$stageParameters.EnginePatchMode = 'EngineOnlyEchoPatch'",
        "'Stable' { 'fearmore-launcher-stable' }",
        "'Modern' { 'fearmore-launcher-modern' }",
        "'CameraLab' { 'fearmore-launcher-native-camera-lab-armed' }"
    )) {
    if (-not $launcherSource.Contains($mapping)) {
        throw "Launcher preset mapping changed or is missing: $mapping"
    }
}
if ($launcherSource.Contains("'CameraLab' { 'fearmore-launcher-native-camera-lab' }")) {
    throw 'The launcher still targets the stale CameraLab stage lifecycle.'
}
if (-not $launcherSource.Contains('(Test-Path -LiteralPath $gameIniPathBeforeStaging -PathType Leaf)')) {
    throw 'The launcher can launch before the Game.ini seed transaction completes.'
}
foreach ($corpsePersistenceContract in @(
        '$settingsExistedBeforeStaging = Test-Path -LiteralPath $settingsPathBeforeStaging -PathType Leaf',
        'Get-FearMoreCorpsePersistenceEnabledFromSettings',
        "-DefaultEnabled:(`$Preset -eq 'Modern' -and -not `$settingsExistedBeforeStaging)",
        '-CorpsePersistenceEnabled $corpsePersistenceEnabled'
    )) {
    if (-not $launcherSource.Contains($corpsePersistenceContract)) {
        throw "Launcher corpse-persistence new-profile ownership changed or is missing: $corpsePersistenceContract"
    }
}
if (-not $launcherSource.Contains("-ControllerEnabled:(`$Preset -eq 'Modern')")) {
    throw 'Launcher controller seeding is no longer restricted to a fresh Modern profile.'
}

$screenMainSource = Get-Content -LiteralPath $screenMainPath -Raw
$gameClientShellSource = Get-Content -LiteralPath $gameClientShellPath -Raw
if (-not $screenMainSource.Contains('if( nGameRuns != 1 )')) {
    throw 'The source-owned first-run auto-detect condition changed; review the launcher seed contract.'
}
if (-not $gameClientShellSource.Contains('nGameRuns++;')) {
    throw 'The source-owned startup GameRuns increment changed; review the launcher seed contract.'
}

$localRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $repositoryRoot 'local-runtime')).TrimEnd('\')
$fixtureRoot = Join-Path $localRuntimeRoot "launcher-profile-test-$([Guid]::NewGuid().ToString('N'))"
$profileAncestorJunction = $null
try {
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null

    $fresh = New-TestUserDirectory -Root $fixtureRoot -Name 'fresh-explicit-ultrawide'
    $explicitSeed = Get-FearMoreInitialDisplaySeed `
        -UseExplicitResolution $true `
        -RequestedWidth 3440 `
        -RequestedHeight 1440
    $freshResult = Initialize-FearMoreSettings `
        -UserDirectory $fresh.UserDirectory `
        -StageRoot $fresh.StageRoot `
        -DisplaySeed $explicitSeed `
        -EnhancedGoreEnabled $true `
        -CorpsePersistenceEnabled $true `
        -ControllerEnabled $true
    if (-not $freshResult.Seeded -or -not $freshResult.GameRunsSeeded) {
        throw 'A fresh explicit ultrawide profile did not seed both settings.cfg and Game.ini.'
    }
    $freshSettings = [IO.File]::ReadAllText($freshResult.Path)
    if (-not $freshSettings.Contains('"ScreenWidth" "3440"') -or
        -not $freshSettings.Contains('"ScreenHeight" "1440"')) {
        throw 'The fresh profile did not retain the explicit 3440x1440 seed.'
    }
    foreach ($expectedModernDefault in @(
            '"EnhancedGore" "1.000000"',
            '"FearMoreCorpsePersistence" "1.000000"',
            '"FearMoreRendererQuality" "0.000000"',
            '"FearMoreEffectsTargetQuality" "0.000000"',
            '"FearMorePostProcess" "0.000000"',
            '"FearMoreControllerEnabled" "1.000000"',
            '"GPadAimSensitivity" "2.000000"',
            '"FearMoreControllerDeadZone" "0.180000"',
            '"FearMoreControllerInvertY" "0.000000"',
            '"FearMoreControllerRumble" "0.000000"',
            '"HUDSafeAreaFullWidth" "0.000000"'
        )) {
        if (-not $freshSettings.Contains($expectedModernDefault)) {
            throw "The fresh profile is missing a modern-display default: $expectedModernDefault"
        }
    }
    $freshGameIni = [IO.File]::ReadAllText($freshResult.GameIniPath)
    $gameRunsMatch = [regex]::Match($freshGameIni, '(?m)^GameRuns=(?<Value>\d+)\s*$')
    if (-not $gameRunsMatch.Success) {
        throw 'The fresh Game.ini is missing its launcher-owned GameRuns seed.'
    }
    $seededGameRuns = [int]$gameRunsMatch.Groups['Value'].Value
    $gameRunsAtMainMenu = $seededGameRuns + 1
    if ($seededGameRuns -ne 1 -or $gameRunsAtMainMenu -eq 1) {
        throw 'The fresh profile can still reach ScreenMain with GameRuns == 1 and trigger auto-detect.'
    }
    foreach ($recoveryPath in @(
            (Join-Path $fresh.UserDirectory 'settings.cfg.fearmore.new'),
            (Join-Path $fresh.UserDirectory 'Game.ini.fearmore.new')
        )) {
        if (Test-Path -LiteralPath $recoveryPath) {
            throw "A completed fresh-profile transaction left a recovery file: $recoveryPath"
        }
    }

    $existing = New-TestUserDirectory -Root $fixtureRoot -Name 'existing-profile'
    $existingSettingsPath = Join-Path $existing.UserDirectory 'settings.cfg'
    $existingGameIniPath = Join-Path $existing.UserDirectory 'Game.ini'
    $existingSettingsBytes = [Text.UTF8Encoding]::new($false).GetBytes("existing settings`nwith intentional LF only")
    $existingGameIniBytes = [Text.UTF8Encoding]::new($false).GetBytes("[Game]`nGameRuns=9`nProfileName=KeepMe`n")
    [IO.File]::WriteAllBytes($existingSettingsPath, $existingSettingsBytes)
    [IO.File]::WriteAllBytes($existingGameIniPath, $existingGameIniBytes)
    $existingResult = Initialize-FearMoreSettings `
        -UserDirectory $existing.UserDirectory `
        -WritableRoot $localRuntimeRoot `
        -StageRoot $existing.StageRoot `
        -DisplaySeed $explicitSeed `
        -EnhancedGoreEnabled $true `
        -CorpsePersistenceEnabled $true
    if ($existingResult.Seeded -or $existingResult.GameRunsSeeded -or
        -not $existingResult.ExistingFilePreserved -or -not $existingResult.ExistingGameIniPreserved) {
        throw 'An existing profile was reported as newly seeded.'
    }
    Assert-ExactBytes -Expected $existingSettingsBytes -Actual ([IO.File]::ReadAllBytes($existingSettingsPath)) -Description 'Existing settings.cfg'
    Assert-ExactBytes -Expected $existingGameIniBytes -Actual ([IO.File]::ReadAllBytes($existingGameIniPath)) -Description 'Existing Game.ini'

    $settingsOnly = New-TestUserDirectory -Root $fixtureRoot -Name 'settings-only-profile'
    $settingsOnlyPath = Join-Path $settingsOnly.UserDirectory 'settings.cfg'
    $settingsOnlyBytes = [Text.ASCIIEncoding]::new().GetBytes('preserve this settings profile exactly')
    [IO.File]::WriteAllBytes($settingsOnlyPath, $settingsOnlyBytes)
    $settingsOnlyResult = Initialize-FearMoreSettings `
        -UserDirectory $settingsOnly.UserDirectory `
        -WritableRoot $localRuntimeRoot `
        -StageRoot $settingsOnly.StageRoot `
        -DisplaySeed $explicitSeed
    if ($settingsOnlyResult.Seeded -or -not $settingsOnlyResult.GameRunsSeeded) {
        throw 'A settings-only profile did not receive only the missing Game.ini seed.'
    }
    Assert-ExactBytes -Expected $settingsOnlyBytes -Actual ([IO.File]::ReadAllBytes($settingsOnlyPath)) -Description 'Settings-only settings.cfg'

    $gameIniOnly = New-TestUserDirectory -Root $fixtureRoot -Name 'game-ini-only-profile'
    $gameIniOnlyPath = Join-Path $gameIniOnly.UserDirectory 'Game.ini'
    $gameIniOnlyBytes = [Text.ASCIIEncoding]::new().GetBytes("[Game]`r`nGameRuns=7`r`n")
    [IO.File]::WriteAllBytes($gameIniOnlyPath, $gameIniOnlyBytes)
    $gameIniOnlyResult = Initialize-FearMoreSettings `
        -UserDirectory $gameIniOnly.UserDirectory `
        -WritableRoot $localRuntimeRoot `
        -StageRoot $gameIniOnly.StageRoot `
        -DisplaySeed $explicitSeed
    if (-not $gameIniOnlyResult.Seeded -or $gameIniOnlyResult.GameRunsSeeded) {
        throw 'A Game.ini-only profile did not receive only the missing settings.cfg seed.'
    }
    $defaultSeededSettings = [IO.File]::ReadAllText($gameIniOnlyResult.Path)
    if (-not $defaultSeededSettings.Contains('"EnhancedGore" "0.000000"')) {
        throw 'The profile seeder no longer keeps Enhanced Gore disabled when its caller does not opt in.'
    }
    if (-not $defaultSeededSettings.Contains('"FearMoreCorpsePersistence" "0.000000"')) {
        throw 'The profile seeder no longer keeps corpse persistence disabled when its caller does not opt in.'
    }
    if (-not $defaultSeededSettings.Contains('"FearMoreControllerEnabled" "0.000000"')) {
        throw 'The profile seeder no longer preserves stock/legacy controller input unless its caller opts into SDL.'
    }
    Assert-ExactBytes -Expected $gameIniOnlyBytes -Actual ([IO.File]::ReadAllBytes($gameIniOnlyPath)) -Description 'Game.ini-only Game.ini'

    # A final UserDirectory can look ordinary even when an intermediate path
    # component redirects writes through a junction. Profile seeding must use
    # the same component-by-component guard as runtime staging.
    $reparseTargetRoot = Join-Path $fixtureRoot 'ancestor-reparse-target'
    $reparseTargetStageRoot = Join-Path $reparseTargetRoot 'Stage'
    $reparseTargetUserDirectory = Join-Path $reparseTargetStageRoot 'UserDirectory'
    [IO.Directory]::CreateDirectory($reparseTargetUserDirectory) | Out-Null
    $reparseSentinelPath = Join-Path $reparseTargetUserDirectory 'sentinel.bin'
    $reparseSentinelBytes = [byte[]](0x53, 0x41, 0x46, 0x45)
    [IO.File]::WriteAllBytes($reparseSentinelPath, $reparseSentinelBytes)
    $profileAncestorJunction = Join-Path $fixtureRoot 'redirected-stage-parent'
    New-Item -ItemType Junction -Path $profileAncestorJunction -Target $reparseTargetRoot | Out-Null
    $redirectedStageRoot = Join-Path $profileAncestorJunction 'Stage'
    $redirectedUserDirectory = Join-Path $redirectedStageRoot 'UserDirectory'

    $ancestorReparseRejected = $false
    try {
        Initialize-FearMoreSettings `
            -UserDirectory $redirectedUserDirectory `
            -WritableRoot $localRuntimeRoot `
            -StageRoot $redirectedStageRoot `
            -DisplaySeed $explicitSeed | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('Unsafe reparse point') -or
            -not $_.Exception.Message.Contains($profileAncestorJunction)) {
            throw "Profile ancestor-reparse guard failed without precise evidence: $($_.Exception.Message)"
        }
        $ancestorReparseRejected = $true
    }
    if (-not $ancestorReparseRejected) {
        throw 'Profile seeding accepted a junction in the writable-root-to-StageRoot ancestor chain.'
    }
    Assert-ExactBytes `
        -Expected $reparseSentinelBytes `
        -Actual ([IO.File]::ReadAllBytes($reparseSentinelPath)) `
        -Description 'Profile ancestor-reparse sentinel'
    foreach ($unexpectedPath in @(
            (Join-Path $reparseTargetUserDirectory 'settings.cfg'),
            (Join-Path $reparseTargetUserDirectory 'Game.ini'),
            (Join-Path $reparseTargetUserDirectory 'settings.cfg.fearmore.new'),
            (Join-Path $reparseTargetUserDirectory 'Game.ini.fearmore.new')
        )) {
        if (Test-Path -LiteralPath $unexpectedPath) {
            throw "Profile ancestor-reparse rejection wrote through the external target: $unexpectedPath"
        }
    }
}
finally {
    if ($profileAncestorJunction -and (Test-Path -LiteralPath $profileAncestorJunction)) {
        $canonicalJunction = [IO.Path]::GetFullPath($profileAncestorJunction)
        $canonicalFixturePrefix = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\') + '\'
        if (-not $canonicalJunction.StartsWith($canonicalFixturePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a launcher-profile test junction outside its fixture: $canonicalJunction"
        }
        [IO.Directory]::Delete($canonicalJunction, $false)
    }
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $canonicalFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
        $localRuntimePrefix = $localRuntimeRoot + '\'
        if (-not $canonicalFixtureRoot.StartsWith($localRuntimePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean a launcher-profile fixture outside local-runtime: $canonicalFixtureRoot"
        }
        [IO.Directory]::Delete($canonicalFixtureRoot, $true)
    }
}

[pscustomobject]@{
    Status                       = 'PASS'
    FreshExplicitResolution      = '3440x1440'
    GameRunsAtMainMenu           = 2
    FirstRunAutoDetectSuppressed = $true
    ExistingFilesPreserved       = $true
    PartialProfilesPreserved     = $true
    ModernCorpsePersistenceOn    = $true
    GenericCorpsePersistenceOff  = $true
    ModernControllerOn           = $true
    GenericControllerOff         = $true
    AncestorReparseRejected      = $true
    DefaultWritableRootVerified  = $true
    DefaultPreset                = 'Modern'
    StableModernMappings         = 'Preserved'
    CameraLabStageLifecycle      = 'fearmore-launcher-native-camera-lab-armed'
}
