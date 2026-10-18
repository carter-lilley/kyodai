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

# Stage the sigil CLI as a fake native library (libsigil.so) in the plugin's
# jniLibs. Android only allows executing binaries from nativeLibraryDir, and
# the package manager extracts libs named lib*.so there with exec permission.
# The committed ELF executables live in bin/sigil/android/ - this copy is why
# Wii U/Switch/etc. title-ID extraction works on-device. (Generated dir;
# gitignored. Never put these in android/build manually - that dir is a
# gitignored generated template and doing exactly that is how this was lost.)
jni_libs="$repo_root/android/plugin/src/main/jniLibs"
mkdir -p "$jni_libs/arm64-v8a" "$jni_libs/armeabi-v7a"
for abi_pair in "arm64:arm64-v8a" "armv7:armeabi-v7a"; do
  src_name="${abi_pair%%:*}"
  dst_abi="${abi_pair##*:}"
  src="$repo_root/bin/sigil/android/sigil-$src_name.bin"
  [[ -f "$src" ]] || { echo "Missing sigil binary: $src" >&2; exit 1; }
  cp -f "$src" "$jni_libs/$dst_abi/libsigil.so"
done
echo "Staged libsigil.so into plugin jniLibs (arm64-v8a, armeabi-v7a)"

echo "Building plugin release AAR..."
(cd "$repo_root/android" && ./gradlew :plugin:assembleRelease --console=plain)

built_aar="$repo_root/android/plugin/build/outputs/aar/plugin-release.aar"
dest_aar="$repo_root/addons/KyodaiBridge/KyodaiBridgePlugin.aar"

[[ -f "$built_aar" ]] || { echo "Build output not found: $built_aar" >&2; exit 1; }

cp -f "$built_aar" "$dest_aar"
echo "Copied $built_aar -> $dest_aar"
echo "Re-export/reinstall the Android build to deploy the new plugin."
