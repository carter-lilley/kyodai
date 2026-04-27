## Save Conflict Dialog Component
## Mimics Steam Cloud Conflict UI
## Shows when local and server saves have both changed since last sync
## Layout follows OOBE wizard pattern with centered dialog over dark overlay

class_name SaveConflictDialog
extends Control

signal server_selected()
signal local_selected()
signal cancelled()

var _game_name: String = ""
var _server_time: int = 0
var _local_time: int = 0

func setup(game_name: String, server_time_unix: int, local_time_unix: int) -> void:
	_game_name = game_name
	_server_time = server_time_unix
	_local_time = local_time_unix
	_update_ui()

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build_ui()
	_update_ui()

func _build_ui():
	# Background overlay (matches OOBE pattern)
	var overlay = ColorRect.new()
	overlay.name = "Overlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0, 0, 0, 0.85)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	
	# Center container (matches OOBE pattern)
	var center = CenterContainer.new()
	center.name = "CenterContainer"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	
	# Dialog panel (matches OOBE ContentPanel pattern)
	var dialog_panel = PanelContainer.new()
	dialog_panel.name = "DialogPanel"
	dialog_panel.custom_minimum_size = Vector2(600, 400)
	center.add_child(dialog_panel)
	
	# Main VBox layout
	var main_vbox = VBoxContainer.new()
	main_vbox.name = "MainVBox"
	main_vbox.add_theme_constant_override("separation", 12)
	main_vbox.add_theme_constant_override("margin_left", 24)
	main_vbox.add_theme_constant_override("margin_right", 24)
	main_vbox.add_theme_constant_override("margin_top", 20)
	main_vbox.add_theme_constant_override("margin_bottom", 20)
	dialog_panel.add_child(main_vbox)
	
	# Title
	var title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "Save Conflict"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 24)
	main_vbox.add_child(title_label)
	
	# Separator
	main_vbox.add_child(HSeparator.new())
	
	# Description
	var desc_label = Label.new()
	desc_label.name = "DescLabel"
	desc_label.text = "Your local save data for %s conflicts with what is stored on the server.\n\nWhichever save data you choose to keep will be synced to this device and the cloud. The option you choose not to keep will be overwritten." % _game_name
	desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	main_vbox.add_child(desc_label)
	
	# Spacer
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 16)
	main_vbox.add_child(spacer)
	
	# Server save button (large, Steam-style with timestamp)
	var server_btn = Button.new()
	server_btn.name = "ServerButton"
	server_btn.custom_minimum_size = Vector2(0, 80)
	server_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	server_btn.pressed.connect(_on_server_pressed)
	main_vbox.add_child(server_btn)
	
	# Local save button (large, Steam-style with timestamp)
	var local_btn = Button.new()
	local_btn.name = "LocalButton"
	local_btn.custom_minimum_size = Vector2(0, 80)
	local_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	local_btn.pressed.connect(_on_local_pressed)
	main_vbox.add_child(local_btn)
	
	# Spacer to push cancel to bottom
	var spacer2 = Control.new()
	spacer2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(spacer2)
	
	# Cancel button (right-aligned, smaller)
	var cancel_btn = Button.new()
	cancel_btn.name = "CancelButton"
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	cancel_btn.pressed.connect(_on_cancel_pressed)
	main_vbox.add_child(cancel_btn)
	
	# Block input to scene below
	process_mode = Node.PROCESS_MODE_ALWAYS

func _update_ui() -> void:
	var main_vbox = get_node_or_null("CenterContainer/DialogPanel/MainVBox")
	if not main_vbox:
		return
	
	var server_btn = main_vbox.get_node_or_null("ServerButton")
	var local_btn = main_vbox.get_node_or_null("LocalButton")
	
	var server_date = _format_timestamp(_server_time)
	var local_date = _format_timestamp(_local_time)
	
	if server_btn:
		server_btn.text = "Server Save\nModified: " + server_date
	
	if local_btn:
		local_btn.text = "Local Save\nModified: " + local_date
	
	# Update description with game name if available
	var desc_label = main_vbox.get_node_or_null("DescLabel")
	if desc_label and _game_name != "":
		desc_label.text = "Your local save data for %s conflicts with what is stored on the server.\n\nWhichever save data you choose to keep will be synced to this device and the cloud. The option you choose not to keep will be overwritten." % _game_name

func _format_timestamp(unix_time: int) -> String:
	if unix_time <= 0:
		return "Unknown"
	
	var dict = Time.get_datetime_dict_from_unix_time(unix_time)
	var month_names = ["January", "February", "March", "April", "May", "June",
					"July", "August", "September", "October", "November", "December"]
	
	var month = month_names[dict.month - 1]
	var day = dict.day
	var year = dict.year
	var hour = dict.hour
	var minute = dict.minute
	var ampm = "AM" if hour < 12 else "PM"
	
	if hour > 12:
		hour -= 12
	elif hour == 0:
		hour = 12
	
	return "%s %d, %d at %d:%02d %s" % [month, day, year, hour, minute, ampm]

func _on_server_pressed() -> void:
	server_selected.emit()
	queue_free()

func _on_local_pressed() -> void:
	local_selected.emit()
	queue_free()

func _on_cancel_pressed() -> void:
	cancelled.emit()
	queue_free()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_cancel_pressed()
		get_viewport().set_input_as_handled()
