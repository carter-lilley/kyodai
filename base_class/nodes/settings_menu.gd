# settings_menu.gd
extends VBoxContainer
class_name SettingsMenu

var subgroup_name: String
var variables: Array

var accent_color: Color = Color.TRANSPARENT

# Rows are rendered into SettingsSection cards (header + rounded surface card
# with separators). Reused when no new title is given.
var _current_section: SettingsSection = null

# Small-viewport (compact) state: descriptions hidden, titles single-line,
# trailing controls width-capped.
var _compact: bool = false
var _label_blocks: Array[Dictionary] = []  # [{title, description}]
var _trailing_controls: Array[Control] = []
var _sections: Array[SettingsSection] = []

const COMPACT_TRAILING_MAX_WIDTH_DP := 200.0

const State = SettingsVar.SettingState
const Type = SettingsVar.SettingType
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
signal setting_changed(value: Variant, setting: SettingsVar)

func _init() -> void:
	add_theme_constant_override("separation", int(M3Units.dp(16)))
	setting_changed.connect(func(_value, _setting): _update_visibility())

func _ready() -> void:
	call_deferred("_reevaluate_compact")

func _enter_tree() -> void:
	# Live re-tier when the viewport crosses the small breakpoint (incl. DS
	# swaps while a settings page is open). Connect on every tree entry, not
	# just _ready: settings pages are cached and remove_child/add_child'd on
	# category switches, and _ready only runs once per node lifetime, so a
	# reconnect here is the only way the connection survives page caching.
	if SystemManager.display and not SystemManager.display.viewport_size_changed.is_connected(_reevaluate_compact):
		SystemManager.display.viewport_size_changed.connect(_reevaluate_compact)
	# Heal any fold transition missed while disconnected.
	call_deferred("_reevaluate_compact")

func _exit_tree() -> void:
	if SystemManager.display and SystemManager.display.viewport_size_changed.is_connected(_reevaluate_compact):
		SystemManager.display.viewport_size_changed.disconnect(_reevaluate_compact)

func _reevaluate_compact(_new_size: Vector2 = Vector2.ZERO) -> void:
	var small := true
	if SystemManager.display:
		small = SystemManager.display.is_small_viewport()
	else:
		var viewport := get_viewport()
		if viewport:
			small = viewport.get_visible_rect().size.x < M3Units.dp(DisplaySubManager.SMALL_VIEWPORT_DP)
	set_compact(small)

func set_compact(small: bool) -> void:
	if _compact == small:
		return
	_compact = small
	add_theme_constant_override("separation", int(M3Units.dp(10.0 if small else 16.0)))
	for block in _label_blocks:
		var title: M3Label = block.get("title")
		var description: M3Label = block.get("description")
		if is_instance_valid(description):
			description.visible = not small
		if is_instance_valid(title):
			if small:
				title.autowrap_mode = TextServer.AUTOWRAP_OFF
				title.clip_text = true
				title.text_overrun_behavior = TextServer.OVERRUN_TRIM_WORD_ELLIPSIS
				title.max_lines_visible = 1
			else:
				title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
				title.clip_text = false
				title.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
				title.max_lines_visible = -1
	for control in _trailing_controls:
		if is_instance_valid(control):
			control.custom_maximum_size = Vector2(M3Units.dp(COMPACT_TRAILING_MAX_WIDTH_DP), -1) if small else Vector2(-1, -1)
	for section in _sections:
		if is_instance_valid(section):
			section.compact = small

func initialize_settings_menu(subgroup : String, settingsvars : Array[SettingsVar], icon : String = ""):
	_current_section = SettingsSection.new(subgroup, icon)
	_sections.append(_current_section)
	add_child(_current_section)
	build_controls_from_settingsvars(settingsvars)

func build_controls_from_settingsvars(settingsvars: Array[SettingsVar], title: String = "", icon: String = "") -> void:
	if not title.is_empty() or _current_section == null:
		_current_section = SettingsSection.new(title, icon)
		_sections.append(_current_section)
		add_child(_current_section)

	for settingsvar in settingsvars:
		if settingsvar.state != State.INTERNAL:
			match_var_type(settingsvar)
	_update_visibility()

func _add_setting_row(content: Control, trailing: Array[Control] = []) -> void:
	var row = _current_section.add_row(content, trailing)
	for control in trailing:
		if control != null:
			_trailing_controls.append(control)
			if _compact:
				control.custom_maximum_size = Vector2(M3Units.dp(COMPACT_TRAILING_MAX_WIDTH_DP), -1)
	if not _building_property.is_empty():
		_rows_by_property[_building_property] = {"section": _current_section, "row": row}

func _add_setting_content(content: Control) -> void:
	_current_section.add_content(content)

## Title + optional description block used at the leading edge of rows.
func _make_label_block(settingsvar: SettingsVar) -> VBoxContainer:
	var block := VBoxContainer.new()
	block.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# PASS so touch drags bubble through to an ancestor ScrollContainer.
	block.mouse_filter = Control.MOUSE_FILTER_PASS
	block.add_theme_constant_override("separation", int(M3Units.dp(2)))

	var title := M3Label.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	title.text = settingsvar.display_name
	title.label_style = M3Label.Style.BODY_LARGE
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if _compact:
		title.autowrap_mode = TextServer.AUTOWRAP_OFF
		title.clip_text = true
		title.text_overrun_behavior = TextServer.OVERRUN_TRIM_WORD_ELLIPSIS
		title.max_lines_visible = 1
	block.add_child(title)

	var description: M3Label = null
	if not settingsvar.description.is_empty():
		description = M3Label.new()
		description.mouse_filter = Control.MOUSE_FILTER_IGNORE
		description.text = settingsvar.description
		description.label_style = M3Label.Style.BODY_SMALL
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		# M3Label owns font_color; use its variant-color switch rather than an
		# override (which _apply_style would clobber).
		description.use_on_surface_variant = true
		description.visible = not _compact
		block.add_child(description)

	_label_blocks.append({"title": title, "description": description})
	return block

func update_control_value(property_name: String, value: Variant) -> void:
	var control = controls.get(property_name)
	if not control:
		return
	
	if control is M3Switch:
		control.button_pressed = value
	elif control is M3OptionButton:
		if value is int:
			control.selected = value
		else:
			# ARRAY type may store non-int values (e.g., Vector2i for resolution).
			# Look up the matching index from the stored options.
			var options = control.get_meta("options", [])
			var matched_index = 0
			for i in range(options.size()):
				if str(options[i]) == str(value):
					matched_index = i
					break
			control.selected = matched_index
	elif control is M3Slider:
		# The unlimited tick stores 0 and parks the handle at max_value.
		if control.get_meta("unlimited_tick", false) and value is int and value == 0:
			control.value = control.max_value
		else:
			control.value = value * control.get_meta("display_scale", 1.0)
	elif control is M3TextField:
		control.text = str(value)
		control.refresh_visuals()
	elif control is M3ColorPicker:
		control.color = value
	elif control is RangeSlider:
		control.set_range(value.x, value.y)
	elif control is GradientEdit:
		if value is Gradient:
			control.set_gradient(value)
	elif control is AngleDial:
		control.set_angle(value)
		var spinbox = control.get_meta("spinbox", null)
		if spinbox:
			spinbox.value = value

func get_control_value(property_name: String) -> Variant:
	var control = controls.get(property_name)
	if not control:
		return null
	
	if control is M3Switch:
		return control.button_pressed
	elif control is M3OptionButton:
		return control.selected
	elif control is M3Slider:
		if control.get_meta("unlimited_tick", false) and control.value >= control.max_value:
			return 0
		return control.value / control.get_meta("display_scale", 1.0)
	elif control is M3TextField:
		return control.text
	elif control is M3ColorPicker:
		return control.color
	elif control is RangeSlider:
		return Vector2(control.range_start, control.range_end)
	elif control is GradientEdit:
		return control.get_gradient()
	elif control is AngleDial:
		return control.get_angle()
	return null

func clear_controls() -> void:
	for child in get_children():
		child.queue_free()
	controls.clear()
	_rows_by_property.clear()
	_visibility_rules.clear()
	_current_section = null

func refresh_all_control_values() -> void:
	for property_name in controls.keys():
		var setting = DataManager.get_setting(property_name)
		if setting:
			update_control_value(property_name, setting.value)

func refresh_theme() -> void:
	_refresh_theme_recursive(self)

func refresh_scale() -> void:
	add_theme_constant_override("separation", int(M3Units.dp(16)))
	for control in controls.values():
		if not is_instance_valid(control):
			continue
		if control.has_meta("trailing_width"):
			var trailing: Array = control.get_meta("trailing_width")
			control.custom_minimum_size.x = _trailing_width(trailing[0], trailing[1])
		if control is AngleDial and control.has_meta("spinbox"):
			var spinbox: SpinBox = control.get_meta("spinbox")
			if spinbox and spinbox.has_meta("width_dp"):
				spinbox.custom_minimum_size.x = M3Units.dp(spinbox.get_meta("width_dp"))
	refresh_theme()

func _refresh_theme_recursive(node: Node) -> void:
	if node.has_method("refresh_theme") and node != self:
		node.refresh_theme()
	for child in node.get_children():
		_refresh_theme_recursive(child)

var controls: Dictionary[String, Control] = {}

# Conditional row visibility: SettingsVar metadata key "visible_if" with
# {"property": <controlling property_name>, "values": [<allowed values>]}.
# Rows without the key are always visible; values persist while hidden.
var _rows_by_property: Dictionary = {}
var _visibility_rules: Array = []
var _building_property: String = ""

func _update_visibility() -> void:
	for rule in _visibility_rules:
		var entry = _rows_by_property.get(rule["target"])
		if entry == null:
			continue
		var controlling = get_control_value(rule["property"])
		var row_visible = false
		for allowed in rule["values"]:
			if str(controlling) == str(allowed):
				row_visible = true
				break
		entry["section"].set_row_visible(entry["row"], row_visible)

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

func _apply_accent(control: Control) -> void:
	"""Apply accent color to supported M3 components."""
	if accent_color == Color.TRANSPARENT:
		return
	if control is M3Slider or control is M3Switch or control is M3TextField or control is M3ColorPicker:
		control.accent_color = accent_color

## Trailing control width in px; overridable per-setting via the
## "control_width" metadata key (dp).
func _trailing_width(settingsvar: SettingsVar, default_dp: float) -> float:
	return M3Units.dp(settingsvar.metadata.get("control_width", default_dp))

## Sets the trailing width and records the inputs so refresh_scale() can
## re-bake it without a full rebuild.
func _set_trailing_width(control: Control, settingsvar: SettingsVar, default_dp: float) -> void:
	control.custom_minimum_size.x = _trailing_width(settingsvar, default_dp)
	control.set_meta("trailing_width", [settingsvar, default_dp])

func match_var_type(settingsvar : SettingsVar):
	_building_property = settingsvar.property_name
	var rule = settingsvar.metadata.get("visible_if", {})
	if rule is Dictionary and not rule.is_empty():
		_visibility_rules.append({
			"target": settingsvar.property_name,
			"property": rule.get("property", ""),
			"values": rule.get("values", []),
		})
	match settingsvar.type:
		Type.BOOL:
			var switch = M3Switch.new()
			switch.button_pressed = settingsvar.value
			# For dual_screen_mode, disable the switch if no second display is available
			var is_disabled = settingsvar.state != 0
			if settingsvar.property_name == "dual_screen_mode" and SystemManager.display and not SystemManager.display.is_dual_screen_available():
				is_disabled = true
			switch.disabled = is_disabled
			if is_disabled:
				switch.focus_mode = Control.FOCUS_NONE
			switch.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
			switch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			_add_setting_row(_make_label_block(settingsvar), [switch])
			controls[settingsvar.property_name] = switch
			_apply_metadata(switch, settingsvar.metadata)
			_apply_accent(switch)
			
			# Connect to dual screen availability changes for dynamic enable/disable
			if settingsvar.property_name == "dual_screen_mode" and SystemManager.display:
				if not SystemManager.display.dual_screen_availability_changed.is_connected(_on_dual_screen_availability_changed):
					SystemManager.display.dual_screen_availability_changed.connect(_on_dual_screen_availability_changed)
			
			switch.toggled.connect(func(pressed: bool):
				emit_signal("setting_changed", pressed, settingsvar)
			)
		Type.ENUM, Type.ARRAY:
			var option_button = M3OptionButton.new()
			# Row carries the label; keep the field's floating label empty.
			option_button.label_text = ""
			option_button.fit_to_longest_item = false
			_set_trailing_width(option_button, settingsvar, 220.0)
			option_button.size_flags_horizontal = Control.SIZE_SHRINK_END
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
			# Store options for reverse lookup when refreshing values
			option_button.set_meta("options", settingsvar.options.duplicate())
			_add_setting_row(_make_label_block(settingsvar), [option_button])
			controls[settingsvar.property_name] = option_button
			_apply_metadata(option_button, settingsvar.metadata)
			_apply_accent(option_button)
			option_button.item_selected.connect(func(value: int):
				emit_signal("setting_changed", value, settingsvar)
			)
		Type.FLOAT, Type.INT:
			var display_scale = settingsvar.metadata.get("display_scale", 1.0)
			var display_unit = settingsvar.metadata.get("display_unit", "")
			# Appends one step past max_value that stores 0 and labels itself
			# "Unlimited" (see M3Slider.max_value_label).
			var unlimited_tick: bool = settingsvar.metadata.get("unlimited_tick", false)

			var slider = M3Slider.new()
			slider.slider_size = M3Slider.Size.EXTRA_SMALL
			# Set cached properties before add_child so _ready() picks them up
			slider.min_value = settingsvar.min_value * display_scale
			slider.max_value = settingsvar.max_value * display_scale
			if unlimited_tick:
				slider.max_value += settingsvar.step * display_scale
				slider.max_value_label = "Unlimited"
			slider.step = settingsvar.step * display_scale
			slider.show_stops = false
			slider.set_meta("display_scale", display_scale)
			slider.set_meta("unlimited_tick", unlimited_tick)
			_set_trailing_width(slider, settingsvar, 220.0)
			slider.size_flags_horizontal = Control.SIZE_SHRINK_END

			if not display_unit.is_empty():
				slider.label_formatter = "%.0f" + display_unit.replace("%", "%%")

			_add_setting_row(_make_label_block(settingsvar), [slider])
			controls[settingsvar.property_name] = slider

			# Properties that need the internal slider to exist must be set after add_child
			if unlimited_tick and settingsvar.value is int and settingsvar.value == 0:
				slider.value = slider.max_value
			else:
				slider.value = settingsvar.value * display_scale
			slider.editable = settingsvar.state == 0
			_apply_metadata(slider, settingsvar.metadata)
			_apply_accent(slider)

			slider.value_changed.connect(func(display_value: float):
				var new_value: Variant = display_value / display_scale
				if settingsvar.type == Type.INT:
					new_value = int(round(new_value))
				if unlimited_tick and display_value >= slider.max_value:
					new_value = 0
				emit_signal("setting_changed", new_value, settingsvar)
			)
		Type.STRING:
			var text_field = M3TextField.new()
			# Row carries the label; keep the field's floating label empty.
			text_field.label_text = ""
			text_field.text = settingsvar.value if settingsvar.value else ""
			text_field.editable = settingsvar.state == 0
			text_field.secret = settingsvar.encrypted
			_set_trailing_width(text_field, settingsvar, 240.0)
			text_field.size_flags_horizontal = Control.SIZE_SHRINK_END
			_add_setting_row(_make_label_block(settingsvar), [text_field])
			controls[settingsvar.property_name] = text_field
			_apply_metadata(text_field, settingsvar.metadata)
			_apply_accent(text_field)
			text_field.text_changed.connect(func(text: String):
				emit_signal("setting_changed", text, settingsvar)
			)
		
		Type.PATH:
			var is_file_dialog = settingsvar.metadata.get("dialog", "folder") == "file"
			var path_field = M3TextField.new()
			path_field.label_text = ""
			path_field.text = settingsvar.value if settingsvar.value else ""
			path_field.editable = settingsvar.state == 0
			path_field.focus_mode = Control.FOCUS_NONE
			path_field.virtual_keyboard_enabled = false
			path_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			controls[settingsvar.property_name] = path_field
			_apply_metadata(path_field, settingsvar.metadata)
			_apply_accent(path_field)

			var browse_button = M3Button.new()
			browse_button.text = "Browse..."
			browse_button.icon_name = "file" if is_file_dialog else "folder-open"
			browse_button.button_variant = M3Button.Variant.OUTLINED
			browse_button.disabled = settingsvar.state != 0
			browse_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER

			var path_controls = HBoxContainer.new()
			path_controls.add_theme_constant_override("separation", int(M3Units.dp(8)))
			# Keep the trailing group compact (like other control types) so the
			# label block isn't squeezed into word-per-line wrapping on
			# high-dp screens; long paths elide inside the field instead.
			path_controls.size_flags_horizontal = Control.SIZE_SHRINK_END
			_set_trailing_width(path_field, settingsvar, 140.0)
			path_controls.add_child(path_field)
			path_controls.add_child(browse_button)

			var clear_button: M3Button = null
			if is_file_dialog:
				clear_button = M3Button.new()
				clear_button.icon_name = "close"
				clear_button.button_variant = M3Button.Variant.TEXT
				clear_button.disabled = settingsvar.state != 0
				clear_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				clear_button.visible = not path_field.text.is_empty()
				path_controls.add_child(clear_button)
				clear_button.pressed.connect(func():
					path_field.text = ""
					path_field.refresh_visuals()
					clear_button.visible = false
					emit_signal("setting_changed", "", settingsvar)
				)

			_add_setting_row(_make_label_block(settingsvar), [path_controls])

			if is_file_dialog:
				var filters: PackedStringArray = settingsvar.metadata.get("filters", [])
				browse_button.pressed.connect(func():
					UIManager.show_file_dialog("Select " + settingsvar.display_name, filters, path_field.text.get_base_dir(), func(file: String):
						path_field.text = file
						path_field.refresh_visuals()
						if clear_button:
							clear_button.visible = true
						emit_signal("setting_changed", file, settingsvar)
					)
				)
			else:
				browse_button.pressed.connect(func():
					UIManager.show_folder_dialog("Select " + settingsvar.display_name, path_field.text, func(dir: String):
						path_field.text = dir
						path_field.refresh_visuals()
						emit_signal("setting_changed", dir, settingsvar)
					)
				)

			path_field.text_changed.connect(func(text: String):
				if clear_button:
					clear_button.visible = not text.is_empty()
				emit_signal("setting_changed", text, settingsvar)
			)
		
		Type.VECTOR2:
			var rangeslider = RangeSlider.new(settingsvar.value.x, settingsvar.value.y, settingsvar.step, settingsvar.min_value, settingsvar.max_value)
			_set_trailing_width(rangeslider, settingsvar, 220.0)
			rangeslider.size_flags_horizontal = Control.SIZE_SHRINK_END
			rangeslider.editable = settingsvar.state == 0
			_add_setting_row(_make_label_block(settingsvar), [rangeslider])
			controls[settingsvar.property_name] = rangeslider
			rangeslider.value_changed.connect(func(value: Vector2):
				emit_signal("setting_changed", value, settingsvar)
			)
		
		Type.COLOR:
			var color_picker = M3ColorPicker.new()
			color_picker.color = settingsvar.value if settingsvar.value is Color else Color.WHITE
			color_picker.disabled = settingsvar.state != 0
			_add_setting_row(_make_label_block(settingsvar), [color_picker])
			controls[settingsvar.property_name] = color_picker
			_apply_accent(color_picker)
			color_picker.color_changed.connect(func(color: Color):
				emit_signal("setting_changed", color, settingsvar)
			)
		
		Type.GRADIENT:
			var gradient_edit = GradientEdit.new()
			if settingsvar.value is Gradient:
				gradient_edit.set_gradient(settingsvar.value)
			gradient_edit.custom_minimum_size.y = 24
			_set_trailing_width(gradient_edit, settingsvar, 220.0)
			gradient_edit.size_flags_horizontal = Control.SIZE_SHRINK_END
			_add_setting_row(_make_label_block(settingsvar), [gradient_edit])
			controls[settingsvar.property_name] = gradient_edit
			gradient_edit.gradient_changed.connect(func(gradient: Gradient):
				emit_signal("setting_changed", gradient, settingsvar)
			)

		Type.ANGLE:
			var dial = AngleDial.new()
			var initial_angle = settingsvar.value if settingsvar.value is float or settingsvar.value is int else 0.0
			dial.set_angle(initial_angle)
			dial.default_angle = initial_angle
			dial.editable = settingsvar.state == 0
			dial.custom_minimum_size = Vector2(48, 48)
			dial.size_flags_vertical = Control.SIZE_SHRINK_CENTER

			var spinbox = SpinBox.new()
			spinbox.min_value = settingsvar.min_value
			spinbox.max_value = settingsvar.max_value
			spinbox.step = settingsvar.step
			spinbox.value = initial_angle
			spinbox.editable = settingsvar.state == 0
			spinbox.suffix = "°"
			spinbox.custom_minimum_size.x = M3Units.dp(90.0)
			spinbox.set_meta("width_dp", 90.0)
			spinbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER

			var angle_controls = HBoxContainer.new()
			angle_controls.add_theme_constant_override("separation", int(M3Units.dp(8)))
			angle_controls.add_child(dial)
			angle_controls.add_child(spinbox)
			angle_controls.size_flags_horizontal = Control.SIZE_SHRINK_END

			_add_setting_row(_make_label_block(settingsvar), [angle_controls])
			controls[settingsvar.property_name] = dial
			dial.set_meta("spinbox", spinbox)

			var updating := {"active": false}
			dial.angle_changed.connect(func(value: float):
				if updating.active:
					return
				updating.active = true
				spinbox.value = value
				updating.active = false
				emit_signal("setting_changed", value, settingsvar)
			)
			spinbox.value_changed.connect(func(value: float):
				if updating.active:
					return
				updating.active = true
				dial.set_angle(value)
				updating.active = false
				emit_signal("setting_changed", value, settingsvar)
			)

		_:
			var button = M3Button.new()
			button.text = settingsvar.display_name
			button.button_variant = M3Button.Variant.TEXT
			_add_setting_content(button)

func _on_dual_screen_availability_changed(available: bool) -> void:
	"""Update the dual_screen_mode switch when display availability changes."""
	var switch = controls.get("dual_screen_mode")
	if not switch or not switch is M3Switch:
		return
	
	var settingsvar = DataManager.get_setting("dual_screen_mode")
	var is_disabled = settingsvar.state != 0 if settingsvar else false
	if not available:
		is_disabled = true
	
	switch.disabled = is_disabled
	if is_disabled:
		switch.focus_mode = Control.FOCUS_NONE
	else:
		switch.focus_mode = Control.FOCUS_ALL
