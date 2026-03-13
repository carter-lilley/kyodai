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
		# Check and request permissions on Android
		_request_android_permissions()

func _on_node_added_android(node: Node):
	# When a LineEdit/TextEdit is added on Android, disable the native virtual keyboard
	# We use our own onscreen keyboard instead
	if node is LineEdit:
		node.virtual_keyboard_enabled = false
	elif node is TextEdit:
		# TextEdit doesn't have virtual_keyboard_enabled, use focus callback
		node.focus_entered.connect(_hide_android_keyboard.bind(node))

func _hide_android_keyboard(node: Control):
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
	# Check and request standard runtime permissions
	var permissions_to_request = []
	
	# Check storage permissions
	if not OS.request_permission("android.permission.READ_EXTERNAL_STORAGE"):
		permissions_to_request.append("android.permission.READ_EXTERNAL_STORAGE")
	
	if not OS.request_permission("android.permission.WRITE_EXTERNAL_STORAGE"):
		permissions_to_request.append("android.permission.WRITE_EXTERNAL_STORAGE")
	
	# Check internet permission (usually granted automatically)
	if not OS.request_permission("android.permission.INTERNET"):
		permissions_to_request.append("android.permission.INTERNET")
	
	# Check network state permission
	if not OS.request_permission("android.permission.ACCESS_NETWORK_STATE"):
		permissions_to_request.append("android.permission.ACCESS_NETWORK_STATE")
	
	if permissions_to_request.size() > 0:
		OS.request_permissions()
	
	# Note: "Install unknown apps" permission is checked when user tries to install an emulator
	# We don't prompt on startup to avoid annoying the user

## Opens Android Settings to enable "Install unknown apps" permission
func open_install_unknown_apps_settings():
	if not is_android():
		return
	
	# On Android, we need to open the system settings for this app
	# The user must manually enable "Install unknown apps" permission
	# We use a generic settings intent since we can't directly open the specific page
	OS.shell_open("android.settings.APPLICATION_SETTINGS")

## Checks if a specific permission is granted on Android
func has_permission(permission_name: String) -> bool:
	if not is_android():
		return true  # Non-Android platforms don't need Android permissions
	
	var granted_permissions = OS.get_granted_permissions()
	return permission_name in granted_permissions

## Opens Android Settings to enable install permissions
## Called when user tries to install an emulator without the required permission
func show_install_permission_dialog():
	if not is_android():
		return
	
	# Open Android settings directly - user must manually enable "Install unknown apps"
	# We don't show a notification since we're taking them directly to settings
	open_install_unknown_apps_settings()
