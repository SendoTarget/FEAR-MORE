// ----------------------------------------------------------------------- //
//
// MODULE  : AIProfiler.h
//
// PURPOSE : Opt-in, server-frame AI profiling
//
// ----------------------------------------------------------------------- //

#ifndef __AIPROFILER_H__
#define __AIPROFILER_H__

#include "ltbasetypes.h"
#include "lttimeutils.h"

class ILTOutStream;

enum EnumAIProfileScope
{
	kAIProfileScope_AIUpdate = 0,
	kAIProfileScope_AIMgr,
	kAIProfileScope_Sensors,
	kAIProfileScope_GoalSelection,
	kAIProfileScope_Navigation,

	kAIProfileScope_Count,
};

class CAIProfiler
{
public:
	static CAIProfiler& Instance();

	// The server shell brackets the engine's authoritative per-frame update
	// with these calls.  Object-level scopes contribute to the active frame.
	void BeginServerFrame();
	void EndServerFrame();
	void Shutdown();

	bool BeginScope( EnumAIProfileScope eScope, TLTPrecisionTime& nStartTime );
	void EndScope( EnumAIProfileScope eScope, TLTPrecisionTime nStartTime );

private:
	CAIProfiler();
	~CAIProfiler();

	CAIProfiler( const CAIProfiler& );
	CAIProfiler& operator=( const CAIProfiler& );

	bool RefreshOutput();
	bool OpenOutput();
	void CloseOutput();
	void ResetFrame();
	void WriteFrame( TLTPrecisionTime nFrameEndTime );
	void ReportOutputError( const char* pszOperation );

private:
	ILTOutStream*	m_pOutput;
	bool			m_bFrameActive;
	bool			m_bOpenFailed;
	uint32			m_nFrameIndex;
	TLTPrecisionTime	m_nFrameStartTime;
	TLTPrecisionTime	m_nPreviousFrameStartTime;
	double			m_fFrameDeltaMS;
	double			m_afScopeTimeMS[kAIProfileScope_Count];
	uint32			m_anScopeCount[kAIProfileScope_Count];
	char			m_szOutputFile[260];
};

class CAIProfileScope
{
public:
	explicit CAIProfileScope( EnumAIProfileScope eScope );
	~CAIProfileScope();

private:
	CAIProfileScope( const CAIProfileScope& );
	CAIProfileScope& operator=( const CAIProfileScope& );

private:
	EnumAIProfileScope	m_eScope;
	TLTPrecisionTime	m_nStartTime;
	bool				m_bActive;
};

#endif // __AIPROFILER_H__
