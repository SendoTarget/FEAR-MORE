[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet('Rebuilt', 'StockEchoPatch', 'SdkSmoke')]
    [string]$Lane = 'Rebuilt',

    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release',

    [string]$RepositoryRoot,
    [string]$RetailRoot,
    [string]$SdkRoot,
    [string]$BuildRoot,
    [string]$StageRoot,
    [string]$EchoPatchArchive,
    [string]$ControllerArchive,

    [ValidateSet('NativeD3D9', 'DgVoodooD3D11', 'RtxRemixProbe')]
    [string]$RendererMode = 'NativeD3D9',

    [ValidateSet('Native', 'Max2x')]
    [string]$RendererQuality = 'Native',

    [string]$DgVoodooArchive,
    [string]$RtxRemixArchive,

    [ValidateSet('None', 'ReShadeCas')]
    [string]$PostProcessMode = 'None',

    [string]$ReShadeSetup,

    [ValidateSet('None', 'EngineOnlyEchoPatch', 'RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')]
    [string]$EnginePatchMode = 'None',

    [string]$EnginePatchPackageRoot,
    [string]$EnginePatchManifest,

    [ValidateSet('Off', 'Lite', 'Full')]
    [string]$HdTextureMode = 'Off',

    [string]$HdTexturePackRoot,
    [string]$HdTextureLaaExecutable,
    [string]$HdTextureLaaBackup,

    [ValidateRange(30.0, 300.0)]
    [double]$MaxFPS = 60.0,

    [ValidateRange(1.0, 4.0)]
    [double]$SSAAScale = 1.0,

    [switch]$ValidateOnly,
    [switch]$RefreshRuntimeExecutable,
    [switch]$Launch,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$LaunchArguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Get-FileHash resolves its input through WhatIf-aware provider commands.  Keep
# read-only preflight deterministic under -WhatIf, then restore the invocation
# preference at the single filesystem-mutation authorization boundary below.
$stageWhatIfPreference = $WhatIfPreference
$WhatIfPreference = $false
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeExecutable.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStagePlan.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStageOwnership.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRendererPackage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearEnginePatchPackage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeStageSafety.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearTexturePackage.psm1') -Force -ErrorAction Stop
Import-Module (Join-Path $PSScriptRoot 'FearRuntimeLayout.psm1') -Force -ErrorAction Stop

$ExpectedFearVersion = '1.08.282.0'
$ExpectedEchoPatchHash = '5AE9BF8F4D549B0F1CD682D63B4123C2BFF2622BD2035779DF263183C61BF9AE'
$SteamAppId = '21090'
$SteamAppIdFileName = 'steam_appid.txt'
$SteamAppIdFileSha256 = 'AD63AE7E99775887985974467E5FD52CCE63C0AA631494BA753D34CFA99CF5EA'
$StageManifestName = 'fearmore-stage.json'
$GameModuleNames = @('GameClient.dll', 'GameServer.dll', 'ClientFx.fxd')

function Copy-FileToStage {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Destination
    Copy-Item -LiteralPath $Source -Destination $Destination -Force
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Destination
}

function Write-BytesToStage {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Bytes,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][long]$ExpectedSize,
        [Parameter(Mandatory = $true)][ValidatePattern('^[0-9A-Fa-f]{64}$')][string]$ExpectedSha256,
        [Parameter(Mandatory = $true)][string]$Description,
        [switch]$CreateNew
    )

    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Destination
    if ($CreateNew) {
        $outputStream = [IO.File]::Open(
            $Destination,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None)
        try {
            $outputStream.Write($Bytes, 0, $Bytes.Length)
            $outputStream.Flush()
        }
        finally {
            $outputStream.Dispose()
        }
    }
    else {
        [IO.File]::WriteAllBytes($Destination, $Bytes)
    }
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Destination
    $item = Get-Item -LiteralPath $Destination -Force -ErrorAction Stop
    $sha256 = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash
    if ([long]$item.Length -ne $ExpectedSize -or $sha256 -cne $ExpectedSha256.ToUpperInvariant()) {
        throw "Staged $Description does not match its validated in-memory payload identity: $Destination"
    }

    return [pscustomobject]@{
        Path    = $item.FullName
        Size    = [long]$item.Length
        Sha256  = $sha256
    }
}

function ConvertTo-WindowsCommandLineArgument {
    param([AllowEmptyString()][string]$Value)

    if ($null -eq $Value) {
        $Value = ''
    }
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    # Follow CommandLineToArgvW quoting rules so paths containing spaces and
    # trailing backslashes remain one argument when Start-Process joins them.
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }
        if ($character -eq '"') {
            for ($index = 0; $index -lt (($backslashCount * 2) + 1); $index++) {
                [void]$builder.Append('\')
            }
            [void]$builder.Append('"')
            $backslashCount = 0
            continue
        }
        for ($index = 0; $index -lt $backslashCount; $index++) {
            [void]$builder.Append('\')
        }
        $backslashCount = 0
        [void]$builder.Append($character)
    }
    for ($index = 0; $index -lt ($backslashCount * 2); $index++) {
        [void]$builder.Append('\')
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Join-WindowsCommandLineArguments {
    param([AllowEmptyCollection()][string[]]$Arguments)

    return (@($Arguments | ForEach-Object { ConvertTo-WindowsCommandLineArgument -Value $_ }) -join ' ')
}

function Ensure-SafeStageDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Assert-FearSafeStageDirectoryTarget -StageRoot $StageRoot -Path $Path
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
    Assert-FearSafeStageDirectoryTarget -StageRoot $StageRoot -Path $Path
}

function Ensure-StageUserDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Ensure-SafeStageDirectory -Path $Path -StageRoot $StageRoot
}

function Archive-FearRemixRuntimeLog {
    param([Parameter(Mandatory = $true)][string]$StageRoot)

    $logPath = Join-Path $StageRoot 'rtx-remix\logs\remix-dxvk.log'
    if (-not (Test-Path -LiteralPath $logPath)) {
        return $null
    }
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $logPath
    if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
        throw "RTX Remix active log is not an ordinary file: $logPath"
    }

    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ')
    $archiveName = "remix-dxvk.before-$stamp-$([guid]::NewGuid().ToString('N')).log"
    $archivePath = Join-Path (Split-Path $logPath -Parent) $archiveName
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $archivePath
    [IO.File]::Move($logPath, $archivePath)
    return $archivePath
}

function Assert-FileVersion {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$ExpectedVersion,
        [Parameter(Mandatory = $true)][string]$Description
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing: $Path"
    }

    $actualVersion = (Get-Item -LiteralPath $Path).VersionInfo.FileVersion
    if ($actualVersion -ne $ExpectedVersion) {
        throw "$Description must be F.E.A.R. v1.08 ($ExpectedVersion), but '$Path' is '$actualVersion'."
    }

    return $actualVersion
}

function Get-RuntimeRefreshTransactionPaths {
    param([Parameter(Mandatory = $true)][string]$StageRoot)

    return @(
        (Join-Path $StageRoot 'FEAR.exe.refresh.new'),
        (Join-Path $StageRoot 'FEAR.exe.refresh.previous'),
        (Join-Path $StageRoot 'FEAR.exe.bak.refresh.previous')
    )
}

function Assert-NoRuntimeRefreshTransactionFiles {
    param([Parameter(Mandatory = $true)][string]$StageRoot)

    foreach ($path in (Get-RuntimeRefreshTransactionPaths -StageRoot $StageRoot)) {
        if (Test-Path -LiteralPath $path) {
            throw "An earlier runtime refresh left a recovery file. No stage files were changed; inspect and recover it manually before staging: $path"
        }
    }
}

function Invoke-TransactionalStockRuntimeExecutableRefresh {
    param(
        [Parameter(Mandatory = $true)][string]$RetailExecutable,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    $stageExecutable = Join-Path $StageRoot 'FEAR.exe'
    $backupExecutable = Join-Path $StageRoot 'FEAR.exe.bak'
    $transactionPaths = @(Get-RuntimeRefreshTransactionPaths -StageRoot $StageRoot)
    $newExecutable = $transactionPaths[0]
    $previousExecutable = $transactionPaths[1]
    $previousBackup = $transactionPaths[2]
    Assert-NoRuntimeRefreshTransactionFiles -StageRoot $StageRoot

    foreach ($path in @($stageExecutable, $backupExecutable)) {
        if (Test-Path -LiteralPath $path) {
            Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $path
        }
    }
    foreach ($path in $transactionPaths) {
        Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $path
    }

    $executableMoved = $false
    $backupMoved = $false
    $replacementInstalled = $false
    $committed = $false
    try {
        Copy-FileToStage -Source $RetailExecutable -Destination $newExecutable -StageRoot $StageRoot
        $retailHash = (Get-FileHash -LiteralPath $RetailExecutable -Algorithm SHA256).Hash
        $newIdentity = Get-FearPeRuntimeIdentity -Path $newExecutable
        if ($newIdentity.Sha256 -ne $retailHash -or -not (Test-FearX86Pe32Identity -Identity $newIdentity)) {
            throw "Runtime refresh copy failed identity verification: $newExecutable"
        }

        if (Test-Path -LiteralPath $backupExecutable -PathType Leaf) {
            [IO.File]::Move($backupExecutable, $previousBackup)
            $backupMoved = $true
        }
        [IO.File]::Move($stageExecutable, $previousExecutable)
        $executableMoved = $true
        [IO.File]::Move($newExecutable, $stageExecutable)
        $replacementInstalled = $true

        $assessment = Get-FearStockRuntimeExecutableAssessment -RetailExecutable $RetailExecutable -StageRoot $StageRoot
        if ($assessment.State -ne 'RetailOriginal') {
            throw "Runtime refresh installed an executable that did not attest as RetailOriginal: $stageExecutable"
        }
        $committed = $true
    }
    catch {
        $failure = $_
        if (-not $committed) {
            if ($replacementInstalled -and (Test-Path -LiteralPath $stageExecutable -PathType Leaf)) {
                Remove-Item -LiteralPath $stageExecutable -Force
            }
            if ($executableMoved -and (Test-Path -LiteralPath $previousExecutable -PathType Leaf)) {
                [IO.File]::Move($previousExecutable, $stageExecutable)
            }
            if ($backupMoved -and (Test-Path -LiteralPath $previousBackup -PathType Leaf)) {
                [IO.File]::Move($previousBackup, $backupExecutable)
            }
            if (Test-Path -LiteralPath $newExecutable -PathType Leaf) {
                Remove-Item -LiteralPath $newExecutable -Force
            }
        }
        throw $failure
    }

    # Defer destructive cleanup until the replacement has been fully verified.
    # Any cleanup failure leaves an explicitly named recovery copy rather than
    # destroying the pre-refresh executable pair.
    foreach ($path in @($previousBackup, $previousExecutable)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    return $assessment
}

function Sync-StockRuntimeExecutable {
    param(
        [Parameter(Mandatory = $true)][string]$RetailExecutable,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [switch]$Refresh
    )

    $stageExecutable = Join-Path $StageRoot 'FEAR.exe'
    $assessment = Get-FearStockRuntimeExecutableAssessment -RetailExecutable $RetailExecutable -StageRoot $StageRoot

    if ($assessment.State -eq 'Missing') {
        Copy-FileToStage -Source $RetailExecutable -Destination $stageExecutable -StageRoot $StageRoot
        return Get-FearStockRuntimeExecutableAssessment -RetailExecutable $RetailExecutable -StageRoot $StageRoot
    }
    if ($assessment.State -eq 'RetailOriginal') {
        return $assessment
    }
    if ($assessment.State -eq 'EchoPatchedLAA' -and -not $Refresh) {
        return $assessment
    }
    if ($assessment.State -eq 'Unknown' -and -not $Refresh) {
        throw "Stock EchoPatch stage contains an unknown FEAR.exe derivative. Inspect it manually or use -RefreshRuntimeExecutable to replace the ordinary stage-local executable pair: $stageExecutable"
    }

    return Invoke-TransactionalStockRuntimeExecutableRefresh -RetailExecutable $RetailExecutable -StageRoot $StageRoot
}

function Write-SteamAppIdHintFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)][string]$AppId
    )

    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
    if (Test-Path -LiteralPath $Path) {
        throw "Refusing to overwrite an existing Steam App ID hint transaction file: $Path"
    }
    [IO.File]::WriteAllText($Path, $AppId, [Text.ASCIIEncoding]::new())
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $SteamAppIdFileSha256) {
        throw "Generated Steam App ID hint failed its exact-content check: $Path"
    }
}

function Assert-GameModules {
    param([Parameter(Mandatory = $true)][string]$ModuleRoot)

    $result = @()
    foreach ($moduleName in $GameModuleNames) {
        $modulePath = Join-Path $ModuleRoot $moduleName
        if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
            throw "Required rebuilt module is missing: $modulePath"
        }

        $peIdentity = Get-FearPeRuntimeIdentity -Path $modulePath
        if (-not (Test-FearX86Pe32Identity -Identity $peIdentity)) {
            throw "'$modulePath' is not a 32-bit x86 PE image (machine 0x014C, PE32 magic 0x010B required)."
        }

        $fileVersion = $null
        if ($moduleName -ne 'ClientFx.fxd') {
            $fileVersion = Assert-FileVersion -Path $modulePath -ExpectedVersion $ExpectedFearVersion -Description $moduleName
        }

        $result += [pscustomobject]@{
            Name        = $moduleName
            Path        = $modulePath
            FileVersion = $fileVersion
            Sha256      = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash
        }
    }

    return $result
}

function Add-UniqueCandidate {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[string]]$Candidates,
        [string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) {
        return
    }

    try {
        $canonicalCandidate = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Candidate))
    }
    catch {
        return
    }

    foreach ($existingCandidate in $Candidates) {
        if ($existingCandidate.Equals($canonicalCandidate, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
    }

    $Candidates.Add($canonicalCandidate)
}

function Get-SteamLibraryRoots {
    $libraryFiles = [Collections.Generic.List[string]]::new()
    if (${env:ProgramFiles(x86)}) {
        Add-UniqueCandidate -Candidates $libraryFiles -Candidate (Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\libraryfolders.vdf')
    }
    if ($env:ProgramFiles) {
        Add-UniqueCandidate -Candidates $libraryFiles -Candidate (Join-Path $env:ProgramFiles 'Steam\steamapps\libraryfolders.vdf')
    }

    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        Add-UniqueCandidate -Candidates $libraryFiles -Candidate (Join-Path $drive.Root 'SteamLibrary\steamapps\libraryfolders.vdf')
        Add-UniqueCandidate -Candidates $libraryFiles -Candidate (Join-Path $drive.Root 'Steam\steamapps\libraryfolders.vdf')
    }

    $libraries = [Collections.Generic.List[string]]::new()
    foreach ($libraryFile in $libraryFiles) {
        if (-not (Test-Path -LiteralPath $libraryFile -PathType Leaf -ErrorAction SilentlyContinue)) {
            continue
        }

        $defaultLibrary = Split-Path (Split-Path $libraryFile -Parent) -Parent
        Add-UniqueCandidate -Candidates $libraries -Candidate $defaultLibrary

        foreach ($line in (Get-Content -LiteralPath $libraryFile)) {
            if ($line -match '"path"\s+"([^"]+)"') {
                Add-UniqueCandidate -Candidates $libraries -Candidate ($Matches[1] -replace '\\\\', '\')
            }
        }
    }

    return $libraries
}

function Get-FearRetailCandidates {
    $candidates = [Collections.Generic.List[string]]::new()

    foreach ($steamLibrary in (Get-SteamLibraryRoots)) {
        $steamApps = Join-Path $steamLibrary 'steamapps'
        $manifestPath = Join-Path $steamApps 'appmanifest_21090.acf'
        if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
            $manifestText = Get-Content -LiteralPath $manifestPath -Raw
            if ($manifestText -match '"installdir"\s+"([^"]+)"') {
                Add-UniqueCandidate -Candidates $candidates -Candidate (Join-Path (Join-Path $steamApps 'common') $Matches[1])
            }
        }

        Add-UniqueCandidate -Candidates $candidates -Candidate (Join-Path (Join-Path $steamApps 'common') 'F.E.A.R. - Ultimate Shooter Edition')
        Add-UniqueCandidate -Candidates $candidates -Candidate (Join-Path (Join-Path $steamApps 'common') 'FEAR Ultimate Shooter Edition')
    }

    $uninstallRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($entry in (Get-ItemProperty $uninstallRoots -ErrorAction SilentlyContinue)) {
        $displayNameProperty = $entry.PSObject.Properties['DisplayName']
        $installLocationProperty = $entry.PSObject.Properties['InstallLocation']
        if ($displayNameProperty -and $installLocationProperty -and
            ($displayNameProperty.Value -match '(?i)F\.E\.A\.R|First Encounter Assault') -and
            $installLocationProperty.Value) {
            Add-UniqueCandidate -Candidates $candidates -Candidate $installLocationProperty.Value
        }
    }

    foreach ($entry in (Get-ItemProperty 'HKLM:\SOFTWARE\GOG.com\Games\*' -ErrorAction SilentlyContinue)) {
        $pathProperty = $entry.PSObject.Properties['path']
        if ($pathProperty -and $pathProperty.Value) {
            Add-UniqueCandidate -Candidates $candidates -Candidate $pathProperty.Value
        }
    }

    foreach ($drive in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($relativePath in @(
            'GOG Games\F.E.A.R. Platinum Collection',
            'GOG\F.E.A.R. Platinum Collection',
            'GOG\FEAR',
            'Games\F.E.A.R. Platinum Collection',
            'Program Files (x86)\Sierra\FEAR',
            'Program Files (x86)\Monolith Productions\FEAR'
        )) {
            Add-UniqueCandidate -Candidates $candidates -Candidate (Join-Path $drive.Root $relativePath)
        }
    }

    return $candidates
}

function Test-FearRetailRoot {
    param([Parameter(Mandatory = $true)][string]$Candidate)

    $fearExe = Join-Path $Candidate 'FEAR.exe'
    $archiveConfig = Join-Path $Candidate 'Default.archcfg'
    $baseArchive = Join-Path $Candidate 'FEAR.Arch00'
    if (-not (Test-Path -LiteralPath $fearExe -PathType Leaf -ErrorAction SilentlyContinue) -or
        -not (Test-Path -LiteralPath $archiveConfig -PathType Leaf -ErrorAction SilentlyContinue) -or
        -not (Test-Path -LiteralPath $baseArchive -PathType Leaf -ErrorAction SilentlyContinue)) {
        return $false
    }

    return (Get-Item -LiteralPath $fearExe).VersionInfo.FileVersion -eq $ExpectedFearVersion
}

function Resolve-FearRetailRoot {
    param(
        [string]$RequestedRoot,
        [Parameter(Mandatory = $true)][string]$BasePath
    )

    if (-not [string]::IsNullOrWhiteSpace($RequestedRoot)) {
        $explicitRoot = Get-FearCanonicalPath -Path $RequestedRoot -BasePath $BasePath
        if (-not (Test-FearRetailRoot -Candidate $explicitRoot)) {
            throw "'$explicitRoot' is not a complete F.E.A.R. v1.08 retail root. FEAR.exe v$ExpectedFearVersion, Default.archcfg, and FEAR.Arch00 are required."
        }
        return $explicitRoot
    }

    foreach ($candidate in (Get-FearRetailCandidates)) {
        if (Test-FearRetailRoot -Candidate $candidate) {
            return $candidate
        }
    }

    throw "No F.E.A.R. v1.08 retail installation was found in Steam, GOG, uninstall-registry, or standard game locations. Install a user-owned Steam/GOG copy or pass -RetailRoot explicitly."
}

function Get-RetailArchiveEntries {
    param([Parameter(Mandatory = $true)][string]$Root)

    $entries = @()
    $archiveConfig = Join-Path $Root 'Default.archcfg'
    foreach ($rawLine in (Get-Content -LiteralPath $archiveConfig)) {
        $entry = $rawLine.Trim()
        if (-not $entry -or $entry.StartsWith(';') -or $entry.StartsWith('#')) {
            continue
        }

        if ([IO.Path]::IsPathRooted($entry)) {
            throw "Retail Default.archcfg contains an absolute path, which is not accepted by the safe staging tool: $entry"
        }

        $resourcePath = [IO.Path]::GetFullPath((Join-Path $Root $entry))
        if (-not (Test-FearPathIsBelow -Path $resourcePath -Parent $Root)) {
            throw "Retail Default.archcfg entry escapes the retail root: $entry"
        }
        if (-not (Test-Path -LiteralPath $resourcePath)) {
            throw "Retail Default.archcfg references a missing resource: $resourcePath"
        }

        $normalizedEntry = ($entry -replace '/', '\').TrimStart('.', '\')
        $entries += "Retail\$normalizedEntry"
    }

    if ($entries.Count -eq 0) {
        throw "Retail Default.archcfg did not contain any resource entries: $archiveConfig"
    }

    return $entries
}

function Find-SdkRedistributable {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Name
    )

    foreach ($subdirectory in @('Redist', 'Tools', 'Runtime')) {
        $searchRoot = Join-Path $Root $subdirectory
        if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) {
            continue
        }

        $match = Get-ChildItem -LiteralPath $searchRoot -Recurse -File -Filter $Name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) {
            return $match.FullName
        }
    }

    throw "The Public Tools redistributable '$Name' was not found under '$Root'. Extract/install the Runtime, Game, and support-runtime portions of F.E.A.R. Public Tools 1.08."
}

function Assert-SystemDependency {
    param([Parameter(Mandatory = $true)][string]$Name)

    $candidates = @(
        (Join-Path $env:WINDIR "SysWOW64\$Name"),
        (Join-Path $env:WINDIR "System32\$Name")
    )
    $searchedPaths = @()
    $incompatibleImages = @()
    foreach ($candidate in $candidates) {
        $searchedPaths += $candidate
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            try {
                $peIdentity = Get-FearPeRuntimeIdentity -Path $candidate
                if (Test-FearX86Pe32Identity -Identity $peIdentity) {
                    return $candidate
                }

                $machine = '0x{0:X4}' -f [int]$peIdentity.Machine
                $incompatibleImages += "$candidate (machine $machine)"
            }
            catch {
                $incompatibleImages += "$candidate (invalid PE image: $($_.Exception.Message))"
            }
        }
    }

    $searchSummary = $searchedPaths -join '; '
    $incompatibleSummary = if ($incompatibleImages.Count -gt 0) {
        " Incompatible files found: $($incompatibleImages -join '; ')."
    }
    else {
        ''
    }
    throw "Required 32-bit x86 runtime dependency '$Name' is missing. Searched: $searchSummary.$incompatibleSummary Install the official legacy DirectX runtime or current Microsoft Visual C++ x86 redistributable, as appropriate."
}

function Assert-SdkRoot {
    param([Parameter(Mandatory = $true)][string]$Root)

    $runtimeExe = Join-Path $Root 'Runtime\FEARDevSP.exe'
    Assert-FileVersion -Path $runtimeExe -ExpectedVersion $ExpectedFearVersion -Description 'Public Tools FEARDevSP.exe' | Out-Null

    $sdkGameRoot = Join-Path $Root 'Game'
    if (-not (Test-Path -LiteralPath $sdkGameRoot -PathType Container)) {
        throw "Public Tools Game overlay is missing: $sdkGameRoot"
    }
    Assert-GameModules -ModuleRoot $sdkGameRoot | Out-Null

    return [pscustomobject]@{
        RuntimeExe = $runtimeExe
        GameRoot   = $sdkGameRoot
        Msvcp71    = Find-SdkRedistributable -Root $Root -Name 'msvcp71.dll'
        Msvcr71    = Find-SdkRedistributable -Root $Root -Name 'msvcr71.dll'
    }
}

function Assert-RetailBootstrapFiles {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [switch]$IncludeRetailExecutable
    )

    $requiredFiles = @(
        'EngineServer.dll',
        'GameDatabase.dll',
        'LTMemory.dll',
        'SndDrv.dll',
        'StringEditRuntime.dll'
    )
    if ($IncludeRetailExecutable) {
        $requiredFiles = @('FEAR.exe') + $requiredFiles
    }
    foreach ($fileName in $requiredFiles) {
        $path = Join-Path $Root $fileName
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Retail runtime bootstrap file is missing: $path"
        }
    }

    return $requiredFiles
}

function Copy-RetailRuntimeFiles {
    param(
        [Parameter(Mandatory = $true)][string]$RetailRuntimeRoot,
        [Parameter(Mandatory = $true)][string]$DestinationRoot,
        [switch]$IncludeRetailExecutable
    )

    $requiredFiles = @(Assert-RetailBootstrapFiles -Root $RetailRuntimeRoot -IncludeRetailExecutable:$IncludeRetailExecutable)
    $optionalFiles = @(
        'binkw32.dll', 'eax.dll', 'msvcp71.dll', 'msvcr71.dll', 'MFC71.dll', 'MFC71u.dll',
        'enginemsg.txt', 'gamecfg.txt', 'Config.Strdb00p'
    )
    foreach ($fileName in ($requiredFiles + $optionalFiles | Select-Object -Unique)) {
        $sourcePath = Join-Path $RetailRuntimeRoot $fileName
        if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
            Copy-FileToStage -Source $sourcePath -Destination (Join-Path $DestinationRoot $fileName) -StageRoot $DestinationRoot
        }
    }
}

function Remove-ObsoleteRebuiltSdkFiles {
    param([Parameter(Mandatory = $true)][string]$Root)

    foreach ($fileName in @('FEARDevSP.exe', 'AssertWin32DLL.dll', 'FEAR.proj00', 'msvcp71.dll', 'msvcr71.dll')) {
        $path = Join-Path $Root $fileName
        if (-not (Test-Path -LiteralPath $path)) {
            continue
        }
        Assert-FearSafeStageFileTarget -StageRoot $Root -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Cannot migrate the owned Rebuilt stage because an obsolete SDK file path is not a file: $path"
        }
        Remove-Item -LiteralPath $path -Force
    }
}

function Assert-EchoPatchArchive {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Pinned EchoPatch 4.2.1 archive is missing: $Path"
    }

    $actualHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    if ($actualHash -ne $ExpectedEchoPatchHash) {
        throw "EchoPatch archive hash mismatch. Expected $ExpectedEchoPatchHash but found $actualHash at '$Path'."
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        $entryNames = @($zip.Entries | ForEach-Object FullName)
        foreach ($requiredEntry in @('dinput8.dll', 'EchoPatch.ini')) {
            if ($entryNames -notcontains $requiredEntry) {
                throw "Pinned EchoPatch archive is missing '$requiredEntry': $Path"
            }
        }
    }
    finally {
        $zip.Dispose()
    }

    return $actualHash
}

function Copy-ZipEntry {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$EntryName,
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Destination
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $entry = $zip.GetEntry($EntryName)
        if (-not $entry) {
            throw "Archive entry '$EntryName' was not found in '$ArchivePath'."
        }

        $inputStream = $entry.Open()
        try {
            $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try {
                $inputStream.CopyTo($outputStream)
            }
            finally {
                $outputStream.Dispose()
            }
        }
        finally {
            $inputStream.Dispose()
        }
    }
    finally {
        $zip.Dispose()
    }
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Destination
}

function Copy-RendererArchivePayloadToStage {
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][object[]]$Files,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    $stagedFiles = [Collections.Generic.List[object]]::new()
    try {
        foreach ($file in @($Files | Sort-Object RelativePath)) {
            $relativePath = [string]$file.RelativePath
            $destination = [IO.Path]::GetFullPath((Join-Path $StageRoot $relativePath))
            $parentPath = Split-Path $destination -Parent
            if (-not (Test-FearPathsEqual -Left $parentPath -Right $StageRoot)) {
                $relativeParent = $parentPath.Substring([IO.Path]::GetFullPath($StageRoot).TrimEnd('\').Length).TrimStart('\')
                $currentPath = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\')
                foreach ($component in @($relativeParent -split '\\' | Where-Object { $_ })) {
                    $currentPath = Join-Path $currentPath $component
                    Ensure-SafeStageDirectory -Path $currentPath -StageRoot $StageRoot
                }
            }
            Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $destination

            $entry = $zip.GetEntry([string]$file.ArchiveEntry)
            if (-not $entry -or $entry.Length -ne [long]$file.Size) {
                throw "Validated renderer archive entry changed before staging: $($file.ArchiveEntry)"
            }
            $inputStream = $entry.Open()
            try {
                $outputStream = [IO.File]::Open($destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $inputStream.CopyTo($outputStream)
                }
                finally {
                    $outputStream.Dispose()
                }
            }
            finally {
                $inputStream.Dispose()
            }
            Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $destination

            $actualSize = (Get-Item -LiteralPath $destination).Length
            $actualHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
            if ($actualSize -ne [long]$file.Size -or $actualHash -ne [string]$file.Sha256) {
                throw "Staged renderer payload does not match the pinned archive identity: $relativePath"
            }
            $stagedFiles.Add([pscustomobject][ordered]@{
                RelativePath = $relativePath
                Size         = $actualSize
                Sha256       = $actualHash
            })
        }
    }
    finally {
        $zip.Dispose()
    }
    return @($stagedFiles)
}

function Set-EchoPatchSsaaScale {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][double]$Scale,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
    $content = [IO.File]::ReadAllText($Path)
    $pattern = '(?m)^(?<Prefix>[ \t]*SSAAScale[ \t]*=[ \t]*)[^\r\n]*'
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one SSAAScale setting in staged EchoPatch.ini, found $($matches.Count): $Path"
    }

    $formattedScale = $Scale.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
    $updatedContent = [regex]::Replace(
        $content,
        $pattern,
        { param($match) $match.Groups['Prefix'].Value + $formattedScale }
    )
    [IO.File]::WriteAllText($Path, $updatedContent, [Text.UTF8Encoding]::new($false))
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
}

function Set-EngineOnlyEchoPatchFrameCap {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][ValidateRange(30.0, 300.0)][double]$FrameCap,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
    $content = [IO.File]::ReadAllText($Path)
    $maxFpsPattern = '(?m)^(?<Prefix>[ \t]*MaxFPS[ \t]*=[ \t]*)[^\r\n]*'
    $dynamicVsyncPattern = '(?m)^(?<Prefix>[ \t]*DynamicVsync[ \t]*=[ \t]*)[^\r\n]*'
    $maxFpsMatches = [regex]::Matches($content, $maxFpsPattern)
    $dynamicVsyncMatches = [regex]::Matches($content, $dynamicVsyncPattern)
    if ($maxFpsMatches.Count -ne 1 -or $dynamicVsyncMatches.Count -ne 1) {
        throw "Expected exactly one MaxFPS and one DynamicVsync setting in staged engine-only EchoPatch.ini; found $($maxFpsMatches.Count) and $($dynamicVsyncMatches.Count): $Path"
    }

    $formattedFrameCap = $FrameCap.ToString('0.0###', [Globalization.CultureInfo]::InvariantCulture)
    $content = [regex]::Replace(
        $content,
        $maxFpsPattern,
        { param($match) $match.Groups['Prefix'].Value + $formattedFrameCap }
    )
    $content = [regex]::Replace(
        $content,
        $dynamicVsyncPattern,
        { param($match) $match.Groups['Prefix'].Value + '0' }
    )
    [IO.File]::WriteAllText($Path, $content, [Text.UTF8Encoding]::new($false))
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
}

function Set-StagedEchoPatchForceWindowed {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
    $content = [IO.File]::ReadAllText($Path)
    $pattern = '(?m)^(?<Prefix>[ \t]*ForceWindowed[ \t]*=[ \t]*)[^\r\n]*'
    $matches = [regex]::Matches($content, $pattern)
    if ($matches.Count -ne 1) {
        throw "Expected exactly one ForceWindowed setting in staged EchoPatch.ini, found $($matches.Count): $Path"
    }

    $updatedContent = [regex]::Replace(
        $content,
        $pattern,
        { param($match) $match.Groups['Prefix'].Value + $(if ($Enabled) { '1' } else { '0' }) }
    )
    [IO.File]::WriteAllText($Path, $updatedContent, [Text.UTF8Encoding]::new($false))
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
}

function Ensure-ReadOnlyStageJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)]
        [ValidateSet('Retail', 'HDTextures')]
        [string]$MountName
    )

    $expectedPath = Join-Path $StageRoot $MountName
    if (-not (Test-FearPathsEqual -Left $Path -Right $expectedPath)) {
        throw "Only the stage's read-only $MountName junction may be created: $Path"
    }
    Assert-FearNoReparsePathComponents -Root $StageRoot -Path $StageRoot -RequirePath -Description 'stage root'
    if (Test-Path -LiteralPath $Path) {
        Assert-FearIntentionalReadOnlyJunction -Path $Path -Target $Target -MountName $MountName
        return
    }

    New-Item -ItemType Junction -Path $Path -Target $Target | Out-Null
    Assert-FearIntentionalReadOnlyJunction -Path $Path -Target $Target -MountName $MountName
}

function Ensure-RetailJunction {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Ensure-ReadOnlyStageJunction -Path $Path -Target $Target -StageRoot $StageRoot -MountName 'Retail'
}

function Get-ExistingHdTextureMountDeclaration {
    param([AllowNull()]$Manifest)

    if (-not $Manifest) {
        return $null
    }
    $modeProperty = $Manifest.PSObject.Properties['HdTextureMode']
    $mode = if ($modeProperty -and $modeProperty.Value) { [string]$modeProperty.Value } else { 'Off' }
    if ($mode -eq 'Off') {
        return $null
    }
    if ($mode -notin @('Lite', 'Full')) {
        throw "Existing stage manifest declares an unsupported HD texture mode '$mode'. Choose a new stage directory."
    }

    $mountProperty = $Manifest.PSObject.Properties['HdTextureMount']
    $contentRootProperty = $Manifest.PSObject.Properties['HdTextureContentRoot']
    $digestProperty = $Manifest.PSObject.Properties['HdTextureManifestSha256']
    if (-not $mountProperty -or [string]$mountProperty.Value -cne 'HDTextures' -or
        -not $contentRootProperty -or -not [string]$contentRootProperty.Value -or
        -not $digestProperty -or [string]$digestProperty.Value -notmatch '^[0-9A-F]{64}$') {
        throw 'Existing stage manifest does not completely own its HDTextures mount. Choose a new stage directory.'
    }

    return [pscustomobject]@{
        Name   = 'HDTextures'
        Target = [IO.Path]::GetFullPath([string]$contentRootProperty.Value).TrimEnd('\')
    }
}

function Sync-HdTextureJunction {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [AllowNull()]$ExistingMount,
        [AllowNull()][string]$DesiredTarget
    )

    $path = Join-Path $StageRoot 'HDTextures'
    if (Test-Path -LiteralPath $path) {
        if (-not $ExistingMount) {
            throw "Stage contains an unowned HDTextures mount: $path"
        }
        Assert-FearIntentionalReadOnlyJunction -Path $path -Target $ExistingMount.Target -MountName 'HDTextures'
        if ($DesiredTarget -and (Test-FearPathsEqual -Left $ExistingMount.Target -Right $DesiredTarget)) {
            return
        }
        [IO.Directory]::Delete($path, $false)
        if (Test-Path -LiteralPath $path) {
            throw "Failed to remove the previously owned HDTextures junction: $path"
        }
    }
    elseif ($ExistingMount) {
        throw "Existing stage manifest owns an HDTextures mount, but the junction is missing: $path"
    }

    if ($DesiredTarget) {
        Ensure-ReadOnlyStageJunction `
            -Path $path `
            -Target $DesiredTarget `
            -StageRoot $StageRoot `
            -MountName 'HDTextures'
    }
}

function Get-FearRebuiltStageTransitionPaths {
    param([Parameter(Mandatory = $true)][string]$StageRoot)

    return [pscustomobject]@{
        Marker               = Join-Path $StageRoot 'fearmore-stage-transition.json'
        ExecutablePrevious   = Join-Path $StageRoot 'FEAR.exe.stage-transition.previous'
        ArchivePrevious      = Join-Path $StageRoot 'Default.archcfg.stage-transition.previous'
        ManagedFilesPrevious = Join-Path $StageRoot 'fearmore-stage-transition-files.previous'
    }
}

function Assert-NoFearRebuiltStageTransitionFiles {
    param([Parameter(Mandatory = $true)][string]$StageRoot)

    $paths = Get-FearRebuiltStageTransitionPaths -StageRoot $StageRoot
    $legacyPaths = @(
        (Join-Path $StageRoot 'fearmore-hd-transition.json'),
        (Join-Path $StageRoot 'FEAR.exe.hd-transition.previous'),
        (Join-Path $StageRoot 'Default.archcfg.hd-transition.previous'),
        (Join-Path $StageRoot 'fearmore-hd-transition-files.previous')
    )
    foreach ($path in @($paths.Marker, $paths.ExecutablePrevious, $paths.ArchivePrevious, $paths.ManagedFilesPrevious) + $legacyPaths) {
        if (Test-Path -LiteralPath $path) {
            throw "An earlier Rebuilt stage transition left a recovery file. No stage files were changed; inspect and recover the transition before staging: $path"
        }
    }
}

function Start-FearRebuiltStageTransition {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)]$ExistingManifest,
        [AllowNull()][string]$DesiredRetailTarget,
        [AllowNull()]$ExistingMount,
        [AllowNull()][string]$DesiredMountTarget,
        [Parameter(Mandatory = $true)][string[]]$ManagedRelativePaths,
        [string[]]$ManagedRelativeDirectories = @()
    )

    Assert-NoFearRebuiltStageTransitionFiles -StageRoot $StageRoot
    $paths = Get-FearRebuiltStageTransitionPaths -StageRoot $StageRoot
    $manifestPath = Join-Path $StageRoot $StageManifestName
    $executablePath = Join-Path $StageRoot 'FEAR.exe'
    $archivePath = Join-Path $StageRoot 'Default.archcfg'
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $manifestPath
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Owned Rebuilt stage transition manifest is missing: $manifestPath"
    }
    foreach ($path in @($executablePath, $archivePath)) {
        Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $path
        if ((Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Owned Rebuilt stage transition core path is not an ordinary file: $path"
        }
    }
    foreach ($path in @($paths.Marker, $paths.ExecutablePrevious, $paths.ArchivePrevious, $paths.ManagedFilesPrevious)) {
        Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $path
    }

    try {
        $retailPath = Join-Path $StageRoot 'Retail'
        $retailItem = Get-Item -LiteralPath $retailPath -Force -ErrorAction SilentlyContinue
        $retailExisted = $null -ne $retailItem
        $oldRetailTarget = $null
        if ($retailExisted) {
            if (($retailItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or
                -not $retailItem.PSIsContainer -or $retailItem.LinkType -ne 'Junction') {
                throw "Rebuilt stage transition found an unexpected non-junction Retail path: $retailPath"
            }
            $rawRetailTarget = @($retailItem.Target) | Select-Object -First 1
            if (-not $rawRetailTarget) {
                throw "Rebuilt stage transition could not resolve the existing Retail target: $retailPath"
            }
            $oldRetailTarget = Get-FearCanonicalPath -Path ([string]$rawRetailTarget) -BasePath $StageRoot
            if ($DesiredRetailTarget -and
                -not (Test-FearPathsEqual -Left $oldRetailTarget -Right $DesiredRetailTarget)) {
                throw "Rebuilt stage transition found Retail targeting '$oldRetailTarget', expected '$DesiredRetailTarget'."
            }
        }

        $executableExisted = Test-Path -LiteralPath $executablePath -PathType Leaf
        $archiveExisted = Test-Path -LiteralPath $archivePath -PathType Leaf
        $executableSha256 = $null
        $archiveSha256 = $null
        [long]$executableSize = 0
        [long]$archiveSize = 0
        if ($executableExisted) {
            Copy-FileToStage -Source $executablePath -Destination $paths.ExecutablePrevious -StageRoot $StageRoot
            $executableSha256 = (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash
            $executableSize = (Get-Item -LiteralPath $executablePath).Length
            if ((Get-Item -LiteralPath $paths.ExecutablePrevious).Length -ne $executableSize -or
                (Get-FileHash -LiteralPath $paths.ExecutablePrevious -Algorithm SHA256).Hash -cne $executableSha256) {
                throw 'Rebuilt stage transition executable recovery copy failed identity verification.'
            }
        }
        if ($archiveExisted) {
            Copy-FileToStage -Source $archivePath -Destination $paths.ArchivePrevious -StageRoot $StageRoot
            $archiveSha256 = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
            $archiveSize = (Get-Item -LiteralPath $archivePath).Length
            if ((Get-Item -LiteralPath $paths.ArchivePrevious).Length -ne $archiveSize -or
                (Get-FileHash -LiteralPath $paths.ArchivePrevious -Algorithm SHA256).Hash -cne $archiveSha256) {
                throw 'Rebuilt stage transition archive-config recovery copy failed identity verification.'
            }
        }

        Assert-FearSafeStageDirectoryTarget -StageRoot $StageRoot -Path $paths.ManagedFilesPrevious
        Ensure-SafeStageDirectory -Path $paths.ManagedFilesPrevious -StageRoot $StageRoot
        $managedFiles = [Collections.Generic.List[object]]::new()
        $seenRelativePaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $derivedManagedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $managedIndex = 0
        foreach ($rawRelativePath in @($ManagedRelativePaths | Sort-Object)) {
            if (-not $rawRelativePath -or [IO.Path]::IsPathRooted($rawRelativePath)) {
                throw "Invalid absolute or empty Rebuilt stage transition file path: $rawRelativePath"
            }
            $relativePath = $rawRelativePath.Replace('/', '\').TrimStart('\')
            $targetPath = [IO.Path]::GetFullPath((Join-Path $StageRoot $relativePath))
            $targetParent = Split-Path $targetPath -Parent
            if (Test-Path -LiteralPath $targetParent -PathType Container) {
                Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $targetPath
            }
            else {
                Assert-FearNoReparsePathComponents `
                    -Root $StageRoot `
                    -Path $targetParent `
                    -Description 'Rebuilt stage transition file parent'
            }
            $canonicalRelativePath = $targetPath.Substring([IO.Path]::GetFullPath($StageRoot).TrimEnd('\').Length).TrimStart('\')
            if (-not $canonicalRelativePath.Equals($relativePath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Non-canonical Rebuilt stage transition file path is not allowed: $rawRelativePath"
            }
            if (-not $seenRelativePaths.Add($canonicalRelativePath)) {
                throw "Duplicate Rebuilt stage transition file path is not allowed: $canonicalRelativePath"
            }
            $ancestorRelativePath = Split-Path $canonicalRelativePath -Parent
            while (-not [string]::IsNullOrWhiteSpace($ancestorRelativePath)) {
                [void]$derivedManagedDirectories.Add($ancestorRelativePath)
                $nextAncestorRelativePath = Split-Path $ancestorRelativePath -Parent
                if ($nextAncestorRelativePath -ceq $ancestorRelativePath) {
                    throw "Rebuilt stage transition could not reduce managed-file ancestor path: $canonicalRelativePath"
                }
                $ancestorRelativePath = $nextAncestorRelativePath
            }
            if ($canonicalRelativePath -in @('FEAR.exe', 'Default.archcfg')) {
                continue
            }

            $existed = Test-Path -LiteralPath $targetPath
            if ($existed -and -not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                throw "Rebuilt stage transition can only preserve ordinary managed files: $targetPath"
            }
            $backupName = ('{0:D5}.previous' -f $managedIndex)
            $backupPath = Join-Path $paths.ManagedFilesPrevious $backupName
            Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $backupPath
            $sha256 = $null
            [long]$size = 0
            if ($existed) {
                Copy-FileToStage -Source $targetPath -Destination $backupPath -StageRoot $StageRoot
                $sha256 = (Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash
                $size = (Get-Item -LiteralPath $targetPath).Length
                if ((Get-Item -LiteralPath $backupPath).Length -ne $size -or
                    (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -cne $sha256) {
                    throw "Rebuilt stage transition recovery copy failed identity verification: $canonicalRelativePath"
                }
            }
            $managedFiles.Add([pscustomobject][ordered]@{
                RelativePath = $canonicalRelativePath
                Existed      = $existed
                BackupName   = if ($existed) { $backupName } else { $null }
                Size         = $size
                Sha256       = $sha256
            })
            $managedIndex++
        }

        $managedDirectories = [Collections.Generic.List[object]]::new()
        $seenRelativeDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $allManagedRelativeDirectories = @($ManagedRelativeDirectories) + @($derivedManagedDirectories)
        foreach ($rawRelativeDirectory in @($allManagedRelativeDirectories | Sort-Object -Unique)) {
            if (-not $rawRelativeDirectory -or [IO.Path]::IsPathRooted($rawRelativeDirectory)) {
                throw "Invalid absolute or empty Rebuilt stage transition directory path: $rawRelativeDirectory"
            }
            $relativeDirectory = $rawRelativeDirectory.Replace('/', '\').TrimStart('\').TrimEnd('\')
            $targetDirectory = [IO.Path]::GetFullPath((Join-Path $StageRoot $relativeDirectory))
            if (Test-Path -LiteralPath (Split-Path $targetDirectory -Parent) -PathType Container) {
                Assert-FearSafeStageDirectoryTarget -StageRoot $StageRoot -Path $targetDirectory
            }
            else {
                Assert-FearNoReparsePathComponents `
                    -Root $StageRoot `
                    -Path $targetDirectory `
                    -Description 'Rebuilt stage transition managed directory'
            }
            $canonicalRelativeDirectory = $targetDirectory.Substring([IO.Path]::GetFullPath($StageRoot).TrimEnd('\').Length).TrimStart('\')
            if (-not $canonicalRelativeDirectory.Equals($relativeDirectory, [StringComparison]::OrdinalIgnoreCase) -or
                -not $seenRelativeDirectories.Add($canonicalRelativeDirectory)) {
                throw "Non-canonical or duplicate Rebuilt stage transition directory path: $rawRelativeDirectory"
            }
            $directoryExisted = Test-Path -LiteralPath $targetDirectory
            if ($directoryExisted -and -not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
                throw "Rebuilt stage transition can only preserve ordinary managed directories: $targetDirectory"
            }
            $managedDirectories.Add([pscustomobject][ordered]@{
                RelativePath = $canonicalRelativeDirectory
                Existed      = $directoryExisted
            })
        }

        $oldMountTarget = if ($ExistingMount) { [string]$ExistingMount.Target } else { $null }
        $marker = [ordered]@{
            SchemaVersion             = 4
            OldManifestSha256         = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
            OldRetailRoot             = $oldRetailTarget
            DesiredRetailRoot         = $DesiredRetailTarget
            OldHdTextureMode          = if ($ExistingManifest.PSObject.Properties['HdTextureMode']) { [string]$ExistingManifest.HdTextureMode } else { 'Off' }
            OldHdTextureContentRoot   = $oldMountTarget
            DesiredHdTextureContentRoot = $DesiredMountTarget
            ExecutableExisted         = $executableExisted
            ExecutableSize            = $executableSize
            ExecutableSha256          = $executableSha256
            ArchiveConfigExisted      = $archiveExisted
            ArchiveConfigSize         = $archiveSize
            ArchiveConfigSha256       = $archiveSha256
            ManagedFiles              = @($managedFiles)
            ManagedDirectories        = @($managedDirectories)
        }
        Write-StageManifest -Path $paths.Marker -StageRoot $StageRoot -Manifest $marker
        return [pscustomobject]@{
            Paths              = $paths
            OldManifestSha256  = $marker.OldManifestSha256
            OldRetailTarget    = $oldRetailTarget
            DesiredRetailTarget = $DesiredRetailTarget
            OldMountTarget     = $oldMountTarget
            DesiredMountTarget = $DesiredMountTarget
            ExecutableExisted  = $executableExisted
            ExecutableSize     = $executableSize
            ExecutableSha256   = $executableSha256
            ArchiveExisted     = $archiveExisted
            ArchiveSize        = $archiveSize
            ArchiveSha256      = $archiveSha256
            ManagedFiles       = @($managedFiles)
            ManagedDirectories = @($managedDirectories)
        }
    }
    catch {
        $failure = $_
        foreach ($path in @($paths.Marker, $paths.ArchivePrevious, $paths.ExecutablePrevious)) {
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        if (Test-Path -LiteralPath $paths.ManagedFilesPrevious) {
            Assert-FearSafeStageDirectoryTarget -StageRoot $StageRoot -Path $paths.ManagedFilesPrevious
            [IO.Directory]::Delete($paths.ManagedFilesPrevious, $true)
        }
        throw $failure
    }
}

function Restore-FearRebuiltStageTransition {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)]$Transition
    )

    $manifestPath = Join-Path $StageRoot $StageManifestName
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf) -or
        (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -cne $Transition.OldManifestSha256) {
        throw 'The prior stage manifest changed during the Rebuilt stage transition; automatic rollback was refused.'
    }
    if ([bool]$Transition.ExecutableExisted) {
        if (-not (Test-Path -LiteralPath $Transition.Paths.ExecutablePrevious -PathType Leaf) -or
            (Get-Item -LiteralPath $Transition.Paths.ExecutablePrevious).Length -ne [long]$Transition.ExecutableSize -or
            (Get-FileHash -LiteralPath $Transition.Paths.ExecutablePrevious -Algorithm SHA256).Hash -cne [string]$Transition.ExecutableSha256) {
            throw 'Rebuilt stage transition executable recovery file failed identity verification; automatic rollback was refused.'
        }
    }
    elseif ((Test-Path -LiteralPath $Transition.Paths.ExecutablePrevious) -or
        $Transition.ExecutableSha256 -or [long]$Transition.ExecutableSize -ne 0) {
        throw 'Rebuilt stage transition executable-absence record unexpectedly owns recovery data; automatic rollback was refused.'
    }
    if ([bool]$Transition.ArchiveExisted) {
        if (-not (Test-Path -LiteralPath $Transition.Paths.ArchivePrevious -PathType Leaf) -or
            (Get-Item -LiteralPath $Transition.Paths.ArchivePrevious).Length -ne [long]$Transition.ArchiveSize -or
            (Get-FileHash -LiteralPath $Transition.Paths.ArchivePrevious -Algorithm SHA256).Hash -cne [string]$Transition.ArchiveSha256) {
            throw 'Rebuilt stage transition archive-config recovery file failed identity verification; automatic rollback was refused.'
        }
    }
    elseif ((Test-Path -LiteralPath $Transition.Paths.ArchivePrevious) -or
        $Transition.ArchiveSha256 -or [long]$Transition.ArchiveSize -ne 0) {
        throw 'Rebuilt stage transition archive-config absence record unexpectedly owns recovery data; automatic rollback was refused.'
    }
    if (-not (Test-Path -LiteralPath $Transition.Paths.ManagedFilesPrevious -PathType Container)) {
        throw 'Rebuilt stage transition managed-file recovery directory is missing; automatic rollback was refused.'
    }

    foreach ($record in @($Transition.ManagedFiles)) {
        $targetPath = [IO.Path]::GetFullPath((Join-Path $StageRoot ([string]$record.RelativePath)))
        $targetParent = Split-Path $targetPath -Parent
        if (Test-Path -LiteralPath $targetParent -PathType Container) {
            Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $targetPath
        }
        else {
            Assert-FearNoReparsePathComponents `
                -Root $StageRoot `
                -Path $targetParent `
                -Description 'Rebuilt stage transition rollback file parent'
        }
        if ((Test-Path -LiteralPath $targetPath) -and -not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
            throw "Rebuilt stage transition rollback found an unexpected non-file path: $targetPath"
        }
        if ([bool]$record.Existed) {
            $backupPath = Join-Path $Transition.Paths.ManagedFilesPrevious ([string]$record.BackupName)
            Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $backupPath
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or
                (Get-Item -LiteralPath $backupPath).Length -ne [long]$record.Size -or
                (Get-FileHash -LiteralPath $backupPath -Algorithm SHA256).Hash -cne [string]$record.Sha256) {
                throw "Rebuilt stage transition managed-file recovery identity failed: $($record.RelativePath)"
            }
        }
        elseif ($record.BackupName -or $record.Sha256 -or [long]$record.Size -ne 0) {
            throw "Rebuilt stage transition absence record unexpectedly owns recovery data: $($record.RelativePath)"
        }
    }
    $seenManagedDirectories = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in @($Transition.ManagedDirectories)) {
        $relativePath = [string]$record.RelativePath
        if (-not $relativePath -or [IO.Path]::IsPathRooted($relativePath) -or
            -not $seenManagedDirectories.Add($relativePath)) {
            throw "Rebuilt stage transition contains an invalid or duplicate managed-directory record: $relativePath"
        }
        $targetDirectory = [IO.Path]::GetFullPath((Join-Path $StageRoot $relativePath))
        if (Test-Path -LiteralPath (Split-Path $targetDirectory -Parent) -PathType Container) {
            Assert-FearSafeStageDirectoryTarget -StageRoot $StageRoot -Path $targetDirectory
        }
        else {
            Assert-FearNoReparsePathComponents `
                -Root $StageRoot `
                -Path $targetDirectory `
                -Description 'Rebuilt stage transition rollback managed directory'
        }
        if ((Test-Path -LiteralPath $targetDirectory) -and -not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            throw "Rebuilt stage transition rollback found an unexpected non-directory path: $targetDirectory"
        }
    }

    # Preflight both read-only mounts before restoring any bytes. Rollback must
    # either restore the complete prior state or leave all recovery data intact.
    $retailPath = Join-Path $StageRoot 'Retail'
    $currentRetailItem = Get-Item -LiteralPath $retailPath -Force -ErrorAction SilentlyContinue
    $currentRetailPresent = $null -ne $currentRetailItem
    if ($currentRetailPresent) {
        if (($currentRetailItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or
            -not $currentRetailItem.PSIsContainer -or $currentRetailItem.LinkType -ne 'Junction') {
            throw "Rebuilt stage transition rollback found an unexpected non-junction Retail path: $retailPath"
        }
        $rawRetailTarget = @($currentRetailItem.Target) | Select-Object -First 1
        if (-not $rawRetailTarget) {
            throw "Rebuilt stage transition rollback could not resolve the current Retail target: $retailPath"
        }
        $actualRetailTarget = Get-FearCanonicalPath -Path ([string]$rawRetailTarget) -BasePath $StageRoot
        $allowedRetailTargets = @($Transition.OldRetailTarget, $Transition.DesiredRetailTarget) |
            Where-Object { $_ }
        if (@($allowedRetailTargets | Where-Object {
                    Test-FearPathsEqual -Left $_ -Right $actualRetailTarget
                }).Count -eq 0) {
            throw "Rebuilt stage transition rollback refused an unexpected Retail target: $actualRetailTarget"
        }
    }

    $mountPath = Join-Path $StageRoot 'HDTextures'
    # Test-Path can report a dangling junction as absent when its external target
    # disappears.  Inspect the link object itself so rollback cannot leave an
    # unexpected broken mount behind.
    $currentMountItem = Get-Item -LiteralPath $mountPath -Force -ErrorAction SilentlyContinue
    $currentMountPresent = $null -ne $currentMountItem
    if ($currentMountPresent) {
        $mountItem = $currentMountItem
        if (($mountItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -or
            -not $mountItem.PSIsContainer -or $mountItem.LinkType -ne 'Junction') {
            throw "Rebuilt stage transition rollback found an unexpected non-junction mount path: $mountPath"
        }
        $rawTarget = @($mountItem.Target) | Select-Object -First 1
        if (-not $rawTarget) {
            throw "Rebuilt stage transition rollback could not resolve the current mount target: $mountPath"
        }
        $actualTarget = Get-FearCanonicalPath -Path $rawTarget -BasePath $StageRoot
        $allowedTargets = @($Transition.OldMountTarget, $Transition.DesiredMountTarget) |
            Where-Object { $_ }
        if (@($allowedTargets | Where-Object { Test-FearPathsEqual -Left $_ -Right $actualTarget }).Count -eq 0) {
            throw "Rebuilt stage transition rollback refused an unexpected mount target: $actualTarget"
        }
    }

    $executablePath = Join-Path $StageRoot 'FEAR.exe'
    $archivePath = Join-Path $StageRoot 'Default.archcfg'
    if ([bool]$Transition.ExecutableExisted) {
        Copy-FileToStage `
            -Source $Transition.Paths.ExecutablePrevious `
            -Destination $executablePath `
            -StageRoot $StageRoot
    }
    elseif (Test-Path -LiteralPath $executablePath) {
        Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $executablePath
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
            throw "Rebuilt stage transition rollback found an unexpected non-file executable path: $executablePath"
        }
        Remove-Item -LiteralPath $executablePath -Force
    }
    if ([bool]$Transition.ArchiveExisted) {
        Copy-FileToStage `
            -Source $Transition.Paths.ArchivePrevious `
            -Destination $archivePath `
            -StageRoot $StageRoot
    }
    elseif (Test-Path -LiteralPath $archivePath) {
        Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $archivePath
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
            throw "Rebuilt stage transition rollback found an unexpected non-file archive-config path: $archivePath"
        }
        Remove-Item -LiteralPath $archivePath -Force
    }

    foreach ($record in @($Transition.ManagedFiles)) {
        $targetPath = [IO.Path]::GetFullPath((Join-Path $StageRoot ([string]$record.RelativePath)))
        if ([bool]$record.Existed) {
            Copy-FileToStage `
                -Source (Join-Path $Transition.Paths.ManagedFilesPrevious ([string]$record.BackupName)) `
                -Destination $targetPath `
                -StageRoot $StageRoot
            if ((Get-FileHash -LiteralPath $targetPath -Algorithm SHA256).Hash -cne [string]$record.Sha256) {
                throw "Rebuilt stage transition did not restore a managed file: $($record.RelativePath)"
            }
        }
        elseif (Test-Path -LiteralPath $targetPath) {
            Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $targetPath
            if (-not (Test-Path -LiteralPath $targetPath -PathType Leaf)) {
                throw "Rebuilt stage transition rollback found an unexpected non-file path: $targetPath"
            }
            Remove-Item -LiteralPath $targetPath -Force
        }
    }

    foreach ($record in @($Transition.ManagedDirectories | Where-Object { [bool]$_.Existed })) {
        $targetDirectory = [IO.Path]::GetFullPath((Join-Path $StageRoot ([string]$record.RelativePath)))
        if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container)) {
            Ensure-SafeStageDirectory -Path $targetDirectory -StageRoot $StageRoot
        }
    }
    foreach ($record in @($Transition.ManagedDirectories |
            Where-Object { -not [bool]$_.Existed } |
            Sort-Object { ([string]$_.RelativePath).Length } -Descending)) {
        $targetDirectory = [IO.Path]::GetFullPath((Join-Path $StageRoot ([string]$record.RelativePath)))
        if (Test-Path -LiteralPath $targetDirectory) {
            Assert-FearSafeStageDirectoryTarget -StageRoot $StageRoot -Path $targetDirectory
            if (-not (Test-Path -LiteralPath $targetDirectory -PathType Container) -or
                @(Get-ChildItem -LiteralPath $targetDirectory -Force).Count -ne 0) {
                throw "Rebuilt stage transition cannot remove a newly introduced non-empty or invalid directory: $targetDirectory"
            }
            [IO.Directory]::Delete($targetDirectory, $false)
        }
    }

    if ($Transition.OldRetailTarget) {
        if ($currentRetailPresent) {
            Assert-FearIntentionalRetailJunction -Path $retailPath -Target $Transition.OldRetailTarget
        }
        else {
            Ensure-RetailJunction `
                -Path $retailPath `
                -Target $Transition.OldRetailTarget `
                -StageRoot $StageRoot
        }
    }
    elseif ($currentRetailPresent) {
        [IO.Directory]::Delete($retailPath, $false)
    }

    if ($currentMountPresent) {
        [IO.Directory]::Delete($mountPath, $false)
    }
    if ($Transition.OldMountTarget) {
        Ensure-ReadOnlyStageJunction `
            -Path $mountPath `
            -Target $Transition.OldMountTarget `
            -StageRoot $StageRoot `
            -MountName 'HDTextures'
    }

    if ([bool]$Transition.ExecutableExisted) {
        if (-not (Test-Path -LiteralPath $executablePath -PathType Leaf) -or
            (Get-Item -LiteralPath $executablePath).Length -ne [long]$Transition.ExecutableSize -or
            (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256).Hash -cne [string]$Transition.ExecutableSha256) {
            throw 'Rebuilt stage transition rollback did not restore the prior executable identity.'
        }
    }
    elseif (Test-Path -LiteralPath $executablePath) {
        throw 'Rebuilt stage transition rollback did not restore the prior executable absence.'
    }
    if ([bool]$Transition.ArchiveExisted) {
        if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf) -or
            (Get-Item -LiteralPath $archivePath).Length -ne [long]$Transition.ArchiveSize -or
            (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash -cne [string]$Transition.ArchiveSha256) {
            throw 'Rebuilt stage transition rollback did not restore the prior archive-config identity.'
        }
    }
    elseif (Test-Path -LiteralPath $archivePath) {
        throw 'Rebuilt stage transition rollback did not restore the prior archive-config absence.'
    }
    if ($Transition.OldRetailTarget) {
        Assert-FearIntentionalRetailJunction -Path $retailPath -Target $Transition.OldRetailTarget
    }
    elseif ($null -ne (Get-Item -LiteralPath $retailPath -Force -ErrorAction SilentlyContinue)) {
        throw 'Rebuilt stage transition rollback did not restore the prior Retail-mount absence.'
    }
    if ($Transition.OldMountTarget) {
        Assert-FearIntentionalReadOnlyJunction -Path $mountPath -Target $Transition.OldMountTarget -MountName 'HDTextures'
    }
    elseif ($null -ne (Get-Item -LiteralPath $mountPath -Force -ErrorAction SilentlyContinue)) {
        throw 'Rebuilt stage transition rollback did not restore the prior Off mount state.'
    }

    Complete-FearRebuiltStageTransition -StageRoot $StageRoot -Transition $Transition
}

function Complete-FearRebuiltStageTransition {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)]$Transition
    )

    foreach ($path in @($Transition.Paths.ExecutablePrevious, $Transition.Paths.ArchivePrevious, $Transition.Paths.Marker)) {
        Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $path
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
    Assert-FearSafeStageDirectoryTarget -StageRoot $StageRoot -Path $Transition.Paths.ManagedFilesPrevious
    if (Test-Path -LiteralPath $Transition.Paths.ManagedFilesPrevious) {
        [IO.Directory]::Delete($Transition.Paths.ManagedFilesPrevious, $true)
    }
}

function Write-ArchiveConfig {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StageLane,
        [Parameter(Mandatory = $true)][string[]]$Entries,
        [Parameter(Mandatory = $true)][string]$StageRoot
    )

    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
    $laneNote = if ($StageLane -eq 'StockEchoPatch') {
        '; Lane: StockEchoPatch. Uses untouched retail game modules only.'
    }
    else {
        "; Lane: $StageLane. Uses rebuilt game modules; optional proxies are separately owned by the stage manifest."
    }

    $lines = @(
        '; Generated by FearMore tools/runtime/New-FearRuntimeStage.ps1.',
        $laneNote,
        ''
    ) + $Entries
    [IO.File]::WriteAllLines($Path, $lines, [Text.ASCIIEncoding]::new())
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
}

function Write-StageManifest {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)]$Manifest
    )

    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
    $Manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
    Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $Path
}

function Invoke-TransactionalStageOwnershipCommit {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][bool]$SteamHintShouldExist,
        [Parameter(Mandatory = $true)][string]$AppId
    )

    $manifestPath = Join-Path $StageRoot $StageManifestName
    $steamHintPath = Join-Path $StageRoot $SteamAppIdFileName
    $paths = Get-FearStageOwnershipTransactionPaths `
        -StageRoot $StageRoot `
        -StageManifestName $StageManifestName `
        -SteamAppIdFileName $SteamAppIdFileName
    Assert-FearNoStageOwnershipTransactionFiles `
        -StageRoot $StageRoot `
        -StageManifestName $StageManifestName `
        -SteamAppIdFileName $SteamAppIdFileName

    foreach ($path in @(
        $manifestPath,
        $steamHintPath,
        $paths.ManifestNew,
        $paths.ManifestPrevious,
        $paths.SteamHintNew,
        $paths.SteamHintPrevious
    )) {
        Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $path
    }

    $hadManifest = Test-Path -LiteralPath $manifestPath -PathType Leaf
    $hadSteamHint = Test-Path -LiteralPath $steamHintPath -PathType Leaf
    $manifestMoved = $false
    $steamHintMoved = $false
    $manifestInstalled = $false
    $steamHintInstalled = $false
    $committed = $false

    try {
        if ($SteamHintShouldExist) {
            Write-SteamAppIdHintFile -Path $paths.SteamHintNew -StageRoot $StageRoot -AppId $AppId
        }
        Write-StageManifest -Path $paths.ManifestNew -StageRoot $StageRoot -Manifest $Manifest

        $candidateManifest = Get-Content -LiteralPath $paths.ManifestNew -Raw | ConvertFrom-Json
        if ($SteamHintShouldExist) {
            if ($candidateManifest.SteamAppId -ne $AppId -or
                -not [bool]$candidateManifest.SteamAppIdHintManaged -or
                -not (Test-FearPathsEqual -Left $candidateManifest.SteamAppIdFile -Right $steamHintPath) -or
                $candidateManifest.SteamAppIdFileSha256 -ne $SteamAppIdFileSha256) {
                throw 'Candidate stage manifest does not own the exact Steam App ID hint it is committing.'
            }
        }
        elseif ($candidateManifest.SteamAppId -or $candidateManifest.SteamAppIdFile -or
            [bool]$candidateManifest.SteamAppIdHintManaged -or $candidateManifest.SteamAppIdFileSha256) {
            throw 'Candidate non-Steam stage manifest unexpectedly claims a Steam App ID hint.'
        }

        # Move/install the hint first so a forced manifest failure exercises the
        # exact rollback path that previously left an unowned steam_appid.txt.
        if ($hadSteamHint) {
            [IO.File]::Move($steamHintPath, $paths.SteamHintPrevious)
            $steamHintMoved = $true
        }
        if ($SteamHintShouldExist) {
            [IO.File]::Move($paths.SteamHintNew, $steamHintPath)
            $steamHintInstalled = $true
        }
        if ($hadManifest) {
            [IO.File]::Move($manifestPath, $paths.ManifestPrevious)
            $manifestMoved = $true
        }
        [IO.File]::Move($paths.ManifestNew, $manifestPath)
        $manifestInstalled = $true

        $installedManifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        if ($SteamHintShouldExist) {
            if (-not (Test-Path -LiteralPath $steamHintPath -PathType Leaf) -or
                (Get-FileHash -LiteralPath $steamHintPath -Algorithm SHA256).Hash -ne $SteamAppIdFileSha256 -or
                $installedManifest.SteamAppId -ne $AppId -or
                -not [bool]$installedManifest.SteamAppIdHintManaged -or
                -not (Test-FearPathsEqual -Left $installedManifest.SteamAppIdFile -Right $steamHintPath) -or
                $installedManifest.SteamAppIdFileSha256 -ne $SteamAppIdFileSha256) {
                throw 'Committed Steam hint and stage manifest failed their ownership invariant.'
            }
        }
        elseif ((Test-Path -LiteralPath $steamHintPath) -or $installedManifest.SteamAppId -or
            $installedManifest.SteamAppIdFile -or [bool]$installedManifest.SteamAppIdHintManaged -or
            $installedManifest.SteamAppIdFileSha256) {
            throw 'Committed non-Steam stage unexpectedly retained or claimed a Steam App ID hint.'
        }
        $committed = $true
    }
    catch {
        $failure = $_
        if (-not $committed) {
            if ($manifestInstalled -and (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                Remove-Item -LiteralPath $manifestPath -Force
            }
            if ($manifestMoved -and (Test-Path -LiteralPath $paths.ManifestPrevious -PathType Leaf)) {
                [IO.File]::Move($paths.ManifestPrevious, $manifestPath)
            }
            if ($steamHintInstalled -and (Test-Path -LiteralPath $steamHintPath -PathType Leaf)) {
                Remove-Item -LiteralPath $steamHintPath -Force
            }
            if ($steamHintMoved -and (Test-Path -LiteralPath $paths.SteamHintPrevious -PathType Leaf)) {
                [IO.File]::Move($paths.SteamHintPrevious, $steamHintPath)
            }
            foreach ($path in @($paths.ManifestNew, $paths.SteamHintNew)) {
                if (Test-Path -LiteralPath $path -PathType Leaf) {
                    Remove-Item -LiteralPath $path -Force
                }
            }
        }
        throw $failure
    }

    return $paths
}

function Complete-TransactionalStageOwnershipCommit {
    param(
        [Parameter(Mandatory = $true)][string]$StageRoot,
        [Parameter(Mandatory = $true)]$Paths
    )

    # Cleanup is deliberately separate from the verified commit.  If cleanup
    # fails, callers already know the new manifest is authoritative and must
    # never roll the data files back underneath it.
    foreach ($path in @($Paths.ManifestPrevious, $Paths.SteamHintPrevious)) {
        Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $path
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
        }
    }
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = Get-FearCanonicalPath -Path $RepositoryRoot -BasePath (Get-Location).Path
$runtimeLayout = Resolve-FearRuntimeLayout -SourceRoot $RepositoryRoot
$RepositoryRoot = $runtimeLayout.SourceRoot

$maxFpsExplicit = $PSBoundParameters.ContainsKey('MaxFPS')
$rendererQualityExplicit = $PSBoundParameters.ContainsKey('RendererQuality')
Assert-FearRuntimeStagePackageSelection `
    -Lane $Lane `
    -ControllerArchiveSpecified:$($PSBoundParameters.ContainsKey('ControllerArchive')) `
    -RendererMode $RendererMode `
    -RendererQuality $RendererQuality `
    -RendererQualitySpecified:$rendererQualityExplicit `
    -DgVoodooArchiveSpecified:$($PSBoundParameters.ContainsKey('DgVoodooArchive')) `
    -RtxRemixArchiveSpecified:$($PSBoundParameters.ContainsKey('RtxRemixArchive')) `
    -PostProcessMode $PostProcessMode `
    -ReShadeSetupSpecified:$($PSBoundParameters.ContainsKey('ReShadeSetup')) `
    -EnginePatchMode $EnginePatchMode `
    -EnginePatchPackageRootSpecified:$($PSBoundParameters.ContainsKey('EnginePatchPackageRoot')) `
    -EnginePatchManifestSpecified:$($PSBoundParameters.ContainsKey('EnginePatchManifest')) `
    -MaxFPSExplicit:$maxFpsExplicit

if ($Lane -eq 'SdkSmoke') {
    if (-not $SdkRoot) {
        $SdkRoot = Join-Path $RepositoryRoot 'vendor-local\fear-sdk-108'
    }
    $SdkRoot = Get-FearCanonicalPath -Path $SdkRoot -BasePath $RepositoryRoot
}
elseif ($SdkRoot) {
    $SdkRoot = Get-FearCanonicalPath -Path $SdkRoot -BasePath $RepositoryRoot
}

if (-not $BuildRoot) {
    $BuildRoot = Join-Path $RepositoryRoot "build\fear-win32\bin\$Configuration"
}
$BuildRoot = Get-FearCanonicalPath -Path $BuildRoot -BasePath $RepositoryRoot

if (-not $EchoPatchArchive) {
    $EchoPatchArchive = Join-Path $RepositoryRoot 'vendor-local\EchoPatch-4.2.1.zip'
}
$EchoPatchArchive = Get-FearCanonicalPath -Path $EchoPatchArchive -BasePath $RepositoryRoot

$packagePlan = Resolve-FearRuntimeStagePackagePlan `
    -Lane $Lane `
    -Configuration $Configuration `
    -RepositoryRoot $RepositoryRoot `
    -RuntimeToolsRoot $PSScriptRoot `
    -ControllerArchive $ControllerArchive `
    -ControllerArchiveSpecified:$($PSBoundParameters.ContainsKey('ControllerArchive')) `
    -RendererMode $RendererMode `
    -RendererQuality $RendererQuality `
    -RendererQualitySpecified:$rendererQualityExplicit `
    -DgVoodooArchive $DgVoodooArchive `
    -DgVoodooArchiveSpecified:$($PSBoundParameters.ContainsKey('DgVoodooArchive')) `
    -RtxRemixArchive $RtxRemixArchive `
    -RtxRemixArchiveSpecified:$($PSBoundParameters.ContainsKey('RtxRemixArchive')) `
    -PostProcessMode $PostProcessMode `
    -ReShadeSetup $ReShadeSetup `
    -ReShadeSetupSpecified:$($PSBoundParameters.ContainsKey('ReShadeSetup')) `
    -EnginePatchMode $EnginePatchMode `
    -EnginePatchPackageRoot $EnginePatchPackageRoot `
    -EnginePatchPackageRootSpecified:$($PSBoundParameters.ContainsKey('EnginePatchPackageRoot')) `
    -EnginePatchManifest $EnginePatchManifest `
    -EnginePatchManifestSpecified:$($PSBoundParameters.ContainsKey('EnginePatchManifest')) `
    -MaxFPS $MaxFPS `
    -MaxFPSExplicit:$maxFpsExplicit

$DgVoodooArchive = $packagePlan.DgVoodooArchive
$RtxRemixArchive = $packagePlan.RtxRemixArchive
$ControllerArchive = $packagePlan.ControllerArchive
$ReShadeSetup = $packagePlan.PostProcessSetup
$rendererConfigSource = $packagePlan.RendererConfigSource
$rendererRuntimeConfigSeedSource = $packagePlan.RendererRuntimeConfigSeedSource
$EnginePatchPackageRoot = $packagePlan.EnginePatchPackageRoot
$EnginePatchManifest = $packagePlan.EnginePatchManifest

$localRuntimeRoot = $runtimeLayout.RuntimeRoot
if (-not $StageRoot) {
    $StageRoot = Join-Path $localRuntimeRoot $packagePlan.DefaultStageDirectoryName
}
$StageRoot = Get-FearCanonicalPath -Path $StageRoot -BasePath $runtimeLayout.RelativeStageBase
if (-not (Test-FearPathIsBelow -Path $StageRoot -Parent $localRuntimeRoot)) {
    throw "StageRoot must be a child of the FearMore writable runtime directory: $localRuntimeRoot"
}

if ($Launch -and $ValidateOnly) {
    throw '-Launch cannot be combined with -ValidateOnly.'
}
if ($Launch -and $Lane -eq 'SdkSmoke') {
    throw 'SdkSmoke is never launch-permitted: Public Tools does not redistribute the matching retail bootstrap DLL set. Use -Lane Rebuilt with a user-owned v1.08 retail root for runtime testing.'
}
if ($Lane -ne 'StockEchoPatch' -and $PSBoundParameters.ContainsKey('SSAAScale')) {
    throw '-SSAAScale is supported only by -Lane StockEchoPatch. The engine-only rebuilt profile deliberately leaves supersampling disabled.'
}
if ($RefreshRuntimeExecutable -and $Lane -ne 'StockEchoPatch') {
    throw '-RefreshRuntimeExecutable is supported only by -Lane StockEchoPatch.'
}
if ($RefreshRuntimeExecutable -and $ValidateOnly) {
    throw '-RefreshRuntimeExecutable cannot be combined with -ValidateOnly.'
}
if ($HdTextureMode -ne 'Off' -and $Lane -ne 'Rebuilt') {
    throw '-HdTextureMode Lite or Full is supported only by -Lane Rebuilt.'
}
if ($HdTextureMode -eq 'Off' -and (
        $PSBoundParameters.ContainsKey('HdTexturePackRoot') -or
        $PSBoundParameters.ContainsKey('HdTextureLaaExecutable') -or
        $PSBoundParameters.ContainsKey('HdTextureLaaBackup'))) {
    throw '-HdTexturePackRoot and HD-texture LAA inputs require -HdTextureMode Lite or Full.'
}
if ($HdTextureMode -ne 'Off' -and -not $HdTexturePackRoot) {
    throw '-HdTextureMode Lite or Full requires a locally registered or explicit -HdTexturePackRoot.'
}
if ($PSBoundParameters.ContainsKey('HdTextureLaaExecutable') -xor
    $PSBoundParameters.ContainsKey('HdTextureLaaBackup')) {
    throw '-HdTextureLaaExecutable and -HdTextureLaaBackup must be supplied together.'
}

$userDirectory = if ($Lane -ne 'SdkSmoke') {
    [IO.Path]::GetFullPath((Join-Path $StageRoot 'UserDirectory'))
}
else {
    $null
}
$additionalLaunchArguments = if ($null -ne $LaunchArguments) {
    @($LaunchArguments)
}
else {
    @()
}
if ($userDirectory) {
    foreach ($argument in $additionalLaunchArguments) {
        if ($argument -imatch '^(?:\+UserDirectory|-userdirectory|UserDirectory)(?:=|$)') {
            throw "LaunchArguments must not override the lane-isolated -userdirectory path: $userDirectory"
        }
        if ($argument -imatch '^\+FearMoreHDTexturesActive(?:=|$)') {
            throw 'LaunchArguments must not override the launcher-owned FearMoreHDTexturesActive state.'
        }
        if ($argument -imatch '^\+FearMoreCameraDiagnostics(?:=|$)') {
            throw 'LaunchArguments must not override the launcher-owned FearMoreCameraDiagnostics state.'
        }
    }
    # The engine-level dash switch is consumed during startup, before the game
    # shell can touch the default Public Documents profile/save root. A
    # +UserDirectory console variable is applied too late for that guarantee.
    $hdTextureActivityArguments = if ($HdTextureMode -ne 'Off') {
        @('+FearMoreHDTexturesActive', $(if ($HdTextureMode -eq 'Lite') { '1' } else { '2' }))
    }
    else {
        @()
    }
    $cameraDiagnosticArguments = if ($EnginePatchMode -in @('CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')) {
        @('+FearMoreCameraDiagnostics', '1')
    }
    else {
        @()
    }
    $effectiveLaunchArguments = @('-userdirectory', $userDirectory, '-archcfg', 'Default.archcfg') +
        $hdTextureActivityArguments + $cameraDiagnosticArguments + $additionalLaunchArguments
}
else {
    $effectiveLaunchArguments = @()
}
$launchArgumentString = Join-WindowsCommandLineArguments -Arguments $effectiveLaunchArguments

$resolvedRetailRoot = $null
$retailEntries = @()
$sdkIdentity = $null
$rebuiltModules = @()
$echoPatchHash = $null
$runtimeExecutableName = $null
$runtimeExecutableState = $null
$bootstrapRequired = $false
$runtimeExecutableSha256 = $null
$retailExecutableSha256 = $null
$runtimeExecutableBackupSha256 = $null
$steamAppIdFile = $null
$isSteamRetail = $false
$rendererPackageIdentity = $null
$rendererConfigIdentity = $null
$rendererRuntimeConfigSeedIdentity = $null
$rendererRuntimeConfigSeedApplied = $false
$postProcessPackageIdentity = $null
$postProcessStagePayload = $null
$stagedPostProcessProxyIdentity = $null
$stagedPostProcessOwnedFiles = @()
$postProcessSeedAppliedFiles = @()
$postProcessEverEnabled = $false
$postProcessFirstEnable = $false
$controllerPackageIdentity = $null
$stagedControllerRuntimeIdentity = $null
$stagedControllerLicenseIdentity = $null
$enginePatchPackageIdentity = $null
$stagedRendererProxyIdentity = $null
$stagedRendererConfigIdentity = $null
$stagedRendererOwnedFiles = @()
$rendererRuntimeWritableDirectories = @($packagePlan.RendererRuntimeWritableDirectories)
$rendererRuntimeMutableFiles = @($packagePlan.RendererRuntimeMutableFiles)
$stagedEnginePatchProxyIdentity = $null
$stagedEnginePatchConfigIdentity = $null
$effectiveMaxFPS = $packagePlan.MaxFPS
$effectiveDynamicVsync = $packagePlan.DynamicVsync
$hdTexturePackageIdentity = $null
$hdTextureLaaIdentity = $null
$existingHdTextureMount = $null
$desiredHdTextureMounts = @()

if ($Lane -ne 'SdkSmoke') {
    $resolvedRetailRoot = Resolve-FearRetailRoot -RequestedRoot $RetailRoot -BasePath $RepositoryRoot
    Assert-FileVersion -Path (Join-Path $resolvedRetailRoot 'FEAR.exe') -ExpectedVersion $ExpectedFearVersion -Description 'Retail FEAR.exe' | Out-Null
    $retailInputIdentity = Get-FearPeRuntimeIdentity -Path (Join-Path $resolvedRetailRoot 'FEAR.exe')
    if (-not (Test-FearX86Pe32Identity -Identity $retailInputIdentity)) {
        throw "Retail FEAR.exe is not a 32-bit x86 PE image (machine 0x014C, PE32 magic 0x010B required): $(Join-Path $resolvedRetailRoot 'FEAR.exe')"
    }
    $isSteamRetail = Test-FearSteamRetailInstallation -RetailRoot $resolvedRetailRoot -AppId $SteamAppId
    $retailEntries = @(Get-RetailArchiveEntries -Root $resolvedRetailRoot)
}

if ($HdTextureMode -ne 'Off') {
    $HdTexturePackRoot = Get-FearCanonicalPath -Path $HdTexturePackRoot -BasePath $RepositoryRoot
    $hdTexturePackageIdentity = Get-FearHdTexturePackageIdentity `
        -PackageRoot $HdTexturePackRoot `
        -RequireKnownMode $HdTextureMode

    if (-not $HdTextureLaaExecutable) {
        $HdTextureLaaExecutable = Join-Path $runtimeLayout.RuntimeRoot 'fearmore-stock-echopatch\FEAR.exe'
        $HdTextureLaaBackup = Join-Path $runtimeLayout.RuntimeRoot 'fearmore-stock-echopatch\FEAR.exe.bak'
    }
    $HdTextureLaaExecutable = Get-FearCanonicalPath -Path $HdTextureLaaExecutable -BasePath $RepositoryRoot
    $HdTextureLaaBackup = Get-FearCanonicalPath -Path $HdTextureLaaBackup -BasePath $RepositoryRoot
    $hdTextureLaaIdentity = Get-FearAttestedLaaRuntimeExecutablePairIdentity `
        -RetailExecutable (Join-Path $resolvedRetailRoot 'FEAR.exe') `
        -PatchedExecutable $HdTextureLaaExecutable `
        -BackupExecutable $HdTextureLaaBackup
    $desiredHdTextureMounts = @([pscustomobject]@{
        Name   = 'HDTextures'
        Target = $hdTexturePackageIdentity.ContentRoot
    })
}

if ($Lane -in @('Rebuilt', 'SdkSmoke')) {
    if ($Lane -eq 'SdkSmoke') {
        $sdkIdentity = Assert-SdkRoot -Root $SdkRoot
        $sdkInputIdentity = Get-FearPeRuntimeIdentity -Path $sdkIdentity.RuntimeExe
        if (-not (Test-FearX86Pe32Identity -Identity $sdkInputIdentity)) {
            throw "Public Tools FEARDevSP.exe is not a 32-bit x86 PE image (machine 0x014C, PE32 magic 0x010B required): $($sdkIdentity.RuntimeExe)"
        }
    }
    $rebuiltModules = @(Assert-GameModules -ModuleRoot $BuildRoot)
    Assert-SystemDependency -Name 'd3dx9_27.dll' | Out-Null
    if ($Configuration -eq 'Debug') {
        Assert-SystemDependency -Name 'msvcp140d.dll' | Out-Null
        Assert-SystemDependency -Name 'vcruntime140d.dll' | Out-Null
        Assert-SystemDependency -Name 'ucrtbased.dll' | Out-Null
    }
    else {
        Assert-SystemDependency -Name 'msvcp140.dll' | Out-Null
        Assert-SystemDependency -Name 'vcruntime140.dll' | Out-Null
        Assert-SystemDependency -Name 'ucrtbase.dll' | Out-Null
    }
    if ($Lane -eq 'Rebuilt') {
        Assert-RetailBootstrapFiles -Root $resolvedRetailRoot -IncludeRetailExecutable | Out-Null
        $runtimeExecutableName = 'FEAR.exe'
    }
    else {
        $runtimeExecutableName = 'FEARDevSP.exe'
    }
}
else {
    Assert-RetailBootstrapFiles -Root $resolvedRetailRoot -IncludeRetailExecutable | Out-Null
    $echoPatchHash = Assert-EchoPatchArchive -Path $EchoPatchArchive
    $runtimeExecutableName = 'FEAR.exe'
}

$packageIdentities = Get-FearRuntimeStagePackageIdentities `
    -RendererMode $RendererMode `
    -RendererQuality $RendererQuality `
    -DgVoodooArchive $DgVoodooArchive `
    -RtxRemixArchive $RtxRemixArchive `
    -RendererConfigSource $rendererConfigSource `
    -RendererRuntimeConfigSeedSource $rendererRuntimeConfigSeedSource `
    -PostProcessMode $PostProcessMode `
    -PostProcessSetup $ReShadeSetup `
    -PostProcessAssetRoot $packagePlan.PostProcessAssetRoot `
    -ControllerArchive $ControllerArchive `
    -EnginePatchMode $EnginePatchMode `
    -EnginePatchPackageRoot $EnginePatchPackageRoot `
    -EnginePatchManifest $EnginePatchManifest
$rendererPackageIdentity = $packageIdentities.RendererPackageIdentity
$rendererConfigIdentity = $packageIdentities.RendererConfigIdentity
$rendererRuntimeConfigSeedIdentity = $packageIdentities.RendererRuntimeConfigSeedIdentity
$postProcessPackageIdentity = $packageIdentities.PostProcessPackageIdentity
$postProcessStagePayload = $packageIdentities.PostProcessStagePayload
$controllerPackageIdentity = $packageIdentities.ControllerPackageIdentity
$enginePatchPackageIdentity = $packageIdentities.EnginePatchPackageIdentity

$validationResult = [pscustomobject]@{
    Lane                 = $Lane
    Configuration        = $Configuration
    RendererMode         = $RendererMode
    RendererQuality      = $packagePlan.RendererQuality
    RendererPackage      = if ($rendererPackageIdentity) { $rendererPackageIdentity.ArchivePath } else { $null }
    RendererPackageVersion = if ($rendererPackageIdentity) { $rendererPackageIdentity.Version } else { $null }
    RendererPackageSize  = if ($rendererPackageIdentity) { $rendererPackageIdentity.ArchiveSize } else { $null }
    RendererPackageSha256 = if ($rendererPackageIdentity) { $rendererPackageIdentity.ArchiveSha256 } else { $null }
    RendererConfig       = if ($rendererConfigIdentity) { $rendererConfigIdentity.Path } else { $null }
    RendererConfigSha256 = if ($rendererConfigIdentity) { $rendererConfigIdentity.Sha256 } else { $null }
    RendererOutputAPI    = if ($rendererConfigIdentity -and $rendererConfigIdentity.PSObject.Properties['OutputAPI']) { $rendererConfigIdentity.OutputAPI } else { $null }
    RendererResolution   = if ($RendererMode -eq 'DgVoodooD3D11') { $rendererConfigIdentity.Resolution } else { $null }
    RendererScalingMode  = if ($RendererMode -eq 'DgVoodooD3D11') { $rendererConfigIdentity.ScalingMode } else { $null }
    RendererResampling   = if ($RendererMode -eq 'DgVoodooD3D11') { $rendererConfigIdentity.Resampling } else { $null }
    RendererFiltering    = if ($RendererMode -eq 'DgVoodooD3D11') { $rendererConfigIdentity.Filtering } else { $null }
    RendererAntialiasing = if ($RendererMode -eq 'DgVoodooD3D11') { $rendererConfigIdentity.Antialiasing } else { $null }
    RendererVRAM         = if ($RendererMode -eq 'DgVoodooD3D11') { $rendererConfigIdentity.VRAM } else { $null }
    RendererFPSLimit     = if ($RendererMode -eq 'DgVoodooD3D11') { $rendererConfigIdentity.FPSLimit } else { $null }
    RendererForceVerticalSync = if ($RendererMode -eq 'DgVoodooD3D11') { $rendererConfigIdentity.ForceVerticalSync } else { $null }
    RendererExperimental = $packagePlan.RendererExperimental
    RendererCompatibilityStatus = $packagePlan.RendererCompatibilityStatus
    RendererPackageFileCount = if ($RendererMode -eq 'RtxRemixProbe') { $rendererPackageIdentity.ArchiveFileCount } else { $null }
    RendererOwnedFiles   = @()
    RendererRuntimeWritableDirectories = @($rendererRuntimeWritableDirectories)
    RendererRuntimeMutableFiles = @($rendererRuntimeMutableFiles)
    RendererRuntimeConfigSeedSource = if ($rendererRuntimeConfigSeedIdentity) { $rendererRuntimeConfigSeedIdentity.Path } else { $null }
    RendererRuntimeConfigSeedSha256 = if ($rendererRuntimeConfigSeedIdentity) { $rendererRuntimeConfigSeedIdentity.Sha256 } else { $null }
    RendererRuntimeConfigSeedPolicy = if ($rendererRuntimeConfigSeedIdentity) { 'NewStageOnly' } else { $null }
    RendererRuntimeConfigSeedApplied = $false
    RendererRuntimeConfigSeedBackend = if ($rendererRuntimeConfigSeedIdentity) { $rendererRuntimeConfigSeedIdentity.IndirectLightingBackend } else { $null }
    RendererRuntimeConfigSeedDlssFrameGenerationEnabled = if ($rendererRuntimeConfigSeedIdentity) { [bool]$rendererRuntimeConfigSeedIdentity.DlssFrameGenerationEnabled } else { $null }
    ControllerRuntime      = if ($controllerPackageIdentity) { $controllerPackageIdentity.RuntimeFileName } else { $null }
    ControllerPackage     = if ($controllerPackageIdentity) { $controllerPackageIdentity.ArchivePath } else { $null }
    ControllerPackageVersion = if ($controllerPackageIdentity) { $controllerPackageIdentity.Version } else { $null }
    ControllerPackageSize = if ($controllerPackageIdentity) { $controllerPackageIdentity.ArchiveSize } else { $null }
    ControllerPackageSha256 = if ($controllerPackageIdentity) { $controllerPackageIdentity.ArchiveSha256 } else { $null }
    ControllerRuntimeFile = if ($controllerPackageIdentity) { $controllerPackageIdentity.RuntimeFileName } else { $null }
    ControllerRuntimeSize = if ($controllerPackageIdentity) { $controllerPackageIdentity.RuntimeSize } else { $null }
    ControllerRuntimeSha256 = if ($controllerPackageIdentity) { $controllerPackageIdentity.RuntimeSha256 } else { $null }
    ControllerRuntimeArchitecture = if ($controllerPackageIdentity) { $controllerPackageIdentity.RuntimeArchitecture } else { $null }
    ControllerLicense     = if ($controllerPackageIdentity) { $controllerPackageIdentity.License } else { $null }
    ControllerLicenseFile = if ($controllerPackageIdentity) { $controllerPackageIdentity.LicenseStagePath } else { $null }
    ControllerLicenseSize = if ($controllerPackageIdentity) { $controllerPackageIdentity.LicenseSize } else { $null }
    ControllerLicenseSha256 = if ($controllerPackageIdentity) { $controllerPackageIdentity.LicenseSha256 } else { $null }
    ControllerAcceptanceTested = $false
    PostProcessMode       = $PostProcessMode
    PostProcessPackage    = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.SetupPath } else { $null }
    PostProcessPackageVersion = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.ReShadeVersion } else { $null }
    PostProcessPackageSize = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.SetupSize } else { $null }
    PostProcessPackageSha256 = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.SetupSha256 } else { $null }
    PostProcessProxyFile  = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.ProxyFileName } else { $null }
    PostProcessProxySize  = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.ProxySize } else { $null }
    PostProcessProxySha256 = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.ProxySha256 } else { $null }
    PostProcessProxyApi   = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.ProxyApi } else { $null }
    PostProcessOwnedFiles = @()
    PostProcessAssetRoot  = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.Assets.Root } else { $null }
    PostProcessRuntimeMutableFiles = @($packagePlan.PostProcessRuntimeMutableFiles)
    PostProcessRuntimeWritableDirectories = @($packagePlan.PostProcessRuntimeWritableDirectories)
    PostProcessConfigSeedPolicy = 'FirstEnableOnly'
    PostProcessConfigSeedApplied = $false
    PostProcessConfigSeedAppliedFiles = @()
    PostProcessEverEnabled = $null
    PostProcessDefaultSharpness = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.Assets.DefaultSharpness } else { $null }
    PostProcessColorOnly  = if ($postProcessPackageIdentity) { [bool]$postProcessPackageIdentity.Assets.ColorOnly } else { $null }
    PostProcessUsesDepth  = if ($postProcessPackageIdentity) { [bool]$postProcessPackageIdentity.Assets.UsesDepth } else { $null }
    PostProcessPerformsScaling = if ($postProcessPackageIdentity) { [bool]$postProcessPackageIdentity.Assets.PerformsScaling } else { $null }
    PostProcessExperimental = $packagePlan.PostProcessExperimental
    PostProcessCompatibilityStatus = $packagePlan.PostProcessCompatibilityStatus
    PostProcessAcceptanceTested = $false
    EnginePatchMode      = $EnginePatchMode
    EnginePatchPackage   = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.PackageRoot } else { $null }
    EnginePatchManifest  = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.ManifestPath } else { $null }
    EnginePatchManifestSha256 = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.ManifestSha256 } else { $null }
    EnginePatchProxySha256 = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.BinarySha256 } else { $null }
    EnginePatchForceWindowed = if ($enginePatchPackageIdentity) { [bool]$packagePlan.EnginePatchForceWindowed } else { $null }
    EnginePatchFixWindowStyle = if ($enginePatchPackageIdentity) { [bool]$packagePlan.EnginePatchFixWindowStyle } else { $null }
    HdTextureMode         = $HdTextureMode
    HdTexturePackageRoot  = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.PackageRoot } else { $null }
    HdTextureContentRoot  = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.ContentRoot } else { $null }
    HdTextureFileCount    = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.FileCount } else { $null }
    HdTextureTotalBytes   = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.TotalBytes } else { $null }
    HdTextureManifestSha256 = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.ManifestSha256 } else { $null }
    HdTextureLaaExecutableSha256 = if ($hdTextureLaaIdentity) { $hdTextureLaaIdentity.PatchedExecutableSha256 } else { $null }
    MaxFPS               = $effectiveMaxFPS
    MaxFPSExplicit       = $maxFpsExplicit
    DynamicVsync         = $effectiveDynamicVsync
    StageRoot            = $StageRoot
    RetailRoot           = $resolvedRetailRoot
    RetailVersion        = if ($resolvedRetailRoot) { $ExpectedFearVersion } else { $null }
    PublicToolsRoot      = if ($sdkIdentity) { $SdkRoot } else { $null }
    EchoPatchArchive     = if ($Lane -eq 'StockEchoPatch') { $EchoPatchArchive } else { $null }
    EchoPatchSha256      = $echoPatchHash
    SSAAScale            = if ($Lane -eq 'StockEchoPatch') { $SSAAScale } else { $null }
    RuntimeExecutable    = $runtimeExecutableName
    RuntimeExecutableState = 'NotStaged'
    BootstrapRequired    = $null
    BootstrapNote        = $null
    RuntimeExecutableSha256 = $null
    RetailExecutableSha256 = if ($resolvedRetailRoot) { (Get-FileHash -LiteralPath (Join-Path $resolvedRetailRoot 'FEAR.exe') -Algorithm SHA256).Hash } else { $null }
    RuntimeExecutableBackupSha256 = $null
    SteamAppId           = if ($isSteamRetail) { $SteamAppId } else { $null }
    SteamAppIdFile       = $null
    SteamAppIdHintManaged = $false
    SteamAppIdFileSha256 = $null
    UserDirectory        = $userDirectory
    SaveIsolation        = [bool]$userDirectory
    LaunchArguments      = @($effectiveLaunchArguments)
    LaunchArgumentString = $launchArgumentString
    InputsValidated      = $true
    LayoutValidated      = $false
    LaunchPermitted      = $false
    AcceptanceTested     = $false
    ValidationOnly       = [bool]$ValidateOnly
}

Assert-FearNoReparsePathComponents -Root $localRuntimeRoot -Path $StageRoot -Description 'local-runtime to StageRoot path'
if ($ValidateOnly) {
    $validationResult
    return
}

Assert-FearNoStageOwnershipTransactionFiles `
    -StageRoot $StageRoot `
    -StageManifestName $StageManifestName `
    -SteamAppIdFileName $SteamAppIdFileName
Assert-NoFearRebuiltStageTransitionFiles -StageRoot $StageRoot
$existingStageManifest = Assert-FearOwnedStage `
    -Root $StageRoot `
    -ExpectedLane $Lane `
    -ExpectedRendererMode $RendererMode `
    -ExpectedEnginePatchMode $EnginePatchMode `
    -StageManifestName $StageManifestName
$existingRetailRootProperty = if ($existingStageManifest) { $existingStageManifest.PSObject.Properties['RetailRoot'] } else { $null }
$existingRetailMountRequired = $existingStageManifest -and $resolvedRetailRoot -and
    $existingRetailRootProperty -and -not [string]::IsNullOrWhiteSpace([string]$existingRetailRootProperty.Value)
if ($existingRetailMountRequired) {
    # A completed owned retail-backed stage must retain its manifest-owned base
    # mount. Recreating a missing Retail junction inside a Rebuilt-stage transition
    # would otherwise add state that the rollback journal does not own. Minimal
    # legacy ownership manifests without RetailRoot keep their narrow migration.
    Assert-FearIntentionalRetailJunction `
        -Path (Join-Path $StageRoot 'Retail') `
        -Target $resolvedRetailRoot
}
$existingHdTextureMount = Get-ExistingHdTextureMountDeclaration -Manifest $existingStageManifest
if ($existingHdTextureMount) {
    Assert-FearIntentionalReadOnlyJunction `
        -Path (Join-Path $StageRoot 'HDTextures') `
        -Target $existingHdTextureMount.Target `
        -MountName 'HDTextures'
}
Assert-FearStageTreeNoUnexpectedReparsePoints `
    -StageRoot $StageRoot `
    -RetailTarget $resolvedRetailRoot `
    -AuthorizedMounts @($existingHdTextureMount)
Assert-FearStageProxyOwnership `
    -Root $StageRoot `
    -StageLane $Lane `
    -PackagePlan $packagePlan `
    -RendererPackageIdentity $rendererPackageIdentity `
    -RendererConfigIdentity $rendererConfigIdentity `
    -EnginePatchPackageIdentity $enginePatchPackageIdentity `
    -ExistingManifest $existingStageManifest
$postProcessOwnership = Assert-FearStagePostProcessOwnership `
    -Root $StageRoot `
    -PackagePlan $packagePlan `
    -ExpectedPackageIdentity $postProcessPackageIdentity `
    -ExistingManifest $existingStageManifest
$postProcessEverEnabled = [bool]$postProcessOwnership.EverEnabled
$postProcessFirstEnable = [bool]$postProcessOwnership.FirstEnable
Assert-FearStageControllerOwnership `
    -Root $StageRoot `
    -StageLane $Lane `
    -ExpectedPackageIdentity $controllerPackageIdentity `
    -ExistingManifest $existingStageManifest | Out-Null
if ($Lane -eq 'Rebuilt' -and $existingStageManifest) {
    Assert-FearStageRuntimeExecutableOwnership `
        -Root $StageRoot `
        -Manifest $existingStageManifest `
        -ExpectedExecutableName 'FEAR.exe'
}
if ($Lane -eq 'StockEchoPatch') {
    Assert-NoRuntimeRefreshTransactionFiles -StageRoot $StageRoot
}
$steamAppIdHintPlan = Get-FearSteamAppIdHintPlan `
    -StageRoot $StageRoot `
    -ExistingManifest $existingStageManifest `
    -ShouldExist:$isSteamRetail `
    -AppId $SteamAppId `
    -SteamAppIdFileName $SteamAppIdFileName `
    -ExpectedSha256 $SteamAppIdFileSha256
if ($Lane -eq 'StockEchoPatch') {
    $stockRuntimePreflight = Get-FearStockRuntimeExecutableAssessment `
        -RetailExecutable (Join-Path $resolvedRetailRoot 'FEAR.exe') `
        -StageRoot $StageRoot
    if ($stockRuntimePreflight.State -eq 'Unknown' -and -not $RefreshRuntimeExecutable) {
        throw "Stock EchoPatch stage contains an unknown FEAR.exe derivative. No stage files were changed. Inspect it manually or use -RefreshRuntimeExecutable to replace the ordinary stage-local executable pair: $(Join-Path $StageRoot 'FEAR.exe')"
    }
}

# Single filesystem-mutation authorization boundary. Planning and ownership
# modules are read-only; every stage write, extraction, removal, junction, and
# process launch remains in this orchestrator after this gate.
$WhatIfPreference = $stageWhatIfPreference
if (-not $PSCmdlet.ShouldProcess($StageRoot, "Create or update the disposable FearMore '$Lane' runtime stage")) {
    $validationResult
    return
}

Assert-FearNoReparsePathComponents -Root $localRuntimeRoot -Path $StageRoot -Description 'local-runtime to StageRoot path'
if ($existingRetailMountRequired) {
    # Repeat immediately after authorization to close the preflight/mutation
    # window for an existing stage.
    Assert-FearIntentionalRetailJunction `
        -Path (Join-Path $StageRoot 'Retail') `
        -Target $resolvedRetailRoot
}
Assert-FearStageTreeNoUnexpectedReparsePoints `
    -StageRoot $StageRoot `
    -RetailTarget $resolvedRetailRoot `
    -AuthorizedMounts @($existingHdTextureMount)
$postProcessOwnership = Assert-FearStagePostProcessOwnership `
    -Root $StageRoot `
    -PackagePlan $packagePlan `
    -ExpectedPackageIdentity $postProcessPackageIdentity `
    -ExistingManifest $existingStageManifest
$postProcessEverEnabled = [bool]$postProcessOwnership.EverEnabled
$postProcessFirstEnable = [bool]$postProcessOwnership.FirstEnable
Assert-FearStageControllerOwnership `
    -Root $StageRoot `
    -StageLane $Lane `
    -ExpectedPackageIdentity $controllerPackageIdentity `
    -ExistingManifest $existingStageManifest | Out-Null
if (-not (Test-Path -LiteralPath $localRuntimeRoot)) {
    New-Item -ItemType Directory -Path $localRuntimeRoot | Out-Null
}
Assert-FearNoReparsePathComponents -Root $localRuntimeRoot -Path $localRuntimeRoot -RequirePath -Description 'local-runtime root'
if (-not (Test-Path -LiteralPath $StageRoot)) {
    New-Item -ItemType Directory -Path $StageRoot -Force | Out-Null
}
Assert-FearNoReparsePathComponents -Root $localRuntimeRoot -Path $StageRoot -RequirePath -Description 'local-runtime to StageRoot path'
Assert-FearStageTreeNoUnexpectedReparsePoints `
    -StageRoot $StageRoot `
    -RetailTarget $resolvedRetailRoot `
    -AuthorizedMounts @($existingHdTextureMount)
$rebuiltStageTransition = $null
$stageOwnershipCommitted = $false
try {
if ($existingStageManifest -and $Lane -eq 'Rebuilt') {
    # Immutable payloads are rewritten/removed on restage. Runtime config seeds
    # are journaled only on first enable, because later edits belong to ReShade
    # or the user and must never be rolled back by an unrelated stage failure.
    $postProcessTransitionFiles = @($packagePlan.PostProcessImmutableFiles)
    if ($postProcessFirstEnable) {
        $postProcessTransitionFiles += @($packagePlan.PostProcessSeedFiles | ForEach-Object {
            [string]$_.TargetRelativePath
        })
    }
    $rebuiltTransitionDirectories = @(
        'Game',
        'UserDirectory'
    ) + @($packagePlan.PostProcessManagedDirectories) +
        @($packagePlan.ControllerManagedDirectories) +
        @($packagePlan.RendererRequiredDirectories) +
        @($packagePlan.RendererRuntimeWritableDirectories)
    $rebuiltTransitionDirectories = @($rebuiltTransitionDirectories | Sort-Object -Unique)
    $rebuiltMutationRelativePaths = Get-FearRebuiltStageMutationRelativePaths `
        -RendererMode $RendererMode `
        -RendererPackageIdentity $rendererPackageIdentity `
        -RendererConfigFile $packagePlan.RendererConfigFile `
        -EnginePatchMode $EnginePatchMode `
        -PostProcessManagedFiles @($postProcessTransitionFiles) `
        -ControllerManagedFiles @($packagePlan.ControllerManagedFiles) `
        -GameModuleNames $GameModuleNames
    $rebuiltStageTransition = Start-FearRebuiltStageTransition `
        -StageRoot $StageRoot `
        -ExistingManifest $existingStageManifest `
        -DesiredRetailTarget $resolvedRetailRoot `
        -ExistingMount $existingHdTextureMount `
        -DesiredMountTarget $(if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.ContentRoot } else { $null }) `
        -ManagedRelativePaths $rebuiltMutationRelativePaths `
        -ManagedRelativeDirectories @($rebuiltTransitionDirectories)
}
if ($Lane -eq 'Rebuilt') {
    Remove-ObsoleteRebuiltSdkFiles -Root $StageRoot
}
if ($userDirectory) {
    Ensure-StageUserDirectory -Path $userDirectory -StageRoot $StageRoot
}

$archiveEntries = @()
if ($resolvedRetailRoot) {
    Ensure-RetailJunction -Path (Join-Path $StageRoot 'Retail') -Target $resolvedRetailRoot -StageRoot $StageRoot
    $archiveEntries += $retailEntries
}
Sync-HdTextureJunction `
    -StageRoot $StageRoot `
    -ExistingMount $existingHdTextureMount `
    -DesiredTarget $(if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.ContentRoot } else { $null })

if ($Lane -in @('Rebuilt', 'SdkSmoke')) {
    $unexpectedDinput = Join-Path $StageRoot 'dinput8.dll'
    if ($EnginePatchMode -eq 'None' -and (Test-Path -LiteralPath $unexpectedDinput -PathType Leaf)) {
        throw "Rebuilt-module stages must not contain EchoPatch or another dinput8 proxy: $unexpectedDinput"
    }

    if ($Lane -eq 'SdkSmoke') {
        Copy-FileToStage -Source $sdkIdentity.RuntimeExe -Destination (Join-Path $StageRoot 'FEARDevSP.exe') -StageRoot $StageRoot
        foreach ($sdkRuntimeFile in @('AssertWin32DLL.dll', 'FEAR.proj00')) {
            $sourcePath = Join-Path $SdkRoot "Runtime\$sdkRuntimeFile"
            if (Test-Path -LiteralPath $sourcePath -PathType Leaf) {
                Copy-FileToStage -Source $sourcePath -Destination (Join-Path $StageRoot $sdkRuntimeFile) -StageRoot $StageRoot
            }
        }
        Copy-FileToStage -Source $sdkIdentity.Msvcp71 -Destination (Join-Path $StageRoot 'msvcp71.dll') -StageRoot $StageRoot
        Copy-FileToStage -Source $sdkIdentity.Msvcr71 -Destination (Join-Path $StageRoot 'msvcr71.dll') -StageRoot $StageRoot
        $sdkRuntimeIdentity = Get-FearPeRuntimeIdentity -Path (Join-Path $StageRoot 'FEARDevSP.exe')
        if (-not (Test-FearX86Pe32Identity -Identity $sdkRuntimeIdentity)) {
            throw "Staged FEARDevSP.exe is not a 32-bit x86 PE image: $(Join-Path $StageRoot 'FEARDevSP.exe')"
        }
        $runtimeExecutableState = 'SdkDiagnostic'
        $runtimeExecutableSha256 = $sdkRuntimeIdentity.Sha256
    }
    else {
        Copy-RetailRuntimeFiles `
            -RetailRuntimeRoot $resolvedRetailRoot `
            -DestinationRoot $StageRoot `
            -IncludeRetailExecutable:($HdTextureMode -eq 'Off')
        if ($HdTextureMode -ne 'Off') {
            Copy-FileToStage `
                -Source $hdTextureLaaIdentity.PatchedExecutable `
                -Destination (Join-Path $StageRoot 'FEAR.exe') `
                -StageRoot $StageRoot
        }
        $rebuiltRuntimeIdentity = Get-FearPeRuntimeIdentity -Path (Join-Path $StageRoot 'FEAR.exe')
        if (-not (Test-FearX86Pe32Identity -Identity $rebuiltRuntimeIdentity)) {
            throw "Staged FEAR.exe is not a 32-bit x86 PE image: $(Join-Path $StageRoot 'FEAR.exe')"
        }
        if ($HdTextureMode -ne 'Off' -and
            ($rebuiltRuntimeIdentity.Sha256 -cne $hdTextureLaaIdentity.PatchedExecutableSha256 -or
                -not $rebuiltRuntimeIdentity.LargeAddressAware)) {
            throw "Staged HD-texture runtime executable does not match the attested LAA source: $(Join-Path $StageRoot 'FEAR.exe')"
        }
        if ($HdTextureMode -eq 'Off' -and
            $rebuiltRuntimeIdentity.Sha256 -cne $retailInputIdentity.Sha256) {
            throw "Staged Off-mode FEAR.exe does not match the selected retail executable: $(Join-Path $StageRoot 'FEAR.exe')"
        }
        $runtimeExecutableState = if ($HdTextureMode -ne 'Off') { 'AttestedLAAForHdTextures' } else { 'RetailOriginal' }
        $runtimeExecutableSha256 = $rebuiltRuntimeIdentity.Sha256
        $retailExecutableSha256 = $retailInputIdentity.Sha256
    }

    $stageGameRoot = Join-Path $StageRoot 'Game'
    Ensure-SafeStageDirectory -Path $stageGameRoot -StageRoot $StageRoot
    foreach ($module in $rebuiltModules) {
        Copy-FileToStage -Source $module.Path -Destination (Join-Path $stageGameRoot $module.Name) -StageRoot $StageRoot
    }
    $archiveEntries += 'Game'
    if ($hdTexturePackageIdentity) {
        # Resource trees are inserted at the head as they are read, so the last
        # entry has highest lookup priority over rebuilt and retail content.
        $archiveEntries += 'HDTextures'
    }
}
else {
    Copy-RetailRuntimeFiles -RetailRuntimeRoot $resolvedRetailRoot -DestinationRoot $StageRoot

    $stockRuntimeState = Sync-StockRuntimeExecutable `
        -RetailExecutable (Join-Path $resolvedRetailRoot 'FEAR.exe') `
        -StageRoot $StageRoot `
        -Refresh:$RefreshRuntimeExecutable
    $runtimeExecutableState = $stockRuntimeState.State
    $bootstrapRequired = $stockRuntimeState.BootstrapRequired
    $runtimeExecutableSha256 = $stockRuntimeState.RuntimeExecutableSha256
    $retailExecutableSha256 = $stockRuntimeState.RetailExecutableSha256
    $runtimeExecutableBackupSha256 = $stockRuntimeState.RuntimeExecutableBackupSha256

    Copy-ZipEntry -ArchivePath $EchoPatchArchive -EntryName 'dinput8.dll' -Destination (Join-Path $StageRoot 'dinput8.dll') -StageRoot $StageRoot
    Copy-ZipEntry -ArchivePath $EchoPatchArchive -EntryName 'EchoPatch.ini' -Destination (Join-Path $StageRoot 'EchoPatch.ini') -StageRoot $StageRoot
    Set-EchoPatchSsaaScale -Path (Join-Path $StageRoot 'EchoPatch.ini') -Scale $SSAAScale -StageRoot $StageRoot
}

if ($Lane -eq 'Rebuilt') {
    foreach ($relativeDirectory in @($packagePlan.ControllerManagedDirectories)) {
        Ensure-SafeStageDirectory `
            -Path (Join-Path $StageRoot $relativeDirectory) `
            -StageRoot $StageRoot
    }

    $controllerRuntimePath = Join-Path $StageRoot ([string]$controllerPackageIdentity.RuntimeFileName)
    $controllerRuntimeWriteIdentity = Write-BytesToStage `
        -Bytes ([byte[]]$controllerPackageIdentity.RuntimeBytes) `
        -Destination $controllerRuntimePath `
        -StageRoot $StageRoot `
        -ExpectedSize ([long]$controllerPackageIdentity.RuntimeSize) `
        -ExpectedSha256 ([string]$controllerPackageIdentity.RuntimeSha256) `
        -Description 'SDL3 x86 controller runtime'
    $stagedControllerRuntimeIdentity = Get-FearPeRuntimeIdentity -Path $controllerRuntimePath
    if (-not (Test-FearX86Pe32Identity -Identity $stagedControllerRuntimeIdentity) -or
        [long]$stagedControllerRuntimeIdentity.Size -ne [long]$controllerRuntimeWriteIdentity.Size -or
        [string]$stagedControllerRuntimeIdentity.Sha256 -cne [string]$controllerRuntimeWriteIdentity.Sha256) {
        throw "Staged SDL3 controller runtime is not the validated 32-bit x86 payload: $controllerRuntimePath"
    }

    $controllerLicensePath = Join-Path $StageRoot ([string]$controllerPackageIdentity.LicenseStagePath)
    $stagedControllerLicenseIdentity = Write-BytesToStage `
        -Bytes ([byte[]]$controllerPackageIdentity.LicenseBytes) `
        -Destination $controllerLicensePath `
        -StageRoot $StageRoot `
        -ExpectedSize ([long]$controllerPackageIdentity.LicenseSize) `
        -ExpectedSha256 ([string]$controllerPackageIdentity.LicenseSha256) `
        -Description 'SDL3 zlib license'
}

if ($RendererMode -eq 'DgVoodooD3D11') {
    $stagedRendererProxyPath = Join-Path $StageRoot 'd3d9.dll'
    $stagedRendererConfigPath = Join-Path $StageRoot 'dgVoodoo.conf'
    Copy-ZipEntry `
        -ArchivePath $DgVoodooArchive `
        -EntryName $rendererPackageIdentity.ProxyEntry `
        -Destination $stagedRendererProxyPath `
        -StageRoot $StageRoot
    Copy-FileToStage -Source $rendererConfigSource -Destination $stagedRendererConfigPath -StageRoot $StageRoot

    $stagedRendererProxyIdentity = Get-FearPeRuntimeIdentity -Path $stagedRendererProxyPath
    if (-not (Test-FearX86Pe32Identity -Identity $stagedRendererProxyIdentity) -or
        $stagedRendererProxyIdentity.Sha256 -ne $rendererPackageIdentity.ProxySha256 -or
        $stagedRendererProxyIdentity.Size -ne $rendererPackageIdentity.ProxySize) {
        throw "Staged dgVoodoo2 d3d9.dll does not match the pinned x86 package identity: $stagedRendererProxyPath"
    }
    $stagedRendererConfigIdentity = Get-FearDgVoodooConfigIdentity `
        -Path $stagedRendererConfigPath `
        -RendererQuality $RendererQuality
    if ($stagedRendererConfigIdentity.Sha256 -ne $rendererConfigIdentity.Sha256) {
        throw "Staged dgVoodoo2 config does not match the project-owned D3D11 profile: $stagedRendererConfigPath"
    }
    $stagedRendererOwnedFiles = @(
        [pscustomobject][ordered]@{
            RelativePath = 'd3d9.dll'
            Size         = $stagedRendererProxyIdentity.Size
            Sha256       = $stagedRendererProxyIdentity.Sha256
        },
        [pscustomobject][ordered]@{
            RelativePath = 'dgVoodoo.conf'
            Size         = (Get-Item -LiteralPath $stagedRendererConfigPath).Length
            Sha256       = $stagedRendererConfigIdentity.Sha256
        }
    )
}
elseif ($RendererMode -eq 'RtxRemixProbe') {
    foreach ($relativeDirectory in $rendererRuntimeWritableDirectories) {
        Ensure-SafeStageDirectory -Path (Join-Path $StageRoot $relativeDirectory) -StageRoot $StageRoot
    }
    foreach ($relativeFile in $rendererRuntimeMutableFiles) {
        $mutablePath = Join-Path $StageRoot $relativeFile
        if (Test-Path -LiteralPath $mutablePath) {
            Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $mutablePath
            if (-not (Test-Path -LiteralPath $mutablePath -PathType Leaf)) {
                throw "RTX Remix runtime-mutable path is not an ordinary file: $mutablePath"
            }
        }
    }

    $rtxRuntimeConfigPath = Join-Path $StageRoot 'rtx.conf'
    if (-not $existingStageManifest -and -not (Test-Path -LiteralPath $rtxRuntimeConfigPath)) {
        Copy-FileToStage `
            -Source $rendererRuntimeConfigSeedIdentity.Path `
            -Destination $rtxRuntimeConfigPath `
            -StageRoot $StageRoot
        $stagedRuntimeConfigSeedIdentity = Get-FearRtxRemixRuntimeConfigSeedIdentity -Path $rtxRuntimeConfigPath
        if ($stagedRuntimeConfigSeedIdentity.Sha256 -cne $rendererRuntimeConfigSeedIdentity.Sha256) {
            throw "Staged RTX Remix runtime config seed does not match the project-owned Custom + ReSTIR GI compatibility profile: $rtxRuntimeConfigPath"
        }
        $rendererRuntimeConfigSeedApplied = $true
    }

    $stagedRendererOwnedFiles = @(Copy-RendererArchivePayloadToStage `
        -ArchivePath $RtxRemixArchive `
        -Files $rendererPackageIdentity.Files `
        -StageRoot $StageRoot)
    if ($stagedRendererOwnedFiles.Count -ne $rendererPackageIdentity.ArchiveFileCount) {
        throw "Staged RTX Remix payload file-count mismatch. Expected $($rendererPackageIdentity.ArchiveFileCount) but found $($stagedRendererOwnedFiles.Count)."
    }
    $stagedRendererConfigPath = Join-Path $StageRoot $packagePlan.RendererConfigFile
    Copy-FileToStage -Source $rendererConfigSource -Destination $stagedRendererConfigPath -StageRoot $StageRoot
    $stagedRendererConfigIdentity = Get-FearRtxRemixBridgeConfigIdentity -Path $stagedRendererConfigPath
    if ($stagedRendererConfigIdentity.Sha256 -cne $rendererConfigIdentity.Sha256) {
        throw "Staged RTX Remix bridge config does not match the project-owned troubleshooting profile: $stagedRendererConfigPath"
    }
    $stagedRendererProxyPath = Join-Path $StageRoot 'd3d9.dll'
    $stagedRendererProxyIdentity = Get-FearPeRuntimeIdentity -Path $stagedRendererProxyPath
    if (-not (Test-FearX86Pe32Identity -Identity $stagedRendererProxyIdentity) -or
        $stagedRendererProxyIdentity.Sha256 -ne $rendererPackageIdentity.ProxySha256 -or
        $stagedRendererProxyIdentity.Size -ne $rendererPackageIdentity.ProxySize) {
        throw "Staged RTX Remix bridge interposer does not match the pinned x86 package identity: $stagedRendererProxyPath"
    }
}

if ($PostProcessMode -eq 'ReShadeCas') {
    if ($postProcessFirstEnable) {
        foreach ($relativePath in @($packagePlan.PostProcessRuntimeMutableFiles) + @($packagePlan.PostProcessRuntimeWritableDirectories)) {
            $firstEnablePath = Join-Path $StageRoot $relativePath
            if (Test-Path -LiteralPath $firstEnablePath) {
                throw "First ReShadeCas enable found unowned runtime state that appeared after ownership preflight: $firstEnablePath"
            }
        }
    }
    foreach ($relativeDirectory in @($packagePlan.PostProcessManagedDirectories)) {
        Ensure-SafeStageDirectory `
            -Path (Join-Path $StageRoot $relativeDirectory) `
            -StageRoot $StageRoot
    }

    $postProcessRecords = [Collections.Generic.List[object]]::new()
    $proxyPath = Join-Path $StageRoot ([string]$postProcessStagePayload.ProxyRelativePath)
    $proxyWriteIdentity = Write-BytesToStage `
        -Bytes ([byte[]]$postProcessStagePayload.ProxyBytes) `
        -Destination $proxyPath `
        -StageRoot $StageRoot `
        -ExpectedSize ([long]$postProcessPackageIdentity.ProxySize) `
        -ExpectedSha256 ([string]$postProcessPackageIdentity.ProxySha256) `
        -Description 'ReShade x86 DXGI proxy'
    $stagedPostProcessProxyIdentity = Get-FearPeRuntimeIdentity -Path $proxyPath
    if (-not (Test-FearX86Pe32Identity -Identity $stagedPostProcessProxyIdentity) -or
        [long]$stagedPostProcessProxyIdentity.Size -ne [long]$proxyWriteIdentity.Size -or
        [string]$stagedPostProcessProxyIdentity.Sha256 -cne [string]$proxyWriteIdentity.Sha256) {
        throw "Staged ReShade DXGI proxy is not the validated 32-bit x86 payload: $proxyPath"
    }
    $postProcessRecords.Add([pscustomobject][ordered]@{
        RelativePath = [string]$postProcessStagePayload.ProxyRelativePath
        Size         = [long]$proxyWriteIdentity.Size
        Sha256       = [string]$proxyWriteIdentity.Sha256
    })

    foreach ($assetPayload in @($postProcessStagePayload.AssetFiles | Sort-Object StageRelativePath)) {
        $assetPath = Join-Path $StageRoot ([string]$assetPayload.StageRelativePath)
        $assetWriteIdentity = Write-BytesToStage `
            -Bytes ([byte[]]$assetPayload.Bytes) `
            -Destination $assetPath `
            -StageRoot $StageRoot `
            -ExpectedSize ([long]$assetPayload.Size) `
            -ExpectedSha256 ([string]$assetPayload.Sha256) `
            -Description "FearMore post-process asset '$($assetPayload.SourceRelativePath)'"
        $postProcessRecords.Add([pscustomobject][ordered]@{
            RelativePath = [string]$assetPayload.StageRelativePath
            Size         = [long]$assetWriteIdentity.Size
            Sha256       = [string]$assetWriteIdentity.Sha256
        })
    }

    if ($postProcessFirstEnable) {
        foreach ($seedPlan in @($packagePlan.PostProcessSeedFiles)) {
            $seedTargetPath = Join-Path $StageRoot ([string]$seedPlan.TargetRelativePath)
            if (Test-Path -LiteralPath $seedTargetPath) {
                throw "First ReShadeCas enable found an unowned config that appeared after ownership preflight: $seedTargetPath"
            }
            $matchingSeedPayload = @($postProcessStagePayload.AssetFiles | Where-Object {
                    [string]$_.SourceRelativePath -ceq [string]$seedPlan.SourceAssetRelativePath
                })
            if ($matchingSeedPayload.Count -ne 1) {
                throw "Validated post-process payload does not contain exactly one seed source '$($seedPlan.SourceAssetRelativePath)'."
            }
            $seedPayload = $matchingSeedPayload[0]
            Write-BytesToStage `
                -Bytes ([byte[]]$seedPayload.Bytes) `
                -Destination $seedTargetPath `
                -StageRoot $StageRoot `
                -ExpectedSize ([long]$seedPayload.Size) `
                -ExpectedSha256 ([string]$seedPayload.Sha256) `
                -Description "first-enable post-process config '$($seedPlan.TargetRelativePath)'" `
                -CreateNew | Out-Null
            $postProcessSeedAppliedFiles += [string]$seedPlan.TargetRelativePath
        }
        if ($postProcessSeedAppliedFiles.Count -ne @($packagePlan.PostProcessSeedFiles).Count) {
            throw "First ReShadeCas enable must apply exactly $(@($packagePlan.PostProcessSeedFiles).Count) owned config seeds; applied $($postProcessSeedAppliedFiles.Count)."
        }
    }

    $stagedPostProcessOwnedFiles = @($postProcessRecords | Sort-Object RelativePath)
    if ($stagedPostProcessOwnedFiles.Count -ne @($packagePlan.PostProcessImmutableFiles).Count) {
        throw "Staged ReShadeCas immutable-file count mismatch. Expected $(@($packagePlan.PostProcessImmutableFiles).Count) but found $($stagedPostProcessOwnedFiles.Count)."
    }
    $postProcessEverEnabled = $true
}
else {
    foreach ($relativePath in @($packagePlan.PostProcessImmutableFiles)) {
        $immutablePath = Join-Path $StageRoot $relativePath
        if (Test-Path -LiteralPath $immutablePath) {
            Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path $immutablePath
            if (-not (Test-Path -LiteralPath $immutablePath -PathType Leaf)) {
                throw "Post-process immutable path is not an ordinary file and cannot be disabled safely: $immutablePath"
            }
            Remove-Item -LiteralPath $immutablePath -Force
        }
    }
}

if ($EnginePatchMode -in @('EngineOnlyEchoPatch', 'RemixDiagnosticEchoPatch', 'CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')) {
    $stagedEnginePatchProxyPath = Join-Path $StageRoot 'dinput8.dll'
    $stagedEnginePatchConfigPath = Join-Path $StageRoot 'EchoPatch.ini'
    Copy-FileToStage `
        -Source $enginePatchPackageIdentity.BinaryPath `
        -Destination $stagedEnginePatchProxyPath `
        -StageRoot $StageRoot
    Copy-FileToStage `
        -Source $enginePatchPackageIdentity.ConfigPath `
        -Destination $stagedEnginePatchConfigPath `
        -StageRoot $StageRoot
    if ($EnginePatchMode -eq 'EngineOnlyEchoPatch' -and $maxFpsExplicit) {
        Set-EngineOnlyEchoPatchFrameCap -Path $stagedEnginePatchConfigPath -FrameCap $MaxFPS -StageRoot $StageRoot
    }
    if ($packagePlan.EnginePatchForceWindowed) {
        Set-StagedEchoPatchForceWindowed `
            -Path $stagedEnginePatchConfigPath `
            -Enabled $true `
            -StageRoot $StageRoot
    }

    $stagedEnginePatchProxyIdentity = Get-FearPeRuntimeIdentity -Path $stagedEnginePatchProxyPath
    if (-not (Test-FearX86Pe32Identity -Identity $stagedEnginePatchProxyIdentity) -or
        $stagedEnginePatchProxyIdentity.Sha256 -ne $enginePatchPackageIdentity.BinarySha256) {
        throw "Staged engine-only EchoPatch dinput8.dll does not match the pinned x86 package identity: $stagedEnginePatchProxyPath"
    }
    $stagedEnginePatchConfigIdentity = Get-FearEngineOnlyEchoPatchConfigIdentity `
        -Path $stagedEnginePatchConfigPath `
        -ExpectedMaxFPS $effectiveMaxFPS `
        -ExpectedDynamicVsync $effectiveDynamicVsync `
        -ExpectedCameraDiagnostics $(if ($EnginePatchMode -in @('CameraDiagnosticEchoPatch', 'RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')) { 1 } else { 0 }) `
        -ExpectedRemixCameraDiagnostics $(if ($EnginePatchMode -eq 'RemixDiagnosticEchoPatch') { 1 } else { 0 }) `
        -ExpectedRtxFocusPreservation $(if ($EnginePatchMode -in @('RtxCameraDiagnosticEchoPatch', 'RtxCameraReassertionEchoPatch')) { 1 } else { 0 }) `
        -ExpectedRtxCameraReassertion $(if ($EnginePatchMode -eq 'RtxCameraReassertionEchoPatch') { 1 } else { 0 }) `
        -ExpectedForceWindowed $(if ($packagePlan.EnginePatchForceWindowed) { 1 } else { 0 }) `
        -ExpectedFixWindowStyle $(if ($packagePlan.EnginePatchFixWindowStyle) { 1 } else { 0 })
}

$steamAppIdFile = if ($steamAppIdHintPlan.Action -in @('Create', 'Preserve')) {
    $steamAppIdHintPlan.Path
}
else {
    $null
}

Write-ArchiveConfig -Path (Join-Path $StageRoot 'Default.archcfg') -StageLane $Lane -Entries $archiveEntries -StageRoot $StageRoot

Assert-FileVersion -Path (Join-Path $StageRoot $runtimeExecutableName) -ExpectedVersion $ExpectedFearVersion -Description "Staged $runtimeExecutableName" | Out-Null
if ($Lane -in @('Rebuilt', 'SdkSmoke')) {
    Assert-GameModules -ModuleRoot (Join-Path $StageRoot 'Game') | Out-Null
}
Assert-FearStagePackageLayout -Root $StageRoot -StageLane $Lane -PackagePlan $packagePlan

Assert-FearNoReparsePathComponents -Root $localRuntimeRoot -Path $StageRoot -RequirePath -Description 'local-runtime to StageRoot path'
Assert-FearSafeStageFileTarget -StageRoot $StageRoot -Path (Join-Path $StageRoot 'Default.archcfg')
if ($userDirectory) {
    Assert-FearSafeStageDirectoryTarget -StageRoot $StageRoot -Path $userDirectory
}
Assert-FearStageTreeNoUnexpectedReparsePoints `
    -StageRoot $StageRoot `
    -RetailTarget $resolvedRetailRoot `
    -AuthorizedMounts $desiredHdTextureMounts

$launchPermitted = $Lane -ne 'SdkSmoke' -and
    -not ($Lane -eq 'StockEchoPatch' -and $bootstrapRequired)
$bootstrapNote = if ($Lane -eq 'StockEchoPatch' -and $bootstrapRequired) {
    'The staged StockEchoPatch executable still requires EchoPatch LAA bootstrap. Launch is blocked because the upstream bootstrap may restart without the recorded -userdirectory and -archcfg arguments. A safe automated first-launch bootstrap is not implemented; only an already attested executable/backup pair is launchable through this tool.'
}
else {
    $null
}
$acceptanceNote = if ($Lane -eq 'SdkSmoke') {
    'SDK-only staging validates the available Public Tools binary and rebuilt-module layout. Launch is forbidden because Public Tools does not distribute the matching retail bootstrap DLL set.'
}
elseif ($PostProcessMode -eq 'ReShadeCas') {
    'Project-level live acceptance verified the pinned x86 ReShade DXGI proxy chain and FearMore CAS shader at 6880x2880 internal rendering with 3440x1440 output. This staging invocation does not itself prove launch, image quality, stability, or performance for the current machine and session.'
}
elseif ($RendererMode -eq 'RtxRemixProbe') {
    'The official RTX Remix payload is staged for a bounded compatibility probe only. F.E.A.R. runtime interception, scene capture, visual completeness, stability, performance, and path tracing compatibility are unverified.'
}
elseif ($EnginePatchMode -eq 'CameraDiagnosticEchoPatch') {
    'The native D3D9 query-light camera diagnostic is staged for bounded developer capture only; captured constants still require source correlation before any renderer behavior changes.'
}
elseif ($Lane -eq 'StockEchoPatch' -and $bootstrapRequired) {
    $bootstrapNote
}
else {
    'Runtime launch and gameplay acceptance have not been performed by the staging tool.'
}

$manifest = [ordered]@{
    SchemaVersion          = 9
    GeneratedUtc           = [DateTime]::UtcNow.ToString('o')
    Lane                   = $Lane
    Configuration          = $Configuration
    RendererMode           = $RendererMode
    RendererQuality        = $packagePlan.RendererQuality
    RendererPackage        = if ($rendererPackageIdentity) { $rendererPackageIdentity.ArchivePath } else { $null }
    RendererPackageVersion = if ($rendererPackageIdentity) { $rendererPackageIdentity.Version } else { $null }
    RendererPackageSize    = if ($rendererPackageIdentity) { $rendererPackageIdentity.ArchiveSize } else { $null }
    RendererPackageSha256  = if ($rendererPackageIdentity) { $rendererPackageIdentity.ArchiveSha256 } else { $null }
    RendererProxyFile      = if ($stagedRendererProxyIdentity) { 'd3d9.dll' } else { $null }
    RendererProxySha256    = if ($stagedRendererProxyIdentity) { $stagedRendererProxyIdentity.Sha256 } else { $null }
    RendererConfigFile     = if ($stagedRendererConfigIdentity) { $packagePlan.RendererConfigFile } else { $null }
    RendererConfigSha256   = if ($stagedRendererConfigIdentity) { $stagedRendererConfigIdentity.Sha256 } else { $null }
    RendererOutputAPI      = if ($stagedRendererConfigIdentity -and $stagedRendererConfigIdentity.PSObject.Properties['OutputAPI']) { $stagedRendererConfigIdentity.OutputAPI } else { $null }
    RendererResolution     = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.Resolution } else { $null }
    RendererScalingMode    = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.ScalingMode } else { $null }
    RendererResampling     = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.Resampling } else { $null }
    RendererFiltering      = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.Filtering } else { $null }
    RendererAntialiasing   = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.Antialiasing } else { $null }
    RendererVRAM           = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.VRAM } else { $null }
    RendererFPSLimit       = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.FPSLimit } else { $null }
    RendererForceVerticalSync = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.ForceVerticalSync } else { $null }
    RendererExperimental   = $packagePlan.RendererExperimental
    RendererCompatibilityStatus = $packagePlan.RendererCompatibilityStatus
    RendererPackageFileCount = if ($RendererMode -eq 'RtxRemixProbe') { $rendererPackageIdentity.ArchiveFileCount } else { $null }
    RendererOwnedFiles     = @($stagedRendererOwnedFiles)
    RendererRuntimeWritableDirectories = @($rendererRuntimeWritableDirectories)
    RendererRuntimeMutableFiles = @($rendererRuntimeMutableFiles)
    RendererRuntimeConfigSeedSource = if ($rendererRuntimeConfigSeedIdentity) { $rendererRuntimeConfigSeedIdentity.Path } else { $null }
    RendererRuntimeConfigSeedSha256 = if ($rendererRuntimeConfigSeedIdentity) { $rendererRuntimeConfigSeedIdentity.Sha256 } else { $null }
    RendererRuntimeConfigSeedPolicy = if ($rendererRuntimeConfigSeedIdentity) { 'NewStageOnly' } else { $null }
    RendererRuntimeConfigSeedApplied = $rendererRuntimeConfigSeedApplied
    RendererRuntimeConfigSeedBackend = if ($rendererRuntimeConfigSeedIdentity) { $rendererRuntimeConfigSeedIdentity.IndirectLightingBackend } else { $null }
    RendererRuntimeConfigSeedDlssFrameGenerationEnabled = if ($rendererRuntimeConfigSeedIdentity) { [bool]$rendererRuntimeConfigSeedIdentity.DlssFrameGenerationEnabled } else { $null }
    ControllerRuntime      = if ($stagedControllerRuntimeIdentity) { 'SDL3' } else { $null }
    ControllerPackage     = if ($controllerPackageIdentity) { $controllerPackageIdentity.ArchivePath } else { $null }
    ControllerPackageVersion = if ($controllerPackageIdentity) { $controllerPackageIdentity.Version } else { $null }
    ControllerPackageSize = if ($controllerPackageIdentity) { $controllerPackageIdentity.ArchiveSize } else { $null }
    ControllerPackageSha256 = if ($controllerPackageIdentity) { $controllerPackageIdentity.ArchiveSha256 } else { $null }
    ControllerRuntimeFile = if ($stagedControllerRuntimeIdentity) { $controllerPackageIdentity.RuntimeFileName } else { $null }
    ControllerRuntimeSize = if ($stagedControllerRuntimeIdentity) { $stagedControllerRuntimeIdentity.Size } else { $null }
    ControllerRuntimeSha256 = if ($stagedControllerRuntimeIdentity) { $stagedControllerRuntimeIdentity.Sha256 } else { $null }
    ControllerRuntimeArchitecture = if ($stagedControllerRuntimeIdentity) { 'x86' } else { $null }
    ControllerLicense     = if ($stagedControllerLicenseIdentity) { $controllerPackageIdentity.License } else { $null }
    ControllerLicenseFile = if ($stagedControllerLicenseIdentity) { $controllerPackageIdentity.LicenseStagePath } else { $null }
    ControllerLicenseSize = if ($stagedControllerLicenseIdentity) { $stagedControllerLicenseIdentity.Size } else { $null }
    ControllerLicenseSha256 = if ($stagedControllerLicenseIdentity) { $stagedControllerLicenseIdentity.Sha256 } else { $null }
    ControllerAcceptanceTested = $false
    PostProcessMode        = $PostProcessMode
    PostProcessPackage     = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.SetupPath } else { $null }
    PostProcessPackageVersion = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.ReShadeVersion } else { $null }
    PostProcessPackageSize = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.SetupSize } else { $null }
    PostProcessPackageSha256 = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.SetupSha256 } else { $null }
    PostProcessProxyFile   = if ($stagedPostProcessProxyIdentity) { 'dxgi.dll' } else { $null }
    PostProcessProxySize   = if ($stagedPostProcessProxyIdentity) { $stagedPostProcessProxyIdentity.Size } else { $null }
    PostProcessProxySha256 = if ($stagedPostProcessProxyIdentity) { $stagedPostProcessProxyIdentity.Sha256 } else { $null }
    PostProcessProxyApi    = if ($stagedPostProcessProxyIdentity) { $postProcessPackageIdentity.ProxyApi } else { $null }
    PostProcessOwnedFiles  = @($stagedPostProcessOwnedFiles)
    PostProcessAssetRoot   = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.Assets.Root } else { $null }
    PostProcessRuntimeMutableFiles = @($packagePlan.PostProcessRuntimeMutableFiles)
    PostProcessRuntimeWritableDirectories = @($packagePlan.PostProcessRuntimeWritableDirectories)
    PostProcessConfigSeedPolicy = 'FirstEnableOnly'
    PostProcessConfigSeedApplied = $postProcessSeedAppliedFiles.Count -gt 0
    PostProcessConfigSeedAppliedFiles = @($postProcessSeedAppliedFiles)
    PostProcessEverEnabled = [bool]$postProcessEverEnabled
    PostProcessDefaultSharpness = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.Assets.DefaultSharpness } else { $null }
    PostProcessColorOnly   = if ($postProcessPackageIdentity) { [bool]$postProcessPackageIdentity.Assets.ColorOnly } else { $null }
    PostProcessUsesDepth   = if ($postProcessPackageIdentity) { [bool]$postProcessPackageIdentity.Assets.UsesDepth } else { $null }
    PostProcessPerformsScaling = if ($postProcessPackageIdentity) { [bool]$postProcessPackageIdentity.Assets.PerformsScaling } else { $null }
    PostProcessExperimental = $packagePlan.PostProcessExperimental
    PostProcessCompatibilityStatus = $packagePlan.PostProcessCompatibilityStatus
    PostProcessAcceptanceTested = $false
    EnginePatchMode        = $EnginePatchMode
    EnginePatchPackage     = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.PackageRoot } else { $null }
    EnginePatchManifest    = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.ManifestPath } else { $null }
    EnginePatchManifestSha256 = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.ManifestSha256 } else { $null }
    EnginePatchCommit      = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.Commit } else { $null }
    EnginePatchProxyFile   = if ($stagedEnginePatchProxyIdentity) { 'dinput8.dll' } else { $null }
    EnginePatchProxySha256 = if ($stagedEnginePatchProxyIdentity) { $stagedEnginePatchProxyIdentity.Sha256 } else { $null }
    EnginePatchConfigFile  = if ($stagedEnginePatchConfigIdentity) { 'EchoPatch.ini' } else { $null }
    EnginePatchConfigSha256 = if ($stagedEnginePatchConfigIdentity) { $stagedEnginePatchConfigIdentity.Sha256 } else { $null }
    EnginePatchForceWindowed = if ($stagedEnginePatchConfigIdentity) { [bool]$stagedEnginePatchConfigIdentity.ForceWindowed } else { $null }
    EnginePatchFixWindowStyle = if ($stagedEnginePatchConfigIdentity) { [bool]$stagedEnginePatchConfigIdentity.FixWindowStyle } else { $null }
    HdTextureMode          = $HdTextureMode
    HdTexturePackageRoot   = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.PackageRoot } else { $null }
    HdTextureContentRoot   = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.ContentRoot } else { $null }
    HdTextureMount         = if ($hdTexturePackageIdentity) { 'HDTextures' } else { $null }
    HdTexturePackageName   = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.KnownPackageName } else { $null }
    HdTextureFileCount     = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.FileCount } else { $null }
    HdTextureTotalBytes    = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.TotalBytes } else { $null }
    HdTextureManifestFormat = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.ManifestFormat } else { $null }
    HdTextureManifestSha256 = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.ManifestSha256 } else { $null }
    HdTextureLaaSource     = if ($hdTextureLaaIdentity) { $hdTextureLaaIdentity.PatchedExecutable } else { $null }
    HdTextureLaaSourceSha256 = if ($hdTextureLaaIdentity) { $hdTextureLaaIdentity.PatchedExecutableSha256 } else { $null }
    HdTextureLaaBackupSha256 = if ($hdTextureLaaIdentity) { $hdTextureLaaIdentity.BackupExecutableSha256 } else { $null }
    MaxFPS                 = $effectiveMaxFPS
    MaxFPSExplicit         = $maxFpsExplicit
    DynamicVsync           = $effectiveDynamicVsync
    FearVersion            = $ExpectedFearVersion
    RuntimeExecutable      = $runtimeExecutableName
    RuntimeExecutableState = $runtimeExecutableState
    BootstrapRequired      = $bootstrapRequired
    BootstrapNote          = $bootstrapNote
    RuntimeExecutableSha256 = $runtimeExecutableSha256
    RetailExecutableSha256 = $retailExecutableSha256
    RuntimeExecutableBackupSha256 = $runtimeExecutableBackupSha256
    SteamAppId             = if ($isSteamRetail) { $SteamAppId } else { $null }
    SteamAppIdFile         = $steamAppIdFile
    SteamAppIdHintManaged  = $isSteamRetail
    SteamAppIdFileSha256   = if ($isSteamRetail) { $SteamAppIdFileSha256 } else { $null }
    RetailRoot             = $resolvedRetailRoot
    PublicToolsRoot        = if ($sdkIdentity) { $SdkRoot } else { $null }
    BuildRoot              = if ($Lane -in @('Rebuilt', 'SdkSmoke')) { $BuildRoot } else { $null }
    EchoPatchArchive       = if ($Lane -eq 'StockEchoPatch') { $EchoPatchArchive } else { $null }
    EchoPatchArchiveSha256 = $echoPatchHash
    SSAAScale              = if ($Lane -eq 'StockEchoPatch') { $SSAAScale } else { $null }
    ArchiveEntries         = $archiveEntries
    Modules                = if ($Lane -in @('Rebuilt', 'SdkSmoke')) { $rebuiltModules } else { @() }
    UserDirectory          = $userDirectory
    SaveIsolation          = [bool]$userDirectory
    LaunchArguments        = @($effectiveLaunchArguments)
    LaunchArgumentString   = $launchArgumentString
    InputsValidated        = $true
    LayoutValidated        = $true
    LaunchPermitted        = $launchPermitted
    AcceptanceTested       = $false
    AcceptanceNote         = $acceptanceNote
}
$ownershipTransaction = Invoke-TransactionalStageOwnershipCommit `
    -StageRoot $StageRoot `
    -Manifest $manifest `
    -SteamHintShouldExist:$isSteamRetail `
    -AppId $SteamAppId
$stageOwnershipCommitted = $true
Complete-TransactionalStageOwnershipCommit -StageRoot $StageRoot -Paths $ownershipTransaction
Assert-FearStageTreeNoUnexpectedReparsePoints `
    -StageRoot $StageRoot `
    -RetailTarget $resolvedRetailRoot `
    -AuthorizedMounts $desiredHdTextureMounts
if ($rebuiltStageTransition) {
    Complete-FearRebuiltStageTransition -StageRoot $StageRoot -Transition $rebuiltStageTransition
}
}
catch {
    $failure = $_
    if ($rebuiltStageTransition -and -not $stageOwnershipCommitted) {
        try {
            Restore-FearRebuiltStageTransition -StageRoot $StageRoot -Transition $rebuiltStageTransition
        }
        catch {
            throw "Rebuilt stage transition failed and its rollback also failed. Original failure: $($failure.Exception.Message) Rollback failure: $($_.Exception.Message)"
        }
    }
    throw $failure
}

$result = [pscustomobject]@{
    Lane                 = $Lane
    Configuration        = $Configuration
    RendererMode         = $RendererMode
    RendererQuality      = $packagePlan.RendererQuality
    RendererPackage      = if ($rendererPackageIdentity) { $rendererPackageIdentity.ArchivePath } else { $null }
    RendererPackageVersion = if ($rendererPackageIdentity) { $rendererPackageIdentity.Version } else { $null }
    RendererPackageSize  = if ($rendererPackageIdentity) { $rendererPackageIdentity.ArchiveSize } else { $null }
    RendererPackageSha256 = if ($rendererPackageIdentity) { $rendererPackageIdentity.ArchiveSha256 } else { $null }
    RendererProxy        = if ($stagedRendererProxyIdentity) { Join-Path $StageRoot 'd3d9.dll' } else { $null }
    RendererProxySha256  = if ($stagedRendererProxyIdentity) { $stagedRendererProxyIdentity.Sha256 } else { $null }
    RendererConfig       = if ($stagedRendererConfigIdentity) { Join-Path $StageRoot $packagePlan.RendererConfigFile } else { $null }
    RendererConfigSha256 = if ($stagedRendererConfigIdentity) { $stagedRendererConfigIdentity.Sha256 } else { $null }
    RendererOutputAPI    = if ($stagedRendererConfigIdentity -and $stagedRendererConfigIdentity.PSObject.Properties['OutputAPI']) { $stagedRendererConfigIdentity.OutputAPI } else { $null }
    RendererResolution   = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.Resolution } else { $null }
    RendererScalingMode  = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.ScalingMode } else { $null }
    RendererResampling   = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.Resampling } else { $null }
    RendererFiltering    = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.Filtering } else { $null }
    RendererAntialiasing = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.Antialiasing } else { $null }
    RendererVRAM         = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.VRAM } else { $null }
    RendererFPSLimit     = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.FPSLimit } else { $null }
    RendererForceVerticalSync = if ($RendererMode -eq 'DgVoodooD3D11') { $stagedRendererConfigIdentity.ForceVerticalSync } else { $null }
    RendererExperimental = $packagePlan.RendererExperimental
    RendererCompatibilityStatus = $packagePlan.RendererCompatibilityStatus
    RendererPackageFileCount = if ($RendererMode -eq 'RtxRemixProbe') { $rendererPackageIdentity.ArchiveFileCount } else { $null }
    RendererOwnedFiles   = @($stagedRendererOwnedFiles)
    RendererRuntimeWritableDirectories = @($rendererRuntimeWritableDirectories)
    RendererRuntimeMutableFiles = @($rendererRuntimeMutableFiles)
    RendererRuntimeConfigSeedSource = if ($rendererRuntimeConfigSeedIdentity) { $rendererRuntimeConfigSeedIdentity.Path } else { $null }
    RendererRuntimeConfigSeedSha256 = if ($rendererRuntimeConfigSeedIdentity) { $rendererRuntimeConfigSeedIdentity.Sha256 } else { $null }
    RendererRuntimeConfigSeedPolicy = if ($rendererRuntimeConfigSeedIdentity) { 'NewStageOnly' } else { $null }
    RendererRuntimeConfigSeedApplied = $rendererRuntimeConfigSeedApplied
    RendererRuntimeConfigSeedBackend = if ($rendererRuntimeConfigSeedIdentity) { $rendererRuntimeConfigSeedIdentity.IndirectLightingBackend } else { $null }
    RendererRuntimeConfigSeedDlssFrameGenerationEnabled = if ($rendererRuntimeConfigSeedIdentity) { [bool]$rendererRuntimeConfigSeedIdentity.DlssFrameGenerationEnabled } else { $null }
    ControllerRuntime      = if ($stagedControllerRuntimeIdentity) { Join-Path $StageRoot $controllerPackageIdentity.RuntimeFileName } else { $null }
    ControllerPackage     = if ($controllerPackageIdentity) { $controllerPackageIdentity.ArchivePath } else { $null }
    ControllerPackageVersion = if ($controllerPackageIdentity) { $controllerPackageIdentity.Version } else { $null }
    ControllerPackageSize = if ($controllerPackageIdentity) { $controllerPackageIdentity.ArchiveSize } else { $null }
    ControllerPackageSha256 = if ($controllerPackageIdentity) { $controllerPackageIdentity.ArchiveSha256 } else { $null }
    ControllerRuntimeSize = if ($stagedControllerRuntimeIdentity) { $stagedControllerRuntimeIdentity.Size } else { $null }
    ControllerRuntimeSha256 = if ($stagedControllerRuntimeIdentity) { $stagedControllerRuntimeIdentity.Sha256 } else { $null }
    ControllerRuntimeArchitecture = if ($stagedControllerRuntimeIdentity) { 'x86' } else { $null }
    ControllerLicense     = if ($stagedControllerLicenseIdentity) { Join-Path $StageRoot $controllerPackageIdentity.LicenseStagePath } else { $null }
    ControllerLicenseSize = if ($stagedControllerLicenseIdentity) { $stagedControllerLicenseIdentity.Size } else { $null }
    ControllerLicenseSha256 = if ($stagedControllerLicenseIdentity) { $stagedControllerLicenseIdentity.Sha256 } else { $null }
    ControllerAcceptanceTested = $false
    PostProcessMode       = $PostProcessMode
    PostProcessPackage    = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.SetupPath } else { $null }
    PostProcessPackageVersion = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.ReShadeVersion } else { $null }
    PostProcessPackageSize = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.SetupSize } else { $null }
    PostProcessPackageSha256 = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.SetupSha256 } else { $null }
    PostProcessProxy      = if ($stagedPostProcessProxyIdentity) { Join-Path $StageRoot 'dxgi.dll' } else { $null }
    PostProcessProxySize  = if ($stagedPostProcessProxyIdentity) { $stagedPostProcessProxyIdentity.Size } else { $null }
    PostProcessProxySha256 = if ($stagedPostProcessProxyIdentity) { $stagedPostProcessProxyIdentity.Sha256 } else { $null }
    PostProcessProxyApi   = if ($stagedPostProcessProxyIdentity) { $postProcessPackageIdentity.ProxyApi } else { $null }
    PostProcessOwnedFiles = @($stagedPostProcessOwnedFiles)
    PostProcessAssetRoot  = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.Assets.Root } else { $null }
    PostProcessRuntimeMutableFiles = @($packagePlan.PostProcessRuntimeMutableFiles)
    PostProcessRuntimeWritableDirectories = @($packagePlan.PostProcessRuntimeWritableDirectories)
    PostProcessConfigSeedPolicy = 'FirstEnableOnly'
    PostProcessConfigSeedApplied = $postProcessSeedAppliedFiles.Count -gt 0
    PostProcessConfigSeedAppliedFiles = @($postProcessSeedAppliedFiles)
    PostProcessEverEnabled = [bool]$postProcessEverEnabled
    PostProcessDefaultSharpness = if ($postProcessPackageIdentity) { $postProcessPackageIdentity.Assets.DefaultSharpness } else { $null }
    PostProcessColorOnly  = if ($postProcessPackageIdentity) { [bool]$postProcessPackageIdentity.Assets.ColorOnly } else { $null }
    PostProcessUsesDepth  = if ($postProcessPackageIdentity) { [bool]$postProcessPackageIdentity.Assets.UsesDepth } else { $null }
    PostProcessPerformsScaling = if ($postProcessPackageIdentity) { [bool]$postProcessPackageIdentity.Assets.PerformsScaling } else { $null }
    PostProcessExperimental = $packagePlan.PostProcessExperimental
    PostProcessCompatibilityStatus = $packagePlan.PostProcessCompatibilityStatus
    PostProcessAcceptanceTested = $false
    EnginePatchMode      = $EnginePatchMode
    EnginePatchPackage   = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.PackageRoot } else { $null }
    EnginePatchManifest  = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.ManifestPath } else { $null }
    EnginePatchManifestSha256 = if ($enginePatchPackageIdentity) { $enginePatchPackageIdentity.ManifestSha256 } else { $null }
    EnginePatchProxy     = if ($stagedEnginePatchProxyIdentity) { Join-Path $StageRoot 'dinput8.dll' } else { $null }
    EnginePatchProxySha256 = if ($stagedEnginePatchProxyIdentity) { $stagedEnginePatchProxyIdentity.Sha256 } else { $null }
    EnginePatchConfig    = if ($stagedEnginePatchConfigIdentity) { Join-Path $StageRoot 'EchoPatch.ini' } else { $null }
    EnginePatchConfigSha256 = if ($stagedEnginePatchConfigIdentity) { $stagedEnginePatchConfigIdentity.Sha256 } else { $null }
    EnginePatchForceWindowed = if ($stagedEnginePatchConfigIdentity) { [bool]$stagedEnginePatchConfigIdentity.ForceWindowed } else { $null }
    EnginePatchFixWindowStyle = if ($stagedEnginePatchConfigIdentity) { [bool]$stagedEnginePatchConfigIdentity.FixWindowStyle } else { $null }
    HdTextureMode         = $HdTextureMode
    HdTexturePackageRoot  = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.PackageRoot } else { $null }
    HdTextureContentRoot  = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.ContentRoot } else { $null }
    HdTextureMount        = if ($hdTexturePackageIdentity) { Join-Path $StageRoot 'HDTextures' } else { $null }
    HdTextureFileCount    = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.FileCount } else { $null }
    HdTextureTotalBytes   = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.TotalBytes } else { $null }
    HdTextureManifestSha256 = if ($hdTexturePackageIdentity) { $hdTexturePackageIdentity.ManifestSha256 } else { $null }
    MaxFPS               = $effectiveMaxFPS
    MaxFPSExplicit       = $maxFpsExplicit
    DynamicVsync         = $effectiveDynamicVsync
    StageRoot            = $StageRoot
    RetailRoot           = $resolvedRetailRoot
    RetailVersion        = if ($resolvedRetailRoot) { $ExpectedFearVersion } else { $null }
    PublicToolsRoot      = if ($sdkIdentity) { $SdkRoot } else { $null }
    EchoPatchArchive     = if ($Lane -eq 'StockEchoPatch') { $EchoPatchArchive } else { $null }
    EchoPatchSha256      = $echoPatchHash
    SSAAScale            = if ($Lane -eq 'StockEchoPatch') { $SSAAScale } else { $null }
    RuntimeExecutable    = (Join-Path $StageRoot $runtimeExecutableName)
    RuntimeExecutableState = $runtimeExecutableState
    BootstrapRequired    = $bootstrapRequired
    BootstrapNote        = $bootstrapNote
    RuntimeExecutableSha256 = $runtimeExecutableSha256
    RetailExecutableSha256 = $retailExecutableSha256
    RuntimeExecutableBackupSha256 = $runtimeExecutableBackupSha256
    SteamAppId           = if ($isSteamRetail) { $SteamAppId } else { $null }
    SteamAppIdFile       = $steamAppIdFile
    SteamAppIdHintManaged = $isSteamRetail
    SteamAppIdFileSha256 = if ($isSteamRetail) { $SteamAppIdFileSha256 } else { $null }
    ArchiveConfig        = (Join-Path $StageRoot 'Default.archcfg')
    UserDirectory        = $userDirectory
    SaveIsolation        = [bool]$userDirectory
    LaunchArguments      = @($effectiveLaunchArguments)
    LaunchArgumentString = $launchArgumentString
    InputsValidated      = $true
    LayoutValidated      = $true
    LaunchPermitted      = $launchPermitted
    AcceptanceTested     = $false
    AcceptanceNote       = $acceptanceNote
    ValidationOnly       = $false
    ArchivedRemixLog     = $null
    LaunchProcessId      = $null
}

if ($Launch) {
    if ($result.BootstrapRequired) {
        throw 'StockEchoPatch launch is blocked while EchoPatch LAA bootstrap is required because the upstream restart can drop the isolated user-directory arguments.'
    }
    if (-not $result.LaunchPermitted) {
        throw "Lane '$Lane' is not launch-permitted."
    }
    Assert-FearNoReparsePathComponents -Root $localRuntimeRoot -Path $StageRoot -RequirePath -Description 'local-runtime to StageRoot path before launch'
    Assert-FearStageTreeNoUnexpectedReparsePoints `
        -StageRoot $StageRoot `
        -RetailTarget $resolvedRetailRoot `
        -AuthorizedMounts $desiredHdTextureMounts
    if ($RendererMode -eq 'RtxRemixProbe') {
        $result.ArchivedRemixLog = Archive-FearRemixRuntimeLog -StageRoot $StageRoot
    }
    $launchProcess = Start-Process `
        -FilePath $result.RuntimeExecutable `
        -WorkingDirectory $StageRoot `
        -ArgumentList $launchArgumentString `
        -PassThru
    $result.LaunchProcessId = $launchProcess.Id
}

$result
