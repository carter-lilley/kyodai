class_name EffectDesignerUI
extends Control

signal config_changed(config: Dictionary)
signal save_requested(config: Dictionary)

# Configuration
var title: String = "Effects":
	set(value):
		title = value
		if _title_label:
			_title_label.text = value
var context: String = "hero"  # "hero", "base_card", or "focus_card"
var inherit_from_base: bool = false  # For focus effects - copy defaults from base effects
var config_key: String = "effects"  # Key in config dict ("effects" or "focus_effects")

# State
var _current_config: Dictionary = {}
var _base_effects: Array = []  # For focus effect inheritance
var _effects_list: VBoxContainer
var _add_effect_button: MenuButton
var _scroll_container: ScrollContainer
var _title_label: Label

# Discovered effects for this context
var _available_effects: Dictionary = {}  # Maps effect_id -> display_name
var _effect_id_map: Dictionary = {}  # Maps dropdown_id -> effect_id

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
	},
	"gradient_overlay": {
		"gradient": null,  # Will create default gradient
		"gradient_direction": 0
	},
	"hsl": {
		"hue_shift": 0.0,
		"saturation_scale": 1.0,
		"lightness_scale": 1.0
	},
	"blur": {
		"blur_strength": 4.0,
		"blur_samples": 8
	}
}

func setup(p_title: String, p_context: String, p_config_key: String = "effects", p_inherit_from_base: bool = false):
	title = p_title
	context = p_context
	config_key = p_config_key
	inherit_from_base = p_inherit_from_base
	_discover_effects()
	_rebuild_add_effect_dropdown()

func set_base_effects(base_effects: Array):
	_base_effects = base_effects.duplicate(true)
	if inherit_from_base:
		_rebuild_add_effect_dropdown()  # Update to show overlap labels

func _discover_effects():
	"""Auto-discover effects that support this context."""
	_available_effects.clear()
	_effect_id_map.clear()
	
	var dropdown_id = 0
	for effect_id in EffectStack.EFFECT_REGISTRY.keys():
		var script_path = EffectStack.EFFECT_REGISTRY[effect_id]
		var script = load(script_path)
		if not script:
			continue
		
		# Check if effect supports this context
		var supports_context = false
		if script.has_method("get_allowed_contexts"):
			var contexts = script.get_allowed_contexts()
			supports_context = context in contexts
		else:
			# Default: support all contexts
			supports_context = true
		
		if supports_context:
			var display_name = effect_id.replace("_", " ").capitalize()
			_available_effects[effect_id] = display_name
			_effect_id_map[dropdown_id] = effect_id
			dropdown_id += 1

func _ready():
	_setup_ui()
	_discover_effects()

func _setup_ui():
	# Set up this control to fill parent
	set_anchors_preset(Control.PRESET_FULL_RECT)
	
	_scroll_container = ScrollContainer.new()
	_scroll_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll_container.follow_focus = true
	_scroll_container.name = "ScrollContainer"
	add_child(_scroll_container)
	
	# Connect to viewport focus changes to ensure focused items are visible
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	var vbox = VBoxContainer.new()
	_scroll_container.add_child(vbox)
	
	_title_label = Label.new()
	_title_label.text = title
	_title_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(_title_label)
	
	_effects_list = VBoxContainer.new()
	vbox.add_child(_effects_list)
	
	_add_effect_button = MenuButton.new()
	_add_effect_button.text = "Add Effect"
	vbox.add_child(_add_effect_button)
	
	var popup = _add_effect_button.get_popup()
	popup.id_pressed.connect(_on_add_effect)

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting into a SubViewport."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return
	
	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)
	
	viewport.gui_focus_changed.connect(_on_focus_changed)

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
	
	var effects = _current_config.get(config_key, [])
	
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
	var effects = _current_config.get(config_key, [])
	for effect in effects:
		var effect_id = effect.get("effect_id", "")
		if effect_id:
			active_effects.append(effect_id)
	
	# Get list of base effect IDs for overlap detection (focus effects only)
	var base_effects: Array[String] = []
	if inherit_from_base:
		for effect in _base_effects:
			var effect_id = effect.get("effect_id", "")
			if effect_id:
				base_effects.append(effect_id)
	
	# Add only inactive effects to the dropdown
	var has_available_effects = false
	for dropdown_id in _effect_id_map.keys():
		var effect_id = _effect_id_map[dropdown_id]
		
		# Build display name with overlap indicator if applicable
		var display_name = _available_effects.get(effect_id, effect_id.replace("_", " ").capitalize())
		if inherit_from_base and effect_id in base_effects:
			display_name += " (overrides base)"
		
		popup.add_item(display_name, dropdown_id)
		
		# Disable if already in effects list
		if effect_id in active_effects:
			popup.set_item_disabled(popup.get_item_index(dropdown_id), true)
		else:
			has_available_effects = true
	
	# Disable button if all effects are active
	_add_effect_button.disabled = not has_available_effects
	if not has_available_effects:
		_add_effect_button.text = "All Effects Added"
	else:
		_add_effect_button.text = "Add " + title

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

func _get_base_effect_settings(effect_id: String) -> Dictionary:
	"""Get settings from base effect if it exists (for focus effect inheritance)."""
	for effect in _base_effects:
		if effect.get("effect_id") == effect_id:
			return effect.get("settings", {}).duplicate(true)
	return {}

func _get_default_settings(effect_id: String) -> Dictionary:
	"""Get default settings, inheriting from base if applicable."""
	var defaults = _effect_defaults.get(effect_id, {}).duplicate(true)
	
	# Handle special case for gradient_overlay default gradient
	if effect_id == "gradient_overlay" and defaults.get("gradient") == null:
		var default_gradient = Gradient.new()
		default_gradient.offsets = [0.0, 1.0]
		default_gradient.colors = [Color.WHITE, Color.BLACK]
		defaults["gradient"] = default_gradient
	
	# If inheriting from base, merge base settings
	if inherit_from_base:
		var base_settings = _get_base_effect_settings(effect_id)
		for key in base_settings.keys():
			defaults[key] = base_settings[key]
	
	return defaults

func _on_add_effect(id: int):
	var effect_id = _effect_id_map.get(id, "")
	if effect_id == "":
		return
	
	var new_effect = {
		"effect_id": effect_id,
		"settings": _get_default_settings(effect_id)
	}
	
	var effects = _current_config.get(config_key, [])
	effects.append(new_effect)
	_current_config[config_key] = effects
	
	_rebuild_effects_ui()
	config_changed.emit(_current_config.duplicate(true))

func _on_remove_effect(index: int):
	var effects = _current_config.get(config_key, [])
	if index >= 0 and index < effects.size():
		effects.remove_at(index)
		_current_config[config_key] = effects
		_rebuild_effects_ui()
		config_changed.emit(_current_config.duplicate(true))

func _on_effect_setting_changed(effect_index: int, setting_name: String, value: Variant):
	var effects = _current_config.get(config_key, [])
	if effect_index >= 0 and effect_index < effects.size():
		if not effects[effect_index].has("settings"):
			effects[effect_index]["settings"] = {}
		effects[effect_index]["settings"][setting_name] = value
		config_changed.emit(_current_config.duplicate(true))

func save_config():
	save_requested.emit(_current_config.duplicate(true))

func _on_focus_changed(control: Control) -> void:
	"""Ensure focused controls are visible in the scroll container."""
	if not control:
		return
	if not is_instance_valid(_scroll_container):
		return
	if not _scroll_container.is_ancestor_of(control):
		return
	_scroll_container.ensure_control_visible(control)
