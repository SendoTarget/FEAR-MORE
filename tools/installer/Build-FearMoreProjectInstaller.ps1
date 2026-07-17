[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$RepositoryRoot,
    [string]$LauncherRoot,
    [string]$HdLiteRoot,
    [string]$OutputRoot,
    [string]$IsccPath,
    [switch]$WithoutHdLite,
    [switch]$PrivateHouseholdBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
if (-not $PrivateHouseholdBuild) {
    throw 'Re-run with -PrivateHouseholdBuild, or use Build FearMore Project Installer.cmd, to acknowledge that the output is private and must not be published.'
}
if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot '.git') -PathType Container)) {
    throw "The Project Installer must be built from a FearMore developer checkout: $RepositoryRoot"
}
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $git) {
    throw 'Git is required to attest the exact clean source revision used by the private Project Installer.'
}
$revisionOutput = @(& $git.Source -C $RepositoryRoot rev-parse HEAD 2>$null)
if ($LASTEXITCODE -ne 0 -or $revisionOutput.Count -ne 1 -or
    [string]$revisionOutput[0] -notmatch '^[0-9A-Fa-f]{40}$') {
    throw 'The current FearMore Git revision could not be resolved.'
}
$currentRevision = [string]$revisionOutput[0]
$trackedStatus = @(& $git.Source -C $RepositoryRoot status --porcelain --untracked-files=no 2>$null)
if ($LASTEXITCODE -ne 0) {
    throw 'The tracked FearMore working-tree state could not be inspected.'
}
if ($trackedStatus.Count -gt 0) {
    throw 'Commit or restore tracked source changes before building a reproducible Project Installer. Ignored private inputs and outputs do not block this check.'
}

$launcherBuilder = Join-Path $RepositoryRoot 'tools\runtime\New-FearMoreLauncherPackage.ps1'
$installerBuilder = Join-Path $PSScriptRoot 'New-FearMoreInstallerPackage.ps1'
$launcherModule = Join-Path $RepositoryRoot 'tools\runtime\FearLauncherPackage.psm1'
foreach ($path in @($launcherBuilder, $installerBuilder, $launcherModule)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "FearMore Project Installer component is missing: $path"
    }
}

if ([string]::IsNullOrWhiteSpace($LauncherRoot)) {
    $LauncherRoot = Join-Path $RepositoryRoot 'dist\local\FearMore-Playable'
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepositoryRoot 'dist\local\FearMore-Project-Installer'
}
$LauncherRoot = [IO.Path]::GetFullPath($LauncherRoot).TrimEnd('\')
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')

Import-Module $launcherModule -Force -ErrorAction Stop
$launcherIdentity = $null
if (Test-Path -LiteralPath $LauncherRoot -PathType Container) {
    Write-Host "Verifying existing private launcher payload: $LauncherRoot"
    $launcherIdentity = Test-FearMoreLauncherPackageIntegrity -PackageRoot $LauncherRoot
    if ($launcherIdentity.SourceRevision -cne $currentRevision -or
        $launcherIdentity.SourceTreeState -cne 'Clean') {
        throw ("The existing launcher was not built from the current clean Git revision $currentRevision. " +
            "Move or remove '$LauncherRoot', then rerun this builder so it can assemble a current launcher.")
    }
}
else {
    $requiredPrivateInputs = @(
        'build\fear-win32\bin\Release\ClientFx.fxd',
        'build\fear-win32\bin\Release\GameClient.dll',
        'build\fear-win32\bin\Release\GameServer.dll',
        'vendor-local\controller-deps\SDL3-3.4.10-win32-x86.zip',
        'vendor-local\renderer-deps\dgVoodoo2_87_3.zip',
        'vendor-local\EchoPatch-4.2.1.zip',
        'vendor-local\echopatch-engine-only\manifest-b4a7074e4cbb.json',
        'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb\dinput8.dll',
        'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb\EchoPatch.ini'
    )
    $missingPrivateInputs = @($requiredPrivateInputs | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $_) -PathType Leaf)
        })
    if ($missingPrivateInputs.Count -gt 0) {
        $missingList = ($missingPrivateInputs | ForEach-Object { "  - $_" }) -join "`n"
        throw ("The private launcher cannot be assembled until these ignored local inputs exist:`n" +
            $missingList + "`nFollow QUICKSTART.md and docs/building.md, then run this command again.")
    }

    Write-Host 'Assembling the validated private FearMore launcher payload...'
    $launcherResults = @(& $launcherBuilder `
            -RepositoryRoot $RepositoryRoot `
            -OutputRoot $LauncherRoot `
            -PrivateOwnerBuild `
            -Confirm:$false)
    if ($launcherResults.Count -ne 1 -or $launcherResults[0].Status -cne 'PASS') {
        throw 'The private launcher assembler did not return exactly one passing result.'
    }
    $launcherIdentity = Test-FearMoreLauncherPackageIntegrity -PackageRoot $LauncherRoot
    if ($launcherIdentity.SourceRevision -cne $currentRevision -or
        $launcherIdentity.SourceTreeState -cne 'Clean') {
        throw 'The newly assembled launcher did not record the current clean Git revision.'
    }
}

if (Test-Path -LiteralPath $OutputRoot) {
    throw ("The Project Installer output already exists and is never overwritten: $OutputRoot`n" +
        'Move or remove that private output after verifying its contents, then run the builder again.')
}

$installerParameters = @{
    RepositoryRoot        = $RepositoryRoot
    LauncherRoot          = $LauncherRoot
    OutputRoot            = $OutputRoot
    PrivateHouseholdBuild = $true
    Confirm               = $false
}
if (-not [string]::IsNullOrWhiteSpace($HdLiteRoot)) {
    $installerParameters.HdLiteRoot = $HdLiteRoot
}
if (-not [string]::IsNullOrWhiteSpace($IsccPath)) {
    $installerParameters.IsccPath = $IsccPath
}
if ($WithoutHdLite) {
    $installerParameters.WithoutHdLite = $true
}

Write-Host 'Compiling the private FearMore Project Installer...'
$installerResults = @(& $installerBuilder @installerParameters)
if ($installerResults.Count -ne 1 -or $installerResults[0].Status -cne 'PASS') {
    throw 'The Project Installer compiler did not return exactly one passing result.'
}
$installer = $installerResults[0]

Write-Host ''
Write-Host 'FearMore Project Installer build completed.' -ForegroundColor Green
Write-Host "Copy this entire folder: $($installer.OutputRoot)"
Write-Host 'The recipient runs FearMore-Setup.exe and keeps every adjacent .bin file beside it.'
Write-Host 'Do not upload or publish this private output.' -ForegroundColor Yellow

[pscustomobject]@{
    Status               = 'PASS'
    OutputRoot           = [string]$installer.OutputRoot
    SetupPath            = [string]$installer.SetupPath
    LauncherRoot         = $LauncherRoot
    LauncherFileCount    = [int]$launcherIdentity.FileCount
    IncludesHdLite       = [bool]$installer.IncludesHdLite
    HdLiteFileCount      = [int]$installer.HdLiteFileCount
    HdLiteManifestSha256 = $installer.HdLiteManifestSha256
    ContainsRetailFiles  = $false
    PublishPermitted     = $false
}
