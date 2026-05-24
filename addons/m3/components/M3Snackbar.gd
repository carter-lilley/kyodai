class_name M3Snackbar
extends M3Overlay

## Material 3 Snackbar Component
## Transient notification shown at the bottom of the screen.

const M3Units = preload("res://addons/m3/M3Units.gd")

# ============================================
# SIZE SPECS
# ============================================

const SNACKBAR_HEIGHT := 48.0
const MAX_WIDTH := 400.0
const MOBILE_MARGIN := 8.0
const CORNER_RADIUS := 4.0
const LEFT_PADDING := 16.0
const RIGHT_PADDING := 8.0
const PROGRESS_EXTRA_HEIGHT := 12.0
const ICON_SIZE := 24.0
const FONT_SIZE_NORMAL := 14.0
const FONT_SIZE_SMALL := 12.0

# ============================================
# SIGNALS
# ============================================

signal action_pressed

# ============================================
# INTERNAL
# ============================================

var _container: Panel
var _hbox: HBoxContainer
var _message_label: Label
var _action_button: M3Button
var _dismiss_button: M3IconButton
var _timer: Timer
var _hovered: bool = false
var _cached_fonts: Dictionary = {}

var _progress: M3Progress
var _leading_icon: FontIcon
var _font_icon_template: FontIconSettings = null

var message: String = ""
var action_text: String = ""
var dismissible: bool = true
var _auto_dismiss: bool = true
var _progress_visible: bool = false

# ============================================
# LIFECYCLE
# ============================================

func _init():
	super._init()
	overlay_type = "snackbar"
	overlay_layer = 1100
	_create_visuals()
	_cached_fonts = M3Theme.load_fonts()

func _ready():
	super._ready()
	_cached_fonts = M3Theme.load_fonts()
	_position_snackbar()
	_setup_timer()
	_update_appearance()
	if _auto_dismiss:
		start_timer(4000)
	
	_container.mouse_entered.connect(_on_mouse_entered)
	_container.mouse_exited.connect(_on_mouse_exited)
	get_viewport().size_changed.connect(_on_viewport_resized)

func _create_visuals():
	_container = Panel.new()
	_container.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_container)
	
	_hbox = HBoxContainer.new()
	_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_hbox.mouse_filter = Control.MOUSE_FILTER_PASS
	_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_container.add_child(_hbox)
	
	_leading_icon = FontIcon.new()
	_leading_icon.icon_settings = _get_font_icon_settings()
	_leading_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_leading_icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_leading_icon.visible = false
	_leading_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hbox.add_child(_leading_icon)
	
	_message_label = Label.new()
	_message_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_message_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_message_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_message_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_message_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_hbox.add_child(_message_label)
	
	var action_center = CenterContainer.new()
	action_center.size_flags_horizontal = Control.SIZE_SHRINK_END
	action_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_hbox.add_child(action_center)
	
	_action_button = M3Button.new()
	_action_button.button_variant = M3Button.Variant.TEXT
	_action_button.button_size = M3Button.Size.SMALL
	_action_button.pressed.connect(_on_action_pressed)
	action_center.add_child(_action_button)
	
	var dismiss_center = CenterContainer.new()
	dismiss_center.size_flags_horizontal = Control.SIZE_SHRINK_END
	dismiss_center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_hbox.add_child(dismiss_center)
	
	_dismiss_button = M3IconButton.new()
	_dismiss_button.icon_name = "close"
	_dismiss_button.pressed.connect(_on_dismiss_pressed)
	dismiss_center.add_child(_dismiss_button)
	
	_progress = M3Progress.new()
	_progress.mode = M3Progress.Mode.LINEAR
	_progress.progress_size = M3Progress.Size.SMALL
	_progress.visible = false
	_container.add_child(_progress)

func _get_font_icon_settings() -> FontIconSettings:
	if _font_icon_template == null:
		_font_icon_template = FontIconSettings.new()
		_font_icon_template.icon_size = M3Units.dp(ICON_SIZE)
		_font_icon_template.icon_font = "MaterialIcons"
	return _font_icon_template.duplicate()

func _setup_timer():
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_timer_timeout)
	add_child(_timer)

func _position_snackbar():
	var viewport_size = get_viewport().get_visible_rect().size
	var margin = M3Units.dp(MOBILE_MARGIN)
	var max_width = M3Units.dp(MAX_WIDTH)
	var height = M3Units.dp(SNACKBAR_HEIGHT)
	var extra = M3Units.dp(PROGRESS_EXTRA_HEIGHT) if _progress_visible else 0.0
	
	var width: float
	if viewport_size.x <= M3Units.dp(600):
		width = viewport_size.x - margin * 2
	else:
		width = min(viewport_size.x - margin * 2, max_width)
	
	_container.size = Vector2(width, height + extra)
	_container.position = Vector2(
		(viewport_size.x - width) / 2.0,
		viewport_size.y - height - extra - margin
	)

func _update_appearance():
	if _cached_fonts.is_empty():
		_cached_fonts = M3Theme.load_fonts()
	var fonts = _cached_fonts
	
	var bg = M3Theme.get_inverse_surface()
	var sb = M3Theme.make_shadow(bg, M3Units.dpi(CORNER_RADIUS), 6, Vector2(0, 3), Color(0, 0, 0, 0.20))
	_container.add_theme_stylebox_override("panel", sb)
	
	_message_label.add_theme_color_override("font_color", M3Theme.get_inverse_on_surface())
	_message_label.add_theme_font_override("font", fonts["medium"])
	
	_action_button.add_theme_color_override("font_color", M3Theme.get_primary())
	_action_button.add_theme_color_override("font_pressed_color", M3Theme.get_primary())
	_action_button.add_theme_color_override("font_hover_color", M3Theme.get_primary())
	
	var dismiss_color = M3Theme.get_inverse_on_surface()
	_dismiss_button.add_theme_color_override("font_color", Color(dismiss_color.r, dismiss_color.g, dismiss_color.b, 0.6))
	_dismiss_button.add_theme_color_override("font_hover_color", dismiss_color)
	
	if is_instance_valid(_leading_icon) and _leading_icon.visible:
		_leading_icon.icon_settings.icon_color = dismiss_color
	
	_update_layout()
	_fit_text()

func _update_layout():
	var h_padding = M3Units.dp(LEFT_PADDING)
	var right_padding = M3Units.dp(RIGHT_PADDING)
	var hbox_height = M3Units.dp(SNACKBAR_HEIGHT)
	
	_hbox.position = Vector2(h_padding, 0)
	_hbox.size = Vector2(_container.size.x - h_padding - right_padding, hbox_height)
	
	if _progress_visible and is_instance_valid(_progress):
		var progress_y = hbox_height + M3Units.dp(4)
		_progress.position = Vector2(h_padding, progress_y)
		_progress.size = Vector2(_container.size.x - h_padding - right_padding, M3Units.dp(4))

func _fit_text():
	if not is_instance_valid(_message_label) or not _message_label.is_inside_tree():
		return
	
	var container_width: float = _container.size.x
	if container_width <= 0:
		return
	
	# Calculate width taken by other visible children in the HBox
	var other_width := 0.0
	var visible_children := 0
	for child in _hbox.get_children():
		if child is Control and child.visible:
			visible_children += 1
			if child != _message_label:
				other_width += child.get_combined_minimum_size().x
	
	# Account for HBox separation gaps
	var separation := _hbox.get_theme_constant("separation")
	other_width += maxi(0, visible_children - 1) * separation
	
	# Account for container padding
	other_width += M3Units.dp(LEFT_PADDING) + M3Units.dp(RIGHT_PADDING)
	
	var available_width := container_width - other_width
	if available_width <= 0:
		return
	
	var font := _message_label.get_theme_font("font")
	if font == null:
		return
	
	# Try normal font size first
	var normal_size := M3Units.dp(FONT_SIZE_NORMAL)
	var text_width := font.get_string_size(message, HORIZONTAL_ALIGNMENT_LEFT, -1, normal_size).x
	
	if text_width <= available_width:
		_message_label.add_theme_font_size_override("font_size", normal_size)
		_message_label.clip_text = false
		return
	
	# Try smaller font size
	var small_size := M3Units.dp(FONT_SIZE_SMALL)
	text_width = font.get_string_size(message, HORIZONTAL_ALIGNMENT_LEFT, -1, small_size).x
	
	if text_width <= available_width:
		_message_label.add_theme_font_size_override("font_size", small_size)
		_message_label.clip_text = false
		return
	
	# Still too long — use small font with ellipsis
	_message_label.add_theme_font_size_override("font_size", small_size)
	_message_label.clip_text = true
	_message_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS

# ============================================
# TIMER
# ============================================

func start_timer(duration_ms: int = 4000):
	_timer.wait_time = duration_ms / 1000.0
	_timer.start()

func pause_timer():
	if _timer and not _timer.is_stopped():
		_timer.paused = true

func resume_timer():
	if _timer and not _timer.is_stopped():
		_timer.paused = false

func _on_timer_timeout():
	dismiss()

# ============================================
# INTERACTION
# ============================================

func _on_action_pressed():
	action_pressed.emit()
	dismiss()

func _on_dismiss_pressed():
	dismiss()

func dismiss():
	_timer.stop()
	super.dismiss()

# ============================================
# INPUT
# ============================================

func _on_mouse_entered():
	_hovered = true
	pause_timer()

func _on_mouse_exited():
	_hovered = false
	resume_timer()

func _on_viewport_resized():
	_position_snackbar()
	_update_layout()
	_fit_text()

# ============================================
# PUBLIC
# ============================================

static func show_message(message: String, action_text: String = "", action_callback: Callable = Callable(), dismissible: bool = true):
	var snackbar = M3Snackbar.new()
	snackbar.setup(message, action_text, action_callback, dismissible)
	
	var parent = M3Overlay.get_overlay_parent()
	if parent:
		parent.add_child(snackbar)
		snackbar.show_overlay()

static func dismiss_current():
	M3Overlay.dismiss_type("snackbar")

func setup(msg: String, act_text: String = "", action_callback: Callable = Callable(), can_dismiss: bool = true):
	message = msg
	action_text = act_text
	dismissible = can_dismiss
	
	# Disconnect previous callback(s) to avoid accumulation on reuse
	for conn in action_pressed.get_connections():
		action_pressed.disconnect(conn.callable)
	
	if action_callback.is_valid():
		action_pressed.connect(action_callback)
	
	_action_button.visible = not action_text.is_empty()
	_dismiss_button.visible = dismissible
	
	_message_label.text = msg
	_action_button.text = act_text

func set_overlay_type(type: String):
	overlay_type = type

func set_auto_dismiss(enabled: bool):
	_auto_dismiss = enabled

func show_progress(enabled: bool):
	_progress_visible = enabled
	if is_instance_valid(_progress):
		_progress.visible = enabled
	if is_node_ready():
		_position_snackbar()
		_update_layout()

func set_progress_fraction(fraction: float):
	if is_instance_valid(_progress):
		_progress.set_fraction(fraction)

func set_leading_icon(icon_name: String):
	if not is_instance_valid(_leading_icon):
		return
	if icon_name.is_empty():
		_leading_icon.visible = false
	else:
		_leading_icon.icon_settings.icon_name = icon_name
		_leading_icon.visible = true
		_update_appearance()

func set_pulsing(enabled: bool):
	if is_instance_valid(_progress):
		_progress.indeterminate = enabled

func refresh_theme():
	_update_appearance()
	if is_instance_valid(_progress):
		_progress.refresh_theme()
