Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:MaximumSetupBytes = 536870912
$script:MaximumPayloadBytes = 67108864
$script:ReShadeVersion = '6.7.3'
$script:ReShadeSetupName = 'ReShade_Setup_6.7.3.exe'
$script:ReShadeDownloadUri = 'https://reshade.me/downloads/ReShade_Setup_6.7.3.exe'
$script:ExpectedSetupSize = 3982792
$script:ExpectedSetupSha256 = '56791FD065358E899C581EBEFE2AD871399B7C7AE83FB85E1154C08A75A44147'
$script:ExpectedReShade32Size = 4015384
$script:ExpectedReShade32Sha256 = 'B63DF921946967D2CD8DDB1BF8A5F66B4F3C9B269A5F4EA8BA49B6DBA330658B'
$script:ExpectedReShade64Size = 5157144
$script:ExpectedReShade64Sha256 = '059168B9D8AAA694A02A64342409FA26DFDF335035F2C0184CC61581DEFFC3BC'
$script:ExpectedSignerCertificateThumbprint = '589690208A5E52FB96980C4A6698F50ACD47C49F'
$script:ExpectedEmbeddedZipOffset = 154112
$script:ExpectedEmbeddedZipSize = 3820715
$script:ExpectedEmbeddedZipEntryCount = 6
$script:ExpectedCertificateAlignmentPadding = 5
$script:ExpectedCertificateTableOffset = 3974832
$script:ExpectedCertificateTableSize = 7960
$script:ExpectedAssetDirectories = @('config', 'licenses', 'Shaders')
$script:ExpectedAssetRecords = @(
    [pscustomobject]@{ RelativePath = 'config\FearMore-CAS.seed.ini'; Sha256 = 'DD1F87434CDFA78FD7C55BCD61F2887C3DF8212F64273347CC0428CBD78F072D' },
    [pscustomobject]@{ RelativePath = 'config\ReShade.seed.ini'; Sha256 = '864358B2D4246B54BBAAF9071D37CD2D603BFEDDDB01975E7BE7C1E9E23B55A3' },
    [pscustomobject]@{ RelativePath = 'licenses\AMD-CAS-MIT.txt'; Sha256 = 'A963DCD0FD24AEEB870F2DB34AACE2BB4663E5CAE6BBA91B1147D0FDD5B8A863' },
    [pscustomobject]@{ RelativePath = 'licenses\ReShade-BSD-3-Clause.txt'; Sha256 = '653EF2E7E7EBA3332F2EC6E820954F8650A776316E26ACD3A8DBC05B8F39D87E' },
    [pscustomobject]@{ RelativePath = 'Shaders\FearMoreCAS.fx'; Sha256 = 'D5D90493CE4BD273D488029CEBFEC48420A7F03221B1232DEE315FA917344D0B' }
)

function Get-FearPostProcessPackageMetadata {
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Provider                    = 'ReShade'
        Version                     = $script:ReShadeVersion
        SetupName                   = $script:ReShadeSetupName
        DownloadUri                 = $script:ReShadeDownloadUri
        SetupSize                   = $script:ExpectedSetupSize
        SetupSha256                 = $script:ExpectedSetupSha256
        SignerCertificateThumbprint = $script:ExpectedSignerCertificateThumbprint
        ProjectPage                 = 'https://reshade.me/'
        RedistributionPolicy        = 'OfficialDownloadOnly'
    }
}

function Get-FearPostProcessByteSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-FearPostProcessPeIdentity {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if ($Bytes.Length -lt 256 -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) {
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

function Get-FearPostProcessEmbeddedZip {
    param([Parameter(Mandatory = $true)][byte[]]$SetupBytes)

    if ($SetupBytes.Length -lt 278) {
        throw 'ReShade setup is too small to contain a PE image and appended ZIP payload.'
    }

    $peOffset = [BitConverter]::ToInt32($SetupBytes, 0x3C)
    $optionalHeaderOffset = $peOffset + 24
    $optionalHeaderMagic = [BitConverter]::ToUInt16($SetupBytes, $optionalHeaderOffset)
    if ($optionalHeaderMagic -eq 0x010B) {
        $dataDirectoryOffset = $optionalHeaderOffset + 96
    }
    elseif ($optionalHeaderMagic -eq 0x020B) {
        $dataDirectoryOffset = $optionalHeaderOffset + 112
    }
    else {
        throw 'ReShade setup has an unsupported PE optional-header magic value.'
    }
    $securityDirectoryOffset = $dataDirectoryOffset + 32
    if (($securityDirectoryOffset + 8) -gt $SetupBytes.Length) {
        throw 'ReShade setup PE security directory is outside the file.'
    }

    $certificateOffset = [long][BitConverter]::ToUInt32($SetupBytes, $securityDirectoryOffset)
    $certificateSize = [long][BitConverter]::ToUInt32($SetupBytes, $securityDirectoryOffset + 4)
    if (($certificateOffset -eq 0) -xor ($certificateSize -eq 0)) {
        throw 'ReShade setup PE certificate-table offset and size must either both be zero or both be present.'
    }
    if ($certificateOffset -eq 0) {
        $zipContainerEnd = [long]$SetupBytes.LongLength
    }
    else {
        if (($certificateOffset % 8) -ne 0 -or $certificateSize -lt 8 -or
            ($certificateOffset + $certificateSize) -ne $SetupBytes.LongLength) {
            throw 'ReShade setup PE certificate table is not a valid aligned end-of-file range.'
        }
        $declaredCertificateLength = [long][BitConverter]::ToUInt32($SetupBytes, [int]$certificateOffset)
        if ($declaredCertificateLength -lt 8 -or $declaredCertificateLength -gt $certificateSize) {
            throw 'ReShade setup PE certificate table has an invalid WIN_CERTIFICATE length.'
        }
        $zipContainerEnd = $certificateOffset
    }

    $searchStart = [Math]::Max(0, $zipContainerEnd - 65557)
    for ($offset = $zipContainerEnd - 22; $offset -ge $searchStart; $offset--) {
        if ($SetupBytes[$offset] -ne 0x50 -or $SetupBytes[$offset + 1] -ne 0x4B -or
            $SetupBytes[$offset + 2] -ne 0x05 -or $SetupBytes[$offset + 3] -ne 0x06) {
            continue
        }

        $commentLength = [BitConverter]::ToUInt16($SetupBytes, $offset + 20)
        $zipEnd = [long]$offset + 22 + $commentLength
        $alignmentPadding = $zipContainerEnd - $zipEnd
        $maximumAlignmentPadding = if ($certificateOffset -eq 0) { 0 } else { 7 }
        if ($alignmentPadding -lt 0 -or $alignmentPadding -gt $maximumAlignmentPadding) {
            continue
        }
        $paddingIsZero = $true
        for ($paddingOffset = $zipEnd; $paddingOffset -lt $zipContainerEnd; $paddingOffset++) {
            if ($SetupBytes[$paddingOffset] -ne 0) {
                $paddingIsZero = $false
                break
            }
        }
        if (-not $paddingIsZero) {
            continue
        }

        $diskNumber = [BitConverter]::ToUInt16($SetupBytes, $offset + 4)
        $centralDirectoryDisk = [BitConverter]::ToUInt16($SetupBytes, $offset + 6)
        $entriesOnDisk = [BitConverter]::ToUInt16($SetupBytes, $offset + 8)
        $totalEntries = [BitConverter]::ToUInt16($SetupBytes, $offset + 10)
        $centralDirectorySize = [BitConverter]::ToUInt32($SetupBytes, $offset + 12)
        $centralDirectoryOffset = [BitConverter]::ToUInt32($SetupBytes, $offset + 16)
        if ($diskNumber -ne 0 -or $centralDirectoryDisk -ne 0 -or
            $entriesOnDisk -ne $totalEntries -or $totalEntries -eq 0 -or
            $totalEntries -eq 0xFFFF -or $centralDirectorySize -eq 0xFFFFFFFF -or
            $centralDirectoryOffset -eq 0xFFFFFFFF) {
            throw 'ReShade setup embedded ZIP must be a non-ZIP64, single-disk archive.'
        }

        $zipOffset = [long]$offset - [long]$centralDirectorySize - [long]$centralDirectoryOffset
        if ($zipOffset -le 0 -or
            ($zipOffset + $centralDirectoryOffset + $centralDirectorySize) -ne $offset -or
            ($zipOffset + 4) -gt $SetupBytes.LongLength) {
            throw 'ReShade setup embedded ZIP central-directory offsets are invalid.'
        }
        if ($SetupBytes[$zipOffset] -ne 0x50 -or $SetupBytes[$zipOffset + 1] -ne 0x4B -or
            $SetupBytes[$zipOffset + 2] -ne 0x03 -or $SetupBytes[$zipOffset + 3] -ne 0x04) {
            throw 'ReShade setup embedded ZIP does not begin with a local-file header.'
        }

        $zipLength = [int]($zipEnd - $zipOffset)
        $zipBytes = [byte[]]::new($zipLength)
        [Buffer]::BlockCopy($SetupBytes, [int]$zipOffset, $zipBytes, 0, $zipLength)
        return [pscustomobject]@{
            Offset                 = $zipOffset
            Length                 = $zipLength
            EntryCount             = [int]$totalEntries
            CertificateAlignmentPadding = [int]$alignmentPadding
            CertificateTableOffset = $certificateOffset
            CertificateTableSize   = $certificateSize
            Bytes                  = $zipBytes
        }
    }

    throw 'ReShade setup does not contain a valid appended ZIP end-of-central-directory record.'
}

function Read-FearPostProcessZipEntryBytes {
    param(
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)][string]$EntryName
    )

    $matches = @($Archive.Entries | Where-Object { $_.FullName -ceq $EntryName })
    if ($matches.Count -ne 1) {
        throw "ReShade setup embedded ZIP must contain exactly one '$EntryName' entry; found $($matches.Count)."
    }
    $entry = $matches[0]
    if ($entry.FullName.EndsWith('/') -or $entry.Length -le 0 -or $entry.Length -gt $script:MaximumPayloadBytes) {
        throw "ReShade setup '$EntryName' entry has an invalid payload size: $($entry.Length)."
    }

    $stream = $entry.Open()
    try {
        $memory = [IO.MemoryStream]::new()
        try {
            $stream.CopyTo($memory)
            $bytes = $memory.ToArray()
        }
        finally {
            $memory.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
    if ($bytes.LongLength -ne $entry.Length) {
        throw "ReShade setup '$EntryName' entry ended before its declared length."
    }
    return $bytes
}

function Get-FearPostProcessIniSettings {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $settings = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $section = 'Root'
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction Stop) {
        $trimmed = $line.Trim()
        if ($trimmed.Length -eq 0 -or $trimmed.StartsWith(';') -or $trimmed.StartsWith('#')) {
            continue
        }
        if ($trimmed -match '^\[([^\]]+)\]$') {
            $section = $Matches[1].Trim()
            if ([string]::IsNullOrWhiteSpace($section)) {
                throw "$Description contains an empty section name: $Path"
            }
            continue
        }
        if ($trimmed -notmatch '^([^=]+?)\s*=\s*(.*?)\s*$') {
            throw "$Description contains an unrecognized active line: $line"
        }
        $key = $Matches[1].Trim()
        if ([string]::IsNullOrWhiteSpace($key)) {
            throw "$Description contains an empty setting name: $line"
        }
        $qualifiedName = "$section.$key"
        if ($settings.ContainsKey($qualifiedName)) {
            throw "$Description contains a duplicate active setting: $qualifiedName"
        }
        $settings[$qualifiedName] = $Matches[2].Trim()
    }
    return $settings
}

function Assert-FearPostProcessExactSettings {
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)]$Required,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Path
    )

    if ($Settings.Count -ne $Required.Count) {
        throw "$Description must contain exactly $($Required.Count) active settings; found $($Settings.Count): $Path"
    }
    foreach ($setting in $Required.GetEnumerator()) {
        if (-not $Settings.ContainsKey($setting.Key) -or $Settings[$setting.Key] -cne $setting.Value) {
            throw "$Description requires '$($setting.Key) = $($setting.Value)': $Path"
        }
    }
}

function Get-FearPostProcessAssetIdentity {
    param([Parameter(Mandatory = $true)][string]$AssetRoot)

    $fullAssetRoot = [IO.Path]::GetFullPath($AssetRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $fullAssetRoot -PathType Container)) {
        throw "FearMore post-process asset root is missing: $fullAssetRoot"
    }
    $rootItem = Get-Item -LiteralPath $fullAssetRoot -Force -ErrorAction Stop
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "FearMore post-process asset root must not be a reparse point: $fullAssetRoot"
    }

    $rootPrefix = $fullAssetRoot + '\'
    $actualDirectories = [Collections.Generic.List[string]]::new()
    $actualFiles = [Collections.Generic.List[object]]::new()
    foreach ($item in @(Get-ChildItem -LiteralPath $fullAssetRoot -Recurse -Force -ErrorAction Stop)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "FearMore post-process assets must not contain reparse points: $($item.FullName)"
        }
        if (-not $item.FullName.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "FearMore post-process asset escapes its root: $($item.FullName)"
        }
        $relativePath = $item.FullName.Substring($rootPrefix.Length)
        if ($item.PSIsContainer) {
            $actualDirectories.Add($relativePath)
            continue
        }
        $actualFiles.Add([pscustomobject]@{
            RelativePath = $relativePath
            FullPath     = $item.FullName
            Size         = [long]$item.Length
            Sha256       = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
        })
    }

    $orderedActualDirectories = @($actualDirectories | Sort-Object)
    $orderedExpectedDirectories = @($script:ExpectedAssetDirectories | Sort-Object)
    if (($orderedActualDirectories -join '|') -cne ($orderedExpectedDirectories -join '|')) {
        throw "FearMore post-process asset directory layout mismatch. Expected '$($orderedExpectedDirectories -join ', ')' but found '$($orderedActualDirectories -join ', ')': $fullAssetRoot"
    }
    if ($actualFiles.Count -ne $script:ExpectedAssetRecords.Count) {
        throw "FearMore post-process asset file-count mismatch. Expected $($script:ExpectedAssetRecords.Count) files but found $($actualFiles.Count): $fullAssetRoot"
    }

    $validatedFiles = [Collections.Generic.List[object]]::new()
    foreach ($expected in $script:ExpectedAssetRecords) {
        $matches = @($actualFiles | Where-Object { $_.RelativePath -ceq $expected.RelativePath })
        if ($matches.Count -ne 1) {
            throw "FearMore post-process asset package must contain exactly one '$($expected.RelativePath)' file; found $($matches.Count)."
        }
        if ($matches[0].Sha256 -cne $expected.Sha256) {
            throw "FearMore post-process asset hash mismatch for '$($expected.RelativePath)'. Expected $($expected.Sha256) but found $($matches[0].Sha256)."
        }
        $validatedFiles.Add($matches[0])
    }

    $shaderPath = Join-Path $fullAssetRoot 'Shaders\FearMoreCAS.fx'
    $shader = Get-Content -LiteralPath $shaderPath -Raw -ErrorAction Stop
    foreach ($requiredToken in @(
            'texture2D FearMoreBackBuffer : COLOR;',
            'uniform float FearMoreSharpness',
            'ui_type = "slider";',
            'BUFFER_RCP_WIDTH',
            'BUFFER_RCP_HEIGHT',
            '9fabcc9a2c45f958aff55ddfda337e74ef894b7f',
            'CAS_BETTER_DIAGONALS',
            'const float3 softMinimum = crossMinimum + boxMinimum;',
            'const float3 softMaximum = crossMaximum + boxMaximum;',
            'technique FearMoreCAS',
            'SPDX-License-Identifier: MIT')) {
        if (-not $shader.Contains($requiredToken)) {
            throw "FearMore CAS shader is missing required token '$requiredToken': $shaderPath"
        }
    }
    if ($shader -match ':\s*DEPTH\b' -or
        $shader -match '(?<!\d)(1920|2560|3440|1080|1440)(?!\d)' -or
        $shader -notmatch '(?s)uniform\s+float\s+FearMoreSharpness\s*<.*?>\s*=\s*0\.25\s*;') {
        throw "FearMore CAS shader must remain color-only, aspect-independent, and conservatively defaulted to 0.25: $shaderPath"
    }

    $reshadeSeedPath = Join-Path $fullAssetRoot 'config\ReShade.seed.ini'
    $reshadeSeedSettings = Get-FearPostProcessIniSettings -Path $reshadeSeedPath -Description 'FearMore ReShade config seed'
    $requiredReShadeSeedSettings = [ordered]@{
        'GENERAL.EffectSearchPaths'     = '.\.fearmore\postprocess\Shaders'
        'GENERAL.IntermediateCachePath' = '.\.fearmore\postprocess\Cache'
        'GENERAL.PerformanceMode'       = '0'
        'GENERAL.PresetPath'            = '.\FearMore-CAS.ini'
        'GENERAL.TextureSearchPaths'    = ''
        'INPUT.KeyEffects'              = '145,0,0,0'
        'INPUT.KeyOverlay'              = '36,0,0,0'
        'OVERLAY.TutorialProgress'      = '4'
    }
    Assert-FearPostProcessExactSettings -Settings $reshadeSeedSettings -Required $requiredReShadeSeedSettings -Description 'FearMore ReShade config seed' -Path $reshadeSeedPath

    $casPresetPath = Join-Path $fullAssetRoot 'config\FearMore-CAS.seed.ini'
    $casPresetSettings = Get-FearPostProcessIniSettings -Path $casPresetPath -Description 'FearMore CAS preset seed'
    $requiredCasPresetSettings = [ordered]@{
        'Root.Techniques'                    = 'FearMoreCAS@FearMoreCAS.fx'
        'Root.TechniqueSorting'              = 'FearMoreCAS@FearMoreCAS.fx'
        'FearMoreCAS.fx.FearMoreSharpness'   = '0.250000'
    }
    Assert-FearPostProcessExactSettings -Settings $casPresetSettings -Required $requiredCasPresetSettings -Description 'FearMore CAS preset seed' -Path $casPresetPath

    $amdLicensePath = Join-Path $fullAssetRoot 'licenses\AMD-CAS-MIT.txt'
    $amdLicense = Get-Content -LiteralPath $amdLicensePath -Raw -ErrorAction Stop
    if (-not $amdLicense.Contains('Advanced Micro Devices, Inc.') -or
        -not $amdLicense.Contains('Permission is hereby granted, free of charge') -or
        -not $amdLicense.Contains('https://github.com/GPUOpen-Effects/FidelityFX-CAS')) {
        throw "FearMore AMD CAS notice is incomplete: $amdLicensePath"
    }

    $reshadeLicensePath = Join-Path $fullAssetRoot 'licenses\ReShade-BSD-3-Clause.txt'
    $reshadeLicense = Get-Content -LiteralPath $reshadeLicensePath -Raw -ErrorAction Stop
    if (-not $reshadeLicense.Contains('Copyright 2014 Patrick Mours') -or
        -not $reshadeLicense.Contains('Redistribution and use in source and binary forms') -or
        -not $reshadeLicense.Contains('https://github.com/crosire/reshade')) {
        throw "FearMore ReShade notice is incomplete: $reshadeLicensePath"
    }

    return [pscustomobject]@{
        Root                     = $fullAssetRoot
        FileCount                = $validatedFiles.Count
        Files                    = @($validatedFiles | Sort-Object RelativePath)
        ShaderRelativePath       = 'Shaders\FearMoreCAS.fx'
        ReShadeSeedRelativePath  = 'config\ReShade.seed.ini'
        CasPresetRelativePath    = 'config\FearMore-CAS.seed.ini'
        AmdLicenseRelativePath   = 'licenses\AMD-CAS-MIT.txt'
        ReShadeLicenseRelativePath = 'licenses\ReShade-BSD-3-Clause.txt'
        ColorOnly                = $true
        UsesDepth                = $false
        PerformsScaling          = $false
        DefaultSharpness         = 0.25
    }
}

function Get-FearPostProcessPackageIdentityCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SetupPath,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedSetupSha256,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedReShade32Sha256,
        [Parameter(Mandatory = $true)][string]$AssetRoot,
        [ValidatePattern('^[0-9A-Fa-f]{40}$')][string]$ExpectedSignerCertificateThumbprint,
        [switch]$IncludeStageProxyBytes
    )

    $fullSetupPath = [IO.Path]::GetFullPath($SetupPath)
    if (-not (Test-Path -LiteralPath $fullSetupPath -PathType Leaf)) {
        throw "User-supplied official ReShade setup is missing: $fullSetupPath"
    }
    if ([IO.Path]::GetExtension($fullSetupPath) -ine '.exe') {
        throw "User-supplied ReShade setup must be an EXE file: $fullSetupPath"
    }
    $setupItem = Get-Item -LiteralPath $fullSetupPath -Force -ErrorAction Stop
    if (($setupItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "User-supplied ReShade setup must not be a reparse point: $fullSetupPath"
    }
    if ($setupItem.Length -le 0 -or $setupItem.Length -gt $script:MaximumSetupBytes) {
        throw "User-supplied ReShade setup size is outside the supported validation range: $($setupItem.Length) bytes."
    }

    $expectedSetupHash = $ExpectedSetupSha256.ToUpperInvariant()
    $setupHash = (Get-FileHash -LiteralPath $fullSetupPath -Algorithm SHA256).Hash
    if ($setupHash -cne $expectedSetupHash) {
        throw "User-supplied ReShade setup hash mismatch. Expected $expectedSetupHash but found $setupHash at '$fullSetupPath'."
    }

    $signatureStatus = 'NotChecked'
    $signerThumbprint = $null
    $signerCertificateMatched = $false
    $signatureSystemTrustValidated = $false
    if ($PSBoundParameters.ContainsKey('ExpectedSignerCertificateThumbprint')) {
        $signature = Get-AuthenticodeSignature -LiteralPath $fullSetupPath
        $signatureStatus = [string]$signature.Status
        if ($null -eq $signature.SignerCertificate -or
            ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -and $signatureStatus -cne 'UnknownError')) {
            throw "User-supplied ReShade setup Authenticode signer cannot be validated; status is '$signatureStatus': $fullSetupPath"
        }
        $signerThumbprint = $signature.SignerCertificate.Thumbprint.Replace(' ', '').ToUpperInvariant()
        $expectedThumbprint = $ExpectedSignerCertificateThumbprint.ToUpperInvariant()
        if ($signerThumbprint -cne $expectedThumbprint) {
            throw "User-supplied ReShade setup signer mismatch. Expected $expectedThumbprint but found $signerThumbprint."
        }
        $signerCertificateMatched = $true
        $signatureSystemTrustValidated = $signature.Status -eq [Management.Automation.SignatureStatus]::Valid
    }

    $setupBytes = [IO.File]::ReadAllBytes($fullSetupPath)
    $setupPeIdentity = Get-FearPostProcessPeIdentity -Bytes $setupBytes -Description 'User-supplied ReShade setup'
    $embeddedZip = Get-FearPostProcessEmbeddedZip -SetupBytes $setupBytes

    Add-Type -AssemblyName System.IO.Compression
    $zipStream = [IO.MemoryStream]::new($embeddedZip.Bytes, $false)
    try {
        $archive = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Read, $false)
        try {
            if ($archive.Entries.Count -ne $embeddedZip.EntryCount) {
                throw "ReShade setup embedded ZIP entry-count mismatch. EOCD declares $($embeddedZip.EntryCount) but the archive exposes $($archive.Entries.Count)."
            }
            $reshade32Bytes = Read-FearPostProcessZipEntryBytes -Archive $archive -EntryName 'ReShade32.dll'
            $reshade64Bytes = Read-FearPostProcessZipEntryBytes -Archive $archive -EntryName 'ReShade64.dll'
        }
        finally {
            $archive.Dispose()
        }
    }
    catch [IO.InvalidDataException] {
        throw "User-supplied ReShade setup embedded ZIP is invalid: $($_.Exception.Message)"
    }
    finally {
        $zipStream.Dispose()
    }

    $reshade32Hash = Get-FearPostProcessByteSha256 -Bytes $reshade32Bytes
    $expectedReShade32Hash = $ExpectedReShade32Sha256.ToUpperInvariant()
    if ($reshade32Hash -cne $expectedReShade32Hash) {
        throw "User-supplied ReShade32 payload hash mismatch. Expected $expectedReShade32Hash but found $reshade32Hash."
    }
    $reshade32PeIdentity = Get-FearPostProcessPeIdentity -Bytes $reshade32Bytes -Description 'User-supplied ReShade32 payload'
    if ($reshade32PeIdentity.Machine -ne 0x014C -or $reshade32PeIdentity.Magic -ne 0x010B) {
        throw 'User-supplied ReShade32 payload is not a 32-bit x86 PE image (machine 0x014C, PE32 magic 0x010B required).'
    }
    $reshade64Hash = Get-FearPostProcessByteSha256 -Bytes $reshade64Bytes
    $reshade64PeIdentity = Get-FearPostProcessPeIdentity -Bytes $reshade64Bytes -Description 'User-supplied ReShade64 payload'
    if ($reshade64PeIdentity.Machine -ne 0x8664 -or $reshade64PeIdentity.Magic -ne 0x020B) {
        throw 'User-supplied ReShade64 payload is not a 64-bit x64 PE image (machine 0x8664, PE32+ magic 0x020B required).'
    }

    $assetIdentity = Get-FearPostProcessAssetIdentity -AssetRoot $AssetRoot
    return [pscustomobject]@{
        PackageName                    = 'FearMore ReShade CAS post-process package'
        ReShadeVersion                 = $null
        PinnedIdentity                 = $false
        PostProcessMode                = 'ReShadeCas'
        SetupPath                      = $fullSetupPath
        SetupSize                      = [long]$setupItem.Length
        SetupSha256                    = $setupHash
        SetupMachine                   = $setupPeIdentity.Machine
        SetupOptionalHeaderMagic       = $setupPeIdentity.Magic
        SignatureValidationRequested   = $PSBoundParameters.ContainsKey('ExpectedSignerCertificateThumbprint')
        SignerCertificateMatched       = $signerCertificateMatched
        SignatureSystemTrustValidated  = $signatureSystemTrustValidated
        SignatureStatus                = $signatureStatus
        SignerCertificateThumbprint    = $signerThumbprint
        EmbeddedZipOffset              = [long]$embeddedZip.Offset
        EmbeddedZipSize                = [long]$embeddedZip.Length
        EmbeddedZipEntryCount          = [int]$embeddedZip.EntryCount
        CertificateAlignmentPadding    = [int]$embeddedZip.CertificateAlignmentPadding
        CertificateTableOffset         = [long]$embeddedZip.CertificateTableOffset
        CertificateTableSize           = [long]$embeddedZip.CertificateTableSize
        ProxyEntry                     = 'ReShade32.dll'
        ProxyFileName                  = 'dxgi.dll'
        ProxyApi                       = 'DXGI'
        ProxySize                      = [long]$reshade32Bytes.Length
        ProxySha256                    = $reshade32Hash
        ProxyMachine                   = $reshade32PeIdentity.Machine
        ProxyOptionalHeaderMagic       = $reshade32PeIdentity.Magic
        CompanionEntry                 = 'ReShade64.dll'
        CompanionSize                  = [long]$reshade64Bytes.Length
        CompanionSha256                = $reshade64Hash
        CompanionMachine               = $reshade64PeIdentity.Machine
        CompanionOptionalHeaderMagic   = $reshade64PeIdentity.Magic
        Assets                         = $assetIdentity
        RuntimeConfigFileName          = 'ReShade.ini'
        RuntimePresetFileName          = 'FearMore-CAS.ini'
        RuntimeMutableFiles            = @('ReShade.ini', 'FearMore-CAS.ini', 'ReShade.log')
        RuntimeWritableDirectories     = @('.fearmore\postprocess\Cache')
        SeedPolicy                     = 'FirstEnableOnly'
        ValidationOnly                 = $true
        MutationPerformed              = $false
        StageProxyBytes                = if ($IncludeStageProxyBytes) { $reshade32Bytes } else { $null }
    }
}

function Complete-FearPostProcessPinnedIdentity {
    param([Parameter(Mandatory = $true)]$Identity)

    $requiredIdentity = [ordered]@{
        SetupSize                       = [long]$script:ExpectedSetupSize
        SetupMachine                    = [uint16]0x014C
        SetupOptionalHeaderMagic        = [uint16]0x010B
        EmbeddedZipOffset               = [long]$script:ExpectedEmbeddedZipOffset
        EmbeddedZipSize                 = [long]$script:ExpectedEmbeddedZipSize
        EmbeddedZipEntryCount           = [int]$script:ExpectedEmbeddedZipEntryCount
        CertificateAlignmentPadding     = [int]$script:ExpectedCertificateAlignmentPadding
        CertificateTableOffset          = [long]$script:ExpectedCertificateTableOffset
        CertificateTableSize            = [long]$script:ExpectedCertificateTableSize
        ProxySize                       = [long]$script:ExpectedReShade32Size
        ProxySha256                     = $script:ExpectedReShade32Sha256
        CompanionSize                   = [long]$script:ExpectedReShade64Size
        CompanionSha256                 = $script:ExpectedReShade64Sha256
        SignerCertificateThumbprint     = $script:ExpectedSignerCertificateThumbprint
        SignerCertificateMatched        = $true
    }
    foreach ($required in $requiredIdentity.GetEnumerator()) {
        if ($Identity.($required.Key) -cne $required.Value) {
            throw "Pinned ReShade $script:ReShadeVersion package identity mismatch for '$($required.Key)'. Expected '$($required.Value)' but found '$($Identity.($required.Key))'."
        }
    }

    $Identity.PackageName = "FearMore ReShade $script:ReShadeVersion CAS post-process package"
    $Identity.ReShadeVersion = $script:ReShadeVersion
    $Identity.PinnedIdentity = $true
    return $Identity
}

function Get-FearPostProcessPackageIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SetupPath,
        [Parameter(Mandatory = $true)][string]$AssetRoot
    )

    $identity = Get-FearPostProcessPackageIdentityCore `
        -SetupPath $SetupPath `
        -ExpectedSetupSha256 $script:ExpectedSetupSha256 `
        -ExpectedReShade32Sha256 $script:ExpectedReShade32Sha256 `
        -ExpectedSignerCertificateThumbprint $script:ExpectedSignerCertificateThumbprint `
        -AssetRoot $AssetRoot
    $identity = Complete-FearPostProcessPinnedIdentity -Identity $identity
    [void]$identity.PSObject.Properties.Remove('StageProxyBytes')
    return $identity
}

function Get-FearPostProcessPackageStagePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SetupPath,
        [Parameter(Mandatory = $true)][string]$AssetRoot
    )

    $identity = Get-FearPostProcessPackageIdentityCore `
        -SetupPath $SetupPath `
        -ExpectedSetupSha256 $script:ExpectedSetupSha256 `
        -ExpectedReShade32Sha256 $script:ExpectedReShade32Sha256 `
        -ExpectedSignerCertificateThumbprint $script:ExpectedSignerCertificateThumbprint `
        -AssetRoot $AssetRoot `
        -IncludeStageProxyBytes
    $identity = Complete-FearPostProcessPinnedIdentity -Identity $identity
    $proxyBytes = [byte[]]$identity.StageProxyBytes
    [void]$identity.PSObject.Properties.Remove('StageProxyBytes')

    $assetPayloads = [Collections.Generic.List[object]]::new()
    foreach ($asset in @($identity.Assets.Files | Sort-Object RelativePath)) {
        $bytes = [IO.File]::ReadAllBytes([string]$asset.FullPath)
        $sha256 = Get-FearPostProcessByteSha256 -Bytes $bytes
        if ($bytes.LongLength -ne [long]$asset.Size -or $sha256 -cne [string]$asset.Sha256) {
            throw "FearMore post-process asset changed after package validation: $($asset.RelativePath)"
        }
        $assetPayloads.Add([pscustomobject]@{
            SourceRelativePath = [string]$asset.RelativePath
            StageRelativePath  = ".fearmore\postprocess\$($asset.RelativePath)"
            Size               = [long]$asset.Size
            Sha256             = [string]$asset.Sha256
            Bytes              = $bytes
        })
    }

    if ($proxyBytes.LongLength -ne [long]$identity.ProxySize -or
        (Get-FearPostProcessByteSha256 -Bytes $proxyBytes) -cne [string]$identity.ProxySha256) {
        throw 'Pinned ReShade32 staging payload changed after package validation.'
    }
    return [pscustomobject]@{
        PackageIdentity  = $identity
        ProxyRelativePath = 'dxgi.dll'
        ProxyBytes       = $proxyBytes
        AssetFiles       = @($assetPayloads)
        ValidationOnly   = $true
        MutationPerformed = $false
    }
}

Export-ModuleMember -Function @(
    'Get-FearPostProcessPackageMetadata',
    'Get-FearPostProcessPackageIdentity',
    'Get-FearPostProcessPackageStagePayload'
)
