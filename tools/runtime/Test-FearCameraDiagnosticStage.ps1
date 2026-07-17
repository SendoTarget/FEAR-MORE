[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',
    [switch]$SkipRealPackage
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
        if (-not $_.Exception.Message.Contains($ExpectedMessage)) {
            throw
        }
        return
    }
    throw "$Description was accepted."
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    [IO.File]::WriteAllText(
        $Path,
        ($Value | ConvertTo-Json -Depth 8),
        [Text.UTF8Encoding]::new($false))
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
$launcherScript = Join-Path $PSScriptRoot 'Start-FearMore.ps1'
$enginePatchModule = Join-Path $PSScriptRoot 'FearEnginePatchPackage.psm1'
$sdkRuntimeExecutable = Join-Path $RepositoryRoot 'vendor-local\fear-sdk-108\Runtime\FEARDevSP.exe'
$buildRoot = Join-Path $RepositoryRoot "build\fear-win32\bin\$Configuration"
$realCameraPackageRoot = Join-Path $RepositoryRoot 'vendor-local\echopatch-camera-diagnostics\local-package-b4a7074e4cbb'
$realCameraManifestPath = Join-Path $RepositoryRoot 'vendor-local\echopatch-camera-diagnostics\manifest-b4a7074e4cbb.json'
$rtxRemixArchive = Join-Path $RepositoryRoot 'vendor-local\renderer-deps\remix-1.5.2-release.zip'
$cameraSourceFiles = [ordered]@{
    cameraDiagnosticsPatchSha256   = Join-Path $RepositoryRoot 'patches\echopatch\0004-add-camera-diagnostics.patch'
    cameraDiagnosticsOverlaySha256 = Join-Path $RepositoryRoot 'tools\echopatch\overlays\CameraDiagnostics.cpp'
    profileBaseSha256               = Join-Path $RepositoryRoot 'tools\echopatch\EchoPatch.engine-only.ini'
    profileOverrideSha256           = Join-Path $RepositoryRoot 'tools\echopatch\EchoPatch.camera-diagnostics.override.ini'
}
$protectedInputs = @(
    $stageScript,
    $launcherScript,
    $enginePatchModule,
    $sdkRuntimeExecutable,
    (Join-Path $buildRoot 'GameClient.dll'),
    (Join-Path $buildRoot 'GameServer.dll'),
    (Join-Path $buildRoot 'ClientFx.fxd')
) + @($cameraSourceFiles.Values)
$realCameraPackageInputs = @(
    (Join-Path $realCameraPackageRoot 'dinput8.dll'),
    (Join-Path $realCameraPackageRoot 'EchoPatch.ini'),
    $realCameraManifestPath
)
$realCameraPackageAvailable = -not $SkipRealPackage -and @($realCameraPackageInputs | Where-Object {
    -not (Test-Path -LiteralPath $_ -PathType Leaf)
}).Count -eq 0
if ($realCameraPackageAvailable) {
    $protectedInputs += $realCameraPackageInputs
}
$rtxCrossProductAvailable = $realCameraPackageAvailable -and (Test-Path -LiteralPath $rtxRemixArchive -PathType Leaf)
if ($rtxCrossProductAvailable) {
    $protectedInputs += $rtxRemixArchive
}
foreach ($inputPath in $protectedInputs) {
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) {
        throw "Camera diagnostic stage test input is missing: $inputPath"
    }
}
$protectedHashes = @{}
foreach ($inputPath in $protectedInputs) {
    $protectedHashes[$inputPath] = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash
}

Import-Module $enginePatchModule -Force -ErrorAction Stop

$launcherSource = (Get-Content -LiteralPath $launcherScript -Raw) -replace "`r`n", "`n"
foreach ($launcherInvariant in @(
        "[ValidateSet('Stable', 'Modern', 'RtxLab', 'RtxBridgeLab', 'CameraLab')]",
        "'Stable' {`n        `$stageParameters.RendererMode = 'NativeD3D9'`n        `$stageParameters.EnginePatchMode = 'None'",
        "'Modern' {`n        `$stageParameters.RendererMode = 'DgVoodooD3D11'`n        `$stageParameters.EnginePatchMode = 'EngineOnlyEchoPatch'",
        "'RtxLab' {`n        `$stageParameters.RendererMode = 'RtxRemixProbe'`n        `$stageParameters.EnginePatchMode = 'RtxCameraDiagnosticEchoPatch'",
        "'RtxBridgeLab' {`n        `$stageParameters.RendererMode = 'RtxRemixProbe'`n        `$stageParameters.EnginePatchMode = 'RtxCameraReassertionEchoPatch'",
        "'CameraLab' {`n        `$stageParameters.RendererMode = 'NativeD3D9'`n        `$stageParameters.EnginePatchMode = 'CameraDiagnosticEchoPatch'",
        "'Stable' { 'fearmore-launcher-stable' }",
        "'Modern' { 'fearmore-launcher-modern' }",
        "'RtxLab' { 'fearmore-launcher-rtx-query-light-restir-custom-focus-preserved-d9d8-lab' }",
        "'RtxBridgeLab' { 'fearmore-launcher-rtx-camera-reassertion-prearm300s-300f-lab' }",
        "'CameraLab' { 'fearmore-launcher-native-camera-lab-armed' }"
    )) {
    if (-not $launcherSource.Contains($launcherInvariant)) {
        throw "Launcher preset mapping changed or is missing: $launcherInvariant"
    }
}
foreach ($retailSteamInvariant in @(
        "`$rtxPreset = `$Preset -in @('RtxLab', 'RtxBridgeLab')",
        '$useRetailSteamLaunch = $rtxPreset -and -not $PrepareOnly',
        '-not $useRetailSteamLaunch -and -not $PrepareOnly',
        '$runningSteamExecutables = @(',
        '& $retailSidecarInstaller',
        '$rtxPreset -and $hdTextureMode -eq ''Full''',
        'New-FearSteamLaunchPlan',
        'Invoke-FearSteamLaunchPlan'
    )) {
    if (-not $launcherSource.Contains($retailSteamInvariant)) {
        throw "The RTX presets no longer route through the guarded retail-sidecar plus Steam launch path: $retailSteamInvariant"
    }
}
$steamPreflightIndex = $launcherSource.IndexOf('Get-FearRunningSteamClientIdentity')
$retailInstallIndex = $launcherSource.IndexOf('& $retailSidecarInstaller')
if ($steamPreflightIndex -lt 0 -or $retailInstallIndex -lt 0 -or
    $steamPreflightIndex -ge $retailInstallIndex) {
    throw 'RtxLab no longer validates the exact running same-session Steam client before its guarded retail mutation.'
}
Assert-Rejected `
    -Action { & $launcherScript -Preset CameraLab -MaxFPS 120 -PrepareOnly } `
    -ExpectedMessage 'CameraLab/RTX diagnostic profiles are fixed at 60 FPS' `
    -Description 'CameraLab explicit MaxFPS override'

$runId = [Guid]::NewGuid().ToString('N')
$localRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'local-runtime')).TrimEnd('\')
$fixtureRoot = Join-Path $localRuntimeRoot "camera-diagnostic-fixture-retail-$runId"
$syntheticRoot = Join-Path $localRuntimeRoot "camera-diagnostic-package-$runId"
$syntheticPackageRoot = Join-Path $syntheticRoot 'local-package-b4a7074e4cbb'
$syntheticManifestPath = Join-Path $syntheticRoot 'manifest-b4a7074e4cbb.json'
$stageRoot = Join-Path $localRuntimeRoot "camera-diagnostic-stage-$runId"
$overrideStageRoot = Join-Path $localRuntimeRoot "camera-diagnostic-override-$runId"
$capStageRoot = Join-Path $localRuntimeRoot "camera-diagnostic-cap-$runId"
$rendererStageRoot = Join-Path $localRuntimeRoot "camera-diagnostic-renderer-$runId"
$rtxStageRoot = Join-Path $localRuntimeRoot "camera-diagnostic-rtx-cross-product-$runId"
$cleanupPaths = @($fixtureRoot, $syntheticRoot, $stageRoot, $overrideStageRoot, $capStageRoot, $rendererStageRoot, $rtxStageRoot)

try {
    New-Item -ItemType Directory -Path $fixtureRoot, $syntheticPackageRoot -Force | Out-Null
    Copy-Item -LiteralPath $sdkRuntimeExecutable -Destination (Join-Path $fixtureRoot 'FEAR.exe') -Force
    foreach ($fileName in @('EngineServer.dll', 'GameDatabase.dll', 'LTMemory.dll', 'SndDrv.dll', 'StringEditRuntime.dll')) {
        [IO.File]::WriteAllBytes((Join-Path $fixtureRoot $fileName), [byte[]](0x46, 0x45, 0x41, 0x52))
    }
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'FEAR.Arch00'), [byte[]](0x46, 0x45, 0x41, 0x52))
    [IO.File]::WriteAllLines((Join-Path $fixtureRoot 'Default.archcfg'), @('FEAR.Arch00'), [Text.ASCIIEncoding]::new())

    $syntheticBinaryPath = Join-Path $syntheticPackageRoot 'dinput8.dll'
    $syntheticConfigPath = Join-Path $syntheticPackageRoot 'EchoPatch.ini'
    Copy-Item -LiteralPath $sdkRuntimeExecutable -Destination $syntheticBinaryPath -Force
    $baseConfig = [IO.File]::ReadAllText($cameraSourceFiles.profileBaseSha256).TrimEnd("`r", "`n")
    $cameraConfig = $baseConfig + "`r`n`r`n[Diagnostics]`r`nCameraDiagnostics = 1`r`n"
    [IO.File]::WriteAllText($syntheticConfigPath, $cameraConfig, [Text.UTF8Encoding]::new($false))

    $manifest = [ordered]@{
        echoPatchCommit                    = 'b4a7074e4cbb2fb6bb238809f7cf26424f1f5961'
        binarySha256                       = (Get-FileHash -LiteralPath $syntheticBinaryPath -Algorithm SHA256).Hash
        profileSha256                      = (Get-FileHash -LiteralPath $syntheticConfigPath -Algorithm SHA256).Hash
        machine                            = '0x014c'
        optionalHeader                     = '0x010b'
        moduleHooks                        = $false
        compatibilityProof                 = 'PatchGameModules=0; GameClient.dll, GameServer.dll, and ClientFX hooks were intentionally skipped.'
        packageMode                        = 'CameraDiagnosticEchoPatch'
        cameraDiagnostics                  = $true
        cameraDiagnosticsProof             = 'FearMoreDiagnostics\camera-d3d9-'
        cameraDiagnosticsPatchSha256       = $protectedHashes[$cameraSourceFiles.cameraDiagnosticsPatchSha256]
        cameraDiagnosticsOverlaySha256     = $protectedHashes[$cameraSourceFiles.cameraDiagnosticsOverlaySha256]
        profileBaseSha256                  = $protectedHashes[$cameraSourceFiles.profileBaseSha256]
        profileOverrideSha256              = $protectedHashes[$cameraSourceFiles.profileOverrideSha256]
    }
    Write-JsonFile -Path $syntheticManifestPath -Value $manifest
    Assert-Rejected `
        -Action { Get-FearCameraDiagnosticEchoPatchPackageIdentity -PackageRoot $syntheticPackageRoot -ManifestPath $syntheticManifestPath } `
        -ExpectedMessage 'manifest hash mismatch' `
        -Description 'Fully self-consistent forged camera diagnostic package'

    $remixConfig = $cameraConfig + "RemixCameraDiagnostics = 1`r`n"
    [IO.File]::WriteAllText($syntheticConfigPath, $remixConfig, [Text.UTF8Encoding]::new($false))
    Assert-Rejected `
        -Action {
            Get-FearEngineOnlyEchoPatchConfigIdentity `
                -Path $syntheticConfigPath `
                -ExpectedMaxFPS 60.0 `
                -ExpectedDynamicVsync 1 `
                -ExpectedCameraDiagnostics 1 `
                -ExpectedRemixCameraDiagnostics 0
        } `
        -ExpectedMessage 'Diagnostics.RemixCameraDiagnostics is 1; expected 0' `
        -Description 'Camera package with Remix diagnostics enabled'
    [IO.File]::WriteAllText($syntheticConfigPath, $cameraConfig, [Text.UTF8Encoding]::new($false))

    $stageParameters = @{
        Lane                   = 'Rebuilt'
        Configuration          = $Configuration
        RepositoryRoot         = $RepositoryRoot
        RetailRoot             = $fixtureRoot
        BuildRoot              = $buildRoot
        RendererMode           = 'NativeD3D9'
        EnginePatchMode        = 'CameraDiagnosticEchoPatch'
        EnginePatchPackageRoot = $syntheticPackageRoot
        EnginePatchManifest    = $syntheticManifestPath
    }
    $invalidRendererParameters = $stageParameters.Clone()
    $invalidRendererParameters.RendererMode = 'DgVoodooD3D11'
    Assert-Rejected `
        -Action { & $stageScript @invalidRendererParameters -StageRoot $rendererStageRoot -ValidateOnly } `
        -ExpectedMessage 'requires -RendererMode NativeD3D9 or RtxRemixProbe' `
        -Description 'Camera diagnostic with unsupported translation renderer'
    Assert-Rejected `
        -Action { & $stageScript @stageParameters -StageRoot $capStageRoot -MaxFPS 120 -ValidateOnly } `
        -ExpectedMessage '-MaxFPS is not configurable for CameraDiagnosticEchoPatch' `
        -Description 'Camera diagnostic explicit frame cap'
    Assert-Rejected `
        -Action { & $stageScript @stageParameters -StageRoot $overrideStageRoot -LaunchArguments '+FearMoreCameraDiagnostics', '0' -ValidateOnly } `
        -ExpectedMessage 'must not override the launcher-owned FearMoreCameraDiagnostics state' `
        -Description 'Camera diagnostic source-cvar override'
    Assert-Rejected `
        -Action { & $stageScript @stageParameters -StageRoot $overrideStageRoot -LaunchArguments '+FearMoreCameraDiagnostics=0' -ValidateOnly } `
        -ExpectedMessage 'must not override the launcher-owned FearMoreCameraDiagnostics state' `
        -Description 'Inline camera diagnostic source-cvar override'
    foreach ($rejectedRoot in @($rendererStageRoot, $capStageRoot, $overrideStageRoot)) {
        if (Test-Path -LiteralPath $rejectedRoot) {
            throw "Rejected camera diagnostic selection created a stage: $rejectedRoot"
        }
    }

    $cameraPackageValidated = $false
    $cameraStageValidated = $false
    $stageOwnershipTamperRejected = $false
    $nativeRendererMarkersRejected = $false
    $diagnosticLogsPreserved = $false
    $rtxCrossProductValidated = $false
    $rtxCrossProductRuntimeConfigPreserved = $false
    if ($realCameraPackageAvailable) {
    $realIdentity = Get-FearCameraDiagnosticEchoPatchPackageIdentity `
        -PackageRoot $realCameraPackageRoot `
        -ManifestPath $realCameraManifestPath
    if ($realIdentity.ManifestSha256 -cne '5ACB326EEF2DFC1E98CEB92F22B6BB219146520154BC0BE26A7434BDE61BC3D4' -or
        $realIdentity.BinarySha256 -cne '7B2B788BF2551A9A1A3E7FFFE87D11120EF68DAFC4FE9FB8DF0AE7D826DD5C35' -or
        $realIdentity.ConfigSha256 -cne 'AF4FEB8EDDD2EC317B736CBE0FBC1B8F008B44DC5C8577292FC409AD18F58AB0') {
        throw 'Pinned real CameraDiagnosticEchoPatch identity changed unexpectedly.'
    }
    $cameraPackageValidated = $true
    $stageParameters.EnginePatchPackageRoot = $realCameraPackageRoot
    $stageParameters.EnginePatchManifest = $realCameraManifestPath
    $stage = & $stageScript @stageParameters -StageRoot $stageRoot
    $stageManifestPath = Join-Path $stageRoot 'fearmore-stage.json'
    $stageManifest = Get-Content -LiteralPath $stageManifestPath -Raw | ConvertFrom-Json
    $expectedLaunchArguments = @(
        '-userdirectory',
        [IO.Path]::GetFullPath((Join-Path $stageRoot 'UserDirectory')),
        '-archcfg',
        'Default.archcfg',
        '+FearMoreCameraDiagnostics',
        '1'
    )
    if ($stage.RendererMode -cne 'NativeD3D9' -or
        $stage.EnginePatchMode -cne 'CameraDiagnosticEchoPatch' -or
        $stage.EnginePatchForceWindowed -or -not $stage.EnginePatchFixWindowStyle -or
        $stageManifest.EnginePatchForceWindowed -or -not $stageManifest.EnginePatchFixWindowStyle -or
        $stage.MaxFPS -ne 60.0 -or $stage.MaxFPSExplicit -or $stage.DynamicVsync -ne 1 -or
        (@($stage.LaunchArguments) -join "`n") -cne ($expectedLaunchArguments -join "`n") -or
        (@($stageManifest.LaunchArguments) -join "`n") -cne ($expectedLaunchArguments -join "`n")) {
        throw 'Camera diagnostic stage did not preserve its native renderer, fixed cap, or launcher-owned source cvar.'
    }
    foreach ($forbiddenMarker in @('d3d9.dll', 'dgVoodoo.conf', 'd3d8to9.dll', 'NvRemixLauncher32.exe', '.trex', 'rtx-remix', 'rtx.conf')) {
        if (Test-Path -LiteralPath (Join-Path $stageRoot $forbiddenMarker)) {
            throw "Camera diagnostic native stage contains a forbidden renderer marker: $forbiddenMarker"
        }
    }
    $stagedConfigIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
        -Path (Join-Path $stageRoot 'EchoPatch.ini') `
        -ExpectedMaxFPS 60.0 `
        -ExpectedDynamicVsync 1 `
        -ExpectedCameraDiagnostics 1 `
        -ExpectedRemixCameraDiagnostics 0 `
        -ExpectedForceWindowed 0 `
        -ExpectedFixWindowStyle 1
    if (-not $stagedConfigIdentity.CameraDiagnostics -or $stagedConfigIdentity.RemixCameraDiagnostics) {
        throw 'Staged camera diagnostic profile did not preserve its mutually exclusive diagnostics flags.'
    }
    $cameraStageValidated = $true

    if ($rtxCrossProductAvailable) {
        $rtxParameters = $stageParameters.Clone()
        $rtxParameters.RendererMode = 'RtxRemixProbe'
        $rtxParameters.RtxRemixArchive = $rtxRemixArchive
        $rtxStage = & $stageScript @rtxParameters -StageRoot $rtxStageRoot
        $rtxManifestPath = Join-Path $rtxStageRoot 'fearmore-stage.json'
        $rtxManifest = Get-Content -LiteralPath $rtxManifestPath -Raw | ConvertFrom-Json
        $rtxConfigPath = Join-Path $rtxStageRoot 'rtx.conf'
        $rtxEchoPatchIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
            -Path (Join-Path $rtxStageRoot 'EchoPatch.ini') `
            -ExpectedMaxFPS 60.0 `
            -ExpectedDynamicVsync 1 `
            -ExpectedCameraDiagnostics 1 `
            -ExpectedRemixCameraDiagnostics 0 `
            -ExpectedForceWindowed 1 `
            -ExpectedFixWindowStyle 1
        if ($rtxStage.RendererMode -cne 'RtxRemixProbe' -or
            $rtxStage.EnginePatchMode -cne 'CameraDiagnosticEchoPatch' -or
            -not $rtxStage.EnginePatchForceWindowed -or -not $rtxStage.EnginePatchFixWindowStyle -or
            -not $rtxManifest.EnginePatchForceWindowed -or -not $rtxManifest.EnginePatchFixWindowStyle -or
            -not $rtxEchoPatchIdentity.ForceWindowed -or -not $rtxEchoPatchIdentity.FixWindowStyle -or
            -not $rtxStage.RendererRuntimeConfigSeedApplied -or
            $rtxStage.RendererRuntimeConfigSeedBackend -cne 'ReSTIR GI (pinned Remix 1.5.2)' -or
            $rtxStage.RendererRuntimeConfigSeedDlssFrameGenerationEnabled -ne $false -or
            -not $rtxManifest.RendererRuntimeConfigSeedApplied -or
            $rtxManifest.RendererRuntimeConfigSeedBackend -cne 'ReSTIR GI (pinned Remix 1.5.2)' -or
            $rtxManifest.RendererRuntimeConfigSeedDlssFrameGenerationEnabled -ne $false -or
            @($rtxManifest.RendererOwnedFiles).Count -ne 165 -or
            -not (Test-Path -LiteralPath $rtxConfigPath -PathType Leaf) -or
            (Get-Content -LiteralPath $rtxConfigPath -Raw) -notmatch '(?m)^rtx\.graphicsPreset\s*=\s*4\s*$' -or
            (Get-Content -LiteralPath $rtxConfigPath -Raw) -notmatch '(?m)^rtx\.integrateIndirectMode\s*=\s*1\s*$' -or
            (Get-Content -LiteralPath $rtxConfigPath -Raw) -notmatch '(?m)^rtx\.dlfg\.enable\s*=\s*False\s*$') {
            throw 'Exact RtxLab renderer/query-light diagnostic cross-product did not receive its pinned Custom + ReSTIR GI seed.'
        }
        $rtxCrossProductValidated = $true

        [IO.File]::WriteAllText($rtxConfigPath, "rtx.testUserOverride = true`r`n", [Text.UTF8Encoding]::new($false))
        $rtxConfigHash = (Get-FileHash -LiteralPath $rtxConfigPath -Algorithm SHA256).Hash
        $rtxRerun = & $stageScript @rtxParameters -StageRoot $rtxStageRoot
        if ($rtxRerun.RendererRuntimeConfigSeedApplied -or
            (Get-FileHash -LiteralPath $rtxConfigPath -Algorithm SHA256).Hash -cne $rtxConfigHash) {
            throw 'Exact RtxLab cross-product rerun overwrote its runtime-owned RTX config.'
        }
        $rtxCrossProductRuntimeConfigPreserved = $true
    }

    $diagnosticsDirectory = Join-Path $stage.UserDirectory 'FearMoreDiagnostics'
    New-Item -ItemType Directory -Path $diagnosticsDirectory -Force | Out-Null
    $diagnosticLog = Join-Path $diagnosticsDirectory 'camera-d3d9-synthetic.jsonl'
    [IO.File]::WriteAllText($diagnosticLog, "{`"event`":`"sentinel`"}`r`n", [Text.UTF8Encoding]::new($false))
    $logHash = (Get-FileHash -LiteralPath $diagnosticLog -Algorithm SHA256).Hash
    & $stageScript @stageParameters -StageRoot $stageRoot | Out-Null
    if (-not (Test-Path -LiteralPath $diagnosticLog -PathType Leaf) -or
        (Get-FileHash -LiteralPath $diagnosticLog -Algorithm SHA256).Hash -cne $logHash) {
        throw 'A safe CameraLab rerun did not preserve UserDirectory\FearMoreDiagnostics logs byte-for-byte.'
    }
    $diagnosticLogsPreserved = $true

    $stageProxyPath = Join-Path $stageRoot 'dinput8.dll'
    $stageProxyBytes = [IO.File]::ReadAllBytes($stageProxyPath)
    $stageProxyBytes[100] = $stageProxyBytes[100] -bxor 1
    [IO.File]::WriteAllBytes($stageProxyPath, $stageProxyBytes)
    $tamperedStageSnapshot = Get-DirectorySnapshot -Root $stageRoot
    Assert-Rejected `
        -Action { & $stageScript @stageParameters -StageRoot $stageRoot } `
        -ExpectedMessage 'Existing tool-owned engine patch proxy was changed' `
        -Description 'Tampered staged camera proxy'
    if ((Get-DirectorySnapshot -Root $stageRoot) -cne $tamperedStageSnapshot) {
        throw 'Tampered CameraLab stage mutated before fail-closed ownership rejection.'
    }
    $stageOwnershipTamperRejected = $true
    Copy-Item -LiteralPath (Join-Path $realCameraPackageRoot 'dinput8.dll') -Destination $stageProxyPath -Force

    $unownedRendererMarker = Join-Path $stageRoot 'd3d9.dll'
    [IO.File]::WriteAllBytes($unownedRendererMarker, [byte[]](0x44, 0x33, 0x44, 0x39))
    $markerSnapshot = Get-DirectorySnapshot -Root $stageRoot
    Assert-Rejected `
        -Action { & $stageScript @stageParameters -StageRoot $stageRoot } `
        -ExpectedMessage 'NativeD3D9 stage contains an unowned renderer proxy/config' `
        -Description 'CameraLab stage with unowned renderer marker'
    if ((Get-DirectorySnapshot -Root $stageRoot) -cne $markerSnapshot) {
        throw 'CameraLab renderer-marker rejection mutated the stage.'
    }
    $nativeRendererMarkersRejected = $true
    }
    else {
        # The package outer-pin rejection and all planning/launcher checks above
        # remain runnable without a built camera artifact. The generic stage
        # preservation invariant is exercised through the native no-patch lane.
        $nativeStageParameters = @{
            Lane           = 'Rebuilt'
            Configuration  = $Configuration
            RepositoryRoot = $RepositoryRoot
            RetailRoot     = $fixtureRoot
            BuildRoot      = $buildRoot
            RendererMode   = 'NativeD3D9'
            EnginePatchMode = 'None'
        }
        $nativeStage = & $stageScript @nativeStageParameters -StageRoot $stageRoot
        $diagnosticsDirectory = Join-Path $nativeStage.UserDirectory 'FearMoreDiagnostics'
        New-Item -ItemType Directory -Path $diagnosticsDirectory -Force | Out-Null
        $diagnosticLog = Join-Path $diagnosticsDirectory 'camera-d3d9-synthetic.jsonl'
        [IO.File]::WriteAllText($diagnosticLog, "{`"event`":`"sentinel`"}`r`n", [Text.UTF8Encoding]::new($false))
        $logHash = (Get-FileHash -LiteralPath $diagnosticLog -Algorithm SHA256).Hash
        & $stageScript @nativeStageParameters -StageRoot $stageRoot | Out-Null
        if ((Get-FileHash -LiteralPath $diagnosticLog -Algorithm SHA256).Hash -cne $logHash) {
            throw 'Native stage rerun did not preserve UserDirectory\FearMoreDiagnostics logs byte-for-byte.'
        }
        $diagnosticLogsPreserved = $true

        $nativeExecutablePath = Join-Path $stageRoot 'FEAR.exe'
        $nativeExecutableBytes = [IO.File]::ReadAllBytes($nativeExecutablePath)
        $nativeExecutableBytes[100] = $nativeExecutableBytes[100] -bxor 1
        [IO.File]::WriteAllBytes($nativeExecutablePath, $nativeExecutableBytes)
        $tamperedStageSnapshot = Get-DirectorySnapshot -Root $stageRoot
        Assert-Rejected `
            -Action { & $stageScript @nativeStageParameters -StageRoot $stageRoot } `
            -ExpectedMessage 'Existing tool-owned runtime executable was changed' `
            -Description 'Tampered native diagnostic-log runtime executable'
        if ((Get-DirectorySnapshot -Root $stageRoot) -cne $tamperedStageSnapshot) {
            throw 'Tampered native diagnostic-log stage mutated before ownership rejection.'
        }
        $stageOwnershipTamperRejected = $true
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'FEAR.exe') -Destination $nativeExecutablePath -Force

        $unownedRendererMarker = Join-Path $stageRoot 'd3d9.dll'
        [IO.File]::WriteAllBytes($unownedRendererMarker, [byte[]](0x44, 0x33, 0x44, 0x39))
        $markerSnapshot = Get-DirectorySnapshot -Root $stageRoot
        Assert-Rejected `
            -Action { & $stageScript @nativeStageParameters -StageRoot $stageRoot } `
            -ExpectedMessage 'NativeD3D9 stage contains an unowned renderer proxy/config' `
            -Description 'Native diagnostic-log stage with unowned renderer marker'
        if ((Get-DirectorySnapshot -Root $stageRoot) -cne $markerSnapshot) {
            throw 'Native renderer-marker rejection mutated the diagnostic-log stage.'
        }
        $nativeRendererMarkersRejected = $true
    }

    foreach ($inputPath in $protectedInputs) {
        if ((Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash -cne $protectedHashes[$inputPath]) {
            throw "Protected camera diagnostic input changed during verification: $inputPath"
        }
    }

    [pscustomobject]@{
        Status                            = 'PASS'
        FullySelfConsistentForgeryRejected = $true
        RealCameraPackageAvailable         = $realCameraPackageAvailable
        RealCameraPackageValidated         = $cameraPackageValidated
        RealCameraStageValidated           = $cameraStageValidated
        RtxCrossProductAvailable            = $rtxCrossProductAvailable
        RtxCrossProductValidated            = $rtxCrossProductValidated
        RtxCrossProductRuntimeConfigPreserved = $rtxCrossProductRuntimeConfigPreserved
        RemixDiagnosticsCombinationRejected = $true
        CameraLabPresetMappingVerified     = $true
        StableModernRtxMappingsPreserved   = $true
        Fixed60FpsPolicyVerified           = $true
        SourceCvarOwnedByLauncher           = $true
        NativeRendererMarkersRejected      = $nativeRendererMarkersRejected
        StageOwnershipTamperRejected       = $stageOwnershipTamperRejected
        DiagnosticLogsPreservedOnRerun     = $diagnosticLogsPreserved
        RuntimeLaunched                    = $false
    }
}
finally {
    foreach ($path in $cleanupPaths) {
        $resolvedPath = [IO.Path]::GetFullPath($path)
        if ((Test-Path -LiteralPath $resolvedPath) -and
            $resolvedPath.StartsWith($localRuntimeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedPath -Recurse -Force
        }
    }
}
