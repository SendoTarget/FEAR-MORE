Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearDdsIdentity.psm1') -Force -Scope Local -ErrorAction Stop

$script:KnownPackages = @{
    Lite = [pscustomobject]@{
        Mode           = 'Lite'
        Name           = 'Rivarez FEAR HD Textures v2.0.2 plus official Lite Pack (base game)'
        FileCount      = 1882
        TotalBytes     = 4440752072
        ManifestSha256 = '758A5112EA00FD802B5373066EE3BD9AF29A501D271AF6A5CA7F14F6FEFB63ED'
    }
    Full = [pscustomobject]@{
        Mode           = 'Full'
        Name           = 'Rivarez FEAR HD Textures v2.0.2 Full (base game)'
        FileCount      = 1882
        TotalBytes     = 7587319112
        ManifestSha256 = 'C92E8C14ABBD5D8C306D072C2ABAD1EA22D0426182CE37E302E948EB9346D801'
    }
}
$script:ManifestFormat = 'Ordinal-sorted lowercase relative/path|decimal-size|lowercase-file-sha256; UTF-8 without BOM; LF between records; no trailing LF'

function Test-FearTextureReparsePoint {
    param([Parameter(Mandatory = $true)]$Item)

    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-FearTexturePackageTreeNoReparsePoints {
    param([Parameter(Mandatory = $true)][IO.DirectoryInfo]$Root)

    if (Test-FearTextureReparsePoint -Item $Root) {
        throw "HD texture package root is a reparse point: $($Root.FullName)"
    }

    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push($Root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)) {
            if (Test-FearTextureReparsePoint -Item $item) {
                throw "HD texture package contains a reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $pending.Push([IO.DirectoryInfo]$item)
            }
        }
    }
}

function Get-FearTextureContentFiles {
    param([Parameter(Mandatory = $true)][IO.DirectoryInfo]$ContentRoot)

    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    $pending = [Collections.Generic.Stack[IO.DirectoryInfo]]::new()
    $pending.Push($ContentRoot)
    while ($pending.Count -gt 0) {
        $directory = $pending.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction Stop)) {
            if (Test-FearTextureReparsePoint -Item $item) {
                throw "F.E.A.R. HD texture content contains a reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $pending.Push([IO.DirectoryInfo]$item)
                continue
            }
            if ($item.Extension -ine '.dds') {
                throw "F.E.A.R. HD texture content must contain only DDS files; found '$($item.FullName)'."
            }
            $files.Add([IO.FileInfo]$item)
        }
    }
    if ($files.Count -eq 0) {
        throw "F.E.A.R. HD texture content contains no DDS files: $($ContentRoot.FullName)"
    }
    return $files
}

function Get-FearCanonicalTextureRelativePath {
    param(
        [Parameter(Mandatory = $true)][string]$ContentRoot,
        [Parameter(Mandatory = $true)][string]$FilePath
    )

    $rootPrefix = [IO.Path]::GetFullPath($ContentRoot).TrimEnd('\') + '\'
    $fullFilePath = [IO.Path]::GetFullPath($FilePath)
    if (-not $fullFilePath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "HD texture file escapes the F.E.A.R. content root: $fullFilePath"
    }
    $relativePath = $fullFilePath.Substring($rootPrefix.Length)
    if ([string]::IsNullOrWhiteSpace($relativePath)) {
        throw "HD texture file has an empty relative path: $fullFilePath"
    }
    if ($relativePath.IndexOf('|') -ge 0 -or
        $relativePath.IndexOf([char]13) -ge 0 -or
        $relativePath.IndexOf([char]10) -ge 0 -or
        $relativePath.IndexOf([char]0) -ge 0) {
        throw "HD texture file path cannot be represented unambiguously in the canonical manifest: $fullFilePath"
    }
    return $relativePath.Replace('\', '/').ToLowerInvariant()
}

function Get-FearHdTexturePackageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$PackageRoot,
        [ValidateSet('Lite', 'Full')][string]$RequireKnownMode,
        [switch]$RequireKnownRivarezV202
    )

    $fullPackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    if ((Split-Path $fullPackageRoot -Leaf) -ieq 'XP') {
        throw "The Extraction Point (XP) texture root cannot be used as the base F.E.A.R. texture package: $fullPackageRoot"
    }
    if (-not (Test-Path -LiteralPath $fullPackageRoot -PathType Container)) {
        throw "HD texture package root is missing: $fullPackageRoot"
    }
    $packageRootItem = Get-Item -LiteralPath $fullPackageRoot -Force -ErrorAction Stop
    if (Test-FearTextureReparsePoint -Item $packageRootItem) {
        throw "HD texture package root is a reparse point: $fullPackageRoot"
    }

    $hdTexturesRoot = Join-Path $fullPackageRoot 'HDTextures'
    $contentRoot = Join-Path $hdTexturesRoot 'FEAR'
    if (-not (Test-Path -LiteralPath $hdTexturesRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $contentRoot -PathType Container)) {
        throw "HD texture package root must contain the base-game directory 'HDTextures\FEAR': $fullPackageRoot"
    }
    $hdTexturesRootItem = Get-Item -LiteralPath $hdTexturesRoot -Force -ErrorAction Stop
    $contentRootItem = Get-Item -LiteralPath $contentRoot -Force -ErrorAction Stop
    foreach ($requiredDirectory in @($hdTexturesRootItem, $contentRootItem)) {
        if (Test-FearTextureReparsePoint -Item $requiredDirectory) {
            throw "HD texture package required directory is a reparse point: $($requiredDirectory.FullName)"
        }
    }

    Assert-FearTexturePackageTreeNoReparsePoints -Root $packageRootItem
    $sourceFiles = Get-FearTextureContentFiles -ContentRoot $contentRootItem
    $textures = [Collections.Generic.List[object]]::new()
    $seenRelativePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($file in $sourceFiles) {
        $relativePath = Get-FearCanonicalTextureRelativePath `
            -ContentRoot $contentRootItem.FullName `
            -FilePath $file.FullName
        if (-not $seenRelativePaths.Add($relativePath)) {
            throw "HD texture content has a duplicate canonical relative path: $relativePath"
        }
        $textures.Add((Get-FearDdsTextureIdentity -File $file -RelativePath $relativePath))
    }

    $orderedTextures = [object[]]@($textures | Sort-Object RelativePath)
    $manifestSha256 = Get-FearDdsManifestSha256 -Files $orderedTextures
    $totalBytes = [long]0
    $minWidth = [uint32]::MaxValue
    $maxWidth = [uint32]0
    $minHeight = [uint32]::MaxValue
    $maxHeight = [uint32]0
    $minMipMapCount = [uint32]::MaxValue
    $maxMipMapCount = [uint32]0
    $fourCcTextureCount = 0
    $rgb32TextureCount = 0
    $formatCounts = [Collections.Generic.Dictionary[string,int]]::new([StringComparer]::Ordinal)
    foreach ($texture in $orderedTextures) {
        $totalBytes += $texture.Size
        $minWidth = [Math]::Min($minWidth, $texture.Width)
        $maxWidth = [Math]::Max($maxWidth, $texture.Width)
        $minHeight = [Math]::Min($minHeight, $texture.Height)
        $maxHeight = [Math]::Max($maxHeight, $texture.Height)
        $minMipMapCount = [Math]::Min($minMipMapCount, $texture.MipMapCount)
        $maxMipMapCount = [Math]::Max($maxMipMapCount, $texture.MipMapCount)
        if ($texture.FormatKind -ceq 'FourCC') {
            $fourCcTextureCount++
        }
        else {
            $rgb32TextureCount++
        }
        if ($formatCounts.ContainsKey($texture.FormatName)) {
            $formatCounts[$texture.FormatName]++
        }
        else {
            $formatCounts[$texture.FormatName] = 1
        }
    }
    $formatSummary = [object[]]@($formatCounts.GetEnumerator() | Sort-Object Key | ForEach-Object {
        [pscustomobject]@{
            Format = $_.Key
            Count  = $_.Value
        }
    })

    $requiredMode = if ($RequireKnownRivarezV202) { 'Full' } else { $RequireKnownMode }
    if ($requiredMode -and -not $script:KnownPackages.ContainsKey($requiredMode)) {
        throw "HD texture mode '$requiredMode' does not yet have a pinned package identity."
    }
    $matchedPackage = @($script:KnownPackages.Values | Where-Object {
        $orderedTextures.Count -eq $_.FileCount -and
        $totalBytes -eq $_.TotalBytes -and
        $manifestSha256 -ceq $_.ManifestSha256
    } | Select-Object -First 1)
    $matchesKnownPackage = $matchedPackage.Count -eq 1
    if ($requiredMode) {
        $expectedPackage = $script:KnownPackages[$requiredMode]
    }
    else {
        $expectedPackage = if ($matchesKnownPackage) { $matchedPackage[0] } else { $script:KnownPackages.Full }
    }
    if ($requiredMode -and (-not $matchesKnownPackage -or $matchedPackage[0].Mode -cne $requiredMode)) {
        throw (("HD texture package identity mismatch. Expected {0} files, {1} bytes, and manifest SHA-256 {2}; " +
            "found {3} files, {4} bytes, and {5}: {6}") -f
            $expectedPackage.FileCount, $expectedPackage.TotalBytes, $expectedPackage.ManifestSha256,
            $orderedTextures.Count, $totalBytes, $manifestSha256, $fullPackageRoot)
    }

    return [pscustomobject]@{
        PackageRoot              = $packageRootItem.FullName
        ContentRoot              = $contentRootItem.FullName
        ContentMountName         = 'FEAR'
        IncludesExpansionContent = $false
        FileCount                = $orderedTextures.Count
        TotalBytes               = $totalBytes
        ManifestSha256           = $manifestSha256
        ManifestFormat           = $script:ManifestFormat
        MatchesKnownPackage      = $matchesKnownPackage
        KnownPackageMode         = if ($matchesKnownPackage) { [string]$matchedPackage[0].Mode } else { $null }
        KnownPackageName         = if ($matchesKnownPackage) { [string]$matchedPackage[0].Name } else { $null }
        ExpectedFileCount        = $expectedPackage.FileCount
        ExpectedTotalBytes       = $expectedPackage.TotalBytes
        ExpectedManifestSha256   = $expectedPackage.ManifestSha256
        MinimumWidth             = [uint32]$minWidth
        MaximumWidth             = [uint32]$maxWidth
        MinimumHeight            = [uint32]$minHeight
        MaximumHeight            = [uint32]$maxHeight
        MinimumMipMapCount       = [uint32]$minMipMapCount
        MaximumMipMapCount       = [uint32]$maxMipMapCount
        FourCcTextureCount       = $fourCcTextureCount
        Rgb32TextureCount        = $rgb32TextureCount
        Formats                  = $formatSummary
        Files                    = $orderedTextures
    }
}

Export-ModuleMember -Function Get-FearHdTexturePackageIdentity
