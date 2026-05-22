# settings_menu.gd
extends VBoxContainer
class_name SettingsMenu

var subgroup_name: String
var variables: Array

const State = SettingsVar.SettingState
const Type = SettingsVar.SettingType
const FSM = preload("res://managers/filesystem_manager.gd")
signal setting_changed(value: Variant, setting: SettingsVar)

func initialize_settings_menu(subgroup : String, settingsvars : Array[SettingsVar]):
	var menu_name_label = M3Label.new()
	menu_name_label.text = subgroup
	menu_name_label.label_style = M3Label.Style.HEADLINE_SMALL
	add_child(menu_name_label)
	build_controls_from_settingsvars(settingsvars)

func build_controls_from_settingsvars(settingsvars: Array[SettingsVar], title: String = "") -> void:
	if title:
		var title_label = M3Label.new()
		title_label.text = title
		title_label.label_style = M3Label.Style.TITLE_MEDIUM
		add_child(title_label)
	
	for settingsvar in settingsvars:
		if settingsvar.state != State.INTERNAL:
			match_var_type(settingsvar)

func update_control_value(property_name: String, value: Variant) -> void:
	var control = controls.get(property_name)
	if not control:
		return
	
	if control is M3Switch:
		control.button_pressed = value
	elif control is M3OptionButton:
		control.selected = value
	elif control is M3Slider:
		control.value = value * control.get_meta("display_scale", 1.0)
	elif control is M3TextField:
		control.text = str(value)
	elif control is ColorPickerButton:
		control.color = value
	elif control is RangeSlider:
		control.set_range(value.x, value.y)

func get_control_value(property_name: String) -> Variant:
	var control = controls.get(property_name)
	if not control:
		return null
	
	if control is M3Switch:
		return control.button_pressed
	elif control is M3OptionButton:
		return control.selected
	elif control is M3Slider:
		return control.value / control.get_meta("display_scale", 1.0)
	elif control is M3TextField:
		return control.text
	elif control is ColorPickerButton:
		return control.color
	elif control is RangeSlider:
		return Vector2(control.range_start, control.range_end)
	return null

func clear_controls() -> void:
	for child in get_children():
		child.queue_free()
	controls.clear()

func refresh_theme() -> void:
	_refresh_theme_recursive(self)

func _refresh_theme_recursive(node: Node) -> void:
	if node.has_method("refresh_theme") and node != self:
		node.refresh_theme()
	for child in node.get_children():
		_refresh_theme_recursive(child)

var controls: Dictionary[String, Control] = {}

func _apply_metadata(control: Control, metadata: Dictionary) -> void:
	"""Apply M3 component-specific properties from SettingsVar metadata."""
	if metadata.is_empty():
		return
	
	if control is M3Slider:
		if metadata.has("show_stops"):
			control.show_stops = metadata["show_stops"]
		if metadata.has("slider_size"):
			match metadata["slider_size"]:
				"EXTRA_SMALL": control.slider_size = M3Slider.Size.EXTRA_SMALL
				"SMALL": control.slider_size = M3Slider.Size.SMALL
				"MEDIUM": control.slider_size = M3Slider.Size.MEDIUM
				"LARGE": control.slider_size = M3Slider.Size.LARGE
				"EXTRA_LARGE": control.slider_size = M3Slider.Size.EXTRA_LARGE
		if metadata.has("label_behavior"):
			match metadata["label_behavior"]:
				"ALWAYS": control.label_behavior = M3Slider.LabelBehavior.ALWAYS
				"WHILE_DRAGGING": control.label_behavior = M3Slider.LabelBehavior.WHILE_DRAGGING
				"NEVER": control.label_behavior = M3Slider.LabelBehavior.NEVER
		if metadata.has("label_formatter"):
			control.label_formatter = metadata["label_formatter"]
		if metadata.has("start_icon_name"):
			control.start_icon_name = metadata["start_icon_name"]
		if metadata.has("end_icon_name"):
			control.end_icon_name = metadata["end_icon_name"]
	elif control is M3TextField or control is M3OptionButton:
		if metadata.has("field_variant"):
			match metadata["field_variant"]:
				"FILLED": control.field_variant = M3TextField.Variant.FILLED
				"OUTLINED": control.field_variant = M3TextField.Variant.OUTLINED
		if metadata.has("leading_icon"):
			control.leading_icon = metadata["leading_icon"]
		if metadata.has("trailing_icon"):
			control.trailing_icon = metadata["trailing_icon"]
	elif control is M3Switch:
		if metadata.has("icon_name"):
			control.icon_name = metadata["icon_name"]

func match_var_type(settingsvar : SettingsVar):
	match settingsvar.type:
		Type.BOOL:
			var hbox = HBoxContainer.new()
			hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			add_child(hbox)
			
			var label = M3Label.new()
			label.text = settingsvar.display_name
			label.label_style = M3Label.Style.BODY_MEDIUM
			label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			hbox.add_child(label)
			
			var switch = M3Switch.new()
			switch.button_pressed = settingsvar.value
			switch.disabled = settingsvar.state != 0
			switch.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			hbox.add_child(switch)
			controls[settingsvar.property_name] = switch
			_apply_metadata(switch, settingsvar.metadata)
			
			switch.toggled.connect(func(pressed: bool):
				emit_signal("setting_changed", pressed, settingsvar)
			)
		Type.ENUM, Type.ARRAY:
			var option_button = M3OptionButton.new()
			option_button.label_text = settingsvar.display_name
			var id = 0
			var matched_index = 0
			for option in settingsvar.options:
				option_button.add_item(str(option), id)
				if settingsvar.value is int and settingsvar.value == id:
					matched_index = id
				elif not settingsvar.value is int and str(option) == str(settingsvar.value):
					matched_index = id
				id += 1
			option_button.selected = matched_index
			option_button.editable = settingsvar.state == 0
			add_child(option_button)
			controls[settingsvar.property_name] = option_button
			_apply_metadata(option_button, settingsvar.metadata)
			option_button.item_selected.connect(func(value: int):
				emit_signal("setting_changed", value, settingsvar)
			)
		Type.FLOAT, Type.INT:
			var slider_label = M3Label.new()
			slider_label.text = settingsvar.display_name
			slider_label.label_style = M3Label.Style.BODY_MEDIUM
			add_child(slider_label)
			
			var display_scale = settingsvar.metadata.get("display_scale", 1.0)
			var display_unit = settingsvar.metadata.get("display_unit", "")
			
			var slider = M3Slider.new()
			slider.slider_size = M3Slider.Size.SMALL
			# Set cached properties before add_child so _ready() picks them up
			slider.min_value = settingsvar.min_value * display_scale
			slider.max_value = settingsvar.max_value * display_scale
			slider.step = settingsvar.step * display_scale
			slider.show_stops = false
			slider.set_meta("display_scale", display_scale)
			
			if not display_unit.is_empty():
				slider.label_formatter = "%.0f" + display_unit.replace("%", "%%")
			
			add_child(slider)
			controls[settingsvar.property_name] = slider
			
			# Properties that need the internal slider to exist must be set after add_child
			slider.value = settingsvar.value * display_scale
			slider.editable = settingsvar.state == 0
			_apply_metadata(slider, settingsvar.metadata)
			
			slider.value_changed.connect(func(display_value: float):
				emit_signal("setting_changed", display_value / display_scale, settingsvar)
			)
		Type.STRING:
			var text_field = M3TextField.new()
			text_field.label_text = settingsvar.display_name
			text_field.text = settingsvar.value if settingsvar.value else ""
			text_field.editable = settingsvar.state == 0
			text_field.secret = settingsvar.encrypted
			add_child(text_field)
			controls[settingsvar.property_name] = text_field
			_apply_metadata(text_field, settingsvar.metadata)
			text_field.text_changed.connect(func(text: String):
				emit_signal("setting_changed", text, settingsvar)
			)
		
		Type.PATH:
			var path_field = M3TextField.new()
			path_field.label_text = settingsvar.display_name
			path_field.text = settingsvar.value if settingsvar.value else ""
			path_field.editable = settingsvar.state == 0
			path_field.focus_mode = Control.FOCUS_NONE
			path_field.virtual_keyboard_enabled = false
			path_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			controls[settingsvar.property_name] = path_field
			_apply_metadata(path_field, settingsvar.metadata)
			
			var browse_button = M3Button.new()
			browse_button.text = "Browse..."
			browse_button.icon_name = "folder-open"
			browse_button.button_variant = M3Button.Variant.OUTLINED
			browse_button.disabled = settingsvar.state != 0
			browse_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			
			var path_row = HBoxContainer.new()
			path_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			path_row.add_child(path_field)
			path_row.add_child(browse_button)
			add_child(path_row)
			
			browse_button.pressed.connect(func():
				var dialog = FileDialog.new()
				dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
				dialog.access = FileDialog.ACCESS_FILESYSTEM
				dialog.use_native_dialog = true
				dialog.current_dir = path_field.text if path_field.text else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
				dialog.title = "Select " + settingsvar.display_name
				
				add_child(dialog)
				
				dialog.dir_selected.connect(func(dir: String):
					var resolved_dir = FSM.resolve_content_uri(dir)
					path_field.text = resolved_dir
					emit_signal("setting_changed", resolved_dir, settingsvar)
					dialog.queue_free()
				)
				
				dialog.canceled.connect(func():
					dialog.queue_free()
				)
				
				dialog.show()
			)
			
			path_field.text_changed.connect(func(text: String):
				emit_signal("setting_changed", text, settingsvar)
			)
		
		Type.VECTOR2:
			var rangeslider_label = M3Label.new()
			rangeslider_label.text = settingsvar.display_name
			rangeslider_label.label_style = M3Label.Style.BODY_MEDIUM
			add_child(rangeslider_label)
			
			var rangeslider = RangeSlider.new(settingsvar.value.x, settingsvar.value.y, 0.05)
			rangeslider.set("_step", 0.05)
			rangeslider.set("range_start", settingsvar.value.x)
			rangeslider.set("range_end", settingsvar.value.y)
			add_child(rangeslider.min)
			add_child(rangeslider.max)
			rangeslider.min.editable = settingsvar.state == 0
			rangeslider.max.editable = settingsvar.state == 0
			controls[settingsvar.property_name] = rangeslider
			rangeslider.value_changed.connect(func(value: Vector2):
				emit_signal("setting_changed", value, settingsvar)
			)
		
		Type.COLOR:
			var color_label = M3Label.new()
			color_label.text = settingsvar.display_name
			color_label.label_style = M3Label.Style.BODY_MEDIUM
			add_child(color_label)
			
			var color_picker = ColorPickerButton.new()
			color_picker.color = settingsvar.value if settingsvar.value is Color else Color.WHITE
			color_picker.disabled = settingsvar.state != 0
			add_child(color_picker)
			controls[settingsvar.property_name] = color_picker
			color_picker.color_changed.connect(func(color: Color):
				emit_signal("setting_changed", color, settingsvar)
			)
		
		Type.GRADIENT:
			var gradient_label = M3Label.new()
			gradient_label.text = settingsvar.display_name
			gradient_label.label_style = M3Label.Style.BODY_MEDIUM
			add_child(gradient_label)
			
			var gradient_edit = GradientEdit.new()
			if settingsvar.value is Gradient:
				gradient_edit.set_gradient(settingsvar.value)
			gradient_edit.custom_minimum_size = Vector2(0, 24)
			add_child(gradient_edit)
			controls[settingsvar.property_name] = gradient_edit
			gradient_edit.gradient_changed.connect(func(gradient: Gradient):
				emit_signal("setting_changed", gradient, settingsvar)
			)
		
		_:
			var button = M3Button.new()
			button.text = settingsvar.display_name
			button.button_variant = M3Button.Variant.TEXT
			add_child(button)
