[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$RepositoryRoot,
    [string]$RetailRoot,

    [ValidateRange(30, 900)]
    [int]$TimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
$runtimeModule = Join-Path $PSScriptRoot 'FearRuntimeExecutable.psm1'
foreach ($path in @($stageScript, $runtimeModule)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "FearMore LAA bootstrap dependency is missing: $path"
    }
}
Import-Module $runtimeModule -Force -ErrorAction Stop

$stageParameters = @{
    Lane           = 'StockEchoPatch'
    RepositoryRoot = $RepositoryRoot
    Confirm        = $false
}
if (-not [string]::IsNullOrWhiteSpace($RetailRoot)) {
    $stageParameters.RetailRoot = $RetailRoot
}

$results = @(& $stageScript @stageParameters)
if ($results.Count -ne 1 -or -not $results[0].LayoutValidated -or -not $results[0].InputsValidated) {
    throw 'The guarded StockEchoPatch staging workflow did not return one validated result.'
}
$stage = $results[0]
$retailExecutable = Join-Path ([string]$stage.RetailRoot) 'FEAR.exe'
$patchedExecutable = Join-Path ([string]$stage.StageRoot) 'FEAR.exe'
$backupExecutable = Join-Path ([string]$stage.StageRoot) 'FEAR.exe.bak'

function Get-CompletedLaaPair {
    try {
        Get-FearAttestedLaaRuntimeExecutablePairIdentity `
            -RetailExecutable $retailExecutable `
            -PatchedExecutable $patchedExecutable `
            -BackupExecutable $backupExecutable
    }
    catch {
        $null
    }
}

$existingPair = Get-CompletedLaaPair
if ($existingPair) {
    return [pscustomobject]@{
        Status                    = 'PASS'
        Created                   = $false
        RetailExecutable          = $retailExecutable
        PatchedExecutable         = $patchedExecutable
        PatchedExecutableSha256   = $existingPair.PatchedExecutableSha256
        BackupExecutableSha256    = $existingPair.BackupExecutableSha256
        RetailInstallationChanged = $false
    }
}
if (-not [bool]$stage.BootstrapRequired) {
    throw 'The StockEchoPatch stage reported no bootstrap requirement, but its LAA executable pair did not attest.'
}

Write-Host ''
Write-Host 'FearMore HD Lite needs a one-time Large Address Aware setup.' -ForegroundColor Cyan
Write-Host 'EchoPatch will ask for permission to patch FearMore''s disposable FEAR.exe copy.'
Write-Host 'Choose Yes. If the temporary game opens, close that temporary window after the menu appears.'
Write-Host 'Your Steam/GOG installation is not modified.' -ForegroundColor Green
Write-Host ''

$process = Start-Process `
    -FilePath $patchedExecutable `
    -WorkingDirectory ([string]$stage.StageRoot) `
    -PassThru
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$completedPair = $null
do {
    Start-Sleep -Milliseconds 500
    $completedPair = Get-CompletedLaaPair
    if ($completedPair) {
        break
    }
    $process.Refresh()
    if ($process.HasExited) {
        Start-Sleep -Seconds 2
        $completedPair = Get-CompletedLaaPair
        if ($completedPair) {
            break
        }
        throw 'EchoPatch closed before a valid FearMore LAA pair was created. Re-run Finish FearMore HD Setup and accept the LAA prompt.'
    }
} while ([DateTime]::UtcNow -lt $deadline)

if (-not $completedPair) {
    throw "Timed out after $TimeoutSeconds seconds while waiting for EchoPatch to create the attested FearMore LAA pair."
}

[pscustomobject]@{
    Status                    = 'PASS'
    Created                   = $true
    RetailExecutable          = $retailExecutable
    PatchedExecutable         = $patchedExecutable
    PatchedExecutableSha256   = $completedPair.PatchedExecutableSha256
    BackupExecutableSha256    = $completedPair.BackupExecutableSha256
    RetailInstallationChanged = $false
}
