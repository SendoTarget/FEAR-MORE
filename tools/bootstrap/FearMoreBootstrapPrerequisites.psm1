Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-FirstExistingFile {
    param([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    return $null
}

function Get-FearMoreBootstrapGitPath {
    $command = Get-Command git.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return Get-FirstExistingFile -Candidates @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\cmd\git.exe')
    )
}

function Get-FearMoreBootstrapCMakePath {
    $command = Get-Command cmake.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return Get-FirstExistingFile -Candidates @(
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'),
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe')
    )
}

function Get-FearMoreBootstrapIsccPath {
    $command = Get-Command ISCC.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return Get-FirstExistingFile -Candidates @(
        (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 7\ISCC.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe')
    )
}

function Get-VisualStudioBuildToolsPath {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { return $null }
    $result = @(& $vswhere -latest -products Microsoft.VisualStudio.Product.BuildTools -property installationPath 2>$null)
    if ($LASTEXITCODE -ne 0 -or $result.Count -lt 1) { return $null }
    $path = [string]$result[0]
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path -PathType Container)) {
        return $null
    }
    return [IO.Path]::GetFullPath($path)
}

function Test-FearMoreBootstrapV141 {
    $installPath = Get-VisualStudioBuildToolsPath
    if (-not $installPath) { return $false }
    $candidates = @(
        (Join-Path $installPath 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.v141.default.txt'),
        (Join-Path $installPath 'MSBuild\Microsoft\VC\v150\Platforms\Win32\PlatformToolsets\v141\Toolset.props'),
        (Join-Path $installPath 'MSBuild\Microsoft\VC\v160\Platforms\Win32\PlatformToolsets\v141\Toolset.props'),
        (Join-Path $installPath 'MSBuild\Microsoft\VC\v170\Platforms\Win32\PlatformToolsets\v141\Toolset.props')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $true }
    }
    return $false
}

function Get-FearMoreBootstrapPrerequisiteState {
    $gitPath = Get-FearMoreBootstrapGitPath
    $cmakePath = Get-FearMoreBootstrapCMakePath
    $isccPath = Get-FearMoreBootstrapIsccPath
    $buildToolsPath = Get-VisualStudioBuildToolsPath
    $hasV141 = Test-FearMoreBootstrapV141
    $missing = [Collections.Generic.List[string]]::new()
    if (-not $gitPath) { $missing.Add('Git for Windows') }
    if (-not $buildToolsPath) { $missing.Add('Visual Studio 2022 Build Tools') }
    if (-not $cmakePath) { $missing.Add('Visual Studio CMake tools') }
    if (-not $hasV141) { $missing.Add('MSVC v141 x86/x64 toolset') }
    if (-not $isccPath) { $missing.Add('Inno Setup 7') }

    [pscustomobject]@{
        Ready          = ($missing.Count -eq 0)
        Missing        = @($missing)
        GitPath        = $gitPath
        CMakePath      = $cmakePath
        IsccPath       = $isccPath
        BuildToolsPath = $buildToolsPath
        HasV141        = $hasV141
    }
}

function Invoke-WinGetExactInstall {
    param(
        [Parameter(Mandatory = $true)][string]$WinGetPath,
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Override
    )

    $arguments = @(
        'install', '--id', $Id, '--exact', '--source', 'winget',
        '--accept-package-agreements', '--accept-source-agreements',
        '--disable-interactivity'
    )
    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        $arguments += @('--override', $Override)
    }
    & $WinGetPath @arguments | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw "WinGet could not install '$Id' (exit $LASTEXITCODE)."
    }
}

function Install-FearMoreBootstrapPrerequisites {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param()

    $state = Get-FearMoreBootstrapPrerequisiteState
    if ($state.Ready) { return $state }
    $winget = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
        throw 'WinGet is unavailable. Install Microsoft App Installer, then run the FearMore bootstrap again.'
    }
    if (-not $PSCmdlet.ShouldProcess(
            ($state.Missing -join ', '),
            'Download and install the required public build tools with WinGet')) {
        return $state
    }

    if (-not $state.GitPath) {
        Invoke-WinGetExactInstall -WinGetPath $winget.Source -Id 'Git.Git'
    }
    if (-not $state.IsccPath) {
        Invoke-WinGetExactInstall -WinGetPath $winget.Source -Id 'JRSoftware.InnoSetup.7'
    }
    if (-not $state.BuildToolsPath) {
        $override = '--wait --passive --norestart --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --add Microsoft.VisualStudio.Component.VC.v141.x86.x64'
        Invoke-WinGetExactInstall -WinGetPath $winget.Source -Id 'Microsoft.VisualStudio.2022.BuildTools' -Override $override
    }
    elseif (-not $state.HasV141 -or -not $state.CMakePath) {
        $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\setup.exe'
        if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
            throw 'Visual Studio Installer could not be found to add the required C++ components.'
        }
        $arguments = @(
            'modify', '--installPath', $state.BuildToolsPath, '--passive', '--norestart',
            '--add', 'Microsoft.VisualStudio.Workload.VCTools', '--includeRecommended',
            '--add', 'Microsoft.VisualStudio.Component.VC.v141.x86.x64'
        )
        $process = Start-Process -FilePath $installer -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Visual Studio Installer could not add the required C++ components (exit $($process.ExitCode))."
        }
    }

    $result = Get-FearMoreBootstrapPrerequisiteState
    if (-not $result.Ready) {
        throw "Prerequisite setup finished, but these items are still missing: $($result.Missing -join ', '). A Windows restart may be required."
    }
    return $result
}

Export-ModuleMember -Function @(
    'Get-FearMoreBootstrapGitPath',
    'Get-FearMoreBootstrapCMakePath',
    'Get-FearMoreBootstrapIsccPath',
    'Test-FearMoreBootstrapV141',
    'Get-FearMoreBootstrapPrerequisiteState',
    'Install-FearMoreBootstrapPrerequisites'
)
