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
$sourcePath = Join-Path $RepositoryRoot 'tools\echopatch\overlays\CameraDiagnostics.cpp'
$patchPath = Join-Path $RepositoryRoot 'patches\echopatch\0004-add-camera-diagnostics.patch'
$overridePath = Join-Path $RepositoryRoot 'tools\echopatch\EchoPatch.camera-diagnostics.override.ini'
$buildPath = Join-Path $RepositoryRoot 'tools\echopatch\Build-EngineOnlyEchoPatch.ps1'

foreach ($required in @($sourcePath, $patchPath, $overridePath, $buildPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Camera diagnostics source input is missing: $required"
    }
}

$source = Get-Content -LiteralPath $sourcePath -Raw
$patch = Get-Content -LiteralPath $patchPath -Raw
$override = Get-Content -LiteralPath $overridePath -Raw
$build = Get-Content -LiteralPath $buildPath -Raw

function Get-SourceSegment {
    param(
        [Parameter(Mandatory = $true)][string]$StartPattern,
        [Parameter(Mandatory = $true)][string]$NextPattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $match = [regex]::Match($source, "(?s)$StartPattern.*?(?=$NextPattern)")
    if (-not $match.Success) {
        throw "Unable to isolate $Description in CameraDiagnostics.cpp."
    }
    return $match.Value
}

if ($source -notmatch '(?s)shader->AddRef\(\);\s*s_ShaderCache\[s_ShaderCount\]\.pointer\s*=\s*shader;' -or
    $source -notmatch '(?s)static void ReleaseShaderCache\(\).*?s_ShaderCache\[index\]\.pointer->Release\(\);' -or
    $source -notmatch '(?s)ResetFrameCounters\(\);.*?if \(s_Frame\.frameNumber == kFrameLimit\).*?ReleaseShaderCache\(\);') {
    throw 'Shader identity caching must retain each bounded COM object and release it at the capture bound.'
}
if ($source -match '->Get(?:VertexShader|Transform|VertexShaderConstantF)\s*\(') {
    throw 'The setter-only probe must not issue synchronous D3D9 state queries.'
}
$endSceneSegment = Get-SourceSegment `
    -StartPattern 'static HRESULT WINAPI EndSceneHook\b' `
    -NextPattern 'static HRESULT WINAPI SetTransformHook\b' `
    -Description 'EndScene hook'
if ([regex]::Matches($source, 'SourceCameraLogIsReady\(\)').Count -ne 2 -or
    $endSceneSegment -notmatch '(?s)if \(!s_CaptureArmed\).*?SourceCameraLogIsReady\(\).*?ArmCapture\(\).*?return result;' -or
    $source -notmatch 'camera-source-%lu\.jsonl' -or
    $source -notmatch 'same-pid-source-camera-log-at-end-scene') {
    throw 'Capture arming must check only the same-PID source-camera file from EndScene.'
}
if ($source -notmatch 'GetProcessTimes\s*\(' -or
    $source -notmatch 'CompareFileTime\(&attributes\.ftLastWriteTime, &s_ProcessStartTime\)' -or
    $source -notmatch 'FILE_ATTRIBUTE_DIRECTORY \| FILE_ATTRIBUTE_REPARSE_POINT') {
    throw 'The same-PID arm signal must reject stale, directory, and reparse-point source logs.'
}
if ($source -notmatch [regex]::Escape('{\"event\":\"arm\"') -or
    $source -notmatch [regex]::Escape('\"armed\":false') -or
    $source -notmatch [regex]::Escape('\"armCheckScope\":\"end-scene-only-until-armed\"') -or
    $source -notmatch [regex]::Escape('\"captureStarts\":\"next-frame\"')) {
    throw 'The capability and explicit arm event must describe the next-frame arming policy.'
}

$captureGateSegments = [ordered]@{
    SetRenderTarget = Get-SourceSegment 'static HRESULT WINAPI SetRenderTargetHook\b' 'static HRESULT WINAPI EndSceneHook\b' 'SetRenderTarget hook'
    EndScene = $endSceneSegment
    SetTransform = Get-SourceSegment 'static HRESULT WINAPI SetTransformHook\b' 'static HRESULT WINAPI SetViewportHook\b' 'SetTransform hook'
    SetViewport = Get-SourceSegment 'static HRESULT WINAPI SetViewportHook\b' 'static void CountDraw\b' 'SetViewport hook'
    CountDraw = Get-SourceSegment 'static void CountDraw\b' 'static HRESULT WINAPI DrawPrimitiveHook\b' 'draw counter'
    SetVertexShader = Get-SourceSegment 'static HRESULT WINAPI SetVertexShaderHook\b' 'static HRESULT WINAPI SetVertexShaderConstantFHook\b' 'SetVertexShader hook'
    SetVertexShaderConstantF = Get-SourceSegment 'static HRESULT WINAPI SetVertexShaderConstantFHook\b' 'template <typename TFunction>' 'SetVertexShaderConstantF hook'
}
foreach ($entry in $captureGateSegments.GetEnumerator()) {
    if ($entry.Value -notmatch 'IsCaptureActiveLocked\(\)') {
        throw "$($entry.Key) performs diagnostic work without the bounded armed-capture gate."
    }
}
$drawPrimitiveSegment = Get-SourceSegment 'static HRESULT WINAPI DrawPrimitiveHook\b' 'static HRESULT WINAPI DrawIndexedPrimitiveHook\b' 'DrawPrimitive hook'
$drawIndexedSegment = Get-SourceSegment 'static HRESULT WINAPI DrawIndexedPrimitiveHook\b' 'static HRESULT WINAPI SetVertexShaderHook\b' 'DrawIndexedPrimitive hook'
if ($drawPrimitiveSegment -notmatch 'CountDraw\(primitiveCount\)' -or
    $drawIndexedSegment -notmatch 'CountDraw\(primitiveCount\)') {
    throw 'Both draw hooks must delegate telemetry to the armed CountDraw gate.'
}
$drawDiagnosticSegments = $captureGateSegments.CountDraw + $drawPrimitiveSegment + $drawIndexedSegment
if ($drawDiagnosticSegments -match '(?:GetFileAttributes|GetDesc|GetFunction|CreateFile|WriteFile|SourceCameraLogIsReady)\s*\(') {
    throw 'Draw hooks must not issue filesystem or device-state queries.'
}
if ([regex]::Matches($source, '->GetFunction\s*\(').Count -ne 2 -or
    $source -notmatch '(?s)SetVertexShaderHook.*?ObserveShader\(shader\)') {
    throw 'Shader bytecode queries must remain bounded to first observation from SetVertexShader.'
}
if ($source -notmatch 'const uint8_t\* bytes' -or $source -notmatch 'fnv1a32-unsigned-byte') {
    throw 'Shader and constant identities must use deterministic unsigned-byte FNV-1a.'
}
if ($source -notmatch 'camera-d3d9-%lu\.constants\.f32bin' -or
    $source -notmatch 'WriteConstantPayload\(constantData, vector4Count, payloadOffset, payloadBytes\)' -or
    $source -notmatch 'payloadEncoding\\\":\\\"ieee754-f32le' -or
    $source -notmatch 'boundedConstantPayloadBytes\\\":%u' -or
    $source -notmatch 'kMaximumConstantPayloadBytes = 32 \* 1024 \* 1024') {
    throw 'Sampled register ranges must retain exact, bounded full-range float payloads outside the JSON preview.'
}
if ($source -notmatch 'kShapeBurstSampleLimit = 8' -or
    $source -notmatch 'kShapeSampleLimit = 32' -or
    $source -notmatch 'kShapeSampleIntervalFrames = 150' -or
    $source -notmatch 'shape\.hasLastValueHash && shape\.lastValueHash == valueHash') {
    throw 'Constant sampling must preserve changed-value burst diversity and later capture-window coverage.'
}
if ($source -match '(?i)clipRegister|cameraRegister|c72') {
    throw 'The observation lane must not assign camera meaning to a shader register.'
}
if ($source -notmatch [regex]::Escape('FearMoreDiagnostics\\camera-d3d9-') -or
    $source -notmatch 'registerAssumptions\\":false' -or $source -notmatch 'mirrorsState\\":false') {
    throw 'The diagnostic capability/proof contract is incomplete.'
}
if ($override -notmatch '(?m)^CameraDiagnostics\s*=\s*1\s*$' -or
    $override -match '(?m)^RemixCameraDiagnostics\s*=\s*1\s*$') {
    throw 'The query-light INI override must enable only CameraDiagnostics.'
}
if ($patch -notmatch 'EnableCameraDiagnostics' -or $patch -match 'EnableRemixCameraDiagnostics') {
    throw 'The camera patch must remain independent from the Remix diagnostics patch.'
}
if ($patch -notmatch 'ReadInteger\("Diagnostics", "CameraDiagnostics", 0\)' -or
    $source -notmatch 'if \(!EnableCameraDiagnostics \|\| !device\)') {
    throw 'Camera diagnostics must remain default-off in both configuration and device installation.'
}
if ($build -notmatch '\[switch\]\$CameraDiagnostics' -or
    $build -notmatch 'CameraDiagnosticEchoPatch' -or
    $build -notmatch 'echopatch-camera-diagnostics' -or
    $build -notmatch '\$RemixCameraDiagnostics -and \$CameraDiagnostics') {
    throw 'The build script no longer preserves the isolated camera package identity or mutual exclusion guard.'
}
$cameraManifestFields = @(
    'packageMode',
    'cameraDiagnostics',
    'cameraDiagnosticsProof',
    'cameraDiagnosticsPatchSha256',
    'cameraDiagnosticsOverlaySha256',
    'profileBaseSha256',
    'profileOverrideSha256'
)
foreach ($field in $cameraManifestFields) {
    if ($build -notmatch [regex]::Escape("`$manifest.$field")) {
        throw "The camera package manifest no longer records the required $field field."
    }
}

[pscustomobject]@{
    Passed = $true
    ShaderPointerLifetime = 'AddRef through bounded capture; released at frame 3600'
    PerDrawDeviceQueries = $false
    RegisterAssumptions = $false
    FullRangePayloads = 'Exact f32le sidecar; 32 MiB bound'
    Sampling = '8 changed-value burst; 32 samples per shape; 150-frame later cadence'
    Arming = 'Same-PID fresh source log, checked only at EndScene; capture starts next frame'
    FrontendBudgetConsumed = $false
    PackageMode = 'CameraDiagnosticEchoPatch'
}
