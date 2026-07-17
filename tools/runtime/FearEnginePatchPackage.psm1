Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearRuntimeExecutable.psm1') -ErrorAction Stop

$script:ExpectedCommit = 'b4a7074e4cbb2fb6bb238809f7cf26424f1f5961'
$script:ExpectedManifestSha256 = '1E17062A5C7D8F1C04478F56E54A3C55EAFEF849026E99DA57F8579EF9B1642E'
$script:ExpectedBinarySha256 = '04A3C95ABFE669D98F647245450863BA7D7E189CE2FE236DE92CB4ACC110FE95'
$script:ExpectedProfileSha256 = 'A22FE3A56061A5ED82D78BA6DA82A93C99CB9D57826B6179DB75140716BEA66B'
$script:ExpectedCompatibilityProof = 'PatchGameModules=0; GameClient.dll, GameServer.dll, and ClientFX hooks were intentionally skipped.'
$script:ExpectedRemixManifestSha256 = '59E5F1D4808C18FC390A0D50E0BB12FBD697EA989E7FAAC82682988F8BEBD849'
$script:ExpectedRemixBinarySha256 = '19FF5BC718C25AB07AF590D2131C8E876D7BC1891F9193CFEBBCAED4F63B57B5'
$script:ExpectedRemixProfileSha256 = 'A47CC3C2F7EB75DA169EA5CC7001DFE489A3E3E81C8634A96283EB134E0777F9'
$script:ExpectedRemixDiagnosticsProof = 'rtx-remix\logs\fearmore-camera-'
$script:ExpectedCameraManifestSha256 = '5ACB326EEF2DFC1E98CEB92F22B6BB219146520154BC0BE26A7434BDE61BC3D4'
$script:ExpectedCameraBinarySha256 = '7B2B788BF2551A9A1A3E7FFFE87D11120EF68DAFC4FE9FB8DF0AE7D826DD5C35'
$script:ExpectedCameraProfileSha256 = 'AF4FEB8EDDD2EC317B736CBE0FBC1B8F008B44DC5C8577292FC409AD18F58AB0'
$script:ExpectedCameraDiagnosticsProof = 'FearMoreDiagnostics\camera-d3d9-'
$script:ExpectedRtxCameraManifestSha256 = '151487BBD3B321F040C2BE776E252023018F24D9F5072F43B82653E72243853B'
$script:ExpectedRtxCameraBinarySha256 = '09933000F129F509399C9792211E333FD3CBE2DDEDC7D19AAD82552AF97ADD15'
$script:ExpectedRtxCameraProfileSha256 = '87A76A140EB03A4CDF689B037BD5F5EFD953C81F8804E6FA59E8377B885F1EB2'
$script:ExpectedRtxFocusPreservationProof = 'FearMore RTX focus preservation: exact FEAR v1.08 renderer calls bypassed; focus events, input, sound, and Console_WindowProc detours preserved.'
$script:ExpectedRtxCameraReassertionManifestSha256 = '4EFBF1321AB608ED05062CDBD059D6B7682C95C129C13FE0FE11825071E56A4B'
$script:ExpectedRtxCameraReassertionBinarySha256 = 'CAF576C721585A7418BCD75386B1D5CA3B819C8803B143A7521842D7675B6270'
$script:ExpectedRtxCameraReassertionProfileSha256 = '727D468594041BE123E80C920A3833F2BA1876AE5D5475A4E8A0D543CDC7E08B'
$script:ExpectedRtxCameraReassertionProof = 'FearMore RTX camera reassertion: F7D91705-880 c0-c3, 300-frame query-gated passive observer.'
$script:CameraDiagnosticsSourceFiles = [ordered]@{
    cameraDiagnosticsPatchSha256   = 'patches\echopatch\0004-add-camera-diagnostics.patch'
    cameraDiagnosticsOverlaySha256 = 'tools\echopatch\overlays\CameraDiagnostics.cpp'
    profileBaseSha256               = 'tools\echopatch\EchoPatch.engine-only.ini'
    profileOverrideSha256           = 'tools\echopatch\EchoPatch.camera-diagnostics.override.ini'
}
$script:RtxFocusPreservationSourceFiles = [ordered]@{
    rtxFocusPreservationPatchSha256           = 'patches\echopatch\0005-add-rtx-focus-preservation.patch'
    rtxFocusPreservationOverlaySha256         = 'tools\echopatch\overlays\RtxFocusPreservation.cpp'
    rtxFocusPreservationProfileOverrideSha256 = 'tools\echopatch\EchoPatch.rtx-focus-preservation.override.ini'
}
$script:RtxCameraReassertionSourceFiles = [ordered]@{
    rtxCameraReassertionPatchSha256           = 'patches\echopatch\0006-add-rtx-camera-reassertion.patch'
    rtxCameraReassertionOverlaySha256         = 'tools\echopatch\overlays\RtxCameraReassertion.cpp'
    rtxCameraReassertionProfileOverrideSha256 = 'tools\echopatch\EchoPatch.rtx-camera-reassertion.override.ini'
}

function Get-FearEnginePatchFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $algorithm.Dispose()
        $stream.Dispose()
    }
}

function Get-RequiredJsonProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) {
        throw "Engine-only EchoPatch manifest is missing '$Name': $ManifestPath"
    }
    return $property.Value
}

function Read-EnginePatchIniSettings {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Engine-only EchoPatch config is missing: $Path"
    }
    $settings = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $section = $null
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith(';')) {
            continue
        }
        if ($trimmed -match '^\[([^\]]+)\]$') {
            $section = $Matches[1].Trim()
            continue
        }
        if (-not $section -or $trimmed -notmatch '^([^=]+?)\s*=\s*(.*?)\s*$') {
            throw "Engine-only EchoPatch config contains an unrecognized active line: $line"
        }
        $qualifiedName = "$section.$($Matches[1].Trim())"
        if ($settings.ContainsKey($qualifiedName)) {
            throw "Engine-only EchoPatch config contains a duplicate active setting: $qualifiedName"
        }
        $settings[$qualifiedName] = $Matches[2].Trim()
    }
    return $settings
}

function Get-FearEngineOnlyEchoPatchConfigIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateRange(30.0, 300.0)][double]$ExpectedMaxFPS,
        [Parameter(Mandatory = $true)][ValidateSet(0, 1)][int]$ExpectedDynamicVsync,
        [ValidateSet(0, 1)][int]$ExpectedCameraDiagnostics = 0,
        [ValidateSet(0, 1)][int]$ExpectedRemixCameraDiagnostics = 0,
        [ValidateSet(0, 1)][int]$ExpectedRtxFocusPreservation = 0,
        [ValidateSet(0, 1)][int]$ExpectedRtxCameraReassertion = 0,
        [ValidateSet(0, 1)][int]$ExpectedForceWindowed = 0,
        [ValidateSet(0, 1)][int]$ExpectedFixWindowStyle = 1
    )
    # Config inspection is read-only and remains authoritative when called by
    # an installer or launcher running under -WhatIf.
    $WhatIfPreference = $false

    $settings = Read-EnginePatchIniSettings -Path $Path
    $required = [ordered]@{
        'Compatibility.PatchGameModules'            = '0'
        'Fixes.CheckLAAPatch'                       = '0'
        'Fixes.FixNvidiaShadowCorruption'           = '1'
        'Fixes.FixAspectRatioBlur'                  = '1'
        'Fixes.HighFPSFixes'                        = '0'
        'Fixes.DisableXPWidescreenFiltering'        = '0'
        'Fixes.FixKeyboardInputLanguage'            = '0'
        'Fixes.WeaponFixes'                         = '0'
        'Graphics.HighResolutionReflections'        = '0'
        'Graphics.SSAAScale'                        = '1.0'
        'Graphics.EnablePersistentWorldState'       = '0'
        'Display.CustomFOV'                         = '0.0'
        'Display.HUDScaling'                        = '0'
        'Display.HUDCustomScalingFactor'            = '1.0'
        'Display.SmallTextCustomScalingFactor'      = '1.0'
        'Display.AutoResolution'                    = '0'
        'Display.DisableLetterbox'                  = '0'
        'Display.ForceWindowed'                     = $ExpectedForceWindowed.ToString([Globalization.CultureInfo]::InvariantCulture)
        'Display.FixWindowStyle'                    = $ExpectedFixWindowStyle.ToString([Globalization.CultureInfo]::InvariantCulture)
        'Controller.MouseAimMultiplier'             = '1.0'
        'Controller.SDLGamepadSupport'              = '0'
        'Controller.RumbleEnabled'                  = '0'
        'Controller.GyroEnabled'                    = '0'
        'Controller.GyroCalibrationPersistence'    = '0'
        'Controller.TouchpadEnabled'                = '0'
        'Controller.HideMouseCursor'                = '0'
        'SkipIntro.SkipSplashScreen'                = '0'
        'Console.ConsoleEnabled'                    = '0'
        'Console.DebugLevel'                        = '0'
        'Console.HighResolutionScaling'             = '0'
        'Console.LogOutputToFile'                   = '0'
        'Extra.InfiniteFlashlight'                  = '0'
        'Extra.EnableCustomMaxWeaponCapacity'       = '0'
        'Extra.MaxWeaponCapacity'                   = '3'
        'Extra.DisableHipFireAccuracyPenalty'       = '0'
    }
    foreach ($setting in $required.GetEnumerator()) {
        if (-not $settings.ContainsKey($setting.Key) -or $settings[$setting.Key] -cne $setting.Value) {
            throw "Engine-only EchoPatch config requires $($setting.Key) = $($setting.Value): $Path"
        }
    }
    foreach ($requiredName in @('Graphics.MaxFPS', 'Graphics.DynamicVsync')) {
        if (-not $settings.ContainsKey($requiredName)) {
            throw "Engine-only EchoPatch config is missing ${requiredName}: $Path"
        }
    }
    $parsedMaxFps = 0.0
    if (-not [double]::TryParse(
        $settings['Graphics.MaxFPS'],
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$parsedMaxFps)) {
        throw "Engine-only EchoPatch Graphics.MaxFPS is not a number: $($settings['Graphics.MaxFPS'])"
    }
    if ([Math]::Abs($parsedMaxFps - $ExpectedMaxFPS) -gt 0.0001) {
        throw "Engine-only EchoPatch Graphics.MaxFPS is $parsedMaxFps; expected $ExpectedMaxFPS."
    }
    if ($settings['Graphics.DynamicVsync'] -cne $ExpectedDynamicVsync.ToString([Globalization.CultureInfo]::InvariantCulture)) {
        throw "Engine-only EchoPatch Graphics.DynamicVsync is $($settings['Graphics.DynamicVsync']); expected $ExpectedDynamicVsync."
    }
    $actualRemixCameraDiagnostics = if ($settings.ContainsKey('Diagnostics.RemixCameraDiagnostics')) {
        $settings['Diagnostics.RemixCameraDiagnostics']
    }
    else {
        '0'
    }
    if ($actualRemixCameraDiagnostics -cne $ExpectedRemixCameraDiagnostics.ToString([Globalization.CultureInfo]::InvariantCulture)) {
        throw "Engine-only EchoPatch Diagnostics.RemixCameraDiagnostics is $actualRemixCameraDiagnostics; expected $ExpectedRemixCameraDiagnostics."
    }
    $actualCameraDiagnostics = if ($settings.ContainsKey('Diagnostics.CameraDiagnostics')) {
        $settings['Diagnostics.CameraDiagnostics']
    }
    else {
        '0'
    }
    if ($actualCameraDiagnostics -cne $ExpectedCameraDiagnostics.ToString([Globalization.CultureInfo]::InvariantCulture)) {
        throw "Engine-only EchoPatch Diagnostics.CameraDiagnostics is $actualCameraDiagnostics; expected $ExpectedCameraDiagnostics."
    }
    $actualRtxFocusPreservation = if ($settings.ContainsKey('Compatibility.PreserveRtxRendererOnFocusChange')) {
        $settings['Compatibility.PreserveRtxRendererOnFocusChange']
    }
    else {
        '0'
    }
    if ($actualRtxFocusPreservation -cne $ExpectedRtxFocusPreservation.ToString([Globalization.CultureInfo]::InvariantCulture)) {
        throw "Engine-only EchoPatch Compatibility.PreserveRtxRendererOnFocusChange is $actualRtxFocusPreservation; expected $ExpectedRtxFocusPreservation."
    }
    $actualRtxCameraReassertion = if ($settings.ContainsKey('Diagnostics.RtxCameraReassertion')) {
        $settings['Diagnostics.RtxCameraReassertion']
    }
    else {
        '0'
    }
    if ($actualRtxCameraReassertion -cne $ExpectedRtxCameraReassertion.ToString([Globalization.CultureInfo]::InvariantCulture)) {
        throw "Engine-only EchoPatch Diagnostics.RtxCameraReassertion is $actualRtxCameraReassertion; expected $ExpectedRtxCameraReassertion."
    }

    return [pscustomobject]@{
        Path         = [IO.Path]::GetFullPath($Path)
        Sha256       = Get-FearEnginePatchFileSha256 -Path $Path
        MaxFPS       = $parsedMaxFps
        DynamicVsync = $ExpectedDynamicVsync
        CameraDiagnostics = $ExpectedCameraDiagnostics -eq 1
        RemixCameraDiagnostics = $ExpectedRemixCameraDiagnostics -eq 1
        RtxFocusPreservation = $ExpectedRtxFocusPreservation -eq 1
        RtxCameraReassertion = $ExpectedRtxCameraReassertion -eq 1
        ForceWindowed = $ExpectedForceWindowed -eq 1
        FixWindowStyle = $ExpectedFixWindowStyle -eq 1
    }
}

function Get-FearEchoPatchPackageCoreIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$Description,
        [AllowNull()][string]$ExpectedManifestSha256,
        [AllowNull()][string]$ExpectedBinarySha256,
        [AllowNull()][string]$ExpectedProfileSha256
    )

    if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) {
        throw "Pinned $Description package is missing: $PackageRoot"
    }
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Pinned $Description manifest is missing: $ManifestPath"
    }
    $binaryPath = Join-Path $PackageRoot 'dinput8.dll'
    $configPath = Join-Path $PackageRoot 'EchoPatch.ini'
    foreach ($path in @($binaryPath, $configPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Pinned $Description package input is missing: $path"
        }
    }

    $manifestHash = (Get-FileHash -LiteralPath $ManifestPath -Algorithm SHA256).Hash
    if ($ExpectedManifestSha256 -and $manifestHash -cne $ExpectedManifestSha256) {
        throw "$Description manifest hash mismatch. Expected $ExpectedManifestSha256 but found ${manifestHash}: $ManifestPath"
    }
    $manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json
    $manifestBinaryHash = [string](Get-RequiredJsonProperty -Object $manifest -Name 'binarySha256' -ManifestPath $ManifestPath)
    $manifestProfileHash = [string](Get-RequiredJsonProperty -Object $manifest -Name 'profileSha256' -ManifestPath $ManifestPath)
    foreach ($hashRecord in @(
            [pscustomobject]@{ Name = 'binarySha256'; Value = $manifestBinaryHash },
            [pscustomobject]@{ Name = 'profileSha256'; Value = $manifestProfileHash }
        )) {
        if ($hashRecord.Value -cnotmatch '^[0-9A-F]{64}$') {
            throw "$Description manifest contains an invalid $($hashRecord.Name): $ManifestPath"
        }
    }

    $trustedBinaryHash = if ($ExpectedBinarySha256) { $ExpectedBinarySha256 } else { $manifestBinaryHash }
    $trustedProfileHash = if ($ExpectedProfileSha256) { $ExpectedProfileSha256 } else { $manifestProfileHash }
    $binaryHash = (Get-FileHash -LiteralPath $binaryPath -Algorithm SHA256).Hash
    $configHash = (Get-FileHash -LiteralPath $configPath -Algorithm SHA256).Hash
    if ($binaryHash -cne $trustedBinaryHash) {
        throw "$Description binary hash mismatch. Expected $trustedBinaryHash but found ${binaryHash}: $binaryPath"
    }
    if ($configHash -cne $trustedProfileHash) {
        throw "$Description config hash mismatch. Expected $trustedProfileHash but found ${configHash}: $configPath"
    }
    if ($manifestBinaryHash -cne $trustedBinaryHash -or $manifestProfileHash -cne $trustedProfileHash) {
        throw "$Description manifest hashes do not match the trusted package identity: $ManifestPath"
    }

    $peIdentity = Get-FearPeRuntimeIdentity -Path $binaryPath
    if (-not (Test-FearX86Pe32Identity -Identity $peIdentity)) {
        throw "$Description dinput8.dll is not a 32-bit x86 PE image: $binaryPath"
    }

    return [pscustomobject]@{
        PackageRoot    = [IO.Path]::GetFullPath($PackageRoot)
        ManifestPath   = [IO.Path]::GetFullPath($ManifestPath)
        ManifestSha256 = $manifestHash
        Manifest       = $manifest
        BinaryPath     = $binaryPath
        BinarySha256   = $binaryHash
        BinarySize     = $peIdentity.Size
        ConfigPath     = $configPath
        ConfigSha256   = $configHash
    }
}

function Assert-FearCameraDiagnosticsSourceHashes {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [switch]$IncludeRtxFocusPreservation,
        [switch]$IncludeRtxCameraReassertion
    )

    $repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
    $sourceRecords = @($script:CameraDiagnosticsSourceFiles.GetEnumerator())
    if ($IncludeRtxCameraReassertion) {
        # The reassertion flavor uses one combined override instead of the
        # narrower camera/focus overrides, so only attest source files that
        # actually contributed to that candidate.
        $sourceRecords = @($sourceRecords | Where-Object { $_.Key -cne 'profileOverrideSha256' })
    }
    if ($IncludeRtxFocusPreservation) {
        $focusSourceRecords = @($script:RtxFocusPreservationSourceFiles.GetEnumerator())
        if ($IncludeRtxCameraReassertion) {
            $focusSourceRecords = @($focusSourceRecords | Where-Object {
                    $_.Key -cne 'rtxFocusPreservationProfileOverrideSha256'
                })
        }
        $sourceRecords += $focusSourceRecords
    }
    if ($IncludeRtxCameraReassertion) {
        $sourceRecords += @($script:RtxCameraReassertionSourceFiles.GetEnumerator())
    }
    foreach ($sourceRecord in $sourceRecords) {
        $recordedHash = [string](Get-RequiredJsonProperty -Object $Manifest -Name $sourceRecord.Key -ManifestPath $ManifestPath)
        if ($recordedHash -cnotmatch '^[0-9A-F]{64}$') {
            throw "Camera diagnostic EchoPatch manifest contains an invalid $($sourceRecord.Key): $ManifestPath"
        }
        $sourcePath = Join-Path $repositoryRoot $sourceRecord.Value
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Camera diagnostic EchoPatch source proof is missing: $sourcePath"
        }
        $actualHash = (Get-FileHash -LiteralPath $sourcePath -Algorithm SHA256).Hash
        if ($recordedHash -cne $actualHash) {
            throw "Camera diagnostic EchoPatch manifest $($sourceRecord.Key) does not match the tracked source. Expected $actualHash but found ${recordedHash}: $ManifestPath"
        }
    }
}

function Get-FearRtxCameraDiagnosticEchoPatchPackageIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $core = Get-FearEchoPatchPackageCoreIdentity `
        -PackageRoot $PackageRoot `
        -ManifestPath $ManifestPath `
        -Description 'RTX focus-preserving camera diagnostic EchoPatch' `
        -ExpectedManifestSha256 $script:ExpectedRtxCameraManifestSha256 `
        -ExpectedBinarySha256 $script:ExpectedRtxCameraBinarySha256 `
        -ExpectedProfileSha256 $script:ExpectedRtxCameraProfileSha256
    $manifest = $core.Manifest
    $commit = [string](Get-RequiredJsonProperty -Object $manifest -Name 'echoPatchCommit' -ManifestPath $ManifestPath)
    $moduleHooks = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'moduleHooks' -ManifestPath $ManifestPath)
    $compatibilityProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'compatibilityProof' -ManifestPath $ManifestPath)
    $packageMode = [string](Get-RequiredJsonProperty -Object $manifest -Name 'packageMode' -ManifestPath $ManifestPath)
    $diagnosticsEnabled = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'cameraDiagnostics' -ManifestPath $ManifestPath)
    $diagnosticsProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'cameraDiagnosticsProof' -ManifestPath $ManifestPath)
    $focusPreservationEnabled = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'rtxFocusPreservation' -ManifestPath $ManifestPath)
    $focusPreservationProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'rtxFocusPreservationProof' -ManifestPath $ManifestPath)
    $machine = [string](Get-RequiredJsonProperty -Object $manifest -Name 'machine' -ManifestPath $ManifestPath)
    $optionalHeader = [string](Get-RequiredJsonProperty -Object $manifest -Name 'optionalHeader' -ManifestPath $ManifestPath)
    if ($commit -cne $script:ExpectedCommit -or
        $moduleHooks -or
        $compatibilityProof -cne $script:ExpectedCompatibilityProof -or
        $packageMode -cne 'RtxCameraDiagnosticEchoPatch' -or
        -not $diagnosticsEnabled -or
        $diagnosticsProof -cne $script:ExpectedCameraDiagnosticsProof -or
        -not $focusPreservationEnabled -or
        $focusPreservationProof -cne $script:ExpectedRtxFocusPreservationProof -or
        $machine -cne '0x014c' -or $optionalHeader -cne '0x010b') {
        throw "RTX focus-preserving camera diagnostic EchoPatch manifest does not match the pinned lab build identity: $ManifestPath"
    }
    Assert-FearCameraDiagnosticsSourceHashes `
        -Manifest $manifest `
        -ManifestPath $ManifestPath `
        -IncludeRtxFocusPreservation

    $configIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
        -Path $core.ConfigPath `
        -ExpectedMaxFPS 60.0 `
        -ExpectedDynamicVsync 1 `
        -ExpectedCameraDiagnostics 1 `
        -ExpectedRemixCameraDiagnostics 0 `
        -ExpectedRtxFocusPreservation 1

    return [pscustomobject]@{
        Commit                       = $commit
        PackageRoot                  = $core.PackageRoot
        ManifestPath                 = $core.ManifestPath
        ManifestSha256               = $core.ManifestSha256
        BinaryPath                   = $core.BinaryPath
        BinarySha256                 = $core.BinarySha256
        BinarySize                   = $core.BinarySize
        ConfigPath                   = $core.ConfigPath
        ConfigSha256                 = $configIdentity.Sha256
        ModuleHooks                  = $moduleHooks
        CompatibilityProof           = $compatibilityProof
        CameraDiagnostics            = $true
        CameraDiagnosticsProof       = $diagnosticsProof
        RtxFocusPreservation         = $true
        RtxFocusPreservationProof    = $focusPreservationProof
    }
}

function Get-FearRtxCameraReassertionEchoPatchPackageIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $core = Get-FearEchoPatchPackageCoreIdentity `
        -PackageRoot $PackageRoot `
        -ManifestPath $ManifestPath `
        -Description 'RTX camera-reassertion EchoPatch' `
        -ExpectedManifestSha256 $script:ExpectedRtxCameraReassertionManifestSha256 `
        -ExpectedBinarySha256 $script:ExpectedRtxCameraReassertionBinarySha256 `
        -ExpectedProfileSha256 $script:ExpectedRtxCameraReassertionProfileSha256
    $manifest = $core.Manifest
    $commit = [string](Get-RequiredJsonProperty -Object $manifest -Name 'echoPatchCommit' -ManifestPath $ManifestPath)
    $moduleHooks = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'moduleHooks' -ManifestPath $ManifestPath)
    $compatibilityProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'compatibilityProof' -ManifestPath $ManifestPath)
    $packageMode = [string](Get-RequiredJsonProperty -Object $manifest -Name 'packageMode' -ManifestPath $ManifestPath)
    $diagnosticsEnabled = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'cameraDiagnostics' -ManifestPath $ManifestPath)
    $diagnosticsProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'cameraDiagnosticsProof' -ManifestPath $ManifestPath)
    $focusPreservationEnabled = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'rtxFocusPreservation' -ManifestPath $ManifestPath)
    $focusPreservationProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'rtxFocusPreservationProof' -ManifestPath $ManifestPath)
    $reassertionEnabled = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'rtxCameraReassertion' -ManifestPath $ManifestPath)
    $reassertionProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'rtxCameraReassertionProof' -ManifestPath $ManifestPath)
    $machine = [string](Get-RequiredJsonProperty -Object $manifest -Name 'machine' -ManifestPath $ManifestPath)
    $optionalHeader = [string](Get-RequiredJsonProperty -Object $manifest -Name 'optionalHeader' -ManifestPath $ManifestPath)
    if ($commit -cne $script:ExpectedCommit -or
        $moduleHooks -or
        $compatibilityProof -cne $script:ExpectedCompatibilityProof -or
        $packageMode -cne 'RtxCameraReassertionEchoPatch' -or
        -not $diagnosticsEnabled -or
        $diagnosticsProof -cne $script:ExpectedCameraDiagnosticsProof -or
        -not $focusPreservationEnabled -or
        $focusPreservationProof -cne $script:ExpectedRtxFocusPreservationProof -or
        -not $reassertionEnabled -or
        $reassertionProof -cne $script:ExpectedRtxCameraReassertionProof -or
        $machine -cne '0x014c' -or $optionalHeader -cne '0x010b') {
        throw "RTX camera-reassertion EchoPatch manifest does not match the pinned experimental build identity: $ManifestPath"
    }
    Assert-FearCameraDiagnosticsSourceHashes `
        -Manifest $manifest `
        -ManifestPath $ManifestPath `
        -IncludeRtxFocusPreservation `
        -IncludeRtxCameraReassertion

    $configIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
        -Path $core.ConfigPath `
        -ExpectedMaxFPS 60.0 `
        -ExpectedDynamicVsync 1 `
        -ExpectedCameraDiagnostics 1 `
        -ExpectedRemixCameraDiagnostics 0 `
        -ExpectedRtxFocusPreservation 1 `
        -ExpectedRtxCameraReassertion 1

    return [pscustomobject]@{
        Commit                       = $commit
        PackageRoot                  = $core.PackageRoot
        ManifestPath                 = $core.ManifestPath
        ManifestSha256               = $core.ManifestSha256
        BinaryPath                   = $core.BinaryPath
        BinarySha256                 = $core.BinarySha256
        BinarySize                   = $core.BinarySize
        ConfigPath                   = $core.ConfigPath
        ConfigSha256                 = $configIdentity.Sha256
        ModuleHooks                  = $moduleHooks
        CompatibilityProof           = $compatibilityProof
        CameraDiagnostics            = $true
        CameraDiagnosticsProof       = $diagnosticsProof
        RtxFocusPreservation         = $true
        RtxFocusPreservationProof    = $focusPreservationProof
        RtxCameraReassertion         = $true
        RtxCameraReassertionProof    = $reassertionProof
    }
}

function Get-FearRemixDiagnosticEchoPatchPackageIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $core = Get-FearEchoPatchPackageCoreIdentity `
        -PackageRoot $PackageRoot `
        -ManifestPath $ManifestPath `
        -Description 'RTX Remix diagnostic EchoPatch' `
        -ExpectedManifestSha256 $script:ExpectedRemixManifestSha256 `
        -ExpectedBinarySha256 $script:ExpectedRemixBinarySha256 `
        -ExpectedProfileSha256 $script:ExpectedRemixProfileSha256
    $manifest = $core.Manifest
    $commit = [string](Get-RequiredJsonProperty -Object $manifest -Name 'echoPatchCommit' -ManifestPath $ManifestPath)
    $moduleHooks = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'moduleHooks' -ManifestPath $ManifestPath)
    $compatibilityProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'compatibilityProof' -ManifestPath $ManifestPath)
    $packageMode = [string](Get-RequiredJsonProperty -Object $manifest -Name 'packageMode' -ManifestPath $ManifestPath)
    $diagnosticsEnabled = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'remixCameraDiagnostics' -ManifestPath $ManifestPath)
    $diagnosticsProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'remixDiagnosticsProof' -ManifestPath $ManifestPath)
    $machine = [string](Get-RequiredJsonProperty -Object $manifest -Name 'machine' -ManifestPath $ManifestPath)
    $optionalHeader = [string](Get-RequiredJsonProperty -Object $manifest -Name 'optionalHeader' -ManifestPath $ManifestPath)
    if ($commit -cne $script:ExpectedCommit -or
        $moduleHooks -or
        $compatibilityProof -cne $script:ExpectedCompatibilityProof -or
        $packageMode -cne 'RemixDiagnosticEchoPatch' -or
        -not $diagnosticsEnabled -or
        $diagnosticsProof -cne $script:ExpectedRemixDiagnosticsProof -or
        $machine -cne '0x014c' -or $optionalHeader -cne '0x010b') {
        throw "RTX Remix diagnostic EchoPatch manifest does not match the pinned lab build identity: $ManifestPath"
    }

    $configIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
        -Path $core.ConfigPath `
        -ExpectedMaxFPS 60.0 `
        -ExpectedDynamicVsync 1 `
        -ExpectedRemixCameraDiagnostics 1

    return [pscustomobject]@{
        Commit                  = $commit
        PackageRoot             = $core.PackageRoot
        ManifestPath            = $core.ManifestPath
        ManifestSha256          = $core.ManifestSha256
        BinaryPath              = $core.BinaryPath
        BinarySha256            = $core.BinarySha256
        BinarySize              = $core.BinarySize
        ConfigPath              = $core.ConfigPath
        ConfigSha256            = $configIdentity.Sha256
        ModuleHooks             = $moduleHooks
        CompatibilityProof      = $compatibilityProof
        RemixCameraDiagnostics  = $true
        RemixDiagnosticsProof   = $diagnosticsProof
    }
}

function Get-FearEngineOnlyEchoPatchPackageIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $core = Get-FearEchoPatchPackageCoreIdentity `
        -PackageRoot $PackageRoot `
        -ManifestPath $ManifestPath `
        -Description 'Engine-only EchoPatch' `
        -ExpectedManifestSha256 $script:ExpectedManifestSha256 `
        -ExpectedBinarySha256 $script:ExpectedBinarySha256 `
        -ExpectedProfileSha256 $script:ExpectedProfileSha256
    $manifest = $core.Manifest
    $commit = [string](Get-RequiredJsonProperty -Object $manifest -Name 'echoPatchCommit' -ManifestPath $ManifestPath)
    $moduleHooks = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'moduleHooks' -ManifestPath $ManifestPath)
    $compatibilityProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'compatibilityProof' -ManifestPath $ManifestPath)
    $machine = [string](Get-RequiredJsonProperty -Object $manifest -Name 'machine' -ManifestPath $ManifestPath)
    $optionalHeader = [string](Get-RequiredJsonProperty -Object $manifest -Name 'optionalHeader' -ManifestPath $ManifestPath)
    if ($commit -cne $script:ExpectedCommit -or
        $moduleHooks -or
        $compatibilityProof -cne $script:ExpectedCompatibilityProof -or
        $machine -cne '0x014c' -or $optionalHeader -cne '0x010b') {
        throw "Engine-only EchoPatch manifest does not match the pinned compatibility build identity: $ManifestPath"
    }

    $configIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity -Path $core.ConfigPath -ExpectedMaxFPS 60.0 -ExpectedDynamicVsync 1

    return [pscustomobject]@{
        Commit             = $commit
        PackageRoot        = $core.PackageRoot
        ManifestPath       = $core.ManifestPath
        ManifestSha256     = $core.ManifestSha256
        BinaryPath         = $core.BinaryPath
        BinarySha256       = $core.BinarySha256
        BinarySize         = $core.BinarySize
        ConfigPath         = $core.ConfigPath
        ConfigSha256       = $configIdentity.Sha256
        ModuleHooks        = $moduleHooks
        CompatibilityProof = $compatibilityProof
    }
}

function Get-FearCameraDiagnosticEchoPatchPackageIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [Parameter(Mandatory = $true)][string]$ManifestPath
    )

    $core = Get-FearEchoPatchPackageCoreIdentity `
        -PackageRoot $PackageRoot `
        -ManifestPath $ManifestPath `
        -Description 'Camera diagnostic EchoPatch' `
        -ExpectedManifestSha256 $script:ExpectedCameraManifestSha256 `
        -ExpectedBinarySha256 $script:ExpectedCameraBinarySha256 `
        -ExpectedProfileSha256 $script:ExpectedCameraProfileSha256
    $manifest = $core.Manifest
    $commit = [string](Get-RequiredJsonProperty -Object $manifest -Name 'echoPatchCommit' -ManifestPath $ManifestPath)
    $moduleHooks = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'moduleHooks' -ManifestPath $ManifestPath)
    $compatibilityProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'compatibilityProof' -ManifestPath $ManifestPath)
    $packageMode = [string](Get-RequiredJsonProperty -Object $manifest -Name 'packageMode' -ManifestPath $ManifestPath)
    $diagnosticsEnabled = [bool](Get-RequiredJsonProperty -Object $manifest -Name 'cameraDiagnostics' -ManifestPath $ManifestPath)
    $diagnosticsProof = [string](Get-RequiredJsonProperty -Object $manifest -Name 'cameraDiagnosticsProof' -ManifestPath $ManifestPath)
    $machine = [string](Get-RequiredJsonProperty -Object $manifest -Name 'machine' -ManifestPath $ManifestPath)
    $optionalHeader = [string](Get-RequiredJsonProperty -Object $manifest -Name 'optionalHeader' -ManifestPath $ManifestPath)
    if ($commit -cne $script:ExpectedCommit -or
        $moduleHooks -or
        $compatibilityProof -cne $script:ExpectedCompatibilityProof -or
        $packageMode -cne 'CameraDiagnosticEchoPatch' -or
        -not $diagnosticsEnabled -or
        $diagnosticsProof -cne $script:ExpectedCameraDiagnosticsProof -or
        $machine -cne '0x014c' -or $optionalHeader -cne '0x010b') {
        throw "Camera diagnostic EchoPatch manifest does not match the source-pinned lab build identity: $ManifestPath"
    }
    Assert-FearCameraDiagnosticsSourceHashes -Manifest $manifest -ManifestPath $ManifestPath

    $configIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
        -Path $core.ConfigPath `
        -ExpectedMaxFPS 60.0 `
        -ExpectedDynamicVsync 1 `
        -ExpectedCameraDiagnostics 1 `
        -ExpectedRemixCameraDiagnostics 0

    return [pscustomobject]@{
        Commit                  = $commit
        PackageRoot             = $core.PackageRoot
        ManifestPath            = $core.ManifestPath
        ManifestSha256          = $core.ManifestSha256
        BinaryPath              = $core.BinaryPath
        BinarySha256            = $core.BinarySha256
        BinarySize              = $core.BinarySize
        ConfigPath              = $core.ConfigPath
        ConfigSha256            = $configIdentity.Sha256
        ModuleHooks             = $moduleHooks
        CompatibilityProof      = $compatibilityProof
        CameraDiagnostics       = $true
        CameraDiagnosticsProof  = $diagnosticsProof
    }
}

Export-ModuleMember -Function Get-FearEngineOnlyEchoPatchPackageIdentity, Get-FearEngineOnlyEchoPatchConfigIdentity, Get-FearRemixDiagnosticEchoPatchPackageIdentity, Get-FearCameraDiagnosticEchoPatchPackageIdentity, Get-FearRtxCameraDiagnosticEchoPatchPackageIdentity, Get-FearRtxCameraReassertionEchoPatchPackageIdentity
