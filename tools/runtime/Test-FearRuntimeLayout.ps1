[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'FearRuntimeLayout.psm1'
$launcherPath = Join-Path $PSScriptRoot 'Start-FearMore.ps1'
$stagePath = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
foreach ($requiredPath in @($modulePath, $launcherPath, $stagePath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Runtime-layout test input is missing: $requiredPath"
    }
}

Import-Module $modulePath -Force -ErrorAction Stop
$exportedFunctions = @(
    Get-Command -Module FearRuntimeLayout -CommandType Function |
        Select-Object -ExpandProperty Name |
        Sort-Object
)
if (@(Compare-Object @('Resolve-FearRuntimeLayout') $exportedFunctions).Count -ne 0) {
    throw "FearRuntimeLayout exports changed. Found: $($exportedFunctions -join ', ')"
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "fearmore-runtime-layout-test-$([Guid]::NewGuid().ToString('N'))"
$developerRoot = Join-Path $fixtureRoot 'developer'
$packageRoot = Join-Path $fixtureRoot 'package'
$invalidRoot = Join-Path $fixtureRoot 'invalid'
$localAppDataRoot = Join-Path $fixtureRoot 'local-app-data'
try {
    [IO.Directory]::CreateDirectory((Join-Path $developerRoot '.git')) | Out-Null
    [IO.Directory]::CreateDirectory($packageRoot) | Out-Null
    [IO.Directory]::CreateDirectory($invalidRoot) | Out-Null

    $developerLayout = Resolve-FearRuntimeLayout `
        -SourceRoot $developerRoot `
        -LocalAppDataRoot $localAppDataRoot
    $expectedDeveloperRuntime = Join-Path ([IO.Path]::GetFullPath($developerRoot).TrimEnd('\')) 'local-runtime'
    if ($developerLayout.LayoutKind -cne 'DeveloperCheckout' -or
        $developerLayout.RuntimeRoot -cne $expectedDeveloperRuntime -or
        $developerLayout.RelativeStageBase -cne [IO.Path]::GetFullPath($developerRoot).TrimEnd('\') -or
        $null -ne $developerLayout.PackageManifestPath -or
        $developerLayout.RegistrationSafetyRoot -cne [IO.Path]::GetFullPath($developerRoot).TrimEnd('\') -or
        $developerLayout.TextureRegistrationPath -cne (Join-Path ([IO.Path]::GetFullPath($developerRoot).TrimEnd('\')) 'vendor-local\texture-packs\fearmore-hd-textures.json')) {
        throw 'Developer-checkout runtime layout changed.'
    }

    $manifestPath = Join-Path $packageRoot 'fearmore-package.json'
    [IO.File]::WriteAllText(
        $manifestPath,
        "{`n  `"SchemaVersion`": 1,`n  `"PackageId`": `"FearMore.Runtime`",`n  `"Layout`": `"LauncherPayload`"`n}`n",
        [Text.UTF8Encoding]::new($false)
    )
    $packagedLayout = Resolve-FearRuntimeLayout `
        -SourceRoot $packageRoot `
        -LocalAppDataRoot $localAppDataRoot
    $expectedPackagedRuntime = Join-Path ([IO.Path]::GetFullPath($localAppDataRoot).TrimEnd('\')) 'FearMore\local-runtime'
    if ($packagedLayout.LayoutKind -cne 'Packaged' -or
        $packagedLayout.RuntimeRoot -cne $expectedPackagedRuntime -or
        $packagedLayout.RelativeStageBase -cne $expectedPackagedRuntime -or
        $packagedLayout.PackageManifestPath -cne [IO.Path]::GetFullPath($manifestPath) -or
        $packagedLayout.RegistrationSafetyRoot -cne [IO.Path]::GetFullPath($localAppDataRoot).TrimEnd('\') -or
        $packagedLayout.TextureRegistrationPath -cne (Join-Path ([IO.Path]::GetFullPath($localAppDataRoot).TrimEnd('\')) 'FearMore\registrations\texture-packs\fearmore-hd-textures.json')) {
        throw 'Packaged runtime layout did not select the per-user FearMore root.'
    }
    if (Test-Path -LiteralPath $localAppDataRoot) {
        throw 'Read-only runtime-layout resolution created the packaged writable root.'
    }

    $missingManifestRejected = $false
    try {
        Resolve-FearRuntimeLayout -SourceRoot $invalidRoot -LocalAppDataRoot $localAppDataRoot | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('neither a developer checkout nor an exact packaged runtime')) {
            throw "Missing package marker failed without precise evidence: $($_.Exception.Message)"
        }
        $missingManifestRejected = $true
    }
    if (-not $missingManifestRejected) {
        throw 'A source root without .git or fearmore-package.json was accepted.'
    }

    [IO.File]::WriteAllText(
        $manifestPath,
        '{"SchemaVersion":1,"PackageId":"FearMore.Runtime","Layout":"LauncherPayload","Unexpected":true}',
        [Text.UTF8Encoding]::new($false)
    )
    $unexpectedPropertyRejected = $false
    try {
        Resolve-FearRuntimeLayout -SourceRoot $packageRoot -LocalAppDataRoot $localAppDataRoot | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('must contain exactly')) {
            throw "Unexpected package-manifest property failed without precise evidence: $($_.Exception.Message)"
        }
        $unexpectedPropertyRejected = $true
    }
    if (-not $unexpectedPropertyRejected) {
        throw 'A package manifest with an unowned property was accepted.'
    }

    [IO.File]::WriteAllText(
        $manifestPath,
        '{"SchemaVersion":2,"PackageId":"FearMore.Runtime","Layout":"LauncherPayload"}',
        [Text.UTF8Encoding]::new($false)
    )
    $wrongIdentityRejected = $false
    try {
        Resolve-FearRuntimeLayout -SourceRoot $packageRoot -LocalAppDataRoot $localAppDataRoot | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('Unsupported FearMore package manifest identity')) {
            throw "Wrong package identity failed without precise evidence: $($_.Exception.Message)"
        }
        $wrongIdentityRejected = $true
    }
    if (-not $wrongIdentityRejected) {
        throw 'A package manifest with an unsupported identity was accepted.'
    }

    [IO.File]::WriteAllText(
        $manifestPath,
        '{"SchemaVersion":"1","PackageId":"FearMore.Runtime","Layout":"LauncherPayload"}',
        [Text.UTF8Encoding]::new($false)
    )
    $stringSchemaRejected = $false
    try {
        Resolve-FearRuntimeLayout -SourceRoot $packageRoot -LocalAppDataRoot $localAppDataRoot | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('Unsupported FearMore package manifest identity')) {
            throw "String package schema failed without precise evidence: $($_.Exception.Message)"
        }
        $stringSchemaRejected = $true
    }
    if (-not $stringSchemaRejected) {
        throw 'A package manifest with a string SchemaVersion was accepted.'
    }

    $launcherSource = (Get-Content -LiteralPath $launcherPath -Raw) -replace "`r`n", "`n"
    $stageSource = (Get-Content -LiteralPath $stagePath -Raw) -replace "`r`n", "`n"
    foreach ($contract in @(
            "Import-Module (Join-Path `$PSScriptRoot 'FearRuntimeLayout.psm1')",
            'Resolve-FearRuntimeLayout -SourceRoot $repositoryRoot',
            '$requestedStageRoot = Join-Path $runtimeRoot $stageDirectoryName',
            '-WritableRoot $runtimeRoot'
        )) {
        if (-not $launcherSource.Contains($contract)) {
            throw "One-click launcher is missing the runtime-layout contract: $contract"
        }
    }
    foreach ($contract in @(
            "Import-Module (Join-Path `$PSScriptRoot 'FearRuntimeLayout.psm1')",
            'Resolve-FearRuntimeLayout -SourceRoot $RepositoryRoot',
            '$localRuntimeRoot = $runtimeLayout.RuntimeRoot',
            '-BasePath $runtimeLayout.RelativeStageBase',
            "Join-Path `$runtimeLayout.RuntimeRoot 'fearmore-stock-echopatch\FEAR.exe'",
            "Join-Path `$runtimeLayout.RuntimeRoot 'fearmore-stock-echopatch\FEAR.exe.bak'"
        )) {
        if (-not $stageSource.Contains($contract)) {
            throw "Stage owner is missing the runtime-layout contract: $contract"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $canonicalFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $canonicalFixtureRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean a runtime-layout fixture outside the temp directory: $canonicalFixtureRoot"
        }
        [IO.Directory]::Delete($canonicalFixtureRoot, $true)
    }
}

[pscustomobject]@{
    Status                     = 'PASS'
    DeveloperBehaviorPreserved = $true
    ExactManifestRequired      = $true
    PackagedRuntimeRoot        = '%LOCALAPPDATA%\FearMore\local-runtime'
    PackagedTextureRegistration = '%LOCALAPPDATA%\FearMore\registrations\texture-packs\fearmore-hd-textures.json'
    LayoutResolutionReadOnly   = $true
    LauncherIntegrated         = $true
    StageOwnerIntegrated       = $true
}
