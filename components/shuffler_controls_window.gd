class_name ShufflerControlsWindow
extends Window

signal pause_requested()
signal resume_requested()
signal skip_requested()
signal restart_requested()
signal remove_requested()
signal stop_requested()

var _pause_btn: M3IconButton
var _is_paused: bool = false

func _ready():
	# Window configuration
	borderless = true
	always_on_top = true
	unresizable = true
	size = Vector2i(64, 320)
	position = Vector2i(16, DisplayServer.screen_get_size().y - 336)
	
	# Create container
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 8)
	add_child(vbox)
	
	# Pause/Resume button
	_pause_btn = _create_icon_button("pause", "Pause")
	_pause_btn.pressed.connect(_on_pause_pressed)
	vbox.add_child(_pause_btn)
	
	# Skip button
	var skip_btn = _create_icon_button("skip-next", "Skip")
	skip_btn.pressed.connect(skip_requested.emit)
	vbox.add_child(skip_btn)
	
	# Restart button
	var restart_btn = _create_icon_button("restart", "Restart")
	restart_btn.pressed.connect(restart_requested.emit)
	vbox.add_child(restart_btn)
	
	# Remove button
	var remove_btn = _create_icon_button("shuffle-variant", "Reroll")
	remove_btn.pressed.connect(remove_requested.emit)
	vbox.add_child(remove_btn)
	
	# Stop button
	var stop_btn = _create_icon_button("stop", "Stop")
	stop_btn.pressed.connect(stop_requested.emit)
	vbox.add_child(stop_btn)
	
	# Style the window background
	var panel = Panel.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12, 0.85)
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	panel.add_theme_stylebox_override("panel", style)
	vbox.add_child(panel)
	vbox.move_child(panel, 0)

func _create_icon_button(icon: String, tooltip: String) -> M3IconButton:
	var btn = M3IconButton.new()
	btn.icon_name = icon
	btn.icon_button_variant = M3IconButton.IconVariant.STANDARD
	btn.icon_button_size = M3IconButton.IconSize.LARGE
	btn.tooltip_text = tooltip
	btn.custom_minimum_size = Vector2(48, 48)
	return btn

func _on_pause_pressed():
	_is_paused = not _is_paused
	if _is_paused:
		_pause_btn.icon_name = "play"
		pause_requested.emit()
	else:
		_pause_btn.icon_name = "pause"
		resume_requested.emit()
