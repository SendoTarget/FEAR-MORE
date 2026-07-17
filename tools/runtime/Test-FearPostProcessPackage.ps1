[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $scriptRoot)
}

function Assert-FearPostProcessEqual {
    param(
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if ($Expected -cne $Actual) {
        throw "$Message Expected '$Expected' but found '$Actual'."
    }
}

function Assert-FearPostProcessTrue {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-FearPostProcessThrows {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$MessagePattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    try {
        & $Action
    }
    catch {
        if ($_.Exception.Message -notmatch $MessagePattern) {
            throw "$Description threw the wrong error. Expected /$MessagePattern/ but found '$($_.Exception.Message)'."
        }
        return
    }
    throw "$Description did not throw."
}

function Get-FearPostProcessTestByteSha256 {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha256.ComputeHash($Bytes))).Replace('-', '')
    }
    finally {
        $sha256.Dispose()
    }
}

function New-FearPostProcessSyntheticPeBytes {
    param(
        [Parameter(Mandatory = $true)][uint16]$Machine,
        [Parameter(Mandatory = $true)][uint16]$OptionalHeaderMagic
    )

    $bytes = [byte[]]::new(512)
    $bytes[0] = 0x4D
    $bytes[1] = 0x5A
    [Buffer]::BlockCopy([BitConverter]::GetBytes([int]0x80), 0, $bytes, 0x3C, 4)
    $bytes[0x80] = 0x50
    $bytes[0x81] = 0x45
    [Buffer]::BlockCopy([BitConverter]::GetBytes($Machine), 0, $bytes, 0x84, 2)
    [Buffer]::BlockCopy([BitConverter]::GetBytes([uint16]1), 0, $bytes, 0x86, 2)
    $optionalHeaderSize = if ($OptionalHeaderMagic -eq 0x020B) { [uint16]0x00F0 } else { [uint16]0x00E0 }
    [Buffer]::BlockCopy([BitConverter]::GetBytes($optionalHeaderSize), 0, $bytes, 0x94, 2)
    [Buffer]::BlockCopy([BitConverter]::GetBytes($OptionalHeaderMagic), 0, $bytes, 0x98, 2)
    $numberOfRvaAndSizesOffset = if ($OptionalHeaderMagic -eq 0x020B) { 0x98 + 108 } else { 0x98 + 92 }
    [Buffer]::BlockCopy([BitConverter]::GetBytes([uint32]16), 0, $bytes, $numberOfRvaAndSizesOffset, 4)
    return ,$bytes
}

function Add-FearPostProcessSyntheticZipEntry {
    param(
        [Parameter(Mandatory = $true)]$Archive,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][byte[]]$Bytes
    )

    $entry = $Archive.CreateEntry($Name, [IO.Compression.CompressionLevel]::NoCompression)
    $stream = $entry.Open()
    try {
        $stream.Write($Bytes, 0, $Bytes.Length)
    }
    finally {
        $stream.Dispose()
    }
}

function New-FearPostProcessSyntheticSetup {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][byte[]]$ReShade32Bytes,
        [Parameter(Mandatory = $true)][byte[]]$ReShade64Bytes,
        [switch]$OmitReShade32,
        [switch]$DuplicateReShade32
    )

    $setupPeBytes = [byte[]](New-FearPostProcessSyntheticPeBytes -Machine 0x014C -OptionalHeaderMagic 0x010B)
    $zipMemory = [IO.MemoryStream]::new()
    try {
        $archive = [IO.Compression.ZipArchive]::new($zipMemory, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            if (-not $OmitReShade32) {
                Add-FearPostProcessSyntheticZipEntry -Archive $archive -Name 'ReShade32.dll' -Bytes $ReShade32Bytes
            }
            if ($DuplicateReShade32) {
                Add-FearPostProcessSyntheticZipEntry -Archive $archive -Name 'ReShade32.dll' -Bytes $ReShade32Bytes
            }
            Add-FearPostProcessSyntheticZipEntry -Archive $archive -Name 'ReShade64.dll' -Bytes $ReShade64Bytes
        }
        finally {
            $archive.Dispose()
        }
        $zipBytes = $zipMemory.ToArray()
    }
    finally {
        $zipMemory.Dispose()
    }

    $setupBytes = [byte[]]::new($setupPeBytes.Length + $zipBytes.Length)
    [Buffer]::BlockCopy($setupPeBytes, 0, $setupBytes, 0, $setupPeBytes.Length)
    [Buffer]::BlockCopy($zipBytes, 0, $setupBytes, $setupPeBytes.Length, $zipBytes.Length)
    [IO.File]::WriteAllBytes($Path, $setupBytes)
    return $Path
}

Add-Type -AssemblyName System.IO.Compression

$fullRepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$modulePath = Join-Path $fullRepositoryRoot 'tools\runtime\FearPostProcessPackage.psm1'
$assetRoot = Join-Path $fullRepositoryRoot 'tools\runtime\postprocess'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "Post-process package module is missing: $modulePath"
}

$module = Import-Module -Name $modulePath -Force -PassThru
$exportedFunctions = @($module.ExportedFunctions.Keys | Sort-Object)
Assert-FearPostProcessEqual -Expected 'Get-FearPostProcessPackageIdentity,Get-FearPostProcessPackageMetadata,Get-FearPostProcessPackageStagePayload' -Actual ($exportedFunctions -join ',') -Message 'The module export surface changed.'
$metadata = Get-FearPostProcessPackageMetadata
Assert-FearPostProcessEqual -Expected '6.7.3' -Actual $metadata.Version -Message 'The ReShade acquisition version changed.'
Assert-FearPostProcessEqual -Expected 'ReShade_Setup_6.7.3.exe' -Actual $metadata.SetupName -Message 'The ReShade setup filename changed.'
Assert-FearPostProcessEqual -Expected 'https://reshade.me/downloads/ReShade_Setup_6.7.3.exe' -Actual $metadata.DownloadUri -Message 'The official ReShade download URI changed.'
Assert-FearPostProcessEqual -Expected 'OfficialDownloadOnly' -Actual $metadata.RedistributionPolicy -Message 'The ReShade redistribution policy changed.'
$coreCommand = & $module { Get-Command -Name Get-FearPostProcessPackageIdentityCore -CommandType Function }

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("FearPostProcessPackage-{0}" -f [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempRoot -Force)
try {
    $x86Bytes = [byte[]](New-FearPostProcessSyntheticPeBytes -Machine 0x014C -OptionalHeaderMagic 0x010B)
    $x64Bytes = [byte[]](New-FearPostProcessSyntheticPeBytes -Machine 0x8664 -OptionalHeaderMagic 0x020B)
    $x86Hash = Get-FearPostProcessTestByteSha256 -Bytes $x86Bytes
    $x64Hash = Get-FearPostProcessTestByteSha256 -Bytes $x64Bytes

    $validSetupPath = Join-Path $tempRoot 'ReShade_Setup.synthetic.exe'
    [void](New-FearPostProcessSyntheticSetup -Path $validSetupPath -ReShade32Bytes $x86Bytes -ReShade64Bytes $x64Bytes)
    $validSetupHash = (Get-FileHash -LiteralPath $validSetupPath -Algorithm SHA256).Hash
    $identity = & $coreCommand -SetupPath $validSetupPath -ExpectedSetupSha256 $validSetupHash -ExpectedReShade32Sha256 $x86Hash -AssetRoot $assetRoot

    Assert-FearPostProcessEqual -Expected 'ReShadeCas' -Actual $identity.PostProcessMode -Message 'Synthetic package mode is wrong.'
    Assert-FearPostProcessEqual -Expected 'ReShade32.dll' -Actual $identity.ProxyEntry -Message 'Synthetic x86 payload entry is wrong.'
    Assert-FearPostProcessEqual -Expected 'dxgi.dll' -Actual $identity.ProxyFileName -Message 'Synthetic proxy destination is wrong.'
    Assert-FearPostProcessEqual -Expected 'DXGI' -Actual $identity.ProxyApi -Message 'Synthetic proxy API is wrong.'
    Assert-FearPostProcessEqual -Expected 0x014C -Actual $identity.ProxyMachine -Message 'Synthetic x86 machine identity is wrong.'
    Assert-FearPostProcessEqual -Expected 0x010B -Actual $identity.ProxyOptionalHeaderMagic -Message 'Synthetic x86 PE identity is wrong.'
    Assert-FearPostProcessEqual -Expected 0x8664 -Actual $identity.CompanionMachine -Message 'Synthetic x64 companion machine identity is wrong.'
    Assert-FearPostProcessEqual -Expected 0x020B -Actual $identity.CompanionOptionalHeaderMagic -Message 'Synthetic x64 companion PE identity is wrong.'
    Assert-FearPostProcessEqual -Expected 0 -Actual $identity.CertificateTableSize -Message 'Unsigned synthetic setup unexpectedly exposed a certificate table.'
    Assert-FearPostProcessEqual -Expected 5 -Actual $identity.Assets.FileCount -Message 'FearMore asset package file count is wrong.'
    Assert-FearPostProcessEqual -Expected 0.25 -Actual $identity.Assets.DefaultSharpness -Message 'FearMore CAS default changed.'
    Assert-FearPostProcessEqual -Expected 'FirstEnableOnly' -Actual $identity.SeedPolicy -Message 'FearMore post-process seed policy changed.'
    Assert-FearPostProcessTrue -Condition ($identity.Assets.ColorOnly -and -not $identity.Assets.UsesDepth -and -not $identity.Assets.PerformsScaling) -Message 'FearMore CAS must remain color-only and native-resolution.'
    Assert-FearPostProcessTrue -Condition ($identity.ValidationOnly -and -not $identity.MutationPerformed) -Message 'Package inspection unexpectedly declared a filesystem mutation.'

    $missingSetupPath = Join-Path $tempRoot 'missing.exe'
    Assert-FearPostProcessThrows -Description 'Missing setup validation' -MessagePattern 'official ReShade setup is missing' -Action {
        Get-FearPostProcessPackageIdentity -SetupPath $missingSetupPath -AssetRoot $assetRoot
    }
    Assert-FearPostProcessThrows -Description 'Outer setup hash validation' -MessagePattern 'setup hash mismatch' -Action {
        Get-FearPostProcessPackageIdentity -SetupPath $validSetupPath -AssetRoot $assetRoot
    }
    Assert-FearPostProcessThrows -Description 'Embedded x86 payload hash validation' -MessagePattern 'ReShade32 payload hash mismatch' -Action {
        & $coreCommand -SetupPath $validSetupPath -ExpectedSetupSha256 $validSetupHash -ExpectedReShade32Sha256 ('0' * 64 -join '') -AssetRoot $assetRoot
    }

    $wrongArchitecturePath = Join-Path $tempRoot 'ReShade_Setup.wrong-architecture.exe'
    [void](New-FearPostProcessSyntheticSetup -Path $wrongArchitecturePath -ReShade32Bytes $x64Bytes -ReShade64Bytes $x64Bytes)
    $wrongArchitectureHash = (Get-FileHash -LiteralPath $wrongArchitecturePath -Algorithm SHA256).Hash
    Assert-FearPostProcessThrows -Description 'Embedded x86 architecture validation' -MessagePattern 'not a 32-bit x86 PE image' -Action {
        & $coreCommand -SetupPath $wrongArchitecturePath -ExpectedSetupSha256 $wrongArchitectureHash -ExpectedReShade32Sha256 $x64Hash -AssetRoot $assetRoot
    }

    $missingPayloadPath = Join-Path $tempRoot 'ReShade_Setup.missing-x86.exe'
    [void](New-FearPostProcessSyntheticSetup -Path $missingPayloadPath -ReShade32Bytes $x86Bytes -ReShade64Bytes $x64Bytes -OmitReShade32)
    $missingPayloadHash = (Get-FileHash -LiteralPath $missingPayloadPath -Algorithm SHA256).Hash
    Assert-FearPostProcessThrows -Description 'Missing x86 payload validation' -MessagePattern "exactly one 'ReShade32\.dll' entry; found 0" -Action {
        & $coreCommand -SetupPath $missingPayloadPath -ExpectedSetupSha256 $missingPayloadHash -ExpectedReShade32Sha256 $x86Hash -AssetRoot $assetRoot
    }

    $duplicatePayloadPath = Join-Path $tempRoot 'ReShade_Setup.duplicate-x86.exe'
    [void](New-FearPostProcessSyntheticSetup -Path $duplicatePayloadPath -ReShade32Bytes $x86Bytes -ReShade64Bytes $x64Bytes -DuplicateReShade32)
    $duplicatePayloadHash = (Get-FileHash -LiteralPath $duplicatePayloadPath -Algorithm SHA256).Hash
    Assert-FearPostProcessThrows -Description 'Duplicate x86 payload validation' -MessagePattern "exactly one 'ReShade32\.dll' entry; found 2" -Action {
        & $coreCommand -SetupPath $duplicatePayloadPath -ExpectedSetupSha256 $duplicatePayloadHash -ExpectedReShade32Sha256 $x86Hash -AssetRoot $assetRoot
    }

    $invalidArchivePath = Join-Path $tempRoot 'ReShade_Setup.no-archive.exe'
    [IO.File]::WriteAllBytes($invalidArchivePath, [byte[]](New-FearPostProcessSyntheticPeBytes -Machine 0x014C -OptionalHeaderMagic 0x010B))
    $invalidArchiveHash = (Get-FileHash -LiteralPath $invalidArchivePath -Algorithm SHA256).Hash
    Assert-FearPostProcessThrows -Description 'Missing appended ZIP validation' -MessagePattern 'does not contain a valid appended ZIP' -Action {
        & $coreCommand -SetupPath $invalidArchivePath -ExpectedSetupSha256 $invalidArchiveHash -ExpectedReShade32Sha256 $x86Hash -AssetRoot $assetRoot
    }

    $tamperedAssetRoot = Join-Path $tempRoot 'tampered-assets'
    Copy-Item -LiteralPath $assetRoot -Destination $tamperedAssetRoot -Recurse
    [IO.File]::AppendAllText((Join-Path $tamperedAssetRoot 'Shaders\FearMoreCAS.fx'), [Environment]::NewLine + '// tampered')
    Assert-FearPostProcessThrows -Description 'Tampered FearMore asset validation' -MessagePattern 'asset hash mismatch' -Action {
        & $coreCommand -SetupPath $validSetupPath -ExpectedSetupSha256 $validSetupHash -ExpectedReShade32Sha256 $x86Hash -AssetRoot $tamperedAssetRoot
    }

    $expandedAssetRoot = Join-Path $tempRoot 'expanded-assets'
    Copy-Item -LiteralPath $assetRoot -Destination $expandedAssetRoot -Recurse
    [IO.File]::WriteAllText((Join-Path $expandedAssetRoot 'unexpected.txt'), 'unowned')
    Assert-FearPostProcessThrows -Description 'Unowned FearMore asset validation' -MessagePattern 'asset file-count mismatch' -Action {
        & $coreCommand -SetupPath $validSetupPath -ExpectedSetupSha256 $validSetupHash -ExpectedReShade32Sha256 $x86Hash -AssetRoot $expandedAssetRoot
    }

    Assert-FearPostProcessThrows -Description 'Unsigned setup signer validation' -MessagePattern 'Authenticode signer cannot be validated' -Action {
        & $coreCommand -SetupPath $validSetupPath -ExpectedSetupSha256 $validSetupHash -ExpectedReShade32Sha256 $x86Hash -ExpectedSignerCertificateThumbprint '589690208A5E52FB96980C4A6698F50ACD47C49F' -AssetRoot $assetRoot
    }

    $realSetupPath = Join-Path $fullRepositoryRoot 'vendor-local\postprocess-deps\ReShade_Setup_6.7.3.exe'
    if (Test-Path -LiteralPath $realSetupPath -PathType Leaf) {
        $realIdentity = Get-FearPostProcessPackageIdentity `
            -SetupPath $realSetupPath `
            -AssetRoot $assetRoot
        Assert-FearPostProcessEqual -Expected '6.7.3' -Actual $realIdentity.ReShadeVersion -Message 'The pinned ReShade package version changed.'
        Assert-FearPostProcessTrue -Condition $realIdentity.PinnedIdentity -Message 'The real ReShade package was not marked as pinned.'
        Assert-FearPostProcessTrue -Condition ($realIdentity.SignatureStatus -cin @('Valid', 'UnknownError')) -Message 'The locally verified ReShade signature has an unsupported status.'
        Assert-FearPostProcessTrue -Condition $realIdentity.SignerCertificateMatched -Message 'The locally verified ReShade signer certificate did not match.'
        Assert-FearPostProcessEqual -Expected ($realIdentity.SignatureStatus -ceq 'Valid') -Actual $realIdentity.SignatureSystemTrustValidated -Message 'ReShade system-trust reporting disagrees with Authenticode status.'
        Assert-FearPostProcessEqual -Expected 5 -Actual $realIdentity.CertificateAlignmentPadding -Message 'Signed ReShade SFX alignment handling changed.'
        Assert-FearPostProcessEqual -Expected 7960 -Actual $realIdentity.CertificateTableSize -Message 'The locally verified ReShade certificate table changed.'
        $stagePayload = Get-FearPostProcessPackageStagePayload -SetupPath $realSetupPath -AssetRoot $assetRoot
        Assert-FearPostProcessEqual -Expected $realIdentity.ProxySha256 -Actual (Get-FearPostProcessTestByteSha256 -Bytes $stagePayload.ProxyBytes) -Message 'The in-memory x86 stage payload changed after validation.'
        Assert-FearPostProcessEqual -Expected 5 -Actual @($stagePayload.AssetFiles).Count -Message 'The in-memory asset staging payload is incomplete.'
        Assert-FearPostProcessTrue -Condition ($stagePayload.ValidationOnly -and -not $stagePayload.MutationPerformed) -Message 'Package staging-payload inspection unexpectedly declared a mutation.'
        foreach ($assetPayload in @($stagePayload.AssetFiles)) {
            Assert-FearPostProcessTrue -Condition ([string]$assetPayload.StageRelativePath).StartsWith('.fearmore\postprocess\', [StringComparison]::Ordinal) -Message 'An asset staging payload escaped the post-process subtree.'
            Assert-FearPostProcessEqual -Expected ([string]$assetPayload.Sha256) -Actual (Get-FearPostProcessTestByteSha256 -Bytes ([byte[]]$assetPayload.Bytes)) -Message "Asset staging bytes changed for $($assetPayload.StageRelativePath)."
        }
        $realInstallerResult = "Passed: official ReShade 6.7.3 exact hash, embedded x86 hash, signer certificate, and signed-SFX layout (Authenticode $($realIdentity.SignatureStatus))"
    }
    else {
        $realInstallerResult = 'Skipped: ignored user-supplied ReShade 6.7.3 setup is not present'
    }

    [pscustomobject]@{
        ModuleExportSurface = $exportedFunctions -join ','
        SyntheticPackage   = 'Passed'
        NegativeCases      = 'Passed (missing/wrong setup, payload identity/architecture, archive, assets, signer)'
        RealInstaller      = $realInstallerResult
        AssetFileCount     = $identity.Assets.FileCount
        DefaultSharpness   = $identity.Assets.DefaultSharpness
        ValidationOnly     = $identity.ValidationOnly
    }
}
finally {
    Remove-Module -Name $module.Name -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
