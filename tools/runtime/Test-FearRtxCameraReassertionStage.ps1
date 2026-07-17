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

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message.Contains($ExpectedMessage)) {
            return
        }
        throw
    }
    throw "$Description was accepted unexpectedly."
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

Import-Module (Join-Path $PSScriptRoot 'FearEnginePatchPackage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStagePlan.psm1') -Force -ErrorAction Stop

$packageRoot = Join-Path $RepositoryRoot 'vendor-local\echopatch-rtx-camera-reassertion\local-package-b4a7074e4cbb'
$manifestPath = Join-Path $RepositoryRoot 'vendor-local\echopatch-rtx-camera-reassertion\manifest-b4a7074e4cbb.json'
$controlPackageRoot = Join-Path $RepositoryRoot 'vendor-local\echopatch-rtx-camera-diagnostics\local-package-b4a7074e4cbb'
$controlManifestPath = Join-Path $RepositoryRoot 'vendor-local\echopatch-rtx-camera-diagnostics\manifest-b4a7074e4cbb.json'

$identity = Get-FearRtxCameraReassertionEchoPatchPackageIdentity `
    -PackageRoot $packageRoot `
    -ManifestPath $manifestPath
if ($identity.ManifestSha256 -cne '4EFBF1321AB608ED05062CDBD059D6B7682C95C129C13FE0FE11825071E56A4B' -or
    $identity.BinarySha256 -cne 'CAF576C721585A7418BCD75386B1D5CA3B819C8803B143A7521842D7675B6270' -or
    $identity.ConfigSha256 -cne '727D468594041BE123E80C920A3833F2BA1876AE5D5475A4E8A0D543CDC7E08B' -or
    -not $identity.CameraDiagnostics -or
    -not $identity.RtxFocusPreservation -or
    -not $identity.RtxCameraReassertion -or
    $identity.ModuleHooks) {
    throw 'Pinned RtxCameraReassertionEchoPatch identity changed unexpectedly.'
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
    EnginePatchMode                 = 'RtxCameraReassertionEchoPatch'
    EnginePatchPackageRoot          = $null
    EnginePatchPackageRootSpecified = $false
    EnginePatchManifest             = $null
    EnginePatchManifestSpecified    = $false
    MaxFPS                          = 60.0
    MaxFPSExplicit                  = $false
}
$plan = Resolve-FearRuntimeStagePackagePlan @planArguments
if ($plan.EnginePatchPackageRoot -cne [IO.Path]::GetFullPath($packageRoot) -or
    $plan.EnginePatchManifest -cne [IO.Path]::GetFullPath($manifestPath) -or
    $plan.DefaultStageDirectoryName -cne 'fearmore-rebuilt-release-rtx-remix-probe-1-5-2-rtx-camera-reassertion-focus-preserved' -or
    $plan.EnginePatchMode -cne 'RtxCameraReassertionEchoPatch' -or
    -not $plan.EnginePatchForceWindowed -or
    -not $plan.EnginePatchFixWindowStyle -or
    $plan.MaxFPS -ne 60.0 -or
    $plan.DynamicVsync -ne 1) {
    throw 'RTX camera-reassertion package plan changed its isolated package or presentation identity.'
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
if (-not $packageIdentities.EnginePatchPackageIdentity.RtxCameraReassertion -or
    $packageIdentities.EnginePatchPackageIdentity.BinarySha256 -cne $identity.BinarySha256) {
    throw 'Stage-plan identity routing did not select the pinned camera-reassertion package.'
}

$nativeArguments = $planArguments.Clone()
$nativeArguments.RendererMode = 'NativeD3D9'
Assert-Rejected `
    -Action { Resolve-FearRuntimeStagePackagePlan @nativeArguments | Out-Null } `
    -ExpectedMessage 'requires -RendererMode RtxRemixProbe' `
    -Description 'Native renderer with RtxCameraReassertionEchoPatch'

$explicitCapArguments = $planArguments.Clone()
$explicitCapArguments.MaxFPSExplicit = $true
Assert-Rejected `
    -Action { Resolve-FearRuntimeStagePackagePlan @explicitCapArguments | Out-Null } `
    -ExpectedMessage '-MaxFPS is not configurable for RtxCameraReassertionEchoPatch' `
    -Description 'Explicit frame cap with RtxCameraReassertionEchoPatch'

Assert-Rejected `
    -Action {
        Get-FearRuntimeStagePackageIdentities `
            -RendererMode $plan.RendererMode `
            -DgVoodooArchive $plan.DgVoodooArchive `
            -RtxRemixArchive $plan.RtxRemixArchive `
            -RendererConfigSource $plan.RendererConfigSource `
            -RendererRuntimeConfigSeedSource $plan.RendererRuntimeConfigSeedSource `
            -PostProcessMode $plan.PostProcessMode `
            -PostProcessSetup $plan.PostProcessSetup `
            -PostProcessAssetRoot $plan.PostProcessAssetRoot `
            -EnginePatchMode 'RtxCameraReassertionEchoPatch' `
            -EnginePatchPackageRoot $controlPackageRoot `
            -EnginePatchManifest $controlManifestPath | Out-Null
    } `
    -ExpectedMessage 'manifest hash mismatch' `
    -Description 'Control package passed as reassertion package'

$stageValidated = $false
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
            throw "RTX camera-reassertion stage input is missing: $stageInput"
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
        -ExpectedRtxCameraReassertion 1 `
        -ExpectedForceWindowed 1 `
        -ExpectedFixWindowStyle 1
    if ($stageManifest.RendererMode -cne 'RtxRemixProbe' -or
        $stageManifest.EnginePatchMode -cne 'RtxCameraReassertionEchoPatch' -or
        $stageManifest.EnginePatchManifestSha256 -cne $identity.ManifestSha256 -or
        $stageManifest.EnginePatchProxySha256 -cne $identity.BinarySha256 -or
        (Get-FileHash -LiteralPath $stageProxyPath -Algorithm SHA256).Hash -cne $identity.BinarySha256 -or
        -not $stageConfigIdentity.RtxCameraReassertion -or
        -not $stageConfigIdentity.RtxFocusPreservation -or
        @($stageManifest.LaunchArguments | Where-Object { $_ -ceq '+FearMoreCameraDiagnostics' }).Count -ne 1) {
        throw 'Prepared RTX camera-reassertion stage does not match its pinned package, config, or launch identity.'
    }
    $stageValidated = $true
}

[pscustomobject]@{
    Passed                    = $true
    PackageMode               = $plan.EnginePatchMode
    ManifestSha256            = $identity.ManifestSha256
    BinarySha256              = $identity.BinarySha256
    ConfigSha256              = $identity.ConfigSha256
    DefaultStageDirectoryName = $plan.DefaultStageDirectoryName
    NativeSelectionRejected   = $true
    ExplicitFrameCapRejected  = $true
    ControlPackageRejected    = $true
    StageValidated            = $stageValidated
    StageRoot                 = if ($stageValidated) { $StageRoot } else { $null }
}
