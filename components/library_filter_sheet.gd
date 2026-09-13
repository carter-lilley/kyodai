class_name LibraryFilterSheet
extends M3SideSheet

## Side sheet for library filters. Embeds a FilterChipsPanel for the chip rows;
## this class owns the sheet shell (scroll wrapper, clear-all action, focus
## management). Selections apply live and reset each session.

signal filters_changed(filters: Dictionary)

static var _instance: LibraryFilterSheet = null

var _scroll: ScrollContainer = null
var _panel: FilterChipsPanel = null
var _clear_button: M3Button = null

func _init():
	super._init()
	persistent = true

func _ready():
	super._ready()
	_build_content()

func refresh_theme():
	super.refresh_theme()
	if _scroll:
		M3Theme.style_scrollbar(_scroll.get_v_scroll_bar())

func refresh_scale() -> void:
	if not is_node_ready():
		return
	if _panel:
		_panel.refresh_scale()
	super.refresh_scale()

func _build_content() -> void:
	if not _content_slot:
		return

	for child in _content_slot.get_children():
		child.queue_free()

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	M3Theme.style_scrollbar(_scroll.get_v_scroll_bar())
	_content_slot.add_child(_scroll)

	_panel = FilterChipsPanel.new()
	_panel.filters_changed.connect(_on_panel_filters_changed)
	# Keep the clear-all button in sync with externally seeded selections too
	# (company filters applied outside the sheet emit no filters_changed).
	_panel.content_rebuilt.connect(_update_clear_button)
	_scroll.add_child(_panel)

	# Bottom bar with clear action
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_END
	_clear_button = M3Button.new()
	_clear_button.text = "Clear all"
	_clear_button.button_variant = M3Button.Variant.TEXT
	_clear_button.visible = false
	_clear_button.pressed.connect(_on_clear_all)
	bar.add_child(_clear_button)
	_content_slot.add_child(bar)

func reload_options() -> void:
	"""Fetch distinct filter values and rebuild the chip rows."""
	if _panel:
		_panel.load_options()

func _on_panel_filters_changed(filters: Dictionary) -> void:
	_update_clear_button()
	filters_changed.emit(filters)

func _on_clear_all() -> void:
	if _panel:
		_panel.clear_all()  # re-emits filters_changed via the panel

func get_active_filters() -> Dictionary:
	return _panel.get_active_filters() if _panel else {}

# ============================================================================
# Focus
# ============================================================================

func _focus_first_chip() -> void:
	"""Focus the first filter chip so controller users land on content instead
	of the header close button. No-op in the loading/empty states."""
	# The panel queue_frees previous chips on rebuild; they linger as children
	# until the frame ends, so wait a frame before searching (and skip queued
	# strays regardless) or the grab lands on a freed node.
	await get_tree().process_frame
	var chip := _find_first_chip(_panel)
	if chip == null:
		return
	if UIManager:
		UIManager.suppress_next_focus_sound()
	chip.grab_focus()

func _find_first_chip(node: Node) -> M3Chip:
	if node is M3Chip and node.focus_mode != Control.FOCUS_NONE and not node.is_queued_for_deletion():
		return node
	for child in node.get_children():
		if child.is_queued_for_deletion():
			continue
		var found := _find_first_chip(child)
		if found:
			return found
	return null

func _focus_restore_to_grid_or_home() -> void:
	"""Fallback when the captured summoner is gone: filter changes recycle grid
	cards, so the exact card rarely survives. Restore the grid's last focused
	card position instead; home button as the final fallback."""
	if UIManager:
		var view = UIManager.get_current_view()
		var grid = view.get("games_grid") if view else null
		if grid is VirtualScrollGridContainer and grid.is_visible_in_tree():
			grid.focus_last_or_first_card()
			return
		UIManager.get_focus_restore_fallback_to_home().call()

func _input(event: InputEvent) -> void:
	# Handle ui_cancel deterministically when this sheet is the topmost visible
	# overlay, bypassing the base class's _max_layer gate (a stale registered
	# overlay above our layer would otherwise silently block dismissal).
	if visible and event.is_action_pressed("ui_cancel") \
			and M3Overlay._get_topmost_overlay() == self:
		get_viewport().set_input_as_handled()
		dismiss()
		return
	super._input(event)

func dismiss() -> void:
	# Restore focus to the summoner before the slide-out so the focus ring
	# doesn't ride the sheet off-screen. The overlay pull-back would yank the
	# deferred grab back into the still-visible sheet, so keep it suppressed
	# until the dismissal completes; the built-in post-animation restore is
	# disabled for this dismiss and re-armed afterwards for the next open.
	M3Overlay.push_focus_pullback_suppression()
	_restore_focus_on_dismiss = false
	if UIManager:
		UIManager.restore_focus(_summoner_focus, _focus_restore_fallback)
	super.dismiss()
	dismissed.connect(func():
		M3Overlay.pop_focus_pullback_suppression()
		_restore_focus_on_dismiss = true, CONNECT_ONE_SHOT | CONNECT_DEFERRED)

func _update_clear_button() -> void:
	if _clear_button:
		_clear_button.visible = _panel != null and _panel.has_active_filters()

static func prepare() -> void:
	"""Pre-create the sheet so the first open doesn't stutter."""
	_ensure_instance(true)

## Sync the panel's selection state from outside (e.g. filters cleared via the
## back button while the sheet is hidden) so a later open doesn't show stale
## chips. Emits no signals.
static func sync_selection(filters: Dictionary) -> void:
	if _instance and is_instance_valid(_instance) and _instance._panel:
		_instance._panel.set_selected_filters(filters)

static func show_sheet(current_filters: Dictionary = {}) -> LibraryFilterSheet:
	_ensure_instance(false)

	_instance.headline_text = "Filters"
	_instance.sheet_variant = Variant.MODAL
	_instance.set_focus_restore_fallback(Callable(_instance, "_focus_restore_to_grid_or_home"))
	# Two-phase show: load filter options before presenting. When the caller
	# already has active filters (e.g. a company filter applied from the
	# details sheet), seed the panel's selection state instead so unrendered
	# kinds survive the rebuild.
	var prepare_cb: Callable = _instance.reload_options
	if not current_filters.is_empty() and _instance._panel:
		prepare_cb = _instance._panel.set_selected_filters.bind(current_filters)
	_instance.show_prepared(prepare_cb)
	_instance._focus_first_chip()
	return _instance

static func cleanup_instance() -> void:
	if _instance != null and is_instance_valid(_instance):
		if _instance.get_parent() == null:
			_instance.free()
	_instance = null

static func _ensure_instance(deferred_add: bool = false) -> void:
	if _instance != null and is_instance_valid(_instance):
		return

	_instance = LibraryFilterSheet.new()
	_instance.headline_text = "Filters"
	_instance.sheet_variant = Variant.MODAL
	_instance.persistent = true

	# Add to the overlay parent so _ready() runs and the UI is built in advance.
	# _ready() sets visible=false, so it stays hidden until show_sheet().
	# Use call_deferred when prepare() is called during a parent's _ready().
	var parent = M3Overlay.get_overlay_parent()
	if parent and _instance.get_parent() == null:
		if deferred_add:
			parent.add_child.call_deferred(_instance)
		else:
			parent.add_child(_instance)
