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
        throw "Remaster-quality source input is missing: $path"
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

$screenHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenPerformance.h'
$screenSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenPerformance.cpp'
$presetHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreRemasterQuality.h'
$presetSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreRemasterQuality.cpp'
$performanceMgrHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\PerformanceMgr.h'
$performanceMgrSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\PerformanceMgr.cpp'
$profileMgrSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ProfileMgr.cpp'
$clientCMake = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\CMakeLists.txt'

$variableAndSpecSection = Get-SourceSection $presetSource `
    'const char* const kTextureFilteringVariables[]' `
    'struct SResolvedOption' `
    'remaster-quality record specification'
$specSection = Get-SourceSection $presetSource `
    'const SOptionSpec kOptions[]' `
    'struct SResolvedOption' `
    'remaster-quality record list'

$requiredRecords = @(
    'TextureFiltering',
    'SoftShadows',
    'TextureResolution',
    'WorldDetail',
    'RenderTargets',
    'Lights'
)
foreach ($recordName in $requiredRecords) {
    $quotedRecord = '"' + $recordName + '"'
    $occurrences = ([regex]::Matches($specSection, [regex]::Escape($quotedRecord))).Count
    if ($occurrences -ne 1) {
        throw "Retail option record $quotedRecord must be targeted exactly once; found $occurrences."
    }
}

foreach ($variableName in @(
    'Trilinear',
    'Anisotropic',
    'Light_ShadowBlur',
    'TextureGroupOffsetD',
    'TextureGroupOffsetN',
    'TextureGroupOffsetS',
    'TextureGroupOffsetE',
    'WorldDetail',
    'RenderTargetLOD',
    'LODLights'
)) {
    if (-not $variableAndSpecSection.Contains('"' + $variableName + '"')) {
        throw "The proven retail variable $variableName is missing from the compatibility contract."
    }
}

if ($variableAndSpecSection.Contains('"LightDetail"') -or
    $variableAndSpecSection.Contains('"Resolution"')) {
    throw 'The preset must not substitute localized suffixes or the display-resolution record for proven retail record names.'
}

$compatibilitySection = Get-SourceSection $presetSource `
    'bool IsCompatibleOption' `
    'bool ResolveOptions' `
    'remaster-quality compatibility preflight'
Assert-LiteralsInOrder $compatibilitySection @(
    'GetAttribute(hOptionRecord, "DetailNames")',
    'GetNumValues(hDetailNames) == 0',
    'GetVariables(hOptionRecord)',
    'if (!hVariables)',
    'nVariableCount != spec.m_nVariableCount',
    '"DetailValues"',
    'GetNumValues(hDetailValues) == 0',
    'LTStrIEquals(pszVariable, spec.m_ppszVariables[nExpectedVariable])',
    'if (nMatches != 1)'
) 'The DB-backed compatibility preflight changed unexpectedly.'

$resolverSection = Get-SourceSection $presetSource `
    'bool ResolveOptions' `
    'namespace FearMoreRemasterQuality' `
    'atomic remaster-quality resolver'
Assert-LiteralsInOrder $resolverSection @(
    'm_bResolved = false;',
    'CPerformanceMgr& performanceMgr = CPerformanceMgr::Instance();',
    'nType < kNumPerformanceTypes',
    'performanceMgr.GetNumGroups(nType)',
    'performanceMgr.GetNumOptions(nType, nGroup)',
    'performanceMgr.GetOptionRecord(nType, nGroup, nOption)',
    'g_pLTDatabase->GetRecordName(hOptionRecord)',
    'LTStrIEquals(pszRecordName, kOptions[nTarget].m_pszRecordName)',
    'pResolvedOptions[nTarget].m_bResolved ||',
    '!IsCompatibleOption',
    'return false;',
    'm_bResolved = true;',
    'if (!pResolvedOptions[nTarget].m_bResolved)',
    'return false;',
    'return true;'
) 'The resolver no longer proves every required record before mutation.'

$buildSection = Get-SourceSection $screenSource `
    'bool CScreenPerformance::Build()' `
    'uint32 CScreenPerformance::OnCommand' `
    'Performance screen controls'
Assert-LiteralsInOrder $buildSection @(
    'CMD_APPLY_REMASTER_QUALITY',
    'FearMoreRemasterQuality::GetHelpId()',
    'AddTextItem(FearMoreRemasterQuality::GetLabel(), cs )'
) 'The opt-in remaster-quality action is no longer exposed on the existing Performance screen.'

if (-not $screenHeader.Contains('GetHelpString(') -or
    -not $screenHeader.Contains('ApplyRemasterQuality()') -or
    -not $presetHeader.Contains('QueueMaximumPreset()')) {
    throw 'The Performance screen lost its source-owned help override or focused action method.'
}

$helpSection = Get-SourceSection $screenSource `
    'void CScreenPerformance::GetHelpString' `
    'void CScreenPerformance::OnFocus' `
    'source-owned remaster-quality help'
Assert-LiteralsInOrder $helpSection @(
    'FearMoreRemasterQuality::GetHelpText(szHelpId)',
    'LTStrCpy(buffer, pHelpText, bufLen)',
    'CBaseScreen::GetHelpString'
) 'The local help text no longer explains the preset scope and deferred apply behavior.'

Assert-LiteralsInOrder $presetSource @(
    '"FearMoreRemasterQuality_Help"',
    'L"Apply remaster quality"',
    'six proven retail option records',
    'Other settings stay unchanged',
    'leave this screen to apply and save',
    'const wchar_t* GetHelpText',
    'if (!pszHelpId)'
) 'The focused module lost its source-owned label/help contract.'

$applySection = Get-SourceSection $screenSource `
    'bool CScreenPerformance::ApplyRemasterQuality()' `
    'void CScreenPerformance::SetOverall' `
    'remaster-quality mutation path'
Assert-LiteralsInOrder $applySection @(
    'if (!FearMoreRemasterQuality::QueueMaximumPreset())',
    'Remaster quality was not applied.',
    'return false;',
    'UpdateOverall(ePT_CPU);',
    'UpdateOverall(ePT_GPU);',
    'CheckResolutionMemory();',
    'UpdateGPUColor();',
    'Leave the Performance screen to apply and save the changes.'
) 'The action lost its all-or-nothing preflight, index-zero queueing, or UI refresh.'

foreach ($forbidden in @(
    'SetDetailLevel(',
    'WriteConsole',
    'SetQueuedConsoleVariable(',
    'ApplyQueuedConsoleChanges(',
    'RevertQueuedConsoleChanges(',
    'pProfile->Save(',
    '"Resolution"'
)) {
    if ($applySection.Contains($forbidden)) {
        throw "The focused action bypasses or broadens the established queued option path: $forbidden"
    }
}

if ($screenSource.Contains('struct SOptionSpec') -or
    $screenSource.Contains('bool ResolveOptions') -or
    $screenSource.Contains('performanceMgr.SetOptionLevel(')) {
    throw 'ScreenPerformance must remain the UI/feedback owner, not absorb preset resolution or queueing.'
}

$queueSection = Get-SourceSection $presetSource `
    'bool QueueMaximumPreset()' `
    "`n}" `
    'focused remaster-quality queue'
Assert-LiteralsInOrder $queueSection @(
    'SResolvedOption aResolvedOptions',
    'if (!ResolveOptions(aResolvedOptions, LTARRAYSIZE(aResolvedOptions)))',
    'return false;',
    'CPerformanceMgr& performanceMgr = CPerformanceMgr::Instance();',
    'for (uint32 nTarget = 0;',
    'performanceMgr.SetOptionLevel(',
    'aResolvedOptions[nTarget].m_nOption,',
    '0 );',
    'return true;'
) 'The focused module lost atomic preflight-before-queue or retail Maximum index zero.'

foreach ($forbidden in @(
    'SetDetailLevel(',
    'WriteConsole',
    'SetQueuedConsoleVariable(',
    'ApplyQueuedConsoleChanges(',
    'RevertQueuedConsoleChanges(',
    '"Resolution"'
)) {
    if ($queueSection.Contains($forbidden)) {
        throw "The focused module bypasses or broadens the established queued option path: $forbidden"
    }
}

$saveSection = Get-SourceSection $screenSource `
    'void CScreenPerformance::Save()' `
    'void CScreenPerformance::SetBasedOnPerformanceStats' `
    'established Performance screen save path'
Assert-LiteralsInOrder $saveSection @(
    'if( m_bTrueExit )',
    'CPerformanceMgr::Instance().ApplyQueuedConsoleChanges(true);',
    'g_pProfileMgr->GetCurrentProfile()->Save();'
) 'Leaving the screen no longer owns applying and saving queued performance changes.'

$loadSection = Get-SourceSection $screenSource `
    'void CScreenPerformance::Load()' `
    'uint8 CScreenPerformance::CycleCallback' `
    'authoritative display-mode seed'
Assert-LiteralsInOrder $loadSection @(
    'CUserProfile* pProfile = g_pProfileMgr->GetCurrentProfile();',
    'pProfile ? pProfile->m_nScreenWidth : GetConsoleInt("ScreenWidth",640)',
    'pProfile ? pProfile->m_nScreenHeight : GetConsoleInt("ScreenHeight",480)',
    'g_pGameClientShell->IsRendererInitted()',
    'g_pLTClient->GetRenderMode(&currentMode) == LT_OK',
    'nWidth = currentMode.m_Width;',
    'nHeight = currentMode.m_Height;',
    'WriteConsoleInt("Performance_ScreenWidth",nWidth);',
    'WriteConsoleInt("Performance_ScreenHeight",nHeight);'
) 'The Performance screen can again seed resolution from stale bootstrap state instead of the active renderer mode.'

$applyQueueSection = Get-SourceSection $performanceMgrSource `
    'bool CPerformanceMgr::ApplyQueuedConsoleChanges(bool bApplyResolution)' `
    'void CPerformanceMgr::RevertQueuedConsoleChanges' `
    'explicit Performance resolution ownership'
Assert-LiteralsInOrder $applyQueueSection @(
    'const bool bResolutionRequested',
    'm_bResolutionWidthRequested && m_bResolutionHeightRequested',
    'const bool bPartialResolutionRequest',
    'm_bResolutionWidthRequested != m_bResolutionHeightRequested',
    'const float fRequestedWidth = m_fResolutionWidthRequest;',
    'const float fRequestedHeight = m_fResolutionHeightRequest;',
    'bool bNonResolutionRestartRequested = false;',
    'const bool bResolutionVariable',
    'if (bResolutionVariable &&',
    '(!bApplyResolution || bPartialResolutionRequest))',
    'ltstd::free_vector( m_VariableQueue );',
    'm_bResolutionWidthRequested = false;',
    'm_bResolutionHeightRequested = false;',
    'const bool bCurrentModeValid',
    'g_pLTClient->GetRenderMode(&currentMode) == LT_OK',
    'if (bApplyResolution && bResolutionRequested)',
    'uint32 nWidth',
    '(uint32)fRequestedWidth',
    'uint32 nHeight',
    '(uint32)fRequestedHeight',
    'const bool bRequestedModeActive',
    'if (bRequestedModeActive)',
    'WriteConsoleInt("ScreenWidth", nWidth);',
    'else if (pProfile)',
    'const uint32 nOldProfileWidth',
    'const uint32 nOldProfileHeight',
    'const uint32 nOldProfileDepth',
    'pProfile->m_nScreenWidth = nWidth;',
    'pProfile->m_nScreenHeight = nHeight;',
    'pProfile->ApplyDisplay();',
    'g_pLTClient->GetRenderMode(&appliedMode) == LT_OK',
    'if (bAppliedModeValid &&',
    'WriteConsoleInt("ScreenWidth", appliedMode.m_Width);',
    'pProfile->m_nScreenDepth = appliedMode.m_BitDepth;',
    'else',
    'pProfile->m_nScreenWidth = appliedMode.m_Width;',
    'pProfile->m_nScreenHeight = appliedMode.m_Height;',
    'pProfile->m_nScreenWidth = nOldProfileWidth;',
    'pProfile->m_nScreenHeight = nOldProfileHeight;',
    'else if (bApplyResolution && bCurrentModeValid)',
    'WriteConsoleInt("ScreenWidth", currentMode.m_Width);',
    'WriteConsoleInt("ScreenHeight", currentMode.m_Height);',
    'ActivateChanges( nATFlags );'
) 'Unrelated queued performance options can again turn a stale resolution baseline into a display-mode change.'

$getQueuedSection = Get-SourceSection $performanceMgrSource `
    'bool CPerformanceMgr::GetQueuedConsoleVariable' `
    'bool CPerformanceMgr::SetQueuedConsoleVariable' `
    'effective paired resolution request lookup'
Assert-LiteralsInOrder $getQueuedSection @(
    'm_bResolutionWidthRequested && LTStrIEquals(szVariable, "Performance_ScreenWidth")',
    'fValue = m_fResolutionWidthRequest;',
    'm_bResolutionHeightRequested && LTStrIEquals(szVariable, "Performance_ScreenHeight")',
    'fValue = m_fResolutionHeightRequest;',
    'std::find( m_VariableQueue.begin()'
) 'Callers can no longer observe an atomic resolution pair when one unchanged dimension was suppressed from the physical queue.'

$performanceSaveSection = Get-SourceSection $performanceMgrSource `
    'void CPerformanceMgr::Save(HDATABASECREATOR hDBC)' `
    'uint32 CPerformanceMgr::GetNumOptions' `
    'active-mode Performance persistence'
Assert-LiteralsInOrder $performanceSaveSection @(
    'CUserProfile *pProfile = g_pProfileMgr->GetCurrentProfile();',
    'uint32 nScreenWidth',
    'uint32 nScreenHeight',
    'g_pLTClient->GetRenderMode(&currentMode) == LT_OK',
    'nScreenWidth = currentMode.m_Width;',
    'nScreenHeight = currentMode.m_Height;',
    'WriteConsoleInt("Performance_ScreenWidth",nScreenWidth);',
    'WriteConsoleInt("Performance_ScreenHeight",nScreenHeight);'
) 'Saving a custom Performance profile can again persist stale profile dimensions instead of the active renderer mode.'

foreach ($member in @(
    'm_bResolutionWidthRequested',
    'm_bResolutionHeightRequested',
    'm_fResolutionWidthRequest',
    'm_fResolutionHeightRequest'
)) {
    if (-not $performanceMgrHeader.Contains($member)) {
        throw "PerformanceMgr lost paired resolution intent tracking: $member"
    }
}

$setQueuedSection = Get-SourceSection $performanceMgrSource `
    'bool CPerformanceMgr::SetQueuedConsoleVariable' `
    'bool CPerformanceMgr::ApplyQueuedConsoleChanges' `
    'resolution request capture before no-op suppression'
Assert-LiteralsInOrder $setQueuedSection @(
    'LTStrIEquals(szVariable, "Performance_ScreenWidth")',
    'm_bResolutionWidthRequested = true;',
    'm_fResolutionWidthRequest = fValue;',
    'LTStrIEquals(szVariable, "Performance_ScreenHeight")',
    'm_bResolutionHeightRequested = true;',
    'm_fResolutionHeightRequest = fValue;',
    'std::find( m_VariableQueue.begin()',
    'LTNearlyEquals(fValueCurrent, fValue, MATH_EPSILON)'
) 'Resolution intent is no longer captured before ordinary no-op queue suppression.'

$revertQueueSection = Get-SourceSection $performanceMgrSource `
    'void CPerformanceMgr::RevertQueuedConsoleChanges()' `
    'bool CPerformanceMgr::DetectPerformanceStats' `
    'paired resolution request rollback'
Assert-LiteralsInOrder $revertQueueSection @(
    'ltstd::free_vector( m_VariableQueue );',
    'm_bResolutionWidthRequested = false;',
    'm_bResolutionHeightRequested = false;',
    'm_fResolutionWidthRequest = 0.0f;',
    'm_fResolutionHeightRequest = 0.0f;'
) 'Reverting the queue no longer clears pending paired resolution intent.'

$performanceLoadSection = Get-SourceSection $performanceMgrSource `
    'void CPerformanceMgr::Load(HDATABASE hDB, bool bLoadDisplaySettings' `
    'void CPerformanceMgr::Save(HDATABASECREATOR hDBC)' `
    'profile Performance queue lifecycle'
Assert-LiteralsInOrder $performanceLoadSection @(
    'if (!hRec)',
    'SetDetailLevel(ePT_CPU,g_DefaultCPUDetailLevel);',
    'SetDetailLevel(ePT_GPU,g_DefaultGPUDetailLevel);',
    'ApplyQueuedConsoleChanges(bLoadDisplaySettings);',
    'return;',
    'ApplyQueuedConsoleChanges(bLoadDisplaySettings);'
) 'A missing or legacy Performance record can again leave the retail default resolution queued for a later screen exit.'

$profileDefaultsSection = Get-SourceSection $profileMgrSource `
    'if (bLoadDefaults)' `
    '// load weapon priorities' `
    'new-profile Performance queue lifecycle'
Assert-LiteralsInOrder $profileDefaultsSection @(
    'if( !CPerformanceMgr::Instance().ArePerformanceStatsValid() )',
    'CPerformanceMgr::Instance().SetDetailLevel(ePT_CPU,g_DefaultCPUDetailLevel);',
    'CPerformanceMgr::Instance().SetDetailLevel(ePT_GPU,g_DefaultGPUDetailLevel);',
    'CPerformanceMgr::Instance().ApplyQueuedConsoleChanges(false);'
) 'A new profile can again retain an implicit 800x600 request until the first Performance-screen exit.'

$maximumSection = Get-SourceSection $performanceMgrSource `
    'int32 CPerformanceMgr::GetOptionLevelFromOverall' `
    'DetailLevel CPerformanceMgr::GetDetailLevel' `
    'retail Maximum mapping'
Assert-LiteralsInOrder $maximumSection @(
    'if (eOverall == ePO_Maximum)',
    'return 0;'
) 'Retail Maximum no longer maps to option detail index zero.'

$setOptionSection = Get-SourceSection $performanceMgrSource `
    'void CPerformanceMgr::SetOptionLevel(uint32 nType, uint32 nGroup, uint32 nOption, int32 nLevel)' `
    'void CPerformanceMgr::ActivateChanges' `
    'shared DB-backed option queue'
Assert-LiteralsInOrder $setOptionSection @(
    'GetOptionRecord(nType,nGroup,nOption)',
    'GetVariables(hOptRec)',
    '"DetailValues"',
    'DetailValues, nLevel',
    'ActivationFlags',
    'SetQueuedConsoleVariable( pszVar, fValue, atFlags )'
) 'SetOptionLevel no longer preserves retail DB values and activation flags through the shared queue.'

foreach ($sourceName in @('FearMoreRemasterQuality.cpp', 'ScreenPerformance.cpp')) {
    if (@($clientCMake -split "`n" | Where-Object { $_ -match ('^\s*' + [regex]::Escape($sourceName) + '\s*$') }).Count -ne 1) {
        throw "$sourceName must appear exactly once in the active ClientShell target."
    }
}

[pscustomobject]@{
    Status = 'PASS'
    RequiredRetailRecords = @($requiredRecords)
    MaximumDetailIndex = 0
    AtomicPreflight = $true
    OtherOptionsPreserved = $true
    RetailActivationFlagsPreserved = $true
    ApplyOnScreenExit = $true
    ActiveDisplayModePreserved = $true
    NewProfileResolutionQueueCleared = $true
    LegacyProfileResolutionQueueCleared = $true
    SameDimensionResolutionIntentPreserved = $true
    SourceOwnedHelp = $true
    FocusedModule = $true
    RuntimeLaunched = $false
}
