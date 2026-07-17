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
$analyzer = Join-Path $RepositoryRoot 'tools\runtime\Analyze-FearCameraCapture.ps1'
if (-not (Test-Path -LiteralPath $analyzer -PathType Leaf)) {
    throw "Camera capture analyzer is missing: $analyzer"
}

function Assert-AnalyzerRejects {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string[]]$D3DLines,
        [Parameter(Mandatory = $true)][string[]]$SourceLines,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage
    )

    $safeName = $Name -replace '[^A-Za-z0-9_-]', '-'
    $rejectionD3DPath = Join-Path $fixtureRoot "reject-$safeName-d3d9.jsonl"
    $rejectionSourcePath = Join-Path $fixtureRoot "reject-$safeName-source.jsonl"
    [IO.File]::WriteAllLines($rejectionD3DPath, $D3DLines, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines($rejectionSourcePath, $SourceLines, [Text.UTF8Encoding]::new($false))

    $rejected = $false
    try {
        $null = & $analyzer -D3D9Path $rejectionD3DPath -SourcePath $rejectionSourcePath -NoShaderDisassembly
    }
    catch {
        if ($_.Exception.Message -notmatch $ExpectedMessage) {
            throw "Analyzer rejected '$Name' for the wrong reason: $($_.Exception.Message)"
        }
        $rejected = $true
    }
    if (-not $rejected) {
        throw "Analyzer accepted invalid capture case '$Name'."
    }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('fear-camera-analyzer-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixtureRoot -Force
try {
    $d3dPath = Join-Path $fixtureRoot 'camera-d3d9-42.jsonl'
    $sourcePath = Join-Path $fixtureRoot 'camera-source-42.jsonl'
    $d3dLines = @(
        '{"event":"capability","schema":1,"capability":"camera-d3d9-setter-capture-v1","pid":42,"qpc":100,"qpcFrequency":1000,"frame":0,"enabled":true,"hooks":{"setRenderTarget":true,"endScene":true,"setTransform":true,"setViewport":true,"drawPrimitive":true,"drawIndexedPrimitive":true,"setVertexShader":true,"setVertexShaderConstantF":true},"stateBlockResync":false}'
        '{"event":"arm","schema":1,"capability":"camera-d3d9-setter-capture-v1","pid":42,"qpc":100,"qpcFrequency":1000,"frame":0,"armingPolicy":"same-pid-source-camera-log-at-end-scene","firstCaptureFrame":0}'
        '{"event":"vertex-shader","schema":1,"pid":42,"qpc":101,"qpcFrequency":1000,"frame":0,"hash":"ABCDEF01","bytes":256}'
        '{"event":"constant-write","schema":1,"pid":42,"qpc":110,"qpcFrequency":1000,"frame":0,"shaderHash":"ABCDEF01","startRegister":72,"endRegisterExclusive":76,"vector4Count":4,"valueCount":16,"loggedValueCount":16,"valuesTruncated":false,"values":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}'
        '{"event":"transform-write","schema":1,"pid":42,"qpc":111,"qpcFrequency":1000,"frame":0,"state":"view","values":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}'
        '{"event":"transform-write","schema":1,"pid":42,"qpc":112,"qpcFrequency":1000,"frame":0,"state":"projection","values":[1.83048772,0,0,0,0,2.36522242,0,0,0,0,1,1,0,0,-4.3,0]}'
        '{"event":"constant-write","schema":1,"pid":42,"qpc":118,"qpcFrequency":1000,"frame":0,"shaderHash":"ABCDEF01","startRegister":0,"endRegisterExclusive":84,"vector4Count":84,"valueCount":336,"loggedValueCount":16,"valuesTruncated":true,"values":[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]}'
        '{"event":"frame","schema":1,"pid":42,"qpc":120,"qpcFrequency":1000,"frame":0,"draws":{"shader":100,"fixedFunction":0,"primitives":500},"setters":{"vertexShader":1,"constants":2,"transforms":0},"viewport":{"width":3440,"height":1440}}'
        '{"event":"frame","schema":1,"pid":42,"qpc":140,"qpcFrequency":1000,"frame":1,"draws":{"shader":90,"fixedFunction":0,"primitives":450},"setters":{"vertexShader":0,"constants":0,"transforms":0},"viewport":{"width":3440,"height":1440}}'
    )
    $sourceLines = @(
        '{"schema":"fearmore.camera-source","version":2,"pid":42,"frame_index":0,"marker":"main_camera_render","qpc_frequency":1000,"qpc_before":105,"qpc_after":115,"render_result":0,"transform":{"position":[0,0,0],"rotation_xyzw":[0,0,0,1],"basis":{"right":[1,0,0],"up":[0,1,0],"forward":[0,0,1]}},"fov_radians":[1.0,0.8],"viewport_normalized":[0,0,1,1],"render_target":{"width":3440,"height":1440},"clip":{"near_z":4.3,"far_z":1000}}'
        '{"schema":"fearmore.camera-source","version":2,"pid":42,"frame_index":1,"marker":"main_camera_render","qpc_frequency":1000,"qpc_before":119,"qpc_after":121,"render_result":0,"transform":{"position":[3,4,0],"rotation_xyzw":[0,0.7071067811865476,0,0.7071067811865476],"basis":{"right":[0,0,-1],"up":[0,1,0],"forward":[1,0,0]}},"fov_radians":[1.0,0.8],"viewport_normalized":[0,0,1,1],"render_target":{"width":3440,"height":1440},"clip":{"near_z":4.3,"far_z":1000}}'
    )
    [IO.File]::WriteAllLines($d3dPath, $d3dLines, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines($sourcePath, $sourceLines, [Text.UTF8Encoding]::new($false))
    $d3dHashBefore = (Get-FileHash -LiteralPath $d3dPath -Algorithm SHA256).Hash
    $sourceHashBefore = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash

    $liveShare = [IO.FileShare]([int][IO.FileShare]::ReadWrite -bor [int][IO.FileShare]::Delete)
    $liveWriter = [IO.FileStream]::new(
        $d3dPath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Write,
        $liveShare
    )
    try {
        $liveWriter.Position = $liveWriter.Length
        $liveResult = & $analyzer -D3D9Path $d3dPath -SourcePath $sourcePath -NoShaderDisassembly
        if ($liveResult.D3D9.Pid -ne 42 -or $liveResult.D3D9.FrameCount -ne 2) {
            throw 'Analyzer did not preserve capture identity while a live writer held the input open.'
        }
    }
    finally {
        $liveWriter.Dispose()
    }

    $result = & $analyzer -D3D9Path $d3dPath -SourcePath $sourcePath -NoShaderDisassembly
    if ($result.D3D9.Pid -ne 42 -or $result.D3D9.FrameCount -ne 2 -or
        $result.D3D9.ConstantRecords -ne 2 -or $result.D3D9.RecoverableConstantRecords -ne 1 -or
        -not $result.D3D9.Armed -or -not $result.D3D9.InstalledHooksVerified) {
        throw 'Analyzer did not preserve the synthetic D3D9 capture identity/counts.'
    }
    if ($result.Activity.Classification -ne 'MainCameraScene' -or
        $result.Activity.MaximumDrawCallsPerFrame -ne 100 -or
        $result.Activity.MaximumPrimitivesPerFrame -ne 500) {
        throw 'Analyzer did not classify the synthetic scene activity from explicit draw evidence.'
    }
    if (-not $result.Source.PidMatches -or -not $result.Source.QpcFrequencyMatches -or
        $result.Source.SchemaVersion -ne 2 -or $result.Source.MainCameraRecords -ne 2 -or
        $result.Source.PostSubmitFrameWindows -ne 1) {
        throw 'Analyzer did not validate the paired source-camera identity.'
    }
    if (-not $result.Source.Motion.CameraVaried -or
        -not $result.Source.Motion.PositionChanged -or
        -not $result.Source.Motion.OrientationChanged -or
        $result.Source.Motion.PositionSamples -ne 2 -or
        $result.Source.Motion.RotationSamples -ne 2 -or
        [Math]::Abs($result.Source.Motion.TotalPositionTravel - 5.0) -gt 0.000001 -or
        [Math]::Abs($result.Source.Motion.TotalAngularTravelDegrees - 90.0) -gt 0.000001) {
        throw 'Analyzer did not report source-camera translation and orientation variation.'
    }
    if ($result.Correlation.ConstantRecordsInsideMainCamera -ne 2 -or
        $result.Correlation.RecoverableConstantRecordsInsideMainCamera -ne 1 -or
        $result.Correlation.ConstantRecordsInsideRenderBracket -ne 1 -or
        $result.Correlation.RecoverableConstantRecordsInsideRenderBracket -ne 1 -or
        $result.Correlation.ConstantRecordsInsidePostSubmitFrameWindow -ne 1 -or
        $result.Correlation.RecoverableConstantRecordsInsidePostSubmitFrameWindow -ne 0 -or
        $result.Correlation.Mode -ne 'RenderBracket' -or
        -not $result.Correlation.TemporalCorrelationReady) {
        throw 'Analyzer did not distinguish strict render-bracket and deferred post-submit frame-window evidence.'
    }

    $unpairedResult = & $analyzer -D3D9Path $d3dPath -NoShaderDisassembly
    if ($unpairedResult.Source.Supplied -or
        $unpairedResult.Source.Motion.PositionSamples -ne 0 -or
        $unpairedResult.Source.Motion.RotationSamples -ne 0 -or
        $unpairedResult.Source.Motion.CameraVaried -or
        @($unpairedResult.Warnings | Where-Object { $_ -match 'No source-camera JSONL' }).Count -ne 1) {
        throw 'Analyzer did not preserve valid D3D9-only analysis with an explicit empty motion summary.'
    }

    $legacySourcePath = Join-Path $fixtureRoot 'camera-source-v1-42.jsonl'
    $legacySourceLines = @($sourceLines | ForEach-Object { $_ -replace '"version":2', '"version":1' })
    [IO.File]::WriteAllLines($legacySourcePath, $legacySourceLines, [Text.UTF8Encoding]::new($false))
    $legacyResult = & $analyzer -D3D9Path $d3dPath -SourcePath $legacySourcePath -NoShaderDisassembly
    if ($legacyResult.Source.SchemaVersion -ne 1 -or
        -not $legacyResult.Correlation.NumericMatrixCorrelationProven) {
        throw 'Analyzer did not preserve read compatibility with internally consistent source schema 1 captures.'
    }

    $windowOnlySourcePath = Join-Path $fixtureRoot 'camera-source-window-only-42.jsonl'
    $windowOnlySourceLines = @(
        '{"schema":"fearmore.camera-source","version":2,"pid":42,"frame_index":0,"marker":"main_camera_render","qpc_frequency":1000,"qpc_before":100,"qpc_after":101,"render_result":0,"transform":{"position":[0,0,0]},"fov_radians":[1.0,0.8],"viewport_normalized":[0,0,1,1],"render_target":{"width":3440,"height":1440}}'
        '{"schema":"fearmore.camera-source","version":2,"pid":42,"frame_index":1,"marker":"main_camera_render","qpc_frequency":1000,"qpc_before":119,"qpc_after":121,"render_result":0,"transform":{"position":[0,0,0]},"fov_radians":[1.0,0.8],"viewport_normalized":[0,0,1,1],"render_target":{"width":3440,"height":1440}}'
    )
    [IO.File]::WriteAllLines($windowOnlySourcePath, $windowOnlySourceLines, [Text.UTF8Encoding]::new($false))
    $windowOnlyHashBefore = (Get-FileHash -LiteralPath $windowOnlySourcePath -Algorithm SHA256).Hash
    $windowOnlyResult = & $analyzer -D3D9Path $d3dPath -SourcePath $windowOnlySourcePath -NoShaderDisassembly
    if ($windowOnlyResult.Correlation.Mode -ne 'PostSubmitFrameWindow' -or
        $windowOnlyResult.Correlation.ConstantRecordsInsideRenderBracket -ne 0 -or
        $windowOnlyResult.Correlation.ConstantRecordsInsidePostSubmitFrameWindow -ne 2 -or
        $windowOnlyResult.Correlation.RecoverableConstantRecordsInsidePostSubmitFrameWindow -ne 1 -or
        -not $windowOnlyResult.Correlation.TemporalCorrelationReady) {
        throw 'Analyzer did not accept recoverable deferred D3D9 work in the post-submit source-frame window.'
    }
    if ($result.Correlation.NamedMatrixSamplesAvailable -or
        -not $result.Correlation.NumericMatrixCorrelationProven -or
        $result.Correlation.SourceAlignedViewTransformMatches -ne 1 -or
        $result.Correlation.SourceAlignedProjectionTransformMatches -ne 1 -or
        $result.Correlation.SourceAlignedFixedFunctionCameraFrames -ne 1) {
        throw 'Analyzer did not keep named shader correlation separate from numeric fixed-function camera proof.'
    }
    if (@($result.Warnings | Where-Object { $_ -match 'truncated' }).Count -ne 1) {
        throw 'Analyzer did not flag the unrecoverable truncated constant payload.'
    }
    if ((Get-FileHash -LiteralPath $d3dPath -Algorithm SHA256).Hash -ne $d3dHashBefore -or
        (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash -ne $sourceHashBefore -or
        (Get-FileHash -LiteralPath $windowOnlySourcePath -Algorithm SHA256).Hash -ne $windowOnlyHashBefore) {
        throw 'Analyzer modified an input capture.'
    }

    Assert-AnalyzerRejects -Name 'missing-arm' `
        -D3DLines @($d3dLines | Where-Object { $_ -notmatch '"event":"arm"' }) `
        -SourceLines $sourceLines -ExpectedMessage 'exactly one arm record'
    Assert-AnalyzerRejects -Name 'late-arm' `
        -D3DLines (@($d3dLines[0]) + @($d3dLines[2..($d3dLines.Count - 1)]) +
            @(($d3dLines[1] -replace '"frame":0', '"frame":1'))) `
        -SourceLines $sourceLines -ExpectedMessage 'arm record must immediately follow'
    Assert-AnalyzerRejects -Name 'failed-hook' `
        -D3DLines @($d3dLines | ForEach-Object { $_ -replace '"setTransform":true', '"setTransform":false' }) `
        -SourceLines $sourceLines -ExpectedMessage "hook 'setTransform'"
    Assert-AnalyzerRejects -Name 'd3d-schema-mismatch' `
        -D3DLines @($d3dLines | ForEach-Object { $_ -replace '"event":"vertex-shader","schema":1', '"event":"vertex-shader","schema":2' }) `
        -SourceLines $sourceLines -ExpectedMessage 'unsupported schema'
    Assert-AnalyzerRejects -Name 'd3d-pid-mismatch' `
        -D3DLines @($d3dLines | ForEach-Object { $_ -replace '"pid":42,"qpc":110', '"pid":43,"qpc":110' }) `
        -SourceLines $sourceLines -ExpectedMessage 'PID 43 does not match capability PID 42'
    Assert-AnalyzerRejects -Name 'd3d-frequency-mismatch' `
        -D3DLines @($d3dLines | ForEach-Object { $_ -replace '"qpc":101,"qpcFrequency":1000', '"qpc":101,"qpcFrequency":999' }) `
        -SourceLines $sourceLines -ExpectedMessage 'QPC frequency 999 does not match capability frequency 1000'
    Assert-AnalyzerRejects -Name 'd3d-frame-regression' `
        -D3DLines @($d3dLines + '{"event":"constant-write","schema":1,"pid":42,"qpc":141,"qpcFrequency":1000,"frame":0}') `
        -SourceLines $sourceLines -ExpectedMessage 'regresses from frame 1 to frame 0'
    Assert-AnalyzerRejects -Name 'source-version-mismatch' -D3DLines $d3dLines `
        -SourceLines @($sourceLines | ForEach-Object { $_ -replace '"version":2,"pid":42,"frame_index":1', '"version":1,"pid":42,"frame_index":1' }) `
        -ExpectedMessage 'version 1 does not match capture version 2'
    Assert-AnalyzerRejects -Name 'source-pid-mismatch' -D3DLines $d3dLines `
        -SourceLines @($sourceLines | ForEach-Object { $_ -replace '"pid":42,"frame_index":1', '"pid":43,"frame_index":1' }) `
        -ExpectedMessage 'PID 43 does not match capture PID 42'
    Assert-AnalyzerRejects -Name 'source-frequency-mismatch' -D3DLines $d3dLines `
        -SourceLines @($sourceLines | ForEach-Object { $_ -replace '"frame_index":1,"marker":"main_camera_render","qpc_frequency":1000', '"frame_index":1,"marker":"main_camera_render","qpc_frequency":999' }) `
        -ExpectedMessage 'QPC frequency 999 does not match capture frequency 1000'
    Assert-AnalyzerRejects -Name 'source-frame-regression' -D3DLines $d3dLines `
        -SourceLines @($sourceLines | ForEach-Object { $_ -replace '"frame_index":1', '"frame_index":0' }) `
        -ExpectedMessage 'does not advance beyond frame 0'

    [pscustomobject]@{
        Status = 'PASS'
        ReadOnlyInputsVerified = $true
        LiveWriterReadSharingVerified = $true
        PairedPidAndQpcVerified = $true
        ArmAndHookGateVerified = $true
        PerRecordSchemaIdentityAndFrameOrderVerified = $true
        SourceCameraMotionVerified = $true
        D3D9OnlyAnalysisPreserved = $true
        LegacySourceSchemaReadCompatibilityVerified = $true
        MainCameraBracketCorrelationVerified = $true
        DeferredFrameWindowCorrelationVerified = $true
        NumericFixedFunctionCameraCorrelationVerified = $true
        TruncatedPayloadGateVerified = $true
        ShaderDisassemblySkipped = $true
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force
    }
}
