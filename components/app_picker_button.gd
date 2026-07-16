class_name AppPickerButton
extends Button

## Button used inside scrollable app picker grids.
## Distinguishes quick taps (emit pressed) from scroll drags.

var _press_start_pos: Vector2 = Vector2.ZERO
var _is_dragging: bool = false
const DRAG_THRESHOLD_DP: float = 10.0

func _ready() -> void:
	# Handle mouse/touch activation ourselves so drags can scroll while taps
	# still activate the button.
	button_mask = 0
	mouse_filter = Control.MOUSE_FILTER_PASS

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_start_pos = event.position
				_is_dragging = false
				button_down.emit()
			else:
				button_up.emit()
				if not _is_dragging and not disabled:
					pressed.emit()
					accept_event()
				_is_dragging = false
		return

	if event is InputEventMouseMotion:
		if event.button_mask == MOUSE_BUTTON_MASK_LEFT and not _is_dragging:
			if event.position.distance_to(_press_start_pos) > M3Units.dp(DRAG_THRESHOLD_DP):
				_is_dragging = true
		return

	# Keyboard / gamepad activation is handled by the native Button focus logic.
