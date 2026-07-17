[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Mandatory = $true)][string]$PayloadRoot,
    [Parameter(Mandatory = $true)][string]$FearMoreRoot,
    [string]$HdLiteRoot,
    [switch]$BootstrapHd,
    [switch]$SkipPrerequisites
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$FearMoreRoot = [IO.Path]::GetFullPath($FearMoreRoot).TrimEnd('\')
Import-Module (Join-Path $PSScriptRoot 'FearMoreInstaller.psm1') -Force -ErrorAction Stop

$install = Install-FearMoreLauncherPayload `
    -PayloadRoot $PayloadRoot `
    -FearMoreRoot $FearMoreRoot `
    -Confirm:$false
$launcherRoot = [string]$install.Target

if (-not $SkipPrerequisites) {
    $null = & (Join-Path $PSScriptRoot 'Ensure-FearMoreVCRuntime.ps1') `
        -DownloadDirectory (Join-Path $FearMoreRoot 'dependencies\vc-runtime')
}

if (-not [string]::IsNullOrWhiteSpace($HdLiteRoot)) {
    $HdLiteRoot = [IO.Path]::GetFullPath($HdLiteRoot).TrimEnd('\')
    $textureModule = Join-Path $launcherRoot 'tools\runtime\FearTexturePackage.psm1'
    Import-Module $textureModule -Force -ErrorAction Stop
    $null = Get-FearHdTexturePackageIdentity -PackageRoot $HdLiteRoot -RequireKnownMode Lite
    $null = & (Join-Path $launcherRoot 'tools\runtime\Register-FearHdTexturePack.ps1') `
        -Mode Lite `
        -PackageRoot $HdLiteRoot `
        -LocalAppDataRoot (Split-Path $FearMoreRoot -Parent) `
        -Confirm:$false
}

$prepared = @(& (Join-Path $launcherRoot 'tools\runtime\Start-FearMore.ps1') `
        -Preset Modern `
        -PrepareOnly)
if ($prepared.Count -ne 1) {
    throw 'FearMore Modern preparation did not return exactly one result.'
}

$laa = $null
if ($BootstrapHd -and -not [string]::IsNullOrWhiteSpace($HdLiteRoot)) {
    $laa = & (Join-Path $launcherRoot 'tools\runtime\Invoke-FearLaaBootstrap.ps1') `
        -RepositoryRoot $launcherRoot
}

[pscustomobject]@{
    Status             = 'PASS'
    LauncherRoot       = $launcherRoot
    HdLiteRegistered   = -not [string]::IsNullOrWhiteSpace($HdLiteRoot)
    HdBootstrapReady   = if ($laa) { $laa.Status -eq 'PASS' } else { $false }
    RetailFilesChanged = $false
    PreparedStage      = [string]$prepared[0].StageRoot
}
