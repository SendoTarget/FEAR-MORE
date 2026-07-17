[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [string]$LauncherRoot
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
$testRoot = Join-Path $RepositoryRoot ('local-runtime\installer-test-' + [guid]::NewGuid().ToString('N'))
$modulePath = Join-Path $PSScriptRoot 'FearMoreInstaller.psm1'
$innoPath = Join-Path $PSScriptRoot 'FearMore.iss'
$orchestratorPath = Join-Path $PSScriptRoot 'Build-FearMoreProjectInstaller.ps1'
$publicOrchestratorPath = Join-Path $RepositoryRoot 'tools\public\Build-FearMorePublicProject.ps1'
$rootCommandPath = Join-Path $RepositoryRoot 'Build FearMore Project Installer.cmd'
$legacyOrchestratorPath = Join-Path $PSScriptRoot 'Build-FearMoreHouseholdInstaller.ps1'
$legacyRootCommandPath = Join-Path $RepositoryRoot 'Build FearMore Household Installer.cmd'
Import-Module $modulePath -Force -ErrorAction Stop

try {
    $installed = Install-FearMoreLauncherPayload `
        -PayloadRoot $LauncherRoot `
        -FearMoreRoot $testRoot `
        -Confirm:$false
    if (-not $installed.Installed -or $installed.FileCount -lt 1) {
        throw 'Synthetic installer transaction did not report a completed payload install.'
    }
    [IO.File]::WriteAllText((Join-Path $testRoot 'preserved-user-data.txt'), 'preserve')
    $removed = Remove-FearMoreLauncherPayload -FearMoreRoot $testRoot -Confirm:$false
    if (-not $removed.Removed -or
        (Test-Path -LiteralPath (Join-Path $testRoot 'Launcher')) -or
        -not (Test-Path -LiteralPath (Join-Path $testRoot 'preserved-user-data.txt') -PathType Leaf)) {
        throw 'Installer removal did not remove only the validated launcher while preserving sibling user data.'
    }

    $innoSource = [IO.File]::ReadAllText($innoPath)
    foreach ($required in @(
            'DiskSpanning=yes',
            'DiskSliceSize=2000000000',
            'PrivilegesRequired=lowest',
            'uninsneveruninstall',
            'Install-FearMore.ps1',
            'Finish-FearMoreHdSetup.ps1',
            'HdLiteRoot'
        )) {
        if ($innoSource.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw "Inno installer source is missing its required contract: $required"
        }
    }
    foreach ($forbidden in @('FEAR.exe"; DestDir', 'ReShade_Setup_6.7.3.exe')) {
        if ($innoSource.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Inno installer source contains a forbidden bundled payload contract: $forbidden"
        }
    }

    $orchestratorSource = [IO.File]::ReadAllText($orchestratorPath)
    $publicOrchestratorSource = [IO.File]::ReadAllText($publicOrchestratorPath)
    $rootCommandSource = [IO.File]::ReadAllText($rootCommandPath)
    $legacyOrchestratorSource = [IO.File]::ReadAllText($legacyOrchestratorPath)
    $legacyRootCommandSource = [IO.File]::ReadAllText($legacyRootCommandPath)
    foreach ($required in @(
            'New-FearMoreLauncherPackage.ps1',
            'New-FearMoreInstallerPackage.ps1',
            'Test-FearMoreLauncherPackageIntegrity',
            'status --porcelain --untracked-files=no',
            "SourceTreeState -cne 'Clean'",
            'PrivateHouseholdBuild',
            'PublishPermitted     = $false'
        )) {
        if ($orchestratorSource.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw "Project Installer orchestrator is missing its required delegation contract: $required"
        }
    }
    $packageBuilderSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'New-FearMoreInstallerPackage.ps1'))
    foreach ($required in @(
            '$textureInstructions = if ($hdIdentity)',
            'HD textures are not included',
            'includes the builder-supplied HD Lite texture tree'
        )) {
        if ($packageBuilderSource.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw "Project Installer START-HERE generation is missing its HD/no-HD contract: $required"
        }
    }
    if ($rootCommandSource.IndexOf('tools\public\Build-FearMorePublicProject.ps1" %*', [StringComparison]::Ordinal) -lt 0 -or
        $publicOrchestratorSource.IndexOf('Build-FearMoreProjectInstaller.ps1', [StringComparison]::Ordinal) -lt 0) {
        throw 'Root Project Installer command does not delegate through the public bootstrapper and focused installer orchestrator.'
    }
    if ($legacyRootCommandSource.IndexOf('Build FearMore Project Installer.cmd" %*', [StringComparison]::Ordinal) -lt 0 -or
        $legacyOrchestratorSource.IndexOf('Build-FearMoreProjectInstaller.ps1', [StringComparison]::Ordinal) -lt 0) {
        throw 'Former household-named builder entry points do not preserve compatibility by forwarding to Project Installer.'
    }
    foreach ($required in @(
            '[string]$RepositoryRoot',
            '[string]$LauncherRoot',
            '[string]$HdLiteRoot',
            '[string]$OutputRoot',
            '[string]$IsccPath',
            '[switch]$WithoutHdLite',
            '$PSBoundParameters',
            '$forwardParameters.PrivateHouseholdBuild = $true'
        )) {
        if ($legacyOrchestratorSource.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
            throw "Former household-named PowerShell entry point does not preserve its parameter contract: $required"
        }
    }

    [pscustomobject]@{
        Status                   = 'PASS'
        TransactionalInstall     = $true
        ExactLauncherUninstall   = $true
        SiblingUserDataPreserved = $true
        HdLitePrivateMount       = $true
        RetailExecutableBundled  = $false
        ReShadeBundled           = $false
        ReproducibleEntryPoint    = $true
    }
}
finally {
    if (Test-Path -LiteralPath $testRoot -PathType Container) {
        [IO.Directory]::Delete($testRoot, $true)
    }
}
