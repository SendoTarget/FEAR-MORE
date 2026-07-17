[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installer = Join-Path $PSScriptRoot 'Install-FearMoreRetailSidecars.ps1'
$seed = Join-Path $PSScriptRoot 'config\rtx-remix-runtime.conf'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$localRuntimeRoot = Join-Path $repositoryRoot 'local-runtime'
$testRoot = Join-Path $localRuntimeRoot "retail-sidecar-install-test-$([guid]::NewGuid().ToString('N'))"
$powershellExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$fearVersion = [string](Get-Item -LiteralPath $powershellExe).VersionInfo.FileVersion
$engineOnlyEchoPatchConfig = Join-Path $repositoryRoot 'tools\echopatch\EchoPatch.engine-only.ini'

function Write-TestBytes {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    $parent = Split-Path $Path -Parent
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent) }
    [IO.File]::WriteAllBytes($Path, [Text.UTF8Encoding]::new($false).GetBytes($Text))
}

function Get-TestHash {
    param([Parameter(Mandatory)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function New-TestFileRecord {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    $path = Join-Path $Root $RelativePath
    [pscustomobject][ordered]@{ RelativePath=$RelativePath; Size=(Get-Item -LiteralPath $path).Length; Sha256=(Get-TestHash $path) }
}

function New-SidecarFixture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [ValidateSet('CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch')]
        [string]$EnginePatchMode = 'CameraDiagnosticEchoPatch'
    )
    $root = Join-Path $testRoot $Name
    $retail = Join-Path $root 'Retail'
    $stage = Join-Path $root 'Stage'
    [void](New-Item -ItemType Directory -Path $retail)
    [void](New-Item -ItemType Directory -Path (Join-Path $stage '.trex'))
    [void](New-Item -ItemType Directory -Path (Join-Path $stage 'Game'))
    Copy-Item -LiteralPath $powershellExe -Destination (Join-Path $retail 'FEAR.exe')
    Copy-Item -LiteralPath $powershellExe -Destination (Join-Path $stage 'FEAR.exe')
    Write-TestBytes (Join-Path $retail 'FEAR.Arch00') "retail archive $Name"
    Write-TestBytes (Join-Path $retail 'Default.archcfg') "FEAR.Arch00`r`n"
    Write-TestBytes (Join-Path $stage 'Default.archcfg') "Retail\FEAR.Arch00`r`nGame`r`n"

    foreach ($file in @(
        [pscustomobject]@{ Path='d3d9.dll'; Text="renderer proxy $Name" },
        [pscustomobject]@{ Path='.trex\payload.dll'; Text="renderer payload $Name" },
        [pscustomobject]@{ Path='LICENSE.txt'; Text="renderer license $Name" },
        [pscustomobject]@{ Path='.trex\bridge.conf'; Text="bridge config $Name" },
        [pscustomobject]@{ Path='dinput8.dll'; Text="camera diagnostic proxy $Name" },
        [pscustomobject]@{ Path='EchoPatch.ini'; Text="camera diagnostic config $Name" },
        [pscustomobject]@{ Path='Game\GameClient.dll'; Text="rebuilt client $Name" },
        [pscustomobject]@{ Path='Game\GameServer.dll'; Text="rebuilt server $Name" },
        [pscustomobject]@{ Path='Game\ClientFx.fxd'; Text="rebuilt client fx $Name" }
    )) { Write-TestBytes (Join-Path $stage $file.Path) $file.Text }

    $rtxEchoPatchConfig = [IO.File]::ReadAllText($engineOnlyEchoPatchConfig)
    $rtxEchoPatchConfig = [regex]::Replace(
        $rtxEchoPatchConfig,
        '(?m)^(?<Prefix>[ \t]*ForceWindowed[ \t]*=[ \t]*)0[ \t]*$',
        '${Prefix}1')
    $rtxEchoPatchConfig = $rtxEchoPatchConfig.TrimEnd("`r", "`n") +
        "`r`n`r`n[Diagnostics]`r`nCameraDiagnostics = 1`r`n"
    if ($EnginePatchMode -ceq 'RtxCameraDiagnosticEchoPatch') {
        $rtxEchoPatchConfig = [regex]::Replace(
            $rtxEchoPatchConfig,
            '(?m)^(?<Line>[ \t]*PatchGameModules[ \t]*=[ \t]*0[ \t]*)$',
            '${Line}' + "`r`nPreserveRtxRendererOnFocusChange = 1")
    }
    Write-TestBytes (Join-Path $stage 'EchoPatch.ini') $rtxEchoPatchConfig

    $rendererRecords = @('d3d9.dll', '.trex\payload.dll', 'LICENSE.txt') | ForEach-Object { New-TestFileRecord $stage $_ }
    $moduleRecords = @('GameClient.dll', 'GameServer.dll', 'ClientFx.fxd') | ForEach-Object {
        [pscustomobject][ordered]@{ Name=$_; Path=(Join-Path $stage "Game\$_"); FileVersion=$null; Sha256=(Get-TestHash (Join-Path $stage "Game\$_")) }
    }
    $manifest = [pscustomobject][ordered]@{
        SchemaVersion=9; Lane='Rebuilt'; Configuration='Release'; RendererMode='RtxRemixProbe'; EnginePatchMode=$EnginePatchMode;
        FearVersion=$fearVersion; RuntimeExecutable='FEAR.exe'; RuntimeExecutableSha256=(Get-TestHash (Join-Path $stage 'FEAR.exe'));
        RetailExecutableSha256=(Get-TestHash (Join-Path $retail 'FEAR.exe')); RetailRoot=$retail;
        ArchiveEntries=@('Retail\FEAR.Arch00', 'Game'); Modules=$moduleRecords;
        RendererPackageFileCount=$rendererRecords.Count; RendererOwnedFiles=$rendererRecords;
        RendererProxyFile='d3d9.dll'; RendererProxySha256=(Get-TestHash (Join-Path $stage 'd3d9.dll'));
        RendererConfigFile='.trex\bridge.conf'; RendererConfigSha256=(Get-TestHash (Join-Path $stage '.trex\bridge.conf'));
        RendererRuntimeConfigSeedSha256=(Get-TestHash $seed); RendererRuntimeConfigSeedPolicy='NewStageOnly';
        RendererRuntimeConfigSeedDlssFrameGenerationEnabled=$false;
        RendererRuntimeWritableDirectories=@('rtx-remix'); RendererRuntimeMutableFiles=@('rtx.conf');
        EnginePatchProxyFile='dinput8.dll'; EnginePatchProxySha256=(Get-TestHash (Join-Path $stage 'dinput8.dll'));
        EnginePatchConfigFile='EchoPatch.ini'; EnginePatchConfigSha256=(Get-TestHash (Join-Path $stage 'EchoPatch.ini'))
        EnginePatchForceWindowed=$true; EnginePatchFixWindowStyle=$true
        InputsValidated=$true; LayoutValidated=$true; LaunchPermitted=$true; SteamAppId='21090'
    }
    [IO.File]::WriteAllText((Join-Path $stage 'fearmore-stage.json'), ($manifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ Root=$root; Retail=$retail; Stage=$stage; Manifest=$manifest }
}

function Get-ProtectedSnapshot {
    param([Parameter(Mandatory)]$Fixture)
    @('FEAR.exe', 'Default.archcfg', 'FEAR.Arch00') | ForEach-Object {
        $path = Join-Path $Fixture.Retail $_
        [pscustomobject]@{ RelativePath=$_; Size=(Get-Item $path).Length; Hash=(Get-TestHash $path) }
    }
}

function Assert-ProtectedUnchanged {
    param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][object[]]$Snapshot)
    foreach ($record in $Snapshot) {
        $path = Join-Path $Fixture.Retail $record.RelativePath
        if ((Get-Item $path).Length -ne $record.Size -or (Get-TestHash $path) -cne $record.Hash) {
            throw "Synthetic retail original changed: $path"
        }
    }
}

function Invoke-Installer {
    param([Parameter(Mandatory)]$Fixture, [Parameter(Mandatory)][ValidateSet('Install','Uninstall','Validate','RetireUninstallReceipt')][string]$Action, [int]$FailAfter=0)
    $arguments = @{ StageRoot=$Fixture.Stage; RetailRoot=$Fixture.Retail; RuntimeConfigSeed=$seed; Confirm=$false }
    $arguments[$Action] = $true
    if ($FailAfter -gt 0) { $arguments.TestFailureAfterWriteCount = $FailAfter }
    & $installer @arguments
}

function Assert-NotExists {
    param([Parameter(Mandatory)][string[]]$Paths)
    foreach ($path in $Paths) { if (Test-Path -LiteralPath $path) { throw "Unexpected synthetic sidecar path remains: $path" } }
}

function Remove-TestRootSafely {
    if (-not (Test-Path -LiteralPath $testRoot)) { return }
    $canonicalRoot = [IO.Path]::GetFullPath($testRoot).TrimEnd('\')
    $canonicalParent = [IO.Path]::GetFullPath($localRuntimeRoot).TrimEnd('\')
    if (-not $canonicalRoot.StartsWith($canonicalParent + '\retail-sidecar-install-test-', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Synthetic cleanup target escaped its exact allowlist: $canonicalRoot"
    }
    $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($canonicalRoot)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        $item = Get-Item -LiteralPath $directory -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Synthetic cleanup refuses reparse point: $directory" }
        foreach ($child in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if (($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Synthetic cleanup refuses reparse point: $($child.FullName)" }
            if ($child.PSIsContainer) { $queue.Enqueue($child.FullName) }
        }
    }
    Remove-Item -LiteralPath $canonicalRoot -Recurse -Force
}

[void](New-Item -ItemType Directory -Path $testRoot)
$testPassed = $false
try {
    $main = New-SidecarFixture 'main'
    $mainProtected = @(Get-ProtectedSnapshot $main)
    $validation = Invoke-Installer $main Validate
    if (-not $validation.Validated -or $validation.State -ne 'ReadyToInstall') { throw 'Synthetic pre-install validation did not report ReadyToInstall.' }

    $rtxFocusMode = New-SidecarFixture -Name 'rtx-focus-mode' -EnginePatchMode 'RtxCameraDiagnosticEchoPatch'
    $rtxFocusValidation = Invoke-Installer $rtxFocusMode Validate
    if (-not $rtxFocusValidation.Validated -or $rtxFocusValidation.State -ne 'ReadyToInstall') {
        throw 'The focus-preserved RTX engine patch mode was rejected by retail-sidecar planning.'
    }
    $unsupportedModeManifestPath = Join-Path $rtxFocusMode.Stage 'fearmore-stage.json'
    $unsupportedModeManifest = Get-Content -LiteralPath $unsupportedModeManifestPath -Raw | ConvertFrom-Json
    $unsupportedModeManifest.EnginePatchMode = 'EngineOnlyEchoPatch'
    [IO.File]::WriteAllText(
        $unsupportedModeManifestPath,
        ($unsupportedModeManifest | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false))
    $unsupportedModeRejected = $false
    try { Invoke-Installer $rtxFocusMode Validate | Out-Null }
    catch { $unsupportedModeRejected = $_.Exception.Message.Contains('supported engine patch modes') }
    if (-not $unsupportedModeRejected) {
        throw 'Retail-sidecar planning accepted an unsupported engine patch mode.'
    }

    # Exercise the actual Windows PowerShell -File entry point and its default seed resolution.
    $processOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Validate `
        -StageRoot $main.Stage -RetailRoot $main.Retail 2>&1
    if ($LASTEXITCODE -ne 0 -or ($processOutput -join "`n") -notmatch 'ReadyToInstall') {
        throw "Out-of-process Windows PowerShell validation failed: $($processOutput -join ' ')"
    }
    $whatIfOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Install `
        -StageRoot $main.Stage -RetailRoot $main.Retail -WhatIf 2>&1
    if ($LASTEXITCODE -ne 0 -or (Test-Path -LiteralPath (Join-Path $main.Retail 'd3d9.dll')) -or
        (Test-Path -LiteralPath (Join-Path $main.Retail 'fearmore-live-install.json'))) {
        throw "Out-of-process Windows PowerShell -Install -WhatIf failed or mutated the target: $($whatIfOutput -join ' ')"
    }

    $installed = Invoke-Installer $main Install
    if (-not $installed.Installed -or $installed.Idempotent) { throw 'Synthetic first install did not commit.' }
    Assert-ProtectedUnchanged $main $mainProtected
    foreach ($relativePath in @('d3d9.dll','.trex\payload.dll','.trex\bridge.conf','LICENSE.txt','dinput8.dll','EchoPatch.ini',
        'FearMoreGame\GameClient.dll','FearMoreGame\GameServer.dll','FearMoreGame\ClientFx.fxd','FearMore.archcfg','rtx.conf','fearmore-live-install.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $main.Retail $relativePath) -PathType Leaf)) { throw "Installed sidecar is missing: $relativePath" }
    }
    $archiveConfig = Get-Content -LiteralPath (Join-Path $main.Retail 'FearMore.archcfg') -Raw
    if ($archiveConfig -notmatch '(?m)^FEAR\.Arch00\r?$' -or $archiveConfig -notmatch '(?m)^FearMoreGame\r?$') { throw 'Generated FearMore.archcfg is incomplete.' }
    $idempotent = Invoke-Installer $main Install
    if (-not $idempotent.Idempotent -or $idempotent.RuntimeConfigStatus -ne 'ExactSeed') { throw 'Exact-owned reinstall was not idempotent.' }

    # Runtime-stage revalidation refreshes provenance-only manifest fields.
    # That must not turn an exact installed payload into an unsupported
    # upgrade, while the immutable/runtime/protected sequence gates remain the
    # package-equivalence authority.
    $mainInstallRecordPath = Join-Path $main.Retail 'fearmore-live-install.json'
    $mainInstallRecordBytesBeforeProvenanceRefresh = [Convert]::ToBase64String(
        [IO.File]::ReadAllBytes($mainInstallRecordPath))
    $mainInstallRecordBeforeProvenanceRefresh = Get-Content -LiteralPath $mainInstallRecordPath -Raw | ConvertFrom-Json
    $mainImmutableBeforeProvenanceRefresh = @($mainInstallRecordBeforeProvenanceRefresh.ImmutableFiles | ForEach-Object {
        $installedPath = Join-Path $main.Retail ([string]$_.RelativePath)
        [pscustomobject]@{
            RelativePath = [string]$_.RelativePath
            Size = (Get-Item -LiteralPath $installedPath).Length
            Sha256 = Get-TestHash $installedPath
        }
    })
    $mainManifestPath = Join-Path $main.Stage 'fearmore-stage.json'
    $mainManifest = Get-Content -LiteralPath $mainManifestPath -Raw | ConvertFrom-Json
    $mainManifest | Add-Member -NotePropertyName GeneratedUtc -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
    [IO.File]::WriteAllText($mainManifestPath, ($mainManifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $provenanceDriftRerun = Invoke-Installer $main Install
    if (-not $provenanceDriftRerun.Idempotent -or $provenanceDriftRerun.RuntimeConfigStatus -ne 'ExactSeed') {
        throw 'A provenance-only stage-manifest refresh broke exact installed-package idempotence.'
    }
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($mainInstallRecordPath)) -cne
        $mainInstallRecordBytesBeforeProvenanceRefresh) {
        throw 'A provenance-only stage-manifest refresh rewrote the historical retail install record.'
    }
    foreach ($snapshot in $mainImmutableBeforeProvenanceRefresh) {
        $installedPath = Join-Path $main.Retail $snapshot.RelativePath
        if ((Get-Item -LiteralPath $installedPath).Length -ne $snapshot.Size -or
            (Get-TestHash $installedPath) -cne $snapshot.Sha256) {
            throw "A provenance-only stage-manifest refresh changed installed immutable bytes: $($snapshot.RelativePath)"
        }
    }

    Remove-Item -LiteralPath (Join-Path $main.Retail 'rtx.conf') -Force
    $missingConfigRerun = Invoke-Installer $main Install
    if (-not $missingConfigRerun.Idempotent -or $missingConfigRerun.RuntimeConfigStatus -ne 'Missing' -or
        (Test-Path -LiteralPath (Join-Path $main.Retail 'rtx.conf'))) { throw 'Idempotent reinstall recreated a deliberately deleted runtime config.' }
    Write-TestBytes (Join-Path $main.Retail 'rtx.conf') 'user-edited runtime config'
    [void](New-Item -ItemType Directory -Path (Join-Path $main.Retail 'rtx-remix'))
    Write-TestBytes (Join-Path $main.Retail 'rtx-remix\user-state.bin') 'runtime state'
    $editedConfigRerun = Invoke-Installer $main Install
    if ($editedConfigRerun.RuntimeConfigStatus -ne 'Changed' -or (Get-Content -Raw (Join-Path $main.Retail 'rtx.conf')) -cne 'user-edited runtime config') {
        throw 'Idempotent reinstall did not preserve an edited runtime config.'
    }
    $uninstalled = Invoke-Installer $main Uninstall
    if (-not $uninstalled.Uninstalled -or -not $uninstalled.RuntimeConfigPreserved -or
        -not (Test-Path (Join-Path $main.Retail 'rtx.conf')) -or -not (Test-Path (Join-Path $main.Retail 'rtx-remix\user-state.bin')) -or
        -not (Test-Path (Join-Path $main.Retail 'fearmore-live-uninstall.json'))) {
        throw 'Uninstall did not preserve mutable config/runtime state.'
    }
    Assert-NotExists @((Join-Path $main.Retail 'd3d9.dll'), (Join-Path $main.Retail '.trex'),
        (Join-Path $main.Retail 'FearMoreGame'), (Join-Path $main.Retail 'FearMore.archcfg'),
        (Join-Path $main.Retail 'fearmore-live-install.json'))
    Assert-ProtectedUnchanged $main $mainProtected
    $reinstalled = Invoke-Installer $main Install
    if (-not $reinstalled.Installed -or $reinstalled.Idempotent -or $reinstalled.RuntimeConfigStatus -ne 'Changed' -or
        (Get-Content -Raw (Join-Path $main.Retail 'rtx.conf')) -cne 'user-edited runtime config' -or
        (Test-Path (Join-Path $main.Retail 'fearmore-live-uninstall.json'))) {
        throw 'Receipt-authorized reinstall did not preserve the edited runtime config and retire its receipt.'
    }
    $secondUninstall = Invoke-Installer $main Uninstall
    if (-not $secondUninstall.RuntimeConfigPreserved -or -not (Test-Path (Join-Path $main.Retail 'rtx.conf')) -or
        -not (Test-Path (Join-Path $main.Retail 'fearmore-live-uninstall.json'))) {
        throw 'Second uninstall did not preserve the re-adopted runtime config.'
    }
    $mainReceiptPath = Join-Path $main.Retail 'fearmore-live-uninstall.json'
    $mainReceiptBytes = [IO.File]::ReadAllBytes($mainReceiptPath)
    $mainReceipt = Get-Content -LiteralPath $mainReceiptPath -Raw | ConvertFrom-Json
    $mainReceipt.InstallIdentitySha256 = ('A' * 64)
    [IO.File]::WriteAllText($mainReceiptPath, ($mainReceipt | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $receiptIdentityRejected = $false
    try { Invoke-Installer $main Validate | Out-Null }
    catch { $receiptIdentityRejected = $_.Exception.Message.Contains('historical package identity is inconsistent') }
    if (-not $receiptIdentityRejected) {
        throw 'An uninstall receipt with a tampered historical identity was accepted.'
    }
    [IO.File]::WriteAllBytes($mainReceiptPath, $mainReceiptBytes)
    $preservedReceiptRetirementRejected = $false
    try { Invoke-Installer $main RetireUninstallReceipt | Out-Null }
    catch { $preservedReceiptRetirementRejected = $_.Exception.Message.Contains('runtime config is absent') }
    if (-not $preservedReceiptRetirementRejected -or
        -not (Test-Path (Join-Path $main.Retail 'fearmore-live-uninstall.json')) -or
        (Get-Content -Raw (Join-Path $main.Retail 'rtx.conf')) -cne 'user-edited runtime config') {
        throw 'Receipt retirement did not fail closed around preserved user runtime configuration.'
    }

    $cleanCycle = New-SidecarFixture 'clean-seed-cycle'
    Invoke-Installer $cleanCycle Install | Out-Null
    $cleanUninstall = Invoke-Installer $cleanCycle Uninstall
    if ($cleanUninstall.RuntimeConfigPreserved -or (Test-Path (Join-Path $cleanCycle.Retail 'rtx.conf'))) {
        throw 'Clean uninstall did not remove the unchanged installer seed.'
    }
    $cleanReceipt = Get-Content -LiteralPath (Join-Path $cleanCycle.Retail 'fearmore-live-uninstall.json') -Raw | ConvertFrom-Json
    if ([string]$cleanReceipt.RuntimeConfigStatus -cne 'RemovedSeed') { throw 'Clean uninstall receipt did not record RemovedSeed.' }
    $cleanReinstall = Invoke-Installer $cleanCycle Install
    if ($cleanReinstall.RuntimeConfigStatus -ne 'ExactSeed' -or
        (Get-TestHash (Join-Path $cleanCycle.Retail 'rtx.conf')) -cne (Get-TestHash $seed) -or
        (Test-Path (Join-Path $cleanCycle.Retail 'fearmore-live-uninstall.json'))) {
        throw 'Receipt-authorized clean reinstall did not recreate the tracked Remix mode-1 seed.'
    }
    Invoke-Installer $cleanCycle Uninstall | Out-Null
    $retiredReceipt = Invoke-Installer $cleanCycle RetireUninstallReceipt
    if (-not $retiredReceipt.Retired -or $retiredReceipt.RuntimeConfigStatus -cne 'RemovedSeed' -or
        (Test-Path (Join-Path $cleanCycle.Retail 'fearmore-live-uninstall.json'))) {
        throw 'Clean uninstall receipt was not safely retired for a package upgrade.'
    }

    $conflict = New-SidecarFixture 'conflict'
    $conflictProtected = @(Get-ProtectedSnapshot $conflict)
    Write-TestBytes (Join-Path $conflict.Retail 'd3d9.dll') 'unowned conflict'
    $conflictRejected = $false
    try { Invoke-Installer $conflict Install | Out-Null }
    catch { $conflictRejected = $_.Exception.Message.Contains('unowned sidecar path conflicts') }
    if (-not $conflictRejected -or (Get-Content -Raw (Join-Path $conflict.Retail 'd3d9.dll')) -cne 'unowned conflict') { throw 'First-install conflict was not rejected without mutation.' }
    Assert-ProtectedUnchanged $conflict $conflictProtected

    $invalidBoolean = New-SidecarFixture 'invalid-boolean'
    $invalidManifestPath = Join-Path $invalidBoolean.Stage 'fearmore-stage.json'
    $invalidManifest = Get-Content -LiteralPath $invalidManifestPath -Raw | ConvertFrom-Json
    $invalidManifest.InputsValidated = 'false'
    [IO.File]::WriteAllText($invalidManifestPath, ($invalidManifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $invalidBooleanRejected = $false
    try { Invoke-Installer $invalidBoolean Validate | Out-Null }
    catch { $invalidBooleanRejected = $_.Exception.Message.Contains('requires an exact schema-9') }
    if (-not $invalidBooleanRejected) { throw 'String-valued false stage gate was accepted as Boolean true.' }

    $invalidWindowed = New-SidecarFixture 'invalid-windowed-contract'
    $invalidWindowedManifestPath = Join-Path $invalidWindowed.Stage 'fearmore-stage.json'
    $invalidWindowedManifest = Get-Content -LiteralPath $invalidWindowedManifestPath -Raw | ConvertFrom-Json
    $invalidWindowedManifest.EnginePatchForceWindowed = $false
    [IO.File]::WriteAllText($invalidWindowedManifestPath, ($invalidWindowedManifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $invalidWindowedRejected = $false
    try { Invoke-Installer $invalidWindowed Validate | Out-Null }
    catch { $invalidWindowedRejected = $_.Exception.Message.Contains('engine-side RTX windowing enabled') }
    if (-not $invalidWindowedRejected) { throw 'RTX retail deployment accepted an engine-side fullscreen profile.' }

    $invalidFrameGeneration = New-SidecarFixture 'invalid-frame-generation-contract'
    $invalidFrameGenerationManifestPath = Join-Path $invalidFrameGeneration.Stage 'fearmore-stage.json'
    $invalidFrameGenerationManifest = Get-Content -LiteralPath $invalidFrameGenerationManifestPath -Raw | ConvertFrom-Json
    $invalidFrameGenerationManifest.RendererRuntimeConfigSeedDlssFrameGenerationEnabled = $true
    [IO.File]::WriteAllText($invalidFrameGenerationManifestPath, ($invalidFrameGenerationManifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $invalidFrameGenerationRejected = $false
    try { Invoke-Installer $invalidFrameGeneration Validate | Out-Null }
    catch { $invalidFrameGenerationRejected = $_.Exception.Message.Contains('Frame Generation path seeded off') }
    if (-not $invalidFrameGenerationRejected) { throw 'RTX retail deployment accepted the known-broken DLSS Frame Generation default.' }

    $invalidWritableDirectories = New-SidecarFixture 'invalid-runtime-writable-directories'
    $invalidWritableDirectoriesManifestPath = Join-Path $invalidWritableDirectories.Stage 'fearmore-stage.json'
    $invalidWritableDirectoriesManifest = Get-Content -LiteralPath $invalidWritableDirectoriesManifestPath -Raw | ConvertFrom-Json
    $invalidWritableDirectoriesManifest.RendererRuntimeWritableDirectories = @('rtx-remix', 'unexpected-runtime-state')
    [IO.File]::WriteAllText($invalidWritableDirectoriesManifestPath, ($invalidWritableDirectoriesManifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $invalidWritableDirectoriesRejected = $false
    try { Invoke-Installer $invalidWritableDirectories Validate | Out-Null }
    catch { $invalidWritableDirectoriesRejected = $_.Exception.Message.Contains('runtime-writable directory contract') }
    if (-not $invalidWritableDirectoriesRejected) { throw 'RTX retail deployment accepted a broadened runtime-writable directory contract.' }

    $invalidMutableFiles = New-SidecarFixture 'invalid-runtime-mutable-files'
    $invalidMutableFilesManifestPath = Join-Path $invalidMutableFiles.Stage 'fearmore-stage.json'
    $invalidMutableFilesManifest = Get-Content -LiteralPath $invalidMutableFilesManifestPath -Raw | ConvertFrom-Json
    $invalidMutableFilesManifest.RendererRuntimeMutableFiles = @('rtx.conf', 'user.conf')
    [IO.File]::WriteAllText($invalidMutableFilesManifestPath, ($invalidMutableFilesManifest | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $invalidMutableFilesRejected = $false
    try { Invoke-Installer $invalidMutableFiles Validate | Out-Null }
    catch { $invalidMutableFilesRejected = $_.Exception.Message.Contains('runtime-mutable file contract') }
    if (-not $invalidMutableFilesRejected) { throw 'RTX retail deployment accepted a broadened runtime-mutable file contract.' }

    $maliciousBackup = New-SidecarFixture 'malicious-backup'
    [void](New-Item -ItemType Directory -Path (Join-Path $maliciousBackup.Retail '.fearmore-live-install.rollback'))
    Write-TestBytes (Join-Path $maliciousBackup.Retail '.fearmore-live-install.rollback\FearMoreGame\GameClient.dll') 'user bytes in reserved backup tree'
    $backupRejected = $false
    try { Invoke-Installer $maliciousBackup Install | Out-Null }
    catch { $backupRejected = $_.Exception.Message.Contains('scratch path already exists') -or $_.Exception.Message.Contains('unowned sidecar path conflicts') }
    if (-not $backupRejected -or (Get-Content -Raw (Join-Path $maliciousBackup.Retail '.fearmore-live-install.rollback\FearMoreGame\GameClient.dll')) -cne 'user bytes in reserved backup tree') {
        throw 'Preexisting rollback tree was not rejected and preserved.'
    }

    $rollback = New-SidecarFixture 'rollback'
    $rollbackProtected = @(Get-ProtectedSnapshot $rollback)
    $failureObserved = $false
    try { Invoke-Installer $rollback Install 2 | Out-Null }
    catch { $failureObserved = $_.Exception.Message.Contains('Synthetic sidecar transaction failure') }
    if (-not $failureObserved) { throw 'Synthetic install failure injection did not fire.' }
    Assert-NotExists @((Join-Path $rollback.Retail 'd3d9.dll'), (Join-Path $rollback.Retail '.trex'),
        (Join-Path $rollback.Retail 'FearMoreGame'), (Join-Path $rollback.Retail 'fearmore-live-install.json'),
        (Join-Path $rollback.Retail 'fearmore-live-install.transaction.json'), (Join-Path $rollback.Retail '.fearmore-live-install.rollback'))
    Assert-ProtectedUnchanged $rollback $rollbackProtected

    $uninstallRollback = New-SidecarFixture 'uninstall-rollback'
    Invoke-Installer $uninstallRollback Install | Out-Null
    $uninstallFailureObserved = $false
    try { Invoke-Installer $uninstallRollback Uninstall 2 | Out-Null }
    catch { $uninstallFailureObserved = $_.Exception.Message.Contains('Synthetic sidecar transaction failure') }
    if (-not $uninstallFailureObserved -or -not (Test-Path (Join-Path $uninstallRollback.Retail 'fearmore-live-install.json')) -or
        -not (Test-Path (Join-Path $uninstallRollback.Retail 'd3d9.dll')) -or
        (Test-Path (Join-Path $uninstallRollback.Retail 'fearmore-live-install.transaction.json')) -or
        (Test-Path (Join-Path $uninstallRollback.Retail '.fearmore-live-install.rollback'))) {
        throw 'Injected uninstall failure did not restore the complete installed state.'
    }
    Invoke-Installer $uninstallRollback Uninstall | Out-Null

    $immutable = New-SidecarFixture 'immutable-tamper'
    Invoke-Installer $immutable Install | Out-Null
    Write-TestBytes (Join-Path $immutable.Retail 'd3d9.dll') 'changed immutable file'
    $immutableRejected = $false
    try { Invoke-Installer $immutable Uninstall | Out-Null }
    catch { $immutableRejected = $_.Exception.Message.Contains('Immutable FearMore sidecar file changed') }
    if (-not $immutableRejected -or -not (Test-Path (Join-Path $immutable.Retail 'fearmore-live-install.json'))) { throw 'Changed immutable file did not block uninstall.' }
    Copy-Item -LiteralPath (Join-Path $immutable.Stage 'd3d9.dll') -Destination (Join-Path $immutable.Retail 'd3d9.dll') -Force
    Invoke-Installer $immutable Uninstall | Out-Null

    $recordTamper = New-SidecarFixture 'record-tamper'
    Invoke-Installer $recordTamper Install | Out-Null
    $recordPath = Join-Path $recordTamper.Retail 'fearmore-live-install.json'
    $recordBytes = [IO.File]::ReadAllBytes($recordPath)
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    $record.OwnedDirectories = @($record.OwnedDirectories) + @('broadened-delete-target')
    [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    $recordRejected = $false
    try { Invoke-Installer $recordTamper Uninstall | Out-Null }
    catch { $recordRejected = $true }
    if (-not $recordRejected -or -not (Test-Path (Join-Path $recordTamper.Retail 'd3d9.dll'))) { throw 'Tampered ownership record broadened uninstall behavior.' }
    [IO.File]::WriteAllBytes($recordPath, $recordBytes)
    Invoke-Installer $recordTamper Uninstall | Out-Null

    $testPassed = $true
    [pscustomobject]@{
        Test='FearMore retail-sidecar install'; Passed=$true; WindowsPowerShellProcessValidation=$true; WindowsPowerShellWhatIf=$true;
        FirstInstall=$true; ExactIdempotence=$true; ManifestProvenanceDriftIdempotent=$true; ProvenanceDriftPreservedInstalledBytes=$true; MissingRuntimeConfigPreserved=$true; EditedRuntimeConfigPreserved=$true;
        RuntimeStatePreserved=$true; ReceiptAuthorizedReinstall=$true; CleanSeedReinstall=$true; FirstInstallConflictRejected=$true;
        ReceiptRetirement=$true; PreservedReceiptRetirementRejected=$true; RtxWindowedContractGate=$true;
        RtxFocusModeGate=$true; UnsupportedEnginePatchRejected=$true;
        DlssFrameGenerationOffGate=$true; RuntimeWritableContractGate=$true; RuntimeMutableFileContractGate=$true;
        StrictBooleanStageGate=$true; MaliciousBackupTreeRejected=$true; InstallRollback=$true; UninstallRollback=$true;
        ChangedImmutableUninstallRejected=$true; TamperedRecordRejected=$true; TamperedReceiptIdentityRejected=$true; RetailOriginalsPreserved=$true
    }
}
finally {
    if ($testPassed) { Remove-TestRootSafely }
    else { Write-Warning "Synthetic sidecar evidence retained after failure: $testRoot" }
}
