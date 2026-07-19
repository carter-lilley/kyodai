@echo off
REM Local build script for the logo_detector GDExtension on Windows.
REM Requires: CMake, Visual Studio 2022 (or compatible generator), and godot-cpp cloned at the repo root.

setlocal enabledelayedexpansion

set ADDON_DIR=%~dp0..
cd /d "%ADDON_DIR%"

REM Find CMake (may not be on PATH)
set CMAKE_PATH=cmake
where /q cmake
if errorlevel 1 (
    if exist "C:\Program Files\CMake\bin\cmake.exe" (
        set CMAKE_PATH="C:\Program Files\CMake\bin\cmake.exe"
    ) else (
        echo CMake not found. Install CMake and make sure it is on PATH.
        exit /b 1
    )
)

REM Try to set up the VS 2022 / Build Tools C++ environment. This is required
REM for the Visual Studio generator to find a compiler instance.
set VSDEVCMD="C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\Tools\VsDevCmd.bat"
if exist %VSDEVCMD% (
    echo Setting up VS Build Tools environment...
    call %VSDEVCMD% -arch=amd64 -host_arch=amd64
    if errorlevel 1 (
        echo Failed to set up VS Build Tools environment
        exit /b 1
    )
) else (
    echo VsDevCmd.bat not found. Assuming running from a Developer Command Prompt.
)

REM Make sure godot-cpp is present
if not exist "..\..\godot-cpp\CMakeLists.txt" (
    echo godot-cpp not found. Run: git clone --recursive --branch 4.3 --depth 1 https://github.com/godotengine/godot-cpp.git ..
    exit /b 1
)

REM Fetch ONNX Runtime if not already present
set ORT_VERSION=1.27.0
set ORT_DIR=%ADDON_DIR%\thirdparty\onnxruntime
set ORT_URL=https://github.com/microsoft/onnxruntime/releases/download/v%ORT_VERSION%/onnxruntime-win-x64-%ORT_VERSION%.zip

if not exist "%ORT_DIR%\include\onnxruntime_c_api.h" (
    echo Downloading ONNX Runtime %ORT_VERSION% ...
    if not exist "%ADDON_DIR%\thirdparty" mkdir "%ADDON_DIR%\thirdparty"
    powershell -NoProfile -Command "Invoke-WebRequest -Uri '%ORT_URL%' -OutFile '%ADDON_DIR%\thirdparty\onnxruntime.zip'"
    if errorlevel 1 (
        echo Failed to download ONNX Runtime
        exit /b 1
    )
    powershell -NoProfile -Command "Expand-Archive -Path '%ADDON_DIR%\thirdparty\onnxruntime.zip' -DestinationPath '%ADDON_DIR%\thirdparty' -Force"
    move "%ADDON_DIR%\thirdparty\onnxruntime-win-x64-%ORT_VERSION%" "%ORT_DIR%"
    del "%ADDON_DIR%\thirdparty\onnxruntime.zip"
)

REM Ensure build directory exists (delete it manually for a clean rebuild)
if not exist build mkdir build

set BUILD_CONFIG=Release

%CMAKE_PATH% -B build -G "Visual Studio 17 2022" -A x64
if errorlevel 1 (
    echo CMake configuration failed
    exit /b 1
)

%CMAKE_PATH% --build build --config %BUILD_CONFIG% --parallel -- -verbosity:minimal
if errorlevel 1 (
    echo Build failed
    exit /b 1
)

REM Copy results to the bin folder used by the .gdextension file
set BIN_DIR=bin\windows.x86_64
mkdir %BIN_DIR% 2>nul
copy "build\%BUILD_CONFIG%\liblogo_detector.windows.template_release.x86_64.dll" %BIN_DIR%\
copy "%ORT_DIR%\lib\onnxruntime.dll" %BIN_DIR%\
copy "%ORT_DIR%\lib\onnxruntime_providers_shared.dll" %BIN_DIR%\

echo.
echo Build complete. Binaries are in %BIN_DIR%/

REM Verify the DLL does not link Debug CRT
python -c "import pefile; pe=pefile.PE(r'%BIN_DIR%\liblogo_detector.windows.template_release.x86_64.dll'); deps=[e.dll.decode().lower() for e in pe.DIRECTORY_ENTRY_IMPORT]; debug=[d for d in deps if d.endswith('d.dll')]; print('Debug CRT imports:', debug) if debug else print('OK: No Debug CRT imports')"
