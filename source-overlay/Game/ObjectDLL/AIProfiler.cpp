// ----------------------------------------------------------------------- //
//
// MODULE  : AIProfiler.cpp
//
// PURPOSE : Opt-in, server-frame AI profiling
//
// ----------------------------------------------------------------------- //

#include "Stdafx.h"
#include "AIProfiler.h"

#include "VarTrack.h"
#include "iltfilemgr.h"
#include "iltoutstream.h"

namespace
{
	static const char* const kpszDefaultProfileFile = "AIProfile.csv";
	static VarTrack s_AIProfileEnabled;
	static VarTrack s_AIProfileFile;

	bool InitializeProfileVariables()
	{
		if( !g_pLTServer )
		{
			return false;
		}

		if( !s_AIProfileEnabled.IsInitted() )
		{
			s_AIProfileEnabled.Init( g_pLTServer, "AIProfileEnabled", NULL, 0.0f );
		}

		if( !s_AIProfileFile.IsInitted() )
		{
			s_AIProfileFile.Init( g_pLTServer, "AIProfileFile", kpszDefaultProfileFile, 0.0f );
		}

		return s_AIProfileEnabled.IsInitted() && s_AIProfileFile.IsInitted();
	}
}

CAIProfiler& CAIProfiler::Instance()
{
	static CAIProfiler s_Profiler;
	return s_Profiler;
}

CAIProfiler::CAIProfiler()
	: m_pOutput( NULL ),
	  m_bFrameActive( false ),
	  m_bOpenFailed( false ),
	  m_nFrameIndex( 0 ),
	  m_nFrameStartTime( 0 ),
	  m_nPreviousFrameStartTime( 0 ),
	  m_fFrameDeltaMS( 0.0 )
{
	m_szOutputFile[0] = '\0';
	ResetFrame();
}

CAIProfiler::~CAIProfiler()
{
	Shutdown();
}

void CAIProfiler::BeginServerFrame()
{
	// A missing PostUpdate must not leak timing into the next frame.
	m_bFrameActive = false;

	if( !RefreshOutput() )
	{
		return;
	}

	ResetFrame();
	m_nFrameStartTime = LTTimeUtils::GetPrecisionTime();
	m_fFrameDeltaMS = ( m_nPreviousFrameStartTime != 0 )
		? LTTimeUtils::GetPrecisionTimeIntervalMS( m_nPreviousFrameStartTime, m_nFrameStartTime )
		: 0.0;
	m_nPreviousFrameStartTime = m_nFrameStartTime;
	m_bFrameActive = true;
}

void CAIProfiler::EndServerFrame()
{
	if( !m_bFrameActive )
	{
		return;
	}

	const TLTPrecisionTime nFrameEndTime = LTTimeUtils::GetPrecisionTime();
	m_bFrameActive = false;
	WriteFrame( nFrameEndTime );
}

void CAIProfiler::Shutdown()
{
	m_bFrameActive = false;
	CloseOutput();
	m_bOpenFailed = false;
	m_nFrameIndex = 0;
	m_nPreviousFrameStartTime = 0;
	m_szOutputFile[0] = '\0';
}

bool CAIProfiler::BeginScope( EnumAIProfileScope eScope, TLTPrecisionTime& nStartTime )
{
	if( !m_bFrameActive || ( eScope < 0 ) || ( eScope >= kAIProfileScope_Count ) )
	{
		return false;
	}

	nStartTime = LTTimeUtils::GetPrecisionTime();
	return true;
}

void CAIProfiler::EndScope( EnumAIProfileScope eScope, TLTPrecisionTime nStartTime )
{
	if( !m_bFrameActive || ( eScope < 0 ) || ( eScope >= kAIProfileScope_Count ) )
	{
		return;
	}

	const TLTPrecisionTime nEndTime = LTTimeUtils::GetPrecisionTime();
	if( nEndTime >= nStartTime )
	{
		m_afScopeTimeMS[eScope] += LTTimeUtils::GetPrecisionTimeIntervalMS( nStartTime, nEndTime );
	}
	++m_anScopeCount[eScope];
}

bool CAIProfiler::RefreshOutput()
{
	if( !InitializeProfileVariables() )
	{
		return false;
	}

	if( s_AIProfileEnabled.GetFloat() <= 0.0f )
	{
		if( m_pOutput )
		{
			CloseOutput();
		}

		m_bOpenFailed = false;
		m_nFrameIndex = 0;
		m_nPreviousFrameStartTime = 0;
		m_szOutputFile[0] = '\0';
		return false;
	}

	const char* pszRequestedFileValue = s_AIProfileFile.GetStr( kpszDefaultProfileFile );
	if( LTStrEmpty( pszRequestedFileValue ) )
	{
		pszRequestedFileValue = kpszDefaultProfileFile;
	}

	char szRequestedFile[LTARRAYSIZE( m_szOutputFile )];
	LTStrCpy( szRequestedFile, pszRequestedFileValue, LTARRAYSIZE( szRequestedFile ) );

	if( LTStrCmp( m_szOutputFile, szRequestedFile ) != 0 )
	{
		CloseOutput();
		m_bOpenFailed = false;
		m_nFrameIndex = 0;
		m_nPreviousFrameStartTime = 0;
		LTStrCpy( m_szOutputFile, szRequestedFile, LTARRAYSIZE( m_szOutputFile ) );
	}

	if( m_pOutput )
	{
		return true;
	}

	if( m_bOpenFailed )
	{
		return false;
	}

	return OpenOutput();
}

bool CAIProfiler::OpenOutput()
{
	m_pOutput = g_pLTBase->FileMgr()->OpenUserFileForWriting( m_szOutputFile );
	if( !m_pOutput )
	{
		ReportOutputError( "open" );
		return false;
	}

	static const char szHeader[] =
		"frame_index,real_time_s,sim_time_s,frame_delta_ms,engine_frame_dt_ms,server_frame_ms,"
		"ai_update_count,ai_update_ms,ai_mgr_count,ai_mgr_ms,sensor_count,sensor_ms,"
		"goal_selection_count,goal_selection_ms,navigation_count,navigation_ms\r\n";

	if( m_pOutput->Write( szHeader, LTStrLen( szHeader ) ) != LT_OK )
	{
		ReportOutputError( "write header to" );
		return false;
	}

	g_pLTServer->CPrint( "AI profiler: writing UserDirectory/%s", m_szOutputFile );
	return true;
}

void CAIProfiler::CloseOutput()
{
	if( m_pOutput )
	{
		m_pOutput->Release();
		m_pOutput = NULL;
	}
}

void CAIProfiler::ResetFrame()
{
	for( uint32 iScope = 0; iScope < kAIProfileScope_Count; ++iScope )
	{
		m_afScopeTimeMS[iScope] = 0.0;
		m_anScopeCount[iScope] = 0;
	}
}

void CAIProfiler::WriteFrame( TLTPrecisionTime nFrameEndTime )
{
	if( !m_pOutput )
	{
		return;
	}

	const double fServerFrameTimeMS = ( nFrameEndTime >= m_nFrameStartTime )
		? LTTimeUtils::GetPrecisionTimeIntervalMS( m_nFrameStartTime, nFrameEndTime )
		: 0.0;

	char szLine[1024];
	LTSNPrintF( szLine, LTARRAYSIZE( szLine ),
		"%u,%.6f,%.6f,%.6f,%.6f,%.6f,%u,%.6f,%u,%.6f,%u,%.6f,%u,%.6f,%u,%.6f\r\n",
		m_nFrameIndex,
		g_pLTServer->GetRealTime(),
		g_pLTServer->GetTime(),
		m_fFrameDeltaMS,
		g_pLTServer->GetFrameTime() * 1000.0,
		fServerFrameTimeMS,
		m_anScopeCount[kAIProfileScope_AIUpdate],
		m_afScopeTimeMS[kAIProfileScope_AIUpdate],
		m_anScopeCount[kAIProfileScope_AIMgr],
		m_afScopeTimeMS[kAIProfileScope_AIMgr],
		m_anScopeCount[kAIProfileScope_Sensors],
		m_afScopeTimeMS[kAIProfileScope_Sensors],
		m_anScopeCount[kAIProfileScope_GoalSelection],
		m_afScopeTimeMS[kAIProfileScope_GoalSelection],
		m_anScopeCount[kAIProfileScope_Navigation],
		m_afScopeTimeMS[kAIProfileScope_Navigation] );

	if( m_pOutput->Write( szLine, LTStrLen( szLine ) ) != LT_OK )
	{
		ReportOutputError( "write to" );
		return;
	}

	++m_nFrameIndex;
}

void CAIProfiler::ReportOutputError( const char* pszOperation )
{
	g_pLTServer->CPrint( "AI profiler: unable to %s UserDirectory/%s; disable AIProfileEnabled or choose another AIProfileFile.",
		pszOperation, m_szOutputFile );
	CloseOutput();
	m_bOpenFailed = true;
}

CAIProfileScope::CAIProfileScope( EnumAIProfileScope eScope )
	: m_eScope( eScope ),
	  m_nStartTime( 0 ),
	  m_bActive( false )
{
	m_bActive = CAIProfiler::Instance().BeginScope( m_eScope, m_nStartTime );
}

CAIProfileScope::~CAIProfileScope()
{
	if( m_bActive )
	{
		CAIProfiler::Instance().EndScope( m_eScope, m_nStartTime );
	}
}
