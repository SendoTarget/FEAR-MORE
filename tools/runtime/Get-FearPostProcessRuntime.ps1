[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    [string]$RepositoryRoot,
    [string]$SetupPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Read-only package identity checks use provider commands such as Get-FileHash.
# Keep those deterministic under -WhatIf, then restore the caller preference at
# the single download mutation boundary.
$acquisitionWhatIfPreference = $WhatIfPreference
$WhatIfPreference = $false

Import-Module (Join-Path $PSScriptRoot 'FearPostProcessPackage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeLayout.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1') -Force -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$runtimeLayout = Resolve-FearRuntimeLayout -SourceRoot $RepositoryRoot
$RepositoryRoot = $runtimeLayout.SourceRoot
$metadata = Get-FearPostProcessPackageMetadata
$assetRoot = Join-Path $PSScriptRoot 'postprocess'

$dependencyRoot = if ($runtimeLayout.LayoutKind -eq 'Packaged') {
    Join-Path (Split-Path $runtimeLayout.RuntimeRoot -Parent) 'dependencies\postprocess'
}
else {
    Join-Path $RepositoryRoot 'vendor-local\postprocess-deps'
}
$dependencyRoot = [IO.Path]::GetFullPath($dependencyRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($SetupPath)) {
    $SetupPath = Join-Path $dependencyRoot $metadata.SetupName
}
$SetupPath = [IO.Path]::GetFullPath($SetupPath)
if (-not (Test-FearPathIsBelow -Path $SetupPath -Parent $dependencyRoot)) {
    throw "ReShade setup target must stay below '$dependencyRoot': $SetupPath"
}

if (Test-Path -LiteralPath $SetupPath) {
    Get-FearPostProcessPackageIdentity -SetupPath $SetupPath -AssetRoot $assetRoot
    return
}

$WhatIfPreference = $acquisitionWhatIfPreference
if (-not $PSCmdlet.ShouldProcess($SetupPath, "Download and validate official ReShade $($metadata.Version) setup")) {
    return
}

$safetyRoot = if ($runtimeLayout.LayoutKind -eq 'Packaged') {
    $runtimeLayout.RegistrationSafetyRoot
}
else {
    $RepositoryRoot
}
Assert-FearNoReparsePathComponents -Root $safetyRoot -Path $dependencyRoot -Description 'ReShade dependency directory'
if (-not (Test-Path -LiteralPath $dependencyRoot)) {
    [IO.Directory]::CreateDirectory($dependencyRoot) | Out-Null
}
Assert-FearNoReparsePathComponents -Root $safetyRoot -Path $dependencyRoot -RequirePath -Description 'ReShade dependency directory'

$temporaryPath = Join-Path $dependencyRoot ('.' + [IO.Path]::GetFileNameWithoutExtension($metadata.SetupName) + '.' + [guid]::NewGuid().ToString('N') + '.download.exe')
try {
    Invoke-WebRequest -UseBasicParsing -Uri $metadata.DownloadUri -OutFile $temporaryPath
    $identity = Get-FearPostProcessPackageIdentity -SetupPath $temporaryPath -AssetRoot $assetRoot
    if (Test-Path -LiteralPath $SetupPath) {
        throw "ReShade setup appeared concurrently and was not replaced: $SetupPath"
    }
    [IO.File]::Move($temporaryPath, $SetupPath)
    Get-FearPostProcessPackageIdentity -SetupPath $SetupPath -AssetRoot $assetRoot
}
finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        [IO.File]::Delete($temporaryPath)
    }
}
