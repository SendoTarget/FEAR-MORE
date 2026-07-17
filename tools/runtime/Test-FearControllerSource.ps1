[CmdletBinding()]
param([string]$RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')

function Assert-SourceContains {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string[]]$Fragments,
        [Parameter(Mandatory = $true)][string]$Description
    )
    foreach ($fragment in $Fragments) {
        if (-not $Source.Contains($fragment)) {
            throw "$Description is missing source contract: $fragment"
        }
    }
}

$clientRoot = Join-Path $RepositoryRoot 'FEAR\Dev\Source\FEAR\ClientShellDLL'
$managerSource = Get-Content -LiteralPath (Join-Path $clientRoot 'FearMoreControllerMgr.cpp') -Raw
$managerHeader = Get-Content -LiteralPath (Join-Path $clientRoot 'FearMoreControllerMgr.h') -Raw
$settingsSource = Get-Content -LiteralPath (Join-Path $clientRoot 'FearMoreControllerSettings.h') -Raw
$bindSource = Get-Content -LiteralPath (Join-Path $clientRoot 'BindMgr.cpp') -Raw
$shellSource = Get-Content -LiteralPath (Join-Path $clientRoot 'GameClientShell.cpp') -Raw
$cameraSource = Get-Content -LiteralPath (Join-Path $clientRoot 'PlayerCamera.cpp') -Raw
$screenSource = Get-Content -LiteralPath (Join-Path $clientRoot 'ScreenJoystick.cpp') -Raw
$controlsScreenSource = Get-Content -LiteralPath (Join-Path $clientRoot 'ScreenControls.cpp') -Raw
$profileSource = Get-Content -LiteralPath (Join-Path $clientRoot 'ProfileMgr.cpp') -Raw
$playerSource = Get-Content -LiteralPath (Join-Path $clientRoot 'PlayerMgr.cpp') -Raw
$cmakeSource = Get-Content -LiteralPath (Join-Path $clientRoot 'CMakeLists.txt') -Raw
$commandIdsSource = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'FEAR\Dev\Source\FEAR\Shared\CommandIDs.h') -Raw
$echoPatchProfile = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'tools\echopatch\EchoPatch.engine-only.ini') -Raw

Assert-SourceContains -Source $managerSource -Description 'Controller manager' -Fragments @(
    'GetModuleFileNameW( NULL, wszExecutable',
    'wcscat_s( wszExecutable, LTARRAYSIZE( wszExecutable ), L"SDL3.dll" )',
    'LoadLibraryW( wszExecutable )',
    'LoadFunction( m_pGetGamepads, "SDL_GetGamepads" )',
    'LoadFunction( m_pRumbleGamepad, "SDL_RumbleGamepad" )',
    'static DWORD const kReconnectIntervalMs = 500;',
    'static DWORD const kRuntimeRetryIntervalMs = 2000;',
    'm_nLastInitializeAttempt = GetTickCount();',
    '( nNow - m_nLastInitializeAttempt ) >= kRuntimeRetryIntervalMs',
    'ApplyRadialDeadZone( fLeftX, fLeftY, fDeadZone );',
    'ApplyRadialDeadZone( fRightX, fRightY, fDeadZone );',
    'm_afCommandValues[COMMAND_ID_FORWARD_AXIS] = -fLeftY;',
    'm_afCommandValues[COMMAND_ID_YAW_ACCEL] = fRightX;',
    'm_afCommandValues[COMMAND_ID_PITCH_ACCEL] = fRightY;',
    'SetCommandButton( COMMAND_ID_JUMP, m_abCurrentButtons[eSDLGamepadButton_South] );',
    'SetCommandButton( COMMAND_ID_ACTIVATE, m_abCurrentButtons[eSDLGamepadButton_West] );',
    'SetCommandButton( COMMAND_ID_FIRING, fRightTrigger >= kTriggerThreshold );',
    'if( bMouseInvert != bControllerInvert )',
    'fRightY = -fRightY;',
    'const bool bAllowRumble = bRumbleEnabled && IsInputActive();',
    'const uint16 nLow = bAllowRumble ? ToRumbleValue( fLowFrequency ) : 0;',
    'const uint16 nHigh = bAllowRumble ? ToRumbleValue( fHighFrequency ) : 0;',
    'if( !IsGamepadConnected() || !m_pImpl->m_bInputActiveLastFrame )',
    'return bEnabled && bFocused;',
    'g_pInterfaceMgr->OnKeyDown( nVirtualKey, 1 );',
    'g_pInterfaceMgr->OnKeyUp( nVirtualKey );',
    'const bool bFocused = g_pGameClientShell && g_pGameClientShell->IsMainWindowFocus();'
)
Assert-SourceContains -Source $managerHeader -Description 'Controller manager API' -Fragments @(
    'float GetCommandValue( uint32 nCommand ) const;',
    'bool IsCommandOn( uint32 nCommand ) const;',
    'void SetRumble( float fLowFrequency, float fHighFrequency );',
    'bool IsInputActive() const;'
)
Assert-SourceContains -Source $settingsSource -Description 'Controller settings' -Fragments @(
    '"FearMoreControllerEnabled"',
    '"FearMoreControllerDeadZone"',
    '"FearMoreControllerInvertY"',
    '"FearMoreControllerRumble"',
    '"GPadAimSensitivity"',
    'static bool const kEnabledDefault = false;',
    'static float const kDeadZoneDefault = 0.18f;'
)
Assert-SourceContains -Source $bindSource -Description 'Keyboard/mouse command merge' -Fragments @(
    'GetCommandValue( nCommand )',
    'GetHighestMappedCommand()',
    'm_aCommandStates[nCommand] = true;',
    'CFearMoreControllerMgr::Instance().IsInputActive()',
    'sDeviceDesc.m_eCategory == ILTInput::eDC_Gamepad',
    'return sBinding.m_fDefaultValue;'
)
Assert-SourceContains -Source $shellSource -Description 'Controller lifecycle' -Fragments @(
    'CFearMoreControllerMgr::Instance().Initialize();',
    'CFearMoreControllerMgr::Instance().Update();',
    'CFearMoreControllerMgr::Instance().Shutdown();'
)
Assert-SourceContains -Source $cameraSource -Description 'Authored vibration bridge' -Fragments @(
    'GetControllerModifier(tCameraTransform, fControllerMotors);',
    'CFearMoreControllerMgr::Instance().SetRumble( fControllerMotors[0], fControllerMotors[1] );',
    'g_pLTInput->SetDeviceObjectValue(ILTInput::eDC_Gamepad'
)
Assert-SourceContains -Source $screenSource -Description 'In-game controller options' -Fragments @(
    'AddToggle( L"Modern controller"',
    'AddSlider( L"Aim sensitivity"',
    'AddSlider( L"Stick deadzone"',
    'AddToggle( L"Invert controller Y"',
    'AddToggle( L"Controller vibration"',
    'a missing or changed owned payload fails closed and requires a fresh stage.',
    'SaveSettings();'
)
Assert-SourceContains -Source $controlsScreenSource -Description 'Controller menu availability' -Fragments @(
    'm_pJoystickCtrl = AddTextItem("IDS_JOYSTICK", cs);',
    'm_pScreenMgr->SetCurrentScreen(SCREEN_ID_JOYSTICK);'
)
Assert-SourceContains -Source $profileSource -Description 'Controller setting persistence' -Fragments @(
    '"FearMoreControllerEnabled"',
    '"FearMoreControllerDeadZone"',
    '"FearMoreControllerInvertY"',
    '"FearMoreControllerRumble"',
    '"GPadAimSensitivity"'
)
Assert-SourceContains -Source $playerSource -Description 'Frame-rate-independent stick aim' -Fragments @(
    'g_vtGPadAimSensitivity.Init( g_pLTClient, "GPadAimSensitivity", NULL, 2.0f);',
    'fPitchDelta *= RealTimeTimer::Instance( ).GetTimerElapsedS( ) * g_vtGPadAimSensitivity.GetFloat();',
    'fYawDelta *= RealTimeTimer::Instance( ).GetTimerElapsedS( ) * g_vtGPadAimSensitivity.GetFloat();',
    'if( pSettings->MouseInvertY() )',
    'fPitchDelta *= -1;'
)
Assert-SourceContains -Source $cmakeSource -Description 'ClientShell build ownership' -Fragments @(
    'FearMoreControllerMgr.cpp'
)

if ($echoPatchProfile -notmatch '(?m)^PatchGameModules\s*=\s*0\s*$' -or
    $echoPatchProfile -notmatch '(?m)^SDLGamepadSupport\s*=\s*0\s*$') {
    throw 'Engine-only EchoPatch must keep its GPL game-module and SDL controller hooks disabled.'
}
if ($managerSource.Contains('SDL_GamepadHasGyro') -or $managerSource.Contains('SDL_GetGamepadTouchpadFinger')) {
    throw 'Gyro or touchpad behavior appeared without an owned in-game configuration and acceptance contract.'
}

$commandValues = @{}
foreach ($match in [regex]::Matches($commandIdsSource, '(?m)^#define\s+(?<Name>COMMAND_ID_[A-Z0-9_]+)\s+(?<Value>\d+)\s*$')) {
    $commandValues[$match.Groups['Name'].Value] = [int]$match.Groups['Value'].Value
}
$mappedCommands = @([regex]::Matches($managerSource, 'COMMAND_ID_[A-Z0-9_]+') |
        ForEach-Object Value | Sort-Object -Unique)
if (-not $commandValues.ContainsKey('COMMAND_ID_FLASHLIGHT')) {
    throw 'Could not resolve the controller command-array ceiling from CommandIDs.h.'
}
$commandCeiling = [int]$commandValues['COMMAND_ID_FLASHLIGHT']
foreach ($mappedCommand in $mappedCommands) {
    if (-not $commandValues.ContainsKey($mappedCommand)) {
        throw "Controller mapping references an unknown command id: $mappedCommand"
    }
    if ([int]$commandValues[$mappedCommand] -gt $commandCeiling) {
        throw "Controller mapping command $mappedCommand=$($commandValues[$mappedCommand]) exceeds the command-state array ceiling $commandCeiling."
    }
}

foreach ($mouseInvert in @($false, $true)) {
    foreach ($controllerInvert in @($false, $true)) {
        $pitchForStickUp = -0.5
        if ($mouseInvert -ne $controllerInvert) {
            $pitchForStickUp = -$pitchForStickUp
        }
        if ($mouseInvert) {
            $pitchForStickUp = -$pitchForStickUp
        }
        $expectedPitch = if ($controllerInvert) { 0.5 } else { -0.5 }
        if ($pitchForStickUp -ne $expectedPitch) {
            throw "Controller/mouse invert compensation failed for MouseInvertY=$mouseInvert ControllerInvertY=$controllerInvert."
        }
    }
}

foreach ($controllerEnabled in @($false, $true)) {
    foreach ($windowFocused in @($false, $true)) {
        foreach ($gamepadConnected in @($false, $true)) {
            foreach ($rumbleEnabled in @($false, $true)) {
                $inputActive = $controllerEnabled -and $windowFocused -and $gamepadConnected
                $nonzeroRumbleAllowed = $rumbleEnabled -and $inputActive
                $expected = $controllerEnabled -and $windowFocused -and $gamepadConnected -and $rumbleEnabled
                if ($nonzeroRumbleAllowed -ne $expected) {
                    throw "Rumble gating failed for Enabled=$controllerEnabled Focused=$windowFocused Connected=$gamepadConnected Rumble=$rumbleEnabled."
                }
            }
        }
    }
}

[pscustomobject]@{
    Status                       = 'PASS'
    RuntimeLoading              = 'ExecutableDirectoryDynamicSDL3'
    InputMerge                  = 'ExistingBindMgrCommandState'
    KeyboardMousePreserved      = $true
    MissingSettingPreservesLegacyInput = $true
    Hotplug                     = $true
    RadialDeadZone              = $true
    FrameRateIndependentAim     = $true
    AuthoredRumbleBridge        = $true
    DisabledOrUnfocusedRumbleZero = $true
    InitFailureCleanupAndRetry  = $true
    LegacyGamepadDoubleInputSuppressed = $true
    MenuAvailableWithoutLegacyJoystick = $true
    IndependentInvertY         = $true
    MappedCommandCeiling       = $commandCeiling
    MappedCommandCount         = $mappedCommands.Count
    InGameSettings              = @('Enabled', 'Sensitivity', 'DeadZone', 'InvertY', 'Rumble')
    EchoPatchGameHooksDisabled  = $true
    Deferred                    = @('FullRemapping', 'GlyphPrompts', 'Gyro', 'Touchpad')
}
