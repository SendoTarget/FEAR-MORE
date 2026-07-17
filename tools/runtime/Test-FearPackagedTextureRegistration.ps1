[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$layoutModule = Join-Path $PSScriptRoot 'FearRuntimeLayout.psm1'
$settingsModule = Join-Path $PSScriptRoot 'FearLauncherSettings.psm1'
$registrationScript = Join-Path $PSScriptRoot 'Register-FearHdTexturePack.ps1'
$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
foreach ($path in @($layoutModule, $settingsModule, $registrationScript, $stageScript)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Packaged texture-registration test input is missing: $path"
    }
}
Import-Module $layoutModule -Force -ErrorAction Stop
Import-Module $settingsModule -Force -ErrorAction Stop

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "fearmore-packaged-texture-registration-$([guid]::NewGuid().ToString('N'))"
$packageRoot = Join-Path $fixtureRoot 'package'
$localAppDataRoot = Join-Path $fixtureRoot 'local-app-data'
$textureRoot = Join-Path $fixtureRoot 'user-supplied-hd-pack'
try {
    [IO.Directory]::CreateDirectory($packageRoot) | Out-Null
    [IO.Directory]::CreateDirectory($localAppDataRoot) | Out-Null
    [IO.Directory]::CreateDirectory($textureRoot) | Out-Null
    [IO.File]::WriteAllText(
        (Join-Path $packageRoot 'fearmore-package.json'),
        "{`n  `"SchemaVersion`": 1,`n  `"PackageId`": `"FearMore.Runtime`",`n  `"Layout`": `"LauncherPayload`"`n}`n",
        [Text.UTF8Encoding]::new($false))

    $layout = Resolve-FearRuntimeLayout -SourceRoot $packageRoot -LocalAppDataRoot $localAppDataRoot
    $expectedRegistrationPath = Join-Path $localAppDataRoot 'FearMore\registrations\texture-packs\fearmore-hd-textures.json'
    if ($layout.TextureRegistrationPath -cne [IO.Path]::GetFullPath($expectedRegistrationPath) -or
        $layout.TextureRegistrationPath.StartsWith([IO.Path]::GetFullPath($packageRoot), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Packaged texture registration did not resolve to per-user state outside the launcher payload.'
    }
    if (Test-Path -LiteralPath (Join-Path $localAppDataRoot 'FearMore')) {
        throw 'Read-only packaged registration resolution created per-user state.'
    }

    [IO.Directory]::CreateDirectory($layout.TextureRegistrationDirectory) | Out-Null
    $registration = [ordered]@{
        SchemaVersion = 1
        Full          = [ordered]@{
            Mode                = 'Full'
            MatchesKnownPackage = $true
            ManifestSha256      = ('A' * 64)
            PackageRoot         = [IO.Path]::GetFullPath($textureRoot)
        }
    }
    [IO.File]::WriteAllText(
        $layout.TextureRegistrationPath,
        ($registration | ConvertTo-Json -Depth 4) + "`n",
        [Text.UTF8Encoding]::new($false))

    $resolvedTextureRoot = Get-FearRegisteredFullHdTextureRoot `
        -RepositoryRoot $packageRoot `
        -LocalAppDataRoot $localAppDataRoot
    if ($resolvedTextureRoot -cne [IO.Path]::GetFullPath($textureRoot)) {
        throw 'Packaged launcher settings did not consume the per-user texture registration.'
    }

    $registrationSource = ([IO.File]::ReadAllText($registrationScript)) -replace "`r`n", "`n"
    foreach ($contract in @(
            "Import-Module `$layoutModulePath -Force",
            'Resolve-FearRuntimeLayout @layoutArguments',
            '$registrationSafetyRoot = $runtimeLayout.RegistrationSafetyRoot',
            '$registrationDirectory = $runtimeLayout.TextureRegistrationDirectory',
            '$registrationPath = $runtimeLayout.TextureRegistrationPath',
            '$PSCmdlet.ShouldProcess($registrationPath',
            '[IO.Directory]::CreateDirectory($registrationDirectory)'
        )) {
        if (-not $registrationSource.Contains($contract)) {
            throw "Registration writer is missing the packaged-state ownership contract: $contract"
        }
    }
    if ($registrationSource.IndexOf('$PSCmdlet.ShouldProcess($registrationPath', [StringComparison]::Ordinal) -gt
        $registrationSource.IndexOf('[IO.Directory]::CreateDirectory($registrationDirectory)', [StringComparison]::Ordinal)) {
        throw 'Packaged registration directory creation escaped the existing ShouldProcess mutation boundary.'
    }

    $stageSource = ([IO.File]::ReadAllText($stageScript)) -replace "`r`n", "`n"
    foreach ($contract in @(
            "Join-Path `$runtimeLayout.RuntimeRoot 'fearmore-stock-echopatch\FEAR.exe'",
            "Join-Path `$runtimeLayout.RuntimeRoot 'fearmore-stock-echopatch\FEAR.exe.bak'"
        )) {
        if (-not $stageSource.Contains($contract)) {
            throw "HD texture LAA prerequisite is not routed through the selected runtime layout: $contract"
        }
    }
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        $canonicalFixture = [IO.Path]::GetFullPath($fixtureRoot)
        $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        if (-not $canonicalFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to clean packaged registration fixture outside temp: $canonicalFixture"
        }
        [IO.Directory]::Delete($canonicalFixture, $true)
    }
}

[pscustomobject]@{
    Status                         = 'PASS'
    DeveloperRegistrationPreserved = 'vendor-local\texture-packs\fearmore-hd-textures.json'
    PackagedRegistration           = '%LOCALAPPDATA%\FearMore\registrations\texture-packs\fearmore-hd-textures.json'
    PackagePayloadMutation         = $false
    LaaPrerequisiteRuntimeRouted   = $true
}
