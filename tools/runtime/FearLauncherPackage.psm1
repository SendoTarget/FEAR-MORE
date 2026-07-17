Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:PackageIdentityFileName = 'fearmore-package.json'
$script:PackageFilesFileName = 'fearmore-package-files.json'
$script:PackageIdentityProperties = @('SchemaVersion', 'PackageId', 'Layout')
$script:PackageFilesProperties = @(
    'SchemaVersion',
    'PackageId',
    'DistributionClass',
    'BuildConfiguration',
    'SourceRepository',
    'SourceRevision',
    'SourceTreeState',
    'GeneratedUtc',
    'SupportedPresets',
    'ContainsRetailFiles',
    'ContainsHdTextures',
    'FileCount',
    'TotalBytes',
    'Files'
)
$script:PackageFileProperties = @('RelativePath', 'Classification', 'Size', 'Sha256')
$script:AllowedClassifications = @(
    'PackageIdentity',
    'ProjectScript',
    'ProjectConfig',
    'ProjectDocumentation',
    'PrivateSourceBuiltOutput',
    'PrivatePinnedDependency'
)

function ConvertTo-FearMorePackageRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0) {
        throw 'FearMore package paths cannot be empty or contain NUL characters.'
    }
    $normalized = $Path.Replace('/', '\').TrimEnd('\')
    if (-not $normalized -or $normalized.StartsWith('\') -or $normalized -match '^[A-Za-z]:') {
        throw "FearMore package paths must be relative: $Path"
    }

    $invalidCharacters = [IO.Path]::GetInvalidFileNameChars()
    $components = @($normalized -split '\\')
    foreach ($component in $components) {
        if (-not $component -or $component -in @('.', '..') -or
            $component.TrimEnd(' ', '.') -cne $component -or
            $component.IndexOfAny($invalidCharacters) -ge 0) {
            throw "FearMore package path contains an unsafe component: $Path"
        }
        $deviceStem = $component.Split('.')[0]
        if ($deviceStem -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9]|CONIN\$|CONOUT\$)$') {
            throw "FearMore package path uses a reserved Windows device name: $Path"
        }
    }
    return ($components -join '\')
}

function New-FearMorePackageMapEntry {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRelativePath,
        [string]$TargetRelativePath = $SourceRelativePath,
        [Parameter(Mandatory = $true)]
        [ValidateSet('ProjectScript', 'ProjectConfig', 'ProjectDocumentation', 'PrivateSourceBuiltOutput', 'PrivatePinnedDependency')]
        [string]$Classification
    )

    [pscustomobject]@{
        SourceRelativePath = ConvertTo-FearMorePackageRelativePath -Path $SourceRelativePath
        TargetRelativePath = ConvertTo-FearMorePackageRelativePath -Path $TargetRelativePath
        Classification     = $Classification
    }
}

function Get-FearMoreLauncherPackageAllowlist {
    [CmdletBinding()]
    param()

    $entries = [Collections.Generic.List[object]]::new()

    foreach ($path in @(
            'tools\runtime\Start-FearMore.ps1',
            'tools\runtime\New-FearRuntimeStage.ps1',
            'tools\runtime\Get-FearControllerRuntime.ps1',
            'tools\runtime\Get-FearPostProcessRuntime.ps1',
            'tools\runtime\Invoke-FearLaaBootstrap.ps1',
            'tools\runtime\New-FearHdTextureLitePackage.ps1',
            'tools\runtime\Register-FearHdTexturePack.ps1',
            'tools\runtime\Verify-FearMoreLauncherPackage.ps1',
            'tools\runtime\package\Launch FearMore.cmd',
            'tools\runtime\package\Verify FearMore Package.cmd',
            'tools\runtime\FearControllerPackage.psm1',
            'tools\runtime\FearDdsIdentity.psm1',
            'tools\runtime\FearEnginePatchPackage.psm1',
            'tools\runtime\FearLauncherPackage.psm1',
            'tools\runtime\FearLauncherProfile.psm1',
            'tools\runtime\FearLauncherSettings.psm1',
            'tools\runtime\FearPostProcessPackage.psm1',
            'tools\runtime\FearRendererPackage.psm1',
            'tools\runtime\FearRuntimeExecutable.psm1',
            'tools\runtime\FearRuntimeLayout.psm1',
            'tools\runtime\FearRuntimeStageOwnership.psm1',
            'tools\runtime\FearRuntimeStagePlan.psm1',
            'tools\runtime\FearRuntimeStageSafety.psm1',
            'tools\runtime\FearTexturePackage.psm1'
        )) {
        $targetPath = switch ($path) {
            'tools\runtime\package\Launch FearMore.cmd' { 'Launch FearMore.cmd' }
            'tools\runtime\package\Verify FearMore Package.cmd' { 'Verify FearMore Package.cmd' }
            default { $path }
        }
        $entries.Add((New-FearMorePackageMapEntry `
                    -SourceRelativePath $path `
                    -TargetRelativePath $targetPath `
                    -Classification ProjectScript))
    }

    foreach ($path in @(
            'tools\runtime\config\dgVoodoo-d3d11.conf',
            'tools\runtime\config\dgVoodoo-d3d11-max2x.conf',
            'tools\runtime\postprocess\config\FearMore-CAS.seed.ini',
            'tools\runtime\postprocess\config\ReShade.seed.ini',
            'tools\runtime\postprocess\licenses\AMD-CAS-MIT.txt',
            'tools\runtime\postprocess\licenses\ReShade-BSD-3-Clause.txt',
            'tools\runtime\postprocess\Shaders\FearMoreCAS.fx'
        )) {
        $entries.Add((New-FearMorePackageMapEntry -SourceRelativePath $path -Classification ProjectConfig))
    }

    foreach ($path in @(
            'README.md',
            'QUICKSTART.md',
            'CREDITS.md',
            'docs\playable-build.md',
            'docs\household-installer.md',
            'docs\project-installer.md',
            'docs\private-owner-build.txt',
            'docs\modern-rendering.md',
            'docs\controller-support.md',
            'docs\enhanced-gore.md',
            'docs\ai-timing.md',
            'docs\building.md',
            'docs\source-provenance.md',
            'tools\runtime\README.md'
        )) {
        $targetPath = if ($path -ceq 'docs\private-owner-build.txt') {
            'PRIVATE-OWNER-BUILD.txt'
        }
        else {
            $path
        }
        $entries.Add((New-FearMorePackageMapEntry `
                    -SourceRelativePath $path `
                    -TargetRelativePath $targetPath `
                    -Classification ProjectDocumentation))
    }

    foreach ($path in @(
            'build\fear-win32\bin\Release\ClientFx.fxd',
            'build\fear-win32\bin\Release\GameClient.dll',
            'build\fear-win32\bin\Release\GameServer.dll'
        )) {
        $entries.Add((New-FearMorePackageMapEntry -SourceRelativePath $path -Classification PrivateSourceBuiltOutput))
    }

    foreach ($path in @(
            'vendor-local\controller-deps\SDL3-3.4.10-win32-x86.zip',
            'vendor-local\renderer-deps\dgVoodoo2_87_3.zip',
            'vendor-local\EchoPatch-4.2.1.zip',
            'vendor-local\echopatch-engine-only\manifest-b4a7074e4cbb.json',
            'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb\0001-add-game-module-compatibility-switch.patch',
            'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb\0002-minhook-match-echopatch-crt.patch',
            'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb\dinput8.dll',
            'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb\EchoPatch.ini',
            'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb\LICENSE.EchoPatch-GPL-3.0.txt',
            'vendor-local\echopatch-engine-only\local-package-b4a7074e4cbb\LICENSE.MinHook-BSD-2-Clause.txt'
        )) {
        $entries.Add((New-FearMorePackageMapEntry -SourceRelativePath $path -Classification PrivatePinnedDependency))
    }

    $duplicateTargets = @(
        $entries |
            Group-Object { $_.TargetRelativePath.ToLowerInvariant() } |
            Where-Object Count -gt 1
    )
    if ($duplicateTargets.Count -gt 0) {
        throw "FearMore launcher-package allowlist contains a duplicate target: $($duplicateTargets[0].Group[0].TargetRelativePath)"
    }
    return @($entries)
}

function Assert-FearMorePackageObjectProperties {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Expected,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $actual = @($Object.PSObject.Properties.Name)
    $unexpected = @($actual | Where-Object { $Expected -cnotcontains $_ })
    $missing = @($Expected | Where-Object { $actual -cnotcontains $_ })
    if ($unexpected.Count -gt 0 -or $missing.Count -gt 0 -or $actual.Count -ne $Expected.Count) {
        throw "$Description must contain exactly: $($Expected -join ', ')."
    }
}

function Test-FearMorePackageProtectedPath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $normalized = (ConvertTo-FearMorePackageRelativePath -Path $RelativePath).ToLowerInvariant()
    $components = @($normalized -split '\\')
    if ($components | Where-Object { $_ -in @('.git', 'retail', 'local-runtime', 'userdirectory', 'texture-packs', 'fear-sdk-108', 'hdtextures') }) {
        return $true
    }
    if ($components | Where-Object { $_ -match '(^|[-_.])sky($|[-_.])' }) {
        return $true
    }
    $leaf = $components[-1]
    if ($leaf -match '\.arch\d+[a-z]?$' -or
        $leaf -in @(
            'fear.exe',
            'fearmp.exe',
            'fearlauncher.exe',
            'steam_appid.txt',
            'engineserver.dll',
            'gamedatabase.dll',
            'ltmemory.dll',
            'snddrv.dll',
            'stringeditruntime.dll'
        ) -or
        $leaf -match '\.(?:sav|dmp|mdmp|log)$' -or
        $leaf -match '^(?:screenshot|crash|dump)') {
        return $true
    }
    return $false
}

function Get-FearMoreOrdinaryPackageFiles {
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $canonicalRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    $rootItem = Get-Item -LiteralPath $canonicalRoot -Force -ErrorAction Stop
    if (-not $rootItem.PSIsContainer -or
        ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "FearMore package root must be an ordinary directory: $canonicalRoot"
    }

    $queue = [Collections.Generic.Queue[string]]::new()
    $queue.Enqueue($canonicalRoot)
    $files = [Collections.Generic.List[object]]::new()
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        foreach ($item in Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "FearMore package cannot contain a reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $queue.Enqueue($item.FullName)
                continue
            }
            $relativePath = $item.FullName.Substring($canonicalRoot.Length).TrimStart('\')
            $files.Add([pscustomobject]@{
                    File         = $item
                    RelativePath = ConvertTo-FearMorePackageRelativePath -Path $relativePath
                })
        }
    }
    return @($files)
}

function Test-FearMoreLauncherPackageIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$PackageRoot)

    $canonicalRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $canonicalRoot -PathType Container)) {
        throw "FearMore launcher package is missing: $canonicalRoot"
    }

    $identityPath = Join-Path $canonicalRoot $script:PackageIdentityFileName
    $filesPath = Join-Path $canonicalRoot $script:PackageFilesFileName
    foreach ($requiredPath in @($identityPath, $filesPath)) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "FearMore launcher package metadata is missing: $requiredPath"
        }
        $item = Get-Item -LiteralPath $requiredPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -gt 4MB) {
            throw "FearMore launcher package metadata must be an ordinary bounded file: $requiredPath"
        }
    }

    try {
        $identity = [IO.File]::ReadAllText($identityPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        $manifest = [IO.File]::ReadAllText($filesPath, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "FearMore launcher package metadata is not valid JSON. $($_.Exception.Message)"
    }
    Assert-FearMorePackageObjectProperties -Object $identity -Expected $script:PackageIdentityProperties -Description 'FearMore package identity'
    if ($identity.SchemaVersion -isnot [int] -or [int]$identity.SchemaVersion -ne 1 -or
        [string]$identity.PackageId -cne 'FearMore.Runtime' -or
        [string]$identity.Layout -cne 'LauncherPayload') {
        throw 'FearMore package identity is not the supported LauncherPayload schema.'
    }

    Assert-FearMorePackageObjectProperties -Object $manifest -Expected $script:PackageFilesProperties -Description 'FearMore package file manifest'
    if ($manifest.SchemaVersion -isnot [int] -or [int]$manifest.SchemaVersion -ne 1 -or
        [string]$manifest.PackageId -cne 'FearMore.OwnerBuild' -or
        [string]$manifest.DistributionClass -cne 'PrivateOwnerBuild' -or
        [string]$manifest.BuildConfiguration -cne 'Release' -or
        [string]$manifest.SourceRepository -cne 'https://github.com/SendoTarget/FEAR-MORE' -or
        $manifest.ContainsRetailFiles -isnot [bool] -or [bool]$manifest.ContainsRetailFiles -or
        $manifest.ContainsHdTextures -isnot [bool] -or [bool]$manifest.ContainsHdTextures) {
        throw 'FearMore package file manifest is not the supported private owner-build identity.'
    }
    $supportedPresets = @($manifest.SupportedPresets)
    if ($supportedPresets.Count -ne 2 -or $supportedPresets[0] -cne 'Stable' -or $supportedPresets[1] -cne 'Modern') {
        throw 'FearMore private owner builds must declare exactly the Stable and Modern presets.'
    }
    if ([string]$manifest.SourceRevision -notmatch '^(?:[0-9A-Fa-f]{40}|Unavailable)$' -or
        [string]$manifest.SourceTreeState -notin @('Clean', 'WorkingTreeSnapshot', 'Unavailable') -or
        [string]$manifest.GeneratedUtc -notmatch '^\d{4}-\d{2}-\d{2}T') {
        throw 'FearMore package provenance fields are malformed.'
    }

    $records = @($manifest.Files)
    if ($records.Count -eq 0 -or $manifest.FileCount -isnot [int] -or [int]$manifest.FileCount -ne $records.Count) {
        throw 'FearMore package file manifest has an invalid file count.'
    }
    $seen = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $recordTotalBytes = [long]0
    $privateFileCount = 0
    foreach ($record in $records) {
        Assert-FearMorePackageObjectProperties -Object $record -Expected $script:PackageFileProperties -Description 'FearMore package file record'
        $relativePath = ConvertTo-FearMorePackageRelativePath -Path ([string]$record.RelativePath)
        if ($relativePath -cne [string]$record.RelativePath) {
            throw "FearMore package file paths must use canonical backslashes: $($record.RelativePath)"
        }
        if ($relativePath -ieq $script:PackageFilesFileName) {
            throw 'FearMore package file manifest cannot hash itself.'
        }
        if ($seen.ContainsKey($relativePath)) {
            throw "FearMore package file manifest contains a duplicate path: $relativePath"
        }
        if (Test-FearMorePackageProtectedPath -RelativePath $relativePath) {
            throw "FearMore package file manifest contains a protected/private game-data path: $relativePath"
        }
        if ([string]$record.Classification -cnotin $script:AllowedClassifications -or
            $record.Size -isnot [long] -and $record.Size -isnot [int] -or
            [long]$record.Size -lt 0 -or
            [string]$record.Sha256 -cnotmatch '^[0-9A-F]{64}$') {
            throw "FearMore package file record is malformed: $relativePath"
        }
        $classification = [string]$record.Classification
        if ($relativePath.StartsWith('vendor-local\', [StringComparison]::OrdinalIgnoreCase)) {
            $approvedVendorPaths = @(Get-FearMoreLauncherPackageAllowlist |
                    Where-Object Classification -eq 'PrivatePinnedDependency' |
                    Select-Object -ExpandProperty TargetRelativePath)
            if ($classification -cne 'PrivatePinnedDependency' -or $approvedVendorPaths -cnotcontains $relativePath) {
                throw "FearMore package contains an unapproved vendor-local file: $relativePath"
            }
        }
        if ($relativePath.StartsWith('build\', [StringComparison]::OrdinalIgnoreCase) -and
            $classification -cne 'PrivateSourceBuiltOutput') {
            throw "FearMore package build output has the wrong private classification: $relativePath"
        }
        if ($classification -in @('PrivateSourceBuiltOutput', 'PrivatePinnedDependency')) {
            $privateFileCount++
        }
        $seen.Add($relativePath, $record)
        $recordTotalBytes += [long]$record.Size
    }
    if ($manifest.TotalBytes -isnot [long] -and $manifest.TotalBytes -isnot [int] -or
        [long]$manifest.TotalBytes -ne $recordTotalBytes) {
        throw 'FearMore package file manifest has an invalid total byte count.'
    }
    if ($privateFileCount -eq 0) {
        throw 'FearMore private owner build contains no explicitly classified private payload.'
    }

    $actualFiles = @(Get-FearMoreOrdinaryPackageFiles -PackageRoot $canonicalRoot |
            Where-Object RelativePath -cne $script:PackageFilesFileName)
    if ($actualFiles.Count -ne $records.Count) {
        throw "FearMore package file count changed. Expected $($records.Count) files but found $($actualFiles.Count)."
    }
    foreach ($actual in $actualFiles) {
        if (-not $seen.ContainsKey($actual.RelativePath)) {
            throw "FearMore package contains an unowned file: $($actual.RelativePath)"
        }
        $record = $seen[$actual.RelativePath]
        $hash = (Get-FileHash -LiteralPath $actual.File.FullName -Algorithm SHA256).Hash
        if ([long]$actual.File.Length -ne [long]$record.Size -or $hash -cne [string]$record.Sha256) {
            throw "FearMore package file identity changed: $($actual.RelativePath)"
        }
    }

    [pscustomobject]@{
        Status                 = 'PASS'
        PackageRoot            = $canonicalRoot
        DistributionClass      = 'PrivateOwnerBuild'
        SupportedPresets       = @('Stable', 'Modern')
        FileCount              = $records.Count
        TotalBytes             = $recordTotalBytes
        PrivateFileCount       = $privateFileCount
        ContainsRetailFiles    = $false
        ContainsHdTextures     = $false
        SourceRepository       = [string]$manifest.SourceRepository
        SourceRevision         = [string]$manifest.SourceRevision
        SourceTreeState        = [string]$manifest.SourceTreeState
    }
}

Export-ModuleMember -Function @(
    'Get-FearMoreLauncherPackageAllowlist',
    'Test-FearMoreLauncherPackageIntegrity'
)
