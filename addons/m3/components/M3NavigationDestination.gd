@tool
class_name M3NavigationDestination
extends M3Button

static var _shared_empty_stylebox: StyleBoxEmpty = StyleBoxEmpty.new()

static func clear_shared_stylebox() -> void:
	_shared_empty_stylebox = null

signal context_menu_requested()

## Material 3 Navigation Destination
## Extends M3Button with navigation-specific layout.
## Draws pill-shaped active and hover indicators via _draw().

enum LayoutMode { VERTICAL, HORIZONTAL }
enum CompactLevel { NONE, ICON_ONLY, SMALL, EXTRA_SMALL, BEST_FIT }

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

# Icon sizes for each compact level (dp)
const COMPACT_ICON_SIZES = {
	CompactLevel.NONE: 24,
	CompactLevel.ICON_ONLY: 24,
	CompactLevel.SMALL: 20,
	CompactLevel.EXTRA_SMALL: 18,
	CompactLevel.BEST_FIT: 16,
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

@export var destination_icon_texture: Texture2D = null:
	set(value):
		if value == destination_icon_texture:
			return
		destination_icon_texture = value
		_update_icon()
		queue_redraw()

@export var compact_level: CompactLevel = CompactLevel.NONE:
	set(value):
		if value == compact_level:
			return
		compact_level = value
		_update_icon()
		_update_label()
		_update_size()
		_update_theme()
		_update_icon_position()
		queue_redraw()

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
var _icon_texture_node: TextureRect
var _hovered: bool = false
var _long_press_timer: Timer = null
var _long_press_active: bool = false
var _draw_sb: StyleBoxFlat
var _cached_variant_colors: Dictionary = {}

## If true, pressing the ui_select action while focused will emit
## context_menu_requested. The navigation manager enables this only for
## pinned shortcuts so controller users can open the remove-shortcut menu.
var context_menu_enabled: bool = false

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	button_type = Type.TOGGLE
	button_variant = Variant.TEXT
	button_shape = Shape.ROUNDED
	flat = true
	auto_size_vertical = false  # Nav bar controls our vertical sizing
	
	super._ready()
	
	# Create texture icon overlay for custom shortcut/app icons
	_icon_texture_node = TextureRect.new()
	_icon_texture_node.name = "IconTexture"
	_icon_texture_node.visible = false
	_icon_texture_node.expand_mode = TextureRect.EXPAND_FIT_WIDTH
	_icon_texture_node.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	add_child(_icon_texture_node)
	
	# Create label (M3Button doesn't have one)
	_label_node = Label.new()
	_label_node.name = "Label"
	_label_node.visible = false
	_label_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_label_node)
	
	_update_icon()
	_update_label()
	_update_layout()
	
	# Track hover state via notifications (more reliable than signals)
	focus_entered.connect(queue_redraw)
	focus_exited.connect(queue_redraw)
	
	# Long-press timer for pinned shortcut removal menus
	_long_press_timer = Timer.new()
	_long_press_timer.name = "LongPressTimer"
	_long_press_timer.wait_time = 0.6
	_long_press_timer.one_shot = true
	_long_press_timer.timeout.connect(_on_long_press_timeout)
	add_child(_long_press_timer)
	
	# Clear native focus stylebox so focus ring is drawn only around the pill
	add_theme_stylebox_override("focus", _shared_empty_stylebox)

# ============================================
# OVERRIDES
# ============================================

func _get_size_spec() -> Dictionary:
	var base = NAV_SIZE_SPECS[destination_layout]
	return {
		"height": base["height"],
		"icon_size": COMPACT_ICON_SIZES[compact_level],
		"radius": base["radius"],
		"font_size": base["font_size"],
		"padding_h": base["padding_h"],
		"icon_gap": base["icon_gap"],
	}

func _update_theme():
	super._update_theme()
	# Clear native focus stylebox after parent sets it
	# so focus ring is drawn only around the pill in _draw()
	add_theme_stylebox_override("focus", _shared_empty_stylebox)
	_update_label_color()

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

func _get_icon_size_px() -> float:
	return M3Units.dp(_get_size_spec()["icon_size"])

func _update_icon_position():
	if not _icon_node:
		return
	
	var icon_size_px = _get_icon_size_px()
	
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
	
	if _icon_texture_node:
		_icon_texture_node.position = _icon_node.position
		_icon_texture_node.size = Vector2(icon_size_px, icon_size_px)
		_icon_texture_node.custom_minimum_size = Vector2(icon_size_px, icon_size_px)

func _update_icon():
	if not _icon_node or not _icon_texture_node:
		return
	
	var had_icon = _icon_node.visible or _icon_texture_node.visible
	
	if destination_icon_texture:
		# Keep icon node visible for layout/content-margin calculations, but blank
		_icon_node.icon_settings.icon_name = ""
		_icon_node.visible = true
		_icon_texture_node.texture = destination_icon_texture
		_icon_texture_node.visible = true
	else:
		_icon_texture_node.visible = false
		_icon_texture_node.texture = null
		if destination_icon:
			_icon_node.icon_settings.icon_name = destination_icon
			_icon_node.visible = true
		else:
			_icon_node.icon_settings.icon_name = ""
			_icon_node.visible = false
	
	var has_icon = _icon_node.visible or _icon_texture_node.visible
	if had_icon != has_icon:
		_update_theme()

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
	var icon_size_px = _get_icon_size_px()
	
	if destination_layout == LayoutMode.VERTICAL:
		if has_label:
			# Collapsed with label: 32×56dp pill centered behind icon
			var pill_width = M3Units.dp(56)
			var pill_height = M3Units.dp(32)
			var icon_center_y = _icon_node.position.y + icon_size_px / 2.0
			return Rect2(
				Vector2((size.x - pill_width) / 2.0, icon_center_y - pill_height / 2.0),
				Vector2(pill_width, pill_height)
			)
		else:
			# Icon-only: circle sized to fit the (possibly compact) icon
			var indicator_size = maxf(M3Units.dp(32), icon_size_px + M3Units.dp(16))
			var icon_center = _icon_node.position + Vector2(icon_size_px / 2.0, icon_size_px / 2.0)
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
			var content_width = icon_size_px + M3Units.dp(12) + label_text_width
			var pill_width = content_width + M3Units.dp(24)  # 12dp padding each side
			var pill_start = M3Units.dp(24)  # Start 24dp from left
			return Rect2(
				Vector2(pill_start, (size.y - pill_height) / 2.0),
				Vector2(pill_width, pill_height)
			)
		else:
			# Expanded icon-only: circle sized to fit the (possibly compact) icon
			var indicator_size = maxf(M3Units.dp(32), icon_size_px + M3Units.dp(16))
			var icon_center_y = size.y / 2.0
			var icon_center_x = _icon_node.position.x + icon_size_px / 2.0
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
		# Circular (radius half of the scaled indicator)
		var indicator_size = maxf(M3Units.dp(32), _get_icon_size_px() + M3Units.dp(16))
		return indicator_size / 2.0

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

func _update_label_color():
	if not _label_node:
		return
	var colors = _get_variant_colors(active)
	var text_color = colors.disabled_text if disabled else colors.text
	_label_node.add_theme_color_override("font_color", text_color)

func _update_label():
	if not _label_node:
		return
	
	var show_label = false
	if compact_level == CompactLevel.NONE:
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
	_update_label_color()
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

func _gui_input(event: InputEvent) -> void:
	# Controller/keyboard context menu (mirrors game card behavior).
	if context_menu_enabled and event.is_action_pressed("ui_select"):
		accept_event()
		context_menu_requested.emit()
		return

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			accept_event()
			context_menu_requested.emit()
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_long_press_active = false
				_long_press_timer.start()
			else:
				_long_press_timer.stop()
				if _long_press_active:
					_long_press_active = false
					accept_event()
					return
				_long_press_active = false
		# Let M3Button handle left clicks / SubViewport workaround
		super._gui_input(event)

func _on_long_press_timeout() -> void:
	_long_press_active = true
	context_menu_requested.emit()

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
