class_name GlowEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero"]

# Base margin ratio for glow (0.08 = 8% of card width)
const GLOW_MARGIN_RATIO = 0.08

func _ready():
	super._ready()
	effect_name = "Glow"
	effect_id = "glow"
	z_index = -2  # Render behind everything (even drop shadow)

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/glow.gdshader")

func _apply_settings() -> void:
	_update_glow_offsets()
	_update_shader_params()

func _on_zoom_changed(_new_zoom: float) -> void:
	_update_glow_offsets()
	_update_shader_params()

# Override to update geometry when container size changes
func _on_size_changed(_new_size: Vector2) -> void:
	_update_glow_offsets()
	_update_shader_params()

func _update_glow_offsets():
	# Use anchors so Godot handles sizing automatically — no manual size/position needed
	var glow_radius_ratio = _settings.get("glow_radius", 0.06)
	var margin_ratio = GLOW_MARGIN_RATIO + glow_radius_ratio
	
	anchor_left = -margin_ratio
	anchor_top = -margin_ratio
	anchor_right = 1.0 + margin_ratio
	anchor_bottom = 1.0 + margin_ratio
	
	# Clear offsets so size is purely anchor-driven
	offset_left = 0.0
	offset_top = 0.0
	offset_right = 0.0
	offset_bottom = 0.0

func set_game_texture(texture: Texture2D) -> void:
	if _container_state:
		_container_state.game_texture = texture
		_update_shader_params()

func _update_shader_params() -> void:
	if not _container_state:
		return
	
	var glow_radius = _settings.get("glow_radius", 0.1)
	var glow_intensity = _settings.get("glow_intensity", 1.5)
	var blur_amount = _settings.get("blur_amount", 12.0)
	var threshold = _settings.get("threshold", 0.1)
	var glow_spread = _settings.get("glow_spread", 0.05)
	
	var card_size = _container_state.container_size
	var card_width = card_size.x
	
	# Convert ratios to pixels
	var radius_pixels = glow_radius * card_width
	var margin_pixels = (GLOW_MARGIN_RATIO + glow_radius) * card_width
	
	_set_shader_param("card_size", card_size)
	_set_shader_param("corner_radius_ratio", _container_state.corner_radius_ratio)
	_set_shader_param("glow_radius", radius_pixels)
	_set_shader_param("glow_intensity", glow_intensity)
	_set_shader_param("blur_amount", blur_amount)
	_set_shader_param("threshold", threshold)
	_set_shader_param("glow_spread", glow_spread)
	_set_shader_param("glow_margin", margin_pixels)
	_set_shader_param("game_texture", _container_state.game_texture)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var radius_var = SettingsVar.new(Type.FLOAT, 0.1, State.ENABLED, "Glow Radius", "Ratio of card width", 0.0, 0.3, 0.001)
	radius_var.property_name = "glow_radius"
	schema.append(radius_var)
	
	var intensity_var = SettingsVar.new(Type.FLOAT, 1.5, State.ENABLED, "Glow Intensity", "Overall brightness multiplier", 0.0, 5.0, 0.1)
	intensity_var.property_name = "glow_intensity"
	schema.append(intensity_var)
	
	var blur_var = SettingsVar.new(Type.FLOAT, 12.0, State.ENABLED, "Blur Amount", "How much to blur the image (0-30)", 0.0, 30.0, 0.5)
	blur_var.property_name = "blur_amount"
	schema.append(blur_var)
	
	var threshold_var = SettingsVar.new(Type.FLOAT, 0.1, State.ENABLED, "Threshold", "Minimum brightness to include in glow (0-1)", 0.0, 1.0, 0.01)
	threshold_var.property_name = "threshold"
	schema.append(threshold_var)
	
	var spread_var = SettingsVar.new(Type.FLOAT, 0.05, State.ENABLED, "Glow Spread", "How much to expand the glow outward (ratio of card width)", 0.0, 0.5, 0.01)
	spread_var.property_name = "glow_spread"
	schema.append(spread_var)
	
	return schema
