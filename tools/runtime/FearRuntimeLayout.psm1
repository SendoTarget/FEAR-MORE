Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1') -ErrorAction Stop

$script:PackageManifestName = 'fearmore-package.json'
$script:PackageManifestProperties = @('SchemaVersion', 'PackageId', 'Layout')

function Resolve-FearRuntimeLayout {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [string]$LocalAppDataRoot
    )

    $resolvedSourceRoot = Get-FearCanonicalPath -Path $SourceRoot -BasePath (Get-Location).Path
    if (-not (Test-Path -LiteralPath $resolvedSourceRoot -PathType Container)) {
        throw "FearMore source root is missing: $resolvedSourceRoot"
    }

    $gitMarker = Join-Path $resolvedSourceRoot '.git'
    if ((Test-Path -LiteralPath $gitMarker -PathType Container) -or
        (Test-Path -LiteralPath $gitMarker -PathType Leaf)) {
        $textureRegistrationDirectory = Join-Path $resolvedSourceRoot 'vendor-local\texture-packs'
        return [pscustomobject]@{
            LayoutKind                  = 'DeveloperCheckout'
            SourceRoot                  = $resolvedSourceRoot
            RuntimeRoot                 = Join-Path $resolvedSourceRoot 'local-runtime'
            RelativeStageBase           = $resolvedSourceRoot
            PackageManifestPath         = $null
            RegistrationSafetyRoot      = $resolvedSourceRoot
            TextureRegistrationDirectory = $textureRegistrationDirectory
            TextureRegistrationPath     = Join-Path $textureRegistrationDirectory 'fearmore-hd-textures.json'
        }
    }

    $manifestPath = Join-Path $resolvedSourceRoot $script:PackageManifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "FearMore source root is neither a developer checkout nor an exact packaged runtime. Missing: $manifestPath"
    }
    $manifestItem = Get-Item -LiteralPath $manifestPath -Force
    if (($manifestItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "FearMore package manifest must be an ordinary file: $manifestPath"
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "FearMore package manifest is not valid JSON: $manifestPath. $($_.Exception.Message)"
    }
    if ($null -eq $manifest) {
        throw "FearMore package manifest is empty: $manifestPath"
    }

    $actualProperties = @($manifest.PSObject.Properties.Name)
    $unexpectedProperties = @($actualProperties | Where-Object { $script:PackageManifestProperties -cnotcontains $_ })
    $missingProperties = @($script:PackageManifestProperties | Where-Object { $actualProperties -cnotcontains $_ })
    if ($unexpectedProperties.Count -gt 0 -or $missingProperties.Count -gt 0 -or
        $actualProperties.Count -ne $script:PackageManifestProperties.Count) {
        throw "FearMore package manifest must contain exactly: $($script:PackageManifestProperties -join ', ')."
    }
    if ($manifest.SchemaVersion -isnot [int] -or [int]$manifest.SchemaVersion -ne 1 -or
        [string]$manifest.PackageId -cne 'FearMore.Runtime' -or
        [string]$manifest.Layout -cne 'LauncherPayload') {
        throw "Unsupported FearMore package manifest identity in: $manifestPath"
    }

    if ([string]::IsNullOrWhiteSpace($LocalAppDataRoot)) {
        $LocalAppDataRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    }
    if ([string]::IsNullOrWhiteSpace($LocalAppDataRoot)) {
        throw 'Windows did not provide a per-user LocalApplicationData directory for the packaged FearMore runtime.'
    }
    $resolvedLocalAppDataRoot = Get-FearCanonicalPath -Path $LocalAppDataRoot -BasePath (Get-Location).Path
    $fearMoreUserRoot = Join-Path $resolvedLocalAppDataRoot 'FearMore'
    $runtimeRoot = Join-Path $fearMoreUserRoot 'local-runtime'
    $textureRegistrationDirectory = Join-Path $fearMoreUserRoot 'registrations\texture-packs'

    return [pscustomobject]@{
        LayoutKind                   = 'Packaged'
        SourceRoot                   = $resolvedSourceRoot
        RuntimeRoot                  = $runtimeRoot
        RelativeStageBase            = $runtimeRoot
        PackageManifestPath          = $manifestPath
        RegistrationSafetyRoot       = $resolvedLocalAppDataRoot
        TextureRegistrationDirectory = $textureRegistrationDirectory
        TextureRegistrationPath      = Join-Path $textureRegistrationDirectory 'fearmore-hd-textures.json'
    }
}

Export-ModuleMember -Function Resolve-FearRuntimeLayout
