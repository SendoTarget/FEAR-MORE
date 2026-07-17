[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$analyzer = Join-Path $RepositoryRoot 'tools\runtime\Get-FearAiEncounterAcceptance.ps1'
if (-not (Test-Path -LiteralPath $analyzer -PathType Leaf)) {
    throw "AI encounter acceptance analyzer is missing: $analyzer"
}

function Assert-Near {
    param(
        [Parameter(Mandatory = $true)][double]$Actual,
        [Parameter(Mandatory = $true)][double]$Expected,
        [Parameter(Mandatory = $true)][double]$Tolerance,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ([Math]::Abs($Actual - $Expected) -gt $Tolerance) {
        throw "$Message Expected $Expected +/- $Tolerance but found $Actual."
    }
}

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage,
        [Parameter(Mandatory = $true)][string]$Description
    )

    try {
        & $Action | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch $ExpectedMessage) {
            throw "$Description failed for the wrong reason: $($_.Exception.Message)"
        }
        return
    }
    throw "$Description was unexpectedly accepted."
}

function New-SyntheticProfile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter()][ValidateRange(1, 1000)][int]$EncounterRows = 100,
        [switch]$IncludeStarvation,
        [switch]$DynamicPopulation,
        [switch]$FreezeSimulation,
        [switch]$JumpSimulation,
        [switch]$OmitEngineFrameDelta
    )

    $columns = @(
        'frame_index', 'real_time_s', 'sim_time_s', 'frame_delta_ms',
        'engine_frame_dt_ms', 'server_frame_ms', 'ai_update_count', 'ai_update_ms',
        'ai_mgr_count', 'sensor_count', 'goal_selection_count', 'navigation_count'
    )
    if ($OmitEngineFrameDelta) {
        $columns = @($columns | Where-Object { $_ -ne 'engine_frame_dt_ms' })
    }

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $null = $lines.Add(($columns -join ','))
    $frameIndex = 0
    $realTimeSeconds = 0.0
    $simTimeSeconds = 0.0

    for ($warmupRow = 0; $warmupRow -lt 5; ++$warmupRow) {
        $values = [ordered]@{
            frame_index         = $frameIndex
            real_time_s         = $realTimeSeconds.ToString('F6', [Globalization.CultureInfo]::InvariantCulture)
            sim_time_s          = $simTimeSeconds.ToString('F6', [Globalization.CultureInfo]::InvariantCulture)
            frame_delta_ms      = '100.000000'
            engine_frame_dt_ms  = '0.000000'
            server_frame_ms     = '0.100000'
            ai_update_count     = '0'
            ai_update_ms        = '0.000000'
            ai_mgr_count        = '0'
            sensor_count        = '0'
            goal_selection_count = '0'
            navigation_count    = '0'
        }
        $null = $lines.Add((@($columns | ForEach-Object { $values[$_] }) -join ','))
        ++$frameIndex
        $realTimeSeconds += 0.1
    }

    for ($encounterRow = 0; $encounterRow -lt $EncounterRows; ++$encounterRow) {
        $starved = $IncludeStarvation -and $encounterRow -ge 30 -and $encounterRow -le 32
        $authoredAiCount = if ($DynamicPopulation -and $encounterRow -ge 50) { 3 } else { 2 }
        $aiCount = if ($starved) { 0 } else { $authoredAiCount }
        $sensorCount = if ($DynamicPopulation -and $encounterRow -eq 50) { 2 } else { $authoredAiCount }
        $serverFrameMs = ($encounterRow + 1) / 100.0
        $values = [ordered]@{
            frame_index         = $frameIndex
            real_time_s         = $realTimeSeconds.ToString('F6', [Globalization.CultureInfo]::InvariantCulture)
            sim_time_s          = $simTimeSeconds.ToString('F6', [Globalization.CultureInfo]::InvariantCulture)
            frame_delta_ms      = '10.000000'
            engine_frame_dt_ms  = '10.000000'
            server_frame_ms     = $serverFrameMs.ToString('F6', [Globalization.CultureInfo]::InvariantCulture)
            ai_update_count     = [string]$aiCount
            ai_update_ms        = if ($starved) { '0.000000' } else { '0.010000' }
            ai_mgr_count        = '1'
            sensor_count        = [string]$sensorCount
            goal_selection_count = [string]$aiCount
            navigation_count    = [string]$aiCount
        }
        $null = $lines.Add((@($columns | ForEach-Object { $values[$_] }) -join ','))
        ++$frameIndex
        $realTimeSeconds += 0.01
        if (-not ($FreezeSimulation -and $encounterRow -ge 30 -and $encounterRow -le 32)) {
            $simTimeSeconds += 0.01
        }
        if ($JumpSimulation -and $encounterRow -eq 50) {
            $simTimeSeconds += 1.0
        }
    }

    [IO.File]::WriteAllLines($Path, $lines, [Text.UTF8Encoding]::new($false))
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('fear-ai-encounter-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixtureRoot -Force
try {
    $validPath = Join-Path $fixtureRoot 'valid.csv'
    New-SyntheticProfile -Path $validPath
    $validHashBefore = (Get-FileHash -LiteralPath $validPath -Algorithm SHA256).Hash

    $valid = & $analyzer -Path $validPath -WarmupSeconds 0.5 -EncounterSeconds 1.0 -ExpectedAiCount 2 -TargetFps 100
    if ($valid.InvariantStatus -ne 'PASS' -or -not $valid.AllInvariantsPassed -or
        $valid.AcceptanceStatus -ne 'PASS' -or -not $valid.AllAcceptanceChecksPassed -or
        $valid.EncounterRows -ne 100 -or $valid.FirstFrameIndex -ne 5 -or $valid.LastFrameIndex -ne 104 -or
        $valid.PopulationMode -ne 'Fixed' -or $valid.ExpectedAiCount -ne 2 -or
        $valid.ExpectedAiCountSource -ne 'Explicit' -or $valid.ModalAiCount -ne 2 -or
        -not $valid.FpsGateEnabled -or -not $valid.FpsWithinTolerance -or
        $valid.LongestAIStarvationFrames -ne 0 -or $valid.LongestAIStarvationMs -ne 0.0 -or
        $valid.AIUpdateCountMismatchFrames -ne 0 -or $valid.AIManagerCountMismatchFrames -ne 0 -or
        $valid.SensorCountMismatchFrames -ne 0 -or $valid.SensorVsAICountMismatchFrames -ne 0 -or
        $valid.GoalCountMismatchFrames -ne 0 -or
        $valid.NavigationBelowAIFrames -ne 0 -or $valid.SimulationTimeRegressionFrames -ne 0 -or
        $valid.SimulationTimeStallFrames -ne 0 -or $valid.SimulationTimeDiscontinuityFrames -ne 0) {
        throw 'The valid synthetic encounter did not preserve its expected identity and invariants.'
    }
    Assert-Near -Actual $valid.AchievedFps -Expected 100.0 -Tolerance 0.001 -Message 'Achieved FPS changed.'
    Assert-Near -Actual $valid.MinimumAcceptedFps -Expected 95.0 -Tolerance 0.001 -Message 'Minimum accepted FPS changed.'
    Assert-Near -Actual $valid.MaximumAcceptedFps -Expected 105.0 -Tolerance 0.001 -Message 'Maximum accepted FPS changed.'
    Assert-Near -Actual $valid.SimulationToWallRatio -Expected 1.0 -Tolerance 0.000001 -Message 'Simulation/wall ratio changed.'
    Assert-Near -Actual $valid.SimulationTimestampToEngineRatio -Expected 1.0 -Tolerance 0.000001 -Message 'Simulation timestamp/engine ratio changed.'
    Assert-Near -Actual $valid.AIActiveFrameRatio -Expected 1.0 -Tolerance 0.000001 -Message 'AI active-frame ratio changed.'
    Assert-Near -Actual $valid.MeanAIUpdateMsPerCall -Expected 0.005 -Tolerance 0.000001 -Message 'Mean AI-update time changed.'
    Assert-Near -Actual $valid.ServerFrameMsP95 -Expected 0.950 -Tolerance 0.001 -Message 'Server P95 changed.'
    Assert-Near -Actual $valid.ServerFrameMsP99 -Expected 0.990 -Tolerance 0.001 -Message 'Server P99 changed.'

    $autoExpected = & $analyzer -Path $validPath -WarmupSeconds 0.5 -EncounterSeconds 1.0
    if ($autoExpected.PopulationMode -ne 'Dynamic' -or $autoExpected.ExpectedAiCount -ne 0 -or
        $autoExpected.ExpectedAiCountSource -ne 'DynamicPopulation' -or $autoExpected.ModalAiCount -ne 2 -or
        $autoExpected.FpsGateEnabled -or -not $autoExpected.FpsWithinTolerance -or
        -not $autoExpected.AllInvariantsPassed -or -not $autoExpected.AllAcceptanceChecksPassed) {
        throw 'Dynamic-population acceptance changed for a stable population.'
    }

    $underTarget = & $analyzer -Path $validPath -WarmupSeconds 0.5 -EncounterSeconds 1.0 -TargetFps 120
    if (-not $underTarget.AllInvariantsPassed -or $underTarget.InvariantStatus -ne 'PASS' -or
        $underTarget.FpsWithinTolerance -or $underTarget.AllAcceptanceChecksPassed -or
        $underTarget.AcceptanceStatus -ne 'FAIL') {
        throw 'The FPS acceptance gate did not reject an encounter below its target band independently of AI invariants.'
    }
    $overTarget = & $analyzer -Path $validPath -WarmupSeconds 0.5 -EncounterSeconds 1.0 -TargetFps 80
    if (-not $overTarget.AllInvariantsPassed -or $overTarget.InvariantStatus -ne 'PASS' -or
        $overTarget.FpsWithinTolerance -or $overTarget.AllAcceptanceChecksPassed -or
        $overTarget.AcceptanceStatus -ne 'FAIL') {
        throw 'The FPS acceptance gate did not reject an encounter above its target band independently of AI invariants.'
    }

    $dynamicPath = Join-Path $fixtureRoot 'dynamic.csv'
    New-SyntheticProfile -Path $dynamicPath -DynamicPopulation
    $dynamicHashBefore = (Get-FileHash -LiteralPath $dynamicPath -Algorithm SHA256).Hash
    $dynamic = & $analyzer -Path $dynamicPath -WarmupSeconds 0.5 -EncounterSeconds 1.0
    if ($dynamic.InvariantStatus -ne 'PASS' -or -not $dynamic.AllInvariantsPassed -or
        $dynamic.PopulationMode -ne 'Dynamic' -or $dynamic.ExpectedAiCount -ne 0 -or
        $dynamic.ModalAiCount -ne 2 -or $dynamic.AIUpdateCountMismatchFrames -ne 0 -or
        $dynamic.SensorCountMismatchFrames -ne 0 -or $dynamic.SensorVsAICountMismatchFrames -ne 1 -or
        $dynamic.SensorMatchesAIInvariant -or -not $dynamic.NoAIStarvation) {
        throw 'The authored dynamic population did not preserve continuous owner acceptance and mismatch diagnostics.'
    }
    $dynamicFixed = & $analyzer -Path $dynamicPath -WarmupSeconds 0.5 -EncounterSeconds 1.0 -ExpectedAiCount 2
    if ($dynamicFixed.InvariantStatus -ne 'FAIL' -or $dynamicFixed.AllInvariantsPassed -or
        $dynamicFixed.AIUpdateCountMismatchFrames -ne 50 -or $dynamicFixed.SensorCountMismatchFrames -ne 49) {
        throw 'Explicit fixed-population acceptance no longer rejects an authored population change.'
    }

    $starvedPath = Join-Path $fixtureRoot 'starved.csv'
    New-SyntheticProfile -Path $starvedPath -IncludeStarvation
    $starvedHashBefore = (Get-FileHash -LiteralPath $starvedPath -Algorithm SHA256).Hash
    $starved = & $analyzer -Path $starvedPath -WarmupSeconds 0.5 -EncounterSeconds 1.0 -ExpectedAiCount 2
    if ($starved.InvariantStatus -ne 'FAIL' -or $starved.AllInvariantsPassed -or $starved.NoAIStarvation -or
        $starved.AIUpdateCountInvariant -or $starved.LongestAIStarvationFrames -ne 3 -or
        $starved.LongestAIStarvationMs -ne 30.0 -or $starved.AIUpdateCountMismatchFrames -ne 3 -or
        -not $starved.AIManagerCountInvariant -or -not $starved.SensorCountInvariant -or
        -not $starved.GoalCountInvariant -or -not $starved.NavigationCountInvariant) {
        throw 'The synthetic starvation run was not isolated from the healthy owner invariants.'
    }
    Assert-Near -Actual $starved.AIActiveFrameRatio -Expected 0.97 -Tolerance 0.000001 -Message 'Starved active-frame ratio changed.'
    $dynamicStarved = & $analyzer -Path $starvedPath -WarmupSeconds 0.5 -EncounterSeconds 1.0
    if ($dynamicStarved.InvariantStatus -ne 'FAIL' -or $dynamicStarved.AIUpdateCountMismatchFrames -ne 3 -or
        $dynamicStarved.LongestAIStarvationFrames -ne 3 -or $dynamicStarved.NoAIStarvation) {
        throw 'Dynamic-population mode hid AI starvation.'
    }

    $frozenSimulationPath = Join-Path $fixtureRoot 'frozen-simulation.csv'
    New-SyntheticProfile -Path $frozenSimulationPath -FreezeSimulation
    $frozenSimulationHashBefore = (Get-FileHash -LiteralPath $frozenSimulationPath -Algorithm SHA256).Hash
    $frozenSimulation = & $analyzer -Path $frozenSimulationPath -WarmupSeconds 0.5 -EncounterSeconds 1.0 -TargetFps 100
    if ($frozenSimulation.InvariantStatus -ne 'FAIL' -or $frozenSimulation.AllInvariantsPassed -or
        $frozenSimulation.SimulationTimeInvariant -or $frozenSimulation.SimulationTimeStallFrames -ne 3 -or
        $frozenSimulation.SimulationTimeDiscontinuityFrames -ne 3 -or
        -not $frozenSimulation.AIUpdateCountInvariant -or -not $frozenSimulation.NoAIStarvation) {
        throw 'Frozen simulation timestamps were not rejected independently of healthy AI-owner cadence.'
    }

    $jumpedSimulationPath = Join-Path $fixtureRoot 'jumped-simulation.csv'
    New-SyntheticProfile -Path $jumpedSimulationPath -JumpSimulation
    $jumpedSimulationHashBefore = (Get-FileHash -LiteralPath $jumpedSimulationPath -Algorithm SHA256).Hash
    $jumpedSimulation = & $analyzer -Path $jumpedSimulationPath -WarmupSeconds 0.5 -EncounterSeconds 1.0 -TargetFps 100
    if ($jumpedSimulation.InvariantStatus -ne 'FAIL' -or $jumpedSimulation.AllInvariantsPassed -or
        $jumpedSimulation.SimulationTimeInvariant -or $jumpedSimulation.SimulationTimeStallFrames -ne 0 -or
        $jumpedSimulation.SimulationTimeDiscontinuityFrames -ne 1 -or
        -not $jumpedSimulation.AIUpdateCountInvariant -or -not $jumpedSimulation.NoAIStarvation) {
        throw 'Discontinuous simulation timestamps were not rejected independently of healthy AI-owner cadence.'
    }

    $shortPath = Join-Path $fixtureRoot 'short.csv'
    New-SyntheticProfile -Path $shortPath -EncounterRows 50
    Assert-Rejected -Action {
        & $analyzer -Path $shortPath -WarmupSeconds 0.5 -EncounterSeconds 1.0 -ExpectedAiCount 2
    } -ExpectedMessage 'ended after 0.5 seconds' -Description 'Short encounter'

    $missingColumnPath = Join-Path $fixtureRoot 'missing-column.csv'
    New-SyntheticProfile -Path $missingColumnPath -OmitEngineFrameDelta
    Assert-Rejected -Action {
        & $analyzer -Path $missingColumnPath -WarmupSeconds 0.5 -EncounterSeconds 1.0 -ExpectedAiCount 2
    } -ExpectedMessage "missing required column 'engine_frame_dt_ms'" -Description 'Missing simulated-frame column'

    if ((Get-FileHash -LiteralPath $validPath -Algorithm SHA256).Hash -ne $validHashBefore -or
        (Get-FileHash -LiteralPath $starvedPath -Algorithm SHA256).Hash -ne $starvedHashBefore -or
        (Get-FileHash -LiteralPath $dynamicPath -Algorithm SHA256).Hash -ne $dynamicHashBefore -or
        (Get-FileHash -LiteralPath $frozenSimulationPath -Algorithm SHA256).Hash -ne $frozenSimulationHashBefore -or
        (Get-FileHash -LiteralPath $jumpedSimulationPath -Algorithm SHA256).Hash -ne $jumpedSimulationHashBefore) {
        throw 'The AI encounter analyzer modified an input capture.'
    }

    [pscustomobject]@{
        Status                         = 'PASS'
        ActiveEncounterCropVerified    = $true
        ModalPopulationVerified        = $true
        DynamicPopulationVerified      = $true
        StarvationPreserved            = $true
        OwnerInvariantsVerified         = $true
        FpsGateVerified                 = $true
        SimulationTimestampVerified     = $true
        PercentilesVerified             = $true
        ShortCaptureRejected            = $true
        MissingColumnRejected           = $true
        ReadOnlyInputsVerified           = $true
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
