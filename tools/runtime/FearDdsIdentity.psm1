Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FearDdsTextureIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][IO.FileInfo]$File,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    $stream = [IO.FileStream]::new(
        $File.FullName,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read,
        1048576,
        [IO.FileOptions]::SequentialScan)
    try {
        if ($stream.Length -lt 128) {
            throw "DDS file is shorter than its 128-byte base header: $($File.FullName)"
        }
        $header = [byte[]]::new(128)
        $offset = 0
        while ($offset -lt $header.Length) {
            $read = $stream.Read($header, $offset, $header.Length - $offset)
            if ($read -eq 0) {
                throw "DDS file ended while its header was being read: $($File.FullName)"
            }
            $offset += $read
        }

        if ($header[0] -ne 0x44 -or $header[1] -ne 0x44 -or
            $header[2] -ne 0x53 -or $header[3] -ne 0x20) {
            throw "DDS magic is invalid: $($File.FullName)"
        }

        $headerSize = [BitConverter]::ToUInt32($header, 4)
        $headerFlags = [BitConverter]::ToUInt32($header, 8)
        $height = [BitConverter]::ToUInt32($header, 12)
        $width = [BitConverter]::ToUInt32($header, 16)
        $mipMapCount = [BitConverter]::ToUInt32($header, 28)
        $pixelFormatSize = [BitConverter]::ToUInt32($header, 76)
        $pixelFormatFlags = [BitConverter]::ToUInt32($header, 80)
        $fourCcBytes = [byte[]]::new(4)
        [Buffer]::BlockCopy($header, 84, $fourCcBytes, 0, 4)
        $fourCc = [Text.Encoding]::ASCII.GetString($fourCcBytes)
        $rgbBitCount = [BitConverter]::ToUInt32($header, 88)
        $redMask = [BitConverter]::ToUInt32($header, 92)
        $greenMask = [BitConverter]::ToUInt32($header, 96)
        $blueMask = [BitConverter]::ToUInt32($header, 100)
        $alphaMask = [BitConverter]::ToUInt32($header, 104)
        $caps = [BitConverter]::ToUInt32($header, 108)

        if ($headerSize -ne 124) {
            throw "DDS header size is $headerSize; expected 124: $($File.FullName)"
        }
        if ($pixelFormatSize -ne 32) {
            throw "DDS pixel-format header size is $pixelFormatSize; expected 32: $($File.FullName)"
        }
        if (($headerFlags -band 0x00001007) -ne 0x00001007) {
            throw "DDS header is missing required caps, dimensions, or pixel-format flags: $($File.FullName)"
        }
        if ($width -eq 0 -or $height -eq 0) {
            throw "DDS dimensions must be positive: $($File.FullName)"
        }
        if (($caps -band 0x00001000) -eq 0) {
            throw "DDS header is missing DDSCAPS_TEXTURE: $($File.FullName)"
        }

        $hasFourCc = (($pixelFormatFlags -band 0x00000004) -ne 0)
        $hasRgb = (($pixelFormatFlags -band 0x00000040) -ne 0)
        if ($hasFourCc -eq $hasRgb) {
            throw "DDS pixel format must declare exactly one FourCC or RGB layout: $($File.FullName)"
        }

        if ($hasFourCc) {
            foreach ($value in $fourCcBytes) {
                if ($value -lt 0x20 -or $value -gt 0x7E) {
                    throw "DDS FourCC contains a non-printable byte: $($File.FullName)"
                }
            }
            if ($fourCc -ceq 'DX10') {
                throw "DDS DX10 pixel formats are not supported by the F.E.A.R. D3D9 content path: $($File.FullName)"
            }
            $formatKind = 'FourCC'
            $formatName = $fourCc
        }
        else {
            if ($rgbBitCount -ne 32) {
                throw "DDS RGB content must use a 32-bit pixel layout; found $rgbBitCount bits: $($File.FullName)"
            }
            if ($redMask -eq 0 -or $greenMask -eq 0 -or $blueMask -eq 0 -or
                ($redMask -band $greenMask) -ne 0 -or
                ($redMask -band $blueMask) -ne 0 -or
                ($greenMask -band $blueMask) -ne 0 -or
                ($alphaMask -ne 0 -and (
                    ($alphaMask -band $redMask) -ne 0 -or
                    ($alphaMask -band $greenMask) -ne 0 -or
                    ($alphaMask -band $blueMask) -ne 0))) {
                throw "DDS 32-bit RGB channel masks are empty or overlapping: $($File.FullName)"
            }
            if (($pixelFormatFlags -band 0x00000001) -ne 0 -and $alphaMask -eq 0) {
                throw "DDS declares alpha pixels but its alpha mask is empty: $($File.FullName)"
            }
            $formatKind = 'Rgb32'
            $formatName = ('RGB32:{0:X8}:{1:X8}:{2:X8}:{3:X8}' -f
                $redMask, $greenMask, $blueMask, $alphaMask)
            $fourCc = ''
        }

        $stream.Position = 0
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $fileSha256 = ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '')
        }
        finally {
            $sha256.Dispose()
        }

        return [pscustomobject]@{
            RelativePath     = $RelativePath
            FullPath         = $File.FullName
            Size             = [long]$stream.Length
            Sha256           = $fileSha256
            Width            = [uint32]$width
            Height           = [uint32]$height
            MipMapCount      = [uint32]$mipMapCount
            HeaderFlags      = [uint32]$headerFlags
            PixelFormatFlags = [uint32]$pixelFormatFlags
            FormatKind       = $formatKind
            FormatName       = $formatName
            FourCC           = $fourCc
            RgbBitCount      = [uint32]$rgbBitCount
            RedMask          = [uint32]$redMask
            GreenMask        = [uint32]$greenMask
            BlueMask         = [uint32]$blueMask
            AlphaMask        = [uint32]$alphaMask
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Get-FearDdsManifestSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object[]]$Files)

    $lines = [string[]]@($Files | ForEach-Object {
        "$($_.RelativePath)|$($_.Size)|$($_.Sha256.ToLowerInvariant())"
    })
    [Array]::Sort($lines, [StringComparer]::Ordinal)
    $manifestText = $lines -join "`n"
    $manifestBytes = [Text.UTF8Encoding]::new($false).GetBytes($manifestText)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($manifestBytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

Export-ModuleMember -Function Get-FearDdsManifestSha256, Get-FearDdsTextureIdentity
