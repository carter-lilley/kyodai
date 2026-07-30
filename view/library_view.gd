class_name LibraryView
extends View

const DEBUG_LOG: bool = false

# games_grid is declared in base View class; initialize here
@onready var margin_container: MarginContainer = $MarginContainer
@onready var platform_indicator: PlatformIndicator = $MarginContainer/VBoxContainer/PlatformIndicator

var _total_games: int = 0
var _is_loading: bool = false

# Platform cycling state
var _platforms: Array[Dictionary] = []  # [{slug, name, count}, ...]
var _current_platform_index: int = -1  # -1 = All Games, 0+ = specific platform
var _current_platform_slug: String = ""  # Empty = All Games

# Search state
var _search_overlay: SearchOverlay = null
var _search_query: String = ""
var _is_search_active: bool = false
var _pre_search_platform_index: int = -1  # Remember platform before search

func _exit_tree() -> void:
	# Disconnect from autoload signals so the view can be freed when the tree tears down.
	if DataManager:
		if DataManager.setting_changed.is_connected(_on_setting_changed):
			DataManager.setting_changed.disconnect(_on_setting_changed)
	if DataManager:
		if DataManager.database_ready.is_connected(_on_database_ready):
			DataManager.database_ready.disconnect(_on_database_ready)
		if DataManager.game_added.is_connected(_on_game_added):
			DataManager.game_added.disconnect(_on_game_added)
		if DataManager.game_updated.is_connected(_on_game_updated):
			DataManager.game_updated.disconnect(_on_game_updated)
		if DataManager.games_removed.is_connected(_on_games_removed):
			DataManager.games_removed.disconnect(_on_games_removed)
		if DataManager.sync_completed.is_connected(_on_sync_completed):
			DataManager.sync_completed.disconnect(_on_sync_completed)
		if DataManager.sync_progress.is_connected(_on_sync_progress):
			DataManager.sync_progress.disconnect(_on_sync_progress)
		if DataManager.games_batch_added.is_connected(_on_games_batch_added):
			DataManager.games_batch_added.disconnect(_on_games_batch_added)
		if DataManager.sync_started.is_connected(_on_sync_started):
			DataManager.sync_started.disconnect(_on_sync_started)
	if UIManager.modal_item_selected.is_connected(_on_modal_item_selected):
		UIManager.modal_item_selected.disconnect(_on_modal_item_selected)
	# The search overlay is created as an orphan; free it explicitly.
	if _search_overlay and is_instance_valid(_search_overlay):
		if _search_overlay.get_parent() == null:
			_search_overlay.free()
		_search_overlay = null

func _enter_tree() -> void:
	_setup_search_overlay()
	_connect_signals()

func _connect_signals() -> void:
	if not DataManager:
		return
	if not DataManager.setting_changed.is_connected(_on_setting_changed):
		DataManager.setting_changed.connect(_on_setting_changed)
	if not DataManager.database_ready.is_connected(_on_database_ready):
		DataManager.database_ready.connect(_on_database_ready)
		if DataManager.is_database_ready():
			_on_database_ready()
	if not DataManager.database_failed.is_connected(_on_database_failed):
		DataManager.database_failed.connect(_on_database_failed)
	if not DataManager.game_added.is_connected(_on_game_added):
		DataManager.game_added.connect(_on_game_added)
	if not DataManager.game_updated.is_connected(_on_game_updated):
		DataManager.game_updated.connect(_on_game_updated)
	if not DataManager.games_removed.is_connected(_on_games_removed):
		DataManager.games_removed.connect(_on_games_removed)
	if not DataManager.sync_completed.is_connected(_on_sync_completed):
		DataManager.sync_completed.connect(_on_sync_completed)
	if not DataManager.sync_progress.is_connected(_on_sync_progress):
		DataManager.sync_progress.connect(_on_sync_progress)
	if not DataManager.games_batch_added.is_connected(_on_games_batch_added):
		DataManager.games_batch_added.connect(_on_games_batch_added)
	if not DataManager.sync_started.is_connected(_on_sync_started):
		DataManager.sync_started.connect(_on_sync_started)
	if UIManager and not UIManager.modal_item_selected.is_connected(_on_modal_item_selected):
		UIManager.modal_item_selected.connect(_on_modal_item_selected)

func _ready():
	view_name = "Library"
	
	# Initialize grid reference (declared in base View class)
	games_grid = $MarginContainer/VBoxContainer/VirtualScrollGridContainer as VirtualScrollGridContainer
	
	# Setup VirtualScrollGridContainer
	if not games_grid:
		push_error("[LibraryView] games_grid is null! Cannot initialize.")
		return
	
	var card_scene = load("res://components/game_card.tscn") as PackedScene
	var initial_zoom: float = UIManager.card_settings_state.card_zoom_ratio if UIManager and UIManager.card_settings_state else 0.25
	games_grid.setup(card_scene, 0, initial_zoom)
	games_grid.items_requested.connect(_on_items_requested)
	games_grid.visible_range_changed.connect(_on_visible_range_changed)
	games_grid.item_created.connect(_on_card_created)
	
	# Setup vertical layout from settings
	_update_grid_orientation()
	
	# Load platforms list for indicator
	_load_platforms_list()
	
	# Connect platform indicator signals
	if platform_indicator:
		platform_indicator.platform_selected.connect(_on_platform_selected)
		platform_indicator.cycle_prev_clicked.connect(_on_cycle_prev_clicked)
		platform_indicator.cycle_next_clicked.connect(_on_cycle_next_clicked)
		platform_indicator.search_clicked.connect(_on_search_button_clicked)
		platform_indicator.filter_clicked.connect(_on_filter_button_clicked)
	
	# Filter sheet is created lazily on first open so it doesn't hold resources
	# for the entire session.
	
	# Let the base View class own the focus signal connection.
	reconnect_viewport()

func _setup_search_overlay():
	"""Create and setup the search overlay. Idempotent so it survives reparenting."""
	if _search_overlay and is_instance_valid(_search_overlay):
		return
	_search_overlay = SearchOverlay.new()
	_search_overlay.name = "SearchOverlay"
	_search_overlay.search_submitted.connect(_on_search_submitted)
	_search_overlay.search_cancelled.connect(_on_search_cancelled)

func _refresh_grid_dimensions() -> void:
	"""Recalculate grid layout using the deterministic available size."""
	if not games_grid:
		return
	if UIManager:
		var available_size = UIManager.compute_grid_available_size(games_grid, self)
		games_grid.recalculate_layout_with_size(available_size)
	else:
		games_grid.refresh_dimensions()

func _on_filter_button_clicked() -> void:
	"""Handle filter button click — open the library filter side sheet."""
	LibraryFilterSheet.show_sheet()

func _on_search_button_clicked() -> void:
	"""Handle search button click — clear active search or show overlay."""
	if _is_search_active:
		_clear_search()
		if games_grid:
			games_grid.grab_focus()
		call_deferred("_focus_first_card")
	else:
		_show_search_overlay()

func _show_search_overlay():
	"""Show the search overlay."""
	# Remember current platform before search
	_pre_search_platform_index = _current_platform_index
	
	# Load last search from settings
	var last_search = ""
	if DataManager:
		var last_search_setting = DataManager.get_setting("library_last_search")
		if last_search_setting:
			last_search = last_search_setting.value
	_search_overlay.set_last_search(last_search)
	
	_search_overlay.show_overlay()

func _on_search_submitted(query: String):
	"""Handle search submission."""
	_search_query = query
	_is_search_active = true
	
	# Save last search to settings
	if DataManager:
		var last_search_setting = DataManager.get_setting("library_last_search")
		if last_search_setting:
			DataManager.set_setting(query, last_search_setting)
			DataManager.save_settings()
	
	_search_overlay.dismiss()
	
	# Explicitly grab focus on the games grid to ensure keyboard closes and focus is set
	if games_grid:
		games_grid.grab_focus()
	
	# Update platform indicator to show SEARCH
	if platform_indicator:
		platform_indicator.show_search_mode(query)
		platform_indicator.set_search_active(true)
	
	# Reload grid with search results
	_load_total_count_with_search()

func _on_search_cancelled():
	"""Handle search cancellation."""
	_search_overlay.dismiss()
	_search_query = ""
	# Explicitly grab focus on the games grid
	if games_grid:
		games_grid.grab_focus()
	# Return focus to the first card in the grid
	call_deferred("_focus_first_card")

func try_clear_search() -> bool:
	"""Clear active search if one is active. Returns true if search was cleared."""
	if _is_search_active:
		_clear_search()
		return true
	return false

func _clear_search():
	"""Clear active search and return to normal platform view."""
	if _is_search_active:
		_is_search_active = false
		_search_query = ""
		
		# Restore previous platform filter
		if _pre_search_platform_index != -1:
			_current_platform_index = _pre_search_platform_index
			if _current_platform_index >= 0 and _current_platform_index < _platforms.size():
				_current_platform_slug = _platforms[_current_platform_index].slug
			else:
				_current_platform_slug = ""
				_current_platform_index = -1
		
		# Update platform indicator
		if platform_indicator:
			platform_indicator.update_display(_platforms, _current_platform_index)
			platform_indicator.set_search_active(false)
		
		# Reload grid
		_load_total_count_with_platform(false)

func _load_total_count_with_search():
	"""Load total count for search results."""
	_is_loading = true
	
	SystemManager.memory.queue_db_task(
		func():
			var count = DataManager.get_search_results_count(_search_query)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				return
			_total_games = count
			var available_size = UIManager.compute_grid_available_size(games_grid, self) if UIManager else Vector2.ZERO
			games_grid.set_total_count_with_available_size(count, available_size, false)
			
			# Reset scroll to top
			games_grid.scroll_to_index(0, false)
			
			# Refresh dimensions
			_refresh_grid_dimensions()
			
			# Focus first card
			call_deferred("_focus_first_card")
			
			_is_loading = false
	)

func _load_platforms_list() -> void:
	"""Load platforms and initialize platform indicator."""
	_platforms = DataManager.get_platforms_with_games()
	
	# Initialize platform indicator with "All" selected
	if platform_indicator:
		platform_indicator.update_display(_platforms, _current_platform_index)

func _input(event: InputEvent) -> void:
	"""Handle platform cycling input using custom actions."""
	# Only handle input when this view is active
	if not UIManager.is_current_view(view_name):
		return
	
	# Don't handle input if search overlay is active
	if _search_overlay and _search_overlay.is_active():
		return
	
	# Handle activate search
	if event.is_action_pressed("activate_search"):
		_show_search_overlay()
		accept_event()
		return
	
	# Handle platform cycling - clears search if active
	if event.is_action_pressed("cycle_platform_next"):
		_clear_search()
		_cycle_platform(1)
		accept_event()
	elif event.is_action_pressed("cycle_platform_prev"):
		_clear_search()
		_cycle_platform(-1)
		accept_event()
	elif event.is_action_pressed("random_game"):
		_focus_random_card()
		accept_event()

func _focus_random_card() -> void:
	"""Focus a random game card in the grid."""
	if _total_games == 0:
		return
	
	# Generate random index within current filtered set
	var random_index = randi() % _total_games
	
	# Jump directly to the random index and focus once the window is rebuilt.
	games_grid.scroll_to_index_and_focus(random_index, false)

func _focus_first_card() -> void:
	"""Focus the first game card in the grid."""
	if not visible:  # Don't try to focus if view is hidden
		return
	if not UIManager.is_current_view(view_name):  # Don't focus if not current view
		return
	var first_card = games_grid.get_card_at_index(0)
	if first_card and first_card is GameCard:
		first_card.grab_focus()

func _cycle_platform(direction: int) -> void:
	"""Cycle to next/previous platform filter."""
	if _is_loading:
		return
	
	# Play platform switch sound effect
	if SystemManager.audio:
		SystemManager.audio.play_sfx("snap")
	
	# Ensure platforms are loaded
	if _platforms.is_empty():
		_load_platforms_list()
	
	if _platforms.is_empty():
		return
	
	# Calculate new index
	var new_index = _current_platform_index + direction
	
	# Wrap around logic: -1 = All Games, 0+ = specific platforms
	if new_index < -1:
		new_index = _platforms.size() - 1
	elif new_index >= _platforms.size():
		new_index = -1
	
	_current_platform_index = new_index
	
	# Update platform indicator UI
	if platform_indicator:
		platform_indicator.update_display(_platforms, _current_platform_index)
	
	if _current_platform_index == -1:
		_current_platform_slug = ""
		_update_status("All Games - Loading...")
	else:
		var platform = _platforms[_current_platform_index]
		_current_platform_slug = platform.slug
		_update_status("%s - Loading..." % platform.name)
	
	# Reload the grid with new filter
	_load_total_count_with_platform(false)

func _load_total_count_with_platform(preserve_cache: bool = false) -> void:
	"""Get total game count for current platform filter."""
	_is_loading = true
	
	SystemManager.memory.queue_db_task(
		func():
			var count = DataManager.get_total_games_count(_current_platform_slug)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				return
			_total_games = count
			var available_size = UIManager.compute_grid_available_size(games_grid, self) if UIManager else Vector2.ZERO
			games_grid.set_total_count_with_available_size(count, available_size, preserve_cache)
			
			# Reset scroll to top when switching platforms
			games_grid.scroll_to_index(0, false)
			
			# Recalculate grid dimensions to fix layout after platform filter change
			_refresh_grid_dimensions()
			
			# Focus the first card after platform switch
			# Use call_deferred to ensure cards are created and ready
			call_deferred("_focus_first_card")
			
			_is_loading = false
	)

func _on_platform_selected(platform_index: int) -> void:
	"""Handle platform selection from indicator click."""
	if _is_loading:
		return
	
	# Play platform switch sound effect
	if SystemManager.audio:
		SystemManager.audio.play_sfx("snap")
	
	# Ensure platforms are loaded
	if _platforms.is_empty():
		_load_platforms_list()
	
	if _platforms.is_empty():
		return
	
	# Set to the selected platform directly
	_current_platform_index = platform_index
	
	# Update platform indicator UI
	if platform_indicator:
		platform_indicator.update_display(_platforms, _current_platform_index)
	
	if _current_platform_index == -1:
		_current_platform_slug = ""
		_update_status("All Games - Loading...")
	else:
		var platform = _platforms[_current_platform_index]
		_current_platform_slug = platform.slug
		_update_status("%s - Loading..." % platform.name)
	
	# Reload the grid with new filter
	_load_total_count_with_platform(false)

func _on_cycle_prev_clicked() -> void:
	"""Handle click on previous arrow in platform indicator."""
	_cycle_platform(-1)

func _on_cycle_next_clicked() -> void:
	"""Handle click on next arrow in platform indicator."""
	_cycle_platform(1)

func _load_total_count(preserve_cache: bool = false):
	"""Get total game count for virtual scrolling setup."""
	if _is_search_active:
		_load_total_count_with_search()
		return
	
	_is_loading = true
	_update_status("Loading library...")
	
	# Query total count asynchronously
	SystemManager.memory.queue_db_task(
		func():
			var count = DataManager.get_total_games_count(_current_platform_slug)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				return
			_total_games = count
			var available_size = UIManager.compute_grid_available_size(games_grid, self) if UIManager else Vector2.ZERO
			games_grid.set_total_count_with_available_size(count, available_size, preserve_cache)
			_update_status("Showing 0-0 of %d games" % count)
			_is_loading = false
	)

func _load_total_count_with_callback(preserve_cache: bool = false, on_complete: Callable = Callable()):
	"""Get total game count for current platform filter and call callback when complete."""
	if _is_search_active:
		_is_loading = true
		SystemManager.memory.queue_db_task(
			func():
				var count = DataManager.get_search_results_count(_search_query)
				return count,
			func(count: int):
				if not is_instance_valid(games_grid):
					_is_loading = false
					if on_complete.is_valid():
						on_complete.call()
					return
				_total_games = count
				var available_size = UIManager.compute_grid_available_size(games_grid, self) if UIManager else Vector2.ZERO
				games_grid.set_total_count_with_available_size(count, available_size, preserve_cache)
				_is_loading = false
				if on_complete.is_valid():
					on_complete.call()
		)
		return
	
	_is_loading = true
	_update_status("Loading library...")
	
	SystemManager.memory.queue_db_task(
		func():
			var count = DataManager.get_total_games_count(_current_platform_slug)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				if on_complete.is_valid():
					on_complete.call()
				return
			_total_games = count
			var available_size = UIManager.compute_grid_available_size(games_grid, self) if UIManager else Vector2.ZERO
			games_grid.set_total_count_with_available_size(count, available_size, preserve_cache)
			_update_status("Showing 0-0 of %d games" % count)
			_is_loading = false
			if on_complete.is_valid():
				on_complete.call()
	)

func _on_items_requested(offset: int, limit: int, is_preload: bool = false):
	"""Handle database query requests from VirtualScrollGridContainer."""
	var request_start_us := Time.get_ticks_usec()
	if _is_search_active:
		SystemManager.memory.queue_db_task(
			func():
				var db_start_us := Time.get_ticks_usec()
				var games = DataManager.search_games_paginated(_search_query, offset, limit)
				if DEBUG_LOG: print("[LibraryView] DB task (search): offset=", offset, " limit=", limit, " db_elapsed_us=", Time.get_ticks_usec() - db_start_us, " total_request_us=", Time.get_ticks_usec() - request_start_us)
				return games,
			func(games: Array[GameResource]):
				var callback_start_us := Time.get_ticks_usec()
				games_grid.on_items_loaded(games, offset, is_preload)
				if DEBUG_LOG: print("[LibraryView] on_items_loaded callback (search): offset=", offset, " count=", games.size(), " elapsed_us=", Time.get_ticks_usec() - callback_start_us, " total_request_us=", Time.get_ticks_usec() - request_start_us)
		)
	else:
		SystemManager.memory.queue_db_task(
			func():
				var db_start_us := Time.get_ticks_usec()
				var games = DataManager.get_games_paginated(offset, limit, "title", true, _current_platform_slug)
				if DEBUG_LOG: print("[LibraryView] DB task: offset=", offset, " limit=", limit, " platform=", _current_platform_slug, " db_elapsed_us=", Time.get_ticks_usec() - db_start_us, " total_request_us=", Time.get_ticks_usec() - request_start_us)
				return games,
			func(games: Array[GameResource]):
				var callback_start_us := Time.get_ticks_usec()
				games_grid.on_items_loaded(games, offset, is_preload)
				if DEBUG_LOG: print("[LibraryView] on_items_loaded callback: offset=", offset, " count=", games.size(), " elapsed_us=", Time.get_ticks_usec() - callback_start_us, " total_request_us=", Time.get_ticks_usec() - request_start_us)
		)

func _on_visible_range_changed(start_index: int, end_index: int, total_count: int):
	"""Update status label with current visible range and platform/search."""
	if total_count == 0:
		if _is_search_active:
			_update_status("Search: No results found")
		elif _current_platform_index == -1:
			_update_status("No games found")
		else:
			var platform_name = _get_current_platform_name()
			_update_status("%s - No games" % platform_name)
	else:
		var start_num = start_index + 1
		var end_num = mini(end_index, total_count)
		if _is_search_active:
			_update_status("Search: %d-%d of %d results" % [start_num, end_num, total_count])
		elif _current_platform_index == -1:
			_update_status("Showing %d-%d of %d games" % [start_num, end_num, total_count])
		else:
			var platform_name = _get_current_platform_name()
			_update_status("%s: %d-%d of %d" % [platform_name, start_num, end_num, total_count])

func _get_current_platform_name() -> String:
	"""Get the display name of the current platform."""
	if _current_platform_index == -1:
		return "All Games"
	elif _current_platform_index >= 0 and _current_platform_index < _platforms.size():
		return _platforms[_current_platform_index].get("name", "Unknown")
	return "Unknown"

func rebuild_grid(refresh_effects: bool = false, preserve_data: bool = true) -> void:
	"""Rebuild the grid to reflect card size/orientation changes.
	
	refresh_effects: when true, fully refresh card effect configurations.
	preserve_data: when true (default), keep the existing data cache and active
	cards; only recalculate layout/geometry. Set false only when the underlying
	data model changed (filter, search, game add/remove)."""
	
	_update_grid_orientation()
	
	# Apply zoom from centralized card settings state
	if UIManager and UIManager.card_settings_state and games_grid:
		games_grid.target_card_width_ratio = UIManager.card_settings_state.card_zoom_ratio
	
	if refresh_effects:
		# Effect configuration changed: reload data if we're also clearing the cache,
		# then refresh dimensions and effects.
		if preserve_data:
			_refresh_grid_dimensions()
			games_grid.refresh_all_card_effects(true)
		else:
			# Use callback version to ensure dimensions refresh BEFORE rebuilding
			# effects, so cards are rebuilt against final bounds.
			_load_total_count_with_callback(false, func():
				# Refresh dimensions first to establish final card bounds.
				_refresh_grid_dimensions()
				# Then refresh existing cards.
				games_grid.refresh_all_card_effects(true)
			)
	else:
		# Force grid to recalculate layout, preserve cache for performance
		_refresh_grid_dimensions()
		if preserve_data:
			# Data is unchanged; just make sure visible cards have their data.
			games_grid._request_missing_data()
		else:
			if _is_search_active:
				_load_total_count_with_search()
			else:
				_load_total_count(true)

func _on_database_ready():
	_load_total_count()

func _on_database_failed(_error: String):
	_is_loading = false
	_update_status("Database unavailable - check storage permissions, then restart the app")

func _on_game_added(_game: GameResource):
	# Refresh total count and grid (for individual additions outside sync)
	_load_total_count()

func _on_games_batch_added(_platform_slug: String, _start_index: int, games: Array[GameResource]):
	"""Handle batch game additions during sync without full grid rebuild."""
	# Filter out games without cover art based on setting
	var hide_no_covers = true
	var setting = DataManager.get_setting("hide_games_without_covers")
	if setting:
		hide_no_covers = setting.value
	
	var filtered_games: Array[GameResource] = []
	for game in games:
		if not hide_no_covers or game.has_cover_art:
			filtered_games.append(game)
	
	if filtered_games.size() == 0:
		return
	
	# Increment total count without rebuilding buffer
	var actual_start = games_grid.increment_total_count(filtered_games.size())
	
	# Cache games for when user scrolls to them
	games_grid.cache_items_at_offset(filtered_games, actual_start)
	
	# Only refresh visible cards if they fall within current viewport
	games_grid.refresh_if_visible(actual_start, actual_start + filtered_games.size() - 1)
	
	# Update status label with current counts
	var range_info = games_grid.get_visible_range()
	if range_info.total > 0:
		var start_num = range_info.start + 1
		var end_num = mini(range_info.end, range_info.total)
		_update_status("Showing %d-%d of %d games" % [start_num, end_num, range_info.total])

func _on_games_removed(_platform_slug: String):
	_reload_after_change()

func _reload_after_change():
	"""Reload after games added/removed."""
	_load_total_count()

func _on_sync_progress(percent: float, current: int, total: int):
	_update_status("Syncing... %d/%d games (%.0f%%)" % [current, total, percent])

func _on_sync_completed(success: bool, message: String):
	if success:
		_update_status("Sync complete. Finalizing...")
		
		# Reload platforms list to pick up any new platforms
		_load_platforms_list()
		
		# Reset to "All Games" view since platform order may have changed
		_current_platform_index = -1
		_current_platform_slug = ""
		
		# Final consistency check - reload total count from database
		# Clear cache (false) to prevent duplicate detection errors after sync
		# Use call_deferred to let sync completion finish before heavy grid refresh
		call_deferred("_deferred_reload_after_sync")
	else:
		_update_status("Sync failed: " + message)

func _deferred_reload_after_sync():
	_load_total_count(false)
	_update_status("Library reloaded after sync")

func _on_sync_started():
	"""Clear grid cache when sync starts to prevent position mismatches.
	
	During a resync, games are added in API order but the database returns them
	sorted by title. Clearing the cache at sync start prevents duplicate warnings
	and ensures games appear at correct positions."""
	if games_grid:
		# Reset total to 0 with preserve_cache=false to clear everything
		games_grid.set_total_count(0, false)
		_update_status("Sync starting...")

func on_view_show():
	super.on_view_show()
	# Ensure search overlay is hidden when returning to this view
	if _search_overlay and _search_overlay.is_active():
		_search_overlay.dismiss()
	# Ensure the grid catches up if it initialized while hidden (e.g. Library tab).
	if games_grid:
		if games_grid._active_cards.size() == 0 and games_grid._total_items > 0 and games_grid.size.x > 0 and games_grid.size.y > 0:
			games_grid._initial_load()
		games_grid._request_missing_data()

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
		"add_to_steam":
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				SteamVDFWriter.add_game(game)
		"delete":
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				SystemManager.notifications.show_notification("Deleting " + game.title + "...", SystemManager.notifications.Type.INFO)

				if games_grid:
					games_grid.mouse_filter = Control.MOUSE_FILTER_IGNORE

				var _refresh_after_delete = func():
					_load_total_count_with_platform(false)
					if games_grid:
						games_grid.mouse_filter = Control.MOUSE_FILTER_PASS
					if SystemManager.audio:
						SystemManager.audio.play_sfx("error")

				DataManager.delete_game_download(game, func(success: bool):
					if success:
						SystemManager.notifications.show_notification(game.title + " deleted", SystemManager.notifications.Type.SUCCESS)
						_refresh_after_delete.call()
					else:
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
