class_name EffectDesignerUI
extends VBoxContainer

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
var hide_disabled_effects: bool = false  # If true, dropdown omits already-active effects entirely
@export var use_internal_scroll: bool = true  # If false, no internal ScrollContainer is created (useful when parent provides scrolling)

# State
var _current_config: Dictionary = {}
var _base_effects: Array = []  # For focus effect inheritance
var _effects_list: VBoxContainer
var _add_effect_button: M3OptionButton
var _scroll_container: ScrollContainer
var _title_label: M3Label

# Discovered effects for this context
var _available_effects: Dictionary = {}  # Maps effect_id -> display_name
var _effect_id_map: Dictionary = {}  # Maps dropdown_id -> effect_id

# Effect default settings
var _effect_defaults: Dictionary = {
	"border": {
		"border_size": 0.0,
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
		"glass_color": Color(0.2, 0.4, 1.0, 0.3),
		"additional_inset_ratio": 0.0,
		"specular_power": 32.0,
		"specular_intensity": 0.8,
		"light_angle": 45.0,
		"light_height": 0.5,
		"bounce_intensity": 0.4,
		"bounce_softness": 3.0,
		"rim_intensity": 1.0,
		"rim_sharpness": 5.0,
		"swoop_intensity": 0.3,
		"swoop_height": 0.25,
		"swoop_curve": 0.5,
		"swoop_tilt": 0.0
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
	_sync_option_button()

func set_base_effects(base_effects: Array):
	_base_effects = base_effects.duplicate(true)
	if inherit_from_base:
		_populate_option_button()  # Update to show overlap labels

var _effects_discovered: bool = false

func _discover_effects():
	"""Auto-discover effects that support this context."""
	if _effects_discovered:
		return
	_effects_discovered = true
	
	_available_effects.clear()
	_effect_id_map.clear()
	
	var dropdown_id = 0
	for effect_id in EffectStack.EFFECT_REGISTRY.keys():
		# Skip auto-managed base effect — it has no user settings and is always injected by EffectStack
		if effect_id == "base":
			continue
		
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
	
	_populate_option_button()

func _ready():
	_setup_ui()
	# If setup() was called before we entered the tree (e.g. CardDesignerView),
	# _add_effect_button didn't exist yet, so _populate_option_button() bailed.
	# Ensure the dropdown is actually populated now that UI exists.
	if not _effects_discovered:
		_discover_effects()
	else:
		_populate_option_button()

func _setup_ui():
	var target: Control = self
	
	if use_internal_scroll:
		_scroll_container = ScrollContainer.new()
		_scroll_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_scroll_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_scroll_container.follow_focus = true
		_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		_scroll_container.clip_contents = true
		_scroll_container.name = "ScrollContainer"
		add_child(_scroll_container)
		
		var inner_vbox = VBoxContainer.new()
		inner_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		inner_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_scroll_container.add_child(inner_vbox)
		target = inner_vbox
	
	# Connect to viewport focus changes to ensure focused items are visible
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	_title_label = M3Label.new()
	_title_label.text = title
	_title_label.label_style = M3Label.Style.TITLE_MEDIUM
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target.add_child(_title_label)
	if context == "focus_card":
		_title_label.add_theme_color_override("font_color", M3Theme.get_secondary())
	
	_add_effect_button = M3OptionButton.new()
	_add_effect_button.multi_select = true
	_add_effect_button.text = "Add Effect"
	_add_effect_button.placeholder_text = "Add Effect"
	_add_effect_button.fit_to_longest_item = false
	_add_effect_button.field_variant = M3TextField.Variant.OUTLINED if context == "focus_card" else M3TextField.Variant.FILLED
	_add_effect_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target.add_child(_add_effect_button)
	
	_add_effect_button.item_selected.connect(_on_effect_toggled)
	
	# Small spacer between button and effects list to prevent visual crowding
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, M3Units.dp(8))
	target.add_child(spacer)
	
	_effects_list = VBoxContainer.new()
	_effects_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	target.add_child(_effects_list)

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
		var no_effects_label = M3Label.new()
		no_effects_label.text = "No effects added. Click 'Add Effect' to get started."
		no_effects_label.label_style = M3Label.Style.BODY_MEDIUM
		no_effects_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		no_effects_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
		_effects_list.add_child(no_effects_label)
	
	for i in range(effects.size()):
		var effect_data = effects[i]
		_create_effect_ui(effect_data, i)
	
	# Restore collapsed states after rebuilding
	for child in _effects_list.get_children():
		if child is CollapsableVBoxContainer and collapsed_states.has(child.title):
			child.collapsed = collapsed_states[child.title]
	
	# Sync the toggle option button to match current config
	_sync_option_button()

func _populate_option_button() -> void:
	if not _add_effect_button:
		return
	_add_effect_button.clear()
	for dropdown_id in _effect_id_map.keys():
		var effect_id = _effect_id_map[dropdown_id]
		var display_name = _available_effects.get(effect_id, effect_id.replace("_", " ").capitalize())
		if inherit_from_base:
			var in_base = false
			for effect in _base_effects:
				if effect.get("effect_id") == effect_id:
					in_base = true
					break
			if in_base:
				display_name += " (overrides base)"
		_add_effect_button.add_item(display_name, dropdown_id)
	_sync_option_button()

func _sync_option_button() -> void:
	if not _add_effect_button:
		return
	_add_effect_button.clear_selection()
	var effects = _current_config.get(config_key, [])
	var active_ids: Array[String] = []
	for effect in effects:
		var effect_id = effect.get("effect_id", "")
		if effect_id:
			active_ids.append(effect_id)
	_add_effect_button.set_block_signals(true)
	for dropdown_id in _effect_id_map.keys():
		var effect_id = _effect_id_map[dropdown_id]
		if effect_id in active_ids:
			_add_effect_button.select_option(dropdown_id)
	_add_effect_button.set_block_signals(false)
	# Override auto-text so the button never appears blank when empty
	var selected_count = _add_effect_button.get_selected_indices().size()
	_add_effect_button.text = "Add Effect" if selected_count == 0 else ("%d selected" % selected_count)

func _is_focus_designer() -> bool:
	return context == "focus_card"

func _create_effect_ui(effect_data: Dictionary, index: int) -> void:
	var container = CollapsableVBoxContainer.new()
	container.title = effect_data.get("effect_id", "Unknown").capitalize()
	container.collapsed = false
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.header_variant = M3Button.Variant.TONAL if _is_focus_designer() else M3Button.Variant.TEXT
	_effects_list.add_child(container)
	
	var remove_btn = M3IconButton.new()
	remove_btn.icon_name = "close"
	remove_btn.icon_button_variant = M3IconButton.IconVariant.TONAL if _is_focus_designer() else M3IconButton.IconVariant.STANDARD
	remove_btn.icon_button_size = M3IconButton.IconSize.EXTRA_SMALL
	remove_btn.pressed.connect(func(): _on_remove_effect(index))
	container.add_header_button(remove_btn)
	
	var content = container.get_content_container()
	var effect_id = effect_data.get("effect_id", "")
	
	# Create settings menu for this effect
	var schema = _get_effect_schema(effect_id)
	if schema.size() > 0:
		var settings_menu = SettingsMenu.new()
		if _is_focus_designer():
			settings_menu.accent_color = M3Theme.get_secondary()
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

func _on_effect_toggled(_index: int):
	var selected_indices = _add_effect_button.get_selected_indices()
	var selected_ids: Dictionary = {}
	for idx in selected_indices:
		var effect_id = _effect_id_map.get(idx, "")
		if effect_id:
			selected_ids[effect_id] = true
	
	var effects = _current_config.get(config_key, [])
	var new_effects: Array = []
	var added_ids: Dictionary = {}
	
	# Preserve order for existing effects that remain selected
	for effect in effects:
		var effect_id = effect.get("effect_id", "")
		if selected_ids.has(effect_id):
			new_effects.append(effect)
			added_ids[effect_id] = true
	
	# Append newly selected effects at the end
	for idx in selected_indices:
		var effect_id = _effect_id_map.get(idx, "")
		if effect_id and not added_ids.has(effect_id):
			new_effects.append({
				"effect_id": effect_id,
				"settings": _get_default_settings(effect_id)
			})
			added_ids[effect_id] = true
	
	_current_config[config_key] = new_effects
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
