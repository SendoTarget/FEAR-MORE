[CmdletBinding()]
param([string]$RepositoryRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Join-Path $PSScriptRoot '..\..'
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)

function Get-RequiredSource {
    param([Parameter(Mandatory = $true)][string]$RelativePath)

    $path = Join-Path $RepositoryRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Required source file is missing: $path"
    }
    return Get-Content -LiteralPath $path -Raw
}

function Assert-Contains {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Literal,
        [Parameter(Mandatory = $true)][string]$Failure
    )

    if (-not $Source.Contains($Literal)) {
        throw "$Failure Missing token: $Literal"
    }
}

function Assert-InOrder {
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

$clientRoot = 'FEAR\Dev\Source\FEAR\ClientShellDLL'
$resolverHeader = Get-RequiredSource "$clientRoot\FearMoreDefaultBindingResolver.h"
$resolverSource = Get-RequiredSource "$clientRoot\FearMoreDefaultBindingResolver.cpp"
$profileHeader = Get-RequiredSource "$clientRoot\ProfileMgr.h"
$profileSource = Get-RequiredSource "$clientRoot\ProfileMgr.cpp"
$clientCMake = Get-RequiredSource "$clientRoot\CMakeLists.txt"

Assert-Contains $clientCMake 'FearMoreDefaultBindingResolver.cpp' `
    'The locale-safe default-binding resolver is no longer compiled into GameClient.dll.'
Assert-Contains $resolverHeader 'Callers must keep this fallback scoped to the' `
    'The resolver contract no longer documents its behavior-preservation boundary.'
Assert-Contains $profileHeader 'ApplyBindings(bool bUseDefaultBindingFallback = false);' `
    'Ordinary binding application no longer defaults to the exact-name-only path.'
Assert-Contains $profileHeader 'LoadControls(HDATABASE hDB, bool bUseDefaultBindingFallback = false);' `
    'Ordinary profile loads no longer default to the exact-name-only path.'

$expectedMappings = [ordered]@{
    'L"Space"'       = 'DIK_SPACE'
    'L"Up Arrow"'    = 'DIK_UPARROW'
    'L"Up"'          = 'DIK_UPARROW'
    'L"Down Arrow"'  = 'DIK_DOWNARROW'
    'L"Down"'        = 'DIK_DOWNARROW'
    'L"Tab"'         = 'DIK_TAB'
    'L"Right Ctrl"'  = 'DIK_RCONTROL'
    'L"Left Arrow"'  = 'DIK_LEFTARROW'
    'L"Left"'        = 'DIK_LEFTARROW'
    'L"Right Arrow"' = 'DIK_RIGHTARROW'
    'L"Right"'       = 'DIK_RIGHTARROW'
    'L"Left Shift"'  = 'DIK_LSHIFT'
}
foreach ($entry in $expectedMappings.GetEnumerator()) {
    Assert-Contains $resolverSource ("{{ {0}, {1} }}" -f $entry.Key, $entry.Value) `
        'A required locale-sensitive retail default no longer maps to its stable DirectInput code.'
}

Assert-InOrder $resolverSource @(
    'FindFirstDeviceByCategory(ILTInput::eDC_Keyboard, &nKeyboardDevice)',
    'FindFirstDeviceObjectByCategory(nKeyboardDevice, ILTInput::eDOC_Button, &nFirstButton)',
    'GetNumDeviceObjectsByCategory(nKeyboardDevice, ILTInput::eDOC_Button, &nButtonCount)',
    'GetDeviceObjectDesc(nKeyboardDevice, nObjectIndex, &sObject)',
    'sObject.m_nControlCode != nControlCode'
) 'Default fallback no longer resolves the actual localized keyboard object by stable control code.'

Assert-InOrder $profileSource @(
    'FindDeviceByName(iCurBinding->m_sDeviceName.c_str(), &nDeviceIndex)',
    'FindDeviceObjectByName(nDeviceIndex, iCurBinding->m_sObjectName.c_str(), &nObjectIndex)',
    'if( !bExactObject &&',
    '!bUseDefaultBindingFallback ||',
    '!FearMoreDefaultBindingResolver::ResolveKeyboardObject'
) 'The original exact-name path no longer runs before the default-only fallback.'

Assert-Contains $profileSource 'LoadControls(hDB, bLoadDefaults);' `
    'New-profile loading no longer passes its default-profile scope to the resolver.'
Assert-Contains $profileSource 'LoadControls(hDB, true);' `
    'The explicit Restore Defaults path no longer enables locale-safe resolution.'

$fallbackCalls = [regex]::Matches(
    $profileSource,
    [regex]::Escape('FearMoreDefaultBindingResolver::ResolveKeyboardObject')).Count
if ($fallbackCalls -ne 1) {
    throw "Default resolver must have exactly one guarded call site; found $fallbackCalls."
}

Write-Output 'F.E.A.R. locale-safe default-binding source checks passed.'
