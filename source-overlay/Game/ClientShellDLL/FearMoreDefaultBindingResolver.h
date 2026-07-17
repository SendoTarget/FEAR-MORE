// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreDefaultBindingResolver.h
//
// PURPOSE : Locale-safe resolution for stock default keyboard bindings
//
// ----------------------------------------------------------------------- //

#ifndef __FEARMOREDEFAULTBINDINGRESOLVER_H__
#define __FEARMOREDEFAULTBINDINGRESOLVER_H__

class ILTInput;

namespace FearMoreDefaultBindingResolver
{
	// Resolves a stock English keyboard-object name through its stable
	// DirectInput control code.  Callers must keep this fallback scoped to the
	// stock Defaults.Gamdb00p path so existing user bindings remain untouched.
	bool ResolveKeyboardObject( ILTInput* pInput, const wchar_t* pDefaultObjectName,
		uint32* pDeviceIndex, uint32* pObjectIndex );
}

#endif // __FEARMOREDEFAULTBINDINGRESOLVER_H__
