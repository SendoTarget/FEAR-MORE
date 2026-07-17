cmake_minimum_required(VERSION 3.20)

project(FearMoreGameModules LANGUAGES C CXX RC)

if(NOT WIN32)
	message(FATAL_ERROR "FearMore's F.E.A.R. v1.08 game modules currently build on Windows only.")
endif()

if(CMAKE_SIZEOF_VOID_P EQUAL 8)
	message(FATAL_ERROR "F.E.A.R. v1.08 game modules must use a Win32 generator (-A Win32).")
endif()

add_compile_definitions(_SILENCE_STDEXT_HASH_DEPRECATION_WARNINGS)
add_subdirectory(FEAR)
