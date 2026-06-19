class_name View
extends Control

signal view_ready()
signal view_shown()
signal view_hidden()
signal hero_game_changed(game: GameResource)

var view_name: String = ""

# Shared grid reference — subclasses set this via @onready
var games_grid: VirtualScrollGridContainer = null

# Lazy rebuild pattern - views marked for rebuild when hidden, rebuilt when shown
var needs_rebuild: bool = false
var needs_rebuild_reason: String = ""
var _rebuild_attempts: int = 0
const MAX_REBUILD_ATTEMPTS: int = 5

# Deferred rebuild guard
var _deferred_rebuild_attempts: int = 0
const MAX_DEFERRED_REBUILD_ATTEMPTS: int = 10

# Track last connected viewport to prevent signal leaks on reparent
var _last_connected_viewport: Viewport = null

func _ready():
	view_ready.emit()

func on_view_show():
	view_shown.emit()
	# Check if view needs to be rebuilt before showing
	check_and_rebuild_if_needed()

func on_view_hide():
	view_hidden.emit()

# Whether the pending rebuild should also do a full card-effect refresh.
var _pending_refresh_effects: bool = false

func mark_for_rebuild(reason: String = "", refresh_effects: bool = false) -> void:
	"""Mark this view as needing a rebuild. Will be rebuilt when next shown."""
	needs_rebuild = true
	needs_rebuild_reason = reason
	_pending_refresh_effects = refresh_effects

func check_and_rebuild_if_needed() -> void:
	"""Override: Capture reason before it's cleared, then defer rebuild."""
	if needs_rebuild:
		var reason = needs_rebuild_reason
		var refresh_effects = _pending_refresh_effects
		# Clear flags now since we're handling the rebuild
		needs_rebuild = false
		needs_rebuild_reason = ""
		_pending_refresh_effects = false
		# Pass the captured reason to the deferred rebuild
		call_deferred("_do_rebuild", reason, refresh_effects)
	else:
		_rebuild_attempts = 0

func perform_rebuild() -> void:
	"""Override in subclasses to perform the actual rebuild."""
	pass

func _do_rebuild(reason: String = "", refresh_effects: bool = false) -> void:
	# Ensure we have valid dimensions before rebuilding
	if size.x <= 0 or size.y <= 0:
		_deferred_rebuild_attempts += 1
		if _deferred_rebuild_attempts > MAX_DEFERRED_REBUILD_ATTEMPTS:
			push_warning("[%s] Max deferred rebuild attempts reached with invalid size, aborting" % view_name)
			_deferred_rebuild_attempts = 0
			return
		call_deferred("_do_rebuild", reason, refresh_effects)
		return
	
	# Reset counter on successful rebuild
	_deferred_rebuild_attempts = 0
	
	if games_grid:
		# Force a layout recalculation with the new valid size
		games_grid.queue_redraw()
	
	# Preset-applied rebuilds and card-effect changes need a full effect refresh.
	var do_refresh_effects = refresh_effects or reason == "Card effects changed"
	rebuild_grid(do_refresh_effects)

# Subclasses override this; base version is a no-op for safety.
func rebuild_grid(_refresh_effects: bool = false) -> void:
	pass

# ============================================
# SHARED GRID / CARD LOGIC
# ============================================

func _update_grid_orientation() -> void:
	var state = UIManager.card_settings_state if UIManager else null
	if not state:
		return

	var layout_mode_val = state.layout_mode

	var new_mode: VirtualScrollGridContainer.ViewMode
	match layout_mode_val:
		0:
			new_mode = VirtualScrollGridContainer.ViewMode.GRID
		1:
			new_mode = VirtualScrollGridContainer.ViewMode.LIST
		2:
			new_mode = VirtualScrollGridContainer.ViewMode.CAROUSEL
		_:
			new_mode = VirtualScrollGridContainer.ViewMode.GRID

	var new_grid_vertical = state.grid_vertical
	var new_focus_scale = 1.0 + state.focus_scale_ratio

	# Batch-apply to avoid redundant rebuilds from individual setters
	games_grid.set_grid_orientation(new_mode, new_grid_vertical, new_focus_scale)

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
	# Disconnect from the PREVIOUSLY connected viewport (not get_viewport() which
	# returns the NEW viewport after reparenting). This prevents signal leaks.
	if _last_connected_viewport and is_instance_valid(_last_connected_viewport):
		if _last_connected_viewport.gui_focus_changed.is_connected(_on_focus_changed):
			_last_connected_viewport.gui_focus_changed.disconnect(_on_focus_changed)
		_last_connected_viewport = null
	
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return
	
	# Connect to new/current viewport
	viewport.gui_focus_changed.connect(_on_focus_changed)
	_last_connected_viewport = viewport
	
	# Reconnect grid's scroll container follow_focus
	if games_grid and games_grid._scroll_container:
		games_grid._scroll_container.reconnect_viewport()

	# Reconnect focus-lock viewport signal on the grid
	if games_grid and games_grid.has_method("refresh_focus_lock"):
		games_grid.refresh_focus_lock()

func _on_game_updated(game: GameResource):
	# Find and update any visible cards for this game
	var range_info = games_grid.get_visible_range()
	for i in range(range_info.buffer_start, range_info.buffer_start + range_info.buffer_size):
		var card = games_grid.get_card_at_index(i)
		if card and card is GameCard and card.game and card.game.romm_id == game.romm_id:
			var card_visible = i >= range_info.start and i < range_info.end
			card.set_game_with_priority(game, card_visible)
			break

func _on_card_created(card: Control, _index: int):
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
		NotificationManager.show_notification("Error: Games folder not set", NotificationManager.Type.ERROR)
		return
	
	var destination_path = root_folder.value + "/" + game.platform_slug + "/" + active_file_name
	var item_id = DownloadManager.queue_download(download_url, destination_path, "game", game.get_display_name(), false, "", game, {}, active_game_id)
	
	if item_id != "":
		pass  # Status updates removed; notifications handled by DownloadManager
	else:
		NotificationManager.show_notification("Failed to queue download", NotificationManager.Type.ERROR)

# Status bar removed — kept as no-op so subclasses don't need to override
func _update_status(_text: String = "") -> void:
	pass

func _on_setting_changed(_value: Variant, _setting: SettingsVar) -> void:
	"""Handle settings changes.
	
	Card config / layout / effect updates are now driven by the grid's own
	SettingsManager handler and by ViewManager, so the base view no longer
	needs to trigger its own rebuilds here."""
	pass
