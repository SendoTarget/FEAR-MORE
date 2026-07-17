[CmdletBinding()]
param([string]$RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$modulePath = Join-Path $PSScriptRoot 'FearSteamLaunch.psm1'
Import-Module $modulePath -Force
$steamModule = Get-Module FearSteamLaunch
$runtimeExecutableModulePath = Join-Path $PSScriptRoot 'FearRuntimeExecutable.psm1'
Import-Module $runtimeExecutableModulePath -Force
$runtimeExecutableModule = Get-Module FearRuntimeExecutable
$retailInstaller = Join-Path $PSScriptRoot 'Install-FearMoreRetailSidecars.ps1'
$runtimeConfigSeed = Join-Path $PSScriptRoot 'config\rtx-remix-runtime.conf'
$engineOnlyEchoPatchConfig = Join-Path $RepositoryRoot 'tools\echopatch\EchoPatch.engine-only.ini'

function Write-TestPe32 {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [byte[]]::new(512)
    $bytes[0] = 0x4D
    $bytes[1] = 0x5A
    ([BitConverter]::GetBytes([int32]0x80)).CopyTo($bytes, 0x3C)
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
    ([BitConverter]::GetBytes([uint16]0x014C)).CopyTo($bytes, 0x84)
    ([BitConverter]::GetBytes([uint16]1)).CopyTo($bytes, 0x86)
    ([BitConverter]::GetBytes([uint16]0x00E0)).CopyTo($bytes, 0x94)
    ([BitConverter]::GetBytes([uint16]0x0102)).CopyTo($bytes, 0x96)
    ([BitConverter]::GetBytes([uint16]0x010B)).CopyTo($bytes, 0x98)
    [Text.Encoding]::ASCII.GetBytes('.text').CopyTo($bytes, 0x178)
    [IO.File]::WriteAllBytes($Path, $bytes)
}

function Get-TestFileHash {
    param([Parameter(Mandatory = $true)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Get-TestTextHash {
    param([Parameter(Mandatory = $true)][string]$Text)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
                $algorithm.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-', '')
    }
    finally { $algorithm.Dispose() }
}

function New-TestFileRecord {
    param([Parameter(Mandatory = $true)][string]$Root, [Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $Root $RelativePath
    $item = Get-Item -LiteralPath $path -Force
    return [pscustomobject][ordered]@{
        RelativePath = $RelativePath
        Size         = $item.Length
        Sha256       = Get-TestFileHash -Path $path
    }
}

function Set-TestInstallRecordIdentity {
    param([Parameter(Mandatory = $true)]$Record)

    $identityLines = @("Manifest=$($Record.StageManifestSha256)")
    foreach ($file in @($Record.ImmutableFiles | Sort-Object RelativePath)) {
        $identityLines += "Immutable=$($file.RelativePath)|$($file.Size)|$($file.Sha256)"
    }
    $runtime = $Record.RuntimeConfig
    $identityLines += "MutableSeed=$($runtime.RelativePath)|$($runtime.SeedSize)|$($runtime.SeedSha256)|$($runtime.Policy)"
    $Record.InstallIdentitySha256 = Get-TestTextHash -Text ($identityLines -join "`n")
}

function Write-TestJson {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)]$Value)

    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}

function Assert-TestSequence {
    param([object[]]$Actual, [string[]]$Expected, [string]$Description)

    $actualValues = @($Actual)
    if ($actualValues.Count -ne $Expected.Count) {
        throw "$Description count mismatch: $($actualValues.Count) != $($Expected.Count)."
    }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$actualValues[$index] -cne $Expected[$index]) {
            throw "$Description mismatch at ${index}: '$($actualValues[$index])' != '$($Expected[$index])'."
        }
    }
}

function Assert-TestThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$Description,
        [AllowNull()][string]$MessagePattern
    )

    $threw = $false
    $observedMessage = $null
    try { & $Action | Out-Null }
    catch {
        $threw = $true
        $observedMessage = $_.Exception.Message
    }
    if (-not $threw) { throw "$Description did not fail closed." }
    if ($MessagePattern -and $observedMessage -notmatch $MessagePattern) {
        throw "$Description failed for an unexpected reason: $observedMessage"
    }
}

$runId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "fearmore-steam-launch-test-$runId"
$steamLibrary = Join-Path $fixtureRoot 'Steam Library With Spaces'
$steamAppsRoot = Join-Path $steamLibrary 'steamapps'
$commonRoot = Join-Path $steamAppsRoot 'common'
$retailRoot = Join-Path $commonRoot 'FEAR Synthetic Retail'
$stageRoot = Join-Path $fixtureRoot 'RTX Stage With Spaces'
$userDirectory = Join-Path $stageRoot 'UserDirectory'
$steamRoot = Join-Path $fixtureRoot 'Steam Client With Spaces'
$steamExecutable = Join-Path $steamRoot 'steam.exe'
$manifestPath = Join-Path $stageRoot 'fearmore-stage.json'
$installRecordPath = Join-Path $retailRoot 'fearmore-live-install.json'

try {
    foreach ($directory in @(
            $retailRoot,
            $userDirectory,
            $steamRoot,
            (Join-Path $stageRoot '.trex'),
            (Join-Path $stageRoot 'Game'))) {
        [void][IO.Directory]::CreateDirectory($directory)
    }
    Write-TestPe32 -Path (Join-Path $retailRoot 'FEAR.exe')
    [IO.File]::Copy((Join-Path $retailRoot 'FEAR.exe'), (Join-Path $stageRoot 'FEAR.exe'), $false)
    [IO.File]::WriteAllBytes($steamExecutable, [byte[]](0x53, 0x54, 0x45, 0x41, 0x4D))
    [IO.File]::WriteAllText((Join-Path $retailRoot 'Default.archcfg'), "FEAR.Arch00`r`n", [Text.ASCIIEncoding]::new())
    [IO.File]::WriteAllBytes((Join-Path $retailRoot 'FEAR.Arch00'), [byte[]](0x46, 0x45, 0x41, 0x52))
    [IO.File]::WriteAllText((Join-Path $stageRoot 'Default.archcfg'), "Retail\FEAR.Arch00`r`nGame`r`n", [Text.ASCIIEncoding]::new())
    foreach ($file in @(
            [pscustomobject]@{ RelativePath='d3d9.dll'; Text='synthetic renderer proxy' },
            [pscustomobject]@{ RelativePath='.trex\payload.dll'; Text='synthetic renderer payload' },
            [pscustomobject]@{ RelativePath='LICENSE.txt'; Text='synthetic renderer license' },
            [pscustomobject]@{ RelativePath='.trex\bridge.conf'; Text='synthetic bridge config' },
            [pscustomobject]@{ RelativePath='dinput8.dll'; Text='synthetic camera proxy' },
            [pscustomobject]@{ RelativePath='EchoPatch.ini'; Text='synthetic camera config' },
            [pscustomobject]@{ RelativePath='Game\GameClient.dll'; Text='synthetic rebuilt client' },
            [pscustomobject]@{ RelativePath='Game\GameServer.dll'; Text='synthetic rebuilt server' },
            [pscustomobject]@{ RelativePath='Game\ClientFx.fxd'; Text='synthetic rebuilt client fx' })) {
        [IO.File]::WriteAllText((Join-Path $stageRoot $file.RelativePath), $file.Text, [Text.UTF8Encoding]::new($false))
    }
    $rtxEchoPatchConfig = [IO.File]::ReadAllText($engineOnlyEchoPatchConfig)
    $rtxEchoPatchConfig = [regex]::Replace(
        $rtxEchoPatchConfig,
        '(?m)^(?<Prefix>[ \t]*ForceWindowed[ \t]*=[ \t]*)0[ \t]*$',
        '${Prefix}1')
    $rtxEchoPatchConfig = $rtxEchoPatchConfig.TrimEnd("`r", "`n") +
        "`r`n`r`n[Diagnostics]`r`nCameraDiagnostics = 1`r`n"
    $rtxEchoPatchConfig = [regex]::Replace(
        $rtxEchoPatchConfig,
        '(?m)^(?<Line>[ \t]*PatchGameModules[ \t]*=[ \t]*0[ \t]*)$',
        '${Line}' + "`r`nPreserveRtxRendererOnFocusChange = 1")
    [IO.File]::WriteAllText(
        (Join-Path $stageRoot 'EchoPatch.ini'),
        $rtxEchoPatchConfig,
        [Text.UTF8Encoding]::new($false))

    [void][IO.Directory]::CreateDirectory($steamAppsRoot)
    $appManifest = @"
"AppState"
{
    "appid"      "21090"
    "installdir" "FEAR Synthetic Retail"
}
"@
    [IO.File]::WriteAllText((Join-Path $steamAppsRoot 'appmanifest_21090.acf'), $appManifest, [Text.UTF8Encoding]::new($false))

    $retailHash = Get-TestFileHash -Path (Join-Path $retailRoot 'FEAR.exe')
    $rendererRecords = @('d3d9.dll', '.trex\payload.dll', 'LICENSE.txt') | ForEach-Object {
        New-TestFileRecord -Root $stageRoot -RelativePath $_
    }
    $moduleRecords = @('GameClient.dll', 'GameServer.dll', 'ClientFx.fxd') | ForEach-Object {
        $modulePath = Join-Path $stageRoot "Game\$_"
        [pscustomobject][ordered]@{
            Name        = $_
            Path        = $modulePath
            FileVersion = $null
            Sha256      = Get-TestFileHash -Path $modulePath
        }
    }
    $manifest = [pscustomobject][ordered]@{
        SchemaVersion           = 9
        Lane                    = 'Rebuilt'
        Configuration           = 'Release'
        RendererMode            = 'RtxRemixProbe'
        EnginePatchMode         = 'RtxCameraDiagnosticEchoPatch'
        FearVersion             = [string](Get-Item -LiteralPath (Join-Path $retailRoot 'FEAR.exe')).VersionInfo.FileVersion
        SteamAppId              = '21090'
        InputsValidated         = $true
        LayoutValidated         = $true
        LaunchPermitted         = $true
        EnginePatchForceWindowed = $true
        EnginePatchFixWindowStyle = $true
        RuntimeExecutable       = 'FEAR.exe'
        RetailRoot              = $retailRoot
        RetailExecutableSha256  = $retailHash
        RuntimeExecutableSha256 = $retailHash
        UserDirectory           = $userDirectory
        ArchiveEntries          = @('Retail\FEAR.Arch00', 'Game')
        Modules                 = @($moduleRecords)
        RendererPackageFileCount = $rendererRecords.Count
        RendererOwnedFiles      = @($rendererRecords)
        RendererProxyFile       = 'd3d9.dll'
        RendererProxySha256     = Get-TestFileHash -Path (Join-Path $stageRoot 'd3d9.dll')
        RendererConfigFile      = '.trex\bridge.conf'
        RendererConfigSha256    = Get-TestFileHash -Path (Join-Path $stageRoot '.trex\bridge.conf')
        RendererRuntimeConfigSeedSha256 = Get-TestFileHash -Path $runtimeConfigSeed
        RendererRuntimeConfigSeedPolicy = 'NewStageOnly'
        RendererRuntimeConfigSeedDlssFrameGenerationEnabled = $false
        RendererRuntimeWritableDirectories = @('rtx-remix')
        RendererRuntimeMutableFiles = @('rtx.conf')
        EnginePatchProxyFile    = 'dinput8.dll'
        EnginePatchProxySha256  = Get-TestFileHash -Path (Join-Path $stageRoot 'dinput8.dll')
        EnginePatchConfigFile   = 'EchoPatch.ini'
        EnginePatchConfigSha256 = Get-TestFileHash -Path (Join-Path $stageRoot 'EchoPatch.ini')
    }
    $manifestJson = $manifest | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($manifestPath, $manifestJson, [Text.UTF8Encoding]::new($false))

    $copiedRetailRoot = Join-Path $fixtureRoot 'Copied Known FEAR Binary'
    [void][IO.Directory]::CreateDirectory($copiedRetailRoot)
    [IO.File]::Copy((Join-Path $retailRoot 'FEAR.exe'), (Join-Path $copiedRetailRoot 'FEAR.exe'), $false)
    $originalExpectedHash = & $runtimeExecutableModule { $script:ExpectedSteamFearExecutableHash }
    try {
        & $runtimeExecutableModule {
            param($SyntheticKnownHash)
            $script:ExpectedSteamFearExecutableHash = $SyntheticKnownHash
        } $retailHash
        if (-not (Test-FearSteamRetailInstallation -RetailRoot $copiedRetailRoot -AppId '21090')) {
            throw 'Backward-compatible known-hash registration shortcut was unexpectedly removed.'
        }
        if (Test-FearSteamRetailInstallation -RetailRoot $copiedRetailRoot -AppId '21090' -RequireRegisteredAppManifest) {
            throw 'Strict Steam registration accepted a copied known-hash FEAR.exe without appmanifest binding.'
        }
        $strictRegistered = & {
            $WhatIfPreference = $true
            Test-FearSteamRetailInstallation `
                -RetailRoot $retailRoot `
                -AppId '21090' `
                -RequireRegisteredAppManifest
        }
        if (-not $strictRegistered) {
            throw 'Strict Steam registration rejected the synthetic appmanifest-bound retail root under WhatIf.'
        }
    }
    finally {
        & $runtimeExecutableModule {
            param($ExpectedHash)
            $script:ExpectedSteamFearExecutableHash = $ExpectedHash
        } $originalExpectedHash
    }

    $planArguments = @{
        StageRoot              = $stageRoot
        SteamExecutable        = $steamExecutable
        ExpectedRetailRoot     = $retailRoot
        AdditionalGameArguments = @('+SafeSetting', 'value with spaces', 'literal"quote', 'C:\tail path\')
    }

    $manifest.EnginePatchForceWindowed = $false
    Write-TestJson -Path $manifestPath -Value $manifest
    Assert-TestThrows -Description 'Engine-side RTX windowed contract disabled' -MessagePattern 'windowed contract enabled|EnginePatchForceWindowed=true' -Action {
        New-FearSteamLaunchPlan @planArguments
    }
    $manifest.EnginePatchForceWindowed = $true
    Write-TestJson -Path $manifestPath -Value $manifest
    $manifest.RendererRuntimeConfigSeedDlssFrameGenerationEnabled = $true
    Write-TestJson -Path $manifestPath -Value $manifest
    Assert-TestThrows -Description 'Known-broken DLSS Frame Generation default enabled' -MessagePattern 'DlssFrameGenerationEnabled=false|Frame Generation path seeded off' -Action {
        New-FearSteamLaunchPlan @planArguments
    }
    $manifest.RendererRuntimeConfigSeedDlssFrameGenerationEnabled = $false
    Write-TestJson -Path $manifestPath -Value $manifest

    Assert-TestThrows -Description 'Missing retail-sidecar install record' -MessagePattern 'exact Installed state|ReadyToInstall' -Action {
        New-FearSteamLaunchPlan @planArguments
    }

    $installedResult = & $retailInstaller `
        -Install `
        -StageRoot $stageRoot `
        -RetailRoot $retailRoot `
        -RuntimeConfigSeed $runtimeConfigSeed `
        -Confirm:$false
    if (-not $installedResult.Installed -or $installedResult.Idempotent) {
        throw 'Synthetic retail sidecar package did not install into its disposable fixture.'
    }

    $plan = New-FearSteamLaunchPlan @planArguments
    if ($plan.PlanKind -cne 'FearMore.SteamLaunchPlan' -or $plan.PlanVersion -ne 3 -or
        $plan.AppId -cne '21090' -or $plan.RendererMode -cne 'RtxRemixProbe' -or
        $plan.EnginePatchMode -cne 'RtxCameraDiagnosticEchoPatch' -or
        $plan.RuntimeConfigGraphicsPreset -ne 4 -or
        $plan.RuntimeConfigIntegrateIndirectMode -ne 1 -or
        $plan.RuntimeConfigDlssFrameGenerationEnabled -ne $false -or
        $plan.RetailSidecarState -cne 'Installed' -or $plan.ProcessStarted -or
        $plan.RemixExperimentActive -or $plan.RemixExperimentTransactionId -or
        -not $plan.WorkingDirectory.Equals($retailRoot, [StringComparison]::OrdinalIgnoreCase) -or
        -not $plan.ArchiveConfigPath.Equals((Join-Path $retailRoot 'FearMore.archcfg'), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Valid installed plan did not preserve its exact Steam/RTX/retail-sidecar identity.'
    }
    if ($plan.RetailInstallIdentitySha256 -cne $plan.FreshSidecarPackageIdentitySha256) {
        throw 'Steam launch plan did not bind the installed record to the freshly recomputed sidecar package identity.'
    }
    $initialRetailInstallIdentity = $plan.RetailInstallIdentitySha256
    $initialFreshPackageIdentity = $plan.FreshSidecarPackageIdentitySha256
    $installRecordBytesBeforeProvenanceRefresh = [Convert]::ToBase64String(
        [IO.File]::ReadAllBytes($installRecordPath))
    $manifest | Add-Member `
        -NotePropertyName GeneratedUtc `
        -NotePropertyValue '2026-07-15T00:00:00.0000000Z' `
        -Force
    Write-TestJson -Path $manifestPath -Value $manifest
    $provenanceRefreshPlan = New-FearSteamLaunchPlan @planArguments
    if ($provenanceRefreshPlan.RetailInstallIdentitySha256 -cne $initialRetailInstallIdentity -or
        $provenanceRefreshPlan.FreshSidecarPackageIdentitySha256 -ceq $initialFreshPackageIdentity -or
        $provenanceRefreshPlan.RetailInstallIdentitySha256 -ceq $provenanceRefreshPlan.FreshSidecarPackageIdentitySha256) {
        throw 'Steam launch planning did not preserve historical install provenance while accepting an exact payload after a manifest metadata refresh.'
    }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($installRecordPath)) -cne
        $installRecordBytesBeforeProvenanceRefresh) {
        throw 'Steam launch planning rewrote the historical retail install record after a provenance-only stage refresh.'
    }
    $plan = $provenanceRefreshPlan
    $runtimeConfigPath = Join-Path $retailRoot 'rtx.conf'
    $exactRuntimeConfigBytes = [IO.File]::ReadAllBytes($runtimeConfigPath)
    [IO.File]::WriteAllText(
        $runtimeConfigPath,
        "rtx.graphicsPreset = 4`r`nrtx.integrateIndirectMode = 1`r`nrtx.dlfg.enable = False`r`nrtx.enableRaytracing = True`r`n",
        [Text.UTF8Encoding]::new($false))
    $safeEditedPlan = New-FearSteamLaunchPlan @planArguments
    if ($safeEditedPlan.RuntimeConfigSha256 -ceq $plan.RuntimeConfigSha256 -or
        $safeEditedPlan.RuntimeConfigGraphicsPreset -ne 4) {
        throw 'Steam launch planning did not safely accept and fingerprint an edited config that preserves the required Custom/ReSTIR/DLSSG-off triple.'
    }
    [IO.File]::WriteAllText(
        $runtimeConfigPath,
        "rtx.graphicsPreset = 5`r`nrtx.integrateIndirectMode = 1`r`nrtx.dlfg.enable = False`r`n",
        [Text.UTF8Encoding]::new($false))
    Assert-TestThrows `
        -Description 'Live config that re-enables the Auto/NRC crash path' `
        -MessagePattern 'graphicsPreset = 4|crashing NRC path' `
        -Action { New-FearSteamLaunchPlan @planArguments }
    [IO.File]::WriteAllBytes($runtimeConfigPath, $exactRuntimeConfigBytes)
    $plan = New-FearSteamLaunchPlan @planArguments
    $userConfigPath = Join-Path $retailRoot 'user.conf'
    [IO.File]::WriteAllText(
        $userConfigPath,
        "rtx.graphicsPreset = 5`r`n",
        [Text.UTF8Encoding]::new($false))
    Assert-TestThrows `
        -Description 'Higher-priority user.conf that re-enables Auto/NRC' `
        -MessagePattern 'higher-priority user.conf|crashing NRC path' `
        -Action { New-FearSteamLaunchPlan @planArguments }
    [IO.File]::WriteAllText(
        $userConfigPath,
        "rtx.graphicsPreset = 4`r`nrtx.dlfg.enable = False`r`nrtx.upscaler = 1`r`n",
        [Text.UTF8Encoding]::new($false))
    $safeUserPlan = New-FearSteamLaunchPlan @planArguments
    if (-not $safeUserPlan.UserConfigPresent -or
        [string]::IsNullOrWhiteSpace([string]$safeUserPlan.UserConfigSha256) -or
        $safeUserPlan.PlanFingerprint -ceq $plan.PlanFingerprint) {
        throw 'Steam launch planning did not resolve and fingerprint a safe higher-priority user.conf layer.'
    }
    Remove-Item -LiteralPath $userConfigPath -Force
    $plan = New-FearSteamLaunchPlan @planArguments
    if ($plan.UserConfigPresent -or $plan.UserConfigSha256) {
        throw 'Steam launch planning reported a removed user.conf as present.'
    }

    $experimentTransactionId = '0123456789abcdef0123456789abcdef'
    $experimentConfigText = "# Temporary FearMore RTX Remix compatibility experiment. Restored after the exact game process exits.`r`nrtx.graphicsPreset = 4`r`nrtx.integrateIndirectMode = 1`r`nrtx.dlfg.enable = False`r`nrtx.enableAlphaBlend = False`r`n"
    [IO.File]::WriteAllText($userConfigPath, $experimentConfigText, [Text.UTF8Encoding]::new($false))
    $experimentConfigHash = Get-TestFileHash -Path $userConfigPath
    $experimentJournalPath = Join-Path $retailRoot 'fearmore-remix-experiment.transaction.json'
    $experimentJournal = [pscustomobject][ordered]@{
        JournalKind='FearMore.RemixExperimentTransaction'; SchemaVersion=1; State='Applied';
        TransactionId=$experimentTransactionId; GeneratedUtc='2026-07-15T00:00:00.0000000Z';
        RetailRoot=$retailRoot; StageRoot=$stageRoot; InstallIdentitySha256=$plan.RetailInstallIdentitySha256;
        Experiment='AlphaBlendOff'; Variant='Candidate'; SettingName='rtx.enableAlphaBlend'; SettingValue='False';
        UserConfigRelativePath='user.conf'; BackupRelativePath='fearmore-remix-experiment.user-conf.previous';
        CandidateRelativePath='fearmore-remix-experiment.user-conf.candidate';
        RestoreRelativePath='fearmore-remix-experiment.user-conf.restore';
        OriginalUserConfigPresent=$false; OriginalUserConfigSize=0L; OriginalUserConfigSha256=$null;
        GeneratedUserConfigSize=(Get-Item -LiteralPath $userConfigPath).Length;
        GeneratedUserConfigSha256=$experimentConfigHash
    }
    Write-TestJson -Path $experimentJournalPath -Value $experimentJournal
    Assert-TestThrows `
        -Description 'Normal RtxLab launch during an active transient experiment' `
        -MessagePattern 'experiment transaction|normal RtxLab launch is blocked' `
        -Action { New-FearSteamLaunchPlan @planArguments }
    $experimentPlanArguments = $planArguments.Clone()
    $experimentPlanArguments.ExpectedRemixExperimentTransactionId = $experimentTransactionId
    $authorizedExperimentPlan = New-FearSteamLaunchPlan @experimentPlanArguments
    if (-not $authorizedExperimentPlan.RemixExperimentActive -or
        $authorizedExperimentPlan.RemixExperimentTransactionId -cne $experimentTransactionId -or
        $authorizedExperimentPlan.UserConfigSha256 -cne $experimentConfigHash) {
        throw 'Steam launch planning did not bind the exact applied RTX Remix experiment transaction and user.conf.'
    }
    $wrongExperimentArguments = $planArguments.Clone()
    $wrongExperimentArguments.ExpectedRemixExperimentTransactionId = 'fedcba9876543210fedcba9876543210'
    Assert-TestThrows `
        -Description 'Mismatched RTX Remix experiment authorization' `
        -MessagePattern 'authorization does not match' `
        -Action { New-FearSteamLaunchPlan @wrongExperimentArguments }
    Remove-Item -LiteralPath $experimentJournalPath -Force
    Remove-Item -LiteralPath $userConfigPath -Force
    $plan = New-FearSteamLaunchPlan @planArguments
    Assert-TestSequence -Description 'owned game arguments' -Actual $plan.OwnedGameArguments -Expected @(
        '-userdirectory', $userDirectory, '-archcfg', 'FearMore.archcfg', '+FearMoreCameraDiagnostics', '1')
    Assert-TestSequence -Description 'Steam launch prefix and game arguments' -Actual $plan.SteamArguments -Expected @(
        '-applaunch', '21090', '-userdirectory', $userDirectory, '-archcfg', 'FearMore.archcfg',
        '+FearMoreCameraDiagnostics', '1', '+SafeSetting', 'value with spaces', 'literal"quote', 'C:\tail path\')

    $quotingCases = @(
        [pscustomobject]@{ Value='simple'; Expected='simple' },
        [pscustomobject]@{ Value=''; Expected='""' },
        [pscustomobject]@{ Value='two words'; Expected='"two words"' },
        [pscustomobject]@{ Value='say "fear"'; Expected='"say \"fear\""' },
        [pscustomobject]@{ Value='C:\path with space\'; Expected='"C:\path with space\\"' }
    )
    foreach ($case in $quotingCases) {
        $actual = ConvertTo-FearWindowsCommandLineArgument -Value $case.Value
        if ($actual -cne $case.Expected) {
            throw "Windows argument quoting mismatch for '$($case.Value)': '$actual' != '$($case.Expected)'."
        }
    }
    if ($plan.ArgumentString -cne (Join-FearWindowsCommandLineArguments -Arguments $plan.SteamArguments)) {
        throw 'Steam plan command line is not the exact robustly quoted argument sequence.'
    }

    foreach ($ownedOverride in @(
            '-userdirectory', '-USERDIRECTORY=C:\outside', '+UserDirectory:C:\outside',
            '-archcfg', '/archcfg:Default.archcfg', 'archcfg=Default.archcfg', '+FearMoreCameraDiagnostics',
            'FearMoreCameraDiagnostics=0')) {
        Assert-TestThrows -Description "Owned override '$ownedOverride'" -Action {
            New-FearSteamLaunchPlan `
                -StageRoot $stageRoot `
                -SteamExecutable $steamExecutable `
                -ExpectedRetailRoot $retailRoot `
                -AdditionalGameArguments @($ownedOverride)
        }
    }
    foreach ($nearCollision in @('-archcfgbackup', '+FearMoreCameraDiagnosticsBackup', '+UserDirectoryBackup')) {
        $nearPlan = New-FearSteamLaunchPlan `
            -StageRoot $stageRoot `
            -SteamExecutable $steamExecutable `
            -ExpectedRetailRoot $retailRoot `
            -AdditionalGameArguments @($nearCollision)
        if (@($nearPlan.AdditionalGameArguments).Count -ne 1) {
            throw "Near-collision argument '$nearCollision' was not preserved."
        }
    }

    $originalArchiveBytes = [IO.File]::ReadAllBytes((Join-Path $retailRoot 'FearMore.archcfg'))
    [IO.File]::WriteAllText((Join-Path $retailRoot 'FearMore.archcfg'), 'tampered', [Text.ASCIIEncoding]::new())
    Assert-TestThrows -Description 'Tampered installed FearMore.archcfg' -MessagePattern 'Immutable FearMore sidecar file changed' -Action {
        New-FearSteamLaunchPlan @planArguments
    }
    [IO.File]::WriteAllBytes((Join-Path $retailRoot 'FearMore.archcfg'), $originalArchiveBytes)

    $validInstallRecordBytes = [IO.File]::ReadAllBytes($installRecordPath)
    $wrongManifestHash = ('A' * 64)
    $recordObject = Get-Content -LiteralPath $installRecordPath -Raw | ConvertFrom-Json
    $recordObject.StageManifestSha256 = $wrongManifestHash
    Write-TestJson -Path $installRecordPath -Value $recordObject
    Assert-TestThrows -Description 'Install record with inconsistent historical provenance' -MessagePattern 'historical package identity is inconsistent' -Action {
        New-FearSteamLaunchPlan @planArguments
    }
    [IO.File]::WriteAllBytes($installRecordPath, $validInstallRecordBytes)

    $recordObject = Get-Content -LiteralPath $installRecordPath -Raw | ConvertFrom-Json
    $recordObject.RuntimeWritablePolicy = 'OwnedAndRemoved'
    Write-TestJson -Path $installRecordPath -Value $recordObject
    Assert-TestThrows -Description 'Install record with broadened runtime-writable policy' -MessagePattern 'runtime-writable preservation policy' -Action {
        New-FearSteamLaunchPlan @planArguments
    }
    [IO.File]::WriteAllBytes($installRecordPath, $validInstallRecordBytes)

    $recordObject = Get-Content -LiteralPath $installRecordPath -Raw | ConvertFrom-Json
    $reorderedOwnedDirectories = @($recordObject.OwnedDirectories)
    [array]::Reverse($reorderedOwnedDirectories)
    $recordObject.OwnedDirectories = @($reorderedOwnedDirectories)
    Write-TestJson -Path $installRecordPath -Value $recordObject
    Assert-TestThrows -Description 'Reordered OwnedDirectories install record' -MessagePattern 'owned-directory set' -Action {
        New-FearSteamLaunchPlan @planArguments
    }
    [IO.File]::WriteAllBytes($installRecordPath, $validInstallRecordBytes)

    $recordObject = Get-Content -LiteralPath $installRecordPath -Raw | ConvertFrom-Json
    $reorderedProtectedFiles = @($recordObject.ProtectedFiles)
    [array]::Reverse($reorderedProtectedFiles)
    $recordObject.ProtectedFiles = @($reorderedProtectedFiles)
    Write-TestJson -Path $installRecordPath -Value $recordObject
    Assert-TestThrows -Description 'Reordered ProtectedFiles install record' -MessagePattern 'protected retail file set' -Action {
        New-FearSteamLaunchPlan @planArguments
    }
    [IO.File]::WriteAllBytes($installRecordPath, $validInstallRecordBytes)

    $recordObject = Get-Content -LiteralPath $installRecordPath -Raw | ConvertFrom-Json
    $immutableRecord = @($recordObject.ImmutableFiles | Where-Object { [string]$_.RelativePath -ceq 'd3d9.dll' })[0]
    $installedImmutablePath = Join-Path $retailRoot 'd3d9.dll'
    $validImmutableBytes = [IO.File]::ReadAllBytes($installedImmutablePath)
    [IO.File]::WriteAllText($installedImmutablePath, 'coherently tampered renderer proxy', [Text.UTF8Encoding]::new($false))
    $immutableRecord.Size = (Get-Item -LiteralPath $installedImmutablePath).Length
    $immutableRecord.Sha256 = Get-TestFileHash -Path $installedImmutablePath
    Set-TestInstallRecordIdentity -Record $recordObject
    Write-TestJson -Path $installRecordPath -Value $recordObject
    Assert-TestThrows -Description 'Consistently rehashed immutable install-record tamper' -MessagePattern 'immutable file set does not exactly match' -Action {
        New-FearSteamLaunchPlan @planArguments
    }
    [IO.File]::WriteAllBytes($installedImmutablePath, $validImmutableBytes)
    [IO.File]::WriteAllBytes($installRecordPath, $validInstallRecordBytes)
    $plan = New-FearSteamLaunchPlan @planArguments

    $sessionId = 47
    $steamSnapshot = @([pscustomobject]@{
            Id=101; ProcessName='steam'; SessionId=$sessionId; Path=$steamExecutable; HasExited=$false })
    $validClient = & $steamModule {
        param($Executable, $Snapshot, $Session)
        Test-FearSteamClientSnapshot -SteamExecutable $Executable -ProcessSnapshot $Snapshot -CurrentSessionId $Session
    } $steamExecutable $steamSnapshot $sessionId
    if (-not $validClient.IsValid -or @($validClient.MatchingProcessIds)[0] -ne 101) {
        throw 'Exact same-session Steam client snapshot was rejected.'
    }
    Assert-TestThrows `
        -Description 'Public Steam preflight without an exact running client' `
        -MessagePattern 'No running Steam client with the exact executable path' `
        -Action { Get-FearRunningSteamClientIdentity -SteamExecutable $steamExecutable }
    foreach ($invalidSteamSnapshot in @(
            @([pscustomobject]@{ Id=102; ProcessName='steam'; SessionId=48; Path=$steamExecutable; HasExited=$false }),
            @([pscustomobject]@{ Id=103; ProcessName='steam'; SessionId=$sessionId; Path=(Join-Path $fixtureRoot 'other\steam.exe'); HasExited=$false }),
            @([pscustomobject]@{ Id=104; ProcessName='steam'; SessionId=$sessionId; Path=$steamExecutable; HasExited=$true }))) {
        $assessment = & $steamModule {
            param($Executable, $Snapshot, $Session)
            Test-FearSteamClientSnapshot -SteamExecutable $Executable -ProcessSnapshot $Snapshot -CurrentSessionId $Session
        } $steamExecutable $invalidSteamSnapshot $sessionId
        if ($assessment.IsValid) { throw 'Steam live-client gate accepted a wrong path/session/exited snapshot.' }
    }

    $dispatches = [Collections.Generic.List[object]]::new()
    $processStarter = {
        param($FilePath, $Arguments, $WorkingDirectory)
        $dispatches.Add([pscustomobject]@{ FilePath=$FilePath; Arguments=$Arguments; WorkingDirectory=$WorkingDirectory })
        return [pscustomobject]@{ Id=202 }
    }.GetNewClosure()
    $retailProcessSnapshotProvider = {
        return @([pscustomobject]@{
                Id=303; ProcessName='FEAR'; SessionId=$sessionId;
                Path=(Join-Path $retailRoot 'FEAR.exe'); HasExited=$false })
    }.GetNewClosure()
    $noDelay = { param($Milliseconds) }
    $dispatchResult = & $steamModule {
        param($Plan, $SteamSnapshot, $Session, $Starter, $GameProvider, $Delay)
        Invoke-FearSteamLaunchPlanCore `
            -Plan $Plan `
            -ProcessSnapshot $SteamSnapshot `
            -CurrentSessionId $Session `
            -ProcessStarter $Starter `
            -PreDispatchRetailProcessSnapshot @() `
            -RetailProcessSnapshotProvider $GameProvider `
            -Delay $Delay `
            -GameStartTimeoutMilliseconds 1000
    } $plan $steamSnapshot $sessionId $processStarter $retailProcessSnapshotProvider $noDelay
    if ($dispatches.Count -ne 1 -or $dispatches[0].FilePath -cne $steamExecutable -or
        $dispatches[0].Arguments -cne $plan.ArgumentString -or
        -not $dispatches[0].WorkingDirectory.Equals($retailRoot, [StringComparison]::OrdinalIgnoreCase) -or
        $dispatchResult.SteamDispatchProcessId -ne 202 -or -not $dispatchResult.GameProcessObserved -or
        $dispatchResult.GameProcessId -ne 303 -or -not $dispatchResult.ProcessStarted) {
        throw "Synthetic dispatch did not report the exact retail FEAR.exe independently of the Steam helper PID. Calls=$($dispatches | ConvertTo-Json -Compress) Result=$($dispatchResult | ConvertTo-Json -Depth 3 -Compress)"
    }

    # This exercises public SupportsShouldProcess validation while returning
    # before both live Steam enumeration and process dispatch.
    Invoke-FearSteamLaunchPlan -Plan $plan -WhatIf

    $manifest.RendererMode = 'NativeD3D9'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-TestThrows -Description 'Wrong renderer stage manifest' -Action {
        New-FearSteamLaunchPlan @planArguments
    }
    $manifest.RendererMode = 'RtxRemixProbe'
    $manifest.SchemaVersion = '9'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Assert-TestThrows -Description 'String-valued manifest schema' -Action {
        New-FearSteamLaunchPlan @planArguments
    }

    [pscustomobject][ordered]@{
        SteamLaunchPlanValidated         = $true
        StrictAppManifestBindingValidated = $true
        RetailSidecarInstalledValidated  = $true
        SafeLiveRuntimeConfigValidated   = $true
        HigherPriorityUserConfigValidated = $true
        TransientExperimentAuthorizationValidated = $true
        FreshSidecarPlanBindingValidated = $true
        ManifestProvenanceDriftValidated = $true
        HistoricalInstallRecordPreserved = $true
        RuntimeWritablePolicyTamperRejected = $true
        OwnedDirectoriesTamperRejected   = $true
        ProtectedFilesTamperRejected     = $true
        RehashedImmutableTamperRejected  = $true
        CommandLineQuotingValidated      = $true
        OwnedOverrideRejectionValidated  = $true
        ExactSteamClientGateValidated    = $true
        PublicSteamPreflightValidated    = $true
        ActualRetailProcessPollValidated = $true
        WhatIfLaunchedProcess             = $false
        RealSteamInteracted               = $false
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $canonicalFixture = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
        $canonicalTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if (-not $canonicalFixture.StartsWith($canonicalTemp + '\', [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path $canonicalFixture -Leaf) -cne "fearmore-steam-launch-test-$runId") {
            throw "Refusing to remove unexpected Steam launch fixture path: $canonicalFixture"
        }
        Remove-Item -LiteralPath $canonicalFixture -Recurse -Force
    }
}
