// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreGraphicsSettings.h
//
// PURPOSE : Source-owned modern display option descriptors
//
// ----------------------------------------------------------------------- //

#ifndef __FEARMOREGRAPHICSSETTINGS_H__
#define __FEARMOREGRAPHICSSETTINGS_H__

#include "ltbasedefs.h"

namespace FearMoreGraphicsSettings
{
	enum EOption
	{
		eOption_RendererQuality,
		eOption_EffectsTargetQuality,
		eOption_PostProcess,
		eOption_HUDPlacement,
	};

	enum ERendererQuality
	{
		eRendererQuality_Native = 0,
		eRendererQuality_2xDownsample = 1,
	};

	enum EEffectsTargetQuality
	{
		eEffectsTargetQuality_Native = 0,
		eEffectsTargetQuality_High = 1,
	};

	enum EPostProcess
	{
		ePostProcess_Off = 0,
		ePostProcess_CAS = 1,
	};

	enum EHUDPlacement
	{
		eHUDPlacement_CenteredSafeArea = 0,
		eHUDPlacement_FullWidth = 1,
	};

	struct SOptionDescriptor
	{
		const char*		m_pszConsoleVariable;
		const char*		m_pszHelpId;
		const wchar_t*	m_pwszLabel;
		int				m_nDefaultValue;
		int				m_nMinimumValue;
		int				m_nMaximumValue;
	};

	const SOptionDescriptor& GetOptionDescriptor(EOption eOption);
	int ClampOptionValue(EOption eOption, int nValue);
	int GetRendererDownsampleScale(int nRendererQuality);
	void CaptureRestartBoundSettings();
	int GetActiveEffectsTargetQuality();
	bool GetEffectsTargetDimensions(int nEffectsTargetQuality,
		uint32 nNativeWidth, uint32 nNativeHeight,
		uint32& nTargetWidth, uint32& nTargetHeight);
	const wchar_t* GetOptionValueLabel(EOption eOption, int nValue);
	const wchar_t* GetHelpText(const char* pszHelpId);
}

#endif // __FEARMOREGRAPHICSSETTINGS_H__
