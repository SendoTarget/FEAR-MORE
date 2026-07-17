Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1') -ErrorAction Stop

function Get-FearMoreInitialDisplaySeed {
    param(
        [Parameter(Mandatory = $true)][bool]$UseExplicitResolution,
        [int]$RequestedWidth,
        [int]$RequestedHeight
    )

    if ($UseExplicitResolution) {
        return [pscustomobject]@{
            Width      = $RequestedWidth
            Height     = $RequestedHeight
            DeviceName = '\\.\DISPLAY1'
            Source     = 'Explicit'
        }
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $screen = [Windows.Forms.Screen]::PrimaryScreen
        if ($screen -and $screen.Bounds.Width -ge 640 -and $screen.Bounds.Height -ge 480) {
            return [pscustomobject]@{
                Width      = [int]$screen.Bounds.Width
                Height     = [int]$screen.Bounds.Height
                DeviceName = if ($screen.DeviceName) { [string]$screen.DeviceName } else { '\\.\DISPLAY1' }
                Source     = 'PrimaryDisplay'
            }
        }
    }
    catch {
        Write-Warning "Primary-display detection failed; the new profile will use the safe 1920x1080 fallback. $($_.Exception.Message)"
    }

    return [pscustomobject]@{
        Width      = 1920
        Height     = 1080
        DeviceName = '\\.\DISPLAY1'
        Source     = 'Fallback'
    }
}

function Test-FearMoreOrdinaryProfileFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$WritableRoot,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-FearMoreProfileFileTarget -WritableRoot $WritableRoot -StageRoot $StageRoot -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is not an ordinary file; it was not changed: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description is a reparse point; it was not changed: $Path"
    }
    return $true
}

function Assert-FearMoreProfileFileTarget {
    param(
        [Parameter(Mandatory = $true)][string]$WritableRoot,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $parentPath = Split-Path ([IO.Path]::GetFullPath($Path)) -Parent
    Assert-FearNoReparsePathComponents `
        -Root $WritableRoot `
        -Path $parentPath `
        -RequirePath `
        -Description 'launcher profile file parent'
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
}

function Write-FearMoreProfileSeedTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$WritableRoot,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string[]]$Lines
    )

    Assert-FearMoreProfileFileTarget -WritableRoot $WritableRoot -StageRoot $StageRoot -Path $Path
    $stream = $null
    $writer = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        $writer = [IO.StreamWriter]::new($stream, [Text.ASCIIEncoding]::new())
        foreach ($line in $Lines) {
            $writer.WriteLine($line)
        }
        $writer.Dispose()
        $writer = $null
        $stream = $null
    }
    finally {
        if ($writer) {
            $writer.Dispose()
        }
        elseif ($stream) {
            $stream.Dispose()
        }
    }
}

function Complete-FearMoreProfileSeedTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$TransactionPath,
        [Parameter(Mandatory = $true)][string]$DestinationPath,
        [Parameter(Mandatory = $true)][string]$WritableRoot,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$Description
    )

    Assert-FearMoreProfileFileTarget -WritableRoot $WritableRoot -StageRoot $StageRoot -Path $TransactionPath
    if (Test-FearMoreOrdinaryProfileFile -Path $DestinationPath -WritableRoot $WritableRoot -StageRoot $StageRoot -Description $Description) {
        Assert-FearMoreProfileFileTarget -WritableRoot $WritableRoot -StageRoot $StageRoot -Path $TransactionPath
        [IO.File]::Delete($TransactionPath)
        return $false
    }

    try {
        Assert-FearMoreProfileFileTarget -WritableRoot $WritableRoot -StageRoot $StageRoot -Path $TransactionPath
        Assert-FearMoreProfileFileTarget -WritableRoot $WritableRoot -StageRoot $StageRoot -Path $DestinationPath
        [IO.File]::Move($TransactionPath, $DestinationPath)
    }
    catch [IO.IOException] {
        # A concurrently created profile file wins; the launcher never replaces it.
        if (Test-FearMoreOrdinaryProfileFile -Path $DestinationPath -WritableRoot $WritableRoot -StageRoot $StageRoot -Description $Description) {
            Assert-FearMoreProfileFileTarget -WritableRoot $WritableRoot -StageRoot $StageRoot -Path $TransactionPath
            [IO.File]::Delete($TransactionPath)
            return $false
        }
        throw
    }
    return $true
}

function Remove-FearMoreProfileSeedTransaction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$WritableRoot,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Assert-FearMoreProfileFileTarget -WritableRoot $WritableRoot -StageRoot $StageRoot -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "A profile seed transaction path is not an ordinary file and was not removed: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "A profile seed transaction path became a reparse point and was not removed: $Path"
    }
    Assert-FearMoreProfileFileTarget -WritableRoot $WritableRoot -StageRoot $StageRoot -Path $Path
    [IO.File]::Delete($Path)
}

function Initialize-FearMoreSettings {
    param(
        [Parameter(Mandatory = $true)][string]$UserDirectory,
        [string]$WritableRoot,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)]$DisplaySeed,
        [bool]$EnhancedGoreEnabled = $false,
        [bool]$CorpsePersistenceEnabled = $false,
        [bool]$ControllerEnabled = $false
    )

    if ([string]::IsNullOrWhiteSpace($WritableRoot)) {
        $WritableRoot = Join-Path $PSScriptRoot '..\..\local-runtime'
    }
    $canonicalWritableRoot = [IO.Path]::GetFullPath($WritableRoot).TrimEnd('\')
    $canonicalStageRoot = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
    $canonicalUserDirectory = [IO.Path]::GetFullPath($UserDirectory).TrimEnd('\')
    $stagePrefix = $canonicalStageRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $canonicalUserDirectory.StartsWith($stagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The staging result returned a UserDirectory outside its stage: $canonicalUserDirectory"
    }
    if (-not (Test-Path -LiteralPath $canonicalUserDirectory -PathType Container)) {
        throw "The staging result did not create its isolated UserDirectory: $canonicalUserDirectory"
    }

    # Profile seeding is a separate launcher transaction, but it shares the
    # runtime-stage filesystem guard. Validate every existing component from
    # the writable local-runtime root through UserDirectory, rather than
    # checking only the final directory for a reparse-point attribute.
    Assert-FearNoReparsePathComponents `
        -Root $canonicalWritableRoot `
        -Path $canonicalUserDirectory `
        -RequirePath `
        -Description 'launcher profile directory'

    $settingsPath = Join-Path $canonicalUserDirectory 'settings.cfg'
    $gameIniPath = Join-Path $canonicalUserDirectory 'Game.ini'
    $settingsTransactionPath = Join-Path $canonicalUserDirectory 'settings.cfg.fearmore.new'
    $gameIniTransactionPath = Join-Path $canonicalUserDirectory 'Game.ini.fearmore.new'
    foreach ($profileTarget in @($settingsPath, $gameIniPath, $settingsTransactionPath, $gameIniTransactionPath)) {
        Assert-FearMoreProfileFileTarget `
            -WritableRoot $canonicalWritableRoot `
            -StageRoot $canonicalStageRoot `
            -Path $profileTarget
    }
    $settingsExists = Test-FearMoreOrdinaryProfileFile `
        -Path $settingsPath `
        -WritableRoot $canonicalWritableRoot `
        -StageRoot $canonicalStageRoot `
        -Description 'Existing settings.cfg'
    $gameIniExists = Test-FearMoreOrdinaryProfileFile `
        -Path $gameIniPath `
        -WritableRoot $canonicalWritableRoot `
        -StageRoot $canonicalStageRoot `
        -Description 'Existing Game.ini'

    if (-not $settingsExists -and (Test-Path -LiteralPath $settingsTransactionPath)) {
        throw "A prior settings seed left a recovery file. Inspect it before retrying: $settingsTransactionPath"
    }
    if (-not $gameIniExists -and (Test-Path -LiteralPath $gameIniTransactionPath)) {
        throw "A prior Game.ini seed left a recovery file. Inspect it before retrying: $gameIniTransactionPath"
    }

    $safeDeviceName = [string]$DisplaySeed.DeviceName
    if (-not $safeDeviceName -or $safeDeviceName.Contains('"')) {
        $safeDeviceName = '\\.\DISPLAY1'
    }
    $settingsLines = @(
        '"GammaB" "1.000000"'
        '"GammaG" "1.000000"'
        '"GammaR" "1.000000"'
        '"BitDepth" "32"'
        '"HardwareCursor" "1.000000"'
        ('"ScreenWidth" "{0}"' -f [int]$DisplaySeed.Width)
        '"VSyncOnFlip" "0.000000"'
        ('"DeviceName" "{0}"' -f $safeDeviceName)
        ('"ScreenHeight" "{0}"' -f [int]$DisplaySeed.Height)
        '"RestartRenderBetweenMaps" "0.000000"'
        ('"EnhancedGore" "{0}.000000"' -f $(if ($EnhancedGoreEnabled) { 1 } else { 0 }))
        ('"FearMoreCorpsePersistence" "{0}.000000"' -f $(if ($CorpsePersistenceEnabled) { 1 } else { 0 }))
        '"FearMoreHDTextures" "0.000000"'
        '"FearMoreRendererQuality" "0.000000"'
        '"FearMoreEffectsTargetQuality" "0.000000"'
        '"FearMorePostProcess" "0.000000"'
        ('"FearMoreControllerEnabled" "{0}.000000"' -f $(if ($ControllerEnabled) { 1 } else { 0 }))
        '"GPadAimSensitivity" "2.000000"'
        '"FearMoreControllerDeadZone" "0.180000"'
        '"FearMoreControllerInvertY" "0.000000"'
        '"FearMoreControllerRumble" "0.000000"'
        '"HUDSafeAreaFullWidth" "0.000000"'
    )
    $gameIniLines = @(
        '[Game]'
        'GameRuns=1'
    )

    $settingsSeeded = $false
    $gameRunsSeeded = $false
    try {
        if (-not $gameIniExists) {
            Write-FearMoreProfileSeedTransaction `
                -Path $gameIniTransactionPath `
                -WritableRoot $canonicalWritableRoot `
                -StageRoot $canonicalStageRoot `
                -Lines $gameIniLines
        }
        if (-not $settingsExists) {
            Write-FearMoreProfileSeedTransaction `
                -Path $settingsTransactionPath `
                -WritableRoot $canonicalWritableRoot `
                -StageRoot $canonicalStageRoot `
                -Lines $settingsLines
        }

        # Commit Game.ini first. If the process stops between the two moves, the
        # next launch still cannot overwrite a newly seeded ultrawide profile via
        # the legacy GameRuns == 1 auto-detect path.
        if (-not $gameIniExists) {
            $gameRunsSeeded = Complete-FearMoreProfileSeedTransaction `
                -TransactionPath $gameIniTransactionPath `
                -DestinationPath $gameIniPath `
                -WritableRoot $canonicalWritableRoot `
                -StageRoot $canonicalStageRoot `
                -Description 'Concurrent Game.ini'
        }
        if (-not $settingsExists) {
            $settingsSeeded = Complete-FearMoreProfileSeedTransaction `
                -TransactionPath $settingsTransactionPath `
                -DestinationPath $settingsPath `
                -WritableRoot $canonicalWritableRoot `
                -StageRoot $canonicalStageRoot `
                -Description 'Concurrent settings.cfg'
        }
    }
    finally {
        Remove-FearMoreProfileSeedTransaction `
            -Path $settingsTransactionPath `
            -WritableRoot $canonicalWritableRoot `
            -StageRoot $canonicalStageRoot
        Remove-FearMoreProfileSeedTransaction `
            -Path $gameIniTransactionPath `
            -WritableRoot $canonicalWritableRoot `
            -StageRoot $canonicalStageRoot
    }

    $existingSettingsPreserved = -not $settingsSeeded
    $existingGameIniPreserved = -not $gameRunsSeeded
    $note = if ($settingsSeeded -and $gameRunsSeeded) {
        'Created settings.cfg and seeded Game.ini GameRuns=1. The engine increments it to 2 before the main menu, preserving the requested resolution while intentionally skipping legacy first-run auto-detect and startup intros.'
    }
    elseif ($settingsSeeded) {
        'Created settings.cfg; existing Game.ini was preserved byte-for-byte, so first-run behavior follows its existing GameRuns value.'
    }
    elseif ($gameRunsSeeded) {
        'Existing settings.cfg was preserved byte-for-byte; seeded Game.ini GameRuns=1 to prevent legacy first-run auto-detect from replacing it.'
    }
    else {
        'Existing settings.cfg and Game.ini were preserved byte-for-byte. Width and Height are initial-profile settings only.'
    }

    return [pscustomobject]@{
        Path                    = $settingsPath
        GameIniPath             = $gameIniPath
        Seeded                  = $settingsSeeded
        GameRunsSeeded          = $gameRunsSeeded
        ExistingFilePreserved   = $existingSettingsPreserved
        ExistingGameIniPreserved = $existingGameIniPreserved
        Width                   = if ($settingsSeeded) { [int]$DisplaySeed.Width } else { $null }
        Height                  = if ($settingsSeeded) { [int]$DisplaySeed.Height } else { $null }
        Source                  = if ($settingsSeeded) { [string]$DisplaySeed.Source } else { 'ExistingProfile' }
        Note                    = $note
    }
}

Export-ModuleMember -Function @(
    'Get-FearMoreInitialDisplaySeed',
    'Initialize-FearMoreSettings'
)
