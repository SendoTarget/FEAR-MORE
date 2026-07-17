[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$LogPath,
    [string]$RemixLogPath,
    [switch]$SourceOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaVersion = 3
$maximumFrames = 3600
$maximumLogBytes = 64MB
$maximumJsonLineCharacters = 16384
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
$hookVtableSlots = [ordered]@{
    setRenderTarget          = 37
    endScene                 = 42
    setTransform             = 44
    setViewport              = 47
    drawPrimitive            = 81
    drawIndexedPrimitive     = 82
    setVertexShader          = 92
    setVertexShaderConstantF = 94
}

function Resolve-ExistingFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $candidate = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $BasePath $Path }
    $resolved = [IO.Path]::GetFullPath($candidate)
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "$Description is missing: $resolved"
    }
    return $resolved
}

function Assert-TextFragments {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string[]]$Fragments,
        [Parameter(Mandatory = $true)][string]$Description
    )

    foreach ($fragment in $Fragments) {
        if (-not $Text.Contains($fragment)) {
            throw "$Description is missing required contract fragment: $fragment"
        }
    }
}

function Assert-ExactProperties {
    param(
        [Parameter(Mandatory = $true)]$Value,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($null -eq $Value) {
        throw "$Description is null."
    }
    $actualNames = @($Value.PSObject.Properties.Name | Sort-Object)
    $expectedNames = @($Expected | Sort-Object)
    $difference = @(Compare-Object -ReferenceObject $expectedNames -DifferenceObject $actualNames)
    if ($difference.Count -ne 0) {
        throw "$Description properties are not schema-$schemaVersion exact. Expected [$($expectedNames -join ', ')], found [$($actualNames -join ', ')]."
    }
}

function Assert-Boolean {
    param($Value, [string]$Description)
    if ($Value -isnot [bool]) {
        throw "$Description must be a JSON boolean."
    }
}

function Assert-IntegerRange {
    param(
        $Value,
        [long]$Minimum,
        [long]$Maximum,
        [string]$Description
    )

    $integerTypes = @([byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64])
    $isInteger = $false
    foreach ($integerType in $integerTypes) {
        if ($Value -is $integerType) {
            $isInteger = $true
            break
        }
    }
    if (-not $isInteger -or [decimal]$Value -lt $Minimum -or [decimal]$Value -gt $Maximum) {
        throw "$Description must be an integer in [$Minimum, $Maximum]; found '$Value'."
    }
}

function Assert-FiniteNumber {
    param($Value, [string]$Description)
    $numericTypes = @(
        [byte], [sbyte], [int16], [uint16], [int32], [uint32], [int64], [uint64],
        [single], [double], [decimal]
    )
    $isNumeric = $false
    foreach ($numericType in $numericTypes) {
        if ($Value -is $numericType) {
            $isNumeric = $true
            break
        }
    }
    if (-not $isNumeric) {
        throw "$Description must be a JSON number."
    }
    $number = [double]$Value
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) {
        throw "$Description must be finite."
    }
}

function Assert-ClipVector {
    param(
        $Value,
        [bool]$ClipFinite,
        [bool]$ClipPresent,
        [string]$Description
    )

    $clip = @($Value)
    if ($clip.Count -ne 16) {
        throw "$Description must contain exactly 16 values."
    }
    $nullClipValues = 0
    for ($index = 0; $index -lt $clip.Count; ++$index) {
        if ($null -eq $clip[$index]) {
            ++$nullClipValues
            continue
        }
        Assert-FiniteNumber -Value $clip[$index] -Description "$Description[$index]"
    }
    if ($ClipFinite -and $nullClipValues -gt 0) {
        throw "$Description is marked finite but contains JSON null values."
    }
    if (-not $ClipFinite -and $nullClipValues -eq 0 -and $ClipPresent) {
        throw "$Description is marked nonfinite but does not identify a nonfinite component with JSON null."
    }
}

[object[]]$nonFiniteClipSelfTest = @($null, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
Assert-ClipVector -Value $nonFiniteClipSelfTest -ClipFinite $false -ClipPresent $true -Description 'Clip null schema self-test'
$finiteClipAcceptedNull = $false
try {
    Assert-ClipVector -Value $nonFiniteClipSelfTest -ClipFinite $true -ClipPresent $true -Description 'Clip null schema self-test'
    $finiteClipAcceptedNull = $true
}
catch {
    if (-not $_.Exception.Message.Contains('marked finite but contains JSON null')) { throw }
}
if ($finiteClipAcceptedNull) {
    throw 'Clip-vector schema validation accepted JSON null while clipFinite was true.'
}

$booleanAcceptedAsNumber = $false
try {
    Assert-FiniteNumber -Value $true -Description 'Finite-number schema self-test'
    $booleanAcceptedAsNumber = $true
}
catch {
    if (-not $_.Exception.Message.Contains('must be a JSON number')) { throw }
}
if ($booleanAcceptedAsNumber) {
    throw 'Finite-number schema validation accepted a JSON boolean.'
}

$stringAcceptedAsInteger = $false
try {
    Assert-IntegerRange -Value ([string]$schemaVersion) -Minimum $schemaVersion -Maximum $schemaVersion -Description 'Integer schema self-test'
    $stringAcceptedAsInteger = $true
}
catch {
    if (-not $_.Exception.Message.Contains('must be an integer')) { throw }
}
if ($stringAcceptedAsInteger) {
    throw 'Integer schema validation accepted a JSON string.'
}

function Assert-HexIdentity {
    param($Value, [string]$Description)
    if ($Value -isnot [string] -or $Value -notmatch '^[0-9A-F]{8}$') {
        throw "$Description must be an eight-digit uppercase hexadecimal string."
    }
}

function Test-ProjectOwnedProbeContract {
    param([string]$Root)

    $contractFiles = [ordered]@{
        Patch = Join-Path $Root 'patches\echopatch\0003-add-remix-camera-diagnostics.patch'
        Overlay = Join-Path $Root 'tools\echopatch\overlays\RemixCameraDiagnostics.cpp'
        Build = Join-Path $Root 'tools\echopatch\Build-EngineOnlyEchoPatch.ps1'
        ProfileOverride = Join-Path $Root 'tools\echopatch\EchoPatch.remix-diagnostics.override.ini'
    }
    foreach ($entry in $contractFiles.GetEnumerator()) {
        if (-not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
            throw "Project-owned RTX camera probe $($entry.Key) is missing: $($entry.Value)"
        }
    }

    $patchText = Get-Content -LiteralPath $contractFiles.Patch -Raw
    Assert-TextFragments -Text $patchText -Description 'RTX camera diagnostics patch' -Fragments @(
        'bool EnableRemixCameraDiagnostics = false;',
        'IniHelper::ReadInteger("Diagnostics", "RemixCameraDiagnostics", 0)',
        '#include "Engine/RemixDiagnostics/RemixCameraDiagnostics.cpp"',
        'InstallRemixCameraDiagnostics(device);',
        '!EnableRemixCameraDiagnostics'
    )

    $overlayText = Get-Content -LiteralPath $contractFiles.Overlay -Raw
    foreach ($hook in $hookVtableSlots.GetEnumerator()) {
        $slotFragment = "InstallHook(vtable[$($hook.Value)]"
        if (-not $overlayText.Contains($slotFragment)) {
            throw "RTX camera diagnostics overlay does not install $($hook.Key) at IDirect3DDevice9 vtable slot $($hook.Value)."
        }
        $capabilityHookFragment = '\' + '"' + $hook.Key + '\' + '"'
        if (-not $overlayText.Contains($capabilityHookFragment)) {
            throw "RTX camera diagnostics capability record does not report hook '$($hook.Key)'."
        }
    }
    Assert-TextFragments -Text $overlayText -Description 'RTX camera diagnostics overlay' -Fragments @(
        'fearmore-camera-%lu.jsonl',
        '{\"event\":\"capability\",\"schema\":3',
        '{\"event\":\"frame\",\"schema\":3',
        's_Frame.frameNumber >= 3600',
        '\"boundedFrames\":3600',
        'static constexpr UINT clipStart = 72;',
        'static constexpr UINT clipEnd = 76;',
        's_ClipRegisterRowMask |=',
        's_HaveClipRegisters = s_ClipRegisterRowMask == 0x0Fu;',
        'static DrawState CaptureDrawState(IDirect3DDevice9* device)',
        'state.vertexShaderKnown = SUCCEEDED(device->GetVertexShader(&shader));',
        'state.worldPresent = SUCCEEDED(device->GetTransform(D3DTS_WORLD, &state.world));',
        'state.viewPresent = SUCCEEDED(device->GetTransform(D3DTS_VIEW, &state.view));',
        'state.projectionPresent = SUCCEEDED(device->GetTransform(D3DTS_PROJECTION, &state.projection));',
        'state.clipRegistersPresent = SUCCEEDED(device->GetVertexShaderConstantF(',
        'const DrawState drawState = CaptureDrawState(device);',
        'static void FormatJsonFloat(float value, char* buffer, size_t bufferSize)',
        'strcpy_s(buffer, bufferSize, "null");',
        'device->GetVertexShader(&initialVertexShader)',
        'device->GetVertexShaderConstantF(72',
        '\"ffpWithCamera\":%u',
        '\"ffpCameraAtDrawPresent\":%s',
        's_FrameFfpCameraView = drawState.view;',
        's_FrameFfpCameraProjection = drawState.projection;',
        '\"nonZeroClipRegisterWrites\":%u',
        '\"frameCandidatePresent\":%s',
        '\"frameCandidateDraws\":%u',
        '\"frameCandidateShaderHash\":\"%08X\"',
        'static bool IsDegenerate(const D3DMATRIX& matrix)',
        '\"worldUsable\":%s',
        's_HaveWorld = SUCCEEDED(device->GetTransform(D3DTS_WORLD, &s_World));'
    )
    if ($overlayText.Contains('s_ShaderIdentities')) {
        throw 'RTX camera diagnostics overlay still caches shader identities by an unowned COM pointer.'
    }
    foreach ($drawHookName in @('DrawPrimitiveHook', 'DrawIndexedPrimitiveHook')) {
        $drawHookPattern = '(?s)static HRESULT WINAPI ' + [regex]::Escape($drawHookName) +
            '.*?const DrawState drawState = CaptureDrawState\(device\);.*?CountDraw\(drawState, primitiveCount\);'
        if ($overlayText -notmatch $drawHookPattern) {
            throw "RTX camera diagnostics $drawHookName does not classify successful draws from freshly queried state."
        }
    }

    $buildText = Get-Content -LiteralPath $contractFiles.Build -Raw
    Assert-TextFragments -Text $buildText -Description 'EchoPatch isolated build workflow' -Fragments @(
        '[switch]$RemixCameraDiagnostics',
        '0003-add-remix-camera-diagnostics.patch',
        'overlays\RemixCameraDiagnostics.cpp',
        'EchoPatch.remix-diagnostics.override.ini',
        '$diagnosticCheckOutput = & git',
        '$diagnosticApplyOutput = & git',
        '$binaryText.Contains($RemixDiagnosticsProof)',
        '$manifest.packageMode = "RemixDiagnosticEchoPatch"',
        '$manifest.remixCameraDiagnostics = $true',
        '$manifest.remixDiagnosticsPatchSha256',
        '$manifest.remixDiagnosticsOverlaySha256'
    )

    $overrideText = Get-Content -LiteralPath $contractFiles.ProfileOverride -Raw
    if ($overrideText -notmatch '(?ms)^\[Diagnostics\]\s*.*?^RemixCameraDiagnostics\s*=\s*1\s*$') {
        throw 'RTX camera diagnostics profile override does not explicitly enable Diagnostics.RemixCameraDiagnostics.'
    }

    $hashes = [ordered]@{}
    foreach ($entry in $contractFiles.GetEnumerator()) {
        $hashes[$entry.Key] = (Get-FileHash -LiteralPath $entry.Value -Algorithm SHA256).Hash
    }
    $localManifestSourceCoherenceVerified = $false
    $localManifestPath = Join-Path $Root 'vendor-local\echopatch-remix-diagnostics\manifest-b4a7074e4cbb.json'
    if (Test-Path -LiteralPath $localManifestPath -PathType Leaf) {
        $localManifest = Get-Content -LiteralPath $localManifestPath -Raw | ConvertFrom-Json
        foreach ($propertyName in @('packageMode', 'remixCameraDiagnostics', 'remixDiagnosticsPatchSha256', 'remixDiagnosticsOverlaySha256')) {
            if (-not $localManifest.PSObject.Properties[$propertyName]) {
                throw "Local Remix diagnostic package manifest is missing source-coherence field '$propertyName': $localManifestPath"
            }
        }
        if ($localManifest.packageMode -cne 'RemixDiagnosticEchoPatch' -or
            $localManifest.remixCameraDiagnostics -isnot [bool] -or -not $localManifest.remixCameraDiagnostics -or
            [string]$localManifest.remixDiagnosticsPatchSha256 -cne [string]$hashes['Patch'] -or
            [string]$localManifest.remixDiagnosticsOverlaySha256 -cne [string]$hashes['Overlay']) {
            throw 'The local Remix diagnostic package was built from different tracked patch/overlay sources. Rebuild it before staging or accepting runtime evidence.'
        }
        $localManifestSourceCoherenceVerified = $true
    }
    return [pscustomobject]@{
        Files = [pscustomobject]$contractFiles
        Sha256 = [pscustomobject]$hashes
        HookCount = $requiredHooks.Count
        HookVtableSlots = [pscustomobject]$hookVtableSlots
        SchemaVersion = $schemaVersion
        BoundedFrames = $maximumFrames
        ClipRegisterStart = 72
        ClipRegisterCount = 4
        LocalManifestSourceCoherenceVerified = $localManifestSourceCoherenceVerified
    }
}

function Read-CameraProbeLog {
    param([string]$Path)

    $file = Get-Item -LiteralPath $Path
    if ($file.Length -le 0 -or $file.Length -gt $maximumLogBytes) {
        throw "Camera-probe log must be between 1 byte and $maximumLogBytes bytes: $Path"
    }

    $capability = $null
    $capabilityRecords = 0
    $frameCount = 0
    $validCameraFrames = 0
    $firstValidCameraFrame = $null
    $nonZeroCandidateFrames = 0
    [uint64]$nonZeroCandidateWrites = 0
    $firstNonZeroCandidateFrame = $null
    $candidateShaderHashes = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [uint64]$shaderDraws = 0
    [uint64]$fixedFunctionDraws = 0
    [uint64]$fixedFunctionCameraDraws = 0
    [uint64]$candidateDraws = 0
    [uint64]$transformSets = 0
    [uint64]$viewSets = 0
    [uint64]$projectionSets = 0
    $lastFrame = -1

    $reader = [IO.File]::OpenText($Path)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNumber = $frameCount + 2
            if ($null -eq $capability) {
                $lineNumber = 1
            }
            if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -gt $maximumJsonLineCharacters) {
                throw "Camera-probe log line $lineNumber is empty or exceeds $maximumJsonLineCharacters characters."
            }
            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
            }
            catch {
                throw "Camera-probe log line $lineNumber is not valid JSON: $($_.Exception.Message)"
            }

            if ($null -eq $capability) {
                Assert-ExactProperties -Value $record -Expected @('event', 'schema', 'pid', 'enabled', 'hooks', 'boundedFrames', 'clipRegisterStart', 'clipRegisterCount') -Description 'Capability record'
                Assert-IntegerRange -Value $record.schema -Minimum $schemaVersion -Maximum $schemaVersion -Description 'Capability schema'
                if ($record.event -cne 'capability' -or $record.schema -ne $schemaVersion) {
                    throw "Camera-probe log must begin with a schema-$schemaVersion capability record."
                }
                Assert-IntegerRange -Value $record.pid -Minimum 1 -Maximum ([uint32]::MaxValue) -Description 'Capability pid'
                Assert-Boolean -Value $record.enabled -Description 'Capability enabled'
                if (-not $record.enabled) {
                    throw 'Camera-probe capability record reports diagnostics disabled.'
                }
                Assert-ExactProperties -Value $record.hooks -Expected $requiredHooks -Description 'Capability hooks'
                foreach ($hookName in $requiredHooks) {
                    $hookValue = $record.hooks.PSObject.Properties[$hookName].Value
                    Assert-Boolean -Value $hookValue -Description "Capability hook $hookName"
                    if (-not $hookValue) {
                        throw "Required D3D9 probe hook '$hookName' failed to install."
                    }
                }
                Assert-IntegerRange -Value $record.boundedFrames -Minimum 1 -Maximum $maximumFrames -Description 'Capability boundedFrames'
                Assert-IntegerRange -Value $record.clipRegisterStart -Minimum 0 -Maximum 255 -Description 'Capability clipRegisterStart'
                Assert-IntegerRange -Value $record.clipRegisterCount -Minimum 1 -Maximum 256 -Description 'Capability clipRegisterCount'
                if ($record.boundedFrames -ne $maximumFrames -or $record.clipRegisterStart -ne 72 -or $record.clipRegisterCount -ne 4) {
                    throw 'Capability record does not match the project-owned 3600-frame, c72-c75 schema contract.'
                }
                $capability = $record
                $capabilityRecords = 1
                continue
            }

            if ($record.PSObject.Properties['event'] -and $record.event -ceq 'capability') {
                Assert-ExactProperties -Value $record -Expected @('event', 'schema', 'pid', 'enabled', 'hooks', 'boundedFrames', 'clipRegisterStart', 'clipRegisterCount') -Description 'Repeated capability record'
                Assert-IntegerRange -Value $record.schema -Minimum $schemaVersion -Maximum $schemaVersion -Description 'Repeated capability schema'
                Assert-IntegerRange -Value $record.pid -Minimum 1 -Maximum ([uint32]::MaxValue) -Description 'Repeated capability pid'
                Assert-Boolean -Value $record.enabled -Description 'Repeated capability enabled'
                Assert-IntegerRange -Value $record.boundedFrames -Minimum 1 -Maximum $maximumFrames -Description 'Repeated capability boundedFrames'
                Assert-IntegerRange -Value $record.clipRegisterStart -Minimum 0 -Maximum 255 -Description 'Repeated capability clipRegisterStart'
                Assert-IntegerRange -Value $record.clipRegisterCount -Minimum 1 -Maximum 256 -Description 'Repeated capability clipRegisterCount'
                if ($record.schema -ne $schemaVersion -or $record.pid -ne $capability.pid -or -not $record.enabled -or
                    $record.boundedFrames -ne $capability.boundedFrames -or
                    $record.clipRegisterStart -ne $capability.clipRegisterStart -or
                    $record.clipRegisterCount -ne $capability.clipRegisterCount) {
                    throw 'Repeated camera-probe capability record does not match the original device/run contract.'
                }
                Assert-ExactProperties -Value $record.hooks -Expected $requiredHooks -Description 'Repeated capability hooks'
                foreach ($hookName in $requiredHooks) {
                    $hookValue = $record.hooks.PSObject.Properties[$hookName].Value
                    Assert-Boolean -Value $hookValue -Description "Repeated capability hook $hookName"
                    if (-not $hookValue) {
                        throw "Repeated camera-probe capability reports failed hook '$hookName'."
                    }
                }
                ++$capabilityRecords
                continue
            }

            Assert-ExactProperties -Value $record -Expected @('event', 'schema', 'frame', 'draws', 'transforms', 'viewport', 'renderTarget', 'vertexShader', 'constants') -Description "Frame record $frameCount"
            Assert-IntegerRange -Value $record.schema -Minimum $schemaVersion -Maximum $schemaVersion -Description "Frame $frameCount schema"
            if ($record.event -cne 'frame' -or $record.schema -ne $schemaVersion) {
                throw "Record after capability is not a schema-$schemaVersion frame record."
            }
            Assert-IntegerRange -Value $record.frame -Minimum 0 -Maximum ($capability.boundedFrames - 1) -Description 'Frame number'
            if ($record.frame -ne ($lastFrame + 1)) {
                throw "Frame numbers must be contiguous from zero; expected $($lastFrame + 1), found $($record.frame)."
            }
            $lastFrame = $record.frame

            Assert-ExactProperties -Value $record.draws -Expected @('shader', 'ffp', 'ffpWithCamera', 'primitives') -Description "Frame $($record.frame) draws"
            foreach ($property in @('shader', 'ffp', 'ffpWithCamera', 'primitives')) {
                Assert-IntegerRange -Value $record.draws.$property -Minimum 0 -Maximum ([uint32]::MaxValue) -Description "Frame $($record.frame) draws.$property"
            }
            if ($record.draws.ffpWithCamera -gt $record.draws.ffp) {
                throw "Frame $($record.frame) fixed-function camera draws exceed total fixed-function draws."
            }
            $shaderDraws += [uint64]$record.draws.shader
            $fixedFunctionDraws += [uint64]$record.draws.ffp
            $fixedFunctionCameraDraws += [uint64]$record.draws.ffpWithCamera

            Assert-ExactProperties -Value $record.transforms -Expected @(
                'sets', 'worldSets', 'viewSets', 'projectionSets',
                'worldPresent', 'viewPresent', 'projectionPresent',
                'worldIdentity', 'viewIdentity', 'projectionIdentity',
                'worldFinite', 'viewFinite', 'projectionFinite',
                'worldUsable', 'viewUsable', 'projectionUsable',
                'ffpCameraAtDrawPresent', 'ffpViewUsableAtDraw',
                'ffpProjectionUsableAtDraw', 'ffpProjectionIdentityAtDraw'
            ) -Description "Frame $($record.frame) transforms"
            foreach ($property in @('sets', 'worldSets', 'viewSets', 'projectionSets')) {
                Assert-IntegerRange -Value $record.transforms.$property -Minimum 0 -Maximum ([uint32]::MaxValue) -Description "Frame $($record.frame) transforms.$property"
            }
            foreach ($property in @(
                'worldPresent', 'viewPresent', 'projectionPresent',
                'worldIdentity', 'viewIdentity', 'projectionIdentity',
                'worldFinite', 'viewFinite', 'projectionFinite',
                'worldUsable', 'viewUsable', 'projectionUsable',
                'ffpCameraAtDrawPresent', 'ffpViewUsableAtDraw',
                'ffpProjectionUsableAtDraw', 'ffpProjectionIdentityAtDraw'
            )) {
                Assert-Boolean -Value $record.transforms.$property -Description "Frame $($record.frame) transforms.$property"
            }
            if (($record.transforms.worldSets + $record.transforms.viewSets + $record.transforms.projectionSets) -gt $record.transforms.sets) {
                throw "Frame $($record.frame) transform subtype counts exceed total SetTransform calls."
            }
            $transformSets += [uint64]$record.transforms.sets
            $viewSets += [uint64]$record.transforms.viewSets
            $projectionSets += [uint64]$record.transforms.projectionSets
            # These fields snapshot the first qualifying fixed-function draw.
            # The general transform fields describe the state at the final draw
            # (or later SetTransform) and must not override draw-time evidence.
            $validCamera = $record.draws.ffpWithCamera -gt 0 -and
                $record.transforms.ffpCameraAtDrawPresent -and
                $record.transforms.ffpViewUsableAtDraw -and
                $record.transforms.ffpProjectionUsableAtDraw -and
                (-not $record.transforms.ffpProjectionIdentityAtDraw)
            if ($record.transforms.ffpCameraAtDrawPresent -ne ($record.draws.ffpWithCamera -gt 0) -or
                ($record.draws.ffpWithCamera -gt 0 -and -not $validCamera)) {
                throw "Frame $($record.frame) fixed-function camera counter and draw-time state snapshot disagree."
            }
            if ($validCamera) {
                ++$validCameraFrames
                if ($null -eq $firstValidCameraFrame) { $firstValidCameraFrame = $record.frame }
            }

            Assert-ExactProperties -Value $record.viewport -Expected @('sets', 'present', 'x', 'y', 'width', 'height', 'minZ', 'maxZ') -Description "Frame $($record.frame) viewport"
            foreach ($property in @('sets', 'x', 'y', 'width', 'height')) {
                Assert-IntegerRange -Value $record.viewport.$property -Minimum 0 -Maximum ([uint32]::MaxValue) -Description "Frame $($record.frame) viewport.$property"
            }
            Assert-Boolean -Value $record.viewport.present -Description "Frame $($record.frame) viewport.present"
            Assert-FiniteNumber -Value $record.viewport.minZ -Description "Frame $($record.frame) viewport.minZ"
            Assert-FiniteNumber -Value $record.viewport.maxZ -Description "Frame $($record.frame) viewport.maxZ"

            Assert-ExactProperties -Value $record.renderTarget -Expected @('sets', 'width', 'height', 'format') -Description "Frame $($record.frame) renderTarget"
            foreach ($property in @('sets', 'width', 'height', 'format')) {
                Assert-IntegerRange -Value $record.renderTarget.$property -Minimum 0 -Maximum ([uint32]::MaxValue) -Description "Frame $($record.frame) renderTarget.$property"
            }

            Assert-ExactProperties -Value $record.vertexShader -Expected @('present', 'hash', 'bytes', 'version') -Description "Frame $($record.frame) vertexShader"
            Assert-Boolean -Value $record.vertexShader.present -Description "Frame $($record.frame) vertexShader.present"
            Assert-HexIdentity -Value $record.vertexShader.hash -Description "Frame $($record.frame) vertexShader.hash"
            Assert-HexIdentity -Value $record.vertexShader.version -Description "Frame $($record.frame) vertexShader.version"
            Assert-IntegerRange -Value $record.vertexShader.bytes -Minimum 0 -Maximum 1048576 -Description "Frame $($record.frame) vertexShader.bytes"

            Assert-ExactProperties -Value $record.constants -Expected @(
                'writes', 'fourRegisterWrites', 'clipRegisterWrites', 'completedClipRegisterWrites',
                'nonZeroClipRegisterWrites', 'minimum', 'maximumExclusive', 'clipRowMask',
                'clipPresent', 'frameCandidatePresent', 'frameCandidateDraws',
                'frameCandidateShaderHash', 'clipFinite', 'clip'
            ) -Description "Frame $($record.frame) constants"
            foreach ($property in @(
                'writes', 'fourRegisterWrites', 'clipRegisterWrites', 'completedClipRegisterWrites',
                'nonZeroClipRegisterWrites', 'minimum', 'maximumExclusive', 'clipRowMask', 'frameCandidateDraws'
            )) {
                Assert-IntegerRange -Value $record.constants.$property -Minimum 0 -Maximum ([uint32]::MaxValue) -Description "Frame $($record.frame) constants.$property"
            }
            foreach ($property in @('clipPresent', 'frameCandidatePresent', 'clipFinite')) {
                Assert-Boolean -Value $record.constants.$property -Description "Frame $($record.frame) constants.$property"
            }
            Assert-HexIdentity -Value $record.constants.frameCandidateShaderHash -Description "Frame $($record.frame) constants.frameCandidateShaderHash"
            Assert-ClipVector `
                -Value $record.constants.clip `
                -ClipFinite $record.constants.clipFinite `
                -ClipPresent $record.constants.clipPresent `
                -Description "Frame $($record.frame) constants.clip"
            if ($record.constants.fourRegisterWrites -gt $record.constants.writes -or
                $record.constants.clipRegisterWrites -gt $record.constants.writes -or
                $record.constants.completedClipRegisterWrites -gt $record.constants.clipRegisterWrites -or
                $record.constants.nonZeroClipRegisterWrites -gt $record.constants.completedClipRegisterWrites -or
                $record.constants.frameCandidateDraws -gt $record.draws.shader -or
                $record.constants.clipRowMask -gt 15 -or
                $record.constants.minimum -gt 256 -or $record.constants.maximumExclusive -gt 256 -or
                $record.constants.minimum -gt $record.constants.maximumExclusive) {
                throw "Frame $($record.frame) constant counters are internally inconsistent or outside D3D9's 256-register vertex-constant range."
            }
            if ($record.constants.clipPresent -ne ($record.constants.clipRowMask -eq 15)) {
                throw "Frame $($record.frame) c72-c75 row mask and complete-state flag disagree."
            }
            $hasCandidate = $record.constants.frameCandidateDraws -gt 0
            if ($record.constants.frameCandidatePresent -ne $hasCandidate) {
                throw "Frame $($record.frame) c72-c75 candidate draw count and frame-candidate flag disagree."
            }
            if ($hasCandidate) {
                if (-not $record.constants.clipFinite) {
                    throw "Frame $($record.frame) claims a c72-c75 draw candidate with nonfinite constants."
                }
                ++$nonZeroCandidateFrames
                $candidateDraws += [uint64]$record.constants.frameCandidateDraws
                if ($null -eq $firstNonZeroCandidateFrame) { $firstNonZeroCandidateFrame = $record.frame }
                [void]$candidateShaderHashes.Add($record.constants.frameCandidateShaderHash)
            }
            $nonZeroCandidateWrites += [uint64]$record.constants.nonZeroClipRegisterWrites

            ++$frameCount
            if ($frameCount -gt $capability.boundedFrames) {
                throw "Camera-probe log exceeded its declared $($capability.boundedFrames)-frame bound."
            }
        }
    }
    finally {
        $reader.Dispose()
    }

    if ($null -eq $capability) {
        throw 'Camera-probe log has no capability record.'
    }
    if ($frameCount -eq 0) {
        throw 'Camera-probe log has no frame records.'
    }

    return [pscustomobject]@{
        Path = $Path
        ProcessId = [uint32]$capability.pid
        CapabilityRecordCount = $capabilityRecords
        Classification = if ($validCameraFrames -gt 0) { 'ValidFfpCameraSeen' } else { 'NeverValidFfpCamera' }
        FrameCount = $frameCount
        BoundedFrames = $capability.boundedFrames
        AllEightHooksInstalled = $true
        ValidFfpCameraFrameCount = $validCameraFrames
        FirstValidFfpCameraFrame = $firstValidCameraFrame
        NonZeroC72CandidateSeen = $nonZeroCandidateFrames -gt 0
        NonZeroC72CandidateFrameCount = $nonZeroCandidateFrames
        NonZeroC72CandidateWriteCount = $nonZeroCandidateWrites
        NonZeroC72CandidateDrawCount = $candidateDraws
        FirstNonZeroC72CandidateFrame = $firstNonZeroCandidateFrame
        C72CandidateShaderHashes = @($candidateShaderHashes | Sort-Object)
        ShaderDrawCallCount = $shaderDraws
        FixedFunctionDrawCallCount = $fixedFunctionDraws
        FixedFunctionCameraDrawCallCount = $fixedFunctionCameraDraws
        SetTransformCallCount = $transformSets
        ViewTransformSetCount = $viewSets
        ProjectionTransformSetCount = $projectionSets
    }
}

function Read-RemixLog {
    param([string]$Path)

    $file = Get-Item -LiteralPath $Path
    if ($file.Length -le 0 -or $file.Length -gt $maximumLogBytes) {
        throw "RTX Remix log must be between 1 byte and $maximumLogBytes bytes: $Path"
    }
    $text = Get-Content -LiteralPath $Path -Raw
    $runtimeMatch = [regex]::Match($text, '(?m)DXVK_Remix:\s*(?<Identity>[^\r\n]+)')
    $gpuMatches = [regex]::Matches($text, '(?m)Device name\s*:\s*(?::\s*)?(?<Identity>[^\r\n]+)')
    $bufferMatches = [regex]::Matches(
        $text,
        '(?ms)D3D9DeviceEx::ResetSwapChain:.*?Buffer size:\s*(?<Width>\d+)x(?<Height>\d+)')
    $lastGpu = if ($gpuMatches.Count -gt 0) { $gpuMatches[$gpuMatches.Count - 1].Groups['Identity'].Value.Trim() } else { $null }
    $lastBuffer = if ($bufferMatches.Count -gt 0) { $bufferMatches[$bufferMatches.Count - 1] } else { $null }
    return [pscustomobject]@{
        Path = $Path
        RuntimeIdentity = if ($runtimeMatch.Success) { $runtimeMatch.Groups['Identity'].Value.Trim() } else { $null }
        GpuIdentity = $lastGpu
        SwapchainWidth = if ($lastBuffer) { [int]$lastBuffer.Groups['Width'].Value } else { $null }
        SwapchainHeight = if ($lastBuffer) { [int]$lastBuffer.Groups['Height'].Value } else { $null }
        CameraRejectionSeen = $text.Contains('Trying to raytrace but not detecting a valid camera.')
    }
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if (-not (Test-Path -LiteralPath $RepositoryRoot -PathType Container)) {
    throw "Repository root is missing: $RepositoryRoot"
}
if ($SourceOnly -and ($PSBoundParameters.ContainsKey('LogPath') -or $PSBoundParameters.ContainsKey('RemixLogPath'))) {
    throw '-SourceOnly cannot be combined with -LogPath or -RemixLogPath.'
}

$sourceContract = Test-ProjectOwnedProbeContract -Root $RepositoryRoot
$cameraLogExplicit = $PSBoundParameters.ContainsKey('LogPath')
$remixLogExplicit = $PSBoundParameters.ContainsKey('RemixLogPath')
if ($cameraLogExplicit -and [string]::IsNullOrWhiteSpace($LogPath)) {
    throw '-LogPath cannot be empty.'
}
if ($remixLogExplicit -and [string]::IsNullOrWhiteSpace($RemixLogPath)) {
    throw '-RemixLogPath cannot be empty.'
}

if (-not $SourceOnly -and -not $cameraLogExplicit -and -not $remixLogExplicit) {
    throw 'Runtime evidence validation requires an explicit -LogPath (and preferably -RemixLogPath). Use -SourceOnly for the tracked source/package contract.'
}

$cameraResult = $null
if ($LogPath) {
    $resolvedLogPath = Resolve-ExistingFile -Path $LogPath -BasePath $RepositoryRoot -Description 'Camera-probe JSONL log'
    $cameraResult = Read-CameraProbeLog -Path $resolvedLogPath
    $expectedCameraFileName = "fearmore-camera-$($cameraResult.ProcessId).jsonl"
    if ((Split-Path $resolvedLogPath -Leaf) -cne $expectedCameraFileName) {
        throw "Camera-probe filename does not match its capability PID $($cameraResult.ProcessId): $resolvedLogPath"
    }
}

$remixResult = $null
if ($RemixLogPath) {
    $resolvedRemixLogPath = Resolve-ExistingFile -Path $RemixLogPath -BasePath $RepositoryRoot -Description 'RTX Remix runtime log'
    if ($cameraResult) {
        $cameraLogDirectory = [IO.Path]::GetFullPath((Split-Path $resolvedLogPath -Parent)).TrimEnd('\')
        $remixLogDirectory = [IO.Path]::GetFullPath((Split-Path $resolvedRemixLogPath -Parent)).TrimEnd('\')
        if (-not $cameraLogDirectory.Equals($remixLogDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Camera and RTX Remix logs must come from the same stage-local logs directory.'
        }
        if ((Split-Path $resolvedRemixLogPath -Leaf) -cne 'remix-dxvk.log') {
            throw 'RTX Remix runtime evidence must use the active run log named remix-dxvk.log.'
        }
        $cameraFile = Get-Item -LiteralPath $resolvedLogPath
        $remixFile = Get-Item -LiteralPath $resolvedRemixLogPath
        $cameraWriteTime = $cameraFile.LastWriteTimeUtc
        $remixWriteTime = $remixFile.LastWriteTimeUtc
        if ([Math]::Abs(($cameraWriteTime - $remixWriteTime).TotalMinutes) -gt 10.0) {
            throw 'Camera and RTX Remix logs are too far apart in time to treat as one runtime probe.'
        }
        if ($cameraFile.CreationTimeUtc -lt $remixFile.CreationTimeUtc -or
            ($cameraFile.CreationTimeUtc - $remixFile.CreationTimeUtc).TotalMinutes -gt 10.0) {
            throw 'Camera capability creation does not fall inside the explicitly supplied RTX Remix run.'
        }
    }
    $remixResult = Read-RemixLog -Path $resolvedRemixLogPath
}

[pscustomobject]@{
    Status = 'PASS'
    Mode = if ($cameraResult) { 'RuntimeLog' } elseif ($remixResult) { 'RemixLogOnly' } else { 'SourceOnly' }
    SourceContract = $sourceContract
    CameraProbe = $cameraResult
    RemixRuntime = $remixResult
}
