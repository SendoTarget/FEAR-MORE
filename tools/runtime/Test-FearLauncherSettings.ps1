[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'FearLauncherSettings.psm1'
Import-Module $modulePath -Force -ErrorAction Stop
$exportedFunctions = @(
    Get-Command -Module FearLauncherSettings -CommandType Function |
        Select-Object -ExpandProperty Name |
        Sort-Object
)
$expectedFunctions = @(
    'Get-FearMoreCorpsePersistenceEnabledFromSettings',
    'Get-FearMoreEnhancedGoreEnabledFromSettings',
	'Get-FearMoreHdTextureModeFromSettings',
	'Get-FearMorePostProcessModeFromSettings',
	'Get-FearMoreRendererQualityFromSettings',
	'Get-FearRegisteredHdTextureRoot',
	'Get-FearRegisteredFullHdTextureRoot'
) | Sort-Object
if (@(Compare-Object $expectedFunctions $exportedFunctions).Count -ne 0) {
    throw "FearLauncherSettings exports changed. Found: $($exportedFunctions -join ', ')"
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$fixtureRoot = Join-Path $repositoryRoot 'local-runtime\launcher-settings-test'
if (-not (Test-Path -LiteralPath $fixtureRoot)) {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
}
$fixtureItem = Get-Item -LiteralPath $fixtureRoot -Force
if (($fixtureItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Launcher settings fixture root must not be a reparse point: $fixtureRoot"
}
$settingsPath = Join-Path $fixtureRoot 'settings.cfg'

function Set-FixtureSettings {
    param([Parameter(Mandatory = $true)][string[]]$Lines)
    [IO.File]::WriteAllLines($settingsPath, $Lines, [Text.ASCIIEncoding]::new())
}

function Assert-Mode {
    param([Parameter(Mandatory = $true)][string[]]$Lines, [Parameter(Mandatory = $true)][string]$Expected)
    Set-FixtureSettings -Lines $Lines
    $actual = Get-FearMoreHdTextureModeFromSettings -Path $settingsPath
    if ($actual -ne $Expected) {
        throw "Expected HD texture mode $Expected but found $actual for: $($Lines -join ' | ')"
    }
}

function Assert-Rejected {
    param([Parameter(Mandatory = $true)][string[]]$Lines)
    Set-FixtureSettings -Lines $Lines
    try {
        Get-FearMoreHdTextureModeFromSettings -Path $settingsPath | Out-Null
    }
    catch {
        return
    }
    throw "Invalid HD texture setting was accepted: $($Lines -join ' | ')"
}

Assert-Mode -Lines @('"ScreenWidth" "3440"') -Expected 'Off'
Assert-Mode -Lines @('"FearMoreHDTextures" "0.000000"') -Expected 'Off'
Assert-Mode -Lines @('"FearMoreHDTextures" "1"') -Expected 'Lite'
Assert-Mode -Lines @('"FearMoreHDTextures" "1.000000"') -Expected 'Lite'
Assert-Mode -Lines @('"fearmorehdtextures" "1.000000"') -Expected 'Lite'
Assert-Mode -Lines @('"FearMoreHDTextures" "2.000000"') -Expected 'Full'
Assert-Rejected -Lines @('"FearMoreHDTextures" "1.5"')
Assert-Rejected -Lines @('"FearMoreHDTextures" "3.000000"')
Assert-Rejected -Lines @('"FearMoreHDTextures" "NaN"')
Assert-Rejected -Lines @('FearMoreHDTextures 1')
Assert-Rejected -Lines @('"FearMoreHDTextures" "0"', '"FearMoreHDTextures" "1"')
Assert-Rejected -Lines @('"FearMoreHDTextures" "0"', '"fearmorehdtextures" "1"')
Assert-Rejected -Lines @('"FearMoreHDTextures" "1"', '"FearMoreHDTextures" "0" trailing')

function Assert-EnhancedGore {
    param(
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [Parameter(Mandatory = $true)][bool]$Expected,
        [bool]$DefaultEnabled = $false
    )
    Set-FixtureSettings -Lines $Lines
    $actual = Get-FearMoreEnhancedGoreEnabledFromSettings -Path $settingsPath -DefaultEnabled $DefaultEnabled
    if ($actual -ne $Expected) {
        throw "Expected Enhanced Gore enabled=$Expected but found $actual for: $($Lines -join ' | ')"
    }
}

function Assert-EnhancedGoreRejected {
    param([Parameter(Mandatory = $true)][string[]]$Lines)
    Set-FixtureSettings -Lines $Lines
    try {
        Get-FearMoreEnhancedGoreEnabledFromSettings -Path $settingsPath | Out-Null
    }
    catch {
        return
    }
    throw "Invalid Enhanced Gore setting was accepted: $($Lines -join ' | ')"
}

Assert-EnhancedGore -Lines @('"ScreenWidth" "3440"') -Expected $false
Assert-EnhancedGore -Lines @('"ScreenWidth" "3440"') -Expected $true -DefaultEnabled $true
Assert-EnhancedGore -Lines @('"EnhancedGore" "0.000000"') -Expected $false
Assert-EnhancedGore -Lines @('"EnhancedGore" "1"') -Expected $true
Assert-EnhancedGore -Lines @('"enhancedgore" "1.000000"') -Expected $true
Assert-EnhancedGoreRejected -Lines @('"EnhancedGore" "1.5"')
Assert-EnhancedGoreRejected -Lines @('"EnhancedGore" "2"')
Assert-EnhancedGoreRejected -Lines @('"EnhancedGore" "NaN"')
Assert-EnhancedGoreRejected -Lines @('EnhancedGore 1')
Assert-EnhancedGoreRejected -Lines @('"EnhancedGore" "0"', '"enhancedgore" "1"')

function Assert-CorpsePersistence {
    param(
        [Parameter(Mandatory = $true)][string[]]$Lines,
        [Parameter(Mandatory = $true)][bool]$Expected,
        [bool]$DefaultEnabled = $false
    )
    Set-FixtureSettings -Lines $Lines
    $actual = Get-FearMoreCorpsePersistenceEnabledFromSettings `
        -Path $settingsPath `
        -DefaultEnabled $DefaultEnabled
    if ($actual -ne $Expected) {
        throw "Expected corpse persistence enabled=$Expected but found $actual for: $($Lines -join ' | ')"
    }
}

function Assert-CorpsePersistenceRejected {
    param([Parameter(Mandatory = $true)][string[]]$Lines)
    Set-FixtureSettings -Lines $Lines
    try {
        Get-FearMoreCorpsePersistenceEnabledFromSettings -Path $settingsPath | Out-Null
    }
    catch {
        return
    }
    throw "Invalid corpse-persistence setting was accepted: $($Lines -join ' | ')"
}

Assert-CorpsePersistence -Lines @('"ScreenWidth" "3440"') -Expected $false
Assert-CorpsePersistence -Lines @('"ScreenWidth" "3440"') -Expected $true -DefaultEnabled $true
Assert-CorpsePersistence -Lines @('"FearMoreCorpsePersistence" "0.000000"') -Expected $false -DefaultEnabled $true
Assert-CorpsePersistence -Lines @('"FearMoreCorpsePersistence" "1"') -Expected $true
Assert-CorpsePersistence -Lines @('"fearmorecorpsepersistence" "1.000000"') -Expected $true
Assert-CorpsePersistenceRejected -Lines @('"FearMoreCorpsePersistence" "1.5"')
Assert-CorpsePersistenceRejected -Lines @('"FearMoreCorpsePersistence" "2"')
Assert-CorpsePersistenceRejected -Lines @('"FearMoreCorpsePersistence" "NaN"')
Assert-CorpsePersistenceRejected -Lines @('FearMoreCorpsePersistence 1')
Assert-CorpsePersistenceRejected -Lines @('"FearMoreCorpsePersistence" "0"', '"fearmorecorpsepersistence" "1"')

function Assert-RendererQuality {
    param([Parameter(Mandatory = $true)][string[]]$Lines, [Parameter(Mandatory = $true)][string]$Expected)
    Set-FixtureSettings -Lines $Lines
    $actual = Get-FearMoreRendererQualityFromSettings -Path $settingsPath
    if ($actual -ne $Expected) {
        throw "Expected renderer quality $Expected but found $actual for: $($Lines -join ' | ')"
    }
}

function Assert-RendererQualityRejected {
    param([Parameter(Mandatory = $true)][string[]]$Lines)
    Set-FixtureSettings -Lines $Lines
    try {
        Get-FearMoreRendererQualityFromSettings -Path $settingsPath | Out-Null
    }
    catch {
        return
    }
    throw "Invalid renderer-quality setting was accepted: $($Lines -join ' | ')"
}

function Assert-PostProcessMode {
    param([Parameter(Mandatory = $true)][string[]]$Lines, [Parameter(Mandatory = $true)][string]$Expected)
    Set-FixtureSettings -Lines $Lines
    $actual = Get-FearMorePostProcessModeFromSettings -Path $settingsPath
    if ($actual -ne $Expected) {
        throw "Expected post-process mode $Expected but found $actual for: $($Lines -join ' | ')"
    }
}

function Assert-PostProcessModeRejected {
    param([Parameter(Mandatory = $true)][string[]]$Lines)
    Set-FixtureSettings -Lines $Lines
    try {
        Get-FearMorePostProcessModeFromSettings -Path $settingsPath | Out-Null
    }
    catch {
        return
    }
    throw "Malformed post-process setting was accepted: $($Lines -join ' | ')"
}

Assert-RendererQuality -Lines @('"ScreenWidth" "3440"') -Expected 'Native'
Assert-RendererQuality -Lines @('"FearMoreRendererQuality" "0.000000"') -Expected 'Native'
Assert-RendererQuality -Lines @('"FearMoreRendererQuality" "1"') -Expected 'Max2x'
Assert-RendererQuality -Lines @('"fearmorerendererquality" "1.000000"') -Expected 'Max2x'
Assert-RendererQualityRejected -Lines @('"FearMoreRendererQuality" "1.5"')
Assert-RendererQualityRejected -Lines @('"FearMoreRendererQuality" "2"')
Assert-RendererQualityRejected -Lines @('FearMoreRendererQuality 1')
Assert-RendererQualityRejected -Lines @('"FearMoreRendererQuality" "0"', '"fearmorerendererquality" "1"')

Assert-PostProcessMode -Lines @('"ScreenWidth" "3440"') -Expected 'None'
Assert-PostProcessMode -Lines @('"FearMorePostProcess" "0.000000"') -Expected 'None'
Assert-PostProcessMode -Lines @('"FearMorePostProcess" "1"') -Expected 'ReShadeCas'
Assert-PostProcessMode -Lines @('"fearmorepostprocess" "1.000000"') -Expected 'ReShadeCas'
Assert-PostProcessModeRejected -Lines @('"FearMorePostProcess" "1.5"')
Assert-PostProcessModeRejected -Lines @('"FearMorePostProcess" "2"')
Assert-PostProcessModeRejected -Lines @('FearMorePostProcess 1')
Assert-PostProcessModeRejected -Lines @('"FearMorePostProcess" "0"', '"fearmorepostprocess" "1"')

$explicitRelative = 'vendor-local\texture-packs'
$resolvedExplicit = Get-FearRegisteredFullHdTextureRoot -RepositoryRoot $repositoryRoot -ExplicitRoot $explicitRelative
$expectedExplicit = [IO.Path]::GetFullPath((Join-Path $repositoryRoot $explicitRelative))
if (-not $resolvedExplicit.Equals($expectedExplicit, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Explicit HD texture root resolution changed.'
}
$resolvedLiteExplicit = Get-FearRegisteredHdTextureRoot -RepositoryRoot $repositoryRoot -Mode Lite -ExplicitRoot $explicitRelative
if (-not $resolvedLiteExplicit.Equals($expectedExplicit, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Explicit Lite HD texture root resolution changed.'
}

[pscustomobject]@{
    Status            = 'PASS'
    MissingField      = 'Off'
    IntegralModes    = 'Off|Lite|Full'
    InvalidValues     = 'Rejected'
    DuplicateFields   = 'Rejected'
	EnhancedGore      = 'Off|On'
	CorpsePersistence = 'Off|On'
	RendererQuality   = 'Native|Max2x'
    PostProcessMode   = 'None|ReShadeCas'
    ExportedFunctions = $exportedFunctions
}
