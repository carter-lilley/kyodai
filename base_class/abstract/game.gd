class_name GameResource
extends Resource

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

@export var id: String
@export var romm_id: int
@export var title: String
@export var platform: String
@export var platform_slug: String
@export var cover_url: String
@export var cover_path: String
@export var file_name: String
@export var file_path: String
@export var file_size: int
@export var has_local_copy: bool = false
@export var last_updated: String
@export var description: String
@export var genres: Array[String] = []
@export var rating: float = 0.0

## Raw IGDB metadata blob from RomM (includes multiplayer_modes, related games, etc.)
@export var igdb_metadata: Dictionary = {}

## Per-game emulator override (optional)
@export var preferred_emulator_id: String = ""

## Per-game RetroArch core override (optional)
@export var preferred_core_id: String = ""

## Sibling ROMs - variants of the same game (different regions, versions, etc.)
@export var siblings: Array[Dictionary] = []  # [{id, name, file_name, file_size, title_id}, ...]
@export var selected_sibling_id: int = 0  # 0 means use this game itself

## Whether this is the "master" entry shown in the library view
@export var is_master_entry: bool = true

## Whether this game has cover art (used to hide games without covers from library view)
@export var has_cover_art: bool = true

## Timestamp of when this game was last played (ISO format)
@export var last_played: String = ""

## Platform-specific Title ID (for Vita, PS3, etc.)
@export var title_id: String = ""

## Tracks which sibling IDs have been downloaded locally
## Array of sibling IDs that have local copies
@export var downloaded_sibling_ids: Array[int] = []

## Cover grouping fields for "Fold Duplicate Covers" feature
## Games with identical covers are grouped together with a cover_group_id
@export var cover_group_id: String = ""  # Empty if no duplicate covers, otherwise hash of cover_url
@export var cover_group_master: bool = true  # Is this the master of its cover group?

## Cached logo box detection result (normalized texture-space coords + metadata)
@export var logo_box: Dictionary = {}

## Precomputed cover-crop UV transforms per ratio index ("1"-"4") x logo mode
## ("include"/"exclude"), with aspect/tex_aspect/logo_rect provenance.
@export var crop_transforms: Dictionary = {}

## Game source type: "romm" (default), "gamenative", etc.
@export var source: String = "romm"

## Steam App ID for GameNative games
@export var steam_app_id: int = 0

# Transient fields for sync tracking (not persisted)
# Used by RomM sync flow via reflection/metascript.
@warning_ignore("unused_private_class_variable")
var _sync_db_done: bool = false
@warning_ignore("unused_private_class_variable")
var _sync_cover_done: bool = false
@warning_ignore("unused_private_class_variable")
var _sync_db_success: bool = false
@warning_ignore("unused_private_class_variable")
var _sync_processed: bool = false  # Guard to prevent double-processing

## Returns the ID of the game/sibling that should be used (for downloads, etc.)
func get_active_game_id() -> int:
	if selected_sibling_id != 0:
		return selected_sibling_id
	return romm_id

## Returns the title_id of the active game/sibling
func get_active_title_id() -> String:
	if selected_sibling_id != 0:
		for sibling in siblings:
			if sibling.get("id", 0) == selected_sibling_id:
				return sibling.get("title_id", "")
	return title_id

## Sets the title_id for a specific sibling
func set_sibling_title_id(sibling_id: int, new_title_id: String) -> void:
	if sibling_id == romm_id:
		title_id = new_title_id
		return
	for sibling in siblings:
		if sibling.get("id", 0) == sibling_id:
			sibling["title_id"] = new_title_id
			return

## Returns the file name of the active game/sibling
func get_active_file_name() -> String:
	if selected_sibling_id != 0:
		for sibling in siblings:
			if sibling.get("id", 0) == selected_sibling_id:
				return sibling.get("file_name", file_name)
	return file_name

## Returns the file size of the active game/sibling
func get_active_file_size() -> int:
	if selected_sibling_id != 0:
		for sibling in siblings:
			if sibling.get("id", 0) == selected_sibling_id:
				return sibling.get("file_size", file_size)
	return file_size

## Returns true if the currently selected sibling (or main game) has been downloaded
func is_active_variant_downloaded() -> bool:
	var active_id = get_active_game_id()
	if active_id == romm_id:
		return has_local_copy
	return active_id in downloaded_sibling_ids

## Marks a specific sibling as downloaded
func mark_sibling_downloaded(sibling_id: int):
	if sibling_id == romm_id:
		has_local_copy = true
	elif not sibling_id in downloaded_sibling_ids:
		downloaded_sibling_ids.append(sibling_id)

## Returns the file path for a specific sibling (constructs it based on current file_path pattern)
func get_sibling_file_path(sibling_id: int, root_folder: String) -> String:
	if sibling_id == romm_id:
		return file_path
	
	for sibling in siblings:
		if sibling.get("id", 0) == sibling_id:
			var sibling_file_name = sibling.get("file_name", "")
			if sibling_file_name != "":
				return FSM.join_paths(root_folder, platform_slug, sibling_file_name)
	
	return file_path

func get_display_name() -> String:
	return title if title else file_name

func get_cover_image() -> Texture2D:
	if cover_path and FSM.file_exists(cover_path):
		var img = Image.new()
		var error = img.load(cover_path)
		if error == OK and not img.is_empty():
			return SystemManager.memory.create_texture_from_image(img)
	return null

## Returns the IGDB multiplayer_modes list if present
func get_igdb_multiplayer_modes() -> Array[Dictionary]:
	if igdb_metadata.has("multiplayer_modes") and igdb_metadata["multiplayer_modes"] is Array:
		var result: Array[Dictionary] = []
		for item in igdb_metadata["multiplayer_modes"]:
			if item is Dictionary:
				result.append(item)
		return result
	return []

## Returns combined IGDB related games from all relation categories
func get_igdb_related_games() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if not igdb_metadata is Dictionary:
		return result
	
	var categories = [
		"expansions",
		"dlcs",
		"remasters",
		"remakes",
		"expanded_games",
		"ports",
		"similar_games",
	]
	
	for category in categories:
		if igdb_metadata.has(category) and igdb_metadata[category] is Array:
			for item in igdb_metadata[category]:
				if item is Dictionary:
					result.append(item)
	return result
