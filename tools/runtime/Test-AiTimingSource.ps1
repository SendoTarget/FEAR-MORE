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
        throw "AI timing source input is missing: $path"
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

function Assert-SourceMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Failure
    )

    if ($Source -notmatch $Pattern) {
        throw $Failure
    }
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

$ai = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\AI.cpp'
$character = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\Character.cpp'
$aiManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\AIMgr.cpp'
$goalManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\AIGoalMgr.cpp'
$navigationManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\AINavigationMgr.cpp'
$sensorManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\AISensorMgr.cpp'
$flamePotSensor = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\AISensorFlamePot.cpp'
$profilerHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\AIProfiler.h'
$profiler = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\AIProfiler.cpp'
$serverShell = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\GameServerShell.cpp'
$serverCMake = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\CMakeLists.txt'
$serverProject = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\Game_ServerShell.vcproj'

# Active AI follows every authoritative frame by default. A positive value is
# still an explicit retail-compatible throttle, and failed setup can retain the
# stock UPDATE_NEVER behavior.
$intervalFunction = Get-SourceSection $ai 'static float GetAIUpdateInterval()' '// Insures the AI do not initially' 'GetAIUpdateInterval'
Assert-LiteralsInOrder $intervalFunction @(
    's_AIUpdateIntervalTrack.Init( g_pLTServer, "AIUpdateInterval", NULL, 0.0f );',
    'const float fConfiguredInterval = s_AIUpdateIntervalTrack.GetFloat();',
    'fConfiguredInterval > 0.0f',
    'LTMAX<float>( fConfiguredInterval, UPDATE_NEXT_FRAME )',
    'UPDATE_NEXT_FRAME;'
) 'The frame-synced/default and positive-interval fallback contract changed.'
$scheduleCallCount = [regex]::Matches($ai, [regex]::Escape('SetNextServerUpdate( GetAIUpdateInterval() );')).Count
if ($scheduleCallCount -ne 2) {
    throw "AI scheduling must be applied at MID_UPDATE and MID_INITIALUPDATE; found $scheduleCallCount call sites."
}
Assert-SourceMatch $ai 'if\(\s*!m_pAnimationContext\s*\)\s*\{\s*SetNextServerUpdate\(\s*UPDATE_NEVER\s*\)' `
    'Failed AI setup no longer preserves its intentional UPDATE_NEVER path.'

# The update order is behavior ownership: state completion precedes current
# goal, navigation precedes goal selection, and animation follows planning.
$aiUpdate = Get-SourceSection $ai 'void CAI::Update()' '// ----------------------------------------------------------------------- //' 'CAI::Update'
Assert-LiteralsInOrder $aiUpdate @(
    'm_pState->Update()',
    'm_pGoalMgr->UpdateGoal()',
    'm_pAINavigationMgr->UpdateNavigation()',
    'm_pGoalMgr->SelectRelevantGoal()',
    'm_pState->UpdateAnimation()'
) 'AI state/goal/navigation/selection/animation ownership order changed.'

# Severing retains one stock 0.01-second update before frame-synced scheduling
# resumes. This is independent of whether Enhanced Gore is enabled.
$severSchedule = Get-SourceSection $character 'static void ScheduleSeveredAIUpdate' 'static bool IsEnhancedGoreEnabled' 'ScheduleSeveredAIUpdate'
Assert-SourceMatch $severSchedule 'pAI->SetNextServerUpdate\(\s*c_fUpdateDelta\s*\);' `
    'The one-shot stock sever update delay is missing.'
$severScheduleCallCount = [regex]::Matches($character, [regex]::Escape('ScheduleSeveredAIUpdate(m_hObject);')).Count
if ($severScheduleCallCount -ne 2) {
    throw "Live and postmortem sever paths must both use the one-shot scheduler guard; found $severScheduleCallCount calls."
}

# The source-owned profiler remains opt-in, uses the precision clock, brackets
# authoritative server work, and times the existing subsystem owners.
Assert-SourceMatch $profiler 's_AIProfileEnabled\.Init\(\s*g_pLTServer\s*,\s*"AIProfileEnabled"\s*,\s*NULL\s*,\s*0\.0f\s*\)' `
    'AI profiling is no longer disabled by default.'
Assert-SourceMatch $profiler 'LTTimeUtils::GetPrecisionTime\(\)' `
    'AI profiling no longer uses the engine precision clock.'
Assert-LiteralsInOrder $serverShell @(
    'CAIProfiler::Instance().BeginServerFrame();',
    'EnterServerShell();',
    'ExitServerShell();',
    'CAIProfiler::Instance().EndServerFrame();'
) 'The authoritative server-frame profiler boundary changed.'
$scopeOwners = @(
    [pscustomobject]@{ Source = $ai;                Scope = 'kAIProfileScope_AIUpdate' },
    [pscustomobject]@{ Source = $aiManager;         Scope = 'kAIProfileScope_AIMgr' },
    [pscustomobject]@{ Source = $sensorManager;     Scope = 'kAIProfileScope_Sensors' },
    [pscustomobject]@{ Source = $goalManager;       Scope = 'kAIProfileScope_GoalSelection' },
    [pscustomobject]@{ Source = $navigationManager; Scope = 'kAIProfileScope_Navigation' }
)
foreach ($owner in $scopeOwners) {
    Assert-SourceMatch $owner.Source ([regex]::Escape("CAIProfileScope ProfileScope( $($owner.Scope) );")) `
        "Profiler scope $($owner.Scope) is no longer attached to its existing behavior owner."
}
foreach ($scopeName in @('AIUpdate', 'AIMgr', 'Sensors', 'GoalSelection', 'Navigation')) {
    Assert-SourceMatch $profilerHeader "kAIProfileScope_${scopeName}" `
        "Profiler enum lost $scopeName."
}
Assert-SourceMatch $serverProject 'RelativePath="AIProfiler\.cpp"' `
    'The tracked GameServer project no longer compiles AIProfiler.cpp.'
Assert-SourceMatch $serverProject 'RelativePath="AIProfiler\.h"' `
    'The tracked GameServer project no longer owns AIProfiler.h.'
if ($serverCMake -match 'list\(APPEND\s+FEAR_SERVER_SOURCES(?s:.*?)AIProfiler') {
    throw 'CMake duplicates the profiler instead of deriving it from the tracked GameServer project.'
}

# Save and load keep the existing count-plus-elements layout. The stock bug
# wrote the list size for every element; the loader has always expected actual
# EnumAIStimulusID values.
$sensorSave = Get-SourceSection $sensorManager 'void CAISensorMgr::Save' 'void CAISensorMgr::Load' 'CAISensorMgr::Save'
Assert-LiteralsInOrder $sensorSave @(
    'SAVE_INT(m_lstProcessedStimuli.size());',
    'for (std::size_t n = 0; n < m_lstProcessedStimuli.size(); ++n)',
    'SAVE_INT(m_lstProcessedStimuli[n]);'
) 'Processed-stimulus save data no longer writes count followed by each stimulus ID.'
$processedStimulusLoop = Get-SourceSection $sensorSave 'for (std::size_t n = 0; n < m_lstProcessedStimuli.size(); ++n)' 'SAVE_INT(m_cIntersectSegmentCount);' 'processed-stimulus save loop'
if ($processedStimulusLoop -match 'SAVE_INT\(m_lstProcessedStimuli\.size\(\)\)') {
    throw 'Processed-stimulus save loop regressed to serializing the list size as an element.'
}
$sensorLoad = Get-SourceSection $sensorManager 'void CAISensorMgr::Load' '// ----------------------------------------------------------------------- //' 'CAISensorMgr::Load'
Assert-LiteralsInOrder $sensorLoad @(
    'LOAD_INT(nProcessedStimuli);',
    'LOAD_INT_CAST(eStimulusID, EnumAIStimulusID);',
    'm_lstProcessedStimuli.push_back(eStimulusID);'
) 'Processed-stimulus load no longer consumes the matching ID sequence.'

# Flame-pot save compatibility remains one bool. Restoring an AI that was in a
# link reconstructs the omitted timestamp and restarts the two-second grace.
Assert-SourceMatch $flamePotSensor 'kFlamePotInvalidPositionDelay\s*=\s*2\.0\s*;' `
    'Flame-pot invalid-position delay is no longer two seconds.'
$flameLoad = Get-SourceSection $flamePotSensor 'void CAISensorFlamePot::Load' 'void CAISensorFlamePot::Save' 'CAISensorFlamePot::Load'
Assert-LiteralsInOrder $flameLoad @(
    'LOAD_bool( m_bWasInFlamePotLastFrame );',
    'm_flTimeEnteredFlamePot = m_bWasInFlamePotLastFrame',
    '? g_pLTServer->GetTime()',
    ': 0.0;'
) 'Flame-pot load no longer reconstructs its omitted entry timestamp safely.'
$flameSave = Get-SourceSection $flamePotSensor 'void CAISensorFlamePot::Save' 'bool CAISensorFlamePot::UpdateSensor' 'CAISensorFlamePot::Save'
$flameSaveCalls = @([regex]::Matches($flameSave, '(?m)^\s*SAVE_[A-Za-z]+\('))
if ($flameSaveCalls.Count -ne 1 -or $flameSave -notmatch 'SAVE_bool\(\s*m_bWasInFlamePotLastFrame\s*\)') {
    throw 'Flame-pot sensor save layout changed; it must retain exactly the inherited data plus one bool.'
}
Assert-SourceMatch $flamePotSensor 'GetTime\(\)\s*>=\s*m_flTimeEnteredFlamePot\s*\+\s*kFlamePotInvalidPositionDelay' `
    'Flame-pot invalidation no longer waits until entry time plus the grace period.'

[pscustomobject]@{
    Status                              = 'PASS'
    FrameSyncedSchedulerVerified        = $true
    UpdateOrderPreserved                = $true
    SeverDelayGuardVerified             = $true
    ProfilerOwnershipVerified           = $true
    ProcessedStimulusSymmetryVerified   = $true
    FlamePotCompatibilityVerified       = $true
    RuntimeLaunched                     = $false
    Note                                = 'Static source invariants only; capped encounter behavior and cross-cap save/load remain separate live gates.'
}
