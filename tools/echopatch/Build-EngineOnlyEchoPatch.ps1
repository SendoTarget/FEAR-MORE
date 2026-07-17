[CmdletBinding()]
param(
    [string]$OutputRoot,
    [string]$MinHookArchive,
    [string]$PlatformToolset = "v143",
    [switch]$RemixCameraDiagnostics,
    [switch]$CameraDiagnostics,
    [switch]$RtxFocusPreservation,
    [switch]$RtxCameraReassertion,
    [switch]$TestFailBeforePromotion
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Import-Module -Name (Join-Path $PSScriptRoot 'EchoPatchPromotion.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'EchoPatchBuildFlavor.psm1') -Force

$ExpectedCommit = "b4a7074e4cbb2fb6bb238809f7cf26424f1f5961"
$MinHookCommit = "c3fcafdc10146beb5919319d0683e44e3c30d537"
$MinHookArchiveSha256 = "CDCB160F734D81BD4D235DFEA79E3F5A661C8EF0AB74FA814272AA5449069034"
$ExpectedMachine = 0x014c
$ExpectedOptionalHeader = 0x010b
$CompatibilityProof = "PatchGameModules=0; GameClient.dll, GameServer.dll, and ClientFX hooks were intentionally skipped."
$RemixDiagnosticsProof = "rtx-remix\logs\fearmore-camera-"
$CameraDiagnosticsProof = "FearMoreDiagnostics\camera-d3d9-"
$RtxFocusPreservationProof = "FearMore RTX focus preservation: exact FEAR v1.08 renderer calls bypassed; focus events, input, sound, and Console_WindowProc detours preserved."
$RtxCameraReassertionLogProof = "FearMoreDiagnostics\rtx-camera-reassertion-"
$RtxCameraReassertionProof = "FearMore RTX camera reassertion: F7D91705-880 c0-c3, 300-frame query-gated passive observer."

$buildFlavor = Get-EchoPatchBuildFlavor `
    -RemixCameraDiagnostics:$RemixCameraDiagnostics `
    -CameraDiagnostics:$CameraDiagnostics `
    -RtxFocusPreservation:$RtxFocusPreservation `
    -RtxCameraReassertion:$RtxCameraReassertion

function Get-FullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-ChildPath([string]$Child, [string]$Parent) {
    $parentFull = (Get-FullPath $Parent).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $childFull = Get-FullPath $Child
    if (-not $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside '$parentFull': $childFull"
    }
}

function Assert-NoReparsePoints([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $rootItem = Get-Item -LiteralPath $Path -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing recursive removal through a reparse point: $Path"
    }
    $nestedReparsePoint = Get-ChildItem -LiteralPath $Path -Force -Recurse |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($nestedReparsePoint) {
        throw "Refusing recursive removal because the tree contains a reparse point: $($nestedReparsePoint.FullName)"
    }
}

function Remove-GuardedTree([string]$Path, [string]$Parent) {
    Assert-ChildPath -Child $Path -Parent $Parent
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Assert-NoReparsePoints -Path $Path
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Assert-PackageCoherence(
    [string]$CandidateRoot,
    [string]$CandidatePackageRoot,
    [string]$CandidateManifestPath,
    [string]$ExpectedPackageMode
) {
    Assert-ChildPath -Child $CandidatePackageRoot -Parent $CandidateRoot
    Assert-ChildPath -Child $CandidateManifestPath -Parent $CandidateRoot

    foreach ($requiredPath in @(
        $CandidatePackageRoot,
        $CandidateManifestPath,
        (Join-Path $CandidatePackageRoot 'dinput8.dll'),
        (Join-Path $CandidatePackageRoot 'EchoPatch.ini')
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Transactional EchoPatch candidate is incomplete: $requiredPath"
        }
    }

    $candidateManifest = Get-Content -LiteralPath $CandidateManifestPath -Raw | ConvertFrom-Json
    $packageModeProperty = $candidateManifest.PSObject.Properties['packageMode']
    $actualPackageMode = if ($packageModeProperty) { [string]$packageModeProperty.Value } else { '' }
    if ($ExpectedPackageMode -eq 'EngineOnlyEchoPatch') {
        if ($packageModeProperty -and $actualPackageMode -ne $ExpectedPackageMode) {
            throw "Transactional EchoPatch candidate mode is '$actualPackageMode'; expected '$ExpectedPackageMode'."
        }
    }
    elseif (-not $packageModeProperty -or $actualPackageMode -ne $ExpectedPackageMode) {
        throw "Transactional EchoPatch candidate mode is '$actualPackageMode'; expected '$ExpectedPackageMode'."
    }

    $candidateBinaryHash = (Get-FileHash -LiteralPath (Join-Path $CandidatePackageRoot 'dinput8.dll') -Algorithm SHA256).Hash
    if ($candidateManifest.binarySha256 -ne $candidateBinaryHash) {
        throw "Transactional EchoPatch candidate DLL hash does not match its manifest."
    }

    $candidateProfileHash = (Get-FileHash -LiteralPath (Join-Path $CandidatePackageRoot 'EchoPatch.ini') -Algorithm SHA256).Hash
    if ($candidateManifest.profileSha256 -ne $candidateProfileHash) {
        throw "Transactional EchoPatch candidate profile hash does not match its manifest."
    }
}

function Assert-ExistingPathChainHasNoReparsePoints([string]$Base, [string]$Target) {
    $baseFull = (Get-FullPath $Base).TrimEnd('\', '/')
    $targetFull = Get-FullPath $Target
    if ($targetFull -ne $baseFull -and -not $targetFull.StartsWith(
        $baseFull + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path-chain target is outside its base: $targetFull"
    }

    $current = $baseFull
    $relative = $targetFull.Substring($baseFull.Length).TrimStart('\', '/')
    $segments = @()
    if ($relative.Length -gt 0) {
        $segments = $relative -split '[\\/]'
    }
    foreach ($segment in @('') + $segments) {
        if ($segment.Length -gt 0) {
            $current = Join-Path $current $segment
        }
        if (-not (Test-Path -LiteralPath $current)) {
            break
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing output path through a reparse point: $($item.FullName)"
        }
        if (-not $item.PSIsContainer -and $current -ne $targetFull) {
            throw "Output path has a non-directory component: $($item.FullName)"
        }
    }
}

function Invoke-GitCapture([string[]]$Arguments) {
    $output = & git @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed:`n$($output -join [Environment]::NewLine)"
    }
    return @($output | ForEach-Object { "$_" })
}

function Find-MSBuild {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere) {
        $found = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe"
        if ($LASTEXITCODE -eq 0 -and $found) {
            return "$($found | Select-Object -First 1)"
        }
    }

    $command = Get-Command msbuild.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    throw "MSBuild was not found. Install Visual Studio Build Tools with the Desktop development with C++ workload."
}

function Get-PEMetadata([string]$Path) {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5a4d) {
            throw "Not an MZ executable: $Path"
        }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Missing PE signature: $Path"
        }
        $machine = $reader.ReadUInt16()
        $stream.Position = $peOffset + 24
        $optionalHeader = $reader.ReadUInt16()
        return [pscustomobject]@{
            Machine = $machine
            OptionalHeader = $optionalHeader
        }
    }
    finally {
        $stream.Dispose()
    }
}

$repoRoot = Get-FullPath (Join-Path $PSScriptRoot "..\..")
$submoduleRoot = Join-Path $repoRoot "external\EchoPatch"
$patchPath = Join-Path $repoRoot "patches\echopatch\0001-add-game-module-compatibility-switch.patch"
$minHookPatchPath = Join-Path $repoRoot "patches\echopatch\0002-minhook-match-echopatch-crt.patch"
$remixDiagnosticsPatchPath = Join-Path $repoRoot "patches\echopatch\0003-add-remix-camera-diagnostics.patch"
$remixDiagnosticsOverlayPath = Join-Path $PSScriptRoot "overlays\RemixCameraDiagnostics.cpp"
$remixDiagnosticsProfileOverridePath = Join-Path $PSScriptRoot "EchoPatch.remix-diagnostics.override.ini"
$cameraDiagnosticsPatchPath = Join-Path $repoRoot "patches\echopatch\0004-add-camera-diagnostics.patch"
$cameraDiagnosticsOverlayPath = Join-Path $PSScriptRoot "overlays\CameraDiagnostics.cpp"
$cameraDiagnosticsProfileOverridePath = Join-Path $PSScriptRoot "EchoPatch.camera-diagnostics.override.ini"
$rtxFocusPreservationPatchPath = Join-Path $repoRoot "patches\echopatch\0005-add-rtx-focus-preservation.patch"
$rtxFocusPreservationOverlayPath = Join-Path $PSScriptRoot "overlays\RtxFocusPreservation.cpp"
$rtxFocusPreservationProfileOverridePath = Join-Path $PSScriptRoot "EchoPatch.rtx-focus-preservation.override.ini"
$rtxCameraReassertionPatchPath = Join-Path $repoRoot "patches\echopatch\0006-add-rtx-camera-reassertion.patch"
$rtxCameraReassertionOverlayPath = Join-Path $PSScriptRoot "overlays\RtxCameraReassertion.cpp"
$rtxCameraReassertionProfileOverridePath = Join-Path $PSScriptRoot "EchoPatch.rtx-camera-reassertion.override.ini"
$profilePath = Join-Path $PSScriptRoot "EchoPatch.engine-only.ini"
$vendorRoot = Join-Path $repoRoot "vendor-local"

if (-not $MinHookArchive) {
    $MinHookArchive = Join-Path $vendorRoot "echopatch-deps\minhook-$MinHookCommit.zip"
}
elseif (-not [System.IO.Path]::IsPathRooted($MinHookArchive)) {
    $MinHookArchive = Join-Path $repoRoot $MinHookArchive
}
$MinHookArchive = Get-FullPath $MinHookArchive

if (-not $OutputRoot) {
    $OutputRoot = Join-Path $vendorRoot $buildFlavor.DefaultOutputLeaf
}
$OutputRoot = Get-FullPath $OutputRoot
Assert-ChildPath -Child $OutputRoot -Parent $vendorRoot
Assert-ExistingPathChainHasNoReparsePoints -Base $vendorRoot -Target $OutputRoot

$shortCommit = $ExpectedCommit.Substring(0, 12)
$outputParent = Split-Path -Parent $OutputRoot
$outputLeaf = Split-Path -Leaf $OutputRoot
if ([string]::IsNullOrWhiteSpace($outputLeaf)) {
    throw "OutputRoot must name a directory beneath $vendorRoot."
}
if ($TestFailBeforePromotion -and -not $outputLeaf.StartsWith('echopatch-transaction-test-', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw '-TestFailBeforePromotion is restricted to an echopatch-transaction-test-* output root.'
}
$expectedPackageMode = $buildFlavor.PackageMode
$promotionContext = Initialize-EchoPatchPromotion `
    -OutputRoot $OutputRoot `
    -VendorRoot $vendorRoot `
    -ShortCommit $shortCommit

$requiredInputs = @($submoduleRoot, $patchPath, $minHookPatchPath, $profilePath, $MinHookArchive)
if ($RemixCameraDiagnostics) {
    $requiredInputs += @($remixDiagnosticsPatchPath, $remixDiagnosticsOverlayPath, $remixDiagnosticsProfileOverridePath)
}
if ($CameraDiagnostics) {
    $requiredInputs += @($cameraDiagnosticsPatchPath, $cameraDiagnosticsOverlayPath)
    if (-not $RtxCameraReassertion) {
        $requiredInputs += $cameraDiagnosticsProfileOverridePath
    }
}
if ($RtxFocusPreservation) {
    $requiredInputs += @($rtxFocusPreservationPatchPath, $rtxFocusPreservationOverlayPath)
    if (-not $RtxCameraReassertion) {
        $requiredInputs += $rtxFocusPreservationProfileOverridePath
    }
}
if ($RtxCameraReassertion) {
    $requiredInputs += @($rtxCameraReassertionPatchPath, $rtxCameraReassertionOverlayPath, $rtxCameraReassertionProfileOverridePath)
}
foreach ($required in $requiredInputs) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required input is missing: $required"
    }
}
$actualMinHookArchiveSha256 = (Get-FileHash -LiteralPath $MinHookArchive -Algorithm SHA256).Hash
if ($actualMinHookArchiveSha256 -ne $MinHookArchiveSha256) {
    throw "MinHook source archive hash is $actualMinHookArchiveSha256; expected $MinHookArchiveSha256 for commit $MinHookCommit."
}
$requiredSafeProfileSettings = [ordered]@{
    "Compatibility.PatchGameModules" = "0"
    "Fixes.CheckLAAPatch" = "0"
    "Fixes.FixNvidiaShadowCorruption" = "1"
    "Fixes.FixAspectRatioBlur" = "1"
    "Fixes.HighFPSFixes" = "0"
    "Fixes.DisableXPWidescreenFiltering" = "0"
    "Fixes.FixKeyboardInputLanguage" = "0"
    "Fixes.WeaponFixes" = "0"
    "Graphics.MaxFPS" = "60.0"
    "Graphics.HighResolutionReflections" = "0"
    "Graphics.SSAAScale" = "1.0"
    "Graphics.EnablePersistentWorldState" = "0"
    "Display.CustomFOV" = "0.0"
    "Display.HUDScaling" = "0"
    "Display.HUDCustomScalingFactor" = "1.0"
    "Display.SmallTextCustomScalingFactor" = "1.0"
    "Display.AutoResolution" = "0"
    "Display.DisableLetterbox" = "0"
    "Controller.MouseAimMultiplier" = "1.0"
    "Controller.SDLGamepadSupport" = "0"
    "Controller.RumbleEnabled" = "0"
    "Controller.GyroEnabled" = "0"
    "Controller.GyroCalibrationPersistence" = "0"
    "Controller.TouchpadEnabled" = "0"
    "Controller.HideMouseCursor" = "0"
    "SkipIntro.SkipSplashScreen" = "0"
    "Console.ConsoleEnabled" = "0"
    "Console.DebugLevel" = "0"
    "Console.HighResolutionScaling" = "0"
    "Console.LogOutputToFile" = "0"
    "Extra.InfiniteFlashlight" = "0"
    "Extra.EnableCustomMaxWeaponCapacity" = "0"
    "Extra.MaxWeaponCapacity" = "3"
    "Extra.DisableHipFireAccuracyPenalty" = "0"
}
if ($RemixCameraDiagnostics) {
    $requiredSafeProfileSettings["Diagnostics.RemixCameraDiagnostics"] = "1"
}
if ($CameraDiagnostics) {
    $requiredSafeProfileSettings["Diagnostics.CameraDiagnostics"] = "1"
}
if ($RtxFocusPreservation) {
    $requiredSafeProfileSettings["Compatibility.PreserveRtxRendererOnFocusChange"] = "1"
}
if ($RtxCameraReassertion) {
    $requiredSafeProfileSettings["Diagnostics.RtxCameraReassertion"] = "1"
}
$profileSettings = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
$currentProfileSection = $null
$profileInputPaths = @($profilePath)
if ($RemixCameraDiagnostics) {
    $profileInputPaths += $remixDiagnosticsProfileOverridePath
}
if ($CameraDiagnostics -and -not $RtxCameraReassertion) {
    $profileInputPaths += $cameraDiagnosticsProfileOverridePath
}
if ($RtxFocusPreservation -and -not $RtxCameraReassertion) {
    $profileInputPaths += $rtxFocusPreservationProfileOverridePath
}
if ($RtxCameraReassertion) {
    $profileInputPaths += $rtxCameraReassertionProfileOverridePath
}
foreach ($profileLine in $profileInputPaths | ForEach-Object { Get-Content -LiteralPath $_ }) {
    $trimmedLine = $profileLine.Trim()
    if ($trimmedLine.Length -eq 0 -or $trimmedLine.StartsWith(";")) {
        continue
    }
    if ($trimmedLine.StartsWith("[")) {
        if ($trimmedLine -notmatch '^\[([^\]]+)\]$') {
            throw "Engine-only profile contains a malformed section: $profileLine"
        }
        $currentProfileSection = $Matches[1].Trim()
        continue
    }
    if (-not $currentProfileSection) {
        throw "Engine-only profile contains a setting outside a section: $profileLine"
    }
    if ($trimmedLine -notmatch '^([^=]+?)\s*=\s*(.*?)\s*$') {
        throw "Engine-only profile contains an unrecognized active line: $profileLine"
    }
    $profileKey = $Matches[1].Trim()
    $profileValue = $Matches[2].Trim()
    $qualifiedProfileKey = "$currentProfileSection.$profileKey"
    if ($profileSettings.ContainsKey($qualifiedProfileKey)) {
        throw "Engine-only profile contains duplicate setting: $qualifiedProfileKey"
    }
    $profileSettings[$qualifiedProfileKey] = $profileValue
}
foreach ($setting in $requiredSafeProfileSettings.GetEnumerator()) {
    if (-not $profileSettings.ContainsKey($setting.Key) -or $profileSettings[$setting.Key] -ne $setting.Value) {
        throw "Engine-only profile requires $($setting.Key) = $($setting.Value)"
    }
}
if ($CameraDiagnostics -and $profileSettings.ContainsKey("Diagnostics.RemixCameraDiagnostics") -and
    $profileSettings["Diagnostics.RemixCameraDiagnostics"] -ne "0") {
    throw 'The camera diagnostics package must not enable Diagnostics.RemixCameraDiagnostics.'
}

$submoduleCommitBeforeLines = @(Invoke-GitCapture @("-C", $submoduleRoot, "rev-parse", "HEAD"))
$submoduleCommitBefore = $submoduleCommitBeforeLines[0].Trim()
if ($submoduleCommitBefore -ne $ExpectedCommit) {
    throw "EchoPatch is at $submoduleCommitBefore; expected pinned commit $ExpectedCommit."
}
$submoduleStatusBefore = @(Invoke-GitCapture @("-C", $submoduleRoot, "status", "--porcelain=v1", "--untracked-files=all"))
if ($submoduleStatusBefore.Count -ne 0) {
    throw "EchoPatch submodule must be clean before building:`n$($submoduleStatusBefore -join [Environment]::NewLine)"
}

$parentGitlink = @(Invoke-GitCapture @("-C", $repoRoot, "ls-tree", "HEAD", "external/EchoPatch"))
if ($parentGitlink.Count -ne 1 -or $parentGitlink[0] -notmatch "160000 commit $ExpectedCommit") {
    throw "The parent repository does not pin external/EchoPatch to $ExpectedCommit."
}

Assert-ExistingPathChainHasNoReparsePoints -Base $vendorRoot -Target $outputParent
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
Assert-ExistingPathChainHasNoReparsePoints -Base $vendorRoot -Target $outputParent

$transactionId = '{0}-{1}' -f $PID, ([Guid]::NewGuid().ToString('N').Substring(0, 8))
# Keep the isolated root names short: MSBuild still contains legacy tools that
# can hit MAX_PATH after appending project/intermediate paths.
$transactionRoot = Join-Path $outputParent ".epb-$transactionId"
Assert-ChildPath -Child $transactionRoot -Parent $vendorRoot
if (Test-Path -LiteralPath $transactionRoot) {
    throw "EchoPatch transaction path collision for $transactionId."
}

New-Item -ItemType Directory -Path $transactionRoot | Out-Null
try {
$archivePath = Join-Path $transactionRoot "EchoPatch-$ExpectedCommit.zip"
$extractRoot = Join-Path $transactionRoot "source-$shortCommit"
$sourceRoot = Join-Path $extractRoot "EchoPatch"
$minHookExtractRoot = Join-Path $transactionRoot "minhook-source-$($MinHookCommit.Substring(0, 12))"
$minHookSourceRoot = Join-Path $minHookExtractRoot "minhook-$MinHookCommit"
$packageRoot = Join-Path $transactionRoot "local-package-$shortCommit"
$minHookBuildLog = Join-Path $transactionRoot "minhook-build-$shortCommit.log"
$minHookBuildDriver = Join-Path $transactionRoot "minhook-build-$shortCommit.cmd"
$buildLog = Join-Path $transactionRoot "build-$shortCommit.log"
$buildDriver = Join-Path $transactionRoot "build-$shortCommit.cmd"
$manifestPath = Join-Path $transactionRoot "manifest-$shortCommit.json"

$archiveOutput = & git -C $submoduleRoot archive --format=zip "--output=$archivePath" --prefix=EchoPatch/ $ExpectedCommit 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "git archive failed:`n$($archiveOutput -join [Environment]::NewLine)"
}
Expand-Archive -LiteralPath $archivePath -DestinationPath $extractRoot
Expand-Archive -LiteralPath $MinHookArchive -DestinationPath $minHookExtractRoot
if (-not (Test-Path -LiteralPath (Join-Path $minHookSourceRoot "LICENSE.txt"))) {
    throw "MinHook archive did not contain the expected commit-root layout: $minHookSourceRoot"
}

$relativeMinHookSource = $minHookSourceRoot.Substring($repoRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/')
$minHookCheckOutput = & git -C $repoRoot apply --check --whitespace=error-all "--directory=$relativeMinHookSource" $minHookPatchPath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "MinHook CRT patch preflight failed:`n$($minHookCheckOutput -join [Environment]::NewLine)"
}
$minHookApplyOutput = & git -C $repoRoot apply --whitespace=error-all "--directory=$relativeMinHookSource" $minHookPatchPath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "MinHook CRT patch application failed:`n$($minHookApplyOutput -join [Environment]::NewLine)"
}

$relativeSource = $sourceRoot.Substring($repoRoot.TrimEnd('\', '/').Length + 1).Replace('\', '/')
$checkOutput = & git -C $repoRoot apply --check --whitespace=error-all "--directory=$relativeSource" $patchPath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Patch preflight failed:`n$($checkOutput -join [Environment]::NewLine)"
}
$applyOutput = & git -C $repoRoot apply --whitespace=error-all "--directory=$relativeSource" $patchPath 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Patch application failed:`n$($applyOutput -join [Environment]::NewLine)"
}

if ($RemixCameraDiagnostics) {
    $diagnosticCheckOutput = & git -C $repoRoot apply --check --whitespace=error-all "--directory=$relativeSource" $remixDiagnosticsPatchPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "RTX Remix diagnostics patch preflight failed:`n$($diagnosticCheckOutput -join [Environment]::NewLine)"
    }
    $diagnosticApplyOutput = & git -C $repoRoot apply --whitespace=error-all "--directory=$relativeSource" $remixDiagnosticsPatchPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "RTX Remix diagnostics patch application failed:`n$($diagnosticApplyOutput -join [Environment]::NewLine)"
    }

    $diagnosticSourceDirectory = Join-Path $sourceRoot "src\Engine\RemixDiagnostics"
    New-Item -ItemType Directory -Force -Path $diagnosticSourceDirectory | Out-Null
    Copy-Item -LiteralPath $remixDiagnosticsOverlayPath -Destination (Join-Path $diagnosticSourceDirectory "RemixCameraDiagnostics.cpp") -Force
}
if ($CameraDiagnostics) {
    $cameraDiagnosticCheckOutput = & git -C $repoRoot apply --check --whitespace=error-all "--directory=$relativeSource" $cameraDiagnosticsPatchPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Camera diagnostics patch preflight failed:`n$($cameraDiagnosticCheckOutput -join [Environment]::NewLine)"
    }
    $cameraDiagnosticApplyOutput = & git -C $repoRoot apply --whitespace=error-all "--directory=$relativeSource" $cameraDiagnosticsPatchPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Camera diagnostics patch application failed:`n$($cameraDiagnosticApplyOutput -join [Environment]::NewLine)"
    }

    $cameraDiagnosticSourceDirectory = Join-Path $sourceRoot "src\Engine\CameraDiagnostics"
    New-Item -ItemType Directory -Force -Path $cameraDiagnosticSourceDirectory | Out-Null
    Copy-Item -LiteralPath $cameraDiagnosticsOverlayPath -Destination (Join-Path $cameraDiagnosticSourceDirectory "CameraDiagnostics.cpp") -Force
}
if ($RtxFocusPreservation) {
    $rtxFocusCheckOutput = & git -C $repoRoot apply --check --whitespace=error-all "--directory=$relativeSource" $rtxFocusPreservationPatchPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "RTX focus-preservation patch preflight failed:`n$($rtxFocusCheckOutput -join [Environment]::NewLine)"
    }
    $rtxFocusApplyOutput = & git -C $repoRoot apply --whitespace=error-all "--directory=$relativeSource" $rtxFocusPreservationPatchPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "RTX focus-preservation patch application failed:`n$($rtxFocusApplyOutput -join [Environment]::NewLine)"
    }

    $rtxFocusSourceDirectory = Join-Path $sourceRoot "src\Engine\RtxFocusPreservation"
    New-Item -ItemType Directory -Force -Path $rtxFocusSourceDirectory | Out-Null
    Copy-Item -LiteralPath $rtxFocusPreservationOverlayPath -Destination (Join-Path $rtxFocusSourceDirectory "RtxFocusPreservation.cpp") -Force
}
if ($RtxCameraReassertion) {
    $rtxCameraReassertionSourceDirectory = Join-Path $sourceRoot "src\Engine\RtxCameraReassertion"
    New-Item -ItemType Directory -Force -Path $rtxCameraReassertionSourceDirectory | Out-Null
    Copy-Item -LiteralPath $rtxCameraReassertionOverlayPath `
        -Destination (Join-Path $rtxCameraReassertionSourceDirectory "RtxCameraReassertion.cpp") -Force

    # The focused patch is deliberately applied after CameraDiagnostics.cpp is
    # copied. It adds only passive observer calls, leaving CameraDiagnostics as
    # the sole owner of the D3D9 vtable hooks.
    $rtxCameraReassertionCheckOutput = & git -C $repoRoot apply --check --whitespace=error-all `
        "--directory=$relativeSource" $rtxCameraReassertionPatchPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "RTX camera-reassertion patch preflight failed:`n$($rtxCameraReassertionCheckOutput -join [Environment]::NewLine)"
    }
    $rtxCameraReassertionApplyOutput = & git -C $repoRoot apply --whitespace=error-all `
        "--directory=$relativeSource" $rtxCameraReassertionPatchPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "RTX camera-reassertion patch application failed:`n$($rtxCameraReassertionApplyOutput -join [Environment]::NewLine)"
    }
}

$patchedInitialization = Join-Path $sourceRoot "src\Initialization.cpp"
foreach ($sourceProof in @("PatchGameModules=0;", "GameClient.dll, GameServer.dll, and ClientFX hooks were intentionally skipped.")) {
    if (-not (Select-String -LiteralPath $patchedInitialization -SimpleMatch $sourceProof -Quiet)) {
        throw "Patched source does not contain compatibility proof fragment: $sourceProof"
    }
}
$builtProfilePath = Join-Path $sourceRoot "EchoPatch\EchoPatch.ini"
Copy-Item -LiteralPath $profilePath -Destination $builtProfilePath -Force
if ($RemixCameraDiagnostics) {
    [IO.File]::AppendAllText(
        $builtProfilePath,
        [IO.File]::ReadAllText($remixDiagnosticsProfileOverridePath),
        [Text.UTF8Encoding]::new($false))
}
if ($CameraDiagnostics -and -not $RtxCameraReassertion) {
    [IO.File]::AppendAllText(
        $builtProfilePath,
        [IO.File]::ReadAllText($cameraDiagnosticsProfileOverridePath),
        [Text.UTF8Encoding]::new($false))
}
if ($RtxFocusPreservation -and -not $RtxCameraReassertion) {
    [IO.File]::AppendAllText(
        $builtProfilePath,
        [IO.File]::ReadAllText($rtxFocusPreservationProfileOverridePath),
        [Text.UTF8Encoding]::new($false))
}
if ($RtxCameraReassertion) {
    [IO.File]::AppendAllText(
        $builtProfilePath,
        [IO.File]::ReadAllText($rtxCameraReassertionProfileOverridePath),
        [Text.UTF8Encoding]::new($false))
}

$msbuild = Find-MSBuild
$normalizedPath = $env:Path
$minHookProject = Join-Path $minHookSourceRoot "build\VC17\libMinHook.vcxproj"
$minHookDriverLines = @(
    "@echo off",
    'set "PATH="',
    ('set "Path={0}"' -f $normalizedPath),
    ('"{0}" "{1}" /m:1 /t:Rebuild /p:Configuration=Release /p:Platform=Win32 /p:PlatformToolset={2} /nologo /verbosity:minimal' -f $msbuild, $minHookProject, $PlatformToolset),
    "exit /b %ERRORLEVEL%"
)
$minHookDriverLines | Set-Content -LiteralPath $minHookBuildDriver -Encoding ASCII
$minHookBuildOutput = & $env:ComSpec /d /c "`"$minHookBuildDriver`"" 2>&1
$minHookBuildExitCode = $LASTEXITCODE
$minHookBuildOutput | Set-Content -LiteralPath $minHookBuildLog -Encoding UTF8
if ($minHookBuildExitCode -ne 0) {
    throw "MinHook x86 Release dependency build failed. See $minHookBuildLog"
}

$rebuiltMinHook = Join-Path $minHookSourceRoot "build\VC17\lib\Release\libMinHook.x86.lib"
if (-not (Test-Path -LiteralPath $rebuiltMinHook)) {
    throw "MinHook build succeeded but output is missing: $rebuiltMinHook"
}
Copy-Item -LiteralPath $rebuiltMinHook -Destination (Join-Path $sourceRoot "lib\libMinHook.x86.lib") -Force

$solution = Join-Path $sourceRoot "EchoPatch.sln"
$driverLines = @(
    "@echo off",
    'set "PATH="',
    ('set "Path={0}"' -f $normalizedPath),
    ('"{0}" "{1}" /m:1 /t:Rebuild /p:Configuration=Release /p:Platform=x86 /p:PlatformToolset={2} /nologo /verbosity:minimal' -f $msbuild, $solution, $PlatformToolset),
    "exit /b %ERRORLEVEL%"
)
$driverLines | Set-Content -LiteralPath $buildDriver -Encoding ASCII
$buildOutput = & $env:ComSpec /d /c "`"$buildDriver`"" 2>&1
$buildExitCode = $LASTEXITCODE
$buildOutput | Set-Content -LiteralPath $buildLog -Encoding UTF8
if ($buildExitCode -ne 0) {
    throw "EchoPatch x86 Release build failed. See $buildLog"
}
if (@($buildOutput | Where-Object { "$_" -match '\bLNK4098\b' }).Count -ne 0) {
    throw "EchoPatch linked with a conflicting C runtime (LNK4098). See $buildLog"
}

$dllPath = Join-Path $sourceRoot "bin\Release\dinput8.dll"
if (-not (Test-Path -LiteralPath $dllPath)) {
    throw "MSBuild succeeded but output is missing: $dllPath"
}
$pe = Get-PEMetadata $dllPath
if ($pe.Machine -ne $ExpectedMachine -or $pe.OptionalHeader -ne $ExpectedOptionalHeader) {
    throw ("Unexpected PE target: Machine=0x{0:x4}, OptionalHeader=0x{1:x4}; expected PE32 x86." -f $pe.Machine, $pe.OptionalHeader)
}
$binaryText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($dllPath))
if (-not $binaryText.Contains($CompatibilityProof)) {
    throw "Built DLL does not contain the compatibility proof string."
}
if ($RemixCameraDiagnostics -and -not $binaryText.Contains($RemixDiagnosticsProof)) {
    throw "Built DLL does not contain the RTX Remix diagnostics proof string."
}
if ($CameraDiagnostics -and -not $binaryText.Contains($CameraDiagnosticsProof)) {
    throw "Built DLL does not contain the query-light camera diagnostics proof string."
}
if ($RtxFocusPreservation -and -not $binaryText.Contains($RtxFocusPreservationProof)) {
    throw "Built DLL does not contain the RTX focus-preservation proof string."
}
if ($RtxCameraReassertion -and
    (-not $binaryText.Contains($RtxCameraReassertionProof) -or
        -not $binaryText.Contains($RtxCameraReassertionLogProof))) {
    throw "Built DLL does not contain the RTX camera-reassertion proof strings."
}

New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null
Copy-Item -LiteralPath $dllPath -Destination (Join-Path $packageRoot "dinput8.dll")
Copy-Item -LiteralPath $builtProfilePath -Destination (Join-Path $packageRoot "EchoPatch.ini")
Copy-Item -LiteralPath (Join-Path $sourceRoot "LICENSE") -Destination (Join-Path $packageRoot "LICENSE.EchoPatch-GPL-3.0.txt")
Copy-Item -LiteralPath (Join-Path $minHookSourceRoot "LICENSE.txt") -Destination (Join-Path $packageRoot "LICENSE.MinHook-BSD-2-Clause.txt")
Copy-Item -LiteralPath $patchPath -Destination (Join-Path $packageRoot (Split-Path $patchPath -Leaf))
Copy-Item -LiteralPath $minHookPatchPath -Destination (Join-Path $packageRoot (Split-Path $minHookPatchPath -Leaf))
if ($RemixCameraDiagnostics) {
    Copy-Item -LiteralPath $remixDiagnosticsPatchPath -Destination (Join-Path $packageRoot (Split-Path $remixDiagnosticsPatchPath -Leaf))
    Copy-Item -LiteralPath $remixDiagnosticsOverlayPath -Destination (Join-Path $packageRoot "RemixCameraDiagnostics.cpp")
    Copy-Item -LiteralPath $remixDiagnosticsProfileOverridePath -Destination (Join-Path $packageRoot (Split-Path $remixDiagnosticsProfileOverridePath -Leaf))
}
if ($CameraDiagnostics) {
    Copy-Item -LiteralPath $cameraDiagnosticsPatchPath -Destination (Join-Path $packageRoot (Split-Path $cameraDiagnosticsPatchPath -Leaf))
    Copy-Item -LiteralPath $cameraDiagnosticsOverlayPath -Destination (Join-Path $packageRoot "CameraDiagnostics.cpp")
    if (-not $RtxCameraReassertion) {
        Copy-Item -LiteralPath $cameraDiagnosticsProfileOverridePath -Destination (Join-Path $packageRoot (Split-Path $cameraDiagnosticsProfileOverridePath -Leaf))
    }
}
if ($RtxFocusPreservation) {
    Copy-Item -LiteralPath $rtxFocusPreservationPatchPath -Destination (Join-Path $packageRoot (Split-Path $rtxFocusPreservationPatchPath -Leaf))
    Copy-Item -LiteralPath $rtxFocusPreservationOverlayPath -Destination (Join-Path $packageRoot "RtxFocusPreservation.cpp")
    if (-not $RtxCameraReassertion) {
        Copy-Item -LiteralPath $rtxFocusPreservationProfileOverridePath -Destination (Join-Path $packageRoot (Split-Path $rtxFocusPreservationProfileOverridePath -Leaf))
    }
}
if ($RtxCameraReassertion) {
    Copy-Item -LiteralPath $rtxCameraReassertionPatchPath -Destination (Join-Path $packageRoot (Split-Path $rtxCameraReassertionPatchPath -Leaf))
    Copy-Item -LiteralPath $rtxCameraReassertionOverlayPath -Destination (Join-Path $packageRoot "RtxCameraReassertion.cpp")
    Copy-Item -LiteralPath $rtxCameraReassertionProfileOverridePath -Destination (Join-Path $packageRoot (Split-Path $rtxCameraReassertionProfileOverridePath -Leaf))
}

$submoduleCommitAfterLines = @(Invoke-GitCapture @("-C", $submoduleRoot, "rev-parse", "HEAD"))
$submoduleCommitAfter = $submoduleCommitAfterLines[0].Trim()
$submoduleStatusAfter = @(Invoke-GitCapture @("-C", $submoduleRoot, "status", "--porcelain=v1", "--untracked-files=all"))
if ($submoduleCommitAfter -ne $submoduleCommitBefore -or $submoduleStatusAfter.Count -ne 0) {
    throw "EchoPatch submodule changed during the isolated build."
}

$dllHash = (Get-FileHash -LiteralPath $dllPath -Algorithm SHA256).Hash
$manifest = [ordered]@{
    echoPatchCommit = $ExpectedCommit
    upstreamUrl = "https://github.com/Wemino/EchoPatch"
    patchSha256 = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash
    profileSha256 = (Get-FileHash -LiteralPath $builtProfilePath -Algorithm SHA256).Hash
    sourceArchiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    minHookCommit = $MinHookCommit
    minHookUpstreamUrl = "https://github.com/TsudaKageyu/minhook"
    minHookSourceArchiveSha256 = $actualMinHookArchiveSha256
    minHookCrtPatchSha256 = (Get-FileHash -LiteralPath $minHookPatchPath -Algorithm SHA256).Hash
    rebuiltMinHookSha256 = (Get-FileHash -LiteralPath $rebuiltMinHook -Algorithm SHA256).Hash
    binarySha256 = $dllHash
    configuration = "Release"
    solutionPlatform = "x86"
    projectPlatform = "Win32"
    platformToolset = $PlatformToolset
    machine = ("0x{0:x4}" -f $pe.Machine)
    optionalHeader = ("0x{0:x4}" -f $pe.OptionalHeader)
    moduleHooks = $false
    compatibilityProof = $CompatibilityProof
    submoduleCleanBefore = $true
    submoduleCleanAfter = $true
    runtimeAccepted = $false
}
if ($RemixCameraDiagnostics) {
    $manifest.packageMode = "RemixDiagnosticEchoPatch"
    $manifest.remixCameraDiagnostics = $true
    $manifest.remixDiagnosticsProof = $RemixDiagnosticsProof
    $manifest.remixDiagnosticsPatchSha256 = (Get-FileHash -LiteralPath $remixDiagnosticsPatchPath -Algorithm SHA256).Hash
    $manifest.remixDiagnosticsOverlaySha256 = (Get-FileHash -LiteralPath $remixDiagnosticsOverlayPath -Algorithm SHA256).Hash
    $manifest.profileBaseSha256 = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $manifest.profileOverrideSha256 = (Get-FileHash -LiteralPath $remixDiagnosticsProfileOverridePath -Algorithm SHA256).Hash
}
elseif ($RtxCameraReassertion) {
    $manifest.packageMode = "RtxCameraReassertionEchoPatch"
    $manifest.cameraDiagnostics = $true
    $manifest.cameraDiagnosticsProof = $CameraDiagnosticsProof
    $manifest.cameraDiagnosticsPatchSha256 = (Get-FileHash -LiteralPath $cameraDiagnosticsPatchPath -Algorithm SHA256).Hash
    $manifest.cameraDiagnosticsOverlaySha256 = (Get-FileHash -LiteralPath $cameraDiagnosticsOverlayPath -Algorithm SHA256).Hash
    $manifest.rtxFocusPreservation = $true
    $manifest.rtxFocusPreservationProof = $RtxFocusPreservationProof
    $manifest.rtxFocusPreservationPatchSha256 = (Get-FileHash -LiteralPath $rtxFocusPreservationPatchPath -Algorithm SHA256).Hash
    $manifest.rtxFocusPreservationOverlaySha256 = (Get-FileHash -LiteralPath $rtxFocusPreservationOverlayPath -Algorithm SHA256).Hash
    $manifest.rtxCameraReassertion = $true
    $manifest.rtxCameraReassertionProof = $RtxCameraReassertionProof
    $manifest.rtxCameraReassertionPatchSha256 = (Get-FileHash -LiteralPath $rtxCameraReassertionPatchPath -Algorithm SHA256).Hash
    $manifest.rtxCameraReassertionOverlaySha256 = (Get-FileHash -LiteralPath $rtxCameraReassertionOverlayPath -Algorithm SHA256).Hash
    $manifest.profileBaseSha256 = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $manifest.profileOverrideSha256 = (Get-FileHash -LiteralPath $rtxCameraReassertionProfileOverridePath -Algorithm SHA256).Hash
    $manifest.rtxCameraReassertionProfileOverrideSha256 = (Get-FileHash -LiteralPath $rtxCameraReassertionProfileOverridePath -Algorithm SHA256).Hash
}
elseif ($RtxFocusPreservation) {
    $manifest.packageMode = "RtxCameraDiagnosticEchoPatch"
    $manifest.cameraDiagnostics = $true
    $manifest.cameraDiagnosticsProof = $CameraDiagnosticsProof
    $manifest.cameraDiagnosticsPatchSha256 = (Get-FileHash -LiteralPath $cameraDiagnosticsPatchPath -Algorithm SHA256).Hash
    $manifest.cameraDiagnosticsOverlaySha256 = (Get-FileHash -LiteralPath $cameraDiagnosticsOverlayPath -Algorithm SHA256).Hash
    $manifest.rtxFocusPreservation = $true
    $manifest.rtxFocusPreservationProof = $RtxFocusPreservationProof
    $manifest.rtxFocusPreservationPatchSha256 = (Get-FileHash -LiteralPath $rtxFocusPreservationPatchPath -Algorithm SHA256).Hash
    $manifest.rtxFocusPreservationOverlaySha256 = (Get-FileHash -LiteralPath $rtxFocusPreservationOverlayPath -Algorithm SHA256).Hash
    $manifest.profileBaseSha256 = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $manifest.profileOverrideSha256 = (Get-FileHash -LiteralPath $cameraDiagnosticsProfileOverridePath -Algorithm SHA256).Hash
    $manifest.rtxFocusPreservationProfileOverrideSha256 = (Get-FileHash -LiteralPath $rtxFocusPreservationProfileOverridePath -Algorithm SHA256).Hash
}
elseif ($CameraDiagnostics) {
    $manifest.packageMode = "CameraDiagnosticEchoPatch"
    $manifest.cameraDiagnostics = $true
    $manifest.cameraDiagnosticsProof = $CameraDiagnosticsProof
    $manifest.cameraDiagnosticsPatchSha256 = (Get-FileHash -LiteralPath $cameraDiagnosticsPatchPath -Algorithm SHA256).Hash
    $manifest.cameraDiagnosticsOverlaySha256 = (Get-FileHash -LiteralPath $cameraDiagnosticsOverlayPath -Algorithm SHA256).Hash
    $manifest.profileBaseSha256 = (Get-FileHash -LiteralPath $profilePath -Algorithm SHA256).Hash
    $manifest.profileOverrideSha256 = (Get-FileHash -LiteralPath $cameraDiagnosticsProfileOverridePath -Algorithm SHA256).Hash
}
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

Assert-NoReparsePoints -Path $transactionRoot
Assert-PackageCoherence `
    -CandidateRoot $transactionRoot `
    -CandidatePackageRoot $packageRoot `
    -CandidateManifestPath $manifestPath `
    -ExpectedPackageMode $expectedPackageMode

if ($TestFailBeforePromotion) {
    throw 'Forced EchoPatch transaction failure before promotion.'
}

Publish-EchoPatchCandidate `
    -Context $promotionContext `
    -CandidateRoot $transactionRoot `
    -ExpectedPackageMode $expectedPackageMode

$finalDllPath = Join-Path $OutputRoot "source-$shortCommit\EchoPatch\bin\Release\dinput8.dll"
$finalPackageRoot = Join-Path $OutputRoot "local-package-$shortCommit"
Write-Host "EchoPatch engine-only build passed."
Write-Host "  Commit: $ExpectedCommit"
Write-Host "  DLL: $finalDllPath"
Write-Host "  Package: $finalPackageRoot"
Write-Host "  SHA256: $dllHash"
Write-Host "  PE: x86 / PE32"
Write-Host "  Submodule: clean and unchanged"
Write-Host "  Package mode: $expectedPackageMode"
Write-Host "  Runtime acceptance: not run (requires a user-owned retail F.E.A.R. installation)"
}
finally {
    if (Test-Path -LiteralPath $transactionRoot) {
        $recoveryRecordRemains =
            (Test-Path -LiteralPath $promotionContext.JournalPath) -or
            (Test-Path -LiteralPath $promotionContext.CommitPath)
        if ($recoveryRecordRemains) {
            Write-Warning "EchoPatch promotion recovery remains pending; preserving transaction candidate '$transactionRoot'."
        }
        else {
            try {
                Remove-GuardedTree -Path $transactionRoot -Parent $vendorRoot
            }
            catch {
                Write-Warning "EchoPatch transaction cleanup left the unpromoted candidate at '$transactionRoot': $($_.Exception.Message)"
            }
        }
    }
}
