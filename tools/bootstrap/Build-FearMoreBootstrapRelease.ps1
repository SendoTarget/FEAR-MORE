[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    [string]$RepositoryRoot,
    [string]$OutputRoot,
    [string]$IsccPath,
    [string]$Version = '0.1.2',
    [string]$ReleaseTag = 'v0.1.2'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) { $RepositoryRoot = Join-Path $PSScriptRoot '..\..' }
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $RepositoryRoot 'dist\local\FearMore-Bootstrap-Release' }
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$outputBoundary = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'dist\local')).TrimEnd('\')
if (-not $OutputRoot.StartsWith($outputBoundary + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Bootstrap release output must stay below '$outputBoundary': $OutputRoot"
}
if (Test-Path -LiteralPath $OutputRoot) { throw "Bootstrap release output already exists: $OutputRoot" }

$git = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $git) { throw 'Git is required to attest the bootstrap release.' }
$status = @(& $git.Source -C $RepositoryRoot status --porcelain --untracked-files=no 2>$null)
if ($LASTEXITCODE -ne 0 -or $status.Count -gt 0) { throw 'The tracked Git checkout must be clean before building a public bootstrap release.' }
$revision = [string](& $git.Source -C $RepositoryRoot rev-parse HEAD)
if ($LASTEXITCODE -ne 0) { throw 'The Git revision could not be read.' }
$tagRevision = [string](& $git.Source -C $RepositoryRoot rev-list -n 1 $ReleaseTag 2>$null)
if ($LASTEXITCODE -ne 0 -or $tagRevision.Trim() -cne $revision.Trim()) {
    throw "The public bootstrap must be built from the exact $ReleaseTag revision."
}

if ([string]::IsNullOrWhiteSpace($IsccPath)) {
    Import-Module (Join-Path $PSScriptRoot 'FearMoreBootstrapPrerequisites.psm1') -Force -ErrorAction Stop
    $IsccPath = Get-FearMoreBootstrapIsccPath
}
if ([string]::IsNullOrWhiteSpace($IsccPath) -or -not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    throw 'Inno Setup 7 compiler was not found.'
}

$inputs = @(
    'tools\bootstrap\Bootstrap-FearMoreProject.ps1',
    'tools\bootstrap\FearMoreBootstrapPrerequisites.psm1',
    'tools\bootstrap\BOOTSTRAP-README.txt',
    'tools\bootstrap\FearMoreBootstrap.iss'
)
foreach ($relativePath in $inputs) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $relativePath) -PathType Leaf)) {
        throw "Bootstrap release input is missing: $relativePath"
    }
}
if (-not $PSCmdlet.ShouldProcess($OutputRoot, "Compile the public FearMore bootstrap $ReleaseTag")) {
    return [pscustomobject]@{ Status = 'WHATIF'; OutputRoot = $OutputRoot; ReleaseTag = $ReleaseTag }
}

$outputParent = Split-Path $OutputRoot -Parent
[IO.Directory]::CreateDirectory($outputParent) | Out-Null
$transactionRoot = Join-Path $outputParent ('.FearMore-Bootstrap-Release.' + [guid]::NewGuid().ToString('N') + '.assembling')
try {
    [IO.Directory]::CreateDirectory($transactionRoot) | Out-Null
    & $IsccPath /Qp "/DOutputRoot=$transactionRoot" "/DAppVersion=$Version" (Join-Path $PSScriptRoot 'FearMoreBootstrap.iss') | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup bootstrap compilation failed with exit $LASTEXITCODE." }
    $setupPath = Join-Path $transactionRoot 'FearMore-Project-Installer-Bootstrap.exe'
    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) { throw 'Inno Setup did not emit the public bootstrap EXE.' }

    $inputRecords = @($inputs | ForEach-Object {
            $path = Join-Path $RepositoryRoot $_
            [ordered]@{
                Path = $_.Replace('\', '/')
                Size = [long](Get-Item -LiteralPath $path).Length
                Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            }
        })
    $manifest = [ordered]@{
        Schema                      = 1
        DistributionClass           = 'PublicBootstrap'
        Version                     = $Version
        ReleaseTag                  = $ReleaseTag
        Repository                  = 'https://github.com/SendoTarget/FEAR-MORE'
        Revision                    = $revision.Trim()
        BuildsLocally               = $true
        ContainsRetailFiles         = $false
        ContainsSdkFiles            = $false
        ContainsCompiledGameModules = $false
        ContainsThirdPartyBinaries  = $false
        Inputs                      = $inputRecords
        Output                      = [ordered]@{
            Name = [IO.Path]::GetFileName($setupPath)
            Size = [long](Get-Item -LiteralPath $setupPath).Length
            Sha256 = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash
        }
    }
    $manifestPath = Join-Path $transactionRoot 'FearMore-Bootstrap-Manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8) + "`r`n", [Text.UTF8Encoding]::new($false))
    $checksums = @(Get-ChildItem -LiteralPath $transactionRoot -File | Sort-Object Name | ForEach-Object {
            '{0} *{1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.Name
        })
    [IO.File]::WriteAllText((Join-Path $transactionRoot 'SHA256SUMS.txt'), ($checksums -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
    [IO.Directory]::Move($transactionRoot, $OutputRoot)
}
finally {
    if (Test-Path -LiteralPath $transactionRoot -PathType Container) { [IO.Directory]::Delete($transactionRoot, $true) }
}

[pscustomobject]@{
    Status = 'PASS'
    OutputRoot = $OutputRoot
    SetupPath = Join-Path $OutputRoot 'FearMore-Project-Installer-Bootstrap.exe'
    ManifestPath = Join-Path $OutputRoot 'FearMore-Bootstrap-Manifest.json'
    ReleaseTag = $ReleaseTag
    Revision = $revision.Trim()
}
