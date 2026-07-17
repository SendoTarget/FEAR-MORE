[CmdletBinding()]
param(
    [string]$RepositoryRoot,
    [ValidateSet('Release', 'Debug')]
    [string]$Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

$stageScript = Join-Path $PSScriptRoot 'New-FearRuntimeStage.ps1'
$sdkRuntime = Join-Path $RepositoryRoot 'vendor-local\fear-sdk-108\Runtime\FEARDevSP.exe'
$buildRoot = Join-Path $RepositoryRoot "build\fear-win32\bin\$Configuration"
$localRuntimeRoot = Join-Path $RepositoryRoot 'local-runtime'
foreach ($requiredPath in @(
        $stageScript,
        $sdkRuntime,
        (Join-Path $buildRoot 'GameClient.dll'),
        (Join-Path $buildRoot 'GameServer.dll'),
        (Join-Path $buildRoot 'ClientFx.fxd'))) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "WhatIf regression input is missing: $requiredPath"
    }
}
if (-not (Test-Path -LiteralPath $localRuntimeRoot -PathType Container)) {
    throw "WhatIf regression requires the existing ignored local-runtime root: $localRuntimeRoot"
}

$runId = [Guid]::NewGuid().ToString('N')
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) "fearmore-runtime-whatif-$runId"
$stageRoot = Join-Path $localRuntimeRoot "runtime-tool-whatif-regression-$runId"
if (Test-Path -LiteralPath $stageRoot) {
    throw "Unique WhatIf regression stage unexpectedly exists: $stageRoot"
}

try {
    [void][IO.Directory]::CreateDirectory($fixtureRoot)
    [IO.File]::Copy($sdkRuntime, (Join-Path $fixtureRoot 'FEAR.exe'), $false)
    foreach ($fileName in @('EngineServer.dll', 'GameDatabase.dll', 'LTMemory.dll', 'SndDrv.dll', 'StringEditRuntime.dll')) {
        [IO.File]::WriteAllBytes((Join-Path $fixtureRoot $fileName), [byte[]](0x46, 0x45, 0x41, 0x52))
    }
    [IO.File]::WriteAllBytes((Join-Path $fixtureRoot 'FEAR.Arch00'), [byte[]](0x46, 0x45, 0x41, 0x52))
    [IO.File]::WriteAllLines((Join-Path $fixtureRoot 'Default.archcfg'), @('FEAR.Arch00'), [Text.ASCIIEncoding]::new())
    $expectedRetailHash = (Get-FileHash -LiteralPath (Join-Path $fixtureRoot 'FEAR.exe') -Algorithm SHA256).Hash

    try {
        $result = & $stageScript `
            -Lane Rebuilt `
            -Configuration $Configuration `
            -RepositoryRoot $RepositoryRoot `
            -RetailRoot $fixtureRoot `
            -BuildRoot $buildRoot `
            -StageRoot $stageRoot `
            -WhatIf
    }
    catch {
        if ($_.Exception.Message -match "property 'Hash' cannot be found") {
            throw "WhatIf suppressed a read-only Get-FileHash result during runtime preflight: $($_.Exception.Message)"
        }
        throw
    }

    if (Test-Path -LiteralPath $stageRoot) {
        throw "WhatIf mutated the new stage path: $stageRoot"
    }
    if (-not $result.InputsValidated -or $result.LayoutValidated -or $result.LaunchPermitted -or
        $result.RuntimeExecutableState -ne 'NotStaged' -or
        $result.RetailExecutableSha256 -cne $expectedRetailHash) {
        throw 'WhatIf did not return the complete read-only validation identity while withholding stage completion.'
    }

    "Fear runtime WhatIf regression check passed ($Configuration): validation hashes were produced and no stage path was created."
}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        $canonicalFixtureRoot = [IO.Path]::GetFullPath($fixtureRoot).TrimEnd('\')
        $canonicalTempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
        if (-not $canonicalFixtureRoot.StartsWith($canonicalTempRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path $canonicalFixtureRoot -Leaf) -cne "fearmore-runtime-whatif-$runId") {
            throw "Refusing to remove an unexpected WhatIf fixture path: $canonicalFixtureRoot"
        }
        Remove-Item -LiteralPath $canonicalFixtureRoot -Recurse -Force
    }
}
