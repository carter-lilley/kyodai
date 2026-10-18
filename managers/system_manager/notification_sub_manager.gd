extends Manager
class_name NotificationSubManager

## Manages notifications as a single unified stack of M3Snackbars.
## Message and progress notifications share one bottom-anchored stack capped at
## MAX_STACK_SIZE visible entries. Progress notifications no longer replace each
## other - concurrent downloads, extractions, syncs, etc. are all visible at once.
##
## Pinned entries are sticky while active: they survive stack eviction,
## dismiss_all_notifications(), and (for messages) the auto-dismiss timer, and
## cannot be dismissed by the user. A pinned progress entry still dismisses
## itself when its progress callable reaches 1.0.
##
## When every visible slot is unevictable, new notifications wait in a FIFO
## pending queue and appear as slots free up, so notifications are never
## silently dropped.

enum Type { INFO, SUCCESS, WARNING, ERROR }

const TYPE_ICONS: Dictionary = {
	Type.INFO: "information-outline",
	Type.SUCCESS: "check-circle",
	Type.WARNING: "alert-outline",
	Type.ERROR: "close-circle-outline",
}

const MAX_STACK_SIZE = 4

signal notification_shown(id: int)
signal notification_dismissed(id: int)

class NotificationEntry:
	var id: int
	var snackbar: M3Snackbar = null  ## null while waiting in the pending queue
	var base_text: String = ""
	var icon_name: String = "information-outline"
	var min_duration: float = 3.0
	var is_progress: bool = false
	var progress_callable: Callable
	var text_formatter: Callable
	var is_pulsing: bool = false
	var is_pinned: bool = false
	var attach_attempts: int = 0  ## retries after add_child() was refused (blocked parent)

const MAX_ATTACH_ATTEMPTS = 120  ## ~2s of frames; beyond this the entry is dropped

## Visible entries, index 0 = bottom of the stack (newest).
var _entries: Array[NotificationEntry] = []
## FIFO overflow queue for notifications that don't fit on screen.
var _pending: Array[NotificationEntry] = []

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
	if HeadlessLaunchRunner.is_active():
		print("[notification] ", text)
		return
	_create_entry(id, text, type, min_duration, progress_callable, text_formatter, pulsing, pinned)
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

	_create_entry(id, text, type, min_duration, progress_callable, text_formatter, pulsing, pinned)
	notification_shown.emit(id)
	return id

# ============================================================================
# Entry lifecycle
# ============================================================================

func _create_entry(id: int, text: String, type: Type, min_duration: float, progress_callable: Callable, text_formatter: Callable, pulsing: bool, pinned: bool) -> void:
	var entry := NotificationEntry.new()
	entry.id = id
	entry.base_text = text
	entry.icon_name = TYPE_ICONS.get(type, "information-outline")
	entry.min_duration = min_duration
	entry.is_progress = not progress_callable.is_null() or pulsing
	entry.progress_callable = progress_callable
	entry.text_formatter = text_formatter
	entry.is_pulsing = pulsing
	entry.is_pinned = pinned

	if _try_make_room():
		_show_entry(entry)
	else:
		# Stack is full of pinned/progress entries - queue instead of dropping.
		_pending.push_back(entry)

## Ensures a visible slot is available: true if the stack has room or an
## evictable (unpinned, non-progress) entry was dismissed to make room.
func _try_make_room() -> bool:
	if _visible_count() < MAX_STACK_SIZE:
		return true
	# Evict the oldest evictable message (oldest = end of the array).
	for i in range(_entries.size() - 1, -1, -1):
		var entry := _entries[i]
		if entry.is_pinned or entry.is_progress:
			continue
		if entry.snackbar and is_instance_valid(entry.snackbar):
			if entry.snackbar.is_dismissing():
				continue  # already freeing its slot
			entry.snackbar.dismiss()
		else:
			_entries.remove_at(i)
			notification_dismissed.emit(entry.id)
		# _on_snackbar_dismissed finishes cleanup when the exit tween ends.
		return true
	return false

## Entries whose snackbars are mid-exit-tween still occupy array slots but are
## already on their way out, so they don't count against the cap.
func _visible_count() -> int:
	var count := 0
	for entry in _entries:
		if entry.snackbar and is_instance_valid(entry.snackbar) and not entry.snackbar.is_dismissing():
			count += 1
	return count

func _show_entry(entry: NotificationEntry) -> bool:
	var snackbar := M3Snackbar.new()
	# Unique overlay type per snackbar: M3Overlay.show_overlay() dismisses any
	# existing overlay of the same type, which would stomp stacked snackbars.
	snackbar.set_overlay_type("snackbar_stack_" + str(_overlay_type_counter))
	_overlay_type_counter += 1
	# Progress snackbars never auto-dismiss; pinned messages don't either.
	# (_ready() starts a default timer when auto-dismiss is on, so this must
	# be set before the snackbar enters the tree.)
	if entry.is_progress or entry.is_pinned:
		snackbar.set_auto_dismiss(false)
	snackbar.setup(entry.base_text, "", Callable(), not entry.is_pinned)
	snackbar.set_leading_icon(entry.icon_name)
	snackbar.set_hover_pauses_timer(false)
	if entry.is_progress:
		snackbar.show_progress(true)
		if entry.is_pulsing:
			snackbar.set_pulsing(true)
	snackbar.dismissed.connect(_on_snackbar_dismissed.bind(snackbar))
	# Parent via the overlay parent (MainViewport in DS mode) so the snackbar
	# renders on the active screen instead of the root window.
	M3Overlay.get_overlay_parent().add_child(snackbar)
	if not snackbar.is_inside_tree():
		# add_child() was refused: the overlay parent (root on single-screen)
		# is blocked. This happens deterministically when called synchronously
		# from inside a propagated engine notification (e.g.
		# NOTIFICATION_APPLICATION_RESUMED), because
		# Node.propagate_notification() holds data.blocked on every node it
		# passes through for the entire propagation. Don't leave a zombie
		# occupying a stack slot: free the unattached snackbar, requeue the
		# entry, and retry at idle time once the propagation has finished.
		snackbar.queue_free()
		entry.attach_attempts += 1
		if entry.attach_attempts > MAX_ATTACH_ATTEMPTS:
			push_warning("[notification] Dropping notification %d: overlay parent still blocked after %d attempts" % [entry.id, entry.attach_attempts])
			notification_dismissed.emit(entry.id)
			return false
		_pending.push_front(entry)
		call_deferred("_drain_pending")
		return false
	snackbar.show_overlay()
	if not entry.is_progress and not entry.is_pinned:
		snackbar.start_timer(int(entry.min_duration * 1000))
	entry.snackbar = snackbar
	_entries.insert(0, entry)
	_reposition_stack()
	return true

func _on_snackbar_dismissed(snackbar: M3Snackbar) -> void:
	var entry := _find_entry_by_snackbar(snackbar)
	if entry == null:
		return
	_entries.erase(entry)
	notification_dismissed.emit(entry.id)
	_reposition_stack()
	_drain_pending()

## Moves queued notifications into newly freed visible slots.
func _drain_pending() -> void:
	while not _pending.is_empty() and _visible_count() < MAX_STACK_SIZE:
		# Stop on attach refusal (tree blocked mid propagated notification):
		# _show_entry already requeued the entry and scheduled a deferred retry.
		if not _show_entry(_pending.pop_front()):
			break

func _reposition_stack() -> void:
	# Cumulative pixel offsets: progress snackbars are taller than messages,
	# so slot-index math would overlap mixed stacks.
	var offset_px := 0.0
	for entry in _entries:
		if entry.snackbar and is_instance_valid(entry.snackbar):
			entry.snackbar.set_stack_offset_px(offset_px)
			offset_px += entry.snackbar.get_stack_height()

func _find_entry_by_id(id: int) -> NotificationEntry:
	for entry in _entries:
		if entry.id == id:
			return entry
	return null

func _find_entry_by_snackbar(snackbar: M3Snackbar) -> NotificationEntry:
	for entry in _entries:
		if entry.snackbar == snackbar:
			return entry
	return null

# ============================================================================
# Dismissal
# ============================================================================

func dismiss_notification(id: int) -> void:
	# Pending entries have no snackbar yet - just dequeue them.
	for entry in _pending:
		if entry.id == id:
			_pending.erase(entry)
			notification_dismissed.emit(id)
			return

	var entry := _find_entry_by_id(id)
	if entry == null:
		return
	if entry.snackbar and is_instance_valid(entry.snackbar):
		entry.snackbar.dismiss()
		# _on_snackbar_dismissed handles array cleanup, repositioning, draining
	else:
		_entries.erase(entry)
		notification_dismissed.emit(id)
		_reposition_stack()
		_drain_pending()

## Dismisses all visible progress notifications whose base text starts with the
## given prefix. Returns true if any notification was dismissed.
func dismiss_progress_notification_by_prefix(prefix: String) -> bool:
	var dismissed_any := false
	for entry in _entries.duplicate():
		if entry.is_progress and entry.base_text.begins_with(prefix):
			dismiss_notification(entry.id)
			dismissed_any = true
	return dismissed_any

func dismiss_all_notifications() -> void:
	# Iterate a copy: dismissal mutates _entries asynchronously via signals.
	for entry in _entries.duplicate():
		if entry.is_pinned:
			continue
		if entry.snackbar and is_instance_valid(entry.snackbar):
			entry.snackbar.dismiss()
		else:
			_entries.erase(entry)
			notification_dismissed.emit(entry.id)

# ============================================================================
# Live updates
# ============================================================================

func update_notification_text(id: int, text: String) -> void:
	var entry := _find_entry_by_id(id)
	if entry == null:
		return
	entry.base_text = text
	if entry.snackbar and is_instance_valid(entry.snackbar):
		entry.snackbar.set_message(text)

## Switches a progress notification between indeterminate (pulsing) and
## determinate (fraction-driven) modes.
func set_notification_pulsing(id: int, pulsing: bool) -> void:
	var entry := _find_entry_by_id(id)
	if entry == null or not entry.is_progress:
		return
	entry.is_pulsing = pulsing
	if entry.snackbar and is_instance_valid(entry.snackbar):
		entry.snackbar.set_pulsing(pulsing)

## Forces one progress/text refresh cycle for the given progress notification.
## Used to show final totals before the notification is dismissed.
func refresh_progress_notification(id: int) -> void:
	var entry := _find_entry_by_id(id)
	if entry == null or not entry.is_progress:
		return
	if not entry.snackbar or not is_instance_valid(entry.snackbar):
		return
	if entry.text_formatter.is_valid():
		var progress := 0.0
		if entry.progress_callable.is_valid():
			progress = float(entry.progress_callable.call())
		entry.snackbar.set_message(entry.text_formatter.call(progress))
	if not entry.is_pulsing and entry.progress_callable.is_valid():
		entry.snackbar.set_progress_fraction(clampf(float(entry.progress_callable.call()), 0.0, 1.0))

func _check_notifications() -> void:
	# Duplicate: completion dismissal mutates _entries during iteration.
	for entry in _entries.duplicate():
		if not entry.is_progress or entry.is_pulsing:
			continue
		if not entry.snackbar or not is_instance_valid(entry.snackbar):
			continue
		if not entry.progress_callable.is_valid():
			continue

		var progress = entry.progress_callable.call()
		if not (progress is float or progress is int):
			continue
		var progress_f := float(progress)
		if progress_f >= 1.0:
			dismiss_notification(entry.id)
			continue

		entry.snackbar.set_progress_fraction(progress_f)

		if entry.text_formatter.is_valid():
			entry.snackbar.set_message(entry.text_formatter.call(progress_f))
		else:
			var percent := int(progress_f * 100)
			entry.snackbar.set_message(entry.base_text + " (" + str(percent) + "%)")
