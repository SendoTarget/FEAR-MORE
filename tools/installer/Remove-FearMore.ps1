[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$FearMoreRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FearMoreInstaller.psm1') -Force -ErrorAction Stop
$result = Remove-FearMoreLauncherPayload -FearMoreRoot $FearMoreRoot -Confirm:$false
Write-Host 'FearMore launcher files were removed.'
Write-Host 'Saved games, settings, downloaded dependencies, and the private HD Lite pack were preserved.'
$result
