extends Node

# Diagnostic script to test controller detection and input mapping
# Run this scene to see what controller info Godot exposes

func _ready():
	print("=== Controller Detection Test ===")
	print("")
	
	# Get all connected joypads
	var connected_joypads = Input.get_connected_joypads()
	print("Connected joypads: ", connected_joypads)
	print("")
	
	for device_id in connected_joypads:
		print("--- Device ", device_id, " ---")
		print("Name: ", Input.get_joy_name(device_id))
		print("GUID: ", Input.get_joy_guid(device_id))
		
		# This is the key method - let's see what it returns
		var joy_info = Input.get_joy_info(device_id)
		print("Joy Info (Dictionary): ", joy_info)
		
		# Print all keys in the dictionary
		if joy_info.size() > 0:
			print("  Available keys:")
			for key in joy_info.keys():
				print("    ", key, " = ", joy_info[key])
		else:
			print("  (empty dictionary)")
		
		print("")
	
	# Also listen for connection changes
	Input.joy_connection_changed.connect(_on_joy_connection_changed)

func _on_joy_connection_changed(device_id: int, connected: bool):
	print("")
	print("=== Connection Changed ===")
	print("Device ", device_id, " connected: ", connected)
	
	if connected:
		print("Name: ", Input.get_joy_name(device_id))
		print("GUID: ", Input.get_joy_guid(device_id))
		var joy_info = Input.get_joy_info(device_id)
		print("Joy Info: ", joy_info)
		for key in joy_info.keys():
			print("  ", key, " = ", joy_info[key])
	print("")

func _input(event):
	# Print button presses to verify controller is working
	if event is InputEventJoypadButton and event.pressed:
		print("Button pressed on device ", event.device, ": button index ", event.button_index)
		# Map button index to SDL name
		var sdl_name = _map_button_to_sdl(event.button_index)
		print("  SDL mapping: ", sdl_name)
	elif event is InputEventJoypadMotion:
		# Only print significant axis movements to avoid spam
		if abs(event.axis_value) > 0.5:
			print("Axis ", event.axis, " on device ", event.device, ": ", event.axis_value)
			var sdl_axis = _map_axis_to_sdl(event.axis, event.axis_value)
			print("  SDL mapping: ", sdl_axis)

## Map Godot button index to SDL button name
func _map_button_to_sdl(button_index: int) -> String:
	var button_names = {
		0: "FaceSouth (A/X)",
		1: "FaceEast (B/O)", 
		2: "FaceWest (X/Square)",
		3: "FaceNorth (Y/Triangle)",
		4: "LeftShoulder (L1/LB)",
		5: "RightShoulder (R1/RB)",
		6: "LeftTrigger (L2/LT)",
		7: "RightTrigger (R2/RT)",
		8: "LeftStick (L3)",
		9: "RightStick (R3)",
		10: "Back (Select/Minus)",
		11: "Start (Plus)",
		12: "DPadUp",
		13: "DPadDown", 
		14: "DPadLeft",
		15: "DPadRight",
		16: "Guide (Home)"
	}
	return button_names.get(button_index, "Unknown(" + str(button_index) + ")")

## Map Godot axis to SDL axis name
func _map_axis_to_sdl(axis: int, value: float) -> String:
	var axis_names = {
		0: "LeftX",
		1: "LeftY", 
		2: "RightX",
		3: "RightY",
		4: "LeftTrigger",
		5: "RightTrigger"
	}
	var axis_name = axis_names.get(axis, "Unknown(" + str(axis) + ")")
	var direction = "+" if value > 0 else "-"
	return direction + axis_name + " (value: " + str(value) + ")"
