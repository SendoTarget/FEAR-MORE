[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$RepositoryRoot,
    [string]$SdkSourceRoot,
    [string]$CMakePath,
    [string]$LauncherRoot,
    [string]$HdLiteRoot,
    [string]$OutputRoot,
    [string]$IsccPath,
    [string]$EchoPatchToolset = 'v143',
    [switch]$RefreshSource,
    [switch]$WithoutHdLite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($SdkSourceRoot)) {
    $SdkSourceRoot = Join-Path $RepositoryRoot 'vendor-local\fear-sdk-108\Source'
}
$SdkSourceRoot = [IO.Path]::GetFullPath($SdkSourceRoot).TrimEnd('\')

$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $git) { throw 'Git is required to build the reproducible FearMore Project Installer.' }
$trackedStatus = @(& $git.Source -C $RepositoryRoot status --porcelain --untracked-files=no 2>$null)
if ($LASTEXITCODE -ne 0) { throw 'The FearMore Git working tree could not be inspected.' }
if ($trackedStatus.Count -gt 0) {
    throw 'Commit or restore tracked changes before building. Ignored SDK, dependency, build, and installer outputs are allowed.'
}

if (-not (Test-Path -LiteralPath (Join-Path $SdkSourceRoot 'Game') -PathType Container)) {
    throw ("The official F.E.A.R. Public Tools 1.08 SDK Source folder is missing.`n" +
        "Expected: $SdkSourceRoot`n" +
        'Install/extract the SDK locally there, or pass -SdkSourceRoot C:\path\to\Source. The SDK is not distributed by this repository.')
}

Write-Host 'Preparing validated third-party dependencies...'
$dependencyResult = & (Join-Path $PSScriptRoot 'Get-FearMorePublicDependencies.ps1') `
    -RepositoryRoot $RepositoryRoot -Confirm:$false
if ($dependencyResult.Status -cne 'PASS') { throw 'Dependency preparation did not pass.' }

Write-Host 'Reconstructing and building FearMore game modules...'
$moduleParameters = @{
    RepositoryRoot = $RepositoryRoot
    SdkSourceRoot  = $SdkSourceRoot
    RefreshSource  = $RefreshSource
}
if (-not [string]::IsNullOrWhiteSpace($CMakePath)) { $moduleParameters.CMakePath = $CMakePath }
$moduleResult = & (Join-Path $PSScriptRoot 'Build-FearMoreModules.ps1') @moduleParameters
if ($moduleResult.Status -cne 'PASS') { throw 'FearMore module build did not pass.' }

Write-Host 'Building the pinned engine-only EchoPatch derivative...'
$minHookArchive = Join-Path $RepositoryRoot 'vendor-local\echopatch-deps\minhook-c3fcafdc10146beb5919319d0683e44e3c30d537.zip'
& (Join-Path $RepositoryRoot 'tools\echopatch\Build-EngineOnlyEchoPatch.ps1') `
    -MinHookArchive $minHookArchive `
    -PlatformToolset $EchoPatchToolset
if ($LASTEXITCODE -ne 0) { throw 'Engine-only EchoPatch build failed.' }

$installerParameters = @{
    RepositoryRoot        = $RepositoryRoot
    PrivateHouseholdBuild = $true
}
if (-not [string]::IsNullOrWhiteSpace($LauncherRoot)) { $installerParameters.LauncherRoot = $LauncherRoot }
if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) { $installerParameters.OutputRoot = $OutputRoot }
if (-not [string]::IsNullOrWhiteSpace($IsccPath)) { $installerParameters.IsccPath = $IsccPath }
if (-not [string]::IsNullOrWhiteSpace($HdLiteRoot)) {
    $installerParameters.HdLiteRoot = $HdLiteRoot
}
else {
    $installerParameters.WithoutHdLite = $true
}
if ($WithoutHdLite) { $installerParameters.WithoutHdLite = $true }

Write-Host 'Assembling and compiling the FearMore Project Installer...'
$installerResult = & (Join-Path $RepositoryRoot 'tools\installer\Build-FearMoreProjectInstaller.ps1') @installerParameters
if ($installerResult.Status -cne 'PASS') { throw 'FearMore Project Installer build did not pass.' }

[pscustomobject]@{
    Status          = 'PASS'
    OutputRoot      = [string]$installerResult.OutputRoot
    SetupPath       = [string]$installerResult.SetupPath
    IncludesHdLite  = [bool]$installerResult.IncludesHdLite
    SdkSourceRoot   = $SdkSourceRoot
    ModuleRoot      = [string]$moduleResult.ReleaseRoot
    DependencyCount = [int]$dependencyResult.DependencyCount
}
