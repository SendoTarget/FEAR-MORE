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
        throw "Enhanced Gore source input is missing: $path"
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

$character = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\Character.cpp'
$characterHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\Character.h'
$characterFx = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\CharacterFX.cpp'
$characterFxHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\CharacterFX.h'
$screenGame = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenGame.cpp'
$screenGameHeader = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ScreenGame.h'
$profileManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ProfileMgr.cpp'
$clientConnection = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ClientShellDLL\ClientConnectionMgr.cpp'
$serverConnection = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\ServerConnectionMgr.cpp'
$serverShell = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\GameServerShell.cpp'
$projectile = Get-RequiredSource 'FEAR\Dev\Source\FEAR\ObjectDLL\Projectile.cpp'
$runtimeControls = Get-RequiredSource 'FEAR\Dev\Source\FEAR\Shared\FearMoreRuntimeControls.h'
$versionManager = Get-RequiredSource 'FEAR\Dev\Source\FEAR\Shared\VersionMgr.cpp'
$launcher = Get-RequiredSource 'tools\runtime\Start-FearMore.ps1'

# The feature remains opt-in, and the normal stock damage tracker remains the
# fall-through when the postmortem path does not consume a hit.
Assert-SourceMatch $character 's_vtEnhancedGore\.Init\(\s*g_pLTServer\s*,\s*"EnhancedGore"\s*,\s*NULL\s*,\s*0\.0f\s*\)' `
    'EnhancedGore is no longer initialized disabled by default.'
Assert-SourceMatch $character 's_vtEnhancedGoreMaxSeversPerBody\.Init\(\s*g_pLTServer\s*,\s*"EnhancedGoreMaxSeversPerBody"\s*,\s*NULL\s*,\s*3\.0f\s*\)' `
    'The bounded three-sever default changed unexpectedly.'

# Modern one-click launch owns an explicit initial value, while the established
# Gameplay screen and settings whitelist own subsequent user changes. The
# server default above stays off for compatibility and non-launcher callers.
$screenBuild = Get-SourceSection $screenGame 'bool CScreenGame::Build()' 'uint32 CScreenGame::OnCommand' 'CScreenGame::Build'
Assert-LiteralsInOrder $screenBuild @(
    'if (pProfile && !g_pVersionMgr->IsLowViolence())',
    'AddToggle("IDS_DISPLAY_GORE",tcs)',
    'tcs.szHelpID = kEnhancedGoreHelpId;',
    'tcs.pbValue = &m_bEnhancedGore;',
    'AddToggle(L"Enhanced gore", tcs)'
) 'Enhanced Gore is no longer exposed beside stock Gore through the shared gameplay-toggle path.'
Assert-SourceMatch $screenGameHeader 'bool\s+m_bEnhancedGore\s*;' `
    'The gameplay screen no longer owns its Enhanced Gore toggle state.'
$screenFocus = Get-SourceSection $screenGame 'void CScreenGame::OnFocus' 'void CScreenGame::GetHelpString' 'CScreenGame::OnFocus'
Assert-LiteralsInOrder $screenFocus @(
    'm_bEnhancedGore = (GetConsoleInt("EnhancedGore", 0) == 1);',
    'WriteConsoleInt("EnhancedGore", m_bEnhancedGore ? 1 : 0);',
    'SaveSettings();'
) 'Enhanced Gore no longer loads, commits, and persists through the established Gameplay settings path.'
Assert-SourceMatch $screenGame 'Standard Gore must also be Yes\. Changes apply on the next world load\.' `
    'Enhanced Gore help no longer explains stock-gore precedence and its world-load boundary.'
Assert-SourceMatch $profileManager '"EnhancedGore"\s*,\s*\r?\n\s*FearMoreCorpsePersistence::kSettingName\s*,\s*\r?\n\s*"FearMoreHDTextures"' `
    'settings.cfg no longer persists EnhancedGore through SaveSettings.'
Assert-LiteralsInOrder $launcher @(
    '-DefaultEnabled:($Preset -eq ''Modern'')',
    "if (`$argument -imatch '^\+EnhancedGore(?:=|`$)')",
    "'+EnhancedGore'",
    "`$(if (`$enhancedGoreEnabled) { '1' } else { '0' })",
    '-EnhancedGoreEnabled $enhancedGoreEnabled'
) 'Modern launch no longer seeds and owns Enhanced Gore without allowing a conflicting free-form argument.'
$processGore = Get-SourceSection $character 'bool CCharacter::ProcessEnhancedGoreDamage' 'bool CCharacter::HasEnhancedGoreSeveredLocation' 'ProcessEnhancedGoreDamage'
Assert-LiteralsInOrder $processGore @(
    'if (IsMultiplayerGameServer() || !IsEnhancedGoreEnabled()',
    '!g_pGameServerShell->IsGoreAllowed()',
    'm_damage.IsDead()',
    'm_EnhancedGoreDamageTracker.ProcessDamage(rDamage);',
    'HandleSeverWithImpulse(hPiece, rDamage.GetDamageDir(), rDamage.fImpulseForce);'
) 'The opt-in/gore/dead-state gate no longer precedes postmortem mutation.'
$processDamage = Get-SourceSection $character 'void CCharacter::ProcessDamageMsg' 'bool CCharacter::ProcessEnhancedGoreDamage' 'ProcessDamageMsg'
Assert-LiteralsInOrder $processDamage @(
    'bool bProcessedEnhancedGoreDamage',
    'if ( !bProcessedEnhancedGoreDamage',
    'm_DamageTracker.ProcessDamage(rDamage);'
) 'The normal damage tracker is no longer the preserved fall-through path.'

# Save schema 283 inserts the exact mask and accumulated thresholds as one
# matched block. Retail saves skip that block and receive an unreplayable
# conservative marker when their precise non-head location is unknowable.
Assert-SourceMatch $versionManager 'kSaveVersion__FearMoreEnhancedGore\s*=\s*283\s*;' `
    'FearMore Enhanced Gore save schema is no longer 283.'
Assert-SourceMatch $versionManager 'kSaveVersion__CurrentBuild\s*=\s*CVersionMgr::kSaveVersion__FearMoreEnhancedGore\s*;' `
    'The current save schema no longer owns the Enhanced Gore fields.'
$saveCharacter = Get-SourceSection $character 'void CCharacter::Save' 'void CCharacter::Load' 'CCharacter::Save'
Assert-LiteralsInOrder $saveCharacter @(
    'SAVE_bool( m_bSevered );',
    'SAVE_bool( m_bDeathEffect );',
    'SAVE_BYTE( m_nEnhancedGoreSeveredLocations );',
    'm_EnhancedGoreDamageTracker.Save(pMsg);',
    'SAVE_bool( m_bDecapitated );'
) 'Enhanced Gore save fields no longer have the expected matched position.'
$loadCharacter = Get-SourceSection $character 'void CCharacter::Load' 'bool CCharacter::SetAIAttributes' 'CCharacter::Load'
Assert-LiteralsInOrder $loadCharacter @(
    'LOAD_bool(m_bSevered);',
    'LOAD_bool(m_bDeathEffect);',
    'g_pVersionMgr->GetCurrentSaveVersion() >= CVersionMgr::kSaveVersion__FearMoreEnhancedGore',
    'LOAD_BYTE(m_nEnhancedGoreSeveredLocations);',
    'm_EnhancedGoreDamageTracker.Load(pMsg);',
    'm_EnhancedGoreDamageTracker.Clear();',
    'LOAD_bool(m_bDecapitated);',
    'm_nEnhancedGoreSeveredLocations |= kEnhancedGoreImpreciseSeverMask;'
) 'Enhanced Gore load/version/legacy ordering changed and may misalign retail saves.'

# Precise masks replay only to the local single-player client that just rebuilt
# CharacterFX. Legacy imprecise masks never become six invented pieces, and
# zero force avoids a second live-shot impulse. Multiplayer late joins retain
# their stock behavior until they receive a separately accepted sync protocol.
$replayGore = Get-SourceSection $character 'void CCharacter::ReplayEnhancedGoreSeversToClient' '// --------------------------------------------------------------------------- //' 'ReplayEnhancedGoreSeversToClient'
Assert-LiteralsInOrder $replayGore @(
    '!hClient',
    'm_nEnhancedGoreSeveredLocations & kEnhancedGoreImpreciseSeverMask',
    'HasEnhancedGoreSeveredLocation( eLocation )',
    'SendSeverMessage( hClient, eLocation, vNeutralSeverDir, 0.0f );'
) 'Persisted sever replay lost its targeted, precise-mask, zero-force boundary.'
$inWorld = Get-SourceSection $serverConnection 'bool ConnectionStateMachine::InWorld_OnMessage' 'bool ConnectionStateMachine::PostLoadWorld_OnUpdate' 'InWorld_OnMessage'
Assert-LiteralsInOrder $inWorld @(
    'm_pGameClientData->SetClientInWorld( true );',
    'if( !IsMultiplayerGameServer( ))',
    'CCharacter::GetCharacterList( )',
    'pCharacter->ReplayEnhancedGoreSeversToClient( m_pGameClientData->GetClient( ));'
) 'Sever replay no longer occurs after the target local single-player client enters the rebuilt world.'
$replayCallCount = [regex]::Matches(
    $inWorld,
    [regex]::Escape('ReplayEnhancedGoreSeversToClient( m_pGameClientData->GetClient( ));')
).Count
if ($replayCallCount -ne 1) {
    throw "InWorld sever replay must have exactly one local single-player call; found $replayCallCount."
}

# Location is the unchanged stock CFX_SEVER protocol identity. The server sends
# location plus impulse data, and the client resolves the first database piece
# for that location, so a repeated location cannot describe a distinct piece.
$sendSever = Get-SourceSection $character 'void CCharacter::SendSeverMessage' 'void CCharacter::ResetModel' 'CCharacter::SendSeverMessage'
Assert-LiteralsInOrder $sendSever @(
    'cMsg.WriteBits(CFX_SEVER',
    'cMsg.Writeuint8(eHitLocation);',
    'cMsg.WriteCompLTPolarCoord(LTPolarCoord(vSeverDir));',
    'cMsg.Writefloat(fImpulseForce);'
) 'The stock CFX_SEVER location/direction/force payload changed unexpectedly.'
Assert-SourceMatch $sendSever '(?s)void CCharacter::SendSeverMessage\( HCLIENT hClient, HitLocation eHitLocation, const LTVector& vSeverDir, float fImpulseForce \).*?SendToClient' `
    'CFX_SEVER no longer uses location as its only sever-piece identity.'

# The client consumes each location once. Validation and de-duplication happen
# before node-tracker teardown or detached-object creation.
$handleSever = Get-SourceSection $characterFx 'void CCharacterFX::HandleSeverMsg' '// ----------------------------------------------------------------------- //' 'CCharacterFX::HandleSeverMsg'
Assert-LiteralsInOrder $handleSever @(
    'if( eHitLoc <= HL_UNKNOWN || eHitLoc >= HL_NUM_LOCS )',
    'if( m_nSeveredLocations & nLocationFlag )'
) 'Client sever-message validation no longer rejects invalid or duplicate locations before mutation.'
$resolvedSever = Get-SourceSection $handleSever 'ModelsDB::HSEVERBODY hBody' '//spawn a model for the severed piece' 'resolved client sever piece'
Assert-LiteralsInOrder $resolvedSever @(
    'if (!hBody)',
    'for (uint32 nPiece = 0; nPiece < nNumPieces && !hPiece; ++nPiece)',
    'HitLocation eTestLoc = g_pModelsDB->GetSPLocation(hTestPiece);',
    'if (eTestLoc == eHitLoc)',
    'hPiece = hTestPiece;',
    'if (!hPiece)',
    'm_nSeveredLocations |= nLocationFlag;',
    'm_NodeTrackerContext.Term();'
) 'Client sever-message de-duplication is committed before a valid body piece resolves.'
Assert-LiteralsInOrder $handleSever @(
    'm_NodeTrackerContext.Term();',
    'm_hSeveredParts.push_back(hObj);'
) 'Valid client sever messages no longer invalidate node tracking before detached-object ownership.'
$initCharacterFx = Get-SourceSection $characterFx 'bool CCharacterFX::Init(HLOCALOBJ hServObj, ILTMessage_Read *pMsg)' 'bool CCharacterFX::Init(SFXCREATESTRUCT* psfxCreateStruct)' 'CCharacterFX::Init'
$clearDead = Get-SourceSection $characterFx 'void CCharacterFX::ClearDead()' '// ----------------------------------------------------------------------- //' 'CCharacterFX::ClearDead'
Assert-SourceMatch $characterFxHeader 'm_nSeveredLocations\s*=\s*0\s*;' `
    'Client sever de-duplication state is not initialized by construction.'
Assert-SourceMatch $initCharacterFx 'm_nSeveredLocations\s*=\s*0\s*;' `
    'Client sever de-duplication state is not reset when CharacterFX initializes.'
Assert-SourceMatch $clearDead 'm_nSeveredLocations\s*=\s*0\s*;' `
    'Client sever de-duplication state is not reset when a dead character is cleared.'

# Command-line acceptance controls share one explicit allowlist. The client
# sends them only for local single-player after its guaranteed InWorld message;
# the server consumes unauthorized private forms and applies values only for a
# local sender on a non-multiplayer server.
$controlBlock = [regex]::Match($runtimeControls, '(?s)kForwardedVariables\[\]\s*=\s*\{(?<Body>.*?)\};')
if (-not $controlBlock.Success) {
    throw 'FearMore runtime-control allowlist is missing.'
}
$actualControls = @([regex]::Matches($controlBlock.Groups['Body'].Value, '"(?<Name>[^"]+)"') | ForEach-Object { $_.Groups['Name'].Value })
$expectedControls = @('EnhancedGore', 'EnhancedGoreMaxSeversPerBody', 'BodySeverTest', 'BodyGibTest', 'AIProfileEnabled', 'AIUpdateInterval')
if ($actualControls.Count -ne $expectedControls.Count) {
    throw "FearMore runtime-control allowlist count changed: $($actualControls -join ', ')"
}
for ($index = 0; $index -lt $expectedControls.Count; $index++) {
    if ($actualControls[$index] -cne $expectedControls[$index]) {
        throw "FearMore runtime-control allowlist changed at index ${index}: $($actualControls -join ', ')"
    }
}
$sendInWorld = Get-SourceSection $clientConnection 'void ClientConnectionMgr::SendClientInWorldMessage' '// ----------------------------------------------------------------------- //' 'SendClientInWorldMessage'
Assert-LiteralsInOrder $sendInWorld @(
    'g_pLTClient->SendToServer(cMsg.Read(),MESSAGE_GUARANTEED);',
    'm_eSentClientConnectionState = eClientConnectionState_InWorld;',
    'if( !IsMultiplayerGameClient( ) && m_StartGameRequest.m_Type == STARTGAME_NORMAL )',
    'ForwardFearMoreSinglePlayerCVar( FearMoreRuntimeControls::kForwardedVariables[nVariable] );'
) 'Runtime controls no longer follow the guaranteed local single-player InWorld transition.'
$serverControl = Get-SourceSection $serverShell 'static bool HandleFearMoreSinglePlayerCVar' '//#define _DEGUG' 'HandleFearMoreSinglePlayerCVar'
Assert-LiteralsInOrder $serverControl @(
    '!LTStrIEquals( parse.m_Args[0], FearMoreRuntimeControls::kForwardCommand )',
    'parse.m_nArgs != 3 || !hSender',
    'g_pLTServer->GetClientInfoFlags( hSender ) & CIF_LOCAL',
    'IsMultiplayerGameServer( )',
    'FearMoreRuntimeControls::kForwardedVariables[nVariable]',
    'strtod( parse.m_Args[2], &pszValueEnd )',
    '*pszValueEnd == ''\0''',
    '_finite( fParsedValue )',
    'fParsedValue >= -FLT_MAX && fParsedValue <= FLT_MAX',
    'g_pLTServer->SetConsoleVariableFloat( pszAllowedVariable'
) 'Server runtime-control validation no longer enforces private-command, local-SP, allowlist, and finite full-value parsing ownership.'

# Hit-node state belongs to exactly one projectile impact dispatch. Direct
# MID_DAMAGE consumes it in Character, while impacts that only apply impulse,
# area damage, or deferred progressive damage clear it at the projectile owner.
Assert-SourceMatch $characterHeader 'void\s+ClearPendingModelNodeHit\(\)\s*\{\s*m_bModelNodeHitPending\s*=\s*false;\s*\}' `
    'Character no longer exposes the narrow pending-hit reset used by projectile dispatch.'
$impactDamage = Get-SourceSection $projectile 'void CProjectile::ImpactDamageObject' '// ----------------------------------------------------------------------- //' 'CProjectile::ImpactDamageObject'
Assert-LiteralsInOrder $impactDamage @(
    'damage.DoDamage(m_hObject, hObj);',
    'if( IsCharacter( hObj ))',
    'pHitCharacter->ClearPendingModelNodeHit();'
) 'Projectile impact no longer clears unused or already-consumed node context at the end of its dispatch.'

[pscustomobject]@{
    Status = 'PASS'
    DefaultOffFallthroughVerified = $true
    SaveVersionAndOrderingVerified = $true
    PreciseReplayBoundaryVerified = $true
    MultiplayerLateJoinPreserved = $true
    StrictMultiplayerGateVerified = $true
    StockSeverProtocolVerified = $true
    ClientDeduplicationVerified = $true
    InGamePersistenceVerified = $true
    ModernOneClickDefaultVerified = $true
    DispatchScopedHitNodeVerified = $true
    FiniteRuntimeControlParsingVerified = $true
    LocalSinglePlayerControlBridgeVerified = $true
    RuntimeLaunched = $false
    Note = 'Static source invariants only; compile and live corpse/save-load acceptance are separate gates.'
}
