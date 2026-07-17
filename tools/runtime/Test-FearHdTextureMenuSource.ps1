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
        throw "HD texture menu source input is missing: $path"
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

$screenHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenGame.h'
$screenSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenGame.cpp'
$cycleSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\Libs\LTGUIMgr\ltguicyclectrl.cpp'
$baseScreenSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\BaseScreen.cpp'

$offHelpIdMatch = [regex]::Match(
    $screenSource,
    'const\s+char\*\s+const\s+kHDTexturesOffHelpId\s*=\s*"([^"]+)"\s*;',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
)
$fullHelpIdMatch = [regex]::Match(
    $screenSource,
    'const\s+char\*\s+const\s+kHDTexturesFullHelpId\s*=\s*"([^"]+)"\s*;',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
)
$liteHelpIdMatch = [regex]::Match(
    $screenSource,
    'const\s+char\*\s+const\s+kHDTexturesLiteHelpId\s*=\s*"([^"]+)"\s*;',
    [Text.RegularExpressions.RegexOptions]::CultureInvariant
)
if (-not $offHelpIdMatch.Success -or -not $liteHelpIdMatch.Success -or -not $fullHelpIdMatch.Success) {
    throw 'The HD texture menu must declare literal Off, Lite, and Full help-cache identities.'
}
if (@(@($offHelpIdMatch.Groups[1].Value, $liteHelpIdMatch.Groups[1].Value, $fullHelpIdMatch.Groups[1].Value) | Select-Object -Unique).Count -ne 3) {
    throw 'The HD texture Off, Lite, and Full help-cache identities must be distinct.'
}

foreach ($requiredHeaderToken in @(
    'void`tUpdateHDTextureHelpId();'.Replace('`t', "`t"),
    'CLTGUICycleCtrl`t`t*m_pHDTexturesCtrl;'.Replace('`t', "`t")
)) {
    if (-not $screenHeader.Contains($requiredHeaderToken)) {
        throw "The HD texture menu header contract is missing: $requiredHeaderToken"
    }
}

$constructorSection = Get-SourceSection $screenSource 'CScreenGame::CScreenGame()' 'CScreenGame::~CScreenGame()' 'HD texture menu constructor'
if (-not $constructorSection.Contains('m_pHDTexturesCtrl = NULL;')) {
    throw 'The base-owned HD texture control pointer is no longer initialized before Build().'
}

$buildSection = Get-SourceSection $screenSource 'bool CScreenGame::Build()' 'uint32 CScreenGame::OnCommand' 'HD texture menu build'
Assert-LiteralsInOrder $buildSection @(
    'hdTexturesCreate.szHelpID = kHDTexturesOffHelpId;',
    'hdTexturesCreate.pCommandHandler = this;',
    'hdTexturesCreate.nCommandID = CMD_UPDATE;',
    'hdTexturesCreate.pnValue = &m_nHDTextures;',
    'm_pHDTexturesCtrl = AddCycle(L"HD textures", hdTexturesCreate);',
    'm_pHDTexturesCtrl->AddString(LoadString("IDS_OFF"));',
    'm_pHDTexturesCtrl->AddString(L"Stable Lite (recommended)");',
    'm_pHDTexturesCtrl->AddString(L"Full v2.0.2 (experimental)");'
) 'The HD cycle must use the existing change-command primitive and remain bound to its saved selection.'

$commandSection = Get-SourceSection $screenSource 'uint32 CScreenGame::OnCommand' 'void CScreenGame::OnFocus' 'HD texture selection command'
Assert-LiteralsInOrder $commandSection @(
    'case CMD_UPDATE:',
    'if (m_pHDTexturesCtrl)',
    'm_pHDTexturesCtrl->UpdateData(true);',
    'UpdateHDTextureHelpId();',
    'UpdateHelpText();'
) 'The HD cycle must copy its new selection before changing the help ID and refreshing the cached help text.'

$focusSection = Get-SourceSection $screenSource 'void CScreenGame::OnFocus' 'void CScreenGame::UpdateHDTextureHelpId' 'HD texture focus persistence'
Assert-LiteralsInOrder $focusSection @(
    'm_nHDTextures = (uint8)LTCLAMP(GetConsoleInt("FearMoreHDTextures", 0), 0, 2);',
    'UpdateData(false);',
    'UpdateHDTextureHelpId();',
    'UpdateData();',
    'WriteConsoleInt("FearMoreHDTextures", (int)LTCLAMP(m_nHDTextures, 0, 2));',
    'SaveSettings();'
) 'The HD selection must restore its help identity on focus and preserve the existing settings save path.'

$helpSection = Get-SourceSection $screenSource 'void CScreenGame::UpdateHDTextureHelpId' 'const wchar_t* HUDSliderTextCallback' 'HD texture dynamic help'
Assert-LiteralsInOrder $helpSection @(
    'szHelpId = kHDTexturesLiteHelpId;',
    'szHelpId = kHDTexturesFullHelpId;',
    'm_pHDTexturesCtrl->SetHelpID(szHelpId);',
    'LTStrIEquals(szHelpId, kHDTexturesLiteHelpId)',
    'LTStrIEquals(szHelpId, kHDTexturesFullHelpId)',
    'const int nSelectedMode = (int)LTCLAMP(m_nHDTextures, 0, 2);',
    'const int nActiveMode = LTCLAMP(GetConsoleInt("FearMoreHDTexturesActive", 0), 0, 2);',
    'The selected HD texture mode applies on the next launch.',
    'Stable Lite is active.',
    'Full v2.0.2 is experimental.',
    'Optional HD textures are off.'
) 'The help contract must retain pending, Off, Lite, and Full states while using distinct cache identities.'

$cycleLeftSection = Get-SourceSection $cycleSource `
    'bool CLTGUICycleCtrl::OnLeft ( )' `
    'bool CLTGUICycleCtrl::OnRight ( )' `
    'LTGUI cycle left path'
Assert-LiteralsInOrder $cycleLeftSection @(
    'SetSelIndex(newSel);',
    'm_pCommandHandler->SendCommand(m_nCommandID, m_nParam1, m_nParam2);'
) 'The active LTGUI cycle primitive must dispatch its change command after changing the left selection.'

$cycleRightSection = Get-SourceSection $cycleSource `
    'bool CLTGUICycleCtrl::OnRight ( )' `
    'void CLTGUICycleCtrl::SetBasePos' `
    'LTGUI cycle right path'
Assert-LiteralsInOrder $cycleRightSection @(
    'SetSelIndex(newSel);',
    'm_pCommandHandler->SendCommand(m_nCommandID, m_nParam1, m_nParam2);'
) 'The active LTGUI cycle primitive must dispatch its change command after changing the right selection.'

Assert-LiteralsInOrder $baseScreenSource @(
    'if( !LTStrIEquals(m_szCurrHelpID, szID) )',
    'GetHelpString(m_szCurrHelpID,m_nSelection,wszHelpText,LTARRAYSIZE(wszHelpText));'
) 'The base help cache contract changed; revisit the two-ID invalidation strategy.'

[pscustomobject]@{
    Status = 'PASS'
    CycleChangeCommand = $true
    ImmediateSelectionCopy = $true
    DistinctHelpCacheIds = $true
    SelectedAndActiveStates = 4
    FocusPersistence = $true
}
