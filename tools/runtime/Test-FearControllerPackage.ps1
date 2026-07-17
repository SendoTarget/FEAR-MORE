[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$ArchivePath,
    [switch]$AllowMissingArchive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$modulePath = Join-Path $PSScriptRoot 'FearControllerPackage.psm1'
$acquisitionPath = Join-Path $PSScriptRoot 'Get-FearControllerRuntime.ps1'
Import-Module $modulePath -Force -ErrorAction Stop

$actualExports = @(Get-Command -Module FearControllerPackage -CommandType Function |
        Select-Object -ExpandProperty Name | Sort-Object)
$expectedExports = @(
    'Get-FearControllerPackageDefaultArchivePath',
    'Get-FearControllerPackageMetadata',
    'Get-FearControllerPackageStagePayload'
) | Sort-Object
if (@(Compare-Object $expectedExports $actualExports).Count -ne 0) {
    throw "FearControllerPackage exports changed. Found: $($actualExports -join ', ')"
}

$metadata = Get-FearControllerPackageMetadata
if ($metadata.Provider -cne 'SDL' -or $metadata.Version -cne '3.4.10' -or
    $metadata.ArchiveSha256 -cne '95FA18CD5C8AD64DCEB0E0F5F006D223FF19630590457F3D4D3841EE2CA839BD' -or
    $metadata.RuntimeSha256 -cne '7F85F7C0FB1189050405ACD39BD1E36A8F94FFF5952C513497A9DCAFCB86A9B0' -or
    $metadata.RuntimeSize -ne 2342912 -or
    $metadata.LicenseSha256 -cne '1C040B8271B37E5076359F8FD54240E371114112924D2DF81EF87C7D6A1DFDFD' -or
    $metadata.LicenseSize -ne 884 -or $metadata.Architecture -cne 'x86' -or
    $metadata.License -cne 'Zlib') {
    throw 'Pinned SDL3 controller package metadata changed.'
}

if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Get-FearControllerPackageDefaultArchivePath -RepositoryRoot $RepositoryRoot
}
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
    if ($AllowMissingArchive) {
        [pscustomobject]@{
            Status       = 'SKIP'
            Reason       = 'Pinned SDL3 archive is not present in vendor-local.'
            ArchivePath  = $ArchivePath
            PackagePin   = $metadata.ArchiveSha256
        }
        return
    }
    throw "Pinned SDL3 archive is missing: $ArchivePath. Run Get-FearControllerRuntime.ps1 first."
}

$identity = Get-FearControllerPackageStagePayload -ArchivePath $ArchivePath
if ($identity.ArchiveSha256 -cne $metadata.ArchiveSha256 -or
    $identity.RuntimeFileName -cne 'SDL3.dll' -or
    $identity.RuntimeSize -ne $metadata.RuntimeSize -or
    $identity.RuntimeSha256 -cne $metadata.RuntimeSha256 -or
    $identity.RuntimeArchitecture -cne 'x86' -or
    $identity.RuntimeMachine -ne 0x014C -or
    $identity.RuntimeOptionalHeaderMagic -ne 0x010B -or
    $identity.LicenseStagePath -cne '.fearmore\licenses\SDL3-zlib.txt' -or
    $identity.LicenseSize -ne $metadata.LicenseSize -or
    $identity.LicenseSha256 -cne $metadata.LicenseSha256) {
    throw 'Validated SDL3 package payload does not match its pinned runtime/license contract.'
}

$existingAcquisition = @(& $acquisitionPath `
        -RepositoryRoot $RepositoryRoot `
        -ArchivePath $ArchivePath `
        -WhatIf)
if ($existingAcquisition.Count -ne 1 -or
    $existingAcquisition[0].ArchiveSha256 -cne $metadata.ArchiveSha256) {
    throw 'Existing-package controller acquisition is not idempotent and validation-only.'
}

$localRuntimeRoot = Join-Path $RepositoryRoot 'local-runtime'
$fixtureRoot = Join-Path $localRuntimeRoot "controller-package-test-$([guid]::NewGuid().ToString('N'))"
try {
    [IO.Directory]::CreateDirectory($fixtureRoot) | Out-Null
    $corruptArchive = Join-Path $fixtureRoot $metadata.ArchiveName
    $corruptBytes = [IO.File]::ReadAllBytes($ArchivePath)
    $corruptBytes[$corruptBytes.Length - 1] = $corruptBytes[$corruptBytes.Length - 1] -bxor 0x01
    [IO.File]::WriteAllBytes($corruptArchive, $corruptBytes)

    $corruptRejected = $false
    try {
        Get-FearControllerPackageStagePayload -ArchivePath $corruptArchive | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('archive hash mismatch')) {
            throw
        }
        $corruptRejected = $true
    }
    if (-not $corruptRejected) {
        throw 'A modified SDL3 archive was accepted.'
    }
}
finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    if ((Test-Path -LiteralPath $resolvedFixture) -and
        $resolvedFixture.StartsWith([IO.Path]::GetFullPath($localRuntimeRoot).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}

[pscustomobject]@{
    Status               = 'PASS'
    Provider             = $identity.Provider
    Version              = $identity.Version
    ArchiveSha256        = $identity.ArchiveSha256
    RuntimeSha256        = $identity.RuntimeSha256
    RuntimeArchitecture  = $identity.RuntimeArchitecture
    License              = $identity.License
    CorruptArchiveRejected = $true
    ExistingAcquisitionIdempotent = $true
}
