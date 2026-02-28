class_name BottomBar
extends MarginContainer

signal nav_button_pressed(view_name: String)
signal zoom_changed(value: float)

enum BarOrientation {
	HORIZONTAL,
	VERTICAL
}

# Scene references
var home_button: TextureButton
var library_button: TextureButton
var downloads_button: TextureButton
var settings_button: TextureButton

# Both orientations (created once, toggled via visibility)
var _horizontal_container: HBoxContainer
var _vertical_container: VBoxContainer

# Horizontal components
var _h_status_label: Label
var _h_nav_buttons: HBoxContainer
var _h_zoom_container: HBoxContainer
var _h_zoom_slider: HSlider

# Vertical components  
var _v_status_label: Label
var _v_nav_buttons: VBoxContainer
var _v_zoom_container: VBoxContainer
var _v_zoom_slider: VSlider

var _current_view: String = ""
var _current_orientation: BarOrientation = BarOrientation.HORIZONTAL

func _ready():
	_find_scene_nodes()
	_build_both_orientations()
	_connect_signals()
	_update_nav_buttons()

func _find_scene_nodes():
	# Find scene nodes but don't remove NavButtons yet - we'll repurpose them
	var scene_status = get_node_or_null("StatusLabel")
	if scene_status:
		scene_status.queue_free()
	
	var nav_buttons = get_node_or_null("NavButtons")
	if nav_buttons:
		home_button = nav_buttons.get_node_or_null("HomeButton")
		library_button = nav_buttons.get_node_or_null("LibraryButton")
		downloads_button = nav_buttons.get_node_or_null("DownloadsButton")
		settings_button = nav_buttons.get_node_or_null("SettingsButton")
		# Keep nav_buttons reference so we can queue_free after extracting buttons
		nav_buttons.visible = false

func _build_both_orientations():
	"""Build both horizontal and vertical layouts once."""
	_horizontal_container = _build_horizontal_layout()
	_horizontal_container.name = "HorizontalContainer"
	_horizontal_container.visible = true
	add_child(_horizontal_container)
	
	_vertical_container = _build_vertical_layout()
	_vertical_container.name = "VerticalContainer"
	_vertical_container.visible = false
	add_child(_vertical_container)
	
	# Remove original nav buttons container after extracting buttons
	var original_nav = get_node_or_null("NavButtons")
	if original_nav:
		original_nav.queue_free()

func _build_horizontal_layout() -> HBoxContainer:
	var container = HBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Status label - use full width in horizontal
	_h_status_label = Label.new()
	_h_status_label.name = "StatusLabel"
	_h_status_label.text = "Ready"
	_h_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_h_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_h_status_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_h_status_label.clip_text = true
	_h_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_h_status_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_child(_h_status_label)
	
	# Center container for nav buttons
	var center = CenterContainer.new()
	center.name = "CenterContainer"
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	_h_nav_buttons = HBoxContainer.new()
	_h_nav_buttons.name = "NavButtons"
	_h_nav_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_h_nav_buttons.add_theme_constant_override("separation", 4)
	_h_nav_buttons.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_h_nav_buttons.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_reparent_buttons_to(_h_nav_buttons)
	center.add_child(_h_nav_buttons)
	container.add_child(center)
	
	# Zoom container - fills available space
	_h_zoom_container = HBoxContainer.new()
	_h_zoom_container.name = "ZoomContainer"
	_h_zoom_container.add_theme_constant_override("separation", 4)
	_h_zoom_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_h_zoom_container.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	
	_h_zoom_slider = HSlider.new()
	_h_zoom_slider.name = "ZoomSlider"
	_h_zoom_slider.custom_minimum_size = Vector2(150, 20)
	_h_zoom_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_h_zoom_slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_setup_zoom_slider(_h_zoom_slider)
	_h_zoom_container.add_child(_h_zoom_slider)
	
	container.add_child(_h_zoom_container)
	
	return container

func _build_vertical_layout() -> VBoxContainer:
	var container = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Nav buttons at top - fill available space
	_v_nav_buttons = VBoxContainer.new()
	_v_nav_buttons.name = "NavButtons"
	_v_nav_buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	_v_nav_buttons.add_theme_constant_override("separation", 4)
	_v_nav_buttons.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_v_nav_buttons.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Don't add buttons here yet - they'll be reparented when switching
	container.add_child(_v_nav_buttons)
	
	# Spacer to push zoom to middle
	var spacer = Control.new()
	spacer.name = "Spacer"
	spacer.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	container.add_child(spacer)
	
	# Zoom container - fills available space
	_v_zoom_container = VBoxContainer.new()
	_v_zoom_container.name = "ZoomContainer"
	_v_zoom_container.add_theme_constant_override("separation", 4)
	_v_zoom_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_v_zoom_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	_v_zoom_slider = VSlider.new()
	_v_zoom_slider.name = "ZoomSlider"
	_v_zoom_slider.custom_minimum_size = Vector2(20, 150)
	_v_zoom_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_v_zoom_slider.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_setup_zoom_slider(_v_zoom_slider)
	_v_zoom_container.add_child(_v_zoom_slider)
	
	container.add_child(_v_zoom_container)
	
	# Status label at bottom - fills width, shrinks vertically
	_v_status_label = Label.new()
	_v_status_label.name = "StatusLabel"
	_v_status_label.text = "Ready"
	_v_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_v_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_v_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_v_status_label.clip_text = true
	_v_status_label.max_lines_visible = 3
	_v_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_v_status_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	container.add_child(_v_status_label)
	
	return container

func _setup_zoom_slider(slider: Slider):
	slider.min_value = 0.15
	slider.max_value = 0.5
	slider.step = 0.01
	slider.value = 0.25
	slider.focus_mode = Control.FOCUS_NONE
	# Size flags will be set by the calling function to match container needs
	slider.value_changed.connect(_on_zoom_value_changed)

func _reparent_buttons_to(container: BoxContainer):
	var buttons = [home_button, library_button, downloads_button, settings_button]
	for button in buttons:
		if is_instance_valid(button):
			if button.get_parent():
				button.get_parent().remove_child(button)
			button.set_anchors_preset(Control.PRESET_TOP_LEFT)
			button.position = Vector2.ZERO
			# Fill mode: buttons expand to fill available space in their container
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.size_flags_vertical = Control.SIZE_EXPAND_FILL
			container.add_child(button)

func _connect_signals():
	if home_button:
		home_button.pressed.connect(_on_nav_pressed.bind("Home"))
	if library_button:
		library_button.pressed.connect(_on_nav_pressed.bind("Library"))
	if downloads_button:
		downloads_button.pressed.connect(_on_nav_pressed.bind("Downloads"))
	if settings_button:
		settings_button.pressed.connect(_on_nav_pressed.bind("Settings"))

func set_orientation(orientation: int) -> void:
	var new_orientation = orientation as BarOrientation
	if _current_orientation == new_orientation:
		return
	
	_current_orientation = new_orientation
	
	# Toggle visibility
	_horizontal_container.visible = _current_orientation == BarOrientation.HORIZONTAL
	_vertical_container.visible = _current_orientation == BarOrientation.VERTICAL
	
	# Sync zoom value before reparenting
	if _current_orientation == BarOrientation.HORIZONTAL:
		_h_zoom_slider.value = _v_zoom_slider.value
		_reparent_buttons_to(_h_nav_buttons)
	else:
		_v_zoom_slider.value = _h_zoom_slider.value
		_reparent_buttons_to(_v_nav_buttons)
	
	_update_zoom_visibility()
	
	# Notify parent to recalculate layout
	if get_parent():
		get_parent().queue_sort()

func _on_nav_pressed(view_name: String):
	if view_name != _current_view:
		nav_button_pressed.emit(view_name)

func _on_zoom_value_changed(value: float):
	# Sync zoom values between orientations
	if _current_orientation == BarOrientation.HORIZONTAL:
		_v_zoom_slider.value = value
	else:
		_h_zoom_slider.value = value
	zoom_changed.emit(value)

func set_current_view(view_name: String):
	_current_view = view_name
	_update_nav_buttons()
	_update_zoom_visibility()

func _update_nav_buttons():
	if home_button:
		home_button.set_pressed(_current_view == "Home")
	if library_button:
		library_button.set_pressed(_current_view == "Library")
	if downloads_button:
		downloads_button.set_pressed(_current_view == "Downloads")
	if settings_button:
		settings_button.set_pressed(_current_view == "Settings")

func _update_zoom_visibility():
	var show_zoom = _current_view in ["Home", "Library"]
	_h_zoom_container.visible = show_zoom
	_v_zoom_container.visible = show_zoom

func set_status_text(text: String):
	if _h_status_label:
		_h_status_label.text = text
	if _v_status_label:
		_v_status_label.text = text

func get_status_text() -> String:
	if _current_orientation == BarOrientation.HORIZONTAL:
		return _h_status_label.text if _h_status_label else ""
	else:
		return _v_status_label.text if _v_status_label else ""

func set_zoom_value(value: float):
	_h_zoom_slider.value = value
	_v_zoom_slider.value = value

func get_zoom_value() -> float:
	if _current_orientation == BarOrientation.HORIZONTAL:
		return _h_zoom_slider.value
	else:
		return _v_zoom_slider.value

func set_zoom_range(min_val: float, max_val: float, step: float):
	_h_zoom_slider.min_value = min_val
	_h_zoom_slider.max_value = max_val
	_h_zoom_slider.step = step
	_v_zoom_slider.min_value = min_val
	_v_zoom_slider.max_value = max_val
	_v_zoom_slider.step = step
