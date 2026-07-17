[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$RealPackageRoot,
    [string]$RealLitePackageRoot,
    [switch]$ValidateRealPackage
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-UInt32LittleEndian {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][int]$Offset,
        [Parameter(Mandatory = $true)][uint32]$Value
    )

    [Buffer]::BlockCopy([BitConverter]::GetBytes($Value), 0, $Bytes, $Offset, 4)
}

function New-SyntheticDdsBytes {
    param(
        [Parameter(Mandatory = $true)][uint32]$Width,
        [Parameter(Mandatory = $true)][uint32]$Height,
        [Parameter(Mandatory = $true)][uint32]$MipMapCount,
        [ValidateSet('DXT1', 'ARGB32')][string]$Format
    )

    $payloadLength = 0
    $mipWidth = $Width
    $mipHeight = $Height
    $levelCount = [Math]::Max(1, $MipMapCount)
    for ($level = 0; $level -lt $levelCount; $level++) {
        if ($Format -eq 'DXT1') {
            $blockWidth = [Math]::Max(1, [int][Math]::Ceiling($mipWidth / 4.0))
            $blockHeight = [Math]::Max(1, [int][Math]::Ceiling($mipHeight / 4.0))
            $payloadLength += $blockWidth * $blockHeight * 8
        }
        else {
            $payloadLength += [int]($mipWidth * $mipHeight * 4)
        }
        $mipWidth = [Math]::Max(1, [uint32]($mipWidth / 2))
        $mipHeight = [Math]::Max(1, [uint32]($mipHeight / 2))
    }
    $bytes = [byte[]]::new(128 + $payloadLength)
    $bytes[0] = 0x44
    $bytes[1] = 0x44
    $bytes[2] = 0x53
    $bytes[3] = 0x20
    Set-UInt32LittleEndian -Bytes $bytes -Offset 4 -Value 124
    $headerFlags = [uint32]0x00001007
    if ($Format -eq 'DXT1') {
        $headerFlags = $headerFlags -bor 0x00080000
        $baseLinearSize = [Math]::Max(1, [int][Math]::Ceiling($Width / 4.0)) *
            [Math]::Max(1, [int][Math]::Ceiling($Height / 4.0)) * 8
        Set-UInt32LittleEndian -Bytes $bytes -Offset 20 -Value $baseLinearSize
    }
    else {
        $headerFlags = $headerFlags -bor 0x00000008
        Set-UInt32LittleEndian -Bytes $bytes -Offset 20 -Value ($Width * 4)
    }
    if ($MipMapCount -gt 1) {
        $headerFlags = $headerFlags -bor 0x00020000
    }
    Set-UInt32LittleEndian -Bytes $bytes -Offset 8 -Value $headerFlags
    Set-UInt32LittleEndian -Bytes $bytes -Offset 12 -Value $Height
    Set-UInt32LittleEndian -Bytes $bytes -Offset 16 -Value $Width
    Set-UInt32LittleEndian -Bytes $bytes -Offset 28 -Value $MipMapCount
    Set-UInt32LittleEndian -Bytes $bytes -Offset 76 -Value 32
    $caps = if ($MipMapCount -gt 1) { [uint32]0x00401008 } else { [uint32]0x00001000 }
    Set-UInt32LittleEndian -Bytes $bytes -Offset 108 -Value $caps

    if ($Format -eq 'DXT1') {
        Set-UInt32LittleEndian -Bytes $bytes -Offset 80 -Value 0x00000004
        [Buffer]::BlockCopy([Text.Encoding]::ASCII.GetBytes('DXT1'), 0, $bytes, 84, 4)
    }
    else {
        Set-UInt32LittleEndian -Bytes $bytes -Offset 80 -Value 0x00000041
        Set-UInt32LittleEndian -Bytes $bytes -Offset 88 -Value 32
        Set-UInt32LittleEndian -Bytes $bytes -Offset 92 -Value 0x00FF0000
        Set-UInt32LittleEndian -Bytes $bytes -Offset 96 -Value 0x0000FF00
        Set-UInt32LittleEndian -Bytes $bytes -Offset 100 -Value 0x000000FF
        Set-UInt32LittleEndian -Bytes $bytes -Offset 104 -Value ([uint32]0xFF000000L)
    }
    for ($index = 128; $index -lt $bytes.Length; $index++) {
        $bytes[$index] = [byte](($index - 128) % 251)
    }
    return $bytes
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        $Actual,
        $Expected
    )

    if ($Actual -cne $Expected) {
        throw "$Description mismatch. Expected '$Expected' but found '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$MessagePattern
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "$Description threw an unexpected error: $($_.Exception.Message)"
        }
        return
    }
    throw "$Description did not fail."
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$modulePath = Join-Path $PSScriptRoot 'FearTexturePackage.psm1'
Import-Module $modulePath -Force -ErrorAction Stop
$exportedFunctions = @((Get-Command -Module FearTexturePackage).Name | Sort-Object) -join ','
Assert-Equal -Description 'Texture-package module export surface' `
    -Actual $exportedFunctions `
    -Expected 'Get-FearHdTexturePackageIdentity'

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ("fear-hd-texture-test-{0}" -f [Guid]::NewGuid().ToString('N'))
$junctionPath = $null
try {
    $validRoot = Join-Path $temporaryRoot 'valid-package'
    $contentRoot = Join-Path $validRoot 'HDTextures\FEAR'
    $worldDirectory = Join-Path $contentRoot 'World'
    $uiDirectory = Join-Path $contentRoot 'UI'
    $xpDirectory = Join-Path $validRoot 'HDTextures\XP'
    New-Item -ItemType Directory -Path $worldDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $uiDirectory -Force | Out-Null
    New-Item -ItemType Directory -Path $xpDirectory -Force | Out-Null
    [IO.File]::WriteAllBytes(
        (Join-Path $worldDirectory 'Concrete.DDS'),
        (New-SyntheticDdsBytes -Width 8 -Height 4 -MipMapCount 3 -Format DXT1))
    [IO.File]::WriteAllBytes(
        (Join-Path $uiDirectory 'Panel.dds'),
        (New-SyntheticDdsBytes -Width 2 -Height 2 -MipMapCount 1 -Format ARGB32))

    $identity = Get-FearHdTexturePackageIdentity -PackageRoot $validRoot
    Assert-Equal -Description 'Synthetic DDS file count' -Actual $identity.FileCount -Expected 2
    Assert-Equal -Description 'Synthetic minimum width' -Actual $identity.MinimumWidth -Expected ([uint32]2)
    Assert-Equal -Description 'Synthetic maximum width' -Actual $identity.MaximumWidth -Expected ([uint32]8)
    Assert-Equal -Description 'Synthetic minimum height' -Actual $identity.MinimumHeight -Expected ([uint32]2)
    Assert-Equal -Description 'Synthetic maximum height' -Actual $identity.MaximumHeight -Expected ([uint32]4)
    Assert-Equal -Description 'Synthetic minimum mip count' -Actual $identity.MinimumMipMapCount -Expected ([uint32]1)
    Assert-Equal -Description 'Synthetic maximum mip count' -Actual $identity.MaximumMipMapCount -Expected ([uint32]3)
    Assert-Equal -Description 'Synthetic FourCC count' -Actual $identity.FourCcTextureCount -Expected 1
    Assert-Equal -Description 'Synthetic RGB32 count' -Actual $identity.Rgb32TextureCount -Expected 1
    Assert-Equal -Description 'Synthetic known-package match' -Actual $identity.MatchesKnownPackage -Expected $false
    Assert-Equal -Description 'Canonical manifest format contract' `
        -Actual $identity.ManifestFormat `
        -Expected 'Ordinal-sorted lowercase relative/path|decimal-size|lowercase-file-sha256; UTF-8 without BOM; LF between records; no trailing LF'
    Assert-Equal -Description 'Canonical first relative path' -Actual $identity.Files[0].RelativePath -Expected 'ui/panel.dds'
    Assert-Equal -Description 'Canonical second relative path' -Actual $identity.Files[1].RelativePath -Expected 'world/concrete.dds'
    Assert-Equal -Description 'ARGB bit count' -Actual $identity.Files[0].RgbBitCount -Expected ([uint32]32)
    Assert-Equal -Description 'ARGB red mask' -Actual $identity.Files[0].RedMask -Expected ([uint32]0x00FF0000)
    Assert-Equal -Description 'ARGB alpha mask' -Actual $identity.Files[0].AlphaMask -Expected ([uint32]0xFF000000L)
    Assert-Equal -Description 'DXT FourCC' -Actual $identity.Files[1].FourCC -Expected 'DXT1'
    Assert-Equal -Description 'Synthetic canonical manifest SHA-256' `
        -Actual $identity.ManifestSha256 `
        -Expected '188F39D9F7062B93EC84264FC8994FD07B701976C5119759EB662D4857DBC087'

    Assert-Throws -Description 'Known-package identity requirement' -MessagePattern 'identity mismatch' -Action {
        Get-FearHdTexturePackageIdentity -PackageRoot $validRoot -RequireKnownRivarezV202 | Out-Null
    }
    Assert-Throws -Description 'Extraction Point root rejection' -MessagePattern 'Extraction Point \(XP\)' -Action {
        Get-FearHdTexturePackageIdentity -PackageRoot $xpDirectory | Out-Null
    }

    $unexpectedRoot = Join-Path $temporaryRoot 'unexpected-extension'
    Copy-Item -LiteralPath $validRoot -Destination $unexpectedRoot -Recurse
    [IO.File]::WriteAllBytes(
        (Join-Path $unexpectedRoot 'HDTextures\FEAR\World\preview.png'),
        [byte[]](0x89, 0x50, 0x4E, 0x47))
    Assert-Throws -Description 'Unexpected extension rejection' -MessagePattern 'only DDS files' -Action {
        Get-FearHdTexturePackageIdentity -PackageRoot $unexpectedRoot | Out-Null
    }

    $corruptRoot = Join-Path $temporaryRoot 'corrupt-dds'
    Copy-Item -LiteralPath $validRoot -Destination $corruptRoot -Recurse
    $corruptPath = Join-Path $corruptRoot 'HDTextures\FEAR\World\Concrete.DDS'
    $corruptBytes = [IO.File]::ReadAllBytes($corruptPath)
    $corruptBytes[0] = 0
    [IO.File]::WriteAllBytes($corruptPath, $corruptBytes)
    Assert-Throws -Description 'DDS magic rejection' -MessagePattern 'DDS magic is invalid' -Action {
        Get-FearHdTexturePackageIdentity -PackageRoot $corruptRoot | Out-Null
    }

    $maskRoot = Join-Path $temporaryRoot 'overlapping-mask'
    Copy-Item -LiteralPath $validRoot -Destination $maskRoot -Recurse
    $maskPath = Join-Path $maskRoot 'HDTextures\FEAR\UI\Panel.dds'
    $maskBytes = [IO.File]::ReadAllBytes($maskPath)
    Set-UInt32LittleEndian -Bytes $maskBytes -Offset 96 -Value 0x00FF0000
    [IO.File]::WriteAllBytes($maskPath, $maskBytes)
    Assert-Throws -Description 'DDS mask rejection' -MessagePattern 'channel masks are empty or overlapping' -Action {
        Get-FearHdTexturePackageIdentity -PackageRoot $maskRoot | Out-Null
    }

    $reparseRoot = Join-Path $temporaryRoot 'reparse-package'
    Copy-Item -LiteralPath $validRoot -Destination $reparseRoot -Recurse
    $junctionTarget = Join-Path $temporaryRoot 'junction-target'
    New-Item -ItemType Directory -Path $junctionTarget | Out-Null
    $junctionPath = Join-Path $reparseRoot 'HDTextures\FEAR\Linked'
    New-Item -ItemType Junction -Path $junctionPath -Target $junctionTarget | Out-Null
    Assert-Throws -Description 'Reparse-point rejection' -MessagePattern 'reparse point' -Action {
        Get-FearHdTexturePackageIdentity -PackageRoot $reparseRoot | Out-Null
    }
    Remove-Item -LiteralPath $junctionPath -Force
    $junctionPath = $null

    $realResult = 'Skipped'
    if ($ValidateRealPackage) {
        if (-not $RealPackageRoot) {
            $RealPackageRoot = Join-Path (Split-Path $RepositoryRoot -Parent) 'FEAR\HDTextures4FEAR_XP_v2.0.2'
        }
        if (-not (Test-Path -LiteralPath $RealPackageRoot -PathType Container)) {
            throw "Real HD texture package validation was requested, but the package root is missing: $RealPackageRoot"
        }
        $realIdentity = Get-FearHdTexturePackageIdentity `
            -PackageRoot $RealPackageRoot `
            -RequireKnownRivarezV202
        Assert-Equal -Description 'Real package DDS file count' -Actual $realIdentity.FileCount -Expected 1882
        Assert-Equal -Description 'Real package total bytes' -Actual $realIdentity.TotalBytes -Expected ([long]7587319112)
        Assert-Equal -Description 'Real package canonical manifest SHA-256' `
            -Actual $realIdentity.ManifestSha256 `
            -Expected 'C92E8C14ABBD5D8C306D072C2ABAD1EA22D0426182CE37E302E948EB9346D801'
        if (-not $RealLitePackageRoot) {
            $RealLitePackageRoot = Join-Path (Split-Path $RepositoryRoot -Parent) 'FEAR\HDTextures4FEAR_XP_v2.0.2-FearMore-Lite'
        }
        if (-not (Test-Path -LiteralPath $RealLitePackageRoot -PathType Container)) {
            throw "Real Stable Lite texture package validation was requested, but the package root is missing: $RealLitePackageRoot"
        }
        $realLiteIdentity = Get-FearHdTexturePackageIdentity `
            -PackageRoot $RealLitePackageRoot `
            -RequireKnownMode Lite
        Assert-Equal -Description 'Real Lite package DDS file count' -Actual $realLiteIdentity.FileCount -Expected 1882
        Assert-Equal -Description 'Real Lite package total bytes' -Actual $realLiteIdentity.TotalBytes -Expected ([long]4440752072)
        Assert-Equal -Description 'Real Lite package canonical manifest SHA-256' `
            -Actual $realLiteIdentity.ManifestSha256 `
            -Expected '758A5112EA00FD802B5373066EE3BD9AF29A501D271AF6A5CA7F14F6FEFB63ED'
        $realResult = 'Passed'
    }

    [pscustomobject]@{
        SyntheticPackage = 'Passed'
        NegativeCases     = 'Passed'
        RealPackage       = $realResult
        ExportedFunctions = $exportedFunctions
    }
}
finally {
    if ($junctionPath -and (Test-Path -LiteralPath $junctionPath)) {
        Remove-Item -LiteralPath $junctionPath -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}
