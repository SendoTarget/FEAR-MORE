Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearRuntimeLayout.psm1') -ErrorAction Stop

function Get-FearMoreIntegralSettingFromSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$FieldName,
        [Parameter(Mandatory = $true)][int]$DefaultValue,
        [Parameter(Mandatory = $true)][int]$Minimum,
        [Parameter(Mandatory = $true)][int]$Maximum,
        [Parameter(Mandatory = $true)][string]$AllowedValuesDescription,
        [Parameter(Mandatory = $true)][string]$SourceDescription
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $DefaultValue
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$SourceDescription is not an ordinary settings file: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$SourceDescription is a reparse point: $Path"
    }
    $content = [IO.File]::ReadAllText($item.FullName)
    # Console-variable names are case-insensitive. Count every textual
    # occurrence as well as exact records so a valid line cannot hide a second
    # malformed or differently cased assignment.
    $escapedFieldName = [regex]::Escape($FieldName)
    $pattern = '(?im)^\s*"' + $escapedFieldName + '"\s+"(?<Value>[^"]*)"\s*$'
    $matches = [regex]::Matches($content, $pattern)
    $fieldOccurrences = [regex]::Matches($content, '(?i)' + $escapedFieldName).Count
    if ($matches.Count -eq 0) {
        if ($fieldOccurrences -ne 0) {
            throw "settings.cfg contains a malformed $FieldName field: $Path"
        }
        return $DefaultValue
    }
    if ($fieldOccurrences -ne $matches.Count) {
        throw "settings.cfg contains an additional malformed or ambiguous $FieldName field: $Path"
    }
    if ($matches.Count -ne 1) {
        throw "settings.cfg must contain at most one $FieldName field; found $($matches.Count): $Path"
    }

    $value = 0.0
    $parsed = [double]::TryParse(
        $matches[0].Groups['Value'].Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$value)
    if (-not $parsed -or [double]::IsNaN($value) -or [double]::IsInfinity($value) -or
        $value -ne [Math]::Truncate($value) -or $value -lt $Minimum -or $value -gt $Maximum) {
        throw "$FieldName must be $AllowedValuesDescription`: $Path"
    }

    return [int]$value
}

function Get-FearMoreHdTextureModeFromSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $value = Get-FearMoreIntegralSettingFromSettings `
        -Path $Path `
        -FieldName 'FearMoreHDTextures' `
        -DefaultValue 0 `
        -Minimum 0 `
        -Maximum 2 `
        -AllowedValuesDescription 'the finite integral value 0 (Off), 1 (Lite), or 2 (Full)' `
        -SourceDescription 'HD texture selection source'
    if ($value -eq 1) {
        return 'Lite'
    }
    if ($value -eq 2) {
        return 'Full'
    }
    return 'Off'
}

function Get-FearMoreEnhancedGoreEnabledFromSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$DefaultEnabled = $false
    )

    $value = Get-FearMoreIntegralSettingFromSettings `
        -Path $Path `
        -FieldName 'EnhancedGore' `
        -DefaultValue $(if ($DefaultEnabled) { 1 } else { 0 }) `
        -Minimum 0 `
        -Maximum 1 `
        -AllowedValuesDescription 'the finite integral value 0 (Off) or 1 (On)' `
        -SourceDescription 'Enhanced Gore selection source'
    return ($value -eq 1)
}

function Get-FearMoreCorpsePersistenceEnabledFromSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [bool]$DefaultEnabled = $false
    )

    $value = Get-FearMoreIntegralSettingFromSettings `
        -Path $Path `
        -FieldName 'FearMoreCorpsePersistence' `
        -DefaultValue $(if ($DefaultEnabled) { 1 } else { 0 }) `
        -Minimum 0 `
        -Maximum 1 `
        -AllowedValuesDescription 'the finite integral value 0 (Off) or 1 (On)' `
        -SourceDescription 'corpse-persistence selection source'
    return ($value -eq 1)
}

function Get-FearMoreRendererQualityFromSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $value = Get-FearMoreIntegralSettingFromSettings `
        -Path $Path `
        -FieldName 'FearMoreRendererQuality' `
        -DefaultValue 0 `
        -Minimum 0 `
        -Maximum 1 `
        -AllowedValuesDescription 'the finite integral value 0 (Native) or 1 (Max2x)' `
        -SourceDescription 'renderer-quality selection source'
    if ($value -eq 1) {
        return 'Max2x'
    }
    return 'Native'
}

function Get-FearMorePostProcessModeFromSettings {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    $value = Get-FearMoreIntegralSettingFromSettings `
        -Path $Path `
        -FieldName 'FearMorePostProcess' `
        -DefaultValue 0 `
        -Minimum 0 `
        -Maximum 1 `
        -AllowedValuesDescription 'the finite integral value 0 (None) or 1 (ReShade CAS)' `
        -SourceDescription 'post-process selection source'
    if ($value -eq 1) {
        return 'ReShadeCas'
    }
    return 'None'
}

function Get-FearRegisteredHdTextureRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [Parameter(Mandatory = $true)][ValidateSet('Lite', 'Full')][string]$Mode,
        [AllowNull()][string]$ExplicitRoot,
        [AllowNull()][string]$LocalAppDataRoot
    )

    if ($ExplicitRoot) {
        return [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($ExplicitRoot)) {
            $ExplicitRoot
        } else {
            Join-Path $RepositoryRoot $ExplicitRoot
        }))
    }

    $layoutArguments = @{ SourceRoot = $RepositoryRoot }
    if (-not [string]::IsNullOrWhiteSpace($LocalAppDataRoot)) {
        $layoutArguments.LocalAppDataRoot = $LocalAppDataRoot
    }
    $runtimeLayout = Resolve-FearRuntimeLayout @layoutArguments
    $registrationPath = $runtimeLayout.TextureRegistrationPath
    if (-not (Test-Path -LiteralPath $registrationPath -PathType Leaf)) {
        throw "$Mode HD textures are selected, but no local package is registered. Run tools\runtime\Register-FearHdTexturePack.ps1 once with the matching package path."
    }
    $registrationItem = Get-Item -LiteralPath $registrationPath -Force
    if (($registrationItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        $registrationItem.Length -gt 1MB) {
        throw "HD texture registration is not an ordinary bounded file: $registrationPath"
    }
    $registration = Get-Content -LiteralPath $registrationPath -Raw | ConvertFrom-Json
    if (-not $registration.PSObject.Properties['SchemaVersion'] -or
        [int]$registration.SchemaVersion -notin @(1, 2)) {
        throw "HD texture registration has an unsupported or incomplete schema: $registrationPath"
    }
    if ([int]$registration.SchemaVersion -eq 1 -and $Mode -ne 'Full') {
        throw "Stable Lite textures are selected, but the registration predates Lite support. Register the validated Lite package first: $registrationPath"
    }
    $modeProperty = $registration.PSObject.Properties[$Mode]
    $record = if ($modeProperty) { $modeProperty.Value } else { $null }
    if (-not $record -or
        -not $record.PSObject.Properties['Mode'] -or
        [string]$record.Mode -cne $Mode -or
        -not [bool]$record.MatchesKnownPackage -or
        [string]$record.ManifestSha256 -notmatch '^[0-9A-F]{64}$' -or
        -not [string]$record.PackageRoot) {
        throw "$Mode HD textures are selected, but their validated package is not registered: $registrationPath"
    }
    return [IO.Path]::GetFullPath([string]$record.PackageRoot)
}

function Get-FearRegisteredFullHdTextureRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryRoot,
        [AllowNull()][string]$ExplicitRoot,
        [AllowNull()][string]$LocalAppDataRoot
    )

    return Get-FearRegisteredHdTextureRoot @PSBoundParameters -Mode 'Full'
}

Export-ModuleMember -Function Get-FearMoreEnhancedGoreEnabledFromSettings, Get-FearMoreCorpsePersistenceEnabledFromSettings, Get-FearMoreHdTextureModeFromSettings, Get-FearMoreRendererQualityFromSettings, Get-FearMorePostProcessModeFromSettings, Get-FearRegisteredHdTextureRoot, Get-FearRegisteredFullHdTextureRoot
