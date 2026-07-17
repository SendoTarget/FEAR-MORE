if(NOT FEAR_LEGACY_SOURCE_ROOT)
	add_library(FearPlatform INTERFACE)
	message(WARNING "FearPlatform: set FEAR_LEGACY_SOURCE_ROOT to an official F.E.A.R. Public Tools Source directory to build Shared_Platform.")
	return()
endif()

set(platform_project
	"${FEAR_LEGACY_SOURCE_ROOT}/libs/platform/Shared_Platform.vcproj")
fear_sources_from_vcproj(FEAR_PLATFORM_SOURCES "${platform_project}")
# Shared_Platform.vcproj keeps its Linux implementation files in the project
# but excludes them from every Win32 configuration.
list(FILTER FEAR_PLATFORM_SOURCES EXCLUDE REGEX "/sys/linux/")
fear_report_missing_sources(FearPlatform ${FEAR_PLATFORM_SOURCES_MISSING})

add_library(FearPlatform STATIC ${FEAR_PLATFORM_SOURCES})
fear_configure_game_target(FearPlatform "")
target_include_directories(FearPlatform BEFORE PRIVATE
	"${FEAR_LEGACY_SOURCE_ROOT}/libs/platform")
target_link_libraries(FearPlatform PUBLIC FearStdLith)
