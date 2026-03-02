class_name PlatformIndicator
extends Control

signal platform_selected(platform_slug: String)

@onready var _prev_button: Button
@onready var _next_button: Button
@onready var _platform_labels: Array[Label] = []

const PLATFORM_COUNT: int = 5  # Total visible platforms (prev2, prev1, current, next1, next2)
const INDICATOR_HEIGHT: float = 50.0

var _platforms: Array[Dictionary] = []
var _current_index: int = -1  # -1 means "All Games"
var _all_games_label: String = "ALL"

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
	_prev_button.flat = true
	_prev_button.focus_mode = Control.FOCUS_NONE
	_prev_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prev_button.add_theme_font_size_override("font_size", 20)
	hbox.add_child(_prev_button)
	
	# Platform labels container
	var platform_container = HBoxContainer.new()
	platform_container.name = "PlatformContainer"
	platform_container.alignment = BoxContainer.ALIGNMENT_CENTER
	platform_container.add_theme_constant_override("separation", 24)
	hbox.add_child(platform_container)
	
	# Create platform labels (will be populated dynamically)
	for i in range(PLATFORM_COUNT):
		var label = _create_platform_label()
		platform_container.add_child(label)
		_platform_labels.append(label)
	
	# Next button (>)
	_next_button = Button.new()
	_next_button.name = "NextButton"
	_next_button.text = ">"
	_next_button.flat = true
	_next_button.focus_mode = Control.FOCUS_NONE
	_next_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_next_button.add_theme_font_size_override("font_size", 20)
	hbox.add_child(_next_button)

func _create_platform_label() -> Label:
	var label = Label.new()
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return label

func update_display(platforms: Array[Dictionary], current_index: int):
	_platforms = platforms
	_current_index = current_index
	_refresh_labels()

func _refresh_labels():
	if _platform_labels.is_empty():
		return
	
	# Calculate which platforms to show with wrapping
	# Total items = platforms + "All Games" (-1)
	# We want to show: prev2, prev1, current, next1, next2
	
	var total_items = _platforms.size() + 1  # +1 for "All Games"
	if total_items <= 1:
		# Not enough items to show
		for i in range(PLATFORM_COUNT):
			_platform_labels[i].text = ""
		return
	
	var visible_platforms: Array[String] = []
	
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
		
		var platform_name: String
		if target_index == -1:
			platform_name = _all_games_label
		else:
			platform_name = _platforms[target_index].get("name", "???")
		
		visible_platforms.append(platform_name)
	
	# Update labels
	for i in range(PLATFORM_COUNT):
		var label = _platform_labels[i]
		var is_center = (i == 2)  # Middle label is current
		var platform_name = visible_platforms[i]
		
		label.text = platform_name.to_upper().replace(" ", "")
		
		# Style based on position
		if is_center:
			# Current platform - highlighted with pill background
			label.add_theme_color_override("font_color", Color.WHITE)
			label.add_theme_font_size_override("font_size", 18)
			label.add_theme_stylebox_override("normal", _create_highlight_style())
		else:
			# Other platforms - visible but not highlighted
			label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7, 0.9))
			label.add_theme_font_size_override("font_size", 14)
			label.remove_theme_stylebox_override("normal")

func _create_highlight_style() -> StyleBoxFlat:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.25, 0.25, 0.25, 0.9)
	style.corner_radius_top_left = 16
	style.corner_radius_top_right = 16
	style.corner_radius_bottom_left = 16
	style.corner_radius_bottom_right = 16
	return style

func get_all_games_label() -> String:
	return _all_games_label

func set_all_games_label(label: String):
	_all_games_label = label
	_refresh_labels()