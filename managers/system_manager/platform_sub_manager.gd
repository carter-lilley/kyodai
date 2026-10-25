extends Manager
class_name PlatformSubManager

enum Platform {
	WINDOWS,
	LINUX,
	ANDROID,
	UNKNOWN
}

var current_platform: Platform = Platform.UNKNOWN

func _ready():
	_detect_platform()
	_setup_platform_specific_behavior()

func _setup_platform_specific_behavior():
	if is_android():
		# Disable native Android virtual keyboard - we use our own onscreen keyboard
		get_tree().node_added.connect(_on_node_added_android)
		# Check and request permissions on Android (skip during first-run OOBE)
		var first_run_completed = DataManager.get_setting("first_run_completed")
		if first_run_completed and first_run_completed.value:
			_request_android_permissions()
		# Defer: SystemManager autoloads before DataManager, so settings reads
		# must wait a frame.
		call_deferred("_setup_sleep_savers")

# ============================================================================
# SLEEP SAVERS (screen-off Wi-Fi / CPU governor — vendor root daemon required)
# ============================================================================

## True when the sleep savers can work: Android + vendor root daemon.
func is_sleep_saver_supported() -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	return plugin != null and plugin.has_method("isSleepSaverSupported") \
			and bool(plugin.isSleepSaverSupported())

func _setup_sleep_savers() -> void:
	if not is_sleep_saver_supported():
		return
	if not DataManager.setting_changed.is_connected(_on_sleep_saver_setting_changed):
		DataManager.setting_changed.connect(_on_sleep_saver_setting_changed)
	_apply_sleep_saver_settings()

func _apply_sleep_saver_settings() -> void:
	var plugin = _get_android_plugin()
	if plugin == null:
		return
	var wifi_setting = DataManager.get_setting("sleep_wifi_off")
	if wifi_setting and plugin.has_method("setSleepWifiSaverEnabled"):
		plugin.setSleepWifiSaverEnabled(bool(wifi_setting.value))
	var cpu_setting = DataManager.get_setting("sleep_powersave_cpu")
	if cpu_setting and plugin.has_method("setSleepGovernorSaverEnabled"):
		plugin.setSleepGovernorSaverEnabled(bool(cpu_setting.value))

func _on_sleep_saver_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	if setting.property_name in ["sleep_wifi_off", "sleep_powersave_cpu"]:
		_apply_sleep_saver_settings()

func _notification(what: int) -> void:
	if not is_android():
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_IN:
		_on_android_window_focus_in()

func _on_android_window_focus_in() -> void:
	# The native IME must never be visible - it steals gamepad key events via
	# its input connection. Hide it natively and through the plugin.
	DisplayServer.virtual_keyboard_hide()
	var plugin = _get_android_plugin()
	if plugin and plugin.has_method("forceHideKeyboard"):
		plugin.forceHideKeyboard()
	# A text field holding focus at window-focus time can re-attach the IME.
	# Release it unless our own on-screen keyboard is intentionally open.
	if UIManager and UIManager.is_onscreen_keyboard_visible():
		return
	var focus_owner := get_viewport().gui_get_focus_owner()
	if focus_owner is LineEdit or focus_owner is TextEdit:
		focus_owner.release_focus()

func _on_node_added_android(node: Node):
	# When a LineEdit/TextEdit is added on Android, disable the native virtual keyboard
	# We use our own onscreen keyboard instead
	if node is LineEdit:
		node.virtual_keyboard_enabled = false
	elif node is TextEdit:
		# TextEdit doesn't have virtual_keyboard_enabled, use focus callback
		node.focus_entered.connect(_hide_android_keyboard.bind(node))

func _hide_android_keyboard(_node: Control):
	# Hide the native Android virtual keyboard when TextEdit gets focus
	DisplayServer.virtual_keyboard_hide()

func _detect_platform():
	match OS.get_name():
		"Windows":
			current_platform = Platform.WINDOWS
		"Linux", "FreeBSD", "NetBSD", "OpenBSD", "BSD":
			current_platform = Platform.LINUX
		"Android":
			current_platform = Platform.ANDROID
		_:
			current_platform = Platform.UNKNOWN

func is_windows() -> bool:
	return current_platform == Platform.WINDOWS

func is_linux() -> bool:
	return current_platform == Platform.LINUX

func is_android() -> bool:
	return current_platform == Platform.ANDROID

## Returns true when running an exported build (not the editor).
## Packaged builds cannot execute or stat files stored inside the PCK.
func is_packaged() -> bool:
	return not OS.has_feature("editor")

## Returns true when running inside a gamescope Game Mode session (SteamOS
## game mode and friends). Game Mode only presents fullscreen windows, so
## overlay windows must be fullscreen and window switching must bypass EWMH
## hints the gamescope WM ignores.
func is_gamemode() -> bool:
	if not is_linux():
		return false
	var haystack := (
		OS.get_environment("XDG_CURRENT_DESKTOP") + ";"
		+ OS.get_environment("XDG_SESSION_DESKTOP") + ";"
		+ OS.get_environment("DESKTOP_SESSION") + ";"
		+ OS.get_environment("WAYLAND_DISPLAY")
	).to_lower()
	return haystack.contains("gamescope")

func get_platform_name() -> String:
	match current_platform:
		Platform.WINDOWS:
			return "Windows"
		Platform.LINUX:
			return "Linux"
		Platform.ANDROID:
			return "Android"
		_:
			return "Unknown"

func get_settings_key_for_emulator() -> String:
	match current_platform:
		Platform.WINDOWS:
			return "emulator_path_windows"
		Platform.LINUX:
			return "emulator_path_linux"
		Platform.ANDROID:
			return "emulator_path_android"
		_:
			return ""

## Requests necessary permissions on Android
func _request_android_permissions():
	# Get currently granted permissions
	var granted_permissions = OS.get_granted_permissions()
	
	# Check and request standard runtime permissions
	var permissions_to_request = []
	
	# Check storage permissions
	if not "android.permission.READ_EXTERNAL_STORAGE" in granted_permissions:
		permissions_to_request.append("android.permission.READ_EXTERNAL_STORAGE")
	
	if not "android.permission.WRITE_EXTERNAL_STORAGE" in granted_permissions:
		permissions_to_request.append("android.permission.WRITE_EXTERNAL_STORAGE")
	
	# Check internet permission (usually granted automatically)
	if not "android.permission.INTERNET" in granted_permissions:
		permissions_to_request.append("android.permission.INTERNET")
	
	# Check network state permission
	if not "android.permission.ACCESS_NETWORK_STATE" in granted_permissions:
		permissions_to_request.append("android.permission.ACCESS_NETWORK_STATE")
	
	# Check notification permission (Android 13+ / API 33+)
	# Required for foreground service notifications during downloads
	if not "android.permission.POST_NOTIFICATIONS" in granted_permissions:
		permissions_to_request.append("android.permission.POST_NOTIFICATIONS")
	
	if permissions_to_request.size() > 0:
		OS.request_permissions()
	
	# Note: "Install unknown apps" permission is checked when user tries to install an emulator
	# We don't prompt on startup to avoid annoying the user

## Opens Android Settings to enable "Install unknown apps" permission
func open_install_unknown_apps_settings():
	if not is_android():
		return
	
	# Use the KyodaiBridge plugin to launch with the correct intent action
	# (ACTION_APPLICATION_DETAILS_SETTINGS + package: URI). OS.shell_open uses
	# ACTION_VIEW which many OEMs don't handle for settings pages.
	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin:
		plugin.requestInstallUnknownAppsPermission()

## Checks if a specific permission is granted on Android
func has_permission(permission_name: String) -> bool:
	if not is_android():
		return true  # Non-Android platforms don't need Android permissions
	
	var granted_permissions = OS.get_granted_permissions()
	return permission_name in granted_permissions

## Checks if storage access is granted (handles both old and new Android permission models)
func has_storage_permission() -> bool:
	if not is_android():
		return true
	
	var granted = OS.get_granted_permissions()
	var has_old = "android.permission.READ_EXTERNAL_STORAGE" in granted and "android.permission.WRITE_EXTERNAL_STORAGE" in granted
	var has_manage = "android.permission.MANAGE_EXTERNAL_STORAGE" in granted
	return has_old or has_manage

## Opens Android Settings to enable MANAGE_EXTERNAL_STORAGE permission
func open_manage_storage_settings():
	if not is_android():
		return

	# Use the KyodaiBridge plugin to launch with the correct intent action
	# (ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION + package: URI).
	# OS.shell_open uses ACTION_VIEW which many OEMs don't handle for settings pages.
	var plugin = Engine.get_singleton("KyodaiBridge")
	if plugin:
		plugin.requestManageExternalStoragePermission()

# ============================================================================
# ANDROID APP-DATA (SAF) ACCESS — just-in-time grant
# Direct File I/O (with MANAGE_EXTERNAL_STORAGE) is our primary path for all
# storage. Other apps' /Android/data/ and /Android/obb/ are the one exception:
# they're gated on the ext_data_rw group. When Kyodai holds it (firmware-
# dependent), direct I/O just works; failing that, a live vendor root daemon
# covers every package; failing that, we need a one-time document-tree grant
# per package folder. This guard prompts only when no route exists
# (argosy-style), calls back with true once usable access exists.
# ============================================================================

var _saf_grant_pending_callback: Callable = Callable()

func has_android_data_access(path: String = "") -> bool:
	if not is_android():
		return true
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	# Holding ext_data_rw ourselves means direct File I/O into Android/data works
	if plugin.has_method("hasExtDataRwAccess") and bool(plugin.hasExtDataRwAccess()):
		return true
	# A live vendor root daemon covers writes for any package (root tier)
	var root_available = plugin.call("rootAvailable")
	if root_available != null and root_available:
		return true
	if path != "":
		return bool(plugin.hasSafGrantFor(path))
	return bool(plugin.hasSafGrant())

## Calls on_ready(granted: bool). If a document-tree grant already exists, calls
## back immediately with true. Otherwise shows a prompt and launches the system
## folder picker; the callback fires when the flow resolves.
## path: the restricted path that needs access (grant targets its package folder).
func ensure_android_data_access(on_ready: Callable, path: String = "") -> void:
	if not is_android():
		on_ready.call(true)
		return
	var plugin = _get_android_plugin()
	if plugin == null:
		on_ready.call(false)
		return
	if has_android_data_access(path):
		on_ready.call(true)
		return
	# A grant flow is already in flight; queue behind it
	if _saf_grant_pending_callback.is_valid():
		on_ready.call(false)
		return

	_saf_grant_pending_callback = on_ready
	if not plugin.is_connected("saf_grant_result", _on_saf_grant_result):
		plugin.connect("saf_grant_result", _on_saf_grant_result)

	UIManager.show_confirm(
		"Folder Access Required",
		"This needs access to an emulator's app-data folder (Android/data), which Android protects separately.\n\nThe picker will open at the right folder — just tap \"Use this folder\".",
		func():
			plugin.requestAndroidDataAccess(path),
		func():
			_resolve_saf_grant(false),
		Callable(),
		{"overlay_layer": OverlayLayers.LAUNCH_CRITICAL}  # above UILayer so it stays visible over the launch transition overlay
	)

func _on_saf_grant_result(granted: bool) -> void:
	_resolve_saf_grant(granted)

func _resolve_saf_grant(granted: bool) -> void:
	var callback = _saf_grant_pending_callback
	_saf_grant_pending_callback = Callable()
	if callback.is_valid():
		callback.call(granted)

## Opens Android Settings to enable install permissions
## Called when user tries to install an emulator without the required permission
func show_install_permission_dialog():
	if not is_android():
		return
	
	# Open Android settings directly - user must manually enable "Install unknown apps"
	# We don't show a notification since we're taking them directly to settings
	open_install_unknown_apps_settings()

# ============================================================================
# ANDROID FOREGROUND SERVICE HELPERS (unified for SystemManager.download + DataManager)
# ============================================================================

func _get_android_plugin() -> Variant:
	if Engine.has_singleton("KyodaiBridge"):
		return Engine.get_singleton("KyodaiBridge")
	return null

## Starts the Android download foreground service
func start_download_foreground_service(game_name: String = "Game") -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		push_warning("[SystemManager.platform] KyodaiBridge plugin not available for download foreground service")
		return false
	plugin.startDownloadForegroundService(game_name)
	return true

## Updates the Android download foreground service progress
func update_download_foreground_service(game_name: String, progress: int) -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	plugin.updateDownloadForegroundService(game_name, progress)
	return true

## Stops the Android download foreground service
func stop_download_foreground_service() -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	plugin.stopDownloadForegroundService()
	return true

## Starts the Android sync foreground service
func start_sync_foreground_service(platform_name: String = "Game Library", current: int = 0, total: int = 0) -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		push_warning("[SystemManager.platform] KyodaiBridge plugin not available for sync foreground service")
		return false
	plugin.startSyncForegroundService(platform_name, current, total)
	return true

## Updates the Android sync foreground service progress
func update_sync_foreground_service(platform_name: String, current: int = 0, total: int = 0) -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	plugin.updateSyncForegroundService(platform_name, current, total)
	return true

## Stops the Android sync foreground service
func stop_sync_foreground_service() -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	plugin.stopSyncForegroundService()
	return true

func _exit_tree() -> void:
	"""Disconnect platform-specific scene-tree signals to avoid leaked callables."""
	if is_android() and get_tree().node_added.is_connected(_on_node_added_android):
		get_tree().node_added.disconnect(_on_node_added_android)
