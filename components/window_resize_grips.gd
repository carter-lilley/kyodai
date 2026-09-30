class_name WindowResizeGrips
extends Control

## Invisible resize grips for the borderless window. Stripping the native
## frame also strips its resize borders, so all four edges and all four
## corners get thin transparent strips that hand off to Window.start_resize()
## — the OS interactive resize loop (correct cursors, window-manager snap
## behavior, and true diagonal corner resize included; Godot 4.7's
## WindowResizeEdge covers all eight directions).
##
## The top strips overlay the top GRIP_DP px of the title bar row; its drag
## area and window buttons keep everything below that. Pressing the very top
## resizes instead of moving, matching native resize borders.
## Hidden while the chrome is inactive or the window is maximized, matching
## native behavior.

## Grip thickness in dp; scales with the UI so it stays hittable on HiDPI.
const GRIP_DP: float = 6

var _active: bool = false

var _left: Control = null
var _right: Control = null
var _top: Control = null
var _bottom: Control = null
var _top_left: Control = null
var _top_right: Control = null
var _bottom_left: Control = null
var _bottom_right: Control = null


func _ready() -> void:
	# Set anchors AND offsets explicitly. set_anchors_preset(PRESET_FULL_RECT)
	# preserves the node's current rect by shifting offsets instead of snapping
	# to the parent — on a fresh 0x0 node that pins the grips to a permanent 0x0
	# (degenerate strips, never hoverable; observed as "grips do nothing").
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # the edge strips still hit-test
	# Above app content (grid z = -1, toolbar/status z = 10); every overlay
	# lives on its own CanvasLayer and still renders above this.
	z_index = OverlayLayers.TOOLBAR_Z + 1

	# Corners are created last so they sit on top of the edge strips they
	# overlap (later siblings win hit-testing).
	_left = _make_grip("Left", 0.0, 0.0, 0.0, 1.0, DisplayServer.WINDOW_EDGE_LEFT,
		Control.CURSOR_HSIZE)
	_right = _make_grip("Right", 1.0, 0.0, 1.0, 1.0, DisplayServer.WINDOW_EDGE_RIGHT,
		Control.CURSOR_HSIZE)
	_bottom = _make_grip("Bottom", 0.0, 1.0, 1.0, 1.0, DisplayServer.WINDOW_EDGE_BOTTOM,
		Control.CURSOR_VSIZE)
	_top = _make_grip("Top", 0.0, 0.0, 1.0, 0.0, DisplayServer.WINDOW_EDGE_TOP,
		Control.CURSOR_VSIZE)
	_bottom_left = _make_grip("BottomLeft", 0.0, 1.0, 0.0, 1.0,
		DisplayServer.WINDOW_EDGE_BOTTOM_LEFT, Control.CURSOR_FDIAGSIZE)
	_bottom_right = _make_grip("BottomRight", 1.0, 1.0, 1.0, 1.0,
		DisplayServer.WINDOW_EDGE_BOTTOM_RIGHT, Control.CURSOR_BDIAGSIZE)
	# Top corners last so they win hit-testing over the top edge strip and the
	# left/right strips they overlap (diagonals pair by axis with their opposite:
	# TL<->BR, TR<->BL).
	_top_left = _make_grip("TopLeft", 0.0, 0.0, 0.0, 0.0,
		DisplayServer.WINDOW_EDGE_TOP_LEFT, Control.CURSOR_BDIAGSIZE)
	_top_right = _make_grip("TopRight", 1.0, 0.0, 1.0, 0.0,
		DisplayServer.WINDOW_EDGE_TOP_RIGHT, Control.CURSOR_FDIAGSIZE)

	_apply_grip_geometry()

	if SystemManager and SystemManager.display:
		if not SystemManager.display.window_chrome_changed.is_connected(_on_window_chrome_changed):
			SystemManager.display.window_chrome_changed.connect(_on_window_chrome_changed)
	var window := get_window()
	if window and not window.size_changed.is_connected(_on_window_size_changed):
		window.size_changed.connect(_on_window_size_changed)

	_refresh_state()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_IN and is_node_ready():
		_refresh_state()


func _make_grip(
	gname: String,
	anchor_left: float, anchor_top: float, anchor_right: float, anchor_bottom: float,
	edge: DisplayServer.WindowResizeEdge, cursor: Control.CursorShape
) -> Control:
	var grip := Control.new()
	grip.name = gname
	grip.mouse_filter = Control.MOUSE_FILTER_STOP
	grip.mouse_default_cursor_shape = cursor
	grip.anchor_left = anchor_left
	grip.anchor_top = anchor_top
	grip.anchor_right = anchor_right
	grip.anchor_bottom = anchor_bottom
	# Offsets are sized in _apply_grip_geometry(); the anchors keep each strip
	# glued to its window edge across resizes.
	grip.gui_input.connect(_on_grip_input.bind(edge))
	add_child(grip)
	return grip


func _apply_grip_geometry() -> void:
	var w := M3Units.dpi(GRIP_DP)
	_left.offset_left = 0.0
	_left.offset_right = w
	_left.offset_top = 0.0
	_left.offset_bottom = 0.0
	_right.offset_left = -w
	_right.offset_right = 0.0
	_right.offset_top = 0.0
	_right.offset_bottom = 0.0
	_bottom.offset_left = 0.0
	_bottom.offset_right = 0.0
	_bottom.offset_top = -w
	_bottom.offset_bottom = 0.0
	_top.offset_left = 0.0
	_top.offset_right = 0.0
	_top.offset_top = 0.0
	_top.offset_bottom = w
	_top_left.offset_left = 0.0
	_top_left.offset_right = w
	_top_left.offset_top = 0.0
	_top_left.offset_bottom = w
	_top_right.offset_left = -w
	_top_right.offset_right = 0.0
	_top_right.offset_top = 0.0
	_top_right.offset_bottom = w
	_bottom_left.offset_left = 0.0
	_bottom_left.offset_right = w
	_bottom_left.offset_top = -w
	_bottom_left.offset_bottom = 0.0
	_bottom_right.offset_left = -w
	_bottom_right.offset_right = 0.0
	_bottom_right.offset_top = -w
	_bottom_right.offset_bottom = 0.0


func _on_grip_input(event: InputEvent, edge: DisplayServer.WindowResizeEdge) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var window := get_window()
		if window:
			window.start_resize(edge)


func _refresh_state() -> void:
	var active := false
	if SystemManager and SystemManager.display:
		active = SystemManager.display.is_window_chrome_active() \
			and not SystemManager.display.is_window_maximized()
	# Sync unconditionally (no change-guard): a guard would leave the default
	# visible=true stuck when the node is created while chrome is inactive
	# (fullscreen startup), and would skip the first transition either way.
	_active = active
	visible = active


func _on_window_chrome_changed(_active: bool) -> void:
	_refresh_state()


func _on_window_size_changed() -> void:
	_refresh_state()


func refresh_scale() -> void:
	_apply_grip_geometry()
