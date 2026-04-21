# CSO Reader

A minimal cross-platform tool to extract PSP game IDs from CSO (Compressed ISO) files.

## Purpose

Reads the `DISC_ID` from `PSP_GAME/PARAM.SFO` inside a CSO file without extracting the entire archive.

## Usage

```bash
cso_reader path/to/game.cso
# Output: ULUS10509
```

## Building

### Requirements

- CMake 3.10+
- C compiler (gcc, clang, or MSVC)
- zlib development libraries

### Linux/macOS

```bash
cd bin/src/cso_reader
mkdir build && cd build
cmake ..
make
```

### Windows (Visual Studio)

```bash
cd bin/src/cso_reader
mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A x64
cmake --build . --config Release
```

### Windows (MinGW)

```bash
cd bin/src/cso_reader
mkdir build && cd build
cmake .. -G "MinGW Makefiles"
mingw32-make
```

### Cross-compiling (Android)

```bash
cd bin/src/cso_reader
mkdir build-android && cd build-android
cmake .. -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
         -DANDROID_ABI=arm64-v8a \
         -DANDROID_PLATFORM=android-21
cmake --build .
```

## Integration with Kyodai

Place the compiled binary in the appropriate platform directory:

```
bin/cso_reader/
├── win/
│   └── cso_reader.exe
├── linux/
│   └── cso_reader
├── macos/
│   └── cso_reader
└── android/
    ├── cso_reader-arm64
    └── cso_reader-armv7
```

## License

MIT License - Same as Kyodai project.
