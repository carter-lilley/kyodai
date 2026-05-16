class_name SettingsDialog
extends M3Dialog

## Fullscreen settings dialog with two-pane layout.
## Creates category content directly from SettingsManager subgroups instead of
## extracting from a SettingsView TabContainer.

const SUBGROUP_ICONS: Dictionary[String, String] = {
	"Audio": "volume-high",
	"Display": "monitor",
	"Save Sync": "sync",
	"Storage": "harddisk",
	"Library Appearance": "palette",
}

var _left_pane: VBoxContainer
var _right_pane: MarginContainer
var _right_content: Control
var _category_buttons: Dictionary[String, M3Button] = {}
var _category_contents: Dictionary[String, Control] = {}
var _current_category: String = ""
var _library_settings_view: SettingsView

func _init():
	dialog_variant = Variant.FULL_SCREEN
	title_text = "Settings"
	persistent = true
	super._init()

func _ready():
	super._ready()
	_build_two_pane_layout()
	await _build_categories()
	
	# Hide default title/body labels — we use the top bar title only
	if _title_label:
		_title_label.visible = false
	if _body_label:
		_body_label.visible = false

func _build_two_pane_layout() -> void:
	"""Build two-pane HBox inside content_slot: sidebar + divider + content pane."""
	
	for child in content_slot.get_children():
		child.queue_free()
	
	var hbox = HBoxContainer.new()
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_slot.add_child(hbox)
	
	# Left sidebar
	_left_pane = VBoxContainer.new()
	_left_pane.custom_minimum_size = Vector2(M3Units.dp(200), 0)
	_left_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_pane.add_theme_constant_override("separation", M3Units.dp(4))
	
	var left_margin = MarginContainer.new()
	left_margin.add_theme_constant_override("margin_left", M3Units.dp(12))
	left_margin.add_theme_constant_override("margin_right", M3Units.dp(12))
	left_margin.add_theme_constant_override("margin_top", M3Units.dp(16))
	left_margin.add_theme_constant_override("margin_bottom", M3Units.dp(16))
	left_margin.add_child(_left_pane)
	hbox.add_child(left_margin)
	
	# Divider
	var divider = VSeparator.new()
	var divider_sb = StyleBoxLine.new()
	divider_sb.color = Color(0.5, 0.5, 0.5, 0.2)
	divider_sb.thickness = 1
	divider.add_theme_stylebox_override("separator", divider_sb)
	hbox.add_child(divider)
	
	# Right content pane
	_right_pane = MarginContainer.new()
	_right_pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_right_pane.add_theme_constant_override("margin_left", M3Units.dp(16))
	_right_pane.add_theme_constant_override("margin_right", M3Units.dp(16))
	_right_pane.add_theme_constant_override("margin_top", M3Units.dp(16))
	_right_pane.add_theme_constant_override("margin_bottom", M3Units.dp(16))
	hbox.add_child(_right_pane)

func _build_categories() -> void:
	"""Create category buttons and content directly from SettingsManager + scenes."""
	
	var subgroups = SettingsManager.get_settings_by_subgroup()
	
	# Regular subgroups — build SettingsMenu content directly
	for subgroup_name in subgroups.keys():
		if subgroup_name == "RomM Connection":
			continue
		
		var id = subgroup_name.to_snake_case()
		var icon = SUBGROUP_ICONS.get(subgroup_name, "tune")
		var settings_vars = subgroups[subgroup_name]
		
		# Filter out platform-specific settings
		if subgroup_name == "Storage":
			if not PlatformManager.is_android():
				settings_vars = settings_vars.filter(func(sv): return sv.display_name != "Vita3K Data Folder")
			if not (PlatformManager.is_windows() or PlatformManager.is_linux()):
				settings_vars = settings_vars.filter(func(sv): return sv.display_name != "Steam Installation Folder")
		
		_add_category_button(id, subgroup_name, icon)
		
		if subgroup_name == "Library Appearance":
			# Library Appearance has complex custom UI — extract from SettingsView
			_category_contents[id] = await _create_library_appearance_content()
		else:
			# Regular subgroup: SettingsMenu in a scrollable wrapper
			_category_contents[id] = _create_settings_menu_content(subgroup_name, settings_vars)
	
	# RomM — platform settings scene
	_add_category_button("romm", "RomM", "cloud-sync")
	var platforms_view = preload("res://view/platforms_settings_view.tscn").instantiate()
	platforms_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_category_contents["romm"] = platforms_view
	
	# Card Designer
	_add_category_button("card_designer", "Card Designer", "cards-outline")
	var card_designer = preload("res://view/card_designer_view.tscn").instantiate()
	card_designer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_category_contents["card_designer"] = card_designer
	
	# Hero Designer
	_add_category_button("hero_designer", "Hero Designer", "image")
	var hero_designer = preload("res://view/hero_designer_view.tscn").instantiate()
	hero_designer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_category_contents["hero_designer"] = hero_designer
	
	# GameNative (Android only)
	if PlatformManager.is_android():
		_add_category_button("gamenative", "GameNative", "android")
		var gamenative = preload("res://view/gamenative_settings_view.gd").new()
		_category_contents["gamenative"] = gamenative
	
	# Spacer at bottom of sidebar
	var spacer = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_pane.add_child(spacer)
	
	# Select first category that has content
	for btn_id in _category_buttons.keys():
		if _category_contents.has(btn_id):
			_select_category(btn_id)
			break

func _add_category_button(id: String, label: String, icon: String) -> void:
	var btn = M3Button.new()
	btn.text = label
	btn.icon_name = icon
	btn.button_variant = M3Button.Variant.TEXT
	btn.button_size = M3Button.Size.MEDIUM
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.pressed.connect(_on_category_selected.bind(id))
	_left_pane.add_child(btn)
	_category_buttons[id] = btn

func _create_settings_menu_content(name: String, settings_vars: Array) -> Control:
	"""Create a SettingsMenu wrapped in ScrollContainer + MarginContainer + VBoxContainer for the right pane."""
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.follow_focus = true
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var margin = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	
	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	var menu = SettingsMenu.new()
	menu.initialize_settings_menu(name, settings_vars)
	menu.setting_changed.connect(func(value, setting): SettingsManager.set_setting(value, setting))
	vbox.add_child(menu)
	
	margin.add_child(vbox)
	scroll.add_child(margin)
	return scroll

func _create_library_appearance_content() -> Control:
	"""Library Appearance has complex custom UI — build via SettingsView and extract the tab."""
	_library_settings_view = SettingsView.new()
	add_child(_library_settings_view)
	_library_settings_view.visible = false
	
	if not _library_settings_view.is_node_ready():
		await _library_settings_view.ready
	
	var tab_container = _library_settings_view.get_settings_container()
	if not tab_container:
		push_error("[SettingsDialog] SettingsView did not create TabContainer for Library Appearance")
		return Control.new()
	
	for i in range(tab_container.get_tab_count()):
		if tab_container.get_tab_title(i) == "Library Appearance":
			var content = tab_container.get_tab_control(i)
			tab_container.remove_child(content)
			content.visible = true
			content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			content.size_flags_vertical = Control.SIZE_EXPAND_FILL
			# Return the ScrollContainer wrapper directly to preserve scrolling behavior
			if content is ScrollContainer:
				return content
			return content
	
	push_error("[SettingsDialog] Library Appearance tab not found in SettingsView")
	return Control.new()

func _on_category_selected(id: String) -> void:
	_select_category(id)

func _select_category(id: String) -> void:
	if _current_category == id:
		return
	
	# Hide previous content
	if _right_content and _right_content.get_parent() == _right_pane:
		if _right_content.has_method("on_view_hide"):
			_right_content.on_view_hide()
		_right_pane.remove_child(_right_content)
	
	_current_category = id
	
	# Update button visuals
	for btn_id in _category_buttons.keys():
		var btn = _category_buttons[btn_id]
		if btn_id == id:
			btn.button_variant = M3Button.Variant.TONAL
		else:
			btn.button_variant = M3Button.Variant.TEXT
	
	# Show new content
	if _category_contents.has(id):
		_right_content = _category_contents[id]
		_right_pane.add_child(_right_content)
		if _right_content.has_method("on_view_show"):
			_right_content.on_view_show()

func show_overlay() -> void:
	super.show_overlay()
	if _right_content and _right_content.has_method("on_view_show"):
		_right_content.on_view_show()
	_set_initial_focus()

func _set_initial_focus() -> void:
	await get_tree().process_frame
	for child in _left_pane.get_children():
		if child is M3Button and child.focus_mode != Control.FOCUS_NONE:
			child.grab_focus()
			return

func dismiss() -> void:
	if _right_content and _right_content.has_method("on_view_hide"):
		_right_content.on_view_hide()
	
	if SettingsManager:
		SettingsManager.save_settings()
	
	super.dismiss()

func get_platforms_settings_view() -> PlatformsSettingsView:
	if _category_contents.has("romm") and _category_contents["romm"] is PlatformsSettingsView:
		return _category_contents["romm"] as PlatformsSettingsView
	return null

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _library_settings_view and is_instance_valid(_library_settings_view):
			_library_settings_view.queue_free()
