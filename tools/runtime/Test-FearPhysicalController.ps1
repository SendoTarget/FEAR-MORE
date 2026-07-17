[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$StageRoot,
    [ValidateRange(0, 60)][double]$SampleSeconds = 2,
    [ValidateRange(0, 5000)][int]$RumbleMilliseconds = 0,
    [switch]$RequireInputActivity
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$StageRoot = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\')

# F.E.A.R. and its validated SDL payload are x86.  Relaunch this acceptance
# probe under the inbox x86 PowerShell host so it exercises the exact DLL that
# the rebuilt client loads instead of introducing a second architecture.
if ([Environment]::Is64BitProcess) {
    $x86PowerShell = Join-Path $env:WINDIR 'SysWOW64\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $x86PowerShell -PathType Leaf)) {
        throw "The x86 Windows PowerShell host is unavailable: $x86PowerShell"
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath,
        '-RepositoryRoot', $RepositoryRoot,
        '-StageRoot', $StageRoot,
        '-SampleSeconds', $SampleSeconds.ToString([Globalization.CultureInfo]::InvariantCulture),
        '-RumbleMilliseconds', $RumbleMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)
    )
    if ($RequireInputActivity) {
        $arguments += '-RequireInputActivity'
    }

    & $x86PowerShell @arguments
    exit $LASTEXITCODE
}

$controllerModule = Join-Path $PSScriptRoot 'FearControllerPackage.psm1'
Import-Module $controllerModule -Force -ErrorAction Stop
$metadata = Get-FearControllerPackageMetadata

$runtimePath = Join-Path $StageRoot 'SDL3.dll'
if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) {
    throw "The staged SDL3 runtime is missing: $runtimePath"
}
$runtimeItem = Get-Item -LiteralPath $runtimePath
$runtimeHash = (Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash
if ($runtimeItem.Length -ne $metadata.RuntimeSize -or $runtimeHash -cne $metadata.RuntimeSha256) {
    throw "The staged SDL3 runtime does not match the pinned controller package identity: $runtimePath"
}

if (-not ('FearMorePhysicalControllerProbeNative' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FearMorePhysicalControllerProbeNative
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool SetDllDirectory(string path);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SDL_InitSubSystem(UInt32 flags);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void SDL_QuitSubSystem(UInt32 flags);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr SDL_GetGamepads(out Int32 count);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr SDL_OpenGamepad(UInt32 instanceId);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void SDL_CloseGamepad(IntPtr gamepad);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SDL_GamepadConnected(IntPtr gamepad);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void SDL_UpdateGamepads();

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern Int16 SDL_GetGamepadAxis(IntPtr gamepad, Int32 axis);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SDL_GetGamepadButton(IntPtr gamepad, Int32 button);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SDL_RumbleGamepad(
        IntPtr gamepad,
        UInt16 lowFrequency,
        UInt16 highFrequency,
        UInt32 durationMilliseconds);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr SDL_GetGamepadName(IntPtr gamepad);

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr SDL_GetError();

    [DllImport("SDL3.dll", CallingConvention = CallingConvention.Cdecl)]
    public static extern void SDL_free(IntPtr memory);
}
'@
}

function Get-SdlError {
    $errorPointer = [FearMorePhysicalControllerProbeNative]::SDL_GetError()
    if ($errorPointer -eq [IntPtr]::Zero) {
        return 'unknown SDL error'
    }
    return [Runtime.InteropServices.Marshal]::PtrToStringAnsi($errorPointer)
}

$axisNames = @('LeftX', 'LeftY', 'RightX', 'RightY', 'LeftTrigger', 'RightTrigger')
$buttonNames = @(
    'South', 'East', 'West', 'North', 'Back', 'Guide', 'Start',
    'LeftStick', 'RightStick', 'LeftShoulder', 'RightShoulder',
    'DPadUp', 'DPadDown', 'DPadLeft', 'DPadRight'
)
$sdlInitGamepad = [uint32]0x00002000
$gamepad = [IntPtr]::Zero
$gamepadList = [IntPtr]::Zero
$subsystemInitialized = $false

if (-not [FearMorePhysicalControllerProbeNative]::SetDllDirectory($StageRoot)) {
    throw "Could not add the validated stage to the process DLL search path: $StageRoot"
}

try {
    if (-not [FearMorePhysicalControllerProbeNative]::SDL_InitSubSystem($sdlInitGamepad)) {
        throw "SDL gamepad subsystem initialization failed: $(Get-SdlError)"
    }
    $subsystemInitialized = $true

    $gamepadCount = 0
    $gamepadList = [FearMorePhysicalControllerProbeNative]::SDL_GetGamepads([ref]$gamepadCount)
    if ($gamepadCount -lt 1 -or $gamepadList -eq [IntPtr]::Zero) {
        throw "SDL found no connected gamepads: $(Get-SdlError)"
    }

    $instanceId = [uint32][Runtime.InteropServices.Marshal]::ReadInt32($gamepadList)
    $gamepad = [FearMorePhysicalControllerProbeNative]::SDL_OpenGamepad($instanceId)
    if ($gamepad -eq [IntPtr]::Zero) {
        throw "SDL could not open gamepad instance $instanceId`: $(Get-SdlError)"
    }

    $namePointer = [FearMorePhysicalControllerProbeNative]::SDL_GetGamepadName($gamepad)
    $gamepadName = if ($namePointer -eq [IntPtr]::Zero) {
        'Unknown SDL gamepad'
    }
    else {
        [Runtime.InteropServices.Marshal]::PtrToStringAnsi($namePointer)
    }

    $axisMinimum = @(0, 0, 0, 0, 0, 0)
    $axisMaximum = @(0, 0, 0, 0, 0, 0)
    $axisInitialized = @($false, $false, $false, $false, $false, $false)
    $buttonsPressed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $sampleCount = 0
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()

    do {
        [FearMorePhysicalControllerProbeNative]::SDL_UpdateGamepads()
        for ($axis = 0; $axis -lt $axisNames.Count; ++$axis) {
            $value = [int][FearMorePhysicalControllerProbeNative]::SDL_GetGamepadAxis($gamepad, $axis)
            if (-not $axisInitialized[$axis]) {
                $axisMinimum[$axis] = $value
                $axisMaximum[$axis] = $value
                $axisInitialized[$axis] = $true
            }
            else {
                $axisMinimum[$axis] = [Math]::Min($axisMinimum[$axis], $value)
                $axisMaximum[$axis] = [Math]::Max($axisMaximum[$axis], $value)
            }
        }
        for ($button = 0; $button -lt $buttonNames.Count; ++$button) {
            if ([FearMorePhysicalControllerProbeNative]::SDL_GetGamepadButton($gamepad, $button)) {
                [void]$buttonsPressed.Add($buttonNames[$button])
            }
        }
        ++$sampleCount
        if ($stopwatch.Elapsed.TotalSeconds -lt $SampleSeconds) {
            Start-Sleep -Milliseconds 16
        }
    } while ($stopwatch.Elapsed.TotalSeconds -lt $SampleSeconds)

    $axisSamples = for ($axis = 0; $axis -lt $axisNames.Count; ++$axis) {
        [pscustomobject]@{
            Axis = $axisNames[$axis]
            Minimum = $axisMinimum[$axis]
            Maximum = $axisMaximum[$axis]
            Range = $axisMaximum[$axis] - $axisMinimum[$axis]
        }
    }
    $axisActivity = @($axisSamples | Where-Object {
            $_.Range -ge 4096 -or [Math]::Abs($_.Minimum) -ge 4096 -or [Math]::Abs($_.Maximum) -ge 4096
        }).Count -gt 0
    $inputActivity = $axisActivity -or $buttonsPressed.Count -gt 0

    $rumbleAttempted = $RumbleMilliseconds -gt 0
    $rumbleAccepted = $false
    if ($rumbleAttempted) {
        $rumbleAccepted = [FearMorePhysicalControllerProbeNative]::SDL_RumbleGamepad(
            $gamepad, [uint16]49151, [uint16]32767, [uint32]$RumbleMilliseconds)
        if (-not $rumbleAccepted) {
            throw "SDL rejected the physical rumble request: $(Get-SdlError)"
        }
        Start-Sleep -Milliseconds $RumbleMilliseconds
        [void][FearMorePhysicalControllerProbeNative]::SDL_RumbleGamepad(
            $gamepad, [uint16]0, [uint16]0, [uint32]0)
    }

    if ($RequireInputActivity -and -not $inputActivity) {
        throw "No controller button or axis activity was observed during the $SampleSeconds-second sample."
    }

    [pscustomobject]@{
        Status = 'PASS'
        ProcessArchitecture = 'x86'
        SDLVersion = $metadata.Version
        SDLRuntimeSha256 = $runtimeHash
        GamepadCount = $gamepadCount
        InstanceId = $instanceId
        Name = $gamepadName
        Connected = [FearMorePhysicalControllerProbeNative]::SDL_GamepadConnected($gamepad)
        SampleSeconds = $SampleSeconds
        SampleCount = $sampleCount
        InputActivityObserved = $inputActivity
        ButtonsPressed = @($buttonsPressed | Sort-Object)
        AxisSamples = @($axisSamples)
        RumbleAttempted = $rumbleAttempted
        RumbleAccepted = $rumbleAccepted
    }
}
finally {
    if ($gamepadList -ne [IntPtr]::Zero) {
        [FearMorePhysicalControllerProbeNative]::SDL_free($gamepadList)
    }
    if ($gamepad -ne [IntPtr]::Zero) {
        [void][FearMorePhysicalControllerProbeNative]::SDL_RumbleGamepad(
            $gamepad, [uint16]0, [uint16]0, [uint32]0)
        [FearMorePhysicalControllerProbeNative]::SDL_CloseGamepad($gamepad)
    }
    if ($subsystemInitialized) {
        [FearMorePhysicalControllerProbeNative]::SDL_QuitSubSystem($sdlInitGamepad)
    }
    [void][FearMorePhysicalControllerProbeNative]::SetDllDirectory($null)
}
