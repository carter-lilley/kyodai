class_name SettingsDialog
extends M3Dialog

## Popup settings dialog with two-pane layout.
## Creates category content directly from DataManager subgroups.

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

# Snapshot of all SettingsVar values at dialog open, used to revert on Cancel.
var _snapshot: Dictionary = {}
var _cancelled: bool = false

func _init():
	dialog_variant = Variant.BASIC
	dialog_max_width = 1100.0
	title_text = "Settings"
	persistent = true
	fill_viewport_height = true
	super._init()
	if UIManager:
		set_focus_restore_fallback(UIManager.get_focus_restore_fallback_to_home())

func _ready():
	super._ready()
	# Fullscreen variant has an outer scroll; BASIC does not. Each category page
	# already scrolls independently, so only touch fullscreen-specific nodes.
	if dialog_variant == Variant.FULL_SCREEN:
		if _scroll:
			_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		if _bottom_actions:
			_bottom_actions.visible = false
	# Make content slot expand to fill the dialog interior
	if content_slot:
		content_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
		content_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_build_two_pane_layout()
	await _build_categories()

	# Categories are built asynchronously; re-position now that the real content
	# minimum size is known so the first summon matches subsequent summons.
	if is_inside_tree():
		_position_dialog()

	# Hide default body label; keep the title label as the popup title.
	if _body_label:
		_body_label.visible = false

	# Replace the default action with explicit Cancel / OK buttons.
	# OK applies changes and closes; Cancel reverts to the snapshot taken on open.
	clear_actions()
	add_action("Cancel", _on_cancel_pressed, false)
	add_action("OK", _on_ok_pressed, true)

func _build_two_pane_layout() -> void:
	"""Build two-pane HBox inside content_slot: sidebar + divider + content pane."""

	for child in content_slot.get_children():
		child.queue_free()

	var hbox = HBoxContainer.new()
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Wrap the content in a plain Control so the right-pane ScrollContainer's
	# natural content height does not propagate to the dialog's minimum size.
	# The HBox fills the wrapper via anchors; the wrapper fills the dialog via
	# size flags, and the dialog clamps its own height to the viewport.
	var content_wrapper = Control.new()
	content_wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_wrapper.custom_minimum_size = Vector2(0, 0)
	content_slot.add_child(content_wrapper)
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.offset_left = 0
	hbox.offset_top = 0
	hbox.offset_right = 0
	hbox.offset_bottom = 0
	content_wrapper.add_child(hbox)

	var compact := _is_compact_sidebar()

	# Left sidebar
	_left_pane = VBoxContainer.new()
	_left_pane.custom_minimum_size = Vector2(M3Units.dp(64) if compact else M3Units.dp(160), 0)
	_left_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_pane.alignment = BoxContainer.ALIGNMENT_CENTER if compact else BoxContainer.ALIGNMENT_BEGIN
	_left_pane.add_theme_constant_override("separation", int(M3Units.dp(4)))

	var left_margin = MarginContainer.new()
	left_margin.add_theme_constant_override("margin_left", int(M3Units.dp(4) if compact else M3Units.dp(8)))
	left_margin.add_theme_constant_override("margin_right", int(M3Units.dp(4) if compact else M3Units.dp(8)))
	left_margin.add_theme_constant_override("margin_top", int(M3Units.dp(12)))
	left_margin.add_theme_constant_override("margin_bottom", int(M3Units.dp(12)))
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
	_right_pane.add_theme_constant_override("margin_left", int(M3Units.dp(8)))
	_right_pane.add_theme_constant_override("margin_right", int(M3Units.dp(8)))
	_right_pane.add_theme_constant_override("margin_top", int(M3Units.dp(12)))
	_right_pane.add_theme_constant_override("margin_bottom", int(M3Units.dp(12)))
	hbox.add_child(_right_pane)

func _is_compact_sidebar() -> bool:
	"""Use icon-only category buttons on small screens."""
	return _is_small_screen()

func _build_categories() -> void:
	"""Create category buttons and content directly from DataManager + scenes."""

	var subgroups = DataManager.get_settings_by_subgroup()

	# Regular subgroups — build SettingsMenu content directly
	for subgroup_name in subgroups.keys():
		if subgroup_name == "RomM Connection":
			continue

		var id = subgroup_name.to_snake_case()
		var icon = SUBGROUP_ICONS.get(subgroup_name, "tune")
		var settings_vars = subgroups[subgroup_name]

		# Filter out platform-specific settings
		if subgroup_name == "Storage":
			if not (SystemManager.platform.is_windows() or SystemManager.platform.is_linux()):
				settings_vars = settings_vars.filter(func(sv): return sv.display_name != "Steam Installation Folder")
			# Move Download Speed to the end so storage paths appear first.
			settings_vars.sort_custom(func(a, b): return int(b.display_name == "Download Speed") - int(a.display_name == "Download Speed"))
		elif subgroup_name == "Display":
			if SystemManager.platform.is_android():
				settings_vars = settings_vars.filter(func(sv): return sv.display_name not in ["Windowed", "Windowed Resolution:"])
		_add_category_button(id, subgroup_name, icon)

		if subgroup_name == "Library Appearance":
			# Library Appearance has complex custom UI — build it directly.
			_category_contents[id] = preload("res://view/library_appearance_settings_view.gd").new()
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

	# GameNative (Android only)
	if SystemManager.platform.is_android():
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
			select_category(btn_id)
			break

func _add_category_button(id: String, label: String, icon: String) -> void:
	var btn: M3Button
	if _is_compact_sidebar():
		var icon_btn = M3IconButton.new()
		icon_btn.icon_name = icon
		icon_btn.icon_button_variant = M3IconButton.IconVariant.STANDARD
		icon_btn.icon_button_size = M3IconButton.IconSize.SMALL
		icon_btn.tooltip_text = label
		icon_btn.pressed.connect(_on_category_selected.bind(id))
		_left_pane.add_child(icon_btn)
		btn = icon_btn
	else:
		var text_btn = M3Button.new()
		text_btn.text = label
		text_btn.icon_name = icon
		text_btn.button_variant = M3Button.Variant.TEXT
		text_btn.button_size = M3Button.Size.SMALL
		text_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		text_btn.pressed.connect(_on_category_selected.bind(id))
		_left_pane.add_child(text_btn)
		btn = text_btn
	_category_buttons[id] = btn

func _create_settings_menu_content(setting_name: String, settings_vars: Array) -> Control:
	"""Create a SettingsMenu wrapped in ScrollContainer + MarginContainer + VBoxContainer for the right pane."""
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var margin = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", M3Units.dp(20))
	margin.add_theme_constant_override("margin_top", M3Units.dp(20))
	margin.add_theme_constant_override("margin_right", M3Units.dp(20))
	margin.add_theme_constant_override("margin_bottom", M3Units.dp(20))

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Use SHRINK_BEGIN so the ScrollContainer measures true content height
	# instead of expanding and inflating the popup's minimum size.
	vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	var menu = SettingsMenu.new()
	menu.initialize_settings_menu(setting_name, settings_vars)
	menu.setting_changed.connect(func(value, setting): DataManager.set_setting(value, setting))
	vbox.add_child(menu)

	margin.add_child(vbox)
	scroll.add_child(margin)
	return scroll

func _on_category_selected(id: String) -> void:
	select_category(id)

func select_category(id: String) -> void:
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
		if btn is M3IconButton:
			btn.icon_button_variant = M3IconButton.IconVariant.TONAL if btn_id == id else M3IconButton.IconVariant.STANDARD
		else:
			btn.button_variant = M3Button.Variant.TONAL if btn_id == id else M3Button.Variant.TEXT

	# Show new content
	if _category_contents.has(id):
		_right_content = _category_contents[id]
		_right_pane.add_child(_right_content)
		if _right_content.has_method("on_view_show"):
			_right_content.on_view_show()

func get_current_category() -> String:
	return _current_category

func cancel_and_dismiss() -> void:
	_cancelled = true
	dismiss()

func show_overlay() -> void:
	_cancelled = false
	_take_snapshot()
	super.show_overlay()
	if _right_content and _right_content.has_method("on_view_show"):
		_right_content.on_view_show()
	_set_initial_focus()

func _set_initial_focus() -> void:
	await get_tree().process_frame
	for child in _left_pane.get_children():
		if child is M3Button and child.focus_mode != Control.FOCUS_NONE:
			if UIManager:
				UIManager.suppress_next_focus_sound()
			child.grab_focus()
			return

func dismiss() -> void:
	if _right_content and _right_content.has_method("on_view_hide"):
		_right_content.on_view_hide()

	# Cancel reverts to the snapshot taken on open. All other dismiss paths
	# (OK, outside-click, ui_cancel, default close) apply pending settings.
	if _cancelled:
		_restore_snapshot()
		# On cancel, return focus to the Home button rather than the summoner.
		if UIManager:
			set_focus_restore_target(UIManager.find_home_button())

	if not _cancelled:
		# Suppress overlay focus pull-back while applying settings and dismissing.
		# The preset triggers grid layout rebuilds and deferred focus restoration;
		# without suppression the still-visible dialog would yank focus back.
		M3Overlay._suppress_focus_pullback = true
		_apply_settings()

	if DataManager:
		DataManager.save_settings()

	super.dismiss()
	M3Overlay._suppress_focus_pullback = false

func _input(event: InputEvent) -> void:
	# Treat ui_cancel as Cancel so focus returns to the Home button.
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_cancel_pressed()
		return
	super._input(event)

func _on_ok_pressed() -> void:
	dismiss()

func _on_cancel_pressed() -> void:
	_cancelled = true
	dismiss()

func _on_close_button_pressed() -> void:
	"""Top-right X behaves like Cancel."""
	_on_cancel_pressed()

func _take_snapshot() -> void:
	_snapshot.clear()
	if not DataManager.is_settings_loaded():
		return
	for property_name in DataManager.get_settings().keys():
		_snapshot[property_name] = _copy_value(DataManager.get_setting(property_name).value)

func _restore_snapshot() -> void:
	if _snapshot.is_empty() or not DataManager.is_settings_loaded():
		return
	for property_name in _snapshot.keys():
		var setting = DataManager.get_setting(property_name)
		if not setting:
			continue
		var snapshot_value = _snapshot[property_name]
		if not _values_equal(snapshot_value, setting.value):
			DataManager.set_setting(_copy_value(snapshot_value), setting)
	refresh_all_category_values()

func _values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Dictionary or a is Array or (a is Object and a.has_method("duplicate")):
		# Deep-compare containers; for Objects, fall back to == if available.
		if a is Object and b is Object:
			return a == b or a.duplicate(true) == b.duplicate(true)
		return a == b
	return a == b

func _copy_value(value: Variant) -> Variant:
	if value is Dictionary:
		return value.duplicate(true)
	if value is Array:
		return value.duplicate(true)
	if value is Object and value.has_method("duplicate"):
		return value.duplicate(true)
	return value

func _apply_settings() -> void:
	if UIManager:
		UIManager.apply_settings_now()

func get_platforms_settings_view() -> PlatformsSettingsView:
	if _category_contents.has("romm") and _category_contents["romm"] is PlatformsSettingsView:
		return _category_contents["romm"] as PlatformsSettingsView
	return null

func get_card_designer_view() -> CardDesignerView:
	if _category_contents.has("card_designer") and _category_contents["card_designer"] is CardDesignerView:
		return _category_contents["card_designer"] as CardDesignerView
	return null

func refresh_theme() -> void:
	super.refresh_theme()
	for content in _category_contents.values():
		if is_instance_valid(content):
			_refresh_theme_recursive(content)

func _refresh_theme_recursive(node: Node) -> void:
	if node.has_method("refresh_theme"):
		node.refresh_theme()
	for child in node.get_children():
		_refresh_theme_recursive(child)

func refresh_all_category_values() -> void:
	"""Refresh all SettingsMenu control values to match current settings."""
	for content in _category_contents.values():
		if is_instance_valid(content):
			_refresh_settings_menu_values_recursive(content)

func _refresh_settings_menu_values_recursive(node: Node) -> void:
	if node is SettingsMenu:
		node.refresh_all_control_values()
		return
	for child in node.get_children():
		_refresh_settings_menu_values_recursive(child)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		pass
