class_name CardDesignerView
extends Control

var _card_state: CardState = CardState.new()
var _current_config: Dictionary = {}

var _preview_card: GameCard
var _effects_list: VBoxContainer
var _add_effect_button: MenuButton
var _orientation_btn: OptionButton
var _corner_slider: HSlider
var _left_scroll: ScrollContainer

# Maps dropdown IDs to effect IDs for filtering active effects
const EFFECT_ID_MAP: Dictionary = {
	0: "border",
	1: "badge",
	2: "drop_shadow",
	3: "glow",
	4: "glass",
	5: "distort",
	6: "gradient_overlay"
}

func _ready():
	_setup_ui()
	_load_current_config()
	call_deferred("_setup_preview_card")
	call_deferred("_rebuild_effects_ui")
	
	# Connect to settings changes so we refresh when a preset is applied
	if SettingsManager:
		SettingsManager.settings_saved.connect(_on_settings_saved)
	
	# Connect to viewport focus changes to ensure focused items are visible
	get_viewport().gui_focus_changed.connect(_on_focus_changed)

func _on_settings_saved():
	_load_current_config()
	_rebuild_effects_ui()
	_setup_preview_card()

func _exit_tree():
	# Disconnect signal to prevent callbacks on freed object
	if SettingsManager and SettingsManager.settings_saved.is_connected(_on_settings_saved):
		SettingsManager.settings_saved.disconnect(_on_settings_saved)

func on_view_hide():
	# Don't save here - the Card Designer reloads from SettingsManager when shown
	# This prevents stale internal config from overwriting preset changes
	pass

func on_view_show():
	# Reload config from SettingsManager to ensure we have latest (including preset changes)
	_load_current_config()
	_rebuild_effects_ui()
	_setup_preview_card()

func _setup_ui():
	var hsplit = HSplitContainer.new()
	hsplit.set_anchors_preset(Control.PRESET_FULL_RECT)
	hsplit.split_offset = 300
	add_child(hsplit)
	
	var left_panel = Panel.new()
	left_panel.custom_minimum_size = Vector2(300, 0)
	hsplit.add_child(left_panel)
	
	_left_scroll = ScrollContainer.new()
	_left_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_left_scroll.follow_focus = true
	left_panel.add_child(_left_scroll)
	
	var left_vbox = VBoxContainer.new()
	_left_scroll.add_child(left_vbox)
	
	var title_label = Label.new()
	title_label.text = "Card Designer"
	title_label.add_theme_font_size_override("font_size", 24)
	left_vbox.add_child(title_label)
	
	var subtitle_label = Label.new()
	subtitle_label.text = "Customize card appearance"
	subtitle_label.add_theme_font_size_override("font_size", 12)
	left_vbox.add_child(subtitle_label)
	
	left_vbox.add_child(HSeparator.new())
	
	var global_label = Label.new()
	global_label.text = "Global Settings"
	global_label.add_theme_font_size_override("font_size", 16)
	left_vbox.add_child(global_label)
	
	var orient_label = Label.new()
	orient_label.text = "Card Orientation"
	left_vbox.add_child(orient_label)
	
	_orientation_btn = OptionButton.new()
	_orientation_btn.add_item("Vertical", 0)
	_orientation_btn.add_item("Horizontal", 1)
	_orientation_btn.add_item("Square", 2)
	_orientation_btn.item_selected.connect(_on_orientation_changed)
	left_vbox.add_child(_orientation_btn)
	
	var corner_label = Label.new()
	corner_label.text = "Corner Radius (0-1)"
	left_vbox.add_child(corner_label)
	
	_corner_slider = HSlider.new()
	_corner_slider.min_value = 0.0
	_corner_slider.max_value = 1.0
	_corner_slider.step = 0.01
	_corner_slider.value = 0.06
	_corner_slider.value_changed.connect(_on_corner_radius_changed)
	left_vbox.add_child(_corner_slider)
	
	left_vbox.add_child(HSeparator.new())
	
	var effects_label = Label.new()
	effects_label.text = "Effects"
	effects_label.add_theme_font_size_override("font_size", 16)
	left_vbox.add_child(effects_label)
	
	_effects_list = VBoxContainer.new()
	left_vbox.add_child(_effects_list)
	
	_add_effect_button = MenuButton.new()
	_add_effect_button.text = "Add Effect"
	left_vbox.add_child(_add_effect_button)
	
	var popup = _add_effect_button.get_popup()
	popup.id_pressed.connect(_on_add_effect)
	# Dropdown will be populated in _rebuild_add_effect_dropdown based on active effects
	
	left_vbox.add_child(HSeparator.new())
	
	var right_panel = Panel.new()
	hsplit.add_child(right_panel)
	
	# Add library background to show cards in context
	var library_bg = preload("res://components/library_background.tscn").instantiate()
	library_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	right_panel.add_child(library_bg)
	
	var preview_container = CenterContainer.new()
	preview_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	right_panel.add_child(preview_container)
	
	_preview_card = preload("res://components/game_card.tscn").instantiate()
	_preview_card.preview_mode = true
	_preview_card.focus_mode = Control.FOCUS_NONE
	preview_container.add_child(_preview_card)

func _load_current_config():
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			_current_config = config_setting.value.duplicate(true)
			# Debug: print all gradient points in loaded config
			for i in range(_current_config.get("effects", []).size()):
				var effect = _current_config["effects"][i]
				var settings = effect.get("settings", {})
				for key in settings.keys():
					if settings[key] is Gradient:
						var grad = settings[key]
						var points_str = ""
						for j in range(grad.get_point_count()):
							points_str += "(" + str(grad.get_offset(j)) + ":" + str(grad.get_color(j)) + ") "
						print("[CardDesigner] Effect ", i, " - ", key, " points: ", points_str)
		else:
			_current_config = _get_default_config()
	else:
		_current_config = _get_default_config()
	
	_orientation_btn.select(_current_config.get("card_orientation", 0))
	_corner_slider.value = _current_config.get("corner_radius", 0.06)
	
	_card_state.orientation = _current_config.get("card_orientation", 0)
	# Corner radius is now 0.0-1.0 ratio directly
	_card_state.corner_radius_ratio = _current_config.get("corner_radius", 0.06)
	_card_state.effect_settings = _current_config.get("effects", [])

func _get_default_config() -> Dictionary:
	return {
		"effects": [],
		"card_orientation": 0,
		"corner_radius": 0.06
	}

func _setup_preview_card():
	if not _preview_card or not is_instance_valid(_preview_card):
		return
	
	var state = CardState.new()
	state.orientation = _current_config.get("card_orientation", 0)
	# Corner radius is now 0.0-1.0 ratio directly
	state.corner_radius_ratio = _current_config.get("corner_radius", 0.06)
	state.effect_settings = _current_config.get("effects", []).duplicate(true)
	state.zoom_level = 1.5
	
	_preview_card.set_card_state(state)

func _rebuild_effects_ui():
	# Save collapsed states before rebuilding
	var collapsed_states: Dictionary = {}
	for child in _effects_list.get_children():
		if child is CollapsableVBoxContainer:
			collapsed_states[child.title] = child.collapsed
	
	for child in _effects_list.get_children():
		child.queue_free()
	
	var effects = _current_config.get("effects", [])
	for i in range(effects.size()):
		var effect_data = effects[i]
		_create_effect_ui(effect_data, i)
	
	# Restore collapsed states after rebuilding
	for child in _effects_list.get_children():
		if child is CollapsableVBoxContainer and collapsed_states.has(child.title):
			child.collapsed = collapsed_states[child.title]
	
	# Update the Add Effect dropdown to only show inactive effects
	_rebuild_add_effect_dropdown()

func _rebuild_add_effect_dropdown() -> void:
	"""Rebuild the Add Effect dropdown to only show effects that aren't already active."""
	if not _add_effect_button:
		return
	
	var popup = _add_effect_button.get_popup()
	popup.clear()
	
	# Get list of currently active effect IDs
	var active_effects: Array[String] = []
	var effects = _current_config.get("effects", [])
	for effect in effects:
		var effect_id = effect.get("effect_id", "")
		if effect_id:
			active_effects.append(effect_id)
	
	# Add only inactive effects to the dropdown
	var has_available_effects = false
	for id in EFFECT_ID_MAP.keys():
		var effect_id = EFFECT_ID_MAP[id]
		if not effect_id in active_effects:
			var display_name = effect_id.replace("_", " ").capitalize()
			popup.add_item(display_name, id)
			has_available_effects = true
	
	# Disable button if all effects are active
	_add_effect_button.disabled = not has_available_effects
	if not has_available_effects:
		_add_effect_button.text = "All Effects Added"
	else:
		_add_effect_button.text = "Add Effect"

func _create_effect_ui(effect_data: Dictionary, index: int) -> void:
	var container = CollapsableVBoxContainer.new()
	container.title = effect_data.get("effect_id", "Unknown").capitalize()
	container.collapsed = false  # Start expanded
	_effects_list.add_child(container)
	
	var remove_btn = Button.new()
	remove_btn.text = "X"
	remove_btn.pressed.connect(func(): _on_remove_effect(index))
	container.add_header_button(remove_btn)
	
	var content = container.get_content_container()
	
	if effect_data.get("effect_id") == "border":
		var border_effect = BorderEffect.new()
		var schema = border_effect.get_settings_schema()
		border_effect.queue_free()
		
		var settings_menu = SettingsMenu.new()
		content.add_child(settings_menu)
		
		var current_settings = effect_data.get("settings", {})
		for setting in schema:
			if current_settings.has(setting.property_name):
				var saved_value = current_settings[setting.property_name]
				if saved_value is Gradient:
					setting.value = saved_value
				else:
					setting.value = saved_value
		
		settings_menu.build_controls_from_settingsvars(schema, "Settings")
		settings_menu.setting_changed.connect(func(value, setting): _on_effect_setting_changed(index, setting.property_name, value))
	
	elif effect_data.get("effect_id") == "badge":
		var badge_effect = BadgeEffect.new()
		var schema = badge_effect.get_settings_schema()
		badge_effect.queue_free()
		
		var settings_menu = SettingsMenu.new()
		content.add_child(settings_menu)
		
		var current_settings = effect_data.get("settings", {})
		for setting in schema:
			if current_settings.has(setting.property_name):
				setting.value = current_settings[setting.property_name]
		
		settings_menu.build_controls_from_settingsvars(schema, "Settings")
		settings_menu.setting_changed.connect(func(value, setting): _on_effect_setting_changed(index, setting.property_name, value))
	
	elif effect_data.get("effect_id") == "drop_shadow":
		var drop_shadow_effect = DropShadowEffect.new()
		var schema = drop_shadow_effect.get_settings_schema()
		drop_shadow_effect.queue_free()
		
		var settings_menu = SettingsMenu.new()
		content.add_child(settings_menu)
		
		var current_settings = effect_data.get("settings", {})
		for setting in schema:
			if current_settings.has(setting.property_name):
				setting.value = current_settings[setting.property_name]
		
		settings_menu.build_controls_from_settingsvars(schema, "Settings")
		settings_menu.setting_changed.connect(func(value, setting): _on_effect_setting_changed(index, setting.property_name, value))
	
	elif effect_data.get("effect_id") == "glow":
		var glow_effect = GlowEffect.new()
		var schema = glow_effect.get_settings_schema()
		glow_effect.queue_free()
		
		var settings_menu = SettingsMenu.new()
		content.add_child(settings_menu)
		
		var current_settings = effect_data.get("settings", {})
		for setting in schema:
			if current_settings.has(setting.property_name):
				setting.value = current_settings[setting.property_name]
		
		settings_menu.build_controls_from_settingsvars(schema, "Settings")
		settings_menu.setting_changed.connect(func(value, setting): _on_effect_setting_changed(index, setting.property_name, value))
	
	elif effect_data.get("effect_id") == "distort":
		var distort_effect = DistortEffect.new()
		var schema = distort_effect.get_settings_schema()
		distort_effect.queue_free()
		
		var settings_menu = SettingsMenu.new()
		content.add_child(settings_menu)
		
		var current_settings = effect_data.get("settings", {})
		for setting in schema:
			if current_settings.has(setting.property_name):
				setting.value = current_settings[setting.property_name]
		
		settings_menu.build_controls_from_settingsvars(schema, "Settings")
		settings_menu.setting_changed.connect(func(value, setting): _on_effect_setting_changed(index, setting.property_name, value))
	
	elif effect_data.get("effect_id") == "glass":
		var glass_effect = GlassEffect.new()
		var schema = glass_effect.get_settings_schema()
		glass_effect.queue_free()
		
		var settings_menu = SettingsMenu.new()
		content.add_child(settings_menu)
		
		var current_settings = effect_data.get("settings", {})
		for setting in schema:
			if current_settings.has(setting.property_name):
				setting.value = current_settings[setting.property_name]
		
		settings_menu.build_controls_from_settingsvars(schema, "Settings")
		settings_menu.setting_changed.connect(func(value, setting): _on_effect_setting_changed(index, setting.property_name, value))
	
	elif effect_data.get("effect_id") == "gradient_overlay":
		var gradient_overlay_effect = GradientOverlayEffect.new()
		var schema = gradient_overlay_effect.get_settings_schema()
		gradient_overlay_effect.queue_free()
		
		var settings_menu = SettingsMenu.new()
		content.add_child(settings_menu)
		
		var current_settings = effect_data.get("settings", {})
		for setting in schema:
			if current_settings.has(setting.property_name):
				setting.value = current_settings[setting.property_name]
		
		settings_menu.build_controls_from_settingsvars(schema, "Settings")
		settings_menu.setting_changed.connect(func(value, setting): _on_effect_setting_changed(index, setting.property_name, value))

func _on_add_effect(id: int):
	var new_effect: Dictionary
	
	match id:
		0:
			new_effect = {
				"effect_id": "border",
				"settings": {
					"border_size": 0.05,
					"border_fade_in": 0.0,
					"border_color": Color.WHITE
				}
			}
		1:
			new_effect = {
				"effect_id": "badge",
				"settings": {
					"hide_background": false,
					"badge_size": 1.0,
					"badge_inner_radius": 0.0,
					"badge_color": Color.WHITE,
					"icon_padding": 0.5,
					"icon_color": Color.WHITE
				}
			}
		2:
			new_effect = {
				"effect_id": "drop_shadow",
				"settings": {
					"shadow_color": Color(0, 0, 0, 0.5),
					"shadow_offset_x": 0.0,
					"shadow_offset_y": 0.05,
					"shadow_softness": 0.04,
					"shadow_spread": 0.0,
					"shadow_expand": 0.02
				}
			}
		3:
			new_effect = {
				"effect_id": "glow",
				"settings": {
					"glow_radius": 0.1,
					"glow_intensity": 1.5,
					"blur_amount": 12.0,
					"threshold": 0.1,
					"glow_spread": 0.05
				}
			}
		4:
			new_effect = {
				"effect_id": "glass",
				"settings": {
					"distortion": 0.5,
					"glass_color": Color(0.2, 0.4, 1.0, 0.3)
				}
			}
		5:
			new_effect = {
				"effect_id": "distort",
				"settings": {
					"distortion": 0.5,
					"opacity": 1.0
				}
			}
		6:
			var default_gradient = Gradient.new()
			default_gradient.offsets = [0.0, 1.0]
			default_gradient.colors = [Color.WHITE, Color.BLACK]
			new_effect = {
				"effect_id": "gradient_overlay",
				"settings": {
					"gradient": default_gradient,
					"gradient_direction": 0
				}
			}
	
	if new_effect:
		var effects = _current_config.get("effects", [])
		effects.append(new_effect)
		_current_config["effects"] = effects
		_card_state.effect_settings = effects
		_rebuild_effects_ui()
		_update_preview()
		_save_to_settings()

func _on_remove_effect(index: int):
	var effects = _current_config.get("effects", [])
	if index >= 0 and index < effects.size():
		effects.remove_at(index)
		_current_config["effects"] = effects
		_card_state.effect_settings = effects
		_rebuild_effects_ui()
		_update_preview()
		_save_to_settings()

func _on_effect_setting_changed(effect_index: int, setting_name: String, value: Variant):
	var effects = _current_config.get("effects", [])
	if effect_index >= 0 and effect_index < effects.size():
		if not effects[effect_index].has("settings"):
			effects[effect_index]["settings"] = {}
		effects[effect_index]["settings"][setting_name] = value
		_update_preview()
		_save_to_settings()

func _on_orientation_changed(index: int):
	_current_config["card_orientation"] = index
	_card_state.orientation = index
	_card_state.zoom_level = 1.5
	_update_preview()
	_save_to_settings()

func _on_corner_radius_changed(value: float):
	_current_config["corner_radius"] = value
	_card_state.corner_radius_ratio = value
	_card_state.zoom_level = 1.5
	_update_preview()
	_save_to_settings()

func _update_preview():
	if not _preview_card or not is_instance_valid(_preview_card):
		return
	
	var state = CardState.new()
	state.orientation = _current_config.get("card_orientation", 0)
	# Corner radius is now 0.0-1.0 ratio directly
	state.corner_radius_ratio = _current_config.get("corner_radius", 0.06)
	state.effect_settings = _current_config.get("effects", []).duplicate(true)
	state.zoom_level = 1.5
	state.game_texture = _preview_card._current_texture
	
	_preview_card.set_card_state(state)

func _save_to_settings() -> void:
	"""Save the current config to SettingsManager immediately."""
	if not SettingsManager:
		return
	
	var config_setting = SettingsManager.get_setting("card_effect_config")
	if config_setting:
		SettingsManager.set_setting(_current_config.duplicate(true), config_setting)

func _on_focus_changed(control: Control) -> void:
	"""Ensure focused controls are visible in the scroll container."""
	if not control:
		return
	if not is_instance_valid(_left_scroll):
		return
	if not _left_scroll.is_ancestor_of(control):
		return
	_left_scroll.ensure_control_visible(control)
