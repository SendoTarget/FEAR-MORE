function(fear_find_engine_sdk_input out_var input_name)
	foreach(input_root IN ITEMS
		"${FEAR_LEGACY_SOURCE_ROOT}/engine/sdk/inc"
		"${FEAR_LEGACY_SOURCE_ROOT}/libs/platform")
		if(input_root AND EXISTS "${input_root}/${input_name}")
			set(${out_var} "${input_root}/${input_name}" PARENT_SCOPE)
			return()
		endif()
	endforeach()

	set(${out_var} "" PARENT_SCOPE)
endfunction()

function(fear_sources_from_vcproj out_var project_file)
	get_filename_component(project_file "${project_file}" ABSOLUTE)
	get_filename_component(project_dir "${project_file}" DIRECTORY)

	if(NOT EXISTS "${project_file}")
		message(FATAL_ERROR "Legacy Visual Studio project not found: ${project_file}")
	endif()

	file(STRINGS "${project_file}" project_lines REGEX "RelativePath=\"")
	set(project_sources)
	set(missing_sources)

	foreach(project_line IN LISTS project_lines)
		string(REGEX MATCH "RelativePath=\"([^\"]+)\"" relative_match "${project_line}")
		if(NOT relative_match)
			continue()
		endif()

		set(relative_path "${CMAKE_MATCH_1}")
		string(REPLACE "\\" "/" relative_path "${relative_path}")

		if(relative_path MATCHES "^\\.\\./\\.\\./Engine/")
			string(REGEX REPLACE "^\\.\\./\\.\\./Engine/" "" engine_relative_path "${relative_path}")
			if(FEAR_LEGACY_SOURCE_ROOT)
				set(source_path "${FEAR_LEGACY_SOURCE_ROOT}/engine/${engine_relative_path}")
			else()
				set(source_path "${CMAKE_SOURCE_DIR}/${engine_relative_path}")
			endif()
		else()
			get_filename_component(source_path "${project_dir}/${relative_path}" ABSOLUTE)
		endif()

		if(NOT source_path MATCHES "\\.(c|cc|cpp|cxx|rc)$")
			continue()
		endif()

		if(EXISTS "${source_path}")
			list(APPEND project_sources "${source_path}")
		else()
			list(APPEND missing_sources "${source_path}")
		endif()
	endforeach()

	list(REMOVE_DUPLICATES project_sources)
	list(REMOVE_DUPLICATES missing_sources)
	set(${out_var} "${project_sources}" PARENT_SCOPE)
	set(${out_var}_MISSING "${missing_sources}" PARENT_SCOPE)
endfunction()

function(fear_report_missing_sources target_name)
	if(ARGN)
		list(JOIN ARGN "\n  " missing_sources_text)
		message(FATAL_ERROR
			"${target_name}: the authoritative legacy project manifest has "
			"missing sources:\n  ${missing_sources_text}")
	endif()
endfunction()

function(fear_configure_game_target target_name build_definition)
	target_compile_definitions(${target_name} PRIVATE
		WIN32
		_WINDOWS
		_CRT_SECURE_NO_WARNINGS
		${build_definition}
		$<$<CONFIG:Debug>:_DEBUG>
		$<$<NOT:$<CONFIG:Debug>>:_FINAL>
		$<$<NOT:$<CONFIG:Debug>>:NDEBUG>
	)

	target_include_directories(${target_name} PRIVATE
		"${CMAKE_SOURCE_DIR}/cmake"
		"${CMAKE_SOURCE_DIR}/sdk/inc"
		"${CMAKE_SOURCE_DIR}/sdk/inc/compat"
		"${CMAKE_SOURCE_DIR}/libs"
		"${CMAKE_SOURCE_DIR}/libs/platform"
		"${CMAKE_SOURCE_DIR}/libs/stdlith"
		"${CMAKE_SOURCE_DIR}/FEAR/Shared"
		"${CMAKE_SOURCE_DIR}/FEAR/Libs/LTGUIMgr"
	)

	if(FEAR_LEGACY_SOURCE_ROOT)
		# The merged source tree also carries an older generic LithTech SDK.  A
		# configured F.E.A.R. SDK must win consistently so headers are never mixed.
		target_include_directories(${target_name} BEFORE PRIVATE
			"${FEAR_LEGACY_SOURCE_ROOT}/engine/sdk/inc"
			"${FEAR_LEGACY_SOURCE_ROOT}/engine/sdk/inc/compat"
			"${FEAR_LEGACY_SOURCE_ROOT}/libs/platform"
			"${FEAR_LEGACY_SOURCE_ROOT}/libs/stdlith"
		)
	endif()

	# A few legacy translation units use <stdafx.h>.  Add the owning module
	# last with BEFORE so it stays ahead of every SDK/library include root and
	# cannot bind to a dependency's unrelated precompiled-header file.
	target_include_directories(${target_name} BEFORE PRIVATE
		"${CMAKE_CURRENT_SOURCE_DIR}")

	if(MSVC)
		target_compile_options(${target_name} PRIVATE
			/MP
			"$<$<CONFIG:Debug>:/MDd>"
			"$<$<NOT:$<CONFIG:Debug>>:/MD>"
			/permissive
			/Zc:forScope-
			/Zc:wchar_t-
			"/FI${CMAKE_SOURCE_DIR}/cmake/FearLegacyCompilerCompat.h")

		# The official v1.08 Debug Shared_Assert and Shared_CRC archives predate
		# SafeSEH metadata.  Keep Release's modern linker default, but match the
		# legacy Debug ABI so the original SDK libraries can be linked.
		target_link_options(${target_name} PRIVATE
			"$<$<CONFIG:Debug>:/SAFESEH:NO>")

		get_target_property(target_type ${target_name} TYPE)
		if(target_type STREQUAL "SHARED_LIBRARY"
				OR target_type STREQUAL "MODULE_LIBRARY"
				OR target_type STREQUAL "EXECUTABLE")
			target_sources(${target_name} PRIVATE
				"${CMAKE_SOURCE_DIR}/cmake/FearLegacyCrtCompat.cpp")
			target_link_libraries(${target_name} PRIVATE
				"$<$<CONFIG:Debug>:legacy_stdio_definitions>")
		endif()
	endif()

	set_target_properties(${target_name} PROPERTIES
		RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
		LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin"
		ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib"
	)
endfunction()

function(fear_link_engine_library target_name library_name override_path)
	if(override_path)
		if(EXISTS "${override_path}")
			target_link_libraries(${target_name} PRIVATE "${override_path}")
		else()
			message(FATAL_ERROR "${target_name}: ${library_name} override is unavailable: ${override_path}")
		endif()
		return()
	endif()

	if(NOT FEAR_LEGACY_SOURCE_ROOT)
		message(FATAL_ERROR "${target_name}: ${library_name} is unavailable; set FEAR_LEGACY_SOURCE_ROOT to an official F.E.A.R. Public Tools Source directory or provide an explicit override.")
	endif()

	set(library_root "${FEAR_LEGACY_SOURCE_ROOT}/engine/sdk/lib/win")
	set(config_mappings
		"Debug|Debug"
		"Release|Final"
		"RelWithDebInfo|Release"
		"MinSizeRel|Release")

	foreach(config_mapping IN LISTS config_mappings)
		string(REPLACE "|" ";" config_parts "${config_mapping}")
		list(GET config_parts 0 cmake_config)
		list(GET config_parts 1 legacy_config)
		set(library_path "${library_root}/${legacy_config}/${library_name}.lib")

		if(EXISTS "${library_path}")
			target_link_libraries(${target_name} PRIVATE
				"$<$<CONFIG:${cmake_config}>:${library_path}>")
		else()
			message(FATAL_ERROR "${target_name}: ${library_name} for ${cmake_config} is unavailable: ${library_path}")
		endif()
	endforeach()
endfunction()
