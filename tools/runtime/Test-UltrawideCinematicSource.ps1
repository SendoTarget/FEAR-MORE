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
        throw "Ultrawide cinematic source input is missing: $path"
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

function Get-ConstrainedGeometry {
    param(
        [Parameter(Mandatory = $true)][double]$Width,
        [Parameter(Mandatory = $true)][double]$Height,
        [double]$MaxAspect = (16.0 / 9.0)
    )

    $contentWidth = $Width
    if ($Width -gt (($Height * $MaxAspect) + 0.5)) {
        $contentWidth = $Height * $MaxAspect
    }

    $side = ($Width - $contentWidth) * 0.5
    return [pscustomobject]@{
        Left = [Math]::Round($side, 6)
        Content = [Math]::Round($contentWidth, 6)
        Right = [Math]::Round($side, 6)
    }
}

$interfaceResHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\InterfaceResMgr.h'
$interfaceRes = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\InterfaceResMgr.cpp'
$interfaceMgrHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\InterfaceMgr.h'
$interfaceMgr = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\InterfaceMgr.cpp'
$playerCameraHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\PlayerCamera.h'
$playerCamera = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\PlayerCamera.cpp'
$cameraProbeHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreCameraProbe.h'
$cameraProbe = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreCameraProbe.cpp'

if ($interfaceResHeader -notmatch 'GetAspectConstrainedRect') {
    throw 'The shared centered-aspect primitive is not declared.'
}

$aspectHelper = Get-SourceSection $interfaceRes `
    'void CInterfaceResMgr::GetAspectConstrainedRect' `
    'void CInterfaceResMgr::GetHUDSafeAreaTransform' `
    'GetAspectConstrainedRect'
Assert-LiteralsInOrder $aspectHelper @(
    'constrainedBounds = screenBounds;',
    'fMaxAspect <= 0.0f',
    'const float fConstrainedWidth = fHeight * fMaxAspect;',
    'if (fWidth <= fConstrainedWidth + 0.5f)',
    'const float fHorizontalInset = (fWidth - fConstrainedWidth) * 0.5f;',
    'constrainedBounds.m_vMin.x += fHorizontalInset;',
    'constrainedBounds.m_vMax.x -= fHorizontalInset;'
) 'The shared centered-aspect geometry changed unexpectedly.'

$hudSafeArea = Get-SourceSection $interfaceRes `
    'void CInterfaceResMgr::GetHUDSafeAreaTransform' `
    '#define USABLE_HEIGHT_I' `
    'GetHUDSafeAreaTransform'
Assert-LiteralsInOrder $hudSafeArea @(
    'if (s_vtHUDSafeAreaFullWidth.GetFloat() != 0.0f)',
    'GetAspectConstrainedRect(screenBounds, kHUDSafeAreaMaxAspect, safeBounds);',
    'safeScale.x *= fSafeWidth / fWidth;'
) 'The HUD no longer reuses the shared aspect primitive with its legacy override.'

$cinematicUpdate = Get-SourceSection $playerCamera `
    'bool CPlayerCamera::UpdateCinematicCameras()' `
    '// ----------------------------------------------------------------------- //' `
    'UpdateCinematicCameras'
Assert-LiteralsInOrder $cinematicUpdate @(
    'g_pInterfaceMgr->SetLetterBox( (pCamFX->GetType() == CT_LETTERBOX) );',
    'g_pInterfaceResMgr->GetScreenFOV',
    'g_pLTClient->SetCameraFOV'
) 'Authored cinematic type and the established Hor+ camera projection are no longer preserved.'

$playerCameraUpdate = Get-SourceSection $playerCamera `
    'void CPlayerCamera::Update( )' `
    '// ----------------------------------------------------------------------- //' `
    'CPlayerCamera::Update'
Assert-LiteralsInOrder $playerCameraUpdate @(
    'const bool bLiveCinematicCamera = UpdateCinematicCameras( );',
    'UpdateScriptedLureCinematicSideMask( bLiveCinematicCamera );'
) 'The scripted-lure framing decision no longer follows the live CameraFX decision.'

if ($interfaceMgrHeader -notmatch 'void\s+SetLetterBox\(bool b\) \{ m_bLetterBox = b; \}' -or
    $interfaceMgrHeader -notmatch 'void\s+SetCinematicSideMask\(bool b\) \{ m_bCinematicSideMask = b; \}' -or
    $playerCameraHeader -notmatch 'void UpdateScriptedLureCinematicSideMask\( bool bLiveCinematicCamera \);') {
    throw 'Letterbox and scripted-lure side-mask ownership are no longer exposed as independent states.'
}

$scriptedLureMask = Get-SourceSection $playerCamera `
    'void CPlayerCamera::UpdateScriptedLureCinematicSideMask' `
    '// ----------------------------------------------------------------------- //' `
    'UpdateScriptedLureCinematicSideMask'
Assert-LiteralsInOrder $scriptedLureMask @(
    'pVehicleMgr->IsVehiclePhysics()',
    'PlayerLureFX::GetPlayerLureFX(',
    'diagnosticState.m_bPlayingSpecial = CPlayerBodyMgr::Instance().IsPlayingSpecial();',
    'diagnosticState.m_bAuthoredCrosshairEnabled = !g_pCrosshair || g_pCrosshair->IsEnabled();',
    'm_hTarget && !bLiveCinematicCamera && pPlayerLureFX &&',
    'diagnosticState.m_bPlayingSpecial && !diagnosticState.m_bAuthoredCrosshairEnabled',
    'g_pInterfaceMgr->SetCinematicSideMask( diagnosticState.m_bSideMaskRequested );',
    'FearMoreCameraProbe::RecordCinematicSideMaskState( diagnosticState );'
) 'The scripted-lure mask no longer requires a valid lure, special animation, and authored crosshair-off state while excluding live CameraFX.'
$sideMaskRequest = [regex]::Match(
    $scriptedLureMask,
    '(?s)diagnosticState\.m_bSideMaskRequested\s*=\s*(?<Expression>.*?);')
if (-not $sideMaskRequest.Success) {
    throw 'The scripted-lure side-mask request expression could not be isolated.'
}
$sideMaskRequestExpression = $sideMaskRequest.Groups['Expression'].Value
if ($scriptedLureMask -match 'DisableCrosshair|CanShowCrosshair' -or
    $sideMaskRequestExpression -match 'GetAllowWeapon|GetAllowSwitchWeapon|m_bAllowWeapon|m_bAllowSwitchWeapon') {
    throw 'Scripted-lure framing must use the authored crosshair message state, not user/transient crosshair state or lure weapon-policy heuristics.'
}

$letterbox = Get-SourceSection $interfaceMgr `
    'void CInterfaceMgr::UpdateLetterBox()' `
    '// --------------------------------------------------------------------------- //' `
    'UpdateLetterBox'
Assert-LiteralsInOrder $letterbox @(
    'const bool bLetterBoxDisabled',
    'const bool bAuthoredLetterBox = (!bLetterBoxDisabled && m_bLetterBox);',
    'const bool bScriptedCinematicSideMask = (!bLetterBoxDisabled && m_bCinematicSideMask);',
    'if (bAuthoredLetterBox)',
    'if (!bOn && m_fLetterBoxAlpha <= 0.0f)',
    'if (!bScriptedCinematicSideMask)',
    'if (m_bAuthoredLetterBoxMask || bScriptedCinematicSideMask)',
    'GetAspectConstrainedRect(rScreenBounds, 16.0f / 9.0f, rCinematicBounds);',
    'DrawPrimSetRGBA(Quad, 0, 0, 0, 255);',
    'rCinematicBounds.m_vMin.x + fBuffer',
    '(float)dwWidth - rCinematicBounds.m_vMax.x + fBuffer'
) 'Authored letterbox side masks no longer use immediate opaque shared-aspect geometry.'

if ($letterbox -match 'GetCameraMode\s*\(') {
    throw 'Cinematic masking must remain owned by the authored letterbox flag, not all cinematic camera modes.'
}

if ($cameraProbeHeader -notmatch 'void RecordCinematicSideMaskState\( const CinematicSideMaskState& state \);' -or
    $cameraProbe -notmatch '(?s)void RecordCinematicSideMaskState\(.*s_CameraDiagnosticsEnabled\.GetFloat\(\) <= 0\.0f.*m_bSideMaskStateKnown = false;.*m_bLastSideMaskRequested == state\.m_bSideMaskRequested.*return;.*FearMore cinematic framing: side_mask=') {
    throw 'Scripted-lure diagnostics are no longer opt-in and edge-triggered through FearMoreCameraDiagnostics.'
}

$movieUpdate = Get-SourceSection $interfaceMgr `
    'void CInterfaceMgr::UpdateMovieState()' `
    '// ----------------------------------------------------------------------- //' `
    'UpdateMovieState'
Assert-LiteralsInOrder $movieUpdate @(
    'uint32 nWidth = nScreenWidth;',
    'uint32 nHeight = nWidth * vnVideoDims.y / vnVideoDims.x;',
    'if(nHeight > nScreenHeight)',
    'nWidth  = nHeight * vnVideoDims.x / vnVideoDims.y;',
    'DrawPrimSetXYWH(Quad, (nScreenWidth - nWidth) * 0.5f, (nScreenHeight - nHeight) * 0.5f'
) 'The existing centered, aspect-preserving pre-rendered movie path changed unexpectedly.'
if ($movieUpdate -match 'GetAspectConstrainedRect|bAuthoredLetterBox') {
    throw 'The real-time cinematic mask must not enter the pre-rendered movie path.'
}

$geometry3440 = Get-ConstrainedGeometry -Width 3440 -Height 1440
$geometry1920 = Get-ConstrainedGeometry -Width 1920 -Height 1080
$geometry5120 = Get-ConstrainedGeometry -Width 5120 -Height 1440

if ($geometry3440.Left -ne 440 -or $geometry3440.Content -ne 2560 -or $geometry3440.Right -ne 440) {
    throw "3440x1440 geometry is incorrect: $($geometry3440 | ConvertTo-Json -Compress)"
}
if ($geometry1920.Left -ne 0 -or $geometry1920.Content -ne 1920 -or $geometry1920.Right -ne 0) {
    throw "1920x1080 must retain its full frame: $($geometry1920 | ConvertTo-Json -Compress)"
}
if ($geometry5120.Left -ne 1280 -or $geometry5120.Content -ne 2560 -or $geometry5120.Right -ne 1280) {
    throw "5120x1440 geometry is incorrect: $($geometry5120 | ConvertTo-Json -Compress)"
}

[pscustomobject]@{
    Status = 'PASS'
    SharedAspectPrimitiveVerified = $true
    GameplayHorPlusPreserved = $true
    FullscreenCamerasPreserved = $true
    ScriptedLureGateVerified = $true
    InteractiveLureGatePreservedStatically = $true
    DiagnosticEdgesOnly = $true
    FmvAspectFitPreserved = $true
    LetterBoxDisabledPreserved = $true
    Geometry3440x1440 = $geometry3440
    Geometry5120x1440 = $geometry5120
    RuntimeLaunched = $false
    Note = 'Static source and geometry invariants only. A separate 3440x1440 Modern 2x + CAS replay passed the ATC_Roof composition and teardown; Native, campaign-entry, skip/restart, and unrelated-cinematic live checks remain open.'
}
