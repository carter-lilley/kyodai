cmake_minimum_required(VERSION 3.10)
project(cso_reader C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Find zlib
find_package(ZLIB REQUIRED)

# Create executable
add_executable(cso_reader cso_reader.c)

# Link zlib
target_link_libraries(cso_reader ZLIB::ZLIB)

# Set static linking for MSVC
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# Install target
install(TARGETS cso_reader DESTINATION .)
