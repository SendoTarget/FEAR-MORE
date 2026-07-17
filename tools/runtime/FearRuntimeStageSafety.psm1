Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ReadOnlyMountNames = @('Retail', 'HDTextures')

function Get-FearCanonicalPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    $expandedPath = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not [IO.Path]::IsPathRooted($expandedPath)) {
        $expandedPath = Join-Path $BasePath $expandedPath
    }

    return [IO.Path]::GetFullPath($expandedPath)
}

function Test-FearPathIsBelow {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $canonicalParent = [IO.Path]::GetFullPath($Parent).TrimEnd('\')
    $parentPrefix = $canonicalParent + [IO.Path]::DirectorySeparatorChar
    return $canonicalPath.StartsWith($parentPrefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-FearPathsEqual {
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )

    return [IO.Path]::GetFullPath($Left).TrimEnd('\').Equals(
        [IO.Path]::GetFullPath($Right).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase)
}

function Assert-FearNoReparsePathComponents {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$RequirePath,
        [string]$Description = 'writable stage path'
    )

    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-FearPathsEqual -Left $canonicalPath -Right $canonicalRoot) -and
        -not (Test-FearPathIsBelow -Path $canonicalPath -Parent $canonicalRoot)) {
        throw "$Description escapes its allowed root '$canonicalRoot': $canonicalPath"
    }

    $pathsToCheck = @($canonicalRoot)
    if (-not (Test-FearPathsEqual -Left $canonicalPath -Right $canonicalRoot)) {
        $relativePath = $canonicalPath.Substring($canonicalRoot.Length).TrimStart('\')
        $currentPath = $canonicalRoot
        foreach ($component in @($relativePath -split '\\' | Where-Object { $_ })) {
            $currentPath = Join-Path $currentPath $component
            $pathsToCheck += $currentPath
        }
    }

    foreach ($currentPath in $pathsToCheck) {
        if (-not (Test-Path -LiteralPath $currentPath)) {
            continue
        }
        $item = Get-Item -LiteralPath $currentPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsafe reparse point is not allowed in $Description components: $currentPath"
        }
        if (-not $item.PSIsContainer) {
            throw "$Description component is not a directory: $currentPath"
        }
    }

    if ($RequirePath -and -not (Test-Path -LiteralPath $canonicalPath -PathType Container)) {
        throw "$Description directory is missing: $canonicalPath"
    }
}

function Assert-FearSafeStageDirectoryTarget {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $canonicalStageRoot = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-FearPathIsBelow -Path $canonicalPath -Parent $canonicalStageRoot)) {
        throw "Generated directory target must stay inside the stage: $canonicalPath"
    }
    $relativePath = $canonicalPath.Substring($canonicalStageRoot.Length).TrimStart('\')
    $topLevelName = $relativePath -split '\\' | Select-Object -First 1
    if ($topLevelName -in $script:ReadOnlyMountNames) {
        throw "Generated directory targets must never write through the read-only $topLevelName junction: $canonicalPath"
    }

    $parentPath = Split-Path $canonicalPath -Parent
    Assert-FearNoReparsePathComponents -Root $canonicalStageRoot -Path $parentPath -RequirePath -Description 'generated stage directory'
    if (Test-Path -LiteralPath $canonicalPath) {
        $item = Get-Item -LiteralPath $canonicalPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsafe reparse point is not allowed for generated stage directory: $canonicalPath"
        }
        if (-not $item.PSIsContainer) {
            throw "Generated stage directory target is not a directory: $canonicalPath"
        }
    }
}

function Assert-FearSafeStageFileTarget {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $canonicalStageRoot = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
    $canonicalPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-FearPathIsBelow -Path $canonicalPath -Parent $canonicalStageRoot)) {
        throw "Generated file target must stay inside the stage: $canonicalPath"
    }
    $relativePath = $canonicalPath.Substring($canonicalStageRoot.Length).TrimStart('\')
    $topLevelName = $relativePath -split '\\' | Select-Object -First 1
    if ($topLevelName -in $script:ReadOnlyMountNames) {
        throw "Generated file targets must never write through the read-only $topLevelName junction: $canonicalPath"
    }

    $parentPath = Split-Path $canonicalPath -Parent
    Assert-FearNoReparsePathComponents -Root $canonicalStageRoot -Path $parentPath -RequirePath -Description 'generated stage file'
    if (Test-Path -LiteralPath $canonicalPath) {
        $item = Get-Item -LiteralPath $canonicalPath -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Unsafe reparse point is not allowed for generated stage file: $canonicalPath"
        }
        if ($item.PSIsContainer) {
            throw "Generated stage file target is a directory: $canonicalPath"
        }
    }
}

function Assert-FearIntentionalReadOnlyJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$MountName
    )

    $existingItem = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $existingItem) {
        throw "Intentional read-only $MountName junction is missing: $Path"
    }
    if (($existingItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or
        -not $existingItem.PSIsContainer -or $existingItem.LinkType -ne 'Junction') {
        throw "$MountName must be an explicitly authorized read-only directory junction: $Path"
    }

    $existingTarget = @($existingItem.Target) | Select-Object -First 1
    if (-not $existingTarget) {
        throw "Could not determine the target of the intentional $MountName junction: $Path"
    }
    $existingTargetPath = Get-FearCanonicalPath -Path $existingTarget -BasePath (Split-Path $Path -Parent)
    if (-not (Test-FearPathsEqual -Left $existingTargetPath -Right $Target)) {
        throw "Existing $MountName junction '$Path' targets '$existingTargetPath', expected '$Target'. Choose a new stage directory."
    }
}

function Assert-FearIntentionalRetailJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target
    )

    Assert-FearIntentionalReadOnlyJunction -Path $Path -Target $Target -MountName 'Retail'
}

function Assert-FearStageTreeNoUnexpectedReparsePoints {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [AllowNull()][string]$RetailTarget,
        [AllowNull()][object[]]$AuthorizedMounts
    )

    if (-not (Test-Path -LiteralPath $StageRoot -PathType Container)) {
        return
    }

    $canonicalStageRoot = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
    $mountsByPath = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    $mountDeclarations = @()
    if ($RetailTarget) {
        $mountDeclarations += [pscustomobject]@{ Name = 'Retail'; Target = $RetailTarget }
    }
    $mountDeclarations += @($AuthorizedMounts | Where-Object { $null -ne $_ })
    foreach ($mount in $mountDeclarations) {
        if (-not $mount -or -not $mount.PSObject.Properties['Name'] -or -not $mount.PSObject.Properties['Target']) {
            throw 'Authorized read-only mount declarations require Name and Target.'
        }
        $mountName = [string]$mount.Name
        if ($mountName -inotmatch '^[A-Za-z0-9_-]+$' -or $mountName -notin $script:ReadOnlyMountNames) {
            throw "Unsupported read-only stage mount name: $mountName"
        }
        $mountPath = Join-Path $canonicalStageRoot $mountName
        if ($mountsByPath.ContainsKey($mountPath)) {
            throw "Duplicate authorized read-only stage mount: $mountName"
        }
        $mountsByPath.Add($mountPath, [pscustomobject]@{
            Name = $mountName
            Target = [IO.Path]::GetFullPath([string]$mount.Target).TrimEnd('\')
        })
    }
    $pendingDirectories = [System.Collections.Generic.Queue[string]]::new()
    $pendingDirectories.Enqueue($canonicalStageRoot)
    while ($pendingDirectories.Count -gt 0) {
        $currentDirectory = $pendingDirectories.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $currentDirectory -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                if ((Test-FearPathsEqual -Left $currentDirectory -Right $canonicalStageRoot) -and
                    $mountsByPath.ContainsKey($item.FullName)) {
                    $mount = $mountsByPath[$item.FullName]
                    Assert-FearIntentionalReadOnlyJunction -Path $item.FullName -Target $mount.Target -MountName $mount.Name
                    continue
                }
                throw "Unsafe reparse point is not allowed in the writable stage tree: $($item.FullName)"
            }
            if ($item.PSIsContainer) {
                $pendingDirectories.Enqueue($item.FullName)
            }
        }
    }
}

Export-ModuleMember -Function `
    Get-FearCanonicalPath, `
    Test-FearPathIsBelow, `
    Test-FearPathsEqual, `
    Assert-FearNoReparsePathComponents, `
    Assert-FearSafeStageDirectoryTarget, `
    Assert-FearSafeStageFileTarget, `
    Assert-FearIntentionalReadOnlyJunction, `
    Assert-FearIntentionalRetailJunction, `
    Assert-FearStageTreeNoUnexpectedReparsePoints
