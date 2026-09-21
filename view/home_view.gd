class_name HomeView
extends View

const DEBUG_LOG: bool = false

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

# One-shot guard: the manual is_database_ready() path in _ready() and the
# database_ready signal can both fire for the same view.
var _database_ready_handled: bool = false

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
	var ready_start_us := Time.get_ticks_usec()

	view_name = "Home"
	
	# Initialize grid reference (declared in base View class)
	games_grid = $MarginContainer/VBoxContainer/VirtualScrollGridContainer as VirtualScrollGridContainer
	
	# Setup VirtualScrollGridContainer
	if not games_grid:
		push_error("[HomeView] games_grid is null! Cannot initialize.")
		return
	
	var phase_start_us := Time.get_ticks_usec()
	var card_scene = load("res://components/game_card.tscn") as PackedScene
	var initial_zoom: float = 0.25
	if UIManager and UIManager.card_settings_state:
		var zoom_state = UIManager.card_settings_state
		initial_zoom = zoom_state.card_zoom_ratio if zoom_state.layout_mode == 0 else zoom_state.card_zoom_list_ratio
	games_grid.setup(card_scene, 0, initial_zoom)
	print("[HomeView] games_grid.setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	games_grid.items_requested.connect(_on_items_requested)
	games_grid.visible_range_changed.connect(_on_visible_range_changed)
	games_grid.item_created.connect(_on_card_created)
	
	# Setup vertical layout from settings
	phase_start_us = Time.get_ticks_usec()
	_update_grid_orientation()
	print("[HomeView] _update_grid_orientation elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	
	# Autoload signals are established via _connect_signals (also re-run on
	# _enter_tree after DS-mode reparenting).
	_connect_signals()
	
	# If database is already ready, trigger the callback manually (happens when DataManager loads first)
	phase_start_us = Time.get_ticks_usec()
	if DataManager.is_database_ready():
		print("[DEBUG] Database already ready, calling _on_database_ready manually")
		_on_database_ready()
	print("[HomeView] _on_database_ready elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	
	# Initial load is handled by _on_database_ready() when the DB is ready
	
	# Let the base View class own the focus signal connection.
	reconnect_viewport()

	print("[HomeView] _ready() total elapsed_us=", Time.get_ticks_usec() - ready_start_us)

func _enter_tree() -> void:
	# DS-mode reparenting fires _exit_tree (which disconnects all autoload
	# signals) and then _enter_tree - re-establish them, or modal actions like
	# the details sheet summon silently die after any DS toggle.
	_connect_signals()

func _connect_signals() -> void:
	# Guards: _enter_tree fires before _ready on the initial add, so both call
	# this - every connect must be idempotent.
	if DataManager:
		if not DataManager.setting_changed.is_connected(_on_setting_changed):
			DataManager.setting_changed.connect(_on_setting_changed)
		if not DataManager.database_ready.is_connected(_on_database_ready):
			DataManager.database_ready.connect(_on_database_ready)
		if not DataManager.database_failed.is_connected(_on_database_failed):
			DataManager.database_failed.connect(_on_database_failed)
		if not DataManager.game_updated.is_connected(_on_game_updated):
			DataManager.game_updated.connect(_on_game_updated)
		if not DataManager.scan_for_downloaded_games_completed.is_connected(_on_scan_completed):
			DataManager.scan_for_downloaded_games_completed.connect(_on_scan_completed)
		if not DataManager.sync_completed.is_connected(_on_sync_completed):
			DataManager.sync_completed.connect(_on_sync_completed)
	if SystemManager and SystemManager.download and not SystemManager.download.download_completed.is_connected(_on_download_completed):
		SystemManager.download.download_completed.connect(_on_download_completed)
	if LaunchManager:
		if not LaunchManager.gamenative_games_updated.is_connected(_on_gamenative_games_updated):
			LaunchManager.gamenative_games_updated.connect(_on_gamenative_games_updated)
		if not LaunchManager.game_launched.is_connected(_on_game_launched):
			LaunchManager.game_launched.connect(_on_game_launched)
		if LaunchManager.update and not LaunchManager.update.update_session_finished.is_connected(_on_update_session_finished):
			LaunchManager.update.update_session_finished.connect(_on_update_session_finished)
	if UIManager and not UIManager.modal_item_selected.is_connected(_on_modal_item_selected):
		UIManager.modal_item_selected.connect(_on_modal_item_selected)

func _exit_tree() -> void:
	# Mirror the connect block in _ready so a torn-down Home tab can't
	# double-connect or leave dangling autoload connections behind.
	if is_instance_valid(DataManager):
		if DataManager.setting_changed.is_connected(_on_setting_changed):
			DataManager.setting_changed.disconnect(_on_setting_changed)
		if DataManager.database_ready.is_connected(_on_database_ready):
			DataManager.database_ready.disconnect(_on_database_ready)
		if DataManager.database_failed.is_connected(_on_database_failed):
			DataManager.database_failed.disconnect(_on_database_failed)
		if DataManager.game_updated.is_connected(_on_game_updated):
			DataManager.game_updated.disconnect(_on_game_updated)
		if DataManager.scan_for_downloaded_games_completed.is_connected(_on_scan_completed):
			DataManager.scan_for_downloaded_games_completed.disconnect(_on_scan_completed)
		if DataManager.sync_completed.is_connected(_on_sync_completed):
			DataManager.sync_completed.disconnect(_on_sync_completed)
	if is_instance_valid(LaunchManager):
		if LaunchManager.gamenative_games_updated.is_connected(_on_gamenative_games_updated):
			LaunchManager.gamenative_games_updated.disconnect(_on_gamenative_games_updated)
		if LaunchManager.game_launched.is_connected(_on_game_launched):
			LaunchManager.game_launched.disconnect(_on_game_launched)
		if LaunchManager.update and LaunchManager.update.update_session_finished.is_connected(_on_update_session_finished):
			LaunchManager.update.update_session_finished.disconnect(_on_update_session_finished)
	if is_instance_valid(SystemManager) and SystemManager.download and SystemManager.download.download_completed.is_connected(_on_download_completed):
		SystemManager.download.download_completed.disconnect(_on_download_completed)
	if is_instance_valid(UIManager) and UIManager.modal_item_selected.is_connected(_on_modal_item_selected):
		UIManager.modal_item_selected.disconnect(_on_modal_item_selected)

func _load_total_count(preserve_cache: bool = false, trigger_scan_if_empty: bool = true, on_complete: Callable = Callable(), reload_gamenative: bool = true):
	var load_start_us := Time.get_ticks_usec()

	_is_loading = true
	_total_count_load_pending = true
	_update_status("Loading recent games...")

	# Load GameNative games first (they're small and cached). When preserving the
	# cache and GameNative games are already loaded, skip this so we don't mark
	# the merged DB cache dirty and defeat the prefetch warm-up.
	var should_reload_gamenative = reload_gamenative and (not _gamenative_loaded or not preserve_cache)
	print("[DEBUG] _load_total_count: preserve_cache=", preserve_cache, " _gamenative_loaded=", _gamenative_loaded, " should_reload_gamenative=", should_reload_gamenative, " _merged_cache_dirty=", _merged_cache_dirty)
	if should_reload_gamenative:
		var phase_start_us := Time.get_ticks_usec()
		_load_gamenative_games()
		print("[HomeView] _load_gamenative_games elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# If the database is already ready AND the count cache is warm, set the count
	# synchronously so the grid can settle with the correct total on the first
	# frame. A cold cache would run a full-table scan on the main thread here
	# (~90ms) — fall through to the async path and let the grid show skeletons.
	if DataManager and DataManager.is_database_ready() and DataManager.has_cached_downloaded_count():
		var phase_start_us := Time.get_ticks_usec()
		var count = DataManager.get_downloaded_games_count()
		print("[HomeView] get_downloaded_games_count elapsed_us=", Time.get_ticks_usec() - phase_start_us)
		_total_count_load_pending = false
		if not is_instance_valid(games_grid):
			_is_loading = false
			if on_complete.is_valid():
				on_complete.call()
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

		phase_start_us = Time.get_ticks_usec()
		var available_size = UIManager.compute_grid_available_size(games_grid, self) if UIManager else Vector2.ZERO
		games_grid.set_total_count_with_available_size(_total_games, available_size, preserve_cache)
		print("[HomeView] games_grid.set_total_count elapsed_us=", Time.get_ticks_usec() - phase_start_us)

		# Only log when the count actually changes to avoid startup noise.
		if _total_games != _last_logged_total_games:
			_last_logged_total_games = _total_games
			print("[DEBUG] _load_total_count sync: _total_games=%d, _db_games_count=%d, _gamenative_games_count=%d" % [_total_games, _db_games_count, _gamenative_games_count])

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
		print("[HomeView] _load_total_count total elapsed_us=", Time.get_ticks_usec() - load_start_us)
		if on_complete.is_valid():
			on_complete.call()
		return

	# Fallback: DB not ready yet, query total count asynchronously.
	SystemManager.memory.queue_db_task(
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

			# Clear the index tracking when total changes significantly
			if not preserve_cache:
				_gamenative_indices.clear()
				_merged_games_cache.clear()
				_merged_cache_start = 0
				_merged_cache_end = 0
				_merged_cache_dirty = true

			games_grid.set_total_count_with_available_size(_total_games, UIManager.compute_grid_available_size(games_grid, self) if UIManager else Vector2.ZERO, preserve_cache)

			# Only log when the count actually changes to avoid startup noise.
			if _total_games != _last_logged_total_games:
				_last_logged_total_games = _total_games
				print("[DEBUG] _load_total_count async: _total_games=%d, _db_games_count=%d, _gamenative_games_count=%d" % [_total_games, _db_games_count, _gamenative_games_count])

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
			if on_complete.is_valid():
				on_complete.call()
	)
	print("[HomeView] _load_total_count async queued elapsed_us=", Time.get_ticks_usec() - load_start_us)

func _load_gamenative_games() -> void:
	"""Load and cache GameNative games for proper merging."""
	if LaunchManager.gamenative_has_games():
		_gamenative_games = LaunchManager.gamenative_create_game_resources()
		# Sort by last_played descending (same as DB query)
		_gamenative_games.sort_custom(func(a: GameResource, b: GameResource) -> bool:
			return a.last_played > b.last_played
		)
	else:
		_gamenative_games.clear()
	_gamenative_loaded = true
	_merged_cache_dirty = true

func _prefetch_first_page() -> void:
	"""Warm the merged-games cache for the first page before the grid asks for it.

	This runs on the DB thread so the initial items_requested callback can hit the
	cache instead of blocking the main thread while the grid is settling."""
	var offset := 0
	var limit := 25
	SystemManager.memory.queue_db_task(
		func():
			var db_start_us := Time.get_ticks_usec()
			var request_end = offset + limit
			var cache_fully_covers = not _merged_games_cache.is_empty() and \
				offset >= _merged_cache_start and \
				request_end <= _merged_cache_end

			if not cache_fully_covers:
				var buffer = limit * 2
				var fetch_offset = max(0, offset - buffer)
				var fetch_limit = max(limit + buffer * 2, 50)
				var db_games = DataManager.get_downloaded_games_paginated(fetch_offset, fetch_limit)
				_merged_games_cache = _merge_all_games_by_last_played(db_games, _gamenative_games)
				_merged_cache_start = fetch_offset
				_merged_cache_end = fetch_offset + _merged_games_cache.size()
				_merged_cache_dirty = false
				print("[HomeView] prefetch first page: fetch_offset=", fetch_offset, " fetch_limit=", fetch_limit, " db_elapsed_us=", Time.get_ticks_usec() - db_start_us)
			else:
				print("[HomeView] prefetch first page: cache already warm")
			return null,
		func(_result):
			pass
	)

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
		SystemManager.notifications.show_notification("Found %d downloaded games" % found_count, SystemManager.notifications.Type.SUCCESS)
		_merged_games_cache.clear()
		_merged_cache_start = 0
		_merged_cache_end = 0
		_merged_cache_dirty = true

func _on_sync_completed(success: bool, _message: String):
	"""Called when library sync completes."""
	_seen_library_generation = DataManager.library_generation
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
	var request_start_us := Time.get_ticks_usec()
	SystemManager.memory.queue_db_task(
		func():
			if not is_instance_valid(games_grid) or not games_grid.is_load_pending(offset):
				return {
					"games": [] as Array[GameResource],
					"offset": offset,
					"gamenative_indices": {}
				}
			var db_start_us := Time.get_ticks_usec()
			var request_end = offset + limit
			# The cache must FULLY contain the requested range, not just overlap.
			# A partial overlap (e.g. cache=[55,98) vs request=[0,98)) still
			# produces misses for the uncovered portion.
			var cache_fully_covers = not _merged_games_cache.is_empty() and \
				offset >= _merged_cache_start and \
				request_end <= _merged_cache_end
			
			var cache_hit = not (_merged_cache_dirty or _merged_games_cache.is_empty() or not cache_fully_covers)
			
			if DEBUG_LOG: print("[HomeView] _on_items_requested cache check: offset=", offset, " limit=", limit, " cache_fully_covers=", cache_fully_covers, " cache_hit=", cache_hit, " dirty=", _merged_cache_dirty, " cache_start=", _merged_cache_start, " cache_end=", _merged_cache_end, " cache_size=", _merged_games_cache.size())
			
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
			
			if DEBUG_LOG: print("[HomeView] DB task: offset=", offset, " limit=", limit, " cache_hit=", cache_hit, " db_elapsed_us=", Time.get_ticks_usec() - db_start_us, " total_request_us=", Time.get_ticks_usec() - request_start_us)
			return {
				"games": result,
				"offset": offset,
				"gamenative_indices": result_gamenative_indices
			},
		func(result: Dictionary):
			var callback_start_us := Time.get_ticks_usec()
			var games = result["games"] as Array[GameResource]
			var response_offset = result["offset"] as int
			var gamenative_indices = result["gamenative_indices"] as Dictionary
			
			for idx in gamenative_indices.keys():
				_gamenative_indices[response_offset + idx] = true
			
			games_grid.on_items_loaded(games, response_offset, is_preload)
			if DEBUG_LOG: print("[HomeView] on_items_loaded callback: offset=", response_offset, " count=", games.size(), " elapsed_us=", Time.get_ticks_usec() - callback_start_us, " total_request_us=", Time.get_ticks_usec() - request_start_us)
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

func rebuild_grid(refresh_effects: bool = false, preserve_data: bool = true) -> void:
	"""Rebuild the grid to reflect card size/orientation changes.
	
	refresh_effects: when true, fully refresh card effect configurations.
	preserve_data: when true (default), keep the existing data cache and active
	cards; only recalculate layout/geometry. Set false only when the underlying
	data model changed (filter, search, game add/remove)."""
	_update_grid_orientation()
	
	# Apply zoom from centralized card settings state (per-mode).
	if UIManager and UIManager.card_settings_state and games_grid:
		if games_grid.view_mode == VirtualScrollGridContainer.ViewMode.GRID:
			games_grid.target_card_width_ratio = UIManager.card_settings_state.card_zoom_ratio
		else:
			games_grid.target_card_width_ratio = UIManager.card_settings_state.card_zoom_list_ratio
	
	if refresh_effects:
		# Effect configuration changed.
		if preserve_data:
			_refresh_grid_dimensions()
			games_grid.refresh_all_card_effects(true)
		elif _total_count_load_pending:
			# A count load is already in flight; just refresh dimensions for now.
			_refresh_grid_dimensions()
		else:
			# Use callback version to ensure dimensions refresh BEFORE rebuilding
			# effects, so cards are rebuilt against final bounds.
			_load_total_count(false, false, func():
				_refresh_grid_dimensions()
				games_grid.refresh_all_card_effects(true)
			)
	else:
		# Force grid to recalculate layout, preserve cache for performance
		_refresh_grid_dimensions()
		if preserve_data:
			if not _total_count_load_pending:
				_load_total_count(true, true)
		else:
			if not _total_count_load_pending:
				_load_total_count(false, false)

## Returns true when intro animations are complete and cards can accept focus
## Note: Intro animations have been removed, so this always returns true
func are_intro_animations_complete() -> bool:
	return true

func _on_download_completed(_item_id: String, success: bool, _message: String):
	# During an update-all session, emulator downloads complete in bursts and
	# each one would rebuild the whole grid - the session's
	# update_session_finished signal triggers one rebuild at the end instead.
	if LaunchManager and LaunchManager.update and LaunchManager.update.is_session_active():
		return
	# Refresh when a download completes (game may now show in home view).
	# preserve_cache=false: a download changes the data model, so the merged
	# DB+GameNative cache must be rebuilt or the new game never materializes.
	if success:
		_load_total_count(false, false)

func _on_update_session_finished(_succeeded: Array, _failed: Array):
	_load_total_count(false, false)

func _on_database_ready():
	print("[DEBUG] _on_database_ready called")
	# One-shot: the manual is_database_ready() path in _ready() and the signal
	# can BOTH fire when the signal is emitted after this view connects (e.g.
	# delayed by startup cache warm-up). A second _load_total_count would force
	# a redundant buffer refresh on the settled grid.
	if _database_ready_handled:
		print("[DEBUG] _on_database_ready already handled, skipping duplicate")
		return
	_database_ready_handled = true
	_load_total_count()
	# Warm the merged-games cache for the first page in the background so the
	# grid's initial items_request can hit the cache instead of waiting on the
	# DB. Deferred a few frames: the prefetch hogs the DB worker for ~100ms,
	# which stalls the startup settle if it runs inside that window.
	if _total_games > 0 and _db_games_count > 0:
		_prefetch_first_page_deferred()

func _prefetch_first_page_deferred() -> void:
	for i in range(3):
		await get_tree().process_frame
	if not is_inside_tree():
		return
	_prefetch_first_page()

func _on_database_failed(_error: String):
	_is_loading = false
	_total_count_load_pending = false
	_update_status("Database unavailable - check storage permissions, then restart the app")

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
	_load_total_count(false, false, func():
		_refresh_grid_dimensions()
	, false)

func _on_gamenative_games_updated():
	"""Called when GameNative games are added or removed - refresh grid."""
	# Reload total count and refresh grid (don't preserve cache)
	_load_total_count(false)

func _refresh_grid_dimensions() -> void:
	"""Recalculate grid layout using the deterministic available size."""
	if not games_grid:
		return
	if UIManager:
		var available_size = UIManager.compute_grid_available_size(games_grid, self)
		games_grid.recalculate_layout_with_size(available_size)
	else:
		games_grid.refresh_dimensions()

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
	# Catch up if sync_completed fired while this view was disconnected.
	_catch_up_missed_sync()
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
	var current_gamenative_count = LaunchManager.gamenative_get_game_count()
	if current_gamenative_count != _gamenative_games_count:
		push_warning("[HomeView] GameNative count mismatch: cached=%d, current=%d" % [_gamenative_games_count, current_gamenative_count])
		return false
	
	# Check if we have the expected number of games cached. Compare against the
	# grid's SOURCE count — "total" is padded with placeholder slots to fill the
	# last row, which would always mismatch and force a spurious reload.
	var range_info = games_grid.get_visible_range()
	var grid_total: int = range_info.get("source_total", range_info.total)
	if grid_total != _total_games:
		push_warning("[HomeView] Total games mismatch: cached=%d, expected=%d" % [grid_total, _total_games])
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
		"add_to_collection":
			UIManager.show_add_to_collection_picker(romm_id)
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
				SystemManager.notifications.show_notification("Deleting " + game.title + "...", SystemManager.notifications.Type.INFO)
				
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
					_load_total_count(false, false, func():
						_refresh_grid_dimensions()
						
						# Re-enable grid interaction
						if games_grid:
							games_grid.mouse_filter = Control.MOUSE_FILTER_PASS
						
						# Reset focus to home button
						if not is_inside_tree() or not get_tree():
							return
						var main = get_tree().get_root().get_node_or_null("Main")
						if main and main.has_method("reset_focus_to_home_button"):
							main.reset_focus_to_home_button()
						if SystemManager.audio:
							SystemManager.audio.play_sfx("error")
					)
				
				# Delete the game
				DataManager.delete_game_download(game, func(success: bool):
					if success:
						SystemManager.notifications.show_notification(game.title + " deleted", SystemManager.notifications.Type.SUCCESS)
						_refresh_after_delete.call()
					else:
						# File not found - ask user if they want to remove from DB anyway
						var on_confirm = func():
							M3Dialog.dismiss_current()
							var on_force_delete = func(force_success: bool):
								if force_success:
									SystemManager.notifications.show_notification(game.title + " removed from library", SystemManager.notifications.Type.SUCCESS)
									_refresh_after_delete.call()
								else:
									SystemManager.notifications.show_notification("Failed to remove " + game.title, SystemManager.notifications.Type.ERROR)
									if games_grid:
										games_grid.mouse_filter = Control.MOUSE_FILTER_PASS
							DataManager.delete_game_download(game, on_force_delete, true)
						
						var on_cancel = func():
							if games_grid:
								games_grid.mouse_filter = Control.MOUSE_FILTER_PASS
							if SystemManager.audio:
								SystemManager.audio.play_sfx("error")
						
						UIManager.show_confirm("File Not Found", "Game files for " + game.title + " were not found on disk. Remove from library anyway?", on_confirm, on_cancel, Callable(), {"cancel_text": "Cancel", "accept_text": "Remove"})
				)
		"hide":
			pass
		"add_to_steam":
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				SteamVDFWriter.add_game(game)
		"open_save_location":
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				DataManager.game_save.open_save_location(game)
