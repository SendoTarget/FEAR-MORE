[CmdletBinding(PositionalBinding = $false)]
param(
    [ValidateSet('Stable', 'Modern', 'RtxLab', 'RtxBridgeLab', 'CameraLab')]
    [string]$Preset = 'Modern',

    [ValidateRange(30.0, 300.0)]
    [double]$MaxFPS = 144.0,

    [ValidateRange(640, 16384)]
    [int]$Width,

    [ValidateRange(480, 8640)]
    [int]$Height,

    [ValidateSet('Native', 'Max2x')]
    [string]$RendererQuality,

    [ValidateSet('None', 'ReShadeCas')]
    [string]$PostProcessMode,

    [string]$RetailRoot,
    [string]$StageRoot,
    [string]$HdTexturePackRoot,
    [string]$SteamExecutable,

    [switch]$PrepareOnly,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$LaunchArguments = @()
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FearLauncherProfile.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearLauncherSettings.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearControllerPackage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearPostProcessPackage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeLayout.psm1') -Force -ErrorAction Stop
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$runtimeLayout = Resolve-FearRuntimeLayout -SourceRoot $repositoryRoot
$repositoryRoot = $runtimeLayout.SourceRoot
if ($runtimeLayout.LayoutKind -eq 'Packaged' -and $Preset -notin @('Stable', 'Modern')) {
    throw "The private FearMore owner package supports only -Preset Stable and -Preset Modern. '$Preset' remains a developer-checkout diagnostic preset."
}
$rtxPreset = $Preset -in @('RtxLab', 'RtxBridgeLab')
if ($rtxPreset) {
    Import-Module (Join-Path $PSScriptRoot 'FearSteamLaunch.psm1') -Force -ErrorAction Stop
}

function Invoke-FearMoreStageWorkflow {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [Parameter(Mandatory = $true)][hashtable]$Parameters,
        [hashtable]$ProcessEnvironment = @{}
    )

    $savedEnvironment = @{}
    try {
        foreach ($entry in $ProcessEnvironment.GetEnumerator()) {
            $savedEnvironment[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
            [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
        }
        $stageResults = @(& $ScriptPath @Parameters)
    }
    finally {
        foreach ($entry in $savedEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
        }
    }
    if ($stageResults.Count -ne 1) {
        throw "The runtime staging workflow returned $($stageResults.Count) results; exactly one completed stage was expected."
    }
    $stageResult = $stageResults[0]
    if (-not $stageResult.LayoutValidated -or -not $stageResult.InputsValidated) {
        throw 'The runtime staging workflow did not report a completed, validated layout.'
    }
    return $stageResult
}

$widthExplicit = $PSBoundParameters.ContainsKey('Width')
$heightExplicit = $PSBoundParameters.ContainsKey('Height')
if ($widthExplicit -ne $heightExplicit) {
    throw '-Width and -Height must be supplied together.'
}
if ($Preset -ne 'Modern' -and $PSBoundParameters.ContainsKey('MaxFPS')) {
    throw '-MaxFPS applies only to Modern; Stable has no limiter owner and the CameraLab/RTX diagnostic profiles are fixed at 60 FPS.'
}
if ($Preset -ne 'Modern' -and $PSBoundParameters.ContainsKey('RendererQuality')) {
    throw '-RendererQuality applies only to the Modern D3D11-wrapper preset.'
}
if ($Preset -ne 'Modern' -and $PSBoundParameters.ContainsKey('PostProcessMode')) {
    throw '-PostProcessMode applies only to the Modern D3D11-wrapper preset.'
}
if (-not $rtxPreset -and $PSBoundParameters.ContainsKey('SteamExecutable')) {
    throw '-SteamExecutable applies only to the RTX presets, whose validated launch transport is the registered retail installation through Steam.'
}

$runtimeRoot = $runtimeLayout.RuntimeRoot
$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
$controllerAcquisitionScript = Join-Path $PSScriptRoot 'Get-FearControllerRuntime.ps1'
$postProcessAcquisitionScript = Join-Path $PSScriptRoot 'Get-FearPostProcessRuntime.ps1'
$retailSidecarInstaller = Join-Path $PSScriptRoot 'Install-FearMoreRetailSidecars.ps1'
if (-not (Test-Path -LiteralPath $stageScript -PathType Leaf)) {
    throw "The runtime staging primitive is missing: $stageScript"
}
if (-not (Test-Path -LiteralPath $controllerAcquisitionScript -PathType Leaf)) {
    throw "The guarded SDL3 controller-runtime acquisition primitive is missing: $controllerAcquisitionScript"
}
if (-not (Test-Path -LiteralPath $postProcessAcquisitionScript -PathType Leaf)) {
    throw "The guarded ReShade acquisition primitive is missing: $postProcessAcquisitionScript"
}
if ($rtxPreset -and -not (Test-Path -LiteralPath $retailSidecarInstaller -PathType Leaf)) {
    throw "The guarded retail-sidecar installer is missing: $retailSidecarInstaller"
}

$controllerArchive = Get-FearControllerPackageDefaultArchivePath -RepositoryRoot $repositoryRoot
if (-not (Test-Path -LiteralPath $controllerArchive -PathType Leaf)) {
    if ($runtimeLayout.LayoutKind -eq 'Packaged') {
        throw "The packaged FearMore payload is incomplete: the pinned SDL3 x86 archive is missing: $controllerArchive"
    }
    Write-Host 'Acquiring the pinned official SDL3 x86 controller runtime...'
    $controllerResults = @(& $controllerAcquisitionScript `
            -RepositoryRoot $repositoryRoot `
            -ArchivePath $controllerArchive `
            -Confirm:$false)
    if ($controllerResults.Count -ne 1) {
        throw "The controller-runtime acquisition workflow returned $($controllerResults.Count) results; exactly one validated package was expected."
    }
}
$controllerIdentity = Get-FearControllerPackageStagePayload -ArchivePath $controllerArchive

$stageParameters = @{
    Lane             = 'Rebuilt'
    Configuration    = 'Release'
    RepositoryRoot   = $repositoryRoot
    ControllerArchive = $controllerIdentity.ArchivePath
}
switch ($Preset) {
    'Stable' {
        $stageParameters.RendererMode = 'NativeD3D9'
        $stageParameters.EnginePatchMode = 'None'
    }
    'Modern' {
        $stageParameters.RendererMode = 'DgVoodooD3D11'
        $stageParameters.EnginePatchMode = 'EngineOnlyEchoPatch'
        $stageParameters.MaxFPS = $MaxFPS
    }
    'RtxLab' {
        $stageParameters.RendererMode = 'RtxRemixProbe'
        $stageParameters.EnginePatchMode = 'RtxCameraDiagnosticEchoPatch'
        Write-Warning 'RtxLab is a parked, unverified RTX Remix experiment. Its dedicated EchoPatch flavor preserves native focus, input, and sound events while bypassing only F.E.A.R.''s verified renderer terminate/reinitialize calls during focus changes; it makes no claim of working path tracing, visual completeness, stability, or performance.'
    }
    'RtxBridgeLab' {
        $stageParameters.RendererMode = 'RtxRemixProbe'
        $stageParameters.EnginePatchMode = 'RtxCameraReassertionEchoPatch'
        Write-Warning 'RtxBridgeLab is a parked, unverified causal experiment. It waits fail-closed for up to 300 wall-clock seconds, then runs a 300-frame window that reasserts unchanged, numerically validated D3D9 camera transforms only before exact F7D91705 world-shader draws; this mechanism makes no renderer-compatibility claim.'
    }
    'CameraLab' {
        $stageParameters.RendererMode = 'NativeD3D9'
        $stageParameters.EnginePatchMode = 'CameraDiagnosticEchoPatch'
        Write-Warning 'CameraLab is a bounded developer diagnostic. It captures native D3D9 shader camera constants without changing renderer behavior.'
    }
}
if ($PSBoundParameters.ContainsKey('RetailRoot')) {
    $stageParameters.RetailRoot = $RetailRoot
}
if ($PSBoundParameters.ContainsKey('StageRoot')) {
    $requestedStageRoot = if ([IO.Path]::IsPathRooted($StageRoot)) {
        [IO.Path]::GetFullPath($StageRoot)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $runtimeLayout.RelativeStageBase $StageRoot))
    }
}
else {
    $stageDirectoryName = switch ($Preset) {
        'Stable' { 'fearmore-launcher-stable' }
        'Modern' { 'fearmore-launcher-modern' }
        'RtxLab' { 'fearmore-launcher-rtx-query-light-restir-custom-focus-preserved-d9d8-lab' }
        'RtxBridgeLab' { 'fearmore-launcher-rtx-camera-reassertion-prearm300s-300f-lab' }
        'CameraLab' { 'fearmore-launcher-native-camera-lab-armed' }
    }
    $requestedStageRoot = Join-Path $runtimeRoot $stageDirectoryName
}
$stageParameters.StageRoot = $requestedStageRoot
$settingsPathBeforeStaging = Join-Path $requestedStageRoot 'UserDirectory\settings.cfg'
$gameIniPathBeforeStaging = Join-Path $requestedStageRoot 'UserDirectory\Game.ini'
$enhancedGoreEnabled = Get-FearMoreEnhancedGoreEnabledFromSettings `
    -Path $settingsPathBeforeStaging `
    -DefaultEnabled:($Preset -eq 'Modern')
$settingsExistedBeforeStaging = Test-Path -LiteralPath $settingsPathBeforeStaging -PathType Leaf
$corpsePersistenceEnabled = Get-FearMoreCorpsePersistenceEnabledFromSettings `
    -Path $settingsPathBeforeStaging `
    -DefaultEnabled:($Preset -eq 'Modern' -and -not $settingsExistedBeforeStaging)
$rendererQualitySelection = if ($Preset -eq 'Modern') {
    if ($PSBoundParameters.ContainsKey('RendererQuality')) {
        $RendererQuality
    }
    else {
        Get-FearMoreRendererQualityFromSettings -Path $settingsPathBeforeStaging
    }
}
else {
    'Native'
}
$postProcessSelection = if ($Preset -eq 'Modern') {
    if ($PSBoundParameters.ContainsKey('PostProcessMode')) {
        $PostProcessMode
    }
    else {
        Get-FearMorePostProcessModeFromSettings -Path $settingsPathBeforeStaging
    }
}
else {
    'None'
}
if ($Preset -eq 'Modern' -and $postProcessSelection -eq 'ReShadeCas') {
    $postProcessMetadata = Get-FearPostProcessPackageMetadata
    $postProcessSetup = if ($runtimeLayout.LayoutKind -eq 'Packaged') {
        Join-Path (Split-Path $runtimeLayout.RuntimeRoot -Parent) "dependencies\postprocess\$($postProcessMetadata.SetupName)"
    }
    else {
        Join-Path $repositoryRoot "vendor-local\postprocess-deps\$($postProcessMetadata.SetupName)"
    }
    if (-not (Test-Path -LiteralPath $postProcessSetup -PathType Leaf)) {
        Write-Host "Downloading the official ReShade $($postProcessMetadata.Version) setup required by CAS..."
        $postProcessResults = @(& $postProcessAcquisitionScript `
                -RepositoryRoot $repositoryRoot `
                -SetupPath $postProcessSetup `
                -Confirm:$false)
        if ($postProcessResults.Count -ne 1) {
            throw "The ReShade acquisition workflow returned $($postProcessResults.Count) results; exactly one validated package was expected."
        }
    }
    $postProcessIdentity = Get-FearPostProcessPackageIdentity `
        -SetupPath $postProcessSetup `
        -AssetRoot (Join-Path $PSScriptRoot 'postprocess')
    $stageParameters.ReShadeSetup = $postProcessIdentity.SetupPath
}
if ($Preset -eq 'Modern') {
    $stageParameters.RendererQuality = $rendererQualitySelection
    $stageParameters.PostProcessMode = $postProcessSelection
    if ($rendererQualitySelection -eq 'Max2x') {
        Write-Warning 'Modern 2x downsampling renders up to four times as many pixels. Native remains the lower-cost compatibility fallback.'
    }
}
$hdTextureMode = Get-FearMoreHdTextureModeFromSettings -Path $settingsPathBeforeStaging
if ($rtxPreset -and $hdTextureMode -ne 'Off') {
    throw 'RTX presets currently require HD Textures Off. Their guarded Steam path uses the original retail executable and archive layout; retail LAA plus HDTextures mounting is not yet an owned RTX combination.'
}
if ($hdTextureMode -ne 'Off') {
    $stageParameters.HdTextureMode = $hdTextureMode
    $stageParameters.HdTexturePackRoot = Get-FearRegisteredHdTextureRoot `
        -RepositoryRoot $repositoryRoot `
        -Mode $hdTextureMode `
        -ExplicitRoot $HdTexturePackRoot
}
elseif ($PSBoundParameters.ContainsKey('HdTexturePackRoot')) {
    throw '-HdTexturePackRoot was supplied, but the in-game HD textures setting is Off.'
}
$stageEnvironment = if ($rtxPreset) {
    @{
        DXVK_LOG_LEVEL = 'debug'
        DXVK_SHADER_DUMP_PATH = Join-Path $requestedStageRoot 'rtx-remix\shader-dumps'
    }
}
else {
    @{}
}
$additionalLaunchArguments = if ($null -eq $LaunchArguments) { @() } else { @($LaunchArguments) }
if (-not $rtxPreset) {
    foreach ($argument in $additionalLaunchArguments) {
        if ($argument -imatch '^\+EnhancedGore(?:=|$)') {
            throw 'LaunchArguments must not override the launcher-owned EnhancedGore state. Change Enhanced gore in Gameplay options instead.'
        }
    }
    $stageParameters.LaunchArguments = @(
        '+EnhancedGore'
        $(if ($enhancedGoreEnabled) { '1' } else { '0' })
    ) + $additionalLaunchArguments
}
$additionalRtxArguments = $additionalLaunchArguments

$useRetailSteamLaunch = $rtxPreset -and -not $PrepareOnly
$launchOnFirstPass = -not $useRetailSteamLaunch -and -not $PrepareOnly -and
    (Test-Path -LiteralPath $settingsPathBeforeStaging -PathType Leaf) -and
    (Test-Path -LiteralPath $gameIniPathBeforeStaging -PathType Leaf)
if ($launchOnFirstPass) {
    $stageParameters.Launch = $true
}

Write-Host "Preparing FearMore preset '$Preset' through the validated runtime staging workflow..."
$stageResult = Invoke-FearMoreStageWorkflow -ScriptPath $stageScript -Parameters $stageParameters -ProcessEnvironment $stageEnvironment
$stagedSettingsPath = Join-Path $stageResult.UserDirectory 'settings.cfg'
$displaySeed = if (Test-Path -LiteralPath $stagedSettingsPath -PathType Leaf) {
    [pscustomobject]@{
        Width      = 0
        Height     = 0
        DeviceName = ''
        Source     = 'ExistingProfile'
    }
}
else {
    Get-FearMoreInitialDisplaySeed `
        -UseExplicitResolution:($widthExplicit -and $heightExplicit) `
        -RequestedWidth $Width `
        -RequestedHeight $Height
}
$settingsResult = Initialize-FearMoreSettings `
    -UserDirectory $stageResult.UserDirectory `
    -WritableRoot $runtimeRoot `
    -StageRoot $stageResult.StageRoot `
    -DisplaySeed $displaySeed `
    -EnhancedGoreEnabled $enhancedGoreEnabled `
    -CorpsePersistenceEnabled $corpsePersistenceEnabled `
    -ControllerEnabled:($Preset -eq 'Modern')

$launched = $launchOnFirstPass
$retailSidecarInstallResult = $null
$steamLaunchResult = $null
if ($useRetailSteamLaunch) {
    $runningSteamExecutables = @(
        if ($PSBoundParameters.ContainsKey('SteamExecutable')) {
            [IO.Path]::GetFullPath($SteamExecutable)
        }
        else {
            Get-Process -Name 'steam' -ErrorAction SilentlyContinue |
                ForEach-Object {
                    try { $_.Path } catch { $null }
                } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { [IO.Path]::GetFullPath($_) } |
                Sort-Object -Unique
        }
    )
    if ($runningSteamExecutables.Count -ne 1) {
        throw 'The RTX preset requires exactly one running Steam client in this Windows session. Start Steam, sign in, and retry; or pass -SteamExecutable with the exact running steam.exe path.'
    }
    $steamClientIdentity = Get-FearRunningSteamClientIdentity `
        -SteamExecutable $runningSteamExecutables[0]

    Write-Host "Installing or validating FearMore RTX sidecars in the registered retail installation..."
    $sidecarResults = @(& $retailSidecarInstaller `
            -Install `
            -StageRoot $stageResult.StageRoot `
            -RetailRoot $stageResult.RetailRoot `
            -Confirm:$false)
    if ($sidecarResults.Count -ne 1 -or
        -not $sidecarResults[0].Validated -or
        -not $sidecarResults[0].Installed) {
        throw 'The guarded FearMore RTX retail-sidecar installer did not report one validated installation result.'
    }
    $retailSidecarInstallResult = $sidecarResults[0]

    $steamLaunchPlan = New-FearSteamLaunchPlan `
        -StageRoot $stageResult.StageRoot `
        -SteamExecutable $steamClientIdentity.SteamExecutable `
        -ExpectedRetailRoot $stageResult.RetailRoot `
        -AdditionalGameArguments $additionalRtxArguments `
        -RequireRunningSteamClient
    Write-Host "Launching FearMore $Preset through the running Steam client and registered retail executable..."
    $steamLaunchResult = Invoke-FearSteamLaunchPlan -Plan $steamLaunchPlan -Confirm:$false
    if (-not $steamLaunchResult -or -not $steamLaunchResult.ProcessStarted) {
        throw "Steam accepted the FearMore $Preset dispatch, but the registered retail FEAR.exe was not observed within the launch timeout."
    }
    $launched = $true
}
elseif (-not $PrepareOnly -and -not $launched) {
    # The first pass had to create the isolated stage/profile. Re-enter the
    # established staging primitive for its immediate pre-launch safety scan
    # instead of reproducing that protected launch path here.
    Write-Host "Revalidating and launching FearMore '$Preset' from its isolated stage..."
    $stageParameters.Launch = $true
    $stageResult = Invoke-FearMoreStageWorkflow -ScriptPath $stageScript -Parameters $stageParameters -ProcessEnvironment $stageEnvironment
    $launched = $true
}
elseif ($PrepareOnly) {
    Write-Host "FearMore '$Preset' is prepared. No process was launched."
}

[pscustomobject]@{
    Preset                       = $Preset
    Experimental                 = $Preset -in @('RtxLab', 'RtxBridgeLab', 'CameraLab')
    RendererMode                 = $stageResult.RendererMode
    RendererQuality              = if ($stageResult.PSObject.Properties['RendererQuality']) { $stageResult.RendererQuality } else { $rendererQualitySelection }
    RendererResolution           = if ($stageResult.PSObject.Properties['RendererResolution']) { $stageResult.RendererResolution } else { $null }
    RendererResampling           = if ($stageResult.PSObject.Properties['RendererResampling']) { $stageResult.RendererResampling } else { $null }
    PostProcessMode              = if ($stageResult.PSObject.Properties['PostProcessMode']) { $stageResult.PostProcessMode } else { $postProcessSelection }
    PostProcessCompatibilityStatus = if ($stageResult.PSObject.Properties['PostProcessCompatibilityStatus']) { $stageResult.PostProcessCompatibilityStatus } else { 'NotApplicable' }
    PostProcessAcceptanceTested  = if ($stageResult.PSObject.Properties['PostProcessAcceptanceTested']) { [bool]$stageResult.PostProcessAcceptanceTested } else { $false }
    RendererCompatibilityStatus = $stageResult.RendererCompatibilityStatus
    AcceptanceTested             = [bool]$stageResult.AcceptanceTested
    AcceptanceNote               = $stageResult.AcceptanceNote
    EnginePatchMode              = $stageResult.EnginePatchMode
    HdTextureMode                = $stageResult.HdTextureMode
    EnhancedGoreEnabled          = $enhancedGoreEnabled
    CorpsePersistenceEnabled     = $corpsePersistenceEnabled
    HdTextureMount               = $stageResult.HdTextureMount
    HdTextureManifestSha256      = $stageResult.HdTextureManifestSha256
    MaxFPS                       = $stageResult.MaxFPS
    StageRoot                    = $stageResult.StageRoot
    RuntimeLayoutKind            = $runtimeLayout.LayoutKind
    RuntimeRoot                  = $runtimeRoot
    PackageManifestPath          = $runtimeLayout.PackageManifestPath
    UserDirectory                = $stageResult.UserDirectory
    SettingsPath                 = $settingsResult.Path
    GameIniPath                  = $settingsResult.GameIniPath
    ResolutionSeeded             = $settingsResult.Seeded
    GameRunsSeeded               = $settingsResult.GameRunsSeeded
    ExistingSettingsPreserved    = $settingsResult.ExistingFilePreserved
    ExistingGameIniPreserved     = $settingsResult.ExistingGameIniPreserved
    SeededWidth                  = $settingsResult.Width
    SeededHeight                 = $settingsResult.Height
    ResolutionSource             = $settingsResult.Source
    ResolutionNote               = $settingsResult.Note
    Prepared                     = $true
    Launched                     = $launched
    LaunchTransport              = if ($rtxPreset) { 'SteamRetailSidecars' } else { 'IsolatedStageExecutable' }
    RetailSidecarsInstalled      = if ($retailSidecarInstallResult) { [bool]$retailSidecarInstallResult.Installed } else { $false }
    RetailSidecarInstallIdempotent = if ($retailSidecarInstallResult) { [bool]$retailSidecarInstallResult.Idempotent } else { $false }
    ArchivedRemixLog             = $stageResult.ArchivedRemixLog
    LaunchProcessId              = if ($steamLaunchResult) { $steamLaunchResult.GameProcessId } else { $stageResult.LaunchProcessId }
}
