class_name M3MenuRenderer
extends Control

const M3MenuItem = preload("res://addons/m3/components/M3MenuItem.gd")

static var _shared_empty_stylebox: StyleBoxEmpty = StyleBoxEmpty.new()

## Material 3 Menu Renderer
## Visual popup layer for M3Menu. Lazy-loaded when popup() is called.
## Handles rendering, input, keyboard navigation, and dismissal.

const M3Units = preload("res://addons/m3/M3Units.gd")

# ============================================
# SIZE SPECS (all values in dp)
# ============================================

const CONTAINER_RADIUS := 16.0
const CONTAINER_PADDING_V := 8.0
const CONTAINER_PADDING_H := 0.0
const ITEM_HEIGHT := 48.0
const ITEM_HEIGHT_TWO_LINE := 56.0
const ITEM_PADDING_H := 12.0
const ICON_SIZE := 24.0
const ICON_TEXT_GAP := 12.0
const SECTION_LABEL_PADDING_TOP := 16.0
const SECTION_LABEL_PADDING_BOTTOM := 8.0
const SEPARATOR_PADDING_H := 16.0
const SEPARATOR_HEIGHT := 1.0
const MIN_WIDTH := 112.0
const MAX_WIDTH := 280.0
const MAX_HEIGHT := 320.0

# ============================================
# ENUMS
# ============================================

enum ColorVariant { STANDARD, VIBRANT }
enum MenuAlignment { START, CENTER, END }

# ============================================
# SIGNALS
# ============================================

signal item_pressed(index: int)
signal submenu_requested(index: int)
signal focus_changed(index: int)
signal navigated_off_edge(direction: String)
signal dismissed

# ============================================
# INTERNAL
# ============================================

var _bg_panel: Panel
var _scroll: ScrollContainer
var _vbox: VBoxContainer
var _item_nodes: Array[Control] = []
var _menu_items: Array[M3MenuItem] = []
var _color_variant: ColorVariant = ColorVariant.STANDARD
var _anchor_control: Control = null
var _horizontal_alignment: MenuAlignment = MenuAlignment.START
var _min_width: float = 0.0
var _multi_select: bool = false
var _radio_group: bool = false
var _submenu_mode: bool = false
var _submenu_rect: Rect2 = Rect2()
var _suppress_submenu: bool = false
var _forced_focus_index: int = -1
var _focused_item_index: int = -1
var _font_icon_template: FontIconSettings = null
var _cached_fonts: Dictionary = {}

# ============================================
# LIFECYCLE
# ============================================

func _init():
	top_level = true
	z_index = 80
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false

func _ready():
	_create_visuals()
	_update_appearance()

func _ensure_visuals():
	if _scroll == null:
		_create_visuals()

func _create_visuals():
	if _bg_panel != null:
		return
	
	# Background panel with M3 shadow
	_bg_panel = Panel.new()
	_bg_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bg_panel)
	
	# Scroll container for overflow
	_scroll = ScrollContainer.new()
	_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	add_child(_scroll)
	
	# Vertical container for items
	_vbox = VBoxContainer.new()
	_vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	_vbox.add_theme_constant_override("separation", 0)
	_vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	_scroll.add_child(_vbox)

func _update_appearance():
	if not _bg_panel:
		return
	
	var bg: Color
	var shadow_color: Color
	
	match _color_variant:
		ColorVariant.VIBRANT:
			bg = M3Theme.get_tertiary_container()
			shadow_color = Color(0, 0, 0, 0.15)
		_:
			bg = M3Theme.get_surface_container_low()
			shadow_color = Color(0, 0, 0, 0.18)
	
	var sb = M3Theme.make_shadow(bg, M3Units.dpi(CONTAINER_RADIUS), 
		M3Theme.ELEVATION_2["size"], M3Theme.ELEVATION_2["offset"], shadow_color)
	_bg_panel.add_theme_stylebox_override("panel", sb)

# ============================================
# PUBLIC API
# ============================================

func popup(items: Array[M3MenuItem], anchor: Control, variant: ColorVariant = ColorVariant.STANDARD, alignment: MenuAlignment = MenuAlignment.START, auto_focus_first: bool = true, min_width: float = 0.0, multi_select: bool = false, radio_group: bool = false, submenu_mode: bool = false):
	_ensure_visuals()
	_cached_fonts = M3Theme.load_fonts()
	
	_menu_items = items.duplicate()
	_color_variant = variant
	_anchor_control = anchor
	_horizontal_alignment = alignment
	_min_width = min_width
	_multi_select = multi_select
	_radio_group = radio_group
	_submenu_mode = submenu_mode
	_cache_variant_colors()
	
	_clear_items()
	_build_items()
	_update_appearance()
	_calculate_size_and_position()
	
	visible = true
	
	# Reset scroll to top
	if _scroll:
		_scroll.scroll_vertical = 0
	
	# Focus the first Button (for keyboard navigation; disable for dropdowns)
	if auto_focus_first:
		for node in _item_nodes:
			if node is Button:
				node.grab_focus()
				break
	_update_item_visuals()

func dismiss():
	visible = false
	dismissed.emit()

func is_open() -> bool:
	return visible

# ============================================
# ITEM BUILDING
# ============================================

func _clear_items():
	for node in _item_nodes:
		node.queue_free()
	_item_nodes.clear()
	_focused_item_index = -1
	if _vbox == null:
		return
	for child in _vbox.get_children():
		child.queue_free()

func _build_items():
	if _cached_fonts.is_empty():
		_cached_fonts = M3Theme.load_fonts()
	var fonts = _cached_fonts
	
	for i in range(_menu_items.size()):
		var item = _menu_items[i]
		var node = _create_item_node(item, i, fonts)
		_vbox.add_child(node)
		_item_nodes.append(node)

func _create_item_node(item: M3MenuItem, index: int, fonts: Dictionary) -> Control:
	match item.item_type:
		M3MenuItem.Type.SEPARATOR:
			return _create_separator_node()
		M3MenuItem.Type.SECTION_LABEL:
			return _create_section_label_node(item, fonts)
		M3MenuItem.Type.TWO_LINE:
			return _create_two_line_node(item, index, fonts)
		_:
			return _create_normal_node(item, index, fonts)

func _get_font_icon_settings() -> FontIconSettings:
	if _font_icon_template == null:
		_font_icon_template = FontIconSettings.new()
		_font_icon_template.icon_size = M3Units.dp(ICON_SIZE)
		_font_icon_template.icon_font = "MaterialIcons"
	return _font_icon_template.duplicate()

func _create_separator_node() -> Control:
	var container = Control.new()
	var sep_height = M3Units.dp(SEPARATOR_HEIGHT)
	var pad_v = M3Units.dp(CONTAINER_PADDING_V)
	container.custom_minimum_size = Vector2(0, sep_height + pad_v * 2)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var line = ColorRect.new()
	line.color = M3Theme.get_outline_variant()
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.add_child(line)
	
	# Position line with horizontal padding, centered vertically
	var pad_h = M3Units.dp(SEPARATOR_PADDING_H)
	line.position = Vector2(pad_h, pad_v)
	line.size = Vector2(100, sep_height)  # Temporary width, updated on resize
	
	# Use resized signal to update line width
	container.resized.connect(_on_separator_resized.bind(container, line, pad_h, sep_height))
	
	return container

func _on_separator_resized(container: Control, line: ColorRect, pad_h: float, sep_height: float):
	line.size = Vector2(container.size.x - pad_h * 2, sep_height)

func _create_section_label_node(item: M3MenuItem, fonts: Dictionary) -> Control:
	var container = Control.new()
	var top_pad = M3Units.dp(SECTION_LABEL_PADDING_TOP)
	var bottom_pad = M3Units.dp(SECTION_LABEL_PADDING_BOTTOM)
	container.custom_minimum_size = Vector2(0, M3Units.dp(16) + top_pad + bottom_pad)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	var label = Label.new()
	label.text = item.text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", fonts["medium"])
	label.add_theme_font_size_override("font_size", M3Units.dp(12))
	label.add_theme_color_override("font_color", _get_secondary_text_color())
	label.position = Vector2(M3Units.dp(ITEM_PADDING_H), top_pad)
	container.add_child(label)
	
	container.resized.connect(_on_section_label_resized.bind(container, label))
	
	return container

func _on_section_label_resized(container: Control, label: Label):
	label.size = Vector2(container.size.x - M3Units.dp(ITEM_PADDING_H) * 2, M3Units.dp(16))

func _create_normal_node(item: M3MenuItem, index: int, fonts: Dictionary) -> Control:
	var height = M3Units.dp(ITEM_HEIGHT)
	var node = _create_interactable_node(item, index, height)
	
	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_PASS
	hbox.position = Vector2(M3Units.dp(ITEM_PADDING_H), 0)
	hbox.size = Vector2(node.size.x - M3Units.dp(ITEM_PADDING_H) * 2, height)
	node.add_child(hbox)
	
	# Icon or checkmark (always reserve space for alignment)
	var icon_node = FontIcon.new()
	icon_node.icon_settings = _get_font_icon_settings()
	icon_node.custom_minimum_size = Vector2(M3Units.dp(ICON_SIZE), M3Units.dp(ICON_SIZE))
	icon_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	if item.checkable and item.checked:
		icon_node.icon_settings.icon_name = "check"
		icon_node.icon_settings.icon_color = _get_primary_text_color()
	elif item.checkable and not item.checked:
		icon_node.icon_settings.icon_color = Color.TRANSPARENT
	elif not item.icon.is_empty():
		icon_node.icon_settings.icon_name = item.icon
		icon_node.icon_settings.icon_color = _get_icon_color()
	else:
		icon_node.icon_settings.icon_color = Color.TRANSPARENT
	
	hbox.add_child(icon_node)
	node.set_meta("m3_menu_icon", icon_node)
	
	# Gap between icon and text (always present for alignment)
	var gap = Control.new()
	gap.custom_minimum_size = Vector2(M3Units.dp(ICON_TEXT_GAP), 0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(gap)
	
	# Text label
	if not item.text.is_empty():
		var label = Label.new()
		label.text = item.text
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.add_theme_font_override("font", fonts["regular"])
		label.add_theme_font_size_override("font_size", M3Units.dp(14))
		label.add_theme_color_override("font_color", _get_primary_text_color() if not item.disabled else _get_disabled_text_color())
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(label)
		node.set_meta("m3_menu_label", label)
	
	# Shortcut text
	if not item.shortcut_text.is_empty():
		var shortcut = Label.new()
		shortcut.text = item.shortcut_text
		shortcut.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		shortcut.add_theme_font_override("font", fonts["regular"])
		shortcut.add_theme_font_size_override("font_size", M3Units.dp(14))
		shortcut.add_theme_color_override("font_color", _get_secondary_text_color())
		shortcut.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(shortcut)
		node.set_meta("m3_menu_shortcut", shortcut)
	
	# Trailing icon (right side) — auto "menu-right" for submenu items
	var show_trailing = not item.trailing_icon.is_empty() or item.submenu != null
	if show_trailing:
		var trailing_icon_node = FontIcon.new()
		trailing_icon_node.icon_settings = _get_font_icon_settings()
		trailing_icon_node.icon_settings.icon_name = item.trailing_icon if not item.trailing_icon.is_empty() else "menu-right"
		trailing_icon_node.icon_settings.icon_color = _get_secondary_text_color()
		trailing_icon_node.custom_minimum_size = Vector2(M3Units.dp(ICON_SIZE), M3Units.dp(ICON_SIZE))
		trailing_icon_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		trailing_icon_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		trailing_icon_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(trailing_icon_node)
		node.set_meta("m3_menu_trailing_icon", trailing_icon_node)
		node.set_meta("m3_menu_has_submenu", item.submenu != null)
	
	node.resized.connect(_on_node_resized.bind(node, hbox, height))
	
	return node

func _on_node_resized(node: Control, hbox: HBoxContainer, height: float):
	hbox.size = Vector2(node.size.x - M3Units.dp(ITEM_PADDING_H) * 2, height)

func _create_two_line_node(item: M3MenuItem, index: int, fonts: Dictionary) -> Control:
	var height = M3Units.dp(ITEM_HEIGHT_TWO_LINE)
	var node = _create_interactable_node(item, index, height)
	
	var hbox = HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_PASS
	hbox.position = Vector2(M3Units.dp(ITEM_PADDING_H), 0)
	hbox.size = Vector2(node.size.x - M3Units.dp(ITEM_PADDING_H) * 2, height)
	node.add_child(hbox)
	
	# Icon (always reserve space for alignment)
	var icon_node = FontIcon.new()
	icon_node.icon_settings = _get_font_icon_settings()
	if not item.icon.is_empty():
		icon_node.icon_settings.icon_name = item.icon
		icon_node.icon_settings.icon_color = _get_icon_color()
	else:
		icon_node.icon_settings.icon_color = Color.TRANSPARENT
	icon_node.custom_minimum_size = Vector2(M3Units.dp(ICON_SIZE), M3Units.dp(ICON_SIZE))
	icon_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	icon_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	icon_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(icon_node)
	node.set_meta("m3_menu_icon", icon_node)
	
	var gap = Control.new()
	gap.custom_minimum_size = Vector2(M3Units.dp(ICON_TEXT_GAP), 0)
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(gap)
	
	# Text column
	var text_vbox = VBoxContainer.new()
	text_vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	text_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(text_vbox)
	
	var primary = Label.new()
	primary.text = item.text
	primary.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	primary.add_theme_font_override("font", fonts["regular"])
	primary.add_theme_font_size_override("font_size", M3Units.dp(14))
	primary.add_theme_color_override("font_color", _get_primary_text_color() if not item.disabled else _get_disabled_text_color())
	primary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_vbox.add_child(primary)
	node.set_meta("m3_menu_label", primary)
	
	var secondary = Label.new()
	secondary.text = item.secondary_text
	secondary.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	secondary.add_theme_font_override("font", fonts["regular"])
	secondary.add_theme_font_size_override("font_size", M3Units.dp(12))
	secondary.add_theme_color_override("font_color", _get_secondary_text_color())
	secondary.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text_vbox.add_child(secondary)
	node.set_meta("m3_menu_secondary", secondary)
	
	# Shortcut
	if not item.shortcut_text.is_empty():
		var shortcut = Label.new()
		shortcut.text = item.shortcut_text
		shortcut.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		shortcut.add_theme_font_override("font", fonts["regular"])
		shortcut.add_theme_font_size_override("font_size", M3Units.dp(14))
		shortcut.add_theme_color_override("font_color", _get_secondary_text_color())
		shortcut.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(shortcut)
		node.set_meta("m3_menu_shortcut", shortcut)
	
	# Trailing icon (right side) — auto "menu-right" for submenu items
	var show_trailing_2l = not item.trailing_icon.is_empty() or item.submenu != null
	if show_trailing_2l:
		var trailing_icon_node = FontIcon.new()
		trailing_icon_node.icon_settings = _get_font_icon_settings()
		trailing_icon_node.icon_settings.icon_name = item.trailing_icon if not item.trailing_icon.is_empty() else "menu-right"
		trailing_icon_node.icon_settings.icon_color = _get_secondary_text_color()
		trailing_icon_node.custom_minimum_size = Vector2(M3Units.dp(ICON_SIZE), M3Units.dp(ICON_SIZE))
		trailing_icon_node.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		trailing_icon_node.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		trailing_icon_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(trailing_icon_node)
		node.set_meta("m3_menu_trailing_icon", trailing_icon_node)
		node.set_meta("m3_menu_has_submenu", item.submenu != null)
	
	node.resized.connect(_on_node_resized.bind(node, hbox, height))
	
	return node

func _create_interactable_node(item: M3MenuItem, index: int, height: float) -> Button:
	var node = M3MenuButton.new()
	node.custom_minimum_size = Vector2(0, height)
	node.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	node.mouse_filter = Control.MOUSE_FILTER_PASS if not item.disabled else Control.MOUSE_FILTER_IGNORE
	node.set_meta("item_index", index)
	node.set_meta("disabled", item.disabled)
	
	# Suppress native Button visuals; we draw our own overlay
	node.flat = true
	node.add_theme_stylebox_override("normal", _shared_empty_stylebox)
	node.add_theme_stylebox_override("pressed", _shared_empty_stylebox)
	node.add_theme_stylebox_override("hover", _shared_empty_stylebox)
	node.add_theme_stylebox_override("disabled", _shared_empty_stylebox)
	node.add_theme_stylebox_override("focus", _shared_empty_stylebox)
	
	# Hover/selected overlay - Panel with rounded StyleBoxFlat, inset 4dp from edges
	var overlay = Panel.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.offset_left = M3Units.dp(4)
	overlay.offset_top = M3Units.dp(4)
	overlay.offset_right = -M3Units.dp(4)
	overlay.offset_bottom = -M3Units.dp(4)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.visible = false
	
	var sb = StyleBoxFlat.new()
	sb.set_corner_radius_all(M3Units.dpi(12))
	sb.anti_aliasing = true
	sb.anti_aliasing_size = 1.0
	sb.set_border_width_all(0)
	overlay.add_theme_stylebox_override("panel", sb)
	
	node.add_child(overlay)
	# Store direct references to avoid child iteration
	node.set_meta("m3_menu_overlay", overlay)
	node.set_meta("m3_menu_overlay_sb", sb)
	
	# Store the menu item index so we can map back to _menu_items
	node.set_meta("menu_item_index", index)
	
	# Connect Button signals
	if not item.disabled:
		node.pressed.connect(_activate_item.bind(index))
		node.focus_entered.connect(_on_item_focus_entered.bind(index))
		node.focus_exited.connect(_on_item_focus_exited.bind(index))
		node.mouse_entered.connect(_on_item_mouse_entered.bind(index))
	
	return node

# ============================================
# COLORS
# ============================================

var _variant_colors: Dictionary = {}

func _cache_variant_colors():
	if _color_variant == ColorVariant.VIBRANT:
		_variant_colors = {
			"primary_text": M3Theme.get_on_tertiary_container(),
			"secondary_text": M3Theme.get_on_tertiary_container(),
			"icon": M3Theme.get_on_tertiary_container(),
			"selected_text": M3Theme.get_on_tertiary(),
			"selected_bg": M3Theme.get_tertiary(),
			"hover_bg": M3Theme.state_overlay(M3Theme.get_tertiary_container(), M3Theme.get_on_tertiary_container(), M3Theme.OPACITY_HOVER),
		}
	else:
		_variant_colors = {
			"primary_text": M3Theme.get_on_surface(),
			"secondary_text": M3Theme.get_on_surface_variant(),
			"icon": M3Theme.get_on_surface_variant(),
			"selected_text": M3Theme.get_on_secondary_container(),
			"selected_bg": M3Theme.get_secondary_container(),
			"hover_bg": M3Theme.state_overlay(M3Theme.get_surface_container_low(), M3Theme.get_on_surface(), M3Theme.OPACITY_HOVER),
		}

func _get_primary_text_color() -> Color:
	return _variant_colors.get("primary_text", M3Theme.get_on_surface())

func _get_secondary_text_color() -> Color:
	return _variant_colors.get("secondary_text", M3Theme.get_on_surface_variant())

func _get_icon_color() -> Color:
	return _variant_colors.get("icon", M3Theme.get_on_surface_variant())

func _get_disabled_text_color() -> Color:
	return M3Theme.disabled_color(_get_primary_text_color())

func _get_selected_text_color() -> Color:
	return _variant_colors.get("selected_text", M3Theme.get_on_secondary_container())

func _get_selected_bg_color() -> Color:
	return _variant_colors.get("selected_bg", M3Theme.get_secondary_container())

func _get_hover_bg_color() -> Color:
	return _variant_colors.get("hover_bg", M3Theme.state_overlay(M3Theme.get_surface_container_low(), M3Theme.get_on_surface(), M3Theme.OPACITY_HOVER))

# ============================================
# SIZING & POSITIONING
# ============================================

func _calculate_size_and_position():
	var pad_h = M3Units.dp(CONTAINER_PADDING_H)
	var pad_v = M3Units.dp(CONTAINER_PADDING_V)
	var margin = M3Units.dp(8)
	var gap = M3Units.dp(8)
	
	# Calculate required width
	var max_content_width = 0.0
	var fonts = _cached_fonts
	
	for item in _menu_items:
		var item_width = M3Units.dp(ITEM_PADDING_H) * 2
		
		if item.item_type == M3MenuItem.Type.SEPARATOR:
			continue
		elif item.item_type == M3MenuItem.Type.SECTION_LABEL:
			item_width += _measure_text(item.text, fonts["medium"], M3Units.dp(12))
		else:
			# Icon/checkmark width (always reserved for alignment)
			item_width += M3Units.dp(ICON_SIZE) + M3Units.dp(ICON_TEXT_GAP)
			
			# Text width
			if not item.text.is_empty():
				item_width += _measure_text(item.text, fonts["regular"], M3Units.dp(14))
			
			# Shortcut width
			if not item.shortcut_text.is_empty():
				item_width += M3Units.dp(16) + _measure_text(item.shortcut_text, fonts["regular"], M3Units.dp(14))
			
			# Trailing icon width
			if not item.trailing_icon.is_empty():
				item_width += M3Units.dp(ICON_SIZE) + M3Units.dp(12)
		
		max_content_width = max(max_content_width, item_width)
	
	# Right margin equals half the width of the longest item
	var width = clamp(max_content_width * 1.5, M3Units.dp(MIN_WIDTH), M3Units.dp(MAX_WIDTH))
	# For dropdowns: ensure menu is at least as wide as the anchor control
	width = max(width, _min_width)
	
	# Calculate total content height
	var total_height = pad_v * 2
	for item in _menu_items:
		match item.item_type:
			M3MenuItem.Type.SEPARATOR:
				total_height += M3Units.dp(SEPARATOR_HEIGHT) + pad_v * 2
			M3MenuItem.Type.SECTION_LABEL:
				total_height += M3Units.dp(16) + M3Units.dp(SECTION_LABEL_PADDING_TOP) + M3Units.dp(SECTION_LABEL_PADDING_BOTTOM)
			M3MenuItem.Type.TWO_LINE:
				total_height += M3Units.dp(ITEM_HEIGHT_TWO_LINE)
			_:
				total_height += M3Units.dp(ITEM_HEIGHT)
	
	# Clamp visible height to MAX_HEIGHT
	var visible_height = min(total_height, M3Units.dp(MAX_HEIGHT))
	
	# Get viewport and anchor
	var viewport = get_viewport()
	var viewport_size = Vector2(1920, 1080)
	if viewport:
		viewport_size = viewport.get_visible_rect().size
	var anchor_rect = _anchor_control.get_global_rect() if _anchor_control else Rect2(Vector2.ZERO, Vector2.ZERO)
	
	# Try positions with visible height
	var positions = _compute_positions(anchor_rect, width, visible_height, gap)
	
	var pos: Vector2 = positions[0]  # Default to first (below-start)
	for try_pos in positions:
		if _position_fits(try_pos, width, visible_height, viewport_size, margin, anchor_rect):
			pos = try_pos
			break
	
	global_position = pos
	size = Vector2(width, visible_height)
	
	# Update background panel
	_bg_panel.position = Vector2.ZERO
	_bg_panel.size = size
	
	# Update scroll container (visible area)
	_scroll.position = Vector2(pad_h, pad_v)
	_scroll.size = Vector2(width - pad_h * 2, visible_height - pad_v * 2)
	
	# Update vbox (total content size for scrolling)
	_vbox.custom_minimum_size = Vector2(width - pad_h * 2, total_height - pad_v * 2)

func _compute_positions(anchor_rect: Rect2, menu_w: float, menu_h: float, gap: float) -> Array[Vector2]:
	var positions: Array[Vector2] = []
	
	# Horizontal alignment offsets
	var align_offset: float
	match _horizontal_alignment:
		MenuAlignment.CENTER:
			align_offset = (anchor_rect.size.x - menu_w) / 2.0
		MenuAlignment.END:
			align_offset = anchor_rect.size.x - menu_w
		_:
			align_offset = 0.0
	
	if _submenu_mode:
		# Submenus cascade to the right of the parent item (Material Design spec)
		# Right of anchor (preferred)
		positions.append(Vector2(anchor_rect.position.x + anchor_rect.size.x + gap, anchor_rect.position.y))
		
		# Left of anchor (RTL fallback)
		positions.append(Vector2(anchor_rect.position.x - menu_w - gap, anchor_rect.position.y))
		
		# Below (fallback if horizontal doesn't fit)
		positions.append(Vector2(anchor_rect.position.x + align_offset, anchor_rect.position.y + anchor_rect.size.y + gap))
		
		# Above
		positions.append(Vector2(anchor_rect.position.x + align_offset, anchor_rect.position.y - menu_h - gap))
	else:
		# Standard dropdown: below (preferred)
		positions.append(Vector2(anchor_rect.position.x + align_offset, anchor_rect.position.y + anchor_rect.size.y + gap))
		
		# Above
		positions.append(Vector2(anchor_rect.position.x + align_offset, anchor_rect.position.y - menu_h - gap))
		
		# Right of anchor
		positions.append(Vector2(anchor_rect.position.x + anchor_rect.size.x + gap, anchor_rect.position.y))
		
		# Left of anchor
		positions.append(Vector2(anchor_rect.position.x - menu_w - gap, anchor_rect.position.y))
		
		# Below, but shifted to avoid viewport clipping on right
		positions.append(Vector2(anchor_rect.position.x + anchor_rect.size.x - menu_w, anchor_rect.position.y + anchor_rect.size.y + gap))
		
		# Above, but shifted to avoid viewport clipping on right
		positions.append(Vector2(anchor_rect.position.x + anchor_rect.size.x - menu_w, anchor_rect.position.y - menu_h - gap))
	
	return positions

func _position_fits(pos: Vector2, width: float, height: float, viewport_size: Vector2, margin: float, anchor_rect: Rect2) -> bool:
	# Must fit within viewport margins
	if pos.x < margin or pos.x + width > viewport_size.x - margin:
		return false
	if pos.y < margin or pos.y + height > viewport_size.y - margin:
		return false
	
	# Must not overlap anchor (if possible)
	var menu_rect = Rect2(pos, Vector2(width, height))
	if menu_rect.intersects(anchor_rect):
		return false
	
	return true

func _measure_text(text: String, font: Font, font_size: int) -> float:
	if text.is_empty():
		return 0.0
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

# ============================================
# INPUT
# ============================================

func _input(event: InputEvent):
	if not visible:
		return
	
	# Outside-click dismissal only; ui_cancel is handled by M3Overlay base class
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not get_global_rect().has_point(event.global_position):
			# Don't dismiss if the click is inside an open submenu
			if not _submenu_rect.has_point(event.global_position):
				dismiss()
		return
	
	# Right arrow opens submenu for the focused item
	if event.is_action_pressed("ui_right"):
		var focused_idx = _focused_item_index
		if focused_idx >= 0 and focused_idx < _menu_items.size() and _menu_items[focused_idx].submenu != null:
			submenu_requested.emit(focused_idx)
			get_viewport().set_input_as_handled()
			return
	
	# Edge navigation: up/down close at vertical edges; left/right always close
	# (vertical menus have no horizontal focus movement, so left/right are universal close)
	var focused_idx = _focused_item_index
	if focused_idx < 0:
		return
	var first_idx = _get_first_focusable_index()
	var last_idx = _get_last_focusable_index()
	
	if event.is_action_pressed("ui_up") and focused_idx == first_idx:
		navigated_off_edge.emit("up")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_down") and focused_idx == last_idx:
		navigated_off_edge.emit("down")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_left"):
		navigated_off_edge.emit("left")
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_right"):
		navigated_off_edge.emit("right")
		get_viewport().set_input_as_handled()

func _get_focused_item_index() -> int:
	var focused = get_viewport().gui_get_focus_owner()
	if focused == null:
		return -1
	for i in range(_item_nodes.size()):
		if _item_nodes[i] == focused:
			return i
	return -1

func _get_first_focusable_index() -> int:
	for i in range(_item_nodes.size()):
		if _item_nodes[i] is Button and i < _menu_items.size() and not _menu_items[i].disabled:
			return i
	return -1

func _get_last_focusable_index() -> int:
	for i in range(_item_nodes.size() - 1, -1, -1):
		if _item_nodes[i] is Button and i < _menu_items.size() and not _menu_items[i].disabled:
			return i
	return -1

func _on_item_mouse_entered(index: int):
	# Mouse hover grabs focus so there's only ever one focused item
	if index >= 0 and index < _item_nodes.size():
		var node = _item_nodes[index]
		if not node.has_focus():
			node.grab_focus()
		elif not _suppress_submenu and index >= 0 and index < _menu_items.size():
			# Already focused but mouse re-entered — re-request submenu if applicable
			var item = _menu_items[index]
			if item.submenu != null:
				submenu_requested.emit(index)

func _on_item_focus_exited(index: int):
	if _focused_item_index == index:
		_focused_item_index = -1
	# Visual unfocus: revert to forced-focus state only
	_update_item_visual(index, index == _forced_focus_index)

func _on_item_focus_entered(index: int):
	_update_item_visual(index, true)
	_focused_item_index = index
	
	focus_changed.emit(index)
	if not _suppress_submenu and index >= 0 and index < _menu_items.size():
		var item = _menu_items[index]
		if item.submenu != null:
			submenu_requested.emit(index)

func _activate_focused():
	var focused = get_viewport().gui_get_focus_owner()
	if focused == null:
		return
	for i in range(_item_nodes.size()):
		if _item_nodes[i] == focused:
			_activate_item(i)
			return

func _activate_item(index: int):
	if index < 0 or index >= _menu_items.size():
		return
	
	var item = _menu_items[index]
	if item.disabled:
		return
	
	# If this item has a submenu, open it instead of activating
	if item.submenu != null:
		submenu_requested.emit(index)
		return
	
	# Toggle checkable items
	if item.checkable:
		if _radio_group:
			# Radio behavior: uncheck all others, check this one
			for i in range(_menu_items.size()):
				if i != index and _menu_items[i].checkable and _menu_items[i].checked:
					_menu_items[i].checked = false
					_update_item_checkmark(i)
			item.checked = true
		else:
			item.checked = not item.checked
		_update_item_checkmark(index)
	
	if item.callback.is_valid():
		item.callback.call()
	
	item_pressed.emit(index)
	
	# In multi-select mode, checkable items toggle without dismissing
	if _multi_select and item.checkable:
		return
	
	dismiss()

# ============================================
# VISUAL UPDATES
# ============================================

func _update_item_visual(index: int, is_focused: bool):
	if index < 0 or index >= _item_nodes.size():
		return
	
	var node = _item_nodes[index]
	var item = _menu_items[index] if index < _menu_items.size() else null
	
	# Direct reference from metadata (avoid child iteration)
	if node.has_meta("m3_menu_overlay"):
		var overlay = node.get_meta("m3_menu_overlay") as Panel
		var sb = node.get_meta("m3_menu_overlay_sb") as StyleBoxFlat
		if is_focused:
			if sb:
				sb.bg_color = _get_selected_bg_color()
			overlay.visible = true
		else:
			overlay.visible = false
	
	# Update text/icon colors for selected vs unselected state
	if is_focused:
		# Selected: use contrasting color on colored background
		if node.has_meta("m3_menu_label"):
			var label = node.get_meta("m3_menu_label") as Label
			if label:
				label.add_theme_color_override("font_color", _get_selected_text_color())
		if node.has_meta("m3_menu_secondary"):
			var secondary = node.get_meta("m3_menu_secondary") as Label
			if secondary:
				secondary.add_theme_color_override("font_color", _get_selected_text_color())
		if node.has_meta("m3_menu_shortcut"):
			var shortcut = node.get_meta("m3_menu_shortcut") as Label
			if shortcut:
				shortcut.add_theme_color_override("font_color", _get_selected_text_color())
		if node.has_meta("m3_menu_icon"):
			var icon_node = node.get_meta("m3_menu_icon") as FontIcon
			if icon_node and icon_node.icon_settings:
				icon_node.icon_settings.icon_color = _get_selected_text_color()
		if node.has_meta("m3_menu_trailing_icon"):
			var trailing = node.get_meta("m3_menu_trailing_icon") as FontIcon
			if trailing and trailing.icon_settings:
				trailing.icon_settings.icon_color = _get_selected_text_color()
	else:
		# Unselected: restore original colors
		var disabled = item.disabled if item else false
		if node.has_meta("m3_menu_label"):
			var label = node.get_meta("m3_menu_label") as Label
			if label:
				label.add_theme_color_override("font_color", _get_primary_text_color() if not disabled else _get_disabled_text_color())
		if node.has_meta("m3_menu_secondary"):
			var secondary = node.get_meta("m3_menu_secondary") as Label
			if secondary:
				secondary.add_theme_color_override("font_color", _get_secondary_text_color())
		if node.has_meta("m3_menu_shortcut"):
			var shortcut = node.get_meta("m3_menu_shortcut") as Label
			if shortcut:
				shortcut.add_theme_color_override("font_color", _get_secondary_text_color())
		if node.has_meta("m3_menu_icon"):
			var icon_node = node.get_meta("m3_menu_icon") as FontIcon
			if icon_node and icon_node.icon_settings:
				if item and item.checkable and item.checked:
					icon_node.icon_settings.icon_color = _get_primary_text_color()
				elif item and item.checkable and not item.checked:
					icon_node.icon_settings.icon_color = Color.TRANSPARENT
				elif item and not item.icon.is_empty():
					icon_node.icon_settings.icon_color = _get_icon_color()
				else:
					icon_node.icon_settings.icon_color = Color.TRANSPARENT
		if node.has_meta("m3_menu_trailing_icon"):
			var trailing = node.get_meta("m3_menu_trailing_icon") as FontIcon
			if trailing and trailing.icon_settings:
				trailing.icon_settings.icon_color = _get_secondary_text_color()

func _update_item_visuals():
	for i in range(_item_nodes.size()):
		var node = _item_nodes[i]
		var is_focused = node.has_focus() or i == _forced_focus_index
		_update_item_visual(i, is_focused)

func _update_item_checkmark(index: int):
	if index < 0 or index >= _item_nodes.size():
		return
	
	var node = _item_nodes[index]
	var item = _menu_items[index]
	var is_focused = node.has_focus()
	
	# Direct reference from metadata (avoid deep child iteration)
	if node.has_meta("m3_menu_icon"):
		var icon_node = node.get_meta("m3_menu_icon") as FontIcon
		if icon_node and icon_node.icon_settings and item.checkable:
			if item.checked:
				icon_node.icon_settings.icon_name = "check"
				icon_node.icon_settings.icon_color = _get_selected_text_color() if is_focused else _get_primary_text_color()
			else:
				icon_node.icon_settings.icon_name = ""
				icon_node.icon_settings.icon_color = Color.TRANSPARENT

func set_submenu_rect(rect: Rect2):
	_submenu_rect = rect

func set_submenu_open(index: int, open: bool):
	if index < 0 or index >= _item_nodes.size():
		return
	var node = _item_nodes[index]
	if not node.has_meta("m3_menu_trailing_icon"):
		return
	var trailing = node.get_meta("m3_menu_trailing_icon") as FontIcon
	if trailing and trailing.icon_settings:
		trailing.icon_settings.icon_name = "menu-left" if open else "menu-right"
		var is_focused = node.has_focus()
		trailing.icon_settings.icon_color = _get_selected_text_color() if is_focused else _get_secondary_text_color()

func grab_item_focus(index: int):
	if index >= 0 and index < _item_nodes.size():
		var node = _item_nodes[index]
		if not node.has_focus():
			node.grab_focus()

func set_forced_focus_index(index: int):
	var old_forced = _forced_focus_index
	_forced_focus_index = index
	
	# Update old forced item to its actual focus state
	if old_forced >= 0 and old_forced != index and old_forced < _item_nodes.size():
		var node = _item_nodes[old_forced]
		_update_item_visual(old_forced, node.has_focus())
	
	# Update new forced item
	if index >= 0 and index != old_forced and index < _item_nodes.size():
		_update_item_visual(index, true)

func refresh_theme():
	_cache_variant_colors()
	_update_appearance()
	_update_item_visuals()
	for i in range(_menu_items.size()):
		if _menu_items[i].checkable:
			_update_item_checkmark(i)
