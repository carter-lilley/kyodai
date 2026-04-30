cmake_minimum_required(VERSION 3.14)
project(fatx_tool C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# Add libfatx subdirectory
add_subdirectory(libfatx)

# Create executable
add_executable(fatx_tool fatx_tool.c)

# Link libfatx
target_link_libraries(fatx_tool fatx)

# Include libfatx headers
target_include_directories(fatx_tool PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

# Set static linking for MSVC
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded$<$<CONFIG:Debug>:Debug>")
endif()

# Install target
install(TARGETS fatx_tool DESTINATION .)
