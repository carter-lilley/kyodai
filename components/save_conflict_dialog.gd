## Save Conflict Dialog Component
## Mimics Steam Cloud Conflict UI
## Shows when local and server saves have both changed since last sync

class_name SaveConflictDialog
extends PanelContainer

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
	# Ensure we're modal and on top
	z_index = 100
	
	# Create UI layout
	var vbox = VBoxContainer.new()
	vbox.name = "MainVBox"
	vbox.add_theme_constant_override("separation", 12)
	add_child(vbox)
	
	# Title
	var title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "Save Conflict"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 24)
	vbox.add_child(title_label)
	
	# Description
	var desc_label = Label.new()
	desc_label.name = "DescLabel"
	desc_label.text = "Your local save data conflicts with what is stored on the server.\nWhichever save data you choose to keep will be synced to this device and the cloud.\nThe option you choose not to keep will be overwritten."
	desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc_label)
	
	# Spacer
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer)
	
	# Server save button
	var server_btn = Button.new()
	server_btn.name = "ServerButton"
	server_btn.custom_minimum_size = Vector2(400, 60)
	server_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	server_btn.pressed.connect(_on_server_pressed)
	vbox.add_child(server_btn)
	
	# Local save button
	var local_btn = Button.new()
	local_btn.name = "LocalButton"
	local_btn.custom_minimum_size = Vector2(400, 60)
	local_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	local_btn.pressed.connect(_on_local_pressed)
	vbox.add_child(local_btn)
	
	# Spacer
	var spacer2 = Control.new()
	spacer2.custom_minimum_size = Vector2(0, 8)
	vbox.add_child(spacer2)
	
	# Cancel button (right-aligned)
	var cancel_btn = Button.new()
	cancel_btn.name = "CancelButton"
	cancel_btn.text = "Cancel"
	cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	cancel_btn.pressed.connect(_on_cancel_pressed)
	vbox.add_child(cancel_btn)
	
	# Update text if setup was called before _ready
	if _game_name != "":
		_update_ui()
	
	# Center the dialog
	_center_dialog()
	
	# Handle cancel/back input
	process_mode = Node.PROCESS_MODE_ALWAYS

func _update_ui() -> void:
	var vbox = get_node_or_null("MainVBox")
	if not vbox:
		return
	
	var server_btn = vbox.get_node_or_null("ServerButton")
	var local_btn = vbox.get_node_or_null("LocalButton")
	
	var server_date = _format_timestamp(_server_time)
	var local_date = _format_timestamp(_local_time)
	
	if server_btn:
		server_btn.text = "Server Save\nModified: " + server_date
	
	if local_btn:
		local_btn.text = "Local Save\nModified: " + local_date

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

func _center_dialog() -> void:
	var viewport_size = get_viewport_rect().size
	var dialog_size = Vector2(500, 300)
	position = (viewport_size - dialog_size) / 2
	size = dialog_size

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

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_center_dialog()
