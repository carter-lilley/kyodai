class_name CollapsableVBoxContainer
extends VBoxContainer

@export var title: String = "":
	set(value):
		title = value
		if _title_label:
			_title_label.text = value

@export var collapsed: bool = false:
	set(value):
		collapsed = value
		_update_collapsed_state()

@export var header_height: float = 32.0:
	set(value):
		header_height = value
		if _header_button:
			_header_button.custom_minimum_size.y = value

var _header_button: Button
var _title_label: Label
var _indicator_label: Label
var _header_hbox: HBoxContainer
var _content_container: VBoxContainer

func _ready():
	_initialize_structure()
	_update_collapsed_state()

func _initialize_structure():
	# Clear existing children
	for child in get_children():
		remove_child(child)
	
	# Header button (spans full width)
	_header_button = Button.new()
	_header_button.custom_minimum_size.y = header_height
	_header_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_header_button.pressed.connect(_on_header_pressed)
	add_child(_header_button)
	
	# Header layout (HBox inside button)
	_header_hbox = HBoxContainer.new()
	_header_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_button.add_child(_header_hbox)
	
	# Fold indicator
	_indicator_label = Label.new()
	_indicator_label.text = "▼"
	_indicator_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_indicator_label.custom_minimum_size.x = 24
	_header_hbox.add_child(_indicator_label)
	
	# Title label
	_title_label = Label.new()
	_title_label.text = title
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_hbox.add_child(_title_label)
	
	# Spacer
	_header_hbox.add_spacer(false)
	
	# Content container
	_content_container = VBoxContainer.new()
	_content_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_content_container)

func _on_header_pressed():
	collapsed = not collapsed

func _update_collapsed_state():
	if _content_container and _indicator_label:
		_content_container.visible = not collapsed
		_indicator_label.text = "▶" if collapsed else "▼"

func set_title(new_title: String) -> void:
	title = new_title

func add_header_button(button: Button) -> void:
	if _header_hbox:
		_header_hbox.add_child(button)

func remove_header_button(button: Button) -> void:
	if _header_hbox and button.get_parent() == _header_hbox:
		_header_hbox.remove_child(button)

func get_content_container() -> VBoxContainer:
	return _content_container

func get_header_hbox() -> HBoxContainer:
	return _header_hbox
