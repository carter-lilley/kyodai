class_name M3MenuButton
extends Button

## Material 3 Menu Button
## Extends native Button with SubViewport touch compatibility.
## Inside a SubViewport, Button ignores clicks because is_hovered() is false
## (push_input() doesn't update the viewport's internal cursor position).

func _gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var vp = get_viewport()
		if vp is SubViewport:
			accept_event()
			if event.pressed:
				grab_focus()
				button_down.emit()
			else:
				button_up.emit()
				if not disabled:
					pressed.emit()
