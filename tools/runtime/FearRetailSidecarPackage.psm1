Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearEnginePatchPackage.psm1') -Force -ErrorAction Stop

$script:InstallRecordName = 'fearmore-live-install.json'
$script:UninstallReceiptName = 'fearmore-live-uninstall.json'
$script:TransactionJournalName = 'fearmore-live-install.transaction.json'
$script:TransactionBackupName = '.fearmore-live-install.rollback'
$script:ArchiveConfigName = 'FearMore.archcfg'
$script:ModuleDirectoryName = 'FearMoreGame'
$script:RuntimeConfigName = 'rtx.conf'
$script:RuntimeWritablePolicy = 'PreserveAlwaysNeverOwnedOrRemoved'
$script:RuntimeWritableDirectories = @('rtx-remix')
$script:RuntimeMutableFiles = @('rtx.conf')
$script:SupportedEnginePatchModes = @(
    'CameraDiagnosticEchoPatch',
    'RtxCameraDiagnosticEchoPatch',
    'RtxCameraReassertionEchoPatch'
)

function Get-FearRetailSidecarNames {
    [pscustomobject]@{
        InstallRecord       = $script:InstallRecordName
        UninstallReceipt    = $script:UninstallReceiptName
        TransactionJournal  = $script:TransactionJournalName
        TransactionBackup   = $script:TransactionBackupName
        ArchiveConfig       = $script:ArchiveConfigName
        ModuleDirectory     = $script:ModuleDirectoryName
        RuntimeConfig       = $script:RuntimeConfigName
    }
}

function Test-FearRetailSidecarPathsEqual {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)
    [IO.Path]::GetFullPath($Left).TrimEnd('\').Equals(
        [IO.Path]::GetFullPath($Right).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase)
}

function Test-FearRetailSidecarPathIsBelow {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Parent)
    $child = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $child.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-FearRetailSidecarRelativePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath) -or
        $RelativePath.Contains(':')) {
        throw "Sidecar path must be a nonempty relative Windows path: '$RelativePath'"
    }
    $normalized = ($RelativePath -replace '/', '\').Trim('\')
    if (-not $normalized -or @($normalized -split '\\' | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) {
        throw "Sidecar path contains an empty, current, or parent component: '$RelativePath'"
    }
    return $normalized
}

function Get-FearRetailSidecarTargetPath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$RelativePath
    )
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $normalized = Assert-FearRetailSidecarRelativePath -RelativePath $RelativePath
    $candidate = [IO.Path]::GetFullPath((Join-Path $canonicalRoot $normalized))
    if (-not (Test-FearRetailSidecarPathIsBelow -Path $candidate -Parent $canonicalRoot)) {
        throw "Sidecar path escapes its root '$canonicalRoot': $RelativePath"
    }
    return $candidate
}

function Assert-FearRetailSidecarPathNoReparse {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowMissingLeaf,
        [switch]$LeafMayBeFile
    )
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-FearRetailSidecarPathsEqual -Left $canonicalRoot -Right $canonicalPath) -and
        -not (Test-FearRetailSidecarPathIsBelow -Path $canonicalPath -Parent $canonicalRoot)) {
        throw "Sidecar path escapes its root '$canonicalRoot': $canonicalPath"
    }
    $paths = @($canonicalRoot)
    if (-not (Test-FearRetailSidecarPathsEqual -Left $canonicalRoot -Right $canonicalPath)) {
        $current = $canonicalRoot
        foreach ($component in $canonicalPath.Substring($canonicalRoot.Length).TrimStart('\') -split '\\') {
            $current = Join-Path $current $component
            $paths += $current
        }
    }
    for ($index = 0; $index -lt $paths.Count; $index++) {
        $current = $paths[$index]
        $isLeaf = $index -eq ($paths.Count - 1)
        if (-not (Test-Path -LiteralPath $current)) {
            if ($AllowMissingLeaf -and $isLeaf) { continue }
            if ($AllowMissingLeaf -and $index -ge 1) { continue }
            throw "Required sidecar path component is missing: $current"
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Sidecar operations never traverse reparse points: $current"
        }
        if (-not $item.PSIsContainer -and -not ($LeafMayBeFile -and $isLeaf)) {
            throw "Sidecar path component is not a directory: $current"
        }
    }
}

function Assert-FearRetailSidecarOrdinaryFile {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Path, [string]$Description = 'file')
    Assert-FearRetailSidecarPathNoReparse -Root $Root -Path $Path -LeafMayBeFile
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing or is not an ordinary file: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description must not be a reparse point: $Path"
    }
    return $item
}

function Get-FearRetailSidecarSha256 {
    param([Parameter(Mandatory)][string]$Path)
    # Get-FileHash participates in a caller's propagated -WhatIf preference and
    # may return no identity at all. Hashing is read-only, so use FileStream
    # directly and keep validation reliable under installer -WhatIf.
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($stream))).Replace('-', '') }
    finally { $algorithm.Dispose(); $stream.Dispose() }
}

function Assert-FearRetailSidecarGameNotRunning {
    [CmdletBinding()]
    param()

    $running = @(Get-Process -Name 'FEAR' -ErrorAction SilentlyContinue | Where-Object { -not $_.HasExited })
    if ($running.Count -gt 0) {
        throw "FEAR.exe is running (PID $(@($running.Id) -join ', ')); retail runtime files will not be installed, recovered, changed, or removed while the game is active."
    }
}

function Get-FearRetailSidecarBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Assert-FearRetailSidecarHash {
    param([Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$Description)
    if ($Value -cnotmatch '^[0-9A-F]{64}$') { throw "$Description is not an uppercase SHA-256 value." }
}

function Get-FearRetailSidecarProperty {
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name)
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) { throw "Required property '$Name' is missing." }
    return $property.Value
}

function Get-FearRetailArchiveEntries {
    param([Parameter(Mandatory)][string]$RetailRoot)
    $configPath = Join-Path $RetailRoot 'Default.archcfg'
    Assert-FearRetailSidecarOrdinaryFile -Root $RetailRoot -Path $configPath -Description 'Retail Default.archcfg' | Out-Null
    $entries = @()
    foreach ($rawLine in Get-Content -LiteralPath $configPath) {
        $entry = $rawLine.Trim()
        if (-not $entry -or $entry.StartsWith(';') -or $entry.StartsWith('#')) { continue }
        $entry = Assert-FearRetailSidecarRelativePath -RelativePath $entry
        $resource = Get-FearRetailSidecarTargetPath -Root $RetailRoot -RelativePath $entry
        Assert-FearRetailSidecarOrdinaryFile -Root $RetailRoot -Path $resource -Description 'Retail archive' | Out-Null
        $entries += $entry
    }
    if ($entries.Count -eq 0) { throw "Retail Default.archcfg has no archive entries: $configPath" }
    return $entries
}

function Test-FearRetailSidecarExactSequence {
    param([object[]]$Actual, [string[]]$Expected)
    $actualValues = @($Actual)
    if ($actualValues.Count -ne $Expected.Count) { return $false }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ([string]$actualValues[$i] -cne $Expected[$i]) { return $false }
    }
    return $true
}

function Get-FearRetailSidecarOwnedDirectories {
    param([Parameter(Mandatory)][string[]]$RelativePaths)
    $directories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relativePath in $RelativePaths) {
        $current = Split-Path (Assert-FearRetailSidecarRelativePath $relativePath) -Parent
        while ($current) {
            [void]$directories.Add($current)
            $parent = Split-Path $current -Parent
            if ($parent -eq $current) { break }
            $current = $parent
        }
    }
    return @($directories | Sort-Object { ($_ -split '\\').Count }, { $_ })
}

function Get-FearRetailSidecarIdentitySha256 {
    param(
        [Parameter(Mandatory)][string]$StageManifestSha256,
        [Parameter(Mandatory)][object[]]$ImmutableFiles,
        [Parameter(Mandatory)]$RuntimeConfig
    )
    $lines = @("Manifest=$StageManifestSha256")
    foreach ($file in @($ImmutableFiles | Sort-Object RelativePath)) {
        $lines += "Immutable=$($file.RelativePath)|$($file.Size)|$($file.Sha256)"
    }
    $lines += "MutableSeed=$($RuntimeConfig.RelativePath)|$($RuntimeConfig.SeedSize)|$($RuntimeConfig.SeedSha256)|$($RuntimeConfig.Policy)"
    Get-FearRetailSidecarBytesSha256 -Bytes ([Text.Encoding]::UTF8.GetBytes(($lines -join "`n")))
}

function Assert-FearRetailSidecarSnapshotHistoricalIdentity {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$Description
    )
    $manifestHash = [string](Get-FearRetailSidecarProperty $Snapshot 'StageManifestSha256')
    $identityHash = [string](Get-FearRetailSidecarProperty $Snapshot 'InstallIdentitySha256')
    Assert-FearRetailSidecarHash $manifestHash "$Description StageManifestSha256"
    Assert-FearRetailSidecarHash $identityHash "$Description InstallIdentitySha256"
    $immutable = @((Get-FearRetailSidecarProperty $Snapshot 'ImmutableFiles'))
    $runtimeConfig = Get-FearRetailSidecarProperty $Snapshot 'RuntimeConfig'
    $recomputed = Get-FearRetailSidecarIdentitySha256 `
        -StageManifestSha256 $manifestHash `
        -ImmutableFiles $immutable `
        -RuntimeConfig $runtimeConfig
    if ($recomputed -cne $identityHash) {
        throw "$Description historical package identity is inconsistent."
    }
}

function Test-FearRetailSidecarFileRecordSequence {
    param([object[]]$Actual, [object[]]$Expected)
    $actualValues = @($Actual)
    $expectedValues = @($Expected)
    if ($actualValues.Count -ne $expectedValues.Count) { return $false }
    for ($index = 0; $index -lt $expectedValues.Count; $index++) {
        $actual = $actualValues[$index]
        $expected = $expectedValues[$index]
        if ([string]$actual.RelativePath -cne [string]$expected.RelativePath -or
            [long]$actual.Size -ne [long]$expected.Size -or
            [string]$actual.Sha256 -cne [string]$expected.Sha256) {
            return $false
        }
        $actualKind = if ($actual.PSObject.Properties['Kind']) { [string]$actual.Kind } else { '' }
        $expectedKind = if ($expected.PSObject.Properties['Kind']) { [string]$expected.Kind } else { '' }
        if ($actualKind -cne $expectedKind) { return $false }
    }
    return $true
}

function Assert-FearRetailSidecarPackageSnapshotMatchesPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][ValidateSet('InstallRecord', 'UninstallReceipt', 'TransactionJournal')][string]$SnapshotKind,
        [string]$Description = 'ownership snapshot'
    )
    Assert-FearRetailSidecarSnapshotHistoricalIdentity -Snapshot $Snapshot -Description $Description
    # StageManifestSha256 and InstallIdentitySha256 retain installation-time
    # provenance, but they are not cross-run equality gates.  A safe stage
    # revalidation regenerates non-payload metadata such as GeneratedUtc, so
    # hashing the complete manifest makes an otherwise exact second launch
    # look like an unsupported package upgrade.  The snapshot's historical
    # identity is internally verified above.  Cross-run package equivalence is
    # instead established below from every immutable file,
    # owned directory, mutable-seed policy, and protected retail file after the
    # current source manifest has independently passed all schema/contracts.
    $snapshotImmutable = @((Get-FearRetailSidecarProperty $Snapshot 'ImmutableFiles'))
    if (-not (Test-FearRetailSidecarFileRecordSequence -Actual $snapshotImmutable -Expected @($Plan.ImmutableFiles))) {
        throw "$Description immutable file set does not exactly match the freshly validated source stage."
    }
    $snapshotDirectories = @((Get-FearRetailSidecarProperty $Snapshot 'OwnedDirectories'))
    if (-not (Test-FearRetailSidecarExactSequence -Actual $snapshotDirectories -Expected @($Plan.OwnedDirectories))) {
        throw "$Description owned-directory set does not exactly match the freshly validated source stage."
    }
    if ($SnapshotKind -in @('InstallRecord', 'UninstallReceipt')) {
        $snapshotRuntimeWritablePolicy = [string](Get-FearRetailSidecarProperty $Snapshot 'RuntimeWritablePolicy')
        if ($snapshotRuntimeWritablePolicy -cne $script:RuntimeWritablePolicy) {
            throw "$Description runtime-writable preservation policy is invalid."
        }
        $snapshotRuntimeWritableDirectories = @((Get-FearRetailSidecarProperty $Snapshot 'RuntimeWritableDirectories'))
        foreach ($relativeDirectory in $snapshotRuntimeWritableDirectories) {
            [void](Assert-FearRetailSidecarRelativePath -RelativePath ([string]$relativeDirectory))
        }
        if (-not (Test-FearRetailSidecarExactSequence `
                -Actual $snapshotRuntimeWritableDirectories `
                -Expected @($Plan.RuntimeWritableDirectories))) {
            throw "$Description runtime-writable directory set does not exactly match the freshly validated source stage."
        }
    }
    $snapshotRuntime = Get-FearRetailSidecarProperty $Snapshot 'RuntimeConfig'
    foreach ($propertyName in @('RelativePath', 'SeedSha256', 'Policy')) {
        if ([string](Get-FearRetailSidecarProperty $snapshotRuntime $propertyName) -cne [string](Get-FearRetailSidecarProperty $Plan.RuntimeConfig $propertyName)) {
            throw "$Description runtime-config policy does not exactly match the freshly validated source stage."
        }
    }
    if ([long](Get-FearRetailSidecarProperty $snapshotRuntime 'SeedSize') -ne [long]$Plan.RuntimeConfig.SeedSize) {
        throw "$Description runtime-config seed size does not exactly match the freshly validated source stage."
    }
    $snapshotProtected = @((Get-FearRetailSidecarProperty $Snapshot 'ProtectedFiles'))
    if (-not (Test-FearRetailSidecarFileRecordSequence -Actual $snapshotProtected -Expected @($Plan.ProtectedFiles))) {
        throw "$Description protected retail file set does not exactly match the freshly validated target."
    }
}

function Get-FearRetailSidecarPackagePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$RetailRoot,
        [string]$SourceManifestName = 'fearmore-stage.json',
        [Parameter(Mandatory)][string]$RuntimeConfigSeed,
        # Read-only compatibility gate used solely to validate and retire a
        # receipt created by the pre-windowing RTX profile. Normal install and
        # launch planning must never set this switch.
        [switch]$AllowLegacyWindowedReceiptRetirement
    )
    # Package identity is strictly read-only and must still be computed when a
    # mutating caller is exercising PowerShell's -WhatIf path.
    $WhatIfPreference = $false
    $stage = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
    $retail = [IO.Path]::GetFullPath($RetailRoot).TrimEnd('\')
    if ((Test-FearRetailSidecarPathsEqual $stage $retail) -or
        (Test-FearRetailSidecarPathIsBelow $stage $retail) -or
        (Test-FearRetailSidecarPathIsBelow $retail $stage)) {
        throw 'Source stage and retail target must be separate, non-nested directories.'
    }
    Assert-FearRetailSidecarPathNoReparse -Root $stage -Path $stage
    Assert-FearRetailSidecarPathNoReparse -Root $retail -Path $retail

    $manifestPath = Get-FearRetailSidecarTargetPath -Root $stage -RelativePath $SourceManifestName
    Assert-FearRetailSidecarOrdinaryFile -Root $stage -Path $manifestPath -Description 'FearMore stage manifest' | Out-Null
    try { $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json }
    catch { throw "FearMore stage manifest is unreadable: $manifestPath. $($_.Exception.Message)" }
    $inputsValidated = Get-FearRetailSidecarProperty $manifest 'InputsValidated'
    $layoutValidated = Get-FearRetailSidecarProperty $manifest 'LayoutValidated'
    $launchPermitted = Get-FearRetailSidecarProperty $manifest 'LaunchPermitted'
    $enginePatchMode = [string](Get-FearRetailSidecarProperty $manifest 'EnginePatchMode')
    $forceWindowedProperty = $manifest.PSObject.Properties['EnginePatchForceWindowed']
    $fixWindowStyleProperty = $manifest.PSObject.Properties['EnginePatchFixWindowStyle']
    $dlssFrameGenerationProperty = $manifest.PSObject.Properties['RendererRuntimeConfigSeedDlssFrameGenerationEnabled']
    $enginePatchForceWindowed = if ($forceWindowedProperty) { $forceWindowedProperty.Value } else { $null }
    $enginePatchFixWindowStyle = if ($fixWindowStyleProperty) { $fixWindowStyleProperty.Value } else { $null }
    $dlssFrameGenerationEnabled = if ($dlssFrameGenerationProperty) { $dlssFrameGenerationProperty.Value } else { $null }
    $windowedContractValid = if ($AllowLegacyWindowedReceiptRetirement) {
        # The one legacy profile had no explicit manifest fields, contained
        # ForceWindowed=0, and retained FixWindowStyle=1. Also accept an
        # explicit Boolean form so this action can retire a current receipt.
        ($null -eq $enginePatchForceWindowed -or $enginePatchForceWindowed -is [bool]) -and
        ($null -eq $enginePatchFixWindowStyle -or
            ($enginePatchFixWindowStyle -is [bool] -and $enginePatchFixWindowStyle -eq $true))
    }
    else {
        $enginePatchForceWindowed -is [bool] -and $enginePatchForceWindowed -eq $true -and
        $enginePatchFixWindowStyle -is [bool] -and $enginePatchFixWindowStyle -eq $true
    }
    $frameGenerationContractValid = if ($AllowLegacyWindowedReceiptRetirement) {
        $null -eq $dlssFrameGenerationEnabled -or
        ($dlssFrameGenerationEnabled -is [bool] -and $dlssFrameGenerationEnabled -eq $false)
    }
    else {
        $dlssFrameGenerationEnabled -is [bool] -and $dlssFrameGenerationEnabled -eq $false
    }
    if ([int](Get-FearRetailSidecarProperty $manifest 'SchemaVersion') -ne 9 -or
        [string](Get-FearRetailSidecarProperty $manifest 'Lane') -cne 'Rebuilt' -or
        [string](Get-FearRetailSidecarProperty $manifest 'RendererMode') -cne 'RtxRemixProbe' -or
        -not ($script:SupportedEnginePatchModes -ccontains $enginePatchMode) -or
        $inputsValidated -isnot [bool] -or $inputsValidated -ne $true -or
        $layoutValidated -isnot [bool] -or $layoutValidated -ne $true -or
        $launchPermitted -isnot [bool] -or $launchPermitted -ne $true -or
        -not $windowedContractValid -or
        -not $frameGenerationContractValid -or
        [string](Get-FearRetailSidecarProperty $manifest 'SteamAppId') -cne '21090') {
        throw "Retail sidecar deployment requires an exact schema-9 Rebuilt + RtxRemixProbe stage using one of the supported engine patch modes ($($script:SupportedEnginePatchModes -join ', ')), with engine-side RTX windowing enabled and the known-broken DLSS Frame Generation path seeded off."
    }
    if (-not (Test-FearRetailSidecarPathsEqual -Left ([string](Get-FearRetailSidecarProperty $manifest 'RetailRoot')) -Right $retail)) {
        throw 'Target retail root does not match the retail root recorded by the source stage manifest.'
    }
    $runtimeWritableDirectories = @((Get-FearRetailSidecarProperty $manifest 'RendererRuntimeWritableDirectories'))
    $runtimeWritableDirectories = @($runtimeWritableDirectories | ForEach-Object {
        Assert-FearRetailSidecarRelativePath -RelativePath ([string]$_)
    })
    if (-not (Test-FearRetailSidecarExactSequence `
            -Actual $runtimeWritableDirectories `
            -Expected $script:RuntimeWritableDirectories)) {
        throw "Stage manifest must declare exactly the supported renderer runtime-writable directory contract: $($script:RuntimeWritableDirectories -join ', ')."
    }
    $runtimeMutableFiles = @((Get-FearRetailSidecarProperty $manifest 'RendererRuntimeMutableFiles'))
    $runtimeMutableFiles = @($runtimeMutableFiles | ForEach-Object {
        Assert-FearRetailSidecarRelativePath -RelativePath ([string]$_)
    })
    if (-not (Test-FearRetailSidecarExactSequence `
            -Actual $runtimeMutableFiles `
            -Expected $script:RuntimeMutableFiles)) {
        throw "Stage manifest must declare exactly the supported renderer runtime-mutable file contract: $($script:RuntimeMutableFiles -join ', ')."
    }

    $retailExe = Join-Path $retail 'FEAR.exe'
    $stageExe = Join-Path $stage 'FEAR.exe'
    $retailExeItem = Assert-FearRetailSidecarOrdinaryFile -Root $retail -Path $retailExe -Description 'Retail FEAR.exe'
    Assert-FearRetailSidecarOrdinaryFile -Root $stage -Path $stageExe -Description 'Staged FEAR.exe' | Out-Null
    $expectedExeHash = [string](Get-FearRetailSidecarProperty $manifest 'RuntimeExecutableSha256')
    $expectedRetailExeHash = [string](Get-FearRetailSidecarProperty $manifest 'RetailExecutableSha256')
    Assert-FearRetailSidecarHash $expectedExeHash 'RuntimeExecutableSha256'
    Assert-FearRetailSidecarHash $expectedRetailExeHash 'RetailExecutableSha256'
    $actualRetailExeHash = Get-FearRetailSidecarSha256 $retailExe
    if ($expectedExeHash -cne $expectedRetailExeHash -or $actualRetailExeHash -cne $expectedExeHash -or
        (Get-FearRetailSidecarSha256 $stageExe) -cne $expectedExeHash) {
        throw 'Retail/staged FEAR.exe identity does not match the source stage manifest.'
    }
    $expectedVersion = [string](Get-FearRetailSidecarProperty $manifest 'FearVersion')
    $actualVersion = [string]$retailExeItem.VersionInfo.FileVersion
    if ($actualVersion -cne $expectedVersion) {
        throw "Retail FEAR.exe version '$actualVersion' does not match manifest version '$expectedVersion'."
    }

    $retailArchiveEntries = @(Get-FearRetailArchiveEntries -RetailRoot $retail)
    $expectedStageArchiveEntries = @($retailArchiveEntries | ForEach-Object { "Retail\$_" }) + @('Game')
    if (-not (Test-FearRetailSidecarExactSequence -Actual @((Get-FearRetailSidecarProperty $manifest 'ArchiveEntries')) -Expected $expectedStageArchiveEntries)) {
        throw 'Source stage archive entries do not exactly match the target retail Default.archcfg plus Game.'
    }

    $immutable = @()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rendererFiles = @((Get-FearRetailSidecarProperty $manifest 'RendererOwnedFiles'))
    if ($rendererFiles.Count -ne [int](Get-FearRetailSidecarProperty $manifest 'RendererPackageFileCount') -or $rendererFiles.Count -lt 1) {
        throw 'RendererOwnedFiles does not match RendererPackageFileCount.'
    }
    foreach ($record in $rendererFiles) {
        $relativePath = Assert-FearRetailSidecarRelativePath ([string](Get-FearRetailSidecarProperty $record 'RelativePath'))
        $size = [long](Get-FearRetailSidecarProperty $record 'Size')
        $hash = [string](Get-FearRetailSidecarProperty $record 'Sha256')
        Assert-FearRetailSidecarHash $hash "RendererOwnedFiles[$relativePath].Sha256"
        if (-not $seen.Add($relativePath)) { throw "Duplicate renderer-owned path: $relativePath" }
        $sourcePath = Get-FearRetailSidecarTargetPath $stage $relativePath
        $item = Assert-FearRetailSidecarOrdinaryFile $stage $sourcePath 'Staged renderer file'
        if ($item.Length -ne $size -or (Get-FearRetailSidecarSha256 $sourcePath) -cne $hash) {
            throw "Staged renderer file does not match its manifest identity: $relativePath"
        }
        $immutable += [pscustomobject][ordered]@{ RelativePath = $relativePath; SourcePath = $sourcePath; Size = $size; Sha256 = $hash; Kind = 'Renderer' }
    }
    $rendererProxy = Assert-FearRetailSidecarRelativePath ([string](Get-FearRetailSidecarProperty $manifest 'RendererProxyFile'))
    $rendererProxyHash = [string](Get-FearRetailSidecarProperty $manifest 'RendererProxySha256')
    $proxyRecord = @($immutable | Where-Object { $_.RelativePath -ieq $rendererProxy })
    if ($proxyRecord.Count -ne 1 -or $proxyRecord[0].Sha256 -cne $rendererProxyHash) {
        throw 'Renderer proxy identity is not backed by exactly one RendererOwnedFiles record.'
    }

    foreach ($descriptor in @(
        [pscustomobject]@{ FileProperty='RendererConfigFile'; HashProperty='RendererConfigSha256'; Kind='BridgeConfig' },
        [pscustomobject]@{ FileProperty='EnginePatchProxyFile'; HashProperty='EnginePatchProxySha256'; Kind='EnginePatchProxy' },
        [pscustomobject]@{ FileProperty='EnginePatchConfigFile'; HashProperty='EnginePatchConfigSha256'; Kind='EnginePatchConfig' }
    )) {
        $relativePath = Assert-FearRetailSidecarRelativePath ([string](Get-FearRetailSidecarProperty $manifest $descriptor.FileProperty))
        $hash = [string](Get-FearRetailSidecarProperty $manifest $descriptor.HashProperty)
        Assert-FearRetailSidecarHash $hash $descriptor.HashProperty
        if (-not $seen.Add($relativePath)) { throw "Sidecar ownership collision: $relativePath" }
        $sourcePath = Get-FearRetailSidecarTargetPath $stage $relativePath
        $item = Assert-FearRetailSidecarOrdinaryFile $stage $sourcePath "Staged $($descriptor.Kind)"
        if ((Get-FearRetailSidecarSha256 $sourcePath) -cne $hash) { throw "Staged $($descriptor.Kind) hash mismatch: $relativePath" }
        $immutable += [pscustomobject][ordered]@{ RelativePath=$relativePath; SourcePath=$sourcePath; Size=$item.Length; Sha256=$hash; Kind=$descriptor.Kind }
    }

    $enginePatchConfigPath = Get-FearRetailSidecarTargetPath `
        -Root $stage `
        -RelativePath ([string](Get-FearRetailSidecarProperty $manifest 'EnginePatchConfigFile'))
    $enginePatchConfigIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
        -Path $enginePatchConfigPath `
        -ExpectedMaxFPS 60.0 `
        -ExpectedDynamicVsync 1 `
        -ExpectedCameraDiagnostics 1 `
        -ExpectedRemixCameraDiagnostics 0 `
        -ExpectedRtxFocusPreservation $(if (@('RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch') -ccontains $enginePatchMode) { 1 } else { 0 }) `
        -ExpectedRtxCameraReassertion $(if ($enginePatchMode -ceq 'RtxCameraReassertionEchoPatch') { 1 } else { 0 }) `
        -ExpectedForceWindowed $(if ($AllowLegacyWindowedReceiptRetirement -and
                ($null -eq $enginePatchForceWindowed -or $enginePatchForceWindowed -eq $false)) { 0 } else { 1 }) `
        -ExpectedFixWindowStyle 1
    if ($enginePatchConfigIdentity.Sha256 -cne [string](Get-FearRetailSidecarProperty $manifest 'EnginePatchConfigSha256')) {
        throw 'Staged EchoPatch config identity does not match the manifest after validating the RTX windowed contract.'
    }

    $requiredModules = @('GameClient.dll', 'GameServer.dll', 'ClientFx.fxd')
    $modules = @((Get-FearRetailSidecarProperty $manifest 'Modules'))
    if ($modules.Count -ne $requiredModules.Count) { throw 'Stage manifest must declare exactly the three rebuilt game modules.' }
    foreach ($moduleName in $requiredModules) {
        $moduleRecords = @($modules | Where-Object { [string]$_.Name -ceq $moduleName })
        if ($moduleRecords.Count -ne 1) { throw "Stage manifest must declare exactly one $moduleName module." }
        $hash = [string](Get-FearRetailSidecarProperty $moduleRecords[0] 'Sha256')
        Assert-FearRetailSidecarHash $hash "$moduleName Sha256"
        $sourcePath = Get-FearRetailSidecarTargetPath $stage "Game\$moduleName"
        $item = Assert-FearRetailSidecarOrdinaryFile $stage $sourcePath 'Staged rebuilt module'
        if ((Get-FearRetailSidecarSha256 $sourcePath) -cne $hash) { throw "Staged rebuilt module hash mismatch: $moduleName" }
        $relativePath = "$($script:ModuleDirectoryName)\$moduleName"
        if (-not $seen.Add($relativePath)) { throw "Sidecar ownership collision: $relativePath" }
        $immutable += [pscustomobject][ordered]@{ RelativePath=$relativePath; SourcePath=$sourcePath; Size=$item.Length; Sha256=$hash; Kind='RebuiltModule' }
    }

    $archiveLines = @(
        '; Generated by FearMore retail-sidecar installer.',
        '; Launch FEAR.exe with -archcfg FearMore.archcfg.',
        ''
    ) + $retailArchiveEntries + @($script:ModuleDirectoryName, '')
    $archiveBytes = [Text.ASCIIEncoding]::new().GetBytes(($archiveLines -join "`r`n"))
    $archiveHash = Get-FearRetailSidecarBytesSha256 $archiveBytes
    if (-not $seen.Add($script:ArchiveConfigName)) { throw "Sidecar ownership collision: $($script:ArchiveConfigName)" }
    $immutable += [pscustomobject][ordered]@{
        RelativePath=$script:ArchiveConfigName; SourcePath=$null; Size=$archiveBytes.Length; Sha256=$archiveHash;
        Kind='GeneratedArchiveConfig'; GeneratedBytes=$archiveBytes
    }

    $seedPath = [IO.Path]::GetFullPath($RuntimeConfigSeed)
    $seedRoot = Split-Path $seedPath -Parent
    Assert-FearRetailSidecarOrdinaryFile $seedRoot $seedPath 'Tracked Remix 1.5.2 Custom + ReSTIR GI runtime seed' | Out-Null
    $seedHash = Get-FearRetailSidecarSha256 $seedPath
    $expectedSeedHash = [string](Get-FearRetailSidecarProperty $manifest 'RendererRuntimeConfigSeedSha256')
    Assert-FearRetailSidecarHash $expectedSeedHash 'RendererRuntimeConfigSeedSha256'
    if ($seedHash -cne $expectedSeedHash -or
        [string](Get-FearRetailSidecarProperty $manifest 'RendererRuntimeConfigSeedPolicy') -cne 'NewStageOnly') {
        throw 'Tracked Remix 1.5.2 Custom + ReSTIR GI runtime seed does not match the stage manifest seed identity/policy.'
    }
    if (-not $seen.Add($script:RuntimeConfigName)) { throw "Sidecar ownership collision: $($script:RuntimeConfigName)" }
    $seedItem = Get-Item -LiteralPath $seedPath
    $runtimeConfig = [pscustomobject][ordered]@{
        RelativePath=$script:RuntimeConfigName; SourcePath=$seedPath; SeedSize=$seedItem.Length; SeedSha256=$seedHash;
        Policy='SeedOncePreserveUserEdits'
    }

    foreach ($reserved in @($script:InstallRecordName, $script:UninstallReceiptName, $script:TransactionJournalName, $script:TransactionBackupName)) {
        if ($seen.Contains($reserved)) { throw "Package collides with installer-reserved path: $reserved" }
    }
    $protected = @()
    foreach ($relativePath in @('FEAR.exe', 'Default.archcfg') + $retailArchiveEntries) {
        $path = Get-FearRetailSidecarTargetPath $retail $relativePath
        $item = Assert-FearRetailSidecarOrdinaryFile $retail $path 'Protected retail file'
        $protected += [pscustomobject][ordered]@{ RelativePath=$relativePath; Size=$item.Length; Sha256=(Get-FearRetailSidecarSha256 $path) }
    }
    $manifestHash = Get-FearRetailSidecarSha256 $manifestPath
    $identityHash = Get-FearRetailSidecarIdentitySha256 -StageManifestSha256 $manifestHash -ImmutableFiles $immutable -RuntimeConfig $runtimeConfig
    $ownedDirectories = @(Get-FearRetailSidecarOwnedDirectories -RelativePaths (@($immutable.RelativePath) + @($runtimeConfig.RelativePath)))
    [pscustomobject]@{
        SchemaVersion=1; StageRoot=$stage; RetailRoot=$retail; ManifestPath=$manifestPath; ManifestSha256=$manifestHash;
        FearVersion=$expectedVersion; RetailExecutableSha256=$actualRetailExeHash; ImmutableFiles=@($immutable);
        RuntimeConfig=$runtimeConfig; OwnedDirectories=$ownedDirectories; ProtectedFiles=$protected;
        ArchiveConfigBytes=$archiveBytes; InstallIdentitySha256=$identityHash;
        RuntimeWritableDirectories=@($runtimeWritableDirectories); RuntimeMutableFiles=@($runtimeMutableFiles);
        SourceManifest=$manifest
    }
}

function Assert-FearRetailSidecarOwnedTreeExact {
    param([Parameter(Mandatory)][string]$RetailRoot, [Parameter(Mandatory)]$Record)
    $allowed = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($file in @($Record.ImmutableFiles)) { [void]$allowed.Add([string]$file.RelativePath) }
    [void]$allowed.Add([string]$Record.RuntimeConfig.RelativePath)
    foreach ($relativeDirectory in @($Record.OwnedDirectories | Sort-Object { ($_ -split '\\').Count })) {
        $directory = Get-FearRetailSidecarTargetPath $RetailRoot ([string]$relativeDirectory)
        Assert-FearRetailSidecarPathNoReparse -Root $RetailRoot -Path $directory
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw "Owned sidecar directory is missing: $directory" }
    }
    foreach ($topDirectory in @($Record.OwnedDirectories | Where-Object { -not (Split-Path ([string]$_) -Parent) })) {
        $topPath = Get-FearRetailSidecarTargetPath $RetailRoot ([string]$topDirectory)
        $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($topPath)
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            foreach ($item in @(Get-ChildItem -LiteralPath $current -Force)) {
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Owned sidecar tree contains a reparse point: $($item.FullName)" }
                if ($item.PSIsContainer) { $queue.Enqueue($item.FullName); continue }
                $relative = $item.FullName.Substring(([IO.Path]::GetFullPath($RetailRoot).TrimEnd('\')).Length).TrimStart('\')
                if (-not $allowed.Contains($relative)) { throw "Owned sidecar tree contains an unowned file: $relative" }
            }
        }
    }
}

function Get-FearRetailSidecarInstalledState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RetailRoot, [switch]$AllowMissingRecord)
    $retail = [IO.Path]::GetFullPath($RetailRoot).TrimEnd('\')
    Assert-FearRetailSidecarPathNoReparse -Root $retail -Path $retail
    $recordPath = Join-Path $retail $script:InstallRecordName
    if (-not (Test-Path -LiteralPath $recordPath)) {
        if ($AllowMissingRecord) { return $null }
        throw "FearMore retail sidecars are not installed: $recordPath"
    }
    Assert-FearRetailSidecarOrdinaryFile $retail $recordPath 'FearMore retail install record' | Out-Null
    try { $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json }
    catch { throw "FearMore retail install record is unreadable: $recordPath. $($_.Exception.Message)" }
    if ([int](Get-FearRetailSidecarProperty $record 'SchemaVersion') -ne 1 -or
        -not (Test-FearRetailSidecarPathsEqual ([string](Get-FearRetailSidecarProperty $record 'RetailRoot')) $retail)) {
        throw 'FearMore retail install record has an unsupported schema or target root.'
    }
    $immutable = @((Get-FearRetailSidecarProperty $record 'ImmutableFiles'))
    $runtimeConfig = Get-FearRetailSidecarProperty $record 'RuntimeConfig'
    $protected = @((Get-FearRetailSidecarProperty $record 'ProtectedFiles'))
    $ownedDirectories = @((Get-FearRetailSidecarProperty $record 'OwnedDirectories'))
    if ($immutable.Count -lt 1 -or $protected.Count -lt 3 -or $ownedDirectories.Count -lt 1) { throw 'FearMore retail install record is incomplete.' }
    foreach ($file in $protected) {
        $path = Get-FearRetailSidecarTargetPath $retail ([string](Get-FearRetailSidecarProperty $file 'RelativePath'))
        $item = Assert-FearRetailSidecarOrdinaryFile $retail $path 'Protected retail file'
        $hash = [string](Get-FearRetailSidecarProperty $file 'Sha256'); Assert-FearRetailSidecarHash $hash 'Protected file hash'
        if ($item.Length -ne [long]$file.Size -or (Get-FearRetailSidecarSha256 $path) -cne $hash) { throw "Protected retail file changed after sidecar installation: $path" }
    }
    foreach ($file in $immutable) {
        $path = Get-FearRetailSidecarTargetPath $retail ([string](Get-FearRetailSidecarProperty $file 'RelativePath'))
        $item = Assert-FearRetailSidecarOrdinaryFile $retail $path 'Immutable FearMore sidecar file'
        $hash = [string](Get-FearRetailSidecarProperty $file 'Sha256'); Assert-FearRetailSidecarHash $hash 'Immutable file hash'
        if ($item.Length -ne [long]$file.Size -or (Get-FearRetailSidecarSha256 $path) -cne $hash) { throw "Immutable FearMore sidecar file changed; refusing mutation: $path" }
    }
    $runtimePath = Get-FearRetailSidecarTargetPath $retail ([string](Get-FearRetailSidecarProperty $runtimeConfig 'RelativePath'))
    $seedHash = [string](Get-FearRetailSidecarProperty $runtimeConfig 'SeedSha256'); Assert-FearRetailSidecarHash $seedHash 'Runtime seed hash'
    $runtimeStatus = 'Missing'
    if (Test-Path -LiteralPath $runtimePath) {
        $runtimeItem = Assert-FearRetailSidecarOrdinaryFile $retail $runtimePath 'FearMore mutable runtime config'
        $runtimeStatus = if ($runtimeItem.Length -eq [long]$runtimeConfig.SeedSize -and
            (Get-FearRetailSidecarSha256 $runtimePath) -ceq $seedHash) { 'ExactSeed' } else { 'Changed' }
    }
    $recordForTree = [pscustomobject]@{ ImmutableFiles=$immutable; RuntimeConfig=$runtimeConfig; OwnedDirectories=$ownedDirectories }
    Assert-FearRetailSidecarOwnedTreeExact -RetailRoot $retail -Record $recordForTree
    Assert-FearRetailSidecarSnapshotHistoricalIdentity -Snapshot $record -Description 'FearMore retail install record'
    [pscustomobject]@{
        RetailRoot=$retail; RecordPath=$recordPath; Record=$record; RuntimeConfigPath=$runtimePath;
        RuntimeConfigStatus=$runtimeStatus; RuntimeConfigChanged=($runtimeStatus -eq 'Changed'); RuntimeConfigMissing=($runtimeStatus -eq 'Missing')
    }
}

function Get-FearRetailSidecarInstallState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    $installed = Get-FearRetailSidecarInstalledState -RetailRoot $Plan.RetailRoot -AllowMissingRecord
    if ($installed) {
        if (Test-Path -LiteralPath (Join-Path $Plan.RetailRoot $script:UninstallReceiptName)) {
            throw 'An uninstall preservation receipt unexpectedly coexists with an active install record.'
        }
        Assert-FearRetailSidecarPackageSnapshotMatchesPlan -Snapshot $installed.Record -Plan $Plan -SnapshotKind InstallRecord -Description 'FearMore retail install record'
        return [pscustomobject]@{ State='InstalledExact'; Installed=$installed; Conflicts=@() }
    }
    $receiptPath = Join-Path $Plan.RetailRoot $script:UninstallReceiptName
    $receipt = $null
    if (Test-Path -LiteralPath $receiptPath) {
        Assert-FearRetailSidecarOrdinaryFile $Plan.RetailRoot $receiptPath 'FearMore uninstall preservation receipt' | Out-Null
        try { $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json }
        catch { throw "FearMore uninstall preservation receipt is unreadable: $receiptPath" }
        if ([int](Get-FearRetailSidecarProperty $receipt 'SchemaVersion') -ne 1 -or
            -not (Test-FearRetailSidecarPathsEqual ([string](Get-FearRetailSidecarProperty $receipt 'RetailRoot')) $Plan.RetailRoot)) {
            throw 'FearMore uninstall preservation receipt has an unsupported schema or retail root.'
        }
        Assert-FearRetailSidecarPackageSnapshotMatchesPlan -Snapshot $receipt -Plan $Plan -SnapshotKind UninstallReceipt -Description 'FearMore uninstall preservation receipt'
        $receiptStatus = [string](Get-FearRetailSidecarProperty $receipt 'RuntimeConfigStatus')
        $runtimePath = Get-FearRetailSidecarTargetPath $Plan.RetailRoot $Plan.RuntimeConfig.RelativePath
        if ($receiptStatus -eq 'Changed') {
            if (-not (Test-Path -LiteralPath $runtimePath -PathType Leaf)) { throw 'Preserved runtime config recorded by the uninstall receipt is missing.' }
            Assert-FearRetailSidecarOrdinaryFile $Plan.RetailRoot $runtimePath 'Preserved runtime config' | Out-Null
            $preservedHash = [string](Get-FearRetailSidecarProperty $receipt 'PreservedRuntimeConfigSha256')
            Assert-FearRetailSidecarHash $preservedHash 'Preserved runtime config hash'
            if ((Get-FearRetailSidecarSha256 $runtimePath) -cne $preservedHash -or
                (Get-Item -LiteralPath $runtimePath).Length -ne [long](Get-FearRetailSidecarProperty $receipt 'PreservedRuntimeConfigSize')) {
                throw 'Preserved runtime config changed after uninstall; reinstall fails closed.'
            }
        }
        elseif ($receiptStatus -in @('Missing', 'RemovedSeed')) {
            if (Test-Path -LiteralPath $runtimePath) { throw 'Uninstall receipt expected an absent runtime config, but the path now exists.' }
        }
        else { throw "Unsupported uninstall receipt runtime-config status: $receiptStatus" }
    }

    $conflicts = @()
    foreach ($file in @($Plan.ImmutableFiles) + @($Plan.RuntimeConfig)) {
        if ($receipt -and [string]$file.RelativePath -ieq [string]$Plan.RuntimeConfig.RelativePath) { continue }
        $path = Get-FearRetailSidecarTargetPath $Plan.RetailRoot ([string]$file.RelativePath)
        if (Test-Path -LiteralPath $path) { $conflicts += [string]$file.RelativePath }
    }
    foreach ($directory in @($Plan.OwnedDirectories)) {
        $path = Get-FearRetailSidecarTargetPath $Plan.RetailRoot ([string]$directory)
        if (Test-Path -LiteralPath $path) { $conflicts += [string]$directory }
    }
    foreach ($reserved in @($script:TransactionBackupName)) {
        if (Test-Path -LiteralPath (Join-Path $Plan.RetailRoot $reserved)) { $conflicts += $reserved }
    }
    if ($conflicts.Count -gt 0) {
        throw "First install found unowned sidecar path conflicts; nothing was changed: $(@($conflicts | Sort-Object -Unique) -join ', ')"
    }
    [pscustomobject]@{
        State=$(if ($receipt) { 'ReadyToReinstall' } else { 'ReadyToInstall' }); Installed=$null; Conflicts=@();
        UninstallReceipt=$receipt; UninstallReceiptPath=$(if ($receipt) { $receiptPath } else { $null });
        RuntimeConfigStatus=$(if ($receipt) { [string]$receipt.RuntimeConfigStatus } else { 'NotInstalled' })
    }
}

function Get-FearRetailSidecarRecoveryState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RetailRoot)
    $retail = [IO.Path]::GetFullPath($RetailRoot).TrimEnd('\')
    $journalPath = Join-Path $retail $script:TransactionJournalName
    if (-not (Test-Path -LiteralPath $journalPath)) { return $null }
    Assert-FearRetailSidecarOrdinaryFile $retail $journalPath 'FearMore sidecar transaction journal' | Out-Null
    try { $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json }
    catch { throw "FearMore sidecar transaction journal is unreadable; recovery fails closed: $journalPath" }
    if ([int](Get-FearRetailSidecarProperty $journal 'SchemaVersion') -ne 1 -or
        [string](Get-FearRetailSidecarProperty $journal 'Operation') -notin @('Install', 'Uninstall') -or
        [string](Get-FearRetailSidecarProperty $journal 'State') -notin @('Prepared', 'BackedUp', 'Committed') -or
        -not (Test-FearRetailSidecarPathsEqual ([string](Get-FearRetailSidecarProperty $journal 'RetailRoot')) $retail)) {
        throw 'FearMore sidecar transaction journal is invalid; recovery fails closed.'
    }
    foreach ($file in @((Get-FearRetailSidecarProperty $journal 'Files'))) {
        [void](Assert-FearRetailSidecarRelativePath ([string](Get-FearRetailSidecarProperty $file 'RelativePath')))
        Assert-FearRetailSidecarHash ([string](Get-FearRetailSidecarProperty $file 'Sha256')) 'Journal file hash'
    }
    foreach ($directory in @((Get-FearRetailSidecarProperty $journal 'OwnedDirectories'))) {
        [void](Assert-FearRetailSidecarRelativePath ([string]$directory))
    }
    [pscustomobject]@{ RetailRoot=$retail; JournalPath=$journalPath; Journal=$journal; BackupRoot=(Join-Path $retail $script:TransactionBackupName) }
}

Export-ModuleMember -Function `
    Get-FearRetailSidecarNames, `
    Get-FearRetailSidecarTargetPath, `
    Assert-FearRetailSidecarPathNoReparse, `
    Assert-FearRetailSidecarOrdinaryFile, `
    Get-FearRetailSidecarSha256, `
    Assert-FearRetailSidecarGameNotRunning, `
    Get-FearRetailSidecarPackagePlan, `
    Get-FearRetailSidecarInstalledState, `
    Get-FearRetailSidecarInstallState, `
    Get-FearRetailSidecarRecoveryState, `
    Assert-FearRetailSidecarPackageSnapshotMatchesPlan
