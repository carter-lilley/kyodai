#!/bin/bash
# Build script for PackageChecker Android Plugin
# This script builds the plugin and copies it to the addons directory

set -e

echo "Building PackageChecker Android Plugin..."
echo "=========================================="

# Navigate to android directory
cd "$(dirname "$0")/android"

# Clean and build using Java directly to ensure fresh build
echo "Cleaning previous build..."
java -cp gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain clean

echo "Building plugin..."
java -cp gradle/wrapper/gradle-wrapper.jar org.gradle.wrapper.GradleWrapperMain :plugin:assembleRelease

# Copy to addons
echo "Copying AAR to addons/PackageChecker/..."
cp plugin/build/outputs/aar/plugin-release.aar ../addons/PackageChecker/PackageCheckerPlugin.aar

echo ""
echo "Build complete!"
echo "AAR location: addons/PackageChecker/PackageCheckerPlugin.aar"
echo ""
echo "Next steps:"
echo "1. Commit the updated AAR to git"
echo "2. Export your project from Godot"
