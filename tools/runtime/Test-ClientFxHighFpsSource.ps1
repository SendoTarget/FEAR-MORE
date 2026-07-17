[CmdletBinding()]
param([string]$RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RequiredFunctionBody {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Signature,
        [Parameter(Mandatory = $true)][string]$NextMarker
    )

    $start = $Source.IndexOf($Signature, [StringComparison]::Ordinal)
    if ($start -lt 0) {
        throw "ClientFX source is missing function '$Signature'."
    }
    $end = $Source.IndexOf($NextMarker, $start + $Signature.Length, [StringComparison]::Ordinal)
    if ($end -lt 0) {
        throw "ClientFX source is missing the boundary after '$Signature'."
    }
    return $Source.Substring($start, $end - $start)
}

function Assert-ContainsExactlyOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $count = ([regex]::Matches($Text, [regex]::Escape($Token))).Count
    if ($count -ne 1) {
        throw "$Description must occur exactly once; found $count."
    }
}

function Assert-MatchesExactlyOnce {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Description
    )

    $count = ([regex]::Matches($Text, $Pattern)).Count
    if ($count -ne 1) {
        throw "$Description must occur exactly once; found $count."
    }
}

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
$clientFxRoot = Join-Path $RepositoryRoot 'FEAR\Dev\Source\FEAR\ClientFxDLL'

$systemPath = Join-Path $clientFxRoot 'ParticleSystemFX.cpp'
$groupPath = Join-Path $clientFxRoot 'ParticleSystemGroup.cpp'
$systemSource = [IO.File]::ReadAllText($systemPath)
$groupSource = [IO.File]::ReadAllText($groupPath)

$updateBody = Get-RequiredFunctionBody `
    -Source $systemSource `
    -Signature 'void CParticleSystemFX::UpdateParticles(float tmDelta' `
    -NextMarker '//called to determine if there are any more particles in this effect'
if ($updateBody.Contains('kfMinParticleUpdate') -or
    $updateBody -match 'if\s*\(\s*tmDelta\s*<') {
    throw 'Particle updates still discard a positive high-frame-rate delta before group simulation.'
}
Assert-ContainsExactlyOnce `
    -Text $updateBody `
    -Token 'pGroup->UpdateParticles(tmDelta, vGravity, fFrictionCoef, tObjTrans);' `
    -Description 'Per-group particle simulation call'

$markerBody = Get-RequiredFunctionBody `
    -Source $groupSource `
    -Signature 'void CParticleSystemGroup::AddParticleBatchMarker(float fUpdateTime, bool bDefault)' `
    -NextMarker '//called to emit a batch of particles given the properties'
Assert-MatchesExactlyOnce `
    -Text $markerBody `
    -Pattern 'pParticle->m_fLifetime\s*=\s*0\.0f;' `
    -Description 'Expired batch-marker lifetime initialization'
if ($markerBody -match 'm_fLifetime\s*=\s*-') {
    throw 'Particle batch markers still begin with a negative lifetime and can over-age high-FPS batches.'
}
Assert-ContainsExactlyOnce `
    -Text $markerBody `
    -Token 'pParticle->m_fTotalLifetime = fUpdateTime;' `
    -Description 'Batch update-time preservation'

[pscustomobject]@{
    Status                    = 'PASS'
    SubMillisecondUpdates     = 'Simulated'
    BatchMarkerLifetime       = 'ZeroExpired'
    AuthoredUpdateTime        = 'Preserved'
    SourceFiles               = @($systemPath, $groupPath)
}
