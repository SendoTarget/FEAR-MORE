[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$StageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Rejected {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$ExpectedMessage,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $rejected = $false
    try {
        & $Action
    }
    catch {
        if (-not $_.Exception.Message.Contains($ExpectedMessage)) {
            throw
        }
        $rejected = $true
    }
    if (-not $rejected) {
        throw "$Description was accepted unexpectedly."
    }
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

$enginePatchModule = Join-Path $PSScriptRoot 'FearEnginePatchPackage.psm1'
$stagePlanModule = Join-Path $PSScriptRoot 'FearRuntimeStagePlan.psm1'
Import-Module $enginePatchModule -Force -ErrorAction Stop
Import-Module $stagePlanModule -Force -ErrorAction Stop

$rtxPackageRoot = Join-Path $RepositoryRoot 'vendor-local\echopatch-rtx-camera-diagnostics\local-package-b4a7074e4cbb'
$rtxManifestPath = Join-Path $RepositoryRoot 'vendor-local\echopatch-rtx-camera-diagnostics\manifest-b4a7074e4cbb.json'
$cameraPackageRoot = Join-Path $RepositoryRoot 'vendor-local\echopatch-camera-diagnostics\local-package-b4a7074e4cbb'
$cameraManifestPath = Join-Path $RepositoryRoot 'vendor-local\echopatch-camera-diagnostics\manifest-b4a7074e4cbb.json'

$rtxIdentity = Get-FearRtxCameraDiagnosticEchoPatchPackageIdentity `
    -PackageRoot $rtxPackageRoot `
    -ManifestPath $rtxManifestPath
if ($rtxIdentity.ManifestSha256 -cne '151487BBD3B321F040C2BE776E252023018F24D9F5072F43B82653E72243853B' -or
    $rtxIdentity.BinarySha256 -cne '09933000F129F509399C9792211E333FD3CBE2DDEDC7D19AAD82552AF97ADD15' -or
    $rtxIdentity.ConfigSha256 -cne '87A76A140EB03A4CDF689B037BD5F5EFD953C81F8804E6FA59E8377B885F1EB2' -or
    -not $rtxIdentity.CameraDiagnostics -or -not $rtxIdentity.RtxFocusPreservation -or
    $rtxIdentity.ModuleHooks) {
    throw 'Pinned RtxCameraDiagnosticEchoPatch identity changed unexpectedly.'
}

# The ordinary CameraLab package is deliberately unchanged. Missing focus
# preservation is interpreted as disabled so older/default profiles remain valid.
$cameraIdentity = Get-FearCameraDiagnosticEchoPatchPackageIdentity `
    -PackageRoot $cameraPackageRoot `
    -ManifestPath $cameraManifestPath
$cameraConfigIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
    -Path $cameraIdentity.ConfigPath `
    -ExpectedMaxFPS 60.0 `
    -ExpectedDynamicVsync 1 `
    -ExpectedCameraDiagnostics 1 `
    -ExpectedRemixCameraDiagnostics 0 `
    -ExpectedRtxFocusPreservation 0
if (-not $cameraIdentity.CameraDiagnostics -or $cameraConfigIdentity.RtxFocusPreservation) {
    throw 'Ordinary CameraDiagnosticEchoPatch no longer preserves native focus-change renderer behavior.'
}

$planArguments = @{
    Lane                            = 'Rebuilt'
    Configuration                   = 'Release'
    RepositoryRoot                  = $RepositoryRoot
    RuntimeToolsRoot                = $PSScriptRoot
    RendererMode                    = 'RtxRemixProbe'
    DgVoodooArchive                 = $null
    DgVoodooArchiveSpecified        = $false
    RtxRemixArchive                 = $null
    RtxRemixArchiveSpecified        = $false
    PostProcessMode                 = 'None'
    ReShadeSetup                    = $null
    ReShadeSetupSpecified           = $false
    EnginePatchMode                 = 'RtxCameraDiagnosticEchoPatch'
    EnginePatchPackageRoot          = $null
    EnginePatchPackageRootSpecified = $false
    EnginePatchManifest             = $null
    EnginePatchManifestSpecified    = $false
    MaxFPS                          = 60.0
    MaxFPSExplicit                  = $false
}
$plan = Resolve-FearRuntimeStagePackagePlan @planArguments
if ($plan.EnginePatchPackageRoot -cne [IO.Path]::GetFullPath($rtxPackageRoot) -or
    $plan.EnginePatchManifest -cne [IO.Path]::GetFullPath($rtxManifestPath) -or
    $plan.DefaultStageDirectoryName -cne 'fearmore-rebuilt-release-rtx-remix-probe-1-5-2-rtx-camera-diagnostics-focus-preserved' -or
    $plan.EnginePatchMode -cne 'RtxCameraDiagnosticEchoPatch' -or
    -not $plan.EnginePatchForceWindowed -or -not $plan.EnginePatchFixWindowStyle -or
    $plan.MaxFPS -ne 60.0 -or $plan.DynamicVsync -ne 1) {
    throw 'RTX focus-preserving package plan changed its isolated package or presentation identity.'
}

$packageIdentities = Get-FearRuntimeStagePackageIdentities `
    -RendererMode $plan.RendererMode `
    -DgVoodooArchive $plan.DgVoodooArchive `
    -RtxRemixArchive $plan.RtxRemixArchive `
    -RendererConfigSource $plan.RendererConfigSource `
    -RendererRuntimeConfigSeedSource $plan.RendererRuntimeConfigSeedSource `
    -PostProcessMode $plan.PostProcessMode `
    -PostProcessSetup $plan.PostProcessSetup `
    -PostProcessAssetRoot $plan.PostProcessAssetRoot `
    -EnginePatchMode $plan.EnginePatchMode `
    -EnginePatchPackageRoot $plan.EnginePatchPackageRoot `
    -EnginePatchManifest $plan.EnginePatchManifest
if (-not $packageIdentities.EnginePatchPackageIdentity.RtxFocusPreservation -or
    $packageIdentities.EnginePatchPackageIdentity.BinarySha256 -cne $rtxIdentity.BinarySha256) {
    throw 'Stage-plan identity routing did not select the pinned RTX focus-preserving EchoPatch package.'
}

$mutationPaths = @(Get-FearRebuiltStageMutationRelativePaths `
    -RendererMode $plan.RendererMode `
    -RendererPackageIdentity $packageIdentities.RendererPackageIdentity `
    -RendererConfigFile $plan.RendererConfigFile `
    -EnginePatchMode $plan.EnginePatchMode `
    -GameModuleNames @('GameClient.dll', 'GameServer.dll', 'ClientFx.fxd'))
foreach ($requiredMutationPath in @('dinput8.dll', 'EchoPatch.ini', '.trex\bridge.conf', 'rtx.conf')) {
    if (@($mutationPaths | Where-Object { $_ -ceq $requiredMutationPath }).Count -ne 1) {
        throw "RTX focus-preserving mutation inventory does not own exactly one '$requiredMutationPath' path."
    }
}

$nativeArguments = $planArguments.Clone()
$nativeArguments.RendererMode = 'NativeD3D9'
Assert-Rejected `
    -Action { Resolve-FearRuntimeStagePackagePlan @nativeArguments | Out-Null } `
    -ExpectedMessage 'requires -RendererMode RtxRemixProbe' `
    -Description 'Native renderer with RtxCameraDiagnosticEchoPatch'

$explicitCapArguments = $planArguments.Clone()
$explicitCapArguments.MaxFPSExplicit = $true
Assert-Rejected `
    -Action { Resolve-FearRuntimeStagePackagePlan @explicitCapArguments | Out-Null } `
    -ExpectedMessage '-MaxFPS is not configurable for RtxCameraDiagnosticEchoPatch' `
    -Description 'Explicit frame cap with RtxCameraDiagnosticEchoPatch'

$focusPreservingStageValidated = $false
if ($StageRoot) {
    if (-not [IO.Path]::IsPathRooted($StageRoot)) {
        $StageRoot = Join-Path $RepositoryRoot $StageRoot
    }
    $StageRoot = [IO.Path]::GetFullPath($StageRoot)
    $stageManifestPath = Join-Path $StageRoot 'fearmore-stage.json'
    $stageConfigPath = Join-Path $StageRoot 'EchoPatch.ini'
    $stageProxyPath = Join-Path $StageRoot 'dinput8.dll'
    foreach ($stageInput in @($stageManifestPath, $stageConfigPath, $stageProxyPath)) {
        if (-not (Test-Path -LiteralPath $stageInput -PathType Leaf)) {
            throw "RTX focus-preserving stage input is missing: $stageInput"
        }
    }

    $stageManifest = Get-Content -LiteralPath $stageManifestPath -Raw | ConvertFrom-Json
    $stageConfigIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
        -Path $stageConfigPath `
        -ExpectedMaxFPS 60.0 `
        -ExpectedDynamicVsync 1 `
        -ExpectedCameraDiagnostics 1 `
        -ExpectedRemixCameraDiagnostics 0 `
        -ExpectedRtxFocusPreservation 1 `
        -ExpectedForceWindowed 1 `
        -ExpectedFixWindowStyle 1
    $stageProxyHash = (Get-FileHash -LiteralPath $stageProxyPath -Algorithm SHA256).Hash
    if ($stageManifest.RendererMode -cne 'RtxRemixProbe' -or
        $stageManifest.EnginePatchMode -cne 'RtxCameraDiagnosticEchoPatch' -or
        $stageManifest.EnginePatchManifestSha256 -cne $rtxIdentity.ManifestSha256 -or
        $stageManifest.EnginePatchProxySha256 -cne $rtxIdentity.BinarySha256 -or
        $stageProxyHash -cne $rtxIdentity.BinarySha256 -or
        -not $stageConfigIdentity.RtxFocusPreservation -or
        -not $stageConfigIdentity.ForceWindowed -or
        @($stageManifest.LaunchArguments | Where-Object { $_ -ceq '+FearMoreCameraDiagnostics' }).Count -ne 1 -or
        -not (Test-Path -LiteralPath (Join-Path $StageRoot '.trex\bridge.conf') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $StageRoot 'rtx.conf') -PathType Leaf)) {
        throw 'Prepared RTX focus-preserving stage does not match its pinned renderer, engine-patch, config, or launch identity.'
    }
    $focusPreservingStageValidated = $true
}

[pscustomobject]@{
    Passed                         = $true
    PackageMode                    = $plan.EnginePatchMode
    PackageRoot                    = $plan.EnginePatchPackageRoot
    ManifestSha256                 = $rtxIdentity.ManifestSha256
    BinarySha256                   = $rtxIdentity.BinarySha256
    ConfigSha256                   = $rtxIdentity.ConfigSha256
    RtxFocusPreservation           = $rtxIdentity.RtxFocusPreservation
    CameraLabFocusPreservation     = $cameraConfigIdentity.RtxFocusPreservation
    NativeSelectionRejected        = $true
    ExplicitFrameCapRejected       = $true
    RendererPackageSha256          = $packageIdentities.RendererPackageIdentity.ArchiveSha256
    DefaultStageDirectoryName      = $plan.DefaultStageDirectoryName
    FocusPreservingStageValidated  = $focusPreservingStageValidated
    StageRoot                       = if ($focusPreservingStageValidated) { $StageRoot } else { $null }
}
