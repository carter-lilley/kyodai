class_name BottomBar
extends HBoxContainer

signal nav_button_pressed(view_name: String)
signal zoom_changed(value: float)

@onready var home_button: TextureButton = $NavButtons/HomeButton
@onready var library_button: TextureButton = $NavButtons/LibraryButton
@onready var downloads_button: TextureButton = $NavButtons/DownloadsButton
@onready var settings_button: TextureButton = $NavButtons/SettingsButton
@onready var zoom_container: HBoxContainer = $ZoomContainer
@onready var zoom_slider: HSlider = $ZoomContainer/ZoomSlider
@onready var status_label: Label = $StatusLabel

var _current_view: String = ""

func _ready():
	# Connect nav button signals
	home_button.pressed.connect(_on_nav_pressed.bind("Home"))
	library_button.pressed.connect(_on_nav_pressed.bind("Library"))
	downloads_button.pressed.connect(_on_nav_pressed.bind("Downloads"))
	settings_button.pressed.connect(_on_nav_pressed.bind("Settings"))
	
	# Connect zoom slider
	if zoom_slider:
		print("[BottomBar] Zoom slider found, connecting value_changed signal")
		zoom_slider.value_changed.connect(_on_zoom_changed)
	else:
		push_error("[BottomBar] Zoom slider not found!")
	
	# Update height when viewport changes
	get_viewport().size_changed.connect(_update_height)
	
	# Set initial height to 5% of viewport (deferred to ensure viewport is available)
	call_deferred("_update_height")
	
	# Initial state
	_update_nav_buttons()

func _update_height():
	var viewport_height = get_viewport().size.y
	var target_height = viewport_height * 0.075
	custom_minimum_size.y = target_height
	# Force the size to prevent expansion
	size.y = target_height
	print("[BottomBar] Height set to: ", target_height, " (7.5% of ", viewport_height, ")")

func _on_nav_pressed(view_name: String):
	if view_name != _current_view:
		nav_button_pressed.emit(view_name)

func _on_zoom_changed(value: float):
	print("[BottomBar] Zoom slider changed to: ", value, " - emitting signal")
	zoom_changed.emit(value)

func set_current_view(view_name: String):
	_current_view = view_name
	_update_nav_buttons()
	_update_zoom_visibility()

func _update_nav_buttons():
	# Update button pressed states to show active view
	home_button.set_pressed(_current_view == "Home")
	library_button.set_pressed(_current_view == "Library")
	downloads_button.set_pressed(_current_view == "Downloads")
	settings_button.set_pressed(_current_view == "Settings")

func _update_zoom_visibility():
	# Show zoom only for Home and Library views
	var show_zoom = _current_view in ["Home", "Library"]
	zoom_container.visible = show_zoom

func set_status_text(text: String):
	status_label.text = text

func get_status_text() -> String:
	return status_label.text

func set_zoom_value(value: float):
	zoom_slider.value = value

func get_zoom_value() -> float:
	return zoom_slider.value

func set_zoom_range(min_val: float, max_val: float, step: float):
	zoom_slider.min_value = min_val
	zoom_slider.max_value = max_val
	zoom_slider.step = step
