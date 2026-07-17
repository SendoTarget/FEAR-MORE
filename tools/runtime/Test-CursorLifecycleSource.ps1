[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$SdkSourceRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($SdkSourceRoot)) {
    $SdkSourceRoot = Join-Path $RepositoryRoot 'vendor-local\fear-sdk-108\Source'
}
$SdkSourceRoot = [IO.Path]::GetFullPath($SdkSourceRoot)

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

$clientRoot = Join-Path $RepositoryRoot 'FEAR\Dev\Source\FEAR\ClientShellDLL'
$cursorSource = Get-Content -LiteralPath (Join-Path $clientRoot 'CursorMgr.cpp') -Raw
$cursorHeader = Get-Content -LiteralPath (Join-Path $clientRoot 'CursorMgr.h') -Raw
$interfaceSource = Get-Content -LiteralPath (Join-Path $clientRoot 'InterfaceMgr.cpp') -Raw
$activeSdkCursorHeaderPath = Join-Path $SdkSourceRoot 'engine\sdk\inc\iltcursor.h'
if (-not (Test-Path -LiteralPath $activeSdkCursorHeaderPath -PathType Leaf)) {
    throw "Active F.E.A.R. 1.08 cursor SDK header is missing: $activeSdkCursorHeaderPath"
}
$activeSdkCursorHeader = Get-Content -LiteralPath $activeSdkCursorHeaderPath -Raw

if (-not $cursorHeader.Contains('ILTCursor*' + "`t" + 'GetCursorInterface() const;') -or
    -not $cursorHeader.Contains('bool' + "`t`t" + 'HasHardwareCursor() const;') -or
    -not $cursorHeader.Contains('bool' + "`t`t" + 'EnsureHardwareCursor();')) {
    throw 'Cursor lifecycle validation and recovery are no longer owned by CCursorMgr.'
}

$constructor = Get-SourceSection $cursorSource `
    'CCursorMgr::CCursorMgr()' `
    'CCursorMgr::~CCursorMgr()' `
    'CCursorMgr constructor'
Assert-LiteralsInOrder $constructor @(
    'm_hCurrentCursorRecord(NULL)',
    'm_hDefaultCursorRecord(NULL)',
    'm_hCursor(NULL)'
) 'The hardware cursor handle is no longer initialized deterministically.'

$init = Get-SourceSection $cursorSource `
    'bool CCursorMgr::Init()' `
    'CCursorMgr::Term' `
    'CCursorMgr::Init'
Assert-LiteralsInOrder $init @(
    'if (m_bInitialized)',
    'return true;',
    'g_vtCursorHack.Init(g_pLTClient, "CursorHack", NULL, 0.0f);',
    'SetDefaultCursor();',
    'return true;'
) 'Cursor initialization no longer restores the default cursor through the manager-owned recovery path.'
if ($init.Contains('Cursor()->') -or $init.Contains('GetCursorInterface()->')) {
    throw 'Cursor initialization directly dereferences a cursor interface instead of using the guarded manager path.'
}

$term = Get-SourceSection $cursorSource `
    'void CCursorMgr::Term()' `
    'CCursorMgr::GetCursorInterface' `
    'CCursorMgr::Term'
Assert-LiteralsInOrder $term @(
    'if (!m_bInitialized && !m_hCursor)',
    'm_hCurrentCursorRecord = NULL;',
    'return;',
    'ILTCursor* pCursor = GetCursorInterface();',
    'if (pCursor)',
    'pCursor->SetCursorMode(CM_None, true);',
    'if (m_hCursor)',
    'pCursor->FreeCursor(m_hCursor);',
    'm_bInitialized = false;',
    'm_hCurrentCursorRecord = NULL;',
    'm_hCursor = NULL;'
) 'Focus/renderer teardown no longer retires the cursor record and engine handle together.'

$cursorInterface = Get-SourceSection $cursorSource `
    'ILTCursor* CCursorMgr::GetCursorInterface() const' `
    'CCursorMgr::HasHardwareCursor' `
    'CCursorMgr::GetCursorInterface'
if (-not $cursorInterface.Contains('return g_pLTClient ? g_pLTClient->Cursor() : NULL;')) {
    throw 'Cursor interface acquisition can dereference an unavailable client.'
}

$handleTracking = Get-SourceSection $cursorSource `
    'bool CCursorMgr::HasHardwareCursor() const' `
    'CCursorMgr::EnsureHardwareCursor' `
    'CCursorMgr::HasHardwareCursor'
Assert-LiteralsInOrder $handleTracking @(
    'ILTCursor* pCursor = GetCursorInterface();',
    'The active F.E.A.R. 1.08 public SDK exposes no handle-validation call.',
    'return m_hCursor && pCursor;'
) 'Cursor handle tracking no longer matches the public SDK boundary.'

$recovery = Get-SourceSection $cursorSource `
    'bool CCursorMgr::EnsureHardwareCursor()' `
    'CCursorMgr::ScheduleReinit' `
    'CCursorMgr::EnsureHardwareCursor'
Assert-LiteralsInOrder $recovery @(
    'if (HasHardwareCursor())',
    'return true;',
    'if (!GetCursorInterface())',
    'return false;',
    'm_hCursor = NULL;',
    'return SetDefaultCursor() && HasHardwareCursor();'
) 'Hardware cursor recovery no longer reloads the default record after teardown.'

$useCursor = Get-SourceSection $cursorSource `
    'void CCursorMgr::UseCursor(bool bUseCursor, bool bLockCursorToCenter)' `
    'CCursorMgr::UseHardwareCursor' `
    'CCursorMgr::UseCursor'
Assert-LiteralsInOrder $useCursor @(
    'ILTCursor* pCursor = GetCursorInterface();',
    'if (!pCursor)',
    'else if (m_bUseCursor && m_bUseHardwareCursor)',
    'if (!EnsureHardwareCursor())',
    'pCursor->SetCursorMode(CM_None);',
    'else',
    'pCursor->SetCursorMode(CM_Hardware);',
    'pCursor->SetCursor(m_hCursor)',
    'pCursor->SetCursorMode(CM_None);',
    'pCursor->FreeCursor(m_hCursor);',
    'm_hCursor = NULL;',
    'if(g_pLTClient && bLockCursorToCenter)',
    'g_pLTClient->SetConsoleVariableFloat("CursorCenter", 1.0f);',
    'else if (g_pLTClient)',
    'g_pLTClient->SetConsoleVariableFloat("CursorCenter", 0.0f);'
) 'Visible hardware-cursor use can reach the engine before recovery or lacks a safe failure mode.'

$useHardwareCursor = Get-SourceSection $cursorSource `
    'void CCursorMgr::UseHardwareCursor(bool bUseHardwareCursor,bool bForce)' `
    'CCursorMgr::Update' `
    'CCursorMgr::UseHardwareCursor'
Assert-LiteralsInOrder $useHardwareCursor @(
    'ILTCursor* pCursor = GetCursorInterface();',
    'if (!pCursor)',
    'return;',
    'if (m_bUseHardwareCursor && m_bUseCursor && EnsureHardwareCursor())',
    'pCursor->SetCursorMode(CM_Hardware,bForce);',
    'else',
    'pCursor->SetCursorMode(CM_None,bForce);'
) 'Hardware-cursor preference changes can dereference an unavailable cursor interface.'

$setCursor = Get-SourceSection $cursorSource `
    'bool CCursorMgr::SetCursor( HRECORD hCursorRecord )' `
    'bool CCursorMgr::SetCursor( const char* szCursorRecord )' `
    'CCursorMgr::SetCursor record overload'
Assert-LiteralsInOrder $setCursor @(
    'hCursorRecord == m_hCurrentCursorRecord && HasHardwareCursor()',
    'ILTCursor* pCursor = GetCursorInterface();',
    'if (!pCursor)',
    'return false;',
    'HLTCURSOR hNewCursor = NULL;',
    'pCursor->LoadCursorFromFile(pszHardwareCursorFileName, hNewCursor)',
    '!hNewCursor)',
    'pCursor->SetCursor(hNewCursor)',
    'pCursor->FreeCursor(hNewCursor);',
    'HLTCURSOR hPreviousCursor = m_hCursor;',
    'm_hCursor = hNewCursor;',
    'if (hPreviousCursor && hPreviousCursor != hNewCursor)',
    'pCursor->FreeCursor(hPreviousCursor);'
) 'Cursor record reuse or loading no longer requires a tracked non-null SDK handle.'

if ($cursorSource.Contains('IsValidCursor') -or
    [regex]::IsMatch($cursorSource, 'g_pLTClient\s*->\s*Cursor\s*\(\s*\)\s*->') -or
    [regex]::IsMatch($cursorSource, 'SetCursor\s*\(\s*NULL\s*\)')) {
    throw 'CursorMgr uses a cursor API outside the F.E.A.R. 1.08 ABI, contains an unguarded cursor-interface chain, or passes a literal null cursor.'
}

$expectedCursorMethods = @('FreeCursor', 'LoadCursorFromFile', 'SetCursor', 'SetCursorMode')
$invokedCursorMethods = @(
    [regex]::Matches($cursorSource, '\bpCursor\s*->\s*(?<Method>[A-Za-z_][A-Za-z0-9_]*)\s*\(') |
        ForEach-Object { $_.Groups['Method'].Value } |
        Sort-Object -Unique
)
$unexpectedCursorMethods = @($invokedCursorMethods | Where-Object { $_ -notin $expectedCursorMethods })
$missingCursorMethods = @($expectedCursorMethods | Where-Object { $_ -notin $invokedCursorMethods })
if ($unexpectedCursorMethods.Count -gt 0 -or $missingCursorMethods.Count -gt 0) {
    throw "CursorMgr's ILTCursor call set drifted. Unexpected: $($unexpectedCursorMethods -join ', '); missing: $($missingCursorMethods -join ', ')."
}
foreach ($method in $invokedCursorMethods) {
    if (-not [regex]::IsMatch($activeSdkCursorHeader, ('\b' + [regex]::Escape($method) + '\s*\('))) {
        throw "CursorMgr invokes ILTCursor::$method, which is absent from the active F.E.A.R. 1.08 SDK header."
    }
}

$renderTerm = Get-SourceSection $interfaceSource `
    'case  LTEVENT_RENDERTERM :' `
    'case LTEVENT_LOSTFOCUS:' `
    'CInterfaceMgr renderer termination'
Assert-LiteralsInOrder $renderTerm @(
    'm_CursorMgr.Term();',
    'if (m_LoadingScreen.IsVisible())',
    'm_LoadingScreen.Pause();'
) 'Renderer-only teardown no longer retires the cursor before delayed reinitialization.'

[pscustomobject]@{
    Status = 'PASS'
    ConstructorHandleInitialized = $true
    TeardownHandleRetired = $true
    DoubleTeardownIdempotent = $true
    PublicSdkHandleTracking = $true
    PublicSdkMethods = ($invokedCursorMethods -join ',')
    DefaultCursorRecovery = $true
    RendererTermRetirement = $true
    WrapperRelease = 'WhenCursorInterfaceAvailable'
    EngineFailureFallback = 'CM_NoneOrNoInterfaceCall'
    RuntimeLaunched = $false
    Note = 'Static source invariants only. Live acceptance must cover unattended movie completion plus focus loss/restoration with the hardware cursor enabled and disabled.'
}
