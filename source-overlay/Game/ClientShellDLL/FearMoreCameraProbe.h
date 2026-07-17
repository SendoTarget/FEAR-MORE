// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreCameraProbe.h
//
// PURPOSE : Opt-in source camera telemetry for renderer modernization
//
// ----------------------------------------------------------------------- //

#ifndef __FEARMORECAMERAPROBE_H__
#define __FEARMORECAMERAPROBE_H__

#include "ltbasedefs.h"

namespace FearMoreCameraProbe
{
	struct CameraRenderToken
	{
		CameraRenderToken()
			: m_nFrameIndex( 0 ),
			  m_bActive( false )
		{
		}

		uint32	m_nFrameIndex;
		bool	m_bActive;
	};

	struct CinematicSideMaskState
	{
		CinematicSideMaskState()
			: m_nCameraMode( 0 ),
			  m_bLiveCinematicCamera( false ),
			  m_bVehiclePhysics( false ),
			  m_nPlayerLureId( 0 ),
			  m_bPlayerLureFxValid( false ),
			  m_nCameraFreedom( 0 ),
			  m_bAllowWeapon( false ),
			  m_bAllowSwitchWeapon( false ),
			  m_bRetainOffsets( false ),
			  m_bTrackPitch( false ),
			  m_bTrackYaw( false ),
			  m_bAllowBodyRotation( false ),
			  m_bPlayingSpecial( false ),
			  m_bAuthoredCrosshairEnabled( true ),
			  m_bSideMaskRequested( false )
		{
		}

		int		m_nCameraMode;
		bool	m_bLiveCinematicCamera;
		bool	m_bVehiclePhysics;
		uint32	m_nPlayerLureId;
		bool	m_bPlayerLureFxValid;
		int		m_nCameraFreedom;
		bool	m_bAllowWeapon;
		bool	m_bAllowSwitchWeapon;
		bool	m_bRetainOffsets;
		bool	m_bTrackPitch;
		bool	m_bTrackYaw;
		bool	m_bAllowBodyRotation;
		bool	m_bPlayingSpecial;
		bool	m_bAuthoredCrosshairEnabled;
		bool	m_bSideMaskRequested;
	};

	// Bracket only the authoritative player-camera render call.  When
	// FearMoreCameraDiagnostics is zero (the default), Begin returns an
	// inactive token and both calls are no-ops apart from the cvar check.
	CameraRenderToken BeginMainCameraRender( HLOCALOBJ hCamera, int nCameraMode,
		bool bPixelDoubleRequested, bool bInternalRenderTargetActive );
	void EndMainCameraRender( const CameraRenderToken& token, LTRESULT nRenderResult );

	// Emits one console line only when the derived side-mask request changes and
	// only while the existing FearMoreCameraDiagnostics opt-in is enabled.
	void RecordCinematicSideMaskState( const CinematicSideMaskState& state );
}

#endif // __FEARMORECAMERAPROBE_H__
