[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PowerShellAst {
    param([Parameter(Mandatory = $true)][string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile(
        [IO.Path]::GetFullPath($Path),
        [ref]$tokens,
        [ref]$errors)
    if (@($errors).Count -gt 0) {
        $messages = @($errors | ForEach-Object { "line $($_.Extent.StartLineNumber): $($_.Message)" }) -join '; '
        throw "PowerShell parse failed for '$Path': $messages"
    }
    return $ast
}

function Get-DirectorySnapshot {
    param([Parameter(Mandatory = $true)][string]$Root)

    return (@(Get-ChildItem -LiteralPath $Root -Recurse -Force | Sort-Object FullName | ForEach-Object {
        $relativePath = $_.FullName.Substring([IO.Path]::GetFullPath($Root).TrimEnd('\').Length).TrimStart('\')
        if ($_.PSIsContainer) {
            "DIR|$relativePath|$([int]$_.Attributes)"
        }
        else {
            "FILE|$relativePath|$([int]$_.Attributes)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)"
        }
    }) -join "`n")
}

function Assert-ExactSequence {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [AllowNull()][object[]]$Actual,
        [AllowNull()][object[]]$Expected
    )

    $actualText = @($Actual | ForEach-Object { [string]$_ }) -join "`n"
    $expectedText = @($Expected | ForEach-Object { [string]$_ }) -join "`n"
    if ($actualText -cne $expectedText) {
        throw "$Description mismatch. Expected [$(@($Expected) -join ', ')] but found [$(@($Actual) -join ', ')]."
    }
}

function Get-DeclaredFunctionParameterNames {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.Ast]$Ast,
        [Parameter(Mandatory = $true)][string]$FunctionName
    )

    $definitions = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq $FunctionName
    }, $true))
    if ($definitions.Count -ne 1) {
        throw "Expected exactly one function definition for '$FunctionName'; found $($definitions.Count)."
    }

    return @($definitions[0].Body.ParamBlock.Parameters | ForEach-Object {
        $_.Name.VariablePath.UserPath
    })
}

function Get-EnclosingFunctionName {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.Language.CommandAst]$Command
    )

    $parent = $Command.Parent
    while ($parent) {
        if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) {
            return $parent.Name
        }
        $parent = $parent.Parent
    }
    return $null
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
$runtimeExecutableModulePath = Join-Path $PSScriptRoot 'FearRuntimeExecutable.psm1'
$rendererPackageModulePath = Join-Path $PSScriptRoot 'FearRendererPackage.psm1'
$postProcessPackageModulePath = Join-Path $PSScriptRoot 'FearPostProcessPackage.psm1'
$controllerPackageModulePath = Join-Path $PSScriptRoot 'FearControllerPackage.psm1'
$enginePatchPackageModulePath = Join-Path $PSScriptRoot 'FearEnginePatchPackage.psm1'
$texturePackageModulePath = Join-Path $PSScriptRoot 'FearTexturePackage.psm1'
$ddsIdentityModulePath = Join-Path $PSScriptRoot 'FearDdsIdentity.psm1'
$safetyModulePath = Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1'
$planModulePath = Join-Path $PSScriptRoot 'FearRuntimeStagePlan.psm1'
$ownershipModulePath = Join-Path $PSScriptRoot 'FearRuntimeStageOwnership.psm1'
$layoutModulePath = Join-Path $PSScriptRoot 'FearRuntimeLayout.psm1'

$moduleContracts = @(
    [pscustomobject]@{
        Name = 'FearRuntimeExecutable'
        Path = $runtimeExecutableModulePath
        Exports = @(
            'Get-FearPeRuntimeIdentity',
            'Get-FearStockRuntimeExecutableAssessment',
            'Get-FearAttestedLaaRuntimeExecutablePairIdentity',
            'Test-FearSteamRetailInstallation',
            'Test-FearX86Pe32Identity'
        )
    },
    [pscustomobject]@{
        Name = 'FearRendererPackage'
        Path = $rendererPackageModulePath
        Exports = @(
            'Get-FearDgVoodooConfigIdentity',
            'Get-FearDgVoodooPackageIdentity',
            'Get-FearRtxRemixBridgeConfigIdentity',
            'Get-FearRtxRemixPackageIdentity',
            'Get-FearRtxRemixRuntimeConfigSafetyIdentity',
            'Get-FearRtxRemixRuntimeConfigSeedIdentity',
            'Test-FearRendererArchiveEntryPath'
        )
    },
    [pscustomobject]@{
        Name = 'FearPostProcessPackage'
        Path = $postProcessPackageModulePath
        Exports = @(
            'Get-FearPostProcessPackageIdentity',
            'Get-FearPostProcessPackageMetadata',
            'Get-FearPostProcessPackageStagePayload'
        )
    },
    [pscustomobject]@{
        Name = 'FearControllerPackage'
        Path = $controllerPackageModulePath
        Exports = @(
            'Get-FearControllerPackageDefaultArchivePath',
            'Get-FearControllerPackageMetadata',
            'Get-FearControllerPackageStagePayload'
        )
    },
    [pscustomobject]@{
        Name = 'FearEnginePatchPackage'
        Path = $enginePatchPackageModulePath
        Exports = @(
            'Get-FearCameraDiagnosticEchoPatchPackageIdentity',
            'Get-FearEngineOnlyEchoPatchConfigIdentity',
            'Get-FearEngineOnlyEchoPatchPackageIdentity',
            'Get-FearRemixDiagnosticEchoPatchPackageIdentity',
            'Get-FearRtxCameraDiagnosticEchoPatchPackageIdentity',
            'Get-FearRtxCameraReassertionEchoPatchPackageIdentity'
        )
    },
    [pscustomobject]@{
        Name = 'FearTexturePackage'
        Path = $texturePackageModulePath
        Exports = @(
            'Get-FearHdTexturePackageIdentity'
        )
    },
    [pscustomobject]@{
        Name = 'FearDdsIdentity'
        Path = $ddsIdentityModulePath
        Exports = @(
            'Get-FearDdsManifestSha256',
            'Get-FearDdsTextureIdentity'
        )
    },
    [pscustomobject]@{
        Name = 'FearRuntimeStageSafety'
        Path = $safetyModulePath
        Exports = @(
            'Assert-FearIntentionalRetailJunction',
            'Assert-FearNoReparsePathComponents',
            'Assert-FearSafeStageDirectoryTarget',
            'Assert-FearSafeStageFileTarget',
            'Assert-FearIntentionalReadOnlyJunction',
            'Assert-FearStageTreeNoUnexpectedReparsePoints',
            'Get-FearCanonicalPath',
            'Test-FearPathIsBelow',
            'Test-FearPathsEqual'
        )
    },
    [pscustomobject]@{
        Name = 'FearRuntimeStagePlan'
        Path = $planModulePath
        Exports = @(
            'Assert-FearRuntimeStagePackageSelection',
            'Get-FearRebuiltStageMutationRelativePaths',
            'Get-FearRuntimeStagePackageIdentities',
            'Resolve-FearRuntimeStagePackagePlan'
        )
    },
    [pscustomobject]@{
        Name = 'FearRuntimeStageOwnership'
        Path = $ownershipModulePath
        Exports = @(
            'Assert-FearNoStageOwnershipTransactionFiles',
            'Assert-FearOwnedStage',
            'Assert-FearStagePackageLayout',
            'Assert-FearStageControllerOwnership',
            'Assert-FearStagePostProcessOwnership',
            'Assert-FearStageProxyOwnership',
            'Assert-FearStageRuntimeExecutableOwnership',
            'Get-FearStageOwnershipTransactionPaths',
            'Get-FearSteamAppIdHintPlan'
        )
    },
    [pscustomobject]@{
        Name = 'FearRuntimeLayout'
        Path = $layoutModulePath
        Exports = @(
            'Resolve-FearRuntimeLayout'
        )
    }
)

$forbiddenCommands = @(
    'ac',
    'Add-Content',
    'clc',
    'Clear-Content',
    'cp',
    'cpi',
    'Copy-Item',
    'del',
    'erase',
    'Export-Clixml',
    'Export-Csv',
    'Expand-Archive',
    'mi',
    'Move-Item',
    'mv',
    'ni',
    'New-Item',
    'Out-File',
    'rd',
    'ri',
    'Remove-Item',
    'Rename-Item',
    'rmdir',
    'rm',
    'saps',
    'sc',
    'Set-Content',
    'si',
    'Set-Item',
    'start',
    'Start-Process'
)
$staticMutationPattern = '(?i)\[(?:System\.)?IO\.(?:File|Directory)\]\s*::\s*(?:Copy|Create|CreateDirectory|Delete|Move|OpenWrite|Replace|Write\w*)\s*\('
$writeCapableOpenPattern = '(?is)\[(?:System\.)?IO\.File\]\s*::\s*Open\s*\([^\)]*(?:FileMode\]\s*::\s*(?:Append|Create|CreateNew|OpenOrCreate|Truncate)|FileAccess\]\s*::\s*(?:Write|ReadWrite))'
$writeCapableStreamPattern = '(?is)\[(?:System\.)?IO\.FileStream\]\s*::\s*new\s*\([^\)]*(?:FileMode\]\s*::\s*(?:Append|Create|CreateNew|OpenOrCreate|Truncate)|FileAccess\]\s*::\s*(?:Write|ReadWrite))'
$writerConstructionPattern = '(?i)\[(?:System\.)?IO\.(?:BinaryWriter|StreamWriter)\]\s*::\s*new\s*\('
$zipExtractionPattern = '(?i)(?:ZipFileExtensions|ZipArchiveEntry)\]\s*::\s*ExtractToFile\s*\('
$contractFileNames = @($moduleContracts.Path | ForEach-Object { Split-Path $_ -Leaf })

foreach ($contract in $moduleContracts) {
    if (-not (Test-Path -LiteralPath $contract.Path -PathType Leaf)) {
        throw "Required runtime-stage module is missing: $($contract.Path)"
    }
    $moduleSource = Get-Content -LiteralPath $contract.Path -Raw
    $moduleAst = Get-PowerShellAst -Path $contract.Path
    $commands = @($moduleAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    foreach ($command in $commands) {
        $commandName = $command.GetCommandName()
        if ($commandName -and $forbiddenCommands -contains $commandName) {
            throw "Read-only module '$($contract.Name)' contains forbidden mutator '$commandName' at line $($command.Extent.StartLineNumber)."
        }
        if ($commandName -eq 'Import-Module') {
            $importMatch = [regex]::Match($command.Extent.Text, "'(?<File>[^']+\.psm1)'")
            if (-not $importMatch.Success -or $contractFileNames -notcontains (Split-Path $importMatch.Groups['File'].Value -Leaf)) {
                throw "Read-only module '$($contract.Name)' imports an unregistered module: $($command.Extent.Text)"
            }
        }
    }
    $redirections = @($moduleAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FileRedirectionAst]
    }, $true))
    if ($redirections.Count -gt 0 -or $moduleSource -match $staticMutationPattern -or
        $moduleSource -match $writeCapableOpenPattern -or $moduleSource -match $writeCapableStreamPattern -or
        $moduleSource -match $writerConstructionPattern -or $moduleSource -match $zipExtractionPattern) {
        throw "Read-only module '$($contract.Name)' contains a filesystem mutation or extraction primitive."
    }

    $importedModule = @(Import-Module $contract.Path -Force -PassThru -ErrorAction Stop |
        Where-Object { $_.Name -eq $contract.Name } | Select-Object -Last 1)
    if ($importedModule.Count -ne 1) {
        throw "Could not inspect the exported command surface for module '$($contract.Name)'."
    }
    $actualExports = @($importedModule[0].ExportedCommands.Keys | Sort-Object)
    $expectedExports = @($contract.Exports | Sort-Object)
    Assert-ExactSequence -Description "$($contract.Name) exports" -Actual $actualExports -Expected $expectedExports
}

$safetyModuleAst = Get-PowerShellAst -Path $safetyModulePath
Assert-ExactSequence `
    -Description 'Assert-FearIntentionalReadOnlyJunction parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $safetyModuleAst -FunctionName 'Assert-FearIntentionalReadOnlyJunction') `
    -Expected @('Path', 'Target', 'MountName')
Assert-ExactSequence `
    -Description 'Assert-FearStageTreeNoUnexpectedReparsePoints parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $safetyModuleAst -FunctionName 'Assert-FearStageTreeNoUnexpectedReparsePoints') `
    -Expected @('StageRoot', 'RetailTarget', 'AuthorizedMounts')

$runtimeExecutableModuleAst = Get-PowerShellAst -Path $runtimeExecutableModulePath
Assert-ExactSequence `
    -Description 'Get-FearAttestedLaaRuntimeExecutablePairIdentity parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $runtimeExecutableModuleAst -FunctionName 'Get-FearAttestedLaaRuntimeExecutablePairIdentity') `
    -Expected @('RetailExecutable', 'PatchedExecutable', 'BackupExecutable')

$ownershipModuleAst = Get-PowerShellAst -Path $ownershipModulePath
Assert-ExactSequence `
    -Description 'Assert-FearStageRuntimeExecutableOwnership parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $ownershipModuleAst -FunctionName 'Assert-FearStageRuntimeExecutableOwnership') `
    -Expected @('Root', 'Manifest', 'ExpectedExecutableName')
Assert-ExactSequence `
    -Description 'Assert-FearStagePostProcessOwnership parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $ownershipModuleAst -FunctionName 'Assert-FearStagePostProcessOwnership') `
    -Expected @('Root', 'PackagePlan', 'ExpectedPackageIdentity', 'ExistingManifest')
Assert-ExactSequence `
    -Description 'Assert-FearStageControllerOwnership parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $ownershipModuleAst -FunctionName 'Assert-FearStageControllerOwnership') `
    -Expected @('Root', 'StageLane', 'ExpectedPackageIdentity', 'ExistingManifest')

$controllerPackageModuleAst = Get-PowerShellAst -Path $controllerPackageModulePath
Assert-ExactSequence `
    -Description 'Get-FearControllerPackageStagePayload parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $controllerPackageModuleAst -FunctionName 'Get-FearControllerPackageStagePayload') `
    -Expected @('ArchivePath')

$texturePackageModuleAst = Get-PowerShellAst -Path $texturePackageModulePath
Assert-ExactSequence `
    -Description 'Get-FearHdTexturePackageIdentity parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $texturePackageModuleAst -FunctionName 'Get-FearHdTexturePackageIdentity') `
    -Expected @('PackageRoot', 'RequireKnownMode', 'RequireKnownRivarezV202')

$planModuleAst = Get-PowerShellAst -Path $planModulePath
Assert-ExactSequence `
    -Description 'Assert-FearRuntimeStagePackageSelection parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $planModuleAst -FunctionName 'Assert-FearRuntimeStagePackageSelection') `
    -Expected @('Lane', 'ControllerArchiveSpecified', 'RendererMode', 'RendererQuality', 'RendererQualitySpecified', 'DgVoodooArchiveSpecified', 'RtxRemixArchiveSpecified', 'PostProcessMode', 'ReShadeSetupSpecified', 'EnginePatchMode', 'EnginePatchPackageRootSpecified', 'EnginePatchManifestSpecified', 'MaxFPSExplicit')
Assert-ExactSequence `
    -Description 'Resolve-FearRuntimeStagePackagePlan parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $planModuleAst -FunctionName 'Resolve-FearRuntimeStagePackagePlan') `
    -Expected @('Lane', 'Configuration', 'RepositoryRoot', 'RuntimeToolsRoot', 'ControllerArchive', 'ControllerArchiveSpecified', 'RendererMode', 'RendererQuality', 'RendererQualitySpecified', 'DgVoodooArchive', 'DgVoodooArchiveSpecified', 'RtxRemixArchive', 'RtxRemixArchiveSpecified', 'PostProcessMode', 'ReShadeSetup', 'ReShadeSetupSpecified', 'EnginePatchMode', 'EnginePatchPackageRoot', 'EnginePatchPackageRootSpecified', 'EnginePatchManifest', 'EnginePatchManifestSpecified', 'MaxFPS', 'MaxFPSExplicit')
Assert-ExactSequence `
    -Description 'Get-FearRebuiltStageMutationRelativePaths parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $planModuleAst -FunctionName 'Get-FearRebuiltStageMutationRelativePaths') `
    -Expected @('RendererMode', 'RendererPackageIdentity', 'RendererConfigFile', 'EnginePatchMode', 'PostProcessManagedFiles', 'ControllerManagedFiles', 'GameModuleNames')
Assert-ExactSequence `
    -Description 'Get-FearRuntimeStagePackageIdentities parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $planModuleAst -FunctionName 'Get-FearRuntimeStagePackageIdentities') `
    -Expected @('RendererMode', 'RendererQuality', 'DgVoodooArchive', 'RtxRemixArchive', 'RendererConfigSource', 'RendererRuntimeConfigSeedSource', 'PostProcessMode', 'PostProcessSetup', 'PostProcessAssetRoot', 'ControllerArchive', 'EnginePatchMode', 'EnginePatchPackageRoot', 'EnginePatchManifest')

$rendererPackageModuleAst = Get-PowerShellAst -Path $rendererPackageModulePath
Assert-ExactSequence `
    -Description 'Get-FearDgVoodooConfigIdentity parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $rendererPackageModuleAst -FunctionName 'Get-FearDgVoodooConfigIdentity') `
    -Expected @('Path', 'RendererQuality')

$stageSource = Get-Content -LiteralPath $stageScript -Raw
$stageAst = Get-PowerShellAst -Path $stageScript
Assert-ExactSequence `
    -Description 'Runtime-stage entry parameters' `
    -Actual @($stageAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath }) `
    -Expected @(
        'Lane',
        'Configuration',
        'RepositoryRoot',
        'RetailRoot',
        'SdkRoot',
        'BuildRoot',
        'StageRoot',
        'EchoPatchArchive',
        'ControllerArchive',
        'RendererMode',
        'RendererQuality',
        'DgVoodooArchive',
        'RtxRemixArchive',
        'PostProcessMode',
        'ReShadeSetup',
        'EnginePatchMode',
        'EnginePatchPackageRoot',
        'EnginePatchManifest',
        'HdTextureMode',
        'HdTexturePackRoot',
        'HdTextureLaaExecutable',
        'HdTextureLaaBackup',
        'MaxFPS',
        'SSAAScale',
        'ValidateOnly',
        'RefreshRuntimeExecutable',
        'Launch',
        'LaunchArguments'
    )
if ($stageSource -notmatch "(?s)\[ValidateSet\('Native',\s*'Max2x'\)\]\s*\[string\]\`$RendererQuality" -or
    $stageSource -notmatch "(?s)\[ValidateSet\('None',\s*'ReShadeCas'\)\]\s*\[string\]\`$PostProcessMode" -or
    $stageSource -notmatch "(?s)\[ValidateSet\('None',\s*'EngineOnlyEchoPatch',\s*'RemixDiagnosticEchoPatch',\s*'CameraDiagnosticEchoPatch',\s*'RtxCameraDiagnosticEchoPatch',\s*'RtxCameraReassertionEchoPatch'\)\]\s*\[string\]\`$EnginePatchMode" -or
    $stageSource -notmatch "(?s)\[ValidateSet\('Off',\s*'Lite',\s*'Full'\)\]\s*\[string\]\`$HdTextureMode") {
    throw 'Runtime-stage entry script no longer exposes the intentional Remix-diagnostic or HD-texture mode surfaces.'
}
foreach ($explicitParameterName in @(
    'RendererQuality',
    'DgVoodooArchive',
    'RtxRemixArchive',
    'ReShadeSetup',
    'EnginePatchPackageRoot',
    'EnginePatchManifest',
    'HdTexturePackRoot',
    'HdTextureLaaExecutable',
    'HdTextureLaaBackup',
    'MaxFPS',
    'SSAAScale'
)) {
    $explicitParameterPattern = "\`$PSBoundParameters\.ContainsKey\('$([regex]::Escape($explicitParameterName))'\)"
    if ($stageSource -notmatch $explicitParameterPattern) {
        throw "Runtime-stage entry script no longer preserves explicit-bound semantics for -$explicitParameterName."
    }
}
$generatedSchemaMatches = [regex]::Matches($stageSource, '(?m)^\s*SchemaVersion\s*=\s*9\s*$')
if ($generatedSchemaMatches.Count -ne 1) {
    throw "Runtime-stage orchestrator must emit exactly one schema-9 manifest declaration; found $($generatedSchemaMatches.Count)."
}
$stageFunctions = @($stageAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false))
$stageFunctionNames = @($stageFunctions | ForEach-Object Name)
Assert-ExactSequence `
    -Description 'Write-BytesToStage parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $stageAst -FunctionName 'Write-BytesToStage') `
    -Expected @('Bytes', 'Destination', 'StageRoot', 'ExpectedSize', 'ExpectedSha256', 'Description', 'CreateNew')
Assert-ExactSequence `
    -Description 'Start-FearRebuiltStageTransition parameters' `
    -Actual (Get-DeclaredFunctionParameterNames -Ast $stageAst -FunctionName 'Start-FearRebuiltStageTransition') `
    -Expected @('StageRoot', 'ExistingManifest', 'DesiredRetailTarget', 'ExistingMount', 'DesiredMountTarget', 'ManagedRelativePaths', 'ManagedRelativeDirectories')
if ($stageSource -notmatch '(?s)\[IO\.FileMode\]::CreateNew' -or
    $stageSource -notmatch '(?s)-Description\s+"first-enable post-process config[^\r\n]+"\s*`\s*\r?\n\s*-CreateNew') {
    throw 'First-enable post-process seeds are no longer created through the atomic CreateNew write path.'
}
if ($stageSource -notmatch '(?s)\$ancestorRelativePath\s*=\s*Split-Path\s+\$canonicalRelativePath\s+-Parent.*?\$derivedManagedDirectories\.Add\(\$ancestorRelativePath\)' -or
    $stageSource -notmatch '(?s)\$rebuiltTransitionDirectories\s*=.*?RendererRequiredDirectories.*?RendererRuntimeWritableDirectories' -or
    $stageSource -notmatch '(?s)-ManagedRelativeDirectories\s+@\(\$rebuiltTransitionDirectories\)') {
    throw 'Rebuilt transition no longer derives managed-file ancestor directories or supplies renderer-owned/runtime-writable directory roots.'
}
$stageCommands = @($stageAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true))
foreach ($importCommand in @($stageCommands | Where-Object { $_.GetCommandName() -eq 'Import-Module' })) {
    $importMatch = [regex]::Match($importCommand.Extent.Text, "'(?<File>[^']+\.psm1)'")
    if (-not $importMatch.Success -or $contractFileNames -notcontains (Split-Path $importMatch.Groups['File'].Value -Leaf)) {
        throw "Runtime-stage orchestrator imports an unregistered module: $($importCommand.Extent.Text)"
    }
}

$junctionCreationRecords = [Collections.Generic.List[object]]::new()
$junctionRemovalRecords = [Collections.Generic.List[object]]::new()
$productionRuntimeScripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object {
    $_.Extension -in @('.ps1', '.psm1') -and $_.BaseName -notlike 'Test-*'
})
foreach ($productionScript in $productionRuntimeScripts) {
    $productionSource = Get-Content -LiteralPath $productionScript.FullName -Raw
    $productionAst = Get-PowerShellAst -Path $productionScript.FullName
    if ($productionSource -match '(?im)\bmklink(?:\.exe)?\b[^\r\n]*\s/J(?:\s|$)' -and
        -not (Test-FearPathsEqual -Left $productionScript.FullName -Right $stageScript)) {
        throw "Only New-FearRuntimeStage.ps1 may create a runtime-stage junction: $($productionScript.FullName)"
    }
    $productionCommands = @($productionAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    foreach ($productionCommand in $productionCommands) {
        $commandName = $productionCommand.GetCommandName()
        $functionName = Get-EnclosingFunctionName -Command $productionCommand
        $createsJunction = $commandName -in @('New-Item', 'ni') -and
            $productionCommand.Extent.Text -match '(?i)-(?:ItemType|Type)\s+["'']?Junction\b'
        if ($createsJunction) {
            if (-not (Test-FearPathsEqual -Left $productionScript.FullName -Right $stageScript)) {
                throw "Only New-FearRuntimeStage.ps1 may create a runtime-stage junction: $($productionScript.FullName):$($productionCommand.Extent.StartLineNumber)"
            }
            $junctionCreationRecords.Add([pscustomobject]@{
                File = $productionScript.FullName
                Function = $functionName
                Line = $productionCommand.Extent.StartLineNumber
            })
        }

        $removesMount = $commandName -in @('Remove-Item', 'del', 'erase', 'rd', 'ri', 'rmdir', 'rm') -and
            (($functionName -and $functionName -match '(?i)(?:Junction|Mount)') -or
                $productionCommand.Extent.Text -match '(?i)(?:HDTextures|Retail|Junction|Mount)')
        if ($removesMount) {
            if (-not (Test-FearPathsEqual -Left $productionScript.FullName -Right $stageScript)) {
                throw "Only New-FearRuntimeStage.ps1 may remove a runtime-stage mount junction: $($productionScript.FullName):$($productionCommand.Extent.StartLineNumber)"
            }
            $junctionRemovalRecords.Add([pscustomobject]@{
                File = $productionScript.FullName
                Function = $functionName
                Line = $productionCommand.Extent.StartLineNumber
            })
        }
    }
    $mountFunctions = @($productionAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -match '(?i)(?:Junction|Mount)'
    }, $true))
    foreach ($mountFunction in $mountFunctions) {
        $staticDeleteMatches = [regex]::Matches(
            $mountFunction.Extent.Text,
            '(?i)\[(?:System\.)?IO\.Directory\]\s*::\s*Delete\s*\(')
        foreach ($staticDeleteMatch in $staticDeleteMatches) {
            if (-not (Test-FearPathsEqual -Left $productionScript.FullName -Right $stageScript)) {
                throw "Only New-FearRuntimeStage.ps1 may remove a runtime-stage mount junction: $($productionScript.FullName):$($mountFunction.Extent.StartLineNumber)"
            }
            $junctionRemovalRecords.Add([pscustomobject]@{
                File = $productionScript.FullName
                Function = $mountFunction.Name
                Line = $mountFunction.Extent.StartLineNumber
            })
        }
    }
}
if ($junctionCreationRecords.Count -ne 1 -or
    $junctionCreationRecords[0].Function -cne 'Ensure-ReadOnlyStageJunction') {
    throw "Read-only stage junction creation must have one owner, Ensure-ReadOnlyStageJunction; found $($junctionCreationRecords.Count)."
}
if ($junctionRemovalRecords.Count -ne 1 -or
    $junctionRemovalRecords[0].Function -cne 'Sync-HdTextureJunction') {
    throw "Read-only stage junction removal must have one owner, Sync-HdTextureJunction; found $($junctionRemovalRecords.Count)."
}

$localFunctionCalls = @{}
$mutatingLocalFunctions = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($stageFunction in $stageFunctions) {
    $functionCommands = @($stageFunction.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst]
    }, $true))
    $localFunctionCalls[$stageFunction.Name] = @($functionCommands |
        ForEach-Object { $_.GetCommandName() } |
        Where-Object { $_ -and $stageFunctionNames -contains $_ } |
        Sort-Object -Unique)
    $functionRedirections = @($stageFunction.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.FileRedirectionAst]
    }, $true))
    $containsForbiddenCommand = @($functionCommands | Where-Object {
        $commandName = $_.GetCommandName()
        $commandName -and $forbiddenCommands -contains $commandName
    }).Count -gt 0
    $functionSource = $stageFunction.Extent.Text
    if ($containsForbiddenCommand -or $functionRedirections.Count -gt 0 -or
        $functionSource -match $staticMutationPattern -or $functionSource -match $writeCapableOpenPattern -or
        $functionSource -match $writeCapableStreamPattern -or $functionSource -match $writerConstructionPattern -or
        $functionSource -match $zipExtractionPattern) {
        [void]$mutatingLocalFunctions.Add($stageFunction.Name)
    }
}
do {
    $mutationSetChanged = $false
    foreach ($stageFunction in $stageFunctions) {
        if ($mutatingLocalFunctions.Contains($stageFunction.Name)) {
            continue
        }
        foreach ($calledFunction in @($localFunctionCalls[$stageFunction.Name])) {
            if ($mutatingLocalFunctions.Contains($calledFunction)) {
                [void]$mutatingLocalFunctions.Add($stageFunction.Name)
                $mutationSetChanged = $true
                break
            }
        }
    }
} while ($mutationSetChanged)

$movedFunctionNames = @(
    'Get-CanonicalPath',
    'Test-PathIsBelow',
    'Test-PathsEqual',
    'Assert-NoReparsePathComponents',
    'Assert-SafeStageDirectoryTarget',
    'Assert-SafeStageFileTarget',
    'Get-StageOwnershipTransactionPaths',
    'Assert-NoStageOwnershipTransactionFiles',
    'Get-SteamAppIdHintPlan',
    'Get-StageManifestMode',
    'Assert-ExistingManagedStageFile',
    'Assert-ExistingManagedRendererPayload',
    'Assert-StageProxyOwnership',
    'Assert-StageRuntimeExecutableOwnership',
    'Assert-OwnedStage',
    'Get-FearRebuiltStageMutationRelativePaths',
    'Assert-IntentionalReadOnlyJunction',
    'Assert-IntentionalRetailJunction',
    'Assert-StageTreeNoUnexpectedReparsePoints'
)
foreach ($functionName in $movedFunctionNames) {
    if ($stageFunctionNames -contains $functionName) {
        throw "Moved read-only function '$functionName' still exists in the write orchestrator."
    }
}

if ($stageSource -notmatch '(?m)^\[CmdletBinding\(SupportsShouldProcess\s*=\s*\$true\)\]') {
    throw 'Runtime-stage orchestrator no longer declares SupportsShouldProcess.'
}
$lastFunctionEndOffset = ($stageFunctions | Sort-Object { $_.Extent.EndOffset } | Select-Object -Last 1).Extent.EndOffset
$mainSource = $stageSource.Substring($lastFunctionEndOffset)
$shouldProcessMatches = [regex]::Matches($mainSource, '\$PSCmdlet\.ShouldProcess\s*\(')
if ($shouldProcessMatches.Count -ne 1) {
    throw "Runtime-stage orchestrator must contain exactly one top-level ShouldProcess boundary; found $($shouldProcessMatches.Count)."
}
$shouldProcessOffset = $lastFunctionEndOffset + $shouldProcessMatches[0].Index
$guardedReturnPattern = '(?s)if\s*\(\s*-not\s+\$PSCmdlet\.ShouldProcess\s*\([^\r\n]*\)\s*\)\s*\{\s*\$validationResult\s*\r?\n\s*return\s*\}'
if ($mainSource -notmatch $guardedReturnPattern) {
    throw 'The sole ShouldProcess call is no longer a fail-closed if (-not ShouldProcess) validation-result return gate.'
}
$preBoundarySource = $stageSource.Substring(
    $lastFunctionEndOffset,
    $shouldProcessOffset - $lastFunctionEndOffset)
$preBoundaryRedirections = @($stageAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.FileRedirectionAst]
}, $true) | Where-Object {
    $_.Extent.StartOffset -gt $lastFunctionEndOffset -and $_.Extent.StartOffset -lt $shouldProcessOffset
})
if ($preBoundaryRedirections.Count -gt 0 -or $preBoundarySource -match $staticMutationPattern -or
    $preBoundarySource -match $writeCapableOpenPattern -or $preBoundarySource -match $writeCapableStreamPattern -or
    $preBoundarySource -match $writerConstructionPattern -or $preBoundarySource -match $zipExtractionPattern) {
    throw 'Runtime-stage orchestrator contains a direct filesystem mutation before its sole ShouldProcess boundary.'
}
$preBoundaryMutatorCommands = @($forbiddenCommands + @($mutatingLocalFunctions) | Sort-Object -Unique)
$topLevelCommands = @($stageAst.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst]
}, $true) | Where-Object { $_.Extent.StartOffset -gt $lastFunctionEndOffset })
foreach ($command in $topLevelCommands) {
    $commandName = $command.GetCommandName()
    if ($commandName -and $preBoundaryMutatorCommands -contains $commandName -and
        $command.Extent.StartOffset -lt $shouldProcessOffset) {
        throw "Top-level mutator '$commandName' occurs before the sole ShouldProcess boundary at line $($command.Extent.StartLineNumber)."
    }
}
foreach ($requiredMutatingFunction in @(
    'Copy-FileToStage',
    'Copy-RetailRuntimeFiles',
    'Copy-RendererArchivePayloadToStage',
    'Copy-ZipEntry',
    'Ensure-ReadOnlyStageJunction',
    'Ensure-RetailJunction',
    'Invoke-TransactionalStageOwnershipCommit',
    'Sync-HdTextureJunction',
    'Sync-StockRuntimeExecutable',
    'Write-BytesToStage',
    'Write-SteamAppIdHintFile',
    'Write-StageManifest'
)) {
    if (-not $mutatingLocalFunctions.Contains($requiredMutatingFunction)) {
        throw "Architecture guard failed to derive local mutator '$requiredMutatingFunction' from the orchestrator call graph."
    }
}
foreach ($requiredMutator in @(
    'New-Item',
    'Copy-FileToStage',
    'Write-BytesToStage',
    'Invoke-TransactionalStageOwnershipCommit',
    'Sync-HdTextureJunction',
    'Start-Process'
)) {
    if (-not @($topLevelCommands | Where-Object { $_.GetCommandName() -eq $requiredMutator })) {
        throw "Architecture guard could not find expected orchestrator mutator entrypoint '$requiredMutator'."
    }
}

$planArguments = @{
    Lane                           = 'Rebuilt'
    Configuration                  = 'Release'
    RepositoryRoot                 = $RepositoryRoot
    RuntimeToolsRoot               = $PSScriptRoot
    ControllerArchive              = $null
    RendererMode                   = 'NativeD3D9'
    RendererQuality                = 'Native'
    RendererQualitySpecified       = $false
    DgVoodooArchive                = $null
    DgVoodooArchiveSpecified       = $false
    RtxRemixArchive                = $null
    RtxRemixArchiveSpecified       = $false
    PostProcessMode                = 'None'
    ReShadeSetup                   = $null
    ReShadeSetupSpecified          = $false
    EnginePatchMode                = 'None'
    EnginePatchPackageRoot         = $null
    EnginePatchPackageRootSpecified = $false
    EnginePatchManifest            = $null
    EnginePatchManifestSpecified   = $false
    MaxFPS                         = 60.0
    MaxFPSExplicit                 = $false
}
$nativePlan = Resolve-FearRuntimeStagePackagePlan @planArguments
$expectedControllerArchive = Join-Path $RepositoryRoot 'vendor-local\controller-deps\SDL3-3.4.10-win32-x86.zip'
if ($nativePlan.DefaultStageDirectoryName -cne 'fearmore-rebuilt-release' -or
    $nativePlan.ControllerArchive -cne $expectedControllerArchive -or
    @($nativePlan.ControllerRequiredFiles).Count -ne 2 -or
    'SDL3.dll' -notin @($nativePlan.ControllerManagedFiles) -or
    '.fearmore\licenses\SDL3-zlib.txt' -notin @($nativePlan.ControllerManagedFiles) -or
    '.fearmore\licenses' -notin @($nativePlan.ControllerManagedDirectories) -or
    $null -ne $nativePlan.RendererQuality -or
    $nativePlan.RendererExperimental -or $nativePlan.RendererCompatibilityStatus -cne 'NotApplicable' -or
    $nativePlan.PostProcessMode -cne 'None' -or $nativePlan.PostProcessExperimental -or
    $nativePlan.PostProcessCompatibilityStatus -cne 'NotApplicable' -or
    $nativePlan.EnginePatchForceWindowed -or $nativePlan.EnginePatchFixWindowStyle -or
    @($nativePlan.RendererForbiddenPaths).Count -ne 7 -or $nativePlan.MaxFPS -or $null -ne $nativePlan.DynamicVsync) {
    throw 'Native renderer/package plan changed its default stage identity or policy.'
}

$modernArguments = $planArguments.Clone()
$modernArguments.RendererMode = 'DgVoodooD3D11'
$modernArguments.EnginePatchMode = 'EngineOnlyEchoPatch'
$modernPlan = Resolve-FearRuntimeStagePackagePlan @modernArguments
if ($modernPlan.DefaultStageDirectoryName -cne 'fearmore-rebuilt-release-dgvoodoo-d3d11-engine-only-echopatch' -or
    $modernPlan.RendererQuality -cne 'Native' -or
    $modernPlan.RendererConfigSource -cne (Join-Path $PSScriptRoot 'config\dgVoodoo-d3d11.conf') -or
    $modernPlan.RendererCompatibilityStatus -cne 'LiveAcceptedDgVoodooD3D11' -or
    $modernPlan.EnginePatchForceWindowed -or -not $modernPlan.EnginePatchFixWindowStyle -or
    $modernPlan.MaxFPS -ne 60.0 -or $modernPlan.DynamicVsync -ne 1 -or $modernPlan.MaxFPSExplicit) {
    throw 'Modern renderer/package plan no longer preserves the omitted-MaxFPS defaults.'
}

$postProcessArguments = $modernArguments.Clone()
$postProcessArguments.PostProcessMode = 'ReShadeCas'
$postProcessPlan = Resolve-FearRuntimeStagePackagePlan @postProcessArguments
$expectedPostProcessRoot = Join-Path $PSScriptRoot 'postprocess'
$expectedReShadeSetup = Join-Path $RepositoryRoot 'vendor-local\postprocess-deps\ReShade_Setup_6.7.3.exe'
if ($postProcessPlan.DefaultStageDirectoryName -cne $modernPlan.DefaultStageDirectoryName -or
    $postProcessPlan.PostProcessMode -cne 'ReShadeCas' -or
    $postProcessPlan.PostProcessSetup -cne $expectedReShadeSetup -or
    $postProcessPlan.PostProcessAssetRoot -cne $expectedPostProcessRoot -or
    $postProcessPlan.PostProcessExperimental -or
    $postProcessPlan.PostProcessCompatibilityStatus -cne 'LiveAcceptedDgVoodooDxgiChain' -or
    @($postProcessPlan.PostProcessRequiredFiles).Count -ne 6 -or
    @($postProcessPlan.PostProcessForbiddenFiles).Count -ne 0 -or
    @($postProcessPlan.PostProcessImmutableFiles).Count -ne 6 -or
    @($postProcessPlan.PostProcessAssetFiles).Count -ne 5 -or
    @($postProcessPlan.PostProcessRuntimeMutableFiles).Count -ne 3 -or
    @($postProcessPlan.PostProcessRuntimeWritableDirectories).Count -ne 1 -or
    @($postProcessPlan.PostProcessSeedFiles).Count -ne 2 -or
    @($postProcessPlan.PostProcessManagedDirectories).Count -ne 5 -or
    'dxgi.dll' -notin @($postProcessPlan.PostProcessImmutableFiles) -or
    'ReShade.ini' -notin @($postProcessPlan.PostProcessManagedFiles) -or
    'FearMore-CAS.ini' -notin @($postProcessPlan.PostProcessManagedFiles)) {
    throw 'ReShadeCas planning no longer preserves its fixed Modern-stage, exact ownership, or live-accepted compatibility contract.'
}

$max2xArguments = $modernArguments.Clone()
$max2xArguments.RendererQuality = 'Max2x'
$max2xArguments.RendererQualitySpecified = $true
$max2xPlan = Resolve-FearRuntimeStagePackagePlan @max2xArguments
if ($max2xPlan.DefaultStageDirectoryName -cne 'fearmore-rebuilt-release-dgvoodoo-d3d11-max2x-engine-only-echopatch' -or
    $max2xPlan.RendererQuality -cne 'Max2x' -or
    $max2xPlan.RendererConfigSource -cne (Join-Path $PSScriptRoot 'config\dgVoodoo-d3d11-max2x.conf') -or
    $max2xPlan.EnginePatchForceWindowed -or -not $max2xPlan.EnginePatchFixWindowStyle -or
    $max2xPlan.MaxFPS -ne 60.0 -or $max2xPlan.DynamicVsync -ne 1 -or $max2xPlan.MaxFPSExplicit) {
    throw 'Max2x renderer/package plan no longer differs from Native only through its owned quality profile.'
}

$explicitCapArguments = $modernArguments.Clone()
$explicitCapArguments.MaxFPSExplicit = $true
$explicitCapPlan = Resolve-FearRuntimeStagePackagePlan @explicitCapArguments
if ($explicitCapPlan.MaxFPS -ne 60.0 -or $explicitCapPlan.DynamicVsync -ne 0 -or -not $explicitCapPlan.MaxFPSExplicit) {
    throw 'Explicit -MaxFPS 60 is no longer distinguishable from an omitted MaxFPS.'
}

$rtxLabArguments = $planArguments.Clone()
$rtxLabArguments.RendererMode = 'RtxRemixProbe'
$rtxLabArguments.EnginePatchMode = 'RtxCameraDiagnosticEchoPatch'
$rtxLabPlan = Resolve-FearRuntimeStagePackagePlan @rtxLabArguments
if ($rtxLabPlan.DefaultStageDirectoryName -cne 'fearmore-rebuilt-release-rtx-remix-probe-1-5-2-rtx-camera-diagnostics-focus-preserved' -or
    -not $rtxLabPlan.RendererExperimental -or
    $rtxLabPlan.RendererCompatibilityStatus -cne 'UnverifiedProbe' -or
    $rtxLabPlan.MaxFPS -ne 60.0 -or $rtxLabPlan.DynamicVsync -ne 1 -or
    $rtxLabPlan.MaxFPSExplicit -or
    $rtxLabPlan.EnginePatchMode -cne 'RtxCameraDiagnosticEchoPatch' -or
    -not $rtxLabPlan.EnginePatchForceWindowed -or -not $rtxLabPlan.EnginePatchFixWindowStyle -or
    $rtxLabPlan.RendererConfigFile -cne '.trex\bridge.conf' -or
    $rtxLabPlan.RendererConfigSource -cne (Join-Path $PSScriptRoot 'config\rtx-remix-bridge.conf') -or
    $rtxLabPlan.RendererRuntimeConfigSeedSource -cne (Join-Path $PSScriptRoot 'config\rtx-remix-runtime.conf') -or
    '.trex\bridge.conf' -notin @($rtxLabPlan.RendererRequiredFiles) -or
    '.trex\bridge.conf' -in @($rtxLabPlan.RendererRuntimeMutableFiles) -or
    @($rtxLabPlan.EnginePatchRequiredFiles).Count -ne 2) {
    throw 'RtxLab no longer preserves its query-light camera-diagnostic identity or bounded 60-FPS policy.'
}
$rtxLabMutationPaths = @(Get-FearRebuiltStageMutationRelativePaths `
    -RendererMode 'RtxRemixProbe' `
    -RendererPackageIdentity ([pscustomobject]@{ Files = @([pscustomobject]@{ RelativePath = 'd3d9.dll' }) }) `
    -RendererConfigFile $rtxLabPlan.RendererConfigFile `
    -EnginePatchMode 'RtxCameraDiagnosticEchoPatch' `
    -PostProcessManagedFiles @($postProcessPlan.PostProcessImmutableFiles) `
    -ControllerManagedFiles @($rtxLabPlan.ControllerManagedFiles) `
    -GameModuleNames @('GameClient.dll', 'GameServer.dll', 'ClientFx.fxd'))
if (@($rtxLabMutationPaths | Where-Object { $_ -ceq '.trex\bridge.conf' }).Count -ne 1 -or
    @($rtxLabMutationPaths | Where-Object { $_ -ceq 'rtx.conf' }).Count -ne 1 -or
    @($rtxLabMutationPaths | Where-Object { $_ -ceq 'dxgi.dll' }).Count -ne 1 -or
    @($rtxLabMutationPaths | Where-Object { $_ -ceq 'SDL3.dll' }).Count -ne 1 -or
    @($rtxLabMutationPaths | Where-Object { $_ -ceq '.fearmore\licenses\SDL3-zlib.txt' }).Count -ne 1 -or
    @($rtxLabMutationPaths | Where-Object { $_ -ceq 'ReShade.ini' }).Count -ne 0 -or
    @($rtxLabMutationPaths | Where-Object { $_ -ceq '.fearmore\postprocess\Shaders\FearMoreCAS.fx' }).Count -ne 1) {
    throw 'Ordinary Rebuilt mutation inventory does not contain exactly one renderer config, runtime seed, post-process proxy, and shader path while excluding mutable post-process config.'
}
$firstEnableMutationPaths = @(Get-FearRebuiltStageMutationRelativePaths `
    -RendererMode 'DgVoodooD3D11' `
    -RendererPackageIdentity $null `
    -RendererConfigFile $postProcessPlan.RendererConfigFile `
    -EnginePatchMode 'EngineOnlyEchoPatch' `
    -PostProcessManagedFiles @($postProcessPlan.PostProcessManagedFiles) `
    -ControllerManagedFiles @($postProcessPlan.ControllerManagedFiles) `
    -GameModuleNames @('GameClient.dll', 'GameServer.dll', 'ClientFx.fxd'))
if (@($firstEnableMutationPaths | Where-Object { $_ -ceq 'ReShade.ini' }).Count -ne 1 -or
    @($firstEnableMutationPaths | Where-Object { $_ -ceq 'FearMore-CAS.ini' }).Count -ne 1) {
    throw 'First-enable Rebuilt mutation inventory does not include each config seed target exactly once.'
}

# Preserve the deep per-draw probe as a historical developer-only package contract. It is
# intentionally not the launcher-facing RtxLab plan because its synchronous queries can stall Remix.
$historicalRemixDiagnosticArguments = $planArguments.Clone()
$historicalRemixDiagnosticArguments.RendererMode = 'RtxRemixProbe'
$historicalRemixDiagnosticArguments.EnginePatchMode = 'RemixDiagnosticEchoPatch'
$historicalRemixDiagnosticPlan = Resolve-FearRuntimeStagePackagePlan @historicalRemixDiagnosticArguments
if ($historicalRemixDiagnosticPlan.DefaultStageDirectoryName -cne 'fearmore-rebuilt-release-rtx-remix-probe-1-5-2-remix-camera-diagnostics' -or
    $historicalRemixDiagnosticPlan.EnginePatchMode -cne 'RemixDiagnosticEchoPatch' -or
    -not $historicalRemixDiagnosticPlan.EnginePatchForceWindowed -or
    -not $historicalRemixDiagnosticPlan.EnginePatchFixWindowStyle -or
    $historicalRemixDiagnosticPlan.MaxFPS -ne 60.0 -or
    $historicalRemixDiagnosticPlan.DynamicVsync -ne 1 -or
    $historicalRemixDiagnosticPlan.MaxFPSExplicit -or
    @($historicalRemixDiagnosticPlan.EnginePatchRequiredFiles).Count -ne 2) {
    throw 'Historical RemixDiagnosticEchoPatch planning compatibility changed unexpectedly.'
}

$cameraDiagnosticArguments = $planArguments.Clone()
$cameraDiagnosticArguments.EnginePatchMode = 'CameraDiagnosticEchoPatch'
$cameraDiagnosticPlan = Resolve-FearRuntimeStagePackagePlan @cameraDiagnosticArguments
if ($cameraDiagnosticPlan.DefaultStageDirectoryName -cne 'fearmore-rebuilt-release-camera-diagnostics' -or
    $cameraDiagnosticPlan.RendererMode -cne 'NativeD3D9' -or
    $cameraDiagnosticPlan.EnginePatchMode -cne 'CameraDiagnosticEchoPatch' -or
    $cameraDiagnosticPlan.EnginePatchForceWindowed -or -not $cameraDiagnosticPlan.EnginePatchFixWindowStyle -or
    $cameraDiagnosticPlan.MaxFPS -ne 60.0 -or $cameraDiagnosticPlan.DynamicVsync -ne 1 -or
    $cameraDiagnosticPlan.MaxFPSExplicit -or
    @($cameraDiagnosticPlan.EnginePatchRequiredFiles).Count -ne 2 -or
    @($cameraDiagnosticPlan.RendererForbiddenPaths).Count -ne 7) {
    throw 'Native camera diagnostic plan no longer preserves its isolated query-light 60-FPS identity.'
}

$invalidPostProcessSelections = @(
    [pscustomobject]@{
        Lane = 'Rebuilt'
        RendererMode = 'NativeD3D9'
        EnginePatchMode = 'None'
        ExpectedMessage = 'requires -RendererMode DgVoodooD3D11'
    },
    [pscustomobject]@{
        Lane = 'StockEchoPatch'
        RendererMode = 'NativeD3D9'
        EnginePatchMode = 'None'
        ExpectedMessage = 'supported only by -Lane Rebuilt'
    },
    [pscustomobject]@{
        Lane = 'Rebuilt'
        RendererMode = 'RtxRemixProbe'
        EnginePatchMode = 'RtxCameraDiagnosticEchoPatch'
        ExpectedMessage = 'requires -RendererMode DgVoodooD3D11'
    }
)
foreach ($invalidSelection in $invalidPostProcessSelections) {
    $selectionArguments = $planArguments.Clone()
    $selectionArguments.Lane = $invalidSelection.Lane
    $selectionArguments.RendererMode = $invalidSelection.RendererMode
    $selectionArguments.EnginePatchMode = $invalidSelection.EnginePatchMode
    $selectionArguments.PostProcessMode = 'ReShadeCas'
    $selectionRejected = $false
    try {
        Resolve-FearRuntimeStagePackagePlan @selectionArguments | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains($invalidSelection.ExpectedMessage)) {
            throw
        }
        $selectionRejected = $true
    }
    if (-not $selectionRejected) {
        throw "Package planner accepted invalid ReShadeCas $($invalidSelection.Lane)/$($invalidSelection.RendererMode) selection."
    }
}

$invalidPackageCombinations = @(
    [pscustomobject]@{
        RendererMode = 'RtxRemixProbe'
        EnginePatchMode = 'EngineOnlyEchoPatch'
        MaxFPSExplicit = $false
        ExpectedMessage = 'requires a separately pinned camera-diagnostic EchoPatch derivative'
    },
    [pscustomobject]@{
        RendererMode = 'RtxRemixProbe'
        EnginePatchMode = 'None'
        MaxFPSExplicit = $false
        ExpectedMessage = 'requires a separately pinned camera-diagnostic EchoPatch derivative'
    },
    [pscustomobject]@{
        RendererMode = 'NativeD3D9'
        EnginePatchMode = 'RemixDiagnosticEchoPatch'
        MaxFPSExplicit = $false
        ExpectedMessage = 'requires -RendererMode RtxRemixProbe'
    },
    [pscustomobject]@{
        RendererMode = 'RtxRemixProbe'
        EnginePatchMode = 'RemixDiagnosticEchoPatch'
        MaxFPSExplicit = $true
        ExpectedMessage = '-MaxFPS is not configurable for RemixDiagnosticEchoPatch'
    },
    [pscustomobject]@{
        RendererMode = 'DgVoodooD3D11'
        EnginePatchMode = 'CameraDiagnosticEchoPatch'
        MaxFPSExplicit = $false
        ExpectedMessage = 'requires -RendererMode NativeD3D9 or RtxRemixProbe'
    },
    [pscustomobject]@{
        RendererMode = 'NativeD3D9'
        EnginePatchMode = 'CameraDiagnosticEchoPatch'
        MaxFPSExplicit = $true
        ExpectedMessage = '-MaxFPS is not configurable for CameraDiagnosticEchoPatch'
    },
    [pscustomobject]@{
        RendererMode = 'RtxRemixProbe'
        EnginePatchMode = 'CameraDiagnosticEchoPatch'
        MaxFPSExplicit = $true
        ExpectedMessage = '-MaxFPS is not configurable for CameraDiagnosticEchoPatch'
    },
    [pscustomobject]@{
        RendererMode = 'NativeD3D9'
        EnginePatchMode = 'RtxCameraDiagnosticEchoPatch'
        MaxFPSExplicit = $false
        ExpectedMessage = 'requires -RendererMode RtxRemixProbe'
    },
    [pscustomobject]@{
        RendererMode = 'RtxRemixProbe'
        EnginePatchMode = 'RtxCameraDiagnosticEchoPatch'
        MaxFPSExplicit = $true
        ExpectedMessage = '-MaxFPS is not configurable for RtxCameraDiagnosticEchoPatch'
    }
)
foreach ($invalidCombination in $invalidPackageCombinations) {
    $combinationArguments = $planArguments.Clone()
    $combinationArguments.RendererMode = $invalidCombination.RendererMode
    $combinationArguments.EnginePatchMode = $invalidCombination.EnginePatchMode
    $combinationArguments.MaxFPSExplicit = $invalidCombination.MaxFPSExplicit
    $combinationRejected = $false
    try {
        Resolve-FearRuntimeStagePackagePlan @combinationArguments | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains($invalidCombination.ExpectedMessage)) {
            throw
        }
        $combinationRejected = $true
    }
    if (-not $combinationRejected) {
        throw "Package planner accepted invalid $($invalidCombination.RendererMode)/$($invalidCombination.EnginePatchMode) selection."
    }
}

$modeOwnershipRejected = $false
$invalidArguments = $planArguments.Clone()
$invalidArguments.Lane = 'StockEchoPatch'
$invalidArguments.RendererMode = 'DgVoodooD3D11'
try {
    Resolve-FearRuntimeStagePackagePlan @invalidArguments | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('supported only by -Lane Rebuilt')) {
        throw
    }
    $modeOwnershipRejected = $true
}
if (-not $modeOwnershipRejected) {
    throw 'Read-only package planner accepted a renderer outside the Rebuilt lane.'
}

$controllerArchiveOwnershipRejected = $false
$invalidControllerArguments = $planArguments.Clone()
$invalidControllerArguments.Lane = 'StockEchoPatch'
$invalidControllerArguments.ControllerArchive = 'explicit-controller-package.zip'
$invalidControllerArguments.ControllerArchiveSpecified = $true
try {
    Resolve-FearRuntimeStagePackagePlan @invalidControllerArguments | Out-Null
}
catch {
    if (-not $_.Exception.Message.Contains('-ControllerArchive is supported only by -Lane Rebuilt.')) {
        throw
    }
    $controllerArchiveOwnershipRejected = $true
}
if (-not $controllerArchiveOwnershipRejected) {
    throw 'Read-only package planner silently ignored an explicit controller archive outside the Rebuilt lane.'
}

$explicitOptionOwnershipCases = @(
    [pscustomobject]@{
        Flag            = 'RendererQualitySpecified'
        ExpectedMessage = '-RendererQuality requires -RendererMode DgVoodooD3D11.'
    },
    [pscustomobject]@{
        Flag            = 'DgVoodooArchiveSpecified'
        ExpectedMessage = '-DgVoodooArchive requires -RendererMode DgVoodooD3D11.'
    },
    [pscustomobject]@{
        Flag            = 'RtxRemixArchiveSpecified'
        ExpectedMessage = '-RtxRemixArchive requires -RendererMode RtxRemixProbe.'
    },
    [pscustomobject]@{
        Flag            = 'ReShadeSetupSpecified'
        ExpectedMessage = '-ReShadeSetup requires -PostProcessMode ReShadeCas.'
    },
    [pscustomobject]@{
        Flag            = 'EnginePatchPackageRootSpecified'
        ExpectedMessage = '-EnginePatchPackageRoot, -EnginePatchManifest, and -MaxFPS require an explicit EchoPatch engine-patch mode.'
    },
    [pscustomobject]@{
        Flag            = 'EnginePatchManifestSpecified'
        ExpectedMessage = '-EnginePatchPackageRoot, -EnginePatchManifest, and -MaxFPS require an explicit EchoPatch engine-patch mode.'
    },
    [pscustomobject]@{
        Flag            = 'MaxFPSExplicit'
        ExpectedMessage = '-EnginePatchPackageRoot, -EnginePatchManifest, and -MaxFPS require an explicit EchoPatch engine-patch mode.'
    }
)
foreach ($ownershipCase in $explicitOptionOwnershipCases) {
    $explicitOptionArguments = $planArguments.Clone()
    $explicitOptionArguments[$ownershipCase.Flag] = $true
    $explicitOptionRejected = $false
    try {
        Resolve-FearRuntimeStagePackagePlan @explicitOptionArguments | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains($ownershipCase.ExpectedMessage)) {
            throw
        }
        $explicitOptionRejected = $true
    }
    if (-not $explicitOptionRejected) {
        throw "Read-only package planner ignored explicit-bound ownership for $($ownershipCase.Flag)."
    }
}

$localRuntimeRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'local-runtime')).TrimEnd('\')
$ownershipFixture = Join-Path $localRuntimeRoot "runtime-stage-architecture-$([Guid]::NewGuid().ToString('N'))"
if (-not $ownershipFixture.StartsWith($localRuntimeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw "Architecture test fixture escaped local-runtime: $ownershipFixture"
}
try {
    New-Item -ItemType Directory -Path $ownershipFixture -Force | Out-Null
    $fixtureRuntimeExecutable = Join-Path $ownershipFixture 'FEAR.exe'
    [IO.File]::WriteAllBytes($fixtureRuntimeExecutable, [byte[]](0x4D, 0x5A, 0x46, 0x45, 0x41, 0x52))
    $fixtureRuntimeSha256 = (Get-FileHash -LiteralPath $fixtureRuntimeExecutable -Algorithm SHA256).Hash
    $manifest = [ordered]@{
        SchemaVersion           = 8
        Lane                    = 'Rebuilt'
        RendererMode            = 'NativeD3D9'
        EnginePatchMode         = 'None'
        RuntimeExecutable       = 'FEAR.exe'
        RuntimeExecutableSha256 = $fixtureRuntimeSha256
    }
    $controllerIdentity = [pscustomobject]@{
        Version                     = '3.4.10'
        ArchiveSha256               = ('A' * 64)
        RuntimeFileName             = 'SDL3.dll'
        RuntimeSize                 = 2342912L
        RuntimeSha256               = ('B' * 64)
        RuntimeArchitecture         = 'x86'
        LicenseStagePath            = '.fearmore\licenses\SDL3-zlib.txt'
        LicenseSize                 = 884L
        LicenseSha256               = ('C' * 64)
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ownershipFixture 'fearmore-stage.json') -Encoding UTF8

    $beforeOwnershipValidation = Get-DirectorySnapshot -Root $ownershipFixture
    Assert-FearOwnedStage `
        -Root $ownershipFixture `
        -ExpectedLane 'Rebuilt' `
        -ExpectedRendererMode 'NativeD3D9' `
        -ExpectedEnginePatchMode 'None' `
        -StageManifestName 'fearmore-stage.json' | Out-Null
    Assert-FearStageRuntimeExecutableOwnership `
        -Root $ownershipFixture `
        -Manifest ([pscustomobject]$manifest) `
        -ExpectedExecutableName 'FEAR.exe'
    Assert-FearStageTreeNoUnexpectedReparsePoints `
        -StageRoot $ownershipFixture `
        -RetailTarget $null `
        -AuthorizedMounts @()
    Assert-FearStageProxyOwnership `
        -Root $ownershipFixture `
        -StageLane 'Rebuilt' `
        -PackagePlan $nativePlan `
        -RendererPackageIdentity $null `
        -EnginePatchPackageIdentity $null `
        -ExistingManifest $manifest
    Assert-FearStagePostProcessOwnership `
        -Root $ownershipFixture `
        -PackagePlan $nativePlan `
        -ExpectedPackageIdentity $null `
        -ExistingManifest $manifest | Out-Null
    Assert-FearStageControllerOwnership `
        -Root $ownershipFixture `
        -StageLane 'Rebuilt' `
        -ExpectedPackageIdentity $controllerIdentity `
        -ExistingManifest $manifest | Out-Null
    if ((Get-DirectorySnapshot -Root $ownershipFixture) -cne $beforeOwnershipValidation) {
        throw 'Successful ownership validation mutated its stage fixture.'
    }

    [IO.File]::WriteAllBytes((Join-Path $ownershipFixture 'SDL3.dll'), [byte[]](0x4D, 0x5A, 0x46, 0x45, 0x41, 0x52))
    $beforeControllerRejection = Get-DirectorySnapshot -Root $ownershipFixture
    $unownedControllerRejected = $false
    try {
        Assert-FearStageControllerOwnership `
            -Root $ownershipFixture `
            -StageLane 'Rebuilt' `
            -ExpectedPackageIdentity $controllerIdentity `
            -ExistingManifest $manifest | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('predates controller ownership')) {
            throw
        }
        $unownedControllerRejected = $true
    }
    if (-not $unownedControllerRejected -or
        (Get-DirectorySnapshot -Root $ownershipFixture) -cne $beforeControllerRejection) {
        throw 'Controller ownership rejection either adopted an unowned SDL3.dll or mutated its stage fixture.'
    }
    Remove-Item -LiteralPath (Join-Path $ownershipFixture 'SDL3.dll') -Force

    [IO.File]::WriteAllBytes((Join-Path $ownershipFixture 'd3d9.dll'), [byte[]](0x46, 0x45, 0x41, 0x52))
    $beforeOwnershipRejection = Get-DirectorySnapshot -Root $ownershipFixture
    $unownedProxyRejected = $false
    try {
        Assert-FearStageProxyOwnership `
            -Root $ownershipFixture `
            -StageLane 'Rebuilt' `
            -PackagePlan $nativePlan `
            -RendererPackageIdentity $null `
            -EnginePatchPackageIdentity $null `
            -ExistingManifest $manifest
    }
    catch {
        if (-not $_.Exception.Message.Contains('unowned renderer proxy/config')) {
            throw
        }
        $unownedProxyRejected = $true
    }
    if (-not $unownedProxyRejected -or (Get-DirectorySnapshot -Root $ownershipFixture) -cne $beforeOwnershipRejection) {
        throw 'Ownership rejection either accepted an unowned proxy or mutated its stage fixture.'
    }

    Remove-Item -LiteralPath (Join-Path $ownershipFixture 'd3d9.dll') -Force
    [IO.File]::WriteAllBytes((Join-Path $ownershipFixture 'dxgi.dll'), [byte[]](0x46, 0x45, 0x41, 0x52))
    $beforePostProcessRejection = Get-DirectorySnapshot -Root $ownershipFixture
    $unownedPostProcessRejected = $false
    try {
        Assert-FearStagePostProcessOwnership `
            -Root $ownershipFixture `
            -PackagePlan $nativePlan `
            -ExpectedPackageIdentity $null `
            -ExistingManifest $manifest | Out-Null
    }
    catch {
        if (-not $_.Exception.Message.Contains('unowned post-process proxy or immutable asset')) {
            throw
        }
        $unownedPostProcessRejected = $true
    }
    if (-not $unownedPostProcessRejected -or
        (Get-DirectorySnapshot -Root $ownershipFixture) -cne $beforePostProcessRejection) {
        throw 'Post-process ownership rejection either accepted an unowned DXGI proxy or mutated its stage fixture.'
    }
}
finally {
    $resolvedFixture = [IO.Path]::GetFullPath($ownershipFixture)
    if ((Test-Path -LiteralPath $resolvedFixture) -and
        $resolvedFixture.StartsWith($localRuntimeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}

[pscustomobject]@{
    Status                         = 'PASS'
    ReadOnlyModulesVerified        = @($moduleContracts.Name)
    ExportSurfacesVerified         = $true
    ParameterSurfacesVerified      = $true
    ImportedModuleCoverageVerified = $true
    MovedFunctionsAbsent           = $true
    SoleMutationBoundaryVerified   = $true
    ReadOnlyMountMutationOwner     = 'New-FearRuntimeStage.ps1'
    ReadOnlyMountCreationFunction  = $junctionCreationRecords[0].Function
    ReadOnlyMountRemovalFunction   = $junctionRemovalRecords[0].Function
    MutationCallGraphVerified      = @($mutatingLocalFunctions | Sort-Object)
    ExplicitMaxFpsSemanticsVerified = $true
    ExplicitPackageOptionsVerified = @($explicitOptionOwnershipCases.Flag)
    RendererQualityPlanningVerified = @('Native', 'Max2x')
    PostProcessPlanningVerified     = @('None', 'ReShadeCas')
    InvalidPostProcessSelectionsRejected = $true
    RtxLabPlanVerified             = $true
    HistoricalRemixDiagnosticPlanVerified = $true
    RemixDiagnosticPlanVerified    = $true
    CameraDiagnosticPlanVerified   = $true
    RebuiltMutationPlanVerified    = $true
    StageSchemaVerified            = 9
    PlannerModeOwnershipRejected   = $modeOwnershipRejected
    OwnershipSuccessNonMutating    = $true
    OwnershipRejectionNonMutating  = $true
    ControllerOwnershipRejectionNonMutating = $true
    PostProcessOwnershipRejectionNonMutating = $true
}
