@tool
class_name M3TextField
extends LineEdit

const M3Units = preload("res://addons/m3/M3Units.gd")

## Material 3 Text Field Component
## Extends native LineEdit with M3 styling: filled/outlined variants,
## floating labels, leading/trailing icons, prefix/suffix text.

enum Variant { FILLED, OUTLINED }

# ============================================
# EXPORTS
# ============================================

@export var field_variant: Variant = Variant.OUTLINED:
	set(value):
		if value == field_variant:
			return
		field_variant = value
		if _ready_called:
			_update_theme()
			_update_layout()
			queue_redraw()

@export var label_text: String = "":
	set(value):
		if value == label_text:
			return
		label_text = value
		if _ready_called:
			_update_floating_label()
			_update_layout()
			queue_redraw()

@export var supporting_text: String = "":
	set(value):
		if value == supporting_text:
			return
		supporting_text = value
		if _ready_called:
			_update_supporting_text()

@export var error_text: String = "":
	set(value):
		if value == error_text:
			return
		error_text = value
		if _ready_called:
			_update_supporting_text()
			_update_theme()
			queue_redraw()

@export var leading_icon: String = "":
	set(value):
		if value == leading_icon:
			return
		leading_icon = value
		if _ready_called:
			_update_icons()
			_update_layout()

@export var trailing_icon: String = "":
	set(value):
		if value == trailing_icon:
			return
		trailing_icon = value
		if _ready_called:
			_update_icons()
			_update_layout()

@export var prefix_text: String = "":
	set(value):
		if value == prefix_text:
			return
		prefix_text = value
		if _ready_called:
			_update_prefix_suffix()
			_update_layout()

@export var suffix_text: String = "":
	set(value):
		if value == suffix_text:
			return
		suffix_text = value
		if _ready_called:
			_update_prefix_suffix()
			_update_layout()

@export var m3_tooltip_text: String = ""
@export var m3_tooltip_variant: M3Tooltip.Variant = M3Tooltip.Variant.PLAIN

# ============================================
# SIGNALS
# ============================================

signal field_focus_entered
signal field_focus_exited

# ============================================
# CONSTANTS
# ============================================

const CONTAINER_HEIGHT := 56.0
const H_PADDING := 16.0
const ICON_SIZE := 24.0
const ICON_GAP := 12.0
const PREFIX_GAP := 4.0
const SUFFIX_GAP := 4.0
const FLOATING_LABEL_FONT_SIZE := 12.0
const INPUT_FONT_SIZE := 16.0
const SUPPORTING_FONT_SIZE := 12.0
const BORDER_WIDTH := 1.0
const BORDER_WIDTH_FOCUSED := 2.0
const RADIUS := 4.0
const SUPPORTING_HEIGHT := 20.0

# ============================================
# INTERNAL
# ============================================

var _leading_icon_node: FontIcon
var _trailing_icon_node: FontIcon
var _prefix_label: Label
var _suffix_label: Label
var _floating_label: Label
var _supporting_label: Label
var _bg_panel: Panel

var _is_focused: bool = false
var _hovered: bool = false
var _menu_active: bool = false
var _ready_called: bool = false

var _cached_bg_sb: StyleBoxFlat
var _cached_border_sb: StyleBoxFlat
var _cached_patch_sb: StyleBoxFlat
var _cached_focus_ring_sb: StyleBoxFlat
var _cached_empty_normal: StyleBoxEmpty
var _cached_empty_focus: StyleBoxEmpty
var _cached_empty_readonly: StyleBoxEmpty
var _updating_layout: bool = false
var _cached_fonts: Dictionary = {}
var _font_icon_template: FontIconSettings = null

# ============================================
# LIFECYCLE
# ============================================

func _init():
	# Set defaults before entering tree so containers see correct flags
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_SHRINK_CENTER

func _ready():
	clip_contents = false
	_cached_fonts = M3Theme.load_fonts()
	_initialize_styleboxes()
	_create_visual_children()
	_update_icons()
	_update_prefix_suffix()
	_update_floating_label()
	_update_supporting_text()
	_update_theme()
	_update_layout()
	
	# Apply theme overrides once; _update_layout() only mutates margins
	add_theme_stylebox_override("normal", _cached_empty_normal)
	add_theme_stylebox_override("focus", _cached_empty_focus)
	add_theme_stylebox_override("read_only", _cached_empty_readonly)
	
	# Ensure minimum size is respected (prevents collapse in containers)
	var min_size = _get_minimum_size()
	if custom_minimum_size.y < min_size.y:
		custom_minimum_size.y = min_size.y
	if custom_minimum_size.x < min_size.x:
		custom_minimum_size.x = min_size.x
	
	# Connect native signals
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(_on_focus_exited)
	text_changed.connect(_on_text_changed)
	
	M3Tooltip.bind(self, m3_tooltip_text, m3_tooltip_variant)
	
	_ready_called = true
	queue_redraw()
	
	# Force layout after container has sized us
	call_deferred("_update_layout")

func _exit_tree():
	M3Tooltip.unbind(self)

func _initialize_styleboxes():
	_cached_bg_sb = StyleBoxFlat.new()
	_cached_bg_sb.anti_aliasing = true
	_cached_bg_sb.anti_aliasing_size = 1.0
	
	_cached_border_sb = StyleBoxFlat.new()
	_cached_border_sb.bg_color = Color.TRANSPARENT
	_cached_border_sb.anti_aliasing = true
	_cached_border_sb.anti_aliasing_size = 1.0
	
	_cached_patch_sb = StyleBoxFlat.new()
	_cached_patch_sb.set_corner_radius_all(0)
	_cached_patch_sb.anti_aliasing = false
	
	_cached_focus_ring_sb = StyleBoxFlat.new()
	_cached_focus_ring_sb.bg_color = Color.TRANSPARENT
	_cached_focus_ring_sb.anti_aliasing = true
	_cached_focus_ring_sb.anti_aliasing_size = 1.0
	
	# Pooled StyleBoxEmpty instances for LineEdit margin overrides
	# LineEdit only re-reads margins on new resource assignment, but we can
	# reuse instances to avoid per-layout allocation churn.
	_cached_empty_normal = StyleBoxEmpty.new()
	_cached_empty_focus = StyleBoxEmpty.new()
	_cached_empty_readonly = StyleBoxEmpty.new()

func _create_visual_children():
	# Background panel - draws behind parent (show_behind_parent) so text renders on top
	_bg_panel = Panel.new()
	_bg_panel.show_behind_parent = true
	_bg_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg_panel)
	
	# Create icons
	_leading_icon_node = FontIcon.new()
	_leading_icon_node.icon_settings = _get_font_icon_settings()
	_leading_icon_node.visible = false
	_leading_icon_node.z_index = 1
	_leading_icon_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	_trailing_icon_node = FontIcon.new()
	_trailing_icon_node.icon_settings = _get_font_icon_settings()
	_trailing_icon_node.visible = false
	_trailing_icon_node.z_index = 1
	_trailing_icon_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Create prefix/suffix labels
	_prefix_label = Label.new()
	_prefix_label.visible = false
	_prefix_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_prefix_label.z_index = 1
	_prefix_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	_suffix_label = Label.new()
	_suffix_label.visible = false
	_suffix_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_suffix_label.z_index = 1
	_suffix_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Create floating label
	_floating_label = Label.new()
	_floating_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_floating_label.z_index = 2
	_floating_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	# Create supporting label
	_supporting_label = Label.new()
	_supporting_label.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	_supporting_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	add_child(_leading_icon_node)
	add_child(_trailing_icon_node)
	add_child(_prefix_label)
	add_child(_suffix_label)
	add_child(_floating_label)
	add_child(_supporting_label)

func _notification(what: int):
	if what == NOTIFICATION_RESIZED:
		if _ready_called and not _updating_layout:
			_update_layout()
			queue_redraw()

# ============================================
# SIGNAL HANDLERS
# ============================================

func _on_mouse_entered():
	_hovered = true
	queue_redraw()

func _on_mouse_exited():
	_hovered = false
	queue_redraw()

func _on_focus_entered():
	_is_focused = true
	field_focus_entered.emit()
	_update_theme()
	_update_floating_label()
	_update_layout()
	queue_redraw()

func _on_focus_exited():
	_is_focused = false
	field_focus_exited.emit()
	_update_theme()
	_update_floating_label()
	_update_layout()
	queue_redraw()

func set_menu_active(active: bool):
	_menu_active = active
	_update_theme()
	_update_floating_label()
	_update_layout()
	queue_redraw()

func _on_text_changed(_new_text: String):
	_update_floating_label()
	_update_layout()
	queue_redraw()

# ============================================
# DRAW
# ============================================

func _draw():
	var container_height = M3Units.dp(CONTAINER_HEIGHT)
	var rect = Rect2(Vector2.ZERO, Vector2(size.x, container_height))
	
	var has_error = not error_text.is_empty()
	var border_color: Color
	var border_width: float
	
	# Focus must be checked BEFORE not editable so non-editable focused controls
	# (e.g., M3OptionButton) still show focused state.
	if has_error:
		border_color = M3Theme.get_error()
		border_width = M3Units.dp(BORDER_WIDTH_FOCUSED)
	elif _is_focused or _menu_active:
		border_color = M3Theme.get_primary()
		border_width = M3Units.dp(BORDER_WIDTH_FOCUSED)
	elif not editable:
		border_color = M3Theme.disabled_color(M3Theme.get_outline())
		border_width = M3Units.dp(BORDER_WIDTH)
	elif _hovered:
		border_color = M3Theme.get_on_surface()
		border_width = M3Units.dp(BORDER_WIDTH)
	else:
		border_color = M3Theme.get_outline()
		border_width = M3Units.dp(BORDER_WIDTH)
	
	_update_bg_panel()
	
	if field_variant == Variant.FILLED:
		_draw_filled(rect, border_color, border_width)
	else:
		_draw_outlined(rect, border_color, border_width)
	
	# TODO: Focus ring behavior temporarily disabled — revisit with cleaner
	# implementation that doesn't overlap with floating label patch
	# if _is_focused and not _menu_active:
	#     _draw_focus_ring(rect)

func _draw_filled(rect: Rect2, border_color: Color, border_width: float):
	var line_y = rect.position.y + rect.size.y - border_width / 2.0
	draw_line(
		Vector2(rect.position.x, line_y),
		Vector2(rect.position.x + rect.size.x, line_y),
		border_color,
		border_width
	)

func _draw_outlined(rect: Rect2, border_color: Color, border_width: float):
	_cached_border_sb.border_color = border_color
	_cached_border_sb.set_border_width_all(border_width)
	_cached_border_sb.set_corner_radius_all(M3Units.dpi(RADIUS))
	_cached_border_sb.draw(get_canvas_item(), rect)
	
	if _should_float_label() and not label_text.is_empty():
		var label_rect = _floating_label.get_rect()
		if label_rect.size.x > 0:
			var patch_padding = M3Units.dp(4.0)
			var patch_rect = Rect2(
				label_rect.position.x - patch_padding,
				label_rect.position.y,
				label_rect.size.x + patch_padding * 2,
				label_rect.size.y
			)
			_cached_patch_sb.bg_color = M3Theme.get_surface()
			_cached_patch_sb.draw(get_canvas_item(), patch_rect)

func _draw_focus_ring(rect: Rect2):
	var ring_color = M3Theme.get_primary()
	var ring_width = M3Units.dp(1)
	
	_cached_focus_ring_sb.border_color = ring_color
	_cached_focus_ring_sb.set_border_width_all(ring_width)
	
	if field_variant == Variant.FILLED:
		# Ring around the filled area (top corners rounded only)
		_cached_focus_ring_sb.corner_radius_top_left = M3Units.dpi(RADIUS)
		_cached_focus_ring_sb.corner_radius_top_right = M3Units.dpi(RADIUS)
		_cached_focus_ring_sb.corner_radius_bottom_left = 0
		_cached_focus_ring_sb.corner_radius_bottom_right = 0
	else:
		# Ring around the outlined area (all corners rounded)
		_cached_focus_ring_sb.set_corner_radius_all(M3Units.dpi(RADIUS))
	
	# Draw at the border edge (not grown outward) so the floating label patch
	# covers the top portion and prevents overlap
	_cached_focus_ring_sb.draw(get_canvas_item(), rect)

func _update_bg_panel():
	if not _bg_panel:
		return
	
	var container_height = M3Units.dp(CONTAINER_HEIGHT)
	var rect = Rect2(Vector2.ZERO, Vector2(size.x, container_height))
	
	if field_variant == Variant.FILLED:
		var bg_color = M3Theme.get_surface_container_low()
		if not editable:
			bg_color = M3Theme.disabled_color(bg_color)
		
		var sb = _cached_bg_sb
		sb.bg_color = bg_color
		sb.corner_radius_top_left = M3Units.dpi(RADIUS)
		sb.corner_radius_top_right = M3Units.dpi(RADIUS)
		sb.corner_radius_bottom_left = 0
		sb.corner_radius_bottom_right = 0
		_bg_panel.add_theme_stylebox_override("panel", sb)
		_bg_panel.visible = true
	else:
		# Outlined variant - transparent background
		_bg_panel.visible = false

# ============================================
# UPDATES
# ============================================

func _get_font_icon_settings() -> FontIconSettings:
	if _font_icon_template == null:
		_font_icon_template = FontIconSettings.new()
		_font_icon_template.icon_size = M3Units.dp(ICON_SIZE)
		_font_icon_template.icon_font = "MaterialIcons"
	return _font_icon_template.duplicate()

func _update_theme():
	var has_error = not error_text.is_empty()
	if _cached_fonts.is_empty():
		_cached_fonts = M3Theme.load_fonts()
	var fonts = _cached_fonts
	
	# Input text styling (native LineEdit)
	var input_color: Color
	if not editable:
		input_color = M3Theme.disabled_color(M3Theme.get_on_surface())
	else:
		input_color = M3Theme.get_on_surface()
	
	add_theme_color_override("font_color", input_color)
	add_theme_color_override("font_placeholder_color", M3Theme.get_on_surface_variant())
	add_theme_color_override("caret_color", M3Theme.get_primary())
	add_theme_color_override("selection_color", M3Theme.get_primary_container())
	add_theme_font_override("font", fonts["regular"])
	add_theme_font_size_override("font_size", M3Units.dp(INPUT_FONT_SIZE))
	
	# Floating label colors
	var label_color: Color
	if not editable:
		label_color = M3Theme.disabled_color(M3Theme.get_on_surface_variant())
	elif has_error:
		label_color = M3Theme.get_error()
	elif _is_focused or _menu_active:
		label_color = M3Theme.get_primary()
	else:
		label_color = M3Theme.get_on_surface_variant()
	
	if _floating_label:
		_floating_label.add_theme_color_override("font_color", label_color)
		_floating_label.add_theme_font_override("font", fonts["regular"])
	
	# Prefix/suffix colors
	if _prefix_label:
		_prefix_label.add_theme_color_override("font_color", input_color)
		_prefix_label.add_theme_font_override("font", fonts["regular"])
		_prefix_label.add_theme_font_size_override("font_size", M3Units.dp(INPUT_FONT_SIZE))
	
	if _suffix_label:
		_suffix_label.add_theme_color_override("font_color", input_color)
		_suffix_label.add_theme_font_override("font", fonts["regular"])
		_suffix_label.add_theme_font_size_override("font_size", M3Units.dp(INPUT_FONT_SIZE))
	
	# Icon colors
	var icon_color = M3Theme.disabled_color(M3Theme.get_on_surface_variant()) if not editable else M3Theme.get_on_surface_variant()
	if _leading_icon_node:
		_leading_icon_node.modulate = icon_color
	if _trailing_icon_node:
		_trailing_icon_node.modulate = icon_color
	
	# Supporting text colors
	var supporting_color: Color
	if has_error:
		supporting_color = M3Theme.get_error()
	elif not editable:
		supporting_color = M3Theme.disabled_color(M3Theme.get_on_surface_variant())
	else:
		supporting_color = M3Theme.get_on_surface_variant()
	
	if _supporting_label:
		_supporting_label.add_theme_color_override("font_color", supporting_color)
		_supporting_label.add_theme_font_override("font", fonts["regular"])
		_supporting_label.add_theme_font_size_override("font_size", M3Units.dp(SUPPORTING_FONT_SIZE))

func _update_layout():
	if _updating_layout:
		return
	_updating_layout = true
	
	var h_padding = M3Units.dp(H_PADDING)
	var icon_size = M3Units.dp(ICON_SIZE)
	var icon_gap = M3Units.dp(ICON_GAP)
	var container_height = M3Units.dp(CONTAINER_HEIGHT)
	
	# Update background panel size
	if _bg_panel:
		_bg_panel.position = Vector2.ZERO
		_bg_panel.size = Vector2(size.x, container_height)
	
	var available_width = size.x
	var current_x = h_padding
	
	# Leading icon
	if _leading_icon_node and _leading_icon_node.visible:
		_leading_icon_node.position = Vector2(current_x, (container_height - icon_size) / 2.0)
		_leading_icon_node.size = Vector2(icon_size, icon_size)
		current_x += icon_size + icon_gap
	
	# Prefix
	if _prefix_label and _prefix_label.visible:
		var prefix_width = _prefix_label.get_minimum_size().x
		_prefix_label.position = Vector2(current_x, (container_height - _prefix_label.size.y) / 2.0)
		_prefix_label.size = Vector2(prefix_width, container_height)
		current_x += prefix_width + M3Units.dp(PREFIX_GAP)
	
	# Calculate right side
	var right_x = size.x - h_padding
	
	# Trailing icon
	if _trailing_icon_node and _trailing_icon_node.visible:
		right_x -= icon_size + icon_gap
		_trailing_icon_node.position = Vector2(right_x + icon_gap, (container_height - icon_size) / 2.0)
		_trailing_icon_node.size = Vector2(icon_size, icon_size)
	
	# Suffix
	if _suffix_label and _suffix_label.visible:
		var suffix_width = _suffix_label.get_minimum_size().x
		right_x -= suffix_width + M3Units.dp(SUFFIX_GAP)
		_suffix_label.position = Vector2(right_x + M3Units.dp(SUFFIX_GAP), (container_height - _suffix_label.size.y) / 2.0)
		_suffix_label.size = Vector2(suffix_width, container_height)
	
	# Determine if label should float
	var should_float = _should_float_label() and not label_text.is_empty()
	
	# Native LineEdit text padding (content margins on stylebox)
	# Text area is confined to container_height; supporting text drawn below by _supporting_label
	var text_left = current_x
	var text_right = size.x - right_x
	var text_top = 0.0
	var text_bottom = 0.0
	if not supporting_text.is_empty() or not error_text.is_empty():
		text_bottom = M3Units.dp(SUPPORTING_HEIGHT)
	
	if field_variant == Variant.FILLED and should_float:
		text_top = M3Units.dp(14.0)
	
	# Reuse pooled StyleBoxEmpty instances (LineEdit only re-reads margins on new resource)
	_cached_empty_normal.content_margin_left = text_left
	_cached_empty_normal.content_margin_right = text_right
	_cached_empty_normal.content_margin_top = text_top
	_cached_empty_normal.content_margin_bottom = text_bottom
	
	_cached_empty_focus.content_margin_left = text_left
	_cached_empty_focus.content_margin_right = text_right
	_cached_empty_focus.content_margin_top = text_top
	_cached_empty_focus.content_margin_bottom = text_bottom
	
	_cached_empty_readonly.content_margin_left = text_left
	_cached_empty_readonly.content_margin_right = text_right
	_cached_empty_readonly.content_margin_top = text_top
	_cached_empty_readonly.content_margin_bottom = text_bottom
	
	# Floating label
	if _floating_label and not label_text.is_empty():
		if should_float:
			var label_font_size = M3Units.dp(FLOATING_LABEL_FONT_SIZE)
			_floating_label.add_theme_font_size_override("font_size", label_font_size)
			_floating_label.size = Vector2(_floating_label.get_minimum_size().x, label_font_size * 1.2)
			
			if field_variant == Variant.FILLED:
				_floating_label.position = Vector2(current_x, M3Units.dp(4.0))
			else:
				_floating_label.position = Vector2(current_x, -M3Units.dp(6.0))
		else:
			var label_font_size = M3Units.dp(INPUT_FONT_SIZE)
			_floating_label.add_theme_font_size_override("font_size", label_font_size)
			_floating_label.size = Vector2(_floating_label.get_minimum_size().x, container_height)
			_floating_label.position = Vector2(current_x, 0)
	
	# Supporting text
	if _supporting_label:
		_supporting_label.position = Vector2(h_padding, container_height + M3Units.dp(4.0))
		_supporting_label.size = Vector2(available_width - h_padding * 2, M3Units.dp(SUPPORTING_HEIGHT))
	
	_updating_layout = false

func _update_floating_label():
	if not _floating_label:
		return
	
	if label_text.is_empty():
		_floating_label.visible = false
		return
	
	_floating_label.visible = true
	_floating_label.text = label_text
	
	if _ready_called:
		_update_layout()

func _update_supporting_text():
	if not _supporting_label:
		return
	
	if not error_text.is_empty():
		_supporting_label.text = error_text
		_supporting_label.visible = true
	elif not supporting_text.is_empty():
		_supporting_label.text = supporting_text
		_supporting_label.visible = true
	else:
		_supporting_label.visible = false
	
	if _ready_called:
		_update_theme()

func _update_icons():
	if not _leading_icon_node or not _trailing_icon_node:
		return
	
	if leading_icon.is_empty():
		_leading_icon_node.visible = false
	else:
		_leading_icon_node.visible = true
		_leading_icon_node.icon_settings.icon_name = leading_icon
		_leading_icon_node.icon_settings.icon_size = M3Units.dp(ICON_SIZE)
	
	if trailing_icon.is_empty():
		_trailing_icon_node.visible = false
	else:
		_trailing_icon_node.visible = true
		_trailing_icon_node.icon_settings.icon_name = trailing_icon
		_trailing_icon_node.icon_settings.icon_size = M3Units.dp(ICON_SIZE)

func _update_prefix_suffix():
	if not _prefix_label or not _suffix_label:
		return
	
	if prefix_text.is_empty():
		_prefix_label.visible = false
	else:
		_prefix_label.visible = true
		_prefix_label.text = prefix_text
	
	if suffix_text.is_empty():
		_suffix_label.visible = false
	else:
		_suffix_label.visible = true
		_suffix_label.text = suffix_text

func _should_float_label() -> bool:
	if _is_focused or _menu_active:
		return true
	return not text.is_empty()

# ============================================
# SIZE
# ============================================

func _get_minimum_size() -> Vector2:
	var min_width = M3Units.dp(H_PADDING * 2)
	if not leading_icon.is_empty():
		min_width += M3Units.dp(ICON_SIZE + ICON_GAP)
	if not trailing_icon.is_empty():
		min_width += M3Units.dp(ICON_SIZE + ICON_GAP)
	if not prefix_text.is_empty():
		min_width += M3Units.dp(20)
	if not suffix_text.is_empty():
		min_width += M3Units.dp(20)
	
	var min_height = M3Units.dp(CONTAINER_HEIGHT)
	
	if not supporting_text.is_empty() or not error_text.is_empty():
		min_height += M3Units.dp(SUPPORTING_HEIGHT)
	
	return Vector2(min_width, min_height)

# ============================================
# PUBLIC
# ============================================

func is_virtual_keyboard_enabled() -> bool:
	return true

func refresh_theme():
	if not _ready_called:
		return
	_update_theme()
	_update_layout()
	queue_redraw()
