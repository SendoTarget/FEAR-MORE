[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$FearMoreRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$launcherRoot = Join-Path ([IO.Path]::GetFullPath($FearMoreRoot).TrimEnd('\')) 'Launcher'
& (Join-Path $launcherRoot 'tools\runtime\Invoke-FearLaaBootstrap.ps1') -RepositoryRoot $launcherRoot
Write-Host ''
Write-Host 'FearMore HD Lite setup is ready. In the game, choose Options > Game > HD Textures > Stable Lite.' -ForegroundColor Green
Read-Host 'Press Enter to close'
