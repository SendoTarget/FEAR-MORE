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

$overlayPath = Join-Path $RepositoryRoot 'tools\echopatch\overlays\RtxCameraReassertion.cpp'
$cameraDiagnosticsPath = Join-Path $RepositoryRoot 'tools\echopatch\overlays\CameraDiagnostics.cpp'
$globalsPath = Join-Path $RepositoryRoot 'external\EchoPatch\src\Globals.cpp'

foreach ($required in @($overlayPath, $cameraDiagnosticsPath, $globalsPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "RTX camera reassertion source input is missing: $required"
    }
}

$parseErrors = $null
$parseTokens = $null
[System.Management.Automation.Language.Parser]::ParseFile(
    $PSCommandPath,
    [ref]$parseTokens,
    [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -ne 0) {
    throw "RTX camera reassertion source test has parse errors: $($parseErrors -join [Environment]::NewLine)"
}

$overlay = Get-Content -LiteralPath $overlayPath -Raw
$cameraDiagnostics = Get-Content -LiteralPath $cameraDiagnosticsPath -Raw
$globals = Get-Content -LiteralPath $globalsPath -Raw

function Get-SourceSegment {
    param(
        [Parameter(Mandatory = $true)][string]$StartPattern,
        [Parameter(Mandatory = $true)][string]$EndPattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $match = [regex]::Match(
        $overlay,
        "(?s)$StartPattern.*?(?=$EndPattern)",
        [Text.RegularExpressions.RegexOptions]::CultureInvariant)
    if (-not $match.Success) {
        throw "Unable to isolate $Description in RtxCameraReassertion.cpp."
    }
    return $match.Value
}

$afterSetShader = Get-SourceSegment `
    -StartPattern 'static void AfterSetVertexShader\b' `
    -EndPattern '\s*// Called immediately before either original draw function\.' `
    -Description 'AfterSetVertexShader observer'
$beforeDraw = Get-SourceSegment `
    -StartPattern 'static void BeforeDraw\b' `
    -EndPattern '\s*// Called once by the sole EndScene hook owner' `
    -Description 'BeforeDraw observer'
$onEndScene = Get-SourceSegment `
    -StartPattern 'static void OnEndScene\b' `
    -EndPattern '\s*}\s*\n\s*static void InstallRtxCameraReassertion' `
    -Description 'OnEndScene observer'
$install = Get-SourceSegment `
    -StartPattern 'static void Install\(IDirect3DDevice9\* device\)' `
    -EndPattern '\s*// Called by the sole SetVertexShader hook owner' `
    -Description 'Install lifecycle'

# Default-safe and exact executable scope.
foreach ($fragment in @(
    'if (!EnableRtxCameraReassertion || !device',
    'g_State.CurrentFEARGame != FEAR',
    'IsExactFear108Executable()',
    'nt->FileHeader.TimeDateStamp == FEAR_TIMESTAMP',
    'nt->FileHeader.Machine == IMAGE_FILE_MACHINE_I386',
    'nt->OptionalHeader.Magic == IMAGE_NT_OPTIONAL_HDR32_MAGIC'
)) {
    if (-not $overlay.Contains($fragment)) {
        throw "RTX camera reassertion is missing default-safe executable invariant: $fragment"
    }
}
if ($overlay -match 'EnableRtxCameraReassertion\s*=\s*true') {
    throw 'RTX camera reassertion must never enable itself in the overlay.'
}
if ($globals -notmatch 'const DWORD FEAR_TIMESTAMP\s*=\s*0x44EF6AE6\s*;') {
    throw 'EchoPatch no longer identifies the pinned FEAR v1.08 executable with timestamp 44EF6AE6.'
}

# Exact shader identity and the same hash algorithm as CaptureDiagnostics.
foreach ($fragment in @(
    'kTargetShaderHash = 0xF7D91705u',
    'kTargetShaderBytes = 880',
    'kTargetShaderVersion = 0xFFFE0101u',
    'kTargetConstantRegister = 0',
    'kTargetConstantRegisterCount = 4',
    'uint32_t hash = 2166136261u',
    'hash ^= static_cast<uint32_t>(bytes[index])',
    'hash *= 16777619u',
    'fnv1a32-unsigned-byte'
)) {
    if (-not $overlay.Contains($fragment)) {
        throw "RTX camera reassertion is missing exact shader/hash invariant: $fragment"
    }
}
foreach ($fragment in @(
    'uint32_t hash = 2166136261u',
    'hash ^= static_cast<uint32_t>(bytes[index])',
    'hash *= 16777619u'
)) {
    if (-not $cameraDiagnostics.Contains($fragment)) {
        throw "CameraDiagnostics hash algorithm drifted from the reassertion observer: $fragment"
    }
}
if ($afterSetShader -notmatch 'ResolveShaderIdentity\(\s*shader,\s*hash,\s*byteCount,\s*versionToken') {
    throw 'AfterSetVertexShader must resolve zero-valued pre-arm identities without changing CameraDiagnostics ordering.'
}

# Frontend/loading frames must not consume the 300-frame experiment. Their
# presentation rate can be uncapped, so only QPC wall time may bound pre-arm.
foreach ($fragment in @(
    'kPreArmTimeoutSeconds = 300',
    'kPreArmProgressSeconds = 60',
    's_PreArmFrameNumber = 0',
    's_PreArmStartQpc = {}',
    's_PreArmDeadlineQpc = {}',
    's_NextPreArmProgressQpc = {}',
    's_PreArmClockReady = false',
    's_Armed = false',
    'QueryPerformanceFrequency(&s_QpcFrequency)',
    'QueryPerformanceCounter(&value)',
    'InitializePreArmClockLocked()',
    '(std::numeric_limits<LONGLONG>::max)()',
    'maximum / kPreArmTimeoutSeconds',
    'start.QuadPart > maximum - timeoutTicks',
    's_PreArmDeadlineQpc.QuadPart = start.QuadPart + timeoutTicks',
    'AdvancePreArmProgressDeadlineLocked(qpc)',
    'prearmDeadlineClock',
    'framesStartAfterExactTargetSelection',
    'WritePreArmLocked("installed", qpc)',
    'WritePreArmLocked("waiting-for-exact-target-shader", qpc)',
    'FailPreArmLocked("qpc-unavailable"',
    'FailPreArmLocked("qpc-deadline-expired"'
)) {
    if (-not $overlay.Contains($fragment)) {
        throw "RTX camera reassertion is missing pre-arm lifecycle invariant: $fragment"
    }
}
$exactArmPattern = '(?s)if\s*\(s_ObservedShaderIsTarget\)\s*\{.*?' +
    'if\s*\(!s_Armed\)\s*\{.*?TryReadQpc\(armQpc\).*?' +
    'armQpc\.QuadPart\s*>=\s*s_PreArmDeadlineQpc\.QuadPart.*?' +
    's_Armed\s*=\s*true\s*;.*?s_FrameNumber\s*=\s*0\s*;.*?' +
    'WriteArmLocked\(armQpc\)\s*;.*?\}\s*\}'
if ($afterSetShader -notmatch $exactArmPattern) {
    throw 'Only the exact F7D91705/880/vs_1_1 shader selection may arm and reset the 300-frame experiment.'
}
if ([regex]::Matches($overlay, 's_Armed\s*=\s*true\s*;').Count -ne 1) {
    throw 'RTX camera reassertion must have exactly one arm transition.'
}
if ($install -notmatch '(?s)s_Active\s*=\s*true\s*;.*?' +
    'if\s*\(!InitializePreArmClockLocked\(\)\).*?' +
    'FailPreArmLocked\("qpc-unavailable",\s*unavailableQpc\)\s*;.*?return\s*;') {
    throw 'Installation must fail closed before pre-arm when QPC deadline initialization is unavailable.'
}
if ($afterSetShader -notmatch '(?s)!s_PreArmClockReady\s*\|\|\s*!TryReadQpc\(armQpc\).*?' +
    'FailPreArmLocked\("qpc-unavailable",\s*armQpc\).*?' +
    'armQpc\.QuadPart\s*>=\s*s_PreArmDeadlineQpc\.QuadPart.*?' +
    'FailPreArmLocked\("qpc-deadline-expired",\s*armQpc\)') {
    throw 'The arm transition must fail closed if QPC is unavailable or its deadline already elapsed.'
}
if ($beforeDraw -notmatch 'if\s*\(\s*!s_Active\s*\|\|\s*!s_Armed\s*\|\|') {
    throw 'BeforeDraw must fail closed until the exact target shader arms the experiment.'
}

$preArmGateIndex = $onEndScene.IndexOf('if (!s_Armed)')
$preArmIncrementIndex = $onEndScene.IndexOf('++s_PreArmFrameNumber')
$qpcReadIndex = $onEndScene.IndexOf('TryReadQpc(qpc)')
$deadlineIndex = $onEndScene.IndexOf('qpc.QuadPart >= s_PreArmDeadlineQpc.QuadPart')
$timeoutIndex = $onEndScene.IndexOf('FailPreArmLocked("qpc-deadline-expired", qpc)')
$progressIndex = $onEndScene.IndexOf('qpc.QuadPart >= s_NextPreArmProgressQpc.QuadPart')
$activeFrameIncrementIndex = $onEndScene.IndexOf('++s_FrameNumber')
if ($preArmGateIndex -lt 0 -or
    $preArmIncrementIndex -le $preArmGateIndex -or
    $qpcReadIndex -le $preArmIncrementIndex -or
    $deadlineIndex -le $qpcReadIndex -or
    $timeoutIndex -le $deadlineIndex -or
    $progressIndex -le $timeoutIndex -or
    $activeFrameIncrementIndex -le $progressIndex) {
    throw 'OnEndScene must use the QPC deadline before exposing the separate armed-frame counter.'
}
if ($onEndScene -notmatch '(?s)if\s*\(!s_Armed\).*?FailPreArmLocked\("qpc-deadline-expired",\s*qpc\)\s*;.*?return\s*;.*?\+\+s_FrameNumber') {
    throw 'Every pre-arm OnEndScene path must return before the 300-frame armed counter advances.'
}
if ($overlay -match 'kPreArmFrameLimit|kPreArmLogInterval' -or
    $onEndScene -match 's_PreArmFrameNumber\s*(?:<=|>=|==|!=|<|>)') {
    throw 'Pre-arm EndScene count is telemetry only and must never control timeout or progress.'
}
if ($onEndScene -notmatch '!s_PreArmClockReady\s*\|\|\s*!TryReadQpc\(qpc\)' -or
    $onEndScene -notmatch 'FailPreArmLocked\("qpc-unavailable",\s*qpc\)') {
    throw 'Unavailable QPC timing must immediately terminate pre-arm fail closed.'
}

# Direct state queries and numeric W*V*P transpose gate.
foreach ($fragment in @(
    'device->GetVertexShader(&currentShader)',
    'device->GetTransform(D3DTS_WORLD, &world)',
    'device->GetTransform(D3DTS_VIEW, &view)',
    'device->GetTransform(D3DTS_PROJECTION, &projection)',
    'device->GetVertexShaderConstantF(',
    'MultiplyMatrix(world, view)',
    'MultiplyMatrix(worldView, projection)',
    'TransposeMatrix(worldViewProjection)',
    'CompareMatrices(constantMatrix, expectedConstants)',
    'kAbsoluteTolerance = 0.002f',
    'kRelativeTolerance = 0.00002f',
    'constantMatrix.m[2][3] - constantMatrix.m[3][3]',
    'std::fabs(nearDifference + kMainNearPlane) <= kMainNearTolerance',
    'const bool matrixMatch = comparison.finite && comparison.matches'
)) {
    if (-not $beforeDraw.Contains($fragment) -and -not $overlay.Contains($fragment)) {
        throw "RTX camera reassertion is missing direct-query/numeric invariant: $fragment"
    }
}

$numericGateIndex = $beforeDraw.IndexOf('if (!matrixMatch || !mainNearPlane)')
$firstReassertIndex = $beforeDraw.IndexOf(
    'originalSetTransform(device, D3DTS_WORLD, &world)')
if ($numericGateIndex -lt 0 -or $firstReassertIndex -le $numericGateIndex) {
    throw 'Unchanged transforms may be reasserted only after both the matrix and main-near numeric gates pass.'
}

# Passive shared-hook ownership and trampoline-only mutation boundary.
foreach ($fragment in @(
    'using SetTransformFn = HRESULT(WINAPI*)(',
    'static void AfterSetVertexShader(',
    'static void BeforeDraw(IDirect3DDevice9* device, SetTransformFn originalSetTransform)',
    'static void OnEndScene(IDirect3DDevice9* device)',
    'static void InstallRtxCameraReassertion(IDirect3DDevice9* device)',
    'originalSetTransform(device, D3DTS_WORLD, &world)',
    'originalSetTransform(device, D3DTS_VIEW, &view)',
    'originalSetTransform(device, D3DTS_PROJECTION, &projection)',
    'passiveObserver',
    'ownsHooks'
)) {
    if (-not $overlay.Contains($fragment)) {
        throw "RTX camera reassertion is missing passive observer API invariant: $fragment"
    }
}
if ($overlay -match 'HookHelper|\bMH_|\bvtable\b|ApplyHook\s*\(') {
    throw 'RTX camera reassertion must not own or duplicate CameraDiagnostics MinHook/vtable hooks.'
}
if ($beforeDraw -match 'device->SetTransform\s*\(') {
    throw 'BeforeDraw must use the passed original SetTransform callback, not the hooked device method.'
}
if ($overlay -match '(?:->|\boriginal)Draw(?:Indexed)?Primitive\s*\(') {
    throw 'The passive observer must never invoke either original draw path.'
}
if ($overlay -match '(?<!Get)SetVertexShaderConstantF\s*\(') {
    throw 'RTX camera reassertion must never write or replace shader constants.'
}

# The observer keeps its handle lifetime under one lock, so detailed events
# must be sampled rather than synchronously written for every candidate draw.
foreach ($fragment in @(
    'kInitialEventSamples = 16',
    'kPeriodicEventSampleInterval = 1024',
    'ShouldRecordOccurrenceLocked(s_ShaderStateDivergences)',
    'ShouldRecordOccurrenceLocked(s_QueryFailures)',
    'ShouldRecordOccurrenceLocked(s_NumericRejects)',
    'ShouldRecordOccurrenceLocked(s_ReassertAttempts)',
    'sampledOutEventRecords',
    'eventSampling'
)) {
    if (-not $overlay.Contains($fragment)) {
        throw "RTX camera reassertion is missing bounded hot-path sampling invariant: $fragment"
    }
}
if ($beforeDraw -match 'FlushFileBuffers\s*\(') {
    throw 'BeforeDraw must never force a synchronous filesystem flush.'
}

# Bounded lifecycle and durable runtime evidence.
foreach ($fragment in @(
    'kFrameLimit = 300',
    'kPreArmTimeoutSeconds = 300',
    'kEventRecordLimit = 16384',
    's_FrameNumber >= kFrameLimit',
    '++s_FrameNumber',
    's_Active = false',
    'WriteSummaryLocked("bounded-complete", "completed")',
    'FearMoreDiagnostics\\rtx-camera-reassertion-',
    'FearMore RTX camera reassertion: F7D91705-880 c0-c3,',
    '\"event\":\"capability\"',
    '\"event\":\"prearm\"',
    '\"event\":\"arm\"',
    '\"event\":\"timeout\"',
    '\"event\":\"query-failure\"',
    '\"event\":\"numeric-reject\"',
    '\"event\":\"reassert\"',
    '\"event\":\"summary\"',
    'setWorld',
    'setView',
    'setProjection',
    'droppedEventRecords'
)) {
    if (-not $overlay.Contains($fragment)) {
        throw "RTX camera reassertion is missing bounded proof invariant: $fragment"
    }
}
if ($onEndScene -notmatch 's_FrameNumber\s*<\s*kFrameLimit' -or
    $onEndScene -notmatch 'WriteSummaryLocked\("bounded-complete",\s*"completed"\)') {
    throw 'OnEndScene must terminate and summarize the experiment at exactly 300 frames.'
}

foreach ($fragment in @(
    '\"state\":\"prearm\"',
    '\"state\":\"armed\"',
    '\"state\":\"timeout\"',
    'const char* reason, const char* state',
    '\"state\":\"%s\"'
)) {
    if (-not $overlay.Contains($fragment)) {
        throw "RTX camera reassertion is missing lifecycle-state evidence: $fragment"
    }
}

[pscustomobject]@{
    Passed = $true
    ExecutableScope = 'FEAR v1.08 timestamp 44EF6AE6, x86 only'
    HookOwner = 'CameraDiagnostics/shared hub (observer owns zero hooks)'
    TargetShader = 'F7D91705 / 880 bytes / vs_1_1 / c0-c3'
    MatrixConvention = 'transpose(World * View * Projection)'
    NumericGates = 'Combined absolute/relative matrix tolerance plus near difference -4.3'
    ArmTrigger = 'First exact F7D91705 / 880-byte / vs_1_1 selection'
    PreArmTimeout = '300 seconds, QPC wall clock'
    PreArmProgress = '60 seconds, QPC wall clock'
    ActiveFrames = 300
    ShaderConstantWrites = 0
    RuntimeProof = 'FearMoreDiagnostics\rtx-camera-reassertion-<pid>.jsonl'
}
