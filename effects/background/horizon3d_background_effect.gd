class_name Horizon3DBackgroundEffect
extends BackgroundEffect

func _ready():
	super._ready()
	effect_name = "Horizon3D"
	effect_id = "horizon3d"

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_horizon3d.gdshader")

func _apply_settings() -> void:
	_set_shader_param("time_scale", _settings.get("time_scale", 0.1))
	_set_shader_param("rotation_speed", _settings.get("rotation_speed", 0.35))
	_set_shader_param("axis_tilt", _settings.get("axis_tilt", 0.0))
	_set_shader_param("diagonal_ratio", _settings.get("diagonal_ratio", 0.4))
	_set_shader_param("curvature", _settings.get("curvature", 0.25))
	_set_shader_param("rows_visible", _settings.get("rows_visible", 4.0))
	_set_shader_param("tile_scale", _settings.get("tile_scale", 0.8))
	_set_shader_param("corner_radius", _settings.get("corner_radius", 0.18))
	_set_shader_param("tile_opacity", _settings.get("tile_opacity", 0.45))
	_set_shader_param("border_opacity", _settings.get("border_opacity", 0.25))
	_set_shader_param("parallax_factor", _settings.get("parallax_factor", 0.15))
	_set_shader_param("back_layer_dim", _settings.get("back_layer_dim", 0.1))
	_set_shader_param("tile_color_top", _settings.get("tile_color_top", Color(1.0, 1.0, 1.0, 1.0)))
	_set_shader_param("tile_color_bottom", _settings.get("tile_color_bottom", Color(0.88, 0.88, 0.93, 1.0)))
	_set_shader_param("bg_color_top", _settings.get("bg_color_top", Color(0.93, 0.93, 0.96, 1.0)))
	_set_shader_param("bg_color_bottom", _settings.get("bg_color_bottom", Color(0.8, 0.8, 0.87, 1.0)))

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var time_var = SettingsVar.new(Type.FLOAT, 0.1, State.ENABLED, "Time Scale", "Animation speed multiplier", 0.0, 2.0, 0.1)
	time_var.property_name = "time_scale"
	schema.append(time_var)

	var speed_var = SettingsVar.new(Type.FLOAT, 0.35, State.ENABLED, "Rotation Speed", "How fast the sphere rotates", 0.0, 2.0, 0.05)
	speed_var.property_name = "rotation_speed"
	schema.append(speed_var)

	var tilt_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Axis Tilt", "Tilt of the sphere rotation axis (radians)", 0.0, 1.4, 0.05)
	tilt_var.property_name = "axis_tilt"
	schema.append(tilt_var)

	var diagonal_var = SettingsVar.new(Type.FLOAT, 0.4, State.ENABLED, "Diagonal Ratio", "How much vertical drift is added to the rotation", 0.0, 1.0, 0.05)
	diagonal_var.property_name = "diagonal_ratio"
	schema.append(diagonal_var)

	var curvature_var = SettingsVar.new(Type.FLOAT, 0.25, State.ENABLED, "Curvature", "How much of the sphere is visible (field of view)", 0.2, 1.2, 0.05)
	curvature_var.property_name = "curvature"
	schema.append(curvature_var)

	var rows_var = SettingsVar.new(Type.FLOAT, 4.0, State.ENABLED, "Rows Visible", "Number of tile rows on screen", 1.5, 10.0, 0.5)
	rows_var.property_name = "rows_visible"
	schema.append(rows_var)

	var scale_var = SettingsVar.new(Type.FLOAT, 0.8, State.ENABLED, "Tile Overlap", "Tile size relative to grid spacing (over 1.0 overlaps)", 0.5, 1.5, 0.05)
	scale_var.property_name = "tile_scale"
	schema.append(scale_var)

	var radius_var = SettingsVar.new(Type.FLOAT, 0.18, State.ENABLED, "Corner Radius", "Roundness of the tile corners", 0.0, 0.5, 0.01)
	radius_var.property_name = "corner_radius"
	schema.append(radius_var)

	var opacity_var = SettingsVar.new(Type.FLOAT, 0.45, State.ENABLED, "Tile Opacity", "Transparency of the tile fill", 0.0, 1.0, 0.05)
	opacity_var.property_name = "tile_opacity"
	schema.append(opacity_var)

	var border_var = SettingsVar.new(Type.FLOAT, 0.25, State.ENABLED, "Border Opacity", "Visibility of the tile borders", 0.0, 1.0, 0.05)
	border_var.property_name = "border_opacity"
	schema.append(border_var)

	var parallax_var = SettingsVar.new(Type.FLOAT, 0.15, State.ENABLED, "Parallax Factor", "Speed ratio of the back layer", 0.1, 1.0, 0.05)
	parallax_var.property_name = "parallax_factor"
	schema.append(parallax_var)

	var dim_var = SettingsVar.new(Type.FLOAT, 0.1, State.ENABLED, "Back Layer Dimming", "How dim the back layer is", 0.0, 1.0, 0.05)
	dim_var.property_name = "back_layer_dim"
	schema.append(dim_var)

	var tile_top_var = SettingsVar.new(Type.COLOR, Color(1.0, 1.0, 1.0, 1.0), State.ENABLED, "Tile Color Top", "Tile gradient top color")
	tile_top_var.property_name = "tile_color_top"
	schema.append(tile_top_var)

	var tile_bottom_var = SettingsVar.new(Type.COLOR, Color(0.88, 0.88, 0.93, 1.0), State.ENABLED, "Tile Color Bottom", "Tile gradient bottom color")
	tile_bottom_var.property_name = "tile_color_bottom"
	schema.append(tile_bottom_var)

	var bg_top_var = SettingsVar.new(Type.COLOR, Color(0.93, 0.93, 0.96, 1.0), State.ENABLED, "Background Top", "Background gradient top color")
	bg_top_var.property_name = "bg_color_top"
	schema.append(bg_top_var)

	var bg_bottom_var = SettingsVar.new(Type.COLOR, Color(0.8, 0.8, 0.87, 1.0), State.ENABLED, "Background Bottom", "Background gradient bottom color")
	bg_bottom_var.property_name = "bg_color_bottom"
	schema.append(bg_bottom_var)

	return schema
