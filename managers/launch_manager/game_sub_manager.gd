extends Manager
class_name GameSubManager

## Per-emulator/per-platform game preparation

const DEBUG_LOG: bool = false
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const _SigilRunner = preload("res://utils/identity/sigil_runner.gd")

var launch_manager: Node

## One-shot awaitable used by _await_extraction so it can wake on either the
## extraction_completed signal or the timeout timer, whichever fires first.
class _ExtractionWaiter:
	signal done

# Set by _prepare_game_for_launch to the final ROM path used during preparation.
# LaunchManager reads this after calling prepare_game_for_shuffler() to update bag entries.
var _last_prepared_rom_path: String = ""

func _ready():
	launch_manager = get_parent()

## Helper to store title_id for the active game or sibling
func _store_file_path(game: GameResource, file_path: String) -> void:
	if DEBUG_LOG: print("[GameManager] _store_file_path: current=" + game.file_path + " new=" + file_path)
	if game.file_path != file_path:
		game.file_path = file_path
		DataManager.update_game(game, func(ok: bool):
			if not ok:
				push_error("[GameManager] _store_file_path: DB persist FAILED for " + game.title + " (path=" + file_path + ")")
		)
		if DEBUG_LOG: print("[GameManager] _store_file_path: UPDATED and persisted to DB")
	else:
		if DEBUG_LOG: print("[GameManager] _store_file_path: path already correct, no update needed")

func _store_title_id(game: GameResource, title_id: String, sigil_result: Dictionary = {}) -> void:
	var save_id: String = sigil_result.get("save_id", "")
	var save_usage: String = sigil_result.get("usage", "")
	var active_id = game.get_active_game_id()
	if active_id == game.romm_id:
		# Main game
		if game.title_id != title_id:
			game.title_id = title_id
			DataManager.update_game_title_id(game.romm_id, title_id)
		if save_id != "" and (game.save_id != save_id or game.save_usage != save_usage):
			game.save_id = save_id
			game.save_usage = save_usage
			DataManager.update_game_save_info(game.romm_id, save_id, save_usage)
	else:
		# Sibling - update in the siblings array
		var changed = false
		if game.get_active_title_id() != title_id:
			game.set_sibling_title_id(active_id, title_id)
			changed = true
		if save_id != "" and (game.get_active_save_id() != save_id or game.get_active_save_usage() != save_usage):
			game.set_sibling_save_info(active_id, save_id, save_usage)
			changed = true
		if changed:
			# Persist the updated siblings array to DB
			DataManager.update_game_siblings(game.romm_id, game.siblings)

## Wii save restore needs the category half of the title id (WiiWare lives
## under 00010004, discs under 00010000). Normalizes a wii game id to its
## full 16-char form: 8-hex disc codes get the disc category, longer ids
## (WAD ticket ids) pass through unchanged.
func _full_wii_title_id(game_id: String) -> String:
	if game_id.length() == 8 and game_id.is_valid_hex_number(false):
		return "00010000" + game_id
	return game_id

## Legacy wii records stored only the 8-hex disc code; they need a one-time
## rewrite to the full 16-char id so save restore picks the right title root.
func _needs_wii_id_upgrade(game: GameResource, title_id: String) -> bool:
	return game.platform_slug == "wii" and title_id.length() == 8 and title_id.is_valid_hex_number(false)

## Best-effort title-ID fill for any launch: when the platform's save flow
## keys on the title ID (folder saves) and none is stored, extract it with
## sigil once here so save sync has it. Runs before the per-family prep flows;
## failure only skips save sync, never the launch.
func _ensure_save_identity(game: GameResource, rom_path: String, emulator_id: String) -> void:
	if game.get_active_title_id() != "":
		return
	var core_id := ""
	if launch_manager.registry.get_emulator_architecture(emulator_id) == "retroarch":
		core_id = LaunchManager.resolve_core_for_game(game)
	if not DataManager.game_save.uses_folder_saves(emulator_id, game.platform_slug, core_id):
		return
	if not _SigilRunner.is_supported(game.platform_slug):
		return
	if rom_path == "" or not FSM.file_exists(rom_path):
		return

	if DEBUG_LOG: print("[GameManager] ID pass: extracting title id from " + rom_path)
	var sigil_result = _SigilRunner.extract(rom_path, game.platform_slug)
	var title_id = sigil_result.get("title_id", "")
	if title_id == "" and game.platform_slug == "wii" and rom_path.get_extension().to_lower() == "wad":
		# Sigil only reads Wii discs; WAD packages carry the id in their ticket
		title_id = TitleIDParser.extract_wii_wad_title_id(rom_path)
		if title_id != "":
			sigil_result = {}
	if title_id == "":
		push_warning("[GameManager] ID pass: no title id found in " + rom_path + " (save sync will skip)")
		return
	if game.platform_slug == "wii":
		title_id = _full_wii_title_id(title_id)
	_store_title_id(game, title_id, sigil_result)
	print("[GameManager] ID pass: stored title id " + title_id + " for " + game.get_display_name())

## Prepares a game for launch by extracting title IDs and game files
## This must be called BEFORE save sync so that the title_id is available
## Returns true if preparation succeeded (or no prep needed), false on error
func _prepare_game_for_launch(game: GameResource, emulator_id: String, is_shuffler: bool = false, rom_path_override: String = "") -> bool:
	print("[GameManager] _prepare_game_for_launch: START for " + game.get_display_name() + " (emulator: " + emulator_id + ")")
	
	# Build a temporary intent for ROM path
	var temp_intent = LaunchIntent.new()
	if rom_path_override != "":
		temp_intent.rom_path = rom_path_override
		if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Using shuffler override path = " + rom_path_override)
	elif game.get_active_game_id() != game.romm_id:
		# A sibling variant is selected: its file lives under the library root
		# named by the sibling's (resolved) file_name. game.file_path belongs
		# to the main entry and points at a different file.
		var sibling_root_folder = DataManager.get_setting("games_root_folder")
		var sibling_root_path = sibling_root_folder.value if sibling_root_folder else "user://roms/"
		temp_intent.rom_path = game.get_sibling_file_path(game.get_active_game_id(), sibling_root_path)
		if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Using sibling path = " + temp_intent.rom_path)
	elif game.file_path != "":
		temp_intent.rom_path = game.file_path
		if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Using game.file_path = " + game.file_path)
	else:
		var root_folder = DataManager.get_setting("games_root_folder")
		var root_path = root_folder.value if root_folder else "user://roms/"
		temp_intent.rom_path = FSM.join_paths(root_path, game.platform_slug, game.get_active_file_name())
		if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Constructed path = " + temp_intent.rom_path)
	
	temp_intent.emulator_id = emulator_id

	# game.file_path can be server-relative ("roms/<slug>/<file>") when the game
	# has no normal local copy (e.g. shuffler sessions play from a temp dir).
	# Downstream tools like sigil need a real path; map it onto the local
	# library layout (games_root_folder/<slug>/<file>).
	if not temp_intent.rom_path.is_absolute_path():
		var library_root_setting = DataManager.get_setting("games_root_folder")
		var library_root: String = library_root_setting.value if library_root_setting else "user://roms/"
		var rel: String = temp_intent.rom_path
		if rel.begins_with("roms/"):
			rel = rel.substr(5)
		temp_intent.rom_path = FSM.join_paths(library_root, rel)
		if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Resolved relative ROM path -> " + temp_intent.rom_path)

	# Generic ID pass: any launch whose save flow keys on the title ID gets one
	# extraction attempt, regardless of emulator family. Per-family prep flows
	# below keep their own semantics; this fills the gap for families without
	# one (RetroArch, ...). Uses the pre-m3u ROM path — sigil reads discs, not
	# playlists. Best-effort: failure never blocks the launch.
	_ensure_save_identity(game, temp_intent.rom_path, emulator_id)

	# Multi-disc games on m3u-capable platforms launch through a generated
	# playlist so the emulator can swap discs. A specific disc sibling selected
	# by the user (disc 2+) still launches that disc file directly. LaunchManager
	# force-downloads missing discs before launch, so the set is complete here.
	if rom_path_override == "" and M3USubManager.supports_m3u(game.platform_slug) and game.is_multi_disc():
		if game.get_active_disc_number() <= 1:
			var m3u_path: String = launch_manager.m3u.ensure_m3u(game)
			if m3u_path != "":
				if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Multi-disc launch via m3u = " + m3u_path)
				temp_intent.rom_path = m3u_path

	var result = true

	# Dispatch prep on architecture family so forks (nethersx2, aps3e,
	# x360-mobile, ...) share their parent emulator's preparation logic.
	match launch_manager.registry.get_emulator_architecture(emulator_id):
		"azahar":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing Azahar game...")
			result = _prepare_azahar_game(game, temp_intent)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Azahar prep result = " + str(result))
		"cemu":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing Cemu game...")
			result = _prepare_cemu_game(game, temp_intent)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Cemu prep result = " + str(result))
		"eden":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing Eden game...")
			result = _prepare_eden_game(game, temp_intent)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Eden prep result = " + str(result))
		"melonds":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing melonDS game...")
			result = _prepare_melonds_game(game, temp_intent)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: melonDS prep result = " + str(result))
		"dolphin":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing Dolphin game...")
			result = _prepare_dolphin_game(game, temp_intent)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Dolphin prep result = " + str(result))
		"pcsx2":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing PCSX2 game...")
			result = _prepare_pcsx2_game(game, temp_intent)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: PCSX2 prep result = " + str(result))
		"ppsspp":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing PPSSPP game...")
			result = _prepare_ppsspp_game(game, temp_intent)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: PPSSPP prep result = " + str(result))
		"vita3k", "vita3k-canary":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing Vita3K game...")
			result = await _prepare_vita3k_game(game, temp_intent, is_shuffler)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Vita3K prep result = " + str(result))
		"rpcs3":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing RPCS3 game...")
			result = await _prepare_rpcs3_game(game, temp_intent, is_shuffler)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: RPCS3 prep result = " + str(result))
		"shadps4":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing shadPS4 game...")
			result = await _prepare_shadps4_game(game, temp_intent)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: shadPS4 prep result = " + str(result))
		"xenia":
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Preparing Xenia game...")
			result = await _prepare_xenia_game(game, temp_intent, is_shuffler)
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: Xenia prep result = " + str(result))
		_:
			if DEBUG_LOG: print("[GameManager] _prepare_game_for_launch: No prep needed for emulator: " + emulator_id)
	
	print("[GameManager] _prepare_game_for_launch: END result = " + str(result))
	if result:
		_last_prepared_rom_path = temp_intent.rom_path
	else:
		_last_prepared_rom_path = ""
	return result

func _prepare_azahar_game(game: GameResource, intent: LaunchIntent) -> bool:
	if game.get_active_title_id() != "":
		return true
	if DEBUG_LOG: print("[GameManager] Azahar: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var sigil_result = _SigilRunner.extract(rom_path, "3ds")
	var title_id = sigil_result.get("title_id", "")
	if title_id == "":
		push_error("[GameManager] Azahar: Failed to extract TitleID from: " + rom_path)
		SystemManager.notifications.show_notification("Failed to extract 3DS game TitleID", SystemManager.notifications.Type.ERROR)
		return false
	
	if DEBUG_LOG: print("[GameManager] Azahar: TitleID from ROM: " + title_id)
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != title_id:
		print("[GameManager] Azahar: WARNING - Stored TitleID " + active_title_id + " doesn't match ROM TitleID " + title_id)
		print("[GameManager] Azahar: Updating to correct TitleID from ROM")
	
	if active_title_id != title_id:
		_store_title_id(game, title_id, sigil_result)
		print("[GameManager] Azahar: Updated database with TitleID: " + title_id)
	
	return true

func _prepare_cemu_game(game: GameResource, intent: LaunchIntent) -> bool:
	if game.get_active_title_id() != "":
		return true
	if DEBUG_LOG: print("[GameManager] Cemu: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var sigil_result = _SigilRunner.extract(rom_path, "wiiu")
	var title_id = sigil_result.get("title_id", "")
	if title_id == "":
		push_error("[GameManager] Cemu: Failed to extract TitleID from: " + rom_path)
		SystemManager.notifications.show_notification("Failed to extract Wii U game TitleID", SystemManager.notifications.Type.ERROR)
		return false
	
	if DEBUG_LOG: print("[GameManager] Cemu: TitleID from WUA: " + title_id)
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != title_id:
		print("[GameManager] Cemu: WARNING - Stored TitleID " + active_title_id + " doesn't match WUA TitleID " + title_id)
		print("[GameManager] Cemu: Updating to correct TitleID from WUA")
	
	if active_title_id != title_id:
		_store_title_id(game, title_id, sigil_result)
		print("[GameManager] Cemu: Updated database with TitleID: " + title_id)
	
	return true

func _resolve_eden_title_id_from_db(game_name: String, emulator_id: String) -> String:
	var emulator_dir = launch_manager.registry._get_emulator_directory(emulator_id).rstrip("/")
	var search_roots: Array[String] = [emulator_dir + "/user"]
	if SystemManager.platform.is_windows():
		var appdata = OS.get_environment("APPDATA")
		if appdata != "":
			search_roots.append(appdata + "/eden")
			search_roots.append(appdata + "/yuzu")
	elif SystemManager.platform.is_linux():
		var home = OS.get_environment("HOME")
		if home != "":
			search_roots.append(home + "/.local/share/eden")
			search_roots.append(home + "/.local/share/yuzu")
	
	for root in search_roots:
		var db_path = root + "/cache/game_list/game_list.db"
		if DEBUG_LOG: print("[GameManager] Eden DB lookup: checking " + db_path)
		if not FSM.file_exists(db_path):
			if DEBUG_LOG: print("[GameManager] Eden DB lookup: file does not exist")
			continue
		if DEBUG_LOG: print("[GameManager] Eden DB lookup: file exists, opening...")
		var db = SQLite.new()
		db.path = db_path
		db.verbosity_level = SQLite.VERBOSE
		if not db.open_db():
			if DEBUG_LOG: print("[GameManager] Eden DB lookup: failed to open DB")
			continue
		if DEBUG_LOG: print("[GameManager] Eden DB lookup: DB opened")
		
		var tables = db.query("SELECT name FROM sqlite_master WHERE type='table';")
		if tables == null or not tables is Array:
			if DEBUG_LOG: print("[GameManager] Eden DB lookup: no tables found")
			db.close_db()
			continue
		if DEBUG_LOG: print("[GameManager] Eden DB lookup: tables count = " + str(tables.size()))
		
		for table_dict in tables:
			var table_name = table_dict.get("name", "")
			if table_name == "" or table_name.begins_with("sqlite_"):
				continue
			
			var cols_result = db.query("PRAGMA table_info(" + table_name + ");")
			if cols_result == null or not cols_result is Array:
				continue
			
			var id_col = ""
			var name_col = ""
			for col in cols_result:
				var col_name = str(col.get("name", "")).to_lower()
				if id_col == "" and col_name in ["title_id", "program_id", "id"]:
					id_col = str(col.get("name", ""))
				if name_col == "" and ("name" in col_name or "title" in col_name):
					name_col = str(col.get("name", ""))
			
			if id_col == "" or name_col == "":
				continue
			
			if DEBUG_LOG: print("[GameManager] Eden DB lookup: scanning table '" + table_name + "' (id_col=" + id_col + ", name_col=" + name_col + ")")
			var query = "SELECT " + id_col + " FROM " + table_name + " WHERE " + name_col + " LIKE ? LIMIT 1;"
			var rows = db.query_with_bindings(query, ["%" + game_name + "%"])
			if rows != null and rows is Array and rows.size() > 0:
				var raw = rows[0].get(id_col, "")
				var tid = ""
				if raw is int:
					tid = "%016x" % raw
				elif raw is String:
					tid = raw.to_upper().replace("0X", "")
				if DEBUG_LOG: print("[GameManager] Eden DB lookup: raw result = " + str(raw) + ", parsed tid = " + tid)
				if tid.length() == 16:
					var valid = true
					for c in tid:
						if not ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F')):
							valid = false
							break
					if valid and tid.begins_with("01"):
						db.close_db()
						if DEBUG_LOG: print("[GameManager] Eden: TitleID from DB (" + root + "): " + tid)
						return tid
					else:
						if DEBUG_LOG: print("[GameManager] Eden DB lookup: parsed tid invalid or doesn't start with 01")
			else:
				if DEBUG_LOG: print("[GameManager] Eden DB lookup: no match in table '" + table_name + "' for '" + game_name + "'")
		
		db.close_db()
	
	if DEBUG_LOG: print("[GameManager] Eden DB lookup: exhausted all roots, no title id found")
	return ""

func _prepare_eden_game(game: GameResource, intent: LaunchIntent) -> bool:
	if game.get_active_title_id() != "":
		return true
	if DEBUG_LOG: print("[GameManager] Eden: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var title_id = ""
	var sigil_result := {}

	# Use existing title_id from database/RomM if it's already valid
	if game.title_id.length() == 16:
		var valid = true
		for c in game.title_id:
			if not ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f')):
				valid = false
				break
		if valid and game.title_id.to_upper().begins_with("01"):
			title_id = game.title_id.to_upper()
			if DEBUG_LOG: print("[GameManager] Eden: Using stored TitleID from database: " + title_id)
	
	if title_id == "":
		var prod_keys = TitleIDParser._get_prod_keys_path(launch_manager.registry._get_emulator_directory("eden"))
		sigil_result = _SigilRunner.extract(rom_path, "switch", prod_keys)
		title_id = sigil_result.get("title_id", "")
	if title_id == "":
		if DEBUG_LOG: print("[GameManager] Eden: ROM extraction failed, trying game_list.db lookup...")
		title_id = _resolve_eden_title_id_from_db(game.get_display_name(), intent.emulator_id)
	
	if title_id == "":
		push_error("[GameManager] Eden: Failed to extract TitleID from: " + rom_path)
		SystemManager.notifications.show_notification("Failed to extract Switch game TitleID", SystemManager.notifications.Type.ERROR)
		return false
	
	if DEBUG_LOG: print("[GameManager] Eden: TitleID resolved: " + title_id)
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != title_id:
		print("[GameManager] Eden: WARNING - Stored TitleID " + active_title_id + " doesn't match resolved TitleID " + title_id)
		print("[GameManager] Eden: Updating to correct TitleID")
	
	if active_title_id != title_id:
		_store_title_id(game, title_id, sigil_result)
		print("[GameManager] Eden: Updated database with TitleID: " + title_id)
	
	return true

func _prepare_dolphin_game(game: GameResource, intent: LaunchIntent) -> bool:
	var existing_id = game.get_active_title_id()
	var is_upgrade_pass = _needs_wii_id_upgrade(game, existing_id)
	if existing_id != "" and not is_upgrade_pass:
		return true
	if DEBUG_LOG: print("[GameManager] Dolphin: Preparing game from ROM path: " + intent.rom_path)

	var rom_path = intent.rom_path
	var game_id = ""
	var sigil_result := {}
	if FSM.file_exists(rom_path):
		sigil_result = _SigilRunner.extract(rom_path, game.platform_slug)
		game_id = sigil_result.get("title_id", "")
		if game_id == "" and game.platform_slug == "wii" and rom_path.get_extension().to_lower() == "wad":
			# Sigil only reads Wii discs; WAD packages carry the id in their ticket
			game_id = TitleIDParser.extract_wii_wad_title_id(rom_path)
			if game_id != "":
				sigil_result = {}
	if game.platform_slug == "wii":
		game_id = _full_wii_title_id(game_id)

	if game_id == "" and existing_id == "":
		if DEBUG_LOG: print("[GameManager] Dolphin: Could not extract Game ID from ROM, trying existing saves...")
		var emulator_dir = launch_manager.registry._get_emulator_directory("dolphin")
		game_id = TitleIDParser.extract_gamecube_game_id_from_existing_saves(emulator_dir)

	if game_id == "":
		if is_upgrade_pass:
			# Best-effort upgrade only; keep the legacy id and never block launch
			push_warning("[GameManager] Dolphin: title id upgrade extraction failed for " + rom_path + ", keeping legacy id " + existing_id)
			return true
		push_error("[GameManager] Dolphin: Failed to extract Game ID from: " + rom_path)
		SystemManager.notifications.show_notification("Failed to extract GameCube/Wii game ID", SystemManager.notifications.Type.ERROR)
		return false

	if DEBUG_LOG: print("[GameManager] Dolphin: Game ID: " + game_id)

	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != game_id:
		print("[GameManager] Dolphin: WARNING - Stored Game ID " + active_title_id + " doesn't match detected Game ID " + game_id)
		print("[GameManager] Dolphin: Updating to correct Game ID")

	if active_title_id != game_id:
		_store_title_id(game, game_id, sigil_result)
		print("[GameManager] Dolphin: Updated database with Game ID: " + game_id)

	return true

## Ensures melonDS actually uses the BIOS/firmware files kyodai manages:
## melonDS defaults Emu.ExternalBIOSEnable to false (built-in FreeBIOS +
## generated firmware), so seeded or drag-dropped files sit unused until the
## flag is on. Each flag is flipped only when every file its section points at
## exists, so setups without real dumps keep the built-in path working.
## Desktop only: the Android port keeps its settings in SharedPreferences.
## Idempotent; never blocks the launch.
func _prepare_melonds_game(game: GameResource, intent: LaunchIntent) -> bool:
	if SystemManager.platform.is_android():
		return true
	var toml_path = FSM.resolve_emulator_path("{emulator_dir}/melonDS.toml", "melonds")
	if toml_path == "" or not FSM.file_exists(toml_path):
		return true
	var parsed = CSM.read_config(toml_path, CSM.Format.TOML)
	if parsed.get("status", CSM.Status.MISSING) != CSM.Status.OK:
		return true
	var sections: Dictionary = parsed.sections
	var base_dir := toml_path.get_base_dir()

	var emu: Dictionary = sections.get("Emu", {})
	if emu.get("ExternalBIOSEnable", false) != true:
		var ds: Dictionary = sections.get("DS", {})
		if _melonds_paths_exist(ds, ["FirmwarePath", "BIOS7Path", "BIOS9Path"], base_dir):
			if CSM.set_value(toml_path, "ExternalBIOSEnable", true, "Emu"):
				if DEBUG_LOG: print("[GameManager] melonDS: enabled Emu.ExternalBIOSEnable (DS BIOS/firmware files present)")

	var dsi: Dictionary = sections.get("DSi", {})
	if dsi.get("ExternalBIOSEnable", false) != true:
		if _melonds_paths_exist(dsi, ["FirmwarePath", "BIOS7Path", "BIOS9Path", "NANDPath"], base_dir):
			if CSM.set_value(toml_path, "ExternalBIOSEnable", true, "DSi"):
				if DEBUG_LOG: print("[GameManager] melonDS: enabled DSi.ExternalBIOSEnable (DSi BIOS/firmware/NAND files present)")

	return true

## True when every named key in the section holds a path that exists on disk
## (relative values resolve against the config file's dir).
func _melonds_paths_exist(section: Dictionary, keys: Array, base_dir: String) -> bool:
	for key in keys:
		var value := str(section.get(key, "")).strip_edges().replace("\\", "/")
		if value == "":
			return false
		if not value.is_absolute_path():
			value = base_dir + "/" + value
		if not FSM.file_exists(value.simplify_path()):
			return false
	return true

func _prepare_xenia_game(game: GameResource, intent: LaunchIntent, is_shuffler: bool = false) -> bool:
	var rom_path = intent.rom_path

	# Already-extracted game folder (XBLA loose files): validate and reuse
	if FSM.dir_exists(rom_path):
		if _xbox360_game_has_files(rom_path):
			_ensure_xenia_title_id(game, rom_path)
			return true
		push_error("[GameManager] Xenia: Extracted folder has no launchable files: " + rom_path)
		SystemManager.notifications.show_notification("Xbox 360 game folder is missing game files", SystemManager.notifications.Type.ERROR)
		return false

	# XBLA archives (.zip of loose STFS files) extract lazily on first launch.
	# The active file name keeps the original archive extension even after
	# file_path is rewritten to the extracted folder, so a deleted folder
	# falls through to here and gets re-extracted from the archive
	var ext = rom_path.get_extension().to_lower()
	if ext != "zip":
		ext = game.get_active_file_name().get_extension().to_lower()
	if ext == "zip":
		return await _prepare_xenia_archive_game(game, intent, rom_path, is_shuffler)

	# ISO/ZAR: only Title ID extraction is needed, xenia reads these directly
	if game.get_active_title_id() != "":
		return true
	if DEBUG_LOG: print("[GameManager] Xenia: Preparing game from ROM path: " + intent.rom_path)

	var title_id = TitleIDParser.extract_xbox360_title_id(rom_path)
	if title_id == "":
		push_error("[GameManager] Xenia: Failed to extract TitleID from: " + rom_path)
		SystemManager.notifications.show_notification("Failed to extract Xbox 360 game TitleID", SystemManager.notifications.Type.ERROR)
		return false

	if DEBUG_LOG: print("[GameManager] Xenia: TitleID from ISO: " + title_id)

	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != title_id:
		print("[GameManager] Xenia: WARNING - Stored TitleID " + active_title_id + " doesn't match ISO TitleID " + title_id)
		print("[GameManager] Xenia: Updating to correct TitleID from ISO")

	if active_title_id != title_id:
		_store_title_id(game, title_id)
		print("[GameManager] Xenia: Updated database with TitleID: " + title_id)

	return true

## Extracts and stores the title ID for a xenia game if not already known
func _ensure_xenia_title_id(game: GameResource, path: String) -> void:
	var active_title_id = game.get_active_title_id()
	if active_title_id != "":
		return
	var title_id = TitleIDParser.extract_xbox360_title_id(path)
	if title_id != "":
		_store_title_id(game, title_id)
		print("[GameManager] Xenia: Updated database with TitleID: " + title_id)

## Returns true if the folder contains a launchable Xbox 360 file (default.xex or STFS package)
func _xbox360_game_has_files(dir_path: String) -> bool:
	return TitleIDParser.find_xbox360_launch_file(dir_path) != ""

## Handles XBLA archives (.zip of loose STFS files)
## Extracts to <roms>/xbox360/<TitleID>/ next to the archive (which is kept),
## then points the intent and game.file_path at the extracted folder
func _prepare_xenia_archive_game(game: GameResource, intent: LaunchIntent, rom_path: String, is_shuffler: bool = false) -> bool:
	var archive_path = rom_path
	if not FSM.file_exists(archive_path):
		# Extracted files were deleted; relocate the original archive for re-extraction
		archive_path = _locate_xenia_archive(game)
		if archive_path == "":
			push_error("[GameManager] Xenia: XBLA archive not found for: " + game.get_display_name())
			SystemManager.notifications.show_notification("Xbox 360 game archive not found", SystemManager.notifications.Type.ERROR)
			return false

	# Title ID is needed for the extraction folder name
	var title_id = game.get_active_title_id()
	if title_id == "":
		title_id = TitleIDParser.extract_xbox360_title_id(archive_path)
		if title_id == "":
			push_error("[GameManager] Xenia: Failed to extract TitleID from: " + archive_path)
			SystemManager.notifications.show_notification("Failed to extract Xbox 360 game TitleID", SystemManager.notifications.Type.ERROR)
			return false
		_store_title_id(game, title_id)
		print("[GameManager] Xenia: Updated database with TitleID: " + title_id)

	var extract_path = FSM.join_paths(archive_path.get_base_dir(), title_id)
	if DEBUG_LOG: print("[GameManager] Xenia: XBLA extraction path: " + extract_path)

	if not _xbox360_game_has_files(extract_path):
		# Remove stale/partial extraction before re-extracting
		if FSM.dir_exists(extract_path):
			if DEBUG_LOG: print("[GameManager] Xenia: Removing stale extraction: " + extract_path)
			FSM.delete_dir_recursive(extract_path)

		var extract_success := await _extract_xenia_archive(archive_path, extract_path, is_shuffler)
		if not extract_success or not _xbox360_game_has_files(extract_path):
			push_error("[GameManager] Xenia: Extraction failed or produced no launchable files: " + archive_path)
			SystemManager.notifications.show_notification("Failed to extract Xbox 360 game archive", SystemManager.notifications.Type.ERROR)
			return false

	intent.rom_path = extract_path
	if not is_shuffler:
		# Shuffler extractions live in the session temp dir, which is deleted
		# when the session ends; don't point the library record at it.
		_store_file_path(game, extract_path)
	print("[GameManager] Xenia: XBLA game ready at: " + extract_path)
	return true

## Reconstructs the path to the game's source archive from library metadata
func _locate_xenia_archive(game: GameResource) -> String:
	var root_folder = DataManager.get_setting("games_root_folder")
	var root_path = root_folder.value if root_folder else "user://roms/"
	var archive_path = FSM.join_paths(root_path, game.platform_slug, game.get_active_file_name())
	if FSM.file_exists(archive_path):
		return archive_path
	return ""

## Waits for a queued extraction to finish. Uses the extraction_completed
## signal + SceneTreeTimer instead of polling process_frame, so large
## extractions don't burn a frame every tick. Disconnects on match or timeout.
func _await_extraction(item_id: String, log_tag: String, timeout_sec: float = 1800.0) -> bool:
	var waiter := _ExtractionWaiter.new()
	# The callable lives in the tracker Dictionary: lambdas capture locals by
	# value, so a captured Callable variable would stay null inside the lambda.
	var tracker := {"complete": false, "success": false, "cb": Callable()}
	tracker.cb = func(completed_item_id: String, success: bool, _message: String):
		if completed_item_id != item_id:
			return
		tracker.complete = true
		tracker.success = success
		if DEBUG_LOG: print("[%s] Extraction callback - success=%s" % [log_tag, str(success)])
		# Disconnect once matched so we don't keep listening for other items.
		SystemManager.download.extraction_completed.disconnect(tracker.cb)
		waiter.done.emit()

	SystemManager.download.extraction_completed.connect(tracker.cb)
	# Wake on timeout too; if the callback already fired, this emit is a no-op
	# since nobody is still awaiting the waiter.
	get_tree().create_timer(timeout_sec).timeout.connect(func(): waiter.done.emit())
	await waiter.done

	if not tracker.complete:
		if SystemManager.download.extraction_completed.is_connected(tracker.cb):
			SystemManager.download.extraction_completed.disconnect(tracker.cb)
		push_error("[%s] Extraction timed out after %d minutes" % [log_tag, int(timeout_sec / 60.0)])
		return false

	print("[%s] Extraction complete, success=%s" % [log_tag, str(tracker.success)])
	return tracker.success

## Extracts an XBLA archive to the specified directory (archive is kept)
func _extract_xenia_archive(archive_path: String, extract_to: String, suppress_notification: bool = false) -> bool:
	print("[GameManager] Xenia: Extracting archive: " + archive_path + " to: " + extract_to)

	if not FSM.dir_exists(extract_to):
		FSM.make_dir_recursive(extract_to)

	# Shuffler preps suppress the extraction notification: the shuffler runs
	# its own "Preparing Shuffle" notification, so a second extraction
	# snackbar would just be noise mid-session.
	var item_id: String = SystemManager.download.queue_extraction(archive_path, extract_to, "xbox360_game", "Extracting Xbox 360 Game", false, suppress_notification)
	if item_id == "":
		push_error("[GameManager] Xenia: Failed to queue extraction")
		return false

	print("[GameManager] Xenia: Waiting for extraction to complete...")
	return await _await_extraction(item_id, "GameManager] Xenia")

func _prepare_pcsx2_game(game: GameResource, intent: LaunchIntent) -> bool:
	if game.get_active_title_id() != "":
		return true
	if DEBUG_LOG: print("[GameManager] PCSX2: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var serial = ""
	var sigil_result := {}

	# Try extracting serial from ROM
	if FSM.file_exists(rom_path):
		sigil_result = _SigilRunner.extract(rom_path, "ps2")
		serial = sigil_result.get("title_id", "")
		if serial != "":
			if DEBUG_LOG: print("[GameManager] PCSX2: Serial from ROM: " + serial)
	
	if serial == "":
		push_error("[GameManager] PCSX2: Failed to extract serial from: " + rom_path)
		SystemManager.notifications.show_notification("Failed to extract PS2 game serial", SystemManager.notifications.Type.ERROR)
		return false
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != serial:
		print("[GameManager] PCSX2: WARNING - Stored serial " + active_title_id + " doesn't match detected serial " + serial)
		print("[GameManager] PCSX2: Updating to correct serial")
	
	if active_title_id != serial:
		_store_title_id(game, serial, sigil_result)
		print("[GameManager] PCSX2: Updated database with serial: " + serial)
	
	return true

## Handles PPSSPP game extraction and launch preparation
## Returns true if ready to launch, false if error
func _prepare_ppsspp_game(game: GameResource, intent: LaunchIntent) -> bool:
	if game.get_active_title_id() != "":
		return true
	if DEBUG_LOG: print("[GameManager] PPSSPP: Preparing game from ROM path: " + intent.rom_path)
	
	var rom_path = intent.rom_path
	var game_id = ""
	var sigil_result := {}

	# Try extracting game ID from ROM
	if FSM.file_exists(rom_path):
		sigil_result = _SigilRunner.extract(rom_path, "psp")
		game_id = sigil_result.get("title_id", "")
		if game_id != "":
			if DEBUG_LOG: print("[GameManager] PPSSPP: Game ID from ROM: " + game_id)
	
	if game_id == "":
		push_error("[GameManager] PPSSPP: Failed to extract game ID from: " + rom_path)
		SystemManager.notifications.show_notification("Failed to extract PSP game ID", SystemManager.notifications.Type.ERROR)
		return false
	
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != game_id:
		print("[GameManager] PPSSPP: WARNING - Stored ID " + active_title_id + " doesn't match detected ID " + game_id)
		print("[GameManager] PPSSPP: Updating to correct ID")
	
	if active_title_id != game_id:
		_store_title_id(game, game_id, sigil_result)
		print("[GameManager] PPSSPP: Updated database with game ID: " + game_id)
	
	return true

## Handles Vita3K game extraction and launch preparation
## Returns true if ready to launch, false if error
func _prepare_vita3k_game(game: GameResource, intent: LaunchIntent, is_shuffler: bool = false) -> bool:
	if DEBUG_LOG: print("[GameManager] _prepare_vita3k_game: ENTER for " + game.get_display_name() + " (shuffler=" + str(is_shuffler) + ")")
	
	var rom_path = intent.rom_path
	if DEBUG_LOG: print("[GameManager] Vita3K: Preparing game from ROM path: " + rom_path)
	
	# Get emulator directory for checking existing games
	# Platform-specific: Android uses fixed external storage path, desktop uses install path
	var emulator_dir: String
	var ux0_app_path: String
	
	if SystemManager.platform.is_android():
		# Android: Vita3K stores games in its external storage path (configurable in settings)
		# Path is a real filesystem path
		emulator_dir = launch_manager.registry.get_app_data_path("vita3k") + "/vita"
		ux0_app_path = emulator_dir + "/ux0/app"
	else:
		# Desktop: Get path from emulator installation
		var emulator_path = ""
		if intent.emulator_id != "":
			emulator_path = launch_manager.registry.get_emulator_install_path(intent.emulator_id)
		else:
			# Fallback: try to find any vita3k emulator
			emulator_path = launch_manager.registry.get_emulator_install_path("vita3k")
		
		if emulator_path != "":
			# Use the managed emulator directory, not the executable's parent:
			# extracted AppImages nest the exe inside squashfs-root/, which is
			# wiped and re-created on updates — user data must never live there.
			emulator_dir = launch_manager.registry._get_emulator_directory(intent.emulator_id if intent.emulator_id != "" else "vita3k").rstrip("/")
		else:
			# Emulator not installed yet, use the default emulator directory
			# We can still extract the TitleID and prepare the game files
			emulator_dir = launch_manager.registry._get_emulator_directory("vita3k").rstrip("/")
			if DEBUG_LOG: print("[GameManager] Vita3K: Emulator not installed yet, using default directory: " + emulator_dir)
		
		ux0_app_path = emulator_dir + "/ux0/app"
	
	if DEBUG_LOG: print("[GameManager] Vita3K: ux0_app_path = " + ux0_app_path)
	
	# Always extract TitleID from ZIP to ensure we have the correct one for this ROM
	if DEBUG_LOG: print("[GameManager] Vita3K: Extracting TitleID from ZIP...")
	var zip_title_id = TitleIDParser.extract_vita_title_id(rom_path)
	if zip_title_id == "" or not TitleIDParser._is_vita_title_id(zip_title_id):
		push_error("[GameManager] Vita3K: Failed to extract a valid TitleID from: " + rom_path)
		SystemManager.notifications.show_notification("Failed to extract Vita game TitleID", SystemManager.notifications.Type.ERROR)
		return false
	if DEBUG_LOG: print("[GameManager] Vita3K: TitleID from ZIP: " + zip_title_id)
	
	# If stored title_id doesn't match the ZIP, update it
	var active_title_id = game.get_active_title_id()
	if DEBUG_LOG: print("[GameManager] Vita3K: active_title_id from DB = '" + active_title_id + "', zip_title_id = '" + zip_title_id + "'")
	if active_title_id != "" and active_title_id != zip_title_id:
		print("[GameManager] Vita3K: WARNING - Stored TitleID " + active_title_id + " doesn't match ZIP TitleID " + zip_title_id)
		print("[GameManager] Vita3K: Updating to correct TitleID from ZIP")
	
	if active_title_id != zip_title_id:
		_store_title_id(game, zip_title_id)
		print("[GameManager] Vita3K: Updated database with TitleID: " + zip_title_id)
	else:
		if DEBUG_LOG: print("[GameManager] Vita3K: TitleID already matches, skipping DB update")
	
	var title_id = game.get_active_title_id()
	if DEBUG_LOG: print("[GameManager] Vita3K: Using TitleID: " + title_id)
	
	# Platform-specific Vita3K app path
	var vita_app_path: String
	if SystemManager.platform.is_android():
		vita_app_path = launch_manager.registry.get_app_data_path("vita3k") + "/vita/ux0/app/" + title_id
	else:
		# Desktop - use emulator directory (already obtained above)
		vita_app_path = emulator_dir + "/ux0/app/" + title_id
	
	if DEBUG_LOG: print("[GameManager] Vita3K: Checking extracted files at: " + vita_app_path)
	
	# Check if already extracted by looking for actual game files, not just directory existence
	var is_extracted = _vita_app_has_game_files(vita_app_path)
	if DEBUG_LOG: print("[GameManager] Vita3K: has_game_files = " + str(is_extracted))
	if is_extracted:
		_ensure_vita3k_license(rom_path, emulator_dir, title_id)
		return true
	
	# Extract ZIP to Vita3K ux0/app directory (ZIP contains the TitleID folder)
	# We extract to the parent directory (ux0/app) so the ZIP's root folder lands correctly
	var extract_parent = vita_app_path.get_base_dir()
	
	# Show persistent pulsing notification during extraction
	var notify_id = SystemManager.notifications.show_notification(
		"Extracting " + game.get_display_name() + "...",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,  # Never auto-dismiss
		Callable(),
		Callable(),
		true,  # Pulsing
		true  # pinned
	)
	if DEBUG_LOG: print("[GameManager] Vita3K: Extracting ZIP to: " + extract_parent)
	
	var extract_success = await _extract_vita_zip(rom_path, extract_parent, title_id)
	
	# Dismiss the extraction notification
	SystemManager.notifications.dismiss_notification(notify_id)
	
	if not extract_success:
		push_error("[GameManager] Vita3K: Failed to extract game to " + vita_app_path)
		return false
	
	print("[GameManager] Vita3K: Extraction successful")

	_ensure_vita3k_license(rom_path, emulator_dir, title_id)
	
	# Mark shuffler-managed app folders so they can be safely cleaned up later.
	if is_shuffler:
		var sentinel_path = vita_app_path + "/.kyodai_shuffler"
		if not FSM.file_exists(sentinel_path):
			if FSM.write_file(sentinel_path, ""):
				if DEBUG_LOG: print("[GameManager] Vita3K: Created shuffler sentinel at " + sentinel_path)
			else:
				push_warning("[GameManager] Vita3K: Failed to create shuffler sentinel at " + sentinel_path)
	
	if DEBUG_LOG: print("[GameManager] _prepare_vita3k_game: EXIT with true")
	return true

## Checks whether the given Vita3K app path contains actual game files
func _vita_app_has_game_files(vita_app_path: String) -> bool:
	# Use SystemManager.filesystem to list files
	var files = FSM.list_dir(vita_app_path)
	# Filter out . and .. entries - they don't count as game files
	var actual_files = 0
	for f in files:
		if f != "." and f != "..":
			actual_files += 1
	if DEBUG_LOG: print("[GameManager] Vita3K: _vita_app_has_game_files: found " + str(actual_files) + " actual files in " + vita_app_path)
	return actual_files > 0

## Extracts Vita game ZIP with progress tracking
func _extract_vita_zip(zip_path: String, extract_to: String, title_id: String) -> bool:
	if DEBUG_LOG: print("[GameManager] _extract_vita_zip: ENTER zip_path=" + zip_path + ", extract_to=" + extract_to)
	
	var parent_dir = extract_to.get_base_dir()
	if DEBUG_LOG: print("[GameManager] Vita3K: Creating parent directory: " + parent_dir)
	if not FSM.make_dir_recursive(parent_dir):
		push_error("[GameManager] Failed to create Vita3K app directory: " + parent_dir)
		if DEBUG_LOG: print("[GameManager] _extract_vita_zip: EXIT false (mkdir failed)")
		return false
	
	# Use SystemManager.download's extraction for progress tracking.
	if DEBUG_LOG: print("[GameManager] Vita3K: Queueing extraction via SystemManager.download")
	var item_id = SystemManager.download.queue_extraction(zip_path, extract_to, "vita_game", title_id, false)
	if item_id == "":
		push_error("[GameManager] Failed to queue Vita game extraction")
		if DEBUG_LOG: print("[GameManager] _extract_vita_zip: EXIT false (queue failed)")
		return false
	if DEBUG_LOG: print("[GameManager] Vita3K: Extraction queued with item_id=" + item_id)
	
	# Use Dictionary for thread-safe state tracking (reference type)
	var future = {"complete": false, "success": false, "message": ""}
	
	var on_complete = func(completed_item_id: String, success: bool, message: String):
		if completed_item_id == item_id:
			future.complete = true
			future.success = success
			future.message = message
			if DEBUG_LOG: print("[GameManager] Vita3K: Extraction callback received - success=" + str(success) + ", message=" + message)
	
	SystemManager.download.extraction_completed.connect(on_complete)
	
	# Wait for completion (with timeout)
	var timeout = 300.0  # 5 minutes timeout
	var elapsed = 0.0
	if DEBUG_LOG: print("[GameManager] _extract_vita_zip: Starting poll loop")
	while not future.complete and elapsed < timeout:
		await get_tree().process_frame
		elapsed += get_process_delta_time()
	
	SystemManager.download.extraction_completed.disconnect(on_complete)
	
	if not future.complete:
		push_error("[GameManager] Vita game extraction timed out")
		if DEBUG_LOG: print("[GameManager] _extract_vita_zip: EXIT false (timeout)")
		return false
	
	if DEBUG_LOG: print("[GameManager] _extract_vita_zip: EXIT " + str(future.success))
	return future.success


## Ensures Vita3K has a license rif for the given title under ux0/license/<title_id>.
## Converted game zips carry the rif inside the title folder (<title_id>/<content_id>.rif);
## after extraction it sits in ux0/app/<title_id>/, so move it where Vita3K looks for it.
## If no rif is found on disk (game extracted before license injection), pull just the
## rif entries from the source zip via ZIPReader without re-extracting the whole archive.
func _ensure_vita3k_license(rom_path: String, emulator_dir: String, title_id: String) -> void:
	var license_dir = emulator_dir + "/ux0/license/" + title_id

	if FSM.dir_exists(license_dir):
		for f in FSM.list_dir(license_dir):
			if f.to_lower().ends_with(".rif"):
				return

	var vita_app_path = emulator_dir + "/ux0/app/" + title_id

	var moved := false
	if FSM.dir_exists(vita_app_path):
		for f in FSM.list_dir(vita_app_path):
			if f != "." and f != ".." and f.to_lower().ends_with(".rif"):
				var src = vita_app_path + "/" + f
				var dst = license_dir + "/" + f
				if FSM.move(src, dst):
					if DEBUG_LOG: print("[GameManager] Vita3K: Installed license " + f + " -> " + license_dir)
					moved = true
				else:
					push_warning("[GameManager] Vita3K: Failed to move license file: " + src)

	if moved:
		return

	var zip_path = TitleIDParser._resolve_zip_path(rom_path)
	if zip_path == "":
		return

	var zr := ZIPReader.new()
	if zr.open(zip_path) != OK:
		return

	for entry in zr.get_files():
		var parts = entry.rstrip("/").split("/")
		if parts.size() == 2 and parts[0] == title_id and entry.to_lower().ends_with(".rif"):
			var dst = license_dir + "/" + parts[1]
			if FSM.make_dir_recursive(license_dir) and FSM.write_file_bytes(dst, zr.read_file(entry)):
				if DEBUG_LOG: print("[GameManager] Vita3K: Installed license from zip: " + dst)
			else:
				push_warning("[GameManager] Vita3K: Failed to write license file: " + dst)

	zr.close()


## Checks whether the given RPCS3 game path contains actual game files
func _rpcs3_game_has_files(game_path: String) -> bool:
	if not FSM.dir_exists(game_path):
		return false
	var files = FSM.list_dir(game_path)
	var actual_files = 0
	for f in files:
		if f != "." and f != "..":
			actual_files += 1
	if DEBUG_LOG: print("[GameManager] RPCS3: _rpcs3_game_has_files: found " + str(actual_files) + " actual files in " + game_path)
	return actual_files > 0


## Prepares a PS3 game for launch by extracting ZIP to a folder next to the ZIP
## The extracted folder path is passed to aPS3e via the game_dir intent extra
## Works on both desktop and Android
func _prepare_rpcs3_game(game: GameResource, intent: LaunchIntent, is_shuffler: bool = false) -> bool:
	if DEBUG_LOG: print("[GameManager] RPCS3: _prepare_rpcs3_game called for: " + game.get_display_name())
	
	if not game or not intent:
		print("[GameManager] RPCS3: ERROR - game or intent is null")
		return false
	
	var rom_path := intent.rom_path if intent.rom_path != "" else game.file_path
	if DEBUG_LOG: print("[GameManager] RPCS3: ROM path: " + rom_path)
	
	if rom_path == "":
		push_error("[GameManager] RPCS3: No ROM path for game: " + game.get_display_name())
		return false
	
	# Handle case where game.file_path points to previously-extracted folder
	# (from older versions or if user deleted files and we need to re-extract)
	var zip_path := rom_path
	
	if FSM.dir_exists(rom_path):
		# This might be an extracted folder. Check if it has actual game files.
		if _ps3_game_has_files(rom_path):
			if DEBUG_LOG: print("[GameManager] RPCS3: ROM path is extracted folder with valid game files")

			# Flatten legacy wrapper layouts ("Game Name/PS3_GAME/") left by
			# older extractions; RPCS3 only boots the folder that directly
			# contains PS3_GAME/PARAM.SFO.
			_unwrap_ps3_wrapper(rom_path)

			# First, try to get TitleID from existing PARAM.SFO in the extracted folder
			# This is more reliable than searching for ZIPs when multiple games share a folder
			var existing_sfo_path = FSM.find_file_recursive(rom_path, "PARAM.SFO")
			if existing_sfo_path != "":
				var sfo_bytes = FSM.read_file_bytes(existing_sfo_path)
				if not sfo_bytes.is_empty():
					var title_id_from_sfo = TitleIDParser.get_title_id_from_sfo_bytes(sfo_bytes)
					if title_id_from_sfo != "":
						if DEBUG_LOG: print("[GameManager] RPCS3: Got TitleID from PARAM.SFO: " + title_id_from_sfo)
						
						# Verify this matches the folder name or update if needed
						var folder_name = rom_path.get_file()
						if folder_name != title_id_from_sfo and folder_name.to_upper() == folder_name:
							# Folder is named after TitleID, all good
							pass
						
						# Update intent and game file_path
						intent.rom_path = rom_path
						if not is_shuffler:
							_store_file_path(game, rom_path)
						
						# Also update title_id if it's different
						if game.get_active_title_id() != title_id_from_sfo:
							_store_title_id(game, title_id_from_sfo)
						
						return true
			
			# Fallback: find the original ZIP
			# This handles cases where we can't read PARAM.SFO
			if DEBUG_LOG: print("[GameManager] RPCS3: Could not get TitleID from PARAM.SFO, searching for ZIP...")
			
			# The extracted folder may live in emulator-managed storage (desktop
			# install dir or Android app-data anchor) while the ZIP stays in the
			# games library. Check both.
			var search_dirs = [rom_path.get_base_dir()]
			var root_folder = DataManager.get_setting("games_root_folder")
			var root_path = root_folder.value if root_folder else "user://roms/"
			var library_dir = FSM.join_paths(root_path, game.platform_slug)
			if library_dir != search_dirs[0]:
				search_dirs.append(library_dir)
			
			var all_zip_files: Array[String] = []
			for search_dir in search_dirs:
				var zip_files = _find_zip_files_in_dir(search_dir)
				for zf in zip_files:
					if not zf in all_zip_files:
						all_zip_files.append(zf)
			
			# Try to find the ZIP that matches this game by name
			var game_name = game.get_display_name().to_lower()
			var matching_zip = ""
			for zf in all_zip_files:
				if zf.to_lower().contains(game_name) or game_name.contains(zf.get_file().get_basename().to_lower()):
					matching_zip = zf
					break
			
			if matching_zip != "":
				zip_path = matching_zip
				if DEBUG_LOG: print("[GameManager] RPCS3: Found matching ZIP by game name: " + zip_path)
			elif all_zip_files.size() > 0:
				# Fallback to first ZIP (old behavior, but warn about it)
				zip_path = all_zip_files[0]
				push_warning("[GameManager] RPCS3: Multiple ZIPs found, using first one: " + zip_path + " for game: " + game.get_display_name())
			else:
				push_error("[GameManager] RPCS3: No ZIP found to verify TitleID")
				SystemManager.notifications.show_notification("Game files missing - please re-download", SystemManager.notifications.Type.ERROR)
				return false
		else:
			# Directory exists but is empty - files were deleted. Look for ZIP.
			if DEBUG_LOG: print("[GameManager] RPCS3: Extracted folder is empty, looking for original ZIP...")
			zip_path = ""
			var parent_dir = rom_path.get_base_dir()
			var zip_files = _find_zip_files_in_dir(parent_dir)
			if zip_files.size() > 0:
				zip_path = zip_files[0]
				if DEBUG_LOG: print("[GameManager] RPCS3: Found original ZIP in parent dir: " + zip_path)
			else:
				# The extracted folder may live in emulator-managed storage while
				# the ZIP is in the games library. Check the library folder.
				var root_folder = DataManager.get_setting("games_root_folder")
				var root_path = root_folder.value if root_folder else "user://roms/"
				var library_dir = FSM.join_paths(root_path, game.platform_slug)
				if DEBUG_LOG: print("[GameManager] RPCS3: Checking games library: " + library_dir)
				zip_files = _find_zip_files_in_dir(library_dir)
				if zip_files.size() > 0:
					zip_path = zip_files[0]
					if DEBUG_LOG: print("[GameManager] RPCS3: Found original ZIP in library: " + zip_path)

				if zip_path == "":
					push_error("[GameManager] RPCS3: No ZIP found to re-extract in: " + parent_dir)
					SystemManager.notifications.show_notification("Game files missing - please re-download", SystemManager.notifications.Type.ERROR)
					return false
	elif not FSM.file_exists(rom_path):
		# Path doesn't exist at all (deleted extracted folder). Look for ZIP in parent.
		if DEBUG_LOG: print("[GameManager] RPCS3: ROM path does not exist, looking for original ZIP...")
		zip_path = ""
		
		# First try the parent directory of the deleted folder
		var parent_dir = rom_path.get_base_dir()
		var zip_files = _find_zip_files_in_dir(parent_dir)
		if zip_files.size() > 0:
			zip_path = zip_files[0]
			if DEBUG_LOG: print("[GameManager] RPCS3: Found original ZIP in parent dir: " + zip_path)
		else:
			# The extracted folder may live in emulator-managed storage while
			# the ZIP is in the games library. Check the library folder.
			var root_folder = DataManager.get_setting("games_root_folder")
			var root_path = root_folder.value if root_folder else "user://roms/"
			var library_dir = FSM.join_paths(root_path, game.platform_slug)
			if DEBUG_LOG: print("[GameManager] RPCS3: Checking games library: " + library_dir)
			zip_files = _find_zip_files_in_dir(library_dir)
			if zip_files.size() > 0:
				zip_path = zip_files[0]
				if DEBUG_LOG: print("[GameManager] RPCS3: Found original ZIP in library: " + zip_path)

			if zip_path == "":
				push_error("[GameManager] RPCS3: No ZIP found to re-extract in: " + parent_dir)
				SystemManager.notifications.show_notification("Game files missing - please re-download", SystemManager.notifications.Type.ERROR)
				return false
	
	# Step 1: Extract TitleID from ZIP
	if DEBUG_LOG: print("[GameManager] RPCS3: Extracting TitleID from ZIP: " + zip_path)
	var zip_title_id = TitleIDParser.extract_ps3_title_id(zip_path)
	if zip_title_id == "":
		push_error("[GameManager] RPCS3: Failed to extract TitleID from: " + zip_path)
		SystemManager.notifications.show_notification("Failed to extract PS3 game TitleID", SystemManager.notifications.Type.ERROR)
		return false
	if DEBUG_LOG: print("[GameManager] RPCS3: TitleID from ZIP: " + zip_title_id)
	
	# If stored title_id doesn't match the ZIP, update it
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != zip_title_id:
		print("[GameManager] RPCS3: WARNING - Stored TitleID " + active_title_id + " doesn't match ZIP TitleID " + zip_title_id)
		print("[GameManager] RPCS3: Updating to correct TitleID from ZIP")
	
	if active_title_id != zip_title_id:
		_store_title_id(game, zip_title_id)
		print("[GameManager] RPCS3: Updated database with TitleID: " + zip_title_id)
	
	var title_id = game.get_active_title_id()
	if DEBUG_LOG: print("[GameManager] RPCS3: Using TitleID: " + title_id)
	
	# Determine the emulator-managed game locations, where the emulator's own
	# library scans: desktop RPCS3 uses the managed install dir; Android
	# rpcs3-architecture emulators (armsx3, aps3e) use the declared resolution
	# anchor (the app-data config root), which kyodai can write with all-files
	# access. Extracting there gives Android parity with desktop (disc games in
	# games/, digital in dev_hdd0/game/) and satisfies prepared-install
	# detection (firmware + a visible game) so the emulator's OOBE is skipped.
	var emu_disc_path := ""
	var emu_digital_path := ""
	if not SystemManager.platform.is_android():
		var emulator_install_path = launch_manager.registry.get_emulator_install_path(intent.emulator_id)
		if emulator_install_path != "":
			# Managed emulator directory, not the exe's parent: extracted
			# AppImages nest the exe inside the update-wiped squashfs-root/.
			var rpcs3_install_dir = launch_manager.registry._get_emulator_directory(intent.emulator_id).rstrip("/")
			emu_disc_path = FSM.join_paths(rpcs3_install_dir, "games", title_id)
			emu_digital_path = FSM.join_paths(rpcs3_install_dir, "dev_hdd0", "game", title_id)
	else:
		var anchor_raw := str(launch_manager.registry.get_emulator(intent.emulator_id).get("resolution", {}).get("anchor", ""))
		if anchor_raw != "":
			var anchor := FSM.resolve_emulator_path(anchor_raw, intent.emulator_id, game.platform_slug).rstrip("/")
			if anchor != "":
				emu_disc_path = FSM.join_paths(anchor, "games", title_id)
				emu_digital_path = FSM.join_paths(anchor, "dev_hdd0", "game", title_id)
	var to_emu_dir := emu_disc_path != ""
	if DEBUG_LOG and to_emu_dir:
		print("[GameManager] RPCS3: Emulator disc path: " + emu_disc_path)
		print("[GameManager] RPCS3: Emulator digital path: " + emu_digital_path)
	
	# Step 2: Determine final extraction path (next to the ZIP)
	var rom_parent_dir = zip_path.get_base_dir()
	var extract_path = FSM.join_paths(rom_parent_dir, title_id)
	if DEBUG_LOG: print("[GameManager] RPCS3: Extraction path: " + extract_path)
	
	# Step 3: Check if already extracted
	# Check the emulator-managed locations first (desktop install dir or the
	# Android resolution anchor), then the legacy library-adjacent folder.
	if to_emu_dir:
		if _ps3_game_has_files(emu_disc_path):
			if DEBUG_LOG: print("[GameManager] RPCS3: Game already extracted at disc path: " + emu_disc_path)
			_unwrap_ps3_wrapper(emu_disc_path)
			intent.rom_path = emu_disc_path
			if not is_shuffler:
				_store_file_path(game, emu_disc_path)
			return true
		elif _ps3_game_has_files(emu_digital_path):
			if DEBUG_LOG: print("[GameManager] RPCS3: Game already extracted at digital path: " + emu_digital_path)
			_unwrap_ps3_wrapper(emu_digital_path)
			intent.rom_path = emu_digital_path
			if not is_shuffler:
				_store_file_path(game, emu_digital_path)
			return true
	
	if _ps3_game_has_files(extract_path):
		if DEBUG_LOG: print("[GameManager] RPCS3: Game already extracted at: " + extract_path)
		_unwrap_ps3_wrapper(extract_path)
		# Update intent to point to extracted folder
		intent.rom_path = extract_path
		if DEBUG_LOG: print("[GameManager] RPCS3: Calling _store_file_path with extract_path=" + extract_path)
		if not is_shuffler:
			_store_file_path(game, extract_path)
		if DEBUG_LOG: print("[GameManager] RPCS3: After _store_file_path, game.file_path=" + game.file_path)
		return true
	
	if DEBUG_LOG: print("[GameManager] RPCS3: Game not extracted, will extract to: " + extract_path)
	
	# Step 4: Extract ZIP
	var rpcs3_notify_id = SystemManager.notifications.show_notification(
		"Extracting " + game.get_display_name() + "...",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true,  # pulsing
		true  # pinned
	)
	
	# Determine extraction target
	var extract_target: String
	if to_emu_dir:
		# Extract directly into the emulator's games dir. We default to the
		# disc path; if the game is digital format it's relocated after
		# extraction.
		extract_target = emu_disc_path
		if DEBUG_LOG: print("[GameManager] RPCS3: Extracting directly to: " + extract_target)
	else:
		# No emulator-managed location (e.g. unmanaged desktop install):
		# extract to temp first (same drive, no permission issues)
		extract_target = extract_path + "_tmp"
		if DEBUG_LOG: print("[GameManager] RPCS3: Extracting to temp: " + extract_target)
	
	# Remove stale/partial game folders so re-extraction starts clean and the
	# unwrap/move steps don't collide with leftover files (e.g. a PARAM.SFO left
	# behind after the user deleted the rest of the game).
	if to_emu_dir:
		for stale_path in [emu_disc_path, emu_digital_path]:
			if FSM.dir_exists(stale_path):
				if DEBUG_LOG: print("[GameManager] RPCS3: Removing stale game folder: " + stale_path)
				FSM.delete_dir_recursive(stale_path)
	elif FSM.dir_exists(extract_path):
		if DEBUG_LOG: print("[GameManager] RPCS3: Removing stale game folder: " + extract_path)
		FSM.delete_dir_recursive(extract_path)
	
	var extract_success := await _extract_ps3_zip(zip_path, extract_target)
	
	# Dismiss the extraction notification
	SystemManager.notifications.dismiss_notification(rpcs3_notify_id)
	
	print("[GameManager] RPCS3: Extraction returned: " + str(extract_success))
	
	if not extract_success:
		push_error("[GameManager] RPCS3: Failed to extract PS3 game ZIP: " + zip_path)
		return false
	
	# Step 5: Find PARAM.SFO and determine format
	var sfo_path = _find_ps3_param_sfo(extract_target)
	
	if sfo_path == "":
		push_error("[GameManager] RPCS3: PARAM.SFO not found after extraction at: " + extract_target)
		FSM.delete_dir_recursive(extract_target)
		return false
	
	print("[GameManager] RPCS3: Found PARAM.SFO at: " + sfo_path)
	var sfo_dir = sfo_path.get_base_dir()
	
	# Determine if disc or digital format
	var is_disc_format = sfo_dir.get_file().to_upper() == "PS3_GAME"
	if DEBUG_LOG: print("[GameManager] RPCS3: Format detected: " + ("disc" if is_disc_format else "digital"))
	
	# Determine final path
	var final_extract_path = extract_path
	if to_emu_dir:
		final_extract_path = emu_disc_path if is_disc_format else emu_digital_path
		if DEBUG_LOG: print("[GameManager] RPCS3: Emulator-managed final path: " + final_extract_path)
	
	# Step 6: Handle wrapper folder (e.g., "Soulcalibur IV/PS3_GAME/" -> "PS3_GAME/")
	var game_root = sfo_dir.get_base_dir() if is_disc_format else sfo_dir
	if to_emu_dir and game_root != final_extract_path:
		if DEBUG_LOG: print("[GameManager] RPCS3: Wrapper folder detected: " + game_root.get_file())
		if DEBUG_LOG: print("[GameManager] RPCS3: Unwrapping to: " + final_extract_path)
		if not _unwrap_ps3_wrapper(final_extract_path):
			return false
	elif not to_emu_dir:
		# Fallback: move from temp to final
		if DEBUG_LOG: print("[GameManager] RPCS3: Moving game files from " + game_root + " to " + final_extract_path)
		if not FSM.move_dir_contents(game_root, final_extract_path):
			push_error("[GameManager] RPCS3: Failed to move game files to " + final_extract_path)
			FSM.delete_dir_recursive(extract_target)
			return false
		FSM.delete_dir_recursive(extract_target)
	
	# Remove any leftover empty wrapper shells of arbitrary depth
	# (e.g. "Game Name/" left behind after unwrapping "Game Name/PS3_GAME/")
	FSM.prune_empty_dirs(final_extract_path)
	if to_emu_dir and extract_target != final_extract_path:
		# Digital games stage into the disc path first; drop the empty staging shell
		FSM.prune_empty_dirs(extract_target)
		if FSM.dir_exists(extract_target) and FSM.list_dir(extract_target).is_empty():
			FSM.delete_dir_recursive(extract_target)
	
	# Step 7: Verify extracted files
	if not _ps3_game_has_files(final_extract_path):
		push_error("[GameManager] RPCS3: Game files missing after extraction at: " + final_extract_path)
		SystemManager.notifications.show_notification("Failed to install PS3 game - files missing", SystemManager.notifications.Type.ERROR)
		return false
	
	# Step 8: Update intent to point to extracted folder
	intent.rom_path = final_extract_path
	
	# Also update game.file_path so create_launch_intent() picks up the extracted folder,
	# but only persist it outside of shuffler sessions.
	if not is_shuffler:
		_store_file_path(game, final_extract_path)
		print("[GameManager] RPCS3: Updated game.file_path to: " + final_extract_path)

	# Mark shuffler-managed installs so session cleanup can safely delete them —
	# they land in emulator-managed storage (desktop install dir or the Android
	# app-data anchor), which TEMP_DIR cleanup never touches. Pre-existing
	# installs get no sentinel and are kept.
	if is_shuffler and to_emu_dir:
		var sentinel_path = final_extract_path + "/.kyodai_shuffler"
		if not FSM.file_exists(sentinel_path):
			if not FSM.write_file(sentinel_path, ""):
				push_warning("[GameManager] RPCS3: Failed to create shuffler sentinel at " + sentinel_path)

	print("[GameManager] RPCS3: Game extracted successfully at: " + final_extract_path)
	return true


## Finds the game PARAM.SFO, preferring the disc layout (PS3_GAME/PARAM.SFO).
## Repacks often contain extra PARAM.SFO files (update data, loose copies) whose
## parent isn't PS3_GAME; a first-match search would misclassify disc games as
## digital. The PARAM.SFO inside PS3_GAME is the authoritative disc marker.
func _find_ps3_param_sfo(root: String) -> String:
	var all = FSM.find_files_recursive(root, "PARAM.SFO")
	all.append_array(FSM.find_files_recursive(root, "PARAM.sfo"))
	for p in all:
		if p.get_base_dir().get_file().to_upper() == "PS3_GAME":
			return p
	return all[0] if all.size() > 0 else ""


## Checks if a PS3 game directory has a valid game structure
## Validates by looking for PARAM.SFO, which is required for both disc and HDD formats
func _ps3_game_has_files(game_path: String) -> bool:
	if not FSM.dir_exists(game_path):
		return false
	
	# Look for PARAM.SFO - the definitive marker of a valid PS3 game
	var sfo_path = FSM.find_file_recursive(game_path, "PARAM.SFO")
	if sfo_path == "":
		# Try lowercase fallback
		sfo_path = FSM.find_file_recursive(game_path, "PARAM.sfo")
	
	if sfo_path == "":
		if DEBUG_LOG: print("[GameManager] RPCS3: _ps3_game_has_files: PARAM.SFO not found in " + game_path)
		return false
	# PARAM.SFO alone isn't enough - a partially deleted game folder still has it.
	# Require the main executable (USRDIR/EBOOT.BIN, a sibling of PARAM.SFO in both
	# disc and digital layouts) so broken folders trigger re-extraction.
	var usrdir = FSM.join_paths(sfo_path.get_base_dir(), "USRDIR")
	var has_eboot = FSM.file_exists(FSM.join_paths(usrdir, "EBOOT.BIN")) or FSM.file_exists(FSM.join_paths(usrdir, "eboot.bin"))
	if DEBUG_LOG: print("[GameManager] RPCS3: _ps3_game_has_files: PARAM.SFO found, EBOOT.BIN present=" + str(has_eboot) + " in " + game_path)
	return has_eboot


## Flattens a leftover wrapper folder inside an extracted PS3 game folder,
## moving the game contents up to folder_path. Covers both layouts:
##   disc:    <folder>/<Game Name>/PS3_GAME/PARAM.SFO  -> <folder>/PS3_GAME/...
##   digital: <folder>/<Game Name>/PARAM.SFO          -> <folder>/PARAM.SFO
## No-op (returns true) when the layout is already flat. Older extractions can
## retain the wrapper; RPCS3 only boots the folder that directly contains
## PS3_GAME/PARAM.SFO, so a wrapped folder fails with "Nothing to boot".
func _unwrap_ps3_wrapper(folder_path: String) -> bool:
	if not FSM.dir_exists(folder_path):
		return false

	var sfo_path = FSM.find_file_recursive(folder_path, "PARAM.SFO")
	if sfo_path == "":
		sfo_path = FSM.find_file_recursive(folder_path, "PARAM.sfo")
	if sfo_path == "":
		return false

	var sfo_dir := sfo_path.get_base_dir()
	var is_disc := sfo_dir.get_file().to_upper() == "PS3_GAME"
	var game_root := sfo_dir.get_base_dir() if is_disc else sfo_dir
	if game_root == folder_path:
		return true

	print("[GameManager] RPCS3: Wrapper folder detected in existing install: " + game_root.get_file() + ", unwrapping to: " + folder_path)
	var items = FSM.list_dir(game_root)
	for item in items:
		if item == "." or item == "..":
			continue
		var source = FSM.join_paths(game_root, item)
		var dest = FSM.join_paths(folder_path, item)
		if not FSM.move(source, dest):
			push_error("[GameManager] RPCS3: Failed to unwrap: " + source + " -> " + dest)
			return false

	FSM.delete_dir_recursive(game_root)
	FSM.prune_empty_dirs(folder_path)
	return true


## Finds ZIP files in a directory (for re-extraction when extracted files are deleted)
func _find_zip_files_in_dir(dir_path: String) -> Array[String]:
	var result: Array[String] = []
	if not FSM.dir_exists(dir_path):
		return result
	
	var dir = DirAccess.open(dir_path)
	if not dir:
		return result
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if file_name != "." and file_name != "..":
			var full_path = FSM.join_paths(dir_path, file_name)
			if not FSM.is_dir(full_path) and file_name.to_lower().ends_with(".zip"):
				result.append(full_path)
		file_name = dir.get_next()
	
	if DEBUG_LOG: print("[GameManager] RPCS3: _find_zip_files_in_dir: found " + str(result.size()) + " ZIP files in " + dir_path)
	return result


## Extracts a PS3 game ZIP file to the specified directory
func _extract_ps3_zip(zip_path: String, extract_to: String) -> bool:
	if DEBUG_LOG: print("[GameManager] RPCS3: Extracting ZIP: " + zip_path + " to: " + extract_to)
	
	# Create extraction directory
	if not FSM.dir_exists(extract_to):
		FSM.make_dir_recursive(extract_to)
	
	# Use SystemManager.download's extraction functionality
	var item_id: String = SystemManager.download.queue_extraction(zip_path, extract_to, "ps3_game", "Extracting PS3 Game", false)
	
	if item_id == "":
		push_error("[GameManager] RPCS3: Failed to queue extraction")
		return false
	
	print("[GameManager] RPCS3: Waiting for extraction to complete...")
	return await _await_extraction(item_id, "GameManager] RPCS3")


## Prepares a PS4 game for launch by extracting the TitleID and extracting game files
## PS4 games are ZIP files containing a CUSAxxxxx directory at the root
## Returns true if preparation succeeded, false on error
func _prepare_shadps4_game(game: GameResource, intent: LaunchIntent) -> bool:
	if game.get_active_title_id() != "":
		return true
	if DEBUG_LOG: print("[GameManager] shadPS4: _prepare_shadps4_game called for: " + game.get_display_name())
	
	if not game or not intent:
		print("[GameManager] shadPS4: ERROR - game or intent is null")
		return false
	
	var rom_path := intent.rom_path if intent.rom_path != "" else game.file_path
	if DEBUG_LOG: print("[GameManager] shadPS4: ROM path: " + rom_path)
	
	if rom_path == "":
		push_error("[GameManager] shadPS4: No ROM path for game: " + game.get_display_name())
		return false
	
	# Step 1: Extract TitleID from ZIP
	if DEBUG_LOG: print("[GameManager] shadPS4: Extracting TitleID from ZIP...")
	var zip_title_id = TitleIDParser.extract_ps4_title_id(rom_path)
	if zip_title_id == "":
		push_error("[GameManager] shadPS4: Failed to extract TitleID from: " + rom_path)
		SystemManager.notifications.show_notification("Failed to extract PS4 game TitleID", SystemManager.notifications.Type.ERROR)
		return false
	if DEBUG_LOG: print("[GameManager] shadPS4: TitleID from ZIP: " + zip_title_id)
	
	# If stored title_id doesn't match the ZIP, update it
	var active_title_id = game.get_active_title_id()
	if active_title_id != "" and active_title_id != zip_title_id:
		print("[GameManager] shadPS4: WARNING - Stored TitleID " + active_title_id + " doesn't match ZIP TitleID " + zip_title_id)
		print("[GameManager] shadPS4: Updating to correct TitleID from ZIP")
	
	if active_title_id != zip_title_id:
		_store_title_id(game, zip_title_id)
		print("[GameManager] shadPS4: Updated database with TitleID: " + zip_title_id)
	
	var title_id = game.get_active_title_id()
	if DEBUG_LOG: print("[GameManager] shadPS4: Using TitleID: " + title_id)
	
	# Step 2: Determine extraction path (next to the ZIP in the ps4 roms folder)
	var rom_parent_dir = rom_path.get_base_dir()
	var extract_path = FSM.join_paths(rom_parent_dir, title_id)
	if DEBUG_LOG: print("[GameManager] shadPS4: Extraction path: " + extract_path)
	
	# Step 3: Check if already extracted
	if _shadps4_game_has_files(extract_path):
		if DEBUG_LOG: print("[GameManager] shadPS4: Game already extracted at: " + extract_path)
		return true
	
	if DEBUG_LOG: print("[GameManager] shadPS4: Game not extracted, will extract to: " + extract_path)
	
	# Step 4: Create extraction directory
	if not FSM.dir_exists(extract_path):
		if DEBUG_LOG: print("[GameManager] shadPS4: Creating extraction directory: " + extract_path)
		if not FSM.make_dir_recursive(extract_path):
			push_error("[GameManager] shadPS4: Failed to create extraction directory: " + extract_path)
			return false
	
	# Step 5: Extract ZIP to extraction path
	var shadps4_notify_id = SystemManager.notifications.show_notification(
		"Extracting " + game.get_display_name() + "...",
		SystemManager.notifications.Type.INFO,
		null,
		0.0,
		Callable(),
		Callable(),
		true,  # pulsing
		true  # pinned
	)
	if DEBUG_LOG: print("[GameManager] shadPS4: Extracting ZIP to: " + extract_path)
	
	var extract_success := await _extract_shadps4_zip(rom_path, extract_path)
	
	# Dismiss the extraction notification
	SystemManager.notifications.dismiss_notification(shadps4_notify_id)
	
	if DEBUG_LOG: print("[GameManager] shadPS4: _extract_shadps4_zip returned: " + str(extract_success))
	
	if not extract_success:
		push_error("[GameManager] shadPS4: Failed to extract PS4 game ZIP: " + rom_path)
		return false
	
	print("[GameManager] shadPS4: Extraction complete")
	
	return true


## Checks if a shadPS4 game directory has actual game files
func _shadps4_game_has_files(game_path: String) -> bool:
	if not FSM.dir_exists(game_path):
		return false
	
	var entries = FSM.list_dir(game_path)
	var actual_files = 0
	for entry in entries:
		if entry == "." or entry == "..":
			continue
		actual_files += 1
	
	if DEBUG_LOG: print("[GameManager] shadPS4: _shadps4_game_has_files: found " + str(actual_files) + " entries in " + game_path)
	return actual_files > 0


## Extracts a PS4 game ZIP file to the specified directory (NO TIMEOUT)
func _extract_shadps4_zip(zip_path: String, extract_to: String) -> bool:
	if DEBUG_LOG: print("[GameManager] shadPS4: Extracting ZIP: " + zip_path + " to: " + extract_to)
	
	# Use SystemManager.download's extraction functionality
	var item_id: String = SystemManager.download.queue_extraction(zip_path, extract_to, "ps4_game", "Extracting PS4 Game", false)
	
	if item_id == "":
		push_error("[GameManager] shadPS4: Failed to queue extraction")
		return false
	
	print("[GameManager] shadPS4: Waiting for extraction to complete...")
	return await _await_extraction(item_id, "GameManager] shadPS4")

## Cleans up extracted game files when a game is deleted
## Platforms that extract: PS3 (RPCS3), Vita (Vita3K)
func cleanup_extracted_game_files(game: GameResource) -> void:
	if not game:
		return
	# Extraction paths are keyed on the active variant's title id.
	var title_id := game.get_active_title_id()
	if title_id == "":
		title_id = game.title_id
	if title_id == "":
		return
	match game.platform_slug:
		"ps3":
			var emulator_path = launch_manager.registry.get_emulator_install_path("rpcs3")
			if emulator_path != "":
				# Managed emulator dir, not the exe's parent (squashfs-root-safe)
				var emulator_dir = launch_manager.registry._get_emulator_directory("rpcs3").rstrip("/")
				for sub_path in ["games", "dev_hdd0/game"]:
					var ps3_path = emulator_dir + "/" + sub_path + "/" + title_id
					if FSM.dir_exists(ps3_path):
						print("[GameManager] Cleaning up extracted PS3 game: " + ps3_path)
						FSM.delete_dir_recursive(ps3_path)
			# Android/legacy layouts extract next to the source zip and store
			# that folder in file_path. The name guard ensures a stale/wrong
			# file_path can only ever match this game's own extracted folder.
			if game.file_path != "" and game.file_path.get_file() == title_id and FSM.dir_exists(game.file_path):
				print("[GameManager] Cleaning up extracted PS3 game folder: " + game.file_path)
				FSM.delete_dir_recursive(game.file_path)
		"psvita":
			# Mirror _prepare_vita3k_game's path resolution: desktop extracts
			# under the managed emulator dir, Android under the app-data path.
			# Check both so layout drift never strands an install.
			var vita_bases: Array[String] = []
			var emulator_path = launch_manager.registry.get_emulator_install_path("vita3k")
			if emulator_path != "":
				# Managed emulator dir, not the exe's parent (squashfs-root-safe)
				vita_bases.append(launch_manager.registry._get_emulator_directory("vita3k").rstrip("/"))
			var app_data = launch_manager.registry.get_app_data_path("vita3k")
			if app_data != "":
				vita_bases.append(app_data.rstrip("/") + "/vita")
			for base in vita_bases:
				# ux0/app holds the extracted game; ux0/license holds the rif
				# moved there by _ensure_vita3k_license (derived content).
				for sub_path in ["ux0/app", "ux0/license"]:
					var vita_path = base + "/" + sub_path + "/" + title_id
					if FSM.dir_exists(vita_path):
						print("[GameManager] Cleaning up extracted Vita game data: " + vita_path)
						FSM.delete_dir_recursive(vita_path)
		"xbox360":
			# XBLA archives extract next to the source archive; file_path points at the folder
			if game.file_path != "" and FSM.dir_exists(game.file_path):
				print("[GameManager] Cleaning up extracted Xbox 360 game: " + game.file_path)
				FSM.delete_dir_recursive(game.file_path)
			# The extraction path is deterministic (<roms>/<platform>/<title_id>):
			# check it directly so shuffler-created extractions (which never
			# rewrite file_path) and legacy folders don't survive the delete.
			var root_folder = DataManager.get_setting("games_root_folder")
			var root_path: String = root_folder.value if root_folder else "user://roms/"
			var extracted_path = root_path + "/" + game.platform_slug + "/" + title_id
			if extracted_path != game.file_path and FSM.dir_exists(extracted_path):
				print("[GameManager] Cleaning up extracted Xbox 360 game folder: " + extracted_path)
				FSM.delete_dir_recursive(extracted_path)
