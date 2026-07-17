[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')

$safetyModule = Join-Path $RepositoryRoot 'tools\runtime\FearRuntimeStageSafety.psm1'
Import-Module $safetyModule -Force -ErrorAction Stop

function Test-ExpectedFileIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][long]$Size,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Path
    $actualSha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($item.Length -ne $Size -or $actualSha256 -cne $Sha256) {
        throw "$Description has an unexpected identity and will not be replaced automatically: $Path"
    }
    return $true
}

function Get-ValidatedDependency {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][long]$Size,
        [Parameter(Mandatory = $true)][string]$Sha256,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $targetPath = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot $RelativePath))
    $vendorRoot = Join-Path $RepositoryRoot 'vendor-local'
    if (-not (Test-FearPathIsBelow -Path $targetPath -Parent $vendorRoot)) {
        throw "Dependency target escapes the ignored vendor-local boundary: $targetPath"
    }
    if (Test-ExpectedFileIdentity -Path $targetPath -Size $Size -Sha256 $Sha256 -Description $Description) {
        return $targetPath
    }
    if (-not $PSCmdlet.ShouldProcess($targetPath, "Download and validate $Description")) {
        return $null
    }

    $parentPath = Split-Path $targetPath -Parent
    Assert-FearNoReparsePathComponents -Root $RepositoryRoot -Path $parentPath -Description 'public dependency directory'
    if (-not (Test-Path -LiteralPath $parentPath)) {
        New-Item -ItemType Directory -Path $parentPath | Out-Null
    }
    Assert-FearNoReparsePathComponents -Root $RepositoryRoot -Path $parentPath -RequirePath -Description 'public dependency directory'

    $temporaryPath = Join-Path $parentPath ('.' + (Split-Path $targetPath -Leaf) + '.' + [guid]::NewGuid().ToString('N') + '.download')
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $temporaryPath
        if (-not (Test-ExpectedFileIdentity -Path $temporaryPath -Size $Size -Sha256 $Sha256 -Description $Description)) {
            throw "$Description download did not produce a file: $Uri"
        }
        if (Test-Path -LiteralPath $targetPath) {
            throw "$Description appeared concurrently and was not replaced: $targetPath"
        }
        [IO.File]::Move($temporaryPath, $targetPath)
        if (-not (Test-ExpectedFileIdentity -Path $targetPath -Size $Size -Sha256 $Sha256 -Description $Description)) {
            throw "$Description failed post-promotion validation: $targetPath"
        }
        return $targetPath
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            [IO.File]::Delete($temporaryPath)
        }
    }
}

$dependencies = @()
$dependencies += Get-ValidatedDependency `
    -RelativePath 'vendor-local\EchoPatch-4.2.1.zip' `
    -Uri 'https://github.com/Wemino/EchoPatch/releases/download/4.2.1/EchoPatch.zip' `
    -Size 1978793 `
    -Sha256 '5AE9BF8F4D549B0F1CD682D63B4123C2BFF2622BD2035779DF263183C61BF9AE' `
    -Description 'EchoPatch 4.2.1 release archive'
$dependencies += Get-ValidatedDependency `
    -RelativePath 'vendor-local\renderer-deps\dgVoodoo2_87_3.zip' `
    -Uri 'https://github.com/dege-diosg/dgVoodoo2/releases/download/v2.87.3/dgVoodoo2_87_3.zip' `
    -Size 9082391 `
    -Sha256 '6FB954BED55BF70E948C5045A663A9DF31EA206FAF105E327BAFE46C318F867F' `
    -Description 'dgVoodoo2 2.87.3 archive'
$dependencies += Get-ValidatedDependency `
    -RelativePath 'vendor-local\echopatch-deps\minhook-c3fcafdc10146beb5919319d0683e44e3c30d537.zip' `
    -Uri 'https://github.com/TsudaKageyu/minhook/archive/c3fcafdc10146beb5919319d0683e44e3c30d537.zip' `
    -Size 79584 `
    -Sha256 'CDCB160F734D81BD4D235DFEA79E3F5A661C8EF0AB74FA814272AA5449069034' `
    -Description 'MinHook c3fcafdc source archive'

$controllerDownloader = Join-Path $RepositoryRoot 'tools\runtime\Get-FearControllerRuntime.ps1'
$controllerResult = & $controllerDownloader -RepositoryRoot $RepositoryRoot -Confirm:$false
if ($controllerResult) {
    $dependencies += [string]$controllerResult.ArchivePath
}

$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $git) {
    throw 'Git is required to initialize the pinned EchoPatch submodule.'
}
$submoduleRoot = Join-Path $RepositoryRoot 'external\EchoPatch'
$expectedCommit = 'b4a7074e4cbb2fb6bb238809f7cf26424f1f5961'
if (-not (Test-Path -LiteralPath (Join-Path $submoduleRoot '.git'))) {
    if ($PSCmdlet.ShouldProcess($submoduleRoot, 'Initialize the pinned EchoPatch submodule')) {
        & $git.Source -C $RepositoryRoot submodule update --init --checkout -- external/EchoPatch
        if ($LASTEXITCODE -ne 0) { throw 'EchoPatch submodule initialization failed.' }
    }
}
if (Test-Path -LiteralPath $submoduleRoot -PathType Container) {
    $commit = @(& $git.Source -C $submoduleRoot rev-parse HEAD 2>$null)
    $status = @(& $git.Source -C $submoduleRoot status --porcelain=v1 --untracked-files=all 2>$null)
    if ($LASTEXITCODE -ne 0 -or $commit.Count -ne 1 -or [string]$commit[0] -cne $expectedCommit -or $status.Count -ne 0) {
        throw "EchoPatch must be clean and pinned to $expectedCommit."
    }
}

[pscustomobject]@{
    Status          = 'PASS'
    DependencyCount = @($dependencies | Where-Object { $_ }).Count
    EchoPatchCommit = $expectedCommit
    VendorRoot      = Join-Path $RepositoryRoot 'vendor-local'
}
