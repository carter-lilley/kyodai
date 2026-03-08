extends Manager

# Manages a stack of notification popups that appear in a corner
# Supports both simple timed notifications and progress-linked notifications

enum StackDirection { UPWARD, DOWNWARD }

# Set to true to show debug visualization
const DEBUG_MODE: bool = false

signal notification_shown(id: int)
signal notification_dismissed(id: int)

class NotificationEntry:
	var id: int
	var notification: Notification
	var created_at: float
	var min_duration: float
	var progress_callable: Callable  # Optional: func() -> float (0.0-1.0)
	var text_formatter: Callable  # Optional: func(progress: float) -> String
	var is_progress_linked: bool = false
	var is_pulsing: bool = false  # NEW: For indeterminate progress animations
	var fade_out_started: bool = false
	var base_text: String = ""

var _stack_control: Control
var _notification_container: VBoxContainer
var _debug_panel: PanelContainer
var _notifications: Array[NotificationEntry] = []
var _notification_id_counter: int = 0
var _notification_width: float = 300.0
var _max_notifications: int = 5
var _fade_duration: float = 0.3
var _check_interval: float = 0.1
var _stack_direction: StackDirection = StackDirection.UPWARD

func _ready() -> void:
	# Create the stack control for positioning
	_stack_control = Control.new()
	_stack_control.name = "NotificationStack"
	# Use full viewport height with top margin
	_stack_control.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_stack_control.anchor_bottom = 1.0
	_stack_control.offset_left = -_notification_width - 20
	_stack_control.offset_top = 20
	_stack_control.offset_right = -20
	_stack_control.offset_bottom = -20
	_stack_control.custom_minimum_size = Vector2(_notification_width, 200)
	_stack_control.top_level = true
	_stack_control.z_index = 100
	add_child(_stack_control)
	
	# Connect to viewport resize to update positioning
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	
	# Setup container for stacking notifications
	_notification_container = VBoxContainer.new()
	_notification_container.alignment = BoxContainer.ALIGNMENT_END
	_notification_container.add_theme_constant_override("separation", 8)
	_notification_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stack_control.add_child(_notification_container)
	
	_apply_stack_direction()
	
	# Enable debug visualization if configured
	if DEBUG_MODE:
		set_debug_mode(true)
	
	# Start checking for expired notifications
	var timer = Timer.new()
	timer.wait_time = _check_interval
	timer.timeout.connect(_check_notifications)
	add_child(timer)
	timer.start()

func initialize(parent: Control) -> void:
	"""Call this to position the manager in a corner of your UI"""
	parent.add_child(self)

func set_notification_width(width: float) -> void:
	_notification_width = width
	if _stack_control:
		_stack_control.offset_left = -_notification_width - 20

func set_max_notifications(max_count: int) -> void:
	_max_notifications = max_count

func set_stack_direction(direction: StackDirection) -> void:
	_stack_direction = direction
	_apply_stack_direction()

func _apply_stack_direction() -> void:
	if not _notification_container:
		return
	
	# Reverse the child order in the container based on direction
	if _stack_direction == StackDirection.UPWARD:
		# Newest at bottom, stack grows upward
		_notification_container.alignment = BoxContainer.ALIGNMENT_END
	else:
		# Newest at top, stack grows downward
		_notification_container.alignment = BoxContainer.ALIGNMENT_BEGIN

func _on_viewport_size_changed() -> void:
	# The anchors handle resizing automatically, but we can update width if needed
	if _stack_control:
		_stack_control.offset_left = -_notification_width - 20

func set_fade_duration(duration: float) -> void:
	_fade_duration = duration

func set_debug_mode(enabled: bool) -> void:
	"""Toggle a colored background on the notification container for debugging"""
	if not _stack_control:
		return
	
	if enabled:
		if not _debug_panel:
			_debug_panel = PanelContainer.new()
			_debug_panel.name = "DebugPanel"
			var style = StyleBoxFlat.new()
			style.bg_color = Color(1, 0, 0, 0.3)  # Semi-transparent red
			_debug_panel.add_theme_stylebox_override("panel", style)
			_debug_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
			_stack_control.add_child(_debug_panel)
			_stack_control.move_child(_debug_panel, 0)  # Put behind VBox
	else:
		if _debug_panel:
			_debug_panel.queue_free()
			_debug_panel = null

func show_notification(
	text: String,
	type: Notification.Type = Notification.Type.INFO,
	icon: Texture2D = null,
	min_duration: float = 3.0,
	progress_callable: Callable = Callable(),  # Optional: func() -> float (0.0-1.0)
	text_formatter: Callable = Callable(),  # Optional: func(progress: float) -> String
	pulsing: bool = false  # NEW: Enable indeterminate pulsing progress
) -> int:
	"""Show a notification. If progress_callable is provided, updates progress bar and fades at 100%.
	If text_formatter is provided, it's called with progress to format text. Otherwise, percentage is auto-appended."""
	var notification = _create_notification(text, type, icon)

	var entry = NotificationEntry.new()
	entry.id = _notification_id_counter
	entry.notification = notification
	entry.created_at = Time.get_unix_time_from_system()
	entry.min_duration = min_duration
	entry.progress_callable = progress_callable
	entry.text_formatter = text_formatter
	entry.base_text = text
	entry.is_pulsing = pulsing
	entry.is_progress_linked = not progress_callable.is_null() or pulsing

	if entry.is_progress_linked:
		# Hide percentage for pulsing notifications, show for regular progress
		notification.show_progress(true, not entry.is_pulsing)
	
	_notifications.append(entry)
	_add_notification_to_container(notification)
	
	# Fade in
	notification.modulate = Color(1, 1, 1, 0)
	var tween = create_tween()
	tween.tween_property(notification, "modulate", Color(1, 1, 1, 1), _fade_duration)
	
	_notification_id_counter += 1
	notification_shown.emit(entry.id)
	
	_enforce_max_notifications()
	return entry.id

func _add_notification_to_container(notification: Notification) -> void:
	if _stack_direction == StackDirection.UPWARD:
		# Add at index 0 so newest appears at bottom, pushing older ones up
		_notification_container.add_child(notification)
		_notification_container.move_child(notification, 0)
	else:
		# Add at end so newest appears at top, pushing older ones down
		_notification_container.add_child(notification)

func dismiss_notification(id: int) -> void:
	"""Manually dismiss a notification by ID"""
	for entry in _notifications:
		if entry.id == id and not entry.fade_out_started:
			_start_fade_out(entry)
			return

func update_notification_text(id: int, text: String) -> void:
	"""Update the text of an existing notification"""
	for entry in _notifications:
		if entry.id == id and is_instance_valid(entry.notification):
			entry.notification.set_text(text)
			return

func _create_notification(text: String, type: Notification.Type, icon: Texture2D) -> Notification:
	var notification = Notification.new()
	notification.custom_minimum_size = Vector2(_notification_width, 0)
	notification.size_flags_vertical = Control.SIZE_SHRINK_BEGIN  # Don't expand vertically
	notification.set_text(text)
	notification.set_type(type)
	if icon:
		notification.set_icon(icon)
	return notification

func _check_notifications() -> void:
	var current_time = Time.get_unix_time_from_system()
	
	for entry in _notifications.duplicate():
		if entry.fade_out_started:
			continue
		
		# Update progress if using a callable or pulsing
		if entry.is_progress_linked and is_instance_valid(entry.notification):
			var progress_f: float
			
			if entry.is_pulsing:
				# Pulsing animation: 2 second cycle
				progress_f = (Time.get_ticks_msec() % 2000) / 2000.0
				entry.notification.set_progress(progress_f)
				# Pulsing notifications don't auto-dismiss based on progress
				# And don't update text with percentage
			else:
				# Regular progress callable
				var progress = entry.progress_callable.call()
				if progress is float or progress is int:
					progress_f = float(progress)
					entry.notification.set_progress(progress_f)

					# Update text based on formatter or auto-append percentage
					if entry.text_formatter.is_valid():
						entry.notification.set_text(entry.text_formatter.call(progress_f))
					else:
						var percent = int(progress_f * 100)
						entry.notification.set_text(entry.base_text + " (" + str(percent) + "%)")

					if progress >= 1.0:
						_start_fade_out(entry)
						continue
			
		# Check if simple notification has expired
		if not entry.is_progress_linked:
			if current_time - entry.created_at >= entry.min_duration:
				_start_fade_out(entry)

func _start_fade_out(entry: NotificationEntry) -> void:
	if entry.fade_out_started:
		return
	
	entry.fade_out_started = true
	
	if not is_instance_valid(entry.notification):
		_remove_notification_entry(entry)
		return
	
	# Fade out
	var tween = create_tween()
	tween.tween_property(entry.notification, "modulate", Color(1, 1, 1, 0), _fade_duration)
	tween.tween_callback(func():
		_remove_notification_entry(entry)
	)

func _remove_notification_entry(entry: NotificationEntry) -> void:
	if is_instance_valid(entry.notification):
		entry.notification.queue_free()
	
	_notifications.erase(entry)
	notification_dismissed.emit(entry.id)

func _enforce_max_notifications() -> void:
	"""Remove oldest notification if we exceed max (only remove one at a time)"""
	if _notifications.size() > _max_notifications:
		# Find oldest non-fading notification
		var oldest: NotificationEntry = null
		for entry in _notifications:
			if not entry.fade_out_started:
				if oldest == null or entry.created_at < oldest.created_at:
					oldest = entry
		
		if oldest:
			_start_fade_out(oldest)

func get_active_notification_count() -> int:
	return _notifications.size()

func clear_all_notifications() -> void:
	for entry in _notifications.duplicate():
		_start_fade_out(entry)
