class_name HomeView
extends View

@onready var margin_container: MarginContainer = $MarginContainer

var _total_games: int = 0
var _db_games_count: int = 0
var _gamenative_games_count: int = 0
var _is_loading: bool = false
var _is_scanning: bool = false

# True while a total-count DB task is queued but not yet completed. Used to
# prevent overlapping count queries from startup paths (database_ready,
# on_view_show, rebuild_grid) running in quick succession.
var _total_count_load_pending: bool = false

# Last total-games value we logged; used to avoid repeating identical debug lines.
var _last_logged_total_games: int = -1

# GameNative games storage - kept separate but merged by last_played
var _gamenative_games: Array[GameResource] = []
var _gamenative_loaded: bool = false

# Track which indices in the grid are GameNative games
# This maps virtual index -> true if it's a GameNative game
var _gamenative_indices: Dictionary = {}

# Cached merged list of DB + GameNative games (rebuilt when dirty)
var _merged_games_cache: Array[GameResource] = []
var _merged_cache_dirty: bool = true
var _merged_cache_start: int = 0
var _merged_cache_end: int = 0



func _ready():
	view_name = "Home"
	
	# Initialize grid reference (declared in base View class)
	games_grid = $MarginContainer/VirtualScrollGridContainer as VirtualScrollGridContainer
	
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
	
	# Connect to settings changes
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
	_total_count_load_pending = true
	_update_status("Loading recent games...")
	
	# Load GameNative games first (they're small and cached)
	_load_gamenative_games()
	
	# Query total count asynchronously
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_downloaded_games_count()
			return count,
		func(count: int):
			_total_count_load_pending = false
			if not is_instance_valid(games_grid):
				_is_loading = false
				return
			
			_db_games_count = count
			_gamenative_games_count = _gamenative_games.size()
			_total_games = _db_games_count + _gamenative_games_count
			
			# Clear the index tracking when total changes significantly
			if not preserve_cache:
				_gamenative_indices.clear()
				_merged_games_cache.clear()
				_merged_cache_start = 0
				_merged_cache_end = 0
				_merged_cache_dirty = true
			
			games_grid.set_total_count(_total_games, preserve_cache)
			
			# Only log when the count actually changes to avoid startup noise.
			if _total_games != _last_logged_total_games:
				_last_logged_total_games = _total_games
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
	_merged_cache_dirty = true

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
		NotificationManager.show_notification("Found %d downloaded games" % found_count, NotificationManager.Type.SUCCESS)
		_merged_games_cache.clear()
		_merged_cache_start = 0
		_merged_cache_end = 0
		_merged_cache_dirty = true

func _on_sync_completed(success: bool, _message: String):
	"""Called when library sync completes."""
	if success:
		_scan_for_downloaded_games()
		_merged_games_cache.clear()
		_merged_cache_start = 0
		_merged_cache_end = 0
		_merged_cache_dirty = true

func _on_items_requested(offset: int, limit: int, is_preload: bool = false):
	"""Handle database query requests from VirtualScrollGridContainer.
	
	Merges DB games with GameNative games, sorted by last_played.
	Uses a cached merged list to avoid O(n²) DB over-fetching.
	Fetches only the requested window plus a small buffer to avoid loading
	the entire library into memory.
	"""
	MemoryManager.queue_db_task(
		func():
			var request_end = offset + limit
			# The cache must FULLY contain the requested range, not just overlap.
			# A partial overlap (e.g. cache=[55,98) vs request=[0,98)) still
			# produces misses for the uncovered portion.
			var cache_fully_covers = not _merged_games_cache.is_empty() and \
				offset >= _merged_cache_start and \
				request_end <= _merged_cache_end
			
			var cache_hit = not (_merged_cache_dirty or _merged_games_cache.is_empty() or not cache_fully_covers)
			
			# Rebuild cache if dirty, empty, or the requested range is not fully
			# covered by the current cached window.
			if not cache_hit:
				var buffer = limit * 2
				var fetch_offset = max(0, offset - buffer)
				# Enforce a minimum fetch window so small _request_missing_data()
				# batches don't create an undersized cache that immediately misses.
				var fetch_limit = max(limit + buffer * 2, 50)
				var db_games = DataManager.get_downloaded_games_paginated(fetch_offset, fetch_limit)
				_merged_games_cache = _merge_all_games_by_last_played(db_games, _gamenative_games)
				_merged_cache_start = fetch_offset
				_merged_cache_end = fetch_offset + _merged_games_cache.size()
				_merged_cache_dirty = false
			else:
				pass
			
			# Slice the cached merged list using virtual-index offsets.
			var result: Array[GameResource] = []
			var result_gamenative_indices: Dictionary = {}
			
			for i in range(limit):
				var virtual_idx = offset + i
				var cache_idx = virtual_idx - _merged_cache_start
				if cache_idx >= 0 and cache_idx < _merged_games_cache.size():
					var game = _merged_games_cache[cache_idx]
					result.append(game)
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
			
			for idx in gamenative_indices.keys():
				_gamenative_indices[response_offset + idx] = true
			
			games_grid.on_items_loaded(games, response_offset, is_preload)
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
	
	# Apply zoom from centralized card settings state
	if UIManager and UIManager.card_settings_state and games_grid:
		games_grid.target_card_width_ratio = UIManager.card_settings_state.card_zoom_ratio
	
	# If refreshing effects, reload data first (clears cache), then refresh dimensions
	if refresh_effects:
		if _total_count_load_pending:
			# A count load is already in flight; just refresh dimensions for now.
			games_grid.refresh_dimensions()
		else:
			# Use callback version to ensure dimensions refresh AFTER data loads
			_load_total_count_with_callback(false, func():
				# Also refresh existing cards
				games_grid.refresh_all_card_effects(true)
				# Refresh dimensions AFTER data reload to get correct layout
				games_grid.refresh_dimensions()
			)
	else:
		# Force grid to recalculate layout, preserve cache for performance
		games_grid.refresh_dimensions()
		if not _total_count_load_pending:
			_load_total_count(true, true)

## Returns true when intro animations are complete and cards can accept focus
## Note: Intro animations have been removed, so this always returns true
func are_intro_animations_complete() -> bool:
	return true

func _on_download_completed(_item_id: String, success: bool, _message: String):
	# Refresh when a download completes (game may now show in home view)
	if success:
		# Rebuild grid to ensure layout transforms are recalculated
		rebuild_grid()

func _on_database_ready():
	print("[DEBUG] _on_database_ready called")
	_load_total_count()

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
	_total_count_load_pending = true
	_update_status("Refreshing...")
	
	# Reload GameNative games first (unless we're preserving our updated cache)
	if reload_gamenative:
		_load_gamenative_games()
	
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_downloaded_games_count()
			return count,
		func(count: int):
			_total_count_load_pending = false
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
				_merged_games_cache.clear()
				_merged_cache_start = 0
				_merged_cache_end = 0
				_merged_cache_dirty = true
			
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

func _input(event: InputEvent) -> void:
	"""Handle random-game input when this view is active."""
	if not UIManager.is_current_view(view_name):
		return
	
	if event.is_action_pressed("random_game"):
		_focus_random_card()
		accept_event()

func _focus_random_card() -> void:
	"""Focus a random downloaded game card in the grid."""
	if _total_games == 0:
		return
	
	var random_index := randi() % _total_games
	games_grid.scroll_to_index_and_focus(random_index, false)

func on_view_show():
	super.on_view_show()
	# Refresh the view when shown (in case downloads happened while away)
	# Skip if we haven't loaded data yet or a load is already pending.
	if not _is_loading and not _total_count_load_pending and _total_games > 0:
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
		"card_designer":
			var card_designer_game = DataManager.get_game_by_id(romm_id)
			if card_designer_game:
				UIManager.set_card_designer_preview_game(card_designer_game.romm_id)
			UIManager.show_settings_dialog_with_category("card_designer")
		"delete":
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				# Show deleting notification
				NotificationManager.show_notification("Deleting " + game.title + "...", NotificationManager.Type.INFO)
				
				# Lock the grid UI during deletion to prevent interaction with stale cards
				if games_grid:
					games_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE
				
				# Helper function to refresh grid after successful delete
				var _refresh_after_delete = func():
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
				
				# Delete the game
				DataManager.delete_game_download(game, func(success: bool):
					if success:
						NotificationManager.show_notification(game.title + " deleted", NotificationManager.Type.SUCCESS)
						_refresh_after_delete.call()
					else:
						# File not found - ask user if they want to remove from DB anyway
						var on_confirm = func():
							M3Dialog.dismiss_current()
							var on_force_delete = func(force_success: bool):
								if force_success:
									NotificationManager.show_notification(game.title + " removed from library", NotificationManager.Type.SUCCESS)
									_refresh_after_delete.call()
								else:
									NotificationManager.show_notification("Failed to remove " + game.title, NotificationManager.Type.ERROR)
									if games_grid:
										games_grid.mouse_filter = Control.MOUSE_FILTER_PASS
							DataManager.delete_game_download(game, on_force_delete, true)
						
						var on_cancel = func():
							M3Dialog.dismiss_current()
							if games_grid:
								games_grid.mouse_filter = Control.MOUSE_FILTER_PASS
							if AudioManager:
								AudioManager.play_sfx("error")
						
						M3Dialog.show_confirm("File Not Found", "Game files for " + game.title + " were not found on disk. Remove from library anyway?", on_confirm, on_cancel)
				)
		"hide":
			pass
		"add_to_steam":
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				SteamVDFWriter.add_game(game)
