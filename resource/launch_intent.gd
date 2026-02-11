class_name LaunchIntent
extends Resource

## Represents a platform-agnostic intent to launch a game
## Contains all information needed to execute the launch on any supported platform

## The game to be launched
var game: GameResource

## Emulator identifier from registry (e.g., "retroarch", "pcsx2")
var emulator_id: String = ""

## Human-readable emulator name
var emulator_name: String = ""

## Path to the ROM file
var rom_path: String = ""

## Platform slug (e.g., "snes", "ps2")
var platform_slug: String = ""

## For RetroArch: the core library name (e.g., "snes9x", "pcsx_rearmed")
var core_name: String = ""

## Platform-specific launch arguments (already formatted)
var launch_args: Array[String] = []

## For Desktop: working directory for the process
var working_directory: String = ""

## For Android: intent action
var android_action: String = ""

## For Android: intent extras dictionary
var android_extras: Dictionary = {}

## For Android: package name
var android_package: String = ""

## For Android: activity class
var android_class: String = ""

func _to_string() -> String:
	return "LaunchIntent(game=%s, emulator=%s, platform=%s, rom=%s)" % [
		game.get_display_name() if game else "null",
		emulator_name,
		platform_slug,
		rom_path
	]

## Validates that all required fields are populated
func is_valid() -> bool:
	if not game:
		return false
	if rom_path == "" or not FileAccess.file_exists(rom_path):
		return false
	if emulator_id == "":
		return false
	if platform_slug == "":
		return false
	return true
