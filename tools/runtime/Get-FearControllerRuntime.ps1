[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$RepositoryRoot,
    [string]$ArchivePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FearControllerPackage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1') -Force -ErrorAction Stop

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$metadata = Get-FearControllerPackageMetadata
if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
    $ArchivePath = Get-FearControllerPackageDefaultArchivePath -RepositoryRoot $RepositoryRoot
}
$ArchivePath = [IO.Path]::GetFullPath($ArchivePath)
$dependencyRoot = Join-Path $RepositoryRoot 'vendor-local\controller-deps'
if (-not (Test-FearPathIsBelow -Path $ArchivePath -Parent $dependencyRoot)) {
    throw "Controller archive target must stay below '$dependencyRoot': $ArchivePath"
}

if (Test-Path -LiteralPath $ArchivePath) {
    Get-FearControllerPackageStagePayload -ArchivePath $ArchivePath
    return
}

if (-not $PSCmdlet.ShouldProcess($ArchivePath, "Download and validate official SDL $($metadata.Version) x86 runtime")) {
    return
}

Assert-FearNoReparsePathComponents -Root $RepositoryRoot -Path $dependencyRoot -Description 'controller dependency directory'
if (-not (Test-Path -LiteralPath $dependencyRoot)) {
    New-Item -ItemType Directory -Path $dependencyRoot | Out-Null
}
Assert-FearNoReparsePathComponents -Root $RepositoryRoot -Path $dependencyRoot -RequirePath -Description 'controller dependency directory'

$temporaryPath = Join-Path $dependencyRoot ('.' + $metadata.ArchiveName + '.' + [guid]::NewGuid().ToString('N') + '.download')
try {
    Invoke-WebRequest -UseBasicParsing -Uri $metadata.DownloadUri -OutFile $temporaryPath
    $identity = Get-FearControllerPackageStagePayload -ArchivePath $temporaryPath
    if (Test-Path -LiteralPath $ArchivePath) {
        throw "Controller archive appeared concurrently and was not replaced: $ArchivePath"
    }
    [IO.File]::Move($temporaryPath, $ArchivePath)
    Get-FearControllerPackageStagePayload -ArchivePath $ArchivePath
}
finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        [IO.File]::Delete($temporaryPath)
    }
}
