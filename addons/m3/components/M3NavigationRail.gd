@tool
class_name M3NavigationRail
extends M3Navigation

## Material 3 Navigation Rail
## Vertical navigation component with collapsed (icon-only) and expanded (icon+label) modes.

enum MenuGravity { TOP, CENTER, BOTTOM }

# ============================================
# SIZE SPECS (all values in dp)
# ============================================

const WIDTH_COLLAPSED := 96
const WIDTH_EXPANDED := 220
const ITEM_HEIGHT_COLLAPSED := 60
const ITEM_HEIGHT_EXPANDED := 56

# ============================================
# EXPORTS
# ============================================

signal width_changed(width: float)

@export var menu_gravity: MenuGravity = MenuGravity.TOP:
	set(value):
		if value == menu_gravity:
			return
		menu_gravity = value
		_update_menu_gravity()

@export var header_content: Node = null:
	set(value):
		if value == header_content:
			return
		if header_content and header_content.get_parent():
			header_content.get_parent().remove_child(header_content)
		header_content = value
		if header_content:
			# Add to end of content container
			if _content_container:
				_content_container.add_child(header_content)
		_update_dimensions()

# ============================================
# INTERNAL
# ============================================

var _content_container: VBoxContainer
var _items_area: VBoxContainer
var _menu_button: M3IconButton
var _menu_wrapper: MarginContainer
var _top_spacer: Control
var _bottom_spacer: Control
var _top_flex_spacer: Control
var _bottom_flex_spacer: Control
var _footer_wrapper: MarginContainer
var _header_nodes: Array[Node] = []
var _header_labels: Array[Label] = []
var _sectioned_items: Array[M3NavigationDestination] = []
var _cached_items_height: float = 0.0

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	_create_layout()
	super._ready()

func _create_layout():
	# Single child: VBoxContainer
	_content_container = VBoxContainer.new()
	_content_container.name = "ContentContainer"
	_content_container.add_theme_constant_override("separation", 0)
	add_child(_content_container)
	
	# Top spacer for padding
	_top_spacer = Control.new()
	_top_spacer.name = "TopSpacer"
	_top_spacer.custom_minimum_size = Vector2(0, M3Units.dp(12))
	_content_container.add_child(_top_spacer)
	
	# Menu toggle button wrapped in MarginContainer for alignment
	_menu_wrapper = MarginContainer.new()
	_menu_wrapper.name = "MenuWrapper"
	_menu_wrapper.add_theme_constant_override("margin_top", 0)
	_menu_wrapper.add_theme_constant_override("margin_bottom", 0)
	_content_container.add_child(_menu_wrapper)
	
	_menu_button = M3IconButton.new()
	_menu_button.name = "MenuButton"
	_menu_button.icon_name = "menu"
	_menu_button.icon_button_variant = M3IconButton.IconVariant.STANDARD
	_menu_button.icon_button_size = M3IconButton.IconSize.MEDIUM
	_menu_button.pressed.connect(_on_menu_button_pressed)
	_menu_wrapper.add_child(_menu_button)
	
	# Items area container (takes all remaining space, holds flex spacers and items)
	_items_area = VBoxContainer.new()
	_items_area.name = "ItemsArea"
	_items_area.add_theme_constant_override("separation", 0)
	_items_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content_container.add_child(_items_area)
	
	# Footer wrapper (for footer_content slot)
	_footer_wrapper = MarginContainer.new()
	_footer_wrapper.name = "FooterWrapper"
	_footer_wrapper.add_theme_constant_override("margin_top", M3Units.dp(12))
	_footer_wrapper.add_theme_constant_override("margin_bottom", M3Units.dp(12))
	_footer_wrapper.visible = false
	_content_container.add_child(_footer_wrapper)
	
	# Bottom spacer for padding when menu is at END
	_bottom_spacer = Control.new()
	_bottom_spacer.name = "BottomSpacer"
	_bottom_spacer.custom_minimum_size = Vector2(0, M3Units.dp(12))
	_content_container.add_child(_bottom_spacer)
	
	_update_dimensions()

func _update_dimensions():
	if not _content_container or not _menu_wrapper:
		return
	
	var width_px = M3Units.dp(WIDTH_EXPANDED) if expanded else M3Units.dp(WIDTH_COLLAPSED)
	custom_minimum_size = Vector2(width_px, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	width_changed.emit(width_px)
	
	# Position menu button via MarginContainer margins
	var btn_size = M3Units.dp(48)
	var margin_left = M3Units.dp(24)
	if expanded:
		# Left-aligned at 24dp (slightly inset, but not as far as destinations)
		_menu_wrapper.add_theme_constant_override("margin_left", margin_left)
		_menu_wrapper.add_theme_constant_override("margin_right", width_px - margin_left - btn_size)
	else:
		# Centered
		var side_margin = (width_px - btn_size) / 2.0
		_menu_wrapper.add_theme_constant_override("margin_left", side_margin)
		_menu_wrapper.add_theme_constant_override("margin_right", side_margin)
	
	# Update content position in integrated mode
	_update_content_position()

func _update_menu_button_state():
	"""Update menu button visibility and position in the rail."""
	if not _menu_wrapper or not _content_container:
		return
	
	# Visibility
	_menu_wrapper.visible = show_menu_button
	if _bottom_spacer:
		_bottom_spacer.visible = show_menu_button and menu_button_position == MenuPosition.END
	
	# Position: START (after TopSpacer) or END (before BottomSpacer)
	if menu_button_position == MenuPosition.START:
		if _content_container.get_child_count() > 1:
			if _content_container.get_child(1) != _menu_wrapper:
				_content_container.move_child(_menu_wrapper, 1)
	else:
		if _content_container.get_child_count() > 2:
			if _content_container.get_child(_content_container.get_child_count() - 2) != _menu_wrapper:
				_content_container.move_child(_menu_wrapper, _content_container.get_child_count() - 2)
	
	_update_menu_gravity()

func _add_footer_content():
	"""Add footer content to the rail's footer wrapper."""
	if not _footer_wrapper or not footer_content:
		return
	
	# Clear existing children
	for child in _footer_wrapper.get_children():
		_footer_wrapper.remove_child(child)
	
	_footer_wrapper.add_child(footer_content)
	_footer_wrapper.visible = true
	
	# Center horizontally in collapsed mode
	var width_px = M3Units.dp(WIDTH_EXPANDED) if expanded else M3Units.dp(WIDTH_COLLAPSED)
	var btn_size = M3Units.dp(48)
	if expanded:
		var margin_left = M3Units.dp(24)
		_footer_wrapper.add_theme_constant_override("margin_left", margin_left)
		_footer_wrapper.add_theme_constant_override("margin_right", width_px - margin_left - btn_size)
	else:
		var side_margin = (width_px - btn_size) / 2.0
		_footer_wrapper.add_theme_constant_override("margin_left", side_margin)
		_footer_wrapper.add_theme_constant_override("margin_right", side_margin)
	
	_update_menu_gravity()

func _apply_content_margins():
	if not content_node:
		return
	var width_px = M3Units.dp(WIDTH_EXPANDED) if expanded else M3Units.dp(WIDTH_COLLAPSED)
	# INTEGRATED mode: push content right by rail width (flush)
	if content_node.has_method("add_theme_constant_override"):
		content_node.add_theme_constant_override("margin_left", int(width_px))
	else:
		content_node.offset_left = width_px

func _can_update_structure() -> bool:
	"""Rail-specific: check if header vs item structure changed."""
	for i in range(destinations.size()):
		var old_is_header = _cached_destinations[i].icon_name.is_empty() and not _cached_destinations[i].label.is_empty()
		var new_is_header = destinations[i].icon_name.is_empty() and not destinations[i].label.is_empty()
		if old_is_header != new_is_header:
			return false
	return true

func _update_menu_gravity():
	if not _top_flex_spacer or not _bottom_flex_spacer:
		return
	
	# Reset
	_top_flex_spacer.size_flags_vertical = 0
	_top_flex_spacer.custom_minimum_size = Vector2.ZERO
	_bottom_flex_spacer.size_flags_vertical = 0
	_bottom_flex_spacer.custom_minimum_size = Vector2.ZERO
	
	# Calculate footer area height if present
	var footer_height = 0.0
	if _footer_wrapper and _footer_wrapper.visible:
		# Footer = margin_top (12dp) + button (48dp) + margin_bottom (12dp)
		footer_height = M3Units.dp(72)
	
	match menu_gravity:
		MenuGravity.TOP:
			if menu_button_position == MenuPosition.START:
				_bottom_flex_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
			# END: both spacers stay 0, items sit at top of ItemsArea
		
		MenuGravity.CENTER:
			if menu_button_position == MenuPosition.START:
				var rail_height = size.y
				# Menu area = top spacer (12dp) + menu button height (48dp for MEDIUM)
				var menu_btn_height = _menu_button.custom_minimum_size.y if _menu_button else M3Units.dp(48)
				var menu_area_height = _top_spacer.custom_minimum_size.y + menu_btn_height
				# Footer area takes space at bottom
				var available_height = rail_height - footer_height
				# Use cached height if valid
				var items_height = _cached_items_height
				if items_height <= 0:
					items_height = _calculate_items_height()
				# Center items within available space below menu and above footer
				# items_center = menu_area + top_padding + items_height/2 = available_height/2
				# top_padding = (available_height - items_height)/2 - menu_area_height
				var top_padding = (available_height - items_height) / 2.0 - menu_area_height
				
				if top_padding > 0:
					_top_flex_spacer.custom_minimum_size = Vector2(0, top_padding)
				_bottom_flex_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
			else:
				# END: center within ItemsArea (menu is outside, so just equal expansion)
				_top_flex_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
				_bottom_flex_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
		
		MenuGravity.BOTTOM:
			_top_flex_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL

func _calculate_items_height() -> float:
	var total = 0.0
	for child in _items_area.get_children():
		if child == _top_flex_spacer or child == _bottom_flex_spacer:
			continue
		if child.visible:
			total += child.custom_minimum_size.y if child.custom_minimum_size.y > 0 else child.size.y
	_cached_items_height = total
	return total

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		if menu_gravity == MenuGravity.CENTER:
			_update_menu_gravity()

# ============================================
# DESTINATION MANAGEMENT (override)
# ============================================

func _rebuild_destinations():
	if not _content_container:
		return
	
	# Check if we can do a lightweight update instead of full rebuild
	if _can_update_in_place():
		_update_destinations_in_place()
		return
	
	# Full rebuild - clear everything
	for item in _destination_items:
		if item.get_parent():
			item.get_parent().remove_child(item)
		item.queue_free()
	_destination_items.clear()
	
	for node in _header_nodes:
		if node.get_parent():
			node.get_parent().remove_child(node)
		node.queue_free()
	_header_nodes.clear()
	_header_labels.clear()
	
	_sectioned_items.clear()
	
	for child in _items_area.get_children():
		_items_area.remove_child(child)
		child.queue_free()
	
	# Re-add top flex spacer
	_top_flex_spacer = Control.new()
	_top_flex_spacer.name = "TopFlexSpacer"
	_items_area.add_child(_top_flex_spacer)
	
	# Build new items
	var item_idx = 0
	var in_section = false
	for i in range(destinations.size()):
		var data = destinations[i]
		
		if data.icon_name.is_empty() and not data.label.is_empty():
			in_section = true
			
			var spacer = Control.new()
			spacer.custom_minimum_size = Vector2(0, M3Units.dp(12))
			spacer.visible = expanded
			_items_area.add_child(spacer)
			_header_nodes.append(spacer)
			
			var header = Label.new()
			header.text = data.label
			header.add_theme_font_size_override("font_size", M3Units.dp(12))
			header.add_theme_color_override("font_color", M3Theme.get_on_surface_variant())
			header.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
			
			var header_container = MarginContainer.new()
			header_container.add_theme_constant_override("margin_left", M3Units.dp(36))
			header_container.add_theme_constant_override("margin_right", M3Units.dp(16))
			header_container.add_theme_constant_override("margin_top", M3Units.dp(12))
			header_container.add_theme_constant_override("margin_bottom", M3Units.dp(8))
			header_container.add_child(header)
			header_container.visible = expanded
			_items_area.add_child(header_container)
			_header_nodes.append(header_container)
			_header_labels.append(header)
			continue
		
		var item = M3NavigationDestination.new()
		item.destination_icon = data.icon_name
		item.destination_label = data.label
		item.destination_layout = M3NavigationDestination.LayoutMode.HORIZONTAL if expanded else M3NavigationDestination.LayoutMode.VERTICAL
		item.active = (item_idx == selected_index)
		item.disabled = data.disabled
		item.label_visibility = _get_effective_label_visibility()
		var height_px = M3Units.dp(ITEM_HEIGHT_EXPANDED) if expanded else M3Units.dp(ITEM_HEIGHT_COLLAPSED)
		item.custom_minimum_size.y = height_px
		if expanded:
			item.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		else:
			item.custom_minimum_size.x = M3Units.dp(WIDTH_COLLAPSED)
			item.size_flags_horizontal = Control.SIZE_FILL
		
		if in_section:
			_sectioned_items.append(item)
			item.visible = expanded
		
		item.pressed.connect(_on_destination_pressed.bind(item_idx))
		
		_destination_items.append(item)
		_items_area.add_child(item)
		item_idx += 1
	
	_bottom_flex_spacer = Control.new()
	_bottom_flex_spacer.name = "BottomFlexSpacer"
	_items_area.add_child(_bottom_flex_spacer)
	
	if header_content and header_content.get_parent() == _content_container:
		# Place header_content at end, but before BottomSpacer if menu is at END
		if menu_button_position == MenuPosition.END and _bottom_spacer and _bottom_spacer.get_parent() == _content_container:
			var bottom_idx = _content_container.get_children().find(_bottom_spacer)
			_content_container.move_child(header_content, bottom_idx)
		else:
			_content_container.move_child(header_content, -1)
	
	_cached_destinations = destinations.duplicate()
	_cached_items_height = 0.0
	_update_menu_gravity()

func _update_destinations_in_place():
	"""Update existing items without destroying them."""
	var item_idx = 0
	var in_section = false
	var header_idx = 0
	var label_idx = 0
	
	for i in range(destinations.size()):
		var data = destinations[i]
		var old_data = _cached_destinations[i]
		
		if data.icon_name.is_empty() and not data.label.is_empty():
			in_section = true
			# Update header visibility
			if header_idx < _header_nodes.size():
				_header_nodes[header_idx].visible = expanded
				header_idx += 1
			if header_idx < _header_nodes.size():
				_header_nodes[header_idx].visible = expanded
				header_idx += 1
			if label_idx < _header_labels.size():
				_header_labels[label_idx].text = data.label
				label_idx += 1
			continue
		
		if item_idx < _destination_items.size():
			var item = _destination_items[item_idx]
			
			# Only update properties that changed
			if item.destination_icon != data.icon_name:
				item.destination_icon = data.icon_name
			if item.destination_label != data.label:
				item.destination_label = data.label
			if item.disabled != data.disabled:
				item.disabled = data.disabled
			
			item.active = (item_idx == selected_index)
			
			if in_section:
				item.visible = expanded
				if not _sectioned_items.has(item):
					_sectioned_items.append(item)
			else:
				item.visible = true
				_sectioned_items.erase(item)
		
		item_idx += 1
	
	_cached_destinations = destinations.duplicate()
	_cached_items_height = 0.0
	_update_menu_gravity()

func _update_destinations_layout():
	# Toggle header visibility
	for node in _header_nodes:
		node.visible = expanded
	
	# Toggle sectioned item visibility
	for item in _sectioned_items:
		item.visible = expanded
	
	for item in _destination_items:
		item.destination_layout = M3NavigationDestination.LayoutMode.HORIZONTAL if expanded else M3NavigationDestination.LayoutMode.VERTICAL
		item.label_visibility = _get_effective_label_visibility()
		# Size: collapsed fills width, expanded shrinks to content width
		var height_px = M3Units.dp(ITEM_HEIGHT_EXPANDED) if expanded else M3Units.dp(ITEM_HEIGHT_COLLAPSED)
		item.custom_minimum_size.y = height_px
		if expanded:
			item.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		else:
			item.custom_minimum_size.x = M3Units.dp(WIDTH_COLLAPSED)
			item.size_flags_horizontal = Control.SIZE_FILL
	
	_cached_items_height = 0.0
	_update_menu_gravity()

# ============================================
# THEME
# ============================================

func refresh_theme():
	super.refresh_theme()
	if _menu_button:
		_menu_button.refresh_theme()
	# Update header label colors
	for label in _header_labels:
		label.add_theme_color_override("font_color", M3Theme.get_on_surface_variant())
