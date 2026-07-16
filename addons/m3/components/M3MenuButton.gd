class_name M3MenuButton
extends Button

## Material 3 Menu Button
## Handles its own press/drag detection so that touch scrolling inside a menu
## works. A quick tap emits pressed; a drag suppresses activation.

var _press_start_pos: Vector2 = Vector2.ZERO
var _is_dragging: bool = false
const DRAG_THRESHOLD_DP: float = 10.0

func _ready():
	# Handle mouse activation ourselves so we can distinguish taps from scroll drags.
	button_mask = 0

func _gui_input(event: InputEvent):
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_press_start_pos = event.position
				_is_dragging = false
				grab_focus()
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
	
	# Keyboard / gamepad activation is handled by the native Button's focus logic.
	# We intentionally do nothing here so the built-in ui_accept handling stays active.
