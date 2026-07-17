[CmdletBinding()]
param(
    [string]$RepositoryRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

function Get-RequiredSource {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Effects-target source input is missing: $path"
    }

    return Get-Content -LiteralPath $path -Raw
}

function Assert-LiteralsInOrder {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string[]]$Literals,
        [Parameter(Mandatory = $true)][string]$Failure
    )

    $searchFrom = 0
    foreach ($literal in $Literals) {
        $index = $Source.IndexOf($literal, $searchFrom, [StringComparison]::Ordinal)
        if ($index -lt 0) {
            throw "$Failure Missing or out-of-order token: $literal"
        }
        $searchFrom = $index + $literal.Length
    }
}

function Get-SourceSection {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Start,
        [Parameter(Mandatory = $true)][string]$End,
        [Parameter(Mandatory = $true)][string]$Name
    )

    $startIndex = $Source.IndexOf($Start, [StringComparison]::Ordinal)
    if ($startIndex -lt 0) {
        throw "$Name start marker is missing: $Start"
    }

    $endIndex = $Source.IndexOf($End, $startIndex + $Start.Length, [StringComparison]::Ordinal)
    if ($endIndex -lt 0) {
        throw "$Name end marker is missing: $End"
    }

    return $Source.Substring($startIndex, $endIndex - $startIndex)
}

function Get-ExpectedDimensions {
    param(
        [Parameter(Mandatory = $true)][int]$Quality,
        [Parameter(Mandatory = $true)][uint32]$NativeWidth,
        [Parameter(Mandatory = $true)][uint32]$NativeHeight
    )

    $isPowerOfTwoWidth = $NativeWidth -ne 0 -and (($NativeWidth -band ($NativeWidth - 1)) -eq 0)
    $isPowerOfTwoHeight = $NativeHeight -ne 0 -and (($NativeHeight -band ($NativeHeight - 1)) -eq 0)
    $canScale = $Quality -eq 1 -and
        $NativeWidth -ge 4 -and $NativeHeight -ge 4 -and
        $isPowerOfTwoWidth -and $isPowerOfTwoHeight -and
        $NativeWidth -le 1024 -and $NativeHeight -le 1024

    return [pscustomobject]@{
        Width = if ($canScale) { $NativeWidth * 2 } else { $NativeWidth }
        Height = if ($canScale) { $NativeHeight * 2 } else { $NativeHeight }
        Upscaled = $canScale
    }
}

$settingsHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreGraphicsSettings.h'
$settingsSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreGraphicsSettings.cpp'
$gameClientShell = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\GameClientShell.cpp'
$screenSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenDisplay.cpp'
$profileSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ProfileMgr.cpp'
$volumetricSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\VolumetricLightFX.cpp'
$targetGroupSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\RenderTargetGroupFx.cpp'
$targetFxSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\RenderTargetFX.cpp'
$sfxMgrSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\SFXMgr.cpp'
$clientCMake = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\CMakeLists.txt'

Assert-LiteralsInOrder $settingsHeader @(
    'eOption_EffectsTargetQuality',
    'eEffectsTargetQuality_Native = 0',
    'eEffectsTargetQuality_High = 1',
    'CaptureRestartBoundSettings',
    'GetActiveEffectsTargetQuality',
    'GetEffectsTargetDimensions'
) 'The source-owned effects-target contract changed unexpectedly.'

Assert-LiteralsInOrder $settingsSource @(
    '"FearMoreEffectsTargetQuality"',
    'L"Effects target quality"',
    'FearMoreGraphicsSettings::eEffectsTargetQuality_Native',
    'FearMoreGraphicsSettings::eEffectsTargetQuality_High',
    'kMinimumEffectsTargetDimension = 4',
    'kMaximumEffectsTargetDimension = 2048',
    '!IsPowerOfTwo(nNativeWidth)',
    '!IsPowerOfTwo(nNativeHeight)',
    'nTargetWidth = nNativeWidth * 2',
    'nTargetHeight = nNativeHeight * 2',
    'L"High (next launch)"'
) 'Native/High mapping or its atomic dimension guards changed unexpectedly.'

$captureSection = Get-SourceSection $settingsSource `
    'void CaptureRestartBoundSettings()' `
    'int GetActiveEffectsTargetQuality()' `
    'restart-bound capture'
Assert-LiteralsInOrder $captureSection @(
    'if (s_bRestartBoundSettingsCaptured)',
    'GetConsoleInt(descriptor.m_pszConsoleVariable, descriptor.m_nDefaultValue)',
    's_bRestartBoundSettingsCaptured = true;'
) 'Effects target quality is no longer captured once per process.'

$engineInit = Get-SourceSection $gameClientShell `
    'uint32 CGameClientShell::OnEngineInitialized' `
    'if(!InitResourceMgr())' `
    'client startup capture'
if (-not $engineInit.Contains('FearMoreGraphicsSettings::CaptureRestartBoundSettings();')) {
    throw 'Restart-bound effects quality is not captured before client resources and world effects initialize.'
}

Assert-LiteralsInOrder $screenSource @(
    'GetOptionDescriptor(FearMoreGraphicsSettings::eOption_EffectsTargetQuality)',
    'AddCycle(effectsTargetQuality.m_pwszLabel,effectsTargetQualityCreate)',
    'eEffectsTargetQuality_Native',
    'eEffectsTargetQuality_High',
    'GetConsoleInt(effectsTargetQuality.m_pszConsoleVariable,effectsTargetQuality.m_nDefaultValue)',
    'WriteConsoleInt(effectsTargetQuality.m_pszConsoleVariable,(int)m_nFearMoreEffectsTargetQuality);'
) 'Display no longer exposes and persists the restart-bound Native/High cycle.'

$saveSettings = Get-SourceSection $profileSource `
    'void SaveSettings()' `
    '//-------------------------------------------------------------------------------------------' `
    'settings.cfg whitelist'
if (-not $saveSettings.Contains('"FearMoreEffectsTargetQuality"')) {
    throw 'settings.cfg no longer persists FearMoreEffectsTargetQuality.'
}

foreach ($owner in @('RenderTargetGroupFx.cpp', 'RenderTargetFX.cpp', 'VolumetricLightFX.cpp')) {
    if (@($clientCMake -split "`n" | Where-Object { $_ -match ('^\s*' + [regex]::Escape($owner) + '\s*$') }).Count -ne 1) {
        throw "$owner must appear exactly once in the active ClientShell target."
    }
}

Assert-LiteralsInOrder $sfxMgrSource @(
    'case SFX_RENDERTARGET_ID :',
    'g_SFXBank_RenderTarget.New()',
    'case SFX_RENDERTARGETGROUP_ID :',
    'g_SFXBank_RenderTargetGroup.New()',
    'void CSFXMgr::UpdateRenderTargets',
    'GetFXList(SFX_RENDERTARGET_ID)'
) 'The live SFX creation/update route for authored render targets is no longer present.'

Assert-LiteralsInOrder $sfxMgrSource @(
    '#include "VolumetricLightFX.h"',
    'CBankedList<CVolumetricLightFX> g_SFXBank_VolumetricLight;',
    'case SFX_VOLUMETRICLIGHT_ID:',
    'VOLUMETRICLIGHTCREATESTRUCT cs;',
    'case SFX_VOLUMETRICLIGHT_ID :',
    'pSFX = g_SFXBank_VolumetricLight.New();'
) 'The volumetric-light allocation owner is no longer reachable through the live SFX bank.'

Assert-LiteralsInOrder $targetFxSource @(
    'm_pRenderTargetGroup->GetRenderTarget()',
    'else if(m_bMirror)',
    'UpdateRenderTargetMirror(hRenderTarget, tCamera, vCameraFOV)',
    'else if(m_bRefraction)',
    'UpdateRenderTargetRefraction(hRenderTarget, tCamera, vCameraFOV)'
) 'The target group is no longer the live surface owner for mirrors/refractions.'

$groupAllocation = Get-SourceSection $targetGroupSource `
    'bool CRenderTargetGroupFX::CreateRenderTarget(uint32 nLOD)' `
    'bool CRenderTargetGroupFX::ReleaseRenderTarget()' `
    'generic target allocation'
Assert-LiteralsInOrder $groupAllocation @(
	'projection and',
	'sampling contract is tied to the authored dimensions',
	'm_nDimensions[nLOD].x, m_nDimensions[nLOD].y, nRTFlags, m_hRenderTarget'
) 'Generic mirror/reflection targets no longer preserve their authored sampling dimensions.'
if ($groupAllocation -match 'GetEffectsTargetDimensions\(' -or
	$groupAllocation -match 'GetActiveEffectsTargetQuality\(') {
	throw 'Effects Target: High must not resize authored mirror/reflection targets.'
}

if ($groupAllocation -notmatch 'g_vtRenderTargetLOD' -and
    $targetGroupSource -notmatch 'g_vtRenderTargetLOD\.Init\(g_pLTBase, "RenderTargetLOD", NULL, 2\.0f\)') {
    throw 'The established authored RenderTargetLOD selection was replaced or bypassed.'
}

$volumetricAllocation = Get-SourceSection $volumetricSource `
    'bool LockRenderTarget(uint32 nToken' `
    '// Let go of a render target set' `
    'volumetric target allocation'
Assert-LiteralsInOrder $volumetricAllocation @(
    'const uint32 nNativeShadowRes = (uint32)g_cvarVolumetricLightShadowRes.GetFloat();',
    'GetActiveEffectsTargetQuality()',
    'nNativeShadowRes, nNativeShadowRes',
    'm_nCurShadowRes != nRequestedShadowWidth',
    'm_nCurNativeShadowRes != nNativeShadowRes',
    'uint32 nAllocationShadowRes = m_nAllocatedShadowRes ? m_nAllocatedShadowRes : m_nCurShadowRes;',
    'CreateRenderTarget(nAllocationShadowRes, nAllocationShadowRes, eRTO_DepthBuffer, hShadowBuffer)',
    'nAllocationShadowRes != nNativeShadowRes',
    'nAllocationShadowRes = nNativeShadowRes;',
    'CreateRenderTarget(nNativeShadowRes, nNativeShadowRes, eRTO_DepthBuffer, hShadowBuffer)',
    'm_nAllocatedShadowRes = nAllocationShadowRes;',
    'LTVector2 vSliceRes = GetSliceBufferRes()',
    'CreateRenderTarget((uint32)vSliceRes.x, (uint32)vSliceRes.y'
) 'Volumetric shadow target lost guarded High allocation/native fallback or slice allocation was displaced.'
Assert-LiteralsInOrder $volumetricAllocation @(
    'm_nCurNativeShadowRes = nNativeShadowRes;',
    'FlushRenderTargets();',
    'm_nAllocatedShadowRes = nAllocationShadowRes;'
) 'Volumetric shadow target no longer distinguishes requested/native configuration from the actual fallback allocation.'
if ($volumetricSource -notmatch 'void FlushRenderTargets\(\)\s*\{\s*m_nAllocatedShadowRes\s*=\s*0;') {
    throw 'Volumetric shadow allocation metadata is not cleared with its render targets.'
}

if (($volumetricAllocation | Select-String -Pattern 'GetEffectsTargetDimensions\(' -AllMatches).Matches.Count -ne 1) {
    throw 'Effects target quality must scale only the proven volumetric shadow target, not the slice target.'
}
if ($volumetricSource -notmatch 'vResult\.x = \(float\)m_nCurSliceRes;\s*vResult\.y = vResult\.x \* 0\.75f;') {
    throw 'Volumetric slice-buffer dimensions changed unexpectedly.'
}

$dimensionCases = @(
    [pscustomobject]@{ Quality = 0; Width = 128; Height = 128; ExpectedWidth = 128; ExpectedHeight = 128; Upscaled = $false },
    [pscustomobject]@{ Quality = 1; Width = 128; Height = 128; ExpectedWidth = 256; ExpectedHeight = 256; Upscaled = $true },
    [pscustomobject]@{ Quality = 1; Width = 512; Height = 256; ExpectedWidth = 1024; ExpectedHeight = 512; Upscaled = $true },
    [pscustomobject]@{ Quality = 1; Width = 1024; Height = 1024; ExpectedWidth = 2048; ExpectedHeight = 2048; Upscaled = $true },
    [pscustomobject]@{ Quality = 1; Width = 2048; Height = 2048; ExpectedWidth = 2048; ExpectedHeight = 2048; Upscaled = $false },
    [pscustomobject]@{ Quality = 1; Width = 320; Height = 240; ExpectedWidth = 320; ExpectedHeight = 240; Upscaled = $false },
    [pscustomobject]@{ Quality = 1; Width = 0; Height = 0; ExpectedWidth = 0; ExpectedHeight = 0; Upscaled = $false }
)

$dimensionResults = foreach ($case in $dimensionCases) {
    $actual = Get-ExpectedDimensions -Quality $case.Quality -NativeWidth $case.Width -NativeHeight $case.Height
    if ($actual.Width -ne $case.ExpectedWidth -or
        $actual.Height -ne $case.ExpectedHeight -or
        $actual.Upscaled -ne $case.Upscaled) {
        throw "Unexpected guarded dimensions for quality $($case.Quality), $($case.Width)x$($case.Height)."
    }
    [pscustomobject]@{
        Input = "$($case.Width)x$($case.Height)"
        Quality = $case.Quality
        Output = "$($actual.Width)x$($actual.Height)"
        Upscaled = $actual.Upscaled
    }
}

[pscustomobject]@{
    Status = 'PASS'
    ActiveOwnersProven = $true
    Default = 'Native'
    Optional = 'High (next launch)'
    VolumetricShadowOnly = $true
	GenericMirrorReflectionTarget = $false
    NativeDeviceFallback = $true
    DimensionCases = @($dimensionResults)
    RuntimeLaunched = $false
}
