[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    $PackageRoot = Join-Path $PSScriptRoot '..\..'
}
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
$modulePath = Join-Path $PSScriptRoot 'FearLauncherPackage.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "FearMore package-integrity module is missing: $modulePath"
}
Import-Module $modulePath -Force -ErrorAction Stop

Test-FearMoreLauncherPackageIntegrity -PackageRoot $PackageRoot
