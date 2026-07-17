[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    [string]$RepositoryRoot,
    [string]$LauncherRoot,
    [string]$HdLiteRoot,
    [string]$OutputRoot,
    [string]$IsccPath,
    [switch]$WithoutHdLite,
    [switch]$PrivateHouseholdBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
if ([string]::IsNullOrWhiteSpace($LauncherRoot)) {
    $LauncherRoot = Join-Path $RepositoryRoot 'dist\local\FearMore-Playable'
}
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $RepositoryRoot 'dist\local\FearMore-Project-Installer'
}
$LauncherRoot = [IO.Path]::GetFullPath($LauncherRoot).TrimEnd('\')
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\')
$outputBoundary = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'dist\local')).TrimEnd('\')
if (-not $OutputRoot.StartsWith($outputBoundary + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Private installer output must stay below the ignored local boundary '$outputBoundary': $OutputRoot"
}
if (-not $PrivateHouseholdBuild) {
    throw 'Re-run with -PrivateHouseholdBuild to acknowledge that the generated installer is private, contains non-redistributable local inputs, and must not be published.'
}
if (Test-Path -LiteralPath $OutputRoot) {
    throw "Private installer output already exists and will not be overwritten: $OutputRoot"
}

Import-Module (Join-Path $RepositoryRoot 'tools\runtime\FearLauncherPackage.psm1') -Force -ErrorAction Stop
$launcherIdentity = Test-FearMoreLauncherPackageIntegrity -PackageRoot $LauncherRoot

$hdIdentity = $null
if (-not $WithoutHdLite) {
    if ([string]::IsNullOrWhiteSpace($HdLiteRoot)) {
        $registrationPath = Join-Path $RepositoryRoot 'vendor-local\texture-packs\fearmore-hd-textures.json'
        $registration = Get-Content -LiteralPath $registrationPath -Raw | ConvertFrom-Json -ErrorAction Stop
        $HdLiteRoot = [string]$registration.Lite.PackageRoot
    }
    $HdLiteRoot = [IO.Path]::GetFullPath($HdLiteRoot).TrimEnd('\')
    Import-Module (Join-Path $RepositoryRoot 'tools\runtime\FearTexturePackage.psm1') -Force -ErrorAction Stop
    $hdIdentity = Get-FearHdTexturePackageIdentity -PackageRoot $HdLiteRoot -RequireKnownMode Lite
}

if ([string]::IsNullOrWhiteSpace($IsccPath)) {
    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'Inno Setup 7\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe'),
        (Join-Path ${env:LOCALAPPDATA} 'Programs\Inno Setup 7\ISCC.exe')
    )
    $matchingIscc = @($candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1)
    if ($matchingIscc.Count -eq 1) { $IsccPath = [string]$matchingIscc[0] } else { $IsccPath = $null }
}
if ([string]::IsNullOrWhiteSpace($IsccPath) -or -not (Test-Path -LiteralPath $IsccPath -PathType Leaf)) {
    throw 'Inno Setup 7 compiler was not found. Install the official JRSoftware.InnoSetup.7 package, then retry.'
}

if (-not $PSCmdlet.ShouldProcess($OutputRoot, 'Compile the private FearMore Project Installer')) {
    return [pscustomobject]@{
        Status          = 'WHATIF'
        OutputRoot      = $OutputRoot
        LauncherFiles   = $launcherIdentity.FileCount
        IncludesHdLite  = [bool]$hdIdentity
        HdLiteFileCount = if ($hdIdentity) { $hdIdentity.FileCount } else { 0 }
    }
}

$outputParent = Split-Path $OutputRoot -Parent
$transactionRoot = Join-Path $outputParent ('.FearMore-Project-Installer.' + [guid]::NewGuid().ToString('N') + '.assembling')
try {
    [IO.Directory]::CreateDirectory($outputParent) | Out-Null
    [IO.Directory]::CreateDirectory($transactionRoot) | Out-Null
    $arguments = @(
        '/Qp',
        "/DLauncherRoot=$LauncherRoot",
        "/DOutputRoot=$transactionRoot"
    )
    if ($hdIdentity) {
        $arguments += "/DHdLiteRoot=$HdLiteRoot"
    }
    $arguments += (Join-Path $PSScriptRoot 'FearMore.iss')
    & $IsccPath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Inno Setup compilation failed with exit code $LASTEXITCODE."
    }

    $textureInstructions = if ($hdIdentity) {
@'
3. Double-click FearMore-Setup.exe. Leave "Prepare HD Lite support now" selected.
4. If EchoPatch asks to enable Large Address Aware support, choose Yes. Close the temporary game window after its menu appears.
5. Start FearMore from the Start menu. Choose Options > Game > HD textures > Stable Lite, exit, and start FearMore again.

This locally built setup includes the builder-supplied HD Lite texture tree. Its public redistribution rights have not been established, so do not upload, publish, mirror, or attach this generated setup to a GitHub release.
'@
    }
    else {
@'
3. Double-click FearMore-Setup.exe.
4. Start FearMore from the Start menu and choose the Modern preset. HD textures are not included; the ordinary Modern game does not require them.

This locally built setup contains SDK-derived modules and downloaded dependencies. It is for the legal owner's local installation and is not the public GitHub bootstrap asset.
'@
    }
    $startHere = @"
FEARMORE - START HERE

1. Keep FearMore-Setup.exe and every FearMore-Setup-*.bin file together in this folder.
2. Install and start your legal F.E.A.R. v1.08 copy once. Steam users: leave Steam running and signed in.
$textureInstructions

This setup is not Authenticode-signed, so Windows may show an Unknown publisher warning. SHA256SUMS.txt contains the hashes created and verified with this build.
"@
    [IO.File]::WriteAllText(
        (Join-Path $transactionRoot 'START-HERE.txt'),
        $startHere.Trim() + "`r`n",
        [Text.UTF8Encoding]::new($false))
    $outputs = @(Get-ChildItem -LiteralPath $transactionRoot -File | Sort-Object Name)
    if (-not ($outputs | Where-Object Name -eq 'FearMore-Setup.exe')) {
        throw 'Inno Setup did not emit FearMore-Setup.exe.'
    }
    $checksumLines = @($outputs | ForEach-Object {
        '{0} *{1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash, $_.Name
    })
    $checksumPath = Join-Path $transactionRoot 'SHA256SUMS.txt'
    [IO.File]::WriteAllText($checksumPath, ($checksumLines -join "`r`n") + "`r`n", [Text.UTF8Encoding]::new($false))
    [IO.Directory]::Move($transactionRoot, $OutputRoot)
}
finally {
    if (Test-Path -LiteralPath $transactionRoot -PathType Container) {
        [IO.Directory]::Delete($transactionRoot, $true)
    }
}

[pscustomobject]@{
    Status               = 'PASS'
    OutputRoot           = $OutputRoot
    SetupPath            = Join-Path $OutputRoot 'FearMore-Setup.exe'
    DistributionClass    = 'PrivateHouseholdBuild'
    IncludesRetailFiles  = $false
    IncludesHdLite       = [bool]$hdIdentity
    HdLiteFileCount      = if ($hdIdentity) { $hdIdentity.FileCount } else { 0 }
    HdLiteTotalBytes     = if ($hdIdentity) { $hdIdentity.TotalBytes } else { 0 }
    HdLiteManifestSha256 = if ($hdIdentity) { $hdIdentity.ManifestSha256 } else { $null }
    OutputFiles          = @($outputs.Name) + 'SHA256SUMS.txt'
}
