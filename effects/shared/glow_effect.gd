class_name GlowEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

const GLOW_MARGIN_RATIO = 0.08

func _ready():
	super._ready()
	effect_name = "Glow"
	effect_id = "glow"
	z_index = -2

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/glow.gdshader")

func _apply_settings() -> void:
	pass  # Offsets: compute_pipeline(). Shader params: _run_pipeline().

func compute_pipeline(cache: Dictionary) -> void:
	_update_glow_offsets()

func _update_glow_offsets():
	if not media_container:
		return

	var glow_radius_ratio = _settings.get("glow_radius", 0.06)
	var margin_ratio = GLOW_MARGIN_RATIO + glow_radius_ratio

	var card_size = media_container.size
	var margin_x = margin_ratio * card_size.x
	var margin_y = margin_ratio * card_size.y

	# Absolute positioning: glow anchored at (0,0) sized to the art + margins.
	# This works on both the base stack (parent = art panel) and the focus stack
	# (parent = full card) because the art is always at the top-left of its parent.
	anchor_left = 0.0
	anchor_top = 0.0
	anchor_right = 0.0
	anchor_bottom = 0.0

	offset_left = -margin_x
	offset_top = -margin_y
	offset_right = card_size.x + margin_x
	offset_bottom = card_size.y + margin_y

func _update_shader_params() -> void:
	if not media_container:
		return
	
	var glow_radius = _settings.get("glow_radius", 0.1)
	var glow_intensity = _settings.get("glow_intensity", 1.5)
	var blur_amount = _settings.get("blur_amount", 12.0)
	var threshold = _settings.get("threshold", 0.1)
	var glow_spread = _settings.get("glow_spread", 0.05)
	
	var card_size = media_container.size
	var card_width = card_size.x
	
	var radius_pixels = glow_radius * card_width
	
	# Margin from card_size (like drop shadow)
	var margin_ratio = GLOW_MARGIN_RATIO + glow_radius
	var margin_pixels = Vector2(
		margin_ratio * card_size.x,
		margin_ratio * card_size.y
	)
	
	# Resolution-dependent quality: reduce blur samples at higher resolutions
	var screen_height = DisplayManager.get_viewport_size().y
	var quality_scale = clamp(1080.0 / screen_height, 0.4, 1.0)
	
	_set_shader_param("card_size", card_size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("glow_radius", radius_pixels)
	_set_shader_param("glow_intensity", glow_intensity)
	_set_shader_param("blur_amount", blur_amount)
	_set_shader_param("threshold", threshold)
	_set_shader_param("glow_spread", glow_spread)
	_set_shader_param("glow_margin", margin_pixels)
	_set_shader_param("game_texture", media_container.texture)
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)
	_set_shader_param("quality_scale", quality_scale)

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
