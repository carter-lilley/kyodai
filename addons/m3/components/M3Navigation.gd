@tool
class_name M3Navigation
extends PanelContainer

## Abstract base class for Material 3 Navigation components.
## Subclasses: M3NavigationRail, M3NavigationBar
## Handles shared logic: expanded state, destination diffing, content positioning.

signal destination_selected(index: int, reselected: bool)
signal on_expanded
signal on_collapsed

enum LabelVisibility { AUTO, SELECTED, LABELED, UNLABELED }
enum PlacementMode { OVERLAY, INTEGRATED }
enum MenuPosition { START, END }

# ============================================
# EXPORTS
# ============================================

@export var placement_mode: PlacementMode = PlacementMode.OVERLAY
@export var content_node: Control = null

@export var expanded: bool = false:
	set(value):
		if value == expanded:
			return
		expanded = value
		if expanded:
			on_expanded.emit()
		else:
			on_collapsed.emit()
		_update_dimensions()
		_update_destinations_layout()
		_update_content_position()
		queue_redraw()

@export var label_visibility: LabelVisibility = LabelVisibility.AUTO:
	set(value):
		if value == label_visibility:
			return
		label_visibility = value
		_update_label_visibility()

@export var destinations: Array = []:
	set(value):
		if value == destinations:
			return
		destinations = value
		_rebuild_destinations()

@export var selected_index: int = -1:
	set(value):
		if value == selected_index:
			return
		var old_index = selected_index
		selected_index = value
		_update_selection(old_index)

@export var show_menu_button: bool = true:
	set(value):
		if value == show_menu_button:
			return
		show_menu_button = value
		_update_menu_button_state()

@export var menu_button_position: MenuPosition = MenuPosition.START:
	set(value):
		if value == menu_button_position:
			return
		menu_button_position = value
		_update_menu_button_state()

@export var footer_content: Control = null:
	set(value):
		if value == footer_content:
			return
		if footer_content and footer_content.get_parent():
			footer_content.get_parent().remove_child(footer_content)
		footer_content = value
		if footer_content:
			_add_footer_content()
		_update_dimensions()

# ============================================
# INTERNAL
# ============================================

var _destination_items: Array[M3NavigationDestination] = []
var _cached_destinations: Array = []
var _cached_background: StyleBoxFlat

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	_initialize_background()
	_rebuild_destinations()

func _initialize_background():
	_cached_background = StyleBoxFlat.new()
	_cached_background.bg_color = M3Theme.get_surface_container()
	_cached_background.anti_aliasing = true
	_cached_background.anti_aliasing_size = 1.0
	add_theme_stylebox_override("panel", _cached_background)

# ============================================
# DIMENSIONS & CONTENT POSITIONING
# ============================================

func _update_dimensions():
	"""Override in subclass to update component size/position."""
	pass

func _update_destinations_layout():
	"""Override in subclass to update destination item layouts."""
	pass

func _update_content_position():
	"""Adjust content_node margins when in INTEGRATED mode."""
	if not content_node or placement_mode == PlacementMode.OVERLAY:
		return
	_apply_content_margins()

func _apply_content_margins():
	"""Override in subclass to set content_node margins."""
	pass

# ============================================
# DESTINATION MANAGEMENT
# ============================================

func _rebuild_destinations():
	"""Override in subclass."""
	pass

func _can_update_in_place() -> bool:
	"""Check if destinations changed in a way that allows in-place updates."""
	if _cached_destinations.is_empty() or destinations.size() != _cached_destinations.size():
		return false
	return _can_update_structure()

func _can_update_structure() -> bool:
	"""Override in subclass if structure checks are needed (e.g., headers)."""
	return true

func _get_effective_label_visibility() -> LabelVisibility:
	match label_visibility:
		LabelVisibility.AUTO:
			var count = _destination_items.size()
			if count <= 3:
				return LabelVisibility.LABELED
			else:
				return LabelVisibility.SELECTED
		_:
			return label_visibility

func _update_label_visibility():
	var effective = _get_effective_label_visibility()
	for item in _destination_items:
		item.label_visibility = effective

func _update_selection(old_index: int):
	var effective = _get_effective_label_visibility()
	
	# Update visual state of items
	for i in range(_destination_items.size()):
		var item = _destination_items[i]
		item.active = (i == selected_index)
	
	# Update label visibility for SELECTED mode
	if effective == LabelVisibility.SELECTED:
		_update_label_visibility()
	
	# Emit signal
	if selected_index >= 0 and selected_index < destinations.size():
		var reselected = (old_index == selected_index)
		destination_selected.emit(selected_index, reselected)

func _on_destination_pressed(index: int):
	if index < 0 or index >= destinations.size():
		return
	if destinations[index].disabled:
		return
	selected_index = index

func _on_menu_button_pressed():
	expanded = not expanded

func _update_menu_button_state():
	"""Override in subclass to update menu button visibility and position."""
	pass

func _add_footer_content():
	"""Override in subclass to place footer content in the correct position."""
	pass

# ============================================
# THEME
# ============================================

func refresh_theme():
	if _cached_background:
		_cached_background.bg_color = M3Theme.get_surface_container()
	for item in _destination_items:
		item.refresh_theme()

# ============================================
# PUBLIC API
# ============================================

func get_destination_count() -> int:
	return destinations.size()

func set_destination_enabled(index: int, enabled: bool):
	if index >= 0 and index < destinations.size():
		var new_disabled = not enabled
		if destinations[index].disabled != new_disabled:
			destinations[index].disabled = new_disabled
			if index < _destination_items.size():
				_destination_items[index].disabled = new_disabled
