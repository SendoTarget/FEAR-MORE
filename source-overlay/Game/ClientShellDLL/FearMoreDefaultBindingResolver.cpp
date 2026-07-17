// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreDefaultBindingResolver.cpp
//
// PURPOSE : Locale-safe resolution for stock default keyboard bindings
//
// ----------------------------------------------------------------------- //

#include "stdafx.h"
#include "FearMoreDefaultBindingResolver.h"
#include "iltinput.h"
#include "dinput.h"

namespace
{
	struct SDefaultKeyboardObject
	{
		const wchar_t* m_pObjectName;
		uint32 m_nControlCode;
	};

	// These are the non-alphanumeric names used by the retail default profile
	// that DirectInput localizes on some Windows installations.  Letter, number,
	// and mouse names continue through the original exact-name path.
	const SDefaultKeyboardObject kDefaultKeyboardObjects[] =
	{
		{ L"Space", DIK_SPACE },
		{ L"Up Arrow", DIK_UPARROW },
		{ L"Up", DIK_UPARROW },
		{ L"Down Arrow", DIK_DOWNARROW },
		{ L"Down", DIK_DOWNARROW },
		{ L"Tab", DIK_TAB },
		{ L"Right Ctrl", DIK_RCONTROL },
		{ L"Left Arrow", DIK_LEFTARROW },
		{ L"Left", DIK_LEFTARROW },
		{ L"Right Arrow", DIK_RIGHTARROW },
		{ L"Right", DIK_RIGHTARROW },
		{ L"Left Shift", DIK_LSHIFT },
		// Some retail default databases label the same left-shift control without
		// the side qualifier.
		{ L"Shift", DIK_LSHIFT },
	};

	bool GetDefaultControlCode( const wchar_t* pObjectName, uint32& nControlCode )
	{
		if( !pObjectName || !pObjectName[0] )
			return false;

		for( uint32 nObject = 0; nObject < LTARRAYSIZE(kDefaultKeyboardObjects); ++nObject )
		{
			if( LTStrIEquals(pObjectName, kDefaultKeyboardObjects[nObject].m_pObjectName) )
			{
				nControlCode = kDefaultKeyboardObjects[nObject].m_nControlCode;
				return true;
			}
		}

		return false;
	}
}

bool FearMoreDefaultBindingResolver::ResolveKeyboardObject( ILTInput* pInput,
	const wchar_t* pDefaultObjectName, uint32* pDeviceIndex, uint32* pObjectIndex )
{
	if( !pInput || !pDeviceIndex || !pObjectIndex )
		return false;

	uint32 nControlCode = 0;
	if( !GetDefaultControlCode(pDefaultObjectName, nControlCode) )
		return false;

	uint32 nKeyboardDevice = ILTInput::k_InvalidIndex;
	if( pInput->FindFirstDeviceByCategory(ILTInput::eDC_Keyboard, &nKeyboardDevice) != LT_OK )
		return false;

	uint32 nFirstButton = ILTInput::k_InvalidIndex;
	if( pInput->FindFirstDeviceObjectByCategory(nKeyboardDevice, ILTInput::eDOC_Button, &nFirstButton) != LT_OK )
		return false;

	uint32 nButtonCount = 0;
	if( pInput->GetNumDeviceObjectsByCategory(nKeyboardDevice, ILTInput::eDOC_Button, &nButtonCount) != LT_OK )
		return false;

	for( uint32 nButton = 0; nButton < nButtonCount; ++nButton )
	{
		const uint32 nObjectIndex = nFirstButton + nButton;
		ILTInput::SDeviceObjectDesc sObject;
		if( pInput->GetDeviceObjectDesc(nKeyboardDevice, nObjectIndex, &sObject) != LT_OK )
			continue;

		if( sObject.m_nControlCode != nControlCode )
			continue;

		*pDeviceIndex = nKeyboardDevice;
		*pObjectIndex = nObjectIndex;
		return true;
	}

	return false;
}
