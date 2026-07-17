[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-DirectorySnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    return (@(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relativePath = $_.FullName.Substring([IO.Path]::GetFullPath($Root).TrimEnd('\').Length).TrimStart('\')
        if ($_.PSIsContainer) {
            "DIR|$relativePath|$([int]$_.Attributes)"
        }
        else {
            "FILE|$relativePath|$([int]$_.Attributes)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        }
    }) -join "`n")
}

function Remove-RendererTestPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$LocalRuntimeRoot,
        [Parameter(Mandatory = $true)][string[]]$AllowedPaths
    )

    $rootFull = [IO.Path]::GetFullPath($LocalRuntimeRoot).TrimEnd('\')
    $pathFull = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $allowedFull = @($AllowedPaths | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') })
    if ($pathFull -notin $allowedFull -or
        -not $pathFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing renderer-test cleanup outside its exact local-runtime output set: $pathFull"
    }
    if (-not (Test-Path -LiteralPath $pathFull)) {
        return
    }

    $item = Get-Item -LiteralPath $pathFull -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing renderer-test cleanup through a top-level reparse point: $pathFull"
    }
    if (-not $item.PSIsContainer) {
        Remove-Item -LiteralPath $pathFull -Force
        return
    }

    # Runtime stages contain one intentional read-only Retail junction. Remove
    # that exact link without recursion before inspecting/deleting ordinary data.
    foreach ($topLevelItem in @(Get-ChildItem -LiteralPath $pathFull -Force)) {
        if (($topLevelItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            continue
        }
        if ($topLevelItem.Name -cne 'Retail' -or
            -not $topLevelItem.PSIsContainer -or
            $topLevelItem.LinkType -cne 'Junction') {
            throw "Refusing renderer-test cleanup through an unexpected reparse point: $($topLevelItem.FullName)"
        }
        # Windows PowerShell 5.1 can throw a NullReferenceException from
        # Remove-Item when the item is a directory junction. Directory.Delete
        # with recursive=false removes only the validated junction entry and
        # cannot traverse into its retail-fixture target.
        [IO.Directory]::Delete($topLevelItem.FullName, $false)
    }
    $nestedReparse = Get-ChildItem -LiteralPath $pathFull -Force -Recurse |
        Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($nestedReparse) {
        throw "Refusing renderer-test cleanup through a nested reparse point: $($nestedReparse.FullName)"
    }
    Remove-Item -LiteralPath $pathFull -Recurse -Force
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
$runtimeExecutableModule = Join-Path $PSScriptRoot 'FearRuntimeExecutable.psm1'
$stageSafetyModule = Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1'
$stagePlanModule = Join-Path $PSScriptRoot 'FearRuntimeStagePlan.psm1'
$stageOwnershipModule = Join-Path $PSScriptRoot 'FearRuntimeStageOwnership.psm1'
$rendererPackageModule = Join-Path $PSScriptRoot 'FearRendererPackage.psm1'
$enginePatchPackageModule = Join-Path $PSScriptRoot 'FearEnginePatchPackage.psm1'
$rendererConfig = Join-Path $PSScriptRoot 'config\dgVoodoo-d3d11.conf'
$rendererMax2xConfig = Join-Path $PSScriptRoot 'config\dgVoodoo-d3d11-max2x.conf'
$rtxBridgeConfig = Join-Path $PSScriptRoot 'config\rtx-remix-bridge.conf'
$rtxRuntimeConfigSeed = Join-Path $PSScriptRoot 'config\rtx-remix-runtime.conf'
$sdkRuntimeExecutable = Join-Path $RepositoryRoot 'vendor-local\fear-sdk-108\Runtime\FEARDevSP.exe'
$buildRoot = Join-Path $RepositoryRoot "build\fear-win32\bin\$Configuration"
$dgVoodooArchive = Join-Path $RepositoryRoot 'vendor-local\renderer-deps\dgVoodoo2_87_3.zip'
$rtxRemixArchive = Join-Path $RepositoryRoot 'vendor-local\renderer-deps\remix-1.5.2-release.zip'
$enginePatchPackageRoot = Join-Path $RepositoryRoot 'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb'
$enginePatchManifest = Join-Path $RepositoryRoot 'vendor-local\echopatch-engine-only\manifest-b4a7074e4cbb.json'
$remixDiagnosticPackageRoot = Join-Path $RepositoryRoot 'vendor-local\echopatch-remix-diagnostics\local-package-b4a7074e4cbb'
$remixDiagnosticManifest = Join-Path $RepositoryRoot 'vendor-local\echopatch-remix-diagnostics\manifest-b4a7074e4cbb.json'
$remixDiagnosticPatchSource = Join-Path $RepositoryRoot 'patches\echopatch\0003-add-remix-camera-diagnostics.patch'
$remixDiagnosticOverlaySource = Join-Path $RepositoryRoot 'tools\echopatch\overlays\RemixCameraDiagnostics.cpp'
$rtxDiagnosticParameters = @{
    EnginePatchMode        = 'RemixDiagnosticEchoPatch'
    EnginePatchPackageRoot = $remixDiagnosticPackageRoot
    EnginePatchManifest    = $remixDiagnosticManifest
}
$runId = [Guid]::NewGuid().ToString('N')

$protectedInputs = @(
    $stageScript,
    $runtimeExecutableModule,
    $stageSafetyModule,
    $stagePlanModule,
    $stageOwnershipModule,
    $rendererPackageModule,
    $enginePatchPackageModule,
    $rendererConfig,
    $rendererMax2xConfig,
    $rtxBridgeConfig,
    $rtxRuntimeConfigSeed,
    $sdkRuntimeExecutable,
    (Join-Path $buildRoot 'GameClient.dll'),
    (Join-Path $buildRoot 'GameServer.dll'),
    (Join-Path $buildRoot 'ClientFx.fxd'),
    $dgVoodooArchive,
    $rtxRemixArchive,
    (Join-Path $enginePatchPackageRoot 'dinput8.dll'),
    (Join-Path $enginePatchPackageRoot 'EchoPatch.ini'),
    $enginePatchManifest,
    (Join-Path $remixDiagnosticPackageRoot 'dinput8.dll'),
    (Join-Path $remixDiagnosticPackageRoot 'EchoPatch.ini'),
    $remixDiagnosticManifest,
    $remixDiagnosticPatchSource,
    $remixDiagnosticOverlaySource
)
foreach ($inputPath in $protectedInputs) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "Renderer-stage test input is missing: $inputPath"
    }
}
$beforeHashes = @{}
foreach ($inputPath in $protectedInputs) {
    $beforeHashes[$inputPath] = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
}
$remixDiagnosticSourceManifest = Get-Content -LiteralPath $remixDiagnosticManifest -Raw | ConvertFrom-Json
if (-not $remixDiagnosticSourceManifest.PSObject.Properties['remixDiagnosticsPatchSha256'] -or
    -not $remixDiagnosticSourceManifest.PSObject.Properties['remixDiagnosticsOverlaySha256'] -or
    [string]$remixDiagnosticSourceManifest.remixDiagnosticsPatchSha256 -cne $beforeHashes[$remixDiagnosticPatchSource] -or
    [string]$remixDiagnosticSourceManifest.remixDiagnosticsOverlaySha256 -cne $beforeHashes[$remixDiagnosticOverlaySource]) {
    throw 'Pinned Remix diagnostic package is not coherent with the tracked patch/overlay sources. Rebuild and repin it before renderer-stage verification.'
}

Import-Module $runtimeExecutableModule -Force -ErrorAction Stop
Import-Module $rendererPackageModule -Force -ErrorAction Stop

$nativeRendererConfigIdentity = Get-FearDgVoodooConfigIdentity `
    -Path $rendererConfig `
    -RendererQuality Native
$max2xRendererConfigIdentity = Get-FearDgVoodooConfigIdentity `
    -Path $rendererMax2xConfig `
    -RendererQuality Max2x
if ($nativeRendererConfigIdentity.RendererQuality -cne 'Native' -or
    $nativeRendererConfigIdentity.OutputAPI -cne 'd3d11_fl11_0' -or
    $nativeRendererConfigIdentity.Resolution -cne 'unforced' -or
    $nativeRendererConfigIdentity.ScalingMode -cne 'unspecified' -or
    $nativeRendererConfigIdentity.Resampling -cne 'lanczos-3' -or
    $nativeRendererConfigIdentity.Filtering -cne 'appdriven' -or
    $nativeRendererConfigIdentity.Antialiasing -cne 'appdriven' -or
    $nativeRendererConfigIdentity.VRAM -ne 256 -or
    $nativeRendererConfigIdentity.FPSLimit -ne 0 -or
    $nativeRendererConfigIdentity.ForceVerticalSync -ne $false -or
    $nativeRendererConfigIdentity.Sha256 -cne $beforeHashes[$rendererConfig]) {
    throw 'Project-owned dgVoodoo Native profile is not the exact conservative D3D11 identity.'
}
if ($max2xRendererConfigIdentity.RendererQuality -cne 'Max2x' -or
    $max2xRendererConfigIdentity.OutputAPI -cne $nativeRendererConfigIdentity.OutputAPI -or
    $max2xRendererConfigIdentity.Resolution -cne 'max_2x' -or
    $max2xRendererConfigIdentity.ScalingMode -cne $nativeRendererConfigIdentity.ScalingMode -or
    $max2xRendererConfigIdentity.Resampling -cne $nativeRendererConfigIdentity.Resampling -or
    $max2xRendererConfigIdentity.Filtering -cne $nativeRendererConfigIdentity.Filtering -or
    $max2xRendererConfigIdentity.Antialiasing -cne $nativeRendererConfigIdentity.Antialiasing -or
    $max2xRendererConfigIdentity.VRAM -ne $nativeRendererConfigIdentity.VRAM -or
    $max2xRendererConfigIdentity.FPSLimit -ne $nativeRendererConfigIdentity.FPSLimit -or
    $max2xRendererConfigIdentity.ForceVerticalSync -ne $nativeRendererConfigIdentity.ForceVerticalSync -or
    $max2xRendererConfigIdentity.Sha256 -cne $beforeHashes[$rendererMax2xConfig]) {
    throw 'Project-owned dgVoodoo Max2x profile changed settings outside the owned resolution multiplier.'
}
$rendererQualityMismatchRejected = $false
try {
    Get-FearDgVoodooConfigIdentity -Path $rendererMax2xConfig -RendererQuality Native | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('DirectX.Resolution = unforced')) { throw }
    $rendererQualityMismatchRejected = $true
}
if (-not $rendererQualityMismatchRejected) {
    throw 'dgVoodoo config validation accepted Max2x bytes as the Native quality profile.'
}

$rtxBridgeConfigIdentity = Get-FearRtxRemixBridgeConfigIdentity -Path $rtxBridgeConfig
if ($rtxBridgeConfigIdentity.ForceWindowed -or
    $rtxBridgeConfigIdentity.Sha256 -cne $beforeHashes[$rtxBridgeConfig]) {
    throw 'Project-owned RTX Remix bridge troubleshooting profile is not exact or immutable.'
}
$rtxRuntimeConfigSeedIdentity = Get-FearRtxRemixRuntimeConfigSeedIdentity -Path $rtxRuntimeConfigSeed
if ($rtxRuntimeConfigSeedIdentity.GraphicsPreset -ne 4 -or
    $rtxRuntimeConfigSeedIdentity.GraphicsPresetName -cne 'Custom' -or
    $rtxRuntimeConfigSeedIdentity.IntegrateIndirectMode -ne 1 -or
    $rtxRuntimeConfigSeedIdentity.IndirectLightingBackend -cne 'ReSTIR GI (pinned Remix 1.5.2)' -or
    $rtxRuntimeConfigSeedIdentity.DlssFrameGenerationEnabled -ne $false -or
    $rtxRuntimeConfigSeedIdentity.Sha256 -cne $beforeHashes[$rtxRuntimeConfigSeed]) {
    throw 'Project-owned RTX Remix runtime compatibility seed is not the exact Custom + ReSTIR GI profile.'
}

$unsafeArchivePaths = @('../escape.dll', '..\escape.dll', 'C:/escape.dll', '/escape.dll', 'Retail/escape.dll', 'CON/file.dll', 'ambiguous./file.dll')
foreach ($unsafeArchivePath in $unsafeArchivePaths) {
    if (Test-FearRendererArchiveEntryPath -EntryName $unsafeArchivePath) {
        throw "Renderer archive path validator accepted an unsafe Windows/ZIP-slip path: $unsafeArchivePath"
    }
}
foreach ($safeArchivePath in @('d3d9.dll', '.trex/d3d9.dll', '.trex/usd/plugins/plugInfo.json')) {
    if (-not (Test-FearRendererArchiveEntryPath -EntryName $safeArchivePath)) {
        throw "Renderer archive path validator rejected a normal package path: $safeArchivePath"
    }
}

# A local retail-shaped fixture exercises package and stage mechanics only. The
# official Public Tools executable supplies the real 1.08/x86 identity; no game launches.
$fixtureRoot = Join-Path $RepositoryRoot "local-runtime\renderer-tool-fixture-retail-$runId"
New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
Copy-Item -LiteralPath $sdkRuntimeExecutable -Destination (Join-Path $fixtureRoot 'FEAR.exe') -Force
foreach ($fileName in @('EngineServer.dll', 'GameDatabase.dll', 'LTMemory.dll', 'SndDrv.dll', 'StringEditRuntime.dll')) {
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot $fileName), [byte[]](0x46, 0x45, 0x41, 0x52))
}
[IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'FEAR.Arch00'), [byte[]](0x46, 0x45, 0x41, 0x52))
[IO.File]::WriteAllLines((Join-Path $fixtureRoot 'Default.archcfg'), @('FEAR.Arch00'), [Text.ASCIIEncoding]::new())

$combinedStage = Join-Path $RepositoryRoot "local-runtime\renderer tool test combined $runId"
$nativeStage = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-native-$runId"
$changedRendererStage = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-changed-$runId"
$changedRendererConfigStage = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-changed-config-$runId"
$corruptRendererArchive = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-corrupt-dgvoodoo-$runId.zip"
$corruptRendererStage = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-corrupt-renderer-stage-$runId"
$corruptEnginePackageRoot = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-corrupt-engine-package-$runId"
$corruptEngineStage = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-corrupt-engine-stage-$runId"
$rtxStage = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-rtx-probe-$runId"
$legacyNativeStage = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-legacy-native-$runId"
$corruptRtxArchive = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-corrupt-rtx-$runId.zip"
$corruptRtxStage = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-corrupt-rtx-stage-$runId"
$invalidRtxRuntimeConfigSeed = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-invalid-rtx-runtime-$runId.conf"
$rtxUserConfigFixture = Join-Path $RepositoryRoot "local-runtime\renderer-tool-test-rtx-user-$runId.conf"
$localRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'local-runtime'))
$cleanupPaths = @(
    $combinedStage,
    $nativeStage,
    $changedRendererStage,
    $changedRendererConfigStage,
    $corruptRendererArchive,
    $corruptRendererStage,
    $corruptEnginePackageRoot,
    $corruptEngineStage,
    $rtxStage,
    $legacyNativeStage,
    $corruptRtxArchive,
    $corruptRtxStage,
    $invalidRtxRuntimeConfigSeed,
    $rtxUserConfigFixture,
    $fixtureRoot
)
[IO.File]::WriteAllText($invalidRtxRuntimeConfigSeed, 'rtx.integrateIndirectMode = 0', [Text.UTF8Encoding]::new($false))
$invalidRtxRuntimeConfigSeedRejected = $false
try {
    Get-FearRtxRemixRuntimeConfigSeedIdentity -Path $invalidRtxRuntimeConfigSeed | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains("'rtx.integrateIndirectMode = 1'")) { throw }
    $invalidRtxRuntimeConfigSeedRejected = $true
}
if (-not $invalidRtxRuntimeConfigSeedRejected) {
    throw 'RTX Remix runtime config seed validation accepted an unexpected mode.'
}
[IO.File]::WriteAllText(
    $invalidRtxRuntimeConfigSeed,
    "rtx.graphicsPreset = 5`r`nrtx.integrateIndirectMode = 1`r`nrtx.dlfg.enable = False`r`n",
    [Text.UTF8Encoding]::new($false))
$automaticGraphicsPresetSeedRejected = $false
try {
    Get-FearRtxRemixRuntimeConfigSeedIdentity -Path $invalidRtxRuntimeConfigSeed | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains("'rtx.graphicsPreset = 4'")) { throw }
    $automaticGraphicsPresetSeedRejected = $true
}
if (-not $automaticGraphicsPresetSeedRejected) {
    throw 'RTX Remix runtime config seed validation accepted the NRC-enabling Automatic graphics preset.'
}
[IO.File]::WriteAllText(
    $invalidRtxRuntimeConfigSeed,
    "rtx.graphicsPreset = 4`r`nrtx.integrateIndirectMode = 1`r`nrtx.dlfg.enable = True`r`n",
    [Text.UTF8Encoding]::new($false))
$invalidFrameGenerationSeedRejected = $false
try {
    Get-FearRtxRemixRuntimeConfigSeedIdentity -Path $invalidRtxRuntimeConfigSeed | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains("'rtx.dlfg.enable = False'")) { throw }
    $invalidFrameGenerationSeedRejected = $true
}
if (-not $invalidFrameGenerationSeedRejected) {
    throw 'RTX Remix runtime config seed validation accepted enabled DLSS Frame Generation.'
}
[IO.File]::WriteAllText(
    $invalidRtxRuntimeConfigSeed,
    "rtx.graphicsPreset = 4`r`nrtx.integrateIndirectMode = 1`r`nrtx.dlfg.enable = False`r`nrtx.enableRaytracing = True`r`n",
    [Text.UTF8Encoding]::new($false))
$safeEditedRuntimeConfig = Get-FearRtxRemixRuntimeConfigSafetyIdentity -Path $invalidRtxRuntimeConfigSeed
if (-not $safeEditedRuntimeConfig.SafeForFearMoreLaunch -or
    $safeEditedRuntimeConfig.ActiveSettingCount -ne 4) {
    throw 'Live RTX config safety validation rejected unrelated user/runtime settings around the required safe triple.'
}
[IO.File]::WriteAllText(
    $invalidRtxRuntimeConfigSeed,
    "rtx.graphicsPreset = 5`r`nrtx.integrateIndirectMode = 1`r`nrtx.dlfg.enable = False`r`nrtx.enableRaytracing = True`r`n",
    [Text.UTF8Encoding]::new($false))
$unsafeEditedRuntimeConfigRejected = $false
try {
    Get-FearRtxRemixRuntimeConfigSafetyIdentity -Path $invalidRtxRuntimeConfigSeed | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains("'rtx.graphicsPreset = 4'")) { throw }
    $unsafeEditedRuntimeConfigRejected = $true
}
if (-not $unsafeEditedRuntimeConfigRejected) {
    throw 'Live RTX config safety validation accepted an NRC-enabling edited graphics preset.'
}
[IO.File]::WriteAllText(
    $invalidRtxRuntimeConfigSeed,
    "rtx.graphicsPreset = 4`r`nrtx.integrateIndirectMode = 1`r`nrtx.dlfg.enable = False`r`n",
    [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText(
    $rtxUserConfigFixture,
    "rtx.graphicsPreset = 5`r`n",
    [Text.UTF8Encoding]::new($false))
$unsafeUserConfigRejected = $false
try {
    Get-FearRtxRemixRuntimeConfigSafetyIdentity `
        -Path $invalidRtxRuntimeConfigSeed `
        -UserConfigPath $rtxUserConfigFixture | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('higher-priority user.conf')) { throw }
    $unsafeUserConfigRejected = $true
}
if (-not $unsafeUserConfigRejected) {
    throw 'Live RTX config safety validation ignored an NRC-enabling user.conf override.'
}
[IO.File]::WriteAllText(
    $rtxUserConfigFixture,
    "rtx.graphicsPreset = 4`r`nrtx.dlfg.enable = False`r`nrtx.upscaler = 1`r`n",
    [Text.UTF8Encoding]::new($false))
$safeUserConfig = Get-FearRtxRemixRuntimeConfigSafetyIdentity `
    -Path $invalidRtxRuntimeConfigSeed `
    -UserConfigPath $rtxUserConfigFixture
if (-not $safeUserConfig.SafeForFearMoreLaunch -or
    -not $safeUserConfig.UserConfigPresent -or
    $safeUserConfig.GraphicsPresetSource -cne 'user.conf' -or
    $safeUserConfig.IntegrateIndirectModeSource -cne 'rtx.conf') {
    throw 'Live RTX config safety validation did not resolve the safe user.conf layer over the base runtime config.'
}

$combinedDefault = & $stageScript `
    -Lane Rebuilt `
    -Configuration $Configuration `
    -RepositoryRoot $RepositoryRoot `
    -RetailRoot $fixtureRoot `
    -BuildRoot $buildRoot `
    -StageRoot $combinedStage `
    -RendererMode DgVoodooD3D11 `
    -EnginePatchMode EngineOnlyEchoPatch
$combinedDefaultManifest = Get-Content -LiteralPath (Join-Path $combinedStage 'fearmore-stage.json') -Raw | ConvertFrom-Json
$combinedDefaultConfig = Get-Content -LiteralPath (Join-Path $combinedStage 'EchoPatch.ini') -Raw
$combinedDefaultRendererConfig = Get-Content -LiteralPath (Join-Path $combinedStage 'dgVoodoo.conf') -Raw
if ($combinedDefault.MaxFPS -ne 60.0 -or $combinedDefault.MaxFPSExplicit -or $combinedDefault.DynamicVsync -ne 1 -or
    $combinedDefaultManifest.MaxFPS -ne 60.0 -or $combinedDefaultManifest.MaxFPSExplicit -or $combinedDefaultManifest.DynamicVsync -ne 1 -or
    $combinedDefaultConfig -notmatch '(?m)^MaxFPS\s*=\s*60\.0\s*$' -or
    $combinedDefaultConfig -notmatch '(?m)^DynamicVsync\s*=\s*1\s*$') {
    throw 'Combined stage did not preserve the conservative 60 FPS / dynamic-VSync engine-patch default.'
}
if ($combinedDefault.RendererQuality -cne 'Native' -or $combinedDefaultManifest.RendererQuality -cne 'Native' -or
    $combinedDefault.RendererOutputAPI -cne 'd3d11_fl11_0' -or $combinedDefaultManifest.RendererOutputAPI -cne 'd3d11_fl11_0' -or
    $combinedDefault.RendererResolution -cne 'unforced' -or $combinedDefaultManifest.RendererResolution -cne 'unforced' -or
    $combinedDefault.RendererScalingMode -cne 'unspecified' -or $combinedDefaultManifest.RendererScalingMode -cne 'unspecified' -or
    $combinedDefault.RendererResampling -cne 'lanczos-3' -or $combinedDefaultManifest.RendererResampling -cne 'lanczos-3' -or
    $combinedDefault.RendererFiltering -cne 'appdriven' -or $combinedDefaultManifest.RendererFiltering -cne 'appdriven' -or
    $combinedDefault.RendererAntialiasing -cne 'appdriven' -or $combinedDefaultManifest.RendererAntialiasing -cne 'appdriven' -or
    $combinedDefault.RendererVRAM -ne 256 -or $combinedDefaultManifest.RendererVRAM -ne 256 -or
    $combinedDefault.RendererFPSLimit -ne 0 -or $combinedDefaultManifest.RendererFPSLimit -ne 0 -or
    $combinedDefault.RendererForceVerticalSync -ne $false -or $combinedDefaultManifest.RendererForceVerticalSync -ne $false -or
    $combinedDefault.RendererConfigSha256 -cne $nativeRendererConfigIdentity.Sha256 -or
    $combinedDefaultRendererConfig -notmatch '(?m)^Resolution\s*=\s*unforced\s*$') {
    throw 'Omitted renderer quality no longer stages and reports the exact Native dgVoodoo profile.'
}

$combinedMax2x = & $stageScript `
    -Lane Rebuilt `
    -Configuration $Configuration `
    -RepositoryRoot $RepositoryRoot `
    -RetailRoot $fixtureRoot `
    -BuildRoot $buildRoot `
    -StageRoot $combinedStage `
    -RendererMode DgVoodooD3D11 `
    -RendererQuality Max2x `
    -EnginePatchMode EngineOnlyEchoPatch
$combinedMax2xManifest = Get-Content -LiteralPath (Join-Path $combinedStage 'fearmore-stage.json') -Raw | ConvertFrom-Json
$combinedMax2xRendererConfig = Get-Content -LiteralPath (Join-Path $combinedStage 'dgVoodoo.conf') -Raw
if ($combinedMax2x.RendererQuality -cne 'Max2x' -or $combinedMax2xManifest.RendererQuality -cne 'Max2x' -or
    $combinedMax2x.RendererResolution -cne 'max_2x' -or $combinedMax2xManifest.RendererResolution -cne 'max_2x' -or
    $combinedMax2x.RendererScalingMode -cne 'unspecified' -or $combinedMax2xManifest.RendererScalingMode -cne 'unspecified' -or
    $combinedMax2x.RendererResampling -cne 'lanczos-3' -or $combinedMax2xManifest.RendererResampling -cne 'lanczos-3' -or
    $combinedMax2x.RendererFiltering -cne 'appdriven' -or $combinedMax2xManifest.RendererFiltering -cne 'appdriven' -or
    $combinedMax2x.RendererAntialiasing -cne 'appdriven' -or $combinedMax2xManifest.RendererAntialiasing -cne 'appdriven' -or
    $combinedMax2x.RendererVRAM -ne 256 -or $combinedMax2xManifest.RendererVRAM -ne 256 -or
    $combinedMax2x.RendererFPSLimit -ne 0 -or $combinedMax2xManifest.RendererFPSLimit -ne 0 -or
    $combinedMax2x.RendererForceVerticalSync -ne $false -or $combinedMax2xManifest.RendererForceVerticalSync -ne $false -or
    $combinedMax2x.RendererConfigSha256 -cne $max2xRendererConfigIdentity.Sha256 -or
    $combinedMax2x.RendererProxySha256 -cne $combinedDefault.RendererProxySha256 -or
    $combinedMax2xRendererConfig -notmatch '(?m)^Resolution\s*=\s*max_2x\s*$') {
    throw 'Opt-in Max2x did not safely refresh and report only the owned dgVoodoo quality profile.'
}

$combined = & $stageScript `
    -Lane Rebuilt `
    -Configuration $Configuration `
    -RepositoryRoot $RepositoryRoot `
    -RetailRoot $fixtureRoot `
    -BuildRoot $buildRoot `
    -StageRoot $combinedStage `
    -RendererMode DgVoodooD3D11 `
    -EnginePatchMode EngineOnlyEchoPatch `
    -MaxFPS 120
$combinedManifest = Get-Content -LiteralPath (Join-Path $combinedStage 'fearmore-stage.json') -Raw | ConvertFrom-Json
if ($combinedManifest.SchemaVersion -ne 9 -or
    $combined.RendererMode -ne 'DgVoodooD3D11' -or $combinedManifest.RendererMode -ne 'DgVoodooD3D11' -or
    $combined.RendererPackageVersion -ne '2.87.3' -or
    $combined.RendererPackageSha256 -ne '6FB954BED55BF70E948C5045A663A9DF31EA206FAF105E327BAFE46C318F867F' -or
    $combined.RendererProxySha256 -ne 'C13E3C0969D2C70A1A63CF96B83C7CD3BC47F925F28EC92C07D5B72D6DF4C240' -or
    $combined.RendererOutputAPI -ne 'd3d11_fl11_0' -or
    $combined.RendererQuality -cne 'Native' -or $combinedManifest.RendererQuality -cne 'Native' -or
    $combined.RendererResolution -cne 'unforced' -or $combinedManifest.RendererResolution -cne 'unforced' -or
    $combined.RendererScalingMode -cne 'unspecified' -or $combined.RendererResampling -cne 'lanczos-3' -or
    $combined.RendererFiltering -cne 'appdriven' -or
    $combined.RendererAntialiasing -cne 'appdriven' -or $combined.RendererVRAM -ne 256 -or
    $combined.RendererFPSLimit -ne 0 -or $combined.RendererForceVerticalSync -ne $false -or
    $combined.RendererConfigSha256 -cne $nativeRendererConfigIdentity.Sha256 -or
    $combined.EnginePatchMode -ne 'EngineOnlyEchoPatch' -or $combinedManifest.EnginePatchMode -ne 'EngineOnlyEchoPatch' -or
    $combined.EnginePatchManifestSha256 -ne '1E17062A5C7D8F1C04478F56E54A3C55EAFEF849026E99DA57F8579EF9B1642E' -or
    $combined.EnginePatchProxySha256 -ne '04A3C95ABFE669D98F647245450863BA7D7E189CE2FE236DE92CB4ACC110FE95' -or
    $combined.MaxFPS -ne 120.0 -or -not $combined.MaxFPSExplicit -or $combined.DynamicVsync -ne 0 -or
    $combinedManifest.MaxFPS -ne 120.0 -or -not $combinedManifest.MaxFPSExplicit -or $combinedManifest.DynamicVsync -ne 0 -or
    -not $combined.LaunchPermitted) {
    throw 'Combined stage result/manifest did not preserve its pinned renderer, engine patch, and explicit cap identity.'
}
foreach ($ownedFile in @(
    [pscustomobject]@{ Name = 'd3d9.dll'; Hash = $combinedManifest.RendererProxySha256 },
    [pscustomobject]@{ Name = 'dgVoodoo.conf'; Hash = $combinedManifest.RendererConfigSha256 },
    [pscustomobject]@{ Name = 'dinput8.dll'; Hash = $combinedManifest.EnginePatchProxySha256 },
    [pscustomobject]@{ Name = 'EchoPatch.ini'; Hash = $combinedManifest.EnginePatchConfigSha256 }
)) {
    $path = Join-Path $combinedStage $ownedFile.Name
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $ownedFile.Hash) {
        throw "Combined stage manifest does not own the exact $($ownedFile.Name) payload."
    }
}
foreach ($proxyPath in @($combined.RendererProxy, $combined.EnginePatchProxy)) {
    if (-not (Test-FearX86Pe32Identity -Identity (Get-FearPeRuntimeIdentity -Path $proxyPath))) {
        throw "Combined stage proxy is not x86 PE32: $proxyPath"
    }
}
$explicitConfig = Get-Content -LiteralPath $combined.EnginePatchConfig -Raw
if ($explicitConfig -notmatch '(?m)^MaxFPS\s*=\s*120\.0\s*$' -or
    $explicitConfig -notmatch '(?m)^DynamicVsync\s*=\s*0\s*$' -or
    $explicitConfig -notmatch '(?m)^PatchGameModules\s*=\s*0\s*$' -or
    $explicitConfig -notmatch '(?m)^HighFPSFixes\s*=\s*0\s*$') {
    throw 'Explicit cap did not disable dynamic VSync while preserving the no-module-hooks boundary.'
}

$defaultRootValidation = & $stageScript `
    -Lane Rebuilt `
    -Configuration $Configuration `
    -RepositoryRoot $RepositoryRoot `
    -RetailRoot $fixtureRoot `
    -BuildRoot $buildRoot `
    -RendererMode DgVoodooD3D11 `
    -EnginePatchMode EngineOnlyEchoPatch `
    -ValidateOnly
$expectedDefaultRoot = Join-Path $RepositoryRoot "local-runtime\fearmore-rebuilt-$($Configuration.ToLowerInvariant())-dgvoodoo-d3d11-engine-only-echopatch"
if ($defaultRootValidation.StageRoot -ne [IO.Path]::GetFullPath($expectedDefaultRoot) -or -not $defaultRootValidation.ValidationOnly) {
    throw 'Nondefault combination does not receive its own deterministic default stage root.'
}
$max2xDefaultRootValidation = & $stageScript `
    -Lane Rebuilt `
    -Configuration $Configuration `
    -RepositoryRoot $RepositoryRoot `
    -RetailRoot $fixtureRoot `
    -BuildRoot $buildRoot `
    -RendererMode DgVoodooD3D11 `
    -RendererQuality Max2x `
    -EnginePatchMode EngineOnlyEchoPatch `
    -ValidateOnly
$expectedMax2xDefaultRoot = Join-Path $RepositoryRoot "local-runtime\fearmore-rebuilt-$($Configuration.ToLowerInvariant())-dgvoodoo-d3d11-max2x-engine-only-echopatch"
if ($max2xDefaultRootValidation.StageRoot -ne [IO.Path]::GetFullPath($expectedMax2xDefaultRoot) -or
    -not $max2xDefaultRootValidation.ValidationOnly -or
    $max2xDefaultRootValidation.RendererQuality -cne 'Max2x' -or
    $max2xDefaultRootValidation.RendererResolution -cne 'max_2x' -or
    $max2xDefaultRootValidation.RendererScalingMode -cne 'unspecified' -or
    $max2xDefaultRootValidation.RendererResampling -cne 'lanczos-3' -or
    $max2xDefaultRootValidation.RendererFiltering -cne 'appdriven' -or
    $max2xDefaultRootValidation.RendererAntialiasing -cne 'appdriven' -or
    $max2xDefaultRootValidation.RendererVRAM -ne 256 -or
    $max2xDefaultRootValidation.RendererFPSLimit -ne 0 -or
    $max2xDefaultRootValidation.RendererForceVerticalSync -ne $false) {
    throw 'Max2x ValidateOnly planning did not report its deterministic stage root and exact renderer semantics.'
}

$modeMismatchBefore = Get-DirectorySnapshot -Root $combinedStage
$modeMismatchRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $combinedStage | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains("belongs to renderer mode 'DgVoodooD3D11'")) { throw }
    $modeMismatchRejected = $true
}
if (-not $modeMismatchRejected -or (Get-DirectorySnapshot -Root $combinedStage) -ne $modeMismatchBefore) {
    throw 'Renderer-mode ownership mismatch did not fail before mutating the combined stage.'
}

$rtx = & $stageScript @rtxDiagnosticParameters `
    -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
    -StageRoot $rtxStage -RendererMode RtxRemixProbe
$rtxManifestPath = Join-Path $rtxStage 'fearmore-stage.json'
$rtxManifest = Get-Content -LiteralPath $rtxManifestPath -Raw | ConvertFrom-Json
$rtxEchoPatchConfigIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
    -Path (Join-Path $rtxStage 'EchoPatch.ini') `
    -ExpectedMaxFPS 60.0 `
    -ExpectedDynamicVsync 1 `
    -ExpectedCameraDiagnostics 0 `
    -ExpectedRemixCameraDiagnostics 1 `
    -ExpectedForceWindowed 1 `
    -ExpectedFixWindowStyle 1
if ($rtxManifest.SchemaVersion -ne 9 -or
    $rtx.RendererMode -ne 'RtxRemixProbe' -or $rtxManifest.RendererMode -ne 'RtxRemixProbe' -or
    $rtx.RendererPackageVersion -ne '1.5.2' -or $rtx.RendererPackageSize -ne 231778218 -or
    $rtx.RendererPackageSha256 -ne 'CC424BE4DD1A0C6FD922BC6A7F8E5F6582BAEA7043A38AFA6686D8B6FAABAD01' -or
    $rtx.RendererProxySha256 -ne 'A9D0846720E90D36D19AFB67E76A4D894EB349ECF13B847DE0CEDA4861669965' -or
    $rtx.RendererConfig -cne (Join-Path $rtxStage '.trex\bridge.conf') -or
    $rtx.RendererConfigSha256 -cne $rtxBridgeConfigIdentity.Sha256 -or
    $rtxManifest.RendererConfigFile -cne '.trex\bridge.conf' -or
    $rtxManifest.RendererConfigSha256 -cne $rtxBridgeConfigIdentity.Sha256 -or
    $rtx.RendererRuntimeConfigSeedSource -cne $rtxRuntimeConfigSeedIdentity.Path -or
    $rtx.RendererRuntimeConfigSeedSha256 -cne $rtxRuntimeConfigSeedIdentity.Sha256 -or
    $rtx.RendererRuntimeConfigSeedPolicy -cne 'NewStageOnly' -or
    -not $rtx.RendererRuntimeConfigSeedApplied -or
    $rtx.RendererRuntimeConfigSeedBackend -cne 'ReSTIR GI (pinned Remix 1.5.2)' -or
    $rtx.RendererRuntimeConfigSeedDlssFrameGenerationEnabled -ne $false -or
    $rtxManifest.RendererRuntimeConfigSeedSource -cne $rtxRuntimeConfigSeedIdentity.Path -or
    $rtxManifest.RendererRuntimeConfigSeedSha256 -cne $rtxRuntimeConfigSeedIdentity.Sha256 -or
    $rtxManifest.RendererRuntimeConfigSeedPolicy -cne 'NewStageOnly' -or
    -not $rtxManifest.RendererRuntimeConfigSeedApplied -or
    $rtxManifest.RendererRuntimeConfigSeedBackend -cne 'ReSTIR GI (pinned Remix 1.5.2)' -or
    $rtxManifest.RendererRuntimeConfigSeedDlssFrameGenerationEnabled -ne $false -or
    $rtx.PSObject.Properties['RendererIndirectLightingBackend'] -or
    $rtxManifest.PSObject.Properties['RendererIndirectLightingBackend'] -or
    $rtx.RendererOutputAPI -or
    $rtx.RendererPackageFileCount -ne 165 -or @($rtx.RendererOwnedFiles).Count -ne 165 -or
    -not $rtx.RendererExperimental -or $rtx.RendererCompatibilityStatus -ne 'UnverifiedProbe' -or
    $rtx.EnginePatchMode -ne 'RemixDiagnosticEchoPatch' -or
    $rtxManifest.EnginePatchMode -ne 'RemixDiagnosticEchoPatch' -or
    $rtx.EnginePatchManifestSha256 -ne '59E5F1D4808C18FC390A0D50E0BB12FBD697EA989E7FAAC82682988F8BEBD849' -or
    $rtx.EnginePatchProxySha256 -ne '19FF5BC718C25AB07AF590D2131C8E876D7BC1891F9193CFEBBCAED4F63B57B5' -or
    $rtx.EnginePatchConfigSha256 -cne $rtxEchoPatchConfigIdentity.Sha256 -or
    $rtxManifest.EnginePatchConfigSha256 -cne $rtxEchoPatchConfigIdentity.Sha256 -or
    -not $rtx.EnginePatchForceWindowed -or -not $rtx.EnginePatchFixWindowStyle -or
    -not $rtxManifest.EnginePatchForceWindowed -or -not $rtxManifest.EnginePatchFixWindowStyle -or
    -not $rtx.LaunchPermitted -or $rtx.AcceptanceTested) {
    throw 'RTX Remix probe stage/result did not preserve its pinned experimental and unverified identity.'
}
$stagedRtxBridgeConfig = Join-Path $rtxStage '.trex\bridge.conf'
if ((Get-FearRtxRemixBridgeConfigIdentity -Path $stagedRtxBridgeConfig).Sha256 -cne $rtxBridgeConfigIdentity.Sha256) {
    throw 'RTX Remix stage does not contain the exact project-owned bridge troubleshooting profile.'
}
if ((@($rtx.RendererRuntimeWritableDirectories) -join ',') -cne 'rtx-remix' -or
    (@($rtx.RendererRuntimeMutableFiles) -join ',') -cne 'rtx.conf' -or
    (@($rtxManifest.RendererRuntimeWritableDirectories) -join ',') -cne 'rtx-remix' -or
    (@($rtxManifest.RendererRuntimeMutableFiles) -join ',') -cne 'rtx.conf') {
    throw 'RTX Remix probe did not declare the exact runtime-writable data/config paths.'
}
$ownedRtxPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($ownedFile in @($rtxManifest.RendererOwnedFiles)) {
    if (-not $ownedRtxPaths.Add([string]$ownedFile.RelativePath)) {
        throw "RTX Remix manifest contains a duplicate package-owned path: $($ownedFile.RelativePath)"
    }
    $ownedPath = Join-Path $rtxStage ([string]$ownedFile.RelativePath)
    if (-not (Test-Path -LiteralPath $ownedPath -PathType Leaf) -or
        (Get-Item -LiteralPath $ownedPath).Length -ne [long]$ownedFile.Size -or
        (Get-FileHash -LiteralPath $ownedPath -Algorithm SHA256).Hash -ne [string]$ownedFile.Sha256) {
        throw "RTX Remix manifest does not exactly own its staged package file: $($ownedFile.RelativePath)"
    }
}
if (-not (Test-FearX86Pe32Identity -Identity (Get-FearPeRuntimeIdentity -Path $rtx.RendererProxy))) {
    throw 'RTX Remix root bridge interposer is not x86 PE32.'
}
foreach ($diagnosticFile in @(
    [pscustomobject]@{ Path = $rtx.EnginePatchProxy; Hash = $rtxManifest.EnginePatchProxySha256 },
    [pscustomobject]@{ Path = $rtx.EnginePatchConfig; Hash = $rtxManifest.EnginePatchConfigSha256 }
)) {
    if (-not (Test-Path -LiteralPath $diagnosticFile.Path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $diagnosticFile.Path -Algorithm SHA256).Hash -cne $diagnosticFile.Hash) {
        throw "RTX Remix diagnostic companion is missing or changed: $($diagnosticFile.Path)"
    }
}
$rtxDataDirectory = Join-Path $rtxStage 'rtx-remix'
$rtxDataDirectoryItem = Get-Item -LiteralPath $rtxDataDirectory -Force
if (-not $rtxDataDirectoryItem.PSIsContainer -or
    ($rtxDataDirectoryItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw 'RTX Remix runtime-writable directory must be an ordinary stage-local directory.'
}

$rtxConfigPath = Join-Path $rtxStage 'rtx.conf'
$stagedRtxRuntimeConfigSeedIdentity = Get-FearRtxRemixRuntimeConfigSeedIdentity -Path $rtxConfigPath
if ($stagedRtxRuntimeConfigSeedIdentity.Sha256 -cne $rtxRuntimeConfigSeedIdentity.Sha256 -or
    $stagedRtxRuntimeConfigSeedIdentity.GraphicsPreset -ne 4 -or
    $stagedRtxRuntimeConfigSeedIdentity.IntegrateIndirectMode -ne 1 -or
    $stagedRtxRuntimeConfigSeedIdentity.DlssFrameGenerationEnabled -ne $false) {
    throw 'A new RTX Remix stage did not receive the exact source-owned Custom + ReSTIR GI runtime config seed.'
}
$rtxRuntimeSentinel = Join-Path $rtxDataDirectory 'probe-sentinel.txt'
[IO.File]::WriteAllText($rtxConfigPath, 'rtx.testSetting = true', [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($rtxRuntimeSentinel, 'runtime-owned', [Text.UTF8Encoding]::new($false))
$rtxConfigHash = (Get-FileHash -LiteralPath $rtxConfigPath -Algorithm SHA256).Hash
$rtxSentinelHash = (Get-FileHash -LiteralPath $rtxRuntimeSentinel -Algorithm SHA256).Hash
$rtxRerun = & $stageScript @rtxDiagnosticParameters `
    -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
    -StageRoot $rtxStage -RendererMode RtxRemixProbe
if ((Get-FileHash -LiteralPath $rtxConfigPath -Algorithm SHA256).Hash -ne $rtxConfigHash -or
    (Get-FileHash -LiteralPath $rtxRuntimeSentinel -Algorithm SHA256).Hash -ne $rtxSentinelHash -or
    @($rtxRerun.RendererOwnedFiles).Count -ne 165 -or
    $rtxRerun.RendererRuntimeConfigSeedApplied) {
    throw 'RTX Remix restaging changed runtime-owned config/data or lost exact package ownership.'
}

Remove-Item -LiteralPath $rtxConfigPath -Force
$rtxMissingRuntimeConfigRerun = & $stageScript @rtxDiagnosticParameters `
    -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
    -StageRoot $rtxStage -RendererMode RtxRemixProbe
if ((Test-Path -LiteralPath $rtxConfigPath) -or $rtxMissingRuntimeConfigRerun.RendererRuntimeConfigSeedApplied) {
    throw 'An existing RTX Remix stage had its deliberately absent runtime-owned rtx.conf recreated during restaging.'
}

$rtxDefaultValidation = & $stageScript @rtxDiagnosticParameters `
    -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
    -RendererMode RtxRemixProbe -ValidateOnly
$expectedRtxDefaultRoot = Join-Path $RepositoryRoot "local-runtime\fearmore-rebuilt-$($Configuration.ToLowerInvariant())-rtx-remix-probe-1-5-2-remix-camera-diagnostics"
if ($rtxDefaultValidation.StageRoot -ne [IO.Path]::GetFullPath($expectedRtxDefaultRoot) -or
    -not $rtxDefaultValidation.ValidationOnly -or -not $rtxDefaultValidation.RendererExperimental) {
    throw 'RTX Remix probe does not receive its own deterministic validation/stage identity.'
}

$validRtxManifestJson = Get-Content -LiteralPath $rtxManifestPath -Raw
$missingConfigRtxManifest = $validRtxManifestJson | ConvertFrom-Json
$missingConfigRtxManifest.PSObject.Properties.Remove('RendererConfigFile')
$missingConfigRtxManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rtxManifestPath -Encoding UTF8
$missingConfigRtxBefore = Get-DirectorySnapshot -Root $rtxStage
$missingConfigRtxRejected = $false
try {
    & $stageScript @rtxDiagnosticParameters `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $rtxStage -RendererMode RtxRemixProbe | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('does not own the expected RTX Remix bridge config')) { throw }
    $missingConfigRtxRejected = $true
}
if (-not $missingConfigRtxRejected -or (Get-DirectorySnapshot -Root $rtxStage) -ne $missingConfigRtxBefore) {
    throw 'An RTX manifest without bridge-config ownership was accepted or mutated before rejection.'
}
[IO.File]::WriteAllText($rtxManifestPath, $validRtxManifestJson, [Text.UTF8Encoding]::new($false))

$legacyRtxManifest = $validRtxManifestJson | ConvertFrom-Json
$legacyRtxManifest.SchemaVersion = 6
$legacyRtxManifest.PSObject.Properties.Remove('RendererOwnedFiles')
$legacyRtxManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rtxManifestPath -Encoding UTF8
$legacyRtxBefore = Get-DirectorySnapshot -Root $rtxStage
$legacyRtxRejected = $false
try {
    & $stageScript @rtxDiagnosticParameters `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $rtxStage -RendererMode RtxRemixProbe | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('does not declare RendererOwnedFiles')) { throw }
    $legacyRtxRejected = $true
}
if (-not $legacyRtxRejected -or (Get-DirectorySnapshot -Root $rtxStage) -ne $legacyRtxBefore) {
    throw 'A legacy RTX manifest without exact package ownership was accepted or mutated before rejection.'
}
[IO.File]::WriteAllText($rtxManifestPath, $validRtxManifestJson, [Text.UTF8Encoding]::new($false))

$wrongPackageRtxManifest = $validRtxManifestJson | ConvertFrom-Json
$wrongPackageRtxManifest.RendererPackageSha256 = '0' * 64
$wrongPackageRtxManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rtxManifestPath -Encoding UTF8
$wrongPackageRtxBefore = Get-DirectorySnapshot -Root $rtxStage
$wrongPackageRtxRejected = $false
try {
    & $stageScript @rtxDiagnosticParameters `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $rtxStage -RendererMode RtxRemixProbe | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('renderer package identity does not match the currently validated package')) { throw }
    $wrongPackageRtxRejected = $true
}
if (-not $wrongPackageRtxRejected -or (Get-DirectorySnapshot -Root $rtxStage) -ne $wrongPackageRtxBefore) {
    throw 'An RTX manifest for a different package identity was accepted or mutated before rejection.'
}
[IO.File]::WriteAllText($rtxManifestPath, $validRtxManifestJson, [Text.UTF8Encoding]::new($false))

$changedPathSetRtxManifest = $validRtxManifestJson | ConvertFrom-Json
$changedPathSetRtxManifest.RendererOwnedFiles[0].RelativePath = 'stale-owned-placeholder.bin'
$changedPathSetRtxManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $rtxManifestPath -Encoding UTF8
$changedPathSetRtxBefore = Get-DirectorySnapshot -Root $rtxStage
$changedPathSetRtxRejected = $false
try {
    & $stageScript @rtxDiagnosticParameters `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $rtxStage -RendererMode RtxRemixProbe | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('does not match the currently validated package file set')) { throw }
    $changedPathSetRtxRejected = $true
}
if (-not $changedPathSetRtxRejected -or (Get-DirectorySnapshot -Root $rtxStage) -ne $changedPathSetRtxBefore) {
    throw 'An RTX manifest with the correct count but a changed owned-path set was accepted or mutated before rejection.'
}
[IO.File]::WriteAllText($rtxManifestPath, $validRtxManifestJson, [Text.UTF8Encoding]::new($false))

$unexpectedTrexFile = Join-Path $rtxStage '.trex\unowned-probe-file.bin'
[IO.File]::WriteAllBytes($unexpectedTrexFile, [byte[]](0x52, 0x54, 0x58))
$unexpectedTrexBefore = Get-DirectorySnapshot -Root $rtxStage
$unexpectedTrexRejected = $false
try {
    & $stageScript @rtxDiagnosticParameters `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $rtxStage -RendererMode RtxRemixProbe | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('immutable package tree contains an unowned file')) { throw }
    $unexpectedTrexRejected = $true
}
if (-not $unexpectedTrexRejected -or (Get-DirectorySnapshot -Root $rtxStage) -ne $unexpectedTrexBefore) {
    throw 'An unowned file in the immutable RTX package tree was accepted or mutated before rejection.'
}
Remove-Item -LiteralPath $unexpectedTrexFile -Force

$validRtxBridgeConfigBytes = [IO.File]::ReadAllBytes($stagedRtxBridgeConfig)
[IO.File]::WriteAllText($stagedRtxBridgeConfig, 'client.forceWindowed = True', [Text.UTF8Encoding]::new($false))
$changedRtxBridgeConfigBefore = Get-DirectorySnapshot -Root $rtxStage
$changedRtxBridgeConfigRejected = $false
try {
    & $stageScript @rtxDiagnosticParameters `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $rtxStage -RendererMode RtxRemixProbe | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('Existing tool-owned RTX Remix bridge config was changed')) { throw }
    $changedRtxBridgeConfigRejected = $true
}
if (-not $changedRtxBridgeConfigRejected -or (Get-DirectorySnapshot -Root $rtxStage) -ne $changedRtxBridgeConfigBefore) {
    throw 'A changed RTX bridge config was overwritten or another stage file mutated before rejection.'
}
[IO.File]::WriteAllBytes($stagedRtxBridgeConfig, $validRtxBridgeConfigBytes)

$changedRtxOwnedPath = Join-Path $rtxStage '.trex\ar.dll'
$changedRtxBytes = [IO.File]::ReadAllBytes($changedRtxOwnedPath)
$changedRtxBytes[100] = $changedRtxBytes[100] -bxor 0x01
[IO.File]::WriteAllBytes($changedRtxOwnedPath, $changedRtxBytes)
$changedRtxBefore = Get-DirectorySnapshot -Root $rtxStage
$changedRtxRejected = $false
try {
    & $stageScript @rtxDiagnosticParameters `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $rtxStage -RendererMode RtxRemixProbe | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('Existing tool-owned RTX Remix payload was changed')) { throw }
    $changedRtxRejected = $true
}
if (-not $changedRtxRejected -or (Get-DirectorySnapshot -Root $rtxStage) -ne $changedRtxBefore) {
    throw 'A changed RTX-owned file was overwritten or another stage file mutated before rejection.'
}

$native = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $nativeStage
$nativeManifest = Get-Content -LiteralPath (Join-Path $nativeStage 'fearmore-stage.json') -Raw | ConvertFrom-Json
if ($native.RendererMode -ne 'NativeD3D9' -or $native.EnginePatchMode -ne 'None' -or
    $nativeManifest.RendererMode -ne 'NativeD3D9' -or $nativeManifest.EnginePatchMode -ne 'None') {
    throw 'Default Rebuilt stage no longer preserves native D3D9/no-patch behavior.'
}
$legacyNative = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $legacyNativeStage
$legacyNativeManifestPath = Join-Path $legacyNativeStage 'fearmore-stage.json'
$legacyNativeManifest = Get-Content -LiteralPath $legacyNativeManifestPath -Raw | ConvertFrom-Json
$legacyNativeManifest.SchemaVersion = 6
$legacyNativeManifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $legacyNativeManifestPath -Encoding UTF8
$migratedNative = & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $legacyNativeStage
$migratedNativeManifest = Get-Content -LiteralPath $legacyNativeManifestPath -Raw | ConvertFrom-Json
if ($migratedNativeManifest.SchemaVersion -ne 9 -or $migratedNative.RendererMode -ne 'NativeD3D9' -or
    @($migratedNative.RendererOwnedFiles).Count -ne 0) {
    throw 'Schema-6 native/no-patch stage did not migrate to schema 9 without acquiring a renderer payload.'
}
[IO.File]::WriteAllBytes((Join-Path $nativeStage 'd3d9.dll'), [byte[]](0x44, 0x33, 0x44, 0x39))
$nativeBefore = Get-DirectorySnapshot -Root $nativeStage
$nativeProxyRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $nativeStage | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('NativeD3D9 stage contains an unowned renderer proxy/config')) { throw }
    $nativeProxyRejected = $true
}
if (-not $nativeProxyRejected -or (Get-DirectorySnapshot -Root $nativeStage) -ne $nativeBefore) {
    throw 'Native staging overwrote or mutated an unowned d3d9.dll before failing.'
}
Remove-Item -LiteralPath (Join-Path $nativeStage 'd3d9.dll') -Force

$nativeRtxDirectory = Join-Path $nativeStage 'rtx-remix'
[void][IO.Directory]::CreateDirectory($nativeRtxDirectory)
[IO.File]::WriteAllBytes((Join-Path $nativeRtxDirectory 'sentinel.bin'), [byte[]](0x52, 0x54, 0x58))
$nativeRtxDirectoryBefore = Get-DirectorySnapshot -Root $nativeStage
$nativeRtxDirectoryRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $nativeStage | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('NativeD3D9 stage contains an unowned renderer proxy/config')) { throw }
    $nativeRtxDirectoryRejected = $true
}
if (-not $nativeRtxDirectoryRejected -or (Get-DirectorySnapshot -Root $nativeStage) -ne $nativeRtxDirectoryBefore) {
    throw 'Native staging accepted or mutated an unowned rtx-remix directory before failing.'
}
Remove-Item -LiteralPath $nativeRtxDirectory -Recurse -Force

$nativeRtxConfig = Join-Path $nativeStage 'rtx.conf'
[IO.File]::WriteAllBytes($nativeRtxConfig, [byte[]](0x52, 0x54, 0x58))
$nativeRtxConfigBefore = Get-DirectorySnapshot -Root $nativeStage
$nativeRtxConfigRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -StageRoot $nativeStage | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('NativeD3D9 stage contains an unowned renderer proxy/config')) { throw }
    $nativeRtxConfigRejected = $true
}
if (-not $nativeRtxConfigRejected -or (Get-DirectorySnapshot -Root $nativeStage) -ne $nativeRtxConfigBefore) {
    throw 'Native staging accepted or mutated an unowned rtx.conf before failing.'
}

$changedRenderer = & $stageScript `
    -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
    -StageRoot $changedRendererStage -RendererMode DgVoodooD3D11
$changedBytes = [IO.File]::ReadAllBytes($changedRenderer.RendererProxy)
$changedBytes[100] = $changedBytes[100] -bxor 0x01
[IO.File]::WriteAllBytes($changedRenderer.RendererProxy, $changedBytes)
$changedBefore = Get-DirectorySnapshot -Root $changedRendererStage
$changedRendererRejected = $false
try {
    & $stageScript `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $changedRendererStage -RendererMode DgVoodooD3D11 | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('Existing tool-owned renderer proxy was changed')) { throw }
    $changedRendererRejected = $true
}
if (-not $changedRendererRejected -or (Get-DirectorySnapshot -Root $changedRendererStage) -ne $changedBefore) {
    throw 'Changed tool-owned renderer proxy was overwritten or mutated before staging failed.'
}

$changedRendererConfig = & $stageScript `
    -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
    -StageRoot $changedRendererConfigStage -RendererMode DgVoodooD3D11
[IO.File]::AppendAllText($changedRendererConfig.RendererConfig, "`r`n; local tamper`r`n", [Text.ASCIIEncoding]::new())
$changedRendererConfigBefore = Get-DirectorySnapshot -Root $changedRendererConfigStage
$changedRendererConfigRejected = $false
try {
    & $stageScript `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $changedRendererConfigStage -RendererMode DgVoodooD3D11 -RendererQuality Max2x | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('Existing tool-owned renderer config was changed')) { throw }
    $changedRendererConfigRejected = $true
}
if (-not $changedRendererConfigRejected -or
    (Get-DirectorySnapshot -Root $changedRendererConfigStage) -ne $changedRendererConfigBefore) {
    throw 'Changed tool-owned renderer config was overwritten or mutated before quality-profile staging failed.'
}

Copy-Item -LiteralPath $dgVoodooArchive -Destination $corruptRendererArchive
$corruptBytes = [IO.File]::ReadAllBytes($corruptRendererArchive)
$corruptBytes[$corruptBytes.Length - 1] = $corruptBytes[$corruptBytes.Length - 1] -bxor 0x01
[IO.File]::WriteAllBytes($corruptRendererArchive, $corruptBytes)
$corruptRendererRejected = $false
try {
    & $stageScript `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $corruptRendererStage -RendererMode DgVoodooD3D11 -DgVoodooArchive $corruptRendererArchive -ValidateOnly | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('dgVoodoo2 archive hash mismatch')) { throw }
    $corruptRendererRejected = $true
}
if (-not $corruptRendererRejected -or (Test-Path -LiteralPath $corruptRendererStage)) {
    throw 'Corrupt dgVoodoo2 package was accepted or its ValidateOnly failure created a stage.'
}

[IO.File]::WriteAllBytes($corruptRtxArchive, [byte[]](0x50, 0x4B, 0x03, 0x04))
$corruptRtxRejected = $false
try {
    & $stageScript @rtxDiagnosticParameters `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $corruptRtxStage -RendererMode RtxRemixProbe -RtxRemixArchive $corruptRtxArchive -ValidateOnly | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('RTX Remix archive size mismatch')) { throw }
    $corruptRtxRejected = $true
}
if (-not $corruptRtxRejected -or (Test-Path -LiteralPath $corruptRtxStage)) {
    throw 'Corrupt RTX Remix package was accepted or its ValidateOnly failure created a stage.'
}

New-Item -ItemType Directory -Path $corruptEnginePackageRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $enginePatchPackageRoot 'dinput8.dll') -Destination (Join-Path $corruptEnginePackageRoot 'dinput8.dll')
Copy-Item -LiteralPath (Join-Path $enginePatchPackageRoot 'EchoPatch.ini') -Destination (Join-Path $corruptEnginePackageRoot 'EchoPatch.ini')
Add-Content -LiteralPath (Join-Path $corruptEnginePackageRoot 'EchoPatch.ini') -Value '; synthetic rejection change'
$corruptEngineRejected = $false
try {
    & $stageScript `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -StageRoot $corruptEngineStage -EnginePatchMode EngineOnlyEchoPatch `
        -EnginePatchPackageRoot $corruptEnginePackageRoot -EnginePatchManifest $enginePatchManifest -ValidateOnly | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('Engine-only EchoPatch config hash mismatch')) { throw }
    $corruptEngineRejected = $true
}
if (-not $corruptEngineRejected -or (Test-Path -LiteralPath $corruptEngineStage)) {
    throw 'Changed engine-only EchoPatch package was accepted or its ValidateOnly failure created a stage.'
}

$stockRendererRejected = $false
try {
    & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -RendererMode DgVoodooD3D11 -ValidateOnly | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('supported only by -Lane Rebuilt')) { throw }
    $stockRendererRejected = $true
}
if (-not $stockRendererRejected) { throw 'StockEchoPatch accepted the rebuilt-only renderer mode.' }

$stockRtxRejected = $false
try {
    & $stageScript -Lane StockEchoPatch -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -RendererMode RtxRemixProbe -ValidateOnly | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('supported only by -Lane Rebuilt')) { throw }
    $stockRtxRejected = $true
}
if (-not $stockRtxRejected) { throw 'StockEchoPatch accepted the rebuilt-only RTX probe mode.' }

$rtxEnginePatchRejected = $false
try {
    & $stageScript `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -RendererMode RtxRemixProbe -EnginePatchMode EngineOnlyEchoPatch -ValidateOnly | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('requires a separately pinned camera-diagnostic EchoPatch derivative')) { throw }
    $rtxEnginePatchRejected = $true
}
if (-not $rtxEnginePatchRejected) { throw 'RTX Remix probe accepted a stacked engine-patch experiment.' }

$rtxMissingDiagnosticRejected = $false
try {
    & $stageScript `
        -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot `
        -RendererMode RtxRemixProbe -ValidateOnly | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('requires a separately pinned camera-diagnostic EchoPatch derivative')) { throw }
    $rtxMissingDiagnosticRejected = $true
}
if (-not $rtxMissingDiagnosticRejected) { throw 'RTX Remix probe accepted a configuration without its diagnostic companion.' }

$unownedCapRejected = $false
try {
    & $stageScript -Lane Rebuilt -Configuration $Configuration -RepositoryRoot $RepositoryRoot -RetailRoot $fixtureRoot -BuildRoot $buildRoot -MaxFPS 120 -ValidateOnly | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('-MaxFPS require an explicit EchoPatch engine-patch mode')) { throw }
    $unownedCapRejected = $true
}
if (-not $unownedCapRejected) { throw 'Default Rebuilt staging accepted a cap without owning the engine patch.' }

foreach ($inputPath in $protectedInputs) {
    if ((Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash -ne $beforeHashes[$inputPath]) {
        throw "Protected renderer-stage input changed during the test: $inputPath"
    }
}
foreach ($localPath in @($fixtureRoot, $combinedStage, $nativeStage, $legacyNativeStage, $rtxStage, $changedRendererStage, $changedRendererConfigStage, $corruptRendererArchive, $corruptRtxArchive, $corruptEnginePackageRoot, $invalidRtxRuntimeConfigSeed, $rtxUserConfigFixture)) {
    & git -C $RepositoryRoot check-ignore -q $localPath
    if ($LASTEXITCODE -ne 0) {
        throw "Renderer-stage test path is not ignored by Git: $localPath"
    }
}

$result = [pscustomobject]@{
    Status                            = 'PASS'
    Configuration                     = $Configuration
    NativeDefaultsPreserved           = $true
    DgVoodooD3D11Validated            = $true
    RendererQualityProfilesValidated  = $rendererQualityMismatchRejected
    RendererQualityRefreshVerified    = $true
    RtxRemixProbeValidated            = $true
    RtxOwnedFileCount                 = 165
    RtxRuntimeWritablePathsPreserved  = $true
    RtxCustomRestirSeedValidated      = $true
    RtxCustomRestirSeedAppliedOnNewStage = $true
    RtxRuntimeConfigEditsPreserved    = $true
    RtxRuntimeConfigAbsencePreserved  = $true
    InvalidRtxRuntimeSeedRejected     = $invalidRtxRuntimeConfigSeedRejected
    RtxAutomaticGraphicsPresetRejected = $automaticGraphicsPresetSeedRejected
    RtxSafeEditedRuntimeConfigAccepted = $true
    RtxUnsafeEditedRuntimeConfigRejected = $unsafeEditedRuntimeConfigRejected
    RtxUnsafeUserConfigOverrideRejected = $unsafeUserConfigRejected
    RtxSafeUserConfigOverrideAccepted = $true
    RtxUnsafeArchivePathsRejected     = $true
    RtxLegacyManifestRejected         = $legacyRtxRejected
    RtxPackageIdentityMismatchRejected = $wrongPackageRtxRejected
    RtxOwnedPathSetMismatchRejected   = $changedPathSetRtxRejected
    NativeSchemaMigrationVerified     = $true
    RtxUnownedTrexFileRejected        = $unexpectedTrexRejected
    RtxBridgeConfigOwned              = $true
    RtxMissingBridgeConfigOwnershipRejected = $missingConfigRtxRejected
    ChangedRtxBridgeConfigRejected    = $changedRtxBridgeConfigRejected
    ChangedRtxOwnedFileRejected       = $changedRtxRejected
    CorruptRtxPackageRejected         = $corruptRtxRejected
    RtxEnginePatchStackRejected       = $rtxEnginePatchRejected
    RtxMissingDiagnosticRejected      = $rtxMissingDiagnosticRejected
    EngineOnlyEchoPatchValidated      = $true
    ProxyCoexistenceVerified          = $true
    ExplicitFrameCapVerified          = $true
    RendererModeMismatchRejected      = $modeMismatchRejected
    NativeRendererProxyRejected       = $nativeProxyRejected
    NativeRtxMarkersRejected          = $nativeRtxDirectoryRejected -and $nativeRtxConfigRejected
    ChangedRendererProxyRejected      = $changedRendererRejected
    ChangedRendererConfigRejected     = $changedRendererConfigRejected
    CorruptRendererPackageRejected    = $corruptRendererRejected
    CorruptEnginePatchPackageRejected = $corruptEngineRejected
    RebuiltOnlyRendererBoundary       = $stockRendererRejected -and $stockRtxRejected
    EnginePatchOptionOwnership        = $unownedCapRejected
    ProtectedInputsUnchanged          = $true
    TemporaryOutputsRemoved           = $true
    RuntimeLaunched                   = $false
    Note                              = 'Synthetic fixture proves package/stage mechanics only; real renderer visual and performance acceptance remains required.'
}

foreach ($cleanupPath in $cleanupPaths) {
    Remove-RendererTestPath -Path $cleanupPath -LocalRuntimeRoot $localRuntimeRoot -AllowedPaths $cleanupPaths
}
$result
