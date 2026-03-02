class_name PlatformIndicator
extends Control

signal platform_selected(platform_index: int)
signal cycle_prev_clicked()
signal cycle_next_clicked()

@onready var _prev_button: Button
@onready var _next_button: Button
@onready var _platform_buttons: Array[Button] = []

const PLATFORM_COUNT: int = 5  # Total visible platforms (prev2, prev1, current, next1, next2)
const INDICATOR_HEIGHT: float = 50.0

var _platforms: Array[Dictionary] = []
var _current_index: int = -1  # -1 means "All Games"
var _all_games_label: String = "ALL"
var _visible_indices: Array[int] = []  # Track which platform index each button represents

func _ready():
	_setup_ui()

func _setup_ui():
	# Main container
	var hbox = HBoxContainer.new()
	hbox.name = "MainContainer"
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 8)
	add_child(hbox)
	
	# Previous button (<)
	_prev_button = Button.new()
	_prev_button.name = "PrevButton"
	_prev_button.text = "<"
	_prev_button.focus_mode = Control.FOCUS_NONE
	_prev_button.add_theme_font_size_override("font_size", 20)
	_prev_button.pressed.connect(_on_prev_clicked)
	hbox.add_child(_prev_button)
	
	# Platform buttons container
	var platform_container = HBoxContainer.new()
	platform_container.name = "PlatformContainer"
	platform_container.alignment = BoxContainer.ALIGNMENT_CENTER
	platform_container.add_theme_constant_override("separation", 24)
	hbox.add_child(platform_container)
	
	# Create platform buttons (will be populated dynamically)
	for i in range(PLATFORM_COUNT):
		var btn = _create_platform_button(i)
		platform_container.add_child(btn)
		_platform_buttons.append(btn)
	
	# Next button (>)
	_next_button = Button.new()
	_next_button.name = "NextButton"
	_next_button.text = ">"
	_next_button.focus_mode = Control.FOCUS_NONE
	_next_button.add_theme_font_size_override("font_size", 20)
	_next_button.pressed.connect(_on_next_clicked)
	hbox.add_child(_next_button)

func _create_platform_button(index: int) -> Button:
	var btn = Button.new()
	btn.name = "PlatformButton" + str(index)
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 16)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	btn.pressed.connect(_on_platform_button_clicked.bind(index))
	return btn

func update_display(platforms: Array[Dictionary], current_index: int):
	_platforms = platforms
	_current_index = current_index
	_refresh_labels()

func _refresh_labels():
	if _platform_buttons.is_empty():
		return
	
	# Calculate which platforms to show with wrapping
	# Total items = platforms + "All Games" (-1)
	# We want to show: prev2, prev1, current, next1, next2
	
	var total_items = _platforms.size() + 1  # +1 for "All Games"
	if total_items <= 1:
		# Not enough items to show
		for i in range(PLATFORM_COUNT):
			_platform_buttons[i].text = ""
			_platform_buttons[i].disabled = true
		return
	
	_visible_indices.clear()
	
	# Build the list of visible platforms with wrapping
	for i in range(PLATFORM_COUNT):
		var offset = i - 2  # -2, -1, 0, 1, 2
		
		# Calculate wrapped index
		# Convert to 0-based index first (All = 0, platforms = 1 to size)
		var current_0_based = _current_index + 1  # -1 becomes 0, 0 becomes 1, etc.
		var target_0_based = current_0_based + offset
		
		# Wrap around
		target_0_based = ((target_0_based % total_items) + total_items) % total_items
		
		# Convert back to our index system
		var target_index = target_0_based - 1  # 0 becomes -1 (All), 1 becomes 0, etc.
		_visible_indices.append(target_index)
		
		var platform_name: String
		if target_index == -1:
			platform_name = _all_games_label
		else:
			platform_name = _platforms[target_index].get("name", "???")
		
		var btn = _platform_buttons[i]
		var is_center = (i == 2)  # Middle button is current
		
		btn.text = platform_name.to_upper().replace(" ", "")
		btn.disabled = false
		
		# Style based on position
		if is_center:
			# Current platform - highlighted with pill background on ALL states
			var pill_style = _create_highlight_style()
			btn.add_theme_stylebox_override("normal", pill_style)
			btn.add_theme_stylebox_override("hover", pill_style)
			btn.add_theme_stylebox_override("pressed", pill_style)
			btn.add_theme_stylebox_override("focus", pill_style)
			# Font colors for all states
			btn.add_theme_color_override("font_color", Color.WHITE)
			btn.add_theme_color_override("font_hover_color", Color.WHITE)
			btn.add_theme_color_override("font_pressed_color", Color.WHITE)
			btn.add_theme_color_override("font_focus_color", Color.WHITE)
			btn.add_theme_font_size_override("font_size", 18)
		else:
			# Other platforms - visible but not highlighted
			btn.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 0.9))
			btn.add_theme_color_override("font_hover_color", Color(0.7, 0.7, 0.7, 0.9))
			btn.add_theme_color_override("font_pressed_color", Color(0.7, 0.7, 0.7, 0.9))
			btn.add_theme_color_override("font_focus_color", Color(0.7, 0.7, 0.7, 0.9))
			btn.add_theme_font_size_override("font_size", 14)
			# Remove any background styles
			btn.remove_theme_stylebox_override("normal")
			btn.remove_theme_stylebox_override("hover")
			btn.remove_theme_stylebox_override("pressed")
			btn.remove_theme_stylebox_override("focus")

func _create_highlight_style() -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.25, 0.25, 0.25, 0.9)
	style.corner_radius_top_left = 16
	style.corner_radius_top_right = 16
	style.corner_radius_bottom_left = 16
	style.corner_radius_bottom_right = 16
	# Add padding so text doesn't get cut off
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	return style

func get_all_games_label() -> String:
	return _all_games_label

func set_all_games_label(label: String):
	_all_games_label = label
	_refresh_labels()

func _on_platform_button_clicked(button_index: int) -> void:
	"""Handle click on a platform button."""
	if button_index >= 0 and button_index < _visible_indices.size():
		var platform_index = _visible_indices[button_index]
		platform_selected.emit(platform_index)

func _on_prev_clicked() -> void:
	"""Handle click on previous arrow."""
	cycle_prev_clicked.emit()

func _on_next_clicked() -> void:
	"""Handle click on next arrow."""
	cycle_next_clicked.emit()