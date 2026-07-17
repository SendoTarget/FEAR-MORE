// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreCorpsePersistence.cpp
//
// PURPOSE : Runtime query for bounded level-session persistence.
//
// ----------------------------------------------------------------------- //

#include "stdafx.h"
#include "FearMoreCorpsePersistence.h"

namespace FearMoreCorpsePersistence
{
	bool IsEnabled()
	{
		return (GetConsoleInt(kSettingName, 0) == 1);
	}
}
