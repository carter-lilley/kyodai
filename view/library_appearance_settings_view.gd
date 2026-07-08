class_name LibraryAppearanceSettingsView
extends Control

## Library Appearance settings page.
## Replaces the Library Appearance tab extracted from SettingsView.
## Builds controls directly from SettingsManager and owns background effect + preset UI.

var _library_appearance_config: Dictionary = {}
var _library_effect_menu: SettingsMenu = null
var _library_effect_dropdown: M3OptionButton = null
var _effect_ids: Array[String] = []
var _library_general_menu: SettingsMenu = null

# Theme preset UI
var _preset_dropdown: M3OptionButton = null
var _current_presets: Array[ThemePreset] = []
var _is_applying_preset: bool = false
var _loaded_preset: ThemePreset = null

# Init guard: block feedback signals while building the initial UI.
var _is_initializing: bool = true

func _ready():
	_setup_ui()
	_load_library_background_config()
	_refresh_all_settings_ui()
	_is_initializing = false

func _setup_ui() -> void:
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	
	var margin = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", M3Units.dp(20))
	margin.add_theme_constant_override("margin_top", M3Units.dp(20))
	margin.add_theme_constant_override("margin_right", M3Units.dp(20))
	margin.add_theme_constant_override("margin_bottom", M3Units.dp(20))
	scroll.add_child(margin)
	
	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	margin.add_child(vbox)
	
	# Title
	var title_label = M3Label.new()
	title_label.text = "Library Appearance"
	title_label.label_style = M3Label.Style.HEADLINE_SMALL
	vbox.add_child(title_label)
	
	# General layout settings (excluding internal ones)
	_library_general_menu = SettingsMenu.new()
	vbox.add_child(_library_general_menu)
	
	# Background Effect dropdown
	_library_effect_dropdown = M3OptionButton.new()
	_library_effect_dropdown.label_text = "Background Effect"
	_library_effect_dropdown.fit_to_longest_item = false
	_library_effect_dropdown.item_selected.connect(_on_library_effect_selected)
	vbox.add_child(_library_effect_dropdown)
	
	# Dynamic settings menu for the selected effect
	_library_effect_menu = SettingsMenu.new()
	vbox.add_child(_library_effect_menu)
	
	# Theme Presets section
	_create_preset_section(vbox)
	
	# Bottom buffer
	var bottom_buffer = Control.new()
	bottom_buffer.custom_minimum_size = Vector2(0, M3Units.dp(60))
	vbox.add_child(bottom_buffer)

func _create_preset_section(vbox: VBoxContainer) -> void:
	var preset_label = M3Label.new()
	preset_label.text = "Theme Presets"
	preset_label.label_style = M3Label.Style.TITLE_MEDIUM
	vbox.add_child(preset_label)
	
	var preset_container = HBoxContainer.new()
	preset_container.custom_minimum_size = Vector2(0, M3Units.dp(30))
	vbox.add_child(preset_container)
	
	_preset_dropdown = M3OptionButton.new()
	_preset_dropdown.label_text = "Theme Preset"
	_preset_dropdown.fit_to_longest_item = false
	_preset_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_dropdown.item_selected.connect(_on_preset_selected)
	preset_container.add_child(_preset_dropdown)
	
	var load_button = M3Button.new()
	load_button.text = "Load"
	load_button.button_size = M3Button.Size.SMALL
	load_button.tooltip_text = "Import preset from file"
	load_button.pressed.connect(_on_load_preset_pressed)
	preset_container.add_child(load_button)
	
	var export_button = M3Button.new()
	export_button.text = "Export"
	export_button.button_size = M3Button.Size.SMALL
	export_button.tooltip_text = "Export current settings as preset"
	export_button.pressed.connect(_on_export_preset_pressed)
	preset_container.add_child(export_button)

func _refresh_all_settings_ui() -> void:
	_load_library_background_config()
	
	# Refresh general settings menu
	if _library_general_menu:
		_library_general_menu.clear_controls()
		var general_settings: Array[SettingsVar] = []
		var subgroups = SettingsManager.get_settings_by_subgroup()
		if subgroups.has("Library Appearance"):
			for sv in subgroups["Library Appearance"]:
				if sv.state != SettingsVar.SettingState.INTERNAL:
					general_settings.append(sv)
		if general_settings.size() > 0:
			_library_general_menu.build_controls_from_settingsvars(general_settings)
			if not _library_general_menu.setting_changed.is_connected(_on_setting_changed):
				_library_general_menu.setting_changed.connect(_on_setting_changed)
	
	# Refresh background effect dropdown
	if _library_effect_dropdown:
		_library_effect_dropdown.clear_items()
		_effect_ids.clear()
		var effects = LibraryBackground.get_available_effects()
		for i in range(effects.size()):
			var effect_id = effects[i]
			var display_name = LibraryBackground.get_effect_display_name(effect_id)
			_library_effect_dropdown.add_item(display_name, i)
			_effect_ids.append(effect_id)
		
		var current_effect_id = _library_appearance_config.get("effect_id", "gradient")
		for i in range(effects.size()):
			if effects[i] == current_effect_id:
				_library_effect_dropdown.selected = i
				break
		_rebuild_library_effect_controls(current_effect_id)
	
	# Refresh preset dropdown
	_refresh_preset_dropdown()

func _on_setting_changed(value: Variant, setting: SettingsVar) -> void:
	if _is_initializing:
		return
	SettingsManager.set_setting(value, setting)

func _load_library_background_config() -> void:
	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting and config_setting.value is Dictionary:
		_library_appearance_config = config_setting.value.duplicate(true)
	else:
		var default_gradient = Gradient.new()
		default_gradient.offsets = [0.0, 1.0]
		default_gradient.colors = [Color(0.1, 0.1, 0.15), Color(0.05, 0.05, 0.08)]
		_library_appearance_config = {
			"effect_id": "gradient",
			"settings": {
				"background_gradient": default_gradient,
				"gradient_direction": 0
			}
		}

func _on_library_effect_selected(index: int) -> void:
	if _is_initializing:
		return
	
	var effect_id = _effect_ids[index] if index >= 0 and index < _effect_ids.size() else ""
	_library_appearance_config["effect_id"] = effect_id
	
	match effect_id:
		"none":
			_library_appearance_config["settings"] = {}
		"gradient":
			var default_gradient = Gradient.new()
			default_gradient.offsets = [0.0, 1.0]
			default_gradient.colors = [Color(0.1, 0.1, 0.15), Color(0.05, 0.05, 0.08)]
			_library_appearance_config["settings"] = {
				"background_gradient": default_gradient,
				"gradient_direction": 0
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
		"xmb_classic":
			_library_appearance_config["settings"] = {
				"wave_color": Color(0.04, 0.69, 0.87, 1.0),
				"time_scale": 1.0,
				"frequency": 4.29,
				"outer_amplitude": 0.5,
				"inner_amplitude": 0.18,
				"outer_speed": 0.044,
				"inner_speed": 0.064
			}
		"motes":
			_library_appearance_config["settings"] = {}
		"osdsys":
			_library_appearance_config["settings"] = {}
		"cafeos":
			_library_appearance_config["settings"] = {
				"time_scale": 0.5,
				"orbit_radius": 2.358,
				"icon_scale": 0.7,
				"orbit_speed": 0.15,
				"num_icons": 21,
				"background_color": Color(0.05, 0.08, 0.18, 1.0)
			}
	
	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting:
		SettingsManager.set_setting(_library_appearance_config.duplicate(true), config_setting)
	
	_rebuild_library_effect_controls(effect_id)

func _rebuild_library_effect_controls(effect_id: String) -> void:
	if not _library_effect_menu:
		return
	
	_library_effect_menu.clear_controls()
	
	var schema = LibraryBackground.get_effect_schema(effect_id)
	var current_settings = _library_appearance_config.get("settings", {})
	
	for setting in schema:
		if current_settings.has(setting.property_name):
			setting.value = current_settings[setting.property_name]
	
	_library_effect_menu.build_controls_from_settingsvars(schema, "Effect Settings")
	if not _library_effect_menu.setting_changed.is_connected(_on_library_effect_setting_changed):
		_library_effect_menu.setting_changed.connect(_on_library_effect_setting_changed)

func _on_library_effect_setting_changed(value: Variant, setting: SettingsVar) -> void:
	if _is_initializing:
		return
	_library_appearance_config["settings"][setting.property_name] = value
	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting:
		SettingsManager.set_setting(_library_appearance_config.duplicate(true), config_setting)

func _refresh_preset_dropdown() -> void:
	if not _preset_dropdown:
		return
	
	_preset_dropdown.clear_items()
	_preset_dropdown.add_item("New Theme...", 0)
	
	_current_presets = SettingsManager.list_presets()
	for i in range(_current_presets.size()):
		var preset = _current_presets[i]
		_preset_dropdown.add_item(preset.get_display_name(), i + 1)
	
	_check_preset_match()

func _on_preset_selected(index: int) -> void:
	if _is_applying_preset or index <= 0 or index > _current_presets.size():
		return
	
	var preset = _current_presets[index - 1] as ThemePreset
	if not preset:
		return
	
	UIManager.show_confirm("Load Theme Preset", "Load preset '%s'?\n\nThis will overwrite your current library and card settings." % preset.name,
		func(): _apply_preset(preset),
		Callable(),
		func(): _preset_dropdown.selected = 0,
		{"cancel_text": "Cancel", "accept_text": "Load"}
	)

func _apply_preset(preset: ThemePreset) -> void:
	_is_applying_preset = true
	
	var success = SettingsManager.apply_preset(preset)
	if success:
		_loaded_preset = preset
		NotificationManager.show_notification("Applied preset: %s" % preset.name, NotificationManager.Type.SUCCESS)
		_refresh_all_settings_ui()
		_update_preset_dropdown_for_loaded_preset()
	else:
		NotificationManager.show_notification("Failed to apply preset", NotificationManager.Type.ERROR)
		_preset_dropdown.selected = 0
	
	_is_applying_preset = false

func _update_preset_dropdown_for_loaded_preset() -> void:
	if not _preset_dropdown or not _loaded_preset:
		return
	
	for i in range(_current_presets.size()):
		var preset = _current_presets[i] as ThemePreset
		if preset and preset.name == _loaded_preset.name:
			_preset_dropdown.selected = i + 1
			return
	
	_preset_dropdown.selected = 0

func _check_preset_match() -> void:
	if not _preset_dropdown:
		return
	
	if not _loaded_preset:
		if _preset_dropdown.get_item_count() > 0:
			_preset_dropdown.selected = 0
		return
	
	var current_preset = SettingsManager.create_preset_from_current()
	var is_match = _presets_equal(current_preset, _loaded_preset)
	
	if is_match:
		_update_preset_dropdown_for_loaded_preset()
	else:
		if _preset_dropdown.get_item_count() > 0:
			_preset_dropdown.selected = 0

func _presets_equal(a: ThemePreset, b: ThemePreset) -> bool:
	if a.library_layout_mode != b.library_layout_mode:
		return false
	if a.library_focus_scale != b.library_focus_scale:
		return false
	if a.library_navigation_type != b.library_navigation_type:
		return false
	if a.library_grid_padding != b.library_grid_padding:
		return false
	if a.library_card_zoom != b.library_card_zoom:
		return false
	if a.library_show_title_mode != b.library_show_title_mode:
		return false
	if a.library_card_display_mode != b.library_card_display_mode:
		return false
	if a.library_card_content_alignment != b.library_card_content_alignment:
		return false
	if a.library_grid_vertical != b.library_grid_vertical:
		return false
	if a.card_media_aspect_ratio != b.card_media_aspect_ratio:
		return false
	if a.library_primary_color != b.library_primary_color:
		return false
	if a.dark_mode != b.dark_mode:
		return false
	
	var card_a = JSON.stringify(a.card_effect_config)
	var card_b = JSON.stringify(b.card_effect_config)
	if card_a != card_b:
		return false
	
	var bg_a = JSON.stringify(a.library_background_config)
	var bg_b = JSON.stringify(b.library_background_config)
	if bg_a != bg_b:
		return false
	
	return true

func _on_load_preset_pressed() -> void:
	UIManager.show_file_dialog("Import Theme Preset", PackedStringArray(["*.tres ; Theme Preset Files"]), "", func(path: String):
		var imported = SettingsManager.import_preset(path)
		if imported:
			NotificationManager.show_notification("Imported preset: %s" % imported.name, NotificationManager.Type.SUCCESS)
			_refresh_preset_dropdown()
			UIManager.show_confirm("Apply Imported Preset", "Apply the imported preset '%s' now?" % imported.name,
				func(): _apply_preset(imported),
				Callable(),
				func(): _preset_dropdown.selected = 0,
				{"cancel_text": "Cancel", "accept_text": "Apply"}
			)
		else:
			NotificationManager.show_notification("Failed to import preset", NotificationManager.Type.ERROR)
	, false)

func _on_export_preset_pressed() -> void:
	if not SettingsManager.settings:
		return
	
	var preset = SettingsManager.create_preset_from_current()
	
	UIManager.show_custom_dialog(func(dialog: M3Dialog):
		dialog.title_text = "Export Theme Preset"
		dialog.body_text = "Enter a name for this preset:"
		
		var line_edit = M3TextField.new()
		line_edit.label_text = "Preset Name"
		line_edit.text = preset.name
		line_edit.placeholder_text = "Preset Name"
		line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dialog.content_slot.add_child(line_edit)
		
		dialog.add_action("Cancel", Callable(), false)
		dialog.add_action("Save", func():
			if line_edit.text.is_empty():
				NotificationManager.show_notification("Preset name cannot be empty", NotificationManager.Type.WARNING)
				return
			
			preset.name = line_edit.text
			preset.created_at = Time.get_datetime_string_from_system()
			
			var success = SettingsManager.save_preset(preset)
			if success:
				NotificationManager.show_notification("Saved preset: %s" % preset.name, NotificationManager.Type.SUCCESS)
				_refresh_preset_dropdown()
			else:
				NotificationManager.show_notification("Failed to save preset", NotificationManager.Type.ERROR)
		, true)
	, func(): _preset_dropdown.selected = 0)

func refresh_values() -> void:
	_refresh_all_settings_ui()
