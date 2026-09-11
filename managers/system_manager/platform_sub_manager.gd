extends Manager
class_name PlatformSubManager

enum Platform {
	WINDOWS,
	LINUX,
	MACOS,
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
		"macOS":
			current_platform = Platform.MACOS
		"Android":
			current_platform = Platform.ANDROID
		_:
			current_platform = Platform.UNKNOWN

func is_windows() -> bool:
	return current_platform == Platform.WINDOWS

func is_linux() -> bool:
	return current_platform == Platform.LINUX

func is_macos() -> bool:
	return current_platform == Platform.MACOS

func is_android() -> bool:
	return current_platform == Platform.ANDROID

## Returns true when running an exported build (not the editor).
## Packaged builds cannot execute or stat files stored inside the PCK.
func is_packaged() -> bool:
	return not OS.has_feature("editor")

func get_platform_name() -> String:
	match current_platform:
		Platform.WINDOWS:
			return "Windows"
		Platform.LINUX:
			return "Linux"
		Platform.MACOS:
			return "macOS"
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
		Platform.MACOS:
			return "emulator_path_macos"
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
	
	# Use the PackageChecker plugin to launch with the correct intent action
	# (ACTION_APPLICATION_DETAILS_SETTINGS + package: URI). OS.shell_open uses
	# ACTION_VIEW which many OEMs don't handle for settings pages.
	var plugin = Engine.get_singleton("PackageChecker")
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

	# Use the PackageChecker plugin to launch with the correct intent action
	# (ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION + package: URI).
	# OS.shell_open uses ACTION_VIEW which many OEMs don't handle for settings pages.
	var plugin = Engine.get_singleton("PackageChecker")
	if plugin:
		plugin.requestManageExternalStoragePermission()

# ============================================================================
# ANDROID APP-DATA (SAF) ACCESS — just-in-time grant
# Direct File I/O (with MANAGE_EXTERNAL_STORAGE) is our primary path for all
# storage. Other apps' /Android/data/ and /Android/obb/ are the one exception:
# Android blocks them per-app regardless of MES, so they require a one-time
# document-tree grant. This guard prompts only when access is actually needed
# (argosy-style), calls back with true once usable access exists.
# ============================================================================

var _saf_grant_pending_callback: Callable = Callable()

func has_android_data_access(path: String = "") -> bool:
	if not is_android():
		return true
	var plugin = _get_android_plugin()
	if plugin == null:
		return false
	# AltAccess (storage-root symlink, direct File I/O with just MES) counts
	if bool(plugin.isAltAccessSupported()):
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
	if bool(plugin.isAltAccessSupported()) or has_android_data_access(path):
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
	if Engine.has_singleton("PackageChecker"):
		return Engine.get_singleton("PackageChecker")
	return null

## Starts the Android download foreground service
func start_download_foreground_service(game_name: String = "Game") -> bool:
	if not is_android():
		return false
	var plugin = _get_android_plugin()
	if plugin == null:
		push_warning("[SystemManager.platform] PackageChecker plugin not available for download foreground service")
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
		push_warning("[SystemManager.platform] PackageChecker plugin not available for sync foreground service")
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
