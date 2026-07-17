// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreControllerMgr.h
//
// PURPOSE : Source-owned SDL3 gamepad input for rebuilt FearMore clients.
//
// ----------------------------------------------------------------------- //

#ifndef __FEARMORE_CONTROLLER_MGR_H__
#define __FEARMORE_CONTROLLER_MGR_H__

#include "ltbasetypes.h"

class CFearMoreControllerMgr
{
public:
	static CFearMoreControllerMgr& Instance();

	// SDL is loaded dynamically from the executable directory.  Initialization
	// failure deliberately leaves the original keyboard/mouse path untouched.
	void Initialize();
	void Shutdown();
	void Update();

	float GetCommandValue( uint32 nCommand ) const;
	bool IsCommandOn( uint32 nCommand ) const;
	uint32 GetHighestMappedCommand() const;

	bool IsRuntimeAvailable() const;
	bool IsGamepadConnected() const;
	bool IsInputActive() const;

	// Uses the existing authored ClientFX two-motor output.  Values are clamped
	// to SDL's low/high-frequency ranges and automatically expire if updates stop.
	void SetRumble( float fLowFrequency, float fHighFrequency );

private:
	CFearMoreControllerMgr();
	~CFearMoreControllerMgr();
	CFearMoreControllerMgr( CFearMoreControllerMgr const& );
	CFearMoreControllerMgr& operator=( CFearMoreControllerMgr const& );

	struct SImpl;
	SImpl* m_pImpl;
	uint32 m_nLastInitializeAttempt;
};

#endif // __FEARMORE_CONTROLLER_MGR_H__
