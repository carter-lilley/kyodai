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
