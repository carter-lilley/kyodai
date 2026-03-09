class_name SettingsView
extends View

var _settings_container: TabContainer

# Library Appearance tab specific
var _library_appearance_config: Dictionary = {}
var _library_effect_menu: SettingsMenu = null
var _library_effect_dropdown: OptionButton = null

func _ready():
	view_name = "Settings"
	_build_settings_view()
	super._ready()

func _build_settings_view():
	# Create sub-TabContainer for settings groups
	_settings_container = TabContainer.new()
	_settings_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_settings_container.tab_changed.connect(_on_settings_tab_changed)
	add_child(_settings_container)
	
	# Get settings by subgroup from SettingsManager
	var subgroups = SettingsManager.get_settings_by_subgroup()
	
	# Create a tab for each subgroup
	for subgroup_name in subgroups.keys():
		var settings_vars = subgroups[subgroup_name]
		var tab = _create_settings_tab(subgroup_name, settings_vars)
		_settings_container.add_child(tab)
		_settings_container.set_tab_title(_settings_container.get_tab_count() - 1, subgroup_name)
	
	# Add Platforms tab
	var platforms_tab = _create_platforms_tab()
	_settings_container.add_child(platforms_tab)
	_settings_container.set_tab_title(_settings_container.get_tab_count() - 1, "Platforms")
	
	# Add Card Designer tab
	var designer_tab = _create_card_designer_tab()
	_settings_container.add_child(designer_tab)
	_settings_container.set_tab_title(_settings_container.get_tab_count() - 1, "Card Designer")

func _create_card_designer_tab() -> Control:
	var designer = preload("res://view/card_designer_view.tscn").instantiate()
	designer.set_anchors_preset(Control.PRESET_FULL_RECT)
	return designer

func _create_platforms_tab() -> Control:
	var platforms_view = preload("res://view/platforms_settings_view.gd").new()
	return platforms_view

func _create_settings_tab(name: String, settings_vars: Array) -> Control:
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	
	if name == "Library Appearance":
		# Handle Library Appearance specially with dynamic background controls
		_create_library_appearance_tab(vbox, settings_vars)
	else:
		# Regular settings tab
		var menu = SettingsMenu.new()
		menu.initialize_settings_menu(name, settings_vars)
		menu.setting_changed.connect(_on_setting_changed)
		vbox.add_child(menu)
	
	if name == "RomM Connection":
		var status_ui = _create_connection_status_ui()
		vbox.add_child(status_ui)
	
	margin.add_child(vbox)
	scroll.add_child(margin)
	
	return scroll

func _create_library_appearance_tab(vbox: VBoxContainer, settings_vars: Array) -> void:
	# Load current background config
	_load_library_background_config()
	
	# Title
	var title_label = Label.new()
	title_label.text = "Library Appearance"
	title_label.add_theme_font_size_override("font_size", 18)
	vbox.add_child(title_label)
	
	vbox.add_child(HSeparator.new())
	
	# General layout settings (from settings_vars, excluding internal ones)
	var general_menu = SettingsMenu.new()
	var general_settings: Array[SettingsVar] = []
	for sv in settings_vars:
		if sv.state != SettingsVar.SettingState.INTERNAL:
			general_settings.append(sv)
	
	if general_settings.size() > 0:
		var general_label = Label.new()
		general_label.text = "Layout Settings"
		general_label.add_theme_font_size_override("font_size", 14)
		vbox.add_child(general_label)
		
		general_menu.build_controls_from_settingsvars(general_settings)
		general_menu.setting_changed.connect(_on_setting_changed)
		vbox.add_child(general_menu)
		vbox.add_child(HSeparator.new())
	
	# Background Effect section
	var bg_label = Label.new()
	bg_label.text = "Background Effect"
	bg_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(bg_label)
	
	# Effect selection dropdown
	var dropdown_container = HBoxContainer.new()
	vbox.add_child(dropdown_container)
	
	var dropdown_label = Label.new()
	dropdown_label.text = "Effect Type"
	dropdown_container.add_child(dropdown_label)
	
	_library_effect_dropdown = OptionButton.new()
	_library_effect_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	# Populate dropdown with available effects
	var effects = LibraryBackground.get_available_effects()
	for i in range(effects.size()):
		var effect_id = effects[i]
		var display_name = LibraryBackground.get_effect_display_name(effect_id)
		_library_effect_dropdown.add_item(display_name, i)
		_library_effect_dropdown.set_item_metadata(i, effect_id)
	
	# Select current effect
	var current_effect_id = _library_appearance_config.get("effect_id", "xmb")
	for i in range(effects.size()):
		if effects[i] == current_effect_id:
			_library_effect_dropdown.select(i)
			break
	
	_library_effect_dropdown.item_selected.connect(_on_library_effect_selected)
	dropdown_container.add_child(_library_effect_dropdown)
	
	# Dynamic settings menu for the selected effect
	_library_effect_menu = SettingsMenu.new()
	vbox.add_child(_library_effect_menu)
	
	# Build initial controls for current effect
	_rebuild_library_effect_controls(current_effect_id)

func _load_library_background_config() -> void:
	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting and config_setting.value is Dictionary:
		_library_appearance_config = config_setting.value.duplicate(true)
	else:
		_library_appearance_config = {
			"effect_id": "xmb",
			"settings": {
				"time_scale": 1.0,
				"show_dust": true,
				"wave_intensity": 1.0,
				"star_threshold": 0.99
			}
		}

func _on_library_effect_selected(index: int) -> void:
	var effect_id = _library_effect_dropdown.get_item_metadata(index)
	_library_appearance_config["effect_id"] = effect_id
	
	# Reset settings to defaults for new effect
	match effect_id:
		"solid":
			_library_appearance_config["settings"] = {
				"background_color": Color(0.1, 0.1, 0.1, 1.0)
			}
		"xmb":
			_library_appearance_config["settings"] = {
				"time_scale": 1.0,
				"show_dust": true,
				"wave_intensity": 1.0,
				"star_threshold": 0.99,
				"color_top_left": Color(0.7, 0.2, 0.2, 1.0),
				"color_top_right": Color(0.4, 0.1, 0.1, 1.0),
				"color_bottom_left": Color(0.45, 0.1, 0.1, 1.0),
				"color_bottom_right": Color(0.8, 0.3, 0.5, 1.0),
				"wave_blend_color": Color.WHITE
			}
		"motes":
			_library_appearance_config["settings"] = {}
		"osdsys":
			_library_appearance_config["settings"] = {}
	
	# Save the config change
	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting:
		SettingsManager.set_setting(_library_appearance_config.duplicate(true), config_setting)
	
	# Rebuild controls
	_rebuild_library_effect_controls(effect_id)

func _rebuild_library_effect_controls(effect_id: String) -> void:
	if not _library_effect_menu:
		return
	
	_library_effect_menu.clear_controls()
	
	var schema = LibraryBackground.get_effect_schema(effect_id)
	var current_settings = _library_appearance_config.get("settings", {})
	
	# Apply current values to schema
	for setting in schema:
		if current_settings.has(setting.property_name):
			setting.value = current_settings[setting.property_name]
	
	_library_effect_menu.build_controls_from_settingsvars(schema, "Effect Settings")
	if not _library_effect_menu.setting_changed.is_connected(_on_library_effect_setting_changed):
		_library_effect_menu.setting_changed.connect(_on_library_effect_setting_changed)

func _on_library_effect_setting_changed(value: Variant, setting: SettingsVar) -> void:
	_library_appearance_config["settings"][setting.property_name] = value
	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting:
		SettingsManager.set_setting(_library_appearance_config.duplicate(true), config_setting)

# Network connection status enum (local to this view)
enum ConnectionStatus { NOT_CONFIGURED, CONNECTED, DISCONNECTED, TESTING }

func _create_connection_status_ui() -> Control:
	# Create a container to hold the indicator and test button
	var container = HBoxContainer.new()
	container.custom_minimum_size = Vector2(0, 30)
	
	# Create indicator
	var indicator = Indicator.new()
	indicator.name = "ConnectionIndicator"
	indicator.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(indicator)
	
	# Create test button
	var test_button = Button.new()
	test_button.name = "TestButton"
	test_button.text = "Test"
	container.add_child(test_button)
	
	# Connect to ready signal to set initial status after node is initialized
	container.ready.connect(func():
		_update_connection_status(indicator)
	)
	
	# Connect test button signal
	test_button.pressed.connect(func():
		_test_connection(indicator)
	)
	
	return container

func _test_connection(indicator: Indicator):
	indicator.set_status(Indicator.Status.WARNING, "Testing connection...")
	
	NetworkManager.test_connection(func(online: bool):
		if online:
			indicator.set_status(Indicator.Status.SUCCESS, "Connected and authenticated")
			NotificationManager.show_notification("Connected to RomM successfully", Notification.Type.SUCCESS)
		else:
			if not NetworkManager.is_configured():
				indicator.set_status(Indicator.Status.NEUTRAL, "Not configured (check URL, username, password)")
				NotificationManager.show_notification("RomM not configured - check URL, username, password", Notification.Type.ERROR)
			else:
				indicator.set_status(Indicator.Status.ERROR, "Connection failed - check credentials")
				NotificationManager.show_notification("Connection failed - check credentials", Notification.Type.ERROR)
	)

func _update_connection_status(indicator: Indicator):
	if NetworkManager.is_online():
		indicator.set_status(Indicator.Status.SUCCESS, "Connected and authenticated")
	elif not NetworkManager.is_configured():
		indicator.set_status(Indicator.Status.NEUTRAL, "Not configured")
	else:
		indicator.set_status(Indicator.Status.ERROR, "Disconnected")

func _on_setting_changed(value: Variant, setting: SettingsVar):
	SettingsManager.set_setting(value, setting)

func on_view_hide():
	SettingsManager.save_settings()
	super.on_view_hide()

func _on_settings_tab_changed(tab_idx: int):
	# Call on_view_show on the newly selected tab
	var tab = _settings_container.get_tab_control(tab_idx)
	if tab and tab.has_method("on_view_show"):
		tab.on_view_show()

func _input(event: InputEvent):
	# Only handle input when this view is the current active view
	if not UIManager.is_current_view(view_name):
		return
	
	# Handle platform cycle actions to navigate between settings tabs
	if event.is_action_pressed("cycle_platform_next"):
		var current_tab = _settings_container.current_tab
		var tab_count = _settings_container.get_tab_count()
		_settings_container.current_tab = (current_tab + 1) % tab_count
		_settings_container.get_tab_bar().grab_focus()
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("cycle_platform_prev"):
		var current_tab = _settings_container.current_tab
		var tab_count = _settings_container.get_tab_count()
		_settings_container.current_tab = (current_tab - 1 + tab_count) % tab_count
		_settings_container.get_tab_bar().grab_focus()
		get_viewport().set_input_as_handled()
