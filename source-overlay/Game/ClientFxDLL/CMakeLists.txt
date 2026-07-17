fear_sources_from_vcproj(FEAR_CLIENT_FX_SOURCES
	"${CMAKE_CURRENT_SOURCE_DIR}/Game_ClientFX.vcproj")
fear_report_missing_sources(ClientFx ${FEAR_CLIENT_FX_SOURCES_MISSING})

add_library(ClientFx SHARED ${FEAR_CLIENT_FX_SOURCES})
fear_configure_game_target(ClientFx _CLIENTBUILD)
target_compile_definitions(ClientFx PRIVATE MEMTRACK_CLIENTFX)
target_include_directories(ClientFx PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(ClientFx PRIVATE FearSharedClient FearStdLith)
fear_link_engine_library(ClientFx Shared_Assert "${FEAR_SHARED_ASSERT_LIBRARY}")

set_target_properties(ClientFx PROPERTIES
	PREFIX ""
	OUTPUT_NAME "ClientFx"
	SUFFIX ".fxd"
)
