// ----------------------------------------------------------------------- //
//
// MODULE  : FearMoreRemasterQuality.cpp
//
// PURPOSE : Focused DB-backed remaster-quality preset
//
// ----------------------------------------------------------------------- //

#include "stdafx.h"
#include "FearMoreRemasterQuality.h"
#include "PerformanceDB.h"
#include "PerformanceMgr.h"

namespace
{
	const char* const kHelpId = "FearMoreRemasterQuality_Help";
	const wchar_t* const kLabel = L"Apply remaster quality";
	const wchar_t* const kHelpText =
		L"Queues Maximum for six proven retail option records: anisotropic and trilinear filtering, soft shadows, texture resolution, world detail, render targets, and light LOD. Other settings stay unchanged; leave this screen to apply and save.";

	const char* const kTextureFilteringVariables[] =
	{
		"Trilinear",
		"Anisotropic",
	};

	const char* const kSoftShadowsVariables[] =
	{
		"Light_ShadowBlur",
	};

	const char* const kTextureResolutionVariables[] =
	{
		"TextureGroupOffsetD",
		"TextureGroupOffsetN",
		"TextureGroupOffsetS",
		"TextureGroupOffsetE",
	};

	const char* const kWorldDetailVariables[] =
	{
		"WorldDetail",
	};

	const char* const kRenderTargetsVariables[] =
	{
		"RenderTargetLOD",
	};

	const char* const kLightsVariables[] =
	{
		"LODLights",
	};

	struct SOptionSpec
	{
		const char* m_pszRecordName;
		const char* const* m_ppszVariables;
		uint32 m_nVariableCount;
	};

	const SOptionSpec kOptions[] =
	{
		{ "TextureFiltering", kTextureFilteringVariables, LTARRAYSIZE(kTextureFilteringVariables) },
		{ "SoftShadows", kSoftShadowsVariables, LTARRAYSIZE(kSoftShadowsVariables) },
		{ "TextureResolution", kTextureResolutionVariables, LTARRAYSIZE(kTextureResolutionVariables) },
		{ "WorldDetail", kWorldDetailVariables, LTARRAYSIZE(kWorldDetailVariables) },
		{ "RenderTargets", kRenderTargetsVariables, LTARRAYSIZE(kRenderTargetsVariables) },
		{ "Lights", kLightsVariables, LTARRAYSIZE(kLightsVariables) },
	};

	struct SResolvedOption
	{
		uint32 m_nType;
		uint32 m_nGroup;
		uint32 m_nOption;
		bool m_bResolved;
	};

	bool IsCompatibleOption(HRECORD hOptionRecord, const SOptionSpec& spec)
	{
		HATTRIBUTE hDetailNames = g_pLTDatabase->GetAttribute(hOptionRecord, "DetailNames");
		if (!hDetailNames || g_pLTDatabase->GetNumValues(hDetailNames) == 0)
			return false;

		HATTRIBUTE hVariables = DATABASE_CATEGORY( PerformanceOption ).GetVariables(hOptionRecord);
		if (!hVariables)
			return false;

		const uint32 nVariableCount = g_pLTDatabase->GetNumValues(hVariables);
		if (nVariableCount != spec.m_nVariableCount)
			return false;

		for (uint32 nVariable = 0; nVariable < nVariableCount; ++nVariable)
		{
			const char* pszVariable = DATABASE_CATEGORY( PerformanceOption ).GETSTRUCTATTRIB(
				Variables, hVariables, nVariable, Variable );
			if (!pszVariable || !pszVariable[0])
				return false;

			HATTRIBUTE hDetailValues = CGameDatabaseReader::GetStructAttribute(
				hVariables, nVariable, "DetailValues" );
			if (!hDetailValues || g_pLTDatabase->GetNumValues(hDetailValues) == 0)
				return false;
		}

		for (uint32 nExpectedVariable = 0; nExpectedVariable < spec.m_nVariableCount; ++nExpectedVariable)
		{
			uint32 nMatches = 0;
			for (uint32 nVariable = 0; nVariable < nVariableCount; ++nVariable)
			{
				const char* pszVariable = DATABASE_CATEGORY( PerformanceOption ).GETSTRUCTATTRIB(
					Variables, hVariables, nVariable, Variable );
				if (LTStrIEquals(pszVariable, spec.m_ppszVariables[nExpectedVariable]))
					++nMatches;
			}

			if (nMatches != 1)
				return false;
		}

		return true;
	}

	bool ResolveOptions(SResolvedOption* pResolvedOptions, uint32 nResolvedOptionCount)
	{
		if (!pResolvedOptions || nResolvedOptionCount != LTARRAYSIZE(kOptions))
			return false;

		for (uint32 nTarget = 0; nTarget < nResolvedOptionCount; ++nTarget)
		{
			pResolvedOptions[nTarget].m_nType = 0;
			pResolvedOptions[nTarget].m_nGroup = 0;
			pResolvedOptions[nTarget].m_nOption = 0;
			pResolvedOptions[nTarget].m_bResolved = false;
		}

		CPerformanceMgr& performanceMgr = CPerformanceMgr::Instance();
		for (uint32 nType = 0; nType < kNumPerformanceTypes; ++nType)
		{
			for (uint32 nGroup = 0; nGroup < performanceMgr.GetNumGroups(nType); ++nGroup)
			{
				for (uint32 nOption = 0; nOption < performanceMgr.GetNumOptions(nType, nGroup); ++nOption)
				{
					HRECORD hOptionRecord = performanceMgr.GetOptionRecord(nType, nGroup, nOption);
					if (!hOptionRecord)
						continue;

					const char* pszRecordName = g_pLTDatabase->GetRecordName(hOptionRecord);
					if (!pszRecordName || !pszRecordName[0])
						continue;

					for (uint32 nTarget = 0; nTarget < nResolvedOptionCount; ++nTarget)
					{
						if (!LTStrIEquals(pszRecordName, kOptions[nTarget].m_pszRecordName))
							continue;

						if (pResolvedOptions[nTarget].m_bResolved ||
							!IsCompatibleOption(hOptionRecord, kOptions[nTarget]))
						{
							return false;
						}

						pResolvedOptions[nTarget].m_nType = nType;
						pResolvedOptions[nTarget].m_nGroup = nGroup;
						pResolvedOptions[nTarget].m_nOption = nOption;
						pResolvedOptions[nTarget].m_bResolved = true;
					}
				}
			}
		}

		for (uint32 nTarget = 0; nTarget < nResolvedOptionCount; ++nTarget)
		{
			if (!pResolvedOptions[nTarget].m_bResolved)
				return false;
		}

		return true;
	}
}

namespace FearMoreRemasterQuality
{
	const char* GetHelpId()
	{
		return kHelpId;
	}

	const wchar_t* GetLabel()
	{
		return kLabel;
	}

	const wchar_t* GetHelpText(const char* pszHelpId)
	{
		if (!pszHelpId)
			return NULL;

		return LTStrIEquals(pszHelpId, kHelpId) ? kHelpText : NULL;
	}

	bool QueueMaximumPreset()
	{
		SResolvedOption aResolvedOptions[LTARRAYSIZE(kOptions)];
		if (!ResolveOptions(aResolvedOptions, LTARRAYSIZE(aResolvedOptions)))
			return false;

		// Maximum is detail index zero for every retail Performance option.  Keep
		// the existing manager path so each record's activation flags are retained.
		CPerformanceMgr& performanceMgr = CPerformanceMgr::Instance();
		for (uint32 nTarget = 0; nTarget < LTARRAYSIZE(aResolvedOptions); ++nTarget)
		{
			performanceMgr.SetOptionLevel(
				aResolvedOptions[nTarget].m_nType,
				aResolvedOptions[nTarget].m_nGroup,
				aResolvedOptions[nTarget].m_nOption,
				0 );
		}

		return true;
	}
}
