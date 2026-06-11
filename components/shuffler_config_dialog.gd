class_name ShufflerConfigDialog
extends M3Dialog

signal start_session_requested(config: Dictionary)

var _platform_grid: GridContainer
var _platform_buttons: Dictionary[String, M3Button] = {}
var _selected_platforms: Array[String] = []

var _bag_size_slider: M3Slider
var _round_time_min_slider: M3Slider
var _round_time_max_slider: M3Slider

func _init():
	dialog_variant = Variant.FULL_SCREEN
	title_text = "Shuffler"
	persistent = true
	super._init()

func _ready():
	super._ready()
	
	# Hide default title/body
	if _title_label:
		_title_label.visible = false
	if _body_label:
		_body_label.visible = false
	
	# Make content slot expand to fill vertical space (required for FULL_SCREEN dialog)
	content_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	_build_content()
	_build_actions()
	_load_platforms()

func _build_content() -> void:
	# M3Dialog (FULL_SCREEN) already provides a ScrollContainer via _scroll.
	# We just add a MarginContainer directly to content_slot.
	var margin = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", int(M3Units.dp(24)))
	margin.add_theme_constant_override("margin_right", int(M3Units.dp(24)))
	margin.add_theme_constant_override("margin_top", int(M3Units.dp(16)))
	margin.add_theme_constant_override("margin_bottom", int(M3Units.dp(16)))
	
	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", int(M3Units.dp(24)))
	
	# Bag size section
	var bag_size_label = _create_section_label("Bag Size")
	vbox.add_child(bag_size_label)
	
	_bag_size_slider = M3Slider.new()
	_bag_size_slider.min_value = 2
	_bag_size_slider.max_value = 12
	_bag_size_slider.step = 1
	_bag_size_slider.value = 4
	_bag_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_bag_size_slider)
	
	var bag_size_value_label = _create_value_label("4 games")
	_bag_size_slider.value_changed.connect(func(v): bag_size_value_label.text = str(int(v)) + " games")
	vbox.add_child(bag_size_value_label)
	
	# Round time section
	var time_label = _create_section_label("Round Time")
	vbox.add_child(time_label)
	
	var time_hbox = HBoxContainer.new()
	time_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_hbox.add_theme_constant_override("separation", int(M3Units.dp(16)))
	
	var min_vbox = VBoxContainer.new()
	min_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var min_label = _create_sub_label("Minimum")
	min_vbox.add_child(min_label)
	_round_time_min_slider = M3Slider.new()
	_round_time_min_slider.min_value = 10
	_round_time_min_slider.max_value = 300
	_round_time_min_slider.step = 5
	_round_time_min_slider.value = 30
	_round_time_min_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	min_vbox.add_child(_round_time_min_slider)
	var min_value_label = _create_value_label("30s")
	_round_time_min_slider.value_changed.connect(func(v): min_value_label.text = str(int(v)) + "s")
	min_vbox.add_child(min_value_label)
	time_hbox.add_child(min_vbox)
	
	var max_vbox = VBoxContainer.new()
	max_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var max_label = _create_sub_label("Maximum")
	max_vbox.add_child(max_label)
	_round_time_max_slider = M3Slider.new()
	_round_time_max_slider.min_value = 10
	_round_time_max_slider.max_value = 300
	_round_time_max_slider.step = 5
	_round_time_max_slider.value = 120
	_round_time_max_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	max_vbox.add_child(_round_time_max_slider)
	var max_value_label = _create_value_label("120s")
	_round_time_max_slider.value_changed.connect(func(v): max_value_label.text = str(int(v)) + "s")
	max_vbox.add_child(max_value_label)
	time_hbox.add_child(max_vbox)
	
	vbox.add_child(time_hbox)
	
	# Platforms section
	var platforms_label = _create_section_label("Platforms")
	vbox.add_child(platforms_label)
	
	_platform_grid = GridContainer.new()
	_platform_grid.columns = 3
	_platform_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_platform_grid.add_theme_constant_override("h_separation", int(M3Units.dp(8)))
	_platform_grid.add_theme_constant_override("v_separation", int(M3Units.dp(8)))
	vbox.add_child(_platform_grid)
	
	margin.add_child(vbox)
	content_slot.add_child(margin)

func _build_actions() -> void:
	add_action("Start Session", _on_start_pressed, true)
	add_action("Cancel", dismiss)

func _load_platforms() -> void:
	var platforms = DataManager.get_platforms_with_games()
	for platform in platforms:
		var slug = platform["slug"]
		var name = platform["name"]
		var btn = M3Button.new()
		btn.text = name
		btn.button_variant = M3Button.Variant.OUTLINED
		btn.button_type = M3Button.Type.TOGGLE
		btn.toggle_mode = true
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.pressed.connect(_on_platform_toggled.bind(slug, btn))
		_platform_grid.add_child(btn)
		_platform_buttons[slug] = btn

func _on_platform_toggled(slug: String, btn: M3Button) -> void:
	if btn.button_pressed:
		if slug not in _selected_platforms:
			_selected_platforms.append(slug)
	else:
		_selected_platforms.erase(slug)

func _on_start_pressed() -> void:
	if _selected_platforms.is_empty():
		NotificationManager.show_notification("Please select at least one platform", NotificationManager.Type.ERROR)
		return
	
	var min_time = _round_time_min_slider.value
	var max_time = _round_time_max_slider.value
	
	if min_time > max_time:
		NotificationManager.show_notification("Minimum round time must be less than maximum", NotificationManager.Type.ERROR)
		return
	
	var config = {
		"platforms": _selected_platforms.duplicate(),
		"bag_size": int(_bag_size_slider.value),
		"round_time_min": min_time,
		"round_time_max": max_time,
	}
	
	dismiss()
	start_session_requested.emit(config)

func _create_section_label(text: String) -> Label:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", M3Units.dp(20))
	return label

func _create_sub_label(text: String) -> Label:
	var label = Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", M3Units.dp(14))
	return label

func _create_value_label(text: String) -> Label:
	var label = Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", M3Units.dp(14))
	return label
