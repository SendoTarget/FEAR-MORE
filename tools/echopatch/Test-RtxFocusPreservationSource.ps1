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

$overlayPath = Join-Path $RepositoryRoot 'tools\echopatch\overlays\RtxFocusPreservation.cpp'
$patchPath = Join-Path $RepositoryRoot 'patches\echopatch\0005-add-rtx-focus-preservation.patch'
$overridePath = Join-Path $RepositoryRoot 'tools\echopatch\EchoPatch.rtx-focus-preservation.override.ini'
$cameraOverridePath = Join-Path $RepositoryRoot 'tools\echopatch\EchoPatch.camera-diagnostics.override.ini'
$baseProfilePath = Join-Path $RepositoryRoot 'tools\echopatch\EchoPatch.engine-only.ini'
$buildPath = Join-Path $RepositoryRoot 'tools\echopatch\Build-EngineOnlyEchoPatch.ps1'
$promotionPath = Join-Path $RepositoryRoot 'tools\echopatch\EchoPatchPromotion.psm1'
$engineWindowProcSourcePath = Join-Path $RepositoryRoot 'FEAR\Dev\Source\runtime\kernel\src\sys\win\client.cpp'
$ltCodesPath = Join-Path $RepositoryRoot 'FEAR\Dev\Source\sdk\inc\ltcodes.h'

foreach ($required in @(
    $overlayPath,
    $patchPath,
    $overridePath,
    $cameraOverridePath,
    $baseProfilePath,
    $buildPath,
    $promotionPath,
    $engineWindowProcSourcePath,
    $ltCodesPath
)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "RTX focus-preservation source input is missing: $required"
    }
}

$overlay = Get-Content -LiteralPath $overlayPath -Raw
$patch = Get-Content -LiteralPath $patchPath -Raw
$override = Get-Content -LiteralPath $overridePath -Raw
$cameraOverride = Get-Content -LiteralPath $cameraOverridePath -Raw
$baseProfile = Get-Content -LiteralPath $baseProfilePath -Raw
$build = Get-Content -LiteralPath $buildPath -Raw
$promotion = Get-Content -LiteralPath $promotionPath -Raw
$engineWindowProcSource = Get-Content -LiteralPath $engineWindowProcSourcePath -Raw
$ltCodes = Get-Content -LiteralPath $ltCodesPath -Raw

foreach ($scriptPath in @($buildPath, $promotionPath, $PSCommandPath)) {
    $parseErrors = $null
    $parseTokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$parseTokens,
        [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -ne 0) {
        throw "RTX focus-preservation script has parse errors in '$scriptPath': $($parseErrors -join [Environment]::NewLine)"
    }
}

if ($engineWindowProcSource -notmatch '(?s)case\s+WM_ACTIVATEAPP:.*?r_InitRender\(&g_RMode\).*?r_TermRender\(1,\s*false\)') {
    throw 'The source-owned F.E.A.R. activation path no longer contains the renderer re-init/shutdown pair this patch isolates.'
}
if ($ltCodes -notmatch '(?m)^\s*LT_OK\s*=\s*0\s*,') {
    throw 'The RTX focus success-return replacement requires the source-owned LT_OK value to remain zero.'
}

$requiredOverlayFragments = @(
    'kInitRenderCallOffset = 0xE0',
    'kTermRenderCallOffset = 0x190',
    '{ 0xE8, 0x4B, 0x6C, 0x00, 0x00, 0x85, 0xC0, 0x74, 0x20 }',
    '{ 0xB8, 0x00, 0x00, 0x00, 0x00 }',
    '{ 0xB8, 0x00, 0x00, 0x00, 0x00, 0x85, 0xC0, 0x74, 0x20 }',
    '{ 0xE8, 0xBB, 0x68, 0x00, 0x00 }',
    '{ 0x90, 0x90, 0x90, 0x90, 0x90 }',
    'g_State.CurrentFEARGame != FEAR',
    'GetAddress(Addr::Console_WindowProc)',
    'kSuccessfulInitRenderResult',
    'MemoryHelper::MakeNOP(termRenderCall, kRtxFocusCallSize)',
    'MemoryHelper::WriteMemoryRaw(',
    'MatchesExpectedBytes(',
    'AppendRtxFocusPreservationLog(',
    'ReportRtxFocusPreservationSuccess();',
    'FlushInstructionCache(',
    'focus events, input, sound, and Console_WindowProc detours preserved.'
)
foreach ($fragment in $requiredOverlayFragments) {
    if (-not $overlay.Contains($fragment)) {
        throw "RTX focus-preservation overlay is missing invariant: $fragment"
    }
}

if ($overlay -match 'HookHelper::ApplyHook|WindowProc_Hook|WM_ACTIVATEAPP') {
    throw 'RTX focus preservation must not install or duplicate a WindowProc detour.'
}
if ($overlay.Contains('MemoryHelper::MakeNOP(initRenderCall, kRtxFocusCallSize)')) {
    throw 'The gain-focus renderer bypass must return LT_OK explicitly; a NOP leaves the following EAX check undefined.'
}

$verificationIndex = $overlay.IndexOf('if (!MatchesExpectedBytes(initRenderCall, kExpectedInitRenderContext, kInitRenderGuardSize) ||')
$firstWriteIndex = $overlay.IndexOf('kSuccessfulInitRenderResult', $verificationIndex)
$secondWriteIndex = $overlay.IndexOf('MemoryHelper::MakeNOP(termRenderCall, kRtxFocusCallSize)')
$readbackIndex = $overlay.IndexOf('kSuccessfulInitRenderContext', $secondWriteIndex)
$rollbackIndex = $overlay.IndexOf('RestoreNativeFocusSites(initRenderCall, termRenderCall)', $secondWriteIndex)
if ($verificationIndex -lt 0 -or $firstWriteIndex -le $verificationIndex -or
    $secondWriteIndex -le $firstWriteIndex -or $readbackIndex -le $secondWriteIndex -or
    $rollbackIndex -le $secondWriteIndex) {
    throw 'Both renderer calls must be verified before mutation, gain must return LT_OK, and second-write/readback failure must roll the transaction back.'
}

if ($patch -notmatch 'PreserveRtxRendererOnFocusChange\s*=\s*false' -or
    $patch -notmatch 'ReadInteger\("Compatibility",\s*"PreserveRtxRendererOnFocusChange",\s*0\)' -or
    $patch -notmatch 'ApplyRtxFocusPreservation\(\);' -or
    $patch -notmatch 'Engine/RtxFocusPreservation/RtxFocusPreservation\.cpp') {
    throw 'The tracked patch must keep the feature default-off and wire only its focused overlay into engine initialization.'
}

if ($override -notmatch '(?m)^PreserveRtxRendererOnFocusChange\s*=\s*1\s*$') {
    throw 'The RTX-only profile override no longer enables focus preservation.'
}
if (($baseProfile + $cameraOverride) -match '(?m)^PreserveRtxRendererOnFocusChange\s*=') {
    throw 'The ordinary engine-only or native CameraLab profile was contaminated by the RTX focus exception.'
}

$requiredBuildFragments = @(
    '[switch]$RtxFocusPreservation',
    '-RtxFocusPreservation requires -CameraDiagnostics',
    'echopatch-rtx-camera-diagnostics',
    'RtxCameraDiagnosticEchoPatch',
    '$manifest.rtxFocusPreservation = $true',
    '$manifest.rtxFocusPreservationProof',
    '$manifest.rtxFocusPreservationPatchSha256',
    '$manifest.rtxFocusPreservationOverlaySha256',
    '$manifest.rtxFocusPreservationProfileOverrideSha256'
)
foreach ($fragment in $requiredBuildFragments) {
    if (-not $build.Contains($fragment)) {
        throw "The RTX camera package build/identity is missing invariant: $fragment"
    }
}
if (-not $promotion.Contains("'RtxCameraDiagnosticEchoPatch'")) {
    throw 'Transactional promotion does not recognize the distinct RTX camera package identity.'
}

# Check the patch stack against pristine pinned EchoPatch source without building
# or touching any stable package output.
$tempRoot = Join-Path $RepositoryRoot ('local-runtime\rtx-focus-source-test-' + [Guid]::NewGuid().ToString('N'))
$allowedTempParent = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'local-runtime')).TrimEnd('\') + '\'
$tempRoot = [IO.Path]::GetFullPath($tempRoot)
if (-not $tempRoot.StartsWith($allowedTempParent, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing RTX focus source-test path outside local-runtime: $tempRoot"
}

New-Item -ItemType Directory -Path $tempRoot | Out-Null
try {
    $archivePath = Join-Path $tempRoot 'EchoPatch.zip'
    $extractRoot = Join-Path $tempRoot 'source'
    $submoduleRoot = Join-Path $RepositoryRoot 'external\EchoPatch'
    $archiveOutput = & git -C $submoduleRoot archive --format=zip "--output=$archivePath" `
        --prefix=EchoPatch/ b4a7074e4cbb2fb6bb238809f7cf26424f1f5961 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to archive pinned EchoPatch source for focus preflight:`n$($archiveOutput -join [Environment]::NewLine)"
    }
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot

    $sourceRoot = Join-Path $extractRoot 'EchoPatch'
    $relativeSource = $sourceRoot.Substring($RepositoryRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/')
    foreach ($stackPatch in @(
        (Join-Path $RepositoryRoot 'patches\echopatch\0001-add-game-module-compatibility-switch.patch'),
        (Join-Path $RepositoryRoot 'patches\echopatch\0004-add-camera-diagnostics.patch'),
        $patchPath
    )) {
        $checkOutput = & git -C $RepositoryRoot apply --check --whitespace=error-all `
            "--directory=$relativeSource" $stackPatch 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "EchoPatch focus stack preflight failed for '$stackPatch':`n$($checkOutput -join [Environment]::NewLine)"
        }
        $applyOutput = & git -C $RepositoryRoot apply --whitespace=error-all `
            "--directory=$relativeSource" $stackPatch 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "EchoPatch focus stack application failed for '$stackPatch':`n$($applyOutput -join [Environment]::NewLine)"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        $item = Get-Item -LiteralPath $tempRoot -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing RTX focus source-test cleanup through reparse point: $tempRoot"
        }
        $nestedReparse = Get-ChildItem -LiteralPath $tempRoot -Force -Recurse |
            Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
            Select-Object -First 1
        if ($nestedReparse) {
            throw "Refusing RTX focus source-test cleanup because it contains a reparse point: $($nestedReparse.FullName)"
        }
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

[pscustomobject]@{
    Passed = $true
    ExecutableScope = 'FEAR v1.08 only'
    WindowProcDetoursAdded = 0
    PreservedFocusBehavior = 'Client events, input clear, sound release/reacquire, console routing'
    GainReturnSemantics = 'LT_OK (EAX=0)'
    DurableRuntimeProof = 'FearMore-EchoPatch.log'
    NativeCameraLabChanged = $false
    PackageMode = 'RtxCameraDiagnosticEchoPatch'
    RetailBuiltOrDeployed = $false
}
