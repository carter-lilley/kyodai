@tool
class_name SearchBar
extends M3TextField


func _init():
	super._init()
	leading_icon = "magnify"
	placeholder_text = "Search games..."
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	custom_minimum_size.x = M3Units.dp(400)


func grab_focus_on_input():
	grab_focus()


func release_focus_from_input():
	release_focus()


func get_line_edit() -> LineEdit:
	return self
