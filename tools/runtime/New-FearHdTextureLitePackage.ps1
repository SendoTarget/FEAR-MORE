[CmdletBinding(PositionalBinding = $false, SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory = $true)][string]$FullPackageRoot,
    [Parameter(Mandatory = $true)][string]$LitePatchRoot,
    [Parameter(Mandatory = $true)][string]$DestinationRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearTexturePackage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearDdsIdentity.psm1') -Force -ErrorAction Stop

$expectedPatchFileCount = 1297
$expectedPatchTotalBytes = 4066601424
$expectedPatchManifestSha256 = '0CDA60503FCC728D08B0870236861E0DA9184576331AAA272367BD9B015ED06D'

function Test-FearLiteReparsePoint {
    param([Parameter(Mandatory = $true)]$Item)
    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Resolve-FearLitePatchContentRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    foreach ($candidate in @(
            (Join-Path $canonicalRoot 'HD Textures Lite Pack\HDTextures'),
            (Join-Path $canonicalRoot 'HDTextures'),
            $canonicalRoot
        )) {
        if ((Test-Path -LiteralPath $candidate -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'Materials') -PathType Container)) {
            return [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        }
    }
    throw "The extracted official Lite patch content root was not found beneath: $canonicalRoot"
}

function Get-FearLitePatchIdentity {
    param([Parameter(Mandatory = $true)][string]$ContentRoot)

    $rootItem = Get-Item -LiteralPath $ContentRoot -Force -ErrorAction Stop
    if (Test-FearLiteReparsePoint -Item $rootItem) {
        throw "Lite patch content root is a reparse point: $ContentRoot"
    }
    $files = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $ContentRoot -Recurse -Force -ErrorAction Stop)) {
        if (Test-FearLiteReparsePoint -Item $item) {
            throw "Lite patch contains a reparse point: $($item.FullName)"
        }
        if ($item.PSIsContainer) {
            continue
        }
        if ($item.Extension -ine '.dds') {
            throw "Lite patch content must contain only DDS files: $($item.FullName)"
        }
        $relativePath = $item.FullName.Substring($ContentRoot.Length + 1).Replace('\', '/').ToLowerInvariant()
        $files.Add((Get-FearDdsTextureIdentity -File $item -RelativePath $relativePath))
    }
    $totalBytes = [long](($files | Measure-Object Size -Sum).Sum)
    $manifestSha256 = Get-FearDdsManifestSha256 -Files $files
    if ($files.Count -ne $expectedPatchFileCount -or
        $totalBytes -ne $expectedPatchTotalBytes -or
        $manifestSha256 -cne $expectedPatchManifestSha256) {
        throw "Lite patch identity mismatch. Expected $expectedPatchFileCount files, $expectedPatchTotalBytes bytes, and $expectedPatchManifestSha256; found $($files.Count) files, $totalBytes bytes, and $manifestSha256."
    }
    return [pscustomobject]@{
        ContentRoot    = $ContentRoot
        FileCount      = $files.Count
        TotalBytes     = $totalBytes
        ManifestSha256 = $manifestSha256
    }
}

$fullIdentity = Get-FearHdTexturePackageIdentity -PackageRoot $FullPackageRoot -RequireKnownMode Full
$patchContentRoot = Resolve-FearLitePatchContentRoot -Root $LitePatchRoot
$patchIdentity = Get-FearLitePatchIdentity -ContentRoot $patchContentRoot
$destination = [IO.Path]::GetFullPath($DestinationRoot).TrimEnd('\')
$destinationParent = Split-Path $destination -Parent
if ([string]::IsNullOrWhiteSpace($destinationParent) -or
    -not (Test-Path -LiteralPath $destinationParent -PathType Container)) {
    throw "Lite package destination parent must already exist: $destinationParent"
}
$destinationParentItem = Get-Item -LiteralPath $destinationParent -Force -ErrorAction Stop
if (Test-FearLiteReparsePoint -Item $destinationParentItem) {
    throw "Lite package destination parent is a reparse point: $destinationParent"
}
if (Test-Path -LiteralPath $destination) {
    throw "Lite package destination already exists; choose a new empty path: $destination"
}

if (-not $PSCmdlet.ShouldProcess($destination, 'Create a local derived Stable Lite texture package')) {
    return [pscustomobject]@{
        Created                    = $false
        DestinationRoot            = $destination
        FullManifestSha256         = $fullIdentity.ManifestSha256
        LitePatchManifestSha256    = $patchIdentity.ManifestSha256
    }
}

$destinationContentRoot = Join-Path $destination 'HDTextures\FEAR'
$created = $false
try {
    [IO.Directory]::CreateDirectory($destinationContentRoot) | Out-Null
    $created = $true
    Get-ChildItem -LiteralPath $fullIdentity.ContentRoot -Force | Copy-Item -Destination $destinationContentRoot -Recurse -Force
    Get-ChildItem -LiteralPath $patchContentRoot -Force | Copy-Item -Destination $destinationContentRoot -Recurse -Force
    $liteIdentity = Get-FearHdTexturePackageIdentity -PackageRoot $destination -RequireKnownMode Lite
}
catch {
    if ($created -and (Test-Path -LiteralPath $destination -PathType Container)) {
        $currentDestination = [IO.Path]::GetFullPath($destination).TrimEnd('\')
        $parentPrefix = [IO.Path]::GetFullPath($destinationParent).TrimEnd('\') + '\'
        if (-not $currentDestination.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean a failed Lite package outside its validated parent: $currentDestination"
        }
        Remove-Item -LiteralPath $currentDestination -Recurse -Force
    }
    throw
}

return [pscustomobject]@{
    Created                    = $true
    DestinationRoot            = $liteIdentity.PackageRoot
    ContentRoot                = $liteIdentity.ContentRoot
    FileCount                  = $liteIdentity.FileCount
    TotalBytes                 = $liteIdentity.TotalBytes
    ManifestSha256             = $liteIdentity.ManifestSha256
    FullManifestSha256         = $fullIdentity.ManifestSha256
    LitePatchManifestSha256    = $patchIdentity.ManifestSha256
    IncludesExpansionContent   = $false
    Redistributable            = $false
}
