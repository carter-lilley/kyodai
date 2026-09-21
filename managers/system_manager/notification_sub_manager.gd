extends Manager
class_name NotificationSubManager

## Manages notifications using M3Snackbar for messages and M3Progress for progress.
## Message notifications stack up to MAX_STACK_SIZE visible snackbars. Older notifications
## are replaced when the stack is full. Progress notifications use a separate M3Snackbar.

enum Type { INFO, SUCCESS, WARNING, ERROR }

const TYPE_ICONS: Dictionary = {
	Type.INFO: "information-outline",
	Type.SUCCESS: "check-circle",
	Type.WARNING: "alert-outline",
	Type.ERROR: "close-circle-outline",
}

const MAX_STACK_SIZE = 3

signal notification_shown(id: int)
signal notification_dismissed(id: int)

class NotificationEntry:
	var id: int
	var base_text: String = ""
	var progress_callable: Callable
	var text_formatter: Callable
	var is_progress_linked: bool = false
	var is_pulsing: bool = false
	var is_pinned: bool = false

var _active_snackbars: Array[M3Snackbar] = []
var _active_ids: Array[int] = []
var _pinned_ids: Array[int] = []

var _current_progress_snackbar: M3Snackbar = null
var _current_progress_id: int = -1
var _progress_entry: NotificationEntry = null

var _notification_id_counter: int = 0
var _overlay_type_counter: int = 0
var _check_interval: float = 0.5

func _ready() -> void:
	var timer = Timer.new()
	timer.wait_time = _check_interval
	timer.timeout.connect(_check_notifications)
	add_child(timer)
	timer.start()

## Thread-safe wrapper for show_notification()
func show_notification_safe(
	text: String,
	type: Type = Type.INFO,
	_icon: Texture2D = null,
	min_duration: float = 3.0,
	progress_callable: Callable = Callable(),
	text_formatter: Callable = Callable(),
	pulsing: bool = false,
	pinned: bool = false
) -> int:
	var id = _notification_id_counter
	_notification_id_counter += 1
	
	# Queue to main thread
	_show_notification_deferred.bind(id, text, type, _icon, min_duration, progress_callable, text_formatter, pulsing, pinned).call_deferred()
	return id

func _show_notification_deferred(id: int, text: String, type: Type, _icon: Texture2D, min_duration: float, progress_callable: Callable, text_formatter: Callable, pulsing: bool, pinned: bool) -> void:
	print("[SystemManager.notifications] _show_notification_deferred id=" + str(id))
	if HeadlessLaunchRunner.is_active():
		print("[notification] ", text)
		return
	if not progress_callable.is_null() or pulsing:
		_show_progress_snackbar(id, text, type, progress_callable, text_formatter, pulsing, pinned)
	else:
		_show_message(id, text, type, min_duration, pinned)
	notification_shown.emit(id)

## Thread-safe wrapper for dismiss_notification()
func dismiss_notification_safe(id: int) -> void:
	dismiss_notification.bind(id).call_deferred()

func show_notification(
	text: String,
	type: Type = Type.INFO,
	_icon: Texture2D = null,
	min_duration: float = 3.0,
	progress_callable: Callable = Callable(),
	text_formatter: Callable = Callable(),
	pulsing: bool = false,
	pinned: bool = false
) -> int:
	var id = _notification_id_counter
	_notification_id_counter += 1

	# Headless launch companions have no snackbar UI - log instead
	if HeadlessLaunchRunner.is_active():
		print("[notification] ", text)
		return id

	if not progress_callable.is_null() or pulsing:
		_show_progress_snackbar(id, text, type, progress_callable, text_formatter, pulsing, pinned)
	else:
		_show_message(id, text, type, min_duration, pinned)

	notification_shown.emit(id)
	return id

func _show_message(id: int, text: String, type: Type, duration: float, pinned: bool = false) -> void:
	if pinned:
		_pinned_ids.append(id)
	else:
		# Only count unpinned toward stack size; dismiss oldest unpinned if full
		var unpinned_count = _active_ids.size() - _pinned_ids.size()
		if unpinned_count >= MAX_STACK_SIZE:
			for i in range(_active_snackbars.size() - 1, -1, -1):
				var check_id = _active_ids[i]
				if not _pinned_ids.has(check_id):
					var oldest_snackbar = _active_snackbars[i]
					var oldest_id = _active_ids[i]
					if oldest_snackbar and is_instance_valid(oldest_snackbar):
						oldest_snackbar.dismiss()
					else:
						_active_snackbars.remove_at(i)
						_active_ids.remove_at(i)
						notification_dismissed.emit(oldest_id)
					break

	var snackbar = _spawn_message_snackbar(text, type, duration)
	_active_snackbars.insert(0, snackbar)
	_active_ids.insert(0, id)
	_reposition_stack()

func _spawn_message_snackbar(text: String, type: Type, duration: float) -> M3Snackbar:
	var snackbar = M3Snackbar.new()
	snackbar.set_overlay_type("snackbar_stack_" + str(_overlay_type_counter))
	_overlay_type_counter += 1
	snackbar.setup(text, "", Callable(), true)
	snackbar.set_leading_icon(TYPE_ICONS.get(type, "info"))
	snackbar.set_hover_pauses_timer(false)
	snackbar.dismissed.connect(_on_message_snackbar_dismissed.bind(snackbar))
	# Parent via the overlay parent (MainViewport in DS mode) so the snackbar
	# renders on the active screen instead of the root window.
	M3Overlay.get_overlay_parent().add_child(snackbar)
	snackbar.show_overlay()
	snackbar.start_timer(int(duration * 1000))
	return snackbar

func _on_message_snackbar_dismissed(snackbar: M3Snackbar) -> void:
	var index = _active_snackbars.find(snackbar)
	if index == -1:
		return

	var dismissed_id = _active_ids[index]
	_active_snackbars.remove_at(index)
	_active_ids.remove_at(index)
	_pinned_ids.erase(dismissed_id)
	notification_dismissed.emit(dismissed_id)

	_reposition_stack()

func _reposition_stack() -> void:
	for i in range(_active_snackbars.size()):
		var snackbar = _active_snackbars[i]
		if is_instance_valid(snackbar):
			snackbar.set_stack_offset(i)

func _show_progress_snackbar(id: int, text: String, type: Type, progress_callable: Callable, text_formatter: Callable, pulsing: bool, pinned: bool = false) -> void:
	if _current_progress_snackbar and is_instance_valid(_current_progress_snackbar):
		_current_progress_snackbar.dismiss()

	_current_progress_id = id
	var snackbar = M3Snackbar.new()
	snackbar.set_overlay_type("snackbar_progress")
	snackbar.set_auto_dismiss(false)
	snackbar.setup(text, "", Callable(), not pinned)
	snackbar.set_leading_icon(TYPE_ICONS.get(type, "info"))
	snackbar.show_progress(true)
	if pulsing:
		snackbar.set_pulsing(true)
	snackbar.dismissed.connect(_on_progress_snackbar_dismissed.bind(snackbar))
	M3Overlay.get_overlay_parent().add_child(snackbar)
	snackbar.show_overlay()
	_current_progress_snackbar = snackbar

	_progress_entry = NotificationEntry.new()
	_progress_entry.id = id
	_progress_entry.base_text = text
	_progress_entry.progress_callable = progress_callable
	_progress_entry.text_formatter = text_formatter
	_progress_entry.is_pulsing = pulsing
	_progress_entry.is_progress_linked = true
	_progress_entry.is_pinned = pinned

func _on_progress_snackbar_dismissed(snackbar: M3Snackbar) -> void:
	# Ignore stale dismissals from a previous progress snackbar whose exit
	# tween finished after a newer progress snackbar already replaced it.
	if snackbar != _current_progress_snackbar:
		return
	var dismissed_id = _current_progress_id
	_current_progress_snackbar = null
	_current_progress_id = -1
	_progress_entry = null
	notification_dismissed.emit(dismissed_id)

func dismiss_notification(id: int) -> void:
	var index = _active_ids.find(id)
	if index != -1:
		var snackbar = _active_snackbars[index]
		if is_instance_valid(snackbar):
			snackbar.dismiss()
		# _on_message_snackbar_dismissed handles array cleanup and repositioning

	if id == _current_progress_id and _current_progress_snackbar and is_instance_valid(_current_progress_snackbar):
		_current_progress_snackbar.dismiss()

	_pinned_ids.erase(id)

## Dismisses the active progress notification if its base text starts with the
## given prefix. Returns true if a notification was dismissed.
func dismiss_progress_notification_by_prefix(prefix: String) -> bool:
	if _progress_entry and _current_progress_id != -1 and _progress_entry.base_text.begins_with(prefix):
		dismiss_notification(_current_progress_id)
		return true
	return false

func dismiss_all_notifications() -> void:
	# Iterate backwards so removal doesn't shift indices
	for i in range(_active_snackbars.size() - 1, -1, -1):
		var id = _active_ids[i]
		if _pinned_ids.has(id):
			continue
		var snackbar = _active_snackbars[i]
		if is_instance_valid(snackbar):
			snackbar.dismiss()
		else:
			_active_snackbars.remove_at(i)
			_active_ids.remove_at(i)
			notification_dismissed.emit(id)

	if _current_progress_snackbar and is_instance_valid(_current_progress_snackbar):
		if not _progress_entry or not _progress_entry.is_pinned:
			_current_progress_snackbar.dismiss()

func update_notification_text(id: int, text: String) -> void:
	var index = _active_ids.find(id)
	if index != -1:
		var snackbar = _active_snackbars[index]
		if is_instance_valid(snackbar):
			snackbar.set_message(text)

	if id == _current_progress_id and _current_progress_snackbar and is_instance_valid(_current_progress_snackbar):
		_current_progress_snackbar.set_message(text)
		if _progress_entry:
			_progress_entry.base_text = text

## Switches the active progress notification between indeterminate (pulsing)
## and determinate (fraction-driven) modes.
func set_notification_pulsing(id: int, pulsing: bool) -> void:
	if id != _current_progress_id:
		return
	if not _current_progress_snackbar or not is_instance_valid(_current_progress_snackbar):
		return
	_current_progress_snackbar.set_pulsing(pulsing)
	if _progress_entry:
		_progress_entry.is_pulsing = pulsing

## Forces one progress/text refresh cycle for the active progress notification.
## Used to show final totals before the notification is dismissed.
func refresh_progress_notification() -> void:
	if not _progress_entry or not _current_progress_snackbar or not is_instance_valid(_current_progress_snackbar):
		return
	if _progress_entry.text_formatter.is_valid():
		var progress := 0.0
		if _progress_entry.progress_callable.is_valid():
			progress = float(_progress_entry.progress_callable.call())
		_current_progress_snackbar.set_message(_progress_entry.text_formatter.call(progress))
	if not _progress_entry.is_pulsing and _progress_entry.progress_callable.is_valid():
		_current_progress_snackbar.set_progress_fraction(clampf(float(_progress_entry.progress_callable.call()), 0.0, 1.0))

func _check_notifications() -> void:
	if not _progress_entry or not _current_progress_snackbar or not is_instance_valid(_current_progress_snackbar):
		return

	if _progress_entry.is_pulsing:
		# Pulsing animation is handled internally by M3Progress
		return

	var progress = _progress_entry.progress_callable.call()
	if progress is float or progress is int:
		var progress_f = float(progress)
		if progress_f >= 1.0:
			dismiss_notification(_current_progress_id)
			return

		_current_progress_snackbar.set_progress_fraction(progress_f)

		if _progress_entry.text_formatter.is_valid():
			_current_progress_snackbar.set_message(_progress_entry.text_formatter.call(progress_f))
		else:
			var percent = int(progress_f * 100)
			_current_progress_snackbar.set_message(_progress_entry.base_text + " (" + str(percent) + "%)" )
