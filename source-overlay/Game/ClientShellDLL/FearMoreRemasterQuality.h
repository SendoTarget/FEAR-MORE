// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreRemasterQuality.h
//
// PURPOSE : Focused DB-backed remaster-quality preset
//
// ----------------------------------------------------------------------- //

#ifndef __FEARMOREREMASTERQUALITY_H__
#define __FEARMOREREMASTERQUALITY_H__

namespace FearMoreRemasterQuality
{
	const char* GetHelpId();
	const wchar_t* GetLabel();
	const wchar_t* GetHelpText(const char* pszHelpId);

	// Resolves every required retail record before queueing Maximum.  Returns
	// false without changing the queue when any record is absent or incompatible.
	bool QueueMaximumPreset();
}

#endif // __FEARMOREREMASTERQUALITY_H__
