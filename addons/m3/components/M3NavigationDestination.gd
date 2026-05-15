@tool
class_name M3NavigationDestination
extends M3Button

static var _shared_empty_stylebox: StyleBoxEmpty = StyleBoxEmpty.new()

## Material 3 Navigation Destination
## Extends M3Button with navigation-specific layout.
## Draws pill-shaped active and hover indicators via _draw().

enum LayoutMode { VERTICAL, HORIZONTAL }

# ============================================
# NAV SIZE SPECS (all values in dp)
# ============================================

const NAV_SIZE_SPECS = {
	LayoutMode.VERTICAL: {
		"height": 60,
		"icon_size": 24,
		"radius": 16,
		"font_size": 12,
		"padding_h": 0,
		"icon_gap": 0,
	},
	LayoutMode.HORIZONTAL: {
		"height": 56,
		"icon_size": 24,
		"radius": 16,
		"font_size": 14,
		"padding_h": 0,
		"icon_gap": 0,
	},
}

# ============================================
# EXPORTS
# ============================================

@export var destination_icon: String = "":
	set(value):
		if value == destination_icon:
			return
		destination_icon = value
		icon_name = value

@export var destination_label: String = "":
	set(value):
		if value == destination_label:
			return
		destination_label = value
		_update_label()

@export var destination_layout: LayoutMode = LayoutMode.VERTICAL:
	set(value):
		if value == destination_layout:
			return
		destination_layout = value
		_update_size()
		_update_theme()
		_update_layout()

@export var label_visibility: M3Navigation.LabelVisibility = M3Navigation.LabelVisibility.LABELED:
	set(value):
		if value == label_visibility:
			return
		label_visibility = value
		_update_label()
		_update_layout()

@export var active: bool = false:
	set(value):
		if value == active:
			return
		active = value
		button_pressed = active
		_invalidate_color_cache()
		_update_theme()
		_update_label()

# ============================================
# INTERNAL
# ============================================

var _label_node: Label
var _hovered: bool = false
var _draw_sb: StyleBoxFlat
var _cached_variant_colors: Dictionary = {}

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	button_type = Type.TOGGLE
	button_variant = Variant.TEXT
	button_shape = Shape.ROUNDED
	flat = true
	
	super._ready()
	
	# Create label (M3Button doesn't have one)
	_label_node = Label.new()
	_label_node.name = "Label"
	_label_node.visible = false
	_label_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_label_node)
	
	_update_label()
	_update_layout()
	
	# Track hover state via notifications (more reliable than signals)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	
	# Clear native focus stylebox so focus ring is drawn only around the pill
	add_theme_stylebox_override("focus", _shared_empty_stylebox)

# ============================================
# OVERRIDES
# ============================================

func _get_size_spec() -> Dictionary:
	return NAV_SIZE_SPECS[destination_layout]

func _update_theme():
	super._update_theme()
	# Clear native focus stylebox after parent sets it
	# so focus ring is drawn only around the pill in _draw()
	add_theme_stylebox_override("focus", _shared_empty_stylebox)

func _get_variant_colors(selected: bool) -> Dictionary:
	var cache_key = str(selected) + "_" + str(disabled)
	if _cached_variant_colors.has(cache_key):
		return _cached_variant_colors[cache_key]
	
	var result = {}
	
	# Transparent background - pills drawn in _draw()
	result.bg = Color.TRANSPARENT
	result.border_c = Color.TRANSPARENT
	result.border_w = 0
	
	if selected:
		result.text = M3Theme.get_on_secondary_container()
		result.hover_bg = Color.TRANSPARENT
		result.pressed_bg = Color.TRANSPARENT
		result.disabled_bg = Color.TRANSPARENT
		result.disabled_text = M3Theme.disabled_color(result.text)
		result.focus_border = result.text
	else:
		result.text = M3Theme.get_on_surface_variant()
		result.hover_bg = Color.TRANSPARENT
		result.pressed_bg = Color.TRANSPARENT
		result.disabled_bg = Color.TRANSPARENT
		result.disabled_text = M3Theme.disabled_color(result.text)
		result.focus_border = result.text
	
	_cached_variant_colors[cache_key] = result
	return result

func _invalidate_color_cache():
	_cached_variant_colors.clear()

func _update_icon_position():
	if not _icon_node or not _icon_node.visible:
		return
	
	var icon_size_px = M3Units.dp(24)
	
	if destination_layout == LayoutMode.VERTICAL:
		# Check if label is visible
		var has_label = _label_node and _label_node.visible
		if has_label:
			# Center content block (icon + 8dp gap + label) vertically
			var label_height = M3Units.dp(16)
			var content_height = icon_size_px + M3Units.dp(8) + label_height
			var top_offset = (size.y - content_height) / 2.0
			_icon_node.position = Vector2(
				size.x / 2.0 - icon_size_px / 2.0,
				top_offset
			)
		else:
			# Collapsed icon-only: icon centered both horizontally and vertically
			_icon_node.position = Vector2(
				size.x / 2.0 - icon_size_px / 2.0,
				size.y / 2.0 - icon_size_px / 2.0
			)
	else:
		# Expanded: icon at 36dp from left, vertically centered
		_icon_node.position = Vector2(
			M3Units.dp(36),
			size.y / 2.0 - icon_size_px / 2.0
		)

func _get_text_alignment() -> HorizontalAlignment:
	if destination_layout == LayoutMode.VERTICAL:
		return HORIZONTAL_ALIGNMENT_CENTER
	return HORIZONTAL_ALIGNMENT_LEFT

# ============================================
# DRAW
# ============================================

func _draw():
	_draw_pill()

func _has_visible_label() -> bool:
	return _label_node != null and _label_node.visible and not destination_label.is_empty()

func _get_pill_rect() -> Rect2:
	var has_label = _has_visible_label()
	
	if destination_layout == LayoutMode.VERTICAL:
		if has_label:
			# Collapsed with label: 32×56dp pill centered behind icon
			var pill_width = M3Units.dp(56)
			var pill_height = M3Units.dp(32)
			var icon_center_y = _icon_node.position.y + M3Units.dp(24) / 2.0
			return Rect2(
				Vector2((size.x - pill_width) / 2.0, icon_center_y - pill_height / 2.0),
				Vector2(pill_width, pill_height)
			)
		else:
			# Icon-only: 48×48dp circle centered behind icon
			var indicator_size = M3Units.dp(48)
			var icon_center = _icon_node.position + Vector2(M3Units.dp(24) / 2.0, M3Units.dp(24) / 2.0)
			return Rect2(
				Vector2(icon_center.x - indicator_size / 2.0, icon_center.y - indicator_size / 2.0),
				Vector2(indicator_size, indicator_size)
			)
	else:
		if has_label:
			# Expanded with label: 48dp height, variable width wrapping label
			var pill_height = M3Units.dp(48)
			var label_text_width = _label_node.get_minimum_size().x
			if label_text_width <= 0:
				label_text_width = _label_node.text.length() * M3Units.dp(8)
			var content_width = M3Units.dp(24) + M3Units.dp(12) + label_text_width
			var pill_width = content_width + M3Units.dp(24)  # 12dp padding each side
			var pill_start = M3Units.dp(24)  # Start 24dp from left
			return Rect2(
				Vector2(pill_start, (size.y - pill_height) / 2.0),
				Vector2(pill_width, pill_height)
			)
		else:
			# Expanded icon-only: 48×48dp circle centered vertically at icon position
			var indicator_size = M3Units.dp(48)
			var icon_center_y = size.y / 2.0
			var icon_center_x = _icon_node.position.x + M3Units.dp(24) / 2.0
			return Rect2(
				Vector2(icon_center_x - indicator_size / 2.0, icon_center_y - indicator_size / 2.0),
				Vector2(indicator_size, indicator_size)
			)

func _get_pill_radius() -> float:
	var has_label = _has_visible_label()
	if has_label:
		# Pill shape
		return M3Units.dp(16) if destination_layout == LayoutMode.VERTICAL else M3Units.dp(24)
	else:
		# Circular (48×48 with 24dp radius)
		return M3Units.dp(24)

func _draw_pill():
	var rect = _get_pill_rect()
	var radius = _get_pill_radius()
	var has_focus_state = has_focus()
	var colors = _get_variant_colors(active)
	var focus_color = colors.focus_border
	
	# Draw focus ring (2dp border around pill)
	if has_focus_state:
		var focus_rect = rect.grow(M3Units.dp(2))
		_draw_rounded_rect(focus_rect, focus_color, radius)
	
	# Draw active pill
	if active:
		_draw_rounded_rect(rect, M3Theme.get_secondary_container(), radius)
	# Draw hover pill (only if not active)
	elif _hovered or has_focus_state:
		var hover_color = M3Theme.get_surface_container().darkened(0.1)
		_draw_rounded_rect(rect, hover_color, radius)

func _draw_rounded_rect(rect: Rect2, color: Color, radius: float):
	if not _draw_sb:
		_draw_sb = StyleBoxFlat.new()
		_draw_sb.set_border_width_all(0)
		_draw_sb.content_margin_left = 0
		_draw_sb.content_margin_top = 0
		_draw_sb.content_margin_right = 0
		_draw_sb.content_margin_bottom = 0
		_draw_sb.anti_aliasing = true
		_draw_sb.anti_aliasing_size = 1.0
	
	_draw_sb.bg_color = color
	_draw_sb.set_corner_radius_all(int(radius))
	draw_style_box(_draw_sb, rect)

# ============================================
# LAYOUT
# ============================================

func _update_layout():
	if not _label_node:
		return
	
	_update_label_position()
	_update_button_width()
	queue_redraw()

func _update_button_width():
	if destination_layout == LayoutMode.VERTICAL:
		# Collapsed: fill rail width
		return
	
	# Expanded: shrink to fit content
	var icon_size_px = M3Units.dp(24)
	var label_text_width = _label_node.get_minimum_size().x
	if label_text_width <= 0:
		label_text_width = _label_node.text.length() * M3Units.dp(8)
	
	# Content = icon (36dp left padding + 24dp icon) + gap (12dp) + label + right padding (16dp)
	var content_width = M3Units.dp(36) + icon_size_px + M3Units.dp(12) + label_text_width + M3Units.dp(16)
	custom_minimum_size = Vector2(content_width, custom_minimum_size.y)
	
	# Trigger parent container relayout
	if get_parent() is Container:
		get_parent().queue_sort()

func _update_label():
	if not _label_node:
		return
	
	var show_label = false
	match label_visibility:
		M3Navigation.LabelVisibility.LABELED:
			show_label = true
		M3Navigation.LabelVisibility.SELECTED:
			show_label = active
		_:
			show_label = false
	
	if destination_label and show_label:
		_label_node.visible = true
		_label_node.text = destination_label
		_label_node.add_theme_font_size_override("font_size", M3Units.dp(12))
		_label_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if destination_layout == LayoutMode.HORIZONTAL else HORIZONTAL_ALIGNMENT_CENTER
	else:
		_label_node.visible = false
	_update_icon_position()
	_update_label_position()
	queue_redraw()

func _update_label_position():
	if not _label_node or not _label_node.visible:
		return
	
	var icon_size_px = M3Units.dp(24)
	
	# Update alignment based on current layout
	_label_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT if destination_layout == LayoutMode.HORIZONTAL else HORIZONTAL_ALIGNMENT_CENTER
	
	# Guard against zero width during initialization
	var node_width = max(size.x, 1.0)
	
	if destination_layout == LayoutMode.VERTICAL:
		# Label below icon with 8dp gap, centered
		_label_node.position = Vector2(0, _icon_node.position.y + icon_size_px + M3Units.dp(8))
		_label_node.size = Vector2(node_width, M3Units.dp(16))
	else:
		# Label to right of icon
		_label_node.position = Vector2(
			_icon_node.position.x + icon_size_px + M3Units.dp(12),
			0
		)
		var label_width = max(node_width - _label_node.position.x - M3Units.dp(16), 1.0)
		_label_node.size = Vector2(label_width, size.y)

# ============================================
# NOTIFICATIONS
# ============================================

func _notification(what: int):
	match what:
		NOTIFICATION_RESIZED:
			_update_icon_position()
			_update_label_position()
			queue_redraw()
		NOTIFICATION_MOUSE_ENTER:
			_hovered = true
			queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			_hovered = false
			queue_redraw()

# ============================================
# THEME
# ============================================

func refresh_theme():
	_invalidate_color_cache()
	super.refresh_theme()
	queue_redraw()
