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
$canonicalScript = Join-Path $PSScriptRoot 'Build-FearMoreProjectInstaller.ps1'
Write-Warning 'Build-FearMoreHouseholdInstaller.ps1 is a compatibility alias. Use Build-FearMoreProjectInstaller.ps1.'
$forwardParameters = @{} + $PSBoundParameters
$forwardParameters.PrivateHouseholdBuild = $true
& $canonicalScript @forwardParameters
