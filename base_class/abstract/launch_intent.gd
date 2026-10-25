class_name LaunchIntent
extends Resource

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

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

## For Desktop: environment variables to set for the emulator process.
## Only applied on Linux via the env(1) wrapper.
var environment: Dictionary = {}

## For Android: intent action
var android_action: String = ""

## For Android: intent extras array
## Format: [{"key": "name", "value": "val", "type": "string"}, ...]
## Types: "string", "file_path", "file_uri", "document_uri", "boolean", "int"
var android_extras: Array = []

## For Android: package name
var android_package: String = ""

## For Android: activity class
var android_class: String = ""

## For Android: full config dictionary (includes use_intent_data, use_extras, resolve_uri_to_path flags)
var android_config: Dictionary = {}

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
	
	# Check ROM file exists (handle SAF paths on Android)
	if rom_path == "":
		return false
	
	# Check if ROM path exists (file or directory). Routed through FSM so
	# restricted Android paths (another app's Android/data, e.g. extracted
	# PS3 games) validate via the KyodaiBridge plugin - raw FileAccess/
	# DirAccess are denied there and would falsely invalidate the intent.
	if not FSM.file_exists(rom_path) and not FSM.dir_exists(rom_path):
		return false
	
	if emulator_id == "":
		return false
	if platform_slug == "":
		return false
	return true
