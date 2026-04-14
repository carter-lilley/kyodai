class_name HomeView
extends View

signal hero_game_changed(game: GameResource)

@onready var games_grid: VirtualScrollGridContainer = $MarginContainer/VirtualScrollGridContainer
@onready var margin_container: MarginContainer = $MarginContainer

var _total_games: int = 0
var _db_games_count: int = 0
var _gamenative_games_count: int = 0
var _is_loading: bool = false
var _is_initial_launch: bool = true
var _is_scanning: bool = false

# Intro animation tracking
var _intro_animations_complete: bool = false
var _cards_animating: int = 0

# GameNative games storage - kept separate but merged by last_played
var _gamenative_games: Array[GameResource] = []
var _gamenative_loaded: bool = false

# Track which indices in the grid are GameNative games
# This maps virtual index -> true if it's a GameNative game
var _gamenative_indices: Dictionary = {}

# Animation timing controls
@export var enter_animation_start_delay: float = 0.2  # Delay before first card animation starts (was 0.5)
@export var enter_animation_stagger: float = 0.04      # Delay between each card's animation (was 0.05)

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
	
	# Setup vertical layout from settings
	_update_grid_orientation()
	
	# Setup grid margins from settings
	_update_grid_margins()
	
	# Connect to settings changes for grid margins
	if SettingsManager:
		SettingsManager.setting_changed.connect(_on_setting_changed)
	
	# Connect to DataManager signals
	DataManager.database_ready.connect(_on_database_ready)
	print("[DEBUG] Connected to database_ready signal")
	
	# If database is already ready, trigger the callback manually (happens when DataManager loads first)
	if DataManager.is_database_ready():
		print("[DEBUG] Database already ready, calling _on_database_ready manually")
		_on_database_ready()
	
	DataManager.game_updated.connect(_on_game_updated)
	
	# Connect to GameNativeManager signal to refresh when games are added/removed
	GameNativeManager.games_updated.connect(_on_gamenative_games_updated)
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
	
	# Initial load is handled by _on_database_ready() when the DB is ready

func _load_total_count(preserve_cache: bool = false, trigger_scan_if_empty: bool = true):
	"""Get total downloaded game count for virtual scrolling setup.
	
	Loads both DB games count and GameNative games, storing GameNative games
	for proper merging by last_played during pagination.
	"""
	_is_loading = true
	_update_status("Loading recent games...")
	
	# Load GameNative games first (they're small and cached)
	_load_gamenative_games()
	
	# Query total count asynchronously
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_downloaded_games_count()
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				return
			
			_db_games_count = count
			_gamenative_games_count = _gamenative_games.size()
			_total_games = _db_games_count + _gamenative_games_count
			
			# Clear the index tracking when total changes significantly
			if not preserve_cache:
				_gamenative_indices.clear()
			
			games_grid.set_total_count(_total_games, preserve_cache)
			
			print("[DEBUG] _load_total_count: _total_games=%d, _db_games_count=%d, _gamenative_games_count=%d" % [_total_games, _db_games_count, _gamenative_games_count])
			
			if _db_games_count == 0:
				_update_status("No downloaded games found")
				# Trigger scan if no DB games found (may have been wiped from DB but files exist)
				if trigger_scan_if_empty:
					print("[DEBUG] Triggering scan because _db_games_count == 0")
					_scan_for_downloaded_games()
				else:
					print("[DEBUG] NOT triggering scan because trigger_scan_if_empty=false")
			else:
				_update_status("Showing 0-0 of %d games" % _total_games)
			_is_loading = false
	)

func _load_gamenative_games() -> void:
	"""Load and cache GameNative games for proper merging."""
	if GameNativeManager.has_games():
		_gamenative_games = GameNativeManager.create_game_resources()
		# Sort by last_played descending (same as DB query)
		_gamenative_games.sort_custom(func(a: GameResource, b: GameResource) -> bool:
			return a.last_played > b.last_played
		)
	else:
		_gamenative_games.clear()
	_gamenative_loaded = true

func _update_status(text: String):
	# Emit signal to update global status bar
	# Find the main node and update its status
	if not is_inside_tree() or not get_tree():
		return
	var main = get_tree().get_root().get_node_or_null("Main")
	if main and main.has_method("set_status_text"):
		main.set_status_text(text)

func _on_focus_changed(control: Control):
	# Traverse up the tree to find if focused control is inside a GameCard
	var card = control
	while card != null:
		if card is GameCard:
			hero_game_changed.emit(card.game)
			return
		card = card.get_parent()
	
	# Don't clear hero - keep the last focused game image

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting to ensure focus events are received."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return
	
	# Try to disconnect from old viewport (might fail if not connected, that's ok)
	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)
	
	# Connect to new/current viewport
	viewport.gui_focus_changed.connect(_on_focus_changed)
	
	# Reconnect grid's scroll container follow_focus
	if games_grid and games_grid._scroll_container:
		games_grid._scroll_container.reconnect_viewport()

func _scan_for_downloaded_games():
	"""Trigger scan to detect downloaded games in filesystem."""
	if _is_scanning:
		print("[DEBUG] _scan_for_downloaded_games skipped - scan already in progress")
		return
	_is_scanning = true
	print("[DEBUG] _scan_for_downloaded_games called")
	_update_status("Scanning for downloaded games...")
	DataManager.scan_for_downloaded_games(func(found_count: int):
		_is_scanning = false
		print("[DEBUG] Scan callback called with found_count: %d" % found_count)
		if found_count > 0:
			# Force complete grid refresh (don't preserve cache - we need fresh data from DB)
			_load_total_count(false, false)
		else:
			_update_status("No downloaded games found")
	)

func _on_scan_completed(found_count: int):
	"""Called when scan for downloaded games completes."""
	print("[DEBUG] _on_scan_completed called with found_count: %d" % found_count)
	if found_count > 0:
		NotificationManager.show_notification("Found %d downloaded games" % found_count, Notification.Type.SUCCESS)

func _on_sync_completed(success: bool, message: String):
	"""Called when library sync completes."""
	if success:
		_scan_for_downloaded_games()

func _on_items_requested(offset: int, limit: int, is_preload: bool = false):
	"""Handle database query requests from VirtualScrollGridContainer.
	
	Merges DB games with GameNative games, sorted by last_played.
	Properly tracks which indices are GameNative vs DB games.
	"""
	MemoryManager.queue_db_task(
		func():
			# To properly merge and paginate, we need to fetch enough DB games
			# to ensure we can fill the requested window after merging with GameNative games.
			# 
			# Strategy: Fetch DB games from 0 up to (offset + limit + gamenative_count)
			# This guarantees we have all DB games that could appear in the merged window.
			# Then merge everything, and slice to get the exact window requested.
			
			var db_limit = offset + limit + _gamenative_games.size()
			var db_games = DataManager.get_downloaded_games_paginated(0, db_limit)
			
			# Merge ALL fetched DB games with GameNative games
			var merged = _merge_all_games_by_last_played(db_games, _gamenative_games)
			
			# Slice to get exactly the requested window
			var result: Array[GameResource] = []
			var result_gamenative_indices: Dictionary = {}
			
			for i in range(limit):
				var idx = offset + i
				if idx < merged.size():
					var game = merged[idx]
					result.append(game)
					# Check if this is a GameNative game
					if game.source == "gamenative":
						result_gamenative_indices[i] = true
			
			return {
				"games": result,
				"offset": offset,
				"gamenative_indices": result_gamenative_indices
			},
		func(result: Dictionary):
			var games = result["games"] as Array[GameResource]
			var response_offset = result["offset"] as int
			var gamenative_indices = result["gamenative_indices"] as Dictionary
			
			# Merge the GameNative index tracking
			for idx in gamenative_indices.keys():
				_gamenative_indices[response_offset + idx] = true
			
			games_grid.on_items_loaded(games, response_offset, is_preload)
			
			# Mark initial launch complete after first batch with actual games loads
			if response_offset == 0 and _is_initial_launch and games.size() > 0:
				_is_initial_launch = false
	)

func _merge_all_games_by_last_played(db_games: Array[GameResource], gamenative_games: Array[GameResource]) -> Array[GameResource]:
	"""Merge DB games with GameNative games, sorted by last_played descending.
	
	This creates a unified list where both types of games are interleaved
	based on their last_played timestamp.
	"""
	var merged: Array[GameResource] = []
	
	# Create working copies of both lists
	var db_idx = 0
	var gn_idx = 0
	
	# Merge sort style: compare heads and take the larger last_played
	while db_idx < db_games.size() or gn_idx < gamenative_games.size():
		if db_idx >= db_games.size():
			# Only GameNative games left
			merged.append(gamenative_games[gn_idx])
			gn_idx += 1
		elif gn_idx >= gamenative_games.size():
			# Only DB games left
			merged.append(db_games[db_idx])
			db_idx += 1
		else:
			# Compare timestamps and take the larger one (more recent)
			var db_game = db_games[db_idx]
			var gn_game = gamenative_games[gn_idx]
			
			if gn_game.last_played > db_game.last_played:
				merged.append(gn_game)
				gn_idx += 1
			else:
				merged.append(db_game)
				db_idx += 1
	
	return merged

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
	_update_grid_orientation()
	
	# If refreshing effects, reload data first (clears cache), then refresh dimensions
	if refresh_effects:
		# Use callback version to ensure dimensions refresh AFTER data loads
		_load_total_count_with_callback(false, func():
			# Also refresh existing cards
			games_grid.refresh_all_card_effects()
			# Refresh dimensions AFTER data reload to get correct layout
			games_grid.refresh_dimensions()
		)
	else:
		# Force grid to recalculate layout, preserve cache for performance
		games_grid.refresh_dimensions()
		_load_total_count(true)

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

## Returns true when intro animations are complete and cards can accept focus
func are_intro_animations_complete() -> bool:
	return _intro_animations_complete

func _on_card_created(card: Control, index: int):
	"""Connect signals to newly created cards."""
	if card is GameCard:
		card.download_requested.connect(_on_download_requested)
		# Play enter animation with staggered delay on initial launch
		if _is_initial_launch:
			# Track this card's animation
			_cards_animating += 1
			
			# Start invisible immediately
			card.set_card_alpha(0.0)
			var delay = _get_animation_delay(index)
			await get_tree().create_timer(delay).timeout
			if is_instance_valid(card):
				card.play_enter_animation()
				# Connect to animation completion (guard against double-connect)
				if not card.enter_animation_completed.is_connected(_on_card_animation_complete):
					card.enter_animation_completed.connect(_on_card_animation_complete)

func _on_card_animation_complete():
	"""Called when a card's enter animation completes."""
	_cards_animating -= 1
	if _cards_animating <= 0:
		_intro_animations_complete = true
		print("[HomeView] All intro animations complete - cards can now accept focus")

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
	print("[DEBUG] _on_database_ready called")
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
	# Check if this is a GameNative game
	if game.source == "gamenative":
		# Update the cached GameNative game's last_played
		var game_found = false
		for gn_game in _gamenative_games:
			if gn_game.romm_id == game.romm_id:
				gn_game.last_played = game.last_played
				game_found = true
				break
		
		if game_found:
			# Re-sort GameNative games by last_played descending
			_gamenative_games.sort_custom(func(a: GameResource, b: GameResource) -> bool:
				return a.last_played > b.last_played
			)
			# Clear GameNative indices since the order changed
			_gamenative_indices.clear()
	
	# Reload data to get new sort order (don't preserve cache), then refresh dimensions
	# Don't reload GameNative games - we just updated the cache with new timestamps
	_load_total_count_with_callback(false, func():
		games_grid.refresh_dimensions()
	, false)

func _on_gamenative_games_updated():
	"""Called when GameNative games are added or removed - refresh grid."""
	# Reload total count and refresh grid (don't preserve cache)
	_load_total_count(false)

func _load_total_count_with_callback(preserve_cache: bool = false, on_complete: Callable = Callable(), reload_gamenative: bool = true):
	"""Get total downloaded game count and call callback when complete."""
	_is_loading = true
	_update_status("Refreshing...")
	
	# Reload GameNative games first (unless we're preserving our updated cache)
	if reload_gamenative:
		_load_gamenative_games()
	
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_downloaded_games_count()
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				if on_complete.is_valid():
					on_complete.call()
				return
			
			_db_games_count = count
			_gamenative_games_count = _gamenative_games.size()
			_total_games = _db_games_count + _gamenative_games_count
			
			if not preserve_cache:
				_gamenative_indices.clear()
			
			games_grid.set_total_count(_total_games, preserve_cache)
			
			if _total_games == 0:
				_update_status("No downloaded games found")
			else:
				var range_info = games_grid.get_visible_range()
				var start_num = range_info.start + 1
				var end_num = mini(range_info.end, _total_games)
				_update_status("Showing %d-%d of %d games" % [start_num, end_num, _total_games])
			_is_loading = false
			
			if on_complete.is_valid():
				on_complete.call()
	)

func on_view_show():
	super.on_view_show()
	# Refresh the view when shown (in case downloads happened while away)
	if not _is_loading:
		# Check if cache is still valid before using it
		if _validate_cached_data():
			_load_total_count(true, false)
		else:
			# Cache is stale, reload fresh
			_load_total_count(false, false)

func _validate_cached_data() -> bool:
	"""Validate that cached data is still consistent with current state.
	
	Returns true if cache is valid, false if it needs to be refreshed.
	"""
	# Quick validation: check if GameNative count matches
	var current_gamenative_count = GameNativeManager.get_game_count()
	if current_gamenative_count != _gamenative_games_count:
		push_warning("[HomeView] GameNative count mismatch: cached=%d, current=%d" % [_gamenative_games_count, current_gamenative_count])
		return false
	
	# Check if we have the expected number of games cached
	var range_info = games_grid.get_visible_range()
	if range_info.total != _total_games:
		push_warning("[HomeView] Total games mismatch: cached=%d, expected=%d" % [range_info.total, _total_games])
		return false
	
	return true

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
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				LaunchManager.launch_game(game)
		"delete":
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				# Show deleting notification
				NotificationManager.show_notification("Deleting " + game.title + "...", Notification.Type.INFO)
				
				# Lock the grid UI during deletion to prevent interaction with stale cards
				if games_grid:
					games_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
				
				# Delete the game
				DataManager.delete_game_download(game, func(success: bool):
					if success:
						NotificationManager.show_notification(game.title + " deleted", Notification.Type.SUCCESS)
						
						# Remove from GameNative cache if it's a GameNative game
						if game.source == "gamenative":
							var gn_idx = -1
							for i in range(_gamenative_games.size()):
								if _gamenative_games[i].romm_id == romm_id:
									gn_idx = i
									break
							if gn_idx >= 0:
								_gamenative_games.remove_at(gn_idx)
								_gamenative_games_count = _gamenative_games.size()
								_total_games = _db_games_count + _gamenative_games_count
					
						# Clear cache and refresh completely
						_gamenative_indices.clear()
						
						# Force refresh the grid (don't preserve cache to remove the deleted game)
						_load_total_count_with_callback(false, func():
							games_grid.refresh_dimensions()
							
							# Re-enable grid interaction
							if games_grid:
								games_grid.mouse_filter = Control.MOUSE_FILTER_PASS
							
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
						
						# Re-enable grid interaction on failure too
						if games_grid:
							games_grid.mouse_filter = Control.MOUSE_FILTER_PASS
						
						# Play error sound
						if AudioManager:
							AudioManager.play_sfx("error")
				)
		"hide":
			pass
		"add_to_steam":
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				_add_game_to_steam(game)

func check_and_rebuild_if_needed() -> void:
	"""Override: Capture reason before it's cleared, then defer rebuild."""
	if needs_rebuild:
		var reason = needs_rebuild_reason
		# Clear flags now since we're handling the rebuild
		needs_rebuild = false
		needs_rebuild_reason = ""
		# Pass the captured reason to the deferred rebuild
		call_deferred("_do_rebuild", reason)

func perform_rebuild() -> void:
	"""Override: Perform the actual grid rebuild when view becomes visible."""
	# This is called by the base class, but we handle the deferred rebuild in check_and_rebuild_if_needed
	pass

var _deferred_rebuild_attempts: int = 0
const MAX_DEFERRED_REBUILD_ATTEMPTS: int = 10

func _do_rebuild(reason: String = "") -> void:
	# Ensure we have valid dimensions before rebuilding
	if size.x <= 0 or size.y <= 0:
		_deferred_rebuild_attempts += 1
		if _deferred_rebuild_attempts > MAX_DEFERRED_REBUILD_ATTEMPTS:
			push_warning("[HomeView] Max deferred rebuild attempts reached with invalid size, aborting")
			_deferred_rebuild_attempts = 0
			return
		call_deferred("_do_rebuild", reason)
		return
	
	# Reset counter on successful rebuild
	_deferred_rebuild_attempts = 0
	
	if games_grid:
		# Force a layout recalculation with the new valid size
		games_grid.queue_redraw()
	
	# Check if rebuild is due to card effects change
	var refresh_effects = reason == "Card effects changed"
	rebuild_grid(refresh_effects)

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
	
func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	"""Handle settings changes."""
	if setting.property_name in ["library_grid_margin_x", "library_grid_margin_y"]:
		_update_grid_margins()
		# Also refresh the grid layout to recalculate with new margins
		games_grid.refresh_dimensions()
	elif setting.property_name == "card_effect_config":
		mark_for_rebuild("Card effects changed")
	elif setting.property_name == "library_show_title_mode":
		if games_grid:
			games_grid.refresh_all_card_effects()

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
