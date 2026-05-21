extends Manager

## Manages notifications using M3Snackbar for messages and M3Progress for progress.
## Simple messages queue into a single M3Snackbar. Progress notifications use a
## separate M3Snackbar with embedded M3Progress (overlay_type = "snackbar_progress").

enum Type { INFO, SUCCESS, WARNING, ERROR }

const TYPE_ICONS: Dictionary = {
	Type.INFO: "information-outline",
	Type.SUCCESS: "check-circle",
	Type.WARNING: "alert-outline",
	Type.ERROR: "close-circle-outline",
}

signal notification_shown(id: int)
signal notification_dismissed(id: int)

class NotificationEntry:
	var id: int
	var base_text: String = ""
	var progress_callable: Callable
	var text_formatter: Callable
	var is_progress_linked: bool = false
	var is_pulsing: bool = false

var _message_queue: Array[Dictionary] = []
var _current_message_snackbar: M3Snackbar = null
var _current_message_id: int = -1

var _current_progress_snackbar: M3Snackbar = null
var _current_progress_id: int = -1
var _progress_entry: NotificationEntry = null

var _notification_id_counter: int = 0
var _check_interval: float = 0.5

func _ready() -> void:
	var timer = Timer.new()
	timer.wait_time = _check_interval
	timer.timeout.connect(_check_notifications)
	add_child(timer)
	timer.start()

func show_notification(
	text: String,
	type: Type = Type.INFO,
	_icon: Texture2D = null,
	min_duration: float = 3.0,
	progress_callable: Callable = Callable(),
	text_formatter: Callable = Callable(),
	pulsing: bool = false
) -> int:
	var id = _notification_id_counter
	_notification_id_counter += 1

	if not progress_callable.is_null() or pulsing:
		_show_progress_snackbar(id, text, type, progress_callable, text_formatter, pulsing)
	else:
		_show_message(id, text, type, min_duration)

	notification_shown.emit(id)
	return id

func _show_message(id: int, text: String, type: Type, min_duration: float) -> void:
	if _current_message_snackbar and is_instance_valid(_current_message_snackbar):
		_message_queue.append({"id": id, "text": text, "type": type, "duration": min_duration})
		return

	_current_message_id = id
	_spawn_message_snackbar(text, type, min_duration)

func _spawn_message_snackbar(text: String, type: Type, duration: float) -> void:
	var snackbar = M3Snackbar.new()
	snackbar.setup(text, "", Callable(), true)
	snackbar.set_leading_icon(TYPE_ICONS.get(type, "info"))
	snackbar.dismissed.connect(_on_message_snackbar_dismissed)
	get_tree().root.add_child(snackbar)
	snackbar.show_overlay()
	snackbar.start_timer(int(duration * 1000))
	_current_message_snackbar = snackbar

func _on_message_snackbar_dismissed() -> void:
	var dismissed_id = _current_message_id
	_current_message_snackbar = null
	_current_message_id = -1
	notification_dismissed.emit(dismissed_id)
	if _message_queue.size() > 0:
		var next = _message_queue.pop_front()
		_current_message_id = next.id
		_spawn_message_snackbar(next.text, next.type, next.duration)

func _show_progress_snackbar(id: int, text: String, type: Type, progress_callable: Callable, text_formatter: Callable, pulsing: bool) -> void:
	if _current_progress_snackbar and is_instance_valid(_current_progress_snackbar):
		_current_progress_snackbar.dismiss()

	_current_progress_id = id
	var snackbar = M3Snackbar.new()
	snackbar.set_overlay_type("snackbar_progress")
	snackbar.set_auto_dismiss(false)
	snackbar.setup(text, "", Callable(), true)
	snackbar.set_leading_icon(TYPE_ICONS.get(type, "info"))
	snackbar.show_progress(true)
	if pulsing:
		snackbar.set_pulsing(true)
	snackbar.dismissed.connect(_on_progress_snackbar_dismissed)
	get_tree().root.add_child(snackbar)
	snackbar.show_overlay()
	_current_progress_snackbar = snackbar

	_progress_entry = NotificationEntry.new()
	_progress_entry.id = id
	_progress_entry.base_text = text
	_progress_entry.progress_callable = progress_callable
	_progress_entry.text_formatter = text_formatter
	_progress_entry.is_pulsing = pulsing
	_progress_entry.is_progress_linked = true

func _on_progress_snackbar_dismissed() -> void:
	var dismissed_id = _current_progress_id
	_current_progress_snackbar = null
	_current_progress_id = -1
	_progress_entry = null
	notification_dismissed.emit(dismissed_id)

func dismiss_notification(id: int) -> void:
	if id == _current_message_id and _current_message_snackbar and is_instance_valid(_current_message_snackbar):
		_current_message_snackbar.dismiss()
	_message_queue = _message_queue.filter(func(item): return item.id != id)

	if id == _current_progress_id and _current_progress_snackbar and is_instance_valid(_current_progress_snackbar):
		_current_progress_snackbar.dismiss()

func dismiss_all_notifications() -> void:
	if _current_message_snackbar and is_instance_valid(_current_message_snackbar):
		_current_message_snackbar.dismiss()
	_message_queue.clear()

	if _current_progress_snackbar and is_instance_valid(_current_progress_snackbar):
		_current_progress_snackbar.dismiss()

func update_notification_text(id: int, text: String) -> void:
	if id == _current_message_id and _current_message_snackbar and is_instance_valid(_current_message_snackbar):
		_current_message_snackbar.setup(text)

	if id == _current_progress_id and _current_progress_snackbar and is_instance_valid(_current_progress_snackbar):
		_current_progress_snackbar.setup(text)
		if _progress_entry:
			_progress_entry.base_text = text

func _check_notifications() -> void:
	if not _progress_entry or not _current_progress_snackbar or not is_instance_valid(_current_progress_snackbar):
		return

	if _progress_entry.is_pulsing:
		# Pulsing animation is handled internally by M3Progress
		return

	var progress = _progress_entry.progress_callable.call()
	if progress is float or progress is int:
		var progress_f = float(progress)
		_current_progress_snackbar.set_progress_fraction(progress_f)

		if _progress_entry.text_formatter.is_valid():
			_current_progress_snackbar.setup(_progress_entry.text_formatter.call(progress_f))
		else:
			var percent = int(progress_f * 100)
			_current_progress_snackbar.setup(_progress_entry.base_text + " (" + str(percent) + "%)" )

		if progress_f >= 1.0:
			_current_progress_snackbar.dismiss()

func get_active_notification_count() -> int:
	var count = 0
	if _current_message_snackbar and is_instance_valid(_current_message_snackbar):
		count += 1
	if _current_progress_snackbar and is_instance_valid(_current_progress_snackbar):
		count += 1
	count += _message_queue.size()
	return count

func clear_all_notifications() -> void:
	dismiss_all_notifications()
