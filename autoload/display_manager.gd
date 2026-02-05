@icon("res://Icons/ArrayMesh.svg")
#display_manager.gd
extends Manager

@onready var settings_man = $"../SettingsManager"

func _ready() -> void:
	settings_man.connect("setting_changed", _on_setting_changed)

func _on_setting_changed(value: Variant, setting: SettingsVar):
	match setting.property_name:
		"windowed":
			windowed_toggle(value)
		"resolution":
			set_resolution(value)

func set_resolution(choice : Vector2i):
	#var chosen_res : Vector2i = settings_man.settings.resolutions[choice]
	DisplayServer.window_set_size(choice)
	DisplayServer.window_set_position((DisplayServer.screen_get_position()+DisplayServer.screen_get_size()/2)-choice/2)

func windowed_toggle(value : bool):
	if value:
		print("[DisplayManager]: Windowed mode.")
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		set_resolution(settings_man.get_setting("resolution").value)
		settings_man.enable_setting("resolution")
	else:
		print("[DisplayManager]: Fullscreen mode.")
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		settings_man.disable_setting("resolution")
