Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-EpFullPath([string]$Path) {
    return [System.IO.Path]::GetFullPath($Path)
}

function Assert-EpChildPath([string]$Child, [string]$Parent) {
    $parentFull = (Get-EpFullPath $Parent).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    $childFull = Get-EpFullPath $Child
    if (-not $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing path outside '$parentFull': $childFull"
    }
}

function Assert-EpNoReparsePoints([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $rootItem = Get-Item -LiteralPath $Path -Force
    if (($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing recursive removal through a reparse point: $Path"
    }
    $nestedReparsePoint = Get-ChildItem -LiteralPath $Path -Force -Recurse |
        Where-Object { ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0 } |
        Select-Object -First 1
    if ($nestedReparsePoint) {
        throw "Refusing recursive removal because the tree contains a reparse point: $($nestedReparsePoint.FullName)"
    }
}

function Remove-EpGuardedTree([string]$Path, [string]$Parent) {
    Assert-EpChildPath -Child $Path -Parent $Parent
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    Assert-EpNoReparsePoints -Path $Path
    Remove-Item -LiteralPath $Path -Recurse -Force
}

function Remove-EpGuardedFile([string]$Path, [string]$Parent) {
    Assert-EpChildPath -Child $Path -Parent $Parent
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing guarded file removal for a directory or reparse point: $Path"
    }
    Remove-Item -LiteralPath $Path -Force
}

function Test-EpSupportedPackageMode([string]$PackageMode) {
    return $PackageMode -in @(
        'EngineOnlyEchoPatch',
        'RemixDiagnosticEchoPatch',
        'CameraDiagnosticEchoPatch',
        'RtxCameraDiagnosticEchoPatch',
        'RtxCameraReassertionEchoPatch'
    )
}

function Assert-EpExistingPathChain([string]$Base, [string]$Target) {
    $baseFull = (Get-EpFullPath $Base).TrimEnd('\', '/')
    $targetFull = Get-EpFullPath $Target
    if ($targetFull -ne $baseFull -and -not $targetFull.StartsWith(
        $baseFull + [System.IO.Path]::DirectorySeparatorChar,
        [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path-chain target is outside its base: $targetFull"
    }

    $current = $baseFull
    $relative = $targetFull.Substring($baseFull.Length).TrimStart('\', '/')
    $segments = @()
    if ($relative.Length -gt 0) {
        $segments = $relative -split '[\\/]'
    }
    foreach ($segment in @('') + $segments) {
        if ($segment.Length -gt 0) {
            $current = Join-Path $current $segment
        }
        if (-not (Test-Path -LiteralPath $current)) {
            break
        }
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing output path through a reparse point: $($item.FullName)"
        }
        if (-not $item.PSIsContainer -and $current -ne $targetFull) {
            throw "Output path has a non-directory component: $($item.FullName)"
        }
    }
}

function Assert-EpPackageCoherence(
    [string]$CandidateRoot,
    [string]$ShortCommit,
    [string]$ExpectedPackageMode
) {
    if (-not (Test-EpSupportedPackageMode -PackageMode $ExpectedPackageMode)) {
        throw "Unsupported EchoPatch package mode '$ExpectedPackageMode'."
    }

    $candidatePackageRoot = Join-Path $CandidateRoot "local-package-$ShortCommit"
    $candidateManifestPath = Join-Path $CandidateRoot "manifest-$ShortCommit.json"
    Assert-EpChildPath -Child $candidatePackageRoot -Parent $CandidateRoot
    Assert-EpChildPath -Child $candidateManifestPath -Parent $CandidateRoot

    foreach ($requiredPath in @(
        $CandidateRoot,
        $candidatePackageRoot,
        $candidateManifestPath,
        (Join-Path $candidatePackageRoot 'dinput8.dll'),
        (Join-Path $candidatePackageRoot 'EchoPatch.ini')
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Transactional EchoPatch candidate is incomplete: $requiredPath"
        }
    }

    $candidateManifest = Get-Content -LiteralPath $candidateManifestPath -Raw | ConvertFrom-Json
    $packageModeProperty = $candidateManifest.PSObject.Properties['packageMode']
    $actualPackageMode = if ($packageModeProperty) { [string]$packageModeProperty.Value } else { '' }
    if ($ExpectedPackageMode -eq 'EngineOnlyEchoPatch') {
        if ($packageModeProperty -and $actualPackageMode -ne $ExpectedPackageMode) {
            throw "Transactional EchoPatch candidate mode is '$actualPackageMode'; expected '$ExpectedPackageMode'."
        }
    }
    elseif (-not $packageModeProperty -or $actualPackageMode -ne $ExpectedPackageMode) {
        throw "Transactional EchoPatch candidate mode is '$actualPackageMode'; expected '$ExpectedPackageMode'."
    }

    $candidateBinaryHash = (Get-FileHash -LiteralPath (Join-Path $candidatePackageRoot 'dinput8.dll') -Algorithm SHA256).Hash
    if ($candidateManifest.binarySha256 -ne $candidateBinaryHash) {
        throw 'Transactional EchoPatch candidate DLL hash does not match its manifest.'
    }
    $candidateProfileHash = (Get-FileHash -LiteralPath (Join-Path $candidatePackageRoot 'EchoPatch.ini') -Algorithm SHA256).Hash
    if ($candidateManifest.profileSha256 -ne $candidateProfileHash) {
        throw 'Transactional EchoPatch candidate profile hash does not match its manifest.'
    }
}

function Get-EpPromotionKey([string]$Path) {
    $normalizedPath = (Get-EpFullPath $Path).ToUpperInvariant()
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

function Write-EpDurableJsonFile([string]$Path, [object]$Value) {
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to replace an existing EchoPatch transaction record: $Path"
    }
    $json = $Value | ConvertTo-Json -Depth 4 -Compress
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($json)
    $stream = [System.IO.FileStream]::new(
        $Path,
        [System.IO.FileMode]::CreateNew,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::None,
        4096,
        [System.IO.FileOptions]::WriteThrough
    )
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Open-EpPromotionLock([string]$Path, [string]$Parent) {
    Assert-EpChildPath -Child $Path -Parent $Parent
    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing EchoPatch promotion lock through a directory or reparse point: $Path"
        }
    }
    try {
        return [System.IO.FileStream]::new(
            $Path,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None,
            1,
            [System.IO.FileOptions]::WriteThrough
        )
    }
    catch [System.IO.IOException] {
        throw "Another EchoPatch promotion or recovery owns '$Path'. Retry after it finishes."
    }
}

function Close-EpPromotionLock([System.IO.FileStream]$Lock, [string]$Path, [string]$Parent) {
    if ($Lock) {
        $Lock.Dispose()
    }
    try {
        Remove-EpGuardedFile -Path $Path -Parent $Parent
    }
    catch {
        Write-Warning "EchoPatch promotion lock file remains at '$Path': $($_.Exception.Message)"
    }
}

function New-EpPromotionRecord(
    [string]$Phase,
    [string]$TransactionId,
    [pscustomobject]$Context,
    [string]$CandidateRoot,
    [string]$ExpectedPackageMode,
    [bool]$HadExistingOutput
) {
    return [ordered]@{
        schemaVersion = 1
        phase = $Phase
        transactionId = $TransactionId
        outputRoot = $Context.OutputRoot
        candidateRoot = (Get-EpFullPath $CandidateRoot)
        backupRoot = $Context.BackupRoot
        packageMode = $ExpectedPackageMode
        hadExistingOutput = $HadExistingOutput
        createdUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Read-EpPromotionRecord([string]$Path, [string]$ExpectedPhase, [pscustomobject]$Context) {
    $record = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($propertyName in @(
        'schemaVersion', 'phase', 'transactionId', 'outputRoot', 'candidateRoot',
        'backupRoot', 'packageMode', 'hadExistingOutput'
    )) {
        if (-not $record.PSObject.Properties[$propertyName]) {
            throw "EchoPatch transaction record is missing '$propertyName': $Path"
        }
        if ($null -eq $record.$propertyName) {
            throw "EchoPatch transaction record has a null '$propertyName': $Path"
        }
    }
    if ([int]$record.schemaVersion -ne 1 -or [string]$record.phase -cne $ExpectedPhase) {
        throw "EchoPatch transaction record has an unsupported schema or phase: $Path"
    }
    if (-not [string]::Equals((Get-EpFullPath ([string]$record.outputRoot)), $Context.OutputRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        -not [string]::Equals((Get-EpFullPath ([string]$record.backupRoot)), $Context.BackupRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "EchoPatch transaction record targets a different output or backup: $Path"
    }
    if ([string]$record.transactionId -notmatch '^[0-9]+-[0-9a-f]{8}$') {
        throw "EchoPatch transaction record has an invalid transaction id: $Path"
    }
    $candidateRoot = Get-EpFullPath ([string]$record.candidateRoot)
    Assert-EpChildPath -Child $candidateRoot -Parent $Context.VendorRoot
    if ((Split-Path -Leaf $candidateRoot) -cne ".epb-$($record.transactionId)" -or
        -not [string]::Equals((Split-Path -Parent $candidateRoot), $Context.OutputParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "EchoPatch transaction record has an invalid candidate path: $Path"
    }
    if (-not (Test-EpSupportedPackageMode -PackageMode ([string]$record.packageMode))) {
        throw "EchoPatch transaction record has an invalid package mode: $Path"
    }
    if ($record.hadExistingOutput -isnot [bool]) {
        throw "EchoPatch transaction record has a non-Boolean existing-output flag: $Path"
    }
    return $record
}

function Invoke-EpPromotionRecovery([pscustomobject]$Context) {
    $journalRecord = $null
    $commitRecord = $null
    $journalError = $null
    $commitError = $null

    if (Test-Path -LiteralPath $Context.JournalPath) {
        try {
            $journalRecord = Read-EpPromotionRecord -Path $Context.JournalPath -ExpectedPhase 'intent' -Context $Context
        }
        catch {
            $journalError = $_
        }
    }
    if (Test-Path -LiteralPath $Context.CommitPath) {
        try {
            $commitRecord = Read-EpPromotionRecord -Path $Context.CommitPath -ExpectedPhase 'committed' -Context $Context
        }
        catch {
            $commitError = $_
        }
    }

    if ($commitRecord) {
        if ($journalRecord) {
            foreach ($propertyName in @(
                'transactionId', 'outputRoot', 'candidateRoot', 'backupRoot', 'packageMode', 'hadExistingOutput'
            )) {
                if ([string]$journalRecord.$propertyName -cne [string]$commitRecord.$propertyName) {
                    throw "EchoPatch intent and commit records disagree on '$propertyName' for '$($Context.OutputRoot)'."
                }
            }
        }
        $candidateRoot = Get-EpFullPath ([string]$commitRecord.candidateRoot)
        if (-not (Test-Path -LiteralPath $Context.OutputRoot)) {
            throw "Committed EchoPatch output is missing and cannot be recovered automatically: $($Context.OutputRoot)"
        }
        Assert-EpNoReparsePoints -Path $Context.OutputRoot
        Assert-EpPackageCoherence -CandidateRoot $Context.OutputRoot -ShortCommit $Context.ShortCommit `
            -ExpectedPackageMode ([string]$commitRecord.packageMode)
        if (Test-Path -LiteralPath $candidateRoot) {
            Remove-EpGuardedTree -Path $candidateRoot -Parent $Context.VendorRoot
        }
        if (Test-Path -LiteralPath $Context.BackupRoot) {
            Remove-EpGuardedTree -Path $Context.BackupRoot -Parent $Context.VendorRoot
        }
        Remove-EpGuardedFile -Path $Context.JournalPath -Parent $Context.VendorRoot
        Remove-EpGuardedFile -Path $Context.CommitPath -Parent $Context.VendorRoot
        Write-Host "Recovered committed EchoPatch promotion for '$($Context.OutputRoot)'."
        return
    }

    if ($commitError -and -not $journalRecord) {
        throw "EchoPatch commit record is unreadable and has no valid intent record: $($commitError.Exception.Message)"
    }

    if ($journalRecord) {
        $candidateRoot = Get-EpFullPath ([string]$journalRecord.candidateRoot)
        $hadExistingOutput = [bool]$journalRecord.hadExistingOutput
        if (Test-Path -LiteralPath $Context.BackupRoot) {
            Assert-EpNoReparsePoints -Path $Context.BackupRoot
            Remove-EpGuardedFile -Path $Context.JournalPath -Parent $Context.VendorRoot
            Remove-EpGuardedFile -Path $Context.CommitPath -Parent $Context.VendorRoot
            if (Test-Path -LiteralPath $Context.OutputRoot) {
                Remove-EpGuardedTree -Path $Context.OutputRoot -Parent $Context.VendorRoot
            }
            Move-Item -LiteralPath $Context.BackupRoot -Destination $Context.OutputRoot
            if (Test-Path -LiteralPath $candidateRoot) {
                Remove-EpGuardedTree -Path $candidateRoot -Parent $Context.VendorRoot
            }
            Write-Host "Recovered interrupted EchoPatch promotion: restored previous output '$($Context.OutputRoot)'."
            return
        }

        $outputExists = Test-Path -LiteralPath $Context.OutputRoot
        $candidateExists = Test-Path -LiteralPath $candidateRoot
        if ($hadExistingOutput) {
            if ($outputExists -and $candidateExists) {
                Remove-EpGuardedTree -Path $candidateRoot -Parent $Context.VendorRoot
                Remove-EpGuardedFile -Path $Context.JournalPath -Parent $Context.VendorRoot
                Remove-EpGuardedFile -Path $Context.CommitPath -Parent $Context.VendorRoot
                Write-Host 'Recovered interrupted EchoPatch promotion before the previous output was moved.'
                return
            }
            throw "Interrupted EchoPatch promotion lost its previous-output backup and cannot be recovered automatically: $($Context.BackupRoot)"
        }

        if ($outputExists -and $candidateExists) {
            throw 'Interrupted first-install EchoPatch promotion has both output and candidate paths occupied.'
        }
        if ($candidateExists) {
            Assert-EpNoReparsePoints -Path $candidateRoot
            Assert-EpPackageCoherence -CandidateRoot $candidateRoot -ShortCommit $Context.ShortCommit `
                -ExpectedPackageMode ([string]$journalRecord.packageMode)
            Move-Item -LiteralPath $candidateRoot -Destination $Context.OutputRoot
            $outputExists = $true
        }
        if ($outputExists) {
            Assert-EpNoReparsePoints -Path $Context.OutputRoot
            Assert-EpPackageCoherence -CandidateRoot $Context.OutputRoot -ShortCommit $Context.ShortCommit `
                -ExpectedPackageMode ([string]$journalRecord.packageMode)
        }
        Remove-EpGuardedFile -Path $Context.JournalPath -Parent $Context.VendorRoot
        Remove-EpGuardedFile -Path $Context.CommitPath -Parent $Context.VendorRoot
        Write-Host "Recovered interrupted first-install EchoPatch promotion for '$($Context.OutputRoot)'."
        return
    }

    if ($journalError) {
        $unidentifiedCandidates = @(Get-ChildItem -LiteralPath $Context.OutputParent -Force |
            Where-Object { $_.Name -match '^\.epb-[0-9]+-[0-9a-f]{8}$' })
        if ($unidentifiedCandidates.Count -gt 0) {
            throw "EchoPatch intent record is unreadable while unidentified promotion candidate(s) remain. The journal, output, backup, and candidates were retained for manual recovery: $($unidentifiedCandidates.FullName -join ', ')"
        }
        if (Test-Path -LiteralPath $Context.BackupRoot) {
            Assert-EpNoReparsePoints -Path $Context.BackupRoot
            Remove-EpGuardedFile -Path $Context.JournalPath -Parent $Context.VendorRoot
            Remove-EpGuardedFile -Path $Context.CommitPath -Parent $Context.VendorRoot
            if (Test-Path -LiteralPath $Context.OutputRoot) {
                Remove-EpGuardedTree -Path $Context.OutputRoot -Parent $Context.VendorRoot
            }
            Move-Item -LiteralPath $Context.BackupRoot -Destination $Context.OutputRoot
            Write-Warning 'Recovered previous EchoPatch output using the deterministic backup because the intent record was unreadable.'
            return
        }
        if (Test-Path -LiteralPath $Context.OutputRoot) {
            $existingManifestPath = Join-Path $Context.OutputRoot "manifest-$($Context.ShortCommit).json"
            try {
                $existingManifest = Get-Content -LiteralPath $existingManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
                if (-not $existingManifest.PSObject.Properties['packageMode'] -or
                    [string]::IsNullOrWhiteSpace([string]$existingManifest.packageMode)) {
                    throw "Existing output manifest has no packageMode: $existingManifestPath"
                }
                Assert-EpPackageCoherence -CandidateRoot $Context.OutputRoot -ShortCommit $Context.ShortCommit `
                    -ExpectedPackageMode ([string]$existingManifest.packageMode)
            }
            catch {
                throw "EchoPatch intent record is unreadable and the existing output could not be validated. Recovery state was retained for manual inspection: $($_.Exception.Message)"
            }
            Remove-EpGuardedFile -Path $Context.JournalPath -Parent $Context.VendorRoot
            Write-Warning 'Discarded an unreadable EchoPatch intent record after validating and preserving the existing output.'
            return
        }
        Remove-EpGuardedFile -Path $Context.JournalPath -Parent $Context.VendorRoot
        Remove-EpGuardedFile -Path $Context.CommitPath -Parent $Context.VendorRoot
        Write-Warning 'Discarded an unreadable first-install EchoPatch intent record; no existing output had been moved.'
        return
    }

    if (Test-Path -LiteralPath $Context.BackupRoot) {
        Assert-EpNoReparsePoints -Path $Context.BackupRoot
        if (Test-Path -LiteralPath $Context.OutputRoot) {
            Remove-EpGuardedTree -Path $Context.OutputRoot -Parent $Context.VendorRoot
        }
        Move-Item -LiteralPath $Context.BackupRoot -Destination $Context.OutputRoot
        Write-Warning 'Restored an orphaned pre-commit EchoPatch backup.'
    }
}

function Initialize-EchoPatchPromotion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$OutputRoot,
        [Parameter(Mandatory)][string]$VendorRoot,
        [Parameter(Mandatory)][string]$ShortCommit
    )

    $outputFull = Get-EpFullPath $OutputRoot
    $vendorFull = Get-EpFullPath $VendorRoot
    Assert-EpChildPath -Child $outputFull -Parent $vendorFull
    Assert-EpExistingPathChain -Base $vendorFull -Target $outputFull
    $outputParent = Split-Path -Parent $outputFull
    Assert-EpExistingPathChain -Base $vendorFull -Target $outputParent
    New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
    Assert-EpExistingPathChain -Base $vendorFull -Target $outputParent

    $key = Get-EpPromotionKey $outputFull
    $context = [pscustomobject]@{
        OutputRoot = $outputFull
        OutputParent = $outputParent
        VendorRoot = $vendorFull
        ShortCommit = $ShortCommit
        BackupRoot = (Join-Path $outputParent ".epo-$key")
        JournalPath = (Join-Path $outputParent ".epj-$key.json")
        CommitPath = (Join-Path $outputParent ".epc-$key.json")
        LockPath = (Join-Path $outputParent ".epl-$key.lock")
    }
    foreach ($path in @($context.BackupRoot, $context.JournalPath, $context.CommitPath, $context.LockPath)) {
        Assert-EpChildPath -Child $path -Parent $vendorFull
    }

    $lock = Open-EpPromotionLock -Path $context.LockPath -Parent $vendorFull
    try {
        Invoke-EpPromotionRecovery -Context $context
    }
    finally {
        Close-EpPromotionLock -Lock $lock -Path $context.LockPath -Parent $vendorFull
    }
    return $context
}

function Publish-EchoPatchCandidate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][pscustomobject]$Context,
        [Parameter(Mandatory)][string]$CandidateRoot,
        [Parameter(Mandatory)][string]$ExpectedPackageMode
    )

    $candidateFull = Get-EpFullPath $CandidateRoot
    Assert-EpChildPath -Child $candidateFull -Parent $Context.VendorRoot
    $candidateLeaf = Split-Path -Leaf $candidateFull
    if ($candidateLeaf -notmatch '^\.epb-([0-9]+-[0-9a-f]{8})$' -or
        -not [string]::Equals((Split-Path -Parent $candidateFull), $Context.OutputParent, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing EchoPatch promotion from an invalid transaction root: $candidateFull"
    }
    $transactionId = $Matches[1]
    Assert-EpNoReparsePoints -Path $candidateFull
    Assert-EpPackageCoherence -CandidateRoot $candidateFull -ShortCommit $Context.ShortCommit `
        -ExpectedPackageMode $ExpectedPackageMode

    $lock = Open-EpPromotionLock -Path $Context.LockPath -Parent $Context.VendorRoot
    try {
        Invoke-EpPromotionRecovery -Context $Context
        if ((Test-Path -LiteralPath $Context.BackupRoot) -or
            (Test-Path -LiteralPath $Context.JournalPath) -or
            (Test-Path -LiteralPath $Context.CommitPath)) {
            throw "EchoPatch promotion recovery did not clear all transaction records for '$($Context.OutputRoot)'."
        }

        $hadExistingOutput = Test-Path -LiteralPath $Context.OutputRoot
        $intentRecord = New-EpPromotionRecord -Phase 'intent' -TransactionId $transactionId `
            -Context $Context -CandidateRoot $candidateFull -ExpectedPackageMode $ExpectedPackageMode `
            -HadExistingOutput $hadExistingOutput
        Write-EpDurableJsonFile -Path $Context.JournalPath -Value $intentRecord

        Assert-EpExistingPathChain -Base $Context.VendorRoot -Target $Context.OutputRoot
        if ($hadExistingOutput) {
            Assert-EpNoReparsePoints -Path $Context.OutputRoot
            Move-Item -LiteralPath $Context.OutputRoot -Destination $Context.BackupRoot
        }
        Move-Item -LiteralPath $candidateFull -Destination $Context.OutputRoot
        Assert-EpNoReparsePoints -Path $Context.OutputRoot
        Assert-EpPackageCoherence -CandidateRoot $Context.OutputRoot -ShortCommit $Context.ShortCommit `
            -ExpectedPackageMode $ExpectedPackageMode

        $commitRecord = New-EpPromotionRecord -Phase 'committed' -TransactionId $transactionId `
            -Context $Context -CandidateRoot $candidateFull -ExpectedPackageMode $ExpectedPackageMode `
            -HadExistingOutput $hadExistingOutput
        Write-EpDurableJsonFile -Path $Context.CommitPath -Value $commitRecord

        if (Test-Path -LiteralPath $Context.BackupRoot) {
            Remove-EpGuardedTree -Path $Context.BackupRoot -Parent $Context.VendorRoot
        }
        Remove-EpGuardedFile -Path $Context.JournalPath -Parent $Context.VendorRoot
        Remove-EpGuardedFile -Path $Context.CommitPath -Parent $Context.VendorRoot
    }
    catch {
        $promotionError = $_
        try {
            Invoke-EpPromotionRecovery -Context $Context
        }
        catch {
            throw "EchoPatch promotion failed and automatic recovery also failed. Original error: $($promotionError.Exception.Message) Recovery error: $($_.Exception.Message)"
        }
        throw $promotionError
    }
    finally {
        Close-EpPromotionLock -Lock $lock -Path $Context.LockPath -Parent $Context.VendorRoot
    }
}

Export-ModuleMember -Function Initialize-EchoPatchPromotion, Publish-EchoPatchCandidate
