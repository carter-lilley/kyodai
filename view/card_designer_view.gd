class_name CardDesignerView
extends Control

var _media_container: MediaContainer = MediaContainer.new()

func _init():
	_media_container.bounds = Rect2(Vector2.ZERO, Vector2(202.0, 270.0))
var _current_config: Dictionary = {}

var _preview_card: GameCard
var _card_rounding_slider: HSlider


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
	# Don't call _setup_preview_card() here — it calls _save_to_settings() which
	# emits setting_changed(card_effect_config) and triggers UIManager._rebuild_views().
	# Just refresh the preview card directly since settings are already saved.
	if _preview_card and is_instance_valid(_preview_card):
		_preview_card.refresh_settings()

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
	hsplit.split_offset = 0
	hsplit.resized.connect(func():
		hsplit.split_offset = int(hsplit.size.x * 0.65)
	)
	add_child(hsplit)
	
	var left_panel = Panel.new()
	left_panel.clip_contents = true
	hsplit.add_child(left_panel)
	
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	left_panel.add_child(scroll)
	
	var left_vbox = VBoxContainer.new()
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(left_vbox)
	
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
	
	left_vbox.add_child(HSeparator.new())
	
	# Base effects designer
	_base_effect_designer = EffectDesignerUI.new()
	_base_effect_designer.use_internal_scroll = false
	_base_effect_designer.hide_disabled_effects = true
	_base_effect_designer.setup("Effects", "base_card", "effects", false)
	_base_effect_designer.config_changed.connect(_on_base_config_changed)
	left_vbox.add_child(_base_effect_designer)
	
	# Focus effects designer
	_focus_effect_designer = EffectDesignerUI.new()
	_focus_effect_designer.use_internal_scroll = false
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
	_preview_card.preview_show_focus = false
	_preview_card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	preview_container.add_child(_preview_card)
	
	# GameCard sets mouse_filter = IGNORE in _ready(), so we must override after
	_preview_card.call_deferred("set", "mouse_filter", Control.MOUSE_FILTER_STOP)
	_preview_card.mouse_entered.connect(func():
		if _preview_card:
			_preview_card.set_preview_focus(true)
	)
	_preview_card.mouse_exited.connect(func():
		if _preview_card:
			_preview_card.set_preview_focus(false)
	)

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
	
	# Migrate old keys to unified card_rounding
	if not _current_config.has("card_rounding"):
		if _current_config.has("art_rounding"):
			_current_config["card_rounding"] = _current_config["art_rounding"]
		elif _current_config.has("corner_radius"):
			_current_config["card_rounding"] = _current_config["corner_radius"]
	
	# Remove stale keys
	_current_config.erase("corner_radius")
	_current_config.erase("art_rounding")
	
	var rounding_value = _current_config.get("card_rounding", 0.12)
	_card_rounding_slider.value = rounding_value
	_media_container.corner_radius_ratio = rounding_value
	if _preview_card and is_instance_valid(_preview_card):
		_preview_card.card_rounding_ratio = rounding_value
	_media_container.effect_settings = _current_config.get("effects", [])
	_media_container.focus_effect_settings = _current_config.get("focus_effects", [])
	
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
	}

func _setup_preview_card():
	if not _preview_card or not is_instance_valid(_preview_card):
		return
	
	_preview_card.custom_minimum_size = _media_container.size
	
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
	_media_container.corner_radius_ratio = value
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
