Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ExpectedSteamFearExecutableHash = 'D5EBC38A4F12B772C9112A2811C290ADB6C5052D3BC2F817302D38CF55BB2CBE'
$script:ExpectedSteamEchoPatchedLaaHash = 'D9E5F716CFA5A6F2E9B1A73FE113CD83D750283D357061E02B484633FE0113BD'

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

function Get-FearPeRuntimeIdentity {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4D -or $bytes[1] -ne 0x5A) {
        throw "Not a valid PE image: $Path"
    }

    $peOffset = [BitConverter]::ToInt32($bytes, 0x3C)
    if ($peOffset -lt 0 -or ($peOffset + 92) -ge $bytes.Length -or
        $bytes[$peOffset] -ne 0x50 -or $bytes[$peOffset + 1] -ne 0x45) {
        throw "Invalid PE headers in: $Path"
    }

    $sectionCount = [BitConverter]::ToUInt16($bytes, $peOffset + 6)
    $optionalHeaderSize = [BitConverter]::ToUInt16($bytes, $peOffset + 20)
    $sectionTableOffset = $peOffset + 24 + $optionalHeaderSize
    if ($sectionCount -eq 0 -or ($sectionTableOffset + ($sectionCount * 40)) -gt $bytes.Length) {
        throw "Invalid PE section table in: $Path"
    }

    $sectionNames = @()
    for ($index = 0; $index -lt $sectionCount; $index++) {
        $sectionOffset = $sectionTableOffset + ($index * 40)
        $sectionNames += [Text.Encoding]::ASCII.GetString($bytes, $sectionOffset, 8).Trim([char]0)
    }

    $characteristics = [BitConverter]::ToUInt16($bytes, $peOffset + 22)
    return [pscustomobject]@{
        Path                = $Path
        Sha256              = Get-ByteArraySha256 -Bytes $bytes
        Size                = $bytes.Length
        PeOffset            = $peOffset
        Machine             = [BitConverter]::ToUInt16($bytes, $peOffset + 4)
        TimeDateStamp       = [BitConverter]::ToUInt32($bytes, $peOffset + 8)
        SectionCount        = $sectionCount
        OptionalHeaderSize  = $optionalHeaderSize
        Magic               = [BitConverter]::ToUInt16($bytes, $peOffset + 24)
        SizeOfCode          = [BitConverter]::ToUInt32($bytes, $peOffset + 28)
        AddressOfEntryPoint = [BitConverter]::ToUInt32($bytes, $peOffset + 40)
        ImageBase           = [BitConverter]::ToUInt32($bytes, $peOffset + 52)
        Characteristics     = $characteristics
        LargeAddressAware   = [bool]($characteristics -band 0x20)
        ChecksumOffset      = $peOffset + 88
        SectionNames        = @($sectionNames)
        HasBindSection      = @($sectionNames) -contains '.bind'
    }
}

function Test-FearX86Pe32Identity {
    param([Parameter(Mandatory = $true)]$Identity)

    return $Identity.Machine -eq 0x014C -and $Identity.Magic -eq 0x010B
}

function Get-EchoPatchHeaderOnlyLaaHash {
    param([Parameter(Mandatory = $true)][string]$RetailExecutable)

    $identity = Get-FearPeRuntimeIdentity -Path $RetailExecutable
    if ($identity.HasBindSection -or $identity.LargeAddressAware) {
        return $null
    }

    $expectedBytes = [byte[]]([IO.File]::ReadAllBytes($RetailExecutable).Clone())
    $laaCharacteristics = [uint16]($identity.Characteristics -bor 0x20)
    ([BitConverter]::GetBytes($laaCharacteristics)).CopyTo($expectedBytes, $identity.PeOffset + 22)
    for ($index = 0; $index -lt 4; $index++) {
        $expectedBytes[$identity.ChecksumOffset + $index] = 0
    }

    return Get-ByteArraySha256 -Bytes $expectedBytes
}

function Test-AttestedEchoPatchLaaPair {
    param(
        [Parameter(Mandatory = $true)][string]$RetailExecutable,
        [Parameter(Mandatory = $true)][string]$PatchedExecutable,
        [Parameter(Mandatory = $true)][string]$BackupExecutable
    )

    foreach ($path in @($RetailExecutable, $PatchedExecutable, $BackupExecutable)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            return $false
        }
    }

    try {
        $retailIdentity = Get-FearPeRuntimeIdentity -Path $RetailExecutable
        $patchedIdentity = Get-FearPeRuntimeIdentity -Path $PatchedExecutable
        $backupIdentity = Get-FearPeRuntimeIdentity -Path $BackupExecutable
    }
    catch {
        return $false
    }

    if (-not (Test-FearX86Pe32Identity -Identity $retailIdentity) -or
        -not (Test-FearX86Pe32Identity -Identity $patchedIdentity) -or
        -not (Test-FearX86Pe32Identity -Identity $backupIdentity) -or
        $backupIdentity.Sha256 -ne $retailIdentity.Sha256 -or
        -not $patchedIdentity.LargeAddressAware -or $patchedIdentity.HasBindSection) {
        return $false
    }

    if ($retailIdentity.Sha256 -eq $script:ExpectedSteamFearExecutableHash) {
        return $patchedIdentity.Sha256 -eq $script:ExpectedSteamEchoPatchedLaaHash -and
            $retailIdentity.HasBindSection -and
            $patchedIdentity.AddressOfEntryPoint -eq 0x13E428
    }

    if ($retailIdentity.HasBindSection -or $retailIdentity.LargeAddressAware -or
        $patchedIdentity.Size -ne $retailIdentity.Size -or
        $patchedIdentity.SectionCount -ne $retailIdentity.SectionCount -or
        $patchedIdentity.AddressOfEntryPoint -ne $retailIdentity.AddressOfEntryPoint) {
        return $false
    }

    $expectedPatchedHash = Get-EchoPatchHeaderOnlyLaaHash -RetailExecutable $RetailExecutable
    return $expectedPatchedHash -and $patchedIdentity.Sha256 -eq $expectedPatchedHash
}

function Get-FearStockRuntimeExecutableAssessment {
    param(
        [Parameter(Mandatory = $true)][string]$RetailExecutable,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    $retailIdentity = Get-FearPeRuntimeIdentity -Path $RetailExecutable
    if (-not (Test-FearX86Pe32Identity -Identity $retailIdentity)) {
        throw "Retail FEAR.exe is not a 32-bit x86 PE image (machine 0x014C, PE32 magic 0x010B required): $RetailExecutable"
    }
    $stageExecutable = Join-Path $StageRoot 'FEAR.exe'
    $backupExecutable = Join-Path $StageRoot 'FEAR.exe.bak'
    $stagePathExists = Test-Path -LiteralPath $stageExecutable
    $backupPathExists = Test-Path -LiteralPath $backupExecutable
    $stageIsFile = Test-Path -LiteralPath $stageExecutable -PathType Leaf
    $backupIsFile = Test-Path -LiteralPath $backupExecutable -PathType Leaf

    $baseResult = [ordered]@{
        State                         = 'Unknown'
        BootstrapRequired             = $null
        RuntimeExecutableSha256       = $null
        RetailExecutableSha256        = $retailIdentity.Sha256
        RuntimeExecutableBackupSha256 = $null
    }

    if (-not $stagePathExists -and -not $backupPathExists) {
        $baseResult.State = 'Missing'
        $baseResult.BootstrapRequired = $retailIdentity.HasBindSection -or -not $retailIdentity.LargeAddressAware
        return [pscustomobject]$baseResult
    }
    if (-not $stageIsFile -or ($backupPathExists -and -not $backupIsFile)) {
        return [pscustomobject]$baseResult
    }

    try {
        $stageIdentity = Get-FearPeRuntimeIdentity -Path $stageExecutable
    }
    catch {
        return [pscustomobject]$baseResult
    }
    $baseResult.RuntimeExecutableSha256 = $stageIdentity.Sha256
    if (-not (Test-FearX86Pe32Identity -Identity $stageIdentity)) {
        return [pscustomobject]$baseResult
    }

    if ($stageIdentity.Sha256 -eq $retailIdentity.Sha256 -and -not $backupPathExists) {
        $baseResult.State = 'RetailOriginal'
        $baseResult.BootstrapRequired = $retailIdentity.HasBindSection -or -not $retailIdentity.LargeAddressAware
        return [pscustomobject]$baseResult
    }

    if ($backupIsFile -and
        (Test-AttestedEchoPatchLaaPair -RetailExecutable $RetailExecutable -PatchedExecutable $stageExecutable -BackupExecutable $backupExecutable)) {
        $baseResult.State = 'EchoPatchedLAA'
        $baseResult.BootstrapRequired = $false
        $baseResult.RuntimeExecutableBackupSha256 = (Get-FileHash -LiteralPath $backupExecutable -Algorithm SHA256).Hash
    }

    return [pscustomobject]$baseResult
}

function Get-FearAttestedLaaRuntimeExecutablePairIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RetailExecutable,
        [Parameter(Mandatory = $true)][string]$PatchedExecutable,
        [Parameter(Mandatory = $true)][string]$BackupExecutable
    )

    $canonicalRetailExecutable = [IO.Path]::GetFullPath($RetailExecutable)
    $canonicalPatchedExecutable = [IO.Path]::GetFullPath($PatchedExecutable)
    $canonicalBackupExecutable = [IO.Path]::GetFullPath($BackupExecutable)
    if (-not (Test-AttestedEchoPatchLaaPair `
            -RetailExecutable $canonicalRetailExecutable `
            -PatchedExecutable $canonicalPatchedExecutable `
            -BackupExecutable $canonicalBackupExecutable)) {
        throw "The proposed LAA executable pair is not an attested header-only derivative of the selected retail FEAR.exe: $canonicalPatchedExecutable"
    }

    $retailIdentity = Get-FearPeRuntimeIdentity -Path $canonicalRetailExecutable
    $patchedIdentity = Get-FearPeRuntimeIdentity -Path $canonicalPatchedExecutable
    $backupIdentity = Get-FearPeRuntimeIdentity -Path $canonicalBackupExecutable
    return [pscustomobject][ordered]@{
        RetailExecutable          = $retailIdentity.Path
        RetailExecutableSha256    = $retailIdentity.Sha256
        PatchedExecutable         = $patchedIdentity.Path
        PatchedExecutableSha256   = $patchedIdentity.Sha256
        BackupExecutable          = $backupIdentity.Path
        BackupExecutableSha256    = $backupIdentity.Sha256
        LargeAddressAware         = $patchedIdentity.LargeAddressAware
        Machine                   = $patchedIdentity.Machine
        Magic                     = $patchedIdentity.Magic
    }
}

function Test-FearSteamRetailInstallation {
    param(
        [Parameter(Mandatory = $true)][string]$RetailRoot,
        [string]$AppId = '21090',
        [switch]$RequireRegisteredAppManifest
    )

    $canonicalRetailRoot = [IO.Path]::GetFullPath($RetailRoot).TrimEnd('\')
    $retailExecutable = Join-Path $canonicalRetailRoot 'FEAR.exe'
    if (-not (Test-Path -LiteralPath $retailExecutable -PathType Leaf)) {
        return $false
    }
    try {
        $retailIdentity = Get-FearPeRuntimeIdentity -Path $retailExecutable
        if (-not (Test-FearX86Pe32Identity -Identity $retailIdentity)) {
            return $false
        }
    }
    catch {
        return $false
    }
    # Preserve the historical known-binary shortcut for general staging, but
    # never let a copied FEAR.exe masquerade as the registered Steam install
    # when a launch caller requests strict appmanifest/root binding.
    if (-not $RequireRegisteredAppManifest -and
        $retailIdentity.Sha256 -eq $script:ExpectedSteamFearExecutableHash) {
        return $true
    }

    $commonRoot = Split-Path $canonicalRetailRoot -Parent
    $steamAppsRoot = Split-Path $commonRoot -Parent
    if ((Split-Path $commonRoot -Leaf) -ine 'common' -or (Split-Path $steamAppsRoot -Leaf) -ine 'steamapps') {
        return $false
    }

    $manifestPath = Join-Path $steamAppsRoot "appmanifest_$AppId.acf"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        return $false
    }
    $manifestText = Get-Content -LiteralPath $manifestPath -Raw
    if ($manifestText -notmatch ('"appid"\s+"{0}"' -f [regex]::Escape($AppId)) -or
        $manifestText -notmatch '"installdir"\s+"([^"]+)"') {
        return $false
    }

    return $Matches[1].Equals((Split-Path $canonicalRetailRoot -Leaf), [StringComparison]::OrdinalIgnoreCase)
}

Export-ModuleMember -Function Get-FearPeRuntimeIdentity, Get-FearStockRuntimeExecutableAssessment, Get-FearAttestedLaaRuntimeExecutablePairIdentity, Test-FearSteamRetailInstallation, Test-FearX86Pe32Identity
