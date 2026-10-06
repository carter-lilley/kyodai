## Save Conflict Dialog Component
## Mimics Steam Cloud Conflict UI
## Shows when local and server saves have both changed since last sync
## Uses M3Dialog with custom content slot for save selection buttons

class_name SaveConflictDialog
extends M3Dialog

signal server_selected()
signal local_selected()
signal cancelled()

var _game_name: String = ""
var _server_time: int = 0
var _local_time: int = 0

func _init():
	super._init()
	title_text = "Save Conflict"
	body_text = "Your local save data conflicts with what is stored on the server.\n\nWhichever save data you choose to keep will be synced to this device and the cloud. The option you choose not to keep will be overwritten."
	dismissible = true

func setup(game_name: String, server_time_unix: int, local_time_unix: int) -> void:
	_game_name = game_name
	_server_time = server_time_unix
	_local_time = local_time_unix
	_update_ui()

func _ready() -> void:
	_ready_internal()
	_update_ui()

func _ready_internal() -> void:
	super._ready()
	_build_content()

func _build_content() -> void:
	content_slot.alignment = BoxContainer.ALIGNMENT_BEGIN

	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, M3Units.dp(16))
	content_slot.add_child(spacer)

	var server_btn = M3Button.new()
	server_btn.name = "ServerButton"
	server_btn.custom_minimum_size = Vector2(0, M3Units.dp(80))
	server_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	server_btn.button_size = M3Button.Size.LARGE
	server_btn.pressed.connect(_on_server_pressed)
	content_slot.add_child(server_btn)

	var local_btn = M3Button.new()
	local_btn.name = "LocalButton"
	local_btn.custom_minimum_size = Vector2(0, M3Units.dp(80))
	local_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	local_btn.button_size = M3Button.Size.LARGE
	local_btn.pressed.connect(_on_local_pressed)
	content_slot.add_child(local_btn)

	add_action("Cancel", _on_cancel_pressed, false)

func _update_ui() -> void:
	var server_btn = content_slot.get_node_or_null("ServerButton")
	var local_btn = content_slot.get_node_or_null("LocalButton")

	var server_date = _format_timestamp(_server_time)
	var local_date = _format_timestamp(_local_time)

	if server_btn:
		server_btn.text = "Server Save\nModified: " + server_date

	if local_btn:
		local_btn.text = "Local Save\nModified: " + local_date

	if _game_name != "":
		body_text = "Your local save data for %s conflicts with what is stored on the server.\n\nWhichever save data you choose to keep will be synced to this device and the cloud. The option you choose not to keep will be overwritten." % _game_name

func _format_timestamp(unix_time: int) -> String:
	if unix_time <= 0:
		return "Unknown"

	var dict = Time.get_datetime_dict_from_unix_time(unix_time)

	var tz_info = Time.get_time_zone_from_system()
	var tz_offset_minutes = tz_info.get("bias", 0)
	var adjusted_unix = unix_time + (tz_offset_minutes * 60)
	dict = Time.get_datetime_dict_from_unix_time(adjusted_unix)
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
	dismiss()

func _on_local_pressed() -> void:
	local_selected.emit()
	dismiss()

func _on_cancel_pressed() -> void:
	cancelled.emit()
	dismiss()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_on_cancel_pressed()
		get_viewport().set_input_as_handled()
