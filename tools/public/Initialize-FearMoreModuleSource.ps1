[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    [string]$RepositoryRoot,
    [string]$SdkSourceRoot,
    [string]$OutputRoot,
    [switch]$Refresh
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\runtime\FearRuntimeStageSafety.psm1') -Force -ErrorAction Stop
$sourceWhatIfPreference = $WhatIfPreference
$WhatIfPreference = $false

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($SdkSourceRoot)) {
    $SdkSourceRoot = Join-Path $RepositoryRoot 'vendor-local\fear-sdk-108\Source'
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepositoryRoot 'FEAR\Dev\Source'
}
$SdkSourceRoot = [IO.Path]::GetFullPath($SdkSourceRoot).TrimEnd('\')
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$outputBoundary = Join-Path $RepositoryRoot 'FEAR\Dev'
if (-not (Test-FearPathIsBelow -Path $OutputRoot -Parent $outputBoundary)) {
    throw "The generated module source must stay below '$outputBoundary': $OutputRoot"
}

$sdkGameRoot = Join-Path $SdkSourceRoot 'Game'
$requiredSdkInputs = @(
    'Game\ClientShellDLL\GameClientShell.cpp',
    'Game\ObjectDLL\GameServerShell.cpp',
    'Game\ClientFxDLL\Game_ClientFX.vcproj',
    'engine\sdk\inc\engine.h',
    'engine\sdk\lib\win\Final\Shared_Assert.lib',
    'engine\sdk\lib\win\Final\Shared_CRC.lib',
    'libs\platform\Shared_Platform.vcproj',
    'libs\stdlith\Shared_StdLith.vcproj'
)
$missingSdkInputs = @($requiredSdkInputs | Where-Object {
        -not (Test-Path -LiteralPath (Join-Path $SdkSourceRoot $_) -PathType Leaf)
    })
if ($missingSdkInputs.Count -gt 0) {
    $missingText = ($missingSdkInputs | ForEach-Object { "  - $_" }) -join "`n"
    throw ("F.E.A.R. Public Tools 1.08 Source is missing required inputs below '$SdkSourceRoot':`n" +
        $missingText + "`nInstall or extract the official Public Tools SDK, then pass its Source folder with -SdkSourceRoot.")
}

$scaffoldRoot = Join-Path $RepositoryRoot 'source-scaffold'
$overlayRoot = Join-Path $RepositoryRoot 'source-overlay\Game'
$patchPath = Join-Path $RepositoryRoot 'source-patches\fearmore-game-modules.patch'
foreach ($requiredProjectInput in @($scaffoldRoot, $overlayRoot, $patchPath)) {
    if (-not (Test-Path -LiteralPath $requiredProjectInput)) {
        throw "FearMore public source input is missing: $requiredProjectInput"
    }
}

function Get-TreeIdentity {
    param([Parameter(Mandatory = $true)][string]$Root)

    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $records = @(Get-ChildItem -LiteralPath $canonicalRoot -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring($canonicalRoot.Length + 1).Replace('\', '/')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            [pscustomobject]@{ RelativePath = $relativePath; Size = [long]$_.Length; Sha256 = $hash }
        } | Sort-Object RelativePath)
    $canonical = ($records | ForEach-Object { "$($_.RelativePath)|$($_.Size)|$($_.Sha256)" }) -join "`n"
    $bytes = [Text.Encoding]::UTF8.GetBytes($canonical)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $manifestHash = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
    return [pscustomobject]@{ FileCount = $records.Count; ManifestSha256 = $manifestHash }
}

function Convert-CrlfToLfBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    $inputBytes = [IO.File]::ReadAllBytes($Path)
    $outputBytes = [Collections.Generic.List[byte]]::new($inputBytes.Length)
    for ($index = 0; $index -lt $inputBytes.Length; $index++) {
        if ($inputBytes[$index] -eq 13 -and $index + 1 -lt $inputBytes.Length -and
            $inputBytes[$index + 1] -eq 10) {
            $outputBytes.Add(10)
            $index++
        }
        else {
            $outputBytes.Add($inputBytes[$index])
        }
    }
    [IO.File]::WriteAllBytes($Path, $outputBytes.ToArray())
}

$patchSha256 = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash
$scaffoldIdentity = Get-TreeIdentity -Root $scaffoldRoot
$overlayIdentity = Get-TreeIdentity -Root $overlayRoot
$WhatIfPreference = $sourceWhatIfPreference
$manifestName = '.fearmore-public-source.json'
$existingManifestPath = Join-Path $OutputRoot $manifestName
if (Test-Path -LiteralPath $OutputRoot) {
    Assert-FearNoReparsePathComponents -Root $outputBoundary -Path $OutputRoot -RequirePath -Description 'generated FearMore source'
    $existingManifest = $null
    if (Test-Path -LiteralPath $existingManifestPath -PathType Leaf) {
        $existingManifest = Get-Content -LiteralPath $existingManifestPath -Raw | ConvertFrom-Json
    }
    $isCurrent = $existingManifest -and
        $existingManifest.Schema -eq 1 -and
        $existingManifest.DistributionClass -ceq 'PublicSdkDerivedSource' -and
        $existingManifest.PatchSha256 -ceq $patchSha256 -and
        $existingManifest.ScaffoldManifestSha256 -ceq $scaffoldIdentity.ManifestSha256 -and
        $existingManifest.OverlayManifestSha256 -ceq $overlayIdentity.ManifestSha256
    if ($isCurrent -and -not $Refresh) {
        return [pscustomobject]@{
            Status = 'PASS'; SourceRoot = $OutputRoot; SdkSourceRoot = $SdkSourceRoot
            Refreshed = $false; PatchSha256 = $patchSha256
        }
    }
    if (-not $Refresh) {
        throw "Generated source already exists but does not match this public revision: $OutputRoot`nRerun with -Refresh to replace only the manifest-owned generated tree."
    }
    if (-not $existingManifest -or $existingManifest.DistributionClass -cne 'PublicSdkDerivedSource') {
        throw "Refusing to replace a source tree not proven to be generated by FearMore: $OutputRoot"
    }
    if ($PSCmdlet.ShouldProcess($OutputRoot, 'Replace the manifest-owned generated module source')) {
        [IO.Directory]::Delete($OutputRoot, $true)
    }
    else {
        return [pscustomobject]@{ Status = 'WHATIF'; SourceRoot = $OutputRoot; Refreshed = $false }
    }
}

if (-not $PSCmdlet.ShouldProcess($OutputRoot, 'Assemble F.E.A.R. module source from the owner-supplied Public Tools SDK')) {
    return [pscustomobject]@{ Status = 'WHATIF'; SourceRoot = $OutputRoot; Refreshed = $false }
}

[IO.Directory]::CreateDirectory($outputBoundary) | Out-Null
Assert-FearNoReparsePathComponents -Root $outputBoundary -Path $outputBoundary -RequirePath -Description 'generated FearMore source boundary'
$transactionRoot = Join-Path $outputBoundary ('.Source.' + [guid]::NewGuid().ToString('N') + '.assembling')
try {
    [IO.Directory]::CreateDirectory($transactionRoot) | Out-Null
    $transactionGameRoot = Join-Path $transactionRoot 'FEAR'
    Copy-Item -LiteralPath $sdkGameRoot -Destination $transactionGameRoot -Recurse -Force

    $patchTargets = @(Get-Content -LiteralPath $patchPath | ForEach-Object {
            if ($_ -match '^--- base/(.+)$') { $Matches[1].Replace('/', '\') }
        } | Where-Object { $_ } | Sort-Object -Unique)
    if ($patchTargets.Count -ne 64) {
        throw "FearMore source delta should modify 64 SDK files, found $($patchTargets.Count)."
    }
    foreach ($patchTarget in $patchTargets) {
        $targetPath = [IO.Path]::GetFullPath((Join-Path $transactionGameRoot $patchTarget))
        if (-not (Test-FearPathIsBelow -Path $targetPath -Parent $transactionGameRoot) -or
            -not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            throw "FearMore source delta names an unsafe or missing SDK file: $patchTarget"
        }
        Convert-CrlfToLfBytes -Path $targetPath
    }

    $relativeGameRoot = $transactionGameRoot.Substring($RepositoryRoot.Length + 1).Replace('\', '/')
    $checkOutput = @(& git -C $RepositoryRoot apply --check --unidiff-zero --whitespace=nowarn -p1 "--directory=$relativeGameRoot" $patchPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The FearMore source delta does not match this Public Tools SDK extraction:`n$($checkOutput -join [Environment]::NewLine)"
    }
    $applyOutput = @(& git -C $RepositoryRoot apply --unidiff-zero --whitespace=nowarn -p1 "--directory=$relativeGameRoot" $patchPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "The FearMore source delta failed to apply:`n$($applyOutput -join [Environment]::NewLine)"
    }

    Copy-Item -Path (Join-Path $overlayRoot '*') -Destination $transactionGameRoot -Recurse -Force
    Copy-Item -Path (Join-Path $scaffoldRoot '*') -Destination $transactionRoot -Recurse -Force

    $manifest = [ordered]@{
        Schema = 1
        DistributionClass = 'PublicSdkDerivedSource'
        PatchSha256 = $patchSha256
        ScaffoldFileCount = [int]$scaffoldIdentity.FileCount
        ScaffoldManifestSha256 = [string]$scaffoldIdentity.ManifestSha256
        OverlayFileCount = [int]$overlayIdentity.FileCount
        OverlayManifestSha256 = [string]$overlayIdentity.ManifestSha256
    }
    [IO.File]::WriteAllText(
        (Join-Path $transactionRoot $manifestName),
        ($manifest | ConvertTo-Json -Depth 4) + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $OutputRoot) {
        throw "Generated source output appeared concurrently and was not replaced: $OutputRoot"
    }
    [IO.Directory]::Move($transactionRoot, $OutputRoot)
}
finally {
    if (Test-Path -LiteralPath $transactionRoot -PathType Container) {
        [IO.Directory]::Delete($transactionRoot, $true)
    }
}

[pscustomobject]@{
    Status = 'PASS'
    SourceRoot = $OutputRoot
    SdkSourceRoot = $SdkSourceRoot
    Refreshed = [bool]$Refresh
    PatchSha256 = $patchSha256
}
