cmake_minimum_required(VERSION 3.14)
project(cso_reader C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Download and build zlib automatically
include(FetchContent)
FetchContent_Declare(
    zlib
    GIT_REPOSITORY https://github.com/madler/zlib.git
    GIT_TAG v1.3.1
)

# Configure zlib build
set(ZLIB_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(ZLIB_BUILD_SHARED OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(zlib)

# Create executable
add_executable(cso_reader cso_reader.c)

# Link zlib
target_link_libraries(cso_reader zlibstatic)

# Include zlib headers
target_include_directories(cso_reader PRIVATE ${zlib_SOURCE_DIR} ${zlib_BINARY_DIR})

# Set static linking for MSVC
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# Install target
install(TARGETS cso_reader DESTINATION .)
