Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'FearRetailSidecarPackage.psm1') -Force -ErrorAction Stop

$script:PlanKind = 'FearMore.RemixExperimentPlan'
$script:PlanVersion = 1
$script:JournalKind = 'FearMore.RemixExperimentTransaction'
$script:JournalVersion = 1
$script:MaximumUserConfigBytes = 16MB
$script:Names = [pscustomobject][ordered]@{
    UserConfig = 'user.conf'
    Journal    = 'fearmore-remix-experiment.transaction.json'
    Backup     = 'fearmore-remix-experiment.user-conf.previous'
    Candidate  = 'fearmore-remix-experiment.user-conf.candidate'
    Restore    = 'fearmore-remix-experiment.user-conf.restore'
    Lock       = 'fearmore-remix-experiment.lock'
}

function Get-FearRemixExperimentProperty {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$Name,
        [string]$Description = 'object'
    )

    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) {
        throw "$Description is missing required property '$Name'."
    }
    return $property.Value
}

function Get-FearRemixExperimentSha256FromBytes {
    param([Parameter(Mandatory)][byte[]]$Bytes)

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '') }
    finally { $algorithm.Dispose() }
}

function Get-FearRemixExperimentSha256FromText {
    param([Parameter(Mandatory)][string]$Text)

    Get-FearRemixExperimentSha256FromBytes -Bytes ([Text.Encoding]::UTF8.GetBytes($Text))
}

function Assert-FearRemixExperimentHash {
    param([AllowNull()][string]$Value, [Parameter(Mandatory)][string]$Description)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -cnotmatch '^[0-9A-F]{64}$') {
        throw "$Description is not an uppercase SHA-256 value."
    }
}

function Test-FearRemixExperimentPathsEqual {
    param([Parameter(Mandatory)][string]$Left, [Parameter(Mandatory)][string]$Right)

    [IO.Path]::GetFullPath($Left).TrimEnd('\').Equals(
        [IO.Path]::GetFullPath($Right).TrimEnd('\'),
        [StringComparison]::OrdinalIgnoreCase)
}

function Get-FearRemixExperimentPaths {
    param([Parameter(Mandatory)][string]$RetailRoot)

    $retail = [IO.Path]::GetFullPath($RetailRoot).TrimEnd('\')
    Assert-FearRetailSidecarPathNoReparse -Root $retail -Path $retail
    $paths = [ordered]@{ RetailRoot = $retail }
    foreach ($property in @('UserConfig', 'Journal', 'Backup', 'Candidate', 'Restore', 'Lock')) {
        $path = Get-FearRetailSidecarTargetPath -Root $retail -RelativePath ([string]$script:Names.$property)
        Assert-FearRetailSidecarPathNoReparse -Root $retail -Path $path -AllowMissingLeaf -LeafMayBeFile
        $paths[$property] = $path
    }
    return [pscustomobject]$paths
}

function Get-FearRemixExperimentOptionalOrdinaryFile {
    param(
        [Parameter(Mandatory)][string]$RetailRoot,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [long]$MaximumBytes = [long]::MaxValue
    )

    Assert-FearRetailSidecarPathNoReparse -Root $RetailRoot -Path $Path -AllowMissingLeaf -LeafMayBeFile
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description must be an ordinary file: $Path"
    }
    $item = Assert-FearRetailSidecarOrdinaryFile -Root $RetailRoot -Path $Path -Description $Description
    if ($item.Length -gt $MaximumBytes) {
        throw "$Description exceeds the maximum supported size of $MaximumBytes bytes: $Path"
    }
    return $item
}

function Get-FearRemixExperimentDefinition {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $definition = switch -CaseSensitive ($Name) {
        'WhiteMaterialOff' {
            [pscustomobject]@{ Name=$Name; SettingName='rtx.useWhiteMaterialMode'; CandidateValue='False'; DiagnosticOnly=$false }
        }
        'AlphaBlendOff' {
            [pscustomobject]@{ Name=$Name; SettingName='rtx.enableAlphaBlend'; CandidateValue='False'; DiagnosticOnly=$false }
        }
        'VertexCapturedNormalsOff' {
            [pscustomobject]@{ Name=$Name; SettingName='rtx.useVertexCapturedNormals'; CandidateValue='False'; DiagnosticOnly=$false }
        }
        'SkyAutoDetect2' {
            [pscustomobject]@{ Name=$Name; SettingName='rtx.skyAutoDetect'; CandidateValue='2'; DiagnosticOnly=$false }
        }
        'WorldMatricesOff' {
            [pscustomobject]@{ Name=$Name; SettingName='rtx.useWorldMatricesForShaders'; CandidateValue='False'; DiagnosticOnly=$false }
        }
        'EmissiveOverrideOff' {
            [pscustomobject]@{ Name=$Name; SettingName='rtx.enableEmissiveBlendEmissiveOverride'; CandidateValue='False'; DiagnosticOnly=$false }
        }
        'EmissiveTranslationOff' {
            [pscustomobject]@{ Name=$Name; SettingName='rtx.enableEmissiveBlendModeTranslation'; CandidateValue='False'; DiagnosticOnly=$false }
        }
        'LegacyAlbedoDiagnostic' {
            [pscustomobject]@{ Name=$Name; SettingName='rtx.legacyMaterial.useAlbedoTextureIfPresent'; CandidateValue='False'; DiagnosticOnly=$true }
        }
        default {
            throw "Unknown RTX Remix experiment '$Name'. Supported names: WhiteMaterialOff, AlphaBlendOff, VertexCapturedNormalsOff, SkyAutoDetect2, WorldMatricesOff, EmissiveOverrideOff, EmissiveTranslationOff, LegacyAlbedoDiagnostic."
        }
    }
    return $definition
}

function Get-FearRemixExperimentUserConfigIdentity {
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][ValidateSet('Control', 'Candidate')][string]$Variant
    )

    $lines = @(
        '# Temporary FearMore RTX Remix compatibility experiment. Restored after the exact game process exits.'
        'rtx.graphicsPreset = 4'
        'rtx.integrateIndirectMode = 1'
        'rtx.dlfg.enable = False'
    )
    if ($Variant -ceq 'Candidate') {
        $lines += "$($Definition.SettingName) = $($Definition.CandidateValue)"
    }
    $text = ($lines -join "`r`n") + "`r`n"
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    return [pscustomobject]@{
        Text   = $text
        Bytes  = $bytes
        Size   = [long]$bytes.Length
        Sha256 = Get-FearRemixExperimentSha256FromBytes -Bytes $bytes
    }
}

function Get-FearRemixExperimentRecoveryState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RetailRoot)

    $paths = Get-FearRemixExperimentPaths -RetailRoot $RetailRoot
    $journalNewPath = "$($paths.Journal).new"
    Assert-FearRetailSidecarPathNoReparse -Root $paths.RetailRoot -Path $journalNewPath -AllowMissingLeaf -LeafMayBeFile
    if (Test-Path -LiteralPath $journalNewPath) {
        throw "RTX Remix experiment journal update is incomplete; recovery fails closed: $journalNewPath"
    }

    if (-not (Test-Path -LiteralPath $paths.Journal)) {
        $orphans = @()
        foreach ($path in @($paths.Backup, $paths.Candidate, $paths.Restore)) {
            if (Test-Path -LiteralPath $path) { $orphans += $path }
        }
        if ($orphans.Count -gt 0) {
            throw "RTX Remix experiment scratch state exists without its journal; recovery fails closed: $($orphans -join ', ')"
        }
        return $null
    }

    $journalItem = Get-FearRemixExperimentOptionalOrdinaryFile `
        -RetailRoot $paths.RetailRoot `
        -Path $paths.Journal `
        -Description 'RTX Remix experiment journal' `
        -MaximumBytes 1MB
    try { $journal = Get-Content -LiteralPath $journalItem.FullName -Raw | ConvertFrom-Json }
    catch { throw "RTX Remix experiment journal is unreadable; recovery fails closed: $($journalItem.FullName). $($_.Exception.Message)" }

    $kind = [string](Get-FearRemixExperimentProperty $journal 'JournalKind' 'RTX Remix experiment journal')
    $version = Get-FearRemixExperimentProperty $journal 'SchemaVersion' 'RTX Remix experiment journal'
    $state = [string](Get-FearRemixExperimentProperty $journal 'State' 'RTX Remix experiment journal')
    $transactionId = [string](Get-FearRemixExperimentProperty $journal 'TransactionId' 'RTX Remix experiment journal')
    $journalRetailRoot = [string](Get-FearRemixExperimentProperty $journal 'RetailRoot' 'RTX Remix experiment journal')
    if ($kind -cne $script:JournalKind -or $version -isnot [ValueType] -or [int]$version -ne $script:JournalVersion -or
        $state -notin @('Intent', 'BackedUp', 'Applied', 'Restoring') -or
        $transactionId -cnotmatch '^[0-9a-f]{32}$' -or
        -not (Test-FearRemixExperimentPathsEqual $journalRetailRoot $paths.RetailRoot)) {
        throw 'RTX Remix experiment journal has an unsupported schema, state, transaction identity, or retail root; recovery fails closed.'
    }
    foreach ($name in @('UserConfigRelativePath', 'BackupRelativePath', 'CandidateRelativePath', 'RestoreRelativePath')) {
        $expectedName = switch ($name) {
            'UserConfigRelativePath' { $script:Names.UserConfig }
            'BackupRelativePath' { $script:Names.Backup }
            'CandidateRelativePath' { $script:Names.Candidate }
            'RestoreRelativePath' { $script:Names.Restore }
        }
        if ([string](Get-FearRemixExperimentProperty $journal $name 'RTX Remix experiment journal') -cne $expectedName) {
            throw "RTX Remix experiment journal has an unexpected $name; recovery fails closed."
        }
    }
    $originalPresentValue = Get-FearRemixExperimentProperty $journal 'OriginalUserConfigPresent' 'RTX Remix experiment journal'
    if ($originalPresentValue -isnot [bool]) {
        throw 'RTX Remix experiment journal OriginalUserConfigPresent must be Boolean.'
    }
    $originalPresent = [bool]$originalPresentValue
    $originalHash = $null
    $originalSize = 0L
    if ($originalPresent) {
        $originalHash = [string](Get-FearRemixExperimentProperty $journal 'OriginalUserConfigSha256' 'RTX Remix experiment journal')
        Assert-FearRemixExperimentHash $originalHash 'Original user.conf hash'
        $originalSize = [long](Get-FearRemixExperimentProperty $journal 'OriginalUserConfigSize' 'RTX Remix experiment journal')
        if ($originalSize -lt 0 -or $originalSize -gt $script:MaximumUserConfigBytes) {
            throw 'RTX Remix experiment journal records an invalid original user.conf size.'
        }
    }
    else {
        if ($null -ne (Get-FearRemixExperimentProperty $journal 'OriginalUserConfigSha256' 'RTX Remix experiment journal') -or
            [long](Get-FearRemixExperimentProperty $journal 'OriginalUserConfigSize' 'RTX Remix experiment journal') -ne 0) {
            throw 'RTX Remix experiment journal records original user.conf identity despite declaring it absent.'
        }
    }
    $generatedHash = [string](Get-FearRemixExperimentProperty $journal 'GeneratedUserConfigSha256' 'RTX Remix experiment journal')
    Assert-FearRemixExperimentHash $generatedHash 'Generated user.conf hash'
    $generatedSize = [long](Get-FearRemixExperimentProperty $journal 'GeneratedUserConfigSize' 'RTX Remix experiment journal')
    $experimentName = [string](Get-FearRemixExperimentProperty $journal 'Experiment' 'RTX Remix experiment journal')
    $variant = [string](Get-FearRemixExperimentProperty $journal 'Variant' 'RTX Remix experiment journal')
    if ($variant -notin @('Control', 'Candidate')) {
        throw 'RTX Remix experiment journal has an unsupported Control/Candidate variant.'
    }
    $definition = Get-FearRemixExperimentDefinition -Name $experimentName
    $expectedConfig = Get-FearRemixExperimentUserConfigIdentity -Definition $definition -Variant $variant
    $journalSettingName = [string](Get-FearRemixExperimentProperty $journal 'SettingName' 'RTX Remix experiment journal')
    $journalSettingValue = Get-FearRemixExperimentProperty $journal 'SettingValue' 'RTX Remix experiment journal'
    $expectedSettingValue = if ($variant -ceq 'Candidate') { [string]$definition.CandidateValue } else { $null }
    if ($journalSettingName -cne [string]$definition.SettingName -or
        [string]$journalSettingValue -cne [string]$expectedSettingValue -or
        $generatedSize -ne $expectedConfig.Size -or
        $generatedHash -cne $expectedConfig.Sha256) {
        throw 'RTX Remix experiment journal does not match its allowlisted canonical Control/Candidate config.'
    }
    $installIdentity = [string](Get-FearRemixExperimentProperty $journal 'InstallIdentitySha256' 'RTX Remix experiment journal')
    Assert-FearRemixExperimentHash $installIdentity 'RTX Remix experiment install identity'

    $backupItem = Get-FearRemixExperimentOptionalOrdinaryFile `
        -RetailRoot $paths.RetailRoot `
        -Path $paths.Backup `
        -Description 'RTX Remix experiment user.conf backup' `
        -MaximumBytes $script:MaximumUserConfigBytes
    if ($originalPresent -and $backupItem) {
        if ($backupItem.Length -ne $originalSize -or (Get-FearRetailSidecarSha256 $backupItem.FullName) -cne $originalHash) {
            throw 'RTX Remix experiment backup does not match the original user.conf identity; recovery fails closed.'
        }
    }
    elseif ($originalPresent -and $state -in @('BackedUp', 'Applied', 'Restoring')) {
        throw 'RTX Remix experiment backup is missing after the transaction passed its intent state; recovery fails closed.'
    }
    elseif (-not $originalPresent -and $backupItem) {
        throw 'RTX Remix experiment unexpectedly has a backup for an originally absent user.conf; recovery fails closed.'
    }

    $userConfigItem = Get-FearRemixExperimentOptionalOrdinaryFile `
        -RetailRoot $paths.RetailRoot `
        -Path $paths.UserConfig `
        -Description 'RTX Remix user.conf' `
        -MaximumBytes $script:MaximumUserConfigBytes

    return [pscustomobject][ordered]@{
        Journal            = $journal
        JournalPath        = $paths.Journal
        RetailRoot         = $paths.RetailRoot
        UserConfigPath     = $paths.UserConfig
        BackupPath         = $paths.Backup
        CandidatePath      = $paths.Candidate
        RestorePath        = $paths.Restore
        LockPath           = $paths.Lock
        State              = $state
        TransactionId      = $transactionId
        InstallIdentitySha256 = $installIdentity
        OriginalUserConfigPresent = $originalPresent
        OriginalUserConfigSize = $originalSize
        OriginalUserConfigSha256 = $originalHash
        GeneratedUserConfigSha256 = $generatedHash
        UserConfigPresent  = $null -ne $userConfigItem
        UserConfigSha256   = if ($userConfigItem) { Get-FearRetailSidecarSha256 $userConfigItem.FullName } else { $null }
        BackupPresent      = $null -ne $backupItem
    }
}

function New-FearRemixExperimentPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StageRoot,
        [Parameter(Mandatory)][string]$RetailRoot,
        [Parameter(Mandatory)][string]$Experiment,
        [Parameter(Mandatory)][ValidateSet('Control', 'Candidate')][string]$Variant,
        [string]$RuntimeConfigSeed
    )

    if ([string]::IsNullOrWhiteSpace($RuntimeConfigSeed)) {
        $RuntimeConfigSeed = Join-Path $PSScriptRoot 'config\rtx-remix-runtime.conf'
    }
    $recovery = Get-FearRemixExperimentRecoveryState -RetailRoot $RetailRoot
    if ($recovery) {
        throw "RTX Remix experiment transaction '$($recovery.TransactionId)' requires recovery before another experiment can begin."
    }
    $definition = Get-FearRemixExperimentDefinition -Name $Experiment
    $packagePlan = Get-FearRetailSidecarPackagePlan `
        -StageRoot $StageRoot `
        -RetailRoot $RetailRoot `
        -RuntimeConfigSeed $RuntimeConfigSeed
    $installState = Get-FearRetailSidecarInstallState -Plan $packagePlan
    if ([string]$installState.State -cne 'InstalledExact' -or -not $installState.Installed) {
        throw "RTX Remix experiments require exact installed retail sidecars; found '$($installState.State)'."
    }
    $paths = Get-FearRemixExperimentPaths -RetailRoot $packagePlan.RetailRoot
    $existing = Get-FearRemixExperimentOptionalOrdinaryFile `
        -RetailRoot $paths.RetailRoot `
        -Path $paths.UserConfig `
        -Description 'Existing RTX Remix user.conf' `
        -MaximumBytes $script:MaximumUserConfigBytes

    $configIdentity = Get-FearRemixExperimentUserConfigIdentity -Definition $definition -Variant $Variant
    $configText = $configIdentity.Text
    $configBytes = $configIdentity.Bytes
    $configHash = $configIdentity.Sha256
    $transactionId = [guid]::NewGuid().ToString('N')
    $installedRecord = $installState.Installed.Record
    $installIdentity = [string](Get-FearRemixExperimentProperty $installedRecord 'InstallIdentitySha256' 'FearMore retail install record')
    Assert-FearRemixExperimentHash $installIdentity 'FearMore retail install identity'
    $originalHash = if ($existing) { Get-FearRetailSidecarSha256 $existing.FullName } else { $null }
    $originalSize = if ($existing) { [long]$existing.Length } else { 0L }
    $fingerprintText = @(
        $script:PlanKind,
        [string]$script:PlanVersion,
        [IO.Path]::GetFullPath($packagePlan.StageRoot).TrimEnd('\'),
        $paths.RetailRoot,
        $installIdentity,
        [string]$installState.Installed.RuntimeConfigStatus,
        (Get-FearRetailSidecarSha256 $installState.Installed.RuntimeConfigPath),
        $Experiment,
        $Variant,
        $definition.SettingName,
        $(if ($Variant -ceq 'Candidate') { $definition.CandidateValue } else { '<omitted>' }),
        [string]($null -ne $existing),
        [string]$originalSize,
        [string]$originalHash,
        $configHash,
        $transactionId
    ) -join "`n"

    return [pscustomobject][ordered]@{
        PlanKind                = $script:PlanKind
        PlanVersion             = $script:PlanVersion
        PlanFingerprint         = Get-FearRemixExperimentSha256FromText -Text $fingerprintText
        TransactionId           = $transactionId
        Experiment              = $Experiment
        Variant                 = $Variant
        SettingName             = [string]$definition.SettingName
        SettingValue            = if ($Variant -ceq 'Candidate') { [string]$definition.CandidateValue } else { $null }
        DiagnosticOnly          = [bool]$definition.DiagnosticOnly
        StageRoot               = [IO.Path]::GetFullPath($packagePlan.StageRoot).TrimEnd('\')
        RetailRoot              = $paths.RetailRoot
        InstallIdentitySha256   = $installIdentity
        RuntimeConfigPath       = $installState.Installed.RuntimeConfigPath
        RuntimeConfigSha256     = Get-FearRetailSidecarSha256 $installState.Installed.RuntimeConfigPath
        UserConfigPath          = $paths.UserConfig
        JournalPath             = $paths.Journal
        BackupPath              = $paths.Backup
        CandidatePath           = $paths.Candidate
        RestorePath             = $paths.Restore
        LockPath                = $paths.Lock
        OriginalUserConfigPresent = $null -ne $existing
        OriginalUserConfigSize  = $originalSize
        OriginalUserConfigSha256 = $originalHash
        GeneratedUserConfigBytes = $configBytes
        GeneratedUserConfigSize = $configIdentity.Size
        GeneratedUserConfigSha256 = $configHash
        ConfigText              = $configText
    }
}

function Assert-FearRemixExperimentLaunchAuthorization {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RetailRoot,
        [AllowNull()][string]$ExpectedTransactionId,
        [Parameter(Mandatory)][string]$ExpectedInstallIdentitySha256,
        [AllowNull()][string]$ExpectedUserConfigSha256
    )

    $state = Get-FearRemixExperimentRecoveryState -RetailRoot $RetailRoot
    if (-not $state) {
        if (-not [string]::IsNullOrWhiteSpace($ExpectedTransactionId)) {
            throw 'Steam launch expected an RTX Remix experiment transaction, but no active transaction exists.'
        }
        return [pscustomobject]@{ Authorized=$true; Active=$false; TransactionId=$null }
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedTransactionId)) {
        throw "RTX Remix experiment transaction '$($state.TransactionId)' is active; normal RtxLab launch is blocked until the experiment session resumes or -Recover restores user.conf."
    }
    if ($ExpectedTransactionId -cnotmatch '^[0-9a-f]{32}$' -or
        $state.TransactionId -cne $ExpectedTransactionId -or
        $state.State -cne 'Applied' -or
        $state.InstallIdentitySha256 -cne $ExpectedInstallIdentitySha256 -or
        [string]::IsNullOrWhiteSpace($ExpectedUserConfigSha256) -or
        $state.GeneratedUserConfigSha256 -cne $ExpectedUserConfigSha256 -or
        -not $state.UserConfigPresent -or
        $state.UserConfigSha256 -cne $ExpectedUserConfigSha256) {
        throw 'RTX Remix experiment launch authorization does not match the applied transaction, installed package, or exact generated user.conf.'
    }
    return [pscustomobject]@{ Authorized=$true; Active=$true; TransactionId=$state.TransactionId }
}

Export-ModuleMember -Function @(
    'Get-FearRemixExperimentDefinition',
    'New-FearRemixExperimentPlan',
    'Get-FearRemixExperimentRecoveryState',
    'Assert-FearRemixExperimentLaunchAuthorization'
)
