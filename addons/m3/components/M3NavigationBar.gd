@tool
class_name M3NavigationBar
extends M3Navigation

## Material 3 Bottom Navigation Bar
## Horizontal navigation component for top-level destinations.
## Supports compact (icon+label vertical, 80dp) and expanded (icon+label horizontal, 64dp) modes.

# ============================================
# SIZE SPECS (all values in dp)
# ============================================

const HEIGHT_COMPACT := 80
const HEIGHT_EXPANDED := 64
const MIN_ITEM_WIDTH := 80
const MAX_ITEM_WIDTH := 168
const MENU_BUTTON_WIDTH := 80  # 16 + 48 + 16

# ============================================
# EXPORTS
# ============================================

signal height_changed(height: float)

# ============================================
# INTERNAL
# ============================================

var _content_container: HBoxContainer
var _items_container: HBoxContainer
var _menu_wrapper: MarginContainer
var _menu_button: M3IconButton
var _footer_wrapper: MarginContainer

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	_create_layout()
	super._ready()

func _create_layout():
	# Set initial height
	custom_minimum_size = Vector2(0, M3Units.dp(HEIGHT_COMPACT))
	
	# Create horizontal content container
	_content_container = HBoxContainer.new()
	_content_container.name = "ContentContainer"
	_content_container.alignment = BoxContainer.ALIGNMENT_CENTER
	_content_container.add_theme_constant_override("separation", 0)
	add_child(_content_container)
	
	# Menu button wrapper with left padding
	_menu_wrapper = MarginContainer.new()
	_menu_wrapper.name = "MenuWrapper"
	_menu_wrapper.custom_minimum_size = Vector2(M3Units.dp(MENU_BUTTON_WIDTH), 0)
	_menu_wrapper.size_flags_vertical = Control.SIZE_FILL
	_menu_wrapper.add_theme_constant_override("margin_left", M3Units.dp(12))
	_content_container.add_child(_menu_wrapper)
	
	_menu_button = M3IconButton.new()
	_menu_button.name = "MenuButton"
	_menu_button.icon_name = "menu"
	_menu_button.icon_button_variant = M3IconButton.IconVariant.STANDARD
	_menu_button.icon_button_size = M3IconButton.IconSize.MEDIUM
	_menu_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_menu_button.pressed.connect(_on_menu_button_pressed)
	_menu_wrapper.add_child(_menu_button)
	
	# Items container
	_items_container = HBoxContainer.new()
	_items_container.name = "ItemsContainer"
	_items_container.alignment = BoxContainer.ALIGNMENT_CENTER
	_items_container.add_theme_constant_override("separation", 0)
	_items_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_container.add_child(_items_container)
	
	# Footer wrapper (for footer_content slot)
	_footer_wrapper = MarginContainer.new()
	_footer_wrapper.name = "FooterWrapper"
	_footer_wrapper.custom_minimum_size = Vector2(M3Units.dp(MENU_BUTTON_WIDTH), 0)
	_footer_wrapper.size_flags_vertical = Control.SIZE_FILL
	_footer_wrapper.visible = false
	_content_container.add_child(_footer_wrapper)
	
	_update_dimensions()

# ============================================
# DIMENSIONS & CONTENT POSITIONING (override)
# ============================================

func _update_dimensions():
	if not _content_container:
		return
	
	var height_px = M3Units.dp(HEIGHT_EXPANDED) if expanded else M3Units.dp(HEIGHT_COMPACT)
	custom_minimum_size.y = height_px
	offset_top = -height_px
	height_changed.emit(height_px)
	
	# Center menu button vertically within wrapper
	if _menu_wrapper:
		var btn_size = M3Units.dp(48)
		var vertical_margin = (height_px - btn_size) / 2.0
		_menu_wrapper.add_theme_constant_override("margin_top", vertical_margin)
		_menu_wrapper.add_theme_constant_override("margin_bottom", vertical_margin)
	
	# Center footer content vertically within wrapper
	if _footer_wrapper:
		var btn_size = M3Units.dp(48)
		var vertical_margin = (height_px - btn_size) / 2.0
		_footer_wrapper.add_theme_constant_override("margin_top", vertical_margin)
		_footer_wrapper.add_theme_constant_override("margin_bottom", vertical_margin)

func _update_menu_button_state():
	"""Update menu button visibility and position in the bar."""
	if not _menu_wrapper or not _content_container:
		return
	
	# Visibility
	_menu_wrapper.visible = show_menu_button
	
	# Position: START (left) or END (right)
	var menu_index := 0 if menu_button_position == MenuPosition.START else 1
	if _content_container.get_child_count() > menu_index:
		if _content_container.get_child(menu_index) != _menu_wrapper:
			_content_container.move_child(_menu_wrapper, menu_index)
	
	# Margins: left padding for START, right padding for END
	if menu_button_position == MenuPosition.START:
		_menu_wrapper.add_theme_constant_override("margin_left", M3Units.dp(12))
		_menu_wrapper.add_theme_constant_override("margin_right", 0)
	else:
		_menu_wrapper.add_theme_constant_override("margin_left", 0)
		_menu_wrapper.add_theme_constant_override("margin_right", M3Units.dp(12))
	
	_update_item_sizes()

func _add_footer_content():
	"""Add footer content to the bar's footer wrapper."""
	if not _footer_wrapper or not footer_content:
		return
	
	# Clear existing children
	for child in _footer_wrapper.get_children():
		_footer_wrapper.remove_child(child)
	
	_footer_wrapper.add_child(footer_content)
	_footer_wrapper.visible = true
	
	# Position footer at END (right)
	if _content_container and _content_container.get_child_count() > 2:
		if _content_container.get_child(2) != _footer_wrapper:
			_content_container.move_child(_footer_wrapper, 2)
	
	_update_item_sizes()

func _apply_content_margins():
	if not content_node:
		return
	var height_px = M3Units.dp(HEIGHT_EXPANDED) if expanded else M3Units.dp(HEIGHT_COMPACT)
	# INTEGRATED mode: push content up by bar height (flush)
	if content_node.has_method("add_theme_constant_override"):
		# It's a MarginContainer or similar
		content_node.add_theme_constant_override("margin_bottom", int(height_px))
	else:
		# It's a Control with offset
		content_node.offset_bottom = -height_px

func _notification(what: int):
	if what == NOTIFICATION_RESIZED:
		_update_item_sizes()

# ============================================
# DESTINATION MANAGEMENT (override)
# ============================================

func _rebuild_destinations():
	# Guard: containers not initialized yet
	if not _content_container or not _items_container:
		return
	
	# Check if we can do a lightweight update instead of full rebuild
	if _can_update_in_place():
		_update_destinations_in_place()
		return
	
	# Full rebuild - clear items only
	for item in _destination_items:
		if item.get_parent():
			item.get_parent().remove_child(item)
		item.queue_free()
	_destination_items.clear()
	
	# Clear items container
	for child in _items_container.get_children():
		_items_container.remove_child(child)
		child.queue_free()
	
	var target_layout = M3NavigationDestination.LayoutMode.VERTICAL if not expanded else M3NavigationDestination.LayoutMode.HORIZONTAL
	var target_height = M3Units.dp(HEIGHT_COMPACT if not expanded else HEIGHT_EXPANDED)
	
	# Build new items
	for i in range(destinations.size()):
		var data = destinations[i]
		
		# Create destination item
		var item = M3NavigationDestination.new()
		item.destination_icon = data.icon_name
		item.destination_label = data.label
		item.destination_layout = target_layout
		item.active = (i == selected_index)
		item.disabled = data.disabled
		item.label_visibility = _get_effective_label_visibility()
		item.size_flags_horizontal = 0
		item.size_flags_vertical = Control.SIZE_FILL
		item.custom_minimum_size.y = target_height
		
		# Connect signal
		item.pressed.connect(_on_destination_pressed.bind(i))
		
		_destination_items.append(item)
		_items_container.add_child(item)
	
	_update_item_sizes()
	_cached_destinations = destinations.duplicate()

func _update_destinations_in_place():
	"""Update existing items without destroying them."""
	var target_layout = M3NavigationDestination.LayoutMode.VERTICAL if not expanded else M3NavigationDestination.LayoutMode.HORIZONTAL
	var target_height = M3Units.dp(HEIGHT_COMPACT if not expanded else HEIGHT_EXPANDED)
	
	for i in range(destinations.size()):
		var data = destinations[i]
		var item = _destination_items[i]
		
		# Only update properties that changed
		if item.destination_icon != data.icon_name:
			item.destination_icon = data.icon_name
		if item.destination_label != data.label:
			item.destination_label = data.label
		if item.disabled != data.disabled:
			item.disabled = data.disabled
		
		item.active = (i == selected_index)
		
		if item.destination_layout != target_layout:
			item.destination_layout = target_layout
		item.custom_minimum_size.y = target_height
	
	_update_item_sizes()
	_cached_destinations = destinations.duplicate()

func _update_destinations_layout():
	var target_layout = M3NavigationDestination.LayoutMode.VERTICAL if not expanded else M3NavigationDestination.LayoutMode.HORIZONTAL
	var target_height = M3Units.dp(HEIGHT_COMPACT if not expanded else HEIGHT_EXPANDED)
	
	for item in _destination_items:
		if item.destination_layout != target_layout:
			item.destination_layout = target_layout
		item.label_visibility = _get_effective_label_visibility()
		item.custom_minimum_size.y = target_height
	
	_update_item_sizes()

# ============================================
# ITEM SIZING
# ============================================

func _update_item_sizes():
	if _destination_items.is_empty() or not _items_container:
		return
	
	var menu_width = M3Units.dp(MENU_BUTTON_WIDTH) if show_menu_button else 0
	var footer_width = M3Units.dp(MENU_BUTTON_WIDTH) if footer_content else 0
	var available_width = size.x - menu_width - footer_width
	var ideal_width = available_width / _destination_items.size()
	var item_width = clamp(ideal_width, M3Units.dp(MIN_ITEM_WIDTH), M3Units.dp(MAX_ITEM_WIDTH))
	
	for item in _destination_items:
		item.custom_minimum_size.x = item_width

# ============================================
# THEME
# ============================================

func refresh_theme():
	super.refresh_theme()
	if _menu_button:
		_menu_button.refresh_theme()
