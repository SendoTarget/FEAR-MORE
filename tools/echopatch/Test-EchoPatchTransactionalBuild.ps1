[CmdletBinding()]
param(
    [switch]$KeepOutput
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-TreeIdentity([string]$Root) {
    if (-not (Test-Path -LiteralPath $Root)) {
        return '<missing>'
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $records = foreach ($file in Get-ChildItem -LiteralPath $rootFull -File -Recurse | Sort-Object FullName) {
        [ordered]@{
            path = $file.FullName.Substring($rootFull.Length + 1).Replace('\', '/')
            length = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
    }
    return ($records | ConvertTo-Json -Compress)
}

function Get-PromotionKey([string]$Path) {
    $normalizedPath = [System.IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedPath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    return -join ($hash[0..11] | ForEach-Object { $_.ToString('x2') })
}

function Remove-TestOutput([string]$Path, [string]$VendorRoot) {
    $vendorFull = [System.IO.Path]::GetFullPath($VendorRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($vendorFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not (Split-Path -Leaf $pathFull).StartsWith('echopatch-transaction-test-', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing test cleanup outside the guarded transaction-test namespace: $pathFull"
    }
    if (Test-Path -LiteralPath $pathFull) {
        $reparsePoint = Get-ChildItem -LiteralPath $pathFull -Force -Recurse |
            Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
            Select-Object -First 1
        if ($reparsePoint) {
            throw "Refusing test cleanup through reparse point: $($reparsePoint.FullName)"
        }
        Remove-Item -LiteralPath $pathFull -Recurse -Force
    }
}

function Remove-TestTransactionArtifact([string]$Path, [string]$VendorRoot, [string[]]$AllowedNames) {
    $vendorFull = [System.IO.Path]::GetFullPath($VendorRoot).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $leaf = Split-Path -Leaf $pathFull
    if (-not $pathFull.StartsWith($vendorFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $leaf -notin $AllowedNames) {
        throw "Refusing test transaction-artifact cleanup outside the exact guarded set: $pathFull"
    }
    if (-not (Test-Path -LiteralPath $pathFull)) {
        return
    }
    $item = Get-Item -LiteralPath $pathFull -Force
    if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing test transaction-artifact cleanup through a reparse point: $pathFull"
    }
    if ($item.PSIsContainer) {
        $nestedReparsePoint = Get-ChildItem -LiteralPath $pathFull -Force -Recurse |
            Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
            Select-Object -First 1
        if ($nestedReparsePoint) {
            throw "Refusing test transaction-artifact cleanup through reparse point: $($nestedReparsePoint.FullName)"
        }
        Remove-Item -LiteralPath $pathFull -Recurse -Force
    }
    else {
        Remove-Item -LiteralPath $pathFull -Force
    }
}

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$vendorRoot = Join-Path $repoRoot 'vendor-local'
$buildScript = Join-Path $PSScriptRoot 'Build-EngineOnlyEchoPatch.ps1'
$promotionModule = Join-Path $PSScriptRoot 'EchoPatchPromotion.psm1'
$flavorModule = Join-Path $PSScriptRoot 'EchoPatchBuildFlavor.psm1'
$reassertionPatch = Join-Path $repoRoot 'patches\echopatch\0006-add-rtx-camera-reassertion.patch'
$reassertionProfile = Join-Path $PSScriptRoot 'EchoPatch.rtx-camera-reassertion.override.ini'
$buildSource = Get-Content -LiteralPath $buildScript -Raw
$promotionSource = Get-Content -LiteralPath $promotionModule -Raw
$flavorSource = Get-Content -LiteralPath $flavorModule -Raw
$reassertionPatchSource = Get-Content -LiteralPath $reassertionPatch -Raw
$reassertionProfileSource = Get-Content -LiteralPath $reassertionProfile -Raw
$shortCommit = 'b4a7074e4cbb'

$patchParseOutput = & git -C $repoRoot apply --numstat $reassertionPatch 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "RTX camera-reassertion integration patch is not syntactically valid:`n$($patchParseOutput -join [Environment]::NewLine)"
}

foreach ($scriptPath in @($buildScript, $promotionModule, $flavorModule)) {
    $parseErrors = $null
    $parseTokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$parseTokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -ne 0) {
        throw "Transactional EchoPatch script has parse errors in '$scriptPath': $($parseErrors -join [Environment]::NewLine)"
    }
}

$requiredBuildFragments = @(
    '".epb-$transactionId"',
    'Assert-PackageCoherence',
    'EchoPatchPromotion.psm1',
    'Publish-EchoPatchCandidate',
    '$recoveryRecordRemains',
    'Forced EchoPatch transaction failure before promotion.',
    "StartsWith('echopatch-transaction-test-'",
    '[switch]$RtxCameraReassertion',
    'EchoPatch.rtx-camera-reassertion.override.ini',
    'RtxCameraReassertionEchoPatch',
    '$manifest.rtxCameraReassertion = $true',
    '$manifest.rtxCameraReassertionProof = $RtxCameraReassertionProof',
    '$manifest.rtxCameraReassertionPatchSha256',
    '$manifest.rtxCameraReassertionOverlaySha256',
    '$manifest.rtxCameraReassertionProfileOverrideSha256'
)
foreach ($fragment in $requiredBuildFragments) {
    if (-not $buildSource.Contains($fragment)) {
        throw "Transactional build source is missing required guard fragment: $fragment"
    }
}
$requiredPromotionFragments = @(
    '".epo-$key"',
    '".epj-$key.json"',
    '".epc-$key.json"',
    '[System.IO.FileOptions]::WriteThrough',
    '$stream.Flush($true)',
    'Invoke-EpPromotionRecovery',
    'Move-Item -LiteralPath $Context.BackupRoot -Destination $Context.OutputRoot',
    'Move-Item -LiteralPath $Context.OutputRoot -Destination $Context.BackupRoot',
    'Move-Item -LiteralPath $candidateFull -Destination $Context.OutputRoot'
)
foreach ($fragment in $requiredPromotionFragments) {
    if (-not $promotionSource.Contains($fragment)) {
        throw "EchoPatch promotion module is missing required guard fragment: $fragment"
    }
}
if (-not $promotionSource.Contains("'RtxCameraReassertionEchoPatch'")) {
    throw 'EchoPatch promotion recovery does not recognize the camera-reassertion package mode.'
}

$requiredFlavorFragments = @(
    '-RtxCameraReassertion requires both -CameraDiagnostics and -RtxFocusPreservation.',
    "PackageMode = 'RtxCameraReassertionEchoPatch'",
    "DefaultOutputLeaf = 'echopatch-rtx-camera-reassertion'"
)
foreach ($fragment in $requiredFlavorFragments) {
    if (-not $flavorSource.Contains($fragment)) {
        throw "EchoPatch flavor policy is missing the camera-reassertion fragment: $fragment"
    }
}

Import-Module -Name $flavorModule -Force
$expectedFlavors = @(
    @{ Arguments = @{}; Mode = 'EngineOnlyEchoPatch'; Output = 'echopatch-engine-only' },
    @{ Arguments = @{ RemixCameraDiagnostics = $true }; Mode = 'RemixDiagnosticEchoPatch'; Output = 'echopatch-remix-diagnostics' },
    @{ Arguments = @{ CameraDiagnostics = $true }; Mode = 'CameraDiagnosticEchoPatch'; Output = 'echopatch-camera-diagnostics' },
    @{ Arguments = @{ CameraDiagnostics = $true; RtxFocusPreservation = $true }; Mode = 'RtxCameraDiagnosticEchoPatch'; Output = 'echopatch-rtx-camera-diagnostics' },
    @{ Arguments = @{ CameraDiagnostics = $true; RtxFocusPreservation = $true; RtxCameraReassertion = $true }; Mode = 'RtxCameraReassertionEchoPatch'; Output = 'echopatch-rtx-camera-reassertion' }
)
foreach ($expectedFlavor in $expectedFlavors) {
    $flavorArguments = $expectedFlavor.Arguments
    $actualFlavor = Get-EchoPatchBuildFlavor @flavorArguments
    if ($actualFlavor.PackageMode -cne $expectedFlavor.Mode -or
        $actualFlavor.DefaultOutputLeaf -cne $expectedFlavor.Output) {
        throw "EchoPatch flavor policy changed '$($expectedFlavor.Mode)' unexpectedly."
    }
}
$missingDependenciesRejected = $false
try {
    $null = Get-EchoPatchBuildFlavor -RtxCameraReassertion
}
catch {
    if (-not $_.Exception.Message.Contains('requires both -CameraDiagnostics and -RtxFocusPreservation')) {
        throw
    }
    $missingDependenciesRejected = $true
}
if (-not $missingDependenciesRejected) {
    throw 'The camera-reassertion flavor accepted missing camera/focus dependencies.'
}

foreach ($requiredProfileSetting in @(
    '(?m)^CameraDiagnostics\s*=\s*1\s*$',
    '(?m)^RtxCameraReassertion\s*=\s*1\s*$',
    '(?m)^PreserveRtxRendererOnFocusChange\s*=\s*1\s*$'
)) {
    if ($reassertionProfileSource -notmatch $requiredProfileSetting) {
        throw "RTX camera-reassertion override is missing an explicit required setting: $requiredProfileSetting"
    }
}
foreach ($requiredPatchFragment in @(
    'bool EnableRtxCameraReassertion = false;',
    'ReadInteger("Diagnostics", "RtxCameraReassertion", 0)',
    '#include "Engine/RtxCameraReassertion/RtxCameraReassertion.cpp"',
    'InstallRtxCameraReassertion(device);',
    'RtxCameraReassertion::BeforeDraw(device, s_SetTransform);',
    'RtxCameraReassertion::AfterSetVertexShader',
    'RtxCameraReassertion::OnEndScene(device);'
)) {
    if (-not $reassertionPatchSource.Contains($requiredPatchFragment)) {
        throw "RTX camera-reassertion integration patch is missing: $requiredPatchFragment"
    }
}
if ($reassertionPatchSource -match '(?m)^\+(?!\+\+).*(?:WindowProc|MH_CreateHook|ApplyHook\()') {
    throw 'RTX camera-reassertion integration patch must not add WindowProc or independent hook ownership.'
}
if (($buildSource + $promotionSource) -match 'Remove-Item\s+-LiteralPath\s+(\$OutputRoot|\$Context\.OutputRoot)') {
    throw 'EchoPatch promotion code must not directly delete the current OutputRoot.'
}

$manifestWriteIndex = $buildSource.IndexOf('$manifest | ConvertTo-Json')
$candidateValidationIndex = $buildSource.IndexOf('Assert-PackageCoherence', $manifestWriteIndex)
$forcedFailureIndex = $buildSource.IndexOf('if ($TestFailBeforePromotion)', $candidateValidationIndex)
$publishIndex = $buildSource.IndexOf('Publish-EchoPatchCandidate', $forcedFailureIndex)
if ($manifestWriteIndex -lt 0 -or $candidateValidationIndex -le $manifestWriteIndex -or
    $forcedFailureIndex -le $candidateValidationIndex -or $publishIndex -le $forcedFailureIndex) {
    throw 'Manifest creation, candidate validation, forced-failure gate, and delegated promotion are not ordered transactionally.'
}

$cameraOverlayCopyIndex = $buildSource.IndexOf('Copy-Item -LiteralPath $cameraDiagnosticsOverlayPath -Destination')
$reassertionOverlayCopyIndex = $buildSource.IndexOf('Copy-Item -LiteralPath $rtxCameraReassertionOverlayPath', $cameraOverlayCopyIndex)
$reassertionPatchIndex = $buildSource.IndexOf('$rtxCameraReassertionCheckOutput =', $reassertionOverlayCopyIndex)
$buildStartIndex = $buildSource.IndexOf('$msbuild = Find-MSBuild', $reassertionPatchIndex)
if ($cameraOverlayCopyIndex -lt 0 -or $reassertionOverlayCopyIndex -le $cameraOverlayCopyIndex -or
    $reassertionPatchIndex -le $reassertionOverlayCopyIndex -or $buildStartIndex -le $reassertionPatchIndex) {
    throw 'CameraDiagnostics copy, passive overlay copy, integration patch, and build are not ordered safely.'
}

$publishFunctionIndex = $promotionSource.IndexOf('function Publish-EchoPatchCandidate')
$prePromotionValidationIndex = $promotionSource.IndexOf('Assert-EpPackageCoherence', $publishFunctionIndex)
$journalWriteIndex = $promotionSource.IndexOf('Write-EpDurableJsonFile -Path $Context.JournalPath', $prePromotionValidationIndex)
$backupMoveIndex = $promotionSource.IndexOf('Move-Item -LiteralPath $Context.OutputRoot -Destination $Context.BackupRoot', $journalWriteIndex)
$promotionIndex = $promotionSource.IndexOf('Move-Item -LiteralPath $candidateFull -Destination $Context.OutputRoot', $journalWriteIndex)
$promotedValidationIndex = $promotionSource.IndexOf('Assert-EpPackageCoherence', $promotionIndex)
$commitWriteIndex = $promotionSource.IndexOf('Write-EpDurableJsonFile -Path $Context.CommitPath', $promotedValidationIndex)
if ($publishFunctionIndex -lt 0 -or $prePromotionValidationIndex -le $publishFunctionIndex -or
    $journalWriteIndex -le $prePromotionValidationIndex -or $backupMoveIndex -le $journalWriteIndex -or
    $promotionIndex -le $journalWriteIndex -or $promotedValidationIndex -le $promotionIndex -or
    $commitWriteIndex -le $promotedValidationIndex) {
    throw 'Candidate validation, durable intent, directory promotion, promoted validation, and durable commit are not ordered inside the promotion owner.'
}

$testLeaf = 'echopatch-transaction-test-{0}' -f ([Guid]::NewGuid().ToString('N').Substring(0, 8))
$testRoot = Join-Path $vendorRoot $testLeaf
$sentinelPackage = Join-Path $testRoot "local-package-$shortCommit"
$sentinelManifest = Join-Path $testRoot "manifest-$shortCommit.json"
$promotionKey = Get-PromotionKey $testRoot
$interruptedTransactionId = '99999-deadbeef'
$interruptedCandidateRoot = Join-Path $vendorRoot ".epb-$interruptedTransactionId"
$interruptedBackupRoot = Join-Path $vendorRoot ".epo-$promotionKey"
$interruptedJournalPath = Join-Path $vendorRoot ".epj-$promotionKey.json"
$interruptedCommitPath = Join-Path $vendorRoot ".epc-$promotionKey.json"
$interruptedLockPath = Join-Path $vendorRoot ".epl-$promotionKey.lock"
$testTransactionArtifactNames = @(
    (Split-Path -Leaf $interruptedCandidateRoot),
    (Split-Path -Leaf $interruptedBackupRoot),
    (Split-Path -Leaf $interruptedJournalPath),
    (Split-Path -Leaf $interruptedCommitPath),
    (Split-Path -Leaf $interruptedLockPath)
)
$testTransactionArtifactPaths = @(
    $interruptedCandidateRoot,
    $interruptedBackupRoot,
    $interruptedJournalPath,
    $interruptedCommitPath,
    $interruptedLockPath
)
foreach ($artifactPath in $testTransactionArtifactPaths) {
    if (Test-Path -LiteralPath $artifactPath) {
        throw "Transaction recovery test artifact already exists: $artifactPath"
    }
}
$protectedRoots = @(
    (Join-Path $vendorRoot 'echopatch-engine-only'),
    (Join-Path $vendorRoot 'echopatch-remix-diagnostics'),
    (Join-Path $vendorRoot 'echopatch-rtx-camera-diagnostics'),
    (Join-Path $vendorRoot 'echopatch-rtx-camera-reassertion')
)
$protectedBefore = @{}
foreach ($protectedRoot in $protectedRoots) {
    $protectedBefore[$protectedRoot] = Get-TreeIdentity $protectedRoot
}
$transactionArtifactsBefore = @(
    Get-ChildItem -LiteralPath $vendorRoot -Force |
        Where-Object { $_.Name.StartsWith('.epb-', [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('.epo-', [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('.epj-', [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('.epc-', [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('.epl-', [System.StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object FullName
)

try {
    New-Item -ItemType Directory -Path $sentinelPackage -Force | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $sentinelPackage 'dinput8.dll'), [byte[]](0x46, 0x45, 0x41, 0x52, 0x4d, 0x4f, 0x52, 0x45))
    [System.IO.File]::WriteAllText((Join-Path $sentinelPackage 'EchoPatch.ini'), "[Sentinel]`r`nPreserve=1`r`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($sentinelManifest, '{"sentinel":true}', [System.Text.UTF8Encoding]::new($false))
    $sentinelBefore = Get-TreeIdentity $testRoot

    New-Item -ItemType Directory -Path $interruptedCandidateRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $interruptedCandidateRoot 'unpromoted-candidate.txt'),
        'candidate must be discarded during rollback',
        [System.Text.UTF8Encoding]::new($false)
    )
    $interruptedRecord = [ordered]@{
        schemaVersion = 1
        phase = 'intent'
        transactionId = $interruptedTransactionId
        outputRoot = [System.IO.Path]::GetFullPath($testRoot)
        candidateRoot = [System.IO.Path]::GetFullPath($interruptedCandidateRoot)
        backupRoot = [System.IO.Path]::GetFullPath($interruptedBackupRoot)
        packageMode = 'CameraDiagnosticEchoPatch'
        hadExistingOutput = $true
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    $interruptedRecord | ConvertTo-Json -Depth 4 -Compress |
        Set-Content -LiteralPath $interruptedJournalPath -Encoding UTF8
    Move-Item -LiteralPath $testRoot -Destination $interruptedBackupRoot

    $powershell = (Get-Process -Id $PID).Path
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $failureOutput = & $powershell -NoProfile -ExecutionPolicy Bypass -File $buildScript `
            -OutputRoot $testRoot -CameraDiagnostics -TestFailBeforePromotion 2>&1
        $failureExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($failureExitCode -eq 0) {
        throw 'The forced pre-promotion failure unexpectedly succeeded.'
    }
    if (($failureOutput -join [Environment]::NewLine) -notmatch 'Forced EchoPatch transaction failure before promotion\.') {
        throw "The forced build failed for an unexpected reason:`n$($failureOutput -join [Environment]::NewLine)"
    }
    if (($failureOutput -join [Environment]::NewLine) -notmatch 'Recovered interrupted EchoPatch promotion: restored previous output') {
        throw "The builder did not report startup recovery of the interrupted promotion:`n$($failureOutput -join [Environment]::NewLine)"
    }

    $sentinelAfterFailure = Get-TreeIdentity $testRoot
    if ($sentinelAfterFailure -cne $sentinelBefore) {
        throw 'Startup recovery plus a failed EchoPatch transaction changed the existing sentinel package or manifest.'
    }
    foreach ($artifactPath in $testTransactionArtifactPaths) {
        if (Test-Path -LiteralPath $artifactPath) {
            throw "Startup recovery left an interrupted-promotion artifact: $artifactPath"
        }
    }

    $ErrorActionPreference = 'Continue'
    try {
        $successOutput = & $powershell -NoProfile -ExecutionPolicy Bypass -File $buildScript `
            -OutputRoot $testRoot -CameraDiagnostics 2>&1
        $successExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($successExitCode -ne 0) {
        throw "The successful camera transaction failed:`n$($successOutput -join [Environment]::NewLine)"
    }

    $packageRoot = Join-Path $testRoot "local-package-$shortCommit"
    $manifestPath = Join-Path $testRoot "manifest-$shortCommit.json"
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $packageDll = Join-Path $packageRoot 'dinput8.dll'
    $packageProfile = Join-Path $packageRoot 'EchoPatch.ini'
    $builtDll = Join-Path $testRoot "source-$shortCommit\EchoPatch\bin\Release\dinput8.dll"

    if ($manifest.packageMode -cne 'CameraDiagnosticEchoPatch' -or -not [bool]$manifest.cameraDiagnostics) {
        throw 'The promoted transaction is not the requested camera-diagnostics package mode.'
    }
    $packageDllHash = (Get-FileHash -LiteralPath $packageDll -Algorithm SHA256).Hash
    $builtDllHash = (Get-FileHash -LiteralPath $builtDll -Algorithm SHA256).Hash
    if ($manifest.binarySha256 -cne $packageDllHash -or $packageDllHash -cne $builtDllHash) {
        throw 'The promoted manifest, package DLL, and isolated-build DLL do not form a coherent binary identity.'
    }
    $packageProfileHash = (Get-FileHash -LiteralPath $packageProfile -Algorithm SHA256).Hash
    if ($manifest.profileSha256 -cne $packageProfileHash) {
        throw 'The promoted manifest and package profile do not form a coherent identity.'
    }
    if ($manifest.PSObject.Properties['sentinel']) {
        throw 'The successful transaction did not replace the sentinel output.'
    }

    $committedOutputBeforeRecovery = Get-TreeIdentity $testRoot
    New-Item -ItemType Directory -Path $interruptedBackupRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $interruptedBackupRoot 'previous-output-cleanup.txt'),
        'committed recovery must clean this backup without restoring it',
        [System.Text.UTF8Encoding]::new($false)
    )
    $postCommitIntentRecord = [ordered]@{
        schemaVersion = 1
        phase = 'intent'
        transactionId = $interruptedTransactionId
        outputRoot = [System.IO.Path]::GetFullPath($testRoot)
        candidateRoot = [System.IO.Path]::GetFullPath($interruptedCandidateRoot)
        backupRoot = [System.IO.Path]::GetFullPath($interruptedBackupRoot)
        packageMode = 'CameraDiagnosticEchoPatch'
        hadExistingOutput = $true
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
    $postCommitRecord = [ordered]@{}
    foreach ($entry in $postCommitIntentRecord.GetEnumerator()) {
        $postCommitRecord[$entry.Key] = $entry.Value
    }
    $postCommitRecord.phase = 'committed'
    $postCommitIntentRecord | ConvertTo-Json -Depth 4 -Compress |
        Set-Content -LiteralPath $interruptedJournalPath -Encoding UTF8
    $postCommitRecord | ConvertTo-Json -Depth 4 -Compress |
        Set-Content -LiteralPath $interruptedCommitPath -Encoding UTF8

    Import-Module -Name $promotionModule -Force
    $null = Initialize-EchoPatchPromotion `
        -OutputRoot $testRoot `
        -VendorRoot $vendorRoot `
        -ShortCommit $shortCommit
    if ((Get-TreeIdentity $testRoot) -cne $committedOutputBeforeRecovery) {
        throw 'Committed startup recovery changed the promoted camera package.'
    }
    foreach ($artifactPath in $testTransactionArtifactPaths) {
        if (Test-Path -LiteralPath $artifactPath) {
            throw "Committed startup recovery left a promotion artifact: $artifactPath"
        }
    }

    $outputBeforeUnreadableRecovery = Get-TreeIdentity $testRoot
    New-Item -ItemType Directory -Path $interruptedCandidateRoot | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $interruptedCandidateRoot 'unidentified-candidate.txt'),
        'unreadable intent must fail closed without deleting this candidate',
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText($interruptedJournalPath, '{', [System.Text.UTF8Encoding]::new($false))
    $unreadableIntentRejected = $false
    try {
        $null = Initialize-EchoPatchPromotion `
            -OutputRoot $testRoot `
            -VendorRoot $vendorRoot `
            -ShortCommit $shortCommit
    }
    catch {
        if (-not $_.Exception.Message.Contains('intent record is unreadable while unidentified promotion candidate(s) remain')) {
            throw
        }
        $unreadableIntentRejected = $true
    }
    if (-not $unreadableIntentRejected -or
        -not (Test-Path -LiteralPath $interruptedCandidateRoot -PathType Container) -or
        -not (Test-Path -LiteralPath $interruptedJournalPath -PathType Leaf) -or
        (Get-TreeIdentity $testRoot) -cne $outputBeforeUnreadableRecovery) {
        throw 'Unreadable-intent recovery did not retain the journal/candidate and preserve the current output.'
    }
    foreach ($artifactPath in @($interruptedCandidateRoot, $interruptedJournalPath)) {
        Remove-TestTransactionArtifact `
            -Path $artifactPath `
            -VendorRoot $vendorRoot `
            -AllowedNames $testTransactionArtifactNames
    }

    $supportedManifestBytes = [System.IO.File]::ReadAllBytes($manifestPath)
    $unsupportedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $unsupportedManifest.packageMode = 'BogusEchoPatchMode'
    [System.IO.File]::WriteAllText(
        $manifestPath,
        ($unsupportedManifest | ConvertTo-Json -Depth 8),
        [System.Text.UTF8Encoding]::new($false)
    )
    $unsupportedModeOutputBeforeRecovery = Get-TreeIdentity $testRoot
    [System.IO.File]::WriteAllText($interruptedJournalPath, '{', [System.Text.UTF8Encoding]::new($false))
    $unsupportedOutputModeRejected = $false
    try {
        $null = Initialize-EchoPatchPromotion `
            -OutputRoot $testRoot `
            -VendorRoot $vendorRoot `
            -ShortCommit $shortCommit
    }
    catch {
        if (-not $_.Exception.Message.Contains("Unsupported EchoPatch package mode 'BogusEchoPatchMode'")) {
            throw
        }
        $unsupportedOutputModeRejected = $true
    }
    if (-not $unsupportedOutputModeRejected -or
        -not (Test-Path -LiteralPath $interruptedJournalPath -PathType Leaf) -or
        (Get-TreeIdentity $testRoot) -cne $unsupportedModeOutputBeforeRecovery) {
        throw 'Unreadable-intent recovery trusted an unsupported package mode or changed its recovery evidence.'
    }
    Remove-TestTransactionArtifact `
        -Path $interruptedJournalPath `
        -VendorRoot $vendorRoot `
        -AllowedNames $testTransactionArtifactNames
    [System.IO.File]::WriteAllBytes($manifestPath, $supportedManifestBytes)

    $transactionDebris = @(Get-ChildItem -LiteralPath $vendorRoot -Force |
        Where-Object { $_.Name.StartsWith('.epb-', [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('.epo-', [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('.epj-', [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('.epc-', [System.StringComparison]::OrdinalIgnoreCase) -or
            $_.Name.StartsWith('.epl-', [System.StringComparison]::OrdinalIgnoreCase) } |
        Where-Object { $_.FullName -notin $transactionArtifactsBefore })
    if ($transactionDebris) {
        throw "Successful transaction left temporary sibling output: $($transactionDebris.FullName -join ', ')"
    }

    foreach ($protectedRoot in $protectedRoots) {
        if ((Get-TreeIdentity $protectedRoot) -cne $protectedBefore[$protectedRoot]) {
            throw "Camera transaction changed a protected ordinary/Remix/RTX-focus/RTX-reassertion output: $protectedRoot"
        }
    }

    Write-Host 'EchoPatch transactional build test passed.'
    Write-Host '  Startup recovery restored the previous output after an interrupted backup move.'
    Write-Host '  Forced failure then preserved the recovered sentinel package and manifest byte-for-byte.'
    Write-Host '  Camera-only success promoted a coherent manifest, package DLL, build DLL, and profile.'
    Write-Host '  Committed startup recovery preserved the promoted package while finishing backup cleanup.'
    Write-Host '  An unreadable intent with an unidentified candidate failed closed and retained all recovery evidence.'
    Write-Host '  An unreadable intent could not trust an otherwise coherent output with an unsupported package mode.'
    Write-Host '  Ordinary, Remix, RTX-focus, and RTX-reassertion output roots were unchanged.'
}
finally {
    if ($KeepOutput) {
        Write-Host "  Kept test output: $testRoot"
    }
    else {
        Remove-TestOutput -Path $testRoot -VendorRoot $vendorRoot
    }
    foreach ($artifactPath in $testTransactionArtifactPaths) {
        Remove-TestTransactionArtifact `
            -Path $artifactPath `
            -VendorRoot $vendorRoot `
            -AllowedNames $testTransactionArtifactNames
    }
}
