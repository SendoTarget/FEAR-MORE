fear_sources_from_vcproj(FEAR_SHARED_CLIENT_SOURCES
	"${CMAKE_CURRENT_SOURCE_DIR}/Game_Shared_Client.vcproj")
fear_sources_from_vcproj(FEAR_SHARED_SERVER_SOURCES
	"${CMAKE_CURRENT_SOURCE_DIR}/Game_Shared_Server.vcproj")

fear_report_missing_sources(FearSharedClient ${FEAR_SHARED_CLIENT_SOURCES_MISSING})
fear_report_missing_sources(FearSharedServer ${FEAR_SHARED_SERVER_SOURCES_MISSING})

add_library(FearSharedClient STATIC ${FEAR_SHARED_CLIENT_SOURCES})
fear_configure_game_target(FearSharedClient _CLIENTBUILD)
target_include_directories(FearSharedClient PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(FearSharedClient PUBLIC FearPlatform)

add_library(FearSharedServer STATIC ${FEAR_SHARED_SERVER_SOURCES})
fear_configure_game_target(FearSharedServer _SERVERBUILD)
target_include_directories(FearSharedServer PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(FearSharedServer PUBLIC FearPlatform)
