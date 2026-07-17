[CmdletBinding(PositionalBinding = $false, SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
param(
    [ValidateSet('Lite', 'Full')]
    [string]$Mode = 'Lite',

    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$LocalAppDataRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RegistrationSchemaVersion = 2
$script:MaximumRegistrationBytes = 1048576

function Test-FearRegistrationReparsePoint {
    param([Parameter(Mandatory = $true)]$Item)

    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-FearRegistrationPathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    $canonicalPath = [IO.Path]::GetFullPath($Path)
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $rootPrefix = $canonicalRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $canonicalPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Purpose escapes the selected registration safety root: $canonicalPath"
    }
    return $canonicalPath
}

function Assert-FearRegistrationDirectoryChain {
    param(
        [Parameter(Mandatory = $true)][string]$SafetyRoot,
        [Parameter(Mandatory = $true)][string]$RegistrationDirectory
    )

    $canonicalSafetyRoot = [IO.Path]::GetFullPath($SafetyRoot).TrimEnd('\')
    $canonicalRegistrationDirectory = Assert-FearRegistrationPathWithinRoot `
        -Path $RegistrationDirectory `
        -Root $canonicalSafetyRoot `
        -Purpose 'HD texture registration directory'

    $safetyRootItem = Get-Item -LiteralPath $canonicalSafetyRoot -Force -ErrorAction Stop
    if (-not $safetyRootItem.PSIsContainer -or
        (Test-FearRegistrationReparsePoint -Item $safetyRootItem)) {
        throw "Registration safety root must be an ordinary directory before registering local texture content: $canonicalSafetyRoot"
    }

    $relativePath = $canonicalRegistrationDirectory.Substring($canonicalSafetyRoot.Length).TrimStart('\')
    $currentPath = $canonicalSafetyRoot
    foreach ($segment in @($relativePath.Split([IO.Path]::DirectorySeparatorChar))) {
        if ([string]::IsNullOrWhiteSpace($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "HD texture registration directory contains an unsafe path segment: $canonicalRegistrationDirectory"
        }
        $currentPath = Join-Path $currentPath $segment
        if (-not (Test-Path -LiteralPath $currentPath)) {
            continue
        }
        $item = Get-Item -LiteralPath $currentPath -Force -ErrorAction Stop
        if (-not $item.PSIsContainer -or (Test-FearRegistrationReparsePoint -Item $item)) {
            throw "HD texture registration path contains a non-directory or reparse point: $($item.FullName)"
        }
    }
}

function Assert-FearOrdinaryRegistrationFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Purpose
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Purpose must be an ordinary file: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (Test-FearRegistrationReparsePoint -Item $item) {
        throw "$Purpose is a reparse point: $Path"
    }
    return $item
}

function Read-FearExistingTextureRegistration {
    param([Parameter(Mandatory = $true)][IO.FileInfo]$File)

    if ($File.Length -gt $script:MaximumRegistrationBytes) {
        throw "Existing HD texture registration is unexpectedly large: $($File.FullName)"
    }
    $json = [IO.File]::ReadAllText($File.FullName, [Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($json)) {
        throw "Existing HD texture registration is empty: $($File.FullName)"
    }
    try {
        $registration = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Existing HD texture registration is not valid JSON: $($File.FullName). $($_.Exception.Message)"
    }

    if (-not $registration.PSObject.Properties['SchemaVersion'] -or
        [int]$registration.SchemaVersion -notin @(1, $script:RegistrationSchemaVersion)) {
        throw "Existing HD texture registration has an unsupported schema version: $($File.FullName)"
    }
    $foundRecord = $false
    foreach ($recordMode in @('Lite', 'Full')) {
        $recordProperty = $registration.PSObject.Properties[$recordMode]
        if (-not $recordProperty -or $null -eq $recordProperty.Value) {
            continue
        }
        $foundRecord = $true
        if (-not $recordProperty.Value.PSObject.Properties['Mode'] -or
            [string]$recordProperty.Value.Mode -cne $recordMode) {
            throw "Existing HD texture registration has an invalid $recordMode package mode: $($File.FullName)"
        }
    }
    if (-not $foundRecord) {
        throw "Existing HD texture registration has no Lite or Full package record: $($File.FullName)"
    }
    return $registration
}

function Write-FearUtf8JsonTransactionFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Json
    )

    $stream = $null
    $writer = $null
    try {
        $stream = [IO.File]::Open(
            $Path,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        $writer = [IO.StreamWriter]::new($stream, [Text.UTF8Encoding]::new($false))
        $writer.NewLine = "`n"
        $writer.Write($Json)
        $writer.WriteLine()
        $writer.Flush()
        $stream.Flush($true)
    }
    finally {
        if ($writer) {
            $writer.Dispose()
        }
        elseif ($stream) {
            $stream.Dispose()
        }
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
$modulePath = Join-Path $PSScriptRoot 'FearTexturePackage.psm1'
$layoutModulePath = Join-Path $PSScriptRoot 'FearRuntimeLayout.psm1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw "HD texture package validator is missing: $modulePath"
}
if (-not (Test-Path -LiteralPath $layoutModulePath -PathType Leaf)) {
    throw "FearMore runtime-layout owner is missing: $layoutModulePath"
}
Import-Module $modulePath -Force
Import-Module $layoutModulePath -Force

$identity = Get-FearHdTexturePackageIdentity `
    -PackageRoot $PackageRoot `
    -RequireKnownMode $Mode

$layoutArguments = @{ SourceRoot = $repositoryRoot }
if (-not [string]::IsNullOrWhiteSpace($LocalAppDataRoot)) {
    $layoutArguments.LocalAppDataRoot = $LocalAppDataRoot
}
$runtimeLayout = Resolve-FearRuntimeLayout @layoutArguments
$registrationSafetyRoot = $runtimeLayout.RegistrationSafetyRoot
$registrationDirectory = $runtimeLayout.TextureRegistrationDirectory
$registrationPath = $runtimeLayout.TextureRegistrationPath
$transactionPath = Join-Path $registrationDirectory 'fearmore-hd-textures.json.fearmore.new'
$backupPath = Join-Path $registrationDirectory 'fearmore-hd-textures.json.fearmore.previous'

$registrationPath = Assert-FearRegistrationPathWithinRoot `
    -Path $registrationPath `
    -Root $registrationSafetyRoot `
    -Purpose 'HD texture registration file'
$transactionPath = Assert-FearRegistrationPathWithinRoot `
    -Path $transactionPath `
    -Root $registrationSafetyRoot `
    -Purpose 'HD texture registration transaction file'
$backupPath = Assert-FearRegistrationPathWithinRoot `
    -Path $backupPath `
    -Root $registrationSafetyRoot `
    -Purpose 'HD texture registration backup file'

Assert-FearRegistrationDirectoryChain `
    -SafetyRoot $registrationSafetyRoot `
    -RegistrationDirectory $registrationDirectory

foreach ($recoveryPath in @($transactionPath, $backupPath)) {
    if (Test-Path -LiteralPath $recoveryPath) {
        $null = Assert-FearOrdinaryRegistrationFile `
            -Path $recoveryPath `
            -Purpose 'Prior HD texture registration recovery path'
        throw "A prior HD texture registration transaction needs inspection before retrying: $recoveryPath"
    }
}

$existingRegistrationItem = Assert-FearOrdinaryRegistrationFile `
    -Path $registrationPath `
    -Purpose 'Existing HD texture registration'
$existingRegistrationSha256 = $null
$existingRegistration = $null
if ($existingRegistrationItem) {
    $existingRegistration = Read-FearExistingTextureRegistration -File $existingRegistrationItem
    $existingRegistrationSha256 = (Get-FileHash -LiteralPath $registrationPath -Algorithm SHA256).Hash
}

$registeredUtc = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
$modeRegistration = [ordered]@{
    Mode                     = $Mode
    PackageRoot              = [string]$identity.PackageRoot
    ContentRoot              = [string]$identity.ContentRoot
    ContentMountName         = [string]$identity.ContentMountName
    IncludesExpansionContent = [bool]$identity.IncludesExpansionContent
    FileCount                = [int]$identity.FileCount
    TotalBytes               = [long]$identity.TotalBytes
    ManifestSha256           = [string]$identity.ManifestSha256
    ManifestFormat           = [string]$identity.ManifestFormat
    MatchesKnownPackage      = [bool]$identity.MatchesKnownPackage
    KnownPackageName         = [string]$identity.KnownPackageName
    RegisteredUtc            = $registeredUtc
    SourceKind               = 'UserSuppliedLocal'
    Redistributable          = $false
}
$registry = [ordered]@{
    SchemaVersion = $script:RegistrationSchemaVersion
    UpdatedUtc    = $registeredUtc
}
foreach ($recordMode in @('Lite', 'Full')) {
    if ($recordMode -eq $Mode) {
        $registry[$recordMode] = $modeRegistration
        continue
    }
    if ($existingRegistration -and $existingRegistration.PSObject.Properties[$recordMode]) {
        $registry[$recordMode] = $existingRegistration.PSObject.Properties[$recordMode].Value
    }
}
$registryJson = $registry | ConvertTo-Json -Depth 5

if (-not $PSCmdlet.ShouldProcess($registrationPath, "Register the validated local $Mode HD texture package")) {
    return [pscustomobject]@{
        Registered        = $false
        RegistrationPath  = $registrationPath
        Mode              = $Mode
        PackageRoot       = [string]$identity.PackageRoot
        ContentRoot       = [string]$identity.ContentRoot
        FileCount         = [int]$identity.FileCount
        TotalBytes        = [long]$identity.TotalBytes
        ManifestSha256    = [string]$identity.ManifestSha256
        MatchesKnownPackage = [bool]$identity.MatchesKnownPackage
    }
}

[IO.Directory]::CreateDirectory($registrationDirectory) | Out-Null
Assert-FearRegistrationDirectoryChain `
    -SafetyRoot $registrationSafetyRoot `
    -RegistrationDirectory $registrationDirectory

# Recheck every fixed transaction path after directory creation and immediately
# before the write. This fails closed on interrupted or concurrent registrations.
foreach ($recoveryPath in @($transactionPath, $backupPath)) {
    if (Test-Path -LiteralPath $recoveryPath) {
        $null = Assert-FearOrdinaryRegistrationFile `
            -Path $recoveryPath `
            -Purpose 'HD texture registration recovery path'
        throw "An HD texture registration recovery path appeared before the write: $recoveryPath"
    }
}
if ($existingRegistrationItem) {
    $currentItem = Assert-FearOrdinaryRegistrationFile `
        -Path $registrationPath `
        -Purpose 'Existing HD texture registration'
    if (-not $currentItem) {
        throw "Existing HD texture registration disappeared before it could be replaced: $registrationPath"
    }
    $currentSha256 = (Get-FileHash -LiteralPath $registrationPath -Algorithm SHA256).Hash
    if ($currentSha256 -cne $existingRegistrationSha256) {
        throw "Existing HD texture registration changed concurrently; it was not replaced: $registrationPath"
    }
}
elseif (Test-Path -LiteralPath $registrationPath) {
    throw "An HD texture registration appeared concurrently; it was not replaced: $registrationPath"
}

$transactionWritten = $false
try {
    Write-FearUtf8JsonTransactionFile -Path $transactionPath -Json $registryJson
    $transactionWritten = $true
    $null = Assert-FearOrdinaryRegistrationFile `
        -Path $transactionPath `
        -Purpose 'HD texture registration transaction file'

    if ($existingRegistrationItem) {
        [IO.File]::Replace($transactionPath, $registrationPath, $backupPath, $true)
        $transactionWritten = $false
        if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
            throw "Atomic HD texture registration replacement did not create its recovery backup: $backupPath"
        }
        $backupItem = Assert-FearOrdinaryRegistrationFile `
            -Path $backupPath `
            -Purpose 'HD texture registration recovery backup'
        $backupSha256 = (Get-FileHash -LiteralPath $backupItem.FullName -Algorithm SHA256).Hash
        if ($backupSha256 -cne $existingRegistrationSha256) {
            throw "HD texture registration recovery backup does not match the replaced file: $backupPath"
        }
        [IO.File]::Delete($backupPath)
    }
    else {
        [IO.File]::Move($transactionPath, $registrationPath)
        $transactionWritten = $false
    }
}
catch {
    if (-not (Test-Path -LiteralPath $registrationPath) -and
        (Test-Path -LiteralPath $backupPath -PathType Leaf)) {
        $backupItem = Assert-FearOrdinaryRegistrationFile `
            -Path $backupPath `
            -Purpose 'HD texture registration recovery backup'
        [IO.File]::Move($backupItem.FullName, $registrationPath)
    }
    throw
}
finally {
    if ($transactionWritten -and (Test-Path -LiteralPath $transactionPath -PathType Leaf)) {
        $transactionItem = Assert-FearOrdinaryRegistrationFile `
            -Path $transactionPath `
            -Purpose 'HD texture registration transaction file'
        [IO.File]::Delete($transactionItem.FullName)
    }
}

$writtenRegistrationItem = Assert-FearOrdinaryRegistrationFile `
    -Path $registrationPath `
    -Purpose 'Completed HD texture registration'
$writtenRegistration = Read-FearExistingTextureRegistration -File $writtenRegistrationItem
$registrationSha256 = (Get-FileHash -LiteralPath $registrationPath -Algorithm SHA256).Hash
$writtenModeRecord = $writtenRegistration.PSObject.Properties[$Mode].Value

return [pscustomobject]@{
    Registered          = $true
    RegistrationPath    = $registrationPath
    RegistrationSha256  = $registrationSha256
    SchemaVersion       = [int]$writtenRegistration.SchemaVersion
    Mode                = [string]$writtenModeRecord.Mode
    PackageRoot         = [string]$writtenModeRecord.PackageRoot
    ContentRoot         = [string]$writtenModeRecord.ContentRoot
    FileCount           = [int]$writtenModeRecord.FileCount
    TotalBytes          = [long]$writtenModeRecord.TotalBytes
    ManifestSha256      = [string]$writtenModeRecord.ManifestSha256
    MatchesKnownPackage = [bool]$writtenModeRecord.MatchesKnownPackage
    RegisteredUtc       = [string]$writtenModeRecord.RegisteredUtc
}
