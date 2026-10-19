class_name TitleBar
extends PanelContainer

## Custom window title bar for windowed mode on desktop platforms. The native
## frame is stripped (see DisplaySubManager.apply_window_chrome) and this
## full-bleed strip replaces it: title + drag area on the left, and
## minimize/maximize/close buttons on the right.
##
## Lives on UIManager's ChromeLayer (OverlayLayers.CHROME), a CanvasLayer above
## every app overlay, so the window controls always render on top and stay
## clickable while dialogs, menus, or transition overlays are open. The layout
## hole it leaves in the root layout is filled by a spacer row UIManager keeps
## in sync with this bar's visibility.
## Hidden whenever the window chrome is inactive (fullscreen, unsupported OS).

const BAR_HEIGHT_DP: float = 36
const TITLE_PAD_DP: float = 12
const TITLE_FONT_SIZE_DP: float = 13
## Press-to-press window (ms) treated as a double-click on the drag area.
## Checked in addition to the viewport's own double_click flag: the first
## press enters the OS drag loop, which can swallow the release on some
## platforms and delay event delivery.
const DOUBLE_CLICK_MS: int = 320
## Mirror the strip into Window.nonclient_area so it keeps receiving mouse
## input while normal input is blocked (exclusive child window); the blocked
## case is delivered via Window.nonclient_window_input instead. Our signal
## handler emulates every interaction, so both delivery paths behave the same.
## Flip off if runtime testing shows the two paths double-firing.
const USE_NONCLIENT_AREA: bool = true

var _hbox: HBoxContainer = null
var _drag_area: Control = null
var _title_label: Label = null
var _min_button: M3IconButton = null
var _max_button: M3IconButton = null
var _close_button: M3IconButton = null
var _background: StyleBoxFlat = null

var _active: bool = false
var _last_drag_press_ms: int = -1000000


func _ready() -> void:
	# Top-wide strip on the ChromeLayer CanvasLayer: anchors carry it across
	# window resizes; the height comes from the fixed bottom offset (re-applied
	# in refresh_scale). No z_index games here — the layer itself (CHROME =
	# 1150) is what puts the bar above every overlay.
	anchor_right = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	offset_bottom = M3Units.dpi(BAR_HEIGHT_DP)
	custom_minimum_size = Vector2(0, M3Units.dpi(BAR_HEIGHT_DP))

	_background = StyleBoxFlat.new()
	_background.content_margin_right = M3Units.dpi(2)
	add_theme_stylebox_override("panel", _background)

	_hbox = HBoxContainer.new()
	_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_hbox.add_theme_constant_override("separation", 0)
	add_child(_hbox)

	_drag_area = Control.new()
	_drag_area.name = "DragArea"
	_drag_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drag_area.size_flags_vertical = Control.SIZE_FILL
	_drag_area.mouse_filter = Control.MOUSE_FILTER_STOP
	_hbox.add_child(_drag_area)

	_title_label = Label.new()
	_title_label.name = "Title"
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_title_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_title_label.offset_left = M3Units.dpi(TITLE_PAD_DP)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_title_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_title_label.clip_text = true
	_drag_area.add_child(_title_label)
	_drag_area.gui_input.connect(_on_drag_area_input)

	_min_button = _make_button("window-minimize", "Minimize")
	_min_button.pressed.connect(_on_minimize_pressed)
	_max_button = _make_button("window-maximize", "Maximize")
	_max_button.pressed.connect(_on_maximize_pressed)
	_close_button = _make_button("close", "Close")
	_close_button.pressed.connect(_on_close_pressed)

	var window := get_window()
	if window:
		_title_label.text = window.title
		# Icon + visibility resync triggers: mode transitions arrive via the
		# display manager signal; maximize/snap changes arrive as resizes;
		# focus-in catches anything set while we were in the background
		# (shuffler sessions restore window modes directly).
		if not window.size_changed.is_connected(_on_window_size_changed):
			window.size_changed.connect(_on_window_size_changed)
		if not window.title_changed.is_connected(_on_title_changed):
			window.title_changed.connect(_on_title_changed)
		if USE_NONCLIENT_AREA and not window.nonclient_window_input.is_connected(_on_nonclient_window_input):
			window.nonclient_window_input.connect(_on_nonclient_window_input)
	if SystemManager and SystemManager.display:
		if not SystemManager.display.window_chrome_changed.is_connected(_on_window_chrome_changed):
			SystemManager.display.window_chrome_changed.connect(_on_window_chrome_changed)
	# Keep the nonclient mirror in sync when the bar is resized with the window.
	resized.connect(_on_resized)

	_apply_colors()
	_refresh_state()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN and is_node_ready():
		_refresh_state()


# ============================================================================
# Window buttons
# ============================================================================

func _make_button(icon: String, tooltip: String) -> M3IconButton:
	var button := M3IconButton.new()
	button.icon_button_size = M3IconButton.IconSize.EXTRA_SMALL
	button.icon_button_variant = M3IconButton.IconVariant.STANDARD
	button.icon_name = icon
	button.m3_tooltip_text = tooltip
	_hbox.add_child(button)
	# M3IconButton._ready() stomps size_flags_vertical to 0 (shrink-begin);
	# re-center the 32dp button in the taller bar once it's in the tree.
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return button


func _on_minimize_pressed() -> void:
	if SystemManager and SystemManager.display:
		SystemManager.display.minimize_window()


func _on_maximize_pressed() -> void:
	if SystemManager and SystemManager.display:
		SystemManager.display.toggle_window_maximize()
		_refresh_maximize_icon()


func _on_close_pressed() -> void:
	# Same shutdown path as the OS close button: main.gd handles the
	# notification (minimize on exit, save state, flush settings, free tree).
	get_tree().root.propagate_notification(Node.NOTIFICATION_WM_CLOSE_REQUEST)


# ============================================================================
# Drag area
# ============================================================================

func _on_drag_area_input(event: InputEvent) -> void:
	if not _active:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_handle_title_press(event as InputEventMouseButton)


func _handle_title_press(event: InputEventMouseButton) -> void:
	var now := Time.get_ticks_msec()
	var is_double := event.double_click or (now - _last_drag_press_ms) <= DOUBLE_CLICK_MS
	_last_drag_press_ms = now
	if not SystemManager or not SystemManager.display:
		return
	if is_double:
		_last_drag_press_ms = -1000000  # a third press starts a fresh sequence
		SystemManager.display.toggle_window_maximize()
		_refresh_maximize_icon()
	else:
		SystemManager.display.begin_title_drag()


func _on_nonclient_window_input(event: InputEvent) -> void:
	# Delivered INSTEAD of normal input while it is blocked (exclusive child
	# window). Hit-test the strip ourselves so drag/buttons keep working; in
	# the platforms where this signal also fires for unblocked input, this is
	# a faithful duplicate of the normal handlers.
	if not _active or not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if mouse.button_index != MOUSE_BUTTON_LEFT or not mouse.pressed:
		return
	var pos: Vector2 = mouse.position
	if _close_button and _close_button.get_global_rect().has_point(pos):
		_on_close_pressed()
	elif _min_button and _min_button.get_global_rect().has_point(pos):
		_on_minimize_pressed()
	elif _max_button and _max_button.get_global_rect().has_point(pos):
		_on_maximize_pressed()
	else:
		_handle_title_press(mouse)


# ============================================================================
# State sync
# ============================================================================

func _refresh_state() -> void:
	var active := false
	if SystemManager and SystemManager.display:
		active = SystemManager.display.is_window_chrome_active()
	if active != _active:
		_active = active
		_apply_nonclient_area()
	# Always sync visibility: when the app STARTS with the chrome inactive
	# (fullscreen restore), both active and _active are false, so the change
	# guard above never fires and the strip would keep its default visible=true.
	visible = active
	_refresh_maximize_icon()


func _refresh_maximize_icon() -> void:
	if not is_instance_valid(_max_button):
		return
	var maximized := false
	if SystemManager and SystemManager.display:
		maximized = SystemManager.display.is_window_maximized()
	_max_button.icon_name = "window-restore" if maximized else "window-maximize"


func _on_window_chrome_changed(_chrome_active: bool) -> void:
	_refresh_state()


func _on_window_size_changed() -> void:
	_refresh_state()


func _on_title_changed() -> void:
	var window := get_window()
	if _title_label and window:
		_title_label.text = window.title


func _on_resized() -> void:
	if _active:
		_apply_nonclient_area()


func _apply_nonclient_area() -> void:
	var window := get_window()
	if window == null:
		return
	if not USE_NONCLIENT_AREA or not _active or get_viewport() != window:
		if window.nonclient_area != Rect2i():
			window.nonclient_area = Rect2i()
		return
	var rect := get_global_rect()
	if rect.size.x < 1.0 or rect.size.y < 1.0:
		return
	# Root-window canvas coords are window pixels (no stretch/camera), so the
	# global rect maps 1:1 onto the embedder's window rect.
	window.nonclient_area = Rect2i(Vector2i(rect.position), Vector2i(rect.size))


# ============================================================================
# Theme / scale
# ============================================================================

func refresh_theme() -> void:
	_apply_colors()


func refresh_scale() -> void:
	custom_minimum_size = Vector2(0, M3Units.dpi(BAR_HEIGHT_DP))
	offset_bottom = M3Units.dpi(BAR_HEIGHT_DP)
	if _background:
		_background.content_margin_right = M3Units.dpi(2)
	if _title_label:
		_title_label.offset_left = M3Units.dpi(TITLE_PAD_DP)
	_apply_colors()


func _apply_colors() -> void:
	if _background:
		# Match the navigation bar background so the desktop chrome blends in.
		_background.bg_color = M3Theme.get_surface_container()
	if _title_label:
		_title_label.add_theme_color_override("font_color", M3Theme.get_on_surface_variant())
		_title_label.add_theme_font_size_override("font_size", M3Units.dpi(TITLE_FONT_SIZE_DP))
