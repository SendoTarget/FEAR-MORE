[CmdletBinding()]
param([string]$RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

if (-not $RepositoryRoot) { $RepositoryRoot = Join-Path $PSScriptRoot '..\..' }
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$modulePath = Join-Path $PSScriptRoot 'FearRemixExperimentPlan.psm1'
$sessionScript = Join-Path $PSScriptRoot 'Invoke-FearRemixExperiment.ps1'
$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
Import-Module $modulePath -Force -ErrorAction Stop
$experimentModule = Get-Module FearRemixExperimentPlan

function Get-TestHashFromBytes([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Get-TestHash([string]$Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    Get-TestHashFromBytes $bytes
}

function Write-TestBytes([string]$Path, [byte[]]$Bytes) {
    [IO.File]::WriteAllBytes($Path, $Bytes)
}

function New-TestJournal {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][ValidateSet('Intent','BackedUp','Applied')][string]$State,
        [Parameter(Mandatory)][bool]$OriginalPresent,
        [AllowNull()][byte[]]$OriginalBytes,
        [Parameter(Mandatory)][byte[]]$GeneratedBytes
    )
    [pscustomobject][ordered]@{
        JournalKind='FearMore.RemixExperimentTransaction'; SchemaVersion=1; State=$State;
        TransactionId='0123456789abcdef0123456789abcdef'; GeneratedUtc='2026-07-15T00:00:00.0000000Z';
        RetailRoot=[IO.Path]::GetFullPath($Root).TrimEnd('\'); StageRoot='D:\synthetic-stage';
        InstallIdentitySha256=('A' * 64); Experiment='AlphaBlendOff'; Variant='Candidate';
        SettingName='rtx.enableAlphaBlend'; SettingValue='False'; UserConfigRelativePath='user.conf';
        BackupRelativePath='fearmore-remix-experiment.user-conf.previous';
        CandidateRelativePath='fearmore-remix-experiment.user-conf.candidate';
        RestoreRelativePath='fearmore-remix-experiment.user-conf.restore';
        OriginalUserConfigPresent=$OriginalPresent;
        OriginalUserConfigSize=$(if ($OriginalPresent) { [long]$OriginalBytes.Length } else { 0L });
        OriginalUserConfigSha256=$(if ($OriginalPresent) { Get-TestHashFromBytes $OriginalBytes } else { $null });
        GeneratedUserConfigSize=[long]$GeneratedBytes.Length;
        GeneratedUserConfigSha256=Get-TestHashFromBytes $GeneratedBytes
    }
}

function Write-TestJournal([string]$Root, $Journal) {
    $path = Join-Path $Root 'fearmore-remix-experiment.transaction.json'
    [IO.File]::WriteAllText($path, ($Journal | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Get-TestSnapshot([string]$Root) {
    @(
        Get-ChildItem -LiteralPath $Root -Force | Sort-Object Name | ForEach-Object {
            if ($_.PSIsContainer) { "D|$($_.Name)" }
            else { "F|$($_.Name)|$($_.Length)|$(Get-TestHash $_.FullName)" }
        }
    ) -join "`n"
}

function Clear-TestRoot([string]$Root) {
    Get-ChildItem -LiteralPath $Root -Force | Remove-Item -Recurse -Force
}

$definitions = @(
    @{ Name='WhiteMaterialOff'; Setting='rtx.useWhiteMaterialMode'; Value='False' },
    @{ Name='AlphaBlendOff'; Setting='rtx.enableAlphaBlend'; Value='False' },
    @{ Name='VertexCapturedNormalsOff'; Setting='rtx.useVertexCapturedNormals'; Value='False' },
    @{ Name='SkyAutoDetect2'; Setting='rtx.skyAutoDetect'; Value='2' },
    @{ Name='WorldMatricesOff'; Setting='rtx.useWorldMatricesForShaders'; Value='False' },
    @{ Name='EmissiveOverrideOff'; Setting='rtx.enableEmissiveBlendEmissiveOverride'; Value='False' },
    @{ Name='EmissiveTranslationOff'; Setting='rtx.enableEmissiveBlendModeTranslation'; Value='False' },
    @{ Name='LegacyAlbedoDiagnostic'; Setting='rtx.legacyMaterial.useAlbedoTextureIfPresent'; Value='False' }
)
foreach ($expected in $definitions) {
    $definition = Get-FearRemixExperimentDefinition -Name $expected.Name
    if ($definition.SettingName -cne $expected.Setting -or $definition.CandidateValue -cne $expected.Value) {
        throw "RTX Remix experiment definition changed unexpectedly: $($expected.Name)"
    }
    $control = & $experimentModule {
        param($Definition)
        Get-FearRemixExperimentUserConfigIdentity -Definition $Definition -Variant Control
    } $definition
    $candidate = & $experimentModule {
        param($Definition)
        Get-FearRemixExperimentUserConfigIdentity -Definition $Definition -Variant Candidate
    } $definition
    $controlActive = @($control.Text -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') })
    $candidateActive = @($candidate.Text -split "`r?`n" | Where-Object { $_ -and -not $_.StartsWith('#') })
    if ($controlActive.Count -ne 3 -or $candidateActive.Count -ne 4 -or
        $candidateActive[3] -cne "$($expected.Setting) = $($expected.Value)" -or
        (@($candidateActive[0..2]) -join "`n") -cne ($controlActive -join "`n")) {
        throw "Control/Candidate configs do not differ by exactly one declared setting: $($expected.Name)"
    }
}
$unknownRejected = $false
try { Get-FearRemixExperimentDefinition -Name 'unbounded.setting' | Out-Null }
catch { $unknownRejected = $_.Exception.Message.Contains('Unknown RTX Remix experiment') }
if (-not $unknownRejected) { throw 'RTX Remix experiment definitions accepted an unbounded setting name.' }

$fixtureRoot = Join-Path $RepositoryRoot 'local-runtime\test-remix-experiment'
if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
[IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
try {
    $userPath = Join-Path $fixtureRoot 'user.conf'
    $backupPath = Join-Path $fixtureRoot 'fearmore-remix-experiment.user-conf.previous'
    $journalPath = Join-Path $fixtureRoot 'fearmore-remix-experiment.transaction.json'
    $alphaDefinition = Get-FearRemixExperimentDefinition -Name 'AlphaBlendOff'
    $alphaCandidate = & $experimentModule {
        param($Definition)
        Get-FearRemixExperimentUserConfigIdentity -Definition $Definition -Variant Candidate
    } $alphaDefinition
    $generatedBytes = [byte[]]$alphaCandidate.Bytes
    $originalBytes = [byte[]](0xEF,0xBB,0xBF,0x23,0x20,0x75,0x73,0x65,0x72,0x0D,0x0A,0x00,0x7F)

    # Applied replacement restores an arbitrary pre-existing user.conf byte-for-byte.
    Write-TestBytes $userPath $generatedBytes
    Write-TestBytes $backupPath $originalBytes
    Write-TestJournal $fixtureRoot (New-TestJournal -Root $fixtureRoot -State Applied -OriginalPresent $true -OriginalBytes $originalBytes -GeneratedBytes $generatedBytes)
    $recovered = & $sessionScript -Recover -RetailRoot $fixtureRoot -Confirm:$false
    if (-not $recovered.Recovered -or
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($userPath)) -cne [Convert]::ToBase64String($originalBytes) -or
        (Test-Path -LiteralPath $journalPath) -or (Test-Path -LiteralPath $backupPath)) {
        throw 'RTX Remix experiment recovery did not restore the pre-existing user.conf byte-for-byte.'
    }

    # An originally absent file returns to absent.
    Clear-TestRoot $fixtureRoot
    Write-TestBytes $userPath $generatedBytes
    Write-TestJournal $fixtureRoot (New-TestJournal -Root $fixtureRoot -State Applied -OriginalPresent $false -OriginalBytes $null -GeneratedBytes $generatedBytes)
    $recoveredAbsent = & $sessionScript -Recover -RetailRoot $fixtureRoot -Confirm:$false
    if (-not $recoveredAbsent.Recovered -or (Test-Path -LiteralPath $userPath) -or (Test-Path -LiteralPath $journalPath)) {
        throw 'RTX Remix experiment recovery did not restore an originally absent user.conf state.'
    }

    # Intent written before any replacement cleans up without changing the original.
    Clear-TestRoot $fixtureRoot
    Write-TestBytes $userPath $originalBytes
    Write-TestJournal $fixtureRoot (New-TestJournal -Root $fixtureRoot -State Intent -OriginalPresent $true -OriginalBytes $originalBytes -GeneratedBytes $generatedBytes)
    & $sessionScript -Recover -RetailRoot $fixtureRoot -Confirm:$false | Out-Null
    if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($userPath)) -cne [Convert]::ToBase64String($originalBytes) -or
        (Test-Path -LiteralPath $journalPath)) {
        throw 'Intent-only RTX Remix experiment recovery changed the original user.conf.'
    }

    # WhatIf leaves every transaction byte unchanged.
    Clear-TestRoot $fixtureRoot
    Write-TestBytes $userPath $generatedBytes
    Write-TestJournal $fixtureRoot (New-TestJournal -Root $fixtureRoot -State Applied -OriginalPresent $false -OriginalBytes $null -GeneratedBytes $generatedBytes)
    $beforeWhatIf = Get-TestSnapshot $fixtureRoot
    $whatIf = & $sessionScript -Recover -RetailRoot $fixtureRoot -WhatIf
    $afterWhatIf = Get-TestSnapshot $fixtureRoot
    if (-not $whatIf.WhatIf -or $beforeWhatIf -cne $afterWhatIf) {
        throw 'RTX Remix experiment -WhatIf recovery mutated the fixture.'
    }
    & $sessionScript -Recover -RetailRoot $fixtureRoot -Confirm:$false | Out-Null

    # A deterministic interruption during restoration leaves a recoverable
    # journal, and the next invocation completes the original absent state.
    Clear-TestRoot $fixtureRoot
    Write-TestBytes $userPath $generatedBytes
    Write-TestJournal $fixtureRoot (New-TestJournal -Root $fixtureRoot -State Applied -OriginalPresent $false -OriginalBytes $null -GeneratedBytes $generatedBytes)
    $restoreInterrupted = $false
    try {
        & $sessionScript -Recover -RetailRoot $fixtureRoot -TestFailureAfterWriteCount 1 -Confirm:$false | Out-Null
    }
    catch { $restoreInterrupted = $_.Exception.Message.Contains('Synthetic RTX Remix experiment failure') }
    if (-not $restoreInterrupted -or -not (Test-Path -LiteralPath $journalPath)) {
        throw 'Synthetic RTX Remix restoration interruption did not retain its recovery journal.'
    }
    & $sessionScript -Recover -RetailRoot $fixtureRoot -Confirm:$false | Out-Null
    if ((Test-Path -LiteralPath $userPath) -or (Test-Path -LiteralPath $journalPath)) {
        throw 'RTX Remix experiment did not recover after an interrupted restoration.'
    }

    # Corrupt backup and path-type swaps fail closed with recovery evidence retained.
    Clear-TestRoot $fixtureRoot
    Write-TestBytes $userPath $generatedBytes
    Write-TestBytes $backupPath ([byte[]](1,2,3))
    Write-TestJournal $fixtureRoot (New-TestJournal -Root $fixtureRoot -State Applied -OriginalPresent $true -OriginalBytes $originalBytes -GeneratedBytes $generatedBytes)
    $backupRejected = $false
    try { Get-FearRemixExperimentRecoveryState -RetailRoot $fixtureRoot | Out-Null }
    catch { $backupRejected = $_.Exception.Message.Contains('backup does not match') }
    if (-not $backupRejected -or -not (Test-Path -LiteralPath $journalPath)) {
        throw 'RTX Remix experiment recovery did not fail closed on a corrupt backup.'
    }

    Clear-TestRoot $fixtureRoot
    [IO.Directory]::CreateDirectory($userPath) | Out-Null
    Write-TestJournal $fixtureRoot (New-TestJournal -Root $fixtureRoot -State Applied -OriginalPresent $false -OriginalBytes $null -GeneratedBytes $generatedBytes)
    $typeSwapRejected = $false
    try { Get-FearRemixExperimentRecoveryState -RetailRoot $fixtureRoot | Out-Null }
    catch { $typeSwapRejected = $_.Exception.Message.Contains('ordinary file') }
    if (-not $typeSwapRejected -or -not (Test-Path -LiteralPath $journalPath)) {
        throw 'RTX Remix experiment recovery did not fail closed on a user.conf path-type swap.'
    }

    Clear-TestRoot $fixtureRoot
    [IO.File]::WriteAllText($journalPath, '{broken', [Text.UTF8Encoding]::new($false))
    $unreadableRejected = $false
    try { Get-FearRemixExperimentRecoveryState -RetailRoot $fixtureRoot | Out-Null }
    catch { $unreadableRejected = $_.Exception.Message.Contains('unreadable') }
    if (-not $unreadableRejected -or -not (Test-Path -LiteralPath $journalPath)) {
        throw 'RTX Remix experiment recovery did not retain an unreadable journal.'
    }

    $sessionSource = Get-Content -LiteralPath $sessionScript -Raw
    $stageSource = Get-Content -LiteralPath $stageScript -Raw
    if ($sessionSource -notmatch '(?m)^\[CmdletBinding\(SupportsShouldProcess\s*=\s*\$true' -or
        $stageSource -match 'FearRemixExperiment|user\.conf') {
        throw 'RTX Remix experiment mutation escaped its focused SupportsShouldProcess owner or entered New-FearRuntimeStage.ps1.'
    }

    [pscustomobject][ordered]@{
        DefinitionAllowlistValidated=$true; OneSettingDifferenceValidated=$true;
        ByteExactRestoreValidated=$true; OriginallyAbsentRestoreValidated=$true;
        IntentRecoveryValidated=$true; WhatIfNoMutationValidated=$true;
        InterruptedRestoreRecoveryValidated=$true;
        CorruptBackupRejected=$true; PathTypeSwapRejected=$true; UnreadableJournalRejected=$true;
        StageOrchestratorUnchanged=$true; RealRetailTouched=$false; SteamLaunched=$false
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
}
