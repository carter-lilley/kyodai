class_name BackgroundDesignerView
extends Control

## Background Designer: base gradient + stackable background effect layers +
## standard-effect overlays, with a live preview pane.

var _config: Dictionary = {}
var _config_loaded: bool = false
var _suppress_config_signal: bool = false

var _base_menu: SettingsMenu
var _effects_designer: EffectDesignerUI
var _overlay_designer: EffectDesignerUI
var _preview_background: LibraryBackground

func _ready():
	_setup_ui()
	_load_current_config()

	if DataManager:
		DataManager.settings_saved.connect(_on_settings_saved)
		DataManager.setting_changed.connect(_on_setting_changed)

	get_viewport().gui_focus_changed.connect(_on_focus_changed)

func _exit_tree():
	if DataManager and DataManager.settings_saved.is_connected(_on_settings_saved):
		DataManager.settings_saved.disconnect(_on_settings_saved)
	if DataManager and DataManager.setting_changed.is_connected(_on_setting_changed):
		DataManager.setting_changed.disconnect(_on_setting_changed)

func on_view_show():
	_load_current_config()

func on_view_hide():
	if _config_loaded:
		_save_to_settings()

func _setup_ui():
	var hsplit = HSplitContainer.new()
	hsplit.set_anchors_preset(Control.PRESET_FULL_RECT)
	hsplit.split_offset = 0
	hsplit.resized.connect(func():
		hsplit.split_offset = int(hsplit.size.x * 0.55)
	)
	add_child(hsplit)

	var scroll = ScrollContainer.new()
	scroll.clip_contents = true
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	hsplit.add_child(scroll)

	var left_vbox = VBoxContainer.new()
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.add_theme_constant_override("separation", int(M3Units.dp(16)))
	scroll.add_child(left_vbox)

	# Base gradient (bottom of the stack)
	_base_menu = SettingsMenu.new()
	left_vbox.add_child(_base_menu)
	_rebuild_base_menu()

	# Stackable background effect layers
	_effects_designer = EffectDesignerUI.new()
	_effects_designer.use_internal_scroll = false
	_effects_designer.effect_registry = LibraryBackground.EFFECT_REGISTRY
	_effects_designer.display_names = LibraryBackground.EFFECT_DISPLAY_NAMES
	_effects_designer.allow_reorder = true
	_effects_designer.use_schema_defaults = true
	_effects_designer.setup("Background Layers", "", "effects", false)
	_effects_designer.config_changed.connect(_on_effects_config_changed)
	left_vbox.add_child(_effects_designer)

	# Standard-effect overlays (drawn on top of everything)
	_overlay_designer = EffectDesignerUI.new()
	_overlay_designer.use_internal_scroll = false
	_overlay_designer.effect_registry = LibraryBackground.OVERLAY_REGISTRY
	_overlay_designer.use_schema_defaults = true
	_overlay_designer.setup("Overlay", "", "overlays", false)
	_overlay_designer.config_changed.connect(_on_overlay_config_changed)
	left_vbox.add_child(_overlay_designer)

	# Live preview
	var right_container = Control.new()
	right_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	hsplit.add_child(right_container)

	var library_bg = preload("res://components/library_background.tscn").instantiate()
	library_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	right_container.add_child(library_bg)
	_preview_background = library_bg

func _base_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var base_settings: Dictionary = _config.get("base", {}).get("settings", {})
	if base_settings.is_empty():
		base_settings = LibraryBackground.default_base_settings()

	var gradient_var = SettingsVar.new(Type.GRADIENT, base_settings.get("gradient"), State.ENABLED, "Base Gradient")
	gradient_var.property_name = "gradient"
	schema.append(gradient_var)

	var angle_var = SettingsVar.new(Type.ANGLE, base_settings.get("gradient_angle", 180.0), State.ENABLED, "Gradient Angle", "", 0.0, 360.0, 15.0)
	angle_var.property_name = "gradient_angle"
	schema.append(angle_var)

	var radial_var = SettingsVar.new(Type.BOOL, base_settings.get("gradient_radial", false), State.ENABLED, "Radial (Vignette)")
	radial_var.property_name = "gradient_radial"
	schema.append(radial_var)

	return schema

func _rebuild_base_menu():
	if not _base_menu:
		return
	_base_menu.clear_controls()
	_base_menu.build_controls_from_settingsvars(_base_schema(), "Base", "image-outline")
	if not _base_menu.setting_changed.is_connected(_on_base_setting_changed):
		_base_menu.setting_changed.connect(_on_base_setting_changed)

func _load_current_config():
	_config_loaded = false
	if DataManager:
		var config_setting = DataManager.get_setting("library_background_config")
		if config_setting and config_setting.value is Dictionary:
			_config = LibraryBackground.normalize_config(config_setting.value)
	if _config.is_empty():
		_config = {"base": {"settings": {}}, "effects": [], "overlays": []}

	_rebuild_base_menu()
	if _effects_designer:
		_effects_designer.set_config(_config)
	if _overlay_designer:
		_overlay_designer.set_config(_config)
	_update_preview()

	_config_loaded = true

func _on_base_setting_changed(value: Variant, setting: SettingsVar) -> void:
	if not _config_loaded:
		return
	if not _config.has("base") or not _config["base"] is Dictionary:
		_config["base"] = {"settings": {}}
	_config["base"]["settings"][setting.property_name] = value
	_apply()

func _on_effects_config_changed(config: Dictionary):
	if not _config_loaded:
		return
	_config["effects"] = config.get("effects", []).duplicate(true)
	_apply()

func _on_overlay_config_changed(config: Dictionary):
	if not _config_loaded:
		return
	_config["overlays"] = config.get("overlays", []).duplicate(true)
	_apply()

func _apply():
	_update_preview()
	_save_to_settings()

func _update_preview():
	if _preview_background and is_instance_valid(_preview_background):
		_preview_background.set_background_config(_config)

func _save_to_settings() -> void:
	if not DataManager or not _config_loaded:
		return
	var config_setting = DataManager.get_setting("library_background_config")
	if config_setting:
		_suppress_config_signal = true
		DataManager.set_setting(_config.duplicate(true), config_setting)
		_suppress_config_signal = false

func _on_settings_saved():
	_load_current_config()

func _on_setting_changed(value: Variant, setting: SettingsVar) -> void:
	if _suppress_config_signal:
		return
	if setting.property_name == "library_background_config" and value is Dictionary:
		_load_current_config()

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting into a SubViewport."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return

	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)

	viewport.gui_focus_changed.connect(_on_focus_changed)

	if _effects_designer and _effects_designer.has_method("reconnect_viewport"):
		_effects_designer.reconnect_viewport()
	if _overlay_designer and _overlay_designer.has_method("reconnect_viewport"):
		_overlay_designer.reconnect_viewport()

func _on_focus_changed(control: Control) -> void:
	if not control:
		return
	if _effects_designer and _effects_designer.is_ancestor_of(control):
		if _effects_designer._scroll_container:
			_effects_designer._scroll_container.ensure_control_visible(control)
		return
	if _overlay_designer and _overlay_designer.is_ancestor_of(control):
		if _overlay_designer._scroll_container:
			_overlay_designer._scroll_container.ensure_control_visible(control)
		return
