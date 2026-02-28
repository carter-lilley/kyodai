#modal.gd
extends PopupPanel
class_name Modal

signal item_selected(item_id: String)
signal dismissed()

var _items_container: VBoxContainer
var _items: Array[Dictionary] = []
var _buttons: Dictionary = {}
var _background_style: StyleBoxFlat

func _init(items: Array[Dictionary] = []) -> void:
	_create_background_style()
	_items = items

func _ready() -> void:
	# Configure popup behavior
	exclusive = false
	
	# Main margin container for padding
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)
	
	# Items container
	_items_container = VBoxContainer.new()
	_items_container.add_theme_constant_override("separation", 0)
	margin.add_child(_items_container)
	
	# Build items
	_rebuild_items()
	
	# Connect signals
	visibility_changed.connect(_on_visibility_changed)

func _create_background_style() -> void:
	_background_style = StyleBoxFlat.new()
	_background_style.corner_radius_top_left = 8
	_background_style.corner_radius_top_right = 8
	_background_style.corner_radius_bottom_left = 8
	_background_style.corner_radius_bottom_right = 8
	add_theme_stylebox_override("panel", _background_style)

func _rebuild_items() -> void:
	# Clear existing
	for child in _items_container.get_children():
		child.queue_free()
	_buttons.clear()
	
	# Build new items
	for i in range(_items.size()):
		var item = _items[i]
		var item_id = item.get("id", "")
		var item_text = item.get("text", "")
		var item_icon = item.get("icon", null)
		var item_disabled = item.get("disabled", false)
		
		if item_id == "":
			continue
		
		# Create button
		var button = Button.new()
		button.text = item_text
		button.flat = true
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.disabled = item_disabled
		
		if item_icon:
			button.icon = item_icon
		
		button.pressed.connect(_on_item_pressed.bind(item_id))
		_items_container.add_child(button)
		_buttons[item_id] = button
		
		# Add separator after each item except the last
		if i < _items.size() - 1:
			var separator = HSeparator.new()
			_items_container.add_child(separator)

func _on_item_pressed(item_id: String) -> void:
	item_selected.emit(item_id)
	hide()

func _on_visibility_changed() -> void:
	if not visible:
		dismissed.emit()

func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed("ui_cancel"):
		hide()
		get_viewport().set_input_as_handled()

# Public API

func set_items(items: Array[Dictionary]) -> void:
	_items = items
	if is_node_ready():
		_rebuild_items()

func add_item(item: Dictionary) -> void:
	_items.append(item)
	if is_node_ready():
		_rebuild_items()

func remove_item(id: String) -> void:
	for i in range(_items.size()):
		if _items[i].get("id", "") == id:
			_items.remove_at(i)
			break
	if is_node_ready():
		_rebuild_items()

func set_item_enabled(id: String, enabled: bool) -> void:
	for item in _items:
		if item.get("id", "") == id:
			item["disabled"] = not enabled
			break
	if _buttons.has(id):
		_buttons[id].disabled = not enabled

func popup_at_position(pos: Vector2) -> void:
	popup(Rect2i(pos.x, pos.y, 0, 0))
	# Grab focus on the first item after showing
	call_deferred("_grab_first_item_focus")

func _grab_first_item_focus() -> void:
	# Find the first button and grab focus
	for child in _items_container.get_children():
		if child is Button and not child.disabled:
			child.grab_focus()
			break

func popup_at_mouse() -> void:
	popup_at_position(get_viewport().get_mouse_position())

func popup_at_control(control: Control, offset: Vector2 = Vector2.ZERO) -> void:
	var global_pos = control.global_position + offset
	popup_at_position(global_pos)

func dismiss() -> void:
	hide()
