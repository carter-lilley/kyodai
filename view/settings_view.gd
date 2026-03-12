class_name SettingsView
extends View

var _settings_container: TabContainer

# Library Appearance tab specific
var _library_appearance_config: Dictionary = {}
var _library_effect_menu: SettingsMenu = null
var _library_effect_dropdown: OptionButton = null
var _library_general_menu: SettingsMenu = null  # Store reference to general settings menu
var _library_gradient_menu: SettingsMenu = null  # Store reference to gradient settings menu

# Theme preset UI
var _preset_dropdown: OptionButton = null
var _current_presets: Array[ThemePreset] = []
var _is_applying_preset: bool = false
var _loaded_preset: ThemePreset = null

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
	
	# Add Hero Designer tab
	var hero_designer_tab = _create_hero_designer_tab()
	_settings_container.add_child(hero_designer_tab)
	_settings_container.set_tab_title(_settings_container.get_tab_count() - 1, "Hero Designer")
	
	# Add GameNative tab (Android only)
	if PlatformManager.is_android():
		var gamenative_tab = _create_gamenative_tab()
		_settings_container.add_child(gamenative_tab)
		_settings_container.set_tab_title(_settings_container.get_tab_count() - 1, "GameNative")

func _create_card_designer_tab() -> Control:
	var designer = preload("res://view/card_designer_view.tscn").instantiate()
	designer.set_anchors_preset(Control.PRESET_FULL_RECT)
	return designer

func _create_hero_designer_tab() -> Control:
	var designer = preload("res://view/designer/hero_designer_view.tscn").instantiate()
	designer.set_anchors_preset(Control.PRESET_FULL_RECT)
	return designer

func _create_platforms_tab() -> Control:
	var platforms_view = preload("res://view/platforms_settings_view.gd").new()
	return platforms_view

func _create_gamenative_tab() -> Control:
	var gamenative_view = preload("res://view/settings/gamenative_settings_view.gd").new()
	return gamenative_view

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
		_library_general_menu = general_menu  # Store reference
		vbox.add_child(HSeparator.new())
	
	# Background Gradient section (global, applies to all effects)
	var bg_gradient_label = Label.new()
	bg_gradient_label.text = "Background Gradient"
	bg_gradient_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(bg_gradient_label)
	
	_library_gradient_menu = SettingsMenu.new()
	var gradient_schema = LibraryBackground.get_background_gradient_schema()
	
	# Apply current values to schema
	for setting in gradient_schema:
		if setting.property_name == "background_gradient":
			var gradient_data = _library_appearance_config.get("background_gradient")
			if gradient_data is Gradient:
				setting.value = gradient_data
		elif setting.property_name == "gradient_direction":
			setting.value = _library_appearance_config.get("gradient_direction", 0)
	
	_library_gradient_menu.build_controls_from_settingsvars(gradient_schema, "Gradient Settings")
	_library_gradient_menu.setting_changed.connect(_on_library_gradient_setting_changed)
	vbox.add_child(_library_gradient_menu)
	
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
	
	vbox.add_child(HSeparator.new())
	
	# Theme Presets section
	_create_preset_section(vbox)

func _create_preset_section(vbox: VBoxContainer) -> void:
	var preset_label = Label.new()
	preset_label.text = "Theme Presets"
	preset_label.add_theme_font_size_override("font_size", 14)
	vbox.add_child(preset_label)
	
	# Preset dropdown and buttons container
	var preset_container = HBoxContainer.new()
	preset_container.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(preset_container)
	
	# Preset dropdown
	_preset_dropdown = OptionButton.new()
	_preset_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_dropdown.text = "Select Preset..."
	_preset_dropdown.item_selected.connect(_on_preset_selected)
	preset_container.add_child(_preset_dropdown)
	
	# Load button (opens file dialog)
	var load_button = Button.new()
	load_button.text = "Load"
	load_button.tooltip_text = "Import preset from file"
	load_button.pressed.connect(_on_load_preset_pressed)
	preset_container.add_child(load_button)
	
	# Export button
	var export_button = Button.new()
	export_button.text = "Export"
	export_button.tooltip_text = "Export current settings as preset"
	export_button.pressed.connect(_on_export_preset_pressed)
	preset_container.add_child(export_button)
	
	# Refresh preset list
	_refresh_preset_dropdown()

func _refresh_preset_dropdown() -> void:
	if not _preset_dropdown:
		return
	
	_preset_dropdown.clear()
	_preset_dropdown.add_item("New Theme...", -1)
	_preset_dropdown.set_item_disabled(0, false)
	
	_current_presets = SettingsManager.list_presets()
	for i in range(_current_presets.size()):
		var preset = _current_presets[i]
		_preset_dropdown.add_item(preset.get_display_name(), i)
		_preset_dropdown.set_item_metadata(i + 1, preset)
	
	# Check if current settings match any preset
	_check_preset_match()

func _on_preset_selected(index: int) -> void:
	if _is_applying_preset or index <= 0:
		return
	
	var preset = _preset_dropdown.get_item_metadata(index) as ThemePreset
	if not preset:
		return
	
	# Show confirmation dialog
	var dialog = ConfirmationDialog.new()
	dialog.title = "Load Theme Preset"
	dialog.dialog_text = "Load preset '%s'?\n\nThis will overwrite your current library and card settings." % preset.name
	dialog.get_ok_button().text = "Load"
	dialog.confirmed.connect(func():
		_apply_preset(preset)
	)
	dialog.canceled.connect(func():
		# Reset dropdown to "Select Preset..."
		_preset_dropdown.select(0)
	)
	add_child(dialog)
	dialog.popup_centered()

func _apply_preset(preset: ThemePreset) -> void:
	_is_applying_preset = true
	
	var success = SettingsManager.apply_preset(preset)
	if success:
		_loaded_preset = preset
		NotificationManager.show_notification("Applied preset: %s" % preset.name, Notification.Type.SUCCESS)
		
		# Refresh all UI to reflect new settings
		_refresh_all_settings_ui()
		
		# Update dropdown to show loaded preset
		_update_preset_dropdown_for_loaded_preset()
	else:
		NotificationManager.show_notification("Failed to apply preset", Notification.Type.ERROR)
		_preset_dropdown.select(0)
	
	_is_applying_preset = false

func _update_preset_dropdown_for_loaded_preset() -> void:
	if not _preset_dropdown or not _loaded_preset:
		return
	
	# Find the loaded preset in the dropdown and select it
	for i in range(_preset_dropdown.get_item_count()):
		if i == 0:
			continue
		var preset = _preset_dropdown.get_item_metadata(i) as ThemePreset
		if preset and preset.name == _loaded_preset.name:
			_preset_dropdown.select(i)
			return
	
	# If not found, select "Select Preset..."
	_preset_dropdown.select(0)

func _check_preset_match() -> void:
	if not _preset_dropdown:
		return
	
	# If no preset is loaded, ensure we show "New Theme..."
	if not _loaded_preset:
		if _preset_dropdown.get_item_count() > 0:
			_preset_dropdown.set_item_text(0, "New Theme...")
			_preset_dropdown.set_item_disabled(0, false)
			_preset_dropdown.select(0)
		return
	
	# Check if current settings match the loaded preset
	var current_preset = ThemePreset.from_current_settings(SettingsManager.settings)
	var is_match = _presets_equal(current_preset, _loaded_preset)
	
	if is_match:
		# Settings match loaded preset, show preset name
		_update_preset_dropdown_for_loaded_preset()
	else:
		# Settings deviated, show "New Theme..."
		if _preset_dropdown.get_item_count() > 0:
			_preset_dropdown.set_item_text(0, "New Theme...")
			_preset_dropdown.set_item_disabled(0, false)
			_preset_dropdown.select(0)

func _presets_equal(a: ThemePreset, b: ThemePreset) -> bool:
	# Compare all relevant fields
	if a.library_hero_layout_height != b.library_hero_layout_height:
		return false
	if a.library_vertical_layout != b.library_vertical_layout:
		return false
	if a.library_navigation_bar_position != b.library_navigation_bar_position:
		return false
	if a.library_grid_padding != b.library_grid_padding:
		return false
	if a.library_grid_margin_x != b.library_grid_margin_x:
		return false
	if a.library_grid_margin_y != b.library_grid_margin_y:
		return false
	if a.library_card_zoom != b.library_card_zoom:
		return false
	if a.library_bar_color != b.library_bar_color:
		return false
	if a.library_icon_color != b.library_icon_color:
		return false
	
	# Compare dictionaries using JSON stringify for reliable comparison
	var card_a = JSON.stringify(a.card_effect_config)
	var card_b = JSON.stringify(b.card_effect_config)
	if card_a != card_b:
		return false
	
	var bg_a = JSON.stringify(a.library_background_config)
	var bg_b = JSON.stringify(b.library_background_config)
	if bg_a != bg_b:
		return false
	
	return true

func _refresh_all_settings_ui() -> void:
	# Refresh library appearance UI
	_load_library_background_config()
	
	# Refresh the general settings menu
	if _library_general_menu:
		_library_general_menu.clear_controls()
		
		# Get fresh settings from SettingsManager
		var general_settings: Array[SettingsVar] = []
		var subgroups = SettingsManager.get_settings_by_subgroup()
		if subgroups.has("Library Appearance"):
			for sv in subgroups["Library Appearance"]:
				if sv.state != SettingsVar.SettingState.INTERNAL:
					general_settings.append(sv)
		
		if general_settings.size() > 0:
			_library_general_menu.build_controls_from_settingsvars(general_settings)
	
	if _library_effect_dropdown:
		var current_effect_id = _library_appearance_config.get("effect_id", "xmb")
		var effects = LibraryBackground.get_available_effects()
		for i in range(effects.size()):
			if effects[i] == current_effect_id:
				_library_effect_dropdown.select(i)
				break
		_rebuild_library_effect_controls(current_effect_id)
	
	# Refresh background gradient menu
	if _library_gradient_menu:
		_library_gradient_menu.clear_controls()
		var gradient_schema = LibraryBackground.get_background_gradient_schema()
		
		# Apply current values to schema
		for setting in gradient_schema:
			if setting.property_name == "background_gradient":
				var gradient_data = _library_appearance_config.get("background_gradient")
				if gradient_data is Gradient:
					setting.value = gradient_data
			elif setting.property_name == "gradient_direction":
				setting.value = _library_appearance_config.get("gradient_direction", 0)
		
		_library_gradient_menu.build_controls_from_settingsvars(gradient_schema, "Gradient Settings")
	
	# Notify other views that settings changed
	# Emit setting_changed for card_effect_config so LibraryView and HomeView rebuild their cards
	var card_effect_setting = SettingsManager.get_setting("card_effect_config")
	if card_effect_setting:
		SettingsManager.setting_changed.emit(card_effect_setting.value, card_effect_setting)
	
	SettingsManager.settings_saved.emit()

func _on_load_preset_pressed() -> void:
	var file_dialog = FileDialog.new()
	file_dialog.title = "Import Theme Preset"
	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
	file_dialog.filters = PackedStringArray(["*.tres ; Theme Preset Files"])
	
	file_dialog.file_selected.connect(func(path: String):
		var preset = SettingsManager.import_preset(path)
		if preset:
			NotificationManager.show_notification("Imported preset: %s" % preset.name, Notification.Type.SUCCESS)
			_refresh_preset_dropdown()
			
			# Auto-apply the imported preset with confirmation
			var dialog = ConfirmationDialog.new()
			dialog.title = "Apply Imported Preset"
			dialog.dialog_text = "Apply the imported preset '%s' now?" % preset.name
			dialog.get_ok_button().text = "Apply"
			dialog.confirmed.connect(func():
				_apply_preset(preset)
			)
			add_child(dialog)
			dialog.popup_centered()
		else:
			NotificationManager.show_notification("Failed to import preset", Notification.Type.ERROR)
	)
	
	add_child(file_dialog)
	file_dialog.popup_centered(Vector2(800, 600))

func _on_export_preset_pressed() -> void:
	if not SettingsManager.settings:
		return
	
	var preset = ThemePreset.from_current_settings(SettingsManager.settings)
	
	# Ask for preset name
	var name_dialog = ConfirmationDialog.new()
	name_dialog.title = "Export Theme Preset"
	name_dialog.dialog_text = "Enter a name for this preset:"
	name_dialog.get_ok_button().text = "Save"
	
	var line_edit = LineEdit.new()
	line_edit.text = preset.name
	line_edit.placeholder_text = "Preset Name"
	line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_dialog.add_child(line_edit)
	
	name_dialog.confirmed.connect(func():
		if line_edit.text.is_empty():
			NotificationManager.show_notification("Preset name cannot be empty", Notification.Type.WARNING)
			return
		
		preset.name = line_edit.text
		preset.created_at = Time.get_datetime_string_from_system()
		
		# Save directly to internal presets folder
		var success = SettingsManager.save_preset(preset)
		if success:
			NotificationManager.show_notification("Saved preset: %s" % preset.name, Notification.Type.SUCCESS)
			_refresh_preset_dropdown()
		else:
			NotificationManager.show_notification("Failed to save preset", Notification.Type.ERROR)
	)
	
	add_child(name_dialog)
	name_dialog.popup_centered()

func _load_library_background_config() -> void:
	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting and config_setting.value is Dictionary:
		_library_appearance_config = config_setting.value.duplicate(true)
	else:
		var default_gradient = Gradient.new()
		default_gradient.offsets = [0.0, 1.0]
		default_gradient.colors = [Color(0.1, 0.1, 0.15), Color(0.05, 0.05, 0.08)]
		
		_library_appearance_config = {
			"effect_id": "xmb",
			"background_gradient": default_gradient,
			"gradient_direction": 0,
			"settings": {
				"time_scale": 1.0,
				"show_dust": true,
				"wave_intensity": 1.0,
				"star_threshold": 0.99
			}
		}

func _on_library_gradient_setting_changed(value: Variant, setting: SettingsVar) -> void:
	_library_appearance_config[setting.property_name] = value
	
	# Save the config change
	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting:
		SettingsManager.set_setting(_library_appearance_config.duplicate(true), config_setting)

func _on_library_effect_selected(index: int) -> void:
	var effect_id = _library_effect_dropdown.get_item_metadata(index)
	_library_appearance_config["effect_id"] = effect_id
	
	# Reset settings to defaults for new effect
	match effect_id:
		"none":
			_library_appearance_config["settings"] = {}
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

func _on_any_setting_changed(value: Variant, setting: SettingsVar):
	# Check if settings now deviate from loaded preset
	if not _is_applying_preset:
		_check_preset_match()

func on_view_show():
	super.on_view_show()
	# Ensure signal is connected when view is shown
	if not SettingsManager.setting_changed.is_connected(_on_any_setting_changed):
		SettingsManager.setting_changed.connect(_on_any_setting_changed)

func on_view_hide():
	# First, trigger on_view_hide on all child tabs (especially Card Designer to save settings)
	for i in range(_settings_container.get_tab_count()):
		var tab = _settings_container.get_tab_control(i)
		if tab and tab.has_method("on_view_hide"):
			tab.on_view_hide()
	
	SettingsManager.save_settings()
	# Disconnect signal to prevent callbacks on freed object
	if SettingsManager.setting_changed.is_connected(_on_any_setting_changed):
		SettingsManager.setting_changed.disconnect(_on_any_setting_changed)
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
