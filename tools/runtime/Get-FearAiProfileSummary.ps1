<#
.SYNOPSIS
Summarizes one or more source-owned FearMore AI profile CSV files.

.DESCRIPTION
Reads profiles without modifying them, removes an initial warmup window, and
returns reusable PowerShell objects with frame-cadence, server-frame, and AI
update-rate metrics. When the profiler's AI subsystem timing columns are
present, AIScopeCpu contains a per-scope CPU breakdown. Scope timers can overlap,
so the breakdown deliberately does not sum them into a misleading total.
Numeric CSV fields are always parsed with invariant culture.

.PARAMETER Path
One or more AIProfile CSV file paths.

.PARAMETER WarmupSeconds
Capture time to discard before calculating metrics. The default is five seconds.

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
    [double]$WarmupSeconds = 5.0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invariantCulture = [Globalization.CultureInfo]::InvariantCulture
$floatStyles = [Globalization.NumberStyles]::Float
$integerStyles = [Globalization.NumberStyles]::Integer

function ConvertTo-FiniteDouble {
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

function ConvertTo-Count {
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

function Get-LinearPercentile {
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

function Get-RoundedMetric {
    param(
        [Parameter(Mandatory = $true)][double]$Value,
        [Parameter()][ValidateRange(0, 12)][int]$Digits = 3
    )

    return [Math]::Round($Value, $Digits, [MidpointRounding]::AwayFromZero)
}

$requiredColumns = @(
    'frame_delta_ms',
    'server_frame_ms',
    'ai_update_count',
    'sensor_count',
    'goal_selection_count',
    'navigation_count'
)

$aiScopeColumns = @(
    [pscustomobject]@{ Scope = 'AIUpdate';      TimeColumn = 'ai_update_ms';      CountColumn = 'ai_update_count' }
    [pscustomobject]@{ Scope = 'AIManager';     TimeColumn = 'ai_mgr_ms';         CountColumn = 'ai_mgr_count' }
    [pscustomobject]@{ Scope = 'Sensors';       TimeColumn = 'sensor_ms';         CountColumn = 'sensor_count' }
    [pscustomobject]@{ Scope = 'GoalSelection'; TimeColumn = 'goal_selection_ms'; CountColumn = 'goal_selection_count' }
    [pscustomobject]@{ Scope = 'Navigation';    TimeColumn = 'navigation_ms';     CountColumn = 'navigation_count' }
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

    $availableAiScopes = @($aiScopeColumns | Where-Object { $_.TimeColumn -in $availableColumns })

    $captureElapsedSeconds = 0.0
    $parsedRows = New-Object 'System.Collections.Generic.List[object]'
    for ($rowIndex = 0; $rowIndex -lt $csvRows.Count; $rowIndex++) {
        $csvLine = $rowIndex + 2
        $csvRow = $csvRows[$rowIndex]
        $frameDeltaMs = ConvertTo-FiniteDouble -Value $csvRow.frame_delta_ms -Column 'frame_delta_ms' -SourcePath $resolvedPath -CsvLine $csvLine
        $serverFrameMs = ConvertTo-FiniteDouble -Value $csvRow.server_frame_ms -Column 'server_frame_ms' -SourcePath $resolvedPath -CsvLine $csvLine
        if ($frameDeltaMs -lt 0.0) {
            throw "Negative frame_delta_ms at CSV line $csvLine of '$resolvedPath'."
        }
        if ($serverFrameMs -lt 0.0) {
            throw "Negative server_frame_ms at CSV line $csvLine of '$resolvedPath'."
        }

        $scopeTimes = @{}
        $scopeCounts = @{}
        foreach ($scope in $availableAiScopes) {
            $scopeTimeMs = ConvertTo-FiniteDouble -Value $csvRow.PSObject.Properties[$scope.TimeColumn].Value -Column $scope.TimeColumn -SourcePath $resolvedPath -CsvLine $csvLine
            if ($scopeTimeMs -lt 0.0) {
                throw "Negative $($scope.TimeColumn) at CSV line $csvLine of '$resolvedPath'."
            }

            $scopeTimes[$scope.TimeColumn] = $scopeTimeMs
            if ($scope.CountColumn -in $availableColumns) {
                $scopeCounts[$scope.CountColumn] = ConvertTo-Count -Value $csvRow.PSObject.Properties[$scope.CountColumn].Value -Column $scope.CountColumn -SourcePath $resolvedPath -CsvLine $csvLine
            }
        }

        $frameStartElapsedSeconds = $captureElapsedSeconds
        $captureElapsedSeconds += $frameDeltaMs / 1000.0
        $null = $parsedRows.Add([pscustomobject]@{
            FrameStartElapsedSeconds = $frameStartElapsedSeconds
            CaptureElapsedSeconds = $captureElapsedSeconds
            FrameDeltaMs          = $frameDeltaMs
            ServerFrameMs         = $serverFrameMs
            AiUpdateCount         = ConvertTo-Count -Value $csvRow.ai_update_count -Column 'ai_update_count' -SourcePath $resolvedPath -CsvLine $csvLine
            SensorCount           = ConvertTo-Count -Value $csvRow.sensor_count -Column 'sensor_count' -SourcePath $resolvedPath -CsvLine $csvLine
            GoalSelectionCount    = ConvertTo-Count -Value $csvRow.goal_selection_count -Column 'goal_selection_count' -SourcePath $resolvedPath -CsvLine $csvLine
            NavigationCount       = ConvertTo-Count -Value $csvRow.navigation_count -Column 'navigation_count' -SourcePath $resolvedPath -CsvLine $csvLine
            ScopeTimes            = $scopeTimes
            ScopeCounts           = $scopeCounts
        })
    }

    $stableRows = @($parsedRows | Where-Object {
        $_.FrameDeltaMs -gt 0.0 -and $_.FrameStartElapsedSeconds -ge $WarmupSeconds
    })
    if ($stableRows.Count -eq 0) {
        throw "AI profile '$resolvedPath' has no positive frame intervals after the $WarmupSeconds second warmup (capture duration: $captureElapsedSeconds seconds)."
    }

    $stableDurationSeconds = (($stableRows | Measure-Object -Property FrameDeltaMs -Sum).Sum / 1000.0)
    if ($stableDurationSeconds -le 0.0) {
        throw "AI profile '$resolvedPath' has a non-positive stable duration."
    }

    [double[]]$frameTimes = @($stableRows | ForEach-Object { $_.FrameDeltaMs })
    [double[]]$instantaneousFps = @($stableRows | ForEach-Object { 1000.0 / $_.FrameDeltaMs })
    [double[]]$serverFrameTimes = @($stableRows | ForEach-Object { $_.ServerFrameMs })

    $aiActiveFrames = @($stableRows | Where-Object { $_.AiUpdateCount -gt 0 }).Count
    $aiUpdates = ($stableRows | Measure-Object -Property AiUpdateCount -Sum).Sum
    $sensorUpdates = ($stableRows | Measure-Object -Property SensorCount -Sum).Sum
    $goalSelections = ($stableRows | Measure-Object -Property GoalSelectionCount -Sum).Sum
    $navigationUpdates = ($stableRows | Measure-Object -Property NavigationCount -Sum).Sum

    $aiScopeCpu = @(
        foreach ($scope in $availableAiScopes) {
            [double[]]$scopeFrameTimes = @($stableRows | ForEach-Object { $_.ScopeTimes[$scope.TimeColumn] })
            $scopeTotalMs = ($scopeFrameTimes | Measure-Object -Sum).Sum
            $scopeHasCountColumn = $scope.CountColumn -in $availableColumns
            $scopeCallCounts = if ($scopeHasCountColumn) {
                @($stableRows | ForEach-Object { $_.ScopeCounts[$scope.CountColumn] })
            }
            else {
                @()
            }
            $scopeCallCount = if ($scopeHasCountColumn) {
                ($scopeCallCounts | Measure-Object -Sum).Sum
            }
            else {
                $null
            }
            $scopeActiveFrames = if ($scopeHasCountColumn) {
                @($scopeCallCounts | Where-Object { $_ -gt 0 }).Count
            }
            else {
                @($scopeFrameTimes | Where-Object { $_ -gt 0.0 }).Count
            }

            [pscustomobject][ordered]@{
                Scope             = $scope.Scope
                TimeColumn        = $scope.TimeColumn
                TotalMs           = Get-RoundedMetric -Value $scopeTotalMs
                MsPerSecond       = Get-RoundedMetric -Value ($scopeTotalMs / $stableDurationSeconds)
                FrameMsP50        = Get-RoundedMetric -Value (Get-LinearPercentile -Values $scopeFrameTimes -Percentile 50)
                FrameMsP95        = Get-RoundedMetric -Value (Get-LinearPercentile -Values $scopeFrameTimes -Percentile 95)
                FrameMsP99        = Get-RoundedMetric -Value (Get-LinearPercentile -Values $scopeFrameTimes -Percentile 99)
                MeanMsPerCall     = if ($null -eq $scopeCallCount -or $scopeCallCount -eq 0) { $null } else { Get-RoundedMetric -Value ($scopeTotalMs / $scopeCallCount) -Digits 6 }
                ActiveFrameRatio  = Get-RoundedMetric -Value ($scopeActiveFrames / [double]$stableRows.Count) -Digits 6
                CallCount         = $scopeCallCount
                CallsPerSecond    = if ($null -eq $scopeCallCount) { $null } else { Get-RoundedMetric -Value ($scopeCallCount / $stableDurationSeconds) }
            }
        }
    )

    [pscustomobject][ordered]@{
        Path                       = $resolvedPath
        WarmupSeconds              = Get-RoundedMetric -Value $WarmupSeconds
        TotalRows                  = $csvRows.Count
        StableRows                 = $stableRows.Count
        StableDurationSeconds      = Get-RoundedMetric -Value $stableDurationSeconds
        AchievedFps                = Get-RoundedMetric -Value ($stableRows.Count / $stableDurationSeconds)
        FpsP1                      = Get-RoundedMetric -Value (Get-LinearPercentile -Values $instantaneousFps -Percentile 1)
        FpsP50                     = Get-RoundedMetric -Value (Get-LinearPercentile -Values $instantaneousFps -Percentile 50)
        FpsP99                     = Get-RoundedMetric -Value (Get-LinearPercentile -Values $instantaneousFps -Percentile 99)
        FrameMsP50                 = Get-RoundedMetric -Value (Get-LinearPercentile -Values $frameTimes -Percentile 50)
        FrameMsP95                 = Get-RoundedMetric -Value (Get-LinearPercentile -Values $frameTimes -Percentile 95)
        FrameMsP99                 = Get-RoundedMetric -Value (Get-LinearPercentile -Values $frameTimes -Percentile 99)
        ServerFrameMsP50           = Get-RoundedMetric -Value (Get-LinearPercentile -Values $serverFrameTimes -Percentile 50)
        ServerFrameMsP95           = Get-RoundedMetric -Value (Get-LinearPercentile -Values $serverFrameTimes -Percentile 95)
        ServerFrameMsP99           = Get-RoundedMetric -Value (Get-LinearPercentile -Values $serverFrameTimes -Percentile 99)
        AIActiveFrameRatio         = Get-RoundedMetric -Value ($aiActiveFrames / [double]$stableRows.Count) -Digits 6
        AIUpdatesPerSecond         = Get-RoundedMetric -Value ($aiUpdates / $stableDurationSeconds)
        SensorUpdatesPerSecond     = Get-RoundedMetric -Value ($sensorUpdates / $stableDurationSeconds)
        GoalSelectionsPerSecond   = Get-RoundedMetric -Value ($goalSelections / $stableDurationSeconds)
        NavigationUpdatesPerSecond = Get-RoundedMetric -Value ($navigationUpdates / $stableDurationSeconds)
        AIScopeCpu                 = $aiScopeCpu
    }
}
