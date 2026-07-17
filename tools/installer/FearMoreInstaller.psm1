Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-FearInstallerReparsePoint {
    param([Parameter(Mandatory = $true)]$Item)

    return (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Assert-FearInstallerDirectoryChain {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $canonicalRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $canonicalPath = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not ($canonicalPath -ieq $canonicalRoot -or
            $canonicalPath.StartsWith($canonicalRoot + '\', [StringComparison]::OrdinalIgnoreCase))) {
        throw "FearMore installer path escapes its selected root: $canonicalPath"
    }
    $cursor = $canonicalPath
    while ($cursor -and $cursor.Length -ge $canonicalRoot.Length) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or (Test-FearInstallerReparsePoint -Item $item)) {
                throw "FearMore installer path contains a non-directory or reparse point: $cursor"
            }
        }
        if ($cursor -ieq $canonicalRoot) { break }
        $cursor = Split-Path $cursor -Parent
    }
    return $canonicalPath
}

function Install-FearMoreLauncherPayload {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)][string]$PayloadRoot,
        [Parameter(Mandatory = $true)][string]$FearMoreRoot
    )

    $source = [IO.Path]::GetFullPath($PayloadRoot).TrimEnd('\')
    $root = [IO.Path]::GetFullPath($FearMoreRoot).TrimEnd('\')
    $target = Join-Path $root 'Launcher'
    $transaction = Join-Path $root ('.Launcher.' + [guid]::NewGuid().ToString('N') + '.installing')
    $backup = Join-Path $root ('.Launcher.' + [guid]::NewGuid().ToString('N') + '.previous')
    $packageModule = Join-Path $source 'tools\runtime\FearLauncherPackage.psm1'
    if (-not (Test-Path -LiteralPath $packageModule -PathType Leaf)) {
        throw "FearMore launcher payload verifier is missing: $packageModule"
    }
    Import-Module $packageModule -Force -ErrorAction Stop
    $sourceIdentity = Test-FearMoreLauncherPackageIntegrity -PackageRoot $source

    if (Test-Path -LiteralPath $root) {
        $null = Assert-FearInstallerDirectoryChain -Root $root -Path $root
    }
    if (Test-Path -LiteralPath $target) {
        $null = Assert-FearInstallerDirectoryChain -Root $root -Path $target
        $null = Test-FearMoreLauncherPackageIntegrity -PackageRoot $target
    }
    foreach ($unexpected in @($transaction, $backup)) {
        if (Test-Path -LiteralPath $unexpected) {
            throw "A prior FearMore installer transaction needs inspection before retrying: $unexpected"
        }
    }

    if (-not $PSCmdlet.ShouldProcess($target, 'Install the validated FearMore launcher payload transactionally')) {
        return [pscustomobject]@{ Installed = $false; Target = $target; FileCount = $sourceIdentity.FileCount }
    }

    [IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        [IO.Directory]::CreateDirectory($transaction) | Out-Null
        foreach ($file in Get-ChildItem -LiteralPath $source -File -Recurse -Force) {
            if (Test-FearInstallerReparsePoint -Item $file) {
                throw "FearMore launcher payload contains a reparse point: $($file.FullName)"
            }
            $relative = $file.FullName.Substring($source.Length).TrimStart('\')
            $destination = Join-Path $transaction $relative
            [IO.Directory]::CreateDirectory((Split-Path $destination -Parent)) | Out-Null
            [IO.File]::Copy($file.FullName, $destination, $false)
        }
        $null = Test-FearMoreLauncherPackageIntegrity -PackageRoot $transaction
        if (Test-Path -LiteralPath $target) {
            [IO.Directory]::Move($target, $backup)
        }
        [IO.Directory]::Move($transaction, $target)
        $completed = Test-FearMoreLauncherPackageIntegrity -PackageRoot $target
        if (Test-Path -LiteralPath $backup) {
            [IO.Directory]::Delete($backup, $true)
        }
        [pscustomobject]@{
            Installed  = $true
            Target     = $target
            FileCount  = $completed.FileCount
            TotalBytes = $completed.TotalBytes
        }
    }
    catch {
        if (-not (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $backup)) {
            [IO.Directory]::Move($backup, $target)
        }
        throw
    }
    finally {
        foreach ($path in @($transaction, $backup)) {
            if (Test-Path -LiteralPath $path -PathType Container) {
                [IO.Directory]::Delete($path, $true)
            }
        }
    }
}

function Remove-FearMoreLauncherPayload {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([Parameter(Mandatory = $true)][string]$FearMoreRoot)

    $root = [IO.Path]::GetFullPath($FearMoreRoot).TrimEnd('\')
    $target = Join-Path $root 'Launcher'
    if (-not (Test-Path -LiteralPath $target)) {
        return [pscustomobject]@{ Removed = $false; Target = $target }
    }
    $null = Assert-FearInstallerDirectoryChain -Root $root -Path $target
    $module = Join-Path $target 'tools\runtime\FearLauncherPackage.psm1'
    Import-Module $module -Force -ErrorAction Stop
    $null = Test-FearMoreLauncherPackageIntegrity -PackageRoot $target
    if ($PSCmdlet.ShouldProcess($target, 'Remove the exact validated FearMore launcher payload')) {
        [IO.Directory]::Delete($target, $true)
        return [pscustomobject]@{ Removed = $true; Target = $target }
    }
    [pscustomobject]@{ Removed = $false; Target = $target }
}

Export-ModuleMember -Function Install-FearMoreLauncherPayload, Remove-FearMoreLauncherPayload
