[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RetailRoot,
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [string]$StageRoot,
    [string]$LaaExecutable,
    [string]$LaaBackup,
    [ValidateSet('NativeD3D9', 'DgVoodooD3D11', 'RtxRemixProbe')]
    [string]$RendererMode = 'NativeD3D9',
    [string]$DgVoodooArchive,
    [string]$RtxRemixArchive,
    [string]$EnginePatchPackageRoot,
    [string]$EnginePatchManifest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStagePlan.psm1') -Force -ErrorAction Stop
if (-not $StageRoot) {
    $StageRoot = Join-Path $repositoryRoot 'local-runtime\fearmore-hd-texture-stage-test'
}
elseif (-not [IO.Path]::IsPathRooted($StageRoot)) {
    $StageRoot = Join-Path $repositoryRoot $StageRoot
}
$StageRoot = [IO.Path]::GetFullPath($StageRoot)

function Get-HdStageStateSnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $manifestPath = Join-Path $Root 'fearmore-stage.json'
    $executablePath = Join-Path $Root 'FEAR.exe'
    $archivePath = Join-Path $Root 'Default.archcfg'
    $mountPath = Join-Path $Root 'HDTextures'
    $mountState = 'Absent'
    $mountItem = Get-Item -LiteralPath $mountPath -Force -ErrorAction SilentlyContinue
    if ($mountItem) {
        $mountTarget = @($mountItem.Target) | Select-Object -First 1
        $mountState = "$($mountItem.LinkType)|$([IO.Path]::GetFullPath([string]$mountTarget).TrimEnd('\'))"
    }
    $recoveryFiles = @(
        'fearmore-hd-transition.json',
        'FEAR.exe.hd-transition.previous',
        'Default.archcfg.hd-transition.previous',
        'fearmore-hd-transition-files.previous'
    ) | Where-Object { Test-Path -LiteralPath (Join-Path $Root $_) }
    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $pendingDirectories = [Collections.Generic.Queue[string]]::new()
    $pendingDirectories.Enqueue($canonicalRoot)
    $managedEntries = [Collections.Generic.List[string]]::new()
    while ($pendingDirectories.Count -gt 0) {
        $currentDirectory = $pendingDirectories.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $currentDirectory -Force)) {
            $relativePath = $item.FullName.Substring($canonicalRoot.Length).TrimStart('\')
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                $targets = @($item.Target | ForEach-Object {
                    [IO.Path]::GetFullPath([string]$_).TrimEnd('\')
                }) -join ','
                $managedEntries.Add("MOUNT|$relativePath|$($item.LinkType)|$targets")
                continue
            }
            if ($item.PSIsContainer) {
                $managedEntries.Add("DIR|$relativePath|$([int]$item.Attributes)")
                $pendingDirectories.Enqueue($item.FullName)
                continue
            }
            $managedEntries.Add("FILE|$relativePath|$([int]$item.Attributes)|$($item.Length)|$((Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash)")
        }
    }
    $managedState = @($managedEntries | Sort-Object) -join ';'

    return @(
        (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash,
        (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash,
        $mountState,
        ($recoveryFiles -join ','),
        $managedState
    ) -join '|'
}

function Assert-HdLateManifestCommitFailure {
    param(
        [Parameter(Mandatory = $true)][System.Management.Automation.ErrorRecord]$Failure,
        [Parameter(Mandatory = $true)][string]$TransitionName
    )

    $isIoFailure = $Failure.Exception -is [IO.IOException] -or
        $Failure.Exception.InnerException -is [IO.IOException]
    if (-not $isIoFailure -or
        $Failure.ScriptStackTrace -notmatch '(?m)\bat Invoke-TransactionalStageOwnershipCommit,') {
        throw "$TransitionName failed before the intended locked-manifest commit point: $($Failure.Exception.Message)"
    }
}

$commonParameters = @{
    Lane           = 'Rebuilt'
    Configuration  = 'Release'
    RepositoryRoot = $repositoryRoot
    RetailRoot     = $RetailRoot
    StageRoot      = $StageRoot
    RendererMode   = $RendererMode
}
if ($PSBoundParameters.ContainsKey('EnginePatchPackageRoot') -xor $PSBoundParameters.ContainsKey('EnginePatchManifest')) {
    throw '-EnginePatchPackageRoot and -EnginePatchManifest must be supplied together.'
}
if ($RendererMode -eq 'DgVoodooD3D11') {
    if (-not $DgVoodooArchive) { throw 'DgVoodooD3D11 rollback coverage requires -DgVoodooArchive.' }
    $commonParameters.DgVoodooArchive = $DgVoodooArchive
}
elseif ($RendererMode -eq 'RtxRemixProbe') {
    if (-not $RtxRemixArchive) { throw 'RtxRemixProbe rollback coverage requires -RtxRemixArchive.' }
    if (-not $EnginePatchPackageRoot) { throw 'RtxRemixProbe rollback coverage requires the diagnostic EchoPatch package and manifest.' }
    $commonParameters.RtxRemixArchive = $RtxRemixArchive
}
if ($EnginePatchPackageRoot) {
    $commonParameters.EnginePatchMode = if ($RendererMode -eq 'RtxRemixProbe') { 'RemixDiagnosticEchoPatch' } else { 'EngineOnlyEchoPatch' }
    $commonParameters.EnginePatchPackageRoot = $EnginePatchPackageRoot
    $commonParameters.EnginePatchManifest = $EnginePatchManifest
    if ($RendererMode -ne 'RtxRemixProbe') {
        $commonParameters.MaxFPS = 144
    }
}
$fullParameters = @{} + $commonParameters
$fullParameters.HdTextureMode = 'Full'
$fullParameters.HdTexturePackRoot = $PackageRoot
if ($PSBoundParameters.ContainsKey('LaaExecutable') -xor $PSBoundParameters.ContainsKey('LaaBackup')) {
    throw '-LaaExecutable and -LaaBackup must be supplied together.'
}
if ($LaaExecutable) {
    $fullParameters.HdTextureLaaExecutable = $LaaExecutable
    $fullParameters.HdTextureLaaBackup = $LaaBackup
}

$full = & $stageScript @fullParameters
$fullManifest = Get-Content -LiteralPath (Join-Path $StageRoot 'fearmore-stage.json') -Raw | ConvertFrom-Json
$mountPath = Join-Path $StageRoot 'HDTextures'
$mount = Get-Item -LiteralPath $mountPath -Force
$mountTarget = @($mount.Target) | Select-Object -First 1
$fullArchiveEntries = @($fullManifest.ArchiveEntries)
if ($full.HdTextureMode -ne 'Full' -or $fullManifest.SchemaVersion -ne 9 -or
    $fullManifest.HdTextureMode -ne 'Full' -or
    $fullManifest.HdTextureManifestSha256 -ne 'C92E8C14ABBD5D8C306D072C2ABAD1EA22D0426182CE37E302E948EB9346D801' -or
    $fullManifest.HdTextureFileCount -ne 1882 -or $fullManifest.HdTextureTotalBytes -ne 7587319112 -or
    $mount.LinkType -ne 'Junction' -or
    -not [IO.Path]::GetFullPath([string]$mountTarget).TrimEnd('\').Equals(
        [IO.Path]::GetFullPath([string]$fullManifest.HdTextureContentRoot).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase) -or
    $fullArchiveEntries.Count -lt 2 -or
    $fullArchiveEntries[-2] -ne 'Game' -or $fullArchiveEntries[-1] -ne 'HDTextures' -or
    $full.RuntimeExecutableState -ne 'AttestedLAAForHdTextures' -or
    -not (@($full.LaunchArguments) -contains '+FearMoreHDTexturesActive')) {
    throw 'Full HD texture stage failed its mount, precedence, manifest, LAA, or launch-state contract.'
}
$rendererBridgeConfigVerified = $false
$rendererBridgeConfigJournaled = $false
$rtxBridgeConfigHash = $null
if ($RendererMode -eq 'RtxRemixProbe') {
    $rtxBridgeConfigPath = Join-Path $StageRoot '.trex\bridge.conf'
    if ($fullManifest.RendererConfigFile -cne '.trex\bridge.conf' -or
        -not (Test-Path -LiteralPath $rtxBridgeConfigPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $rtxBridgeConfigPath -Algorithm SHA256).Hash -cne [string]$fullManifest.RendererConfigSha256) {
        throw 'Full HD texture stage did not preserve exact RTX bridge-config ownership.'
    }
    $rtxBridgeConfigHash = [string]$fullManifest.RendererConfigSha256
    $rtxMutationPaths = @(Get-FearRebuiltStageMutationRelativePaths `
        -RendererMode $RendererMode `
        -RendererPackageIdentity ([pscustomobject]@{ Files = @($fullManifest.RendererOwnedFiles) }) `
        -RendererConfigFile ([string]$fullManifest.RendererConfigFile) `
        -EnginePatchMode 'RemixDiagnosticEchoPatch' `
        -GameModuleNames @('GameClient.dll', 'GameServer.dll', 'ClientFx.fxd'))
    if (@($rtxMutationPaths | Where-Object { $_ -ceq '.trex\bridge.conf' }).Count -ne 1) {
        throw 'RTX Bridge config is not covered exactly once by the Rebuilt HD transition mutation inventory.'
    }
    $rendererBridgeConfigJournaled = $true
}

$rollbackSentinelPath = Join-Path $StageRoot 'FEARDevSP.exe'
[IO.File]::WriteAllBytes($rollbackSentinelPath, [byte[]](0x46, 0x55, 0x4C, 0x4C))
$fullBeforeFailedOff = Get-HdStageStateSnapshot -Root $StageRoot
$fullRollbackVerified = $false
$manifestLock = [IO.File]::Open(
    (Join-Path $StageRoot 'fearmore-stage.json'),
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read)
try {
    try {
        $failedOffParameters = @{} + $commonParameters
        if ($EnginePatchPackageRoot -and $RendererMode -ne 'RtxRemixProbe') { $failedOffParameters.MaxFPS = 165 }
        & $stageScript @failedOffParameters -HdTextureMode Off | Out-Null
    }
    catch {
        Assert-HdLateManifestCommitFailure -Failure $_ -TransitionName 'Full-to-Off transition'
        $fullRollbackVerified = $true
    }
}
finally {
    $manifestLock.Dispose()
}
if (-not $fullRollbackVerified -or
    (Get-HdStageStateSnapshot -Root $StageRoot) -cne $fullBeforeFailedOff) {
    throw 'A failed Full-to-Off transition did not restore the exact prior managed tree, mounts, and manifest state.'
}

$off = & $stageScript @commonParameters -HdTextureMode Off
$offManifest = Get-Content -LiteralPath (Join-Path $StageRoot 'fearmore-stage.json') -Raw | ConvertFrom-Json
$offArchiveEntries = @($offManifest.ArchiveEntries)
if (($null -ne (Get-Item -LiteralPath $mountPath -Force -ErrorAction SilentlyContinue)) -or $off.HdTextureMode -ne 'Off' -or
    $offManifest.HdTextureMode -ne 'Off' -or $offManifest.HdTextureMount -or
    $offArchiveEntries.Count -lt 1 -or $offArchiveEntries[-1] -ne 'Game' -or
    $off.RuntimeExecutableState -ne 'RetailOriginal' -or
    $off.RuntimeExecutableSha256 -ne $off.RetailExecutableSha256 -or
    (@($off.LaunchArguments) -contains '+FearMoreHDTexturesActive')) {
    throw 'Turning HD textures Off did not remove the mount and restore the normal runtime contract.'
}
if ($RendererMode -eq 'RtxRemixProbe') {
    if ($offManifest.RendererConfigFile -cne '.trex\bridge.conf' -or
        [string]$offManifest.RendererConfigSha256 -cne $rtxBridgeConfigHash -or
        (Get-FileHash -LiteralPath (Join-Path $StageRoot '.trex\bridge.conf') -Algorithm SHA256).Hash -cne $rtxBridgeConfigHash) {
        throw 'Turning HD textures Off changed RTX bridge-config ownership or content.'
    }
    $rendererBridgeConfigVerified = $true
}

[IO.File]::WriteAllBytes($rollbackSentinelPath, [byte[]](0x4F, 0x46, 0x46))
$offBeforeFailedFull = Get-HdStageStateSnapshot -Root $StageRoot
$offRollbackVerified = $false
$manifestLock = [IO.File]::Open(
    (Join-Path $StageRoot 'fearmore-stage.json'),
    [IO.FileMode]::Open,
    [IO.FileAccess]::Read,
    [IO.FileShare]::Read)
try {
    try {
        $failedFullParameters = @{} + $fullParameters
        if ($EnginePatchPackageRoot -and $RendererMode -ne 'RtxRemixProbe') { $failedFullParameters.MaxFPS = 165 }
        & $stageScript @failedFullParameters | Out-Null
    }
    catch {
        Assert-HdLateManifestCommitFailure -Failure $_ -TransitionName 'Off-to-Full transition'
        $offRollbackVerified = $true
    }
}
finally {
    $manifestLock.Dispose()
}
if (-not $offRollbackVerified -or
    (Get-HdStageStateSnapshot -Root $StageRoot) -cne $offBeforeFailedFull) {
    throw 'A failed Off-to-Full transition did not restore the exact prior managed tree, mounts, and manifest state.'
}
Remove-Item -LiteralPath $rollbackSentinelPath -Force

[pscustomobject]@{
    Status             = 'PASS'
    FullManifestSha256 = $full.HdTextureManifestSha256
    FullFileCount      = $full.HdTextureFileCount
    FullTotalBytes     = $full.HdTextureTotalBytes
    FullRuntimeState   = $full.RuntimeExecutableState
    OffRuntimeState    = $off.RuntimeExecutableState
    FullToOffRollback = $fullRollbackVerified
    OffToFullRollback = $offRollbackVerified
    FrameCapRollback  = [bool]($EnginePatchPackageRoot -and $RendererMode -ne 'RtxRemixProbe')
    SeededManagedFileRollback = $true
    RtxBridgeConfigJournaled = if ($RendererMode -eq 'RtxRemixProbe') { $rendererBridgeConfigJournaled } else { $null }
    RtxBridgeConfigRollback = if ($RendererMode -eq 'RtxRemixProbe') { $rendererBridgeConfigVerified } else { $null }
    RendererMode       = $RendererMode
    FinalMode          = $off.HdTextureMode
    StageRoot          = $StageRoot
}
