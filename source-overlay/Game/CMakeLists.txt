include("${CMAKE_SOURCE_DIR}/cmake/FearLegacyProject.cmake")

set(FEAR_LEGACY_SOURCE_ROOT "" CACHE PATH
	"Official F.E.A.R. Public Tools Source directory containing engine and libs")
set(FEAR_SHARED_ASSERT_LIBRARY "" CACHE FILEPATH
	"Optional all-config override for a provenance-compatible Shared_Assert library")
set(FEAR_SHARED_CRC_LIBRARY "" CACHE FILEPATH
	"Optional all-config override for a provenance-compatible Shared_CRC library")

if(NOT FEAR_LEGACY_SOURCE_ROOT OR NOT IS_DIRECTORY "${FEAR_LEGACY_SOURCE_ROOT}")
	message(FATAL_ERROR
		"BUILD_FEAR requires FEAR_LEGACY_SOURCE_ROOT to point at the Source "
		"directory installed by F.E.A.R. Public Tools 1.08. The SDK is a "
		"local-only build input and is intentionally not stored in Git.")
endif()

set(required_sdk_inputs
	"engine/sdk/inc/engine.h"
	"engine/sdk/inc/platform.h"
	"engine/sdk/inc/IGameWorldPacker.h"
	"engine/sdk/inc/IGameSpy.h"
	"engine/sdk/inc/ltmemhook.cpp"
	"engine/sdk/inc/performancemonitorhook.cpp")

set(missing_sdk_inputs)
foreach(required_input IN LISTS required_sdk_inputs)
	if(NOT EXISTS "${FEAR_LEGACY_SOURCE_ROOT}/${required_input}")
		list(APPEND missing_sdk_inputs "${required_input}")
	endif()
endforeach()

if(missing_sdk_inputs)
	list(JOIN missing_sdk_inputs ", " missing_sdk_inputs_text)
	message(FATAL_ERROR
		"The configured F.E.A.R. Public Tools source is incomplete. Missing: "
		"${missing_sdk_inputs_text}")
endif()

add_subdirectory(LegacyStdLith)
add_subdirectory(LegacyPlatform)
add_subdirectory(Libs/LTGUIMgr)
add_subdirectory(Shared)
add_subdirectory(ClientFxDLL)
add_subdirectory(ClientShellDLL)
add_subdirectory(ObjectDLL)
