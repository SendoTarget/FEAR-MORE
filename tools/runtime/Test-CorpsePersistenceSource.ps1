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
        throw "World-persistence source input is missing: $path"
    }
    return Get-Content -LiteralPath $path -Raw
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

function Assert-SourceMatch {
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Failure
    )

    if ($Source -notmatch $Pattern) {
        throw $Failure
    }
}

$settingHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreCorpsePersistence.h'
$settingSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\FearMoreCorpsePersistence.cpp'
$baseFxHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\Shared\BaseFx.h'
$baseFxSource = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientFxDLL\BaseFx.cpp'
$clientFxInstance = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ClientFXInstance.cpp'
$clientFxManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ClientFXMgr.cpp'
$clientShellCMake = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\CMakeLists.txt'
$shellCasing = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ShellCasingFX.cpp'
$sfxManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\SFXMgr.cpp'
$shatterEffect = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ShatterEffect.cpp'
$shatterManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ShatterEffectMgr.cpp'
$modelDecalManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ModelDecalMgr.cpp'
$gameClientShell = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\GameClientShell.cpp'
$screenGame = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenGame.cpp'
$screenGameHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenGame.h'
$profileManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ProfileMgr.cpp'
$character = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\Character.cpp'
$gameServerShell = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\GameServerShell.cpp'
$launcherSettings = Get-RequiredSource 'tools\runtime\FearLauncherSettings.psm1'
$launcherProfile = Get-RequiredSource 'tools\runtime\FearLauncherProfile.psm1'
$launcher = Get-RequiredSource 'tools\runtime\Start-FearMore.ps1'
$engineOnlyEchoPatch = Get-RequiredSource 'tools\echopatch\EchoPatch.engine-only.ini'

# One focused client module owns the legacy-compatible cvar name and all
# source-owned level-session budgets. Body counts must still fit the unchanged
# uint8 performance-setting protocol.
Assert-SourceMatch $settingHeader 'kSettingName\s*=\s*"FearMoreCorpsePersistence"\s*;' `
    'The corpse-persistence cvar no longer has one shared source owner.'
$radiusMatch = [regex]::Match($settingHeader, 'kBodyCapRadius\s*=\s*(?<Value>\d+)u\s*;')
$radiusCountMatch = [regex]::Match($settingHeader, 'kBodyCapRadiusCount\s*=\s*(?<Value>\d+)u\s*;')
$totalCountMatch = [regex]::Match($settingHeader, 'kBodyCapTotalCount\s*=\s*(?<Value>\d+)u\s*;')
if (-not $radiusMatch.Success -or -not $radiusCountMatch.Success -or -not $totalCountMatch.Success) {
    throw 'The bounded corpse-budget constants are missing from their shared owner.'
}
$bodyCapRadius = [int]$radiusMatch.Groups['Value'].Value
$bodyCapRadiusCount = [int]$radiusCountMatch.Groups['Value'].Value
$bodyCapTotalCount = [int]$totalCountMatch.Groups['Value'].Value
if ($bodyCapRadius -ne 4096 -or $bodyCapRadiusCount -ne 24 -or $bodyCapTotalCount -ne 48 -or
    $bodyCapRadiusCount -gt $bodyCapTotalCount -or $bodyCapTotalCount -gt [byte]::MaxValue) {
    throw "Corpse-persistence limits are no longer the reviewed 4096/24/48 bounded protocol values."
}

$worldBudgets = [ordered]@{
    PersistentDecalBudget = 512
    PersistentDebrisBudget = 256
    PersistentModelDecalBudget = 256
    PersistentShellCasingBudget = 200
    PersistentShatterGroupBudget = 16
}
foreach ($entry in $worldBudgets.GetEnumerator()) {
    $match = [regex]::Match($settingHeader, ('k{0}\s*=\s*(?<Value>\d+)u\s*;' -f $entry.Key))
    if (-not $match.Success -or [int]$match.Groups['Value'].Value -ne $entry.Value) {
        throw "The reviewed bounded world-persistence value is missing or changed: $($entry.Key)=$($entry.Value)."
    }
}
Assert-SourceMatch $settingSource 'return\s*\(GetConsoleInt\(kSettingName,\s*0\)\s*==\s*1\);' `
    'The shared world-persistence runtime query no longer strictly accepts only the saved value 1.'
Assert-SourceMatch $clientShellCMake '(?m)^\s*FearMoreCorpsePersistence\.cpp\s*$' `
    'The focused world-persistence runtime owner is missing from the rebuilt client target.'

# ClientFX keys retain their authored behavior by default. The manager assigns
# only EchoPatch-informed decal/debris families, excludes rocket debris, stops
# non-looping groups from replaying, and enforces independent oldest-first caps.
Assert-SourceMatch $baseFxHeader 'eFearMorePersistence_None[\s\S]*eFearMorePersistence_Decal[\s\S]*eFearMorePersistence_Debris' `
    'ClientFX persistence classes are missing from the shared rebuilt ABI.'
Assert-SourceMatch $baseFxSource 'm_eFearMorePersistenceClass\(eFearMorePersistence_None\)' `
    'New ClientFX keys no longer preserve authored lifetimes by default.'
foreach ($family in @('Stone_bullethole', 'Flesh_splat6', 'Debris_Electronic_Chunk', 'Debris_Wood_Chunk', 'Debris_Mug_Chunk', 'Debris_Vase1_Chunk')) {
    Assert-SourceMatch $clientFxManager ([regex]::Escape('"' + $family + '"')) `
        "The EchoPatch-informed persistent ClientFX family is missing: $family."
}
Assert-LiteralsInOrder $clientFxManager @(
    'if(eFXType == CBaseFX::eDecalFX)',
    'if(eFXType == CBaseFX::eLTBModelFX)',
    'FearMoreEffectNameStartsWith(pszGroupName, "HRocket_Debris")',
    'return CBaseFX::eFearMorePersistence_None;',
    'pNewFX->SetFearMorePersistenceClass(GetFearMorePersistenceClass(fxInit.m_sName, pNewFX->GetFXType()));'
) 'ClientFX persistence classification no longer preserves the rocket-debris exclusion or assigns classes at creation.'
Assert-LiteralsInOrder $clientFxInstance @(
    'bool bFearMorePersistent = FearMoreCorpsePersistence::IsEnabled()',
    'bool bCompleteKey',
    '!bFearMorePersistent'
) 'Persistent ClientFX keys no longer bypass only their authored completion edge.'
Assert-LiteralsInOrder $clientFxManager @(
    'if(pInst->m_bFearMorePastDuration)',
    'pInst->UpdateInterval(pInst->m_fDuration, pInst->m_fDuration + fFrameTime);',
    'if(!pInst->m_bLoop && pInst->HasFearMorePersistentFX())',
    'pInst->m_bFearMorePastDuration = true;',
    'EnforceFearMorePersistenceBudget(CBaseFX::eFearMorePersistence_Decal,',
    'FearMoreCorpsePersistence::kPersistentDecalBudget',
    'EnforceFearMorePersistenceBudget(CBaseFX::eFearMorePersistence_Debris,',
    'FearMoreCorpsePersistence::kPersistentDebrisBudget'
) 'Non-looping persistent ClientFX can replay their group or escape the separate decal/debris budgets.'

# Shells reuse SpecialFXList's existing oldest-item replacement. Shatter groups
# and model decals add focused caps while Off keeps original expiry/fade paths.
Assert-SourceMatch $sfxManager 'FearMoreCorpsePersistence::kPersistentShellCasingBudget,\s*// Shell casings' `
    'Shell casings no longer reuse the existing bounded SpecialFXList budget.'
Assert-LiteralsInOrder $shellCasing @(
    'if(!FearMoreCorpsePersistence::IsEnabled())',
    'm_fDieTime -= fFrameTime;',
    'if(m_fDieTime <= 0.0f)'
) 'Shell persistence no longer preserves the original expiry path when Off.'
Assert-LiteralsInOrder $shatterManager @(
    'FearMoreCorpsePersistence::IsEnabled()',
    'm_ShatterList.size() >= FearMoreCorpsePersistence::kPersistentShatterGroupBudget',
    'debug_delete(m_ShatterList.front());',
    'm_ShatterList.erase(m_ShatterList.begin());',
    'm_ShatterList.push_back(pNewEffect);'
) 'Persistent shatter groups no longer evict the oldest group before adding a replacement.'
Assert-SourceMatch $shatterEffect '!bPersistent\s*&&\s*\(m_fTotalElapsed >= fMaxLifetime\)' `
    'Shatter lifetime is no longer extended only while bounded persistence is enabled.'
Assert-SourceMatch $shatterEffect '!bPersistent\s*&&\s*\(m_fTotalElapsed > fStartFading\)' `
    'Persistent shatter pieces still enter the authored fade path.'
Assert-LiteralsInOrder $modelDecalManager @(
    'uint32 nBudget = FearMoreCorpsePersistence::kPersistentModelDecalBudget;',
    'if((m_fMaxDecals >= 0.0f) && ((uint32)m_fMaxDecals < nBudget))',
    'if(nBudget == 0u)',
    'RemoveDecal(0);',
    'if (!FearMoreCorpsePersistence::IsEnabled() && (sDecalType.m_fFadeDelay >= 0.0f))'
) 'Model decals no longer honor the lower performance cap, hard ceiling, replacement path, and stock-Off fade behavior.'

# Off reads and sends the stock values unchanged. On substitutes constants only
# after the established multiplayer early return and before the same message.
$sendPerformance = Get-SourceSection $gameClientShell `
    'void CGameClientShell::SendPerformanceSettingsToServer' `
    '// ----------------------------------------------------------------------- //' `
    'SendPerformanceSettingsToServer'
Assert-LiteralsInOrder $sendPerformance @(
    'if( IsMultiplayerGameClient( ))',
    'uint32 nBodyCapRadius = ( uint32 )GetConsoleFloat( "BodyCapRadius", -1.0f );',
    'uint8 nBodyCapRadiusCount = ( uint8 )GetConsoleFloat( "BodyCapRadiusCount", -1.0f );',
    'uint8 nBodyCapTotalCount = ( uint8 )GetConsoleFloat( "BodyCapTotalCount", -1.0f );',
    'if( GetConsoleInt( FearMoreCorpsePersistence::kSettingName, 0 ) == 1 )',
    'nBodyCapRadius = FearMoreCorpsePersistence::kBodyCapRadius;',
    'nBodyCapRadiusCount = FearMoreCorpsePersistence::kBodyCapRadiusCount;',
    'nBodyCapTotalCount = FearMoreCorpsePersistence::kBodyCapTotalCount;',
    'cMsg.Writeuint32( nBodyCapRadius );',
    'cMsg.Writeuint8( nBodyCapRadiusCount );',
    'cMsg.Writeuint8( nBodyCapTotalCount );'
) 'Corpse persistence no longer preserves stock Off values and substitutes only the bounded single-player budget.'
$handlePerformance = Get-SourceSection $gameServerShell `
    'void CGameServerShell::HandlePerformanceSettingMessage' `
    '// ----------------------------------------------------------------------- //' `
    'HandlePerformanceSettingMessage'
Assert-LiteralsInOrder $handlePerformance @(
    'if( IsMultiplayerGameServer( ))',
    'WriteConsoleFloat( "BodyCapRadius", ( float )pMsg->Readuint32( ));',
    'WriteConsoleFloat( "BodyCapRadiusCount", pMsg->Readuint8( ));',
    'WriteConsoleFloat( "BodyCapTotalCount", pMsg->Readuint8( ));'
) 'The stock body-cap protocol no longer receives unsigned radius/count fields after its multiplayer gate.'

# Gameplay uses the established AddToggle/GetConsole/WriteConsole/SaveSettings
# path and tells the player exactly what does and does not persist.
$screenBuild = Get-SourceSection $screenGame 'bool CScreenGame::Build()' 'uint32 CScreenGame::OnCommand' 'CScreenGame::Build'
Assert-LiteralsInOrder $screenBuild @(
    'tcs.szHelpID = kCorpsePersistenceHelpId;',
    'tcs.pbValue = &m_bCorpsePersistence;',
    'AddToggle(L"World persistence", tcs)'
) 'World persistence is no longer exposed through the shared Gameplay toggle primitive.'
Assert-SourceMatch $screenGameHeader 'bool\s+m_bCorpsePersistence\s*;' `
    'The Gameplay screen no longer owns corpse-persistence toggle state.'
$screenFocus = Get-SourceSection $screenGame 'void CScreenGame::OnFocus' 'void CScreenGame::GetHelpString' 'CScreenGame::OnFocus'
Assert-LiteralsInOrder $screenFocus @(
    'm_bCorpsePersistence = (GetConsoleInt(FearMoreCorpsePersistence::kSettingName, 0) == 1);',
    'WriteConsoleInt(FearMoreCorpsePersistence::kSettingName, m_bCorpsePersistence ? 1 : 0);',
    'SaveSettings();'
) 'Corpse persistence no longer loads and persists through Gameplay settings.'
Assert-SourceMatch $screenGame 'Keeps bounded bodies, blood and bullet decals, shell casings, shattered surfaces, and selected debris' `
    'Gameplay help no longer describes the bounded level-session scope.'
Assert-SourceMatch $profileManager '"EnhancedGore"\s*,\s*\r?\n\s*FearMoreCorpsePersistence::kSettingName\s*,\s*\r?\n\s*"FearMoreHDTextures"' `
    'SaveSettings no longer whitelists the shared corpse-persistence setting.'

# Radius-selected bodies also exist in the total queue. Track and skip them so
# the second pass always chooses a distinct body, and cast size_t before cap
# subtraction so a below-budget queue cannot underflow.
$capBodies = Get-SourceSection $character 'void CCharacter::CapNumberOfBodies' '// ----------------------------------------------------------------------- //' 'CapNumberOfBodies'
Assert-LiteralsInOrder $capBodies @(
    'CharacterList lstBodiesStartingFade;',
    'int nBodyCapRadiusCount = ( int )s_vtBodyCapRadiusCount.GetFloat( );',
    'int nBodyCapTotalCount = ( int )s_vtBodyCapTotalCount.GetFloat( );',
    'if( nBodyCapRadiusCount >= 0 )',
    'static_cast<int>( queRadius.size( )) - nBodyCapRadiusCount',
    'lstBodiesStartingFade.push_back( pBody );',
    'if( nBodyCapTotalCount >= 0 )',
    'static_cast<int>( queTotal.size( )) -',
    'static_cast<int>( lstBodiesStartingFade.size( )) -',
    'std::find( lstBodiesStartingFade.begin( ), lstBodiesStartingFade.end( ), pBody )',
    'continue;',
    'pBody->StartFade();',
    '--nTotalCount;'
) 'The body-cap implementation can double-select radius bodies or underflow its signed budget arithmetic.'
if ($capBodies -match 'nBodyCap(?:Radius|Total)Count\s*=\s*LTMAX\(\s*0') {
    throw 'A pre-guard clamp makes the negative radius/total sentinel fade bodies instead of disabling that cap.'
}

# Exercise the overlap case that previously under-evicted: four radius bodies
# are selected first, the total pass encounters them again, and still must find
# three additional distinct bodies to leave one of eight.
$bodies = @(
    [pscustomobject]@{ Id = 'outside-a'; Distance = 100; InRadius = $false },
    [pscustomobject]@{ Id = 'outside-b'; Distance = 90; InRadius = $false },
    [pscustomobject]@{ Id = 'radius-a'; Distance = 80; InRadius = $true },
    [pscustomobject]@{ Id = 'radius-b'; Distance = 70; InRadius = $true },
    [pscustomobject]@{ Id = 'radius-c'; Distance = 60; InRadius = $true },
    [pscustomobject]@{ Id = 'radius-d'; Distance = 50; InRadius = $true },
    [pscustomobject]@{ Id = 'radius-e'; Distance = 40; InRadius = $true },
    [pscustomobject]@{ Id = 'radius-f'; Distance = 30; InRadius = $true }
)
function Get-BodyCapModelSelection {
    param(
        [Parameter(Mandatory = $true)][object[]]$Bodies,
        [Parameter(Mandatory = $true)][int]$RadiusCap,
        [Parameter(Mandatory = $true)][int]$TotalCap
    )

    $selected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ($RadiusCap -ge 0) {
        $radiusQueue = @($Bodies | Where-Object InRadius | Sort-Object Distance -Descending)
        $radiusToFade = [Math]::Max(0, $radiusQueue.Count - $RadiusCap)
        foreach ($body in @($radiusQueue | Select-Object -First $radiusToFade)) {
            $null = $selected.Add($body.Id)
        }
    }
    if ($TotalCap -ge 0) {
        $totalToFade = [Math]::Max(0, $Bodies.Count - $selected.Count - $TotalCap)
        foreach ($body in @($Bodies | Sort-Object Distance -Descending)) {
            if ($totalToFade -eq 0) { break }
            if ($selected.Contains($body.Id)) { continue }
            $null = $selected.Add($body.Id)
            $totalToFade--
        }
    }
    Write-Output -NoEnumerate $selected
}

$selected = Get-BodyCapModelSelection -Bodies $bodies -RadiusCap 2 -TotalCap 1
$remaining = @($bodies | Where-Object { -not $selected.Contains($_.Id) })
if ($selected.Count -ne 7 -or $remaining.Count -ne 1 -or
    @($remaining | Where-Object InRadius).Count -gt 2) {
    throw 'The body-cap overlap model did not enforce distinct radius and total selections.'
}
$sentinelSelected = Get-BodyCapModelSelection -Bodies $bodies -RadiusCap -1 -TotalCap -1
if ($sentinelSelected.Count -ne 0) {
    throw 'Negative radius/total sentinels selected bodies for fading.'
}

# Modern enables the option only when it is creating settings.cfg. Existing
# profiles default missing fields to Off, explicit saved values are parsed, and
# Initialize-FearMoreSettings never rewrites an existing file.
Assert-SourceMatch $launcherSettings 'function Get-FearMoreCorpsePersistenceEnabledFromSettings' `
    'The launcher has no strict parser for the saved corpse-persistence selection.'
Assert-LiteralsInOrder $launcher @(
    '$settingsExistedBeforeStaging = Test-Path -LiteralPath $settingsPathBeforeStaging -PathType Leaf',
    'Get-FearMoreCorpsePersistenceEnabledFromSettings',
    "-DefaultEnabled:(`$Preset -eq 'Modern' -and -not `$settingsExistedBeforeStaging)",
    '-CorpsePersistenceEnabled $corpsePersistenceEnabled',
    'CorpsePersistenceEnabled     = $corpsePersistenceEnabled'
) 'Launcher ownership no longer limits the Modern default to genuinely new profiles.'
Assert-SourceMatch $launcherProfile '\[bool\]\$CorpsePersistenceEnabled\s*=\s*\$false' `
    'Generic profile seeding no longer defaults corpse persistence Off.'
Assert-SourceMatch $launcherProfile '"FearMoreCorpsePersistence"\s+"\{0\}\.000000"' `
    'Fresh profile seeding no longer writes the selected corpse-persistence value.'
Assert-LiteralsInOrder $launcherProfile @(
    'if (-not $settingsExists)',
    '-Path $settingsTransactionPath',
    'if (-not $settingsExists)',
    '-DestinationPath $settingsPath'
) 'Profile seeding no longer restricts settings writes to missing profiles.'

# This source-owned budget is intentionally independent of EchoPatch's game
# module hooks and world-state persistence lane.
Assert-SourceMatch $engineOnlyEchoPatch '(?m)^\s*PatchGameModules\s*=\s*0\s*$' `
    'Engine-only EchoPatch unexpectedly enables game-module hooks.'
Assert-SourceMatch $engineOnlyEchoPatch '(?m)^\s*EnablePersistentWorldState\s*=\s*0\s*$' `
    'Engine-only EchoPatch unexpectedly enables world-state persistence.'

# Enhanced Gore must reject multiplayer inside its mutation owner even if a
# private console value is set by a nonstandard caller.
$processGore = Get-SourceSection $character 'bool CCharacter::ProcessEnhancedGoreDamage' 'bool CCharacter::HasEnhancedGoreSeveredLocation' 'ProcessEnhancedGoreDamage'
Assert-LiteralsInOrder $processGore @(
    'if (IsMultiplayerGameServer() || !IsEnhancedGoreEnabled()',
    'm_EnhancedGoreDamageTracker.ProcessDamage(rDamage);',
    'HandleSeverWithImpulse(hPiece, rDamage.GetDamageDir(), rDamage.fImpulseForce);'
) 'Enhanced Gore no longer rejects multiplayer before any postmortem mutation.'

[pscustomobject]@{
    Status                         = 'PASS'
    ModernBudget                  = "$bodyCapRadius/$bodyCapRadiusCount/$bodyCapTotalCount"
    StockOffPassthroughVerified   = $true
    DistinctBodySelectionVerified = $true
    NegativeCapSentinelsVerified   = $true
    UnsignedClientProtocolVerified = $true
    MultiplayerGoreGateVerified  = $true
    GameplayPersistenceVerified  = $true
    ClientFxBudgetsVerified      = $true
    ShellBudgetVerified          = $true
    ShatterBudgetVerified        = $true
    ModelDecalBudgetVerified     = $true
    NewProfileOnlySeedVerified   = $true
    EchoPatchWorldHooksDisabled  = $true
    RuntimeLaunched              = $false
    Note                           = 'Static source invariants plus an executable body-cap overlap model; compile and live dense-effect acceptance remain separate gates.'
}
