class_name HeroDesignerView
extends Control

var _media_container: MediaContainer = MediaContainer.new()
var _current_config: Dictionary = {}

var _preview_hero: HeroImage
var _preview_container: Control
var _effect_designer_ui: EffectDesignerUI
var _corner_slider: M3Slider
var _height_preset_btn: M3OptionButton

const HEIGHT_RATIOS = [1.0, 0.66, 0.5, 0.33, 0.0]

func _ready():
	_setup_ui()
	_load_current_config()
	
	# Connect to settings changes
	if SettingsManager:
		SettingsManager.settings_saved.connect(_on_settings_saved)
	
	# Connect to viewport size changes
	if DisplayManager:
		DisplayManager.viewport_size_changed.connect(_on_viewport_size_changed)
	
	# Connect to viewport focus changes to ensure focused items are visible
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	# Setup preview after UI is built
	call_deferred("_setup_preview_hero")

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting into a SubViewport."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return
	
	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)
	
	viewport.gui_focus_changed.connect(_on_focus_changed)
	
	# Reconnect nested EffectDesignerUI viewport
	if _effect_designer_ui and _effect_designer_ui.has_method("reconnect_viewport"):
		_effect_designer_ui.reconnect_viewport()

func _on_focus_changed(control: Control) -> void:
	"""Ensure focused controls are visible."""
	if not control:
		return
	
	# EffectDesignerUI has its own ScrollContainer, forward to it if needed
	if _effect_designer_ui and _effect_designer_ui.is_ancestor_of(control):
		# EffectDesignerUI handles its own scroll via ensure_control_visible
		if _effect_designer_ui._scroll_container:
			_effect_designer_ui._scroll_container.ensure_control_visible(control)

func _on_settings_saved():
	_load_current_config()
	_update_preview()

func _exit_tree():
	if SettingsManager and SettingsManager.settings_saved.is_connected(_on_settings_saved):
		SettingsManager.settings_saved.disconnect(_on_settings_saved)
	if DisplayManager and DisplayManager.viewport_size_changed.is_connected(_on_viewport_size_changed):
		DisplayManager.viewport_size_changed.disconnect(_on_viewport_size_changed)
	if get_viewport() and get_viewport().gui_focus_changed.is_connected(_on_focus_changed):
		get_viewport().gui_focus_changed.disconnect(_on_focus_changed)

func on_view_hide():
	pass

func on_view_show():
	_load_current_config()
	_setup_preview_hero()
	_update_preview()

func _setup_ui():
	var hsplit = HSplitContainer.new()
	hsplit.set_anchors_preset(Control.PRESET_FULL_RECT)
	hsplit.split_offset = 350
	add_child(hsplit)
	
	# Left panel - controls
	var left_panel = Panel.new()
	left_panel.custom_minimum_size = Vector2(350, 0)
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
	
	var title_label = M3Label.new()
	title_label.text = "Hero Designer"
	title_label.label_style = M3Label.Style.HEADLINE_SMALL
	left_vbox.add_child(title_label)
	
	var subtitle_label = M3Label.new()
	subtitle_label.text = "Customize hero image appearance"
	subtitle_label.label_style = M3Label.Style.BODY_SMALL
	left_vbox.add_child(subtitle_label)
	
	left_vbox.add_child(HSeparator.new())
	
	# Global Settings section (similar to Card Designer)
	var global_label = M3Label.new()
	global_label.text = "Global Settings"
	global_label.label_style = M3Label.Style.TITLE_MEDIUM
	left_vbox.add_child(global_label)
	
	var corner_label = M3Label.new()
	corner_label.text = "Hero Rounding (0-1)"
	left_vbox.add_child(corner_label)
	
	_corner_slider = M3Slider.new()
	_corner_slider.min_value = 0.0
	_corner_slider.max_value = 1.0
	_corner_slider.step = 0.01
	_corner_slider.value = 0.06
	_corner_slider.value_changed.connect(_on_corner_radius_changed)
	left_vbox.add_child(_corner_slider)
	
	var height_label = M3Label.new()
	height_label.text = "Hero Height"
	left_vbox.add_child(height_label)
	
	_height_preset_btn = M3OptionButton.new()
	_height_preset_btn.add_item("Full (100%)", 0)
	_height_preset_btn.add_item("Two Thirds (66%)", 1)
	_height_preset_btn.add_item("Half (50%)", 2)
	_height_preset_btn.add_item("One Third (33%)", 3)
	_height_preset_btn.add_item("Hidden (0%)", 4)
	_height_preset_btn.item_selected.connect(_on_height_preset_changed)
	left_vbox.add_child(_height_preset_btn)
	
	left_vbox.add_child(HSeparator.new())
	
	# Add the shared effect designer UI
	_effect_designer_ui = EffectDesignerUI.new()
	_effect_designer_ui.use_internal_scroll = false
	_effect_designer_ui.setup("Effects", "hero", "effects", false)
	_effect_designer_ui.config_changed.connect(_on_config_changed)
	left_vbox.add_child(_effect_designer_ui)
	
	# Right panel - hero preview (needs minimum size for split container)
	var right_panel = Panel.new()
	right_panel.custom_minimum_size = Vector2(400, 300)  # Ensure right panel gets some space
	right_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hsplit.add_child(right_panel)
	
	# Create a container for the hero preview (constrains hero size)
	_preview_container = Control.new()
	_preview_container.name = "PreviewContainer"
	# Anchors will be set by _do_update_preview_size based on settings
	right_panel.add_child(_preview_container)
	
	# Create the hero preview - fills its container based on height ratio
	_preview_hero = preload("res://components/hero_image.tscn").instantiate()
	_preview_hero.set_anchors_preset(Control.PRESET_FULL_RECT)
	_preview_container.add_child(_preview_hero)

func _load_current_config():
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("hero_effect_config")
		if config_setting and config_setting.value is Dictionary:
			_current_config = config_setting.value.duplicate(true)
		else:
			_current_config = _get_default_config()
	else:
		_current_config = _get_default_config()
	
	# Update corner radius slider
	if _corner_slider:
		_corner_slider.value = _current_config.get("corner_radius", 0.06)
	
	# Update height preset dropdown
	if _height_preset_btn:
		var height_index = _current_config.get("hero_height", 0)
		if height_index is int and height_index >= 0 and height_index < HEIGHT_RATIOS.size():
			_height_preset_btn.selected = height_index
	
	# Update effect designer UI
	if _effect_designer_ui:
		_effect_designer_ui.set_config(_current_config)
	
	# Update container state
	_media_container.corner_radius_ratio = _current_config.get("corner_radius", 0.06)
	_media_container.effect_settings = _current_config.get("effects", [])

func _get_default_config() -> Dictionary:
	return {
		"effects": [],
		"corner_radius": 0.06,
		"hero_height": 0
	}

func _setup_preview_hero():
	if not _preview_hero or not is_instance_valid(_preview_hero):
		print("[HeroDesignerView] ERROR: _preview_hero is null or invalid!")
		return
	
	# First update the preview size based on current height setting
	_update_preview_hero_size()
	
	# Then apply the settings (this initializes the EffectStack)
	_update_preview()
	
	# Finally load a random game for preview
	if DataManager:
		var random_game = DataManager.get_random_game()
		if random_game:
			_preview_hero.set_game(random_game)

func _on_config_changed(config: Dictionary):
	_current_config = config.duplicate(true)
	_update_preview()
	_save_to_settings()

func _update_preview():
	if not _preview_hero or not is_instance_valid(_preview_hero):
		print("[HeroDesignerView] ERROR: _preview_hero is null or invalid!")
		return
	
	# Update the hero image config
	_preview_hero.refresh_from_settings()

func _save_to_settings() -> void:
	if not SettingsManager:
		return
	
	var config_setting = SettingsManager.get_setting("hero_effect_config")
	if config_setting:
		SettingsManager.set_setting(_current_config.duplicate(true), config_setting)

func _on_corner_radius_changed(value: float):
	_current_config["corner_radius"] = value
	_media_container.corner_radius_ratio = value
	_update_preview()
	_save_to_settings()

func _on_height_preset_changed(index: int):
	# Update the config with the new height value
	_current_config["hero_height"] = index
	
	# Update the preview hero size
	_update_preview_hero_size()
	_update_preview()
	
	# Save the config to settings
	_save_to_settings()

func _on_viewport_size_changed(_new_size: Vector2):
	# Update preview size when viewport changes
	_update_preview_hero_size()

func _update_preview_hero_size():
	if not _preview_container or not _preview_hero:
		return
	
	# Defer the actual size calculation to ensure layout is ready
	call_deferred("_do_update_preview_size")

func _do_update_preview_size():
	if not _preview_container or not _preview_hero:
		return
	
	# Get the height ratio from the current config
	var height_ratio = HEIGHT_RATIOS[0]  # Default to full
	var height_index = _current_config.get("hero_height", 0)
	if height_index is int and height_index >= 0 and height_index < HEIGHT_RATIOS.size():
		height_ratio = HEIGHT_RATIOS[height_index]
	
	# Check if parent is ready (has valid size)
	var parent = _preview_container.get_parent()
	if not parent or parent.size.y <= 0:
		call_deferred("_do_update_preview_size")
		return
	
	# Use anchor_bottom to set the percentage directly
	# This automatically adjusts as parent size changes
	_preview_container.anchor_left = 0.0
	_preview_container.anchor_right = 1.0
	_preview_container.anchor_top = 0.0
	_preview_container.anchor_bottom = height_ratio
	
	# Remove any custom minimum size that might interfere
	_preview_container.custom_minimum_size = Vector2.ZERO
	_preview_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preview_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	# Force the HeroImage to update its size
	call_deferred("_force_hero_resize")

func _force_hero_resize():
	if not _preview_hero:
		return
	
	# Node may have been reparented (e.g., by SettingsDialog); skip if not in tree
	if not is_inside_tree():
		return
	
	# Wait a frame for the layout to actually update
	await get_tree().process_frame
	
	# Update the EffectStack with the actual container size
	if _preview_hero._effect_stack and _preview_hero._effect_stack.media_container:
		var actual_size = _preview_hero.size
		_preview_hero._effect_stack.media_container.bounds = Rect2(Vector2.ZERO, actual_size)
		_preview_hero._effect_stack.force_refresh()
