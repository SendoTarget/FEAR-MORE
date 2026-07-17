// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreControllerMgr.cpp
//
// PURPOSE : Source-owned SDL3 gamepad input for rebuilt FearMore clients.
//
// NOTES   : This implementation is independently written against SDL's public
//           API.  It does not use EchoPatch controller code or game-module
//           hooks.  SDL is zlib-licensed and remains a separate runtime DLL.
//
// ----------------------------------------------------------------------- //

#include "stdafx.h"
#include "FearMoreControllerMgr.h"

#include "FearMoreControllerSettings.h"
#include "CommandIDs.h"
#include "InterfaceMgr.h"

#include <math.h>

namespace
{
	typedef uint32 SDL_JoystickID;
	struct SDL_Gamepad;

	enum ESDLGamepadAxis
	{
		eSDLGamepadAxis_LeftX = 0,
		eSDLGamepadAxis_LeftY,
		eSDLGamepadAxis_RightX,
		eSDLGamepadAxis_RightY,
		eSDLGamepadAxis_LeftTrigger,
		eSDLGamepadAxis_RightTrigger
	};

	enum ESDLGamepadButton
	{
		eSDLGamepadButton_South = 0,
		eSDLGamepadButton_East,
		eSDLGamepadButton_West,
		eSDLGamepadButton_North,
		eSDLGamepadButton_Back,
		eSDLGamepadButton_Guide,
		eSDLGamepadButton_Start,
		eSDLGamepadButton_LeftStick,
		eSDLGamepadButton_RightStick,
		eSDLGamepadButton_LeftShoulder,
		eSDLGamepadButton_RightShoulder,
		eSDLGamepadButton_DPadUp,
		eSDLGamepadButton_DPadDown,
		eSDLGamepadButton_DPadLeft,
		eSDLGamepadButton_DPadRight,
		eSDLGamepadButton_Count
	};

	static uint32 const kSDLInitGamepad = 0x00002000u;
	static uint32 const kMaximumCommand = COMMAND_ID_FLASHLIGHT;
	static float const kTriggerThreshold = 0.20f;
	static DWORD const kReconnectIntervalMs = 500;
	static DWORD const kRuntimeRetryIntervalMs = 2000;
	static DWORD const kRumbleRefreshMs = 50;
	static uint32 const kRumbleDurationMs = 100;

	typedef bool (__cdecl *TSDLInitSubSystem)( uint32 );
	typedef void (__cdecl *TSDLQuitSubSystem)( uint32 );
	typedef SDL_JoystickID* (__cdecl *TSDLGetGamepads)( int* );
	typedef SDL_Gamepad* (__cdecl *TSDLOpenGamepad)( SDL_JoystickID );
	typedef void (__cdecl *TSDLCloseGamepad)( SDL_Gamepad* );
	typedef bool (__cdecl *TSDLGamepadConnected)( SDL_Gamepad* );
	typedef void (__cdecl *TSDLUpdateGamepads)();
	typedef int16 (__cdecl *TSDLGetGamepadAxis)( SDL_Gamepad*, int );
	typedef bool (__cdecl *TSDLGetGamepadButton)( SDL_Gamepad*, int );
	typedef bool (__cdecl *TSDLRumbleGamepad)( SDL_Gamepad*, uint16, uint16, uint32 );
	typedef void (__cdecl *TSDLFree)( void* );
	typedef char const* (__cdecl *TSDLGetError)();

	float NormalizeSignedAxis( int16 nValue )
	{
		return ( nValue < 0 ) ? ( static_cast<float>( nValue ) / 32768.0f ) :
			( static_cast<float>( nValue ) / 32767.0f );
	}

	float NormalizeTrigger( int16 nValue )
	{
		return LTCLAMP( static_cast<float>( nValue ) / 32767.0f, 0.0f, 1.0f );
	}

	void ApplyRadialDeadZone( float& fX, float& fY, float fDeadZone )
	{
		const float fMagnitude = sqrtf( ( fX * fX ) + ( fY * fY ) );
		if( fMagnitude <= fDeadZone || fMagnitude <= 0.0f )
		{
			fX = 0.0f;
			fY = 0.0f;
			return;
		}

		const float fScaledMagnitude = LTCLAMP(
			( fMagnitude - fDeadZone ) / ( 1.0f - fDeadZone ), 0.0f, 1.0f );
		const float fScale = fScaledMagnitude / fMagnitude;
		fX *= fScale;
		fY *= fScale;
	}

	uint16 ToRumbleValue( float fValue )
	{
		return static_cast<uint16>( LTCLAMP( fValue, 0.0f, 1.0f ) * 65535.0f );
	}
}

struct CFearMoreControllerMgr::SImpl
{
	SImpl()
		: m_hSDL( NULL ),
		  m_pGamepad( NULL ),
		  m_bSubsystemInitialized( false ),
		  m_bInputActiveLastFrame( false ),
		  m_nLastConnectAttempt( 0 ),
		  m_nLastRumbleUpdate( 0 ),
		  m_nLastLowRumble( 0 ),
		  m_nLastHighRumble( 0 ),
		  m_pInitSubSystem( NULL ),
		  m_pQuitSubSystem( NULL ),
		  m_pGetGamepads( NULL ),
		  m_pOpenGamepad( NULL ),
		  m_pCloseGamepad( NULL ),
		  m_pGamepadConnected( NULL ),
		  m_pUpdateGamepads( NULL ),
		  m_pGetGamepadAxis( NULL ),
		  m_pGetGamepadButton( NULL ),
		  m_pRumbleGamepad( NULL ),
		  m_pFree( NULL ),
		  m_pGetError( NULL )
	{
		ClearInput();
		memset( m_abPreviousButtons, 0, sizeof( m_abPreviousButtons ) );
		memset( m_abCurrentButtons, 0, sizeof( m_abCurrentButtons ) );
	}

	void ClearInput()
	{
		memset( m_afCommandValues, 0, sizeof( m_afCommandValues ) );
		memset( m_abCommandStates, 0, sizeof( m_abCommandStates ) );
	}

	char const* GetError() const
	{
		return m_pGetError ? m_pGetError() : "unknown SDL error";
	}

	template <class T>
	bool LoadFunction( T& pFunction, char const* pszName )
	{
		pFunction = reinterpret_cast<T>( GetProcAddress( m_hSDL, pszName ) );
		return pFunction != NULL;
	}

	bool LoadRuntime()
	{
		wchar_t wszExecutable[MAX_PATH] = L"";
		const DWORD nLength = GetModuleFileNameW( NULL, wszExecutable, LTARRAYSIZE( wszExecutable ) );
		if( nLength == 0 || nLength >= LTARRAYSIZE( wszExecutable ) )
			return false;

		wchar_t* pSeparator = wcsrchr( wszExecutable, L'\\' );
		if( !pSeparator )
			return false;
		*( pSeparator + 1 ) = L'\0';
		if( wcslen( wszExecutable ) + wcslen( L"SDL3.dll" ) >= LTARRAYSIZE( wszExecutable ) )
			return false;
		wcscat_s( wszExecutable, LTARRAYSIZE( wszExecutable ), L"SDL3.dll" );

		// Use an explicit application-directory path.  SDL3 is a separately
		// validated runtime payload and is never resolved from the working path.
		m_hSDL = LoadLibraryW( wszExecutable );
		if( !m_hSDL )
			return false;

		const bool bComplete =
			LoadFunction( m_pInitSubSystem, "SDL_InitSubSystem" ) &&
			LoadFunction( m_pQuitSubSystem, "SDL_QuitSubSystem" ) &&
			LoadFunction( m_pGetGamepads, "SDL_GetGamepads" ) &&
			LoadFunction( m_pOpenGamepad, "SDL_OpenGamepad" ) &&
			LoadFunction( m_pCloseGamepad, "SDL_CloseGamepad" ) &&
			LoadFunction( m_pGamepadConnected, "SDL_GamepadConnected" ) &&
			LoadFunction( m_pUpdateGamepads, "SDL_UpdateGamepads" ) &&
			LoadFunction( m_pGetGamepadAxis, "SDL_GetGamepadAxis" ) &&
			LoadFunction( m_pGetGamepadButton, "SDL_GetGamepadButton" ) &&
			LoadFunction( m_pRumbleGamepad, "SDL_RumbleGamepad" ) &&
			LoadFunction( m_pFree, "SDL_free" ) &&
			LoadFunction( m_pGetError, "SDL_GetError" );

		if( !bComplete )
		{
			FreeLibrary( m_hSDL );
			m_hSDL = NULL;
		}
		return bComplete;
	}

	void CloseGamepad()
	{
		if( m_pGamepad && m_pCloseGamepad )
		{
			if( m_pRumbleGamepad )
				m_pRumbleGamepad( m_pGamepad, 0, 0, 0 );
			m_pCloseGamepad( m_pGamepad );
		}
		m_pGamepad = NULL;
		m_nLastLowRumble = 0;
		m_nLastHighRumble = 0;
		ClearInput();
		memset( m_abPreviousButtons, 0, sizeof( m_abPreviousButtons ) );
		memset( m_abCurrentButtons, 0, sizeof( m_abCurrentButtons ) );
	}

	void TryOpenGamepad( DWORD nNow )
	{
		if( m_pGamepad || !m_bSubsystemInitialized )
			return;
		if( ( nNow - m_nLastConnectAttempt ) < kReconnectIntervalMs )
			return;
		m_nLastConnectAttempt = nNow;

		int nCount = 0;
		SDL_JoystickID* pGamepads = m_pGetGamepads( &nCount );
		if( pGamepads )
		{
			for( int nIndex = 0; nIndex < nCount && !m_pGamepad; ++nIndex )
				m_pGamepad = m_pOpenGamepad( pGamepads[nIndex] );
			m_pFree( pGamepads );
		}

		if( m_pGamepad && g_pLTClient )
			g_pLTClient->CPrint( "FearMore controller: SDL3 gamepad connected." );
	}

	void SetCommandButton( uint32 nCommand, bool bPressed )
	{
		if( nCommand <= kMaximumCommand )
			m_abCommandStates[nCommand] = m_abCommandStates[nCommand] || bPressed;
	}

	void SendInterfaceKey( int nVirtualKey )
	{
		if( !g_pInterfaceMgr )
			return;
		g_pInterfaceMgr->OnKeyDown( nVirtualKey, 1 );
		g_pInterfaceMgr->OnKeyUp( nVirtualKey );
	}

	bool WasButtonPressed( ESDLGamepadButton eButton ) const
	{
		return m_abCurrentButtons[eButton] && !m_abPreviousButtons[eButton];
	}

	void DispatchInterfaceInput()
	{
		if( !g_pInterfaceMgr )
			return;

		const GameState eGameState = g_pInterfaceMgr->GetGameState();
		if( WasButtonPressed( eSDLGamepadButton_Start ) )
		{
			SendInterfaceKey( VK_ESCAPE );
			return;
		}

		if( eGameState == GS_PLAYING )
			return;

		if( WasButtonPressed( eSDLGamepadButton_DPadUp ) )
			SendInterfaceKey( VK_UP );
		else if( WasButtonPressed( eSDLGamepadButton_DPadDown ) )
			SendInterfaceKey( VK_DOWN );
		else if( WasButtonPressed( eSDLGamepadButton_DPadLeft ) )
			SendInterfaceKey( VK_LEFT );
		else if( WasButtonPressed( eSDLGamepadButton_DPadRight ) )
			SendInterfaceKey( VK_RIGHT );
		else if( WasButtonPressed( eSDLGamepadButton_South ) )
			SendInterfaceKey( VK_RETURN );
		else if( WasButtonPressed( eSDLGamepadButton_East ) )
			SendInterfaceKey( VK_ESCAPE );
	}

	void BuildCommandState()
	{
		ClearInput();

		const float fDeadZone = LTCLAMP(
			GetConsoleFloat( FearMoreControllerSettings::kDeadZoneCVar,
				FearMoreControllerSettings::kDeadZoneDefault ),
			FearMoreControllerSettings::kDeadZoneMinimum,
			FearMoreControllerSettings::kDeadZoneMaximum );

		float fLeftX = NormalizeSignedAxis( m_pGetGamepadAxis( m_pGamepad, eSDLGamepadAxis_LeftX ) );
		float fLeftY = NormalizeSignedAxis( m_pGetGamepadAxis( m_pGamepad, eSDLGamepadAxis_LeftY ) );
		float fRightX = NormalizeSignedAxis( m_pGetGamepadAxis( m_pGamepad, eSDLGamepadAxis_RightX ) );
		float fRightY = NormalizeSignedAxis( m_pGetGamepadAxis( m_pGamepad, eSDLGamepadAxis_RightY ) );
		ApplyRadialDeadZone( fLeftX, fLeftY, fDeadZone );
		ApplyRadialDeadZone( fRightX, fRightY, fDeadZone );

		m_afCommandValues[COMMAND_ID_STRAFE_AXIS] = fLeftX;
		m_afCommandValues[COMMAND_ID_FORWARD_AXIS] = -fLeftY;
		m_afCommandValues[COMMAND_ID_YAW_ACCEL] = fRightX;

		// PlayerMgr historically applies MouseInvertY to the combined mouse and
		// gamepad pitch.  Compensate here so FearMoreControllerInvertY remains an
		// independent controller option without changing legacy mouse behavior.
		const bool bMouseInvert = GetConsoleInt( "MouseInvertY", 0 ) != 0;
		const bool bControllerInvert = GetConsoleInt(
			FearMoreControllerSettings::kInvertYCVar,
			FearMoreControllerSettings::kInvertYDefault ? 1 : 0 ) != 0;
		if( bMouseInvert != bControllerInvert )
			fRightY = -fRightY;
		m_afCommandValues[COMMAND_ID_PITCH_ACCEL] = fRightY;

		for( int nButton = 0; nButton < eSDLGamepadButton_Count; ++nButton )
			m_abCurrentButtons[nButton] = m_pGetGamepadButton( m_pGamepad, nButton );

		SetCommandButton( COMMAND_ID_JUMP, m_abCurrentButtons[eSDLGamepadButton_South] );
		SetCommandButton( COMMAND_ID_DUCK, m_abCurrentButtons[eSDLGamepadButton_East] );
		SetCommandButton( COMMAND_ID_ACTIVATE, m_abCurrentButtons[eSDLGamepadButton_West] );
		SetCommandButton( COMMAND_ID_RELOAD, m_abCurrentButtons[eSDLGamepadButton_North] );
		SetCommandButton( COMMAND_ID_MISSION, m_abCurrentButtons[eSDLGamepadButton_Back] );
		SetCommandButton( COMMAND_ID_MEDKIT, m_abCurrentButtons[eSDLGamepadButton_LeftStick] );
		SetCommandButton( COMMAND_ID_FLASHLIGHT, m_abCurrentButtons[eSDLGamepadButton_RightStick] );
		SetCommandButton( COMMAND_ID_THROW_GRENADE, m_abCurrentButtons[eSDLGamepadButton_LeftShoulder] );
		SetCommandButton( COMMAND_ID_TOGGLEMELEE, m_abCurrentButtons[eSDLGamepadButton_RightShoulder] );
		SetCommandButton( COMMAND_ID_NEXT_WEAPON, m_abCurrentButtons[eSDLGamepadButton_DPadUp] );
		SetCommandButton( COMMAND_ID_NEXT_GRENADE, m_abCurrentButtons[eSDLGamepadButton_DPadDown] );
		SetCommandButton( COMMAND_ID_LEAN_LEFT, m_abCurrentButtons[eSDLGamepadButton_DPadLeft] );
		SetCommandButton( COMMAND_ID_LEAN_RIGHT, m_abCurrentButtons[eSDLGamepadButton_DPadRight] );

		const float fLeftTrigger = NormalizeTrigger(
			m_pGetGamepadAxis( m_pGamepad, eSDLGamepadAxis_LeftTrigger ) );
		const float fRightTrigger = NormalizeTrigger(
			m_pGetGamepadAxis( m_pGamepad, eSDLGamepadAxis_RightTrigger ) );
		SetCommandButton( COMMAND_ID_FOCUS, fLeftTrigger >= kTriggerThreshold );
		SetCommandButton( COMMAND_ID_FIRING, fRightTrigger >= kTriggerThreshold );

		DispatchInterfaceInput();
		memcpy( m_abPreviousButtons, m_abCurrentButtons, sizeof( m_abPreviousButtons ) );
	}

	HMODULE m_hSDL;
	SDL_Gamepad* m_pGamepad;
	bool m_bSubsystemInitialized;
	bool m_bInputActiveLastFrame;
	DWORD m_nLastConnectAttempt;
	DWORD m_nLastRumbleUpdate;
	uint16 m_nLastLowRumble;
	uint16 m_nLastHighRumble;
	float m_afCommandValues[kMaximumCommand + 1];
	bool m_abCommandStates[kMaximumCommand + 1];
	bool m_abPreviousButtons[eSDLGamepadButton_Count];
	bool m_abCurrentButtons[eSDLGamepadButton_Count];

	TSDLInitSubSystem m_pInitSubSystem;
	TSDLQuitSubSystem m_pQuitSubSystem;
	TSDLGetGamepads m_pGetGamepads;
	TSDLOpenGamepad m_pOpenGamepad;
	TSDLCloseGamepad m_pCloseGamepad;
	TSDLGamepadConnected m_pGamepadConnected;
	TSDLUpdateGamepads m_pUpdateGamepads;
	TSDLGetGamepadAxis m_pGetGamepadAxis;
	TSDLGetGamepadButton m_pGetGamepadButton;
	TSDLRumbleGamepad m_pRumbleGamepad;
	TSDLFree m_pFree;
	TSDLGetError m_pGetError;
};

CFearMoreControllerMgr::CFearMoreControllerMgr()
	: m_pImpl( NULL ),
	  m_nLastInitializeAttempt( 0 )
{
}

CFearMoreControllerMgr::~CFearMoreControllerMgr()
{
	Shutdown();
}

CFearMoreControllerMgr& CFearMoreControllerMgr::Instance()
{
	static CFearMoreControllerMgr s_Instance;
	return s_Instance;
}

void CFearMoreControllerMgr::Initialize()
{
	if( m_pImpl )
		return;

	m_nLastInitializeAttempt = GetTickCount();
	m_pImpl = debug_new( SImpl );
	if( !m_pImpl->LoadRuntime() )
	{
		if( g_pLTClient )
			g_pLTClient->CPrint( "FearMore controller: SDL3.dll is unavailable or incompatible; keyboard and mouse remain active." );
		Shutdown();
		return;
	}

	if( !m_pImpl->m_pInitSubSystem( kSDLInitGamepad ) )
	{
		if( g_pLTClient )
			g_pLTClient->CPrint( "FearMore controller: SDL gamepad initialization failed (%s); keyboard and mouse remain active.", m_pImpl->GetError() );
		Shutdown();
		return;
	}

	m_pImpl->m_bSubsystemInitialized = true;
	m_pImpl->m_nLastConnectAttempt = GetTickCount() - kReconnectIntervalMs;
	m_pImpl->TryOpenGamepad( GetTickCount() );
}

void CFearMoreControllerMgr::Shutdown()
{
	if( !m_pImpl )
		return;

	m_pImpl->CloseGamepad();
	if( m_pImpl->m_bSubsystemInitialized && m_pImpl->m_pQuitSubSystem )
		m_pImpl->m_pQuitSubSystem( kSDLInitGamepad );
	m_pImpl->m_bSubsystemInitialized = false;
	if( m_pImpl->m_hSDL )
		FreeLibrary( m_pImpl->m_hSDL );
	m_pImpl->m_hSDL = NULL;
	debug_delete( m_pImpl );
	m_pImpl = NULL;
}

void CFearMoreControllerMgr::Update()
{
	if( !m_pImpl || !m_pImpl->m_bSubsystemInitialized )
	{
		const DWORD nNow = GetTickCount();
		if( ( nNow - m_nLastInitializeAttempt ) >= kRuntimeRetryIntervalMs )
			Initialize();
		return;
	}

	m_pImpl->m_pUpdateGamepads();
	if( m_pImpl->m_pGamepad && !m_pImpl->m_pGamepadConnected( m_pImpl->m_pGamepad ) )
	{
		if( g_pLTClient )
			g_pLTClient->CPrint( "FearMore controller: SDL3 gamepad disconnected." );
		m_pImpl->CloseGamepad();
	}
	m_pImpl->TryOpenGamepad( GetTickCount() );

	const bool bEnabled = GetConsoleInt(
		FearMoreControllerSettings::kEnabledCVar,
		FearMoreControllerSettings::kEnabledDefault ? 1 : 0 ) != 0;
	const bool bFocused = g_pGameClientShell && g_pGameClientShell->IsMainWindowFocus();
	const bool bInputActive = bEnabled && bFocused && m_pImpl->m_pGamepad;
	if( !bInputActive )
	{
		m_pImpl->ClearInput();
		memset( m_pImpl->m_abPreviousButtons, 0, sizeof( m_pImpl->m_abPreviousButtons ) );
		memset( m_pImpl->m_abCurrentButtons, 0, sizeof( m_pImpl->m_abCurrentButtons ) );
		if( m_pImpl->m_bInputActiveLastFrame )
			SetRumble( 0.0f, 0.0f );
		m_pImpl->m_bInputActiveLastFrame = false;
		return;
	}

	m_pImpl->BuildCommandState();
	m_pImpl->m_bInputActiveLastFrame = true;
}

float CFearMoreControllerMgr::GetCommandValue( uint32 nCommand ) const
{
	if( !m_pImpl || !m_pImpl->m_bInputActiveLastFrame || nCommand > kMaximumCommand )
		return 0.0f;
	return m_pImpl->m_afCommandValues[nCommand];
}

bool CFearMoreControllerMgr::IsCommandOn( uint32 nCommand ) const
{
	return m_pImpl && m_pImpl->m_bInputActiveLastFrame && nCommand <= kMaximumCommand &&
		m_pImpl->m_abCommandStates[nCommand];
}

uint32 CFearMoreControllerMgr::GetHighestMappedCommand() const
{
	return kMaximumCommand;
}

bool CFearMoreControllerMgr::IsRuntimeAvailable() const
{
	return m_pImpl && m_pImpl->m_bSubsystemInitialized;
}

bool CFearMoreControllerMgr::IsGamepadConnected() const
{
	return IsRuntimeAvailable() && m_pImpl->m_pGamepad != NULL;
}

bool CFearMoreControllerMgr::IsInputActive() const
{
	if( !IsGamepadConnected() || !m_pImpl->m_bInputActiveLastFrame )
		return false;

	const bool bEnabled = GetConsoleInt(
		FearMoreControllerSettings::kEnabledCVar,
		FearMoreControllerSettings::kEnabledDefault ? 1 : 0 ) != 0;
	const bool bFocused = g_pGameClientShell && g_pGameClientShell->IsMainWindowFocus();
	return bEnabled && bFocused;
}

void CFearMoreControllerMgr::SetRumble( float fLowFrequency, float fHighFrequency )
{
	if( !m_pImpl || !m_pImpl->m_pGamepad || !m_pImpl->m_pRumbleGamepad )
		return;

	const bool bRumbleEnabled = GetConsoleInt(
		FearMoreControllerSettings::kRumbleCVar,
		FearMoreControllerSettings::kRumbleDefault ? 1 : 0 ) != 0;
	const bool bAllowRumble = bRumbleEnabled && IsInputActive();
	const uint16 nLow = bAllowRumble ? ToRumbleValue( fLowFrequency ) : 0;
	const uint16 nHigh = bAllowRumble ? ToRumbleValue( fHighFrequency ) : 0;
	const DWORD nNow = GetTickCount();
	if( nLow == m_pImpl->m_nLastLowRumble && nHigh == m_pImpl->m_nLastHighRumble &&
		( nNow - m_pImpl->m_nLastRumbleUpdate ) < kRumbleRefreshMs )
	{
		return;
	}

	const uint32 nDuration = ( nLow || nHigh ) ? kRumbleDurationMs : 0;
	m_pImpl->m_pRumbleGamepad( m_pImpl->m_pGamepad, nLow, nHigh, nDuration );
	m_pImpl->m_nLastLowRumble = nLow;
	m_pImpl->m_nLastHighRumble = nHigh;
	m_pImpl->m_nLastRumbleUpdate = nNow;
}
