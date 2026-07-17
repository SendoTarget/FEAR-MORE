[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

function Get-RequiredSource {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Modern display source input is missing: $path"
    }

    return Get-Content -LiteralPath $path -Raw
}

function Get-SourceSection {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Start,
        [Parameter(Mandatory = $true)][string]$End,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $startIndex = $Source.IndexOf($Start, [StringComparison]::Ordinal)
    if ($startIndex -lt 0) {
        throw "$Name start marker is missing: $Start"
    }

    $endIndex = $Source.IndexOf($End, $startIndex + $Start.Length, [StringComparison]::Ordinal)
    if ($endIndex -lt 0) {
        throw "$Name end marker is missing: $End"
    }

    return $Source.Substring($startIndex, $endIndex - $startIndex)
}

function Assert-LiteralsInOrder {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string[]]$Literals,
        [Parameter(Mandatory = $true)][string]$Failure
    )

    $searchFrom = 0
    foreach ($literal in $Literals) {
        $index = $Source.IndexOf($literal, $searchFrom, [StringComparison]::Ordinal)
        if ($index -lt 0) {
            throw "$Failure Missing or out-of-order token: $literal"
        }
        $searchFrom = $index + $literal.Length
    }
}

function Get-SafeAreaGeometry {
    param(
        [Parameter(Mandatory = $true)][double]$Width,
        [Parameter(Mandatory = $true)][double]$Height
    )

    $contentWidth = [Math]::Min($Width, $Height * (16.0 / 9.0))
    $sideInset = ($Width - $contentWidth) * 0.5
    return [pscustomobject]@{
        Left = $sideInset
        Content = $contentWidth
        Right = $sideInset
    }
}

function Assert-Near {
    param(
        [Parameter(Mandatory = $true)][double]$Actual,
        [Parameter(Mandatory = $true)][double]$Expected,
        [Parameter(Mandatory = $true)][string]$Description,
        [double]$Tolerance = 0.001
    )

    if ([Math]::Abs($Actual - $Expected) -gt $Tolerance) {
        throw "$Description was $Actual; expected $Expected."
    }
}

$settingsHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreGraphicsSettings.h'
$settingsSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreGraphicsSettings.cpp'
$screenHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenDisplay.h'
$screenSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenDisplay.cpp'
$profileSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ProfileMgr.cpp'
$interfaceResSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\InterfaceResMgr.cpp'
$clientCMake = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\CMakeLists.txt'

Assert-LiteralsInOrder $settingsHeader @(
    'eRendererQuality_Native = 0',
    'eRendererQuality_2xDownsample = 1',
    'ePostProcess_Off = 0',
    'ePostProcess_CAS = 1',
    'eHUDPlacement_CenteredSafeArea = 0',
    'eHUDPlacement_FullWidth = 1',
    'm_nDefaultValue',
    'm_nMinimumValue',
    'm_nMaximumValue',
    'ClampOptionValue',
    'GetRendererDownsampleScale',
    'GetOptionValueLabel',
    'GetHelpText'
) 'The modern display descriptor contract changed unexpectedly.'

Assert-LiteralsInOrder $settingsSource @(
    '"FearMoreRendererQuality"',
    'L"Renderer quality"',
    'FearMoreGraphicsSettings::eRendererQuality_Native',
    'FearMoreGraphicsSettings::eRendererQuality_2xDownsample',
    '"FearMorePostProcess"',
    '"FearMorePostProcess_Help"',
    'L"Post-processing"',
    'FearMoreGraphicsSettings::ePostProcess_Off',
    'FearMoreGraphicsSettings::ePostProcess_CAS',
    '"HUDSafeAreaFullWidth"',
    'L"HUD placement"',
    'FearMoreGraphicsSettings::eHUDPlacement_CenteredSafeArea',
    'FearMoreGraphicsSettings::eHUDPlacement_FullWidth'
) 'The renderer-quality or HUD-placement defaults are no longer source-owned.'

Assert-LiteralsInOrder $settingsSource @(
    'int ClampOptionValue',
    'if (nValue < descriptor.m_nMinimumValue)',
    'if (nValue > descriptor.m_nMaximumValue)',
    'int GetRendererDownsampleScale',
    'eRendererQuality_2xDownsample) ? 2 : 1',
    'L"Full width"',
    'L"Centered 16:9"',
    'L"CAS (next launch)"',
    'L"Max 2x (next launch)"',
    'L"Native leaves the app resolution unforced. Max 2x chooses dgVoodoo''s largest desktop-based resolution with the app aspect ratio, then doubles each axis on the next launch."'
) 'The bounded Native/Max 2x or centered/full-width mapping changed unexpectedly.'

if (-not $settingsSource.Contains('Contrast Adaptive Sharpening') -or
    $settingsHeader.Contains('GetActivePostProcess') -or
    $settingsSource.Contains('s_nActivePostProcess') -or
    $settingsHeader.Contains('PostProcessStrength') -or
    $settingsSource.Contains('PostProcessStrength')) {
    throw 'Post-processing must remain a focused Off/CAS next-launch contract without runtime activation or strength controls.'
}

if (@($clientCMake -split "`n" | Where-Object { $_ -match '^\s*FearMoreGraphicsSettings\.cpp\s*$' }).Count -ne 1) {
    throw 'FearMoreGraphicsSettings.cpp must appear exactly once in the ClientShell target.'
}

Assert-LiteralsInOrder $screenSource @(
    '#include "FearMoreGraphicsSettings.h"',
    'GetOptionDescriptor(FearMoreGraphicsSettings::eOption_RendererQuality)',
    'AddCycle(rendererQuality.m_pwszLabel,rendererQualityCreate)',
    'eRendererQuality_Native',
    'eRendererQuality_2xDownsample',
    'GetOptionDescriptor(FearMoreGraphicsSettings::eOption_PostProcess)',
    'AddCycle(postProcess.m_pwszLabel,postProcessCreate)',
    'ePostProcess_Off',
    'ePostProcess_CAS',
    'GetOptionDescriptor(FearMoreGraphicsSettings::eOption_HUDPlacement)',
    'AddToggle(hudPlacement.m_pwszLabel,hudPlacementCreate)',
    'eHUDPlacement_CenteredSafeArea',
    'eHUDPlacement_FullWidth'
) 'The Display screen no longer reuses the focused modern graphics descriptors and LTGUI controls.'

if ($screenHeader -notmatch 'GetHelpString' -or $screenSource -notmatch 'FearMoreGraphicsSettings::GetHelpText') {
    throw 'The Display screen lost the focused source-owned label/help provider.'
}

$hudCommand = Get-SourceSection $screenSource `
    'case CMD_HUD_PLACEMENT:' `
    'return 1;' `
    'HUD placement command'
Assert-LiteralsInOrder $hudCommand @(
    'm_pHUDPlacement->UpdateData(true);',
    'ClampOptionValue(',
    'WriteConsoleInt(hudPlacement.m_pszConsoleVariable,nHUDPlacement);',
    'g_pInterfaceMgr->ScreenDimsChanged();'
) 'HUD placement no longer applies immediately through the shared interface/HUD reflow.'

$focusSection = Get-SourceSection $screenSource `
    'void CScreenDisplay::OnFocus(bool bFocus)' `
    'void CScreenDisplay::GetHelpString' `
    'Display focus persistence'
Assert-LiteralsInOrder $focusSection @(
    'GetConsoleInt(rendererQuality.m_pszConsoleVariable,rendererQuality.m_nDefaultValue)',
    'GetConsoleInt(postProcess.m_pszConsoleVariable,postProcess.m_nDefaultValue)',
    'GetConsoleInt(hudPlacement.m_pszConsoleVariable,hudPlacement.m_nDefaultValue)',
    'WriteConsoleInt(rendererQuality.m_pszConsoleVariable,(int)m_nFearMoreRendererQuality);',
    'WriteConsoleInt(postProcess.m_pszConsoleVariable,(int)m_nFearMorePostProcess);',
    'WriteConsoleInt(hudPlacement.m_pszConsoleVariable,nHUDPlacement);',
    'pProfile->ApplyDisplay();',
    'pProfile->Save();'
) 'Modern Display settings are no longer clamped and committed before the established display save path.'

$saveSettings = Get-SourceSection $profileSource `
    'void SaveSettings()' `
    '//-------------------------------------------------------------------------------------------' `
    'settings.cfg whitelist'
foreach ($requiredSetting in @('"FearMoreHDTextures"', '"FearMoreRendererQuality"', '"FearMorePostProcess"', '"HUDSafeAreaFullWidth"')) {
    if (-not $saveSettings.Contains($requiredSetting)) {
        throw "settings.cfg no longer preserves $requiredSetting."
    }
}

if ($screenSource -match 'LTStrCat\s*\(\s*wszBuffer\s*,\s*L"\s*\*"' -or
    $screenSource.Contains('ScreenDisplay_ResolutionWarning') -or
    $screenSource.Contains('m_pWarning')) {
    throw 'The obsolete non-4:3 asterisk or aspect-ratio warning is still present.'
}

$rendererEnumeration = Get-SourceSection $screenSource `
    'void CScreenDisplay::GetRendererData' `
    'void CScreenDisplay::SortRenderModes' `
    'renderer mode enumeration'
Assert-LiteralsInOrder $rendererEnumeration @(
    'pCurrentMode->m_Width >= 640',
    'pCurrentMode->m_Height >= 480',
    'pCurrentMode->m_BitDepth == 32',
    'rendererData.m_resolutionArray.Add(resolution);',
    'RelinquishRenderModes(pRenderModes);',
    'SortRenderModes( rendererData );'
) 'Renderer-reported mode enumeration was narrowed while removing the aspect-ratio stigma.'

$memoryWarning = Get-SourceSection $screenSource `
    'void CScreenDisplay::CheckResolutionMemory()' `
    '// ----------------------------------------------------------------------- //' `
    'VRAM warning message'
Assert-LiteralsInOrder $memoryWarning @(
    'EstimateVideoMemoryUsage()',
    'GetPerformanceStats().m_nGPUMemory',
    'ShowMessageBox("PerformanceMessage_ScreenResolution"',
    'm_dwFlags |= eFlag_ScreenResolutionWarning;'
) 'The real VRAM warning message changed while removing the aspect-ratio warning.'

$memoryColorStart = $screenSource.IndexOf('void CScreenDisplay::UpdateResolutionColor()', [StringComparison]::Ordinal)
if ($memoryColorStart -lt 0) {
    throw 'VRAM warning color owner is missing.'
}
$memoryColor = $screenSource.Substring($memoryColorStart)
Assert-LiteralsInOrder $memoryColor @(
    'ArePerformanceCapsValid()',
    'EstimateVideoMemoryUsage()',
    'GetPerformanceStats().m_nGPUMemory',
    'm_pResolutionCtrl->SetColor( m_nWarningColor );',
    'm_pResolutionCtrl->SetColor( m_NonSelectedColor );'
) 'The real VRAM warning color changed while removing the aspect-ratio warning.'

Assert-LiteralsInOrder $interfaceResSource @(
    's_vtHUDSafeAreaFullWidth.Init(g_pLTClient, "HUDSafeAreaFullWidth", NULL, 0.0f);',
    'if (s_vtHUDSafeAreaFullWidth.GetFloat() != 0.0f)',
    'GetAspectConstrainedRect(screenBounds, kHUDSafeAreaMaxAspect, safeBounds);'
) 'The centered 16:9 HUD default or full-width override changed unexpectedly.'

$geometryCases = @(
    [pscustomobject]@{ Width = 1920; Height = 1080; Left = 0.0; Content = 1920.0 },
    [pscustomobject]@{ Width = 2560; Height = 1080; Left = 320.0; Content = 1920.0 },
    [pscustomobject]@{ Width = 3440; Height = 1440; Left = 440.0; Content = 2560.0 },
    [pscustomobject]@{ Width = 3840; Height = 1600; Left = 497.7777777778; Content = 2844.4444444444 },
    [pscustomobject]@{ Width = 5120; Height = 1440; Left = 1280.0; Content = 2560.0 }
)

$geometryResults = foreach ($case in $geometryCases) {
    $geometry = Get-SafeAreaGeometry -Width $case.Width -Height $case.Height
    Assert-Near -Actual $geometry.Left -Expected $case.Left -Description "$($case.Width)x$($case.Height) left inset"
    Assert-Near -Actual $geometry.Content -Expected $case.Content -Description "$($case.Width)x$($case.Height) content width"
    Assert-Near -Actual $geometry.Right -Expected $case.Left -Description "$($case.Width)x$($case.Height) right inset"
    [pscustomobject]@{
        Resolution = "$($case.Width)x$($case.Height)"
        Left = [Math]::Round($geometry.Left, 6)
        Content = [Math]::Round($geometry.Content, 6)
        Right = [Math]::Round($geometry.Right, 6)
    }
}

[pscustomobject]@{
    Status = 'PASS'
    AspectRatioStigmaRemoved = $true
    VramWarningPreserved = $true
    RendererQualityDefault = 'Native'
    RendererQualityOptional = 'Max 2x (next launch)'
    PostProcessDefault = 'Off'
    PostProcessOptional = 'CAS (next launch)'
    HUDPlacementDefault = 'Centered 16:9'
    HUDPlacementImmediate = $true
    Geometries = @($geometryResults)
    RuntimeLaunched = $false
}
