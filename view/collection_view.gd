class_name CollectionView
extends View

@onready var margin_container: MarginContainer = $MarginContainer
@onready var title_label: M3Label = $MarginContainer/VBoxContainer/CollectionTitle

@export var collection_id: int = 0
@export var collection_name: String = ""
## When true, this view shows the RomM favorites collection. The collection id
## is resolved dynamically (it can appear/change after collections sync).
@export var favorites_mode: bool = false
## When non-empty, this view shows the library filtered to this platform slug
## (used by pinned platform tabs).
@export var platform_slug: String = ""

var _total_games: int = 0
var _is_loading: bool = false

# One-shot guard: the manual is_database_ready() path and the database_ready
# signal can both fire for the same view.
var _database_ready_handled: bool = false

func _exit_tree() -> void:
	_disconnect_signals()

func _enter_tree() -> void:
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
	if not DataManager.game_updated.is_connected(_on_game_updated):
		DataManager.game_updated.connect(_on_game_updated)
	if not DataManager.games_removed.is_connected(_on_games_removed):
		DataManager.games_removed.connect(_on_games_removed)
	if not DataManager.sync_completed.is_connected(_on_sync_completed):
		DataManager.sync_completed.connect(_on_sync_completed)
	if DataManager.collections and not DataManager.collections.collections_synced.is_connected(_on_collections_synced):
		DataManager.collections.collections_synced.connect(_on_collections_synced)
	if favorites_mode and DataManager.user_props and not DataManager.user_props.game_props_updated.is_connected(_on_game_props_updated):
		DataManager.user_props.game_props_updated.connect(_on_game_props_updated)
	if not DataManager.collection_membership_changed.is_connected(_on_collection_membership_changed):
		DataManager.collection_membership_changed.connect(_on_collection_membership_changed)
	if UIManager and not UIManager.modal_item_selected.is_connected(_on_modal_item_selected):
		UIManager.modal_item_selected.connect(_on_modal_item_selected)

func _disconnect_signals() -> void:
	if not DataManager:
		return
	if DataManager.setting_changed.is_connected(_on_setting_changed):
		DataManager.setting_changed.disconnect(_on_setting_changed)
	if DataManager.database_ready.is_connected(_on_database_ready):
		DataManager.database_ready.disconnect(_on_database_ready)
	if DataManager.game_updated.is_connected(_on_game_updated):
		DataManager.game_updated.disconnect(_on_game_updated)
	if DataManager.games_removed.is_connected(_on_games_removed):
		DataManager.games_removed.disconnect(_on_games_removed)
	if DataManager.sync_completed.is_connected(_on_sync_completed):
		DataManager.sync_completed.disconnect(_on_sync_completed)
	if DataManager.collections and DataManager.collections.collections_synced.is_connected(_on_collections_synced):
		DataManager.collections.collections_synced.disconnect(_on_collections_synced)
	if DataManager.user_props and DataManager.user_props.game_props_updated.is_connected(_on_game_props_updated):
		DataManager.user_props.game_props_updated.disconnect(_on_game_props_updated)
	if DataManager.collection_membership_changed.is_connected(_on_collection_membership_changed):
		DataManager.collection_membership_changed.disconnect(_on_collection_membership_changed)
	if UIManager and UIManager.modal_item_selected.is_connected(_on_modal_item_selected):
		UIManager.modal_item_selected.disconnect(_on_modal_item_selected)

func _ready():
	if favorites_mode:
		_refresh_favorites_collection_id()
	elif not platform_slug.is_empty():
		view_name = _platform_view_name(platform_slug)
	elif collection_name.is_empty() and collection_id != 0:
		var collection = DataManager.get_collection(collection_id)
		if collection:
			collection_name = collection.get("name", "")
		view_name = _collection_view_name(collection_id)
	
	if title_label:
		title_label.text = collection_name
	
	games_grid = $MarginContainer/VBoxContainer/VirtualScrollGridContainer as VirtualScrollGridContainer
	if not games_grid:
		push_error("[CollectionView] games_grid is null! Cannot initialize.")
		return
	
	var card_scene = load("res://components/game_card.tscn") as PackedScene
	var initial_zoom: float = 0.25
	if UIManager and UIManager.card_settings_state:
		var zoom_state = UIManager.card_settings_state
		initial_zoom = zoom_state.card_zoom_ratio if zoom_state.layout_mode == 0 else zoom_state.card_zoom_list_ratio
	games_grid.setup(card_scene, 0, initial_zoom)
	games_grid.items_requested.connect(_on_items_requested)
	games_grid.visible_range_changed.connect(_on_visible_range_changed)
	games_grid.item_created.connect(_on_card_created)
	
	_update_grid_orientation()
	reconnect_viewport()

static func _collection_view_name(id: int) -> String:
	return "Collection_%d" % id

static func _platform_view_name(slug: String) -> String:
	return "Platform_%s" % slug

func _refresh_favorites_collection_id() -> void:
	"""Re-resolve the favorites collection id; reloads the grid if it changed."""
	if not favorites_mode or not DataManager:
		return
	var resolved := DataManager.get_favorite_collection_id()
	if resolved != collection_id:
		collection_id = resolved
		_load_total_count(false)

func _on_game_props_updated(game: GameResource) -> void:
	# A favorite toggle adds/removes the game from this view.
	if game:
		_load_total_count(false)

func _on_collection_membership_changed(changed_id: int, _romm_id: int) -> void:
	# An add-to-collection changes this view's membership.
	if changed_id == collection_id:
		_load_total_count(false)

func _get_empty_status_text() -> String:
	if favorites_mode:
		return "No favorites yet"
	if not platform_slug.is_empty():
		return "No games for this platform"
	return "No games in this collection"

func _on_database_ready() -> void:
	# One-shot: the manual is_database_ready() path and the signal can both
	# fire when the signal is emitted after this view connects.
	if _database_ready_handled:
		return
	_database_ready_handled = true
	_load_total_count()

func _on_games_removed(_platform_slug: String) -> void:
	_load_total_count()

func _on_sync_completed(success: bool, _message: String) -> void:
	_seen_library_generation = DataManager.library_generation
	if not success:
		return
	if favorites_mode:
		# The favorites collection id is resolved dynamically and can
		# appear/change with a collections sync; re-resolve so a view stuck
		# at id 0 recovers.
		_refresh_favorites_collection_id()
	_load_total_count(false)

func _on_collections_synced(success: bool, _message: String) -> void:
	# Collections re-sync after a library sync; membership and the favorites
	# collection id may have changed.
	if not success:
		return
	if favorites_mode:
		_refresh_favorites_collection_id()
	_load_total_count(false)

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	if setting.property_name in ["hide_games_without_covers", "fold_romm_siblings"]:
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

func _load_total_count(preserve_cache: bool = false) -> void:
	if not platform_slug.is_empty():
		_load_platform_total_count(preserve_cache)
		return
	if collection_id == 0:
		if favorites_mode:
			_total_games = 0
			if games_grid:
				games_grid.set_total_count(0)
			_update_status(_get_empty_status_text())
		return
	_is_loading = true
	_update_status("Loading collection...")
	
	MemorySubManager.queue_db_task(
		func():
			var count = DataManager.get_games_for_collection_count(collection_id)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				return
			_total_games = count
			var available_size = UIManager.compute_grid_available_size(games_grid, self) if UIManager else Vector2.ZERO
			games_grid.set_total_count_with_available_size(count, available_size, preserve_cache)
			if count == 0:
				_update_status(_get_empty_status_text())
			else:
				_update_status("Showing 0-0 of %d games" % count)
			_is_loading = false
	)

func _load_platform_total_count(preserve_cache: bool = false) -> void:
	_is_loading = true
	_update_status("Loading platform...")

	MemorySubManager.queue_db_task(
		func():
			var count = DataManager.get_total_games_count(platform_slug)
			return count,
		func(count: int):
			if not is_instance_valid(games_grid):
				_is_loading = false
				return
			_total_games = count
			var available_size = UIManager.compute_grid_available_size(games_grid, self) if UIManager else Vector2.ZERO
			games_grid.set_total_count_with_available_size(count, available_size, preserve_cache)
			if count == 0:
				_update_status(_get_empty_status_text())
			else:
				_update_status("Showing 0-0 of %d games" % count)
			_is_loading = false
	)

func _on_items_requested(offset: int, limit: int, is_preload: bool = false) -> void:
	if not platform_slug.is_empty():
		MemorySubManager.queue_db_task(
			func():
				if not is_instance_valid(games_grid) or not games_grid.is_load_pending(offset):
					var stale: Array[GameResource] = []
					return stale
				var games = DataManager.get_games_paginated(offset, limit, "title", true, platform_slug)
				return games,
			func(games: Array[GameResource]):
				if not is_instance_valid(games_grid):
					return
				games_grid.on_items_loaded(games, offset, is_preload)
		)
		return
	if collection_id == 0:
		return
	MemorySubManager.queue_db_task(
		func():
			if not is_instance_valid(games_grid) or not games_grid.is_load_pending(offset):
				var stale: Array[GameResource] = []
				return stale
			var games = DataManager.get_games_for_collection_paginated(collection_id, offset, limit)
			return games,
		func(games: Array[GameResource]):
			if not is_instance_valid(games_grid):
				return
			games_grid.on_items_loaded(games, offset, is_preload)
	)

func _on_visible_range_changed(start_index: int, end_index: int, total_count: int) -> void:
	if total_count == 0:
		_update_status(_get_empty_status_text())
	else:
		var start_num = start_index + 1
		var end_num = mini(end_index, total_count)
		_update_status("Showing %d-%d of %d games" % [start_num, end_num, total_count])

func _input(event: InputEvent) -> void:
	if not UIManager.is_current_view(view_name):
		return
	if event.is_action_pressed("random_game"):
		_focus_random_card()
		accept_event()

func _focus_random_card() -> void:
	if _total_games == 0:
		return
	var random_index := randi() % _total_games
	games_grid.scroll_to_index_and_focus(random_index, false)

func on_view_show() -> void:
	super.on_view_show()
	_catch_up_missed_sync()
	if favorites_mode:
		_refresh_favorites_collection_id()
	if title_label:
		title_label.text = collection_name
	if games_grid:
		if games_grid._active_cards.size() == 0 and games_grid._total_items > 0 and games_grid.size.x > 0 and games_grid.size.y > 0:
			games_grid._initial_load()
		games_grid._request_missing_data()

func on_view_hide() -> void:
	view_hidden.emit()

func rebuild_grid(refresh_effects: bool = false, preserve_data: bool = true) -> void:
	_update_grid_orientation()
	
	# Apply zoom from centralized card settings state (per-mode).
	if UIManager and UIManager.card_settings_state and games_grid:
		if games_grid.view_mode == VirtualScrollGridContainer.ViewMode.GRID:
			games_grid.target_card_width_ratio = UIManager.card_settings_state.card_zoom_ratio
		else:
			games_grid.target_card_width_ratio = UIManager.card_settings_state.card_zoom_list_ratio
	
	if refresh_effects:
		if preserve_data:
			_refresh_grid_dimensions()
			games_grid.refresh_all_card_effects(true)
		else:
			_load_total_count(false)
	else:
		_refresh_grid_dimensions()
		if preserve_data:
			games_grid._request_missing_data()
		else:
			_load_total_count(true)

func _on_modal_item_selected(item_id: String, context: Dictionary) -> void:
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
					_load_total_count(false)
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
