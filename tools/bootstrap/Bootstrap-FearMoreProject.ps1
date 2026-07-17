[CmdletBinding(SupportsShouldProcess = $true, PositionalBinding = $false)]
param(
    [string]$RepositoryRoot,
    [string]$SdkSourceRoot,
    [string]$LauncherRoot,
    [string]$OutputRoot,
    [string]$ReleaseTag = 'v0.1.2',
    [string]$RepositoryUrl = 'https://github.com/SendoTarget/FEAR-MORE.git',
    [switch]$SkipPrerequisiteInstall,
    [switch]$NonInteractive,
    [switch]$DoNotLaunchInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'FearMoreBootstrapPrerequisites.psm1') -Force -ErrorAction Stop
if ($ReleaseTag -notmatch '^v\d+\.\d+\.\d+$') { throw "Unsupported FearMore release tag: $ReleaseTag" }

$bootstrapRoot = Join-Path $env:LOCALAPPDATA 'FearMore\Bootstrap'
$logRoot = Join-Path $bootstrapRoot 'logs'
[IO.Directory]::CreateDirectory($logRoot) | Out-Null
$logPath = Join-Path $logRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
$logPath += '-bootstrap.log'
Start-Transcript -LiteralPath $logPath -Force | Out-Null

function Show-FearMoreMessage {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [string]$Title = 'FearMore Project Installer',
        [ValidateSet('OK', 'OKCancel', 'YesNoCancel')][string]$Buttons = 'OK',
        [ValidateSet('Information', 'Warning', 'Error')][string]$Icon = 'Information'
    )
    if ($NonInteractive) {
        Write-Host $Text
        return 'OK'
    }
    Add-Type -AssemblyName System.Windows.Forms
    return [string][Windows.Forms.MessageBox]::Show($Text, $Title, $Buttons, $Icon)
}

function Select-FearPublicToolsSourceFolder {
    if ($NonInteractive) { throw 'Non-interactive use requires -SdkSourceRoot.' }
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = 'Select the Source folder installed by F.E.A.R. Public Tools 1.08'
    $dialog.ShowNewFolderButton = $false
    try {
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { return $null }
        return [string]$dialog.SelectedPath
    }
    finally {
        $dialog.Dispose()
    }
}

function Test-FearPublicToolsSourceFolder {
    param([Parameter(Mandatory = $true)][string]$Path)
    $required = @(
        'Game\ClientShellDLL\GameClientShell.cpp',
        'Game\ObjectDLL\GameServerShell.cpp',
        'Game\ClientFxDLL\Game_ClientFX.vcproj',
        'engine\sdk\inc\engine.h',
        'engine\sdk\lib\win\Final\Shared_Assert.lib',
        'engine\sdk\lib\win\Final\Shared_CRC.lib',
        'libs\platform\Shared_Platform.vcproj',
        'libs\stdlith\Shared_StdLith.vcproj'
    )
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Path $_) -PathType Leaf) })
    [pscustomobject]@{ Valid = ($missing.Count -eq 0); Missing = $missing }
}

function Find-FearPublicToolsInstaller {
    $relativeCandidates = @(
        'SteamLibrary\steamapps\common\FEAR Ultimate Shooter Edition\extras\fear_publictools_108.exe',
        'Steam\steamapps\common\FEAR Ultimate Shooter Edition\extras\fear_publictools_108.exe',
        'Program Files (x86)\Steam\steamapps\common\FEAR Ultimate Shooter Edition\extras\fear_publictools_108.exe'
    )
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        foreach ($relative in $relativeCandidates) {
            $candidate = Join-Path $drive.Root $relative
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { return [IO.Path]::GetFullPath($candidate) }
        }
    }
    return $null
}

function Resolve-FearPublicToolsSource {
    param([string]$RequestedPath)

    if (-not [string]::IsNullOrWhiteSpace($RequestedPath)) {
        $candidate = [IO.Path]::GetFullPath($RequestedPath).TrimEnd('\')
        $check = Test-FearPublicToolsSourceFolder -Path $candidate
        if (-not $check.Valid) {
            throw "The selected folder is not the F.E.A.R. Public Tools 1.08 Source folder. Missing: $($check.Missing -join ', ')"
        }
        return $candidate
    }

    $knownSources = @(
        (Join-Path $env:USERPROFILE 'Documents\FEAR Public Tools\Source'),
        (Join-Path ${env:ProgramFiles(x86)} 'Sierra\FEAR Public Tools\Source')
    )
    foreach ($candidate in $knownSources) {
        if ((Test-Path -LiteralPath $candidate -PathType Container) -and
            (Test-FearPublicToolsSourceFolder -Path $candidate).Valid) {
            return [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        }
    }

    $localInstaller = Find-FearPublicToolsInstaller
    $localText = if ($localInstaller) {
        "FearMore found the official installer here:`n$localInstaller`n`nChoose No to run it."
    }
    else {
        "FearMore did not find fear_publictools_108.exe in a common Steam extras folder.`nChoose No to open the verified SDK v1.08 download page."
    }
    $choice = Show-FearMoreMessage -Buttons YesNoCancel -Icon Information -Text @"
FearMore needs the official F.E.A.R. Public Tools 1.08 SDK source. It is separate from the retail game.

$localText

Choose Yes if the SDK is already installed, then select its Source folder.
Choose No to get or run the official Public Tools installer.
Choose Cancel to stop; you can run this bootstrap again later.
"@
    if ($choice -eq 'Cancel') { throw 'Public Tools selection was cancelled.' }
    if ($choice -eq 'No') {
        if ($localInstaller) {
            $process = Start-Process -FilePath $localInstaller -Wait -PassThru
            if ($process.ExitCode -ne 0) { throw "F.E.A.R. Public Tools installer exited with code $($process.ExitCode)." }
        }
        else {
            Start-Process 'https://www.ausgamers.com/files/download/25133/fear-sdk-v108'
            Show-FearMoreMessage -Text 'The verified F.E.A.R. SDK v1.08 download page is open. Download and install fear_publictools_108.exe, then run this FearMore bootstrap again.' | Out-Null
            throw 'Public Tools must be installed before the local FearMore build can continue.'
        }
    }

    $selected = Select-FearPublicToolsSourceFolder
    if ([string]::IsNullOrWhiteSpace($selected)) { throw 'Public Tools Source folder selection was cancelled.' }
    $selected = [IO.Path]::GetFullPath($selected).TrimEnd('\')
    $selectedCheck = Test-FearPublicToolsSourceFolder -Path $selected
    if (-not $selectedCheck.Valid) {
        throw "That is not the SDK Source folder. Select the folder named Source, not the retail F.E.A.R. folder. Missing: $($selectedCheck.Missing -join ', ')"
    }
    return $selected
}

function Assert-FearMoreRepositoryCheckout {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$GitPath,
        [switch]$RequireTag
    )
    if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "Not a FearMore Git checkout: $Path" }
    $origin = [string](& $GitPath -C $Path remote get-url origin 2>$null)
    $normalizedOrigin = $origin.Trim().TrimEnd('/').ToLowerInvariant()
    $expectedOrigins = @(
        'https://github.com/sendotarget/fear-more',
        'https://github.com/sendotarget/fear-more.git',
        'git@github.com:sendotarget/fear-more',
        'git@github.com:sendotarget/fear-more.git'
    )
    if ($LASTEXITCODE -ne 0 -or $normalizedOrigin -notin $expectedOrigins) {
        throw "The existing checkout has an unexpected origin and was not modified: $Path"
    }
    $status = @(& $GitPath -C $Path status --porcelain --untracked-files=no 2>$null)
    if ($LASTEXITCODE -ne 0 -or $status.Count -gt 0) { throw "The FearMore checkout has tracked changes: $Path" }
    if ($RequireTag) {
        $head = [string](& $GitPath -C $Path rev-parse HEAD)
        $tagCommit = [string](& $GitPath -C $Path rev-list -n 1 $ReleaseTag 2>$null)
        if ($LASTEXITCODE -ne 0 -or $head.Trim() -cne $tagCommit.Trim()) {
            throw "The checkout is not the exact $ReleaseTag release: $Path"
        }
    }
}

try {
    $intro = Show-FearMoreMessage -Buttons OKCancel -Text @"
This bootstrap builds the FearMore Project Installer on your own PC.

You need a legally acquired F.E.A.R. v1.08 copy. The bootstrap may download several gigabytes of public build tools and will request Windows administrator approval for those tools. It contains no game, SDK, HD-texture, or compiled mod binaries.
"@
    if ($intro -eq 'Cancel') { throw 'FearMore bootstrap was cancelled.' }

    $prerequisites = Get-FearMoreBootstrapPrerequisiteState
    if (-not $prerequisites.Ready -and -not $SkipPrerequisiteInstall) {
        $permission = Show-FearMoreMessage -Buttons OKCancel -Icon Warning -Text ("These required tools are missing:`n`n- " + ($prerequisites.Missing -join "`n- ") + "`n`nChoose OK to install them from their public WinGet packages. Windows may request administrator approval.")
        if ($permission -eq 'Cancel') { throw 'Prerequisite installation was cancelled.' }
        $prerequisites = Install-FearMoreBootstrapPrerequisites -Confirm:$false
    }
    if (-not $prerequisites.Ready) {
        throw "Required build tools are missing: $($prerequisites.Missing -join ', ')."
    }

    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        $RepositoryRoot = Join-Path $env:LOCALAPPDATA "FearMore\ProjectSources\$ReleaseTag\FEAR-MORE"
        if (-not (Test-Path -LiteralPath $RepositoryRoot)) {
            $parent = Split-Path $RepositoryRoot -Parent
            [IO.Directory]::CreateDirectory($parent) | Out-Null
            if (-not $PSCmdlet.ShouldProcess($RepositoryRoot, "Clone the exact FearMore $ReleaseTag source and pinned submodules")) {
                throw 'FearMore source checkout was not created.'
            }
            $cloneRoot = Join-Path $parent ('.FEAR-MORE.' + [guid]::NewGuid().ToString('N') + '.cloning')
            try {
                & $prerequisites.GitPath clone --branch $ReleaseTag --depth 1 --recurse-submodules $RepositoryUrl $cloneRoot | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "FearMore $ReleaseTag clone failed." }
                Assert-FearMoreRepositoryCheckout -Path $cloneRoot -GitPath $prerequisites.GitPath -RequireTag
                if (Test-Path -LiteralPath $RepositoryRoot) { throw "FearMore checkout destination appeared concurrently: $RepositoryRoot" }
                [IO.Directory]::Move($cloneRoot, $RepositoryRoot)
            }
            finally {
                if (Test-Path -LiteralPath $cloneRoot -PathType Container) { [IO.Directory]::Delete($cloneRoot, $true) }
            }
        }
        Assert-FearMoreRepositoryCheckout -Path $RepositoryRoot -GitPath $prerequisites.GitPath -RequireTag
    }
    else {
        $RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
        Assert-FearMoreRepositoryCheckout -Path $RepositoryRoot -GitPath $prerequisites.GitPath
    }

    $SdkSourceRoot = Resolve-FearPublicToolsSource -RequestedPath $SdkSourceRoot
    if ([string]::IsNullOrWhiteSpace($LauncherRoot)) { $LauncherRoot = Join-Path $RepositoryRoot 'dist\local\FearMore-Playable' }
    if ([string]::IsNullOrWhiteSpace($OutputRoot)) { $OutputRoot = Join-Path $RepositoryRoot 'dist\local\FearMore-Project-Installer' }
    $setupPath = Join-Path $OutputRoot 'FearMore-Setup.exe'

    if (-not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
        if (-not $PSCmdlet.ShouldProcess($OutputRoot, 'Build the local FearMore playable launcher and Project Installer')) {
            throw 'Local FearMore Project Installer build was not started.'
        }
        $results = @(& (Join-Path $RepositoryRoot 'tools\public\Build-FearMorePublicProject.ps1') `
                -RepositoryRoot $RepositoryRoot `
                -SdkSourceRoot $SdkSourceRoot `
                -CMakePath $prerequisites.CMakePath `
                -LauncherRoot $LauncherRoot `
                -OutputRoot $OutputRoot `
                -IsccPath $prerequisites.IsccPath `
                -WithoutHdLite)
        $passing = @($results | Where-Object { $_ -is [psobject] -and $_.PSObject.Properties['Status'] -and $_.Status -ceq 'PASS' })
        if ($passing.Count -ne 1 -or -not (Test-Path -LiteralPath $setupPath -PathType Leaf)) {
            throw 'The local FearMore Project Installer build did not produce one verified setup.'
        }
    }

    Show-FearMoreMessage -Text "FearMore was built successfully on this PC.`n`nSetup: $setupPath`n`nThe setup will now install the one-click Modern and Stable launch shortcuts." | Out-Null
    if (-not $DoNotLaunchInstaller) {
        Start-Process -FilePath $setupPath | Out-Null
    }
    [pscustomobject]@{ Status = 'PASS'; SetupPath = $setupPath; RepositoryRoot = $RepositoryRoot; SdkSourceRoot = $SdkSourceRoot; LogPath = $logPath }
}
catch {
    $message = "$($_.Exception.Message)`n`nLog: $logPath"
    Show-FearMoreMessage -Text $message -Icon Error | Out-Null
    throw
}
finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
