class_name WiiUBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "WiiU Orbit"
	effect_id = "wiiu"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/library_background_wiiu.gdshader")
	
	# Load the icon atlas texture (x2 resolution)
	var icon_atlas = load("res://assets/ui/background/wiiu_atlas_x2.png")
	if icon_atlas:
		_set_shader_param("icon_atlas", icon_atlas)

func _apply_settings() -> void:
	_set_shader_param("time_scale", _settings.get("time_scale", 0.5))
	_set_shader_param("orbit_radius", _settings.get("orbit_radius", 2.5))
	_set_shader_param("icon_scale", _settings.get("icon_scale", 0.4))
	_set_shader_param("orbit_speed", _settings.get("orbit_speed", 0.15))
	_set_shader_param("num_icons", _settings.get("num_icons", 15))
	_set_shader_param("depth_intensity", _settings.get("depth_intensity", 0.6))
	_set_shader_param("fog_density", _settings.get("fog_density", 0.3))
	_set_shader_param("background_color", _settings.get("background_color", Color(0.95, 0.95, 0.95, 1.0)))
	
	# Light direction as normalized vec3
	var light_dir = _settings.get("light_direction", Vector3(0.5, 0.5, 1.0))
	_set_shader_param("light_direction", light_dir.normalized())

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var time_var = SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Time Scale", "Animation speed", 0.0, 2.0, 0.1)
	time_var.property_name = "time_scale"
	schema.append(time_var)
	
	var orbit_radius_var = SettingsVar.new(Type.FLOAT, 2.5, State.ENABLED, "Orbit Radius", "Size of the orbit sphere", 1.0, 5.0, 0.1)
	orbit_radius_var.property_name = "orbit_radius"
	schema.append(orbit_radius_var)
	
	var icon_scale_var = SettingsVar.new(Type.FLOAT, 0.4, State.ENABLED, "Icon Scale", "Size of controller icons", 0.1, 1.0, 0.05)
	icon_scale_var.property_name = "icon_scale"
	schema.append(icon_scale_var)
	
	var orbit_speed_var = SettingsVar.new(Type.FLOAT, 0.15, State.ENABLED, "Orbit Speed", "How fast icons orbit", 0.05, 1.0, 0.05)
	orbit_speed_var.property_name = "orbit_speed"
	schema.append(orbit_speed_var)
	
	var num_icons_var = SettingsVar.new(Type.INT, 15, State.ENABLED, "Icon Count", "Number of icons to display", 5, 30, 1)
	num_icons_var.property_name = "num_icons"
	schema.append(num_icons_var)
	
	var depth_var = SettingsVar.new(Type.FLOAT, 0.6, State.ENABLED, "Depth Intensity", "3D depth effect strength", 0.0, 1.0, 0.05)
	depth_var.property_name = "depth_intensity"
	schema.append(depth_var)
	
	var fog_var = SettingsVar.new(Type.FLOAT, 0.3, State.ENABLED, "Fog Density", "Distance fog amount", 0.0, 2.0, 0.05)
	fog_var.property_name = "fog_density"
	schema.append(fog_var)
	
	var bg_color_var = SettingsVar.new(Type.COLOR, Color(0.95, 0.95, 0.95, 1.0), State.ENABLED, "Background Color", "Background color")
	bg_color_var.property_name = "background_color"
	schema.append(bg_color_var)
	
	return schema
