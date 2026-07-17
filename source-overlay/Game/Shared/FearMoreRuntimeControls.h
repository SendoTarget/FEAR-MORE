// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreRuntimeControls.h
//
// PURPOSE : Shared names for the local single-player runtime-control bridge.
//
// ----------------------------------------------------------------------- //

#ifndef __FEARMORERUNTIMECONTROLS_H__
#define __FEARMORERUNTIMECONTROLS_H__

namespace FearMoreRuntimeControls
{
	static char const* const kForwardCommand = "FearMoreSetSinglePlayerCVar";

	static char const* const kForwardedVariables[] =
	{
		"EnhancedGore",
		"EnhancedGoreMaxSeversPerBody",
		"BodySeverTest",
		"BodyGibTest",
		"AIProfileEnabled",
		"AIUpdateInterval",
	};
}

#endif // __FEARMORERUNTIMECONTROLS_H__
