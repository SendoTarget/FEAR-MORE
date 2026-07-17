Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:DgVoodooVersion = '2.87.3'
$script:DgVoodooConfigVersion = '0x287'
$script:ExpectedArchiveSize = 9082391
$script:ExpectedArchiveSha256 = '6FB954BED55BF70E948C5045A663A9DF31EA206FAF105E327BAFE46C318F867F'
$script:ProxyEntryName = 'MS/x86/D3D9.dll'
$script:ExpectedProxySize = 485888
$script:ExpectedProxySha256 = 'C13E3C0969D2C70A1A63CF96B83C7CD3BC47F925F28EC92C07D5B72D6DF4C240'
$script:DefaultConfigEntryName = 'dgVoodoo.conf'
$script:ExpectedDefaultConfigSize = 21903
$script:ExpectedDefaultConfigSha256 = 'FD2C19EA2B7C1BD3AE38D86571AC2484E0681294F0783CF5197AD349495A35BD'
$script:RtxRemixVersion = '1.5.2'
$script:ExpectedRtxRemixArchiveSize = 231778218
$script:ExpectedRtxRemixArchiveSha256 = 'CC424BE4DD1A0C6FD922BC6A7F8E5F6582BAEA7043A38AFA6686D8B6FAABAD01'
$script:ExpectedRtxRemixEntryCount = 252
$script:ExpectedRtxRemixFileCount = 165
$script:ExpectedRtxRemixDirectoryCount = 87

function Get-ByteArraySha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Read-ZipEntryBytes {
    param(
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][long]$ExpectedSize
    )

    $matches = @($Archive.Entries | Where-Object { $_.FullName -ieq $EntryName })
    if ($matches.Count -ne 1) {
        throw "Pinned dgVoodoo2 archive must contain exactly one '$EntryName' entry; found $($matches.Count)."
    }
    $entry = $matches[0]
    if ($entry.Length -ne $ExpectedSize) {
        throw "Pinned dgVoodoo2 '$EntryName' size mismatch. Expected $ExpectedSize bytes but found $($entry.Length)."
    }

    $stream = $entry.Open()
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

function Get-PeIdentityFromBytes {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($Bytes.Length -lt 64 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) {
        throw "$Description is not a valid PE image."
    }
    $peOffset = [BitConverter]::ToInt32($Bytes, 0x3C)
    if ($peOffset -lt 0 -or ($peOffset + 26) -ge $Bytes.Length -or
        $Bytes[$peOffset] -ne 0x50 -or $Bytes[$peOffset + 1] -ne 0x45 -or
        $Bytes[$peOffset + 2] -ne 0 -or $Bytes[$peOffset + 3] -ne 0) {
        throw "$Description has invalid PE headers."
    }

    return [pscustomobject]@{
        Machine = [BitConverter]::ToUInt16($Bytes, $peOffset + 4)
        Magic   = [BitConverter]::ToUInt16($Bytes, $peOffset + 24)
    }
}

function ConvertTo-FearSafeRendererArchiveRelativePath {
    param([Parameter(Mandatory = $true)][string]$EntryName)

    if ([string]::IsNullOrWhiteSpace($EntryName) -or $EntryName.IndexOf([char]0) -ge 0) {
        throw "Renderer archive contains an empty or NUL-bearing entry name."
    }

    $normalized = $EntryName.Replace('/', '\').TrimEnd('\')
    if (-not $normalized -or $normalized.StartsWith('\') -or $normalized -match '^[A-Za-z]:') {
        throw "Renderer archive entry is absolute or root-relative: $EntryName"
    }

    $invalidFileNameCharacters = [IO.Path]::GetInvalidFileNameChars()
    $components = @($normalized -split '\\')
    foreach ($component in $components) {
        if (-not $component -or $component -in @('.', '..')) {
            throw "Renderer archive entry contains an unsafe path component: $EntryName"
        }
        if ($component.TrimEnd(' ', '.') -cne $component) {
            throw "Renderer archive entry contains a Windows-ambiguous trailing dot or space: $EntryName"
        }
        if ($component.IndexOfAny($invalidFileNameCharacters) -ge 0) {
            throw "Renderer archive entry contains an invalid Windows filename character: $EntryName"
        }
        $deviceStem = $component.Split('.')[0]
        if ($deviceStem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]|CONIN\$|CONOUT\$)$') {
            throw "Renderer archive entry uses a reserved Windows device name: $EntryName"
        }
    }
    if ($components[0] -ieq 'Retail') {
        throw "Renderer archive entry targets the stage's protected Retail subtree: $EntryName"
    }

    return ($components -join '\')
}

function Test-FearRendererArchiveEntryPath {
    param([Parameter(Mandatory = $true)][string]$EntryName)

    try {
        ConvertTo-FearSafeRendererArchiveRelativePath -EntryName $EntryName | Out-Null
        return $true
    }
    catch {
        return $false
    }
}

function Get-ZipEntrySha256 {
    param([Parameter(Mandatory = $true)]$Entry)

    $stream = $Entry.Open()
    try {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            return ([BitConverter]::ToString($sha256.ComputeHash($stream))).Replace('-', '')
        }
        finally {
            $sha256.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Read-ZipEntryPrefixBytes {
    param(
        [Parameter(Mandatory = $true)]$Entry,
        [ValidateRange(512, 65536)][int]$MaximumBytes = 4096
    )

    $length = [int][Math]::Min([long]$MaximumBytes, [long]$Entry.Length)
    $bytes = [byte[]]::new($length)
    $stream = $Entry.Open()
    try {
        $offset = 0
        while ($offset -lt $bytes.Length) {
            $read = $stream.Read($bytes, $offset, $bytes.Length - $offset)
            if ($read -eq 0) {
                break
            }
            $offset += $read
        }
        if ($offset -ne $bytes.Length) {
            throw "Renderer archive entry '$($Entry.FullName)' ended before its declared length."
        }
        return $bytes
    }
    finally {
        $stream.Dispose()
    }
}

function Get-FearRtxRemixPackageIdentity {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Pinned RTX Remix $script:RtxRemixVersion archive is missing: $ArchivePath"
    }
    $file = Get-Item -LiteralPath $ArchivePath
    if ($file.Length -ne $script:ExpectedRtxRemixArchiveSize) {
        throw "RTX Remix archive size mismatch. Expected $script:ExpectedRtxRemixArchiveSize bytes but found $($file.Length) at '$ArchivePath'."
    }
    $archiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    if ($archiveHash -ne $script:ExpectedRtxRemixArchiveSha256) {
        throw "RTX Remix archive hash mismatch. Expected $script:ExpectedRtxRemixArchiveSha256 but found $archiveHash at '$ArchivePath'."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        if ($archive.Entries.Count -ne $script:ExpectedRtxRemixEntryCount) {
            throw "Pinned RTX Remix archive entry-count mismatch. Expected $script:ExpectedRtxRemixEntryCount but found $($archive.Entries.Count)."
        }

        $seenPaths = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
        $files = [Collections.Generic.List[object]]::new()
        $directoryCount = 0
        foreach ($entry in $archive.Entries) {
            $relativePath = ConvertTo-FearSafeRendererArchiveRelativePath -EntryName $entry.FullName
            $entryKind = if ($entry.FullName.EndsWith('/')) { 'Directory' } else { 'File' }
            if ($seenPaths.ContainsKey($relativePath)) {
                throw "Renderer archive has duplicate or file/directory-colliding entries '$($seenPaths[$relativePath])' and '$($entry.FullName)'."
            }
            $seenPaths[$relativePath] = $entry.FullName

            if ($entryKind -eq 'Directory') {
                if ($entry.Length -ne 0) {
                    throw "Renderer archive directory entry has nonzero content length: $($entry.FullName)"
                }
                $directoryCount++
                continue
            }

            $files.Add([pscustomobject]@{
                ArchiveEntry = $entry.FullName
                RelativePath = $relativePath
                Size         = [long]$entry.Length
                Sha256       = Get-ZipEntrySha256 -Entry $entry
            })
        }
        if ($files.Count -ne $script:ExpectedRtxRemixFileCount -or
            $directoryCount -ne $script:ExpectedRtxRemixDirectoryCount) {
            throw "Pinned RTX Remix archive layout mismatch. Expected $script:ExpectedRtxRemixFileCount files/$script:ExpectedRtxRemixDirectoryCount directories but found $($files.Count)/$directoryCount."
        }

        $requiredEntries = @(
            [pscustomobject]@{ Name = 'd3d9.dll'; Size = 863856; Sha256 = 'A9D0846720E90D36D19AFB67E76A4D894EB349ECF13B847DE0CEDA4861669965'; Machine = 0x014C; Magic = 0x010B },
            [pscustomobject]@{ Name = 'd3d8to9.dll'; Size = 134256; Sha256 = 'DE81BDFCACEF68C9AA59E54C053115BBC7732DCA09838B5383E0A057B3DB0EB0'; Machine = 0x014C; Magic = 0x010B },
            [pscustomobject]@{ Name = 'NvRemixLauncher32.exe'; Size = 148592; Sha256 = 'B41EF550ABA544955F8D61BF7A970695BA0EABADD414DAF82772603A0AB2532C'; Machine = 0x014C; Magic = 0x010B },
            [pscustomobject]@{ Name = '.trex/d3d9.dll'; Size = 190838384; Sha256 = 'F7C310821AA98BCDFDEC120330B0A89457B7C5EBA58D21464AF32639611C809F'; Machine = 0x8664; Magic = 0x020B },
            [pscustomobject]@{ Name = '.trex/NvRemixBridge.exe'; Size = 1121392; Sha256 = '4A5FC2C711850C78E0F70E56512AE31B5AA45D33C3F3DAD7471412D2CB2FD2AE'; Machine = 0x8664; Magic = 0x020B }
        )
        foreach ($required in $requiredEntries) {
            $normalizedRequiredPath = $required.Name.Replace('/', '\')
            $fileIdentity = @($files | Where-Object { $_.RelativePath -ceq $normalizedRequiredPath })
            if ($fileIdentity.Count -ne 1 -or $fileIdentity[0].Size -ne $required.Size -or
                $fileIdentity[0].Sha256 -ne $required.Sha256) {
                throw "Pinned RTX Remix required payload identity mismatch: $($required.Name)"
            }
            $entry = $archive.GetEntry($required.Name)
            $peIdentity = Get-PeIdentityFromBytes -Bytes (Read-ZipEntryPrefixBytes -Entry $entry) -Description "Pinned RTX Remix $($required.Name)"
            if ($peIdentity.Machine -ne $required.Machine -or $peIdentity.Magic -ne $required.Magic) {
                throw ("Pinned RTX Remix '{0}' has the wrong PE architecture (machine 0x{1:X4}/magic 0x{2:X4}; expected 0x{3:X4}/0x{4:X4})." -f
                    $required.Name, $peIdentity.Machine, $peIdentity.Magic, $required.Machine, $required.Magic)
            }
        }

        foreach ($notice in @(
            [pscustomobject]@{ Name = 'LICENSE.txt'; Size = 1147; Sha256 = '374CF90C1E4F2B42451ECD6C0884E1253BD9AA980DCEC732B717E4D872220A25' },
            [pscustomobject]@{ Name = 'ThirdPartyLicenses-d3d8to9.txt'; Size = 1293; Sha256 = 'FA65D158BEEFA55F270EE0C69C42CF5E92CC607D14336E7D74B8524B59A08902' },
            [pscustomobject]@{ Name = 'ThirdPartyLicenses-dxvk.txt'; Size = 144473; Sha256 = '0839004BCB91DD7B9A0998CB0A0001F1EA717A6F17E4B2D2B5741003565D65E2' }
        )) {
            $noticeIdentity = @($files | Where-Object { $_.RelativePath -ceq $notice.Name })
            if ($noticeIdentity.Count -ne 1 -or $noticeIdentity[0].Size -ne $notice.Size -or
                $noticeIdentity[0].Sha256 -ne $notice.Sha256) {
                throw "Pinned RTX Remix notice identity mismatch: $($notice.Name)"
            }
        }

        $orderedFiles = @($files | Sort-Object RelativePath)
        return [pscustomobject]@{
            Version                    = $script:RtxRemixVersion
            ArchivePath                = [IO.Path]::GetFullPath($ArchivePath)
            ArchiveSize                = $file.Length
            ArchiveSha256              = $archiveHash
            ArchiveEntryCount          = $archive.Entries.Count
            ArchiveFileCount           = $files.Count
            ArchiveDirectoryCount      = $directoryCount
            ProxyEntry                 = 'd3d9.dll'
            ProxyFileName              = 'd3d9.dll'
            ProxySize                  = 863856
            ProxySha256                = 'A9D0846720E90D36D19AFB67E76A4D894EB349ECF13B847DE0CEDA4861669965'
            ProxyMachine               = 0x014C
            ProxyOptionalHeaderMagic   = 0x010B
            BridgeEntry                = '.trex/NvRemixBridge.exe'
            BridgeMachine              = 0x8664
            BridgeOptionalHeaderMagic  = 0x020B
            Files                      = $orderedFiles
            Experimental               = $true
            CompatibilityStatus        = 'UnverifiedProbe'
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Read-StrictIniSettings {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "dgVoodoo2 config is missing: $Path"
    }
    $settings = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $section = 'Root'
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith(';')) {
            continue
        }
        if ($trimmed -match '^\[([^\]]+)\]$') {
            $section = $Matches[1].Trim()
            continue
        }
        if ($trimmed -notmatch '^([^=]+?)\s*=\s*(.*?)\s*$') {
            throw "dgVoodoo2 config contains an unrecognized active line: $line"
        }
        $qualifiedName = "$section.$($Matches[1].Trim())"
        if ($settings.ContainsKey($qualifiedName)) {
            throw "dgVoodoo2 config contains a duplicate active setting: $qualifiedName"
        }
        $settings[$qualifiedName] = $Matches[2].Trim()
    }
    return $settings
}

function Get-FearDgVoodooPackageIdentity {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "Pinned dgVoodoo2 $script:DgVoodooVersion archive is missing: $ArchivePath"
    }
    $file = Get-Item -LiteralPath $ArchivePath
    if ($file.Length -ne $script:ExpectedArchiveSize) {
        throw "dgVoodoo2 archive size mismatch. Expected $script:ExpectedArchiveSize bytes but found $($file.Length) at '$ArchivePath'."
    }
    $archiveHash = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    if ($archiveHash -ne $script:ExpectedArchiveSha256) {
        throw "dgVoodoo2 archive hash mismatch. Expected $script:ExpectedArchiveSha256 but found $archiveHash at '$ArchivePath'."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $proxyBytes = Read-ZipEntryBytes -Archive $archive -EntryName $script:ProxyEntryName -ExpectedSize $script:ExpectedProxySize
        $defaultConfigBytes = Read-ZipEntryBytes -Archive $archive -EntryName $script:DefaultConfigEntryName -ExpectedSize $script:ExpectedDefaultConfigSize
    }
    finally {
        $archive.Dispose()
    }

    $proxyHash = Get-ByteArraySha256 -Bytes $proxyBytes
    if ($proxyHash -ne $script:ExpectedProxySha256) {
        throw "Pinned dgVoodoo2 x86 D3D9 proxy hash mismatch. Expected $script:ExpectedProxySha256 but found $proxyHash."
    }
    $defaultConfigHash = Get-ByteArraySha256 -Bytes $defaultConfigBytes
    if ($defaultConfigHash -ne $script:ExpectedDefaultConfigSha256) {
        throw "Pinned dgVoodoo2 default config hash mismatch. Expected $script:ExpectedDefaultConfigSha256 but found $defaultConfigHash."
    }
    $peIdentity = Get-PeIdentityFromBytes -Bytes $proxyBytes -Description 'Pinned dgVoodoo2 x86 D3D9 proxy'
    if ($peIdentity.Machine -ne 0x014C -or $peIdentity.Magic -ne 0x010B) {
        throw "Pinned dgVoodoo2 proxy is not a 32-bit x86 PE image (machine 0x014C, PE32 magic 0x010B required)."
    }
    $defaultConfigText = [Text.Encoding]::ASCII.GetString($defaultConfigBytes)
    if ($defaultConfigText -notmatch '(?m)^Version\s*=\s*0x287\s*$') {
        throw "Pinned dgVoodoo2 archive does not declare config version $script:DgVoodooConfigVersion."
    }

    return [pscustomobject]@{
        Version                    = $script:DgVoodooVersion
        ConfigVersion              = $script:DgVoodooConfigVersion
        ArchivePath                = [IO.Path]::GetFullPath($ArchivePath)
        ArchiveSize                = $file.Length
        ArchiveSha256              = $archiveHash
        ProxyEntry                 = $script:ProxyEntryName
        ProxyFileName              = 'd3d9.dll'
        ProxySize                  = $proxyBytes.Length
        ProxySha256                = $proxyHash
        ProxyMachine               = $peIdentity.Machine
        ProxyOptionalHeaderMagic   = $peIdentity.Magic
        DefaultConfigEntry         = $script:DefaultConfigEntryName
        DefaultConfigSize          = $defaultConfigBytes.Length
        DefaultConfigSha256        = $defaultConfigHash
    }
}

function Get-FearDgVoodooRequiredConfigSettings {
    param(
        [ValidateSet('Native', 'Max2x')]
        [string]$RendererQuality = 'Native'
    )

    return [ordered]@{
        'Root.Version'                              = '0x287'
        'General.OutputAPI'                         = 'd3d11_fl11_0'
        'General.Adapters'                          = 'all'
        'General.FullScreenOutput'                  = 'default'
        'General.FullScreenMode'                    = 'true'
        'General.ScalingMode'                       = 'unspecified'
        'General.KeepWindowAspectRatio'             = 'true'
        'GeneralExt.Resampling'                     = 'lanczos-3'
        'GeneralExt.PresentationModel'              = 'auto'
        'GeneralExt.ColorSpace'                     = 'appdriven'
        'GeneralExt.FPSLimit'                       = '0'
        'DirectX.DisableAndPassThru'                = 'false'
        'DirectX.VideoCard'                         = 'internal3D'
        'DirectX.VRAM'                              = '256'
        'DirectX.Filtering'                         = 'appdriven'
        'DirectX.Mipmapping'                        = 'appdriven'
        'DirectX.Resolution'                        = if ($RendererQuality -eq 'Max2x') { 'max_2x' } else { 'unforced' }
        'DirectX.Antialiasing'                      = 'appdriven'
        'DirectX.AppControlledScreenMode'           = 'true'
        'DirectX.DisableAltEnterToToggleScreenMode' = 'true'
        'DirectX.ForceVerticalSync'                 = 'false'
        'DirectX.dgVoodooWatermark'                 = 'false'
        'DirectX.FastVideoMemoryAccess'             = 'false'
    }
}

function Get-FearDgVoodooConfigIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,

        [ValidateSet('Native', 'Max2x')]
        [string]$RendererQuality = 'Native'
    )

    $settings = Read-StrictIniSettings -Path $Path
    $required = Get-FearDgVoodooRequiredConfigSettings -RendererQuality $RendererQuality
    if ($settings.Count -ne $required.Count) {
        throw "FearMore dgVoodoo2 config must contain exactly $($required.Count) active settings; found $($settings.Count): $Path"
    }
    foreach ($setting in $required.GetEnumerator()) {
        if (-not $settings.ContainsKey($setting.Key) -or $settings[$setting.Key] -cne $setting.Value) {
            throw "FearMore dgVoodoo2 config requires $($setting.Key) = $($setting.Value): $Path"
        }
    }

    return [pscustomobject]@{
        Path          = [IO.Path]::GetFullPath($Path)
        Sha256        = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        ConfigVersion = $script:DgVoodooConfigVersion
        RendererQuality = $RendererQuality
        OutputAPI     = $settings['General.OutputAPI']
        Resolution    = $settings['DirectX.Resolution']
        ScalingMode   = $settings['General.ScalingMode']
        Resampling    = $settings['GeneralExt.Resampling']
        Filtering     = $settings['DirectX.Filtering']
        Antialiasing  = $settings['DirectX.Antialiasing']
        VRAM          = [int]$settings['DirectX.VRAM']
        FPSLimit      = [int]$settings['GeneralExt.FPSLimit']
        ForceVerticalSync = [bool]::Parse($settings['DirectX.ForceVerticalSync'])
    }
}

function Get-FearRtxRemixBridgeConfigIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "FearMore RTX Remix bridge config is missing: $Path"
    }

    $activeSettings = [Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) {
            continue
        }
        if ($trimmed -notmatch '^([^=]+?)\s*=\s*(.*?)\s*$') {
            throw "FearMore RTX Remix bridge config contains an unrecognized active line: $line"
        }
        $activeSettings.Add([pscustomobject]@{
            Name  = $Matches[1].Trim()
            Value = $Matches[2].Trim()
        })
    }

    if ($activeSettings.Count -ne 1 -or
        $activeSettings[0].Name -cne 'client.forceWindowed' -or
        $activeSettings[0].Value -cne 'False') {
        throw "FearMore RTX Remix bridge config must contain exactly 'client.forceWindowed = False' as its only active setting: $Path"
    }

    $file = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Path          = [IO.Path]::GetFullPath($Path)
        Size          = $file.Length
        Sha256        = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        ForceWindowed = $false
    }
}

function Get-FearRtxRemixRuntimeConfigActiveSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing: $Path"
    }

    $activeSettings = [Collections.Generic.List[object]]::new()
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith('#') -or $trimmed.StartsWith(';')) {
            continue
        }
        if ($trimmed -notmatch '^([^=]+?)\s*=\s*(.*?)\s*$') {
            throw "$Description contains an unrecognized active line: $line"
        }
        $activeSettings.Add([pscustomobject]@{
            Name  = $Matches[1].Trim()
            Value = $Matches[2].Trim()
        })
    }
    return @($activeSettings)
}

function Get-FearRtxRemixRuntimeConfigSafetyIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowNull()][string]$UserConfigPath
    )

    $runtimeSettings = @(Get-FearRtxRemixRuntimeConfigActiveSettings `
            -Path $Path `
            -Description 'FearMore live RTX Remix runtime config')
    $resolvedUserConfigPath = $null
    $userConfigPresent = $false
    $userSettings = @()
    $userConfigItem = $null
    if (-not [string]::IsNullOrWhiteSpace($UserConfigPath)) {
        $resolvedUserConfigPath = [IO.Path]::GetFullPath($UserConfigPath)
        if (Test-Path -LiteralPath $resolvedUserConfigPath) {
            if (-not (Test-Path -LiteralPath $resolvedUserConfigPath -PathType Leaf)) {
                throw "FearMore RTX Remix user config must be an ordinary file when present: $resolvedUserConfigPath"
            }
            $userConfigItem = Get-Item -LiteralPath $resolvedUserConfigPath -Force
            if (($userConfigItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "FearMore RTX Remix user config must not be a reparse point: $resolvedUserConfigPath"
            }
            $userSettings = @(Get-FearRtxRemixRuntimeConfigActiveSettings `
                    -Path $resolvedUserConfigPath `
                    -Description 'FearMore RTX Remix user config')
            $userConfigPresent = $true
        }
    }

    $effectiveSettings = @{}
    foreach ($requiredSetting in @(
            [pscustomobject]@{ Name='rtx.graphicsPreset'; Value='4' },
            [pscustomobject]@{ Name='rtx.integrateIndirectMode'; Value='1' },
            [pscustomobject]@{ Name='rtx.dlfg.enable'; Value='False' }
        )) {
        $runtimeMatches = @($runtimeSettings | Where-Object { $_.Name -ceq $requiredSetting.Name })
        $userMatches = @($userSettings | Where-Object { $_.Name -ceq $requiredSetting.Name })
        if ($runtimeMatches.Count -gt 1 -or $userMatches.Count -gt 1) {
            throw "FearMore RTX Remix configuration contains duplicate '$($requiredSetting.Name)' settings; effective launch safety is ambiguous."
        }
        $effectiveSetting = if ($userMatches.Count -eq 1) { $userMatches[0] } elseif ($runtimeMatches.Count -eq 1) { $runtimeMatches[0] } else { $null }
        if ($null -eq $effectiveSetting -or $effectiveSetting.Value -cne $requiredSetting.Value) {
            $userLayerNote = if ($userConfigPresent) { " after applying higher-priority user.conf '$resolvedUserConfigPath'" } else { '' }
            throw "FearMore effective RTX Remix configuration$userLayerNote must keep 'rtx.graphicsPreset = 4' (Custom), 'rtx.integrateIndirectMode = 1' (ReSTIR GI), and 'rtx.dlfg.enable = False'; stock graphics presets can re-enable the crashing NRC path: $Path"
        }
        $effectiveSettings[$requiredSetting.Name] = [pscustomobject]@{
            Value  = $effectiveSetting.Value
            Source = if ($userMatches.Count -eq 1) { 'user.conf' } else { 'rtx.conf' }
        }
    }

    $file = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Path                    = [IO.Path]::GetFullPath($Path)
        Size                    = $file.Length
        Sha256                  = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        ActiveSettingCount      = $runtimeSettings.Count
        GraphicsPreset          = 4
        GraphicsPresetName      = 'Custom'
        GraphicsPresetSource    = $effectiveSettings['rtx.graphicsPreset'].Source
        IntegrateIndirectMode   = 1
        IndirectLightingBackend = 'ReSTIR GI (pinned Remix 1.5.2)'
        IntegrateIndirectModeSource = $effectiveSettings['rtx.integrateIndirectMode'].Source
        DlssFrameGenerationEnabled = $false
        DlssFrameGenerationSource = $effectiveSettings['rtx.dlfg.enable'].Source
        UserConfigPath          = $resolvedUserConfigPath
        UserConfigPresent       = $userConfigPresent
        UserConfigSize          = if ($userConfigPresent) { $userConfigItem.Length } else { 0 }
        UserConfigSha256        = if ($userConfigPresent) { (Get-FileHash -LiteralPath $resolvedUserConfigPath -Algorithm SHA256).Hash } else { $null }
        SafeForFearMoreLaunch   = $true
    }
}

function Get-FearRtxRemixRuntimeConfigSeedIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $activeSettings = @(Get-FearRtxRemixRuntimeConfigActiveSettings `
            -Path $Path `
            -Description 'FearMore RTX Remix runtime config seed')

    $graphicsPresetSettings = @($activeSettings | Where-Object { $_.Name -ceq 'rtx.graphicsPreset' })
    $integrateIndirectSettings = @($activeSettings | Where-Object { $_.Name -ceq 'rtx.integrateIndirectMode' })
    $frameGenerationSettings = @($activeSettings | Where-Object { $_.Name -ceq 'rtx.dlfg.enable' })
    if ($activeSettings.Count -ne 3 -or
        $graphicsPresetSettings.Count -ne 1 -or $graphicsPresetSettings[0].Value -cne '4' -or
        $integrateIndirectSettings.Count -ne 1 -or $integrateIndirectSettings[0].Value -cne '1' -or
        $frameGenerationSettings.Count -ne 1 -or $frameGenerationSettings[0].Value -cne 'False') {
        throw "FearMore RTX Remix runtime config seed must contain exactly 'rtx.graphicsPreset = 4', 'rtx.integrateIndirectMode = 1', and 'rtx.dlfg.enable = False': $Path"
    }

    $file = Get-Item -LiteralPath $Path
    return [pscustomobject]@{
        Path                    = [IO.Path]::GetFullPath($Path)
        Size                    = $file.Length
        Sha256                  = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
        GraphicsPreset          = 4
        GraphicsPresetName      = 'Custom'
        IntegrateIndirectMode   = 1
        IndirectLightingBackend = 'ReSTIR GI (pinned Remix 1.5.2)'
        DlssFrameGenerationEnabled = $false
    }
}

Export-ModuleMember -Function Get-FearDgVoodooPackageIdentity, Get-FearDgVoodooConfigIdentity, Get-FearRtxRemixPackageIdentity, Get-FearRtxRemixBridgeConfigIdentity, Get-FearRtxRemixRuntimeConfigSeedIdentity, Get-FearRtxRemixRuntimeConfigSafetyIdentity, Test-FearRendererArchiveEntryPath
