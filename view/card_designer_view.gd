class_name CardDesignerView
extends Control

var _card_state: CardState = CardState.new()
var _current_config: Dictionary = {}

var _preview_card: GameCard
var _effects_list: VBoxContainer
var _add_effect_button: MenuButton
var _save_button: Button
var _orientation_btn: OptionButton
var _corner_slider: HSlider

func _ready():
	_setup_ui()
	_load_current_config()
	call_deferred("_setup_preview_card")
	call_deferred("_rebuild_effects_ui")

func _setup_ui():
	var hsplit = HSplitContainer.new()
	hsplit.set_anchors_preset(Control.PRESET_FULL_RECT)
	hsplit.split_offset = 300
	add_child(hsplit)
	
	var left_panel = Panel.new()
	left_panel.custom_minimum_size = Vector2(300, 0)
	hsplit.add_child(left_panel)
	
	var left_scroll = ScrollContainer.new()
	left_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	left_panel.add_child(left_scroll)
	
	var left_vbox = VBoxContainer.new()
	left_scroll.add_child(left_vbox)
	
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
	corner_label.text = "Corner Radius"
	left_vbox.add_child(corner_label)
	
	_corner_slider = HSlider.new()
	_corner_slider.min_value = 0
	_corner_slider.max_value = 50
	_corner_slider.step = 1
	_corner_slider.value = 12
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
	popup.add_item("Border", 0)
	popup.add_item("Platform Badge", 1)
	popup.id_pressed.connect(_on_add_effect)
	
	left_vbox.add_child(HSeparator.new())
	
	_save_button = Button.new()
	_save_button.text = "Save Changes"
	_save_button.pressed.connect(_on_save)
	left_vbox.add_child(_save_button)
	
	var right_panel = Panel.new()
	hsplit.add_child(right_panel)
	
	var preview_container = CenterContainer.new()
	preview_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	right_panel.add_child(preview_container)
	
	_preview_card = preload("res://components/game_card.tscn").instantiate()
	_preview_card.preview_mode = true
	preview_container.add_child(_preview_card)

func _load_current_config():
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			_current_config = config_setting.value.duplicate(true)
		else:
			_current_config = _get_default_config()
	else:
		_current_config = _get_default_config()
	
	_orientation_btn.select(_current_config.get("card_orientation", 0))
	_corner_slider.value = _current_config.get("corner_radius", 12.0)
	
	_card_state.orientation = _current_config.get("card_orientation", 0)
	# Convert corner radius from pixels to ratio
	var corner_pixels = _current_config.get("corner_radius", 12.0)
	_card_state.corner_radius_ratio = corner_pixels / 202.0
	_card_state.effect_settings = _current_config.get("effects", [])

func _get_default_config() -> Dictionary:
	return {
		"effects": [],
		"card_orientation": 0,
		"corner_radius": 12.0
	}

func _setup_preview_card():
	if not _preview_card or not is_instance_valid(_preview_card):
		return
	
	var state = CardState.new()
	state.orientation = _current_config.get("card_orientation", 0)
	# Convert corner radius from pixels to ratio
	var corner_pixels = _current_config.get("corner_radius", 12.0)
	state.corner_radius_ratio = corner_pixels / 202.0
	state.effect_settings = _current_config.get("effects", []).duplicate(true)
	state.zoom_level = 1.5
	
	_preview_card.set_card_state(state)

func _rebuild_effects_ui():
	for child in _effects_list.get_children():
		child.queue_free()
	
	var effects = _current_config.get("effects", [])
	for i in range(effects.size()):
		var effect_data = effects[i]
		_create_effect_ui(effect_data, i)

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
				setting.value = current_settings[setting.property_name]
		
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
	
	if new_effect:
		var effects = _current_config.get("effects", [])
		effects.append(new_effect)
		_current_config["effects"] = effects
		_card_state.effect_settings = effects
		_rebuild_effects_ui()
		_update_preview()

func _on_remove_effect(index: int):
	var effects = _current_config.get("effects", [])
	if index >= 0 and index < effects.size():
		effects.remove_at(index)
		_current_config["effects"] = effects
		_card_state.effect_settings = effects
		_rebuild_effects_ui()
		_update_preview()

func _on_effect_setting_changed(effect_index: int, setting_name: String, value: Variant):
	var effects = _current_config.get("effects", [])
	if effect_index >= 0 and effect_index < effects.size():
		if not effects[effect_index].has("settings"):
			effects[effect_index]["settings"] = {}
		effects[effect_index]["settings"][setting_name] = value
		_update_preview()

func _on_orientation_changed(index: int):
	_current_config["card_orientation"] = index
	_card_state.orientation = index
	_card_state.zoom_level = 1.5
	_update_preview()

func _on_corner_radius_changed(value: float):
	_current_config["corner_radius"] = value
	_card_state.corner_radius_ratio = value / 202.0
	_card_state.zoom_level = 1.5
	_update_preview()

func _update_preview():
	if not _preview_card or not is_instance_valid(_preview_card):
		return
	
	var state = CardState.new()
	state.orientation = _current_config.get("card_orientation", 0)
	# Convert corner radius from pixels to ratio
	var corner_pixels = _current_config.get("corner_radius", 12.0)
	state.corner_radius_ratio = corner_pixels / 202.0
	state.effect_settings = _current_config.get("effects", []).duplicate(true)
	state.zoom_level = 1.5
	state.game_texture = _preview_card._current_texture
	
	_preview_card.set_card_state(state)

func _on_save():
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting:
			SettingsManager.set_setting(_current_config.duplicate(true), config_setting)
			SettingsManager.save_settings()
			NotificationManager.show_notification("Card design saved", Notification.Type.SUCCESS)
