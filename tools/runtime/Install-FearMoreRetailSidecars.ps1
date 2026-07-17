[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Validate', ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Install')][switch]$Install,
    [Parameter(Mandatory, ParameterSetName = 'Uninstall')][switch]$Uninstall,
    [Parameter(Mandatory, ParameterSetName = 'Validate')][switch]$Validate,
    [Parameter(Mandatory, ParameterSetName = 'RetireReceipt')][switch]$RetireUninstallReceipt,

    [Parameter(Mandatory)][string]$StageRoot,
    [Parameter(Mandatory)][string]$RetailRoot,
    [string]$SourceManifestName = 'fearmore-stage.json',
    [string]$RuntimeConfigSeed,

    # Deterministic failure injection for the synthetic transaction test only.
    [Parameter(DontShow)][ValidateRange(0, 100000)][int]$TestFailureAfterWriteCount = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearRetailSidecarPackage.psm1') -Force -ErrorAction Stop
if (-not ('FearMoreRuntime.AtomicFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace FearMoreRuntime {
    public static class AtomicFile {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool MoveFileEx(string existingPath, string replacementPath, int flags);
    }
}
'@
}
if ([string]::IsNullOrWhiteSpace($RuntimeConfigSeed)) {
    $RuntimeConfigSeed = Join-Path $PSScriptRoot 'config\rtx-remix-runtime.conf'
}
$names = Get-FearRetailSidecarNames
$backupMarkerName = 'fearmore-rollback-owner.json'
$action = $PSCmdlet.ParameterSetName
$writeCount = 0

function Assert-NoFixedTemporaryConflict {
    param([Parameter(Mandatory)][string]$Root)
    foreach ($relativePath in @(
        "$($names.TransactionJournal).new",
        "$($names.InstallRecord).new",
        "$($names.UninstallReceipt).new",
        $names.TransactionBackup
    )) {
        $path = Join-Path $Root $relativePath
        if (Test-Path -LiteralPath $path) {
            throw "Fixed sidecar transaction scratch path already exists; recovery fails closed: $path"
        }
    }
}

function Write-AtomicUtf8File {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [switch]$ReplaceExisting
    )
    $temporary = "$Path.new"
    if (Test-Path -LiteralPath $temporary) { throw "Fixed atomic-write scratch path already exists: $temporary" }
    Assert-FearRetailSidecarPathNoReparse -Root $Root -Path (Split-Path $Path -Parent)
    try {
        [IO.File]::WriteAllBytes($temporary, $Bytes)
        if (Test-Path -LiteralPath $Path) {
            if (-not $ReplaceExisting) { throw "Atomic create target already exists: $Path" }
            Assert-FearRetailSidecarOrdinaryFile $Root $Path 'Atomic replacement target' | Out-Null
            # MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH. Both paths are
            # in the same validated directory, so this is a same-volume atomic
            # replacement with durable completion semantics.
            if (-not [FearMoreRuntime.AtomicFile]::MoveFileEx($temporary, $Path, 0x9)) {
                $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw [ComponentModel.Win32Exception]::new($errorCode, "Atomic sidecar file replacement failed: $Path")
            }
        }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function ConvertTo-JsonBytes {
    param([Parameter(Mandatory)]$Value)
    [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 20) + "`n")
}

function Get-BytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Write-AtomicJson {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [switch]$ReplaceExisting
    )
    Write-AtomicUtf8File -Root $Root -Path $Path -Bytes (ConvertTo-JsonBytes $Value) -ReplaceExisting:$ReplaceExisting
}

function Write-NewTransactionFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Destination,
        [AllowNull()][string]$SourcePath,
        [AllowNull()][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$TransactionId
    )
    if (Test-Path -LiteralPath $Destination) { throw "Transaction create target already exists: $Destination" }
    $scratch = "$Destination.fearmore-$TransactionId.new"
    if (Test-Path -LiteralPath $scratch) { throw "Transaction scratch target already exists: $scratch" }
    Assert-FearRetailSidecarPathNoReparse -Root $Root -Path (Split-Path $Destination -Parent)
    if ($SourcePath) { Copy-Item -LiteralPath $SourcePath -Destination $scratch }
    elseif ($null -ne $Bytes) { [IO.File]::WriteAllBytes($scratch, $Bytes) }
    else { throw 'Transaction file creation requires SourcePath or Bytes.' }
    if ((Get-FearRetailSidecarSha256 $scratch) -cne $ExpectedSha256) { throw "Transaction scratch verification failed: $scratch" }
    [IO.File]::Move($scratch, $Destination)
}

function Ensure-OwnedDirectory {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    $path = Get-FearRetailSidecarTargetPath -Root $Root -RelativePath $RelativePath
    if (Test-Path -LiteralPath $path) {
        Assert-FearRetailSidecarPathNoReparse -Root $Root -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Owned sidecar directory target is not a directory: $path" }
        return
    }
    $parent = Split-Path $path -Parent
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        $parentRelative = $parent.Substring(([IO.Path]::GetFullPath($Root).TrimEnd('\')).Length).TrimStart('\')
        Ensure-OwnedDirectory -Root $Root -RelativePath $parentRelative
    }
    Assert-FearRetailSidecarPathNoReparse -Root $Root -Path $parent
    [void](New-Item -ItemType Directory -Path $path)
}

function Invoke-WriteCheckpoint {
    $script:writeCount++
    if ($TestFailureAfterWriteCount -gt 0 -and $script:writeCount -eq $TestFailureAfterWriteCount) {
        throw "Synthetic sidecar transaction failure after write $($script:writeCount)."
    }
}

function Remove-ExactFile {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [switch]$AllowMissing
    )
    $path = Get-FearRetailSidecarTargetPath $Root $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        if ($AllowMissing) { return }
        throw "Expected sidecar file is missing: $path"
    }
    Assert-FearRetailSidecarOrdinaryFile $Root $path 'Sidecar transaction file' | Out-Null
    if ((Get-FearRetailSidecarSha256 $path) -cne $ExpectedSha256) {
        throw "Sidecar transaction refuses to remove changed bytes: $path"
    }
    Remove-Item -LiteralPath $path -Force
}

function Remove-EmptyOwnedDirectories {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string[]]$RelativeDirectories)
    foreach ($relativeDirectory in @($RelativeDirectories | Sort-Object { -($_ -split '\\').Count }, { $_ })) {
        $path = Get-FearRetailSidecarTargetPath $Root $relativeDirectory
        if (-not (Test-Path -LiteralPath $path)) { continue }
        Assert-FearRetailSidecarPathNoReparse -Root $Root -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "Owned directory path changed type: $path" }
        if (@(Get-ChildItem -LiteralPath $path -Force).Count -ne 0) { throw "Owned directory contains unexpected state and will not be removed: $path" }
        Remove-Item -LiteralPath $path -Force
    }
}

function Assert-JournalMatchesPlan {
    param([Parameter(Mandatory)]$Recovery, [Parameter(Mandatory)]$Plan)
    Assert-FearRetailSidecarPackageSnapshotMatchesPlan `
        -Snapshot $Recovery.Journal `
        -Plan $Plan `
        -SnapshotKind TransactionJournal `
        -Description 'FearMore transaction journal'
    $operation = [string]$Recovery.Journal.Operation
    $journalState = [string]$Recovery.Journal.State
    $runtimeAction = [string]$Recovery.Journal.RuntimeConfigAction
    if ([string]$Recovery.Journal.TransactionId -cnotmatch '^[0-9a-f]{32}$') {
        throw 'Transaction journal identifier is invalid.'
    }
    if (($operation -eq 'Install' -and ($journalState -notin @('Prepared','Committed') -or $runtimeAction -notin @('Seed','PreserveChanged','PreserveMissing'))) -or
        ($operation -eq 'Uninstall' -and ($journalState -notin @('Prepared','BackedUp','Committed') -or $runtimeAction -notin @('RemoveSeed','PreserveChanged','PreserveMissing')))) {
        throw "Transaction journal operation/state/runtime action combination is invalid: $operation/$journalState/$runtimeAction"
    }
    $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($Plan.ImmutableFiles)) { $expected.Add([string]$file.RelativePath, [string]$file.Sha256) }
    if ($runtimeAction -in @('Seed', 'RemoveSeed')) {
        $expected.Add([string]$Plan.RuntimeConfig.RelativePath, [string]$Plan.RuntimeConfig.SeedSha256)
    }
    elseif ($runtimeAction -notin @('PreserveChanged', 'PreserveMissing')) {
        throw "Transaction journal has an unsupported runtime-config action: $runtimeAction"
    }
    $recordHash = [string]$Recovery.Journal.InstallRecordSha256
    if ($recordHash -cnotmatch '^[0-9A-F]{64}$') { throw 'Transaction journal install-record hash is invalid.' }
    $expected.Add($names.InstallRecord, $recordHash)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($Recovery.Journal.Files)) {
        $relativePath = [string]$file.RelativePath
        if (-not $seen.Add($relativePath) -or -not $expected.ContainsKey($relativePath) -or
            $expected[$relativePath] -cne [string]$file.Sha256) {
            throw "Transaction journal file set does not match the fresh source plan: $relativePath"
        }
    }
    if ($seen.Count -ne $expected.Count) { throw 'Transaction journal file set is incomplete.' }
}

function Get-ValidatedBackupTree {
    param([Parameter(Mandatory)]$Recovery)
    if ([string]$Recovery.Journal.Operation -ne 'Uninstall') {
        if (Test-Path -LiteralPath $Recovery.BackupRoot) { throw 'Install recovery never owns a rollback-backup directory.' }
        return $null
    }
    if (-not (Test-Path -LiteralPath $Recovery.BackupRoot)) {
        if ([string]$Recovery.Journal.State -eq 'BackedUp') { throw 'BackedUp uninstall journal is missing its transaction-owned rollback tree.' }
        return $null
    }
    Assert-FearRetailSidecarPathNoReparse -Root $Recovery.RetailRoot -Path $Recovery.BackupRoot
    $markerHash = [string]$Recovery.Journal.BackupMarkerSha256
    if ($markerHash -cnotmatch '^[0-9A-F]{64}$') { throw 'Uninstall journal has no valid rollback-owner marker hash.' }
    $expected = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($Recovery.Journal.Files)) { $expected.Add([string]$file.RelativePath, [string]$file.Sha256) }
    $expected.Add($backupMarkerName, $markerHash)
    $present = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $files = @(); $directories = @()
    $rootLength = ([IO.Path]::GetFullPath($Recovery.BackupRoot).TrimEnd('\')).Length
    $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($Recovery.BackupRoot)
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue(); $directories += $directory
        foreach ($item in @(Get-ChildItem -LiteralPath $directory -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Rollback tree contains a reparse point: $($item.FullName)" }
            if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
            $relativePath = $item.FullName.Substring($rootLength).TrimStart('\')
            if (-not $present.Add($relativePath) -or -not $expected.ContainsKey($relativePath)) {
                throw "Rollback tree contains an unowned or duplicate file: $relativePath"
            }
            if (($relativePath -ieq $backupMarkerName -or [string]$Recovery.Journal.State -ne 'Prepared') -and
                (Get-FearRetailSidecarSha256 $item.FullName) -cne $expected[$relativePath]) {
                throw "Rollback tree contains changed committed backup bytes: $relativePath"
            }
            $files += $item.FullName
        }
    }
    if (-not $present.Contains($backupMarkerName) -and
        -not ([string]$Recovery.Journal.State -in @('Prepared','Committed') -and $present.Count -eq 0)) {
        throw 'Rollback tree is missing its transaction-owned marker.'
    }
    if ([string]$Recovery.Journal.State -eq 'BackedUp' -and $present.Count -ne $expected.Count) {
        throw 'BackedUp rollback tree is incomplete.'
    }
    [pscustomobject]@{
        Files=$files; Directories=$directories; Present=$present;
        MarkerPath=(Join-Path $Recovery.BackupRoot $backupMarkerName)
    }
}

function Remove-ValidatedBackupTree {
    param([AllowNull()]$ValidatedTree)
    if (-not $ValidatedTree) { return }
    foreach ($file in @($ValidatedTree.Files | Where-Object { $_ -ine $ValidatedTree.MarkerPath })) { Remove-Item -LiteralPath $file -Force }
    if (Test-Path -LiteralPath $ValidatedTree.MarkerPath -PathType Leaf) { Remove-Item -LiteralPath $ValidatedTree.MarkerPath -Force }
    foreach ($directory in @($ValidatedTree.Directories | Sort-Object { -($_ -split '\\').Count })) {
        if (@(Get-ChildItem -LiteralPath $directory -Force).Count -ne 0) { throw "Rollback directory is not empty after validated cleanup: $directory" }
        Remove-Item -LiteralPath $directory -Force
    }
}

function Invoke-TransactionRecovery {
    param([Parameter(Mandatory)]$Recovery, [Parameter(Mandatory)]$Plan)
    Assert-JournalMatchesPlan -Recovery $Recovery -Plan $Plan
    $backupTree = Get-ValidatedBackupTree -Recovery $Recovery
    $receiptPath = Join-Path $Recovery.RetailRoot $names.UninstallReceipt
    $receiptHash = [string]$Recovery.Journal.ReceiptSha256
    $receiptScratch = "$receiptPath.fearmore-$($Recovery.Journal.TransactionId).new"
    $receiptScratchExists = Test-Path -LiteralPath $receiptScratch
    if ($receiptScratchExists) {
        Assert-FearRetailSidecarOrdinaryFile $Recovery.RetailRoot $receiptScratch 'Uninstall receipt transaction scratch file' | Out-Null
    }
    $targetStates = @()
    $scratchPaths = @()
    foreach ($file in @($Recovery.Journal.Files)) {
        $path = Get-FearRetailSidecarTargetPath $Recovery.RetailRoot ([string]$file.RelativePath)
        $exists = Test-Path -LiteralPath $path
        if ($exists) {
            Assert-FearRetailSidecarOrdinaryFile $Recovery.RetailRoot $path 'Transaction recovery target' | Out-Null
            if ((Get-FearRetailSidecarSha256 $path) -cne [string]$file.Sha256) { throw "Transaction recovery found changed target bytes: $path" }
        }
        $targetStates += [pscustomobject]@{ Record=$file; Path=$path; Exists=$exists }
        if ([string]$Recovery.Journal.Operation -eq 'Install') {
            $scratch = "$path.fearmore-$($Recovery.Journal.TransactionId).new"
            if (Test-Path -LiteralPath $scratch) {
                Assert-FearRetailSidecarOrdinaryFile $Recovery.RetailRoot $scratch 'Install transaction scratch file' | Out-Null
                $scratchPaths += $scratch
            }
        }
    }

    if ([string]$Recovery.Journal.Operation -eq 'Install') {
        $allExact = @($targetStates | Where-Object { -not $_.Exists }).Count -eq 0
        if (-not $allExact) {
            foreach ($scratch in $scratchPaths) { Remove-Item -LiteralPath $scratch -Force }
            foreach ($state in $targetStates) { if ($state.Exists) { Remove-Item -LiteralPath $state.Path -Force } }
            Remove-EmptyOwnedDirectories -Root $Recovery.RetailRoot -RelativeDirectories @($Recovery.Journal.OwnedDirectories)
        }
        else {
            foreach ($scratch in $scratchPaths) { Remove-Item -LiteralPath $scratch -Force }
            $priorReceiptHash = [string]$Recovery.Journal.PriorReceiptSha256
            if ($priorReceiptHash) {
                if (Test-Path -LiteralPath $receiptPath) {
                    Assert-FearRetailSidecarOrdinaryFile $Recovery.RetailRoot $receiptPath 'Prior uninstall receipt' | Out-Null
                    if ((Get-FearRetailSidecarSha256 $receiptPath) -cne $priorReceiptHash) { throw 'Prior uninstall receipt changed during committed install recovery.' }
                    Remove-Item -LiteralPath $receiptPath -Force
                }
            }
        }
        Remove-Item -LiteralPath $Recovery.JournalPath -Force
        return
    }

    $committed = [string]$Recovery.Journal.State -eq 'Committed'
    if ($committed) {
        if (@($targetStates | Where-Object Exists).Count -ne 0) { throw 'Committed uninstall recovery found a target file that should already be absent.' }
        Assert-FearRetailSidecarOrdinaryFile $Recovery.RetailRoot $receiptPath 'Committed uninstall receipt' | Out-Null
        if ($receiptHash -cnotmatch '^[0-9A-F]{64}$' -or (Get-FearRetailSidecarSha256 $receiptPath) -cne $receiptHash) {
            throw 'Committed uninstall receipt is missing or changed.'
        }
        if ($receiptScratchExists) { Remove-Item -LiteralPath $receiptScratch -Force }
        Remove-ValidatedBackupTree -ValidatedTree $backupTree
        Remove-Item -LiteralPath $Recovery.JournalPath -Force
        return
    }

    if (Test-Path -LiteralPath $receiptPath) {
        Assert-FearRetailSidecarOrdinaryFile $Recovery.RetailRoot $receiptPath 'Uncommitted uninstall receipt' | Out-Null
        if ($receiptHash -cnotmatch '^[0-9A-F]{64}$' -or (Get-FearRetailSidecarSha256 $receiptPath) -cne $receiptHash) {
            throw 'Uncommitted uninstall receipt contains changed bytes.'
        }
    }
    foreach ($state in $targetStates) {
        if ($state.Exists) { continue }
        $backup = Get-FearRetailSidecarTargetPath $Recovery.BackupRoot ([string]$state.Record.RelativePath)
        Assert-FearRetailSidecarOrdinaryFile $Recovery.BackupRoot $backup 'Uninstall recovery backup' | Out-Null
        if ((Get-FearRetailSidecarSha256 $backup) -cne [string]$state.Record.Sha256) { throw "Uninstall recovery backup mismatch: $backup" }
    }
    # Every target and backup was validated above; mutation begins only now.
    foreach ($state in $targetStates) {
        if ($state.Exists) { continue }
        $backup = Get-FearRetailSidecarTargetPath $Recovery.BackupRoot ([string]$state.Record.RelativePath)
        $parentRelative = Split-Path ([string]$state.Record.RelativePath) -Parent
        if ($parentRelative) { Ensure-OwnedDirectory -Root $Recovery.RetailRoot -RelativePath $parentRelative }
        Copy-Item -LiteralPath $backup -Destination $state.Path
    }
    if ($receiptScratchExists) { Remove-Item -LiteralPath $receiptScratch -Force }
    if (Test-Path -LiteralPath $receiptPath) { Remove-Item -LiteralPath $receiptPath -Force }
    Remove-ValidatedBackupTree -ValidatedTree $backupTree
    Remove-Item -LiteralPath $Recovery.JournalPath -Force
}

function New-OwnershipSnapshotFields {
    param([Parameter(Mandatory)]$Plan)
    $immutable = @($Plan.ImmutableFiles | ForEach-Object {
        [pscustomobject][ordered]@{ RelativePath=$_.RelativePath; Size=$_.Size; Sha256=$_.Sha256; Kind=$_.Kind }
    })
    $runtime = [pscustomobject][ordered]@{
        RelativePath=$Plan.RuntimeConfig.RelativePath; SeedSize=$Plan.RuntimeConfig.SeedSize;
        SeedSha256=$Plan.RuntimeConfig.SeedSha256; Policy=$Plan.RuntimeConfig.Policy
    }
    $protected = @($Plan.ProtectedFiles | ForEach-Object {
        [pscustomobject][ordered]@{ RelativePath=$_.RelativePath; Size=$_.Size; Sha256=$_.Sha256 }
    })
    [pscustomobject]@{ ImmutableFiles=$immutable; RuntimeConfig=$runtime; ProtectedFiles=$protected }
}

function New-InstallRecord {
    param([Parameter(Mandatory)]$Plan)
    $snapshot = New-OwnershipSnapshotFields $Plan
    [pscustomobject][ordered]@{
        SchemaVersion=1; InstalledUtc=[DateTime]::UtcNow.ToString('o'); RetailRoot=$Plan.RetailRoot;
        StageRoot=$Plan.StageRoot; StageManifestSha256=$Plan.ManifestSha256; InstallIdentitySha256=$Plan.InstallIdentitySha256;
        FearVersion=$Plan.FearVersion; RetailExecutableSha256=$Plan.RetailExecutableSha256;
        ImmutableFiles=@($snapshot.ImmutableFiles); OwnedDirectories=@($Plan.OwnedDirectories);
        RuntimeConfig=$snapshot.RuntimeConfig; ProtectedFiles=@($snapshot.ProtectedFiles);
        RuntimeWritableDirectories=@($Plan.RuntimeWritableDirectories);
        RuntimeWritablePolicy='PreserveAlwaysNeverOwnedOrRemoved';
        ArchiveConfig=$names.ArchiveConfig; ModuleDirectory=$names.ModuleDirectory
    }
}

function New-UninstallReceipt {
    param([Parameter(Mandatory)]$Plan, [Parameter(Mandatory)]$Installed)
    $snapshot = New-OwnershipSnapshotFields $Plan
    $status = if ($Installed.RuntimeConfigStatus -eq 'ExactSeed') { 'RemovedSeed' } else { $Installed.RuntimeConfigStatus }
    $preservedSize = $null
    $preservedHash = $null
    if ($status -eq 'Changed') {
        $item = Get-Item -LiteralPath $Installed.RuntimeConfigPath
        $preservedSize = $item.Length
        $preservedHash = Get-FearRetailSidecarSha256 $Installed.RuntimeConfigPath
    }
    [pscustomobject][ordered]@{
        SchemaVersion=1; UninstalledUtc=[DateTime]::UtcNow.ToString('o'); RetailRoot=$Plan.RetailRoot;
        StageManifestSha256=$Plan.ManifestSha256; InstallIdentitySha256=$Plan.InstallIdentitySha256;
        ImmutableFiles=@($snapshot.ImmutableFiles); OwnedDirectories=@($Plan.OwnedDirectories);
        RuntimeConfig=$snapshot.RuntimeConfig; ProtectedFiles=@($snapshot.ProtectedFiles);
        RuntimeConfigStatus=$status; PreservedRuntimeConfigSize=$preservedSize; PreservedRuntimeConfigSha256=$preservedHash;
        RuntimeWritablePolicy='PreserveAlwaysNeverOwnedOrRemoved'; RuntimeWritableDirectories=@($Plan.RuntimeWritableDirectories)
    }
}

function New-TransactionJournal {
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][ValidateSet('Install','Uninstall')][string]$Operation,
        [Parameter(Mandatory)][object[]]$Files,
        [Parameter(Mandatory)][string]$State,
        [Parameter(Mandatory)][ValidateSet('Seed','RemoveSeed','PreserveChanged','PreserveMissing')][string]$RuntimeConfigAction,
        [Parameter(Mandatory)][string]$InstallRecordSha256,
        [AllowNull()][string]$ReceiptSha256,
        [AllowNull()][string]$PriorReceiptSha256,
        [Parameter(Mandatory)][string]$TransactionId,
        [AllowNull()][string]$BackupMarkerSha256
    )
    $snapshot = New-OwnershipSnapshotFields $Plan
    [pscustomobject][ordered]@{
        SchemaVersion=1; Operation=$Operation; State=$State; GeneratedUtc=[DateTime]::UtcNow.ToString('o'); TransactionId=$TransactionId;
        RetailRoot=$Plan.RetailRoot; StageManifestSha256=$Plan.ManifestSha256; InstallIdentitySha256=$Plan.InstallIdentitySha256;
        ImmutableFiles=@($snapshot.ImmutableFiles); OwnedDirectories=@($Plan.OwnedDirectories);
        RuntimeConfig=$snapshot.RuntimeConfig; RuntimeConfigAction=$RuntimeConfigAction; ProtectedFiles=@($snapshot.ProtectedFiles);
        InstallRecordSha256=$InstallRecordSha256; ReceiptRelativePath=$names.UninstallReceipt; ReceiptSha256=$ReceiptSha256;
        PriorReceiptSha256=$PriorReceiptSha256; BackupMarkerSha256=$BackupMarkerSha256; Files=@($Files)
    }
}

$plan = Get-FearRetailSidecarPackagePlan -StageRoot $StageRoot -RetailRoot $RetailRoot `
    -SourceManifestName $SourceManifestName -RuntimeConfigSeed $RuntimeConfigSeed `
    -AllowLegacyWindowedReceiptRetirement:$RetireUninstallReceipt
$recovery = Get-FearRetailSidecarRecoveryState -RetailRoot $plan.RetailRoot

if ($RetireUninstallReceipt) {
    if ($recovery) { throw "A sidecar transaction requires recovery before receipt retirement: $($recovery.JournalPath)" }
    Assert-NoFixedTemporaryConflict -Root $plan.RetailRoot
    $state = Get-FearRetailSidecarInstallState -Plan $plan
    if ($state.State -cne 'ReadyToReinstall' -or
        $state.RuntimeConfigStatus -notin @('RemovedSeed', 'Missing')) {
        throw 'Receipt retirement requires an exact fully uninstalled package whose runtime config is absent; preserved user configuration must remain receipt-owned.'
    }
    Assert-FearRetailSidecarGameNotRunning
    if (-not $PSCmdlet.ShouldProcess($plan.RetailRoot, 'Retire validated FearMore uninstall receipt for a package upgrade')) { return }
    $receiptHash = Get-FearRetailSidecarSha256 $state.UninstallReceiptPath
    Remove-ExactFile `
        -Root $plan.RetailRoot `
        -RelativePath $names.UninstallReceipt `
        -ExpectedSha256 $receiptHash
    [pscustomobject]@{
        Action='RetireUninstallReceipt'; Validated=$true; Retired=$true;
        StageRoot=$plan.StageRoot; RetailRoot=$plan.RetailRoot;
        RetiredReceipt=$state.UninstallReceiptPath;
        RuntimeConfigStatus=$state.RuntimeConfigStatus;
        RuntimeWritableStatePreserved=$true;
        RuntimeWritableDirectories=@($plan.RuntimeWritableDirectories)
    }
    return
}

if ($Validate) {
    if ($recovery) { throw "A sidecar transaction requires recovery before validation: $($recovery.JournalPath)" }
    Assert-NoFixedTemporaryConflict -Root $plan.RetailRoot
    $state = Get-FearRetailSidecarInstallState -Plan $plan
    [pscustomobject]@{
        Action='Validate'; Validated=$true; State=$state.State; StageRoot=$plan.StageRoot; RetailRoot=$plan.RetailRoot;
        InstallRecord=(Join-Path $plan.RetailRoot $names.InstallRecord); ArchiveConfig=(Join-Path $plan.RetailRoot $names.ArchiveConfig);
        RuntimeConfigPolicy=$plan.RuntimeConfig.Policy;
        RuntimeConfigStatus=$(if ($state.Installed) { $state.Installed.RuntimeConfigStatus } else { $state.RuntimeConfigStatus });
        RuntimeWritableStatePolicy='PreserveAlwaysNeverOwnedOrRemoved'; RuntimeWritableDirectories=@($plan.RuntimeWritableDirectories)
    }
    return
}

if ($recovery) {
    Assert-FearRetailSidecarGameNotRunning
    if (-not $PSCmdlet.ShouldProcess($plan.RetailRoot, "Recover interrupted FearMore $($recovery.Journal.Operation) transaction")) { return }
    Invoke-TransactionRecovery -Recovery $recovery -Plan $plan
}
Assert-NoFixedTemporaryConflict -Root $plan.RetailRoot

if ($Install) {
    $state = Get-FearRetailSidecarInstallState -Plan $plan
    if ($state.State -eq 'InstalledExact') {
        [pscustomobject]@{
            Action='Install'; Validated=$true; Installed=$true; Idempotent=$true; StageRoot=$plan.StageRoot; RetailRoot=$plan.RetailRoot;
            InstallRecord=$state.Installed.RecordPath; ArchiveConfig=(Join-Path $plan.RetailRoot $names.ArchiveConfig);
            RuntimeConfigPolicy=$plan.RuntimeConfig.Policy; RuntimeConfigStatus=$state.Installed.RuntimeConfigStatus;
            RuntimeConfigPreserved=($state.Installed.RuntimeConfigStatus -ne 'ExactSeed');
            RuntimeWritableStatePreserved=$true; RuntimeWritableDirectories=@($plan.RuntimeWritableDirectories)
        }
        return
    }
    Assert-FearRetailSidecarGameNotRunning
    if (-not $PSCmdlet.ShouldProcess($plan.RetailRoot, 'Install validated FearMore RTX retail sidecars')) { return }
    $record = New-InstallRecord $plan
    $recordBytes = ConvertTo-JsonBytes $record
    $recordHash = Get-BytesSha256 $recordBytes
    $runtimeAction = 'Seed'
    $priorReceiptHash = $null
    if ($state.State -eq 'ReadyToReinstall') {
        $priorReceiptHash = Get-FearRetailSidecarSha256 $state.UninstallReceiptPath
        $runtimeAction = if ($state.RuntimeConfigStatus -eq 'Changed') {
            'PreserveChanged'
        }
        elseif ($state.RuntimeConfigStatus -eq 'RemovedSeed') {
            'Seed'
        }
        else {
            'PreserveMissing'
        }
    }
    $journalFiles = @($plan.ImmutableFiles | ForEach-Object { [pscustomobject]@{ RelativePath=$_.RelativePath; Sha256=$_.Sha256 } })
    if ($runtimeAction -eq 'Seed') {
        $journalFiles += [pscustomobject]@{ RelativePath=$plan.RuntimeConfig.RelativePath; Sha256=$plan.RuntimeConfig.SeedSha256 }
    }
    $journalFiles += [pscustomobject]@{ RelativePath=$names.InstallRecord; Sha256=$recordHash }
    $transactionId = [guid]::NewGuid().ToString('N')
    $journal = New-TransactionJournal -Plan $plan -Operation Install -Files $journalFiles -State 'Prepared' `
        -RuntimeConfigAction $runtimeAction -InstallRecordSha256 $recordHash -PriorReceiptSha256 $priorReceiptHash `
        -TransactionId $transactionId
    $journalPath = Join-Path $plan.RetailRoot $names.TransactionJournal
    try {
        Write-AtomicJson -Root $plan.RetailRoot -Path $journalPath -Value $journal
        foreach ($directory in @($plan.OwnedDirectories)) { Ensure-OwnedDirectory -Root $plan.RetailRoot -RelativePath $directory }
        foreach ($file in @($plan.ImmutableFiles)) {
            $destination = Get-FearRetailSidecarTargetPath $plan.RetailRoot $file.RelativePath
            if ($file.Kind -eq 'GeneratedArchiveConfig') {
                Write-NewTransactionFile -Root $plan.RetailRoot -Destination $destination -Bytes ([byte[]]$file.GeneratedBytes) `
                    -ExpectedSha256 $file.Sha256 -TransactionId $transactionId
            }
            else {
                Write-NewTransactionFile -Root $plan.RetailRoot -Destination $destination -SourcePath $file.SourcePath `
                    -ExpectedSha256 $file.Sha256 -TransactionId $transactionId
            }
            if ((Get-FearRetailSidecarSha256 $destination) -cne $file.Sha256) { throw "Installed sidecar verification failed: $($file.RelativePath)" }
            Invoke-WriteCheckpoint
        }
        if ($runtimeAction -eq 'Seed') {
            $runtimeDestination = Get-FearRetailSidecarTargetPath $plan.RetailRoot $plan.RuntimeConfig.RelativePath
            Write-NewTransactionFile -Root $plan.RetailRoot -Destination $runtimeDestination -SourcePath $plan.RuntimeConfig.SourcePath `
                -ExpectedSha256 $plan.RuntimeConfig.SeedSha256 -TransactionId $transactionId
            if ((Get-FearRetailSidecarSha256 $runtimeDestination) -cne $plan.RuntimeConfig.SeedSha256) { throw 'Installed Remix 1.5.2 Custom + ReSTIR GI seed verification failed.' }
            Invoke-WriteCheckpoint
        }
        Write-NewTransactionFile -Root $plan.RetailRoot -Destination (Join-Path $plan.RetailRoot $names.InstallRecord) `
            -Bytes $recordBytes -ExpectedSha256 $recordHash -TransactionId $transactionId
        if ((Get-FearRetailSidecarSha256 (Join-Path $plan.RetailRoot $names.InstallRecord)) -cne $recordHash) { throw 'Installed ownership record verification failed.' }
        $journal.State = 'Committed'
        Write-AtomicJson -Root $plan.RetailRoot -Path $journalPath -Value $journal -ReplaceExisting
        if ($priorReceiptHash) {
            $receiptPath = Join-Path $plan.RetailRoot $names.UninstallReceipt
            Assert-FearRetailSidecarOrdinaryFile $plan.RetailRoot $receiptPath 'Prior uninstall receipt' | Out-Null
            if ((Get-FearRetailSidecarSha256 $receiptPath) -cne $priorReceiptHash) { throw 'Prior uninstall receipt changed during reinstall.' }
            Remove-Item -LiteralPath $receiptPath -Force
        }
        Remove-Item -LiteralPath $journalPath -Force
    }
    catch {
        $failure = $_
        if (Test-Path -LiteralPath $journalPath) {
            $pending = Get-FearRetailSidecarRecoveryState -RetailRoot $plan.RetailRoot
            try { Invoke-TransactionRecovery -Recovery $pending -Plan $plan }
            catch { throw "Sidecar install failed and rollback also failed. Original: $($failure.Exception.Message) Rollback: $($_.Exception.Message)" }
        }
        throw $failure
    }
    $installedState = Get-FearRetailSidecarInstallState -Plan $plan
    [pscustomobject]@{
        Action='Install'; Validated=$true; Installed=$true; Idempotent=$false; StageRoot=$plan.StageRoot; RetailRoot=$plan.RetailRoot;
        InstallRecord=$installedState.Installed.RecordPath; ArchiveConfig=(Join-Path $plan.RetailRoot $names.ArchiveConfig);
        RuntimeConfigPolicy=$plan.RuntimeConfig.Policy; RuntimeConfigStatus=$installedState.Installed.RuntimeConfigStatus;
        RuntimeConfigPreserved=($runtimeAction -ne 'Seed'); RuntimeWritableStatePreserved=$true; RuntimeWritableDirectories=@($plan.RuntimeWritableDirectories)
    }
    return
}

$installed = Get-FearRetailSidecarInstalledState -RetailRoot $plan.RetailRoot
Assert-FearRetailSidecarPackageSnapshotMatchesPlan `
    -Snapshot $installed.Record `
    -Plan $plan `
    -SnapshotKind InstallRecord `
    -Description 'FearMore retail install record'
if (Test-Path -LiteralPath (Join-Path $plan.RetailRoot $names.UninstallReceipt)) {
    throw 'An uninstall receipt unexpectedly exists while sidecars are installed; refusing to overwrite it.'
}
Assert-FearRetailSidecarGameNotRunning
if (-not $PSCmdlet.ShouldProcess($plan.RetailRoot, 'Uninstall validated FearMore RTX retail sidecars')) { return }
$filesToRemove = @($installed.Record.ImmutableFiles | ForEach-Object { [pscustomobject]@{ RelativePath=$_.RelativePath; Sha256=$_.Sha256 } })
$runtimePreserved = $installed.RuntimeConfigStatus -ne 'ExactSeed'
$runtimeAction = if ($installed.RuntimeConfigStatus -eq 'ExactSeed') { 'RemoveSeed' } elseif ($installed.RuntimeConfigStatus -eq 'Changed') { 'PreserveChanged' } else { 'PreserveMissing' }
if (-not $runtimePreserved) {
    $filesToRemove += [pscustomobject]@{ RelativePath=$installed.Record.RuntimeConfig.RelativePath; Sha256=$installed.Record.RuntimeConfig.SeedSha256 }
}
$recordHash = Get-FearRetailSidecarSha256 $installed.RecordPath
$filesToRemove += [pscustomobject]@{ RelativePath=$names.InstallRecord; Sha256=$recordHash }
$receipt = New-UninstallReceipt -Plan $plan -Installed $installed
$receiptBytes = ConvertTo-JsonBytes $receipt
$receiptHash = Get-BytesSha256 $receiptBytes
$transactionId = [guid]::NewGuid().ToString('N')
$marker = [pscustomobject][ordered]@{ SchemaVersion=1; TransactionId=$transactionId; RetailRoot=$plan.RetailRoot; Operation='Uninstall' }
$markerBytes = ConvertTo-JsonBytes $marker
$markerHash = Get-BytesSha256 $markerBytes
$journal = New-TransactionJournal -Plan $plan -Operation Uninstall -Files $filesToRemove -State 'Prepared' `
    -RuntimeConfigAction $runtimeAction -InstallRecordSha256 $recordHash -ReceiptSha256 $receiptHash `
    -TransactionId $transactionId -BackupMarkerSha256 $markerHash
$journalPath = Join-Path $plan.RetailRoot $names.TransactionJournal
$backupRoot = Join-Path $plan.RetailRoot $names.TransactionBackup
try {
    Write-AtomicJson -Root $plan.RetailRoot -Path $journalPath -Value $journal
    [void](New-Item -ItemType Directory -Path $backupRoot)
    [IO.File]::WriteAllBytes((Join-Path $backupRoot $backupMarkerName), $markerBytes)
    foreach ($file in $filesToRemove) {
        $source = Get-FearRetailSidecarTargetPath $plan.RetailRoot $file.RelativePath
        $backup = Get-FearRetailSidecarTargetPath $backupRoot $file.RelativePath
        $backupParent = Split-Path $backup -Parent
        if (-not (Test-Path -LiteralPath $backupParent)) {
            $relativeParent = $backupParent.Substring(([IO.Path]::GetFullPath($backupRoot).TrimEnd('\')).Length).TrimStart('\')
            if ($relativeParent) { Ensure-OwnedDirectory -Root $backupRoot -RelativePath $relativeParent }
        }
        Copy-Item -LiteralPath $source -Destination $backup
        if ((Get-FearRetailSidecarSha256 $backup) -cne [string]$file.Sha256) { throw "Rollback backup verification failed: $backup" }
    }
    $journal.State = 'BackedUp'
    Write-AtomicJson -Root $plan.RetailRoot -Path $journalPath -Value $journal -ReplaceExisting
    foreach ($file in $filesToRemove) {
        Remove-ExactFile -Root $plan.RetailRoot -RelativePath $file.RelativePath -ExpectedSha256 $file.Sha256
        Invoke-WriteCheckpoint
    }
    Remove-EmptyOwnedDirectories -Root $plan.RetailRoot -RelativeDirectories @($installed.Record.OwnedDirectories)
    Write-NewTransactionFile -Root $plan.RetailRoot -Destination (Join-Path $plan.RetailRoot $names.UninstallReceipt) `
        -Bytes $receiptBytes -ExpectedSha256 $receiptHash -TransactionId $transactionId
    if ((Get-FearRetailSidecarSha256 (Join-Path $plan.RetailRoot $names.UninstallReceipt)) -cne $receiptHash) { throw 'Uninstall preservation receipt verification failed.' }
    $journal.State = 'Committed'
    Write-AtomicJson -Root $plan.RetailRoot -Path $journalPath -Value $journal -ReplaceExisting
    $recoveryForCleanup = Get-FearRetailSidecarRecoveryState -RetailRoot $plan.RetailRoot
    $validatedBackup = Get-ValidatedBackupTree -Recovery $recoveryForCleanup
    Remove-ValidatedBackupTree -ValidatedTree $validatedBackup
    Remove-Item -LiteralPath $journalPath -Force
}
catch {
    $failure = $_
    if (Test-Path -LiteralPath $journalPath) {
        $pending = Get-FearRetailSidecarRecoveryState -RetailRoot $plan.RetailRoot
        try { Invoke-TransactionRecovery -Recovery $pending -Plan $plan }
        catch { throw "Sidecar uninstall failed and rollback also failed. Original: $($failure.Exception.Message) Rollback: $($_.Exception.Message)" }
    }
    throw $failure
}
[pscustomobject]@{
    Action='Uninstall'; Validated=$true; Uninstalled=$true; StageRoot=$plan.StageRoot; RetailRoot=$plan.RetailRoot;
    InstallRecord=(Join-Path $plan.RetailRoot $names.InstallRecord); ArchiveConfig=(Join-Path $plan.RetailRoot $names.ArchiveConfig);
    RuntimeConfigPolicy=$plan.RuntimeConfig.Policy; RuntimeConfigStatusBeforeUninstall=$installed.RuntimeConfigStatus;
    RuntimeConfigPreserved=$runtimePreserved; RuntimeWritableStatePreserved=$true;
    RuntimeWritableDirectories=@($plan.RuntimeWritableDirectories); RuntimeWritableStateNote='rtx-remix and other runtime-created state are never owned or removed.'
}
