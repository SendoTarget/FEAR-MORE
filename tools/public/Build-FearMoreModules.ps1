[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$RepositoryRoot,
    [string]$SdkSourceRoot,
    [string]$CMakePath,
    [switch]$RefreshSource,
    [switch]$BuildDebug
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

$initializer = Join-Path $PSScriptRoot 'Initialize-FearMoreModuleSource.ps1'
$sourceResults = @(& $initializer -RepositoryRoot $RepositoryRoot -SdkSourceRoot $SdkSourceRoot -Refresh:$RefreshSource -Confirm:$false)
$sourceMatches = @($sourceResults | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Status'] -and $_.Status -ceq 'PASS' })
if ($sourceMatches.Count -ne 1) {
    throw 'FearMore public source assembly did not return a passing result.'
}
$sourceResult = $sourceMatches[0]

if ([string]::IsNullOrWhiteSpace($CMakePath)) {
    $cmakeCommand = Get-Command cmake -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmakeCommand) {
        $CMakePath = $cmakeCommand.Source
    }
    else {
        $vsCMake = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
        if (Test-Path -LiteralPath $vsCMake -PathType Leaf) {
            $CMakePath = $vsCMake
        }
    }
}
if ([string]::IsNullOrWhiteSpace($CMakePath) -or -not (Test-Path -LiteralPath $CMakePath -PathType Leaf)) {
    throw 'CMake was not found. Install Visual Studio 2022 Build Tools with the C++ workload, MSVC v141 toolset, CMake tools, and a Windows SDK.'
}
$CMakePath = [IO.Path]::GetFullPath($CMakePath)
$sourceRoot = [string]$sourceResult.SourceRoot

Push-Location $sourceRoot
try {
    & $CMakePath --preset fear-win32 "-DFEAR_LEGACY_SOURCE_ROOT=$SdkSourceRoot" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "FearMore CMake configuration failed with exit $LASTEXITCODE." }
    if ($BuildDebug) {
        & $CMakePath --build --preset fear-win32-debug | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "FearMore Debug build failed with exit $LASTEXITCODE." }
    }
    & $CMakePath --build --preset fear-win32-release | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "FearMore Release build failed with exit $LASTEXITCODE." }
}
finally {
    Pop-Location
}

$releaseRoot = Join-Path $RepositoryRoot 'build\fear-win32\bin\Release'
$outputs = @('ClientFx.fxd', 'GameClient.dll', 'GameServer.dll')
$missingOutputs = @($outputs | Where-Object { -not (Test-Path -LiteralPath (Join-Path $releaseRoot $_) -PathType Leaf) })
if ($missingOutputs.Count -gt 0) {
    throw "The Release build did not produce: $($missingOutputs -join ', ')"
}

[pscustomobject]@{
    Status = 'PASS'
    SourceRoot = $sourceRoot
    SdkSourceRoot = $SdkSourceRoot
    ReleaseRoot = $releaseRoot
    Outputs = $outputs
}
