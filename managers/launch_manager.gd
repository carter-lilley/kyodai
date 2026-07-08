extends Manager

## Manages emulator registry, launch intents, and game execution (facade)

const FSM = preload("res://managers/filesystem_manager.gd")
const RegistryManager := preload("res://managers/launch/registry_manager.gd")
const EmulatorManager := preload("res://managers/launch/emulator_manager.gd")
const GameManager := preload("res://managers/launch/game_manager.gd")
const FirmwareManager := preload("res://managers/launch/firmware_manager.gd")
const LaunchIntentManager := preload("res://managers/launch/launch_intent_manager.gd")
const ProcessManager := preload("res://managers/launch/process_manager.gd")
const CoreManager := preload("res://managers/launch/core_manager.gd")

# Pending-launch orchestration state
# emulator_id -> {game: GameResource, callback: Callable}
var _pending_launches: Dictionary = {}

# platform_slug -> bool
var _pending_firmware_downloads: Dictionary = {}

# Array[Dictionary] supporting multiple pending launches for the same platform
# Each entry: {game: GameResource, emulator_id: String, callback: Callable}
var _pending_firmware_launches: Array[Dictionary] = []

# Tracks on-demand core downloads and the launches waiting on them.
# key: "platform_slug:core_id", value: true
var _pending_core_downloads: Dictionary = {}

# Each entry: {game: GameResource, platform_slug: String, core_id: String, callback: Callable}
var _pending_core_launches: Array[Dictionary] = []

# Signals
signal game_launched(game: GameResource)
signal game_launch_initiated(game: GameResource, focus_index: int)
signal launch_completed(success: bool, message: String)
signal background_state_entered(pid: int, game: GameResource)
signal background_state_exited(game: GameResource, exit_code: int)
signal emulator_registry_loaded(success: bool)
signal emulator_extraction_started(emulator_id: String)
signal emulator_extraction_completed(emulator_id: String, success: bool)
signal firmware_download_completed(platform_slug: String, success: bool)
signal core_download_completed(platform_slug: String, core_id: String, success: bool)

@onready var registry: RegistryManager = $RegistryManager
@onready var emulator: EmulatorManager = $EmulatorManager
@onready var game: GameManager = $GameManager
@onready var firmware: FirmwareManager = $FirmwareManager
@onready var intent: LaunchIntentManager = $LaunchIntentManager
@onready var process: ProcessManager = $ProcessManager
@onready var core: CoreManager = $CoreManager

func _ready():
	registry._load_registry()
	registry._ensure_emulators_directory()
	
	# Connect to DownloadManager signals
	DownloadManager.extraction_completed.connect(emulator._on_download_manager_extraction_completed)
	DownloadManager.download_completed.connect(emulator._on_unified_download_completed)
	
	# Forward CoreManager signal so UI only needs to listen to LaunchManager.
	core.core_download_completed.connect(_on_core_download_completed)
	
	# Scan existing installations to detect partial installs
	# Wait a frame to ensure everything is initialized
	await get_tree().process_frame

# ============================================================================
# Registry wrappers
# ============================================================================

func get_emulators_directory() -> String:
	return registry.get_emulators_directory()

func get_emulator(emulator_id: String) -> Dictionary:
	return registry.get_emulator(emulator_id)

func get_all_emulators() -> Array[Dictionary]:
	return registry.get_all_emulators()

func get_emulators_for_platform(platform_slug: String) -> Array[Dictionary]:
	return registry.get_emulators_for_platform(platform_slug)

func get_default_emulator_for_platform(platform_slug: String) -> String:
	return registry.get_default_emulator_for_platform(platform_slug)

func get_emulator_install_path(emulator_id: String) -> String:
	return registry.get_emulator_install_path(emulator_id)

func _get_emulator_directory(emulator_id: String) -> String:
	return registry._get_emulator_directory(emulator_id)

func get_core_for_platform(emulator_id: String, platform_slug: String, core_id: String = "") -> String:
	return registry.get_core_for_platform(emulator_id, platform_slug, core_id)

func resolve_core_for_game(game: GameResource) -> String:
	return intent.resolve_core_for_game(game)

func get_cores_for_platform(emulator_id: String, platform_slug: String) -> Array[Dictionary]:
	return registry.get_cores_for_platform(emulator_id, platform_slug)

func get_default_core_id_for_platform(emulator_id: String, platform_slug: String) -> String:
	return registry.get_default_core_id_for_platform(emulator_id, platform_slug)

func get_core_config(emulator_id: String, platform_slug: String, core_id: String) -> Dictionary:
	return registry.get_core_config(emulator_id, platform_slug, core_id)

func get_app_data_path(emulator_id: String) -> String:
	return registry.get_app_data_path(emulator_id)

func get_retroarch_core_name(platform_slug: String) -> String:
	return registry.get_retroarch_core_name(platform_slug)

func check_for_updates(callback: Callable, progress_callback: Callable = Callable()):
	registry.check_for_updates(callback, progress_callback)

# ============================================================================
# Emulator install/update wrappers
# ============================================================================

func clear_validation_cache() -> void:
	emulator.clear_validation_cache()

func repair_emulator_config(emulator_id: String) -> bool:
	return emulator.repair_emulator_config(emulator_id)

func clear_stale_pending_launches() -> void:
	emulator.clear_stale_pending_launches()

func get_emulator_install_progress(emulator_id: String) -> String:
	return emulator.get_emulator_install_progress(emulator_id)

func get_install_progress(emulator_id: String) -> Dictionary:
	return emulator.get_install_progress(emulator_id)

func is_emulator_install_progress_extracting(emulator_id: String) -> bool:
	return emulator.is_install_progress_extracting(emulator_id)

func is_emulator_extracting(emulator_id: String) -> bool:
	return emulator.is_emulator_extracting(emulator_id)

func download_emulator(emulator_id: String) -> bool:
	return emulator.download_emulator(emulator_id)

func edit_emulator_file(
	emulator_id: String,
	file_path: String,
	edits: Array,
	create_if_missing := false,
	append_if_missing: Dictionary = {},
	section_name: String = ""
) -> bool:
	return emulator.edit_emulator_file(emulator_id, file_path, edits, create_if_missing, append_if_missing, section_name)

func edit_emulator_file_with_backup(
	emulator_id: String,
	file_path: String,
	edits: Array,
	create_if_missing := false,
	append_if_missing: Dictionary = {},
	section_name: String = ""
) -> bool:
	return emulator.edit_emulator_file_with_backup(emulator_id, file_path, edits, create_if_missing, append_if_missing, section_name)

func restore_emulator_file(emulator_id: String, file_path: String) -> bool:
	return emulator.restore_emulator_file(emulator_id, file_path)

func scan_emulator_install_state(emulator_id: String):
	emulator.scan_emulator_install_state(emulator_id)

func is_emulator_downloading(emulator_id: String) -> bool:
	return emulator.is_emulator_downloading(emulator_id)

func is_emulator_queued(emulator_id: String) -> bool:
	return emulator.is_emulator_queued(emulator_id)

func get_emulator_active_download(emulator_id: String):
	return emulator.get_emulator_active_download(emulator_id)

# ============================================================================
# Game preparation wrappers
# ============================================================================

func cleanup_extracted_game_files(game: GameResource) -> void:
	$GameManager.cleanup_extracted_game_files(game)

# ============================================================================
# Firmware wrappers
# ============================================================================

func clear_firmware_cache(platform_slug: String, emulator_id: String, core_id: String = "") -> void:
	firmware.clear_firmware_cache(platform_slug, emulator_id, core_id)

func clear_all_firmware_cache() -> void:
	firmware.clear_all_firmware_cache()

func clear_firmware_cache_for_platform(platform_slug: String) -> void:
	firmware.clear_firmware_cache_for_platform(platform_slug)

func get_firmware_directory(emulator_id: String, platform_slug: String = "", core_id: String = "") -> String:
	return firmware.get_firmware_directory(emulator_id, platform_slug, core_id)

func is_platform_firmware_ready(platform_slug: String, emulator_id: String, core_id: String = "") -> bool:
	return firmware.is_platform_firmware_ready(platform_slug, emulator_id, core_id)

func get_platform_firmware_expected_files(platform_slug: String) -> Array:
	return firmware.get_platform_firmware_expected_files(platform_slug)

func setup_platform_firmware(platform_slug: String, emulator_id: String, callback: Callable = Callable(), core_id: String = "") -> void:
	firmware.setup_platform_firmware(platform_slug, emulator_id, callback, core_id)

# ============================================================================
# Launch intent wrappers
# ============================================================================

func resolve_emulator_for_game(game: GameResource) -> String:
	return intent.resolve_emulator_for_game(game)

func create_launch_intent(game: GameResource, rom_path_override: String = "") -> LaunchIntent:
	return intent.create_launch_intent(game, rom_path_override)

# ============================================================================
# Background state wrappers
# ============================================================================

func is_in_background_state() -> bool:
	return process.is_in_background_state()

func get_background_pid() -> int:
	return process.get_background_pid()

func get_background_game() -> GameResource:
	return process.get_background_game()

func force_exit_background_state() -> void:
	process.force_exit_background_state()

func kill_background_process() -> bool:
	return process.kill_background_process()

# ============================================================================
# Process execution wrappers
# ============================================================================

func execute_launch(intent: LaunchIntent) -> bool:
	return process.execute_launch(intent)

func _create_process_from_intent(intent: LaunchIntent) -> int:
	return process._create_process_from_intent(intent)

# ============================================================================
# Launch orchestration
# ============================================================================

# Tracks the most recent prepared ROM path for a shuffler game so callers can
# update their bag entry after pre-launch preparation.
var _last_prepared_rom_paths: Dictionary = {}  # game romm_id -> prepared path

## Launch a game for the shuffler (no save sync, no background state).
## Calls on_pid_ready(pid) when the process is created. PID may be -1 on failure.
## If a download is pending, the function returns immediately and on_pid_ready will be called later.
func launch_shuffler_game(game: GameResource, rom_path_override: String, on_pid_ready: Callable = Callable()) -> void:
	print("[LaunchManager] launch_shuffler_game() called for: ", game.get_display_name())
	
	var emulator_id = intent.resolve_emulator_for_game(game)
	if emulator_id == "":
		push_error("[LaunchManager] No emulator configured for platform: " + game.platform_slug)
		if on_pid_ready.is_valid():
			on_pid_ready.call(-1)
		return
	
	var on_ready = func():
		var prepared_rom_path = _last_prepared_rom_paths.get(game.romm_id, rom_path_override) as String
		var launch_intent = intent.create_launch_intent(game, prepared_rom_path)
		if not launch_intent:
			push_error("[LaunchManager] Failed to create launch intent")
			if on_pid_ready.is_valid():
				on_pid_ready.call(-1)
			return
		
		if PlatformManager.is_android():
			push_error("[LaunchManager] Shuffler not supported on Android")
			if on_pid_ready.is_valid():
				on_pid_ready.call(-1)
			return
		
		var pid = process._create_process_from_intent(launch_intent)
		if pid != -1:
			print("[LaunchManager] Shuffler launch successful, PID: ", pid)
		if on_pid_ready.is_valid():
			on_pid_ready.call(pid)
	
	# Vita3K and RPCS3 need TitleID extraction and ZIP extraction even in shuffler mode.
	# Other emulators skip the normal preparation step.
	var should_prepare = emulator_id.begins_with("vita3k") or emulator_id.begins_with("rpcs3")
	var ready = await _ensure_prerequisites(game, emulator_id, on_ready, should_prepare, true, rom_path_override)
	if not ready:
		return  # Download pending, callback will handle it
	# If ready, on_ready was already called


## Prepares a game for a shuffler session ahead of time. Returns true if the game
## is ready to launch. If preparation updates the ROM path (e.g. extracting a PS3
## ZIP to a folder), the new path can be retrieved with get_last_prepared_rom_path().
func prepare_game_for_shuffler(game: GameResource, emulator_id: String, rom_path_override: String) -> bool:
	var prep_success = await $GameManager._prepare_game_for_launch(game, emulator_id, true, rom_path_override)
	if prep_success:
		_last_prepared_rom_paths[game.romm_id] = $GameManager._last_prepared_rom_path
	return prep_success


func get_last_prepared_rom_path(game: GameResource) -> String:
	return _last_prepared_rom_paths.get(game.romm_id, "") as String


## Main entry point for launching a game
func launch_game(game: GameResource, focus_index: int = -1) -> void:
	print("[LaunchManager] launch_game() called for: ", game.get_display_name() if game else "null", " with focus_index: ", focus_index)
	
	# Emit signal immediately so focus can be saved before any suspension happens
	print("[LaunchManager] Emitting game_launch_initiated signal")
	game_launch_initiated.emit(game, focus_index)
	
	# Play launch sound
	if AudioManager:
		AudioManager.play_sfx("affirm_00")
	
	# Check if this is a GameNative game
	if game.source == "gamenative":
		_launch_gamenative_game(game)
		return
	
	# If game is not downloaded, queue the download first then proceed
	if not game.is_active_variant_downloaded():
		_queue_game_download_then_launch(game)
		return
	
	# Single ordered flow: emulator -> firmware -> prep -> saves -> launch
	_launch_with_emulator_check(game)

## Launch a GameNative game via intent
func _launch_gamenative_game(game: GameResource) -> void:
	if not PlatformManager.is_android():
		push_error("[LaunchManager] Cannot launch GameNative game on non-Android platform")
		NotificationManager.show_notification("GameNative games only available on Android", NotificationManager.Type.ERROR)
		return
	
	var success = GameNativeManager.launch_game(game.steam_app_id)
	if success:
		_update_last_played(game)
	else:
		push_error("[LaunchManager] Failed to launch GameNative game")
		NotificationManager.show_notification("Failed to launch GameNative. Is the app installed?", NotificationManager.Type.ERROR)

## If game is not downloaded, queue the download first then proceed
func _queue_game_download_then_launch(game: GameResource) -> void:
	var active_game_id = game.get_active_game_id()
	var active_file_name = game.get_active_file_name()
	
	var download_url = NetworkManager.get_romm_download_url(active_game_id, active_file_name)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		NotificationManager.show_notification("Error: Games folder not set", NotificationManager.Type.ERROR)
		return
	
	var destination_path = FSM.join_paths(root_folder.value, game.platform_slug, active_file_name)
	
	NotificationManager.show_notification("Downloading " + game.get_display_name() + "...", NotificationManager.Type.INFO)
	
	# Define callback for when download completes
	var on_download_complete = func(success: bool, _path: String):
		if success:
			var updated_game = DataManager.get_game_by_id(game.romm_id)
			var game_to_launch = updated_game if updated_game else game
			
			# Single ordered flow: emulator -> firmware -> prep -> saves -> launch
			_launch_with_emulator_check(game_to_launch)
		else:
			NotificationManager.show_notification("Download failed for " + game.get_display_name(), NotificationManager.Type.ERROR)
	
	# Queue download with callback to continue launch flow
	var item_id = DownloadManager.queue_download(
		download_url,
		destination_path,
		"game",
		game.get_display_name(),
		false,
		"",
		game,
		{"on_complete": on_download_complete},
		active_game_id
	)
	
	if item_id == "":
		NotificationManager.show_notification("Failed to queue download", NotificationManager.Type.ERROR)

## Ensures emulator is installed, firmware is ready, and game is prepared.
## Returns true if everything is ready and on_ready was called.
## Returns false if a download was started (caller should return and wait for callback).
func _ensure_prerequisites(game: GameResource, emulator_id: String, on_ready: Callable, prepare_game: bool = true, is_shuffler: bool = false, rom_path_override: String = "") -> bool:
	var emu = registry.get_emulator(emulator_id)
	var emulator_name = emu.get("name", emulator_id)
	
	# Check if emulator is fully installed
	var is_actually_installed = true
	var install_steps = emu.get("install", [])
	for i in range(install_steps.size()):
		if not emulator._validate_install_step(emulator_id, i, install_steps):
			is_actually_installed = false
			break
	
	# If emulator is now installed but there's a stale pending launch, clear it
	if is_actually_installed and _pending_launches.has(emulator_id):
		print("[LaunchManager] Emulator " + emulator_id + " is installed, clearing stale pending launch")
		_pending_launches.erase(emulator_id)
	
	# Check if this game is already pending launch
	if _pending_launches.has(emulator_id):
		var pending_data = _pending_launches[emulator_id]
		var pending_game: GameResource = pending_data.game
		if pending_game.romm_id == game.romm_id:
			NotificationManager.show_notification("Game already pending launch! Waiting for emulator installation...", NotificationManager.Type.WARNING)
			return false
	
	if not is_actually_installed:
		NotificationManager.show_notification("Setting up " + emulator_name + "...", NotificationManager.Type.INFO)
		
		if not emulator_extraction_completed.is_connected(_on_emulator_installed_for_launch):
			emulator_extraction_completed.connect(_on_emulator_installed_for_launch)
		
		_pending_launches[emulator_id] = {game = game, callback = on_ready}
		
		var download_success = emulator.download_emulator(emulator_id)
		
		if download_success:
			NotificationManager.show_notification(emulator_name + " downloading... Will auto-launch when ready.", NotificationManager.Type.INFO)
		else:
			NotificationManager.show_notification("Failed to queue " + emulator_name + " download", NotificationManager.Type.ERROR)
			_pending_launches.erase(emulator_id)
		return false
	
	# Emulator is installed - check if the selected RetroArch core is ready (Android only)
	if PlatformManager.is_android() and emulator_id == "retroarch":
		var core_id_for_launch: String = intent.resolve_core_for_game(game)
		if not core.is_core_ready(emulator_id, game.platform_slug, core_id_for_launch):
			var core_key: String = game.platform_slug + ":" + core_id_for_launch
			if _pending_core_downloads.has(core_key):
				print("[LaunchManager] Core download already in progress for " + core_key + ", will launch when ready")
				NotificationManager.show_notification("Core download in progress for " + game.platform_slug + "...", NotificationManager.Type.INFO)
				_pending_core_launches.append({"game": game, "platform_slug": game.platform_slug, "core_id": core_id_for_launch, "callback": on_ready})
				return false
			
			print("[LaunchManager] Core not ready for " + game.platform_slug + ", downloading...")
			NotificationManager.show_notification("Downloading core for " + game.platform_slug + "...", NotificationManager.Type.INFO)
			
			_pending_core_downloads[core_key] = true
			_pending_core_launches.append({"game": game, "platform_slug": game.platform_slug, "core_id": core_id_for_launch, "callback": on_ready})
			
			core.setup_platform_core(emulator_id, game.platform_slug, core_id_for_launch, func(_success: bool):
				# Completion is handled by _on_core_download_completed via CoreManager signal.
				# This lambda exists because setup_platform_core requires a callback.
				pass
			)
			return false
	
	# Emulator is installed - check firmware
	var core_id_for_firmware = ""
	if emulator_id == "retroarch":
		core_id_for_firmware = intent.resolve_core_for_game(game)
	
	if not firmware.is_platform_firmware_ready(game.platform_slug, emulator_id, core_id_for_firmware):
		if _pending_firmware_downloads.has(game.platform_slug):
			print("[LaunchManager] Firmware download already in progress for " + game.platform_slug + ", will launch when ready")
			NotificationManager.show_notification("Firmware download in progress for " + game.platform_slug + "...", NotificationManager.Type.INFO)
			_pending_firmware_launches.append({"game": game, "emulator_id": emulator_id, "core_id": core_id_for_firmware, "callback": on_ready})
			return false
		
		print("[LaunchManager] Firmware not ready for " + game.platform_slug + ", downloading...")
		NotificationManager.show_notification("Downloading firmware for " + game.platform_slug + "...", NotificationManager.Type.INFO)
		
		_pending_firmware_downloads[game.platform_slug] = true
		_pending_firmware_launches.append({"game": game, "emulator_id": emulator_id, "core_id": core_id_for_firmware, "callback": on_ready})
		
		firmware.setup_platform_firmware(game.platform_slug, emulator_id, func(success: bool, message: String):
			_pending_firmware_downloads.erase(game.platform_slug)
			
			var matching_indices: Array[int] = []
			for i in range(_pending_firmware_launches.size()):
				var pending = _pending_firmware_launches[i]
				if pending.get("emulator_id", "") == emulator_id and pending.get("core_id", "") == core_id_for_firmware:
					matching_indices.append(i)
			
			if matching_indices.is_empty():
				return
			
			if not success:
				push_error("[LaunchManager] Firmware download failed for " + game.platform_slug + ": " + message)
				NotificationManager.show_notification("Failed to download firmware for " + game.platform_slug, NotificationManager.Type.ERROR)
				for i in matching_indices:
					var pending = _pending_firmware_launches[i]
					var pending_callback = pending.callback
					if pending_callback.is_valid():
						pending_callback.call(false)
				for i in range(matching_indices.size() - 1, -1, -1):
					_pending_firmware_launches.remove_at(matching_indices[i])
				return
			
			print("[LaunchManager] Firmware ready for " + game.platform_slug + ", continuing launch...")
			for i in matching_indices:
				var pending = _pending_firmware_launches[i]
				var pending_callback = pending.callback
				if pending_callback.is_valid():
					pending_callback.call()
			for i in range(matching_indices.size() - 1, -1, -1):
				_pending_firmware_launches.remove_at(matching_indices[i])
		, core_id_for_firmware)
		
		return false
	
	if prepare_game:
		# Emulator and firmware are ready - prepare game
		print("[LaunchManager] _ensure_prerequisites: Preparing game for emulator: " + emulator_id)
		var prep_success = await $GameManager._prepare_game_for_launch(game, emulator_id, is_shuffler, rom_path_override)
		if not prep_success:
			push_error("[LaunchManager] Failed to prepare game for launch: " + game.get_display_name())
			NotificationManager.show_notification("Failed to prepare game for launch", NotificationManager.Type.ERROR)
			return false
		# Cache the prepared ROM path for shuffler launches so callers can update bag entries.
		if is_shuffler:
			_last_prepared_rom_paths[game.romm_id] = $GameManager._last_prepared_rom_path
		print("[LaunchManager] _ensure_prerequisites: Game preparation complete")
	else:
		print("[LaunchManager] _ensure_prerequisites: Skipping game preparation (shuffler session)")
	
	on_ready.call()
	return true

## Check emulator status and launch game (game must be downloaded)
func _launch_with_emulator_check(game: GameResource) -> void:
	print("[LaunchManager] _launch_with_emulator_check: ENTER for " + game.get_display_name())
	
	var emulator_id = intent.resolve_emulator_for_game(game)
	
	if emulator_id == "":
		NotificationManager.show_notification("No emulator configured for platform: " + game.platform_slug, NotificationManager.Type.ERROR)
		return
	
	var on_ready = func():
		# Sync saves then launch
		if emulator_id != "":
			print("[LaunchManager] Starting pre-launch save sync...")
			SaveManager.auto_download_saves_for_game(game, emulator_id, func():
				print("[LaunchManager] Pre-launch save sync complete, launching game...")
				_launch_game_internal(game, emulator_id)
			)
		else:
			_launch_game_internal(game, emulator_id)
		print("[LaunchManager] _launch_with_emulator_check: EXIT")
	
	var ready = await _ensure_prerequisites(game, emulator_id, on_ready)
	if not ready:
		return  # Download pending, callback will handle it
	# If ready, on_ready was already called

## Handler for when emulator extraction completes - retries pending launches
func _on_emulator_installed_for_launch(emulator_id: String, success: bool):
	if not success:
		return
	
	# Check if emulator is actually fully installed by validating all registry steps
	var emu = registry.get_emulator(emulator_id)
	if not emu.is_empty() and emu.has("install"):
		var install_steps = emu.get("install", [])
		var all_valid = true
		for i in range(install_steps.size()):
			if not emulator._validate_install_step(emulator_id, i, install_steps):
				all_valid = false
				break
		if not all_valid:
			# Post-install is still running, wait for it to complete
			return
	
	# Check if we have a pending launch for this emulator
	if _pending_launches.has(emulator_id):
		var pending = _pending_launches[emulator_id]
		var game: GameResource = pending.game
		var callback: Callable = pending.callback
		_pending_launches.erase(emulator_id)
		NotificationManager.show_notification("Launching " + game.get_display_name() + "...", NotificationManager.Type.INFO)
		
		# Give a small delay for file system to settle
		await get_tree().create_timer(0.5).timeout
		
		print("[LaunchManager] _on_emulator_installed_for_launch: Calling ready callback for emulator: " + emulator_id)
		if callback.is_valid():
			callback.call()

## Handler for on-demand core downloads - resumes pending launches
func _on_core_download_completed(platform_slug: String, core_id: String, success: bool):
	var core_key: String = platform_slug + ":" + core_id
	_pending_core_downloads.erase(core_key)
	
	var matching_indices: Array[int] = []
	for i in range(_pending_core_launches.size()):
		var pending = _pending_core_launches[i]
		if pending.get("platform_slug", "") == platform_slug and pending.get("core_id", "") == core_id:
			matching_indices.append(i)
	
	if matching_indices.is_empty():
		return
	
	if not success:
		push_error("[LaunchManager] Core download failed for " + core_key)
		NotificationManager.show_notification("Failed to download core for " + platform_slug, NotificationManager.Type.ERROR)
		for i in matching_indices:
			var pending = _pending_core_launches[i]
			var pending_callback = pending.callback
			if pending_callback.is_valid():
				pending_callback.call(false)
		for i in range(matching_indices.size() - 1, -1, -1):
			_pending_core_launches.remove_at(matching_indices[i])
		core_download_completed.emit(platform_slug, core_id, false)
		return
	
	print("[LaunchManager] Core ready for " + core_key + ", continuing launch...")
	core_download_completed.emit(platform_slug, core_id, true)
	for i in matching_indices:
		var pending = _pending_core_launches[i]
		var game: GameResource = pending.game as GameResource
		var pending_callback = pending.callback
		var pending_emulator_id: String = intent.resolve_emulator_for_game(game)
		await _ensure_prerequisites(game, pending_emulator_id, pending_callback)
	for i in range(matching_indices.size() - 1, -1, -1):
		_pending_core_launches.remove_at(matching_indices[i])

## Internal function to actually launch the game (emulator must be installed)
func _launch_game_internal(game: GameResource, emulator_id: String) -> void:
	print("[LaunchManager] _launch_game_internal: ENTER for " + game.get_display_name() + " (emulator: " + emulator_id + ")")
	
	var launch_intent = intent.create_launch_intent(game)
	
	if not launch_intent:
		push_error("[LaunchManager] _launch_game_internal: create_launch_intent returned null")
		NotificationManager.show_notification("Failed to create launch intent", NotificationManager.Type.ERROR)
		print("[LaunchManager] _launch_game_internal: EXIT (null intent)")
		return
	
	# Wait for launch transition overlay phase 1 to complete before opening game window
	# This ensures the user sees the card scale up before the game covers it
	if LaunchTransitionOverlay.is_transition_active:
		print("[LaunchManager] Waiting for launch transition overlay phase 1...")
		# Find the overlay instance to await its signal
		var overlay_nodes = get_tree().get_nodes_in_group("launch_transition_overlay")
		if overlay_nodes.size() > 0:
			var overlay = overlay_nodes[0] as LaunchTransitionOverlay
			if overlay:
				if overlay.is_phase1_complete():
					print("[LaunchManager] Overlay phase 1 already complete, proceeding")
				else:
					await overlay.phase1_completed
					print("[LaunchManager] Overlay phase 1 complete, proceeding with launch")
		else:
			# Fallback: wait for the expected duration
			await get_tree().create_timer(0.5).timeout
	
	print("[LaunchManager] _launch_game_internal: Launch intent created, executing launch...")
	var success = process.execute_launch(launch_intent)
	
	if not success:
		push_error("[LaunchManager] _launch_game_internal: execute_launch returned false")
		NotificationManager.show_notification("Failed to launch " + game.get_display_name(), NotificationManager.Type.ERROR)
		print("[LaunchManager] _launch_game_internal: EXIT (launch failed)")
		return
	
	print("[LaunchManager] _launch_game_internal: Launch successful")
	
	# Update last_played timestamp on successful launch
	_update_last_played(game)
	print("[LaunchManager] _launch_game_internal: EXIT (success)")

## Update the last_played timestamp for a game
func _update_last_played(game: GameResource) -> void:
	var timestamp = Time.get_datetime_string_from_system(false, true)  # UTC format
	game.last_played = timestamp
	
	# GameNative games are not stored in the database, so persist in settings instead.
	if game.source == "gamenative":
		GameNativeManager.update_last_played(game.steam_app_id, timestamp)
		return
	
	# Update in database
	DataManager.update_game_last_played(game.romm_id, timestamp)
	
	# Notify views that game was launched (so they can re-sort)
	game_launched.emit(game)
