extends Manager

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
		var first_run_completed = SettingsManager.get_setting("first_run_completed")
		if first_run_completed and first_run_completed.value:
			_request_android_permissions()
		# Swap trigger axes: Android handhelds (Ayn, Retroid, Anbernic) report
		# left trigger as axis 5 and right trigger as axis 4 (opposite of standard)
		_swap_android_trigger_axes()

func _swap_android_trigger_axes():
	"""Swap zoom trigger axes for Android handhelds.
	Most Android handhelds (Ayn, Retroid, Anbernic) map left trigger to axis 5
	and right trigger to axis 4, opposite of standard Xbox/PC controllers."""
	var zoom_in_events = InputMap.action_get_events("zoom_in")
	var zoom_out_events = InputMap.action_get_events("zoom_out")
	
	for event in zoom_in_events:
		if event is InputEventJoypadMotion:
			event.axis = 4
			break
	
	for event in zoom_out_events:
		if event is InputEventJoypadMotion:
			event.axis = 5
			break

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

## Opens Android Settings to enable install permissions
## Called when user tries to install an emulator without the required permission
func show_install_permission_dialog():
	if not is_android():
		return
	
	# Open Android settings directly - user must manually enable "Install unknown apps"
	# We don't show a notification since we're taking them directly to settings
	open_install_unknown_apps_settings()

# ============================================================================
# ANDROID FOREGROUND SERVICE HELPERS (unified for DownloadManager + DataManager)
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
		push_warning("[PlatformManager] PackageChecker plugin not available for download foreground service")
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
		push_warning("[PlatformManager] PackageChecker plugin not available for sync foreground service")
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
