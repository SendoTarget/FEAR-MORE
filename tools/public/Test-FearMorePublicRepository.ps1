[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\')
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $git) { throw 'Git is required for the public repository boundary test.' }

$candidateFiles = @(& $git.Source -C $RepositoryRoot ls-files --cached --others --exclude-standard)
if ($LASTEXITCODE -ne 0 -or $candidateFiles.Count -lt 1) {
    throw 'Public repository candidate files could not be enumerated.'
}
$candidateFiles = @($candidateFiles | ForEach-Object { ([string]$_).Replace('/', '\') } | Sort-Object -Unique)

$forbiddenRoots = @('FEAR\', 'vendor-local\', 'build\', 'dist\', 'local-runtime\', 'retail\')
$forbiddenExtensions = @(
    '.exe', '.dll', '.fxd', '.lib', '.pdb', '.obj', '.zip', '.7z', '.rar',
    '.arch00', '.dds', '.hdr', '.png', '.jpg', '.jpeg', '.wav', '.mp3', '.ogg', '.dmp'
)
foreach ($relativePath in $candidateFiles) {
    foreach ($root in $forbiddenRoots) {
        if ($relativePath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Public repository candidate crosses a local/generated boundary: $relativePath"
        }
    }
    $extension = [IO.Path]::GetExtension($relativePath).ToLowerInvariant()
    if ($extension -in $forbiddenExtensions) {
        throw "Public repository candidate contains a prohibited binary/game-asset extension: $relativePath"
    }
}

$patchPath = Join-Path $RepositoryRoot 'source-patches\fearmore-game-modules.patch'
$expectedPatchSha256 = 'B3E130DDB0DF8D398576E694E6C68A508892EB19A4E6DAF91E4B30E732CA81C5'
$actualPatchSha256 = (Get-FileHash -LiteralPath $patchPath -Algorithm SHA256).Hash
if ($actualPatchSha256 -cne $expectedPatchSha256) {
    throw "Public source patch identity changed. Expected $expectedPatchSha256 but found $actualPatchSha256."
}
$patchText = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($patchPath))
$patchTargetCount = @([regex]::Matches($patchText, '(?m)^diff --git ')).Count
if ($patchTargetCount -ne 64) {
    throw "Public source patch must contain exactly 64 modified SDK paths; found $patchTargetCount."
}
$overlayFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'source-overlay\Game') -File -Recurse)
if ($overlayFiles.Count -ne 24) {
    throw "Public source overlay must contain exactly 24 new project files; found $($overlayFiles.Count)."
}
$scaffoldFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'source-scaffold') -File -Recurse)
if ($scaffoldFiles.Count -ne 6) {
    throw "Public source scaffold must contain exactly 6 project files; found $($scaffoldFiles.Count)."
}

$submoduleRecord = @(& $git.Source -C $RepositoryRoot ls-files --stage -- external/EchoPatch)
if ($LASTEXITCODE -ne 0 -or $submoduleRecord.Count -ne 1 -or
    [string]$submoduleRecord[0] -notmatch '^160000 b4a7074e4cbb2fb6bb238809f7cf26424f1f5961 ') {
    throw 'external/EchoPatch is not staged as the exact required b4a7074 gitlink.'
}

$forbiddenText = @(
    ('C:\Users\' + 'sendo'),
    ('CODEX' + '-stuff'),
    ('https://github.com/SendoTarget/' + 'FearMore'),
    ('The GitHub project is ' + 'private'),
    ('keep the repository ' + 'private')
)
foreach ($relativePath in $candidateFiles) {
    if ($relativePath -eq 'external\EchoPatch') { continue }
    $fullPath = Join-Path $RepositoryRoot $relativePath
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { continue }
    $bytes = [IO.File]::ReadAllBytes($fullPath)
    if ($bytes.Length -gt 5MB) {
        throw "Public repository text candidate exceeds the review size limit: $relativePath"
    }
    $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    foreach ($needle in $forbiddenText) {
        if ($text.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            throw "Public repository candidate contains private/personal text '$needle': $relativePath"
        }
    }
}

$requiredPaths = @(
    '.gitattributes',
    'README.md',
    'QUICKSTART.md',
    'CREDITS.md',
    'Build FearMore Project Installer.cmd',
    'tools\bootstrap\Bootstrap-FearMoreProject.ps1',
    'tools\bootstrap\Build-FearMoreBootstrapRelease.ps1',
    'tools\bootstrap\Test-FearMoreBootstrap.ps1',
    'tools\public\Build-FearMorePublicProject.ps1',
    'tools\public\Get-FearMorePublicDependencies.ps1',
    'tools\public\Initialize-FearMoreModuleSource.ps1',
    'docs\project-installer.md'
)
foreach ($relativePath in $requiredPaths) {
    if ($candidateFiles -notcontains $relativePath) {
        throw "Public repository candidate is missing required path: $relativePath"
    }
}

$gitAttributes = Get-Content -LiteralPath (Join-Path $RepositoryRoot '.gitattributes') -Raw
foreach ($requiredRule in @(
        '/tools/echopatch/*.ini text eol=lf',
        '/tools/runtime/config/*.conf text eol=lf',
        '/tools/runtime/postprocess/** text eol=lf'
    )) {
    if ($gitAttributes.IndexOf($requiredRule, [StringComparison]::Ordinal) -lt 0) {
        throw "Public repository is missing the hash-attested checkout rule: $requiredRule"
    }
}

[pscustomobject]@{
    Status             = 'PASS'
    CandidateFileCount = $candidateFiles.Count
    PatchTargetCount   = $patchTargetCount
    OverlayFileCount   = $overlayFiles.Count
    ScaffoldFileCount  = $scaffoldFiles.Count
    EchoPatchCommit    = 'b4a7074e4cbb2fb6bb238809f7cf26424f1f5961'
    ProhibitedFiles    = 0
    PersonalPaths      = 0
}
