<#
.SYNOPSIS
Summarizes paired FearMore source-camera and D3D9 setter captures.

.DESCRIPTION
Reads the bounded JSONL diagnostics without modifying them. The analyzer
requires the explicit arm event and all eight successful hook flags, rejects
per-record schema/PID/QPC-frequency or frame-order drift, and reports render
activity, source-camera motion, constant-payload recoverability, QPC overlap
with the source-owned main-camera bracket, and shader CTAB register declarations
when the Windows SDK fxc.exe disassembler is available.

The result deliberately separates temporal correlation from shader-name
correlation. EchoPatch does not resynchronize state restored by D3D9 state
blocks, so a shader hash attached to a constant setter is evidence, not proof,
until a value also agrees with the source camera transform/projection.

.PARAMETER D3D9Path
Path to camera-d3d9-<pid>.jsonl.

.PARAMETER SourcePath
Optional path to camera-source-<pid>.jsonl from the same process.

.PARAMETER ShaderDirectory
Optional shader dump directory. Defaults to a shaders directory beside the
D3D9 JSONL file.

.PARAMETER FxcPath
Optional explicit path to an x86 Windows SDK fxc.exe.

.PARAMETER NoShaderDisassembly
Skips fxc discovery and CTAB parsing. Intended for environments without the
legacy Direct3D shader compiler and for dependency-free tests.

.OUTPUTS
One PSCustomObject containing capture, activity, source, correlation, shader,
and warning evidence.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$D3D9Path,

    [Parameter()]
    [string]$SourcePath,

    [Parameter()]
    [string]$ShaderDirectory,

    [Parameter()]
    [string]$FxcPath,

    [Parameter()]
    [switch]$NoShaderDisassembly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JsonProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter()][AllowNull()][object]$Default = $null
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }
    return $property.Value
}

function Get-RequiredJsonProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Kind,
        [Parameter(Mandatory = $true)][int]$RecordNumber
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "$Kind record $RecordNumber is missing required field '$Name'."
    }
    return $property.Value
}

function Assert-D3D9CaptureIntegrity {
    param(
        [Parameter(Mandatory = $true)][object[]]$Records,
        [Parameter(Mandatory = $true)][object]$Capability
    )

    $expectedPid = [uint32](Get-RequiredJsonProperty $Capability 'pid' 'D3D9' 1)
    $expectedFrequency = [long](Get-RequiredJsonProperty $Capability 'qpcFrequency' 'D3D9' 1)
    if ($expectedFrequency -le 0) {
        throw 'D3D9 capability has an invalid QPC frequency.'
    }

    if ((Get-RequiredJsonProperty $Capability 'enabled' 'D3D9 capability' 1) -ne $true) {
        throw 'D3D9 camera capability is not enabled.'
    }

    $hooks = Get-RequiredJsonProperty $Capability 'hooks' 'D3D9 capability' 1
    $requiredHooks = @(
        'setRenderTarget',
        'endScene',
        'setTransform',
        'setViewport',
        'drawPrimitive',
        'drawIndexedPrimitive',
        'setVertexShader',
        'setVertexShaderConstantF'
    )
    foreach ($hookName in $requiredHooks) {
        $hookProperty = $hooks.PSObject.Properties[$hookName]
        if ($null -eq $hookProperty -or $hookProperty.Value -ne $true) {
            throw "D3D9 camera capability hook '$hookName' was not installed successfully."
        }
    }

    $previousFrame = [uint64]0
    $hasPreviousFrame = $false
    for ($index = 0; $index -lt $Records.Count; ++$index) {
        $recordNumber = $index + 1
        $record = $Records[$index]
        $schema = Get-RequiredJsonProperty $record 'schema' 'D3D9' $recordNumber
        if ([long]$schema -ne 1) {
            throw "D3D9 record $recordNumber has unsupported schema '$schema'; expected 1."
        }

        $recordPid = [uint32](Get-RequiredJsonProperty $record 'pid' 'D3D9' $recordNumber)
        if ($recordPid -ne $expectedPid) {
            throw "D3D9 record $recordNumber PID $recordPid does not match capability PID $expectedPid."
        }

        $recordFrequency = [long](Get-RequiredJsonProperty $record 'qpcFrequency' 'D3D9' $recordNumber)
        if ($recordFrequency -ne $expectedFrequency) {
            throw "D3D9 record $recordNumber QPC frequency $recordFrequency does not match capability frequency $expectedFrequency."
        }

        $recordFrame = [uint64](Get-RequiredJsonProperty $record 'frame' 'D3D9' $recordNumber)
        if ($hasPreviousFrame -and $recordFrame -lt $previousFrame) {
            throw "D3D9 record $recordNumber regresses from frame $previousFrame to frame $recordFrame."
        }
        $previousFrame = $recordFrame
        $hasPreviousFrame = $true
    }

    $armRecords = @($Records | Where-Object { (Get-JsonProperty $_ 'event') -eq 'arm' })
    if ($armRecords.Count -ne 1) {
        throw "D3D9 capture must contain exactly one arm record; found $($armRecords.Count)."
    }
    if ((Get-JsonProperty $Records[0] 'event') -ne 'capability' -or
        $Records.Count -lt 2 -or (Get-JsonProperty $Records[1] 'event') -ne 'arm') {
        throw 'D3D9 capability must be the first record and the arm record must immediately follow it before captured activity.'
    }

    return [pscustomobject][ordered]@{
        Pid = $expectedPid
        QpcFrequency = $expectedFrequency
        ArmRecord = $armRecords[0]
        RequiredHooks = $requiredHooks
    }
}

function Assert-SourceCaptureIntegrity {
    param([Parameter(Mandatory = $true)][object[]]$Records)

    if ($Records.Count -eq 0) {
        throw 'Source-camera capture contains no JSON records.'
    }

    $expectedPid = [uint32](Get-RequiredJsonProperty $Records[0] 'pid' 'source-camera' 1)
    $expectedFrequency = [long](Get-RequiredJsonProperty $Records[0] 'qpc_frequency' 'source-camera' 1)
    $expectedVersion = [long](Get-RequiredJsonProperty $Records[0] 'version' 'source-camera' 1)
    if ($expectedFrequency -le 0) {
        throw 'Source-camera capture has an invalid QPC frequency.'
    }
    if ($expectedVersion -ne 1 -and $expectedVersion -ne 2) {
        throw "Source-camera capture has unsupported version '$expectedVersion'."
    }

    $previousFrame = [uint64]0
    $previousQpcBefore = [long]0
    $hasPreviousRecord = $false
    for ($index = 0; $index -lt $Records.Count; ++$index) {
        $recordNumber = $index + 1
        $record = $Records[$index]
        $schema = Get-RequiredJsonProperty $record 'schema' 'source-camera' $recordNumber
        if ($schema -ne 'fearmore.camera-source') {
            throw "Source-camera record $recordNumber has unsupported schema '$schema'."
        }
        $version = [long](Get-RequiredJsonProperty $record 'version' 'source-camera' $recordNumber)
        if ($version -ne $expectedVersion) {
            throw "Source-camera record $recordNumber version $version does not match capture version $expectedVersion."
        }
        $marker = Get-RequiredJsonProperty $record 'marker' 'source-camera' $recordNumber
        if ($marker -ne 'main_camera_render') {
            throw "Source-camera record $recordNumber has unsupported marker '$marker'."
        }

        $recordPid = [uint32](Get-RequiredJsonProperty $record 'pid' 'source-camera' $recordNumber)
        if ($recordPid -ne $expectedPid) {
            throw "Source-camera record $recordNumber PID $recordPid does not match capture PID $expectedPid."
        }
        $recordFrequency = [long](Get-RequiredJsonProperty $record 'qpc_frequency' 'source-camera' $recordNumber)
        if ($recordFrequency -ne $expectedFrequency) {
            throw "Source-camera record $recordNumber QPC frequency $recordFrequency does not match capture frequency $expectedFrequency."
        }

        $recordFrame = [uint64](Get-RequiredJsonProperty $record 'frame_index' 'source-camera' $recordNumber)
        if ($hasPreviousRecord -and $recordFrame -le $previousFrame) {
            throw "Source-camera record $recordNumber does not advance beyond frame $previousFrame (found $recordFrame)."
        }

        $qpcBefore = [long](Get-RequiredJsonProperty $record 'qpc_before' 'source-camera' $recordNumber)
        $qpcAfter = [long](Get-RequiredJsonProperty $record 'qpc_after' 'source-camera' $recordNumber)
        if ($qpcAfter -lt $qpcBefore) {
            throw "Source-camera record $recordNumber ends before its render bracket begins."
        }
        if ($hasPreviousRecord -and $qpcBefore -le $previousQpcBefore) {
            throw "Source-camera record $recordNumber has a non-monotonic qpc_before value."
        }

        $previousFrame = $recordFrame
        $previousQpcBefore = $qpcBefore
        $hasPreviousRecord = $true
    }

    return [pscustomobject][ordered]@{
        Pid = $expectedPid
        QpcFrequency = $expectedFrequency
        SchemaVersion = $expectedVersion
    }
}

function ConvertTo-FiniteVectorSample {
    param(
        [Parameter()][AllowNull()][object]$Value,
        [Parameter(Mandatory = $true)][int]$ComponentCount
    )

    $components = @($Value)
    if ($components.Count -ne $ComponentCount) {
        return $null
    }

    $sample = New-Object double[] $ComponentCount
    for ($index = 0; $index -lt $ComponentCount; ++$index) {
        if ($null -eq $components[$index]) {
            return $null
        }
        try {
            $component = [double]$components[$index]
        }
        catch {
            return $null
        }
        if ([double]::IsNaN($component) -or [double]::IsInfinity($component)) {
            return $null
        }
        $sample[$index] = $component
    }
    return ,$sample
}

function Get-SourceCameraMotionSummary {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Records)

    $positions = New-Object 'System.Collections.Generic.List[object]'
    $rotations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($record in $Records) {
        $transform = Get-JsonProperty $record 'transform'
        if ($null -eq $transform) {
            continue
        }

        $position = ConvertTo-FiniteVectorSample -Value (Get-JsonProperty $transform 'position') -ComponentCount 3
        if ($null -ne $position) {
            $null = $positions.Add($position)
        }

        $rotation = ConvertTo-FiniteVectorSample -Value (Get-JsonProperty $transform 'rotation_xyzw') -ComponentCount 4
        if ($null -ne $rotation) {
            $length = [Math]::Sqrt(
                ($rotation[0] * $rotation[0]) + ($rotation[1] * $rotation[1]) +
                ($rotation[2] * $rotation[2]) + ($rotation[3] * $rotation[3]))
            if ($length -gt 0.0) {
                for ($component = 0; $component -lt 4; ++$component) {
                    $rotation[$component] /= $length
                }
                $null = $rotations.Add($rotation)
            }
        }
    }

    $totalTravel = 0.0
    $maximumPositionStep = 0.0
    for ($index = 1; $index -lt $positions.Count; ++$index) {
        $dx = $positions[$index][0] - $positions[$index - 1][0]
        $dy = $positions[$index][1] - $positions[$index - 1][1]
        $dz = $positions[$index][2] - $positions[$index - 1][2]
        $step = [Math]::Sqrt(($dx * $dx) + ($dy * $dy) + ($dz * $dz))
        $totalTravel += $step
        $maximumPositionStep = [Math]::Max($maximumPositionStep, $step)
    }
    $netDisplacement = 0.0
    if ($positions.Count -gt 1) {
        $dx = $positions[$positions.Count - 1][0] - $positions[0][0]
        $dy = $positions[$positions.Count - 1][1] - $positions[0][1]
        $dz = $positions[$positions.Count - 1][2] - $positions[0][2]
        $netDisplacement = [Math]::Sqrt(($dx * $dx) + ($dy * $dy) + ($dz * $dz))
    }

    $totalAngularTravel = 0.0
    $maximumAngularStep = 0.0
    for ($index = 1; $index -lt $rotations.Count; ++$index) {
        $dot = [Math]::Abs(
            ($rotations[$index][0] * $rotations[$index - 1][0]) +
            ($rotations[$index][1] * $rotations[$index - 1][1]) +
            ($rotations[$index][2] * $rotations[$index - 1][2]) +
            ($rotations[$index][3] * $rotations[$index - 1][3]))
        $dot = [Math]::Min(1.0, [Math]::Max(0.0, $dot))
        $stepDegrees = 2.0 * [Math]::Acos($dot) * 180.0 / [Math]::PI
        $totalAngularTravel += $stepDegrees
        $maximumAngularStep = [Math]::Max($maximumAngularStep, $stepDegrees)
    }

    $positionChanged = $totalTravel -gt 0.001
    $orientationChanged = $totalAngularTravel -gt 0.01
    return [pscustomobject][ordered]@{
        PositionSamples = $positions.Count
        RotationSamples = $rotations.Count
        TotalPositionTravel = [Math]::Round($totalTravel, 6)
        NetPositionDisplacement = [Math]::Round($netDisplacement, 6)
        MaximumPositionStep = [Math]::Round($maximumPositionStep, 6)
        TotalAngularTravelDegrees = [Math]::Round($totalAngularTravel, 6)
        MaximumAngularStepDegrees = [Math]::Round($maximumAngularStep, 6)
        PositionChanged = $positionChanged
        OrientationChanged = $orientationChanged
        CameraVaried = $positionChanged -or $orientationChanged
    }
}

function Read-JsonLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Kind
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "$Kind capture path is not a file: '$resolvedPath'."
    }

    $records = New-Object 'System.Collections.Generic.List[object]'
    $lineNumber = 0
    # EchoPatch intentionally keeps the capture handle open for the lifetime of
    # the process and grants read sharing. Match that live-capture contract here:
    # File.OpenText uses FileShare.Read, which conflicts with an existing writer
    # even when that writer explicitly permits readers.
    $share = [IO.FileShare]([int][IO.FileShare]::ReadWrite -bor [int][IO.FileShare]::Delete)
    $stream = [IO.FileStream]::new(
        $resolvedPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        $share
    )
    $reader = [IO.StreamReader]::new(
        $stream,
        [Text.UTF8Encoding]::new($false, $true),
        $true,
        4096,
        $false
    )
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            ++$lineNumber
            if ([string]::IsNullOrWhiteSpace($line)) {
                continue
            }
            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                throw "Invalid JSON at line $lineNumber of $Kind capture '$resolvedPath': $($_.Exception.Message)"
            }
            $null = $records.Add($record)
        }
    }
    finally {
        $reader.Dispose()
    }
    if ($records.Count -eq 0) {
        throw "$Kind capture contains no JSON records: '$resolvedPath'."
    }

    return [pscustomobject]@{
        Path = $resolvedPath
        Records = $records.ToArray()
    }
}

function Resolve-FxcExecutable {
    param([Parameter()][string]$RequestedPath)

    if ($RequestedPath) {
        $resolved = (Resolve-Path -LiteralPath $RequestedPath -ErrorAction Stop).Path
        if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
            throw "fxc path is not a file: '$resolved'."
        }
        return $resolved
    }

    $kitsRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    if (-not (Test-Path -LiteralPath $kitsRoot -PathType Container)) {
        return $null
    }

    foreach ($versionDirectory in @(Get-ChildItem -LiteralPath $kitsRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending)) {
        $candidate = Join-Path $versionDirectory.FullName 'x86\fxc.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    $unversioned = Join-Path $kitsRoot 'x86\fxc.exe'
    if (Test-Path -LiteralPath $unversioned -PathType Leaf) {
        return $unversioned
    }
    return $null
}

function Test-ConstantRecoverable {
    param(
        [Parameter(Mandatory = $true)][object]$Record,
        [Parameter()][AllowNull()][IO.FileInfo]$PayloadFile
    )

    $valueCount = [uint64](Get-JsonProperty -Object $Record -Name 'valueCount' -Default 0)
    $loggedValueCount = [uint64](Get-JsonProperty -Object $Record -Name 'loggedValueCount' -Default 0)
    $valuesTruncated = [bool](Get-JsonProperty -Object $Record -Name 'valuesTruncated' -Default $true)
    if (-not $valuesTruncated -and $valueCount -gt 0 -and $loggedValueCount -eq $valueCount) {
        return $true
    }

    $payloadAvailable = [bool](Get-JsonProperty -Object $Record -Name 'payloadAvailable' -Default $false)
    if (-not $payloadAvailable -or $null -eq $PayloadFile) {
        return $false
    }

    $payloadOffset = [uint64](Get-JsonProperty -Object $Record -Name 'payloadOffset' -Default 0)
    $payloadBytes = [uint64](Get-JsonProperty -Object $Record -Name 'payloadBytes' -Default 0)
    return $payloadBytes -gt 0 -and ($payloadOffset + $payloadBytes) -le [uint64]$PayloadFile.Length
}

function Test-QpcInSourceBracket {
    param(
        [Parameter(Mandatory = $true)][long]$Qpc,
        [Parameter(Mandatory = $true)][object[]]$Brackets
    )

    foreach ($bracket in $Brackets) {
        if ($Qpc -lt [long]$bracket.qpc_before) {
            return $false
        }
        if ($Qpc -le [long]$bracket.qpc_after) {
            return $true
        }
    }
    return $false
}

function Test-QpcInSourceFrameWindow {
    param(
        [Parameter(Mandatory = $true)][long]$Qpc,
        [Parameter(Mandatory = $true)][object[]]$Windows
    )

    foreach ($window in $Windows) {
        if ($Qpc -le [long]$window.StartQpc) {
            return $false
        }
        if ($Qpc -lt [long]$window.EndQpc) {
            return $true
        }
    }
    return $false
}

function Get-SourceRecordForQpc {
    param(
        [Parameter(Mandatory = $true)][long]$Qpc,
        [Parameter(Mandatory = $true)][object[]]$Records
    )

    for ($index = 0; $index -lt $Records.Count; ++$index) {
        $record = $Records[$index]
        $before = [long](Get-JsonProperty $record 'qpc_before')
        $after = [long](Get-JsonProperty $record 'qpc_after')
        if ($Qpc -lt $before) {
            return $null
        }
        if ($Qpc -le $after) {
            return $record
        }
        if ($index + 1 -lt $Records.Count -and
            $Qpc -lt [long](Get-JsonProperty $Records[$index + 1] 'qpc_before')) {
            return $record
        }
    }
    return $null
}

function Test-NearlyEqual {
    param(
        [Parameter(Mandatory = $true)][double]$Value,
        [Parameter(Mandatory = $true)][double]$Expected,
        [Parameter()][double]$AbsoluteTolerance = 0.002,
        [Parameter()][double]$RelativeTolerance = 0.00002
    )

    $allowed = [Math]::Max($AbsoluteTolerance, [Math]::Abs($Expected) * $RelativeTolerance)
    return [Math]::Abs($Value - $Expected) -le $allowed
}

function Test-ViewTransformMatchesSource {
    param(
        [Parameter(Mandatory = $true)][object]$TransformRecord,
        [Parameter(Mandatory = $true)][object]$SourceRecord
    )

    $values = @((Get-JsonProperty $TransformRecord 'values'))
    $transform = Get-JsonProperty $SourceRecord 'transform'
    $position = @(if ($null -ne $transform) { Get-JsonProperty $transform 'position' })
    $basis = if ($null -ne $transform) { Get-JsonProperty $transform 'basis' } else { $null }
    $right = @(if ($null -ne $basis) { Get-JsonProperty $basis 'right' })
    $up = @(if ($null -ne $basis) { Get-JsonProperty $basis 'up' })
    $forward = @(if ($null -ne $basis) { Get-JsonProperty $basis 'forward' })
    if ($values.Count -ne 16 -or $position.Count -ne 3 -or
        $right.Count -ne 3 -or $up.Count -ne 3 -or $forward.Count -ne 3) {
        return $false
    }

    $translationRight = -( ([double]$right[0] * [double]$position[0]) +
        ([double]$right[1] * [double]$position[1]) +
        ([double]$right[2] * [double]$position[2]) )
    $translationUp = -( ([double]$up[0] * [double]$position[0]) +
        ([double]$up[1] * [double]$position[1]) +
        ([double]$up[2] * [double]$position[2]) )
    $translationForward = -( ([double]$forward[0] * [double]$position[0]) +
        ([double]$forward[1] * [double]$position[1]) +
        ([double]$forward[2] * [double]$position[2]) )
    $expected = @(
        [double]$right[0], [double]$up[0], [double]$forward[0], 0.0,
        [double]$right[1], [double]$up[1], [double]$forward[1], 0.0,
        [double]$right[2], [double]$up[2], [double]$forward[2], 0.0,
        $translationRight, $translationUp, $translationForward, 1.0
    )
    for ($index = 0; $index -lt 16; ++$index) {
        $absoluteTolerance = if ($index -ge 12 -and $index -le 14) { 0.05 } else { 0.002 }
        if (-not (Test-NearlyEqual -Value ([double]$values[$index]) -Expected $expected[$index] -AbsoluteTolerance $absoluteTolerance)) {
            return $false
        }
    }
    return $true
}

function Test-ProjectionTransformMatchesSource {
    param(
        [Parameter(Mandatory = $true)][object]$TransformRecord,
        [Parameter(Mandatory = $true)][object]$SourceRecord
    )

    $values = @((Get-JsonProperty $TransformRecord 'values'))
    $fov = @((Get-JsonProperty $SourceRecord 'fov_radians'))
    $clip = Get-JsonProperty $SourceRecord 'clip'
    $nearZ = if ($null -ne $clip) { Get-JsonProperty $clip 'near_z' } else { $null }
    if ($values.Count -ne 16 -or $fov.Count -ne 2 -or $null -eq $nearZ -or
        [double]$fov[0] -le 0.0 -or [double]$fov[1] -le 0.0) {
        return $false
    }

    $expectedX = 1.0 / [Math]::Tan([double]$fov[0] * 0.5)
    $expectedY = 1.0 / [Math]::Tan([double]$fov[1] * 0.5)
    if (-not (Test-NearlyEqual -Value ([double]$values[0]) -Expected $expectedX) -or
        -not (Test-NearlyEqual -Value ([double]$values[5]) -Expected $expectedY) -or
        -not (Test-NearlyEqual -Value ([double]$values[11]) -Expected 1.0) -or
        -not (Test-NearlyEqual -Value ([double]$values[14]) -Expected (-[double]$nearZ) -AbsoluteTolerance 0.01) -or
        -not (Test-NearlyEqual -Value ([double]$values[15]) -Expected 0.0)) {
        return $false
    }

    foreach ($index in @(1, 2, 3, 4, 6, 7, 8, 9, 12, 13)) {
        if (-not (Test-NearlyEqual -Value ([double]$values[$index]) -Expected 0.0)) {
            return $false
        }
    }
    return [double]$values[10] -gt 0.9
}

$d3dCapture = Read-JsonLines -Path $D3D9Path -Kind 'D3D9'
$d3dRecords = @($d3dCapture.Records)
$capabilities = @($d3dRecords | Where-Object { (Get-JsonProperty $_ 'event') -eq 'capability' })
if ($capabilities.Count -ne 1) {
    throw "D3D9 capture must contain exactly one capability record; found $($capabilities.Count)."
}
$capability = $capabilities[0]
if ((Get-JsonProperty $capability 'capability') -ne 'camera-d3d9-setter-capture-v1') {
    throw "Unsupported D3D9 camera capability '$((Get-JsonProperty $capability 'capability'))'."
}
$d3dIntegrity = Assert-D3D9CaptureIntegrity -Records $d3dRecords -Capability $capability

$frames = @($d3dRecords | Where-Object { (Get-JsonProperty $_ 'event') -eq 'frame' } | Sort-Object { [uint64]$_.frame })
if ($frames.Count -eq 0) {
    throw 'D3D9 capture contains no frame records.'
}
$previousFrameRecord = $null
foreach ($frameRecord in $frames) {
    $frameNumber = [uint64](Get-JsonProperty $frameRecord 'frame')
    if ($null -ne $previousFrameRecord -and $frameNumber -le $previousFrameRecord) {
        throw "D3D9 frame records must advance strictly; found frame $frameNumber after frame $previousFrameRecord."
    }
    $previousFrameRecord = $frameNumber
}
$constantWrites = @($d3dRecords | Where-Object { (Get-JsonProperty $_ 'event') -eq 'constant-write' })
$shaderRecords = @($d3dRecords | Where-Object { (Get-JsonProperty $_ 'event') -eq 'vertex-shader' })
$transformWrites = @($d3dRecords | Where-Object { (Get-JsonProperty $_ 'event') -eq 'transform-write' })
$d3dPid = [uint32]$d3dIntegrity.Pid
$qpcFrequency = [long]$d3dIntegrity.QpcFrequency

$frameQpcStart = [long](Get-JsonProperty $frames[0] 'qpc')
$frameQpcEnd = [long](Get-JsonProperty $frames[-1] 'qpc')
$durationSeconds = [Math]::Max(0.0, ($frameQpcEnd - $frameQpcStart) / [double]$qpcFrequency)
$frameRate = if ($durationSeconds -gt 0.0 -and $frames.Count -gt 1) {
    ($frames.Count - 1) / $durationSeconds
}
else {
    0.0
}

$maximumDrawCalls = 0
$maximumPrimitives = 0
$framesWithFixedFunctionDraws = 0
$framesWithTransformSetters = 0
$frameSignatures = New-Object 'System.Collections.Generic.List[object]'
$runStart = $null
$runLast = $null
$runSignature = $null
foreach ($frame in $frames) {
    $shaderDraws = [uint64](Get-JsonProperty (Get-JsonProperty $frame 'draws') 'shader' 0)
    $fixedDraws = [uint64](Get-JsonProperty (Get-JsonProperty $frame 'draws') 'fixedFunction' 0)
    $primitives = [uint64](Get-JsonProperty (Get-JsonProperty $frame 'draws') 'primitives' 0)
    $transforms = [uint64](Get-JsonProperty (Get-JsonProperty $frame 'setters') 'transforms' 0)
    $drawCalls = $shaderDraws + $fixedDraws
    $maximumDrawCalls = [Math]::Max($maximumDrawCalls, $drawCalls)
    $maximumPrimitives = [Math]::Max($maximumPrimitives, $primitives)
    if ($fixedDraws -gt 0) { ++$framesWithFixedFunctionDraws }
    if ($transforms -gt 0) { ++$framesWithTransformSetters }

    $viewport = Get-JsonProperty $frame 'viewport'
    $signatureValues = @(
        $shaderDraws
        $fixedDraws
        $primitives
        (Get-JsonProperty (Get-JsonProperty $frame 'setters') 'vertexShader' 0)
        (Get-JsonProperty (Get-JsonProperty $frame 'setters') 'constants' 0)
        $transforms
        (Get-JsonProperty $viewport 'width' 0)
        (Get-JsonProperty $viewport 'height' 0)
    )
    $signature = '{0}/{1}/{2}|vs{3}|c{4}|t{5}|{6}x{7}' -f $signatureValues
    if ($null -eq $runSignature -or $signature -ne $runSignature) {
        if ($null -ne $runSignature) {
            $null = $frameSignatures.Add([pscustomobject][ordered]@{
                FirstFrame = [uint64]$runStart.frame
                LastFrame = [uint64]$runLast.frame
                Count = ([uint64]$runLast.frame - [uint64]$runStart.frame) + 1
                Signature = $runSignature
            })
        }
        $runStart = $frame
        $runSignature = $signature
    }
    $runLast = $frame
}
$null = $frameSignatures.Add([pscustomobject][ordered]@{
    FirstFrame = [uint64]$runStart.frame
    LastFrame = [uint64]$runLast.frame
    Count = ([uint64]$runLast.frame - [uint64]$runStart.frame) + 1
    Signature = $runSignature
})

$sourceCapturePath = $null
$sourceRecords = @()
$sourcePid = $null
$sourceQpcFrequency = $null
$sourceSchemaVersion = $null
$sourcePidMatches = $false
$sourceFrequencyMatches = $false
$sourceBrackets = @()
$sourceFrameWindows = @()
$sourceMotion = Get-SourceCameraMotionSummary -Records @()
if ($SourcePath) {
    $sourceCapture = Read-JsonLines -Path $SourcePath -Kind 'source-camera'
    $sourceCapturePath = $sourceCapture.Path
    $sourceRecords = @($sourceCapture.Records)
    $sourceIntegrity = Assert-SourceCaptureIntegrity -Records $sourceRecords
    $sourcePid = [uint32]$sourceIntegrity.Pid
    $sourceQpcFrequency = [long]$sourceIntegrity.QpcFrequency
    $sourceSchemaVersion = [long]$sourceIntegrity.SchemaVersion
    $sourceMotion = Get-SourceCameraMotionSummary -Records $sourceRecords
    $sourcePidMatches = $sourcePid -eq $d3dPid
    $sourceFrequencyMatches = $sourceQpcFrequency -eq $qpcFrequency
    if ($sourcePidMatches -and $sourceFrequencyMatches) {
        $sourceBrackets = @($sourceRecords)
        $frameWindows = New-Object 'System.Collections.Generic.List[object]'
        for ($index = 0; $index + 1 -lt $sourceRecords.Count; ++$index) {
            $startQpc = [long](Get-JsonProperty $sourceRecords[$index] 'qpc_after')
            $endQpc = [long](Get-JsonProperty $sourceRecords[$index + 1] 'qpc_before')
            if ($endQpc -le $startQpc) {
                continue
            }
            $null = $frameWindows.Add([pscustomobject][ordered]@{
                SourceFrame = [uint64](Get-JsonProperty $sourceRecords[$index] 'frame_index' $index)
                StartQpc = $startQpc
                EndQpc = $endQpc
            })
        }
        $sourceFrameWindows = $frameWindows.ToArray()
    }
}

$constantsInsideSourceBracket = @()
$constantsInsideSourceFrameWindow = @()
$constantsCorrelatedToSource = @()
if ($sourceBrackets.Count -gt 0) {
    $constantsInsideSourceBracket = @($constantWrites | Where-Object {
        Test-QpcInSourceBracket -Qpc ([long](Get-JsonProperty $_ 'qpc')) -Brackets $sourceBrackets
    })
    $constantsInsideSourceFrameWindow = @($constantWrites | Where-Object {
        $sourceFrameWindows.Count -gt 0 -and
        (Test-QpcInSourceFrameWindow -Qpc ([long](Get-JsonProperty $_ 'qpc')) -Windows $sourceFrameWindows)
    })
    $constantsCorrelatedToSource = @($constantWrites | Where-Object {
        $qpc = [long](Get-JsonProperty $_ 'qpc')
        (Test-QpcInSourceBracket -Qpc $qpc -Brackets $sourceBrackets) -or
        ($sourceFrameWindows.Count -gt 0 -and
            (Test-QpcInSourceFrameWindow -Qpc $qpc -Windows $sourceFrameWindows))
    })
}

$payloadLeafName = ([IO.Path]::GetFileNameWithoutExtension($d3dCapture.Path)) + '.constants.f32bin'
$payloadPath = Join-Path (Split-Path -Parent $d3dCapture.Path) $payloadLeafName
$payloadFile = if (Test-Path -LiteralPath $payloadPath -PathType Leaf) {
    Get-Item -LiteralPath $payloadPath
}
else {
    $null
}
$recoverableConstants = @($constantWrites | Where-Object {
    Test-ConstantRecoverable -Record $_ -PayloadFile $payloadFile
})
$recoverableConstantsInsideSourceBracket = @($constantsInsideSourceBracket | Where-Object {
    Test-ConstantRecoverable -Record $_ -PayloadFile $payloadFile
})
$recoverableConstantsInsideSourceFrameWindow = @($constantsInsideSourceFrameWindow | Where-Object {
    Test-ConstantRecoverable -Record $_ -PayloadFile $payloadFile
})
$recoverableConstantsCorrelatedToSource = @($constantsCorrelatedToSource | Where-Object {
    Test-ConstantRecoverable -Record $_ -PayloadFile $payloadFile
})

$viewTransformEvidence = New-Object 'System.Collections.Generic.List[object]'
$projectionTransformEvidence = New-Object 'System.Collections.Generic.List[object]'
if ($sourceBrackets.Count -gt 0) {
    foreach ($transformWrite in $transformWrites) {
        $state = [string](Get-JsonProperty $transformWrite 'state' '')
        if ($state -ne 'view' -and $state -ne 'projection') {
            continue
        }
        $sourceRecord = Get-SourceRecordForQpc -Qpc ([long](Get-JsonProperty $transformWrite 'qpc')) -Records $sourceBrackets
        if ($null -eq $sourceRecord) {
            continue
        }
        $matches = if ($state -eq 'view') {
            Test-ViewTransformMatchesSource -TransformRecord $transformWrite -SourceRecord $sourceRecord
        }
        else {
            Test-ProjectionTransformMatchesSource -TransformRecord $transformWrite -SourceRecord $sourceRecord
        }
        $evidence = [pscustomobject][ordered]@{
            D3DFrame = [uint64](Get-JsonProperty $transformWrite 'frame' 0)
            SourceFrame = [uint64](Get-JsonProperty $sourceRecord 'frame_index' 0)
            Matches = [bool]$matches
        }
        if ($state -eq 'view') {
            $null = $viewTransformEvidence.Add($evidence)
        }
        else {
            $null = $projectionTransformEvidence.Add($evidence)
        }
    }
}
$viewMatchFrames = @($viewTransformEvidence | Where-Object Matches | ForEach-Object D3DFrame | Sort-Object -Unique)
$projectionMatchFrames = @($projectionTransformEvidence | Where-Object Matches | ForEach-Object D3DFrame | Sort-Object -Unique)
$fixedFunctionCameraMatchFrames = @($viewMatchFrames | Where-Object { $projectionMatchFrames -contains $_ })
$numericMatrixCorrelationProven = $fixedFunctionCameraMatchFrames.Count -gt 0

$warnings = New-Object 'System.Collections.Generic.List[string]'
$stateBlockResync = [bool](Get-JsonProperty $capability 'stateBlockResync' $false)
if (-not $stateBlockResync) {
    $null = $warnings.Add('D3D9 state-block restoration is not resynchronized; shader hashes on setter records can be stale and require numeric/source confirmation.')
}
if (-not $SourcePath) {
    $null = $warnings.Add('No source-camera JSONL was supplied, so main-camera temporal correlation is unavailable.')
}
elseif (-not $sourcePidMatches) {
    $null = $warnings.Add("Source-camera PID $sourcePid does not match D3D9 PID $d3dPid.")
}
elseif (-not $sourceFrequencyMatches) {
    $null = $warnings.Add("Source-camera QPC frequency $sourceQpcFrequency does not match D3D9 frequency $qpcFrequency.")
}
if ($constantWrites.Count -gt $recoverableConstants.Count) {
    $null = $warnings.Add("$($constantWrites.Count - $recoverableConstants.Count) sampled constant writes are truncated and have no complete sidecar payload.")
}
if ($constantsInsideSourceBracket.Count -eq 0 -and
    $constantsInsideSourceFrameWindow.Count -gt 0) {
    $null = $warnings.Add('D3D9 setters occur after the source RenderCamera submission returns; temporal correlation uses the bounded post-submit window before the next main-camera submission.')
}

$sparseActivity = $maximumDrawCalls -le 4 -and $maximumPrimitives -le 8 -and
    $framesWithFixedFunctionDraws -eq 0 -and $framesWithTransformSetters -eq 0
$activityClassification = if ($sparseActivity -and $sourceRecords.Count -eq 0) {
    'FrontendOrFullscreenPassOnly'
}
elseif ($sparseActivity) {
    'MainCameraSparsePass'
}
elseif ($sourceRecords.Count -gt 0) {
    'MainCameraScene'
}
else {
    'SceneLikeUncorrelated'
}
if ($sparseActivity) {
    $null = $warnings.Add('The capture contains only sparse shader draw activity and no fixed-function or transform setters; treat it as frontend/fullscreen-pass evidence, not representative gameplay.')
}

$shaderEventsOutsideFrameZero = @($shaderRecords | Where-Object { [uint64](Get-JsonProperty $_ 'frame' 0) -ne 0 }).Count
$largeConstantWrites = @($constantWrites | Where-Object { [uint64](Get-JsonProperty $_ 'vector4Count' 0) -gt 4 })
$largeConstantWritesOutsideFrameZero = @($largeConstantWrites | Where-Object { [uint64](Get-JsonProperty $_ 'frame' 0) -ne 0 }).Count
if ($shaderRecords.Count -gt 0 -and $shaderEventsOutsideFrameZero -eq 0) {
    $null = $warnings.Add('Every unique shader discovery record occurred at frame 0; the shader inventory is startup/warm-up evidence.')
}
if ($largeConstantWrites.Count -gt 0 -and $largeConstantWritesOutsideFrameZero -eq 0) {
    $null = $warnings.Add('Every sampled constant write larger than one matrix occurred at frame 0; those register blocks are startup/warm-up evidence.')
}

$resolvedShaderDirectory = if ($ShaderDirectory) {
    (Resolve-Path -LiteralPath $ShaderDirectory -ErrorAction Stop).Path
}
else {
    Join-Path (Split-Path -Parent $d3dCapture.Path) 'shaders'
}
$resolvedFxcPath = $null
$shaderConstants = New-Object 'System.Collections.Generic.List[object]'
$disassembledShaderCount = 0
if (-not $NoShaderDisassembly) {
    $resolvedFxcPath = Resolve-FxcExecutable -RequestedPath $FxcPath
    if ($null -eq $resolvedFxcPath) {
        $null = $warnings.Add('Windows SDK fxc.exe was not found; shader CTAB declarations were not parsed.')
    }
    elseif (-not (Test-Path -LiteralPath $resolvedShaderDirectory -PathType Container)) {
        $null = $warnings.Add("Shader dump directory was not found: '$resolvedShaderDirectory'.")
    }
    else {
        foreach ($shaderFile in @(Get-ChildItem -LiteralPath $resolvedShaderDirectory -Filter 'vs-*.dxso' -File | Sort-Object Name)) {
            if ($shaderFile.BaseName -notmatch '^vs-([0-9A-Fa-f]{8})-(\d+)$') {
                $null = $warnings.Add("Ignored shader dump with an unsupported name: '$($shaderFile.Name)'.")
                continue
            }
            $shaderHash = $Matches[1].ToUpperInvariant()
            $shaderBytes = [uint32]$Matches[2]
            $output = @(& $resolvedFxcPath /nologo /dumpbin $shaderFile.FullName 2>&1 | ForEach-Object { $_.ToString() })
            if ($LASTEXITCODE -ne 0) {
                $null = $warnings.Add("fxc failed to disassemble '$($shaderFile.Name)' (exit $LASTEXITCODE).")
                continue
            }
            ++$disassembledShaderCount
            foreach ($line in $output) {
                if ($line -notmatch '^//\s+([A-Za-z_][A-Za-z0-9_\[\]\.]*?)\s+c(\d+)\s+(\d+)\s*$') {
                    continue
                }
                $constantName = $Matches[1]
                $register = [uint32]$Matches[2]
                $registerCount = [uint32]$Matches[3]
                $isMatrixCandidate = $registerCount -ge 4 -and
                    $constantName -match '(?i)(ToClip|ViewProjection|WorldView|Projection)'
                $matchingWrites = @($constantWrites | Where-Object {
                    (Get-JsonProperty $_ 'shaderHash' '') -eq $shaderHash -and
                    [uint32](Get-JsonProperty $_ 'startRegister' 0) -le $register -and
                    [uint32](Get-JsonProperty $_ 'endRegisterExclusive' 0) -ge ($register + $registerCount)
                })
                $matchingSourceBracketWrites = @($matchingWrites | Where-Object {
                    $sourceBrackets.Count -gt 0 -and
                    (Test-QpcInSourceBracket -Qpc ([long](Get-JsonProperty $_ 'qpc')) -Brackets $sourceBrackets)
                })
                $matchingSourceFrameWindowWrites = @($matchingWrites | Where-Object {
                    $sourceFrameWindows.Count -gt 0 -and
                    (Test-QpcInSourceFrameWindow -Qpc ([long](Get-JsonProperty $_ 'qpc')) -Windows $sourceFrameWindows)
                })
                $matchingSourceWrites = @($matchingWrites | Where-Object {
                    $qpc = [long](Get-JsonProperty $_ 'qpc')
                    ($sourceBrackets.Count -gt 0 -and
                        (Test-QpcInSourceBracket -Qpc $qpc -Brackets $sourceBrackets)) -or
                    ($sourceFrameWindows.Count -gt 0 -and
                        (Test-QpcInSourceFrameWindow -Qpc $qpc -Windows $sourceFrameWindows))
                })
                $null = $shaderConstants.Add([pscustomobject][ordered]@{
                    ShaderHash = $shaderHash
                    ShaderBytes = $shaderBytes
                    Name = $constantName
                    Register = $register
                    RegisterCount = $registerCount
                    MatrixCandidate = $isMatrixCandidate
                    SampledCoveringWrites = $matchingWrites.Count
                    SourceBracketCoveringWrites = $matchingSourceBracketWrites.Count
                    SourceFrameWindowCoveringWrites = $matchingSourceFrameWindowWrites.Count
                    SourceCorrelatedCoveringWrites = $matchingSourceWrites.Count
                })
            }
        }
    }
}

$matrixCandidates = @($shaderConstants | Where-Object MatrixCandidate)
$matrixCandidatesWithSourceWrites = @($matrixCandidates | Where-Object SourceCorrelatedCoveringWrites -gt 0)
$temporalCorrelationReady = $sourceBrackets.Count -gt 0 -and $recoverableConstantsCorrelatedToSource.Count -gt 0
$namedMatrixSamplesAvailable = $temporalCorrelationReady -and $matrixCandidatesWithSourceWrites.Count -gt 0
$correlationMode = if ($recoverableConstantsInsideSourceBracket.Count -gt 0 -and
    $recoverableConstantsInsideSourceFrameWindow.Count -gt 0) {
    'RenderBracketAndPostSubmitFrameWindow'
}
elseif ($recoverableConstantsInsideSourceBracket.Count -gt 0) {
    'RenderBracket'
}
elseif ($recoverableConstantsInsideSourceFrameWindow.Count -gt 0) {
    'PostSubmitFrameWindow'
}
else {
    'None'
}

$frameZeroShaderHashes = @($shaderRecords | ForEach-Object { Get-JsonProperty $_ 'hash' } | Sort-Object -Unique)
$resolutions = @($frames | ForEach-Object {
    $viewport = Get-JsonProperty $_ 'viewport'
    '{0}x{1}' -f (Get-JsonProperty $viewport 'width' 0), (Get-JsonProperty $viewport 'height' 0)
} | Sort-Object -Unique)

[pscustomobject][ordered]@{
    D3D9 = [pscustomobject][ordered]@{
        Path = $d3dCapture.Path
        Pid = $d3dPid
        SchemaVersion = 1
        Capability = Get-JsonProperty $capability 'capability'
        Armed = $true
        InstalledHooksVerified = $true
        FrameCount = $frames.Count
        FirstFrame = [uint64](Get-JsonProperty $frames[0] 'frame')
        LastFrame = [uint64](Get-JsonProperty $frames[-1] 'frame')
        DurationSeconds = [Math]::Round($durationSeconds, 6)
        MeanFrameRate = [Math]::Round($frameRate, 3)
        Resolutions = $resolutions
        ShaderRecords = $shaderRecords.Count
        UniqueShaderHashes = $frameZeroShaderHashes.Count
        ConstantRecords = $constantWrites.Count
        TransformRecords = $transformWrites.Count
        PayloadPath = $payloadPath
        PayloadPresent = $null -ne $payloadFile
        RecoverableConstantRecords = $recoverableConstants.Count
    }
    Activity = [pscustomobject][ordered]@{
        Classification = $activityClassification
        MainCameraSceneObserved = -not $sparseActivity -and $sourceRecords.Count -gt 0
        MaximumDrawCallsPerFrame = $maximumDrawCalls
        MaximumPrimitivesPerFrame = $maximumPrimitives
        FramesWithFixedFunctionDraws = $framesWithFixedFunctionDraws
        FramesWithTransformSetters = $framesWithTransformSetters
        ShaderDiscoveriesOutsideFrameZero = $shaderEventsOutsideFrameZero
        LargeConstantWrites = $largeConstantWrites.Count
        LargeConstantWritesOutsideFrameZero = $largeConstantWritesOutsideFrameZero
        FrameSignatureRuns = $frameSignatures.ToArray()
    }
    Source = [pscustomobject][ordered]@{
        Path = $sourceCapturePath
        Supplied = [bool]$SourcePath
        Pid = $sourcePid
        SchemaVersion = $sourceSchemaVersion
        PidMatches = $sourcePidMatches
        QpcFrequencyMatches = $sourceFrequencyMatches
        MainCameraRecords = $sourceRecords.Count
        PostSubmitFrameWindows = $sourceFrameWindows.Count
        ValidTransformRecords = @($sourceRecords | Where-Object { $null -ne (Get-JsonProperty $_ 'transform') }).Count
        Motion = $sourceMotion
    }
    Correlation = [pscustomobject][ordered]@{
        Mode = $correlationMode
        ConstantRecordsInsideMainCamera = $constantsCorrelatedToSource.Count
        RecoverableConstantRecordsInsideMainCamera = $recoverableConstantsCorrelatedToSource.Count
        ConstantRecordsInsideRenderBracket = $constantsInsideSourceBracket.Count
        RecoverableConstantRecordsInsideRenderBracket = $recoverableConstantsInsideSourceBracket.Count
        ConstantRecordsInsidePostSubmitFrameWindow = $constantsInsideSourceFrameWindow.Count
        RecoverableConstantRecordsInsidePostSubmitFrameWindow = $recoverableConstantsInsideSourceFrameWindow.Count
        TemporalCorrelationReady = $temporalCorrelationReady
        NamedMatrixSamplesAvailable = $namedMatrixSamplesAvailable
        NumericMatrixCorrelationProven = $numericMatrixCorrelationProven
        SourceAlignedViewTransformSamples = $viewTransformEvidence.Count
        SourceAlignedViewTransformMatches = @($viewTransformEvidence | Where-Object Matches).Count
        SourceAlignedProjectionTransformSamples = $projectionTransformEvidence.Count
        SourceAlignedProjectionTransformMatches = @($projectionTransformEvidence | Where-Object Matches).Count
        SourceAlignedFixedFunctionCameraFrames = $fixedFunctionCameraMatchFrames.Count
        StateBlockResynchronized = $stateBlockResync
        Note = 'Render-bracket evidence is strict. Post-submit frame-window evidence accounts for F.E.A.R. deferring D3D9 work until after RenderCamera returns. Both remain provisional while stateBlockResync is false; numeric agreement with source transform, FOV, viewport, and projection probes remains the acceptance gate.'
    }
    ShaderAnalysis = [pscustomobject][ordered]@{
        Directory = $resolvedShaderDirectory
        FxcPath = $resolvedFxcPath
        DisassembledShaderCount = $disassembledShaderCount
        DeclaredConstants = $shaderConstants.ToArray()
        MatrixCandidates = $matrixCandidates
    }
    Warnings = $warnings.ToArray()
}
