[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$OutputRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Join-Path $PSScriptRoot '..\..' }
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')

$required = @(
    'tools\bootstrap\Bootstrap-FearMoreProject.ps1',
    'tools\bootstrap\FearMoreBootstrapPrerequisites.psm1',
    'tools\bootstrap\BOOTSTRAP-README.txt',
    'tools\bootstrap\FearMoreBootstrap.iss',
    'tools\bootstrap\Build-FearMoreBootstrapRelease.ps1'
)
foreach ($relativePath in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $relativePath) -PathType Leaf)) {
        throw "Bootstrap input is missing: $relativePath"
    }
}

$issText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'FearMoreBootstrap.iss') -Raw
$filesSection = [regex]::Match($issText, '(?ms)^\[Files\]\s*(.+?)(?=^\[)').Groups[1].Value
$sourceLines = @($filesSection -split "`r?`n" | Where-Object { $_ -match '^Source:' })
if ($sourceLines.Count -ne 3) { throw "Public bootstrap must package exactly three text/script inputs; found $($sourceLines.Count)." }
foreach ($expectedName in @('Bootstrap-FearMoreProject.ps1', 'FearMoreBootstrapPrerequisites.psm1', 'BOOTSTRAP-README.txt')) {
    if ($filesSection -notmatch [regex]::Escape($expectedName)) { throw "Bootstrap payload is missing $expectedName." }
}
if ($filesSection -match '(?i)\.(exe|dll|fxd|lib|zip|7z|rar|dds|arch00)\b|vendor-local|source-overlay|source-patches|external\\EchoPatch|HDTextures') {
    throw 'Public bootstrap Inno payload references a prohibited binary, generated input, source delta, or game asset.'
}

$bootstrapText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Bootstrap-FearMoreProject.ps1') -Raw
foreach ($needle in @(
        "[string]`$ReleaseTag = 'v0.1.0'",
        "[string]`$RepositoryUrl = 'https://github.com/SendoTarget/FEAR-MORE.git'",
        '--recurse-submodules',
        'fear_publictools_108.exe',
        'https://www.ausgamers.com/files/download/25133/fear-sdk-v108',
        'Test-FearPublicToolsSourceFolder',
        '-WithoutHdLite'
    )) {
    if ($bootstrapText.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) { throw "Bootstrap workflow lost required public/local-build behavior: $needle" }
}
$prerequisiteText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'FearMoreBootstrapPrerequisites.psm1') -Raw
foreach ($needle in @(
        'Git.Git',
        'JRSoftware.InnoSetup.7',
        'Microsoft.VisualStudio.2022.BuildTools',
        'Microsoft.VisualStudio.Workload.VCTools',
        'Microsoft.VisualStudio.Component.VC.v141.x86.x64',
        '--accept-package-agreements',
        '--accept-source-agreements'
    )) {
    if ($prerequisiteText.IndexOf($needle, [StringComparison]::Ordinal) -lt 0) { throw "Prerequisite owner lost exact dependency identity: $needle" }
}

$outputFileCount = 0
if (-not [string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
    $setupPath = Join-Path $OutputRoot 'FearMore-Project-Installer-Bootstrap.exe'
    $manifestPath = Join-Path $OutputRoot 'FearMore-Bootstrap-Manifest.json'
    $checksumPath = Join-Path $OutputRoot 'SHA256SUMS.txt'
    foreach ($path in @($setupPath, $manifestPath, $checksumPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Bootstrap release output is missing: $path" }
    }
    $bytes = [IO.File]::ReadAllBytes($setupPath)
    if ($bytes.Length -lt 2 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) { throw 'Bootstrap setup is not a Windows PE file.' }
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Schema -ne 1 -or $manifest.DistributionClass -cne 'PublicBootstrap' -or -not $manifest.BuildsLocally -or
        $manifest.ContainsRetailFiles -or $manifest.ContainsSdkFiles -or $manifest.ContainsCompiledGameModules -or $manifest.ContainsThirdPartyBinaries) {
        throw 'Bootstrap manifest does not preserve the public local-build boundary.'
    }
    $actualHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash
    if ($manifest.Output.Sha256 -cne $actualHash -or [long]$manifest.Output.Size -ne [long]$bytes.Length) {
        throw 'Bootstrap manifest output identity does not match the EXE.'
    }
    $checksumText = Get-Content -LiteralPath $checksumPath -Raw
    if ($checksumText -notmatch [regex]::Escape("$actualHash *FearMore-Project-Installer-Bootstrap.exe")) {
        throw 'Bootstrap SHA256SUMS does not attest the EXE.'
    }
    $outputFileCount = @(Get-ChildItem -LiteralPath $OutputRoot -File).Count
    if ($outputFileCount -ne 3) { throw "Bootstrap release should contain exactly three files; found $outputFileCount." }
}

[pscustomobject]@{
    Status = 'PASS'
    PayloadFiles = $sourceLines.Count
    ExactPrerequisites = 3
    PublicToolsGuidance = $true
    OutputFiles = $outputFileCount
    ProhibitedPayloadFiles = 0
}
