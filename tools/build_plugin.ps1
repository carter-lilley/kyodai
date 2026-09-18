# Rebuilds the PackageChecker Android plugin and copies the release AAR into
# the Godot project (addons/PackageChecker). Run this after editing anything
# under android/plugin/src.
#
# Note: the AAR is baked into the APK at export time - after running this,
# re-export/reinstall the app for the changes to reach the device.

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$androidDir = Join-Path $repoRoot "android"

Write-Host "Building plugin release AAR..."
Push-Location $androidDir
try {
    # Invoke the Gradle wrapper jar directly - the gradlew shell script
    # silently fails in some Windows environments (git-bash xargs check).
    java -classpath "gradle\wrapper\gradle-wrapper.jar" org.gradle.wrapper.GradleWrapperMain ":plugin:assembleRelease" "--console=plain"
    if ($LASTEXITCODE -ne 0) { throw "Gradle build failed with exit code $LASTEXITCODE" }
} finally {
    Pop-Location
}

$builtAar = Join-Path $androidDir "plugin\build\outputs\aar\plugin-release.aar"
$destAar = Join-Path $repoRoot "addons\PackageChecker\PackageCheckerPlugin.aar"

if (-not (Test-Path $builtAar)) { throw "Build output not found: $builtAar" }

Copy-Item $builtAar $destAar -Force
Write-Host "Copied $builtAar -> $destAar"
Write-Host "Re-export/reinstall the Android build to deploy the new plugin."
