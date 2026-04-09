class_name SearchBar
extends Control

signal text_changed(text: String)
signal text_submitted(text: String)

@onready var line_edit: LineEdit
@onready var search_icon: TextureRect

var _is_active: bool = false

func _ready():
	# Set up pill-shaped styling
	custom_minimum_size = Vector2(400, 50)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	
	# Create background panel (pill shape)
	var background = Panel.new()
	background.name = "Background"
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	
	# Apply pill shape via stylebox
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.2, 0.2, 0.95)
	style.corner_radius_top_left = 25
	style.corner_radius_top_right = 25
	style.corner_radius_bottom_left = 25
	style.corner_radius_bottom_right = 25
	background.add_theme_stylebox_override("panel", style)
	
	# Create horizontal container for icon + input
	var hbox = HBoxContainer.new()
	hbox.name = "HBox"
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 10)
	hbox.add_theme_constant_override("margin_left", 15)
	hbox.add_theme_constant_override("margin_right", 15)
	hbox.add_theme_constant_override("margin_top", 5)
	hbox.add_theme_constant_override("margin_bottom", 5)
	add_child(hbox)
	
	# Search icon
	search_icon = TextureRect.new()
	search_icon.name = "SearchIcon"
	search_icon.custom_minimum_size = Vector2(24, 24)
	search_icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	search_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	search_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	search_icon.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	# Try to load a search icon, fallback to nothing if not found
	var icon = load("res://assets/icons/search.png")
	if icon:
		search_icon.texture = icon
	hbox.add_child(search_icon)
	
	# LineEdit for text input
	line_edit = LineEdit.new()
	line_edit.name = "LineEdit"
	line_edit.placeholder_text = "Search games..."
	line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	line_edit.flat = true
	line_edit.focus_mode = Control.FOCUS_ALL
	line_edit.caret_blink = true
	hbox.add_child(line_edit)
	
	# Connect signals
	line_edit.text_changed.connect(_on_text_changed)
	line_edit.text_submitted.connect(_on_text_submitted)

func _on_text_changed(text: String):
	text_changed.emit(text)

func _on_text_submitted(text: String):
	text_submitted.emit(text)

func get_text() -> String:
	return line_edit.text

func set_text(text: String):
	line_edit.text = text

func clear():
	line_edit.text = ""

func grab_focus_on_input():
	line_edit.grab_focus()

func release_focus_from_input():
	line_edit.release_focus()
