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
        throw "Camera probe source input is missing: $path"
    }

    return Get-Content -LiteralPath $path -Raw
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

$probeHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreCameraProbe.h'
$probeSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreCameraProbe.cpp'
$playerCamera = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\PlayerCamera.cpp'
$clientCMake = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\CMakeLists.txt'

if ($probeSource -notmatch 's_CameraDiagnosticsEnabled\.Init\(\s*g_pLTClient\s*,\s*kDiagnosticsCVar\s*,\s*NULL\s*,\s*0\.0f\s*\)') {
    throw 'FearMoreCameraDiagnostics is no longer initialized disabled by default.'
}
if ($probeSource -notmatch 'kMaxCapturedFrames\s*=\s*3600\s*;' -or
    $probeSource -notmatch 'm_nFrameCount\s*>=\s*kMaxCapturedFrames') {
    throw 'The source camera probe no longer has its 3,600-main-frame safety bound.'
}
if ($probeSource -notmatch '(?s)const bool bDiagnosticsEnabled.*if\( !bDiagnosticsEnabled \).*m_bDiagnosticsWasEnabled && m_Output\.is_open\(\).*m_Output\.flush\(\).*m_bDiagnosticsWasEnabled = false;.*return token;.*m_bDiagnosticsWasEnabled = true;') {
    throw 'The source camera probe no longer flushes one final partial batch when diagnostics are disabled without truncating on re-enable.'
}
if ($probeSource -notmatch 'fearmore\.camera-source\\\",\\\"version\\\":2') {
    throw 'The source camera schema version was not advanced for the projection-probe field split.'
}

Assert-LiteralsInOrder $probeSource @(
    'GetAbsoluteUserFileName(',
    'kDiagnosticsDirectory, szDiagnosticsDirectory,',
    'CWinUtil::CreateDir( szDiagnosticsDirectory )',
    '"%s\\camera-source-%lu.jsonl"',
    'std::ios::out | std::ios::trunc'
) 'Camera diagnostics output is no longer rooted in the isolated UserDirectory.'

foreach ($requiredToken in @(
    'fearmore.camera-source',
    'qpc_before',
    'qpc_after',
    'render_result',
    'rotation_xyzw',
    'basis',
    'fov_radians',
    'viewport_normalized',
    'render_target',
    'near_z',
    'far_z',
    'pixel_double',
    'WorldPosToScreenPos(',
    'screen_normalized_xy',
    'camera_z'
)) {
    if (-not $probeSource.Contains($requiredToken)) {
        throw "Camera diagnostics evidence field is missing: $requiredToken"
    }
}

if ($probeSource.Contains('\"screen_normalized\":')) {
    throw 'Projection probe schema still conflates normalized screen XY with camera-space Z.'
}
Assert-LiteralsInOrder $probeSource @(
    '<< ",\"screen_normalized_xy\":";',
    'WriteJsonFloat( output, probe.m_vScreen.x );',
    'WriteJsonFloat( output, probe.m_vScreen.y );',
    'output << ",\"camera_z\":";',
    'WriteJsonFloat( output, probe.m_vScreen.z );'
) 'Projection probe schema no longer writes normalized XY separately from camera depth.'

if ($probeSource -match 'IDirect3D|d3d9\.h|GetDirect3D') {
    throw 'The source camera probe must stay on supported client/renderer interfaces, not fragile D3D access.'
}

$renderStart = $playerCamera.IndexOf('void CPlayerCamera::RenderCamera( )', [StringComparison]::Ordinal)
$renderEnd = $playerCamera.IndexOf('// ----------------------------------------------------------------------- //', $renderStart + 1, [StringComparison]::Ordinal)
if ($renderStart -lt 0 -or $renderEnd -lt 0) {
    throw 'CPlayerCamera::RenderCamera could not be isolated for ownership verification.'
}
$renderCamera = $playerCamera.Substring($renderStart, $renderEnd - $renderStart)

Assert-LiteralsInOrder $renderCamera @(
    'UpdateRenderTarget();',
    'g_pLTRenderer->SetRenderTarget( m_hRenderTarget );',
    'ClearRenderTarget( CLEARRTARGET_ALL, 0 );',
    'FearMoreCameraProbe::BeginMainCameraRender(',
    'g_pLTClient->GetRenderer()->RenderCamera( m_hCamera );',
    'FearMoreCameraProbe::EndMainCameraRender(',
    'g_pLTRenderer->StretchRect(',
    'g_pLTRenderer->SetRenderTargetScreen( );'
) 'The probe no longer brackets only the authoritative main-camera render while preserving target handling.'

if (@($clientCMake -split "`n" | Where-Object { $_ -match '^\s*FearMoreCameraProbe\.cpp\s*$' }).Count -ne 1) {
    throw 'ClientShell must compile the focused camera probe implementation exactly once.'
}
if ($probeHeader -notmatch 'CameraRenderToken BeginMainCameraRender' -or
    $probeHeader -notmatch 'void EndMainCameraRender') {
    throw 'The camera probe module no longer exposes the bounded begin/end seam.'
}

[pscustomobject]@{
    Status = 'PASS'
    DefaultOffVerified = $true
    FrameLimit = 3600
    SourceSchemaVersion = 2
    ProjectionDepthSeparated = $true
    DisableEdgeFlushVerified = $true
    StageLocalUserDirectoryVerified = $true
    AuthoritativeRenderBracketVerified = $true
    SupportedRendererInterfacesOnly = $true
    RuntimeLaunched = $false
    Note = 'Static ownership/schema verification only; a rebuilt Native or Modern runtime capture is still required.'
}
