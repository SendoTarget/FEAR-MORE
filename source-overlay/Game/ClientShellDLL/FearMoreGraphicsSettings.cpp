// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreGraphicsSettings.cpp
//
// PURPOSE : Source-owned modern display option descriptors
//
// ----------------------------------------------------------------------- //

#include "stdafx.h"
#include "FearMoreGraphicsSettings.h"
#include "ClientUtilities.h"

#include <cstring>

namespace
{
	const FearMoreGraphicsSettings::SOptionDescriptor kRendererQuality =
	{
		"FearMoreRendererQuality",
		"FearMoreRendererQuality_Help",
		L"Renderer quality",
		FearMoreGraphicsSettings::eRendererQuality_Native,
		FearMoreGraphicsSettings::eRendererQuality_Native,
		FearMoreGraphicsSettings::eRendererQuality_2xDownsample,
	};

	const FearMoreGraphicsSettings::SOptionDescriptor kEffectsTargetQuality =
	{
		"FearMoreEffectsTargetQuality",
		"FearMoreEffectsTargetQuality_Help",
		L"Effects target quality",
		FearMoreGraphicsSettings::eEffectsTargetQuality_Native,
		FearMoreGraphicsSettings::eEffectsTargetQuality_Native,
		FearMoreGraphicsSettings::eEffectsTargetQuality_High,
	};

	const FearMoreGraphicsSettings::SOptionDescriptor kPostProcess =
	{
		"FearMorePostProcess",
		"FearMorePostProcess_Help",
		L"Post-processing",
		FearMoreGraphicsSettings::ePostProcess_Off,
		FearMoreGraphicsSettings::ePostProcess_Off,
		FearMoreGraphicsSettings::ePostProcess_CAS,
	};

	const FearMoreGraphicsSettings::SOptionDescriptor kHUDPlacement =
	{
		"HUDSafeAreaFullWidth",
		"FearMoreHUDPlacement_Help",
		L"HUD placement",
		FearMoreGraphicsSettings::eHUDPlacement_CenteredSafeArea,
		FearMoreGraphicsSettings::eHUDPlacement_CenteredSafeArea,
		FearMoreGraphicsSettings::eHUDPlacement_FullWidth,
	};

	bool s_bRestartBoundSettingsCaptured = false;
	int s_nActiveEffectsTargetQuality = FearMoreGraphicsSettings::eEffectsTargetQuality_Native;

	const uint32 kMinimumEffectsTargetDimension = 4;
	const uint32 kMaximumEffectsTargetDimension = 2048;

	bool IsPowerOfTwo(uint32 nValue)
	{
		return nValue && ((nValue & (nValue - 1)) == 0);
	}
}

namespace FearMoreGraphicsSettings
{
	const SOptionDescriptor& GetOptionDescriptor(EOption eOption)
	{
		switch (eOption)
		{
		case eOption_EffectsTargetQuality:
			return kEffectsTargetQuality;

		case eOption_PostProcess:
			return kPostProcess;

		case eOption_HUDPlacement:
			return kHUDPlacement;

		case eOption_RendererQuality:
		default:
			return kRendererQuality;
		}
	}

	int ClampOptionValue(EOption eOption, int nValue)
	{
		const SOptionDescriptor& descriptor = GetOptionDescriptor(eOption);
		if (nValue < descriptor.m_nMinimumValue)
			return descriptor.m_nMinimumValue;
		if (nValue > descriptor.m_nMaximumValue)
			return descriptor.m_nMaximumValue;
		return nValue;
	}

	int GetRendererDownsampleScale(int nRendererQuality)
	{
		return (ClampOptionValue(eOption_RendererQuality, nRendererQuality) ==
			eRendererQuality_2xDownsample) ? 2 : 1;
	}

	void CaptureRestartBoundSettings()
	{
		if (s_bRestartBoundSettingsCaptured)
			return;

		const SOptionDescriptor& descriptor = GetOptionDescriptor(eOption_EffectsTargetQuality);
		s_nActiveEffectsTargetQuality = ClampOptionValue(eOption_EffectsTargetQuality,
			GetConsoleInt(descriptor.m_pszConsoleVariable, descriptor.m_nDefaultValue));
		s_bRestartBoundSettingsCaptured = true;
	}

	int GetActiveEffectsTargetQuality()
	{
		return s_nActiveEffectsTargetQuality;
	}

	bool GetEffectsTargetDimensions(int nEffectsTargetQuality,
		uint32 nNativeWidth, uint32 nNativeHeight,
		uint32& nTargetWidth, uint32& nTargetHeight)
	{
		nTargetWidth = nNativeWidth;
		nTargetHeight = nNativeHeight;

		if (ClampOptionValue(eOption_EffectsTargetQuality, nEffectsTargetQuality) !=
			eEffectsTargetQuality_High)
		{
			return false;
		}

		if ((nNativeWidth < kMinimumEffectsTargetDimension) ||
			(nNativeHeight < kMinimumEffectsTargetDimension) ||
			!IsPowerOfTwo(nNativeWidth) || !IsPowerOfTwo(nNativeHeight) ||
			(nNativeWidth > (kMaximumEffectsTargetDimension / 2)) ||
			(nNativeHeight > (kMaximumEffectsTargetDimension / 2)))
		{
			return false;
		}

		nTargetWidth = nNativeWidth * 2;
		nTargetHeight = nNativeHeight * 2;
		return true;
	}

	const wchar_t* GetOptionValueLabel(EOption eOption, int nValue)
	{
		nValue = ClampOptionValue(eOption, nValue);
		if (eOption == eOption_HUDPlacement)
		{
			return (nValue == eHUDPlacement_FullWidth) ?
				L"Full width" : L"Centered 16:9";
		}

		if (eOption == eOption_EffectsTargetQuality)
		{
			return (nValue == eEffectsTargetQuality_High) ?
				L"High (next launch)" : L"Native";
		}

		if (eOption == eOption_PostProcess)
		{
			return (nValue == ePostProcess_CAS) ?
				L"CAS (next launch)" : L"Off";
		}

		return (nValue == eRendererQuality_2xDownsample) ?
			L"Max 2x (next launch)" : L"Native";
	}

	const wchar_t* GetHelpText(const char* pszHelpId)
	{
		if (!pszHelpId)
			return NULL;

		if (std::strcmp(pszHelpId, kRendererQuality.m_pszHelpId) == 0)
		{
			return L"Native leaves the app resolution unforced. Max 2x chooses dgVoodoo's largest desktop-based resolution with the app aspect ratio, then doubles each axis on the next launch.";
		}

		if (std::strcmp(pszHelpId, kEffectsTargetQuality.m_pszHelpId) == 0)
		{
			return L"High doubles the proven volumetric-light shadow depth target on the next launch. Authored mirror/reflection targets stay native to preserve their projection and sampling contract; unsupported shadow allocations fall back to native.";
		}

		if (std::strcmp(pszHelpId, kPostProcess.m_pszHelpId) == 0)
		{
			return L"Off leaves post-processing disabled. CAS saves Contrast Adaptive Sharpening for the next launch and does not change the running session.";
		}

		if (std::strcmp(pszHelpId, kHUDPlacement.m_pszHelpId) == 0)
		{
			return L"Centered 16:9 keeps important HUD elements within a readable ultrawide safe area. Full width restores the original edge placement. Changes apply immediately.";
		}

		return NULL;
	}
}
