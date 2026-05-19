class_name CardDesignerView
extends Control

var _container_state: EffectContainerState = EffectContainerState.for_card()
var _current_config: Dictionary = {}

var _preview_card: GameCard
var _card_rounding_slider: HSlider
var _art_rounding_slider: HSlider

# Shared effect designer UI instances
var _base_effect_designer: EffectDesignerUI
var _focus_effect_designer: EffectDesignerUI

func _ready():
	_setup_ui()
	_load_current_config()
	call_deferred("_setup_preview_card")
	
	# Connect to settings changes so we refresh when a preset is applied
	if SettingsManager:
		SettingsManager.settings_saved.connect(_on_settings_saved)
	
	# Connect to viewport focus changes to ensure focused items are visible
	get_viewport().gui_focus_changed.connect(_on_focus_changed)

func _on_settings_saved():
	_load_current_config()
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
	_setup_preview_card()

func _setup_ui():
	var hsplit = HSplitContainer.new()
	hsplit.set_anchors_preset(Control.PRESET_FULL_RECT)
	hsplit.split_offset = 300
	add_child(hsplit)
	
	var left_panel = Panel.new()
	left_panel.custom_minimum_size = Vector2(300, 0)
	left_panel.clip_contents = true
	hsplit.add_child(left_panel)
	
	var left_vbox = VBoxContainer.new()
	left_vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	left_panel.add_child(left_vbox)
	
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
	
	var card_rounding_label = Label.new()
	card_rounding_label.text = "Card Rounding (0-1)"
	left_vbox.add_child(card_rounding_label)
	
	_card_rounding_slider = HSlider.new()
	_card_rounding_slider.min_value = 0.0
	_card_rounding_slider.max_value = 1.0
	_card_rounding_slider.step = 0.01
	_card_rounding_slider.value = 0.12
	_card_rounding_slider.value_changed.connect(_on_card_rounding_changed)
	left_vbox.add_child(_card_rounding_slider)
	
	var art_rounding_label = Label.new()
	art_rounding_label.text = "Art Rounding (0-1)"
	left_vbox.add_child(art_rounding_label)
	
	_art_rounding_slider = HSlider.new()
	_art_rounding_slider.min_value = 0.0
	_art_rounding_slider.max_value = 1.0
	_art_rounding_slider.step = 0.01
	_art_rounding_slider.value = 0.12
	_art_rounding_slider.value_changed.connect(_on_art_rounding_changed)
	left_vbox.add_child(_art_rounding_slider)
	
	left_vbox.add_child(HSeparator.new())
	
	# Base effects designer
	_base_effect_designer = EffectDesignerUI.new()
	_base_effect_designer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_base_effect_designer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_base_effect_designer.custom_minimum_size = Vector2(0, 250)
	_base_effect_designer.hide_disabled_effects = true
	_base_effect_designer.setup("Effects", "base_card", "effects", false)
	_base_effect_designer.config_changed.connect(_on_base_config_changed)
	left_vbox.add_child(_base_effect_designer)
	
	left_vbox.add_child(HSeparator.new())
	
	# Focus effects designer
	_focus_effect_designer = EffectDesignerUI.new()
	_focus_effect_designer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_focus_effect_designer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_focus_effect_designer.custom_minimum_size = Vector2(0, 250)
	_focus_effect_designer.setup("Focus Effects", "focus_card", "focus_effects", true)
	_focus_effect_designer.config_changed.connect(_on_focus_config_changed)
	left_vbox.add_child(_focus_effect_designer)
	
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
	
	# Backward compat: old single "corner_radius" → copy to both new keys
	if _current_config.has("corner_radius") and not _current_config.has("card_rounding"):
		_current_config["card_rounding"] = _current_config["corner_radius"]
		_current_config["art_rounding"] = _current_config["corner_radius"]
	
	_card_rounding_slider.value = _current_config.get("card_rounding", 0.12)
	_art_rounding_slider.value = _current_config.get("art_rounding", 0.12)
	
	_container_state.corner_radius_ratio = _current_config.get("art_rounding", 0.12)
	_container_state.effect_settings = _current_config.get("effects", [])
	_container_state.focus_effect_settings = _current_config.get("focus_effects", [])
	
	# Sync shared effect designers
	if _base_effect_designer:
		_base_effect_designer.set_config(_current_config)
	if _focus_effect_designer:
		_focus_effect_designer.set_config(_current_config)
		_focus_effect_designer.set_base_effects(_current_config.get("effects", []))

func _get_default_config() -> Dictionary:
	return {
		"effects": [],
		"focus_effects": [],
		"card_rounding": 0.12,
		"art_rounding": 0.12,
	}

func _setup_preview_card():
	if not _preview_card or not is_instance_valid(_preview_card):
		return
	
	_preview_card.custom_minimum_size = _container_state.container_size
	
	# Save current config to SettingsManager so refresh_settings() picks it up
	_save_to_settings()
	_preview_card.refresh_settings()

func _on_base_config_changed(config: Dictionary):
	_current_config["effects"] = config.get("effects", []).duplicate(true)
	# Refresh focus designer's base reference so overlap labels stay current
	if _focus_effect_designer:
		_focus_effect_designer.set_base_effects(_current_config.get("effects", []))
	_update_preview()
	_save_to_settings()

func _on_focus_config_changed(config: Dictionary):
	_current_config["focus_effects"] = config.get("focus_effects", []).duplicate(true)
	_update_preview()
	_save_to_settings()

func _on_card_rounding_changed(value: float):
	_current_config["card_rounding"] = value
	if _preview_card:
		_preview_card.card_rounding_ratio = value
	_update_preview()
	_save_to_settings()

func _on_art_rounding_changed(value: float):
	_current_config["art_rounding"] = value
	_container_state.corner_radius_ratio = value
	_container_state.zoom_level = 1.5
	_update_preview()
	_save_to_settings()

func _update_preview():
	if not _preview_card or not is_instance_valid(_preview_card):
		return
	
	# Save current config to SettingsManager so refresh_settings() picks it up
	_save_to_settings()
	_preview_card.refresh_settings()

func _save_to_settings() -> void:
	"""Save the current config to SettingsManager immediately."""
	if not SettingsManager:
		return
	
	var config_setting = SettingsManager.get_setting("card_effect_config")
	if config_setting:
		SettingsManager.set_setting(_current_config.duplicate(true), config_setting)

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting into a SubViewport."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return
	
	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)
	
	viewport.gui_focus_changed.connect(_on_focus_changed)
	
	# Reconnect nested EffectDesignerUI viewports
	if _base_effect_designer and _base_effect_designer.has_method("reconnect_viewport"):
		_base_effect_designer.reconnect_viewport()
	if _focus_effect_designer and _focus_effect_designer.has_method("reconnect_viewport"):
		_focus_effect_designer.reconnect_viewport()

func _on_focus_changed(control: Control) -> void:
	"""Ensure focused controls are visible in nested scroll containers."""
	if not control:
		return
	
	# Forward to the appropriate designer's scroll container
	if _base_effect_designer and _base_effect_designer.is_ancestor_of(control):
		if _base_effect_designer._scroll_container:
			_base_effect_designer._scroll_container.ensure_control_visible(control)
		return
	
	if _focus_effect_designer and _focus_effect_designer.is_ancestor_of(control):
		if _focus_effect_designer._scroll_container:
			_focus_effect_designer._scroll_container.ensure_control_visible(control)
		return
