Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1') -ErrorAction Stop

function Get-FearStageManifestMode {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$LegacyDefault
    )

    $property = $Manifest.PSObject.Properties[$PropertyName]
    if (-not $property -or -not $property.Value) {
        return $LegacyDefault
    }
    return [string]$property.Value
}

function Get-FearStageOwnershipTransactionPaths {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$StageManifestName,
        [Parameter(Mandatory = $true)][string]$SteamAppIdFileName
    )

    return [pscustomobject]@{
        ManifestNew       = Join-Path $StageRoot "$StageManifestName.ownership.new"
        ManifestPrevious  = Join-Path $StageRoot "$StageManifestName.ownership.previous"
        SteamHintNew      = Join-Path $StageRoot "$SteamAppIdFileName.ownership.new"
        SteamHintPrevious = Join-Path $StageRoot "$SteamAppIdFileName.ownership.previous"
    }
}

function Assert-FearNoStageOwnershipTransactionFiles {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$StageManifestName,
        [Parameter(Mandatory = $true)][string]$SteamAppIdFileName
    )

    $paths = Get-FearStageOwnershipTransactionPaths `
        -StageRoot $StageRoot `
        -StageManifestName $StageManifestName `
        -SteamAppIdFileName $SteamAppIdFileName
    foreach ($path in @($paths.ManifestNew, $paths.ManifestPrevious, $paths.SteamHintNew, $paths.SteamHintPrevious)) {
        if (Test-Path -LiteralPath $path) {
            throw "An earlier stage-ownership commit left a recovery file. No stage files were changed; inspect and recover it manually before staging: $path"
        }
    }
}

function Get-FearSteamAppIdHintPlan {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [AllowNull()]$ExistingManifest,
        [Parameter(Mandatory = $true)][bool]$ShouldExist,
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][string]$SteamAppIdFileName,
        [Parameter(Mandatory = $true)][string]$ExpectedSha256
    )

    $path = Join-Path $StageRoot $SteamAppIdFileName
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{
            Action         = if ($ShouldExist) { 'Create' } else { 'None' }
            Path           = $path
            ExpectedSha256 = $ExpectedSha256
        }
    }

    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $path
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    $recordedPath = if ($ExistingManifest -and $ExistingManifest.PSObject.Properties['SteamAppIdFile']) {
        [string]$ExistingManifest.SteamAppIdFile
    }
    else {
        ''
    }
    $explicitOwnership = $ExistingManifest -and
        $ExistingManifest.PSObject.Properties['SchemaVersion'] -and
        [int]$ExistingManifest.SchemaVersion -ge 5 -and
        $ExistingManifest.PSObject.Properties['SteamAppId'] -and
        $ExistingManifest.SteamAppId -eq $AppId -and
        $ExistingManifest.PSObject.Properties['SteamAppIdHintManaged'] -and
        [bool]$ExistingManifest.SteamAppIdHintManaged -and
        $ExistingManifest.PSObject.Properties['SteamAppIdFileSha256'] -and
        $ExistingManifest.SteamAppIdFileSha256 -eq $ExpectedSha256
    $legacyOwnership = $ExistingManifest -and
        $ExistingManifest.PSObject.Properties['SchemaVersion'] -and
        [int]$ExistingManifest.SchemaVersion -eq 4 -and
        -not $ExistingManifest.PSObject.Properties['SteamAppIdHintManaged'] -and
        $ExistingManifest.PSObject.Properties['SteamAppId'] -and
        $ExistingManifest.SteamAppId -eq $AppId
    $pathMatches = $recordedPath -and (Test-FearPathsEqual -Left $recordedPath -Right $path)

    if (-not ($pathMatches -and ($explicitOwnership -or $legacyOwnership) -and $actualHash -eq $ExpectedSha256)) {
        throw "Stage contains an unowned or changed steam_appid.txt. No stage files were changed; move it aside or restore the exact tool-owned state before staging: $path"
    }

    return [pscustomobject]@{
        Action         = if ($ShouldExist) { 'Preserve' } else { 'Remove' }
        Path           = $path
        ExpectedSha256 = $ExpectedSha256
    }
}

function Assert-FearExistingManagedStageFile {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$FileName,
        [Parameter(Mandatory = $true)][string]$ManifestFileProperty,
        [Parameter(Mandatory = $true)][string]$ManifestHashProperty,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $recordedFileProperty = $Manifest.PSObject.Properties[$ManifestFileProperty]
    $recordedHashProperty = $Manifest.PSObject.Properties[$ManifestHashProperty]
    if (-not $recordedFileProperty -or [string]$recordedFileProperty.Value -cne $FileName -or
        -not $recordedHashProperty -or -not [string]$recordedHashProperty.Value) {
        throw "Existing stage manifest does not own the expected $Description '$FileName'. Choose a new stage directory."
    }
    $path = Join-Path $Root $FileName
    Assert-FearSafeStageFileTarget -StageRoot $Root -Path $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Existing stage manifest owns $Description '$FileName', but the file is missing or not an ordinary file: $path"
    }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actualHash -ne [string]$recordedHashProperty.Value) {
        throw "Existing tool-owned $Description was changed. Expected $($recordedHashProperty.Value) but found ${actualHash}: $path"
    }
}

function Test-FearExactStringSequence {
    param(
        [AllowNull()][object[]]$Actual,
        [AllowNull()][string[]]$Expected
    )

    $actualValues = @($Actual)
    $expectedValues = @($Expected)
    if ($actualValues.Count -ne $expectedValues.Count) {
        return $false
    }
    for ($index = 0; $index -lt $expectedValues.Count; $index++) {
        if ([string]$actualValues[$index] -cne $expectedValues[$index]) {
            return $false
        }
    }
    return $true
}

function Assert-FearManifestIdentityProperty {
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$PropertyName,
        [Parameter(Mandatory = $true)][string]$ExpectedValue,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $property = $Manifest.PSObject.Properties[$PropertyName]
    if (-not $property -or [string]$property.Value -cne $ExpectedValue) {
        $actualValue = if ($property) { [string]$property.Value } else { '<missing>' }
        throw "Existing stage manifest $Description identity does not match the currently validated package. Expected $ExpectedValue but found $actualValue. Use a new stage directory."
    }
}

function Assert-FearExistingManagedRendererPayload {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$ExpectedPackageIdentity,
        [Parameter(Mandatory = $true)][string[]]$ExpectedRuntimeWritableDirectories,
        [Parameter(Mandatory = $true)][string[]]$ExpectedRuntimeMutableFiles,
        [Parameter(Mandatory = $true)][string[]]$ExpectedImmutableTreeRoots,
        [Parameter(Mandatory = $true)][string]$ExpectedProxyFile,
        [Parameter(Mandatory = $true)]$ExpectedConfigIdentity,
        [Parameter(Mandatory = $true)][string]$ExpectedConfigFile
    )

    $expectedArchiveHashProperty = $ExpectedPackageIdentity.PSObject.Properties['ArchiveSha256']
    $expectedFileCountProperty = $ExpectedPackageIdentity.PSObject.Properties['ArchiveFileCount']
    $expectedFilesProperty = $ExpectedPackageIdentity.PSObject.Properties['Files']
    if (-not $expectedArchiveHashProperty -or [string]$expectedArchiveHashProperty.Value -notmatch '^[0-9A-F]{64}$' -or
        -not $expectedFileCountProperty -or [int]$expectedFileCountProperty.Value -lt 1 -or
        -not $expectedFilesProperty) {
        throw 'Validated RTX Remix package identity is incomplete; ownership validation cannot continue.'
    }
    $expectedOwnedFileCount = [int]$expectedFileCountProperty.Value
    $expectedOwnedFiles = @($expectedFilesProperty.Value)
    if ($expectedOwnedFiles.Count -ne $expectedOwnedFileCount) {
        throw "Validated RTX Remix package identity file-count mismatch: expected $expectedOwnedFileCount records but found $($expectedOwnedFiles.Count)."
    }
    Assert-FearManifestIdentityProperty `
        -Manifest $Manifest `
        -PropertyName 'RendererPackageSha256' `
        -ExpectedValue ([string]$expectedArchiveHashProperty.Value) `
        -Description 'renderer package'
    $manifestFileCountProperty = $Manifest.PSObject.Properties['RendererPackageFileCount']
    if (-not $manifestFileCountProperty -or [int]$manifestFileCountProperty.Value -ne $expectedOwnedFileCount) {
        $actualFileCount = if ($manifestFileCountProperty) { [string]$manifestFileCountProperty.Value } else { '<missing>' }
        throw "Existing RTX Remix probe manifest package file count does not match the currently validated package. Expected $expectedOwnedFileCount but found $actualFileCount. Use a new stage directory."
    }

    $expectedFilesByPath = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($expectedFile in $expectedOwnedFiles) {
        $relativePathProperty = $expectedFile.PSObject.Properties['RelativePath']
        $sizeProperty = $expectedFile.PSObject.Properties['Size']
        $hashProperty = $expectedFile.PSObject.Properties['Sha256']
        if (-not $relativePathProperty -or -not [string]$relativePathProperty.Value -or
            -not $sizeProperty -or [long]$sizeProperty.Value -lt 0 -or
            -not $hashProperty -or [string]$hashProperty.Value -notmatch '^[0-9A-F]{64}$' -or
            $expectedFilesByPath.ContainsKey([string]$relativePathProperty.Value)) {
            throw 'Validated RTX Remix package identity contains an invalid or duplicate file record.'
        }
        $expectedFilesByPath.Add([string]$relativePathProperty.Value, $expectedFile)
    }
    if ($expectedFilesByPath.ContainsKey($ExpectedConfigFile)) {
        throw "RTX Remix package/config ownership collision: $ExpectedConfigFile"
    }
    Assert-FearManifestIdentityProperty `
        -Manifest $Manifest `
        -PropertyName 'RendererConfigSha256' `
        -ExpectedValue ([string]$ExpectedConfigIdentity.Sha256) `
        -Description 'RTX Remix bridge config'
    Assert-FearExistingManagedStageFile -Root $Root -Manifest $Manifest -FileName $ExpectedConfigFile `
        -ManifestFileProperty 'RendererConfigFile' -ManifestHashProperty 'RendererConfigSha256' -Description 'RTX Remix bridge config'

    $ownedFilesProperty = $Manifest.PSObject.Properties['RendererOwnedFiles']
    if (-not $ownedFilesProperty) {
        throw "Existing RTX Remix probe manifest does not declare RendererOwnedFiles. Choose a new stage directory."
    }
    $ownedFiles = @($ownedFilesProperty.Value)
    if ($ownedFiles.Count -ne $expectedOwnedFileCount) {
        throw "Existing RTX Remix probe manifest must own exactly $expectedOwnedFileCount package files; found $($ownedFiles.Count). Choose a new stage directory."
    }

    $writableDirectoriesProperty = $Manifest.PSObject.Properties['RendererRuntimeWritableDirectories']
    $mutableFilesProperty = $Manifest.PSObject.Properties['RendererRuntimeMutableFiles']
    $writableDirectories = @(if ($writableDirectoriesProperty) { @($writableDirectoriesProperty.Value) })
    $mutableFiles = @(if ($mutableFilesProperty) { @($mutableFilesProperty.Value) })
    if (-not (Test-FearExactStringSequence -Actual $writableDirectories -Expected $ExpectedRuntimeWritableDirectories) -or
        -not (Test-FearExactStringSequence -Actual $mutableFiles -Expected $ExpectedRuntimeMutableFiles)) {
        throw "Existing RTX Remix probe manifest does not declare the exact runtime-writable paths. Choose a new stage directory."
    }
    foreach ($relativeDirectory in $ExpectedRuntimeWritableDirectories) {
        $runtimeDataPath = Join-Path $Root $relativeDirectory
        Assert-FearSafeStageDirectoryTarget -StageRoot $Root -Path $runtimeDataPath
        if (-not (Test-Path -LiteralPath $runtimeDataPath -PathType Container)) {
            throw "Existing RTX Remix probe runtime-writable directory is missing or not a directory: $runtimeDataPath"
        }
    }
    foreach ($relativeFile in $ExpectedRuntimeMutableFiles) {
        $runtimeConfigPath = Join-Path $Root $relativeFile
        if (Test-Path -LiteralPath $runtimeConfigPath) {
            Assert-FearSafeStageFileTarget -StageRoot $Root -Path $runtimeConfigPath
            if (-not (Test-Path -LiteralPath $runtimeConfigPath -PathType Leaf)) {
                throw "Existing RTX Remix runtime-mutable config is not an ordinary file: $runtimeConfigPath"
            }
        }
    }

    $seenPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($ownedFile in $ownedFiles) {
        $relativePathProperty = $ownedFile.PSObject.Properties['RelativePath']
        $sizeProperty = $ownedFile.PSObject.Properties['Size']
        $hashProperty = $ownedFile.PSObject.Properties['Sha256']
        if (-not $relativePathProperty -or -not [string]$relativePathProperty.Value -or
            -not $sizeProperty -or [long]$sizeProperty.Value -lt 0 -or
            -not $hashProperty -or [string]$hashProperty.Value -notmatch '^[0-9A-F]{64}$') {
            throw "Existing RTX Remix probe manifest has an invalid RendererOwnedFiles record. Choose a new stage directory."
        }
        $relativePath = [string]$relativePathProperty.Value
        if (-not $seenPaths.Add($relativePath)) {
            throw "Existing RTX Remix probe manifest contains a duplicate owned path: $relativePath"
        }
        if (-not $expectedFilesByPath.ContainsKey($relativePath)) {
            throw "Existing RTX Remix probe manifest owned path does not match the currently validated package file set: $relativePath"
        }
        $expectedFile = $expectedFilesByPath[$relativePath]
        if ([long]$sizeProperty.Value -ne [long]$expectedFile.Size -or
            [string]$hashProperty.Value -cne [string]$expectedFile.Sha256) {
            throw "Existing RTX Remix probe manifest identity does not match the currently validated package file: $relativePath"
        }
        $path = [IO.Path]::GetFullPath((Join-Path $Root $relativePath))
        Assert-FearSafeStageFileTarget -StageRoot $Root -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Existing RTX Remix probe manifest owns '$relativePath', but the file is missing or not an ordinary file: $path"
        }
        $actualSize = (Get-Item -LiteralPath $path).Length
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        if ($actualSize -ne [long]$expectedFile.Size -or $actualHash -ne [string]$expectedFile.Sha256) {
            throw "Existing tool-owned RTX Remix payload was changed: $relativePath"
        }
    }
    if ($seenPaths.Count -ne $expectedFilesByPath.Count) {
        throw 'Existing RTX Remix probe manifest does not own the complete currently validated package file set.'
    }

    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    foreach ($immutableTreeRoot in $ExpectedImmutableTreeRoots) {
        $immutableRuntimeRoot = Join-Path $Root $immutableTreeRoot
        if (-not (Test-Path -LiteralPath $immutableRuntimeRoot -PathType Container)) {
            throw "Existing RTX Remix immutable runtime directory is missing or not a directory: $immutableRuntimeRoot"
        }
        foreach ($packageTreeFile in @(Get-ChildItem -LiteralPath $immutableRuntimeRoot -Recurse -Force -File)) {
            $relativePath = $packageTreeFile.FullName.Substring($canonicalRoot.Length).TrimStart('\')
            if (-not $seenPaths.Contains($relativePath) -and $relativePath -ine $ExpectedConfigFile) {
                throw "Existing RTX Remix immutable package tree contains an unowned file: $relativePath"
            }
        }
    }

    Assert-FearExistingManagedStageFile -Root $Root -Manifest $Manifest -FileName $ExpectedProxyFile `
        -ManifestFileProperty 'RendererProxyFile' -ManifestHashProperty 'RendererProxySha256' -Description 'RTX Remix renderer proxy'
}

function Assert-FearStageProxyOwnership {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$StageLane,
        [Parameter(Mandatory = $true)]$PackagePlan,
        [Parameter(Mandatory = $true)][AllowNull()]$RendererPackageIdentity,
        [AllowNull()]$RendererConfigIdentity,
        [Parameter(Mandatory = $true)][AllowNull()]$EnginePatchPackageIdentity,
        [AllowNull()]$ExistingManifest
    )

    if ($PackagePlan.RendererMode -ne 'NativeD3D9' -and -not $RendererPackageIdentity) {
        throw "Validated renderer package identity is required for $($PackagePlan.RendererMode) ownership validation."
    }
    if ($PackagePlan.EnginePatchMode -ne 'None' -and -not $EnginePatchPackageIdentity) {
        throw "Validated engine-patch package identity is required for $($PackagePlan.EnginePatchMode) ownership validation."
    }

    foreach ($fileName in @($PackagePlan.RendererForbiddenPaths)) {
        $path = Join-Path $Root $fileName
        if (Test-Path -LiteralPath $path) {
            if ($PackagePlan.RendererMode -eq 'NativeD3D9') {
                throw "NativeD3D9 stage contains an unowned renderer proxy/config '$fileName'. Move it aside or use a separate renderer stage: $path"
            }
            if ($PackagePlan.RendererMode -eq 'DgVoodooD3D11') {
                throw "DgVoodooD3D11 stage contains an unowned RTX Remix payload marker '$fileName': $path"
            }
            throw "RtxRemixProbe stage contains an unowned dgVoodoo config: $path"
        }
    }

    if ($ExistingManifest -and $PackagePlan.RendererMode -eq 'DgVoodooD3D11') {
        Assert-FearManifestIdentityProperty `
            -Manifest $ExistingManifest `
            -PropertyName 'RendererPackageSha256' `
            -ExpectedValue ([string]$RendererPackageIdentity.ArchiveSha256) `
            -Description 'renderer package'
        Assert-FearExistingManagedStageFile -Root $Root -Manifest $ExistingManifest -FileName $PackagePlan.RendererProxyFile `
            -ManifestFileProperty 'RendererProxyFile' -ManifestHashProperty 'RendererProxySha256' -Description 'renderer proxy'
        Assert-FearExistingManagedStageFile -Root $Root -Manifest $ExistingManifest -FileName $PackagePlan.RendererConfigFile `
            -ManifestFileProperty 'RendererConfigFile' -ManifestHashProperty 'RendererConfigSha256' -Description 'renderer config'
    }
    elseif ($ExistingManifest -and $PackagePlan.RendererMode -eq 'RtxRemixProbe') {
        if (-not $RendererConfigIdentity) {
            throw 'Validated RTX Remix bridge config identity is required for ownership validation.'
        }
        Assert-FearExistingManagedRendererPayload `
            -Root $Root `
            -Manifest $ExistingManifest `
            -ExpectedPackageIdentity $RendererPackageIdentity `
            -ExpectedRuntimeWritableDirectories @($PackagePlan.RendererRuntimeWritableDirectories) `
            -ExpectedRuntimeMutableFiles @($PackagePlan.RendererRuntimeMutableFiles) `
            -ExpectedImmutableTreeRoots @($PackagePlan.RendererImmutableTreeRoots) `
            -ExpectedProxyFile $PackagePlan.RendererProxyFile `
            -ExpectedConfigIdentity $RendererConfigIdentity `
            -ExpectedConfigFile $PackagePlan.RendererConfigFile
    }

    if ($StageLane -notin @('Rebuilt', 'SdkSmoke')) {
        return
    }
    if ($PackagePlan.EnginePatchMode -eq 'None') {
        foreach ($fileName in @($PackagePlan.EnginePatchForbiddenFiles)) {
            $path = Join-Path $Root $fileName
            if (Test-Path -LiteralPath $path) {
                throw "Rebuilt-module stage without an engine patch contains an unowned EchoPatch proxy/config '$fileName': $path"
            }
        }
    }
    elseif ($ExistingManifest) {
        Assert-FearManifestIdentityProperty `
            -Manifest $ExistingManifest `
            -PropertyName 'EnginePatchManifestSha256' `
            -ExpectedValue ([string]$EnginePatchPackageIdentity.ManifestSha256) `
            -Description 'engine-patch package'
        Assert-FearExistingManagedStageFile -Root $Root -Manifest $ExistingManifest -FileName 'dinput8.dll' `
            -ManifestFileProperty 'EnginePatchProxyFile' -ManifestHashProperty 'EnginePatchProxySha256' -Description 'engine patch proxy'
        Assert-FearExistingManagedStageFile -Root $Root -Manifest $ExistingManifest -FileName 'EchoPatch.ini' `
            -ManifestFileProperty 'EnginePatchConfigFile' -ManifestHashProperty 'EnginePatchConfigSha256' -Description 'engine patch config'
    }
}

function Assert-FearStagePostProcessOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$PackagePlan,
        [AllowNull()]$ExpectedPackageIdentity,
        [AllowNull()]$ExistingManifest
    )

    $existingMode = if ($ExistingManifest) {
        Get-FearStageManifestMode -Manifest $ExistingManifest -PropertyName 'PostProcessMode' -LegacyDefault 'None'
    }
    else {
        'None'
    }
    if ($existingMode -notin @('None', 'ReShadeCas')) {
        throw "Existing stage manifest declares an unsupported post-process mode '$existingMode'."
    }
    if ($PackagePlan.PostProcessMode -eq 'ReShadeCas' -and -not $ExpectedPackageIdentity) {
        throw 'Validated ReShadeCas package identity is required for post-process ownership validation.'
    }

    $everEnabled = $existingMode -eq 'ReShadeCas'
    if ($ExistingManifest -and $ExistingManifest.PSObject.Properties['PostProcessEverEnabled']) {
        $everEnabledValue = $ExistingManifest.PSObject.Properties['PostProcessEverEnabled'].Value
        if ($everEnabledValue -isnot [bool]) {
            throw 'Existing stage manifest PostProcessEverEnabled must be a JSON Boolean.'
        }
        $everEnabled = [bool]$everEnabledValue
    }
    elseif ($existingMode -eq 'ReShadeCas') {
        throw 'Existing ReShadeCas manifest is missing required Boolean ownership property PostProcessEverEnabled.'
    }
    if ($existingMode -eq 'ReShadeCas' -and -not $everEnabled) {
        throw 'Existing ReShadeCas manifest cannot declare PostProcessEverEnabled=false.'
    }

    if ($everEnabled) {
        foreach ($manifestProperty in @(
                'PostProcessRuntimeMutableFiles',
                'PostProcessRuntimeWritableDirectories',
                'PostProcessConfigSeedPolicy')) {
            if (-not $ExistingManifest.PSObject.Properties[$manifestProperty]) {
                throw "Existing post-process history is missing required mutable-state ownership property '$manifestProperty'."
            }
        }
        if ([string]$ExistingManifest.PostProcessConfigSeedPolicy -cne 'FirstEnableOnly' -or
            -not (Test-FearExactStringSequence -Actual @($ExistingManifest.PostProcessRuntimeMutableFiles) -Expected @($PackagePlan.PostProcessRuntimeMutableFiles)) -or
            -not (Test-FearExactStringSequence -Actual @($ExistingManifest.PostProcessRuntimeWritableDirectories) -Expected @($PackagePlan.PostProcessRuntimeWritableDirectories))) {
            throw 'Existing post-process history does not declare the exact first-enable and runtime-mutable ownership contract.'
        }
    }

    foreach ($relativeFile in @($PackagePlan.PostProcessRuntimeMutableFiles)) {
        $path = Join-Path $Root $relativeFile
        if (Test-Path -LiteralPath $path) {
            Assert-FearSafeStageFileTarget -StageRoot $Root -Path $path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
                throw "Post-process runtime-mutable path is not an ordinary file: $path"
            }
            if (-not $everEnabled) {
                throw "First ReShadeCas enable cannot adopt a pre-existing unowned runtime-mutable file '$relativeFile': $path"
            }
        }
    }
    foreach ($relativeDirectory in @($PackagePlan.PostProcessRuntimeWritableDirectories)) {
        $path = Join-Path $Root $relativeDirectory
        if (Test-Path -LiteralPath $path) {
            Assert-FearSafeStageDirectoryTarget -StageRoot $Root -Path $path
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                throw "Post-process runtime-writable path is not an ordinary directory: $path"
            }
            if (-not $everEnabled) {
                throw "First ReShadeCas enable cannot adopt a pre-existing unowned runtime-writable tree '$relativeDirectory': $path"
            }
        }
    }

    $expectedImmutablePaths = @($PackagePlan.PostProcessImmutableFiles)
    $expectedAssetPaths = @($PackagePlan.PostProcessAssetFiles)
    if ($existingMode -eq 'None') {
        foreach ($relativePath in $expectedImmutablePaths) {
            $path = Join-Path $Root $relativePath
            if (Test-Path -LiteralPath $path) {
                throw "Stage without ReShadeCas contains an unowned post-process proxy or immutable asset '$relativePath': $path"
            }
        }
    }
    else {
        foreach ($manifestProperty in @(
                'PostProcessPackageSha256',
                'PostProcessPackageVersion',
                'PostProcessProxyFile',
                'PostProcessProxySha256',
                'PostProcessProxySize',
                'PostProcessOwnedFiles',
                'PostProcessConfigSeedPolicy')) {
            if (-not $ExistingManifest.PSObject.Properties[$manifestProperty]) {
                throw "Existing ReShadeCas manifest is missing required ownership property '$manifestProperty'."
            }
        }
        if ([string]$ExistingManifest.PostProcessProxyFile -cne 'dxgi.dll' -or
            [string]$ExistingManifest.PostProcessProxySha256 -notmatch '^[0-9A-F]{64}$' -or
            [long]$ExistingManifest.PostProcessProxySize -lt 1 -or
            [string]$ExistingManifest.PostProcessPackageSha256 -notmatch '^[0-9A-F]{64}$' -or
            [string]$ExistingManifest.PostProcessConfigSeedPolicy -cne 'FirstEnableOnly') {
            throw 'Existing ReShadeCas manifest does not declare the exact proxy, package, seed, and runtime-mutable ownership contract.'
        }

        $ownedFiles = @($ExistingManifest.PostProcessOwnedFiles)
        if ($ownedFiles.Count -ne $expectedImmutablePaths.Count) {
            throw "Existing ReShadeCas manifest must own exactly $($expectedImmutablePaths.Count) immutable files; found $($ownedFiles.Count)."
        }
        $ownedByPath = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($record in $ownedFiles) {
            $relativePath = if ($record.PSObject.Properties['RelativePath']) { [string]$record.RelativePath } else { '' }
            if (-not $relativePath -or $relativePath -notin $expectedImmutablePaths -or
                -not $record.PSObject.Properties['Size'] -or [long]$record.Size -lt 1 -or
                -not $record.PSObject.Properties['Sha256'] -or [string]$record.Sha256 -notmatch '^[0-9A-F]{64}$' -or
                $ownedByPath.ContainsKey($relativePath)) {
                throw 'Existing ReShadeCas manifest contains an invalid, unexpected, or duplicate immutable-file record.'
            }
            $ownedByPath.Add($relativePath, $record)
        }
        foreach ($relativePath in $expectedImmutablePaths) {
            if (-not $ownedByPath.ContainsKey($relativePath)) {
                throw "Existing ReShadeCas manifest does not own immutable path '$relativePath'."
            }
            $record = $ownedByPath[$relativePath]
            $path = Join-Path $Root $relativePath
            Assert-FearSafeStageFileTarget -StageRoot $Root -Path $path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                (Get-Item -LiteralPath $path).Length -ne [long]$record.Size -or
                (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -cne [string]$record.Sha256) {
                throw "Existing tool-owned ReShadeCas immutable payload was changed or removed: $relativePath"
            }
        }
        $proxyRecord = $ownedByPath['dxgi.dll']
        if ([long]$proxyRecord.Size -ne [long]$ExistingManifest.PostProcessProxySize -or
            [string]$proxyRecord.Sha256 -cne [string]$ExistingManifest.PostProcessProxySha256) {
            throw 'Existing ReShadeCas proxy manifest identity is internally inconsistent.'
        }

        if ($ExpectedPackageIdentity) {
            if ([string]$ExistingManifest.PostProcessPackageSha256 -cne [string]$ExpectedPackageIdentity.SetupSha256 -or
                [string]$ExistingManifest.PostProcessPackageVersion -cne [string]$ExpectedPackageIdentity.ReShadeVersion -or
                [long]$ExistingManifest.PostProcessProxySize -ne [long]$ExpectedPackageIdentity.ProxySize -or
                [string]$ExistingManifest.PostProcessProxySha256 -cne [string]$ExpectedPackageIdentity.ProxySha256) {
                throw 'Existing ReShadeCas manifest identity does not match the currently validated pinned package.'
            }
            $expectedAssetsByPath = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($asset in @($ExpectedPackageIdentity.Assets.Files)) {
                $expectedAssetsByPath.Add(".fearmore\postprocess\$($asset.RelativePath)", $asset)
            }
            foreach ($relativePath in $expectedAssetPaths) {
                if (-not $expectedAssetsByPath.ContainsKey($relativePath)) {
                    throw "Validated ReShadeCas package is missing planned asset '$relativePath'."
                }
                $record = $ownedByPath[$relativePath]
                $expectedAsset = $expectedAssetsByPath[$relativePath]
                if ([long]$record.Size -ne [long]$expectedAsset.Size -or
                    [string]$record.Sha256 -cne [string]$expectedAsset.Sha256) {
                    throw "Existing ReShadeCas asset identity does not match the currently validated package: $relativePath"
                }
            }
        }
    }

    $assetTreeRoot = Join-Path $Root '.fearmore\postprocess'
    if (Test-Path -LiteralPath $assetTreeRoot) {
        Assert-FearSafeStageDirectoryTarget -StageRoot $Root -Path $assetTreeRoot
        if (-not (Test-Path -LiteralPath $assetTreeRoot -PathType Container)) {
            throw "Post-process asset root is not an ordinary directory: $assetTreeRoot"
        }
    }
    if (Test-Path -LiteralPath $assetTreeRoot -PathType Container) {
        $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
        $cachePrefix = ([IO.Path]::GetFullPath((Join-Path $Root '.fearmore\postprocess\Cache')).TrimEnd('\') + '\')
        foreach ($file in @(Get-ChildItem -LiteralPath $assetTreeRoot -Recurse -Force -File)) {
            if ($file.FullName.StartsWith($cachePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                continue
            }
            $relativePath = $file.FullName.Substring($canonicalRoot.Length).TrimStart('\')
            if ($existingMode -ne 'ReShadeCas' -or $relativePath -notin $expectedAssetPaths) {
                throw "Post-process asset tree contains an unowned immutable file: $relativePath"
            }
        }
    }

    return [pscustomobject]@{
        ExistingMode = $existingMode
        EverEnabled  = $everEnabled
        FirstEnable  = $PackagePlan.PostProcessMode -eq 'ReShadeCas' -and -not $everEnabled
    }
}

function Assert-FearStageControllerOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$StageLane,
        [AllowNull()]$ExpectedPackageIdentity,
        [AllowNull()]$ExistingManifest
    )

    $runtimeFile = 'SDL3.dll'
    $licenseFile = '.fearmore\licenses\SDL3-zlib.txt'
    $managedFiles = @($runtimeFile, $licenseFile)

    if ($StageLane -ne 'Rebuilt') {
        if ($ExpectedPackageIdentity) {
            throw "Controller package identity is only valid for a Rebuilt stage, not '$StageLane'."
        }
        foreach ($relativePath in $managedFiles) {
            $path = Join-Path $Root $relativePath
            if (Test-Path -LiteralPath $path) {
                throw "Non-Rebuilt stage contains an unowned FearMore controller payload '$relativePath': $path"
            }
        }
        return [pscustomobject]@{ ExistingManaged = $false }
    }

    if (-not $ExpectedPackageIdentity) {
        throw 'Validated SDL3 controller package identity is required for a Rebuilt stage.'
    }
    if ([string]$ExpectedPackageIdentity.RuntimeFileName -cne $runtimeFile -or
        [string]$ExpectedPackageIdentity.LicenseStagePath -cne $licenseFile -or
        [string]$ExpectedPackageIdentity.ArchiveSha256 -notmatch '^[0-9A-F]{64}$' -or
        [string]$ExpectedPackageIdentity.RuntimeSha256 -notmatch '^[0-9A-F]{64}$' -or
        [string]$ExpectedPackageIdentity.LicenseSha256 -notmatch '^[0-9A-F]{64}$' -or
        [long]$ExpectedPackageIdentity.RuntimeSize -lt 1 -or
        [long]$ExpectedPackageIdentity.LicenseSize -lt 1 -or
        [string]$ExpectedPackageIdentity.RuntimeArchitecture -cne 'x86') {
        throw 'Validated SDL3 controller package identity is incomplete or incompatible with the Rebuilt x86 runtime.'
    }

    if (-not $ExistingManifest) {
        foreach ($relativePath in $managedFiles) {
            $path = Join-Path $Root $relativePath
            if (Test-Path -LiteralPath $path) {
                throw "New Rebuilt stage contains an unowned controller payload '$relativePath': $path"
            }
        }
        return [pscustomobject]@{ ExistingManaged = $false }
    }

    $controllerProperties = @(
        'ControllerPackageSha256',
        'ControllerPackageVersion',
        'ControllerRuntimeFile',
        'ControllerRuntimeSize',
        'ControllerRuntimeSha256',
        'ControllerRuntimeArchitecture',
        'ControllerLicenseFile',
        'ControllerLicenseSize',
        'ControllerLicenseSha256'
    )
    $presentPropertyCount = @($controllerProperties | Where-Object {
            $null -ne $ExistingManifest.PSObject.Properties[$_]
        }).Count

    # Schema 8 and older Rebuilt stages predate the SDL payload. They can be
    # migrated only when neither newly managed path already exists, which
    # prevents the stage tool from adopting arbitrary local DLL/license bytes.
    if ($presentPropertyCount -eq 0) {
        foreach ($relativePath in $managedFiles) {
            $path = Join-Path $Root $relativePath
            if (Test-Path -LiteralPath $path) {
                throw "Existing Rebuilt stage predates controller ownership but already contains '$relativePath'. Move it aside or use a new stage directory: $path"
            }
        }
        return [pscustomobject]@{ ExistingManaged = $false }
    }
    if ($presentPropertyCount -ne $controllerProperties.Count) {
        throw 'Existing Rebuilt stage manifest has a partial SDL3 controller ownership record. Use a new stage directory.'
    }

    Assert-FearManifestIdentityProperty `
        -Manifest $ExistingManifest `
        -PropertyName 'ControllerPackageSha256' `
        -ExpectedValue ([string]$ExpectedPackageIdentity.ArchiveSha256) `
        -Description 'controller package'
    Assert-FearManifestIdentityProperty `
        -Manifest $ExistingManifest `
        -PropertyName 'ControllerPackageVersion' `
        -ExpectedValue ([string]$ExpectedPackageIdentity.Version) `
        -Description 'controller package version'
    Assert-FearManifestIdentityProperty `
        -Manifest $ExistingManifest `
        -PropertyName 'ControllerRuntimeSha256' `
        -ExpectedValue ([string]$ExpectedPackageIdentity.RuntimeSha256) `
        -Description 'controller runtime'
    Assert-FearManifestIdentityProperty `
        -Manifest $ExistingManifest `
        -PropertyName 'ControllerLicenseSha256' `
        -ExpectedValue ([string]$ExpectedPackageIdentity.LicenseSha256) `
        -Description 'controller license'

    if ([long]$ExistingManifest.ControllerRuntimeSize -ne [long]$ExpectedPackageIdentity.RuntimeSize -or
        [long]$ExistingManifest.ControllerLicenseSize -ne [long]$ExpectedPackageIdentity.LicenseSize -or
        [string]$ExistingManifest.ControllerRuntimeArchitecture -cne 'x86') {
        throw 'Existing Rebuilt stage manifest SDL3 size or architecture does not match the currently validated package.'
    }

    Assert-FearExistingManagedStageFile `
        -Root $Root `
        -Manifest $ExistingManifest `
        -FileName $runtimeFile `
        -ManifestFileProperty 'ControllerRuntimeFile' `
        -ManifestHashProperty 'ControllerRuntimeSha256' `
        -Description 'controller runtime'
    Assert-FearExistingManagedStageFile `
        -Root $Root `
        -Manifest $ExistingManifest `
        -FileName $licenseFile `
        -ManifestFileProperty 'ControllerLicenseFile' `
        -ManifestHashProperty 'ControllerLicenseSha256' `
        -Description 'controller license'

    return [pscustomobject]@{ ExistingManaged = $true }
}

function Assert-FearStageRuntimeExecutableOwnership {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ExpectedExecutableName
    )

    $schemaProperty = $Manifest.PSObject.Properties['SchemaVersion']
    if (-not $schemaProperty -or [int]$schemaProperty.Value -lt 7) {
        return
    }

    $fileProperty = $Manifest.PSObject.Properties['RuntimeExecutable']
    $hashProperty = $Manifest.PSObject.Properties['RuntimeExecutableSha256']
    if (-not $fileProperty -or [string]$fileProperty.Value -cne $ExpectedExecutableName -or
        -not $hashProperty -or [string]$hashProperty.Value -notmatch '^[0-9A-F]{64}$') {
        throw "Existing stage manifest does not own the expected runtime executable '$ExpectedExecutableName'. Choose a new stage directory."
    }

    $path = Join-Path $Root $ExpectedExecutableName
    Assert-FearSafeStageFileTarget -StageRoot $Root -Path $path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Existing stage runtime executable is missing or not an ordinary file: $path"
    }
    $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    if ($actualHash -cne [string]$hashProperty.Value) {
        throw "Existing tool-owned runtime executable was changed. Expected $($hashProperty.Value) but found ${actualHash}: $path"
    }
}

function Assert-FearOwnedStage {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ExpectedLane,
        [Parameter(Mandatory = $true)][string]$ExpectedRendererMode,
        [Parameter(Mandatory = $true)][string]$ExpectedEnginePatchMode,
        [Parameter(Mandatory = $true)][string]$StageManifestName
    )

    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        return
    }

    $children = @(Get-ChildItem -LiteralPath $Root -Force)
    if ($children.Count -eq 0) {
        return
    }

    $manifestPath = Join-Path $Root $StageManifestName
    Assert-FearSafeStageFileTarget -StageRoot $Root -Path $manifestPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Stage '$Root' is not empty and has no FearMore stage manifest. Choose another -StageRoot; existing files will not be overwritten."
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Lane -ne $ExpectedLane) {
        throw "Stage '$Root' belongs to lane '$($manifest.Lane)', not '$ExpectedLane'. Use a separate stage directory."
    }
    $manifestRendererMode = Get-FearStageManifestMode -Manifest $manifest -PropertyName 'RendererMode' -LegacyDefault 'NativeD3D9'
    if ($manifestRendererMode -ne $ExpectedRendererMode) {
        throw "Stage '$Root' belongs to renderer mode '$manifestRendererMode', not '$ExpectedRendererMode'. Use a separate stage directory."
    }
    $manifestEnginePatchMode = Get-FearStageManifestMode -Manifest $manifest -PropertyName 'EnginePatchMode' -LegacyDefault 'None'
    if ($manifestEnginePatchMode -ne $ExpectedEnginePatchMode) {
        throw "Stage '$Root' belongs to engine patch mode '$manifestEnginePatchMode', not '$ExpectedEnginePatchMode'. Use a separate stage directory."
    }

    return $manifest
}

function Assert-FearStagePackageLayout {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$StageLane,
        [Parameter(Mandatory = $true)]$PackagePlan
    )

    if ($StageLane -in @('Rebuilt', 'SdkSmoke')) {
        if ($PackagePlan.EnginePatchMode -eq 'None') {
            foreach ($fileName in @($PackagePlan.EnginePatchForbiddenFiles)) {
                if (Test-Path -LiteralPath (Join-Path $Root $fileName)) {
                    throw "Safety check failed: rebuilt stage without an engine patch contains $fileName."
                }
            }
        }
        else {
            foreach ($fileName in @($PackagePlan.EnginePatchRequiredFiles)) {
                if (-not (Test-Path -LiteralPath (Join-Path $Root $fileName) -PathType Leaf)) {
                    throw "Engine-only EchoPatch stage is missing: $fileName"
                }
            }
        }
    }
    else {
        foreach ($echoPatchFile in @('dinput8.dll', 'EchoPatch.ini')) {
            if (-not (Test-Path -LiteralPath (Join-Path $Root $echoPatchFile) -PathType Leaf)) {
                throw "Stock EchoPatch stage is missing: $echoPatchFile"
            }
        }
    }

    foreach ($fileName in @($PackagePlan.RendererForbiddenPaths)) {
        if (Test-Path -LiteralPath (Join-Path $Root $fileName)) {
            if ($PackagePlan.RendererMode -eq 'NativeD3D9') {
                throw "Safety check failed: NativeD3D9 stage contains $fileName."
            }
            if ($PackagePlan.RendererMode -eq 'RtxRemixProbe') {
                throw 'RtxRemixProbe stage must not contain a dgVoodoo config.'
            }
            throw "Safety check failed: DgVoodooD3D11 stage contains $fileName."
        }
    }
    foreach ($fileName in @($PackagePlan.RendererRequiredFiles)) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $fileName) -PathType Leaf)) {
            throw "$($PackagePlan.RendererMode) stage is missing: $fileName"
        }
    }
    foreach ($directoryName in @($PackagePlan.RendererRequiredDirectories)) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $directoryName) -PathType Container)) {
            throw "$($PackagePlan.RendererMode) stage is missing runtime directory: $directoryName"
        }
    }

    foreach ($fileName in @($PackagePlan.PostProcessForbiddenFiles)) {
        if (Test-Path -LiteralPath (Join-Path $Root $fileName)) {
            throw "Safety check failed: stage without ReShadeCas contains $fileName."
        }
    }
    foreach ($fileName in @($PackagePlan.PostProcessRequiredFiles)) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $fileName) -PathType Leaf)) {
            throw "ReShadeCas stage is missing immutable payload: $fileName"
        }
    }
    foreach ($relativeFile in @($PackagePlan.PostProcessRuntimeMutableFiles)) {
        $path = Join-Path $Root $relativeFile
        if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "ReShadeCas runtime-mutable path is not an ordinary file: $path"
        }
    }
    foreach ($relativeDirectory in @($PackagePlan.PostProcessRuntimeWritableDirectories)) {
        $path = Join-Path $Root $relativeDirectory
        if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Container)) {
            throw "ReShadeCas runtime-writable path is not an ordinary directory: $path"
        }
    }

    foreach ($relativeFile in @($PackagePlan.ControllerRequiredFiles)) {
        $path = Join-Path $Root $relativeFile
        Assert-FearSafeStageFileTarget -StageRoot $Root -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Rebuilt controller runtime is missing an ordinary managed file: $relativeFile"
        }
    }
}

Export-ModuleMember -Function `
    Get-FearStageOwnershipTransactionPaths, `
    Assert-FearNoStageOwnershipTransactionFiles, `
    Get-FearSteamAppIdHintPlan, `
    Assert-FearStageProxyOwnership, `
    Assert-FearStagePostProcessOwnership, `
    Assert-FearStageControllerOwnership, `
    Assert-FearStageRuntimeExecutableOwnership, `
    Assert-FearOwnedStage, `
    Assert-FearStagePackageLayout
