extends Manager
class_name M3USubManager

## Generates and validates .m3u playlists for multi-disc games.
## Mirrors argosy-launcher's M3uManager: m3u is only used on platforms whose
## emulators/cores understand playlists; other platforms fall back to disc 1.

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

const SUPPORTED_PLATFORMS: Array[String] = ["psx", "saturn", "dc", "dreamcast", "amiga"]
const DISC_IMAGE_EXTENSIONS: Array[String] = ["cue", "gdi", "chd", "iso", "bin", "img", "mdf", "cdi", "adf", "adz", "dms", "fdi", "ipf"]

var launch_manager: Node

func _ready():
	launch_manager = get_parent()

static func supports_m3u(platform_slug: String) -> bool:
	return platform_slug in SUPPORTED_PLATFORMS

## Returns the path to launch for a multi-disc game: a validated/generated m3u,
## or the single downloaded disc if only one exists. Returns "" when m3u does
## not apply (unsupported platform, not multi-disc, or no discs on disk).
func ensure_m3u(game: GameResource) -> String:
	if not supports_m3u(game.platform_slug):
		return ""
	if not game.is_multi_disc():
		return ""

	var disc_files := _resolve_disc_files(game)
	if disc_files.is_empty():
		return ""

	var existing := game.m3u_path
	if existing != "" and _validate_m3u(existing, disc_files.size()):
		return existing

	return _generate_m3u(game, disc_files)

## Generates the m3u once every disc of a multi-disc game is downloaded.
## Called after downloads complete; no-op for incomplete sets.
func generate_m3u_if_complete(game: GameResource) -> void:
	if not supports_m3u(game.platform_slug):
		return
	if not game.is_multi_disc() or not game.are_all_discs_downloaded():
		return
	var result := ensure_m3u(game)
	if result != "":
		print("[M3UManager] m3u ready for " + game.get_display_name() + ": " + result)

## Resolves on-disk paths for all downloaded disc entries, ordered by disc number.
## Sibling file names may lack an extension until full details are fetched;
## in that case the platform folder is scanned for a matching disc image.
func _resolve_disc_files(game: GameResource) -> Array[String]:
	var root_folder = DataManager.get_setting("games_root_folder")
	var root_path: String = root_folder.value if root_folder else "user://roms/"
	var platform_dir := FSM.join_paths(root_path, game.platform_slug)

	var disc_files: Array[String] = []
	for entry in game.get_disc_entries():
		if not entry["downloaded"]:
			continue
		var file_name: String = entry["file_name"]
		if file_name == "":
			continue
		var path := FSM.join_paths(platform_dir, file_name)
		if FSM.file_exists(path):
			disc_files.append(path)
			continue
		# File name may be unresolved (fs_name_no_ext, which can itself contain
		# dots) - find the real file on disk by matching the basename.
		if not entry.get("name_resolved", false) or not file_name.contains("."):
			var found := _find_disc_file(platform_dir, file_name)
			if found != "":
				disc_files.append(found)
	return disc_files

func _find_disc_file(platform_dir: String, base_name: String) -> String:
	for candidate in FSM.list_dir(platform_dir):
		if candidate.get_basename() == base_name and candidate.get_extension().to_lower() in DISC_IMAGE_EXTENSIONS:
			var path := FSM.join_paths(platform_dir, candidate)
			if FSM.file_exists(path):
				return path
	return ""

func _generate_m3u(game: GameResource, disc_files: Array[String]) -> String:
	if disc_files.size() == 1:
		# Single runnable disc - no playlist needed; drop any stale m3u
		if game.m3u_path != "":
			FSM.delete_file(game.m3u_path)
			game.m3u_path = ""
			DataManager.update_game_m3u_path(game.romm_id, "")
		return disc_files[0]

	var parent_dir := FSM.get_dir(disc_files[0])
	var lines: Array[String] = []
	for disc_path in disc_files:
		lines.append(disc_path.get_file())

	var m3u_file := write_m3u(parent_dir, game.title, lines)
	if m3u_file == "":
		return ""

	game.m3u_path = m3u_file
	DataManager.update_game_m3u_path(game.romm_id, m3u_file)
	print("[M3UManager] Generated m3u: " + m3u_file)
	return m3u_file

## Writes an m3u playlist listing file_names (one per line) into dir_path,
## named after the sanitized title. Returns the m3u path, or "" on failure.
static func write_m3u(dir_path: String, title: String, file_names: Array[String]) -> String:
	var m3u_file := FSM.join_paths(dir_path, _sanitize_file_name(title) + ".m3u")
	if not FSM.write_file(m3u_file, "\n".join(file_names)):
		push_error("[M3UManager] Failed to write m3u: " + m3u_file)
		return ""
	return m3u_file

func _validate_m3u(m3u_path: String, expected_disc_count: int) -> bool:
	if not FSM.file_exists(m3u_path):
		return false
	var lines := _parse_m3u_lines(m3u_path)
	if lines.size() < 2 or lines.size() != expected_disc_count:
		return false
	var parent_dir := FSM.get_dir(m3u_path)
	for line in lines:
		if not FSM.file_exists(FSM.join_paths(parent_dir, line)):
			return false
	return true

func _parse_m3u_lines(m3u_path: String) -> Array[String]:
	var lines: Array[String] = []
	var content := FSM.read_file(m3u_path)
	for raw_line in content.split("\n"):
		var line := raw_line.strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		lines.append(line)
	return lines

static func _sanitize_file_name(p_name: String) -> String:
	var regex := RegEx.new()
	regex.compile("[<>:\"/\\\\|?*]")
	var sanitized := regex.sub(p_name, "", true)
	regex.compile("\\s+")
	return regex.sub(sanitized, " ", true).strip_edges()
