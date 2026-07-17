Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ControllerVersion = '3.4.10'
$script:ControllerArchiveName = 'SDL3-3.4.10-win32-x86.zip'
$script:ControllerDownloadUri = 'https://github.com/libsdl-org/SDL/releases/download/release-3.4.10/SDL3-3.4.10-win32-x86.zip'
$script:ExpectedArchiveSha256 = '95FA18CD5C8AD64DCEB0E0F5F006D223FF19630590457F3D4D3841EE2CA839BD'
$script:ExpectedRuntimeSha256 = '7F85F7C0FB1189050405ACD39BD1E36A8F94FFF5952C513497A9DCAFCB86A9B0'
$script:ExpectedRuntimeSize = 2342912L
$script:ExpectedLicenseSha256 = '1C040B8271B37E5076359F8FD54240E371114112924D2DF81EF87C7D6A1DFDFD'
$script:ExpectedLicenseSize = 884L
$script:ExpectedEntries = @('.git-hash', 'INSTALL.md', 'LICENSE.txt', 'README.md', 'SDL3.dll')

function Get-FearControllerPackageMetadata {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Provider              = 'SDL'
        Version               = $script:ControllerVersion
        ArchiveName           = $script:ControllerArchiveName
        DownloadUri           = $script:ControllerDownloadUri
        ArchiveSha256         = $script:ExpectedArchiveSha256
        RuntimeFileName       = 'SDL3.dll'
        RuntimeSha256         = $script:ExpectedRuntimeSha256
        RuntimeSize           = $script:ExpectedRuntimeSize
        LicenseEntryName      = 'LICENSE.txt'
        LicenseStagePath      = '.fearmore\licenses\SDL3-zlib.txt'
        LicenseSha256         = $script:ExpectedLicenseSha256
        LicenseSize           = $script:ExpectedLicenseSize
        Architecture          = 'x86'
        License               = 'Zlib'
        SourceRepository      = 'https://github.com/libsdl-org/SDL'
        ReleasePage           = 'https://github.com/libsdl-org/SDL/releases/tag/release-3.4.10'
    }
}

function Get-FearControllerPackageDefaultArchivePath {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    Join-Path ([IO.Path]::GetFullPath($RepositoryRoot)) "vendor-local\controller-deps\$script:ControllerArchiveName"
}

function Get-FearControllerBytesSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Read-FearControllerArchiveEntryBytes {
    param([Parameter(Mandatory = $true)]$Entry)

    $stream = $Entry.Open()
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            return $memory.ToArray()
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Assert-FearControllerX86PeBytes {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    if ($Bytes.Length -lt 512 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) {
        throw 'Pinned SDL3 runtime payload is not a PE image.'
    }
    $peOffset = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($peOffset -lt 0x40 -or $peOffset + 26 -gt $Bytes.Length -or
        $Bytes[$peOffset] -ne 0x50 -or $Bytes[$peOffset + 1] -ne 0x45 -or
        $Bytes[$peOffset + 2] -ne 0 -or $Bytes[$peOffset + 3] -ne 0) {
        throw 'Pinned SDL3 runtime payload has an invalid PE header.'
    }
    $machine = [BitConverter]::ToUInt16($Bytes, $peOffset + 4)
    $optionalHeaderMagic = [BitConverter]::ToUInt16($Bytes, $peOffset + 24)
    if ($machine -ne 0x014C -or $optionalHeaderMagic -ne 0x010B) {
        throw ('Pinned SDL3 runtime payload is not a 32-bit x86 PE image ' +
            "(machine=0x$($machine.ToString('X4')), magic=0x$($optionalHeaderMagic.ToString('X4'))).")
    }

    [pscustomobject]@{
        Machine            = $machine
        OptionalHeaderMagic = $optionalHeaderMagic
        IsX86Pe32          = $true
    }
}

function Get-FearControllerPackageStagePayload {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    $resolvedArchive = [IO.Path]::GetFullPath($ArchivePath)
    if (-not (Test-Path -LiteralPath $resolvedArchive -PathType Leaf)) {
        throw "Pinned SDL3 x86 archive is missing: $resolvedArchive. Run tools/runtime/Get-FearControllerRuntime.ps1 or relaunch through Start-FearMore.ps1."
    }
    $archiveItem = Get-Item -LiteralPath $resolvedArchive -Force
    if (($archiveItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Pinned SDL3 archive must be an ordinary file, not a reparse point: $resolvedArchive"
    }
    $archiveSha256 = (Get-FileHash -LiteralPath $resolvedArchive -Algorithm SHA256).Hash
    if ($archiveSha256 -cne $script:ExpectedArchiveSha256) {
        throw "SDL3 archive hash mismatch. Expected $script:ExpectedArchiveSha256 but found $archiveSha256 at '$resolvedArchive'."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($resolvedArchive)
    try {
        $entriesByName = @{}
        foreach ($entry in $archive.Entries) {
            $entryName = [string]$entry.FullName
            if ([string]::IsNullOrWhiteSpace($entryName) -or $entryName.Contains('/') -or
                $entryName.Contains('\') -or $entryName.Contains(':') -or $entryName -in @('.', '..')) {
                throw "SDL3 archive contains an unexpected or unsafe path: '$entryName'."
            }
            if ($entriesByName.ContainsKey($entryName)) {
                throw "SDL3 archive contains duplicate entry '$entryName'."
            }
            $entriesByName[$entryName] = $entry
        }
        $actualEntries = @($entriesByName.Keys | Sort-Object)
        $expectedEntries = @($script:ExpectedEntries | Sort-Object)
        if (($actualEntries -join '|') -cne ($expectedEntries -join '|')) {
            throw "SDL3 archive entry set is not the pinned official x86 package. Expected '$($expectedEntries -join ', ')' but found '$($actualEntries -join ', ')'."
        }

        $runtimeBytes = Read-FearControllerArchiveEntryBytes -Entry $entriesByName['SDL3.dll']
        $licenseBytes = Read-FearControllerArchiveEntryBytes -Entry $entriesByName['LICENSE.txt']
        $runtimeSha256 = Get-FearControllerBytesSha256 -Bytes $runtimeBytes
        $licenseSha256 = Get-FearControllerBytesSha256 -Bytes $licenseBytes
        if ($runtimeBytes.Length -ne $script:ExpectedRuntimeSize -or
            $runtimeSha256 -cne $script:ExpectedRuntimeSha256) {
            throw 'SDL3.dll does not match the pinned official 3.4.10 x86 runtime identity.'
        }
        if ($licenseBytes.Length -ne $script:ExpectedLicenseSize -or
            $licenseSha256 -cne $script:ExpectedLicenseSha256) {
            throw 'SDL3 LICENSE.txt does not match the pinned official zlib license identity.'
        }
        $peIdentity = Assert-FearControllerX86PeBytes -Bytes $runtimeBytes
        $licenseText = [Text.Encoding]::UTF8.GetString($licenseBytes)
        if ($licenseText -notmatch 'Permission is granted to anyone to use this software for any purpose' -or
            $licenseText -notmatch 'This notice may not be removed or altered') {
            throw 'SDL3 license payload is not the expected zlib license text.'
        }

        [pscustomobject]@{
            Provider               = 'SDL'
            Version                = $script:ControllerVersion
            ArchivePath            = $resolvedArchive
            ArchiveSize            = [long]$archiveItem.Length
            ArchiveSha256          = $archiveSha256
            DownloadUri            = $script:ControllerDownloadUri
            RuntimeFileName        = 'SDL3.dll'
            RuntimeBytes           = $runtimeBytes
            RuntimeSize            = [long]$runtimeBytes.Length
            RuntimeSha256          = $runtimeSha256
            RuntimeMachine         = $peIdentity.Machine
            RuntimeOptionalHeaderMagic = $peIdentity.OptionalHeaderMagic
            RuntimeArchitecture    = 'x86'
            LicenseEntryName       = 'LICENSE.txt'
            LicenseStagePath       = '.fearmore\licenses\SDL3-zlib.txt'
            LicenseBytes           = $licenseBytes
            LicenseSize            = [long]$licenseBytes.Length
            LicenseSha256          = $licenseSha256
            License                = 'Zlib'
            SourceRepository       = 'https://github.com/libsdl-org/SDL'
            ReleasePage            = 'https://github.com/libsdl-org/SDL/releases/tag/release-3.4.10'
        }
    }
    finally {
        $archive.Dispose()
    }
}

Export-ModuleMember -Function @(
    'Get-FearControllerPackageMetadata',
    'Get-FearControllerPackageDefaultArchivePath',
    'Get-FearControllerPackageStagePayload'
)
