[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'FearLauncherPackage.psm1'
$builderPath = Join-Path $PSScriptRoot 'New-FearMoreLauncherPackage.ps1'
$verifierPath = Join-Path $PSScriptRoot 'Verify-FearMoreLauncherPackage.ps1'
foreach ($path in @($modulePath, $builderPath, $verifierPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Launcher-package test input is missing: $path"
    }
}
Import-Module $modulePath -Force -ErrorAction Stop

$exports = @(Get-Command -Module FearLauncherPackage -CommandType Function |
        Select-Object -ExpandProperty Name |
        Sort-Object)
$expectedExports = @('Get-FearMoreLauncherPackageAllowlist', 'Test-FearMoreLauncherPackageIntegrity')
if (@(Compare-Object $expectedExports $exports).Count -ne 0) {
    throw "FearLauncherPackage exports changed. Found: $($exports -join ', ')"
}

$allowlist = @(Get-FearMoreLauncherPackageAllowlist)
$targets = @($allowlist.TargetRelativePath)
foreach ($required in @(
        'Launch FearMore.cmd',
        'Verify FearMore Package.cmd',
        'QUICKSTART.md',
        'CREDITS.md',
        'tools\runtime\Start-FearMore.ps1',
        'tools\runtime\New-FearRuntimeStage.ps1',
        'tools\runtime\Get-FearPostProcessRuntime.ps1',
        'tools\runtime\New-FearHdTextureLitePackage.ps1',
        'tools\runtime\FearRuntimeLayout.psm1',
        'tools\runtime\README.md',
        'build\fear-win32\bin\Release\GameClient.dll',
        'vendor-local\controller-deps\SDL3-3.4.10-win32-x86.zip',
        'vendor-local\renderer-deps\dgVoodoo2_87_3.zip',
        'vendor-local\EchoPatch-4.2.1.zip'
    )) {
    if ($targets -cnotcontains $required) {
        throw "Launcher-package allowlist is missing: $required"
    }
}
foreach ($developerOnlyPath in @(
        'tools\runtime\Install-FearMoreRetailSidecars.ps1',
        'tools\runtime\Invoke-FearRemixExperiment.ps1',
        'tools\runtime\FearRemixExperimentPlan.psm1',
        'tools\runtime\FearRetailSidecarPackage.psm1',
        'tools\runtime\FearSteamLaunch.psm1'
    )) {
    if ($targets -ccontains $developerOnlyPath) {
        throw "Stable+Modern owner package includes a developer-only RTX/CameraLab owner: $developerOnlyPath"
    }
}
foreach ($entry in $allowlist) {
    $path = $entry.TargetRelativePath.ToLowerInvariant()
    if ($path -match '(^|\\)(?:retail|local-runtime|userdirectory|texture-packs|fear-sdk-108|hdtextures)(\\|$)' -or
        $path -match '(^|\\)[^\\]*sky[^\\]*(\\|$)' -or
        $path -match '\.(?:arch00.|sav|dmp|mdmp|log)$') {
        throw "Launcher-package allowlist crossed a protected private-data boundary: $($entry.TargetRelativePath)"
    }
}
$vendorEntries = @($allowlist | Where-Object { $_.TargetRelativePath.StartsWith('vendor-local\', [StringComparison]::OrdinalIgnoreCase) })
if ($vendorEntries.Count -eq 0 -or @($vendorEntries | Where-Object Classification -ne 'PrivatePinnedDependency').Count -ne 0) {
    throw 'Launcher-package vendor-local entries are not all explicitly classified private pinned dependencies.'
}

$builderSource = ([IO.File]::ReadAllText($builderPath)) -replace "`r`n", "`n"
foreach ($contract in @(
        '[switch]$PrivateOwnerBuild',
        '[switch]$VerifyOnly',
        "'dist\local\FearMore-Playable'",
        'Get-FearControllerPackageStagePayload',
        'Get-FearDgVoodooPackageIdentity',
        'Get-FearEngineOnlyEchoPatchPackageIdentity',
        "PostProcessAcquisition     = 'OfficialOnDemand'",
        'Get-FearPeRuntimeIdentity',
        '$PSCmdlet.ShouldProcess($OutputRoot',
        'Test-FearMoreLauncherPackageIntegrity -PackageRoot $transactionRoot',
        'ContainsRetailFiles = $false',
        'ContainsHdTextures  = $false'
    )) {
    if (-not $builderSource.Contains($contract)) {
        throw "Launcher-package assembler is missing its safety/identity contract: $contract"
    }
}
if ($builderSource -match '(?im)^\s*(?:Copy-Item|robocopy|xcopy)\b' -or
    $builderSource.Contains('Get-ChildItem -LiteralPath $RepositoryRoot -Recurse')) {
    throw 'Launcher-package assembler contains a broad copy/enumeration primitive instead of the exact allowlist.'
}

$launcherSource = ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Start-FearMore.ps1'))) -replace "`r`n", "`n"
foreach ($contract in @(
        '$runtimeLayout.LayoutKind -eq ''Packaged''',
        '$Preset -notin @(''Stable'', ''Modern'')',
        'private FearMore owner package supports only -Preset Stable and -Preset Modern',
        'Get-FearPostProcessPackageMetadata',
        'Get-FearPostProcessRuntime.ps1',
        'dependencies\postprocess'
    )) {
    if (-not $launcherSource.Contains($contract)) {
        throw "Packaged launcher is missing its finite Stable+Modern preset gate: $contract"
    }
}

$verifyCommandPath = Join-Path $PSScriptRoot 'package\Verify FearMore Package.cmd'
$verifyCommandSource = [IO.File]::ReadAllText($verifyCommandPath)
if (-not $verifyCommandSource.Contains('-PackageRoot "%~dp0."') -or
    $verifyCommandSource.Contains('-PackageRoot "%~dp0"')) {
    throw 'Packaged verifier must terminate the batch directory argument with a dot so its trailing backslash cannot escape the closing quote.'
}

function Write-TestJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 6
    [IO.File]::WriteAllText($Path, $json + "`n", [Text.UTF8Encoding]::new($false))
}

function Get-TestRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$Classification
    )

    $path = Join-Path $Root $RelativePath
    $item = Get-Item -LiteralPath $path -Force
    [pscustomobject][ordered]@{
        RelativePath   = $RelativePath
        Classification = $Classification
        Size           = [long]$item.Length
        Sha256         = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "fearmore-launcher-package-test-$([guid]::NewGuid().ToString('N'))"
try {
    [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'vendor-local\controller-deps')) | Out-Null
    Write-TestJson -Path (Join-Path $fixtureRoot 'fearmore-package.json') -Value ([ordered]@{
            SchemaVersion = 1
            PackageId      = 'FearMore.Runtime'
            Layout         = 'LauncherPayload'
        })
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'README.md'), "synthetic owner package`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllBytes(
        (Join-Path $fixtureRoot 'vendor-local\controller-deps\SDL3-3.4.10-win32-x86.zip'),
        [byte[]](1, 2, 3, 4))

    $records = @(
        Get-TestRecord -Root $fixtureRoot -RelativePath 'fearmore-package.json' -Classification PackageIdentity
        Get-TestRecord -Root $fixtureRoot -RelativePath 'README.md' -Classification ProjectDocumentation
        Get-TestRecord -Root $fixtureRoot -RelativePath 'vendor-local\controller-deps\SDL3-3.4.10-win32-x86.zip' -Classification PrivatePinnedDependency
    ) | Sort-Object RelativePath
    $manifest = [ordered]@{
        SchemaVersion       = 1
        PackageId           = 'FearMore.OwnerBuild'
        DistributionClass   = 'PrivateOwnerBuild'
        BuildConfiguration  = 'Release'
        SourceRepository    = 'https://github.com/SendoTarget/FEAR-MORE'
        SourceRevision      = ('0' * 40)
        SourceTreeState     = 'WorkingTreeSnapshot'
        GeneratedUtc        = '2026-07-16T00:00:00.0000000Z'
        SupportedPresets    = @('Stable', 'Modern')
        ContainsRetailFiles = $false
        ContainsHdTextures  = $false
        FileCount           = [int]$records.Count
        TotalBytes          = [long](($records | Measure-Object Size -Sum).Sum)
        Files               = @($records)
    }
    $manifestPath = Join-Path $fixtureRoot 'fearmore-package-files.json'
    Write-TestJson -Path $manifestPath -Value $manifest

    $accepted = Test-FearMoreLauncherPackageIntegrity -PackageRoot $fixtureRoot
    if ($accepted.Status -cne 'PASS' -or $accepted.FileCount -ne 3 -or
        $accepted.PrivateFileCount -ne 1 -or $accepted.ContainsRetailFiles -or $accepted.ContainsHdTextures) {
        throw 'Synthetic private-owner package did not pass with the expected identity.'
    }

    [IO.File]::AppendAllText((Join-Path $fixtureRoot 'README.md'), 'tamper')
    try {
        Test-FearMoreLauncherPackageIntegrity -PackageRoot $fixtureRoot | Out-Null
        throw 'Tampered package file was accepted.'
    }
    catch {
        if ($_.Exception.Message -eq 'Tampered package file was accepted.') { throw }
        if (-not $_.Exception.Message.Contains('file identity changed')) { throw }
    }
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'README.md'), "synthetic owner package`n", [Text.UTF8Encoding]::new($false))

    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'unknown.txt'), 'unknown')
    try {
        Test-FearMoreLauncherPackageIntegrity -PackageRoot $fixtureRoot | Out-Null
        throw 'Unowned package file was accepted.'
    }
    catch {
        if ($_.Exception.Message -eq 'Unowned package file was accepted.') { throw }
        if (-not $_.Exception.Message.Contains('file count changed')) { throw }
    }
    [IO.File]::Delete((Join-Path $fixtureRoot 'unknown.txt'))

    [IO.Directory]::CreateDirectory((Join-Path $fixtureRoot 'Retail')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'Retail\FEAR.exe'), 'retail')
    $retailRecord = Get-TestRecord -Root $fixtureRoot -RelativePath 'Retail\FEAR.exe' -Classification PrivatePinnedDependency
    $manifest.Files = @($records) + $retailRecord
    $manifest.FileCount = [int]$manifest.Files.Count
    $manifest.TotalBytes = [long](($manifest.Files | Measure-Object Size -Sum).Sum)
    Write-TestJson -Path $manifestPath -Value $manifest
    try {
        Test-FearMoreLauncherPackageIntegrity -PackageRoot $fixtureRoot | Out-Null
        throw 'Retail-shaped package path was accepted.'
    }
    catch {
        if ($_.Exception.Message -eq 'Retail-shaped package path was accepted.') { throw }
        if (-not $_.Exception.Message.Contains('protected/private game-data path')) { throw }
    }

    [IO.Directory]::Delete((Join-Path $fixtureRoot 'Retail'), $true)
    foreach ($protectedLeaf in @('Game.Arch00', 'FEAR.exe', 'steam_appid.txt')) {
        $protectedPath = Join-Path $fixtureRoot $protectedLeaf
        [IO.File]::WriteAllText($protectedPath, 'protected retail input')
        $protectedRecord = Get-TestRecord -Root $fixtureRoot -RelativePath $protectedLeaf -Classification PrivatePinnedDependency
        $manifest.Files = @($records) + $protectedRecord
        $manifest.FileCount = [int]$manifest.Files.Count
        $manifest.TotalBytes = [long](($manifest.Files | Measure-Object Size -Sum).Sum)
        Write-TestJson -Path $manifestPath -Value $manifest
        try {
            Test-FearMoreLauncherPackageIntegrity -PackageRoot $fixtureRoot | Out-Null
            throw "Protected retail leaf was accepted: $protectedLeaf"
        }
        catch {
            if ($_.Exception.Message -eq "Protected retail leaf was accepted: $protectedLeaf") { throw }
            if (-not $_.Exception.Message.Contains('protected/private game-data path')) { throw }
        }
        [IO.File]::Delete($protectedPath)
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $canonicalFixture = [IO.Path]::GetFullPath($fixtureRoot)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $canonicalFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean launcher-package fixture outside temp: $canonicalFixture"
        }
        [IO.Directory]::Delete($canonicalFixture, $true)
    }
}

[pscustomobject]@{
    Status                       = 'PASS'
    AllowlistEntryCount          = $allowlist.Count
    PrivateDependenciesExplicit = $true
    RetailFilesRejected          = $true
    HdTexturesExcluded           = $true
    SkyWorkExcluded              = $true
    TamperRejected               = $true
    UnknownFilesRejected         = $true
    SingleMutationBoundary       = $true
}
