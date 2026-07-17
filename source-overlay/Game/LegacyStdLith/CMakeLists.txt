if(NOT FEAR_LEGACY_SOURCE_ROOT)
	add_library(FearStdLith INTERFACE)
	message(WARNING "FearStdLith: set FEAR_LEGACY_SOURCE_ROOT to an official F.E.A.R. Public Tools Source directory to build Shared_StdLith.")
	return()
endif()

set(stdlith_project
	"${FEAR_LEGACY_SOURCE_ROOT}/libs/stdlith/Shared_StdLith.vcproj")
fear_sources_from_vcproj(FEAR_STDLITH_SOURCES "${stdlith_project}")
fear_report_missing_sources(FearStdLith ${FEAR_STDLITH_SOURCES_MISSING})

add_library(FearStdLith STATIC ${FEAR_STDLITH_SOURCES})
fear_configure_game_target(FearStdLith "")
target_include_directories(FearStdLith BEFORE PUBLIC
	"${FEAR_LEGACY_SOURCE_ROOT}/libs/stdlith")
