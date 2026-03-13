class_name EffectDesignerUI
extends Control

signal config_changed(config: Dictionary)
signal save_requested(config: Dictionary)

var _current_config: Dictionary = {}
var _effects_list: VBoxContainer
var _add_effect_button: MenuButton

# Maps dropdown IDs to effect IDs for filtering active effects
var _effect_id_map: Dictionary = {
	0: "border",
	1: "badge",
	2: "drop_shadow",
	3: "glow",
	4: "glass",
	5: "distort"
}

# Effect default settings
var _effect_defaults: Dictionary = {
	"border": {
		"border_size": 0.05,
		"border_fade_in": 0.0,
		"border_color": Color.WHITE
	},
	"badge": {
		"hide_background": false,
		"badge_size": 1.0,
		"badge_inner_radius": 0.0,
		"badge_color": Color.WHITE,
		"icon_padding": 0.5,
		"icon_color": Color.WHITE
	},
	"drop_shadow": {
		"shadow_color": Color(0, 0, 0, 0.5),
		"shadow_offset_x": 0.0,
		"shadow_offset_y": 0.05,
		"shadow_softness": 0.04,
		"shadow_spread": 0.0,
		"shadow_expand": 0.02
	},
	"glow": {
		"glow_radius": 0.1,
		"glow_intensity": 1.5,
		"blur_amount": 12.0,
		"threshold": 0.1,
		"glow_spread": 0.05
	},
	"glass": {
		"distortion": 0.5,
		"glass_color": Color(0.2, 0.4, 1.0, 0.3)
	},
	"distort": {
		"distortion": 0.5,
		"opacity": 1.0
	}
}

func _ready():
	_setup_ui()

func _setup_ui():
	# Set up this control to fill parent
	set_anchors_preset(Control.PRESET_FULL_RECT)
	
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.name = "ScrollContainer"
	add_child(scroll)
	
	var vbox = VBoxContainer.new()
	scroll.add_child(vbox)
	
	var title_label = Label.new()
	title_label.text = "Effects"
	title_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title_label)
	
	_effects_list = VBoxContainer.new()
	vbox.add_child(_effects_list)
	
	_add_effect_button = MenuButton.new()
	_add_effect_button.text = "Add Effect"
	vbox.add_child(_add_effect_button)
	
	var popup = _add_effect_button.get_popup()
	popup.id_pressed.connect(_on_add_effect)

func set_config(config: Dictionary):
	_current_config = config.duplicate(true)
	_rebuild_effects_ui()

func get_config() -> Dictionary:
	return _current_config.duplicate(true)

func _rebuild_effects_ui():
	if not _effects_list:
		push_error("_effects_list is null")
		return
	
	# Save collapsed states before rebuilding
	var collapsed_states: Dictionary = {}
	for child in _effects_list.get_children():
		if child is CollapsableVBoxContainer:
			collapsed_states[child.title] = child.collapsed
	
	for child in _effects_list.get_children():
		child.queue_free()
	
	var effects = _current_config.get("effects", [])
	
	# Show message if no effects
	if effects.size() == 0:
		var no_effects_label = Label.new()
		no_effects_label.text = "No effects added. Click 'Add Effect' to get started."
		no_effects_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_effects_list.add_child(no_effects_label)
	
	for i in range(effects.size()):
		var effect_data = effects[i]
		_create_effect_ui(effect_data, i)
	
	# Restore collapsed states after rebuilding
	for child in _effects_list.get_children():
		if child is CollapsableVBoxContainer and collapsed_states.has(child.title):
			child.collapsed = collapsed_states[child.title]
	
	# Update the Add Effect dropdown
	_rebuild_add_effect_dropdown()

func _rebuild_add_effect_dropdown() -> void:
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
	for id in _effect_id_map.keys():
		var effect_id = _effect_id_map[id]
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
	container.collapsed = false
	_effects_list.add_child(container)
	
	var remove_btn = Button.new()
	remove_btn.text = "X"
	remove_btn.pressed.connect(func(): _on_remove_effect(index))
	container.add_header_button(remove_btn)
	
	var content = container.get_content_container()
	var effect_id = effect_data.get("effect_id", "")
	
	# Create settings menu for this effect
	var schema = _get_effect_schema(effect_id)
	if schema.size() > 0:
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

func _get_effect_schema(effect_id: String) -> Array[SettingsVar]:
	# Load the effect class and get its schema
	var script_path = EffectStack.EFFECT_REGISTRY.get(effect_id, "")
	if script_path == "":
		return []
	
	var script = load(script_path)
	if not script:
		return []
	
	var effect = script.new()
	var schema = effect.get_settings_schema()
	effect.queue_free()
	
	return schema

func _on_add_effect(id: int):
	var effect_id = _effect_id_map.get(id, "")
	if effect_id == "":
		return
	
	var new_effect = {
		"effect_id": effect_id,
		"settings": _effect_defaults.get(effect_id, {}).duplicate(true)
	}
	
	var effects = _current_config.get("effects", [])
	effects.append(new_effect)
	_current_config["effects"] = effects
	
	_rebuild_effects_ui()
	config_changed.emit(_current_config.duplicate(true))

func _on_remove_effect(index: int):
	var effects = _current_config.get("effects", [])
	if index >= 0 and index < effects.size():
		effects.remove_at(index)
		_current_config["effects"] = effects
		_rebuild_effects_ui()
		config_changed.emit(_current_config.duplicate(true))

func _on_effect_setting_changed(effect_index: int, setting_name: String, value: Variant):
	var effects = _current_config.get("effects", [])
	if effect_index >= 0 and effect_index < effects.size():
		if not effects[effect_index].has("settings"):
			effects[effect_index]["settings"] = {}
		effects[effect_index]["settings"][setting_name] = value
		config_changed.emit(_current_config.duplicate(true))

func save_config():
	save_requested.emit(_current_config.duplicate(true))
