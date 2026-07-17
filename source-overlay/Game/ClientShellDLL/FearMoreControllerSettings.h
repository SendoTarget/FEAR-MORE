// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreControllerSettings.h
//
// PURPOSE : Shared source-owned controller setting identity and defaults.
//
// ----------------------------------------------------------------------- //

#ifndef __FEARMORE_CONTROLLER_SETTINGS_H__
#define __FEARMORE_CONTROLLER_SETTINGS_H__

namespace FearMoreControllerSettings
{
	static char const* const kEnabledCVar = "FearMoreControllerEnabled";
	static char const* const kDeadZoneCVar = "FearMoreControllerDeadZone";
	static char const* const kInvertYCVar = "FearMoreControllerInvertY";
	static char const* const kRumbleCVar = "FearMoreControllerRumble";
	static char const* const kSensitivityCVar = "GPadAimSensitivity";

	// Preserve stock/legacy controller input unless a launcher profile or the
	// in-game option explicitly opts into the SDL path.
	static bool const kEnabledDefault = false;
	static float const kDeadZoneDefault = 0.18f;
	static bool const kInvertYDefault = false;
	static bool const kRumbleDefault = false;
	static float const kSensitivityDefault = 2.0f;

	static float const kDeadZoneMinimum = 0.05f;
	static float const kDeadZoneMaximum = 0.40f;
	static float const kSensitivityMinimum = 0.5f;
	static float const kSensitivityMaximum = 5.0f;
}

#endif // __FEARMORE_CONTROLLER_SETTINGS_H__
