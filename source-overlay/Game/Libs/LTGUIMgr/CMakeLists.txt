fear_sources_from_vcproj(FEAR_GUI_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/Game_GUIMgr.vcproj")
fear_report_missing_sources(FearGui ${FEAR_GUI_SOURCES_MISSING})

add_library(FearGui STATIC ${FEAR_GUI_SOURCES})
fear_configure_game_target(FearGui _CLIENTBUILD)
target_include_directories(FearGui PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}")
