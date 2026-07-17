// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreCorpsePersistence.h
//
// PURPOSE : Shared client ownership for the bounded corpse-budget setting.
//
// ----------------------------------------------------------------------- //

#ifndef __FEARMORE_CORPSE_PERSISTENCE_H__
#define __FEARMORE_CORPSE_PERSISTENCE_H__

namespace FearMoreCorpsePersistence
{
	// Off deliberately leaves F.E.A.R.'s performance-derived BodyCap values
	// untouched.  On substitutes these bounded values in the existing
	// single-player performance-settings message.
	static char const* const kSettingName = "FearMoreCorpsePersistence";
	static uint32 const kBodyCapRadius = 4096u;
	static uint8 const kBodyCapRadiusCount = 24u;
	static uint8 const kBodyCapTotalCount = 48u;
}

#endif // __FEARMORE_CORPSE_PERSISTENCE_H__
