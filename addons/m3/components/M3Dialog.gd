@tool
class_name M3Dialog
extends M3Overlay

## Material 3 Dialog Component
## Extends M3Overlay for modal overlay rendering.
## Supports BASIC and FULL_SCREEN variants with hero icon, title, body,
## custom content slot, and action buttons.

enum Variant { BASIC, FULL_SCREEN }

# ============================================
# SIZE SPECS (all values in dp)
# ============================================

const BASIC_MAX_WIDTH := 560.0
const BASIC_MAX_HEIGHT := 640.0
const BASIC_MIN_HEIGHT := 200.0
const BASIC_RADIUS := 28.0
const PADDING := 24.0
const PADDING_TOP_NO_ICON := 16.0
const ICON_SIZE := 24.0
const ICON_TITLE_GAP := 16.0
const ACTIONS_GAP := 8.0
const FULLSCREEN_TOP_BAR_HEIGHT := 64.0
const FULLSCREEN_ACTIONS_HEIGHT := 64.0

# ============================================
# EXPORTS
# ============================================

@export var dialog_variant: Variant = Variant.BASIC:
	set(value):
		if value == dialog_variant:
			return
		dialog_variant = value
		if _ready_called or get_child_count() > 0:
			_rebuild_layout()

@export var title_text: String = "":
	set(value):
		if value == title_text:
			return
		title_text = value
		if _ready_called:
			_update_text()

@export var body_text: String = "":
	set(value):
		if value == body_text:
			return
		body_text = value
		if _ready_called:
			_update_text()

@export var hero_icon_name: String = "":
	set(value):
		if value == hero_icon_name:
			return
		hero_icon_name = value
		if _ready_called:
			_update_hero_icon()

@export var dismissible: bool = true
@export var dialog_max_width: float = BASIC_MAX_WIDTH

# ============================================
# SIGNALS
# ============================================

signal action_pressed(action_label: String)

# ============================================
# INTERNAL
# ============================================

var _scrim: ColorRect
var _dialog_wrapper: Control
var _dialog_container: PanelContainer

var _vbox: VBoxContainer
var _hero_icon: FontIcon
var _title_label: Label
var _body_label: Label
## The content slot for adding custom controls (VBoxContainer).
var content_slot: VBoxContainer
var _divider: HSeparator
var _actions_container: HBoxContainer

var _fullscreen_root: VBoxContainer
var _top_bar: Panel
var _top_bar_title: Label
var _close_button: M3IconButton
var _scroll: ScrollContainer
var _scroll_content: VBoxContainer
var _bottom_actions: Panel

var _actions: Array[M3Button] = []
var _ready_called: bool = false
var _cached_fonts: Dictionary = {}
var _font_icon_template: FontIconSettings = null
var _cached_divider_sb: StyleBoxLine = null
var _cached_bg_sb: StyleBoxFlat = null
var _cached_top_bar_sb: StyleBoxFlat = null
var _cached_bottom_actions_sb: StyleBoxFlat = null

# ============================================
# PUBLIC API
# ============================================

## Add an action button to the dialog.
func add_action(label: String, callback: Callable = Callable(), primary: bool = false):
	var btn = M3Button.new()
	btn.text = label
	btn.button_size = M3Button.Size.SMALL
	btn.button_variant = M3Button.Variant.FILLED if primary else M3Button.Variant.TEXT
	btn.pressed.connect(_on_action_pressed.bind(label))
	if callback.is_valid():
		btn.pressed.connect(callback)
	_actions.append(btn)
	if _actions_container:
		_actions_container.add_child(btn)

## Clear all action buttons.
func clear_actions():
	for btn in _actions:
		btn.queue_free()
	_actions.clear()

## Show the dialog overlay.
func show_overlay():
	var parent = M3Overlay.get_overlay_parent()
	if parent and get_parent() == null:
		parent.add_child(self)
	# Defer positioning so dialogs with async-built content (e.g. SettingsDialog)
	# are measured after their children have finished laying out.
	_deferred_position_and_show()

func _deferred_position_and_show():
	await get_tree().process_frame
	_position_dialog()
	super.show_overlay()
	_focus_first_action()

# ============================================
# LIFECYCLE
# ============================================

func _init():
	super._init()
	overlay_type = "dialog"
	overlay_layer = 90
	_build_layout()

func _ready():
	super._ready()
	_cached_fonts = M3Theme.load_fonts()
	_update_appearance()
	_update_text()
	_update_hero_icon()
	
	for btn in _actions:
		if btn.get_parent() == null and _actions_container:
			_actions_container.add_child(btn)
	
	_add_default_action()
	_ready_called = true

func _focus_first() -> void:
	_focus_first_action()

func _build_layout():
	# Scrim
	_scrim = ColorRect.new()
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(M3Theme.get_on_surface().r, M3Theme.get_on_surface().g, M3Theme.get_on_surface().b, 0.32)
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.gui_input.connect(_on_scrim_input)
	add_child(_scrim)
	
	# Wrapper enforces the dialog's fixed size and clips any content that tries
	# to expand past it (e.g. async-built children inflating PanelContainer).
	_dialog_wrapper = Control.new()
	_dialog_wrapper.clip_contents = true
	add_child(_dialog_wrapper)
	
	# Dialog container (PanelContainer)
	_dialog_container = PanelContainer.new()
	_dialog_container.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_dialog_container.size_flags_horizontal = Control.SIZE_FILL
	_dialog_container.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_dialog_wrapper.add_child(_dialog_container)
	
	if dialog_variant == Variant.BASIC:
		_build_basic_layout()
	else:
		_build_fullscreen_layout()

func _build_basic_layout():
	_vbox = VBoxContainer.new()
	_vbox.alignment = BoxContainer.ALIGNMENT_BEGIN
	_dialog_container.add_child(_vbox)
	
	_vbox.add_theme_constant_override("separation", 0)
	
	_hero_icon = FontIcon.new()
	_hero_icon.icon_settings = _get_font_icon_settings()
	_hero_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hero_icon.visible = false
	_vbox.add_child(_hero_icon)
	
	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_title_label)
	
	var title_body_spacer = Control.new()
	title_body_spacer.custom_minimum_size = Vector2(0, M3Units.dp(16))
	_vbox.add_child(title_body_spacer)
	
	_body_label = Label.new()
	_body_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_vbox.add_child(_body_label)
	
	var body_content_spacer = Control.new()
	body_content_spacer.custom_minimum_size = Vector2(0, M3Units.dp(24))
	body_content_spacer.name = "BodyContentSpacer"
	_vbox.add_child(body_content_spacer)
	
	content_slot = VBoxContainer.new()
	content_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_slot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_vbox.add_child(content_slot)
	
	_divider = HSeparator.new()
	_divider.visible = false
	_vbox.add_child(_divider)
	
	var divider_actions_spacer = Control.new()
	divider_actions_spacer.custom_minimum_size = Vector2(0, M3Units.dp(24))
	divider_actions_spacer.visible = false
	divider_actions_spacer.name = "DividerActionsSpacer"
	_vbox.add_child(divider_actions_spacer)
	
	_actions_container = HBoxContainer.new()
	_actions_container.alignment = BoxContainer.ALIGNMENT_END
	_actions_container.add_theme_constant_override("separation", M3Units.dp(ACTIONS_GAP))
	_vbox.add_child(_actions_container)

func _build_fullscreen_layout():
	var bg_panel = Panel.new()
	bg_panel.name = "FullscreenBackground"
	bg_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dialog_container.add_child(bg_panel)
	
	_fullscreen_root = VBoxContainer.new()
	_fullscreen_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dialog_container.add_child(_fullscreen_root)
	
	_top_bar = Panel.new()
	_top_bar.custom_minimum_size = Vector2(0, M3Units.dp(FULLSCREEN_TOP_BAR_HEIGHT))
	_fullscreen_root.add_child(_top_bar)
	
	var top_hbox = HBoxContainer.new()
	top_hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	top_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_top_bar.add_child(top_hbox)
	
	_close_button = M3IconButton.new()
	_close_button.icon_name = "close"
	_close_button.pressed.connect(dismiss)
	top_hbox.add_child(_close_button)
	
	_top_bar_title = Label.new()
	_top_bar_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_top_bar_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	top_hbox.add_child(_top_bar_title)
	
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fullscreen_root.add_child(_scroll)
	
	var scroll_margin = MarginContainer.new()
	scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var pad = M3Units.dp(PADDING)
	scroll_margin.add_theme_constant_override("margin_left", pad)
	scroll_margin.add_theme_constant_override("margin_right", pad)
	scroll_margin.add_theme_constant_override("margin_top", pad)
	scroll_margin.add_theme_constant_override("margin_bottom", pad)
	_scroll.add_child(scroll_margin)
	
	_scroll_content = VBoxContainer.new()
	_scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_content.add_theme_constant_override("separation", M3Units.dp(16))
	scroll_margin.add_child(_scroll_content)
	
	_hero_icon = FontIcon.new()
	_hero_icon.icon_settings = _get_font_icon_settings()
	_hero_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hero_icon.visible = false
	_scroll_content.add_child(_hero_icon)
	
	_title_label = Label.new()
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_title_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_scroll_content.add_child(_title_label)
	
	_body_label = Label.new()
	_body_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_scroll_content.add_child(_body_label)
	
	content_slot = VBoxContainer.new()
	_scroll_content.add_child(content_slot)
	
	_bottom_actions = Panel.new()
	_bottom_actions.custom_minimum_size = Vector2(0, M3Units.dp(FULLSCREEN_ACTIONS_HEIGHT))
	_fullscreen_root.add_child(_bottom_actions)
	
	_actions_container = HBoxContainer.new()
	_actions_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_actions_container.alignment = BoxContainer.ALIGNMENT_END
	_actions_container.add_theme_constant_override("separation", M3Units.dp(ACTIONS_GAP))
	_bottom_actions.add_child(_actions_container)
	
	_dialog_container.set_anchors_preset(Control.PRESET_FULL_RECT)

func _rebuild_layout():
	# Disconnect and remove action buttons before clearing references
	for btn in _actions:
		for c in btn.pressed.get_connections():
			btn.pressed.disconnect(c.callable)
		if btn.get_parent():
			btn.get_parent().remove_child(btn)
	_actions.clear()
	
	for child in _dialog_container.get_children():
		child.queue_free()
	
	_vbox = null
	_fullscreen_root = null
	_top_bar = null
	_scroll = null
	_scroll_content = null
	_bottom_actions = null
	
	if dialog_variant == Variant.BASIC:
		_build_basic_layout()
	else:
		_build_fullscreen_layout()
	_update_appearance()
	_update_text()
	_update_hero_icon()

func _add_default_action():
	if _actions.is_empty():
		add_action("OK", Callable(), true)

func _on_action_pressed(label: String):
	action_pressed.emit(label)

func _on_scrim_input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed:
		get_viewport().set_input_as_handled()
		if dismissible:
			dismiss()

func _focus_first_action() -> void:
	for btn in _actions:
		if btn is Control and btn.focus_mode != Control.FOCUS_NONE:
			if UIManager and UIManager.has_method("suppress_next_focus_sound"):
				UIManager.suppress_next_focus_sound()
			btn.grab_focus()
			return

func _position_dialog():
	var viewport_size = get_viewport().get_visible_rect().size if get_viewport() else Vector2(1920, 1080)
	
	if dialog_variant == Variant.BASIC:
		var margin = M3Units.dp(48)
		var max_w = M3Units.dp(dialog_max_width)
		var max_h = M3Units.dp(BASIC_MAX_HEIGHT)
		var min_h = M3Units.dp(BASIC_MIN_HEIGHT)
		var dialog_width = min(max_w, viewport_size.x - margin)
		
		_dialog_container.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
		_dialog_container.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		_dialog_container.custom_minimum_size = Vector2(dialog_width, 0)
		await get_tree().process_frame
		var content_height := _dialog_container.get_combined_minimum_size().y
		content_height += M3Units.dp(PADDING * 2)
		var dialog_height = clamp(content_height, min_h, max_h)
		dialog_height = min(dialog_height, viewport_size.y - margin)
		
		_dialog_container.set_deferred("custom_minimum_size", Vector2(dialog_width, dialog_height))
		_dialog_wrapper.set_anchors_preset(Control.PRESET_CENTER, false)
		_dialog_wrapper.set_deferred("size", Vector2(dialog_width, dialog_height))
		_dialog_wrapper.set_deferred("position", (viewport_size - Vector2(dialog_width, dialog_height)) / 2.0)
	else:
		# Fullscreen: wrapper fills the viewport.
		_dialog_wrapper.set_anchors_preset(Control.PRESET_FULL_RECT)
		_dialog_wrapper.position = Vector2.ZERO
		_dialog_wrapper.size = viewport_size


# ============================================
# APPEARANCE
# ============================================

func _get_font_icon_settings() -> FontIconSettings:
	if _font_icon_template == null:
		_font_icon_template = FontIconSettings.new()
		_font_icon_template.icon_size = M3Units.dp(ICON_SIZE)
		_font_icon_template.icon_font = "MaterialIcons"
	return _font_icon_template.duplicate()

func _update_appearance():
	if _cached_fonts.is_empty():
		_cached_fonts = M3Theme.load_fonts()
	var fonts = _cached_fonts
	
	if dialog_variant == Variant.BASIC:
		var bg = M3Theme.get_surface_container()
		var sb = M3Theme.make_shadow(bg, M3Units.dpi(BASIC_RADIUS),
			M3Theme.ELEVATION_3["size"], M3Theme.ELEVATION_3["offset"], M3Theme.ELEVATION_3["color"])
		var pad = M3Units.dp(PADDING)
		sb.content_margin_left = pad
		sb.content_margin_right = pad
		sb.content_margin_top = pad
		sb.content_margin_bottom = pad
		_dialog_container.add_theme_stylebox_override("panel", sb)
		
		_style_label(_title_label, fonts["regular"], M3Units.dp(24), M3Theme.get_on_surface())
		_style_label(_body_label, fonts["regular"], M3Units.dp(14), M3Theme.get_on_surface_variant())
		
		if _cached_divider_sb == null:
			_cached_divider_sb = StyleBoxLine.new()
		_cached_divider_sb.color = M3Theme.get_outline()
		_cached_divider_sb.thickness = 1
		_divider.add_theme_stylebox_override("separator", _cached_divider_sb)
		
		if _hero_icon and _hero_icon.visible:
			_hero_icon.icon_settings.icon_color = M3Theme.get_secondary()
		
	else:
		if _cached_bg_sb == null:
			_cached_bg_sb = StyleBoxFlat.new()
		_cached_bg_sb.bg_color = M3Theme.get_surface()
		for child in _dialog_container.get_children():
			if child.name == "FullscreenBackground":
				child.add_theme_stylebox_override("panel", _cached_bg_sb)
				break
		
		if _cached_top_bar_sb == null:
			_cached_top_bar_sb = StyleBoxFlat.new()
		_cached_top_bar_sb.bg_color = M3Theme.get_surface()
		_top_bar.add_theme_stylebox_override("panel", _cached_top_bar_sb)
		_style_label(_top_bar_title, fonts["regular"], M3Units.dp(22), M3Theme.get_on_surface())
		
		if _cached_bottom_actions_sb == null:
			_cached_bottom_actions_sb = StyleBoxFlat.new()
		_cached_bottom_actions_sb.bg_color = M3Theme.get_surface()
		_bottom_actions.add_theme_stylebox_override("panel", _cached_bottom_actions_sb)
		
		_style_label(_title_label, fonts["regular"], M3Units.dp(24), M3Theme.get_on_surface())
		_style_label(_body_label, fonts["regular"], M3Units.dp(14), M3Theme.get_on_surface_variant())
		
		if _hero_icon and _hero_icon.visible:
			_hero_icon.icon_settings.icon_color = M3Theme.get_secondary()

func _style_label(label: Label, font: Font, font_size: int, color: Color):
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)

func _update_text():
	if _title_label:
		_title_label.text = title_text
		_title_label.visible = not title_text.is_empty()
	if _body_label:
		_body_label.text = body_text
		_body_label.visible = not body_text.is_empty()
	if _top_bar_title:
		_top_bar_title.text = title_text

func _update_hero_icon():
	if not _hero_icon:
		return
	
	if hero_icon_name.is_empty():
		_hero_icon.visible = false
	else:
		_hero_icon.icon_settings.icon_name = hero_icon_name
		_hero_icon.visible = true

func refresh_theme():
	if not _ready_called:
		return
	_update_appearance()

# ============================================
# STATIC FACTORIES
# ============================================

static func show_dialog(dialog: M3Dialog):
	var parent = M3Overlay.get_overlay_parent()
	if parent:
		parent.add_child(dialog)
		dialog.show_overlay()

static func show_confirm(title: String, body: String, on_accept: Callable = Callable(), on_cancel: Callable = Callable()) -> M3Dialog:
	var dialog = M3Dialog.new()
	dialog.title_text = title
	dialog.body_text = body
	dialog.add_action("Cancel", on_cancel, false)
	dialog.add_action("Accept", on_accept, true)
	show_dialog(dialog)
	return dialog

static func show_alert(title: String, body: String, on_ok: Callable = Callable()) -> M3Dialog:
	var dialog = M3Dialog.new()
	dialog.title_text = title
	dialog.body_text = body
	dialog.add_action("OK", on_ok, true)
	show_dialog(dialog)
	return dialog

static func dismiss_current():
	M3Overlay.dismiss_type("dialog")
