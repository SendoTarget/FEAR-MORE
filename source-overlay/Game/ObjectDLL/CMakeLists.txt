fear_sources_from_vcproj(FEAR_SERVER_SOURCES
	"${CMAKE_CURRENT_SOURCE_DIR}/Game_ServerShell.vcproj")
fear_report_missing_sources(GameServer ${FEAR_SERVER_SOURCES_MISSING})

add_library(GameServer SHARED ${FEAR_SERVER_SOURCES})
fear_configure_game_target(GameServer _SERVERBUILD)
target_compile_definitions(GameServer PRIVATE MEMTRACK_SERVER)
target_include_directories(GameServer PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(GameServer PRIVATE FearSharedServer FearStdLith winmm)
fear_link_engine_library(GameServer Shared_Assert "${FEAR_SHARED_ASSERT_LIBRARY}")
fear_link_engine_library(GameServer Shared_CRC "${FEAR_SHARED_CRC_LIBRARY}")

set_target_properties(GameServer PROPERTIES
	PREFIX ""
	OUTPUT_NAME "GameServer"
)
