[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Run', ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [string]$Experiment,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [ValidateSet('Control', 'Candidate')]
    [string]$Variant,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [string]$StageRoot,

    [Parameter(Mandatory)]
    [string]$RetailRoot,

    [Parameter(ParameterSetName = 'Run')]
    [string]$SteamExecutable,

    [Parameter(ParameterSetName = 'Run')]
    [AllowEmptyCollection()]
    [string[]]$LaunchArguments = @('+runworld', 'Worlds\Release\Docks'),

    [Parameter(Mandatory, ParameterSetName = 'Recover')]
    [switch]$Recover,

    # Deterministic transaction failure injection for the synthetic test only.
    [Parameter(DontShow)]
    [ValidateRange(0, 100)]
    [int]$TestFailureAfterWriteCount = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearSteamLaunch.psm1') -Force -ErrorAction Stop
# FearSteamLaunch imports these same read-only dependencies into its module
# scope. Import the public surfaces into this script scope afterwards so a
# forced nested reload cannot remove the commands used by the transaction
# owner below.
Import-Module (Join-Path $PSScriptRoot 'FearRendererPackage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRemixExperimentPlan.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRetailSidecarPackage.psm1') -Force -ErrorAction Stop

if (-not ('FearMoreRuntime.RemixExperimentAtomicFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace FearMoreRuntime {
    public static class RemixExperimentAtomicFile {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        public static extern bool MoveFileEx(string existingPath, string replacementPath, int flags);
    }
}
'@
}

$script:WriteCount = 0

function Invoke-FearRemixExperimentWriteCheckpoint {
    $script:WriteCount++
    if ($TestFailureAfterWriteCount -gt 0 -and $script:WriteCount -eq $TestFailureAfterWriteCount) {
        throw "Synthetic RTX Remix experiment failure after write $script:WriteCount."
    }
}

function Open-FearRemixExperimentLock {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)

    Assert-FearRetailSidecarPathNoReparse -Root $Root -Path $Path -AllowMissingLeaf -LeafMayBeFile
    if (Test-Path -LiteralPath $Path) {
        throw "Another RTX Remix experiment session may be active, or a lock artifact requires inspection: $Path"
    }
    try {
        return [IO.FileStream]::new(
            $Path,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None,
            1,
            [IO.FileOptions]::DeleteOnClose)
    }
    catch {
        throw "Could not acquire the exclusive RTX Remix experiment lock '$Path': $($_.Exception.Message)"
    }
}

function Write-FearRemixDurableNewFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Root
    )

    Assert-FearRetailSidecarPathNoReparse -Root $Root -Path $Path -AllowMissingLeaf -LeafMayBeFile
    $stream = $null
    try {
        $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally {
        if ($stream) { $stream.Dispose() }
    }
    Invoke-FearRemixExperimentWriteCheckpoint
}

function Move-FearRemixExperimentFileReplaceExisting {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Root
    )

    Assert-FearRetailSidecarOrdinaryFile -Root $Root -Path $Source -Description 'RTX Remix experiment atomic source' | Out-Null
    Assert-FearRetailSidecarOrdinaryFile -Root $Root -Path $Destination -Description 'RTX Remix experiment atomic destination' | Out-Null
    # MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH
    if (-not [FearMoreRuntime.RemixExperimentAtomicFile]::MoveFileEx($Source, $Destination, 0x9)) {
        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw [ComponentModel.Win32Exception]::new($errorCode, "Atomic RTX Remix experiment replacement failed: '$Source' -> '$Destination'")
    }
}

function Write-FearRemixExperimentJournal {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][string]$Root
    )

    $temporary = "$Path.new"
    if (Test-Path -LiteralPath $temporary) {
        throw "RTX Remix experiment journal scratch path already exists: $temporary"
    }
    $json = ($Journal | ConvertTo-Json -Depth 8) + "`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    try {
        Write-FearRemixDurableNewFile -Path $temporary -Bytes $bytes -Root $Root
        if (Test-Path -LiteralPath $Path) {
            Assert-FearRetailSidecarOrdinaryFile -Root $Root -Path $Path -Description 'Existing RTX Remix experiment journal' | Out-Null
            Move-FearRemixExperimentFileReplaceExisting -Source $temporary -Destination $Path -Root $Root
        }
        else {
            [IO.File]::Move($temporary, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            [IO.File]::Delete($temporary)
        }
    }
    Invoke-FearRemixExperimentWriteCheckpoint
}

function Remove-FearRemixExperimentFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Description
    )

    Assert-FearRetailSidecarPathNoReparse -Root $Root -Path $Path -AllowMissingLeaf -LeafMayBeFile
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-FearRetailSidecarOrdinaryFile -Root $Root -Path $Path -Description $Description | Out-Null
    [IO.File]::Delete($Path)
    Invoke-FearRemixExperimentWriteCheckpoint
}

function Test-FearRemixExperimentFileIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Root,
        [AllowNull()][string]$ExpectedSha256,
        [long]$ExpectedSize,
        [Parameter(Mandatory)][string]$Description
    )

    Assert-FearRetailSidecarPathNoReparse -Root $Root -Path $Path -AllowMissingLeaf -LeafMayBeFile
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Assert-FearRetailSidecarOrdinaryFile -Root $Root -Path $Path -Description $Description
    return $item.Length -eq $ExpectedSize -and
        (Get-FearRetailSidecarSha256 $item.FullName) -ceq $ExpectedSha256
}

function Assert-FearRemixExperimentPreimage {
    param([Parameter(Mandatory)]$Plan)

    if ($Plan.OriginalUserConfigPresent) {
        if (-not (Test-FearRemixExperimentFileIdentity `
                -Path $Plan.UserConfigPath `
                -Root $Plan.RetailRoot `
                -ExpectedSha256 $Plan.OriginalUserConfigSha256 `
                -ExpectedSize $Plan.OriginalUserConfigSize `
                -Description 'Original RTX Remix user.conf')) {
            throw 'RTX Remix user.conf changed after experiment planning; the transaction was not started.'
        }
    }
    elseif (Test-Path -LiteralPath $Plan.UserConfigPath) {
        throw 'RTX Remix user.conf appeared after experiment planning; the transaction was not started.'
    }
}

function New-FearRemixExperimentJournalRecord {
    param([Parameter(Mandatory)]$Plan)

    [pscustomobject][ordered]@{
        JournalKind              = 'FearMore.RemixExperimentTransaction'
        SchemaVersion            = 1
        State                    = 'Intent'
        TransactionId            = $Plan.TransactionId
        GeneratedUtc             = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        RetailRoot               = $Plan.RetailRoot
        StageRoot                = $Plan.StageRoot
        InstallIdentitySha256    = $Plan.InstallIdentitySha256
        Experiment               = $Plan.Experiment
        Variant                  = $Plan.Variant
        SettingName              = $Plan.SettingName
        SettingValue             = $Plan.SettingValue
        UserConfigRelativePath   = 'user.conf'
        BackupRelativePath       = 'fearmore-remix-experiment.user-conf.previous'
        CandidateRelativePath    = 'fearmore-remix-experiment.user-conf.candidate'
        RestoreRelativePath      = 'fearmore-remix-experiment.user-conf.restore'
        OriginalUserConfigPresent = [bool]$Plan.OriginalUserConfigPresent
        OriginalUserConfigSize   = [long]$Plan.OriginalUserConfigSize
        OriginalUserConfigSha256 = $Plan.OriginalUserConfigSha256
        GeneratedUserConfigSize  = [long]$Plan.GeneratedUserConfigSize
        GeneratedUserConfigSha256 = $Plan.GeneratedUserConfigSha256
    }
}

function Install-FearRemixExperimentUserConfig {
    param([Parameter(Mandatory)]$Plan)

    Assert-FearRetailSidecarGameNotRunning
    Assert-FearRemixExperimentPreimage -Plan $Plan
    $journal = New-FearRemixExperimentJournalRecord -Plan $Plan
    Write-FearRemixExperimentJournal -Path $Plan.JournalPath -Journal $journal -Root $Plan.RetailRoot
    try {
        if ($Plan.OriginalUserConfigPresent) {
            Assert-FearRemixExperimentPreimage -Plan $Plan
            [IO.File]::Copy($Plan.UserConfigPath, $Plan.BackupPath, $false)
            Invoke-FearRemixExperimentWriteCheckpoint
            if (-not (Test-FearRemixExperimentFileIdentity `
                    -Path $Plan.BackupPath `
                    -Root $Plan.RetailRoot `
                    -ExpectedSha256 $Plan.OriginalUserConfigSha256 `
                    -ExpectedSize $Plan.OriginalUserConfigSize `
                    -Description 'RTX Remix experiment user.conf backup')) {
                throw 'RTX Remix experiment backup verification failed.'
            }
        }
        $journal.State = 'BackedUp'
        Write-FearRemixExperimentJournal -Path $Plan.JournalPath -Journal $journal -Root $Plan.RetailRoot

        Write-FearRemixDurableNewFile `
            -Path $Plan.CandidatePath `
            -Bytes ([byte[]]$Plan.GeneratedUserConfigBytes) `
            -Root $Plan.RetailRoot
        if (-not (Test-FearRemixExperimentFileIdentity `
                -Path $Plan.CandidatePath `
                -Root $Plan.RetailRoot `
                -ExpectedSha256 $Plan.GeneratedUserConfigSha256 `
                -ExpectedSize $Plan.GeneratedUserConfigSize `
                -Description 'Generated RTX Remix experiment user.conf candidate')) {
            throw 'Generated RTX Remix experiment user.conf candidate verification failed.'
        }
        Assert-FearRemixExperimentPreimage -Plan $Plan
        if ($Plan.OriginalUserConfigPresent) {
            Move-FearRemixExperimentFileReplaceExisting `
                -Source $Plan.CandidatePath `
                -Destination $Plan.UserConfigPath `
                -Root $Plan.RetailRoot
        }
        else {
            [IO.File]::Move($Plan.CandidatePath, $Plan.UserConfigPath)
        }
        Invoke-FearRemixExperimentWriteCheckpoint
        if (-not (Test-FearRemixExperimentFileIdentity `
                -Path $Plan.UserConfigPath `
                -Root $Plan.RetailRoot `
                -ExpectedSha256 $Plan.GeneratedUserConfigSha256 `
                -ExpectedSize $Plan.GeneratedUserConfigSize `
                -Description 'Applied RTX Remix experiment user.conf')) {
            throw 'Applied RTX Remix experiment user.conf verification failed.'
        }
        $journal.State = 'Applied'
        Write-FearRemixExperimentJournal -Path $Plan.JournalPath -Journal $journal -Root $Plan.RetailRoot
        return Get-FearRemixExperimentRecoveryState -RetailRoot $Plan.RetailRoot
    }
    catch {
        throw
    }
}

function Restore-FearRemixExperimentUserConfig {
    param([Parameter(Mandatory)]$RecoveryState)

    Assert-FearRetailSidecarGameNotRunning
    $state = Get-FearRemixExperimentRecoveryState -RetailRoot $RecoveryState.RetailRoot
    if (-not $state -or $state.TransactionId -cne $RecoveryState.TransactionId) {
        throw 'RTX Remix experiment recovery state changed before restoration.'
    }

    $userIsOriginal = $false
    if ($state.OriginalUserConfigPresent -and $state.UserConfigPresent) {
        $userIsOriginal = $state.UserConfigSha256 -ceq $state.OriginalUserConfigSha256 -and
            (Get-Item -LiteralPath $state.UserConfigPath -Force).Length -eq $state.OriginalUserConfigSize
    }
    if ($state.OriginalUserConfigPresent -and -not $userIsOriginal) {
        if (-not $state.BackupPresent) {
            throw 'Original RTX Remix user.conf cannot be restored because its verified transaction backup is missing.'
        }
        $journal = $state.Journal
        $journal.State = 'Restoring'
        Write-FearRemixExperimentJournal -Path $state.JournalPath -Journal $journal -Root $state.RetailRoot
        [IO.File]::Copy($state.BackupPath, $state.RestorePath, $false)
        Invoke-FearRemixExperimentWriteCheckpoint
        if (-not (Test-FearRemixExperimentFileIdentity `
                -Path $state.RestorePath `
                -Root $state.RetailRoot `
                -ExpectedSha256 $state.OriginalUserConfigSha256 `
                -ExpectedSize $state.OriginalUserConfigSize `
                -Description 'RTX Remix experiment restore candidate')) {
            throw 'RTX Remix experiment restore candidate verification failed.'
        }
        if (Test-Path -LiteralPath $state.UserConfigPath) {
            Assert-FearRetailSidecarOrdinaryFile -Root $state.RetailRoot -Path $state.UserConfigPath -Description 'Temporary RTX Remix experiment user.conf' | Out-Null
            Move-FearRemixExperimentFileReplaceExisting `
                -Source $state.RestorePath `
                -Destination $state.UserConfigPath `
                -Root $state.RetailRoot
        }
        else {
            [IO.File]::Move($state.RestorePath, $state.UserConfigPath)
        }
        Invoke-FearRemixExperimentWriteCheckpoint
        if (-not (Test-FearRemixExperimentFileIdentity `
                -Path $state.UserConfigPath `
                -Root $state.RetailRoot `
                -ExpectedSha256 $state.OriginalUserConfigSha256 `
                -ExpectedSize $state.OriginalUserConfigSize `
                -Description 'Restored RTX Remix user.conf')) {
            throw 'Restored RTX Remix user.conf does not match its byte-exact pre-experiment identity.'
        }
    }
    elseif (-not $state.OriginalUserConfigPresent -and $state.UserConfigPresent) {
        Remove-FearRemixExperimentFile `
            -Path $state.UserConfigPath `
            -Root $state.RetailRoot `
            -Description 'Temporary RTX Remix experiment user.conf'
    }

    Remove-FearRemixExperimentFile -Path $state.CandidatePath -Root $state.RetailRoot -Description 'RTX Remix experiment candidate'
    Remove-FearRemixExperimentFile -Path $state.RestorePath -Root $state.RetailRoot -Description 'RTX Remix experiment restore candidate'
    Remove-FearRemixExperimentFile -Path $state.BackupPath -Root $state.RetailRoot -Description 'RTX Remix experiment backup'
    Remove-FearRemixExperimentFile -Path $state.JournalPath -Root $state.RetailRoot -Description 'RTX Remix experiment journal'
    if (Get-FearRemixExperimentRecoveryState -RetailRoot $state.RetailRoot) {
        throw 'RTX Remix experiment recovery state still exists after restoration.'
    }
    return [pscustomobject]@{
        Restored                  = $true
        TransactionId             = $state.TransactionId
        OriginalUserConfigPresent = $state.OriginalUserConfigPresent
        UserConfigPath            = $state.UserConfigPath
    }
}

function Resolve-FearRemixExperimentSteamExecutable {
    param([AllowNull()][string]$ExplicitPath)

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        return [IO.Path]::GetFullPath($ExplicitPath)
    }
    $candidates = @(
        Get-Process -Name 'steam' -ErrorAction SilentlyContinue |
            ForEach-Object { try { $_.Path } catch { $null } } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { [IO.Path]::GetFullPath($_) } |
            Sort-Object -Unique
    )
    if ($candidates.Count -ne 1) {
        throw 'RTX Remix experiment launch requires exactly one running Steam executable in this Windows session; pass -SteamExecutable to disambiguate.'
    }
    return $candidates[0]
}

$canonicalRetailRoot = [IO.Path]::GetFullPath($RetailRoot).TrimEnd('\')
$lockPath = Get-FearRetailSidecarTargetPath -Root $canonicalRetailRoot -RelativePath 'fearmore-remix-experiment.lock'
$lock = Open-FearRemixExperimentLock -Path $lockPath -Root $canonicalRetailRoot
try {
    if ($PSCmdlet.ParameterSetName -ceq 'Recover') {
        $state = Get-FearRemixExperimentRecoveryState -RetailRoot $canonicalRetailRoot
        if (-not $state) {
            return [pscustomobject]@{ Recovered=$false; RetailRoot=$canonicalRetailRoot; Note='No RTX Remix experiment transaction requires recovery.' }
        }
        Assert-FearRetailSidecarGameNotRunning
        if (-not $PSCmdlet.ShouldProcess($canonicalRetailRoot, "Restore user.conf from RTX Remix experiment transaction $($state.TransactionId)")) {
            return [pscustomobject]@{ Recovered=$false; RetailRoot=$canonicalRetailRoot; TransactionId=$state.TransactionId; WhatIf=$true }
        }
        $restored = Restore-FearRemixExperimentUserConfig -RecoveryState $state
        return [pscustomobject]@{
            Recovered                  = $true
            RetailRoot                 = $canonicalRetailRoot
            TransactionId              = $restored.TransactionId
            OriginalUserConfigPresent  = $restored.OriginalUserConfigPresent
        }
    }

    $existingRecovery = Get-FearRemixExperimentRecoveryState -RetailRoot $canonicalRetailRoot
    if ($existingRecovery) {
        throw "RTX Remix experiment transaction '$($existingRecovery.TransactionId)' requires -Recover before another run."
    }
    Assert-FearRetailSidecarGameNotRunning
    $plan = New-FearRemixExperimentPlan `
        -StageRoot $StageRoot `
        -RetailRoot $canonicalRetailRoot `
        -Experiment $Experiment `
        -Variant $Variant
    if (-not $PSCmdlet.ShouldProcess(
            $plan.UserConfigPath,
            "Temporarily apply RTX Remix $($plan.Experiment) $($plan.Variant), launch F.E.A.R., wait for exit, and restore user.conf")) {
        return [pscustomobject]@{
            Experiment=$plan.Experiment; Variant=$plan.Variant; Applied=$false; Launched=$false;
            Restored=$false; WhatIf=$true; PlanFingerprint=$plan.PlanFingerprint
        }
    }

    $gameProcessId = $null
    $launchResult = $null
    $restoredResult = $null
    $appliedState = $null
    try {
        $appliedState = Install-FearRemixExperimentUserConfig -Plan $plan
        $runtimeSafety = Get-FearRtxRemixRuntimeConfigSafetyIdentity `
            -Path $plan.RuntimeConfigPath `
            -UserConfigPath $plan.UserConfigPath
        if (-not $runtimeSafety.SafeForFearMoreLaunch -or
            $runtimeSafety.UserConfigSha256 -cne $plan.GeneratedUserConfigSha256) {
            throw 'Applied RTX Remix experiment config did not pass the existing effective launch-safety identity.'
        }
        $steamPath = Resolve-FearRemixExperimentSteamExecutable -ExplicitPath $SteamExecutable
        $steamIdentity = Get-FearRunningSteamClientIdentity -SteamExecutable $steamPath
        $steamPlan = New-FearSteamLaunchPlan `
            -StageRoot $plan.StageRoot `
            -SteamExecutable $steamIdentity.SteamExecutable `
            -ExpectedRetailRoot $plan.RetailRoot `
            -ExpectedRemixExperimentTransactionId $plan.TransactionId `
            -AdditionalGameArguments @($LaunchArguments) `
            -RequireRunningSteamClient
        $launchResult = Invoke-FearSteamLaunchPlan -Plan $steamPlan -Confirm:$false
        if (-not $launchResult -or -not $launchResult.ProcessStarted -or -not $launchResult.GameProcessId) {
            throw 'Steam dispatch did not return one exact observed F.E.A.R. process for the RTX Remix experiment.'
        }
        $gameProcessId = [int]$launchResult.GameProcessId
        if (Get-Process -Id $gameProcessId -ErrorAction SilentlyContinue) {
            try { Wait-Process -Id $gameProcessId -ErrorAction Stop }
            catch {
                if (Get-Process -Id $gameProcessId -ErrorAction SilentlyContinue) { throw }
            }
        }
    }
    finally {
        $gameStillRunning = $false
        if ($gameProcessId) {
            $remainingProcess = Get-Process -Id $gameProcessId -ErrorAction SilentlyContinue
            if ($remainingProcess) {
                try {
                    $remainingPath = [IO.Path]::GetFullPath($remainingProcess.Path)
                    $expectedPath = [IO.Path]::GetFullPath([string]$launchResult.GameExecutable)
                    $gameStillRunning = $remainingPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)
                }
                catch {
                    # A still-live PID whose executable cannot be re-attested is
                    # not a safe moment to replace a renderer-owned file.
                    $gameStillRunning = $true
                }
            }
        }
        if ($gameStillRunning) {
            Write-Warning "F.E.A.R. PID $gameProcessId is still running; user.conf remains transaction-owned and must be restored with -Recover after the process exits."
        }
        else {
            $pending = Get-FearRemixExperimentRecoveryState -RetailRoot $plan.RetailRoot
            if ($pending) {
                $restoredResult = Restore-FearRemixExperimentUserConfig -RecoveryState $pending
            }
        }
    }

    return [pscustomobject][ordered]@{
        Experiment             = $plan.Experiment
        Variant                = $plan.Variant
        SettingName            = $plan.SettingName
        SettingValue           = $plan.SettingValue
        TransactionId          = $plan.TransactionId
        GeneratedUserConfigSha256 = $plan.GeneratedUserConfigSha256
        PlanFingerprint        = $plan.PlanFingerprint
        Applied                = $null -ne $appliedState
        Launched               = $null -ne $launchResult -and [bool]$launchResult.ProcessStarted
        GameProcessId          = $gameProcessId
        Restored               = $null -ne $restoredResult -and [bool]$restoredResult.Restored
        OriginalUserConfigPresent = [bool]$plan.OriginalUserConfigPresent
    }
}
finally {
    if ($lock) { $lock.Dispose() }
}
