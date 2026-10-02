class_name GlowEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["hero", "base_card", "focus_card"]

## Glow derives its look from the source image and user brightness settings;
## auto-inverting lightness on dark/light swaps reads as the effect breaking,
## so its settings never convert across mode swaps.
static func is_theme_adaptive() -> bool:
	return false

const GLOW_MARGIN_RATIO = 0.08
const MAX_QUALITY_SCALE = 0.6

var _draw_rect: Rect2 = Rect2()

func _init():
	super._init()
	effect_id = "glow"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/glow.gdshader")

func compute_pipeline() -> void:
	_update_glow_offsets()

func _update_glow_offsets():
	if not media_container:
		return

	var glow_radius_ratio = _settings.get("glow_radius", 0.1)
	var margin_ratio = GLOW_MARGIN_RATIO + glow_radius_ratio

	var card_size = media_container.size
	var margin_x = margin_ratio * card_size.x
	var margin_y = margin_ratio * card_size.y

	_draw_rect = Rect2(Vector2(-margin_x, -margin_y), card_size + Vector2(margin_x * 2.0, margin_y * 2.0))

func _compute_draw_rect() -> Rect2:
	if not media_container:
		return _draw_rect

	var glow_radius_ratio = _settings.get("glow_radius", 0.1)
	var margin_ratio = GLOW_MARGIN_RATIO + glow_radius_ratio

	var card_size = media_container.size
	var margin_x = margin_ratio * card_size.x
	var margin_y = margin_ratio * card_size.y

	return Rect2(Vector2(-margin_x, -margin_y), card_size + Vector2(margin_x * 2.0, margin_y * 2.0))

func get_draw_rect() -> Rect2:
	return _compute_draw_rect()

func _apply_settings() -> void:
	_update_glow_offsets()

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

	var margin_ratio = GLOW_MARGIN_RATIO + glow_radius
	var margin_pixels = Vector2(
		margin_ratio * card_size.x,
		margin_ratio * card_size.y
	)

	var screen_height = SystemManager.display.get_viewport_size().y
	# Cap kernel quality (radius = int(12 * quality_scale) in-shader) so the
	# worst case is 15x15=225 taps/px instead of 25x25=625; widen the step
	# inversely so the blur footprint stays the same.
	var quality_scale = clamp(1080.0 / screen_height, 0.4, MAX_QUALITY_SCALE)

	_set_shader_param("card_size", card_size)
	_set_shader_param("corner_radius_ratio", media_container.corner_radius_ratio)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("glow_radius", radius_pixels)
	_set_shader_param("glow_intensity", glow_intensity)
	_set_shader_param("blur_amount", blur_amount / quality_scale)
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
