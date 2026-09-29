class_name LibraryView
extends View

const DEBUG_LOG: bool = false

# games_grid is declared in base View class; initialize here
@onready var margin_container: MarginContainer = $MarginContainer
@onready var platform_indicator: PlatformIndicator = $MarginContainer/VBoxContainer/PlatformIndicator

var _total_games: int = 0
var _is_loading: bool = false

# One-shot guard: the manual is_database_ready() path and the database_ready
# signal can both fire for the same view.
var _database_ready_handled: bool = false

# Platform cycling state
var _platforms: Array[Dictionary] = []  # [{slug, name, count}, ...]
var _current_platform_index: int = -1  # -1 = All Games, 0+ = specific platform
var _current_platform_slug: String = ""  # Empty = All Games

# Search state
var _search_overlay: SearchOverlay = null
var _search_query: String = ""
var _is_search_active: bool = false
var _pre_search_platform_index: int = -1  # Remember platform before search

# Filter state (IGDB metadata chips; kind -> Array of selected values)
var _active_filters: Dictionary = {}

# A-Z letter navigation overlay (child of games_grid; does not affect layout)
var _az_carousel: AZLetterCarousel = null
var _letter_first_index: Dictionary = {}  # letter -> first grid index

func _exit_tree() -> void:
	# Disconnect from autoload signals so the view can be freed when the tree tears down.
	if DataManager:
		if DataManager.setting_changed.is_connected(_on_setting_changed):
			DataManager.setting_changed.disconnect(_on_setting_changed)
	if DataManager:
		if DataManager.database_ready.is_connected(_on_database_ready):
			DataManager.database_ready.disconnect(_on_database_ready)
		if DataManager.game_updated.is_connected(_on_game_updated):
			DataManager.game_updated.disconnect(_on_game_updated)
		if DataManager.games_removed.is_connected(_on_games_removed):
			DataManager.games_removed.disconnect(_on_games_removed)
		if DataManager.sync_completed.is_connected(_on_sync_completed):
			DataManager.sync_completed.disconnect(_on_sync_completed)
		if DataManager.sync_progress.is_connected(_on_sync_progress):
			DataManager.sync_progress.disconnect(_on_sync_progress)
	if is_instance_valid(SystemManager) and SystemManager.download and SystemManager.download.download_completed.is_connected(_on_download_completed):
		SystemManager.download.download_completed.disconnect(_on_download_completed)
	if is_instance_valid(LaunchManager) and LaunchManager.update and LaunchManager.update.update_session_finished.is_connected(_on_update_session_finished):
		LaunchManager.update.update_session_finished.disconnect(_on_update_session_finished)
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
	if not DataManager.game_updated.is_connected(_on_game_updated):
		DataManager.game_updated.connect(_on_game_updated)
	if not DataManager.games_removed.is_connected(_on_games_removed):
		DataManager.games_removed.connect(_on_games_removed)
	if not DataManager.sync_completed.is_connected(_on_sync_completed):
		DataManager.sync_completed.connect(_on_sync_completed)
	if not DataManager.sync_progress.is_connected(_on_sync_progress):
		DataManager.sync_progress.connect(_on_sync_progress)
	if SystemManager and SystemManager.download and not SystemManager.download.download_completed.is_connected(_on_download_completed):
		SystemManager.download.download_completed.connect(_on_download_completed)
	if LaunchManager and LaunchManager.update and not LaunchManager.update.update_session_finished.is_connected(_on_update_session_finished):
		LaunchManager.update.update_session_finished.connect(_on_update_session_finished)
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
	var initial_zoom: float = 0.25
	if UIManager and UIManager.card_settings_state:
		var zoom_state = UIManager.card_settings_state
		initial_zoom = zoom_state.card_zoom_ratio if zoom_state.layout_mode == 0 else zoom_state.card_zoom_list_ratio
	var phase_start_us := Time.get_ticks_usec()
	games_grid.setup(card_scene, 0, initial_zoom)
	print("[LibraryView] grid setup elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	games_grid.items_requested.connect(_on_items_requested)
	games_grid.visible_range_changed.connect(_on_visible_range_changed)
	games_grid.item_created.connect(_on_card_created)

	# Setup vertical layout from settings
	phase_start_us = Time.get_ticks_usec()
	_update_grid_orientation()
	print("[LibraryView] _update_grid_orientation elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Load platforms list for indicator
	phase_start_us = Time.get_ticks_usec()
	_load_platforms_list()
	print("[LibraryView] _load_platforms_list elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	
	# Connect platform indicator signals
	if platform_indicator:
		platform_indicator.platform_selected.connect(_on_platform_selected)
		platform_indicator.cycle_prev_clicked.connect(_on_cycle_prev_clicked)
		platform_indicator.cycle_next_clicked.connect(_on_cycle_next_clicked)
		platform_indicator.search_clicked.connect(_on_search_button_clicked)
		platform_indicator.filter_clicked.connect(_on_filter_button_clicked)

	# A-Z letter carousel overlaying the grid's right edge
	_setup_az_carousel()

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

func _setup_az_carousel() -> void:
	"""Create the A-Z letter carousel as a child of the grid Control.

	The grid does not arrange its direct children (only _flow_container's),
	so the carousel overlays the grid's right edge without affecting layout."""
	_az_carousel = AZLetterCarousel.new()
	_az_carousel.name = "AZLetterCarousel"
	_az_carousel.visible = false  # Shown once the letter map loads.
	_az_carousel.letter_selected.connect(_on_az_letter_selected)
	# Scrubbing teleports through many letters per second; suppress network
	# cover loads for the duration (cache-only) and fetch on finger-lift so
	# the download queue only serves the position the user settles on.
	_az_carousel.scrub_started.connect(func(): games_grid.set_scrub_cover_suppressed(true))
	_az_carousel.scrub_ended.connect(func(): games_grid.set_scrub_cover_suppressed(false))
	games_grid.add_child(_az_carousel)

func _load_letter_index() -> void:
	"""Query first-character run lengths and derive the letter -> index map."""
	if not _az_carousel:
		return
	var platform_slug := _current_platform_slug
	var filters := _active_filters.duplicate(true)
	var search_query := _search_query if _is_search_active else ""
	SystemManager.memory.queue_db_task(
		func():
			return DataManager.get_title_letter_runs(platform_slug, filters, search_query),
		func(runs: Array[Dictionary]):
			if not is_instance_valid(_az_carousel):
				return
			_apply_letter_runs(runs)
	)

func _apply_letter_runs(runs: Array[Dictionary]) -> void:
	var first_index: Dictionary = {}
	var ordered_letters: Array[String] = []
	var ordered_indices: Array[int] = []
	var idx := 0
	for run in runs:
		var key := _letter_key_for_char(str(run.get("letter", "")))
		if not first_index.has(key):
			first_index[key] = idx
			ordered_letters.append(key)
			ordered_indices.append(idx)
		idx += int(run.get("count", 0))
	_letter_first_index = first_index
	_az_carousel.set_letter_map(first_index, ordered_letters, ordered_indices)
	_az_carousel.visible = idx > 0

static func _letter_key_for_char(ch: String) -> String:
	if ch.is_empty():
		return "#"
	var up := ch.to_upper()
	if up >= "A" and up <= "Z":
		return up
	return "#"

func _on_az_letter_selected(letter: String, _from_drag: bool) -> void:
	if not games_grid:
		return
	var idx: int = _letter_first_index.get(letter, -1)
	if idx < 0:
		return
	# Always jump instantly: an animated cross-library jump smooth-scrolls
	# through every intermediate row, recycling thousands of cards on the way.
	games_grid.scroll_to_index(idx, false)

func _on_filter_button_clicked() -> void:
	"""Handle filter button click — open the library filter side sheet."""
	var sheet := LibraryFilterSheet.show_sheet(_active_filters)
	if not sheet.filters_changed.is_connected(_on_filters_changed):
		sheet.filters_changed.connect(_on_filters_changed)

## External entry point (e.g. a studio chip in the details sheet): replace all
## active filters with a single company include and reload the grid.
func apply_company_filter(company: String) -> void:
	apply_external_filter("company", company, "STUDIO", company)

## Replace all active search/filter state with a single external filter value
## (details sheet chips: company, genre, release_week) and reload the grid.
func apply_external_filter(kind: String, value: String, center_text: String, label: String) -> void:
	if value == "":
		return
	if DEBUG_LOG: print("[LibraryView] apply_external_filter: kind=", kind, " value=", value, " platform_slug=", _current_platform_slug)
	try_clear_search()
	_active_filters = {kind: {"include": [value], "exclude": []}}
	# Details sheets are reachable for games on any platform (search, home,
	# collections, related cards), so composing with the cycler could exclude
	# the very game the chip was clicked from. Reset to All Games.
	_current_platform_index = -1
	_current_platform_slug = ""
	if platform_indicator:
		platform_indicator.set_filter_active(true)
		platform_indicator.show_filter_mode(center_text, label)
	# Scrolls to top and focuses the first card once the count lands.
	_load_total_count_with_platform(false)

## External entry point (platform chip in the details sheet): clear all
## search/filter state and jump the platform cycler to the given slug.
func apply_platform_selection(slug: String, platform_name: String = "") -> void:
	if slug == "":
		return
	if _platforms.is_empty():
		_load_platforms_list()
	var index := -1
	for i in range(_platforms.size()):
		if _platforms[i].get("slug", "") == slug:
			index = i
			break
	if index == -1:
		SystemManager.notifications.show_notification("Platform not in library: " + (platform_name if platform_name != "" else slug), SystemManager.notifications.Type.WARNING)
		return
	if DEBUG_LOG: print("[LibraryView] apply_platform_selection: slug=", slug, " index=", index)
	try_clear_search()
	if not _active_filters.is_empty():
		_active_filters = {}
		LibraryFilterSheet.sync_selection({})
	if platform_indicator:
		platform_indicator.set_filter_active(false)
		platform_indicator.update_display(_platforms, index)
	_current_platform_index = index
	_current_platform_slug = slug
	_load_total_count_with_platform(false)

## Clear active filters (back-button path, mirrors try_clear_search).
## Returns true if filters were cleared.
func try_clear_filters() -> bool:
	if _active_filters.is_empty():
		return false
	_active_filters = {}
	if platform_indicator:
		platform_indicator.set_filter_active(false)
		platform_indicator.update_display(_platforms, _current_platform_index)
	# Keep the persistent filter sheet's selection in sync so reopening it
	# doesn't resurrect stale chips.
	LibraryFilterSheet.sync_selection({})
	# Mirrors _clear_search: scroll to top, focus the first card on reload.
	_load_total_count_with_platform(false)
	return true

func _on_filters_changed(filters: Dictionary) -> void:
	"""Handle live filter chip changes from the filter sheet."""
	_active_filters = filters
	if platform_indicator:
		platform_indicator.set_filter_active(not filters.is_empty())
		# Sheet edits replace the filter set; the STUDIO label only reflects
		# chip-applied company filters, so restore the platform labels.
		platform_indicator.update_display(_platforms, _current_platform_index)
	_load_total_count()

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

func _load_total_count_with_search(on_complete: Callable = Callable()):
	"""Load total count for search results."""
	_is_loading = true

	SystemManager.memory.queue_db_task(
		func():
			var count = DataManager.get_search_results_count(_search_query, _active_filters)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				if on_complete.is_valid():
					on_complete.call()
				return
			_total_games = count
			var available_size = UIManager.compute_grid_available_size(games_grid, self) if UIManager else Vector2.ZERO
			games_grid.set_total_count_with_available_size(count, available_size, false)

			# Reset scroll to top
			games_grid.scroll_to_index(0, false)

			# Refresh dimensions
			_refresh_grid_dimensions()

			# Refresh A-Z letter navigation for the new result set
			_load_letter_index()

			# Focus first card
			call_deferred("_focus_first_card")

			_is_loading = false
			if on_complete.is_valid():
				on_complete.call()
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
			var count = DataManager.get_total_games_count(_current_platform_slug, _active_filters)
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
			
			# Refresh A-Z letter navigation for the new platform/filter set
			_load_letter_index()
			
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

func _load_total_count(preserve_cache: bool = false, on_complete: Callable = Callable()):
	"""Get total game count for virtual scrolling setup."""
	if _is_search_active:
		_load_total_count_with_search(on_complete)
		return

	_is_loading = true
	_update_status("Loading library...")

	# Query total count asynchronously
	SystemManager.memory.queue_db_task(
		func():
			var count = DataManager.get_total_games_count(_current_platform_slug, _active_filters)
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
			# Refresh A-Z letter navigation for the new result set
			_load_letter_index()
			if on_complete.is_valid():
				on_complete.call()
	)

func _on_items_requested(offset: int, limit: int, is_preload: bool = false):
	"""Handle database query requests from VirtualScrollGridContainer."""
	var request_start_us := Time.get_ticks_usec()
	if _is_search_active:
		SystemManager.memory.queue_db_task(
			func():
				if not is_instance_valid(games_grid) or not games_grid.is_load_pending(offset):
					var stale: Array[GameResource] = []
					return stale
				var db_start_us := Time.get_ticks_usec()
				var games = DataManager.search_games_paginated(_search_query, offset, limit, _active_filters)
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
				if not is_instance_valid(games_grid) or not games_grid.is_load_pending(offset):
					var stale: Array[GameResource] = []
					return stale
				var db_start_us := Time.get_ticks_usec()
				var games = DataManager.get_games_paginated(offset, limit, "title", true, _current_platform_slug, _active_filters)
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

	# Highlight the current letter in the A-Z carousel
	if _az_carousel and _az_carousel.visible:
		_az_carousel.set_active_from_index(start_index)

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
	
	# Apply zoom from centralized card settings state (per-mode).
	if UIManager and UIManager.card_settings_state and games_grid:
		if games_grid.view_mode == VirtualScrollGridContainer.ViewMode.GRID:
			games_grid.target_card_width_ratio = UIManager.card_settings_state.card_zoom_ratio
		else:
			games_grid.target_card_width_ratio = UIManager.card_settings_state.card_zoom_list_ratio
	
	if refresh_effects:
		# Effect configuration changed: reload data if we're also clearing the cache,
		# then refresh dimensions and effects.
		if preserve_data:
			_refresh_grid_dimensions()
			games_grid.refresh_all_card_effects(true)
		else:
			# Use callback version to ensure dimensions refresh BEFORE rebuilding
			# effects, so cards are rebuilt against final bounds.
			_load_total_count(false, func():
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
				_load_total_count(false)

func _on_database_ready():
	# One-shot: the manual is_database_ready() path and the signal can both
	# fire when the signal is emitted after this view connects.
	if _database_ready_handled:
		return
	_database_ready_handled = true
	_load_total_count()

func _on_database_failed(_error: String):
	_is_loading = false
	_update_status("Database unavailable - check storage permissions, then restart the app")

func _on_download_completed(item_id: String, success: bool, _message: String):
	# During an update-all session, emulator downloads complete in bursts and
	# each one would reload the grid - the session's update_session_finished
	# signal triggers one reload at the end instead.
	if LaunchManager and LaunchManager.update and LaunchManager.update.is_session_active():
		return
	# Downloads don't change library membership or counts, so update the
	# game's card in place: a full _load_total_count() tears down the buffer,
	# resets scroll to top, and races focus restoration.
	if not success or not DataManager or not DataManager.is_database_ready():
		return
	var item = SystemManager.download.get_item(item_id)
	if item and item.game_resource:
		games_grid.update_cached_game(item.game_resource)
		_on_game_updated(item.game_resource)
	else:
		_load_total_count()  # Unknown item: legacy full reload

func _on_update_session_finished(_succeeded: Array, _failed: Array):
	if DataManager and DataManager.is_database_ready():
		_load_total_count()

func _on_games_removed(_platform_slug: String):
	_reload_after_change()

func _reload_after_change():
	"""Reload after games added/removed."""
	_load_total_count()

func _on_sync_progress(percent: float, current: int, total: int):
	_update_status("Syncing... %d/%d games (%.0f%%)" % [current, total, percent])

func _on_sync_completed(success: bool, message: String):
	_seen_library_generation = DataManager.library_generation
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

func on_view_show():
	super.on_view_show()
	# Catch up if sync_completed fired while this view was disconnected.
	_catch_up_missed_sync()
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
		"add_to_steam":
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				SteamVDFWriter.add_game(game)
		"open_save_location":
			var game = DataManager.get_game_by_id(romm_id)
			if game:
				DataManager.game_save.open_save_location(game)
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
