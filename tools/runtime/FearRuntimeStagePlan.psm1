Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRendererPackage.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearEnginePatchPackage.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearPostProcessPackage.psm1') -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearControllerPackage.psm1') -ErrorAction Stop

function Assert-FearRuntimeStagePackageSelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Rebuilt', 'StockEchoPatch', 'SdkSmoke')]
        [string]$Lane,

        [bool]$ControllerArchiveSpecified = $false,

        [Parameter(Mandatory = $true)]
        [ValidateSet('NativeD3D9', 'DgVoodooD3D11', 'RtxRemixProbe')]
        [string]$RendererMode,

        [ValidateSet('Native', 'Max2x')]
        [string]$RendererQuality = 'Native',
        [bool]$RendererQualitySpecified = $false,

        [Parameter(Mandatory = $true)][bool]$DgVoodooArchiveSpecified,
        [Parameter(Mandatory = $true)][bool]$RtxRemixArchiveSpecified,

        [Parameter(Mandatory = $true)]
        [ValidateSet('None', 'ReShadeCas')]
        [string]$PostProcessMode,
        [Parameter(Mandatory = $true)][bool]$ReShadeSetupSpecified,

        [Parameter(Mandatory = $true)]
        [ValidateSet('None', 'EngineOnlyEchoPatch', 'RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')]
        [string]$EnginePatchMode,

        [Parameter(Mandatory = $true)][bool]$EnginePatchPackageRootSpecified,
        [Parameter(Mandatory = $true)][bool]$EnginePatchManifestSpecified,
        [Parameter(Mandatory = $true)][bool]$MaxFPSExplicit
    )

    if ($Lane -ne 'Rebuilt' -and $ControllerArchiveSpecified) {
        throw '-ControllerArchive is supported only by -Lane Rebuilt.'
    }
    if ($RendererMode -ne 'NativeD3D9' -and $Lane -ne 'Rebuilt') {
        throw "-RendererMode $RendererMode is supported only by -Lane Rebuilt. StockEchoPatch and SdkSmoke remain isolated control/diagnostic lanes."
    }
    if ($EnginePatchMode -ne 'None' -and $Lane -ne 'Rebuilt') {
        throw "-EnginePatchMode $EnginePatchMode is supported only by -Lane Rebuilt."
    }
    if ($PostProcessMode -ne 'None' -and $Lane -ne 'Rebuilt') {
        throw "-PostProcessMode $PostProcessMode is supported only by -Lane Rebuilt."
    }
    if ($PostProcessMode -eq 'ReShadeCas' -and $RendererMode -ne 'DgVoodooD3D11') {
        throw '-PostProcessMode ReShadeCas requires -RendererMode DgVoodooD3D11 so ReShade can target the translated DXGI output.'
    }
    if ($PostProcessMode -eq 'None' -and $ReShadeSetupSpecified) {
        throw '-ReShadeSetup requires -PostProcessMode ReShadeCas.'
    }
    if ($RendererMode -ne 'DgVoodooD3D11' -and $DgVoodooArchiveSpecified) {
        throw '-DgVoodooArchive requires -RendererMode DgVoodooD3D11.'
    }
    if ($RendererMode -ne 'DgVoodooD3D11' -and
        ($RendererQualitySpecified -or $RendererQuality -ne 'Native')) {
        throw '-RendererQuality requires -RendererMode DgVoodooD3D11.'
    }
    if ($RendererMode -ne 'RtxRemixProbe' -and $RtxRemixArchiveSpecified) {
        throw '-RtxRemixArchive requires -RendererMode RtxRemixProbe.'
    }
    if ($RendererMode -eq 'RtxRemixProbe' -and
        $EnginePatchMode -notin @('RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')) {
        throw 'RtxRemixProbe requires a separately pinned camera-diagnostic EchoPatch derivative; None and ordinary engine-only EchoPatch are not valid RTX lab configurations.'
    }
    if ($EnginePatchMode -eq 'RemixDiagnosticEchoPatch' -and $RendererMode -ne 'RtxRemixProbe') {
        throw 'RemixDiagnosticEchoPatch is a developer-only camera probe and requires -RendererMode RtxRemixProbe.'
    }
    if ($EnginePatchMode -eq 'CameraDiagnosticEchoPatch' -and
        $RendererMode -notin @('NativeD3D9', 'RtxRemixProbe')) {
        throw 'CameraDiagnosticEchoPatch is a query-light D3D9 diagnostic and requires -RendererMode NativeD3D9 or RtxRemixProbe.'
    }
    if ($EnginePatchMode -eq 'RtxCameraDiagnosticEchoPatch' -and $RendererMode -ne 'RtxRemixProbe') {
        throw 'RtxCameraDiagnosticEchoPatch is an RTX-only focus-preserving camera diagnostic and requires -RendererMode RtxRemixProbe.'
    }
    if ($EnginePatchMode -eq 'RtxCameraReassertionEchoPatch' -and $RendererMode -ne 'RtxRemixProbe') {
        throw 'RtxCameraReassertionEchoPatch is an RTX-only bounded camera-state experiment and requires -RendererMode RtxRemixProbe.'
    }
    if ($EnginePatchMode -eq 'None' -and
        ($EnginePatchPackageRootSpecified -or $EnginePatchManifestSpecified -or $MaxFPSExplicit)) {
        throw '-EnginePatchPackageRoot, -EnginePatchManifest, and -MaxFPS require an explicit EchoPatch engine-patch mode.'
    }
    if ($EnginePatchMode -in @('RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch') -and $MaxFPSExplicit) {
        throw "-MaxFPS is not configurable for $EnginePatchMode; its bounded lab profile remains at 60 FPS."
    }
}

function Resolve-FearRuntimeStagePackagePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Rebuilt', 'StockEchoPatch', 'SdkSmoke')]
        [string]$Lane,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Release', 'Debug')]
        [string]$Configuration,

        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][string]$RuntimeToolsRoot,
        [AllowNull()][string]$ControllerArchive,
        [bool]$ControllerArchiveSpecified = $false,

        [Parameter(Mandatory = $true)]
        [ValidateSet('NativeD3D9', 'DgVoodooD3D11', 'RtxRemixProbe')]
        [string]$RendererMode,

        [ValidateSet('Native', 'Max2x')]
        [string]$RendererQuality = 'Native',
        [bool]$RendererQualitySpecified = $false,

        [AllowNull()][string]$DgVoodooArchive,
        [Parameter(Mandatory = $true)][bool]$DgVoodooArchiveSpecified,
        [AllowNull()][string]$RtxRemixArchive,
        [Parameter(Mandatory = $true)][bool]$RtxRemixArchiveSpecified,

        [Parameter(Mandatory = $true)]
        [ValidateSet('None', 'ReShadeCas')]
        [string]$PostProcessMode,
        [AllowNull()][string]$ReShadeSetup,
        [Parameter(Mandatory = $true)][bool]$ReShadeSetupSpecified,

        [Parameter(Mandatory = $true)]
        [ValidateSet('None', 'EngineOnlyEchoPatch', 'RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')]
        [string]$EnginePatchMode,

        [AllowNull()][string]$EnginePatchPackageRoot,
        [Parameter(Mandatory = $true)][bool]$EnginePatchPackageRootSpecified,
        [AllowNull()][string]$EnginePatchManifest,
        [Parameter(Mandatory = $true)][bool]$EnginePatchManifestSpecified,

        [Parameter(Mandatory = $true)]
        [ValidateRange(30.0, 300.0)]
        [double]$MaxFPS,
        [Parameter(Mandatory = $true)][bool]$MaxFPSExplicit
    )

    Assert-FearRuntimeStagePackageSelection `
        -Lane $Lane `
        -ControllerArchiveSpecified:($ControllerArchiveSpecified -or -not [string]::IsNullOrWhiteSpace($ControllerArchive)) `
        -RendererMode $RendererMode `
        -RendererQuality $RendererQuality `
        -RendererQualitySpecified:$RendererQualitySpecified `
        -DgVoodooArchiveSpecified:$DgVoodooArchiveSpecified `
        -RtxRemixArchiveSpecified:$RtxRemixArchiveSpecified `
        -PostProcessMode $PostProcessMode `
        -ReShadeSetupSpecified:$ReShadeSetupSpecified `
        -EnginePatchMode $EnginePatchMode `
        -EnginePatchPackageRootSpecified:$EnginePatchPackageRootSpecified `
        -EnginePatchManifestSpecified:$EnginePatchManifestSpecified `
        -MaxFPSExplicit:$MaxFPSExplicit

    $resolvedDgVoodooArchive = $null
    $resolvedRtxRemixArchive = $null
    $rendererConfigSource = $null
    $rendererRequiredFiles = @()
    $rendererRequiredDirectories = @()
    $rendererForbiddenPaths = @()
    $rendererImmutableTreeRoots = @()
    $rendererRuntimeWritableDirectories = @()
    $rendererRuntimeMutableFiles = @()
    $rendererRuntimeConfigSeedSource = $null
    $rendererProxyFile = $null
    $rendererConfigFile = $null
    $rendererExperimental = $false
    $rendererCompatibilityStatus = 'NotApplicable'
    $rendererStageSuffix = ''
    $resolvedControllerArchive = $null
    $controllerRequiredFiles = @()
    $controllerManagedFiles = @()
    $controllerManagedDirectories = @()
    if ($Lane -eq 'Rebuilt') {
        if (-not $ControllerArchive) {
            $ControllerArchive = Get-FearControllerPackageDefaultArchivePath -RepositoryRoot $RepositoryRoot
        }
        $resolvedControllerArchive = Get-FearCanonicalPath -Path $ControllerArchive -BasePath $RepositoryRoot
        $controllerRequiredFiles = @('SDL3.dll', '.fearmore\licenses\SDL3-zlib.txt')
        $controllerManagedFiles = @($controllerRequiredFiles)
        $controllerManagedDirectories = @('.fearmore', '.fearmore\licenses')
    }

    $postProcessAssetRoot = Join-Path $RuntimeToolsRoot 'postprocess'
    $postProcessAssetFiles = @(
        '.fearmore\postprocess\config\FearMore-CAS.seed.ini',
        '.fearmore\postprocess\config\ReShade.seed.ini',
        '.fearmore\postprocess\licenses\AMD-CAS-MIT.txt',
        '.fearmore\postprocess\licenses\ReShade-BSD-3-Clause.txt',
        '.fearmore\postprocess\Shaders\FearMoreCAS.fx'
    )
    $postProcessImmutableFiles = @('dxgi.dll') + $postProcessAssetFiles
    $postProcessRuntimeMutableFiles = @('ReShade.ini', 'FearMore-CAS.ini', 'ReShade.log')
    $postProcessRuntimeWritableDirectories = @('.fearmore\postprocess\Cache')
    $postProcessSeedFiles = @(
        [pscustomobject]@{ TargetRelativePath = 'ReShade.ini'; SourceAssetRelativePath = 'config\ReShade.seed.ini' },
        [pscustomobject]@{ TargetRelativePath = 'FearMore-CAS.ini'; SourceAssetRelativePath = 'config\FearMore-CAS.seed.ini' }
    )
    $postProcessManagedFiles = @($postProcessImmutableFiles) + @($postProcessSeedFiles.TargetRelativePath)
    $postProcessManagedDirectories = @(
        '.fearmore',
        '.fearmore\postprocess',
        '.fearmore\postprocess\config',
        '.fearmore\postprocess\licenses',
        '.fearmore\postprocess\Shaders'
    )
    $resolvedReShadeSetup = $null
    if ($PostProcessMode -eq 'ReShadeCas') {
        if (-not $ReShadeSetup) {
            $ReShadeSetup = Join-Path $RepositoryRoot 'vendor-local\postprocess-deps\ReShade_Setup_6.7.3.exe'
        }
        $resolvedReShadeSetup = Get-FearCanonicalPath -Path $ReShadeSetup -BasePath $RepositoryRoot
    }

    switch ($RendererMode) {
        'NativeD3D9' {
            $rendererForbiddenPaths = @(
                'd3d9.dll',
                'dgVoodoo.conf',
                'd3d8to9.dll',
                'NvRemixLauncher32.exe',
                '.trex',
                'rtx-remix',
                'rtx.conf'
            )
        }
        'DgVoodooD3D11' {
            if (-not $DgVoodooArchive) {
                $DgVoodooArchive = Join-Path $RepositoryRoot 'vendor-local\renderer-deps\dgVoodoo2_87_3.zip'
            }
            $resolvedDgVoodooArchive = Get-FearCanonicalPath -Path $DgVoodooArchive -BasePath $RepositoryRoot
            $rendererCompatibilityStatus = 'LiveAcceptedDgVoodooD3D11'
            $rendererConfigSource = if ($RendererQuality -eq 'Max2x') {
                Join-Path $RuntimeToolsRoot 'config\dgVoodoo-d3d11-max2x.conf'
            }
            else {
                Join-Path $RuntimeToolsRoot 'config\dgVoodoo-d3d11.conf'
            }
            $rendererRequiredFiles = @('d3d9.dll', 'dgVoodoo.conf')
            $rendererForbiddenPaths = @('d3d8to9.dll', 'NvRemixLauncher32.exe', '.trex', 'rtx-remix', 'rtx.conf')
            $rendererProxyFile = 'd3d9.dll'
            $rendererConfigFile = 'dgVoodoo.conf'
            $rendererStageSuffix = if ($RendererQuality -eq 'Max2x') {
                '-dgvoodoo-d3d11-max2x'
            }
            else {
                '-dgvoodoo-d3d11'
            }
        }
        'RtxRemixProbe' {
            if (-not $RtxRemixArchive) {
                $RtxRemixArchive = Join-Path $RepositoryRoot 'vendor-local\renderer-deps\remix-1.5.2-release.zip'
            }
            $resolvedRtxRemixArchive = Get-FearCanonicalPath -Path $RtxRemixArchive -BasePath $RepositoryRoot
            $rendererConfigSource = Join-Path $RuntimeToolsRoot 'config\rtx-remix-bridge.conf'
            $rendererRequiredFiles = @('d3d9.dll', 'd3d8to9.dll', 'NvRemixLauncher32.exe', '.trex\bridge.conf')
            $rendererRequiredDirectories = @('.trex', 'rtx-remix')
            $rendererForbiddenPaths = @('dgVoodoo.conf')
            $rendererImmutableTreeRoots = @('.trex')
            $rendererRuntimeWritableDirectories = @('rtx-remix')
            $rendererRuntimeMutableFiles = @('rtx.conf')
            $rendererRuntimeConfigSeedSource = Join-Path $RuntimeToolsRoot 'config\rtx-remix-runtime.conf'
            $rendererProxyFile = 'd3d9.dll'
            $rendererConfigFile = '.trex\bridge.conf'
            $rendererExperimental = $true
            $rendererCompatibilityStatus = 'UnverifiedProbe'
            $rendererStageSuffix = '-rtx-remix-probe-1-5-2'
        }
    }

    $resolvedEnginePatchPackageRoot = $null
    $resolvedEnginePatchManifest = $null
    $enginePatchRequiredFiles = @()
    $enginePatchForbiddenFiles = @()
    $enginePatchStageSuffix = ''
    if ($EnginePatchMode -in @('EngineOnlyEchoPatch', 'RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')) {
        if (-not $EnginePatchPackageRoot) {
            $EnginePatchPackageRoot = switch ($EnginePatchMode) {
                'RemixDiagnosticEchoPatch' {
                    Join-Path $RepositoryRoot 'vendor-local\echopatch-remix-diagnostics\local-package-b4a7074e4cbb'
                }
                'CameraDiagnosticEchoPatch' {
                    Join-Path $RepositoryRoot 'vendor-local\echopatch-camera-diagnostics\local-package-b4a7074e4cbb'
                }
                'RtxCameraDiagnosticEchoPatch' {
                    Join-Path $RepositoryRoot 'vendor-local\echopatch-rtx-camera-diagnostics\local-package-b4a7074e4cbb'
                }
                'RtxCameraReassertionEchoPatch' {
                    Join-Path $RepositoryRoot 'vendor-local\echopatch-rtx-camera-reassertion\local-package-b4a7074e4cbb'
                }
                default {
                    Join-Path $RepositoryRoot 'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb'
                }
            }
        }
        if (-not $EnginePatchManifest) {
            $EnginePatchManifest = switch ($EnginePatchMode) {
                'RemixDiagnosticEchoPatch' {
                    Join-Path $RepositoryRoot 'vendor-local\echopatch-remix-diagnostics\manifest-b4a7074e4cbb.json'
                }
                'CameraDiagnosticEchoPatch' {
                    Join-Path $RepositoryRoot 'vendor-local\echopatch-camera-diagnostics\manifest-b4a7074e4cbb.json'
                }
                'RtxCameraDiagnosticEchoPatch' {
                    Join-Path $RepositoryRoot 'vendor-local\echopatch-rtx-camera-diagnostics\manifest-b4a7074e4cbb.json'
                }
                'RtxCameraReassertionEchoPatch' {
                    Join-Path $RepositoryRoot 'vendor-local\echopatch-rtx-camera-reassertion\manifest-b4a7074e4cbb.json'
                }
                default {
                    Join-Path $RepositoryRoot 'vendor-local\echopatch-engine-only\manifest-b4a7074e4cbb.json'
                }
            }
        }
        $resolvedEnginePatchPackageRoot = Get-FearCanonicalPath -Path $EnginePatchPackageRoot -BasePath $RepositoryRoot
        $resolvedEnginePatchManifest = Get-FearCanonicalPath -Path $EnginePatchManifest -BasePath $RepositoryRoot
        $enginePatchRequiredFiles = @('dinput8.dll', 'EchoPatch.ini')
        $enginePatchStageSuffix = switch ($EnginePatchMode) {
            'RemixDiagnosticEchoPatch' { '-remix-camera-diagnostics' }
            'CameraDiagnosticEchoPatch' { '-camera-diagnostics' }
            'RtxCameraDiagnosticEchoPatch' { '-rtx-camera-diagnostics-focus-preserved' }
            'RtxCameraReassertionEchoPatch' { '-rtx-camera-reassertion-focus-preserved' }
            default { '-engine-only-echopatch' }
        }
    }
    elseif ($Lane -in @('Rebuilt', 'SdkSmoke')) {
        $enginePatchForbiddenFiles = @('dinput8.dll', 'EchoPatch.ini')
    }

    $defaultStageDirectoryName = switch ($Lane) {
        'StockEchoPatch' { 'fearmore-stock-echopatch' }
        'SdkSmoke'       { "fearmore-sdk-smoke-$($Configuration.ToLowerInvariant())" }
        default          {
            "fearmore-rebuilt-$($Configuration.ToLowerInvariant())$rendererStageSuffix$enginePatchStageSuffix"
        }
    }

    return [pscustomobject]@{
		ControllerArchive                    = $resolvedControllerArchive
		ControllerRequiredFiles              = @($controllerRequiredFiles)
		ControllerManagedFiles               = @($controllerManagedFiles)
		ControllerManagedDirectories         = @($controllerManagedDirectories)
        RendererMode                       = $RendererMode
        RendererQuality                    = if ($RendererMode -eq 'DgVoodooD3D11') { $RendererQuality } else { $null }
        DgVoodooArchive                    = $resolvedDgVoodooArchive
        RtxRemixArchive                    = $resolvedRtxRemixArchive
        RendererConfigSource               = $rendererConfigSource
        RendererProxyFile                  = $rendererProxyFile
        RendererConfigFile                 = $rendererConfigFile
        RendererRequiredFiles              = @($rendererRequiredFiles)
        RendererRequiredDirectories        = @($rendererRequiredDirectories)
        RendererForbiddenPaths             = @($rendererForbiddenPaths)
        RendererImmutableTreeRoots         = @($rendererImmutableTreeRoots)
        RendererRuntimeWritableDirectories = @($rendererRuntimeWritableDirectories)
        RendererRuntimeMutableFiles        = @($rendererRuntimeMutableFiles)
        RendererRuntimeConfigSeedSource     = $rendererRuntimeConfigSeedSource
        RendererExperimental               = $rendererExperimental
        RendererCompatibilityStatus        = $rendererCompatibilityStatus
        PostProcessMode                    = $PostProcessMode
        PostProcessSetup                   = $resolvedReShadeSetup
        PostProcessAssetRoot               = $postProcessAssetRoot
        PostProcessRequiredFiles           = if ($PostProcessMode -eq 'ReShadeCas') { @($postProcessImmutableFiles) } else { @() }
        PostProcessForbiddenFiles          = if ($PostProcessMode -eq 'None') { @($postProcessImmutableFiles) } else { @() }
        PostProcessImmutableFiles          = @($postProcessImmutableFiles)
        PostProcessAssetFiles              = @($postProcessAssetFiles)
        PostProcessRuntimeMutableFiles     = @($postProcessRuntimeMutableFiles)
        PostProcessRuntimeWritableDirectories = @($postProcessRuntimeWritableDirectories)
        PostProcessSeedFiles               = @($postProcessSeedFiles)
        PostProcessManagedFiles             = @($postProcessManagedFiles | Sort-Object -Unique)
        PostProcessManagedDirectories       = @($postProcessManagedDirectories)
        PostProcessExperimental             = $false
        PostProcessCompatibilityStatus      = if ($PostProcessMode -eq 'ReShadeCas') { 'LiveAcceptedDgVoodooDxgiChain' } else { 'NotApplicable' }
        EnginePatchMode                    = $EnginePatchMode
        EnginePatchPackageRoot             = $resolvedEnginePatchPackageRoot
        EnginePatchManifest                = $resolvedEnginePatchManifest
        EnginePatchRequiredFiles           = @($enginePatchRequiredFiles)
        EnginePatchForbiddenFiles          = @($enginePatchForbiddenFiles)
        # RTX Remix must agree with LithTech about presentation mode. EchoPatch
        # owns F.E.A.R.'s real Windowed CVar for RTX lanes; the Bridge consumes
        # those presentation parameters without independently rewriting them.
        EnginePatchForceWindowed            = $EnginePatchMode -ne 'None' -and $RendererMode -eq 'RtxRemixProbe'
        EnginePatchFixWindowStyle           = $EnginePatchMode -ne 'None'
        MaxFPS                             = if ($EnginePatchMode -eq 'EngineOnlyEchoPatch') {
            $MaxFPS
        }
        elseif ($EnginePatchMode -in @('RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')) {
            60.0
        }
        else {
            $null
        }
        MaxFPSExplicit                     = $MaxFPSExplicit
        DynamicVsync                       = if ($EnginePatchMode -eq 'EngineOnlyEchoPatch') {
            if ($MaxFPSExplicit) { 0 } else { 1 }
        }
        elseif ($EnginePatchMode -in @('RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')) {
            1
        }
        else {
            $null
        }
        DefaultStageDirectoryName          = $defaultStageDirectoryName
    }
}

function Get-FearRebuiltStageMutationRelativePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('NativeD3D9', 'DgVoodooD3D11', 'RtxRemixProbe')]
        [string]$RendererMode,
        [AllowNull()]$RendererPackageIdentity,
        [AllowNull()][string]$RendererConfigFile,
        [Parameter(Mandatory = $true)]
        [ValidateSet('None', 'EngineOnlyEchoPatch', 'RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')]
        [string]$EnginePatchMode,
        [string[]]$PostProcessManagedFiles = @(),
		[string[]]$ControllerManagedFiles = @(),
        [Parameter(Mandatory = $true)][string[]]$GameModuleNames
    )

    # This is the complete ordinary-file write/remove surface of the Rebuilt
    # mutation block. The write orchestrator snapshots it before the first
    # mutation so a late manifest failure cannot leave new bytes owned by the
    # old manifest.
    $relativePaths = @(
        'FEAR.exe',
        'Default.archcfg',
        'EngineServer.dll',
        'GameDatabase.dll',
        'LTMemory.dll',
        'SndDrv.dll',
        'StringEditRuntime.dll',
        'binkw32.dll',
        'eax.dll',
        'msvcp71.dll',
        'msvcr71.dll',
        'MFC71.dll',
        'MFC71u.dll',
        'enginemsg.txt',
        'gamecfg.txt',
        'Config.Strdb00p',
        'FEARDevSP.exe',
        'AssertWin32DLL.dll',
        'FEAR.proj00'
    )
    $relativePaths += @($GameModuleNames | ForEach-Object { "Game\$_" })

    if ($RendererMode -eq 'DgVoodooD3D11') {
        $relativePaths += @('d3d9.dll', 'dgVoodoo.conf')
    }
    elseif ($RendererMode -eq 'RtxRemixProbe') {
        if (-not $RendererPackageIdentity) {
            throw 'RTX Remix mutation planning requires a validated package identity.'
        }
        if ([string]::IsNullOrWhiteSpace($RendererConfigFile)) {
            throw 'RTX Remix mutation planning requires the owned Bridge config path.'
        }
        $relativePaths += @($RendererPackageIdentity.Files | ForEach-Object { [string]$_.RelativePath })
        $relativePaths += @($RendererConfigFile, 'rtx.conf')
    }

    if ($EnginePatchMode -in @('EngineOnlyEchoPatch', 'RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')) {
        $relativePaths += @('dinput8.dll', 'EchoPatch.ini')
    }

    $relativePaths += @($PostProcessManagedFiles)
	$relativePaths += @($ControllerManagedFiles)

    return @($relativePaths | Sort-Object -Unique)
}

function Get-FearRuntimeStagePackageIdentities {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('NativeD3D9', 'DgVoodooD3D11', 'RtxRemixProbe')]
        [string]$RendererMode,
        [ValidateSet('Native', 'Max2x')]
        [string]$RendererQuality = 'Native',
        [AllowNull()][string]$DgVoodooArchive,
        [AllowNull()][string]$RtxRemixArchive,
        [AllowNull()][string]$RendererConfigSource,
        [AllowNull()][string]$RendererRuntimeConfigSeedSource,

        [Parameter(Mandatory = $true)]
        [ValidateSet('None', 'ReShadeCas')]
        [string]$PostProcessMode,
        [AllowNull()][string]$PostProcessSetup,
        [AllowNull()][string]$PostProcessAssetRoot,
		[AllowNull()][string]$ControllerArchive,

        [Parameter(Mandatory = $true)]
        [ValidateSet('None', 'EngineOnlyEchoPatch', 'RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')]
        [string]$EnginePatchMode,
        [AllowNull()][string]$EnginePatchPackageRoot,
        [AllowNull()][string]$EnginePatchManifest
    )

    $rendererPackageIdentity = $null
    $rendererConfigIdentity = $null
    $rendererRuntimeConfigSeedIdentity = $null
    $enginePatchPackageIdentity = $null
    $postProcessPackageIdentity = $null
    $postProcessStagePayload = $null
	$controllerPackageIdentity = $null

    if ($RendererMode -eq 'DgVoodooD3D11') {
        $rendererPackageIdentity = Get-FearDgVoodooPackageIdentity -ArchivePath $DgVoodooArchive
        $rendererConfigIdentity = Get-FearDgVoodooConfigIdentity -Path $RendererConfigSource -RendererQuality $RendererQuality
    }
    elseif ($RendererMode -eq 'RtxRemixProbe') {
        $rendererPackageIdentity = Get-FearRtxRemixPackageIdentity -ArchivePath $RtxRemixArchive
        $rendererConfigIdentity = Get-FearRtxRemixBridgeConfigIdentity -Path $RendererConfigSource
        $rendererRuntimeConfigSeedIdentity = Get-FearRtxRemixRuntimeConfigSeedIdentity -Path $RendererRuntimeConfigSeedSource
    }

    if ($PostProcessMode -eq 'ReShadeCas') {
        $postProcessStagePayload = Get-FearPostProcessPackageStagePayload `
            -SetupPath $PostProcessSetup `
            -AssetRoot $PostProcessAssetRoot
        $postProcessPackageIdentity = $postProcessStagePayload.PackageIdentity
    }

	if ($ControllerArchive) {
		$controllerPackageIdentity = Get-FearControllerPackageStagePayload -ArchivePath $ControllerArchive
	}

    if ($EnginePatchMode -eq 'EngineOnlyEchoPatch') {
        $enginePatchPackageIdentity = Get-FearEngineOnlyEchoPatchPackageIdentity `
            -PackageRoot $EnginePatchPackageRoot `
            -ManifestPath $EnginePatchManifest
    }
    elseif ($EnginePatchMode -eq 'RemixDiagnosticEchoPatch') {
        $enginePatchPackageIdentity = Get-FearRemixDiagnosticEchoPatchPackageIdentity `
            -PackageRoot $EnginePatchPackageRoot `
            -ManifestPath $EnginePatchManifest
    }
    elseif ($EnginePatchMode -eq 'CameraDiagnosticEchoPatch') {
        $enginePatchPackageIdentity = Get-FearCameraDiagnosticEchoPatchPackageIdentity `
            -PackageRoot $EnginePatchPackageRoot `
            -ManifestPath $EnginePatchManifest
    }
    elseif ($EnginePatchMode -eq 'RtxCameraDiagnosticEchoPatch') {
        $enginePatchPackageIdentity = Get-FearRtxCameraDiagnosticEchoPatchPackageIdentity `
            -PackageRoot $EnginePatchPackageRoot `
            -ManifestPath $EnginePatchManifest
    }
    elseif ($EnginePatchMode -eq 'RtxCameraReassertionEchoPatch') {
        $enginePatchPackageIdentity = Get-FearRtxCameraReassertionEchoPatchPackageIdentity `
            -PackageRoot $EnginePatchPackageRoot `
            -ManifestPath $EnginePatchManifest
    }

    return [pscustomobject]@{
        RendererPackageIdentity  = $rendererPackageIdentity
        RendererConfigIdentity   = $rendererConfigIdentity
        RendererRuntimeConfigSeedIdentity = $rendererRuntimeConfigSeedIdentity
        PostProcessPackageIdentity = $postProcessPackageIdentity
        PostProcessStagePayload    = $postProcessStagePayload
		ControllerPackageIdentity   = $controllerPackageIdentity
        EnginePatchPackageIdentity = $enginePatchPackageIdentity
    }
}

Export-ModuleMember -Function Assert-FearRuntimeStagePackageSelection, Resolve-FearRuntimeStagePackagePlan, Get-FearRebuiltStageMutationRelativePaths, Get-FearRuntimeStagePackageIdentities
