class_name HomeView
extends View

signal hero_game_changed(game: GameResource)

@onready var games_grid: VirtualScrollGridContainer = $MarginContainer/VirtualScrollGridContainer
@onready var margin_container: MarginContainer = $MarginContainer

var _total_games: int = 0
var _is_loading: bool = false
var _is_initial_launch: bool = true

# Animation timing controls
@export var enter_animation_start_delay: float = .5  # Delay before first card animation starts
@export var enter_animation_stagger: float = 0.05      # Delay between each card's animation

# Animation mode
enum AnimationMode { SEQUENTIAL, RANDOM }
@export var enter_animation_mode: AnimationMode = AnimationMode.RANDOM

# Delay pool for random mode
var _delay_pool: Array[float] = []

func _ready():
	view_name = "Home"
	
	# Setup VirtualScrollGridContainer
	if not games_grid:
		push_error("[HomeView] games_grid is null! Cannot initialize.")
		return
	
	var card_scene = preload("res://components/game_card.tscn")
	games_grid.setup(card_scene, 0)
	games_grid.items_requested.connect(_on_items_requested)
	games_grid.visible_range_changed.connect(_on_visible_range_changed)
	games_grid.item_created.connect(_on_card_created)
	# Connect to resized signal to trigger rebuild when grid gets valid dimensions
	games_grid.resized.connect(_on_grid_resized)
	
	# Setup vertical layout from settings
	_update_grid_orientation()
	
	# Setup grid margins from settings
	_update_grid_margins()
	
	# Connect to settings changes for grid margins
	if SettingsManager:
		SettingsManager.setting_changed.connect(_on_setting_changed)
	
	# Connect to DataManager signals
	DataManager.database_ready.connect(_on_database_ready)
	DataManager.game_updated.connect(_on_game_updated)
	DataManager.scan_for_downloaded_games_completed.connect(_on_scan_completed)
	DataManager.sync_completed.connect(_on_sync_completed)
	
	# Connect to download manager for download status updates
	DownloadManager.download_completed.connect(_on_download_completed)
	
	# Connect to LaunchManager for game launch events (to resort by last_played)
	LaunchManager.game_launched.connect(_on_game_launched)
	
	# Connect to UIManager modal signals
	UIManager.modal_item_selected.connect(_on_modal_item_selected)
	
	# Connect to focus changes for hero image
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	# Initial load (will trigger scan if no games found)
	_load_total_count()

func _load_total_count(preserve_cache: bool = false, trigger_scan_if_empty: bool = true):
	"""Get total downloaded game count for virtual scrolling setup."""
	_is_loading = true
	_update_status("Loading recent games...")
	
	# Query total count asynchronously
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_downloaded_games_count()
			print("[HomeView] Total downloaded games count: %d" % count)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				print("[HomeView] games_grid no longer valid, skipping set_total_count")
				_is_loading = false
				return
			_total_games = count
			print("[HomeView] Setting total count: %d (preserve_cache=%s)" % [count, preserve_cache])
			games_grid.set_total_count(count, preserve_cache)
			if count == 0:
				_update_status("No downloaded games found")
				# Trigger scan if no games found (may have been wiped from DB but files exist)
				if trigger_scan_if_empty:
					_scan_for_downloaded_games()
			else:
				_update_status("Showing 0-0 of %d games" % count)
			_is_loading = false
	)

func _update_status(text: String):
	# Emit signal to update global status bar
	# Find the main node and update its status
	if not is_inside_tree() or not get_tree():
		return
	var main = get_tree().get_root().get_node_or_null("Main")
	if main and main.has_method("set_status_text"):
		main.set_status_text(text)

func _on_focus_changed(control: Control):
	print("[HomeView] Focus changed to: ", control.name if control else "null")
	# Traverse up the tree to find if focused control is inside a GameCard
	var card = control
	while card != null:
		if card is GameCard:
			print("[HomeView] Focus on GameCard: ", card.game.get_display_name() if card.game else "no game")
			hero_game_changed.emit(card.game)
			return
		card = card.get_parent()
	
	# Don't clear hero - keep the last focused game image

func _scan_for_downloaded_games():
	"""Trigger scan to detect downloaded games in filesystem."""
	_update_status("Scanning for downloaded games...")
	print("[HomeView] Scanning for downloaded games...")
	DataManager.scan_for_downloaded_games(func(found_count: int):
		print("[HomeView] Scan complete, found %d games" % found_count)
		if found_count > 0:
			# Force complete grid refresh (don't preserve cache - we need fresh data from DB)
			_load_total_count(false, false)
		else:
			_update_status("No downloaded games found")
	)

func _on_scan_completed(found_count: int):
	"""Called when scan for downloaded games completes."""
	if found_count > 0:
		NotificationManager.show_notification("Found %d downloaded games" % found_count, Notification.Type.SUCCESS)
		# Debug: Show details of games that were found
		print("[HomeView] Scan found %d games, querying details..." % found_count)
		MemoryManager.queue_db_task(
			func():
				var query = """
					SELECT title, platform_slug, romm_id, has_local_copy, is_master_entry, has_cover_art, file_path, downloaded_sibling_ids 
					FROM games 
					WHERE has_local_copy = 1 
					ORDER BY title
				"""
				var games = []
				if DataManager._db.query(query):
					for row in DataManager._db.query_result:
						games.append({
							"title": row.get("title", "N/A"),
							"platform": row.get("platform_slug", "N/A"),
							"romm_id": row.get("romm_id", 0),
							"has_local_copy": row.get("has_local_copy", 0),
							"is_master_entry": row.get("is_master_entry", 0),
							"has_cover_art": row.get("has_cover_art", 0),
							"file_path": row.get("file_path", ""),
							"downloaded_sibling_ids": row.get("downloaded_sibling_ids", "[]")
						})
				return games,
			func(games: Array):
				print("[HomeView] === GAMES MARKED AS DOWNLOADED ===")
				for g in games:
					print("[HomeView] Game: '%s' (%s)" % [g.title, g.platform])
					print("[HomeView]   romm_id: %d, has_local_copy: %d, is_master_entry: %d, has_cover_art: %d" % [g.romm_id, g.has_local_copy, g.is_master_entry, g.has_cover_art])
					print("[HomeView]   file_path: %s" % g.file_path)
					print("[HomeView]   downloaded_sibling_ids: %s" % g.downloaded_sibling_ids)
				print("[HomeView] === END OF DOWNLOADED GAMES ===")
		)

func _on_sync_completed(success: bool, message: String):
	"""Called when library sync completes."""
	if success:
		print("[HomeView] Sync completed, triggering scan for downloaded games")
		_scan_for_downloaded_games()

func _on_items_requested(offset: int, limit: int, is_preload: bool = false):
	"""Handle database query requests from VirtualScrollGridContainer."""
	print("[HomeView] Items requested: offset=%d, limit=%d, preload=%s" % [offset, limit, is_preload])
	MemoryManager.queue_db_task(
		func():
			var games = DataManager.get_downloaded_games_paginated(offset, limit)
			print("[HomeView] DB query complete: got %d games" % games.size())
			for game in games:
				print("[HomeView] Loaded game: %s (has_local_copy=%s, file_path=%s)" % [game.title, game.has_local_copy, game.file_path])
			return games,
		func(games: Array[GameResource]):
			print("[HomeView] Calling on_items_loaded with %d games at offset %d (preload: %s)" % [games.size(), offset, is_preload])
			games_grid.on_items_loaded(games, offset, is_preload)
			# Mark initial launch complete after first batch loads
			if offset == 0 and _is_initial_launch:
				_is_initial_launch = false
	)

func _on_visible_range_changed(start_index: int, end_index: int, total_count: int):
	"""Update status label with current visible range."""
	if total_count == 0:
		_update_status("No downloaded games found")
	else:
		var start_num = start_index + 1
		var end_num = mini(end_index, total_count)
		_update_status("Showing %d-%d of %d games" % [start_num, end_num, total_count])

func rebuild_grid(refresh_effects: bool = false) -> void:
	"""Rebuild the grid to reflect card size/orientation changes."""
	print("[HomeView] === rebuild_grid called ===")
	print("[HomeView] refresh_effects parameter: ", refresh_effects)
	
	# DEBUG: Check what SettingsManager has for card_effect_config at rebuild time
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			print("[HomeView] SettingsManager card_effect_config at rebuild time:")
			print("[HomeView]   - effects count: ", config_setting.value.get("effects", []).size())
		else:
			print("[HomeView] WARNING: SettingsManager card_effect_config not available or not a Dictionary")
	
	_update_grid_orientation()
	
	# If refreshing effects, reload data first (clears cache), then refresh dimensions
	if refresh_effects:
		print("[HomeView] Rebuilding grid with effect refresh")
		# Use callback version to ensure dimensions refresh AFTER data loads
		_load_total_count_with_callback(false, func():
			print("[HomeView] In rebuild callback - calling refresh_all_card_effects")
			# Also refresh existing cards
			games_grid.refresh_all_card_effects()
			# Refresh dimensions AFTER data reload to get correct layout
			print("[HomeView] In rebuild callback - calling refresh_dimensions")
			games_grid.refresh_dimensions()
			print("[HomeView] In rebuild callback - complete")
		)
	else:
		print("[HomeView] Rebuilding grid without effect refresh")
		# Force grid to recalculate layout, preserve cache for performance
		games_grid.refresh_dimensions()
		_load_total_count(true)
	print("[HomeView] === rebuild_grid complete ===")

func _regenerate_delay_pool(count: int) -> void:
	"""Generate a shuffled pool of animation delays for random mode."""
	_delay_pool.clear()
	for i in range(count):
		_delay_pool.append(i * enter_animation_stagger)
	_delay_pool.shuffle()

func _get_animation_delay(index: int) -> float:
	"""Calculate delay for a card based on current animation mode."""
	match enter_animation_mode:
		AnimationMode.SEQUENTIAL:
			return enter_animation_start_delay + (index * enter_animation_stagger)
		AnimationMode.RANDOM:
			if _delay_pool.is_empty():
				# Estimate visible cards and regenerate pool
				var visible_range = games_grid.get_visible_range()
				var visible_count = visible_range.buffer_size if visible_range else 20
				_regenerate_delay_pool(visible_count)
			return enter_animation_start_delay + _delay_pool.pop_front()
	return enter_animation_start_delay

func _on_card_created(card: Control, index: int):
	"""Connect signals to newly created cards."""
	if card is GameCard:
		card.download_requested.connect(_on_download_requested)
		# Play enter animation with staggered delay on initial launch
		if _is_initial_launch:
			# Start invisible immediately
			card.set_card_alpha(0.0)
			var delay = _get_animation_delay(index)
			await get_tree().create_timer(delay).timeout
			if is_instance_valid(card):
				card.play_enter_animation()

func _on_download_requested(game: GameResource):
	# Use the selected sibling's ID and file name if one is selected
	var active_game_id = game.get_active_game_id()
	var active_file_name = game.get_active_file_name()
	
	var download_url = NetworkManager.get_romm_download_url(active_game_id, active_file_name)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		_update_status("Error: Games folder not set")
		NotificationManager.show_notification("Error: Games folder not set", Notification.Type.ERROR)
		return
	
	var destination_path = root_folder.value + "/" + game.platform_slug + "/" + active_file_name
	var item_id = DownloadManager.queue_download(download_url, destination_path, "game", game.get_display_name(), false, "", game, {}, active_game_id)
	
	if item_id != "":
		_update_status("Queued: " + game.get_display_name())
	else:
		_update_status("Failed to queue download")

func _on_download_completed(item_id: String, success: bool, message: String):
	# Refresh when a download completes (game may now show in home view)
	if success:
		# Rebuild grid to ensure layout transforms are recalculated
		rebuild_grid()

func _on_database_ready():
	_load_total_count()

func _on_game_updated(game: GameResource):
	# Find and update any visible cards for this game
	var range_info = games_grid.get_visible_range()
	for i in range(range_info.buffer_start, range_info.buffer_start + range_info.buffer_size):
		var card = games_grid.get_card_at_index(i)
		if card and card is GameCard and card.game and card.game.romm_id == game.romm_id:
			card.game = game
			break

func _on_game_launched(game: GameResource):
	"""Called when a game is launched - refresh grid to resort by last_played."""
	print("[HomeView] Game launched, refreshing grid to resort by last_played")
	# Reload data to get new sort order (don't preserve cache), then refresh dimensions
	_load_total_count_with_callback(false, func():
		games_grid.refresh_dimensions()
	)

func _load_total_count_with_callback(preserve_cache: bool = false, on_complete: Callable = Callable()):
	"""Get total downloaded game count and call callback when complete."""
	_is_loading = true
	_update_status("Refreshing...")
	
	MemoryManager.queue_db_task(
		func():
			return DataManager.get_downloaded_games_count(),
		func(count: int):
			if not is_instance_valid(games_grid):
				print("[HomeView] games_grid no longer valid, skipping set_total_count")
				_is_loading = false
				if on_complete.is_valid():
					on_complete.call()
				return
			_total_games = count
			games_grid.set_total_count(count, preserve_cache)
			if count == 0:
				_update_status("No downloaded games found")
			else:
				var range_info = games_grid.get_visible_range()
				var start_num = range_info.start + 1
				var end_num = mini(range_info.end, count)
				_update_status("Showing %d-%d of %d games" % [start_num, end_num, count])
			_is_loading = false
			
			if on_complete.is_valid():
				on_complete.call()
	)

func on_view_show():
	super.on_view_show()
	# Refresh the view when shown (in case downloads happened while away)
	if not _is_loading:
		_load_total_count(true, false)

func on_view_hide():
	view_hidden.emit()

func _on_modal_item_selected(item_id: String, context: Dictionary):
	# Only handle modal actions if this view is currently active
	if not UIManager.is_current_view(view_name):
		return
	
	var romm_id = context.get("romm_id", 0)
	
	match item_id:
		"details":
			UIManager.show_game_details(romm_id)
		"launch":
			print("[HomeView] Launch requested for game: ", romm_id)
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				LaunchManager.launch_game(game)
			else:
				print("[HomeView] Game not found: ", romm_id)
		"delete":
			print("[HomeView] Delete requested for game: ", romm_id)
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				# Show deleting notification
				NotificationManager.show_notification("Deleting " + game.title + "...", Notification.Type.INFO)
				# Delete the game
				DataManager.delete_game_download(game, func(success: bool):
					if success:
						NotificationManager.show_notification(game.title + " deleted", Notification.Type.SUCCESS)
						# Force refresh the grid (don't preserve cache to remove the deleted game)
						_load_total_count_with_callback(false, func():
							games_grid.refresh_dimensions()
							# Reset focus to home button
							if not is_inside_tree() or not get_tree():
								return
							var main = get_tree().get_root().get_node_or_null("Main")
							if main and main.has_method("reset_focus_to_home_button"):
								main.reset_focus_to_home_button()
							if AudioManager:
								AudioManager.play_sfx("error")
						)
					else:
						NotificationManager.show_notification("Failed to delete " + game.title, Notification.Type.ERROR)
						# Play error sound
						if AudioManager:
							AudioManager.play_sfx("error")
				)
		"hide":
			print("[HomeView] Hide requested for game: ", romm_id)
		"add_to_steam":
			print("[HomeView] Add to Steam requested for game: ", romm_id)
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				_add_game_to_steam(game)

func check_and_rebuild_if_needed() -> void:
	"""Override: Capture reason before it's cleared, then defer rebuild."""
	print("[HomeView] check_and_rebuild_if_needed() called, needs_rebuild=%s" % str(needs_rebuild))
	if needs_rebuild:
		var reason = needs_rebuild_reason
		print("[HomeView] Rebuilding due to: %s" % reason)
		# Clear flags now since we're handling the rebuild
		needs_rebuild = false
		needs_rebuild_reason = ""
		# Pass the captured reason to the deferred rebuild
		call_deferred("_do_rebuild", reason)
	else:
		print("[HomeView] No rebuild needed")

func perform_rebuild() -> void:
	"""Override: Perform the actual grid rebuild when view becomes visible."""
	# This is called by the base class, but we handle the deferred rebuild in check_and_rebuild_if_needed
	pass

func _do_rebuild(reason: String = "") -> void:
	print("[HomeView] _do_rebuild() executing, reason: '%s'" % reason)
	print("[HomeView] Size now: ", size)
	print("[HomeView] Visible now: ", visible)
	
	# Ensure we have valid dimensions before rebuilding
	if size.x <= 0 or size.y <= 0:
		print("[HomeView] WARNING: Invalid size detected, deferring again...")
		call_deferred("_do_rebuild", reason)
		return
	
	if games_grid:
		print("[HomeView] games_grid size: ", games_grid.size)
		print("[HomeView] games_grid visible: ", games_grid.visible)
		# Force a layout recalculation with the new valid size
		games_grid.queue_redraw()
	
	# Check if rebuild is due to card effects change
	var refresh_effects = reason == "Card effects changed"
	print("[HomeView] refresh_effects=%s (reason: '%s')" % [refresh_effects, reason])
	rebuild_grid(refresh_effects)
	print("[HomeView] Rebuild complete")

func _on_grid_resized() -> void:
	"""Called when games_grid is resized. Triggers rebuild if needed and grid has valid dimensions."""
	# Only trigger rebuild if we have valid dimensions and a pending rebuild
	if needs_rebuild and games_grid and games_grid.size.x > 0 and games_grid.size.y > 0:
		print("[HomeView] Grid resized with valid dimensions, triggering pending rebuild")
		check_and_rebuild_if_needed()

func _update_grid_orientation() -> void:
	if SettingsManager:
		var vertical_setting = SettingsManager.get_setting("library_vertical_layout")
		if vertical_setting:
			games_grid.vertical = vertical_setting.value

func _update_grid_margins() -> void:
	"""Update the grid margins from settings."""
	if not margin_container:
		return
	
	var margin_x = 0
	var margin_y = 0
	
	if SettingsManager:
		var margin_x_setting = SettingsManager.get_setting("library_grid_margin_x")
		if margin_x_setting:
			margin_x = int(margin_x_setting.value)
		
		var margin_y_setting = SettingsManager.get_setting("library_grid_margin_y")
		if margin_y_setting:
			margin_y = int(margin_y_setting.value)
	
	margin_container.add_theme_constant_override("margin_left", margin_x)
	margin_container.add_theme_constant_override("margin_right", margin_x)
	margin_container.add_theme_constant_override("margin_top", margin_y)
	margin_container.add_theme_constant_override("margin_bottom", margin_y)
	
	print("[HomeView] Grid margins updated: x=%d, y=%d" % [margin_x, margin_y])

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	"""Handle settings changes."""
	if setting.property_name in ["library_grid_margin_x", "library_grid_margin_y"]:
		print("[HomeView] Grid margin setting changed, updating margins...")
		_update_grid_margins()
		# Also refresh the grid layout to recalculate with new margins
		games_grid.refresh_dimensions()
	elif setting.property_name == "card_effect_config":
		print("[HomeView] Card effect config changed, marking for rebuild...")
		mark_for_rebuild("Card effects changed")

func _add_game_to_steam(game: GameResource) -> void:
	"""Add a game to Steam as a non-Steam game."""
	# Validate Steam path
	var steam_folder_setting = SettingsManager.get_setting("steam_folder")
	if not steam_folder_setting or steam_folder_setting.value.is_empty():
		NotificationManager.show_notification("Steam folder not configured", Notification.Type.ERROR)
		if AudioManager:
			AudioManager.play_sfx("error")
		return
	
	var steam_path = steam_folder_setting.value
	if not SteamVDFWriter.is_valid_steam_path(steam_path):
		NotificationManager.show_notification("Invalid Steam installation folder", Notification.Type.ERROR)
		if AudioManager:
			AudioManager.play_sfx("error")
		return
	
	# Show processing notification
	NotificationManager.show_notification("Adding " + game.title + " to Steam...", Notification.Type.INFO)
	
	# Get launch intent for the game
	var launch_intent = await LaunchManager.create_launch_intent(game)
	if not launch_intent:
		NotificationManager.show_notification("Failed to create launch intent for " + game.title, Notification.Type.ERROR)
		if AudioManager:
			AudioManager.play_sfx("error")
		return
	
	# Get emulator executable path
	var exe_path = LaunchManager.get_emulator_install_path(launch_intent.emulator_id)
	if exe_path.is_empty():
		NotificationManager.show_notification("Could not find emulator executable for " + game.title, Notification.Type.ERROR)
		if AudioManager:
			AudioManager.play_sfx("error")
		return
	
	# Globalize the path for Steam (needs absolute system path)
	exe_path = ProjectSettings.globalize_path(exe_path)
	exe_path = exe_path.replace("//", "/")
	# Convert to native path separators (backslashes on Windows)
	exe_path = exe_path.replace("/", "\\")
	
	# Get the ROM path and ensure it's quoted
	var rom_path: String = ProjectSettings.globalize_path(launch_intent.rom_path)
	rom_path = rom_path.replace("//", "/")
	rom_path = rom_path.replace("/", "\\")
	
	# Build the full command line: "exe" args "rom"
	# Start with quoted exe path
	var full_command: String = "\"" + exe_path + "\""
	
	# Add launch arguments (skip first if it's the exe)
	if not launch_intent.launch_args.is_empty():
		for i in range(launch_intent.launch_args.size()):
			var arg: String = launch_intent.launch_args[i]
			# Skip first arg if it's the exe path
			if i == 0 and (arg == exe_path or arg.ends_with(exe_path.get_file())):
				continue
			# Wrap ROM path in quotes
			if arg == rom_path or arg.replace("/", "\\") == rom_path:
				arg = "\"" + arg + "\""
			full_command += " " + arg
	
	# Determine working directory
	var working_dir: String = launch_intent.working_directory
	if working_dir.is_empty():
		working_dir = exe_path.get_base_dir()
	working_dir = ProjectSettings.globalize_path(working_dir)
	working_dir = working_dir.replace("//", "/")
	# Convert to native path separators (backslashes on Windows)
	working_dir = working_dir.replace("/", "\\")
	
	# Get the cached cover art path (same as GameCard uses)
	var cover_art_path: String = ""
	const CACHE_FOLDER = "user://cache/covers/"
	
	# Try to get the cached cover path from cover_url
	if not game.cover_url.is_empty() and game.cover_url.begins_with("http"):
		cover_art_path = CACHE_FOLDER + game.cover_url.md5_text() + ".jpg"
		cover_art_path = ProjectSettings.globalize_path(cover_art_path)
	elif not game.cover_path.is_empty():
		# Fallback to cover_path if it's a valid local path
		cover_art_path = game.cover_path
		if cover_art_path.find("?") != -1:
			cover_art_path = cover_art_path.substr(0, cover_art_path.find("?"))
		if FileAccess.file_exists(cover_art_path):
			cover_art_path = ProjectSettings.globalize_path(cover_art_path)
	
	# Build game data for Steam
	# exe = full command with args (used as Steam target in VDF)
	var game_data := {
		"name": game.title,
		"exe": full_command,
		"start_dir": working_dir,
		"icon": "",
		"launch_options": "",
		"last_play_time": 0,
		"cover_path": cover_art_path
	}
	
	# Get shortcuts.vdf path
	var shortcuts_path = SteamVDFWriter.get_shortcuts_vdf_path(steam_path)
	if shortcuts_path.is_empty():
		NotificationManager.show_notification("Could not find Steam shortcuts file", Notification.Type.ERROR)
		if AudioManager:
			AudioManager.play_sfx("error")
		return
	
	# Read existing shortcuts or create new structure
	var shortcuts := {}
	if FileAccess.file_exists(shortcuts_path):
		shortcuts = SteamVDFWriter.read_vdf(shortcuts_path)
	
	if not shortcuts.has("shortcuts"):
		shortcuts["shortcuts"] = {}
	
	# Check if game already exists
	var shortcuts_list = shortcuts["shortcuts"]
	for key in shortcuts_list.keys():
		var entry = shortcuts_list[key]
		if entry is Dictionary and entry.get("AppName", "") == game.title:
			NotificationManager.show_notification(game.title + " is already in Steam", Notification.Type.WARNING)
			if AudioManager:
				AudioManager.play_sfx("error")
			return
	
	# Debug: Calculate all possible AppIDs
	SteamVDFWriter.debug_calculate_app_ids(game_data.exe, game.title)
	
	# Add the new shortcut
	var result = SteamVDFWriter.add_shortcut(shortcuts, game_data)
	shortcuts = result.shortcuts
	var app_id = result.app_id
	
	# Write back to file
	if SteamVDFWriter.write_vdf(shortcuts_path, shortcuts):
		# Copy artwork to Steam grid folder
		var cover_path = game_data.get("cover_path", "")
		if not cover_path.is_empty():
			SteamVDFWriter.copy_artwork_to_steam(steam_path, app_id, cover_path)
		
		NotificationManager.show_notification(game.title + " added to Steam! Restart Steam to see it.", Notification.Type.SUCCESS)
		if AudioManager:
			AudioManager.play_sfx("success")
	else:
		NotificationManager.show_notification("Failed to add " + game.title + " to Steam", Notification.Type.ERROR)
		if AudioManager:
			AudioManager.play_sfx("error")
