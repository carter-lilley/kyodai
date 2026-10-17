# Kyodai Android Permissions

Canonical record of every Android permission Kyodai declares, why it exists,
where it is declared, and how its runtime grant is obtained. **Update this file
whenever a permission is added or removed** — the merged manifest is generated
at export time and `android/build/` is gitignored, so this document is the
source of truth for intent.

Kyodai is sideloaded (not Play Store), so restricted permissions are fine, but
several still need a *runtime* grant by the user in addition to the manifest
declaration.

## Declared permissions

| Permission | Why | Declared in | Runtime grant |
|---|---|---|---|
| `INTERNET` | Downloads, RomM sync | Export preset checkbox | none |
| `ACCESS_NETWORK_STATE` | Network status checks | Export preset checkbox | none |
| `ACCESS_WIFI_STATE` | Wifi status | Export preset checkbox | none |
| `WAKE_LOCK` | Keep CPU alive during downloads/play | Export preset checkbox (`permissions/wake_lock`) | none |
| `MANAGE_EXTERNAL_STORAGE` | All-files access: `/storage/emulated/0`, USB/OTG SSD mounts, emulator dirs | Plugin manifest + preset checkbox | Settings intent via `requestManageExternalStoragePermission()` |
| `READ/WRITE_EXTERNAL_STORAGE` | Legacy storage (API ≤ 29) | Export preset checkboxes | runtime prompt on old APIs |
| `QUERY_ALL_PACKAGES` | Detect installed emulators (`isPackageInstalled`, app picker) | Plugin manifest + `export_plugin.gd` | none |
| `REQUEST_INSTALL_PACKAGES` | `installApk()` — sideload emulator APKs | Plugin manifest + `export_plugin.gd` + preset `custom_permissions` | **Settings toggle** via `canInstallUnknownApps()` / `requestInstallUnknownAppsPermission()`; install flow is gated on this |
| `REQUEST_DELETE_PACKAGES` | Uninstall emulators from the UI | Preset `custom_permissions` | none (system shows confirm dialog per uninstall) |
| `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` | Keep long downloads/syncs/extractions alive under doze | Preset `custom_permissions` | System dialog via `isIgnoringBatteryOptimizations()` / `requestIgnoreBatteryOptimizations()` |
| `FOREGROUND_SERVICE` / `FOREGROUND_SERVICE_DATA_SYNC` | Download / sync / extractor services | Plugin manifest | none |
| `POST_NOTIFICATIONS` | Download progress + reminders (API 33+) | Plugin manifest + preset checkbox | runtime prompt |
| `VIBRATE` | `vibrateDevice()` | Export preset checkbox | none |
| `READ/WRITE_USER_DICTIONARY` | Onscreen keyboard word suggestions | Export preset checkboxes | none |

## Deliberately NOT declared

- `SCHEDULE_EXACT_ALARM` / `SET_ALARM` — no alarm features planned.
- `CHANGE_WIFI_STATE`, `ACCESS_FINE_LOCATION` — no wifi toggling/SSID scanning.
- `RECEIVE_BOOT_COMPLETED` — no boot autostart.
- `BATTERY_STATS` — signature-level, never granted to sideloaded apps; battery
  level is read from `/sys/class/power_supply/` which needs no permission.
- `READ_MEDIA_*` — redundant with `MANAGE_EXTERNAL_STORAGE`.
- `SYSTEM_ALERT_WINDOW`, Bluetooth perms — no overlay/BT-stack features.

## Rebuilding after changes

1. Edit `android/plugin/src/main/AndroidManifest.xml` and/or
   `export_presets.cfg` (`permissions/*`).
2. If the plugin changed: `cd android && ./build_plugin.sh`
   (needs JDK 17 — e.g. `JAVA_HOME=/usr/lib/jvm/java-17-openjdk` — the plugin's
   Gradle 7.5.1 wrapper cannot run on newer JDKs).
3. Re-export / remote-deploy from the Godot editor.
4. Verify on device:
   `adb shell dumpsys package com.heckpoint.kyodai | grep -A30 "requested permissions"`

## History

- 2026-10-17: Reconstructed after the previous environment's permission set was
  lost (it lived in a gitignored `android/build/` template / uncommitted state).
  Added `REQUEST_INSTALL_PACKAGES` (root cause of silent APK install failures),
  `REQUEST_DELETE_PACKAGES`, `REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`, `WAKE_LOCK`.
  Plugin renamed PackageChecker → KyodaiBridge in the same pass.
