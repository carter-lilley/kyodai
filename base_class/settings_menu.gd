# settings_menu.gd
extends VBoxContainer
class_name SettingsMenu

var subgroup_name: String
var variables: Array

const State = SettingsVar.SettingState
const Type = SettingsVar.SettingType
signal setting_changed(value: Variant, setting: SettingsVar)

func initialize_settings_menu(subgroup : String, settingsvars : Array[SettingsVar]):
	var menu_name_label = Label.new()
	menu_name_label.text = subgroup
	add_child(menu_name_label)
	build_controls_from_settingsvars(settingsvars)

func build_controls_from_settingsvars(settingsvars: Array[SettingsVar], title: String = "") -> void:
	if title:
		var title_label = Label.new()
		title_label.text = title
		title_label.add_theme_font_size_override("font_size", 16)
		add_child(title_label)
	
	for settingsvar in settingsvars:
		print("[SettingsMenu] Processing setting: ", settingsvar.display_name, " state: ", settingsvar.state, " INTERNAL?: ", settingsvar.state == State.INTERNAL)
		if settingsvar.state != State.INTERNAL:
			print("[SettingsMenu]   -> Adding to menu")
			match_var_type(settingsvar)
		else:
			print("[SettingsMenu]   -> SKIPPING (INTERNAL)")

func update_control_value(property_name: String, value: Variant) -> void:
	var control = controls.get(property_name)
	if not control:
		return
	
	if control is CheckBox:
		control.button_pressed = value
	elif control is OptionButton:
		control.select(value)
	elif control is HSlider:
		control.value = value
	elif control is LineEdit:
		control.text = str(value)
	elif control is ColorPickerButton:
		control.color = value
	elif control is RangeSlider:
		control.set_range(value.x, value.y)

func get_control_value(property_name: String) -> Variant:
	var control = controls.get(property_name)
	if not control:
		return null
	
	if control is CheckBox:
		return control.button_pressed
	elif control is OptionButton:
		return control.selected
	elif control is HSlider:
		return control.value
	elif control is LineEdit:
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

var controls: Dictionary[String, Control] = {}
func match_var_type(settingsvar : SettingsVar):
	match settingsvar.type:
		Type.BOOL:
			var check_box = CheckBox.new()
			check_box.text = settingsvar.display_name
			check_box.button_pressed = settingsvar.value
			add_child(check_box)
			check_box.disabled = settingsvar.state
			controls[settingsvar.property_name] = check_box
			check_box.toggled.connect(func(pressed: bool):
				emit_signal("setting_changed", pressed, settingsvar)
			)
		Type.ENUM, Type.ARRAY:
			var option_button = OptionButton.new()
			var option_label = Label.new()
			option_label.text = settingsvar.display_name
			var id = 0
			for option in settingsvar.options:
				option_button.add_item(str(option), id)
				# For enums (ints), match by index
				if settingsvar.type == Type.ENUM and settingsvar.value == id:
					option_button.select(id)
				# For arrays, match by actual value (string or Vector2)
				elif settingsvar.type == Type.ARRAY and str(option) == str(settingsvar.value):
					option_button.select(id)
				id += 1
			add_child(option_label)
			add_child(option_button)
			option_button.disabled = settingsvar.state
			controls[settingsvar.property_name] = option_button
			option_button.item_selected.connect(func(value: int):
				emit_signal("setting_changed", value, settingsvar)
			)
		Type.FLOAT, Type.INT:
			var slider = HSlider.new()
			slider.focus_mode = 2
			slider.min_value = settingsvar.min_value
			slider.max_value = settingsvar.max_value
			slider.step = settingsvar.step
			slider.value = settingsvar.value  # Default value if not provided
			var slider_label = Label.new()
			slider_label.text = settingsvar.display_name
			add_child(slider_label)
			add_child(slider)
			slider.editable = settingsvar.state == 0
			controls[settingsvar.property_name] = slider
			slider.value_changed.connect(func(value: float):
				emit_signal("setting_changed", value, settingsvar)
			)
		Type.STRING:
			var string_label = Label.new()
			string_label.text = settingsvar.display_name
			add_child(string_label)
			
			var line_edit = LineEdit.new()
			line_edit.text = settingsvar.value if settingsvar.value else ""
			line_edit.editable = settingsvar.state == 0
			line_edit.secret = settingsvar.encrypted
			add_child(line_edit)
			controls[settingsvar.property_name] = line_edit
			line_edit.text_changed.connect(func(text: String):
				emit_signal("setting_changed", text, settingsvar)
			)
		
		Type.PATH:
			var path_label = Label.new()
			path_label.text = settingsvar.display_name
			add_child(path_label)
			
			var path_container = HBoxContainer.new()
			add_child(path_container)
			
			var line_edit = LineEdit.new()
			line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			line_edit.text = settingsvar.value if settingsvar.value else ""
			line_edit.editable = settingsvar.state == 0
			path_container.add_child(line_edit)
			controls[settingsvar.property_name] = line_edit
			
			var browse_button = Button.new()
			browse_button.text = "Browse..."
			browse_button.disabled = settingsvar.state != 0
			path_container.add_child(browse_button)
			
			browse_button.pressed.connect(func():
				var dialog = FileDialog.new()
				dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
				dialog.access = FileDialog.ACCESS_FILESYSTEM
				dialog.use_native_dialog = true  # Use OS native file picker!
				dialog.current_dir = line_edit.text if line_edit.text else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
				dialog.title = "Select " + settingsvar.display_name
				
				add_child(dialog)
				
				dialog.dir_selected.connect(func(dir: String):
					line_edit.text = dir
					emit_signal("setting_changed", dir, settingsvar)
					dialog.queue_free()
				)
				
				dialog.canceled.connect(func():
					dialog.queue_free()
				)
				
				dialog.show()
			)
			
			line_edit.text_changed.connect(func(text: String):
				emit_signal("setting_changed", text, settingsvar)
			)
		
		Type.VECTOR2: # Replace with a real range slider eventually
			var rangeslider = RangeSlider.new(settingsvar.value.x, settingsvar.value.y, 0.05)
			#fix setting after creation
			rangeslider.set("_step",0.05)
			rangeslider.set("range_start",settingsvar.value.x)
			#print("SETTING RANGE START ", settingsvar.value.x)
			rangeslider.set("range_end",settingsvar.value.y)
			var rangeslider_label = Label.new()
			rangeslider_label.text = settingsvar.display_name
			add_child(rangeslider_label)
			add_child(rangeslider.min)
			add_child(rangeslider.max)
			rangeslider.min.editable = settingsvar.state == 0
			rangeslider.max.editable = settingsvar.state == 0
			controls[settingsvar.property_name] = rangeslider
			rangeslider.value_changed.connect(func(value: Vector2):
				emit_signal("setting_changed", value, settingsvar)
			)
		
		Type.COLOR:
			var color_label = Label.new()
			color_label.text = settingsvar.display_name
			add_child(color_label)
			
			var color_picker = ColorPickerButton.new()
			color_picker.color = settingsvar.value if settingsvar.value is Color else Color.WHITE
			color_picker.disabled = settingsvar.state != 0
			add_child(color_picker)
			controls[settingsvar.property_name] = color_picker
			color_picker.color_changed.connect(func(color: Color):
				emit_signal("setting_changed", color, settingsvar)
			)
		
		_:
			var button = Button.new()
			button.text = settingsvar.display_name
			add_child(button)
