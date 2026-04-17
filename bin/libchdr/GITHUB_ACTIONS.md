# CHD Reader - GitHub Actions Build

This GitHub Actions workflow automatically builds the `chd_reader` CLI tool for all supported platforms.

## Platforms

- **Windows x64** (Visual Studio 2022)
- **Linux x64** (Ubuntu latest)
- **macOS Universal** (Intel + Apple Silicon)
- **Android** (ARM64 + ARMv7)

## How It Works

### Automatic Builds

The workflow triggers on:
- Pushes to `main` or `master` branch (only when `bin/libchdr/**` files change)
- Pull requests affecting `bin/libchdr/**`
- Manual trigger via "Run workflow" button

### Build Outputs

Each build creates:
1. **Artifacts** - Available in the workflow run summary
2. **Release** - Pre-release created automatically on main branch pushes

## Downloading Pre-built Binaries

### Option 1: GitHub Releases (Recommended)

1. Go to [Releases](../../releases)
2. Find the latest `chd_reader-*` release
3. Download the binary for your platform:
   - `chd_reader-windows-x64.exe`
   - `chd_reader-linux-x64`
   - `chd_reader-macos-universal`
   - `chd_reader-android-arm64`

### Option 2: Workflow Artifacts

1. Go to [Actions](../../actions)
2. Click on the latest "Build CHD Reader" workflow run
3. Scroll down to "Artifacts" section
4. Download the artifact for your platform

## Integration with Kyodai

### Desktop (Windows/Linux/macOS)

1. Download the appropriate binary
2. Place it in your project:
   ```
   assets/tools/windows/chd_reader.exe
   assets/tools/linux/chd_reader
   assets/tools/macos/chd_reader
   ```
3. Update GDScript to call the binary:
   ```gdscript
   var chd_reader_path = ProjectSettings.globalize_path("res://assets/tools/windows/chd_reader.exe")
   var output = []
   var exit_code = OS.execute(chd_reader_path, [chd_path, "16", "/tmp/sector.bin"], output)
   ```

### Android

For Android, you need to build `chd_reader` as a shared library and use JNI. See the `libchdr` module in `argosy-launcher` for reference implementation.

## Manual Build

If you prefer to build locally:

### Windows
```powershell
cd bin/libchdr
cmake -B build -G "Visual Studio 17 2022" -A x64
cmake --build build --config Release
```

### Linux/macOS
```bash
cd bin/libchdr
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

### Android (with NDK)
```bash
cd bin/libchdr
cmake -B build \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a \
  -DANDROID_PLATFORM=android-21
cmake --build build
```

## Troubleshooting

### Build Failures

If the GitHub Actions build fails:

1. Check the build logs for specific errors
2. Ensure `submodules: recursive` is working (libchdr has no submodules, but just in case)
3. Verify CMakeLists.txt syntax with `cmake -P CMakeLists.txt`

### Runtime Issues

- **"Cannot execute binary"** - Check file permissions (`chmod +x` on Unix)
- **"Missing DLLs"** (Windows) - May need Visual C++ Redistributable
- **"libc++ not found"** (macOS) - Install Xcode Command Line Tools

## Updating the Build

To modify build configuration:
1. Edit `.github/workflows/build-chd-reader.yml`
2. Commit and push
3. Workflow will run automatically

To add new platforms:
1. Add a new job to the workflow
2. Follow the pattern of existing jobs
3. Update the `release` job to include new artifacts

## License

The `chd_reader` wrapper and build scripts are MIT licensed. libchdr and its dependencies have their own licenses (BSD, zlib, etc.).