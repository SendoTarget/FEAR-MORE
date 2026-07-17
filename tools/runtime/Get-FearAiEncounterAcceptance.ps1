<#
.SYNOPSIS
Analyzes a bounded active-AI encounter in a FearMore AI profile.

.DESCRIPTION
Reads one or more source-owned AIProfile CSV files without modifying them.  For
each capture, the analyzer discards an initial wall-clock warmup, starts at the
first positive-duration simulated frame with at least one AI update, and keeps
one contiguous simulated encounter window.  Simulated frames with zero AI
updates remain in the window so scheduler starvation cannot be hidden by the
crop.

The result reports cadence, simulation-to-wall-clock ratio, simulation
timestamp consistency, owner call-count invariants, longest AI starvation, and
authoritative server-frame percentiles.
It deliberately treats sensor, goal, and navigation counts as owner entry
counts; they are not evidence of a particular stimulus, goal transition, or
path result.

.PARAMETER Path
One or more AIProfile CSV file paths.

.PARAMETER WarmupSeconds
Wall-clock capture time to discard before searching for the encounter.  The
default is five seconds.

.PARAMETER EncounterSeconds
Minimum contiguous simulated encounter duration to analyze.  The default is
thirty seconds.  A pause, loading screen, death stop, or end of file before this
duration fails closed.

.PARAMETER ExpectedAiCount
Expected active AI updates and sensor-manager calls per simulated frame.  Zero
accepts an authored dynamic population while requiring both owners to remain
active on every simulated frame.  The modal positive AI-update count is always
reported as context.  Pass an explicit value for a fixed-population encounter.

.PARAMETER TargetFps
Optional frame-rate target for the bounded encounter.  Zero disables the FPS
gate so existing analysis callers retain invariant-only acceptance.

.PARAMETER FpsTolerancePercent
Allowed percentage below or above TargetFps.  The default is five percent.
This parameter is reported but does not affect acceptance when TargetFps is
zero.

.OUTPUTS
PSCustomObject, one object per input path.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string[]]$Path,

    [Parameter()]
    [ValidateRange(0.0, 86400.0)]
    [double]$WarmupSeconds = 5.0,

    [Parameter()]
    [ValidateRange(0.001, 86400.0)]
    [double]$EncounterSeconds = 30.0,

    [Parameter()]
    [ValidateRange(0, 65535)]
    [uint32]$ExpectedAiCount = 0,

    [Parameter()]
    [ValidateRange(0.0, 1000.0)]
    [double]$TargetFps = 0.0,

    [Parameter()]
    [ValidateRange(0.0, 50.0)]
    [double]$FpsTolerancePercent = 5.0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invariantCulture = [Globalization.CultureInfo]::InvariantCulture
$floatStyles = [Globalization.NumberStyles]::Float
$integerStyles = [Globalization.NumberStyles]::Integer

function ConvertTo-FearAiFiniteDouble {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Column,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][int]$CsvLine
    )

    [double]$parsedValue = 0.0
    if (-not [double]::TryParse($Value, $floatStyles, $invariantCulture, [ref]$parsedValue) -or
        [double]::IsNaN($parsedValue) -or [double]::IsInfinity($parsedValue)) {
        throw "Invalid invariant number in '$Column' at CSV line $CsvLine of '$SourcePath': '$Value'."
    }

    return $parsedValue
}

function ConvertTo-FearAiCount {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Column,
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][int]$CsvLine
    )

    [uint64]$parsedValue = 0
    if (-not [uint64]::TryParse($Value, $integerStyles, $invariantCulture, [ref]$parsedValue)) {
        throw "Invalid non-negative integer in '$Column' at CSV line $CsvLine of '$SourcePath': '$Value'."
    }

    return $parsedValue
}

function Get-FearAiLinearPercentile {
    param(
        [Parameter(Mandatory = $true)][double[]]$Values,
        [Parameter(Mandatory = $true)][ValidateRange(0.0, 100.0)][double]$Percentile
    )

    if ($Values.Count -eq 0) {
        throw 'Cannot calculate a percentile for an empty sample.'
    }

    [double[]]$sortedValues = @($Values | Sort-Object)
    if ($sortedValues.Count -eq 1) {
        return $sortedValues[0]
    }

    $rank = ($Percentile / 100.0) * ($sortedValues.Count - 1)
    $lowerIndex = [int][Math]::Floor($rank)
    $upperIndex = [int][Math]::Ceiling($rank)
    if ($lowerIndex -eq $upperIndex) {
        return $sortedValues[$lowerIndex]
    }

    $fraction = $rank - $lowerIndex
    return $sortedValues[$lowerIndex] + (($sortedValues[$upperIndex] - $sortedValues[$lowerIndex]) * $fraction)
}

function Get-FearAiRoundedMetric {
    param(
        [Parameter(Mandatory = $true)][double]$Value,
        [Parameter()][ValidateRange(0, 12)][int]$Digits = 3
    )

    return [Math]::Round($Value, $Digits, [MidpointRounding]::AwayFromZero)
}

$requiredColumns = @(
    'frame_index',
    'real_time_s',
    'sim_time_s',
    'frame_delta_ms',
    'engine_frame_dt_ms',
    'server_frame_ms',
    'ai_update_count',
    'ai_update_ms',
    'ai_mgr_count',
    'sensor_count',
    'goal_selection_count',
    'navigation_count'
)

foreach ($inputPath in $Path) {
    if ([string]::IsNullOrWhiteSpace($inputPath)) {
        throw 'Profile paths must not be empty or whitespace.'
    }

    $resolvedPath = (Resolve-Path -LiteralPath $inputPath -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $resolvedPath -PathType Leaf)) {
        throw "AI profile path is not a file: '$resolvedPath'."
    }

    $csvRows = @(Import-Csv -LiteralPath $resolvedPath)
    if ($csvRows.Count -eq 0) {
        throw "AI profile contains no data rows: '$resolvedPath'."
    }

    $availableColumns = @($csvRows[0].PSObject.Properties.Name)
    foreach ($requiredColumn in $requiredColumns) {
        if ($requiredColumn -notin $availableColumns) {
            throw "AI profile '$resolvedPath' is missing required column '$requiredColumn'."
        }
    }

    $captureElapsedSeconds = 0.0
    $parsedRows = New-Object 'System.Collections.Generic.List[object]'
    $hasPreviousFrameIndex = $false
    [uint64]$previousFrameIndex = 0

    for ($rowIndex = 0; $rowIndex -lt $csvRows.Count; ++$rowIndex) {
        $csvLine = $rowIndex + 2
        $csvRow = $csvRows[$rowIndex]
        $frameIndex = ConvertTo-FearAiCount -Value $csvRow.frame_index -Column 'frame_index' -SourcePath $resolvedPath -CsvLine $csvLine
        if ($hasPreviousFrameIndex -and $frameIndex -le $previousFrameIndex) {
            throw "Non-increasing frame_index $frameIndex at CSV line $CsvLine of '$resolvedPath' (previous: $previousFrameIndex)."
        }
        $hasPreviousFrameIndex = $true
        $previousFrameIndex = $frameIndex

        $realTimeSeconds = ConvertTo-FearAiFiniteDouble -Value $csvRow.real_time_s -Column 'real_time_s' -SourcePath $resolvedPath -CsvLine $csvLine
        $simTimeSeconds = ConvertTo-FearAiFiniteDouble -Value $csvRow.sim_time_s -Column 'sim_time_s' -SourcePath $resolvedPath -CsvLine $csvLine
        $frameDeltaMs = ConvertTo-FearAiFiniteDouble -Value $csvRow.frame_delta_ms -Column 'frame_delta_ms' -SourcePath $resolvedPath -CsvLine $csvLine
        $engineFrameDeltaMs = ConvertTo-FearAiFiniteDouble -Value $csvRow.engine_frame_dt_ms -Column 'engine_frame_dt_ms' -SourcePath $resolvedPath -CsvLine $csvLine
        $serverFrameMs = ConvertTo-FearAiFiniteDouble -Value $csvRow.server_frame_ms -Column 'server_frame_ms' -SourcePath $resolvedPath -CsvLine $csvLine
        $aiUpdateMs = ConvertTo-FearAiFiniteDouble -Value $csvRow.ai_update_ms -Column 'ai_update_ms' -SourcePath $resolvedPath -CsvLine $csvLine
        foreach ($timing in @(
            [pscustomobject]@{ Name = 'real_time_s'; Value = $realTimeSeconds },
            [pscustomobject]@{ Name = 'sim_time_s'; Value = $simTimeSeconds },
            [pscustomobject]@{ Name = 'frame_delta_ms'; Value = $frameDeltaMs },
            [pscustomobject]@{ Name = 'engine_frame_dt_ms'; Value = $engineFrameDeltaMs },
            [pscustomobject]@{ Name = 'server_frame_ms'; Value = $serverFrameMs },
            [pscustomobject]@{ Name = 'ai_update_ms'; Value = $aiUpdateMs }
        )) {
            if ($timing.Value -lt 0.0) {
                throw "Negative $($timing.Name) at CSV line $csvLine of '$resolvedPath'."
            }
        }

        $frameStartElapsedSeconds = $captureElapsedSeconds
        $captureElapsedSeconds += $frameDeltaMs / 1000.0
        $null = $parsedRows.Add([pscustomobject]@{
            SourceRowIndex          = $rowIndex
            CsvLine                 = $csvLine
            FrameIndex              = $frameIndex
            FrameStartElapsedSeconds = $frameStartElapsedSeconds
            FrameDeltaMs            = $frameDeltaMs
            EngineFrameDeltaMs      = $engineFrameDeltaMs
            RealTimeSeconds         = $realTimeSeconds
            SimTimeSeconds          = $simTimeSeconds
            ServerFrameMs           = $serverFrameMs
            AiUpdateCount           = ConvertTo-FearAiCount -Value $csvRow.ai_update_count -Column 'ai_update_count' -SourcePath $resolvedPath -CsvLine $csvLine
            AiUpdateMs              = $aiUpdateMs
            AiManagerCount          = ConvertTo-FearAiCount -Value $csvRow.ai_mgr_count -Column 'ai_mgr_count' -SourcePath $resolvedPath -CsvLine $csvLine
            SensorCount             = ConvertTo-FearAiCount -Value $csvRow.sensor_count -Column 'sensor_count' -SourcePath $resolvedPath -CsvLine $csvLine
            GoalSelectionCount      = ConvertTo-FearAiCount -Value $csvRow.goal_selection_count -Column 'goal_selection_count' -SourcePath $resolvedPath -CsvLine $csvLine
            NavigationCount         = ConvertTo-FearAiCount -Value $csvRow.navigation_count -Column 'navigation_count' -SourcePath $resolvedPath -CsvLine $csvLine
        })
    }

    $encounterStartIndex = -1
    for ($rowIndex = 0; $rowIndex -lt $parsedRows.Count; ++$rowIndex) {
        $row = $parsedRows[$rowIndex]
        if ($row.FrameStartElapsedSeconds -ge $WarmupSeconds -and
            $row.FrameDeltaMs -gt 0.0 -and
            $row.EngineFrameDeltaMs -gt 0.0 -and
            $row.AiUpdateCount -gt 0) {
            $encounterStartIndex = $rowIndex
            break
        }
    }
    if ($encounterStartIndex -lt 0) {
        throw "AI profile '$resolvedPath' has no positive-duration active simulated frame after the $WarmupSeconds second warmup."
    }

    $encounterRows = New-Object 'System.Collections.Generic.List[object]'
    $encounterWallMs = 0.0
    for ($rowIndex = $encounterStartIndex; $rowIndex -lt $parsedRows.Count; ++$rowIndex) {
        $row = $parsedRows[$rowIndex]
        if ($row.FrameDeltaMs -le 0.0 -or $row.EngineFrameDeltaMs -le 0.0) {
            break
        }

        $null = $encounterRows.Add($row)
        $encounterWallMs += $row.FrameDeltaMs
        if ($encounterWallMs -ge ($EncounterSeconds * 1000.0)) {
            break
        }
    }

    $encounterDurationSeconds = $encounterWallMs / 1000.0
    if ($encounterDurationSeconds -lt $EncounterSeconds) {
        throw "AI profile '$resolvedPath' active simulated encounter ended after $([Math]::Round($encounterDurationSeconds, 6)) seconds; at least $EncounterSeconds seconds were required."
    }

    $observedPositiveCounts = @{}
    foreach ($row in $encounterRows) {
        if ($row.AiUpdateCount -eq 0) {
            continue
        }
        $key = [string]$row.AiUpdateCount
        if (-not $observedPositiveCounts.ContainsKey($key)) {
            $observedPositiveCounts[$key] = 0
        }
        ++$observedPositiveCounts[$key]
    }
    $modalCount = @(
        $observedPositiveCounts.GetEnumerator() |
            Sort-Object @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { [uint64]$_.Key }; Ascending = $true }
    )[0]
    [uint64]$modalAiCount = $modalCount.Key

    $fixedPopulation = $ExpectedAiCount -gt 0
    $populationMode = if ($fixedPopulation) { 'Fixed' } else { 'Dynamic' }
    $expectedAiCountSource = if ($fixedPopulation) { 'Explicit' } else { 'DynamicPopulation' }

    $aiActiveFrames = 0
    [uint64]$aiUpdateTotal = 0
    [uint64]$sensorTotal = 0
    [uint64]$goalSelectionTotal = 0
    [uint64]$navigationTotal = 0
    $aiUpdateTimeTotalMs = 0.0
    $engineFrameTimeTotalMs = 0.0
    $aiCountMismatchFrames = 0
    $aiManagerMismatchFrames = 0
    $sensorCountMismatchFrames = 0
    $sensorVsAiCountMismatchFrames = 0
    $goalCountMismatchFrames = 0
    $navigationBelowAiFrames = 0
    $simTimeRegressionFrames = 0
    $simTimeStallFrames = 0
    $simTimeDiscontinuityFrames = 0
    $simulationTimestampAdvanceMs = 0.0
    $simulationEngineDeltaMs = 0.0
    $currentStarvationFrames = 0
    $currentStarvationMs = 0.0
    $longestStarvationFrames = 0
    $longestStarvationMs = 0.0
    $hasPreviousSimTime = $false
    $previousSimTimeSeconds = 0.0
    [double[]]$serverFrameTimes = @($encounterRows | ForEach-Object { $_.ServerFrameMs })

    foreach ($row in $encounterRows) {
        $engineFrameTimeTotalMs += $row.EngineFrameDeltaMs
        $aiUpdateTotal += $row.AiUpdateCount
        $sensorTotal += $row.SensorCount
        $goalSelectionTotal += $row.GoalSelectionCount
        $navigationTotal += $row.NavigationCount
        $aiUpdateTimeTotalMs += $row.AiUpdateMs

        if ($row.AiUpdateCount -gt 0) {
            ++$aiActiveFrames
            $currentStarvationFrames = 0
            $currentStarvationMs = 0.0
        }
        else {
            ++$currentStarvationFrames
            $currentStarvationMs += $row.FrameDeltaMs
            if ($currentStarvationFrames -gt $longestStarvationFrames) {
                $longestStarvationFrames = $currentStarvationFrames
            }
            if ($currentStarvationMs -gt $longestStarvationMs) {
                $longestStarvationMs = $currentStarvationMs
            }
        }

        if ($fixedPopulation) {
            if ($row.AiUpdateCount -ne $ExpectedAiCount) {
                ++$aiCountMismatchFrames
            }
            if ($row.SensorCount -ne $ExpectedAiCount) {
                ++$sensorCountMismatchFrames
            }
        }
        else {
            if ($row.AiUpdateCount -eq 0) {
                ++$aiCountMismatchFrames
            }
            if ($row.SensorCount -eq 0) {
                ++$sensorCountMismatchFrames
            }
        }
        if ($row.AiManagerCount -ne 1) {
            ++$aiManagerMismatchFrames
        }
        if ($row.SensorCount -ne $row.AiUpdateCount) {
            ++$sensorVsAiCountMismatchFrames
        }
        if ($row.GoalSelectionCount -ne $row.AiUpdateCount) {
            ++$goalCountMismatchFrames
        }
        if ($row.NavigationCount -lt $row.AiUpdateCount) {
            ++$navigationBelowAiFrames
        }
        if ($hasPreviousSimTime) {
            $simulationDeltaMs = ($row.SimTimeSeconds - $previousSimTimeSeconds) * 1000.0
            $simulationTimestampAdvanceMs += $simulationDeltaMs
            $simulationEngineDeltaMs += $row.EngineFrameDeltaMs
            if ($simulationDeltaMs -lt 0.0) {
                ++$simTimeRegressionFrames
            }
            if ($simulationDeltaMs -le 0.0) {
                ++$simTimeStallFrames
            }
            $allowedSimulationDeltaErrorMs = [Math]::Max(0.1, $row.EngineFrameDeltaMs * 0.05)
            if ([Math]::Abs($simulationDeltaMs - $row.EngineFrameDeltaMs) -gt $allowedSimulationDeltaErrorMs) {
                ++$simTimeDiscontinuityFrames
            }
        }
        $hasPreviousSimTime = $true
        $previousSimTimeSeconds = $row.SimTimeSeconds
    }

    $noAiStarvation = $longestStarvationFrames -eq 0
    $aiCountInvariant = $aiCountMismatchFrames -eq 0
    $aiManagerInvariant = $aiManagerMismatchFrames -eq 0
    $sensorCountInvariant = $sensorCountMismatchFrames -eq 0
    $goalCountInvariant = $goalCountMismatchFrames -eq 0
    $navigationCountInvariant = $navigationBelowAiFrames -eq 0
    $simulationTimestampToEngineRatio = if ($simulationEngineDeltaMs -gt 0.0) {
        $simulationTimestampAdvanceMs / $simulationEngineDeltaMs
    }
    else {
        0.0
    }
    $simTimeInvariant = $simTimeRegressionFrames -eq 0 -and $simTimeStallFrames -eq 0 -and
        $simTimeDiscontinuityFrames -eq 0 -and
        $simulationTimestampToEngineRatio -ge 0.995 -and $simulationTimestampToEngineRatio -le 1.005
    $allInvariantsPassed = $noAiStarvation -and $aiCountInvariant -and $aiManagerInvariant -and
        $sensorCountInvariant -and $goalCountInvariant -and $navigationCountInvariant -and $simTimeInvariant

    $achievedFps = $encounterRows.Count / $encounterDurationSeconds
    $fpsGateEnabled = $TargetFps -gt 0.0
    $minimumAcceptedFps = if ($fpsGateEnabled) {
        $TargetFps * (1.0 - ($FpsTolerancePercent / 100.0))
    }
    else {
        $null
    }
    $maximumAcceptedFps = if ($fpsGateEnabled) {
        $TargetFps * (1.0 + ($FpsTolerancePercent / 100.0))
    }
    else {
        $null
    }
    $fpsWithinTolerance = -not $fpsGateEnabled -or
        ($achievedFps -ge $minimumAcceptedFps -and $achievedFps -le $maximumAcceptedFps)
    $allAcceptanceChecksPassed = $allInvariantsPassed -and $fpsWithinTolerance

    [pscustomobject][ordered]@{
        Path                            = $resolvedPath
        WarmupSeconds                   = Get-FearAiRoundedMetric -Value $WarmupSeconds
        RequestedEncounterSeconds       = Get-FearAiRoundedMetric -Value $EncounterSeconds
        EncounterDurationSeconds        = Get-FearAiRoundedMetric -Value $encounterDurationSeconds
        EncounterRows                   = $encounterRows.Count
        FirstFrameIndex                 = $encounterRows[0].FrameIndex
        LastFrameIndex                  = $encounterRows[$encounterRows.Count - 1].FrameIndex
        PopulationMode                  = $populationMode
        ExpectedAiCount                 = $ExpectedAiCount
        ExpectedAiCountSource           = $expectedAiCountSource
        ModalAiCount                    = $modalAiCount
        TargetFps                       = Get-FearAiRoundedMetric -Value $TargetFps
        FpsTolerancePercent             = Get-FearAiRoundedMetric -Value $FpsTolerancePercent
        FpsGateEnabled                  = $fpsGateEnabled
        MinimumAcceptedFps              = if ($fpsGateEnabled) { Get-FearAiRoundedMetric -Value $minimumAcceptedFps } else { $null }
        MaximumAcceptedFps              = if ($fpsGateEnabled) { Get-FearAiRoundedMetric -Value $maximumAcceptedFps } else { $null }
        AchievedFps                     = Get-FearAiRoundedMetric -Value $achievedFps
        FpsWithinTolerance              = $fpsWithinTolerance
        SimulationToWallRatio           = Get-FearAiRoundedMetric -Value ($engineFrameTimeTotalMs / $encounterWallMs) -Digits 6
        SimulationTimestampToEngineRatio = Get-FearAiRoundedMetric -Value $simulationTimestampToEngineRatio -Digits 6
        AIActiveFrameRatio              = Get-FearAiRoundedMetric -Value ($aiActiveFrames / [double]$encounterRows.Count) -Digits 6
        AIUpdatesPerSecond              = Get-FearAiRoundedMetric -Value ($aiUpdateTotal / $encounterDurationSeconds)
        SensorManagerCallsPerSecond     = Get-FearAiRoundedMetric -Value ($sensorTotal / $encounterDurationSeconds)
        GoalSelectionCallsPerSecond     = Get-FearAiRoundedMetric -Value ($goalSelectionTotal / $encounterDurationSeconds)
        NavigationCallsPerSecond        = Get-FearAiRoundedMetric -Value ($navigationTotal / $encounterDurationSeconds)
        MeanAIUpdateMsPerCall           = if ($aiUpdateTotal -eq 0) { $null } else { Get-FearAiRoundedMetric -Value ($aiUpdateTimeTotalMs / $aiUpdateTotal) -Digits 6 }
        ServerFrameMsP95                = Get-FearAiRoundedMetric -Value (Get-FearAiLinearPercentile -Values $serverFrameTimes -Percentile 95)
        ServerFrameMsP99                = Get-FearAiRoundedMetric -Value (Get-FearAiLinearPercentile -Values $serverFrameTimes -Percentile 99)
        LongestAIStarvationFrames       = $longestStarvationFrames
        LongestAIStarvationMs           = Get-FearAiRoundedMetric -Value $longestStarvationMs
        AIUpdateCountMismatchFrames     = $aiCountMismatchFrames
        AIManagerCountMismatchFrames    = $aiManagerMismatchFrames
        SensorCountMismatchFrames       = $sensorCountMismatchFrames
        SensorVsAICountMismatchFrames   = $sensorVsAiCountMismatchFrames
        GoalCountMismatchFrames         = $goalCountMismatchFrames
        NavigationBelowAIFrames         = $navigationBelowAiFrames
        SimulationTimeRegressionFrames  = $simTimeRegressionFrames
        SimulationTimeStallFrames       = $simTimeStallFrames
        SimulationTimeDiscontinuityFrames = $simTimeDiscontinuityFrames
        NoAIStarvation                  = $noAiStarvation
        AIUpdateCountInvariant          = $aiCountInvariant
        AIManagerCountInvariant         = $aiManagerInvariant
        SensorCountInvariant            = $sensorCountInvariant
        SensorMatchesAIInvariant        = $sensorVsAiCountMismatchFrames -eq 0
        GoalCountInvariant              = $goalCountInvariant
        NavigationCountInvariant        = $navigationCountInvariant
        SimulationTimeInvariant         = $simTimeInvariant
        AllInvariantsPassed             = $allInvariantsPassed
        InvariantStatus                 = if ($allInvariantsPassed) { 'PASS' } else { 'FAIL' }
        AllAcceptanceChecksPassed        = $allAcceptanceChecksPassed
        AcceptanceStatus                = if ($allAcceptanceChecksPassed) { 'PASS' } else { 'FAIL' }
    }
}
