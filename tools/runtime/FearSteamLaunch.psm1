Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$runtimeExecutableModule = Join-Path $PSScriptRoot 'FearRuntimeExecutable.psm1'
Import-Module $runtimeExecutableModule -Force
$retailSidecarModule = Join-Path $PSScriptRoot 'FearRetailSidecarPackage.psm1'
Import-Module $retailSidecarModule -Force
$rendererPackageModule = Join-Path $PSScriptRoot 'FearRendererPackage.psm1'
Import-Module $rendererPackageModule -Force
$remixExperimentModule = Join-Path $PSScriptRoot 'FearRemixExperimentPlan.psm1'
Import-Module $remixExperimentModule -Force

$script:FearSteamAppId = '21090'
$script:FearSteamArchiveConfig = 'FearMore.archcfg'
$script:FearSteamPlanKind = 'FearMore.SteamLaunchPlan'
$script:FearSteamPlanVersion = 3
$script:SupportedRtxEnginePatchModes = @(
    'CameraDiagnosticEchoPatch',
    'RtxCameraDiagnosticEchoPatch',
    'RtxCameraReassertionEchoPatch'
)

function ConvertTo-FearWindowsCommandLineArgument {
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) {
        $Value = ''
    }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    # Match the CommandLineToArgvW/CRT escaping contract. In particular,
    # backslashes immediately before a quote or the closing quote are doubled.
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            for ($index = 0; $index -lt (($backslashCount * 2) + 1); $index++) {
                [void]$builder.Append('\')
            }
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        for ($index = 0; $index -lt $backslashCount; $index++) {
            [void]$builder.Append('\')
        }
        $backslashCount = 0
        [void]$builder.Append($character)
    }
    for ($index = 0; $index -lt ($backslashCount * 2); $index++) {
        [void]$builder.Append('\')
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-FearWindowsCommandLineArguments {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]]$Arguments)

    return (@($Arguments | ForEach-Object {
                ConvertTo-FearWindowsCommandLineArgument -Value $_
            }) -join ' ')
}

function Test-FearSteamPathsEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [IO.Path]::GetFullPath($Left).TrimEnd('\').Equals(
        [IO.Path]::GetFullPath($Right).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase)
}

function Assert-FearSteamRegularFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a reparse point: $Path"
    }
}

function Assert-FearSteamRegularDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "$Description is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a reparse point: $Path"
    }
}

function Get-FearSteamRequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        throw "$Description is missing required property '$Name'."
    }
    return $property.Value
}

function Get-FearSteamTextSha256 {
    param([Parameter(Mandatory = $true)][string]$Text)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
                $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-FearSteamFileSha256 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
        $stream.Dispose()
    }
}

function Assert-FearSteamAdditionalArguments {
    param([AllowEmptyCollection()][string[]]$Arguments)

    foreach ($argument in @($Arguments)) {
        if ($null -eq $argument) {
            throw 'AdditionalGameArguments must not contain null values.'
        }
        if ($argument -imatch '^(?:[-+\/]?userdirectory|[-+\/]?archcfg|[-+\/]?FearMoreCameraDiagnostics)(?:=|:|$)') {
            throw "AdditionalGameArguments must not override Steam-launch-owned argument or cvar '$argument'."
        }
    }
}

function Get-FearSteamStageIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [AllowNull()][string]$ExpectedRetailRoot,
        [AllowNull()][string]$ExpectedRemixExperimentTransactionId
    )

    # Read-only identity commands must still execute when their caller is a
    # SupportsShouldProcess command running under -WhatIf.
    $WhatIfPreference = $false
    $canonicalStageRoot = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
    Assert-FearSteamRegularDirectory -Path $canonicalStageRoot -Description 'FearMore RTX stage root'

    $manifestPath = Join-Path $canonicalStageRoot 'fearmore-stage.json'
    Assert-FearSteamRegularFile -Path $manifestPath -Description 'FearMore stage manifest'
    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "FearMore stage manifest is not valid JSON: $manifestPath ($($_.Exception.Message))"
    }
    $manifestSha256 = Get-FearSteamFileSha256 -Path $manifestPath

    $schemaVersion = Get-FearSteamRequiredProperty -InputObject $manifest -Name 'SchemaVersion' -Description 'FearMore stage manifest'
    if ($schemaVersion -isnot [ValueType] -or [int64]$schemaVersion -ne 9) {
        throw "Steam RTX launch requires stage manifest schema 9; found '$schemaVersion'."
    }
    $rendererMode = [string](Get-FearSteamRequiredProperty -InputObject $manifest -Name 'RendererMode' -Description 'FearMore stage manifest')
    if ($rendererMode -cne 'RtxRemixProbe') {
        throw "Steam RTX launch requires RendererMode RtxRemixProbe; found '$rendererMode'."
    }
    $enginePatchMode = [string](Get-FearSteamRequiredProperty -InputObject $manifest -Name 'EnginePatchMode' -Description 'FearMore stage manifest')
    if (-not ($script:SupportedRtxEnginePatchModes -ccontains $enginePatchMode)) {
        throw "Steam RTX launch requires one of the supported engine patch modes ($($script:SupportedRtxEnginePatchModes -join ', ')); found '$enginePatchMode'."
    }
    $steamAppId = [string](Get-FearSteamRequiredProperty -InputObject $manifest -Name 'SteamAppId' -Description 'FearMore stage manifest')
    if ($steamAppId -cne $script:FearSteamAppId) {
        throw "Steam RTX launch requires Steam app id $($script:FearSteamAppId); found '$steamAppId'."
    }
    foreach ($booleanProperty in @('InputsValidated', 'LayoutValidated', 'LaunchPermitted')) {
        if ((Get-FearSteamRequiredProperty -InputObject $manifest -Name $booleanProperty -Description 'FearMore stage manifest') -ne $true) {
            throw "Steam RTX launch requires manifest property $booleanProperty=true."
        }
    }
    foreach ($windowedProperty in @('EnginePatchForceWindowed', 'EnginePatchFixWindowStyle')) {
        $windowedValue = Get-FearSteamRequiredProperty `
            -InputObject $manifest `
            -Name $windowedProperty `
            -Description 'FearMore stage manifest'
        if ($windowedValue -isnot [bool] -or $windowedValue -ne $true) {
            throw "Steam RTX launch requires Boolean manifest property $windowedProperty=true."
        }
    }
    $dlssFrameGenerationEnabled = Get-FearSteamRequiredProperty `
        -InputObject $manifest `
        -Name 'RendererRuntimeConfigSeedDlssFrameGenerationEnabled' `
        -Description 'FearMore stage manifest'
    if ($dlssFrameGenerationEnabled -isnot [bool] -or $dlssFrameGenerationEnabled -ne $false) {
        throw 'Steam RTX launch requires Boolean manifest property RendererRuntimeConfigSeedDlssFrameGenerationEnabled=false.'
    }

    $manifestRuntimeExecutable = [string](Get-FearSteamRequiredProperty -InputObject $manifest -Name 'RuntimeExecutable' -Description 'FearMore stage manifest')
    if ($manifestRuntimeExecutable -cne 'FEAR.exe') {
        throw "Steam RTX launch requires the exact staged runtime executable name FEAR.exe; found '$manifestRuntimeExecutable'."
    }

    $manifestRetailRoot = [string](Get-FearSteamRequiredProperty -InputObject $manifest -Name 'RetailRoot' -Description 'FearMore stage manifest')
    if (-not [IO.Path]::IsPathRooted($manifestRetailRoot)) {
        throw "FearMore stage manifest RetailRoot must be absolute: $manifestRetailRoot"
    }
    $canonicalRetailRoot = [IO.Path]::GetFullPath($manifestRetailRoot).TrimEnd('\')
    Assert-FearSteamRegularDirectory -Path $canonicalRetailRoot -Description 'registered F.E.A.R. retail root'
    if ($ExpectedRetailRoot -and
        -not (Test-FearSteamPathsEqual -Left $canonicalRetailRoot -Right $ExpectedRetailRoot)) {
        throw "Stage RetailRoot '$canonicalRetailRoot' does not match expected retail root '$ExpectedRetailRoot'."
    }
    if (-not (Test-FearSteamRetailInstallation `
            -RetailRoot $canonicalRetailRoot `
            -AppId $script:FearSteamAppId `
            -RequireRegisteredAppManifest)) {
        throw "RetailRoot is not the registered Steam F.E.A.R. $($script:FearSteamAppId) installation: $canonicalRetailRoot"
    }

    $retailExecutable = Join-Path $canonicalRetailRoot 'FEAR.exe'
    $stageExecutable = Join-Path $canonicalStageRoot 'FEAR.exe'
    Assert-FearSteamRegularFile -Path $retailExecutable -Description 'registered retail FEAR.exe'
    Assert-FearSteamRegularFile -Path $stageExecutable -Description 'staged FEAR.exe'
    $retailIdentity = Get-FearPeRuntimeIdentity -Path $retailExecutable
    $stageIdentity = Get-FearPeRuntimeIdentity -Path $stageExecutable
    if (-not (Test-FearX86Pe32Identity -Identity $retailIdentity) -or
        -not (Test-FearX86Pe32Identity -Identity $stageIdentity)) {
        throw 'Steam RTX launch requires 32-bit x86 PE32 retail and staged FEAR.exe images.'
    }

    $manifestRetailHash = [string](Get-FearSteamRequiredProperty -InputObject $manifest -Name 'RetailExecutableSha256' -Description 'FearMore stage manifest')
    $manifestRuntimeHash = [string](Get-FearSteamRequiredProperty -InputObject $manifest -Name 'RuntimeExecutableSha256' -Description 'FearMore stage manifest')
    if ($manifestRetailHash -cne $retailIdentity.Sha256 -or
        $manifestRuntimeHash -cne $stageIdentity.Sha256 -or
        $stageIdentity.Sha256 -cne $retailIdentity.Sha256) {
        throw 'Stage/manifest FEAR.exe identity does not exactly match the registered retail FEAR.exe.'
    }

    $manifestUserDirectory = [string](Get-FearSteamRequiredProperty -InputObject $manifest -Name 'UserDirectory' -Description 'FearMore stage manifest')
    if (-not [IO.Path]::IsPathRooted($manifestUserDirectory)) {
        throw "FearMore stage manifest UserDirectory must be absolute: $manifestUserDirectory"
    }
    $userDirectory = [IO.Path]::GetFullPath($manifestUserDirectory).TrimEnd('\')
    $expectedUserDirectory = [IO.Path]::GetFullPath((Join-Path $canonicalStageRoot 'UserDirectory')).TrimEnd('\')
    if (-not (Test-FearSteamPathsEqual -Left $userDirectory -Right $expectedUserDirectory)) {
        throw "Steam RTX launch requires the exact stage-local UserDirectory '$expectedUserDirectory'; found '$userDirectory'."
    }
    Assert-FearSteamRegularDirectory -Path $userDirectory -Description 'stage-local UserDirectory'

    if (Get-FearRetailSidecarRecoveryState -RetailRoot $canonicalRetailRoot) {
        throw 'FearMore retail sidecars have an unfinished transaction; Steam launch requires a stable Installed state.'
    }
    $runtimeConfigSeed = Join-Path $PSScriptRoot 'config\rtx-remix-runtime.conf'
    $freshSidecarPlan = Get-FearRetailSidecarPackagePlan `
        -StageRoot $canonicalStageRoot `
        -RetailRoot $canonicalRetailRoot `
        -RuntimeConfigSeed $runtimeConfigSeed
    $sidecarInstallState = Get-FearRetailSidecarInstallState -Plan $freshSidecarPlan
    if ([string]$sidecarInstallState.State -cne 'InstalledExact' -or -not $sidecarInstallState.Installed) {
        throw "FearMore retail sidecars must be in the exact Installed state for this fresh stage package; found '$($sidecarInstallState.State)'."
    }
    $installedSidecars = $sidecarInstallState.Installed
    Assert-FearRetailSidecarPackageSnapshotMatchesPlan `
        -Snapshot $installedSidecars.Record `
        -Plan $freshSidecarPlan `
        -SnapshotKind InstallRecord `
        -Description 'FearMore retail install record before Steam launch'
    $installRecord = $installedSidecars.Record
    $installedRetailHash = [string](Get-FearSteamRequiredProperty -InputObject $installRecord -Name 'RetailExecutableSha256' -Description 'FearMore retail install record')
    if ($installedRetailHash -cne $retailIdentity.Sha256) {
        throw 'FearMore retail sidecar install is not bound to the registered retail FEAR.exe.'
    }
    $runtimeConfigSafety = Get-FearRtxRemixRuntimeConfigSafetyIdentity `
        -Path $installedSidecars.RuntimeConfigPath `
        -UserConfigPath (Join-Path $canonicalRetailRoot 'user.conf')
    $experimentAuthorization = Assert-FearRemixExperimentLaunchAuthorization `
        -RetailRoot $canonicalRetailRoot `
        -ExpectedTransactionId $ExpectedRemixExperimentTransactionId `
        -ExpectedInstallIdentitySha256 ([string](Get-FearSteamRequiredProperty -InputObject $installRecord -Name 'InstallIdentitySha256' -Description 'FearMore retail install record')) `
        -ExpectedUserConfigSha256 $runtimeConfigSafety.UserConfigSha256
    $archiveRecords = @(@(Get-FearSteamRequiredProperty -InputObject $installRecord -Name 'ImmutableFiles' -Description 'FearMore retail install record') |
            Where-Object { [string]$_.RelativePath -ceq $script:FearSteamArchiveConfig })
    if ($archiveRecords.Count -ne 1) {
        throw "FearMore retail sidecar install must own exactly one $($script:FearSteamArchiveConfig) record."
    }
    $archiveConfigPath = Join-Path $canonicalRetailRoot $script:FearSteamArchiveConfig
    Assert-FearSteamRegularFile -Path $archiveConfigPath -Description 'installed Steam RTX archive configuration'
    $archiveConfigHash = Get-FearSteamFileSha256 -Path $archiveConfigPath
    if ([string]$archiveRecords[0].Sha256 -cne $archiveConfigHash -or
        [long]$archiveRecords[0].Size -ne (Get-Item -LiteralPath $archiveConfigPath -Force).Length) {
        throw "Installed $($script:FearSteamArchiveConfig) does not match its exact retail install record."
    }

    return [pscustomobject][ordered]@{
        StageRoot                  = $canonicalStageRoot
        ManifestPath               = $manifestPath
        ManifestSha256             = $manifestSha256
        RetailRoot                 = $canonicalRetailRoot
        RetailExecutable           = $retailExecutable
        RetailExecutableSha256     = $retailIdentity.Sha256
        StageExecutable            = $stageExecutable
        StageExecutableSha256      = $stageIdentity.Sha256
        UserDirectory              = $userDirectory
        ArchiveConfigPath          = $archiveConfigPath
        ArchiveConfigSha256        = $archiveConfigHash
        RuntimeConfigPath          = $runtimeConfigSafety.Path
        RuntimeConfigSha256        = $runtimeConfigSafety.Sha256
        RuntimeConfigGraphicsPreset = $runtimeConfigSafety.GraphicsPreset
        RuntimeConfigIntegrateIndirectMode = $runtimeConfigSafety.IntegrateIndirectMode
        RuntimeConfigDlssFrameGenerationEnabled = $runtimeConfigSafety.DlssFrameGenerationEnabled
        UserConfigPath             = $runtimeConfigSafety.UserConfigPath
        UserConfigPresent          = $runtimeConfigSafety.UserConfigPresent
        UserConfigSha256           = $runtimeConfigSafety.UserConfigSha256
        RemixExperimentActive      = [bool]$experimentAuthorization.Active
        RemixExperimentTransactionId = $experimentAuthorization.TransactionId
        RetailSidecarState         = 'Installed'
        RetailInstallRecordPath    = $installedSidecars.RecordPath
        RetailInstallIdentitySha256 = [string](Get-FearSteamRequiredProperty -InputObject $installRecord -Name 'InstallIdentitySha256' -Description 'FearMore retail install record')
        FreshSidecarPackageIdentitySha256 = [string]$freshSidecarPlan.InstallIdentitySha256
        RendererMode               = $rendererMode
        EnginePatchMode            = $enginePatchMode
    }
}

function Get-FearSteamProcessSnapshot {
    $snapshot = @()
    foreach ($process in @(Get-Process -Name 'steam' -ErrorAction SilentlyContinue)) {
        $processPath = $null
        $hasExited = $true
        try { $processPath = $process.Path } catch { $processPath = $null }
        try { $hasExited = $process.HasExited } catch { $hasExited = $true }
        $snapshot += [pscustomobject]@{
            Id          = $process.Id
            ProcessName = $process.ProcessName
            SessionId   = $process.SessionId
            Path        = $processPath
            HasExited   = $hasExited
        }
    }
    return @($snapshot)
}

function Get-FearRetailGameProcessSnapshot {
    $snapshot = @()
    foreach ($process in @(Get-Process -Name 'FEAR' -ErrorAction SilentlyContinue)) {
        $processPath = $null
        $hasExited = $true
        try { $processPath = $process.Path } catch { $processPath = $null }
        try { $hasExited = $process.HasExited } catch { $hasExited = $true }
        $snapshot += [pscustomobject]@{
            Id          = $process.Id
            ProcessName = $process.ProcessName
            SessionId   = $process.SessionId
            Path        = $processPath
            HasExited   = $hasExited
        }
    }
    return @($snapshot)
}

function Get-FearMatchingRetailGameProcesses {
    param(
        [Parameter(Mandatory = $true)][string]$RetailExecutable,
        [AllowEmptyCollection()][object[]]$ProcessSnapshot,
        [Parameter(Mandatory = $true)][int]$CurrentSessionId
    )

    $matches = @()
    foreach ($process in @($ProcessSnapshot)) {
        $nameProperty = $process.PSObject.Properties['ProcessName']
        $pathProperty = $process.PSObject.Properties['Path']
        $sessionProperty = $process.PSObject.Properties['SessionId']
        $idProperty = $process.PSObject.Properties['Id']
        $exitedProperty = $process.PSObject.Properties['HasExited']
        if ($null -eq $nameProperty -or $null -eq $pathProperty -or $null -eq $sessionProperty -or
            $null -eq $idProperty -or $null -eq $pathProperty.Value -or
            ($null -ne $exitedProperty -and $exitedProperty.Value) -or
            [string]$nameProperty.Value -ine 'FEAR' -or [int]$sessionProperty.Value -ne $CurrentSessionId) {
            continue
        }
        try {
            if (Test-FearSteamPathsEqual -Left ([string]$pathProperty.Value) -Right $RetailExecutable) {
                $matches += $process
            }
        }
        catch {
            continue
        }
    }
    return @($matches)
}

function Wait-FearRetailGameProcess {
    param(
        [Parameter(Mandatory = $true)][string]$RetailExecutable,
        [Parameter(Mandatory = $true)][int]$CurrentSessionId,
        [Parameter(Mandatory = $true)][scriptblock]$ProcessSnapshotProvider,
        [Parameter(Mandatory = $true)][scriptblock]$Delay,
        [Parameter(Mandatory = $true)][int]$TimeoutMilliseconds,
        [int]$PollIntervalMilliseconds = 250
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        do {
            $matches = @(Get-FearMatchingRetailGameProcesses `
                    -RetailExecutable $RetailExecutable `
                    -ProcessSnapshot @(& $ProcessSnapshotProvider) `
                    -CurrentSessionId $CurrentSessionId)
            if ($matches.Count -gt 0) {
                return $matches[0]
            }
            if ($stopwatch.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
                break
            }
            & $Delay $PollIntervalMilliseconds
        } while ($stopwatch.ElapsedMilliseconds -lt $TimeoutMilliseconds)
    }
    finally {
        $stopwatch.Stop()
    }
    return $null
}

function Test-FearSteamClientSnapshot {
    param(
        [Parameter(Mandatory = $true)][string]$SteamExecutable,
        [AllowEmptyCollection()][object[]]$ProcessSnapshot,
        [Parameter(Mandatory = $true)][int]$CurrentSessionId
    )

    $expectedPath = [IO.Path]::GetFullPath($SteamExecutable)
    $matchingIds = @()
    foreach ($process in @($ProcessSnapshot)) {
        $nameProperty = $process.PSObject.Properties['ProcessName']
        $pathProperty = $process.PSObject.Properties['Path']
        $sessionProperty = $process.PSObject.Properties['SessionId']
        $idProperty = $process.PSObject.Properties['Id']
        $exitedProperty = $process.PSObject.Properties['HasExited']
        if ($null -eq $nameProperty -or $null -eq $pathProperty -or $null -eq $sessionProperty -or
            $null -eq $idProperty -or $null -eq $pathProperty.Value -or
            ($null -ne $exitedProperty -and $exitedProperty.Value)) {
            continue
        }
        if ([string]$nameProperty.Value -ine 'steam' -or [int]$sessionProperty.Value -ne $CurrentSessionId) {
            continue
        }
        try {
            if (-not (Test-FearSteamPathsEqual -Left ([string]$pathProperty.Value) -Right $expectedPath)) {
                continue
            }
        }
        catch {
            continue
        }
        $matchingIds += [int]$idProperty.Value
    }

    $valid = $matchingIds.Count -gt 0
    return [pscustomobject][ordered]@{
        IsValid            = $valid
        ExpectedPath       = $expectedPath
        CurrentSessionId   = $CurrentSessionId
        MatchingProcessIds = @($matchingIds)
        Reason             = if ($valid) {
            'A running Steam client with the exact executable path is present in the current Windows session.'
        }
        else {
            'No running Steam client with the exact executable path was found in the current Windows session.'
        }
    }
}

function Get-FearRunningSteamClientIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SteamExecutable)

    $canonicalSteamExecutable = [IO.Path]::GetFullPath($SteamExecutable)
    if ((Split-Path $canonicalSteamExecutable -Leaf) -ine 'steam.exe') {
        throw "SteamExecutable must be the exact steam.exe path: $canonicalSteamExecutable"
    }
    Assert-FearSteamRegularFile -Path $canonicalSteamExecutable -Description 'Steam client executable'
    $currentSessionId = (Get-Process -Id $PID).SessionId
    $assessment = Test-FearSteamClientSnapshot `
        -SteamExecutable $canonicalSteamExecutable `
        -ProcessSnapshot (Get-FearSteamProcessSnapshot) `
        -CurrentSessionId $currentSessionId
    if (-not $assessment.IsValid) {
        throw $assessment.Reason
    }
    return [pscustomobject][ordered]@{
        SteamExecutable       = $canonicalSteamExecutable
        SteamExecutableSha256 = Get-FearSteamFileSha256 -Path $canonicalSteamExecutable
        CurrentSessionId      = $currentSessionId
        MatchingProcessIds    = @($assessment.MatchingProcessIds)
        Validated             = $true
    }
}

function New-FearSteamLaunchPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$SteamExecutable,
        [AllowNull()][string]$ExpectedRetailRoot,
        [AllowNull()][string]$ExpectedRemixExperimentTransactionId,
        [AllowEmptyCollection()][string[]]$AdditionalGameArguments = @(),
        [switch]$RequireRunningSteamClient
    )

    Assert-FearSteamAdditionalArguments -Arguments $AdditionalGameArguments
    $identity = Get-FearSteamStageIdentity `
        -StageRoot $StageRoot `
        -ExpectedRetailRoot $ExpectedRetailRoot `
        -ExpectedRemixExperimentTransactionId $ExpectedRemixExperimentTransactionId

    $canonicalSteamExecutable = [IO.Path]::GetFullPath($SteamExecutable)
    if ((Split-Path $canonicalSteamExecutable -Leaf) -ine 'steam.exe') {
        throw "SteamExecutable must be the exact steam.exe path: $canonicalSteamExecutable"
    }
    Assert-FearSteamRegularFile -Path $canonicalSteamExecutable -Description 'Steam client executable'

    $ownedGameArguments = @(
        '-userdirectory',
        $identity.UserDirectory,
        '-archcfg',
        $script:FearSteamArchiveConfig,
        '+FearMoreCameraDiagnostics',
        '1'
    )
    $gameArguments = @($ownedGameArguments + @($AdditionalGameArguments))
    $steamArguments = @('-applaunch', $script:FearSteamAppId) + $gameArguments
    $argumentString = Join-FearWindowsCommandLineArguments -Arguments $steamArguments
    $fingerprintInput = @(
        $script:FearSteamPlanKind,
        [string]$script:FearSteamPlanVersion,
        $identity.StageRoot,
        $identity.ManifestSha256,
        $identity.RetailRoot,
        $identity.RetailExecutableSha256,
        $identity.UserDirectory,
        $identity.ArchiveConfigSha256,
        $identity.RuntimeConfigSha256,
        [string]$identity.UserConfigPresent,
        [string]$identity.UserConfigSha256,
        [string]$identity.RemixExperimentActive,
        [string]$identity.RemixExperimentTransactionId,
        $identity.RetailInstallIdentitySha256,
        $identity.FreshSidecarPackageIdentitySha256,
        $canonicalSteamExecutable,
        (Get-FearSteamFileSha256 -Path $canonicalSteamExecutable),
        $argumentString
    ) -join "`n"

    $liveAssessment = $null
    if ($RequireRunningSteamClient) {
        $liveAssessment = Get-FearRunningSteamClientIdentity -SteamExecutable $canonicalSteamExecutable
    }

    return [pscustomobject][ordered]@{
        PlanKind                    = $script:FearSteamPlanKind
        PlanVersion                 = $script:FearSteamPlanVersion
        PlanFingerprint             = Get-FearSteamTextSha256 -Text $fingerprintInput
        AppId                       = $script:FearSteamAppId
        StageRoot                   = $identity.StageRoot
        ManifestPath                = $identity.ManifestPath
        ManifestSha256              = $identity.ManifestSha256
        RendererMode                = $identity.RendererMode
        EnginePatchMode             = $identity.EnginePatchMode
        RetailRoot                  = $identity.RetailRoot
        RegisteredRetailExecutable = $identity.RetailExecutable
        RetailExecutableSha256      = $identity.RetailExecutableSha256
        UserDirectory               = $identity.UserDirectory
        ArchiveConfig               = $script:FearSteamArchiveConfig
        ArchiveConfigPath           = $identity.ArchiveConfigPath
        RuntimeConfigPath           = $identity.RuntimeConfigPath
        RuntimeConfigSha256         = $identity.RuntimeConfigSha256
        RuntimeConfigGraphicsPreset = $identity.RuntimeConfigGraphicsPreset
        RuntimeConfigIntegrateIndirectMode = $identity.RuntimeConfigIntegrateIndirectMode
        RuntimeConfigDlssFrameGenerationEnabled = $identity.RuntimeConfigDlssFrameGenerationEnabled
        UserConfigPath              = $identity.UserConfigPath
        UserConfigPresent           = $identity.UserConfigPresent
        UserConfigSha256            = $identity.UserConfigSha256
        RemixExperimentActive       = $identity.RemixExperimentActive
        RemixExperimentTransactionId = $identity.RemixExperimentTransactionId
        RetailSidecarState          = $identity.RetailSidecarState
        RetailInstallRecordPath     = $identity.RetailInstallRecordPath
        RetailInstallIdentitySha256 = $identity.RetailInstallIdentitySha256
        FreshSidecarPackageIdentitySha256 = $identity.FreshSidecarPackageIdentitySha256
        SteamExecutable             = $canonicalSteamExecutable
        SteamExecutableSha256       = Get-FearSteamFileSha256 -Path $canonicalSteamExecutable
        WorkingDirectory            = $identity.RetailRoot
        OwnedGameArguments          = @($ownedGameArguments)
        AdditionalGameArguments     = @($AdditionalGameArguments)
        GameArguments               = @($gameArguments)
        SteamArguments              = @($steamArguments)
        ArgumentString              = $argumentString
        LiveSteamClientValidated    = [bool]$RequireRunningSteamClient
        LiveSteamClientProcessIds   = if ($liveAssessment) { @($liveAssessment.MatchingProcessIds) } else { @() }
        ProcessStarted              = $false
    }
}

function Assert-FearSteamLaunchPlanCurrent {
    param([Parameter(Mandatory = $true)]$Plan)

    if ([string](Get-FearSteamRequiredProperty -InputObject $Plan -Name 'PlanKind' -Description 'Steam launch plan') -cne $script:FearSteamPlanKind -or
        [int](Get-FearSteamRequiredProperty -InputObject $Plan -Name 'PlanVersion' -Description 'Steam launch plan') -ne $script:FearSteamPlanVersion) {
        throw 'The supplied object is not a supported FearMore Steam launch plan.'
    }
    $experimentProperty = $Plan.PSObject.Properties['RemixExperimentTransactionId']
    if ($null -eq $experimentProperty) {
        throw "Steam launch plan is missing required property 'RemixExperimentTransactionId'."
    }
    $expectedExperimentTransactionId = if ($null -eq $experimentProperty.Value) {
        $null
    }
    else {
        [string]$experimentProperty.Value
    }
    $rebuilt = New-FearSteamLaunchPlan `
        -StageRoot ([string](Get-FearSteamRequiredProperty -InputObject $Plan -Name 'StageRoot' -Description 'Steam launch plan')) `
        -SteamExecutable ([string](Get-FearSteamRequiredProperty -InputObject $Plan -Name 'SteamExecutable' -Description 'Steam launch plan')) `
        -ExpectedRetailRoot ([string](Get-FearSteamRequiredProperty -InputObject $Plan -Name 'RetailRoot' -Description 'Steam launch plan')) `
        -ExpectedRemixExperimentTransactionId $expectedExperimentTransactionId `
        -AdditionalGameArguments @($Plan.AdditionalGameArguments)
    if ($rebuilt.PlanFingerprint -cne [string](Get-FearSteamRequiredProperty -InputObject $Plan -Name 'PlanFingerprint' -Description 'Steam launch plan')) {
        throw 'The Steam launch plan is stale or has been modified; build a fresh plan.'
    }
    return $rebuilt
}

function Test-FearSteamClientForLaunch {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Plan)

    $currentPlan = Assert-FearSteamLaunchPlanCurrent -Plan $Plan
    $currentSessionId = (Get-Process -Id $PID).SessionId
    return Test-FearSteamClientSnapshot `
        -SteamExecutable $currentPlan.SteamExecutable `
        -ProcessSnapshot (Get-FearSteamProcessSnapshot) `
        -CurrentSessionId $currentSessionId
}

function Invoke-FearSteamLaunchPlanCore {
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [AllowEmptyCollection()][object[]]$ProcessSnapshot,
        [Parameter(Mandatory = $true)][int]$CurrentSessionId,
        [Parameter(Mandatory = $true)][scriptblock]$ProcessStarter,
        [AllowEmptyCollection()][object[]]$PreDispatchRetailProcessSnapshot,
        [Parameter(Mandatory = $true)][scriptblock]$RetailProcessSnapshotProvider,
        [Parameter(Mandatory = $true)][scriptblock]$Delay,
        [Parameter(Mandatory = $true)][int]$GameStartTimeoutMilliseconds
    )

    $assessment = Test-FearSteamClientSnapshot `
        -SteamExecutable $Plan.SteamExecutable `
        -ProcessSnapshot $ProcessSnapshot `
        -CurrentSessionId $CurrentSessionId
    if (-not $assessment.IsValid) {
        throw $assessment.Reason
    }
    $existingRetailProcesses = @(Get-FearMatchingRetailGameProcesses `
            -RetailExecutable $Plan.RegisteredRetailExecutable `
            -ProcessSnapshot $PreDispatchRetailProcessSnapshot `
            -CurrentSessionId $CurrentSessionId)
    if ($existingRetailProcesses.Count -gt 0) {
        throw "The registered retail FEAR.exe is already running in this Windows session (PID $($existingRetailProcesses[0].Id)); refusing an ambiguous Steam dispatch."
    }
    $process = & $ProcessStarter $Plan.SteamExecutable $Plan.ArgumentString $Plan.WorkingDirectory
    if ($null -eq $process) {
        throw 'Steam launch dispatch did not return a process object.'
    }
    $processIdProperty = $process.PSObject.Properties['Id']
    $gameProcess = Wait-FearRetailGameProcess `
        -RetailExecutable $Plan.RegisteredRetailExecutable `
        -CurrentSessionId $CurrentSessionId `
        -ProcessSnapshotProvider $RetailProcessSnapshotProvider `
        -Delay $Delay `
        -TimeoutMilliseconds $GameStartTimeoutMilliseconds
    $gameProcessId = $null
    if ($gameProcess) {
        $gameProcessId = $gameProcess.PSObject.Properties['Id'].Value
    }
    return [pscustomobject][ordered]@{
        Plan                      = $Plan
        SteamClientProcessIds     = @($assessment.MatchingProcessIds)
        SteamDispatchProcessId    = if ($processIdProperty) { $processIdProperty.Value } else { $null }
        GameProcessObserved       = [bool]$gameProcess
        GameProcessId             = $gameProcessId
        GameExecutable            = $Plan.RegisteredRetailExecutable
        ProcessStarted            = [bool]$gameProcess
    }
}

function Invoke-FearSteamLaunchPlan {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory = $true)]$Plan,
        [ValidateRange(1, 120)][int]$GameStartTimeoutSeconds = 30
    )

    $currentPlan = Assert-FearSteamLaunchPlanCurrent -Plan $Plan
    if (-not $PSCmdlet.ShouldProcess(
            "$($currentPlan.SteamExecutable) $($currentPlan.ArgumentString)",
            'Dispatch the validated F.E.A.R. launch through the running Steam client')) {
        return
    }

    $currentSessionId = (Get-Process -Id $PID).SessionId
    $processSnapshot = Get-FearSteamProcessSnapshot
    $assessment = Test-FearSteamClientSnapshot `
        -SteamExecutable $currentPlan.SteamExecutable `
        -ProcessSnapshot $processSnapshot `
        -CurrentSessionId $currentSessionId
    if (-not $assessment.IsValid) {
        throw $assessment.Reason
    }

    $processStarter = {
        param($FilePath, $Arguments, $WorkingDirectory)

        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $FilePath
        $startInfo.Arguments = $Arguments
        $startInfo.WorkingDirectory = $WorkingDirectory
        $startInfo.UseShellExecute = $false
        return [Diagnostics.Process]::Start($startInfo)
    }
    $retailProcessSnapshotProvider = { Get-FearRetailGameProcessSnapshot }
    $preDispatchRetailProcessSnapshot = @(& $retailProcessSnapshotProvider)
    $delay = { param($Milliseconds) [Threading.Thread]::Sleep($Milliseconds) }
    return Invoke-FearSteamLaunchPlanCore `
        -Plan $currentPlan `
        -ProcessSnapshot $processSnapshot `
        -CurrentSessionId $currentSessionId `
        -ProcessStarter $processStarter `
        -PreDispatchRetailProcessSnapshot $preDispatchRetailProcessSnapshot `
        -RetailProcessSnapshotProvider $retailProcessSnapshotProvider `
        -Delay $delay `
        -GameStartTimeoutMilliseconds ($GameStartTimeoutSeconds * 1000)
}

Export-ModuleMember -Function `
    ConvertTo-FearWindowsCommandLineArgument, `
    Join-FearWindowsCommandLineArguments, `
    Get-FearRunningSteamClientIdentity, `
    New-FearSteamLaunchPlan, `
    Test-FearSteamClientForLaunch, `
    Invoke-FearSteamLaunchPlan
