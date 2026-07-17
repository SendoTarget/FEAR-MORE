// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreCorpsePersistence.h
//
// PURPOSE : Shared client ownership for bounded level-session persistence.
//
// ----------------------------------------------------------------------- //

#ifndef __FEARMORE_CORPSE_PERSISTENCE_H__
#define __FEARMORE_CORPSE_PERSISTENCE_H__

namespace FearMoreCorpsePersistence
{
	// The legacy setting name is retained so existing FearMore profiles keep
	// their choice as the option expands from corpses to bounded world effects.
	static char const* const kSettingName = "FearMoreCorpsePersistence";

	// Off deliberately leaves F.E.A.R.'s authored lifetimes and
	// performance-derived BodyCap values untouched.
	static uint32 const kBodyCapRadius = 4096u;
	static uint8 const kBodyCapRadiusCount = 24u;
	static uint8 const kBodyCapTotalCount = 48u;

	// Client-only level-session budgets.  Existing lower per-model, regional,
	// and SFX-list limits remain authoritative where they already exist.
	static uint32 const kPersistentDecalBudget = 512u;
	static uint32 const kPersistentDebrisBudget = 256u;
	static uint32 const kPersistentModelDecalBudget = 256u;
	static uint32 const kPersistentShellCasingBudget = 200u;
	static uint32 const kPersistentShatterGroupBudget = 16u;

	bool IsEnabled();
}

#endif // __FEARMORE_CORPSE_PERSISTENCE_H__
