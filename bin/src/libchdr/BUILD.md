# Building chd_reader

Cross-platform CLI tool for reading ISO sectors from CHD files using libchdr.

## Prerequisites

- **CMake 3.10+**
- **C compiler** (GCC, Clang, or MSVC)

## Windows (Visual Studio)

```powershell
# Open "Developer PowerShell for VS"
cd bin/src/libchdr
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
# Output: build/Release/chd_reader.exe
# Copy to: bin/libchdr/win/chd_reader.exe
```

## Windows (MinGW)

```bash
cd bin/src/libchdr
cmake -B build -G "MinGW Makefiles"
cmake --build build
# Output: build/chd_reader.exe
# Copy to: bin/libchdr/win/chd_reader.exe
```

## Linux

```bash
cd bin/src/libchdr
cmake -B build
cmake --build build
# Output: build/chd_reader
# Copy to: bin/libchdr/linux/chd_reader
```

## macOS

```bash
cd bin/src/libchdr
cmake -B build
cmake --build build
# Output: build/chd_reader
# Copy to: bin/libchdr/macos/chd_reader
```

## Android (via NDK)

```bash
cd bin/src/libchdr
$ANDROID_SDK/ndk/25.2.9519653/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-21 \
  -B build-android
cmake --build build-android
# Output: build-android/chd_reader
# Copy to: bin/libchdr/android/chd_reader-arm64
```

For Android integration with Godot, build as a shared library and use JNI instead.

## Usage

```bash
# Read single sector to stdout
chd_reader game.chd 16 > sector_16.bin

# Read single sector to file
chd_reader game.chd 16 sector_16.bin

# Dump multiple sectors
chd_reader game.chd dump 16 10 output_prefix
# Creates: output_prefix_00000016.bin, output_prefix_00000017.bin, etc.
```

## Integration with Kyodai

Copy the built binary to the platform directory:

```
bin/libchdr/win/chd_reader.exe
bin/libchdr/linux/chd_reader
bin/libchdr/macos/chd_reader
bin/libchdr/android/chd_reader-arm64
```

Then call from GDScript:
```gdscript
var chd_reader_path = ProjectSettings.globalize_path("res://bin/libchdr/win/chd_reader.exe")
var output = []
var exit_code = OS.execute(chd_reader_path, [chd_path, "16", "/tmp/sector.bin"], output)
```

## Troubleshooting

**"CMake not found"**: Install CMake from https://cmake.org/download/

**"No C compiler found"**: Install Visual Studio (Windows) or build-essential (Linux)

**"LNK2019 errors"**: Make sure all submodules are initialized:
```bash
git submodule update --init --recursive
```

## License

The chd_reader wrapper is MIT licensed. libchdr and its dependencies have their own licenses (BSD, zlib, etc.).
