cmake_minimum_required(VERSION 3.10)
project(chd_reader C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

# libchdr source directory
set(LIBCHDIR ${CMAKE_CURRENT_SOURCE_DIR})

# miniz (zlib replacement)
set(MINIZ_SOURCES ${LIBCHDIR}/deps/miniz-3.1.1/miniz.c)
add_library(miniz STATIC ${MINIZ_SOURCES})
target_include_directories(miniz PUBLIC ${LIBCHDIR}/deps/miniz-3.1.1)

# lzma
set(LZMA_SOURCES 
    ${LIBCHDIR}/deps/lzma-25.01/src/LzmaDec.c
    ${LIBCHDIR}/deps/lzma-25.01/src/Alloc.c
)
add_library(lzma STATIC ${LZMA_SOURCES})
target_include_directories(lzma PUBLIC ${LIBCHDIR}/deps/lzma-25.01/include)
target_compile_definitions(lzma PRIVATE _7ZIP_ST)

# zstd
set(ZSTD_SOURCES ${LIBCHDIR}/deps/zstd-1.5.7/zstddeclib.c)
add_library(zstd STATIC ${ZSTD_SOURCES})
target_include_directories(zstd PUBLIC ${LIBCHDIR}/deps/zstd-1.5.7)

# libchdr
set(LIBCHDR_SOURCES
    ${LIBCHDIR}/src/libchdr_bitstream.c
    ${LIBCHDIR}/src/libchdr_cdrom.c
    ${LIBCHDIR}/src/libchdr_chd.c
    ${LIBCHDIR}/src/libchdr_flac.c
    ${LIBCHDIR}/src/libchdr_huffman.c
    ${LIBCHDIR}/src/libchdr_codec_cdlz.c
    ${LIBCHDIR}/src/libchdr_codec_cdzl.c
    ${LIBCHDIR}/src/libchdr_codec_cdzs.c
    ${LIBCHDIR}/src/libchdr_codec_cdfl.c
    ${LIBCHDIR}/src/libchdr_codec_flac.c
    ${LIBCHDIR}/src/libchdr_codec_huff.c
    ${LIBCHDIR}/src/libchdr_codec_lzma.c
    ${LIBCHDIR}/src/libchdr_codec_zlib.c
    ${LIBCHDIR}/src/libchdr_codec_zstd.c
)
add_library(chdr STATIC ${LIBCHDR_SOURCES})
target_include_directories(chdr PUBLIC ${LIBCHDIR}/include)
target_link_libraries(chdr PRIVATE miniz lzma zstd)
target_compile_definitions(chdr PRIVATE FLAC__NO_DLL FLAC__HAS_OGG=0)

# Suppress warnings for cleaner build
if(MSVC)
    target_compile_options(chdr PRIVATE /W0)
else()
    target_compile_options(chdr PRIVATE -w)
endif()

# chd_reader CLI tool
add_executable(chd_reader chd_reader.c)
target_link_libraries(chd_reader PRIVATE chdr miniz lzma zstd)

# Install
install(TARGETS chd_reader DESTINATION .)
