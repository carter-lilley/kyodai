#!/usr/bin/env bash
# Rebuilds the KyodaiBridge Android plugin and copies the release AAR into
# the Godot project (addons/KyodaiBridge). Run this after editing anything
# under android/plugin/src. (Bash port of build_plugin.ps1 - the PowerShell
# version only existed because gradlew misbehaves in Windows git-bash.)
#
# Note: the AAR is baked into the APK at export time - after running this,
# re-export/reinstall the app for the changes to reach the device.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Building plugin release AAR..."
(cd "$repo_root/android" && ./gradlew :plugin:assembleRelease --console=plain)

built_aar="$repo_root/android/plugin/build/outputs/aar/plugin-release.aar"
dest_aar="$repo_root/addons/KyodaiBridge/KyodaiBridgePlugin.aar"

[[ -f "$built_aar" ]] || { echo "Build output not found: $built_aar" >&2; exit 1; }

cp -f "$built_aar" "$dest_aar"
echo "Copied $built_aar -> $dest_aar"
echo "Re-export/reinstall the Android build to deploy the new plugin."
