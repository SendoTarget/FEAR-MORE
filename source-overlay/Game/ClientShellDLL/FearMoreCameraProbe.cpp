// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreCameraProbe.cpp
//
// PURPOSE : Opt-in source camera telemetry for renderer modernization
//
// ----------------------------------------------------------------------- //

#include "Stdafx.h"
#include "FearMoreCameraProbe.h"

#include "ILTRenderer.h"
#include "VarTrack.h"
#include "WinUtil.h"
#include "iltfilemgr.h"

#include <float.h>
#include <fstream>
#include <iomanip>
#include <locale>
#include <sstream>

namespace
{
	static const uint32 kMaxCapturedFrames = 3600;
	static const char* const kDiagnosticsCVar = "FearMoreCameraDiagnostics";
	static const char* const kDiagnosticsDirectory = "FearMoreDiagnostics";
	static VarTrack s_CameraDiagnosticsEnabled;

	struct ProjectionProbe
	{
		ProjectionProbe()
			: m_nResult( LT_ERROR )
		{
			m_vWorld.Init();
			m_vScreen.Init();
		}

		LTVector	m_vWorld;
		LTVector	m_vScreen;
		LTRESULT	m_nResult;
	};

	struct PendingCameraFrame
	{
		PendingCameraFrame()
		{
			Reset();
		}

		void Reset()
		{
			m_bActive = false;
			m_nFrameIndex = 0;
			m_nCameraMode = 0;
			m_bPixelDoubleRequested = false;
			m_bInternalRenderTargetActive = false;
			m_bTransformValid = false;
			m_bFovValid = false;
			m_bViewportValid = false;
			m_bRenderTargetDimsValid = false;
			m_bNearZValid = false;
			m_bFarZValid = false;
			m_nRenderTargetWidth = 0;
			m_nRenderTargetHeight = 0;
			m_fNearZ = 0.0f;
			m_fFarZ = 0.0f;
			m_nQpcBefore = 0;
			m_tTransform.Init();
			m_vFov.Init();
			m_rViewport.Init( 0.0f, 0.0f, 1.0f, 1.0f );
			for( uint32 nProbe = 0; nProbe < LTARRAYSIZE( m_aProbes ); ++nProbe )
			{
				m_aProbes[nProbe] = ProjectionProbe();
			}
		}

		bool			m_bActive;
		uint32			m_nFrameIndex;
		int				m_nCameraMode;
		bool			m_bPixelDoubleRequested;
		bool			m_bInternalRenderTargetActive;
		bool			m_bTransformValid;
		bool			m_bFovValid;
		bool			m_bViewportValid;
		bool			m_bRenderTargetDimsValid;
		bool			m_bNearZValid;
		bool			m_bFarZValid;
		LTRigidTransform	m_tTransform;
		LTVector2		m_vFov;
		LTRect2f		m_rViewport;
		uint32			m_nRenderTargetWidth;
		uint32			m_nRenderTargetHeight;
		float			m_fNearZ;
		float			m_fFarZ;
		ProjectionProbe	m_aProbes[3];
		__int64			m_nQpcBefore;
	};

	bool InitializeDiagnosticsVariable()
	{
		if( !g_pLTClient )
		{
			return false;
		}

		if( !s_CameraDiagnosticsEnabled.IsInitted() )
		{
			s_CameraDiagnosticsEnabled.Init( g_pLTClient, kDiagnosticsCVar, NULL, 0.0f );
		}

		return s_CameraDiagnosticsEnabled.IsInitted();
	}

	void WriteJsonFloat( std::ostream& output, float fValue )
	{
		if( _finite( fValue ) )
		{
			output << fValue;
		}
		else
		{
			output << "null";
		}
	}

	void WriteJsonVector( std::ostream& output, const LTVector& vValue )
	{
		output << '[';
		WriteJsonFloat( output, vValue.x );
		output << ',';
		WriteJsonFloat( output, vValue.y );
		output << ',';
		WriteJsonFloat( output, vValue.z );
		output << ']';
	}

	void WriteJsonProjectionProbe( std::ostream& output, const char* pszName,
		const ProjectionProbe& probe )
	{
		output << "{\"name\":\"" << pszName << "\",\"world\":";
		WriteJsonVector( output, probe.m_vWorld );
		output << ",\"result\":" << static_cast<unsigned long>( probe.m_nResult )
			<< ",\"screen_normalized_xy\":";
		if( probe.m_nResult == LT_OK )
		{
			output << '[';
			WriteJsonFloat( output, probe.m_vScreen.x );
			output << ',';
			WriteJsonFloat( output, probe.m_vScreen.y );
			output << ']';
		}
		else
		{
			output << "null";
		}
		output << ",\"camera_z\":";
		if( probe.m_nResult == LT_OK )
		{
			WriteJsonFloat( output, probe.m_vScreen.z );
		}
		else
		{
			output << "null";
		}
		output << '}';
	}

	bool ReadConsoleFloat( const char* pszVariable, float& fValue )
	{
		HCONSOLEVAR hVariable = g_pLTClient->GetConsoleVariable( pszVariable );
		if( !hVariable )
		{
			return false;
		}

		fValue = g_pLTClient->GetConsoleVariableFloat( hVariable );
		return true;
	}

	class CameraProbeState
	{
	public:
		CameraProbeState()
			: m_bOutputFailed( false ),
			  m_bLimitReported( false ),
			  m_bDiagnosticsWasEnabled( false ),
			  m_bSideMaskStateKnown( false ),
			  m_bLastSideMaskRequested( false ),
			  m_nFrameCount( 0 ),
			  m_nProcessId( GetCurrentProcessId() ),
			  m_nQpcFrequency( 0 )
		{
			LARGE_INTEGER qpcFrequency;
			if( QueryPerformanceFrequency( &qpcFrequency ) )
			{
				m_nQpcFrequency = qpcFrequency.QuadPart;
			}
		}

		~CameraProbeState()
		{
			if( m_Output.is_open() )
			{
				m_Output.flush();
				m_Output.close();
			}
		}

		FearMoreCameraProbe::CameraRenderToken Begin( HLOCALOBJ hCamera, int nCameraMode,
			bool bPixelDoubleRequested, bool bInternalRenderTargetActive )
		{
			FearMoreCameraProbe::CameraRenderToken token;
			if( !InitializeDiagnosticsVariable() || m_bOutputFailed )
			{
				return token;
			}

			const bool bDiagnosticsEnabled = ( s_CameraDiagnosticsEnabled.GetFloat() > 0.0f );
			if( !bDiagnosticsEnabled )
			{
				// Preserve the final partial batch when a developer disables capture
				// without ending the process.  Keep the stream open so re-enabling
				// continues the same bounded trace instead of truncating evidence.
				if( m_bDiagnosticsWasEnabled && m_Output.is_open() )
				{
					m_Output.flush();
					if( !m_Output.good() )
					{
						ReportOutputError( "flush" );
					}
				}
				m_bDiagnosticsWasEnabled = false;
				return token;
			}
			m_bDiagnosticsWasEnabled = true;

			if( m_nFrameCount >= kMaxCapturedFrames )
			{
				ReportCaptureLimit();
				return token;
			}

			if( !EnsureOutput() )
			{
				return token;
			}

			// The main camera is single-threaded and non-reentrant.  Refuse to
			// replace an unfinished record if that invariant is ever violated.
			if( m_Pending.m_bActive )
			{
				return token;
			}

			m_Pending.Reset();
			m_Pending.m_bActive = true;
			m_Pending.m_nFrameIndex = m_nFrameCount++;
			m_Pending.m_nCameraMode = nCameraMode;
			m_Pending.m_bPixelDoubleRequested = bPixelDoubleRequested;
			m_Pending.m_bInternalRenderTargetActive = bInternalRenderTargetActive;

			if( hCamera )
			{
				m_Pending.m_bTransformValid =
					( g_pLTClient->GetObjectTransform( hCamera, &m_Pending.m_tTransform ) == LT_OK );
				g_pLTClient->GetCameraFOV( hCamera, &m_Pending.m_vFov.x, &m_Pending.m_vFov.y );
				m_Pending.m_bFovValid = true;
				g_pLTClient->GetCameraRect( hCamera, m_Pending.m_rViewport );
				m_Pending.m_bViewportValid = true;
			}

			ILTRenderer* pRenderer = g_pLTClient->GetRenderer();
			if( pRenderer )
			{
				m_Pending.m_bRenderTargetDimsValid =
					( pRenderer->GetCurrentRenderTargetDims(
						m_Pending.m_nRenderTargetWidth, m_Pending.m_nRenderTargetHeight ) == LT_OK );

				if( hCamera && m_Pending.m_bTransformValid )
				{
					const LTVector vRight = m_Pending.m_tTransform.m_rRot.Right();
					const LTVector vUp = m_Pending.m_tTransform.m_rRot.Up();
					const LTVector vForward = m_Pending.m_tTransform.m_rRot.Forward();
					const LTVector vCenter = m_Pending.m_tTransform.m_vPos + ( vForward * 100.0f );

					m_Pending.m_aProbes[0].m_vWorld = vCenter;
					m_Pending.m_aProbes[1].m_vWorld = vCenter + ( vRight * 25.0f );
					m_Pending.m_aProbes[2].m_vWorld = vCenter + ( vUp * 25.0f );
					for( uint32 nProbe = 0; nProbe < LTARRAYSIZE( m_Pending.m_aProbes ); ++nProbe )
					{
						m_Pending.m_aProbes[nProbe].m_nResult = pRenderer->WorldPosToScreenPos(
							hCamera, m_Pending.m_aProbes[nProbe].m_vWorld,
							m_Pending.m_aProbes[nProbe].m_vScreen );
					}
				}
			}

			m_Pending.m_bNearZValid = ReadConsoleFloat( "NearZ", m_Pending.m_fNearZ );
			m_Pending.m_bFarZValid = ReadConsoleFloat( "FarZ", m_Pending.m_fFarZ );

			LARGE_INTEGER qpcBefore;
			qpcBefore.QuadPart = 0;
			QueryPerformanceCounter( &qpcBefore );
			m_Pending.m_nQpcBefore = qpcBefore.QuadPart;

			token.m_nFrameIndex = m_Pending.m_nFrameIndex;
			token.m_bActive = true;
			return token;
		}

		void End( const FearMoreCameraProbe::CameraRenderToken& token, LTRESULT nRenderResult )
		{
			if( !token.m_bActive || !m_Pending.m_bActive ||
				token.m_nFrameIndex != m_Pending.m_nFrameIndex )
			{
				return;
			}

			LARGE_INTEGER qpcAfter;
			qpcAfter.QuadPart = 0;
			QueryPerformanceCounter( &qpcAfter );
			m_Pending.m_bActive = false;

			std::ostringstream line;
			line.imbue( std::locale::classic() );
			line << std::fixed << std::setprecision( 9 );
			line << "{\"schema\":\"fearmore.camera-source\",\"version\":2"
				<< ",\"pid\":" << static_cast<unsigned long>( m_nProcessId )
				<< ",\"frame_index\":" << m_Pending.m_nFrameIndex
				<< ",\"marker\":\"main_camera_render\""
				<< ",\"qpc_frequency\":" << m_nQpcFrequency
				<< ",\"qpc_before\":" << m_Pending.m_nQpcBefore
				<< ",\"qpc_after\":" << qpcAfter.QuadPart
				<< ",\"render_result\":" << static_cast<unsigned long>( nRenderResult )
				<< ",\"camera_mode\":" << m_Pending.m_nCameraMode;

			line << ",\"transform\":";
			if( m_Pending.m_bTransformValid )
			{
				const LTRotation& rRotation = m_Pending.m_tTransform.m_rRot;
				line << "{\"position\":";
				WriteJsonVector( line, m_Pending.m_tTransform.m_vPos );
				line << ",\"rotation_xyzw\":[";
				WriteJsonFloat( line, rRotation.m_Quat[LTRotation::QX] );
				line << ',';
				WriteJsonFloat( line, rRotation.m_Quat[LTRotation::QY] );
				line << ',';
				WriteJsonFloat( line, rRotation.m_Quat[LTRotation::QZ] );
				line << ',';
				WriteJsonFloat( line, rRotation.m_Quat[LTRotation::QW] );
				line << "],\"basis\":{\"right\":";
				WriteJsonVector( line, rRotation.Right() );
				line << ",\"up\":";
				WriteJsonVector( line, rRotation.Up() );
				line << ",\"forward\":";
				WriteJsonVector( line, rRotation.Forward() );
				line << "}}";
			}
			else
			{
				line << "null";
			}

			line << ",\"fov_radians\":";
			if( m_Pending.m_bFovValid )
			{
				line << '[';
				WriteJsonFloat( line, m_Pending.m_vFov.x );
				line << ',';
				WriteJsonFloat( line, m_Pending.m_vFov.y );
				line << ']';
			}
			else
			{
				line << "null";
			}

			line << ",\"viewport_normalized\":";
			if( m_Pending.m_bViewportValid )
			{
				line << '[';
				WriteJsonFloat( line, m_Pending.m_rViewport.Left() );
				line << ',';
				WriteJsonFloat( line, m_Pending.m_rViewport.Top() );
				line << ',';
				WriteJsonFloat( line, m_Pending.m_rViewport.Right() );
				line << ',';
				WriteJsonFloat( line, m_Pending.m_rViewport.Bottom() );
				line << ']';
			}
			else
			{
				line << "null";
			}

			line << ",\"render_target\":{\"width\":";
			if( m_Pending.m_bRenderTargetDimsValid )
			{
				line << m_Pending.m_nRenderTargetWidth;
			}
			else
			{
				line << "null";
			}
			line << ",\"height\":";
			if( m_Pending.m_bRenderTargetDimsValid )
			{
				line << m_Pending.m_nRenderTargetHeight;
			}
			else
			{
				line << "null";
			}
			line << '}';

			line << ",\"clip\":{\"near_z\":";
			if( m_Pending.m_bNearZValid )
			{
				WriteJsonFloat( line, m_Pending.m_fNearZ );
			}
			else
			{
				line << "null";
			}
			line << ",\"far_z\":";
			if( m_Pending.m_bFarZValid )
			{
				WriteJsonFloat( line, m_Pending.m_fFarZ );
			}
			else
			{
				line << "null";
			}
			line << '}';

			line << ",\"pixel_double\":{\"requested\":"
				<< ( m_Pending.m_bPixelDoubleRequested ? "true" : "false" )
				<< ",\"internal_target_active\":"
				<< ( m_Pending.m_bInternalRenderTargetActive ? "true" : "false" ) << '}';

			line << ",\"projection_probes\":[";
			if( m_Pending.m_bTransformValid )
			{
				WriteJsonProjectionProbe( line, "forward_100", m_Pending.m_aProbes[0] );
				line << ',';
				WriteJsonProjectionProbe( line, "forward_100_right_25", m_Pending.m_aProbes[1] );
				line << ',';
				WriteJsonProjectionProbe( line, "forward_100_up_25", m_Pending.m_aProbes[2] );
			}
			line << "]}";

			m_Output << line.str() << '\n';
			// Flush the first record so an early failure still leaves evidence,
			// then batch subsequent writes to avoid a synchronous disk flush in
			// every active gameplay frame.
			if( m_Pending.m_nFrameIndex == 0 ||
				( ( m_Pending.m_nFrameIndex + 1 ) % 60 ) == 0 ||
				m_nFrameCount >= kMaxCapturedFrames )
			{
				m_Output.flush();
			}
			if( !m_Output.good() )
			{
				ReportOutputError( "write" );
				return;
			}

			if( m_nFrameCount >= kMaxCapturedFrames )
			{
				ReportCaptureLimit();
			}
		}

		void RecordCinematicSideMaskState(
			const FearMoreCameraProbe::CinematicSideMaskState& state )
		{
			if( !InitializeDiagnosticsVariable() ||
				s_CameraDiagnosticsEnabled.GetFloat() <= 0.0f )
			{
				m_bSideMaskStateKnown = false;
				return;
			}

			if( m_bSideMaskStateKnown &&
				m_bLastSideMaskRequested == state.m_bSideMaskRequested )
			{
				return;
			}

			m_bSideMaskStateKnown = true;
			m_bLastSideMaskRequested = state.m_bSideMaskRequested;
			g_pLTClient->CPrint(
				"FearMore cinematic framing: side_mask=%u mode=%d live_camera=%u vehicle=%u lure_id=%lu lure_fx=%u freedom=%d special=%u crosshair_enabled=%u allow_weapon=%u allow_switch=%u retain_offsets=%u track_pitch=%u track_yaw=%u body_rotation=%u",
				state.m_bSideMaskRequested ? 1 : 0,
				state.m_nCameraMode,
				state.m_bLiveCinematicCamera ? 1 : 0,
				state.m_bVehiclePhysics ? 1 : 0,
				static_cast<unsigned long>( state.m_nPlayerLureId ),
				state.m_bPlayerLureFxValid ? 1 : 0,
				state.m_nCameraFreedom,
				state.m_bPlayingSpecial ? 1 : 0,
				state.m_bAuthoredCrosshairEnabled ? 1 : 0,
				state.m_bAllowWeapon ? 1 : 0,
				state.m_bAllowSwitchWeapon ? 1 : 0,
				state.m_bRetainOffsets ? 1 : 0,
				state.m_bTrackPitch ? 1 : 0,
				state.m_bTrackYaw ? 1 : 0,
				state.m_bAllowBodyRotation ? 1 : 0 );
		}

	private:
		bool EnsureOutput()
		{
			if( m_Output.is_open() )
			{
				return true;
			}

			char szDiagnosticsDirectory[MAX_PATH];
			if( !g_pLTClient->FileMgr() ||
				g_pLTClient->FileMgr()->GetAbsoluteUserFileName(
					kDiagnosticsDirectory, szDiagnosticsDirectory,
					LTARRAYSIZE( szDiagnosticsDirectory ) ) != LT_OK ||
				!CWinUtil::CreateDir( szDiagnosticsDirectory ) )
			{
				ReportOutputError( "create directory" );
				return false;
			}

			char szOutputPath[MAX_PATH];
			LTSNPrintF( szOutputPath, LTARRAYSIZE( szOutputPath ),
				"%s\\camera-source-%lu.jsonl", szDiagnosticsDirectory,
				static_cast<unsigned long>( m_nProcessId ) );

			m_Output.open( szOutputPath, std::ios::out | std::ios::trunc );
			if( !m_Output.good() )
			{
				ReportOutputError( "open" );
				return false;
			}

			m_Output.imbue( std::locale::classic() );
			g_pLTClient->CPrint( "FearMore camera diagnostics: writing UserDirectory/%s/camera-source-%lu.jsonl",
				kDiagnosticsDirectory, static_cast<unsigned long>( m_nProcessId ) );
			return true;
		}

		void ReportOutputError( const char* pszOperation )
		{
			if( g_pLTClient )
			{
				g_pLTClient->CPrint( "FearMore camera diagnostics: unable to %s UserDirectory/%s output; disabling capture for this process.",
					pszOperation, kDiagnosticsDirectory );
			}
			if( m_Output.is_open() )
			{
				m_Output.close();
			}
			m_bOutputFailed = true;
			m_Pending.m_bActive = false;
		}

		void ReportCaptureLimit()
		{
			if( m_bLimitReported )
			{
				return;
			}

			if( m_Output.is_open() )
			{
				m_Output.flush();
			}
			if( g_pLTClient )
			{
				g_pLTClient->CPrint( "FearMore camera diagnostics: capture stopped at the %u-frame safety limit.",
					kMaxCapturedFrames );
			}
			m_bLimitReported = true;
		}

	private:
		std::ofstream		m_Output;
		bool				m_bOutputFailed;
		bool				m_bLimitReported;
		bool				m_bDiagnosticsWasEnabled;
		bool				m_bSideMaskStateKnown;
		bool				m_bLastSideMaskRequested;
		uint32				m_nFrameCount;
		DWORD				m_nProcessId;
		__int64				m_nQpcFrequency;
		PendingCameraFrame	m_Pending;
	};

	CameraProbeState& GetCameraProbeState()
	{
		static CameraProbeState s_State;
		return s_State;
	}
}

FearMoreCameraProbe::CameraRenderToken FearMoreCameraProbe::BeginMainCameraRender(
	HLOCALOBJ hCamera, int nCameraMode, bool bPixelDoubleRequested,
	bool bInternalRenderTargetActive )
{
	return GetCameraProbeState().Begin( hCamera, nCameraMode,
		bPixelDoubleRequested, bInternalRenderTargetActive );
}

void FearMoreCameraProbe::EndMainCameraRender( const CameraRenderToken& token,
	LTRESULT nRenderResult )
{
	GetCameraProbeState().End( token, nRenderResult );
}

void FearMoreCameraProbe::RecordCinematicSideMaskState(
	const CinematicSideMaskState& state )
{
	GetCameraProbeState().RecordCinematicSideMaskState( state );
}
