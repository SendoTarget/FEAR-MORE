[CmdletBinding()]
param([string]$DownloadDirectory)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$runtimeKey = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\VisualStudio\14.0\VC\Runtimes\x86'

function Test-FearMoreVCRuntimeInstalled {
    try {
        return [int](Get-ItemPropertyValue -LiteralPath $runtimeKey -Name Installed -ErrorAction Stop) -eq 1
    }
    catch {
        return $false
    }
}

if (Test-FearMoreVCRuntimeInstalled) {
    return [pscustomobject]@{ Installed = $true; Downloaded = $false; RestartRequired = $false }
}
if ([string]::IsNullOrWhiteSpace($DownloadDirectory)) {
    $DownloadDirectory = Join-Path ([IO.Path]::GetTempPath()) 'FearMore'
}
$DownloadDirectory = [IO.Path]::GetFullPath($DownloadDirectory)
[IO.Directory]::CreateDirectory($DownloadDirectory) | Out-Null
$installer = Join-Path $DownloadDirectory 'vc_redist.x86.exe'
$temporary = Join-Path $DownloadDirectory ('vc_redist.x86.' + [guid]::NewGuid().ToString('N') + '.download.exe')

try {
    Invoke-WebRequest -UseBasicParsing -Uri 'https://aka.ms/vc14/vc_redist.x86.exe' -OutFile $temporary
    $item = Get-Item -LiteralPath $temporary -Force
    if ($item.Length -lt 5MB -or $item.Length -gt 100MB) {
        throw "The downloaded Microsoft Visual C++ x86 runtime has an unexpected size: $($item.Length) bytes."
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $temporary
    if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid -or
        -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch 'Microsoft Corporation') {
        throw 'The downloaded Visual C++ x86 runtime does not have a valid Microsoft Authenticode signature.'
    }
    if (Test-Path -LiteralPath $installer -PathType Leaf) {
        [IO.File]::Delete($installer)
    }
    [IO.File]::Move($temporary, $installer)
    $process = Start-Process `
        -FilePath $installer `
        -ArgumentList @('/install', '/passive', '/norestart') `
        -Verb RunAs `
        -Wait `
        -PassThru
    if ($process.ExitCode -notin @(0, 3010, 1638) -or -not (Test-FearMoreVCRuntimeInstalled)) {
        throw "Microsoft Visual C++ x86 runtime setup did not complete successfully (exit code $($process.ExitCode))."
    }
    [pscustomobject]@{
        Installed       = $true
        Downloaded      = $true
        RestartRequired = $process.ExitCode -eq 3010
    }
}
finally {
    foreach ($path in @($temporary, $installer)) {
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            [IO.File]::Delete($path)
        }
    }
}
