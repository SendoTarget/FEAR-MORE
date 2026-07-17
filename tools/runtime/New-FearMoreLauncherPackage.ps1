[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    [string]$RepositoryRoot,
    [string]$OutputRoot,
    [switch]$PrivateOwnerBuild,
    [switch]$VerifyOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Package identity checks are read-only. Get-FileHash and Authenticode helpers
# otherwise inherit -WhatIf and return incomplete provider objects, so preserve
# the invocation preference for the one mutation boundary and disable it only
# during preflight.
$packageWhatIfPreference = $WhatIfPreference
$WhatIfPreference = $false

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')

$packageModule = Join-Path $PSScriptRoot 'FearLauncherPackage.psm1'
$layoutModule = Join-Path $PSScriptRoot 'FearRuntimeLayout.psm1'
$safetyModule = Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1'
$runtimeExecutableModule = Join-Path $PSScriptRoot 'FearRuntimeExecutable.psm1'
$controllerModule = Join-Path $PSScriptRoot 'FearControllerPackage.psm1'
$rendererModule = Join-Path $PSScriptRoot 'FearRendererPackage.psm1'
$enginePatchModule = Join-Path $PSScriptRoot 'FearEnginePatchPackage.psm1'
foreach ($module in @(
        $packageModule,
        $layoutModule,
        $safetyModule,
        $runtimeExecutableModule,
        $controllerModule,
        $rendererModule,
        $enginePatchModule
    )) {
    if (-not (Test-Path -LiteralPath $module -PathType Leaf)) {
        throw "FearMore package assembler dependency is missing: $module"
    }
    Import-Module $module -Force -ErrorAction Stop
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepositoryRoot 'dist\local\FearMore-Playable'
}
$OutputRoot = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($OutputRoot)) {
            $OutputRoot
        }
        else {
            Join-Path $RepositoryRoot $OutputRoot
        })).TrimEnd('\')

if ($VerifyOnly) {
    Test-FearMoreLauncherPackageIntegrity -PackageRoot $OutputRoot
    return
}
if (-not $PrivateOwnerBuild) {
    throw ('Binary assembly is intentionally owner-only. Re-run with -PrivateOwnerBuild to acknowledge that ' +
        'the rebuilt game modules and pinned local dependencies are not a public release and must not be redistributed.')
}

$runtimeLayout = Resolve-FearRuntimeLayout -SourceRoot $RepositoryRoot
if ($runtimeLayout.LayoutKind -cne 'DeveloperCheckout') {
    throw 'New-FearMoreLauncherPackage.ps1 must run from a developer checkout, not from an assembled launcher payload.'
}
$RepositoryRoot = $runtimeLayout.SourceRoot
$outputBoundary = Join-Path $RepositoryRoot 'dist\local'
if (-not (Test-FearPathIsBelow -Path $OutputRoot -Parent $outputBoundary)) {
    throw "FearMore owner packages must be emitted below the ignored local boundary '$outputBoundary': $OutputRoot"
}
if (Test-Path -LiteralPath $OutputRoot) {
    throw "FearMore package output already exists and will not be overwritten: $OutputRoot"
}

$allowlist = @(Get-FearMoreLauncherPackageAllowlist)
if ($allowlist.Count -eq 0) {
    throw 'FearMore launcher-package allowlist is empty.'
}
foreach ($entry in $allowlist) {
    $sourcePath = Join-Path $RepositoryRoot $entry.SourceRelativePath
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Allowlisted FearMore package source is missing: $sourcePath"
    }
    $sourceItem = Get-Item -LiteralPath $sourcePath -Force
    if (($sourceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Allowlisted FearMore package source must be an ordinary file: $sourcePath"
    }
    Assert-FearNoReparsePathComponents `
        -Root $RepositoryRoot `
        -Path (Split-Path $sourcePath -Parent) `
        -RequirePath `
        -Description 'launcher-package source directory'
}

# Validate every private input through its existing runtime owner before the
# single package mutation boundary. This prevents the assembler's allowlist
# from becoming a second, weaker package-identity authority.
$releaseRoot = Join-Path $RepositoryRoot 'build\fear-win32\bin\Release'
$rebuiltIdentities = [Collections.Generic.List[object]]::new()
foreach ($moduleName in @('ClientFx.fxd', 'GameClient.dll', 'GameServer.dll')) {
    $identity = Get-FearPeRuntimeIdentity -Path (Join-Path $releaseRoot $moduleName)
    if (-not (Test-FearX86Pe32Identity -Identity $identity)) {
        throw "Rebuilt Release module is not an x86 PE32 image: $($identity.Path)"
    }
    $rebuiltIdentities.Add($identity)
}

$controllerArchive = Join-Path $RepositoryRoot 'vendor-local\controller-deps\SDL3-3.4.10-win32-x86.zip'
$controllerIdentity = Get-FearControllerPackageStagePayload -ArchivePath $controllerArchive
$dgVoodooArchive = Join-Path $RepositoryRoot 'vendor-local\renderer-deps\dgVoodoo2_87_3.zip'
$rendererIdentity = Get-FearDgVoodooPackageIdentity -ArchivePath $dgVoodooArchive
$enginePatchRoot = Join-Path $RepositoryRoot 'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb'
$enginePatchManifest = Join-Path $RepositoryRoot 'vendor-local\echopatch-engine-only\manifest-b4a7074e4cbb.json'
$enginePatchIdentity = Get-FearEngineOnlyEchoPatchPackageIdentity `
    -PackageRoot $enginePatchRoot `
    -ManifestPath $enginePatchManifest
$stockEchoPatchArchive = Join-Path $RepositoryRoot 'vendor-local\EchoPatch-4.2.1.zip'
$stockEchoPatchHash = (Get-FileHash -LiteralPath $stockEchoPatchArchive -Algorithm SHA256).Hash
if ($stockEchoPatchHash -cne '5AE9BF8F4D549B0F1CD682D63B4123C2BFF2622BD2035779DF263183C61BF9AE') {
    throw "Pinned EchoPatch 4.2.1 archive identity changed: $stockEchoPatchArchive"
}

$sourceRevision = 'Unavailable'
$sourceTreeState = 'Unavailable'
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($git) {
    $revisionOutput = @(& $git.Source -C $RepositoryRoot rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -eq 0 -and $revisionOutput.Count -eq 1 -and
        [string]$revisionOutput[0] -match '^[0-9A-Fa-f]{40}$') {
        $sourceRevision = [string]$revisionOutput[0]
        $statusOutput = @(& $git.Source -C $RepositoryRoot status --porcelain 2>$null)
        $sourceTreeState = if ($LASTEXITCODE -eq 0 -and $statusOutput.Count -eq 0) {
            'Clean'
        }
        elseif ($LASTEXITCODE -eq 0) {
            'WorkingTreeSnapshot'
        }
        else {
            'Unavailable'
        }
    }
}

$outputParent = Split-Path $OutputRoot -Parent
$transactionRoot = Join-Path $outputParent ('.FearMore-Playable.' + [guid]::NewGuid().ToString('N') + '.assembling')
$WhatIfPreference = $packageWhatIfPreference
if (-not $PSCmdlet.ShouldProcess($OutputRoot, 'Assemble the private, allowlisted FearMore owner launcher package')) {
    [pscustomobject]@{
        Status            = 'WHATIF'
        OutputRoot        = $OutputRoot
        DistributionClass = 'PrivateOwnerBuild'
        PlannedFileCount  = $allowlist.Count + 1
        MutationPerformed = $false
    }
    return
}

try {
    Assert-FearNoReparsePathComponents -Root $RepositoryRoot -Path $outputParent -Description 'launcher-package output directory'
    if (-not (Test-Path -LiteralPath $outputParent)) {
        [IO.Directory]::CreateDirectory($outputParent) | Out-Null
    }
    Assert-FearNoReparsePathComponents -Root $RepositoryRoot -Path $outputParent -RequirePath -Description 'launcher-package output directory'
    [IO.Directory]::CreateDirectory($transactionRoot) | Out-Null

    foreach ($entry in $allowlist) {
        $sourcePath = Join-Path $RepositoryRoot $entry.SourceRelativePath
        $targetPath = Join-Path $transactionRoot $entry.TargetRelativePath
        $targetParent = Split-Path $targetPath -Parent
        if (-not (Test-Path -LiteralPath $targetParent)) {
            [IO.Directory]::CreateDirectory($targetParent) | Out-Null
        }
        [IO.File]::Copy($sourcePath, $targetPath, $false)
    }

    $identityPath = Join-Path $transactionRoot 'fearmore-package.json'
    $identityJson = [ordered]@{
        SchemaVersion = 1
        PackageId      = 'FearMore.Runtime'
        Layout         = 'LauncherPayload'
    } | ConvertTo-Json
    [IO.File]::WriteAllText($identityPath, $identityJson + "`n", [Text.UTF8Encoding]::new($false))

    $records = [Collections.Generic.List[object]]::new()
    $identityItem = Get-Item -LiteralPath $identityPath
    $records.Add([pscustomobject][ordered]@{
            RelativePath   = 'fearmore-package.json'
            Classification = 'PackageIdentity'
            Size           = [long]$identityItem.Length
            Sha256         = (Get-FileHash -LiteralPath $identityPath -Algorithm SHA256).Hash
        })
    foreach ($entry in $allowlist | Sort-Object TargetRelativePath) {
        $targetPath = Join-Path $transactionRoot $entry.TargetRelativePath
        $item = Get-Item -LiteralPath $targetPath -Force
        $records.Add([pscustomobject][ordered]@{
                RelativePath   = [string]$entry.TargetRelativePath
                Classification = [string]$entry.Classification
                Size           = [long]$item.Length
                Sha256         = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
            })
    }
    $orderedRecords = @($records | Sort-Object RelativePath)
    $totalBytes = [long](($orderedRecords | Measure-Object -Property Size -Sum).Sum)
    $manifest = [ordered]@{
        SchemaVersion       = 1
        PackageId           = 'FearMore.OwnerBuild'
        DistributionClass   = 'PrivateOwnerBuild'
        BuildConfiguration  = 'Release'
        SourceRepository    = 'https://github.com/SendoTarget/FEAR-MORE'
        SourceRevision      = $sourceRevision
        SourceTreeState     = $sourceTreeState
        GeneratedUtc        = [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        SupportedPresets    = @('Stable', 'Modern')
        ContainsRetailFiles = $false
        ContainsHdTextures  = $false
        FileCount           = [int]$orderedRecords.Count
        TotalBytes          = $totalBytes
        Files               = $orderedRecords
    }
    $manifestPath = Join-Path $transactionRoot 'fearmore-package-files.json'
    $manifestJson = $manifest | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($manifestPath, $manifestJson + "`n", [Text.UTF8Encoding]::new($false))

    $layoutProbeRoot = Join-Path $outputParent ('.layout-probe-' + [guid]::NewGuid().ToString('N'))
    $layoutIdentity = Resolve-FearRuntimeLayout -SourceRoot $transactionRoot -LocalAppDataRoot $layoutProbeRoot
    if ($layoutIdentity.LayoutKind -cne 'Packaged' -or (Test-Path -LiteralPath $layoutProbeRoot)) {
        throw 'Assembled payload did not pass the read-only packaged runtime-layout gate.'
    }
    $integrity = Test-FearMoreLauncherPackageIntegrity -PackageRoot $transactionRoot

    if (Test-Path -LiteralPath $OutputRoot) {
        throw "FearMore package output appeared concurrently and was not replaced: $OutputRoot"
    }
    [IO.Directory]::Move($transactionRoot, $OutputRoot)
    $completedIntegrity = Test-FearMoreLauncherPackageIntegrity -PackageRoot $OutputRoot

    [pscustomobject]@{
        Status                     = 'PASS'
        OutputRoot                 = $OutputRoot
        DistributionClass          = 'PrivateOwnerBuild'
        SupportedPresets           = @('Stable', 'Modern')
        FileCount                  = $completedIntegrity.FileCount
        TotalBytes                 = $completedIntegrity.TotalBytes
        ContainsRetailFiles        = $false
        ContainsHdTextures         = $false
        SourceRevision             = $sourceRevision
        SourceTreeState            = $sourceTreeState
        RebuiltModuleHashes        = @($rebuiltIdentities | ForEach-Object Sha256)
        ControllerArchiveSha256    = $controllerIdentity.ArchiveSha256
        RendererArchiveSha256      = $rendererIdentity.ArchiveSha256
        EnginePatchBinarySha256    = $enginePatchIdentity.BinarySha256
        PostProcessAcquisition     = 'OfficialOnDemand'
        StockEchoPatchArchiveSha256 = $stockEchoPatchHash
        MutationPerformed          = $true
    }
}
finally {
    if (Test-Path -LiteralPath $transactionRoot -PathType Container) {
        $canonicalTransaction = [IO.Path]::GetFullPath($transactionRoot)
        if (-not (Test-FearPathIsBelow -Path $canonicalTransaction -Parent $outputBoundary) -or
            -not (Split-Path $canonicalTransaction -Leaf).StartsWith('.FearMore-Playable.', [StringComparison]::Ordinal)) {
            throw "Refusing to clean an unexpected launcher-package transaction path: $canonicalTransaction"
        }
        [IO.Directory]::Delete($canonicalTransaction, $true)
    }
}
