extends Manager
class_name LaunchIntentSubManager

## GameResource -> LaunchIntent transformation

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

var launch_manager: Node

func _ready():
	launch_manager = get_parent()

## Resolves which emulator to use for a game
## Priority: 1. Game override, 2. Active shuffler override, 3. User platform setting, 4. Registry default
## Stored selections that are unavailable on the current OS fall through to the next priority
func resolve_emulator_for_game(game: GameResource) -> String:
	var registry = launch_manager.registry

	# 1. Check game override
	if game.preferred_emulator_id != "":
		var canonical = registry.canonicalize_emulator_id(game.preferred_emulator_id)
		if registry.is_emulator_available(canonical):
			return canonical

	# 2. Check active shuffler override
	if LaunchManager.is_shuffle_session_active():
		var override = LaunchManager.get_shuffle_override(game.platform_slug)
		if override.get("emulator_id", "") != "":
			var canonical = registry.canonicalize_emulator_id(override["emulator_id"])
			if registry.is_emulator_available(canonical):
				return canonical

	# 2b. Use shuffler-specific defaults if the platform has one configured
	if LaunchManager.is_shuffle_session_active():
		if LaunchManager.SHUFFLER_DEFAULT_EMULATORS.has(game.platform_slug):
			var shuffler_default = registry.canonicalize_emulator_id(LaunchManager.get_shuffler_default_emulator_for_platform(game.platform_slug))
			if registry.is_emulator_available(shuffler_default):
				return shuffler_default

	# 3. Check user platform settings (empty = use registry default)
	var enabled_platforms = _get_enabled_platforms()
	var platform_config = enabled_platforms.get(game.platform_slug, {})
	var platform_emulator = platform_config.get("emulator_id", "")

	if platform_emulator != "":
		var canonical = registry.canonicalize_emulator_id(platform_emulator)
		if registry.is_emulator_available(canonical):
			return canonical

	# 4. Use registry default (from _platform_defaults or first available)
	return registry.get_default_emulator_for_platform(game.platform_slug)

## Resolves which RetroArch core id to use for a game.
## Priority: 1. Game override, 2. Active shuffler override, 3. User platform setting, 4. platforms.json default
func resolve_core_for_game(game: GameResource) -> String:
	# 1. Check game override
	if game.preferred_core_id != "":
		return game.preferred_core_id
	
	# 2. Check active shuffler override
	if LaunchManager.is_shuffle_session_active():
		var override = LaunchManager.get_shuffle_override(game.platform_slug)
		if override.get("core_id", "") != "":
			return override["core_id"]
	
	# 2b. Use shuffler-specific default core if the platform has one configured
	if LaunchManager.is_shuffle_session_active():
		if LaunchManager.SHUFFLER_DEFAULT_EMULATORS.has(game.platform_slug):
			return LaunchManager.get_shuffler_default_core_for_platform(game.platform_slug)
	
	# 3. Check user platform settings
	var enabled_platforms = _get_enabled_platforms()
	var platform_config = enabled_platforms.get(game.platform_slug, {})
	var platform_core = platform_config.get("core_id", "")
	if platform_core != "":
		return platform_core
	
	# 4. Use platforms.json default
	return launch_manager.registry.get_retroarch_core_name(game.platform_slug)

## Creates a launch intent for a game
func create_launch_intent(game: GameResource, rom_path_override: String = "") -> LaunchIntent:
	if rom_path_override == "" and not game.is_active_variant_downloaded():
		push_error("[LaunchIntentManager] Cannot launch game without local copy: " + game.get_display_name())
		return null
	
	var intent = LaunchIntent.new()
	intent.game = game
	
	if rom_path_override != "":
		intent.rom_path = rom_path_override
	else:
		# Get the correct file path for the active variant
		var active_file_name = game.get_active_file_name()
		var root_folder = DataManager.get_setting("games_root_folder")
		var root_path = root_folder.value if root_folder else "user://roms/"

		var active_id = game.get_active_game_id()
		if active_id != game.romm_id:
			# A sibling variant is selected: its file lives under the library
			# root named by the sibling's (resolved) file_name. The main
			# entry's file_path points at a different file.
			intent.rom_path = game.get_sibling_file_path(active_id, root_path)
		elif game.file_path != "":
			# Use the actual file_path from game resource
			# Only fall back to constructing path if file_path is empty
			intent.rom_path = game.file_path
		else:
			# Fallback: construct path from components (for legacy or if file_path not set)
			intent.rom_path = FSM.join_paths(root_path, game.platform_slug, active_file_name)
	
	intent.platform_slug = game.platform_slug
	
	# Resolve emulator
	intent.emulator_id = resolve_emulator_for_game(game)
	if intent.emulator_id == "":
		push_error("[LaunchIntentManager] No emulator configured for platform: " + game.platform_slug)
		return null
	
	var emulator = launch_manager.registry.get_emulator(intent.emulator_id)
	intent.emulator_name = RegistrySubManager.get_emulator_display_name(emulator, intent.emulator_id)
	
	# Resolve core if needed (for RetroArch)
	var core_id = ""
	if intent.emulator_id == "retroarch":
		core_id = resolve_core_for_game(game)
	intent.core_name = launch_manager.registry.get_core_for_platform(intent.emulator_id, game.platform_slug, core_id)
	
	# Build launch arguments based on platform
	_build_launch_args(intent, emulator)
	
	# NOTE: Emulator-specific preparation (TitleID extraction, game file extraction, etc.)
	# is done upstream in launch_game(), _queue_game_download_then_launch(), or
	# _on_emulator_installed_for_launch() BEFORE save sync. create_launch_intent()
	# only builds the launch arguments and should not perform any file I/O.
	
	return intent

func _build_launch_args(intent: LaunchIntent, emulator: Dictionary):
	var platform_name = SystemManager.platform.get_platform_name().to_lower()
	
	# Get launch configuration from new registry format
	var launch_config = emulator.get("launch", {})
	var platforms = launch_config.get("platforms", {})
	
	if SystemManager.platform.is_android():
		# Android uses intent-based launching
		var android_template = platforms.get("android", {})
		
		intent.android_action = android_template.get("action", "")
		intent.android_package = android_template.get("package", "")
		intent.android_class = android_template.get("class", "")
		# Extras is always an array in the new unified format
		intent.android_extras = android_template.get("extras", [])
		intent.android_config = android_template
		
		# Xenia special handling - extracted XBLA folders can't be handed to the
		# emulator as intent data; resolve the launchable file inside instead
		# (STFS package for XBLA, default.xex for extracted disc games)
		if launch_manager.registry.get_emulator_architecture(intent.emulator_id) == "xenia" and FSM.dir_exists(intent.rom_path):
			var android_xenia_launch_file = TitleIDParser.find_xbox360_launch_file(intent.rom_path)
			if android_xenia_launch_file != "":
				print("[LaunchIntentManager] Xenia: Using launch file: " + android_xenia_launch_file)
				intent.rom_path = android_xenia_launch_file
			else:
				push_error("[LaunchIntentManager] Xenia: No launchable file in folder: " + intent.rom_path)

		# Vita3K special handling - pass TitleID as command-line args via AppStartParameters
		# Vita3K expects StringArray extra with key "AppStartParameters" containing ["-r", "TitleID"]
		var vita_title_id = intent.game.get_active_title_id() if intent.game else ""
		if intent.emulator_id.begins_with("vita3k"):
			print("[LaunchIntentManager] Vita3K launch: game.title_id='" + (intent.game.title_id if intent.game else "") + "', get_active_title_id='" + vita_title_id + "'")
			if vita_title_id != "":
				intent.android_extras.append({
					"key": "AppStartParameters",
					"value": JSON.stringify(["-r", vita_title_id]),
					"type": "string_array"
				})
				print("[LaunchIntentManager] Vita3K launch: Added AppStartParameters extra with TitleID: " + vita_title_id)
			else:
				print("[LaunchIntentManager] Vita3K launch: WARNING - No TitleID available for launch intent!")
		
		# No emulator-specific extra handling needed - all defined in JSON
		
	else:
		# Desktop uses command-line arguments
		var platform_config = platforms.get(platform_name, {})
		var template = platform_config.get("template", [])
		
		var install_path = launch_manager.registry.get_emulator_install_path(intent.emulator_id)
		
		# Convert paths to absolute system paths for OS.execute
		# Use native path resolution for external tools (converts user:// and handles Windows backslashes)
		var global_install_path = FSM.resolve_native_path(install_path)
		var global_rom_path = FSM.resolve_native_path(intent.rom_path)
		var install_dir = global_install_path.get_base_dir()
		install_dir = install_dir.replace("//", "/")
		
		# Absolute emulator directory for placeholder substitution
		var global_emulator_dir = FSM.resolve_path(
			launch_manager.registry._get_emulator_directory(intent.emulator_id),
			{"format": FSM.PathFormat.ABSOLUTE}
		).rstrip("/")
		
		# Build absolute core path. Cores live in {emulator_dir}/cores, not next to
		# the executable (important for extracted AppImages where the executable is
		# inside squashfs-root/).
		var core_extension = "_libretro.dll" if SystemManager.platform.is_windows() else "_libretro.so"
		var core_separator = "\\" if SystemManager.platform.is_windows() else "/"
		var global_core_path = global_emulator_dir + core_separator + "cores" + core_separator + intent.core_name + core_extension
		global_core_path = global_core_path.replace("//", "/")
		
		# Set working directory from JSON template if provided; otherwise keep
		# the legacy requires_working_dir behavior for backwards compatibility.
		var working_dir_template = platform_config.get("working_directory", "")
		if working_dir_template != "":
			var resolved_working_dir = working_dir_template.replace("{exe}", global_install_path)
			resolved_working_dir = resolved_working_dir.replace("{rom}", global_rom_path)
			resolved_working_dir = resolved_working_dir.replace("{core}", global_core_path)
			# resolve_emulator_path handles {emulator_dir}, {home}, {env.*}, etc.
			resolved_working_dir = FSM.resolve_emulator_path(resolved_working_dir, intent.emulator_id, intent.platform_slug)
			intent.working_directory = FSM.resolve_native_path(resolved_working_dir).rstrip("/")
		elif emulator.get("requires_working_dir", false) or intent.emulator_id.begins_with("vita3k"):
			intent.working_directory = install_dir
		
		for arg in template:
			var formatted_arg = arg.replace("{exe}", global_install_path)
			formatted_arg = formatted_arg.replace("{rom}", global_rom_path)
			formatted_arg = formatted_arg.replace("{core}", global_core_path)
			formatted_arg = formatted_arg.replace("{emulator_dir}", global_emulator_dir)
			intent.launch_args.append(formatted_arg)
		
		# Apply per-platform environment variables (Linux only)
		var env_config = platform_config.get("environment", {})
		for var_name in env_config:
			var formatted_value = str(env_config[var_name])
			formatted_value = formatted_value.replace("{exe}", global_install_path)
			formatted_value = formatted_value.replace("{rom}", global_rom_path)
			formatted_value = formatted_value.replace("{core}", global_core_path)
			formatted_value = formatted_value.replace("{emulator_dir}", global_emulator_dir)
			intent.environment[var_name] = formatted_value
		
		# Vita3K special handling for desktop - pass TitleID via "-r" so the
		# emulator boots the installed app. On Linux this only works once the
		# emulator's VitaFS/config is redirected to the managed emulator dir
		# (handled via XDG env in the JSON), otherwise "-r TitleID" fails with
		# "not in {}" because the installed app lives in the wrong XDG path.
		var desktop_vita_title_id = intent.game.get_active_title_id() if intent.game else ""
		if intent.emulator_id.begins_with("vita3k"):
			if desktop_vita_title_id != "":
				# Replace the ROM path (ZIP) with the TitleID flag
				for i in range(intent.launch_args.size()):
					if intent.launch_args[i] == global_rom_path:
						intent.launch_args[i] = "-r"
						intent.launch_args.insert(i + 1, desktop_vita_title_id)
						break
		
		# RPCS3 special handling for desktop - replace ROM path with game folder path
		var desktop_rpcs3_title_id = intent.game.get_active_title_id() if intent.game else ""
		if launch_manager.registry.get_emulator_architecture(intent.emulator_id) == "rpcs3" and desktop_rpcs3_title_id != "":
			# Check both disc and digital install locations. Use the emulator root
			# (not install_dir) so extracted AppImage installs still find games outside
			# squashfs-root.
			var disc_path: String = FSM.resolve_native_path(FSM.join_paths(global_emulator_dir, "games", desktop_rpcs3_title_id))
			var digital_path: String = FSM.resolve_native_path(FSM.join_paths(global_emulator_dir, "dev_hdd0", "game", desktop_rpcs3_title_id))
			
			var game_path: String
			if FSM.dir_exists(disc_path):
				game_path = disc_path
			elif FSM.dir_exists(digital_path):
				game_path = digital_path
			else:
				# Fallback to disc path if neither exists (will fail gracefully later)
				game_path = disc_path
			
			print("[LaunchIntentManager] RPCS3: Using game path: " + game_path)
			
			# Replace the ROM path (ZIP) with the game folder path
			for i in range(intent.launch_args.size()):
				if intent.launch_args[i] == global_rom_path:
					intent.launch_args[i] = game_path
					break
		
		# Xenia special handling - extracted XBLA folders launch the file inside
		# (STFS package for XBLA, default.xex for extracted disc games)
		if launch_manager.registry.get_emulator_architecture(intent.emulator_id) == "xenia" and FSM.dir_exists(intent.rom_path):
			var xenia_launch_file = TitleIDParser.find_xbox360_launch_file(intent.rom_path)
			if xenia_launch_file != "":
				var global_xenia_launch_file = FSM.resolve_native_path(xenia_launch_file)
				print("[LaunchIntentManager] Xenia: Using launch file: " + global_xenia_launch_file)
				for i in range(intent.launch_args.size()):
					if intent.launch_args[i] == global_rom_path:
						intent.launch_args[i] = global_xenia_launch_file
						break
			else:
				push_error("[LaunchIntentManager] Xenia: No launchable file in folder: " + intent.rom_path)

		# shadPS4 special handling for desktop - replace ROM path with TitleID
		# shadPS4 searches configured installDirs for matching TitleID folder
		var shadps4_title_id = intent.game.get_active_title_id() if intent.game else ""
		if intent.emulator_id == "shadps4" and shadps4_title_id != "":
			print("[LaunchIntentManager] shadPS4: Using TitleID: " + shadps4_title_id)
			
			# Replace the ROM path (ZIP) with just the TitleID
			for i in range(intent.launch_args.size()):
				if intent.launch_args[i] == global_rom_path:
					intent.launch_args[i] = shadps4_title_id
					break

## Helper: Get enabled platforms from settings
func _get_enabled_platforms() -> Dictionary:
	var setting = DataManager.get_setting("enabled_platforms")
	if setting and setting.value is Dictionary:
		return setting.value
	return {}
