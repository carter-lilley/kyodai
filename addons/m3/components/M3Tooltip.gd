class_name M3Tooltip
extends M3Overlay

const M3Units = preload("res://addons/m3/M3Units.gd")

## Material 3 Tooltip Overlay
## Extends M3Overlay for consistent overlay behavior.
## Single shared instance pattern - only one tooltip visible at a time.

enum Variant { PLAIN, RICH }

# ============================================
# CONSTANTS
# ============================================

const PLAIN_PADDING_H := 8.0
const PLAIN_PADDING_V := 4.0
const PLAIN_RADIUS := 4.0
const PLAIN_MAX_WIDTH := 120.0

const RICH_PADDING := 16.0
const RICH_RADIUS := 12.0
const RICH_MAX_WIDTH := 280.0

const VIEWPORT_MARGIN := 8.0
const OFFSET_WITH_BOUNDARY := 4.0
const OFFSET_WITHOUT_BOUNDARY := 8.0
const SHOW_DELAY_MS := 500

# ============================================
# STATIC STATE
# ============================================

static var _delay_timer: Timer = null
static var _scheduled_control: Control = null

# ============================================
# EXPORTS (instance-level, set before show_overlay)
# ============================================

var _tooltip_text: String = ""
var _tooltip_variant: Variant = Variant.PLAIN
var _anchor_node: Control = null
var _anchor_rect_override: Rect2 = Rect2()

# ============================================
# INTERNAL
# ============================================

var _label: Label
var _rich_label: RichTextLabel
var _bg_panel: Panel
var _anchor_start_pos: Vector2 = Vector2.ZERO

# ============================================
# STATIC BIND API
# ============================================

## Bind a tooltip to a control. Call from _ready().
static func bind(control: Control, text: String, variant: Variant = Variant.PLAIN):
	if text.is_empty():
		return
	
	# Store tooltip data in control metadata
	control.set_meta("m3_tooltip_text", text)
	control.set_meta("m3_tooltip_variant", variant)
	
	# Connect signals (avoid duplicates)
	if not control.mouse_entered.is_connected(_on_control_mouse_entered):
		control.mouse_entered.connect(_on_control_mouse_entered.bind(control))
	if not control.mouse_exited.is_connected(_on_control_mouse_exited):
		control.mouse_exited.connect(_on_control_mouse_exited.bind(control))
	if not control.focus_entered.is_connected(_on_control_focus_entered):
		control.focus_entered.connect(_on_control_focus_entered.bind(control))
	if not control.focus_exited.is_connected(_on_control_focus_exited):
		control.focus_exited.connect(_on_control_focus_exited.bind(control))

## Unbind tooltip from a control. Call in _exit_tree() or before queue_free.
static func unbind(control: Control):
	if control.mouse_entered.is_connected(_on_control_mouse_entered):
		control.mouse_entered.disconnect(_on_control_mouse_entered)
	if control.mouse_exited.is_connected(_on_control_mouse_exited):
		control.mouse_exited.disconnect(_on_control_mouse_exited)
	if control.focus_entered.is_connected(_on_control_focus_entered):
		control.focus_entered.disconnect(_on_control_focus_entered)
	if control.focus_exited.is_connected(_on_control_focus_exited):
		control.focus_exited.disconnect(_on_control_focus_exited)
	
	control.remove_meta("m3_tooltip_text")
	control.remove_meta("m3_tooltip_variant")

static func _ensure_timer():
	if _delay_timer == null or not is_instance_valid(_delay_timer):
		_delay_timer = Timer.new()
		_delay_timer.one_shot = true
		_delay_timer.wait_time = SHOW_DELAY_MS / 1000.0
		_delay_timer.timeout.connect(_on_timer_timeout)
		var tree = Engine.get_main_loop()
		if tree and tree.root:
			tree.root.add_child(_delay_timer)

static func _on_control_mouse_entered(control: Control):
	_schedule_show(control)

static func _on_control_mouse_exited(control: Control):
	_cancel_show()
	if M3Overlay.is_showing("tooltip"):
		var active = M3Overlay._active.get("tooltip")
		if active is M3Tooltip and active._anchor_node == control:
			active.dismiss()

static func _on_control_focus_entered(control: Control):
	_schedule_show(control)

static func _on_control_focus_exited(control: Control):
	_cancel_show()
	if M3Overlay.is_showing("tooltip"):
		var active = M3Overlay._active.get("tooltip")
		if active is M3Tooltip and active._anchor_node == control:
			active.dismiss()

static func _schedule_show(control: Control):
	_ensure_timer()
	_scheduled_control = control
	_delay_timer.stop()
	_delay_timer.start()

static func _cancel_show():
	if _delay_timer:
		_delay_timer.stop()
	_scheduled_control = null

static func _on_timer_timeout():
	if _scheduled_control == null or not is_instance_valid(_scheduled_control):
		return
	
	var control = _scheduled_control
	_scheduled_control = null
	
	var text = control.get_meta("m3_tooltip_text", "")
	if text.is_empty():
		return
	
	var variant = control.get_meta("m3_tooltip_variant", Variant.PLAIN)
	_show_for(control, text, variant)

static func _show_for(control: Control, text: String, variant: Variant):
	var tooltip = M3Tooltip.new()
	tooltip._tooltip_text = text
	tooltip._tooltip_variant = variant
	tooltip._anchor_node = control
	
	# Check for custom anchor rect
	if control.has_method("get_tooltip_anchor_rect"):
		tooltip._anchor_rect_override = control.get_tooltip_anchor_rect()
	
	var parent = M3Overlay.get_overlay_parent()
	if parent:
		parent.add_child(tooltip)
		tooltip.show_overlay()

# ============================================
# LIFECYCLE
# ============================================

func _init():
	super._init()
	overlay_type = "tooltip"
	overlay_layer = 110

func _ready():
	super._ready()
	_create_visuals()
	_position_and_show()

func _process(_delta):
	# Dismiss if anchor has moved (e.g., page scrolled)
	if not visible or _anchor_node == null or not is_instance_valid(_anchor_node):
		return
	if _anchor_node.global_position.distance_to(_anchor_start_pos) > 1.0:
		dismiss()

func _create_visuals():
	# Background panel
	_bg_panel = Panel.new()
	_bg_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg_panel)
	
	# Plain label
	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_label)
	
	# Rich label
	_rich_label = RichTextLabel.new()
	_rich_label.bbcode_enabled = true
	_rich_label.fit_content = true
	_rich_label.scroll_active = false
	_rich_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rich_label)

func _position_and_show():
	_update_appearance()
	
	# Store anchor starting position for scroll dismissal
	if _anchor_node and is_instance_valid(_anchor_node):
		_anchor_start_pos = _anchor_node.global_position
	
	# Rich tooltips need text set BEFORE measurement (get_content_height)
	if _tooltip_variant == Variant.RICH:
		_rich_label.text = _tooltip_text
	
	var tooltip_size = _get_tooltip_size()
	var anchor_rect = _get_anchor_rect()
	var viewport_size = get_viewport().get_visible_rect().size
	var margin = M3Units.dp(VIEWPORT_MARGIN)
	
	var pos: Vector2
	if _tooltip_variant == Variant.PLAIN:
		pos = _position_plain(anchor_rect, tooltip_size, viewport_size, margin)
	else:
		pos = _position_rich(anchor_rect, tooltip_size, viewport_size, margin)
		var grid = M3Units.dp(8)
		pos = Vector2(floor(pos.x / grid) * grid, floor(pos.y / grid) * grid)
	
	# Position background panel
	_bg_panel.position = pos
	_bg_panel.size = tooltip_size
	
	# Position label and set text AFTER size is known (avoids cached layout bug)
	if _tooltip_variant == Variant.PLAIN:
		var pad_h = M3Units.dp(PLAIN_PADDING_H)
		_label.position = Vector2(pos.x + pad_h, pos.y)
		_label.size = Vector2(tooltip_size.x - pad_h * 2, tooltip_size.y)
		_label.text = _tooltip_text
	else:
		var pad = M3Units.dp(RICH_PADDING)
		_rich_label.position = Vector2(pos.x + pad, pos.y + pad)
		_rich_label.size = Vector2(tooltip_size.x - pad * 2, tooltip_size.y - pad * 2)

func _get_anchor_rect() -> Rect2:
	if not _anchor_node:
		return Rect2()
	
	if _anchor_rect_override.has_area():
		return Rect2(
			_anchor_node.global_position + _anchor_rect_override.position,
			_anchor_rect_override.size
		)
	
	return _anchor_node.get_global_rect()

# ============================================
# POSITIONING
# ============================================

func _position_plain(anchor_rect: Rect2, tooltip_size: Vector2, viewport_size: Vector2, margin: float) -> Vector2:
	var offset = M3Units.dp(_get_offset_for_anchor())
	var placement = _get_placement_for_anchor()
	
	var pos = anchor_rect.position + Vector2((anchor_rect.size.x - tooltip_size.x) / 2.0, 0)
	
	if placement == "below":
		pos.y = anchor_rect.position.y + anchor_rect.size.y + offset
	else:
		pos.y = anchor_rect.position.y - tooltip_size.y - offset
	
	pos.x = clamp(pos.x, margin, viewport_size.x - tooltip_size.x - margin)
	pos.y = clamp(pos.y, margin, viewport_size.y - tooltip_size.y - margin)
	
	if placement == "below" and pos.y + tooltip_size.y > viewport_size.y - margin:
		pos.y = anchor_rect.position.y - tooltip_size.y - offset
		pos.y = max(pos.y, margin)
	elif placement == "above" and pos.y < margin:
		pos.y = anchor_rect.position.y + anchor_rect.size.y + offset
		pos.y = min(pos.y, viewport_size.y - tooltip_size.y - margin)
	
	return pos

func _position_rich(anchor_rect: Rect2, tooltip_size: Vector2, viewport_size: Vector2, margin: float) -> Vector2:
	var gap = M3Units.dp(8)
	
	var positions = [
		Vector2(anchor_rect.position.x + anchor_rect.size.x + gap, anchor_rect.position.y + anchor_rect.size.y + gap),
		Vector2(anchor_rect.position.x - tooltip_size.x - gap, anchor_rect.position.y + anchor_rect.size.y + gap),
		Vector2(anchor_rect.position.x + anchor_rect.size.x + gap, anchor_rect.position.y - tooltip_size.y - gap),
		Vector2(anchor_rect.position.x - tooltip_size.x - gap, anchor_rect.position.y - tooltip_size.y - gap),
	]
	
	for p in positions:
		var fits_x = p.x >= margin and p.x + tooltip_size.x <= viewport_size.x - margin
		var fits_y = p.y >= margin and p.y + tooltip_size.y <= viewport_size.y - margin
		var overlaps = Rect2(p, tooltip_size).intersects(anchor_rect)
		if fits_x and fits_y and not overlaps:
			return p
	
	var p = positions[0]
	p.x = clamp(p.x, margin, viewport_size.x - tooltip_size.x - margin)
	p.y = clamp(p.y, margin, viewport_size.y - tooltip_size.y - margin)
	return p

func _get_offset_for_anchor() -> float:
	if _has_visual_boundary(_anchor_node):
		return OFFSET_WITH_BOUNDARY
	return OFFSET_WITHOUT_BOUNDARY

func _get_placement_for_anchor() -> String:
	if _is_in_app_bar(_anchor_node):
		return "below"
	return "above"

func _has_visual_boundary(node: Control) -> bool:
	if not node:
		return false
	# Group-based overrides for extensibility (custom controls can opt in/out)
	if node.is_in_group("m3_no_boundary"):
		return false
	if node.is_in_group("m3_has_boundary"):
		return true
	# M3Checkbox is the exception: no visual boundary
	if is_instance_of(node, M3Checkbox):
		return false
	# All other interactive controls have visual boundaries
	return is_instance_of(node, Button) or is_instance_of(node, LineEdit) or is_instance_of(node, TextEdit) or is_instance_of(node, CheckBox) or is_instance_of(node, CheckButton) or is_instance_of(node, OptionButton)

func _is_in_app_bar(node: Control) -> bool:
	if not node:
		return false
	var parent = node.get_parent()
	while parent:
		if parent is M3NavigationBar or parent is M3NavigationRail:
			return true
		parent = parent.get_parent()
	return false

# ============================================
# SIZING
# ============================================

func _get_tooltip_size() -> Vector2:
	if _tooltip_variant == Variant.PLAIN:
		var pad_h = M3Units.dp(PLAIN_PADDING_H)
		var pad_v = M3Units.dp(PLAIN_PADDING_V)
		var max_w = M3Units.dp(PLAIN_MAX_WIDTH)
		var fonts = M3Theme.load_fonts()
		var font = fonts["medium"]
		var font_size = M3Units.dp(12)
		
		var text_width = font.get_string_size(_tooltip_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var width = min(text_width + pad_h * 2, max_w)
		
		var lines = 1 if text_width <= max_w - pad_h * 2 else ceili(text_width / (max_w - pad_h * 2))
		var line_height = font.get_height(font_size) * 1.2
		var height = max(lines * line_height + pad_v * 2, M3Units.dp(24))
		
		return Vector2(width, height)
	else:
		var pad = M3Units.dp(RICH_PADDING)
		var max_w = M3Units.dp(RICH_MAX_WIDTH)
		
		_rich_label.size = Vector2(max_w - pad * 2, 0)
		var text_size = _rich_label.get_content_height()
		
		var width = max_w
		var height = text_size + pad * 2
		
		return Vector2(width, height)

# ============================================
# APPEARANCE
# ============================================

func _update_appearance():
	var fonts = M3Theme.load_fonts()
	
	if _tooltip_variant == Variant.PLAIN:
		_label.visible = true
		_rich_label.visible = false
		
		var bg = M3Theme.get_inverse_surface()
		var text_color = M3Theme.get_inverse_on_surface()
		
		_label.add_theme_color_override("font_color", text_color)
		_label.add_theme_font_override("font", fonts["medium"])
		_label.add_theme_font_size_override("font_size", M3Units.dp(12))
		
		var sb = M3Theme.make_shadow(bg, M3Units.dpi(PLAIN_RADIUS), 2, Vector2(0, 1), Color(0, 0, 0, 0.15))
		_bg_panel.add_theme_stylebox_override("panel", sb)
	else:
		_label.visible = false
		_rich_label.visible = true
		
		var bg = M3Theme.get_surface_container()
		var text_color = M3Theme.get_on_surface()
		
		_rich_label.add_theme_color_override("default_color", text_color)
		_rich_label.add_theme_font_override("normal_font", fonts["regular"])
		_rich_label.add_theme_font_override("bold_font", fonts["bold"])
		_rich_label.add_theme_font_size_override("normal_font_size", M3Units.dp(14))
		
		var sb = M3Theme.make_shadow(bg, M3Units.dpi(RICH_RADIUS), 4, Vector2(0, 2), Color(0, 0, 0, 0.18))
		_bg_panel.add_theme_stylebox_override("panel", sb)
