@icon("res://Icons/ArrayMesh.svg")
#display_manager.gd
extends Manager

signal viewport_size_changed(new_size: Vector2)

@onready var settings_man = $"../SettingsManager"

var _viewport_size: Vector2 = Vector2.ZERO

func _ready() -> void:
	settings_man.connect("setting_changed", _on_setting_changed)
	
	# Connect to viewport size changes
	var viewport = get_viewport()
	if viewport:
		viewport.size_changed.connect(_on_viewport_size_changed)
		_viewport_size = viewport.size
		print("[DisplayManager] Initial viewport size: ", _viewport_size)

func _on_viewport_size_changed() -> void:
	var viewport = get_viewport()
	if viewport:
		_viewport_size = viewport.size
		print("[DisplayManager] Viewport size changed: ", _viewport_size)
		viewport_size_changed.emit(_viewport_size)

func get_viewport_size() -> Vector2:
	if _viewport_size == Vector2.ZERO:
		var viewport = get_viewport()
		if viewport:
			_viewport_size = viewport.size
	return _viewport_size

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
