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
var context: String = "hero"  # "hero", "base_card", "focus_card", or "" to skip context filtering
var inherit_from_base: bool = false  # For focus effects - copy defaults from base effects
var config_key: String = "effects"  # Key in config dict ("effects" or "focus_effects")
var hide_disabled_effects: bool = false  # If true, dropdown omits already-active effects entirely
@export var use_internal_scroll: bool = true  # If false, no internal ScrollContainer is created (useful when parent provides scrolling)
## Custom effect registry (effect_id -> script path). Empty = EffectStack.EFFECT_REGISTRY.
var effect_registry: Dictionary = {}
## Display name overrides (effect_id -> name); falls back to capitalized id.
var display_names: Dictionary = {}
## Which kind of user-provided custom effects (user://effects/<kind>/) to
## offer in the dropdown: "card", "background", or "" for none.
var custom_kind: String = ""
## When true, per-effect rows get up/down buttons (config order = draw order).
var allow_reorder: bool = false

# State
var _current_config: Dictionary = {}
var _base_effects: Array = []  # For focus effect inheritance
var _effects_list: VBoxContainer
var _add_effect_button: M3OptionButton
var _scroll_container: ScrollContainer
var _title_label: M3Label
var _focus_badge: M3Chip

# Discovered effects for this context
var _available_effects: Dictionary = {}  # Maps effect_id -> display_name
var _effect_id_map: Dictionary = {}  # Maps dropdown_id -> effect_id

# Effect default settings
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

## Re-runs effect discovery, e.g. after EffectRegistry.rescan() picks up
## newly added (or removed) custom shaders.
func rediscover() -> void:
	_effects_discovered = false
	_discover_effects()
	if _effects_list:
		_rebuild_effects_ui()

var _effects_discovered: bool = false

func _discover_effects():
	"""Auto-discover effects that support this context."""
	if _effects_discovered:
		return
	_effects_discovered = true
	
	_available_effects.clear()
	_effect_id_map.clear()
	
	var dropdown_id = 0
	var registry: Dictionary = effect_registry if not effect_registry.is_empty() else EffectStack.EFFECT_REGISTRY
	for effect_id in registry.keys():
		# Skip auto-managed base effect — it has no user settings and is always injected by EffectStack
		if effect_id == "base":
			continue

		var script_path = registry[effect_id]
		var script = load(script_path)
		if not script:
			continue

		# Check if effect supports this context (empty context = no filtering)
		var supports_context = true
		if not context.is_empty():
			if script.has_method("get_allowed_contexts"):
				var contexts = script.get_allowed_contexts()
				supports_context = context in contexts

		if supports_context:
			var display_name = display_names.get(effect_id, effect_id.replace("_", " ").capitalize())
			_available_effects[effect_id] = display_name
			_effect_id_map[dropdown_id] = effect_id
			dropdown_id += 1

	# User-provided custom effects (user://effects/<kind>/). Their generic
	# layers allow every context, so no context filtering is needed.
	if custom_kind != "":
		for descriptor in EffectRegistry.get_custom_descriptors(custom_kind):
			var custom_id: String = descriptor.get("id", "")
			if custom_id == "" or _available_effects.has(custom_id):
				continue
			_available_effects[custom_id] = descriptor.get("display_name", custom_id)
			_effect_id_map[dropdown_id] = custom_id
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
	if _is_focus_designer():
		var title_row := HBoxContainer.new()
		title_row.add_theme_constant_override("separation", int(M3Units.dp(8)))
		target.add_child(title_row)
		title_row.add_child(_title_label)
		_focus_badge = M3Chip.new()
		_focus_badge.text = "Focus"
		_focus_badge.chip_variant = M3Chip.ChipVariant.FILTER
		_focus_badge.checked_icon_name = "crosshairs"
		_focus_badge.focus_mode = Control.FOCUS_NONE
		_focus_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		title_row.add_child(_focus_badge)
		_focus_badge.checked = true
	else:
		target.add_child(_title_label)
	_apply_focus_styling()
	
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
		no_effects_label.use_on_surface_variant = true
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
	_add_effect_button.clear_items()
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

func refresh_theme() -> void:
	# Child M3Labels re-apply their own colors during the global theme walk,
	# clobbering our overrides — re-apply focus styling deferred so it wins.
	call_deferred("_apply_focus_styling")

func _apply_focus_styling() -> void:
	if not _is_focus_designer():
		return
	if _title_label:
		_title_label.add_theme_color_override("font_color", M3Theme.get_secondary())
	if not is_instance_valid(_effects_list):
		return
	for row in _effects_list.get_children():
		for section in row.find_children("*", "SettingsSection", true, false):
			section.surface_tint = M3Theme.get_secondary()

func _create_effect_ui(effect_data: Dictionary, index: int) -> void:
	var container = CollapsableVBoxContainer.new()
	var effect_id_for_title = effect_data.get("effect_id", "Unknown")
	container.title = _available_effects.get(effect_id_for_title, effect_id_for_title.replace("_", " ").capitalize())
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

	if allow_reorder:
		var effects_count = _current_config.get(config_key, []).size()
		var up_btn = M3IconButton.new()
		up_btn.icon_name = "arrow-up"
		up_btn.icon_button_variant = M3IconButton.IconVariant.STANDARD
		up_btn.icon_button_size = M3IconButton.IconSize.EXTRA_SMALL
		up_btn.disabled = index == 0
		up_btn.tooltip_text = "Move up (draws later)"
		up_btn.pressed.connect(func(): _on_move_effect(index, -1))
		container.add_header_button(up_btn)

		var down_btn = M3IconButton.new()
		down_btn.icon_name = "arrow-down"
		down_btn.icon_button_variant = M3IconButton.IconVariant.STANDARD
		down_btn.icon_button_size = M3IconButton.IconSize.EXTRA_SMALL
		down_btn.disabled = index >= effects_count - 1
		down_btn.tooltip_text = "Move down (draws earlier)"
		down_btn.pressed.connect(func(): _on_move_effect(index, 1))
		container.add_header_button(down_btn)
	
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
		
		# Untitled section: a plain card groups the effect's settings without
		# adding a header inside the collapsible row.
		settings_menu.build_controls_from_settingsvars(schema)
		if _is_focus_designer() and settings_menu._current_section:
			settings_menu._current_section.surface_tint = M3Theme.get_secondary()
		settings_menu.setting_changed.connect(func(value, setting): _on_effect_setting_changed(index, setting.property_name, value))

func _get_effect_schema(effect_id: String) -> Array[SettingsVar]:
	# Custom (user-shader) effects carry a pregenerated introspected schema.
	if EffectRegistry.is_custom(effect_id):
		return EffectRegistry.get_schema(effect_id)
	# Load the effect class and get its schema
	var registry: Dictionary = effect_registry if not effect_registry.is_empty() else EffectStack.EFFECT_REGISTRY
	var script_path = registry.get(effect_id, "")
	if script_path == "":
		return []

	var script = load(script_path)
	if not script:
		return []

	var effect = script.new()
	var schema = effect.get_settings_schema()
	# Card effects are RefCounted (RID cleanup); background effects are Nodes
	if effect is Node:
		effect.free()
	else:
		effect.free_rid()

	return schema

func _get_base_effect_settings(effect_id: String) -> Dictionary:
	"""Get settings from base effect if it exists (for focus effect inheritance)."""
	for effect in _base_effects:
		if effect.get("effect_id") == effect_id:
			return effect.get("settings", {}).duplicate(true)
	return {}

func _get_default_settings(effect_id: String) -> Dictionary:
	"""Get default settings from the effect schema, inheriting from base if applicable."""
	var defaults: Dictionary = {}
	for setting in _get_effect_schema(effect_id):
		if setting.value is Resource:
			defaults[setting.property_name] = setting.value.duplicate()
		else:
			defaults[setting.property_name] = setting.value

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

func _on_move_effect(index: int, delta: int):
	var effects = _current_config.get(config_key, [])
	var target = index + delta
	if index >= 0 and index < effects.size() and target >= 0 and target < effects.size():
		var entry = effects[index]
		effects.remove_at(index)
		effects.insert(target, entry)
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
