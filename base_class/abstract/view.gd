class_name View
extends Control

signal view_ready()
signal view_shown()
signal view_hidden()
signal hero_game_changed(game: GameResource)

var view_name: String = ""

# Whether focusing a game card in this view should update the hero image.
var supports_hero: bool = true

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

# Track a focused GameCard that hasn't loaded its game data yet, so we can
# re-emit hero_game_changed once the data arrives.
var _pending_hero_card: GameCard = null

func _ready():
	view_ready.emit()

func on_view_show():
	view_shown.emit()
	# Hidden views can have a stale or zero grid size when shown. Run a single
	# deterministic layout recalc now so the grid is settled against the real
	# available rect, unless a full rebuild is already pending.
	if not needs_rebuild and games_grid and UIManager:
		var available_size = UIManager.compute_grid_available_size(games_grid, self)
		games_grid.recalculate_layout_with_size(available_size)
	# Check if view needs to be rebuilt before showing (e.g. data/effect refresh).
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
		print("[View._update_grid_orientation] no card_settings_state for ", view_name)
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

	# Apply the saved zoom level (grid) or ratio (list/carousel) before any cards
	# are created so the first visible layout uses the user's setting instead of
	# the default 0.15.
	if games_grid:
		print("[View._update_grid_orientation] view_name=", view_name, " level=", state.card_zoom_level, " ratio=", state.card_zoom_ratio, " grid_target_before=", games_grid.target_card_width_ratio)
		if new_mode == VirtualScrollGridContainer.ViewMode.GRID:
			var level: int = state.card_zoom_level
			if level < 0:
				# Derive level from the legacy saved ratio for migration. If the
				# grid has no valid size yet, leave the level unset — the settle
				# paths derive N from the ratio once the size is final.
				var derived: int = games_grid.get_zoom_level(state.card_zoom_ratio)
				if derived >= 0:
					level = derived
					state.card_zoom_level = level
			if level >= 0:
				games_grid.set_zoom_level(level)
				state.card_zoom_ratio = games_grid.target_card_width_ratio
		else:
			# LIST/CAROUSEL: use the per-mode saved ratio.
			if not is_equal_approx(games_grid.target_card_width_ratio, state.card_zoom_list_ratio):
				games_grid.target_card_width_ratio = state.card_zoom_list_ratio
	else:
		print("[View._update_grid_orientation] no games_grid for ", view_name)

	# Batch-apply to avoid redundant rebuilds from individual setters
	games_grid.set_grid_orientation(new_mode, new_grid_vertical, new_focus_scale)

func _on_focus_changed(control: Control):
	# Traverse up the tree to find if focused control is inside a GameCard
	var card = control
	while card != null:
		if card is GameCard:
			if card.game:
				hero_game_changed.emit(card.game)
				_clear_pending_hero_card()
			else:
				# Data hasn't loaded yet; wait for the card's game_changed signal.
				_clear_pending_hero_card()
				_pending_hero_card = card
				if not card.game_changed.is_connected(_on_pending_card_game_changed):
					card.game_changed.connect(_on_pending_card_game_changed)
			return
		card = card.get_parent()
	
	# Focus is not on a card; stop waiting for a pending card.
	_clear_pending_hero_card()
	# Don't clear hero - keep the last focused game image

func _on_pending_card_game_changed(game: GameResource) -> void:
	if _pending_hero_card and is_instance_valid(_pending_hero_card):
		hero_game_changed.emit(game)
	_clear_pending_hero_card()

func _clear_pending_hero_card() -> void:
	if _pending_hero_card and is_instance_valid(_pending_hero_card):
		if _pending_hero_card.game_changed.is_connected(_on_pending_card_game_changed):
			_pending_hero_card.game_changed.disconnect(_on_pending_card_game_changed)
	_pending_hero_card = null

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
	SystemManager.download.queue_game_download(game)

# Status bar removed — kept as no-op so subclasses don't need to override
func _update_status(_text: String = "") -> void:
	pass

func _on_setting_changed(_value: Variant, _setting: SettingsVar) -> void:
	"""Handle settings changes.
	
	Card config / layout / effect updates are now driven by the grid's own
	DataManager handler and by ViewManager, so the base view no longer
	needs to trigger its own rebuilds here."""
	pass
