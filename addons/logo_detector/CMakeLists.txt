cmake_minimum_required(VERSION 3.22)
project(logo_detector LANGUAGES CXX)

# C++ standard
set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Default to Release if not specified
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# Disable godot-cpp hot reload for cleaner release binaries
set(GODOT_USE_HOT_RELOAD OFF CACHE BOOL "" FORCE)
set(GODOT_DISABLE_EXCEPTIONS OFF CACHE BOOL "" FORCE)
set(GODOT_PRECISION "single" CACHE STRING "" FORCE)

# godot-cpp location --------------------------------------------------------
# Default: the submodule at the repo root (kyodai/godot-cpp)
if(NOT GODOT_CPP_PATH)
    set(GODOT_CPP_PATH "${CMAKE_CURRENT_SOURCE_DIR}/../../godot-cpp")
endif()

get_filename_component(GODOT_CPP_PATH "${GODOT_CPP_PATH}" ABSOLUTE)

if(NOT EXISTS "${GODOT_CPP_PATH}/CMakeLists.txt")
    message(FATAL_ERROR "godot-cpp not found at ${GODOT_CPP_PATH}. "
        "Clone it as a submodule: git submodule update --init --recursive")
endif()

add_subdirectory(${GODOT_CPP_PATH} ${CMAKE_CURRENT_BINARY_DIR}/godot-cpp)

# ONNX Runtime location ------------------------------------------------------
# Default: thirdparty/onnxruntime inside this addon
if(NOT ONNXRUNTIME_ROOT)
    if(DEFINED ENV{ONNXRUNTIME_ROOT})
        set(ONNXRUNTIME_ROOT "$ENV{ONNXRUNTIME_ROOT}")
    else()
        set(ONNXRUNTIME_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty/onnxruntime")
    endif()
endif()

get_filename_component(ONNXRUNTIME_ROOT "${ONNXRUNTIME_ROOT}" ABSOLUTE)

if(NOT EXISTS "${ONNXRUNTIME_ROOT}/include/onnxruntime_c_api.h")
    message(FATAL_ERROR "ONNX Runtime not found at ${ONNXRUNTIME_ROOT}. "
        "Pass -DONNXRUNTIME_ROOT=/path/to/onnxruntime")
endif()

# Platform-specific library discovery
if(WIN32)
    set(ONNXRUNTIME_LIB "${ONNXRUNTIME_ROOT}/lib/onnxruntime.lib")
    set(ONNXRUNTIME_DLL "${ONNXRUNTIME_ROOT}/lib/onnxruntime.dll")
    set(ONNXRUNTIME_SHARED_DLL "${ONNXRUNTIME_ROOT}/lib/onnxruntime_providers_shared.dll")
elseif(ANDROID)
    set(ONNXRUNTIME_LIB "${ONNXRUNTIME_ROOT}/libonnxruntime.so")
elseif(APPLE)
    set(ONNXRUNTIME_LIB "${ONNXRUNTIME_ROOT}/lib/libonnxruntime.dylib")
else()
    set(ONNXRUNTIME_LIB "${ONNXRUNTIME_ROOT}/lib/libonnxruntime.so")
endif()

if(NOT EXISTS "${ONNXRUNTIME_LIB}")
    message(FATAL_ERROR "ONNX Runtime library not found: ${ONNXRUNTIME_LIB}")
endif()

message(STATUS "godot-cpp: ${GODOT_CPP_PATH}")
message(STATUS "ONNX Runtime: ${ONNXRUNTIME_LIB}")

# Source files ---------------------------------------------------------------
set(SOURCES
    src/extension.cpp
    src/logo_detector.cpp
)

add_library(logo_detector SHARED ${SOURCES})

# Standard GDExtension naming convention:
# lib<name>.<platform>.template_release.<arch>.<ext>
set_target_properties(logo_detector PROPERTIES
    OUTPUT_NAME "logo_detector"
    PREFIX "lib"
)

if(WIN32)
    set_target_properties(logo_detector PROPERTIES
        OUTPUT_NAME "logo_detector.windows.template_release.x86_64"
    )
elseif(LINUX AND NOT ANDROID)
    set_target_properties(logo_detector PROPERTIES
        OUTPUT_NAME "logo_detector.linux.template_release.x86_64"
    )
elseif(ANDROID)
    if(CMAKE_ANDROID_ARCH_ABI STREQUAL "arm64-v8a")
        set_target_properties(logo_detector PROPERTIES
            OUTPUT_NAME "logo_detector.android.template_release.arm64"
        )
    elseif(CMAKE_ANDROID_ARCH_ABI STREQUAL "armeabi-v7a")
        set_target_properties(logo_detector PROPERTIES
            OUTPUT_NAME "logo_detector.android.template_release.arm32"
        )
    endif()
endif()

# Link libraries
target_link_libraries(logo_detector PRIVATE
    godot-cpp
    ${ONNXRUNTIME_LIB}
)

# Include directories
target_include_directories(logo_detector PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${ONNXRUNTIME_ROOT}/include
)

# Platform-specific settings -------------------------------------------------
if(WIN32)
    target_compile_definitions(logo_detector PRIVATE
        NOMINMAX
        _CRT_SECURE_NO_WARNINGS
    )
    set_target_properties(logo_detector PROPERTIES
        WINDOWS_EXPORT_ALL_SYMBOLS ON
    )

    # Copy ONNX Runtime DLLs next to the built extension
    if(EXISTS "${ONNXRUNTIME_DLL}")
        add_custom_command(TARGET logo_detector POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${ONNXRUNTIME_DLL}" $<TARGET_FILE_DIR:logo_detector>
            COMMENT "Copying onnxruntime.dll"
        )
    endif()
    if(EXISTS "${ONNXRUNTIME_SHARED_DLL}")
        add_custom_command(TARGET logo_detector POST_BUILD
            COMMAND ${CMAKE_COMMAND} -E copy_if_different
                "${ONNXRUNTIME_SHARED_DLL}" $<TARGET_FILE_DIR:logo_detector>
            COMMENT "Copying onnxruntime_providers_shared.dll"
        )
    endif()
elseif(UNIX AND NOT APPLE)
    set_target_properties(logo_detector PROPERTIES
        BUILD_RPATH "\$ORIGIN"
        INSTALL_RPATH "\$ORIGIN"
    )
elseif(APPLE)
    set_target_properties(logo_detector PROPERTIES
        BUILD_RPATH "@loader_path"
        INSTALL_RPATH "@loader_path"
    )
endif()

# Optional install target
install(TARGETS logo_detector
    LIBRARY DESTINATION bin
    RUNTIME DESTINATION bin
)
