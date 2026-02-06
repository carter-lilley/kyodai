#notification.gd
extends PanelContainer
class_name Notification

enum Type { INFO, SUCCESS, WARNING, ERROR }

var _icon: TextureRect
var _text_label: Label
var _progress_bar: ProgressBar
var _content_container: VBoxContainer
var _main_container: HBoxContainer

var _type_styles: Dictionary = {}

func _init() -> void:
	_create_styles()

func _ready() -> void:
	# Main layout
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)
	
	_main_container = HBoxContainer.new()
	_main_container.add_theme_constant_override("separation", 8)
	margin.add_child(_main_container)
	
	# Icon (hidden by default)
	_icon = TextureRect.new()
	_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_icon.custom_minimum_size = Vector2(24, 24)
	_icon.visible = false
	_main_container.add_child(_icon)
	
	# Content container (text + progress)
	_content_container = VBoxContainer.new()
	_content_container.add_theme_constant_override("separation", 4)
	_content_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_main_container.add_child(_content_container)
	
	# Text label
	_text_label = Label.new()
	_text_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content_container.add_child(_text_label)
	
	# Progress bar (hidden by default)
	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size = Vector2(0, 8)
	_progress_bar.visible = false
	_content_container.add_child(_progress_bar)
	
	# Default style
	set_type(Type.INFO)

func _create_styles() -> void:
	var info_style = StyleBoxFlat.new()
	info_style.bg_color = Color("3498db")
	info_style.corner_radius_top_left = 6
	info_style.corner_radius_top_right = 6
	info_style.corner_radius_bottom_left = 6
	info_style.corner_radius_bottom_right = 6
	_type_styles[Type.INFO] = info_style
	
	var success_style = StyleBoxFlat.new()
	success_style.bg_color = Color("2ecc71")
	success_style.corner_radius_top_left = 6
	success_style.corner_radius_top_right = 6
	success_style.corner_radius_bottom_left = 6
	success_style.corner_radius_bottom_right = 6
	_type_styles[Type.SUCCESS] = success_style
	
	var warning_style = StyleBoxFlat.new()
	warning_style.bg_color = Color("f1c40f")
	warning_style.corner_radius_top_left = 6
	warning_style.corner_radius_top_right = 6
	warning_style.corner_radius_bottom_left = 6
	warning_style.corner_radius_bottom_right = 6
	_type_styles[Type.WARNING] = warning_style
	
	var error_style = StyleBoxFlat.new()
	error_style.bg_color = Color("e74c3c")
	error_style.corner_radius_top_left = 6
	error_style.corner_radius_top_right = 6
	error_style.corner_radius_bottom_left = 6
	error_style.corner_radius_bottom_right = 6
	_type_styles[Type.ERROR] = error_style

func set_text(text: String) -> void:
	if not is_node_ready():
		await ready
	_text_label.text = text

func get_text() -> String:
	return _text_label.text if _text_label else ""

func set_progress(value: float) -> void:
	if not is_node_ready():
		await ready
	_progress_bar.value = clamp(value, 0.0, 1.0) * 100

func get_progress() -> float:
	return _progress_bar.value / 100.0 if _progress_bar else 0.0

func show_progress(visible: bool) -> void:
	if not is_node_ready():
		await ready
	_progress_bar.visible = visible

func set_icon(texture: Texture2D) -> void:
	if not is_node_ready():
		await ready
	_icon.texture = texture
	_icon.visible = texture != null

func set_type(type: Type) -> void:
	if not is_node_ready():
		await ready
	if _type_styles.has(type):
		add_theme_stylebox_override("panel", _type_styles[type])
