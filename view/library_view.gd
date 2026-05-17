class_name LibraryView
extends View

signal hero_game_changed(game: GameResource)

@onready var games_grid: VirtualScrollGridContainer = $MarginContainer/VBoxContainer/VirtualScrollGridContainer
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

func _ready():
	view_name = "Library"
	
	# Setup VirtualScrollGridContainer
	if not games_grid:
		push_error("[LibraryView] games_grid is null! Cannot initialize.")
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
	# If database is already ready, trigger the callback manually
	if DataManager.is_database_ready():
		_on_database_ready()
	DataManager.game_added.connect(_on_game_added)
	DataManager.game_updated.connect(_on_game_updated)
	DataManager.games_removed.connect(_on_games_removed)
	DataManager.sync_completed.connect(_on_sync_completed)
	DataManager.sync_progress.connect(_on_sync_progress)
	
	# NEW: Connect to batch updates for efficient UI during sync
	DataManager.games_batch_added.connect(_on_games_batch_added)
	
	# Connect to sync_started to clear cache before new sync begins
	DataManager.sync_started.connect(_on_sync_started)
	
	# Connect to download manager for downloads
	DownloadManager.download_progress.connect(_on_download_progress)
	DownloadManager.download_completed.connect(_on_download_completed)
	
	# Connect to UIManager modal signals
	UIManager.modal_item_selected.connect(_on_modal_item_selected)
	
	# Connect to focus changes for hero image
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	# Load platforms list for indicator
	_load_platforms_list()
	
	# Connect platform indicator signals
	if platform_indicator:
		platform_indicator.platform_selected.connect(_on_platform_selected)
		platform_indicator.cycle_prev_clicked.connect(_on_cycle_prev_clicked)
		platform_indicator.cycle_next_clicked.connect(_on_cycle_next_clicked)
		platform_indicator.search_clicked.connect(_on_search_button_clicked)
	
	# Create search overlay
	_setup_search_overlay()

func _setup_search_overlay():
	"""Create and setup the search overlay."""
	_search_overlay = SearchOverlay.new()
	_search_overlay.name = "SearchOverlay"
	_search_overlay.visible = false
	_search_overlay.search_submitted.connect(_on_search_submitted)
	_search_overlay.search_cancelled.connect(_on_search_cancelled)
	add_child(_search_overlay)

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
	if SettingsManager:
		var last_search_setting = SettingsManager.get_setting("library_last_search")
		if last_search_setting:
			last_search = last_search_setting.value
	_search_overlay.set_last_search(last_search)
	
	_search_overlay.show_overlay()

func _on_search_submitted(query: String):
	"""Handle search submission."""
	_search_query = query
	_is_search_active = true
	
	# Save last search to settings
	if SettingsManager:
		var last_search_setting = SettingsManager.get_setting("library_last_search")
		if last_search_setting:
			SettingsManager.set_setting(query, last_search_setting)
			SettingsManager.save_settings()
	
	_search_overlay.hide_overlay()
	
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
	_search_overlay.hide_overlay()
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
	
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_search_results_count(_search_query)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				return
			_total_games = count
			games_grid.set_total_count(count, false)
			
			# Reset scroll to top
			games_grid.scroll_to_index(0, false)
			
			# Refresh dimensions
			games_grid.refresh_dimensions()
			
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
	
	# Jump directly to the random index without scrolling
	games_grid.scroll_to_index(random_index, false)
	_focus_card_at_index(random_index)

func _focus_card_at_index(index: int) -> void:
	"""Focus the game card at the specified index."""
	if not visible:
		return
	if not UIManager.is_current_view(view_name):
		return
	var card = games_grid.get_card_at_index(index)
	if card and card is GameCard:
		if card.card_input:
			card.card_input.grab_focus()

func _focus_first_card() -> void:
	"""Focus the first game card in the grid."""
	if not visible:  # Don't try to focus if view is hidden
		return
	if not UIManager.is_current_view(view_name):  # Don't focus if not current view
		return
	var first_card = games_grid.get_card_at_index(0)
	if first_card and first_card is GameCard:
		if first_card.card_input:
			first_card.card_input.grab_focus()

func _cycle_platform(direction: int) -> void:
	"""Cycle to next/previous platform filter."""
	if _is_loading:
		return
	
	# Play platform switch sound effect
	if AudioManager:
		AudioManager.play_sfx("snap")
	
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
	
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_total_games_count(_current_platform_slug)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				return
			_total_games = count
			games_grid.set_total_count(count, preserve_cache)
			
			# Reset scroll to top when switching platforms
			games_grid.scroll_to_index(0, false)
			
			# Recalculate grid dimensions to fix layout after platform filter change
			games_grid.refresh_dimensions()
			
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
	if AudioManager:
		AudioManager.play_sfx("snap")
	
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
	MemoryManager.queue_db_task(
		func():
			var count = DataManager.get_total_games_count(_current_platform_slug)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				return
			_total_games = count
			games_grid.set_total_count(count, preserve_cache)
			_update_status("Showing 0-0 of %d games" % count)
			_is_loading = false
	)

func _load_total_count_with_callback(preserve_cache: bool = false, on_complete: Callable = Callable()):
	"""Get total game count for current platform filter and call callback when complete."""
	if _is_search_active:
		_is_loading = true
		MemoryManager.queue_db_task(
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
				games_grid.set_total_count(count, preserve_cache)
				_is_loading = false
				if on_complete.is_valid():
					on_complete.call()
		)
		return
	
	_is_loading = true
	_update_status("Loading library...")
	
	MemoryManager.queue_db_task(
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
			games_grid.set_total_count(count, preserve_cache)
			_update_status("Showing 0-0 of %d games" % count)
			_is_loading = false
			if on_complete.is_valid():
				on_complete.call()
	)

func _update_status(text: String):
	# Status bar removed - no-op
	pass

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

func _on_items_requested(offset: int, limit: int, is_preload: bool = false):
	"""Handle database query requests from VirtualScrollGridContainer."""
	if _is_search_active:
		MemoryManager.queue_db_task(
			func():
				var games = DataManager.search_games_paginated(_search_query, offset, limit)
				return games,
			func(games: Array[GameResource]):
				games_grid.on_items_loaded(games, offset, is_preload)
		)
	else:
		MemoryManager.queue_db_task(
			func():
				var games = DataManager.get_games_paginated(offset, limit, "title", true, _current_platform_slug)
				return games,
			func(games: Array[GameResource]):
				games_grid.on_items_loaded(games, offset, is_preload)
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
		if _is_search_active:
			_load_total_count_with_search()
		else:
			_load_total_count(true)

func _on_card_created(card: Control, index: int):
	"""Connect signals to newly created cards."""
	if card is GameCard:
		card.download_requested.connect(_on_download_requested)

func _on_download_requested(game: GameResource):
	# Use the selected sibling's ID and file name if one is selected
	var active_game_id = game.get_active_game_id()
	var active_file_name = game.get_active_file_name()
	
	var download_url = NetworkManager.get_romm_download_url(active_game_id, active_file_name)
	var root_folder = SettingsManager.get_setting("games_root_folder")
	if not root_folder or root_folder.value == "":
		_update_status("Error: Games folder not set")
		NotificationManager.show_notification("Error: Games folder not set", NotificationManager.Type.ERROR)
		return
	
	var destination_path = root_folder.value + "/" + game.platform_slug + "/" + active_file_name
	var item_id = DownloadManager.queue_download(download_url, destination_path, "game", game.get_display_name(), false, "", game, {}, active_game_id)
	
	if item_id != "":
		_update_status("Queued: " + game.get_display_name())
	else:
		_update_status("Failed to queue download")

func _on_download_progress(item_id: String, progress: float):
	pass

func _on_download_completed(item_id: String, success: bool, message: String):
	if success:
		_update_status("Download completed")
	else:
		_update_status("Download failed: " + message)

func _on_database_ready():
	_load_total_count()

func _on_game_added(game: GameResource):
	# Refresh total count and grid (for individual additions outside sync)
	_load_total_count()

func _on_games_batch_added(platform_slug: String, start_index: int, games: Array[GameResource]):
	"""Handle batch game additions during sync without full grid rebuild."""
	# Filter out games without cover art based on setting
	var hide_no_covers = true
	var setting = SettingsManager.get_setting("hide_games_without_covers")
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

func _on_game_updated(game: GameResource):
	# Find and update any visible cards for this game
	var range_info = games_grid.get_visible_range()
	for i in range(range_info.buffer_start, range_info.buffer_start + range_info.buffer_size):
		var card = games_grid.get_card_at_index(i)
		if card and card is GameCard and card.game and card.game.romm_id == game.romm_id:
			var is_visible = i >= range_info.start and i < range_info.end
			card.set_game_with_priority(game, is_visible)
			break

func _on_games_removed(platform_slug: String):
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
		_search_overlay.hide_overlay()

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
		"hide":
			pass

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
			push_warning("[LibraryView] Max deferred rebuild attempts reached with invalid size, aborting")
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
	if not SettingsManager:
		return
	
	var mode_setting = SettingsManager.get_setting("library_layout_mode")
	var layout_mode = mode_setting.value if mode_setting else 0
	
	# Migrate old 4-mode values to new 3-mode values
	match layout_mode:
		0, 1:
			games_grid.view_mode = VirtualScrollGridContainer.ViewMode.GRID
		2:
			games_grid.view_mode = VirtualScrollGridContainer.ViewMode.CAROUSEL
		3:
			games_grid.view_mode = VirtualScrollGridContainer.ViewMode.LIST
	
	var grid_vertical_setting = SettingsManager.get_setting("library_grid_vertical")
	games_grid.grid_vertical = grid_vertical_setting.value if grid_vertical_setting else true
	
	var focus_scale_setting = SettingsManager.get_setting("library_focus_scale")
	games_grid.focus_scale = 1.0 + (focus_scale_setting.value if focus_scale_setting else 0.08)

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
	match setting.property_name:
		"library_grid_margin_x", "library_grid_margin_y":
			_update_grid_margins()
			# Also refresh the grid layout to recalculate with new margins
			games_grid.refresh_dimensions()
		"card_effect_config":
			mark_for_rebuild("Card effects changed")
		"library_show_title_mode":
			if games_grid:
				games_grid.refresh_all_card_effects()
