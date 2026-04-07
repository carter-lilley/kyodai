class_name DropShadowEffect
extends EffectBase

# Base margin ratio for shadow (0.05 = 5% of card width)
const SHADOW_MARGIN_RATIO = 0.05

func _ready():
	super._ready()
	effect_name = "Drop Shadow"
	effect_id = "drop_shadow"
	z_index = -1
	
	# Connect to parent resized signal to update geometry when card size changes
	# This ensures shadow size is calculated AFTER the card has its final size
	if get_parent():
		get_parent().resized.connect(_on_parent_resized)

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/drop_shadow.gdshader")

func _apply_settings() -> void:
	_update_shadow_offsets()
	_update_shader_params()

func _on_zoom_changed(_new_zoom: float) -> void:
	_update_shadow_offsets()
	_update_shader_params()

func _on_orientation_changed(_new_orientation: int) -> void:
	_update_shadow_offsets()
	_update_shader_params()

# Override to update geometry when container size changes
func _on_size_changed(_new_size: Vector2) -> void:
	_update_shadow_offsets()
	_update_shader_params()

# Called when parent card resizes - ensures geometry is calculated after layout settles
func _on_parent_resized() -> void:
	_update_shadow_offsets()
	_update_shader_params()

func _update_shadow_offsets():
	# Use parent's ACTUAL size (not container_state) to ensure we're synced with layout
	var parent = get_parent()
	if not parent:
		return
	
	var card_size = parent.size
	var card_width = card_size.x
	var card_height = card_size.y
	var shadow_offset_y_ratio = _settings.get("shadow_offset_y", 0.05)
	var shadow_softness_ratio = _settings.get("shadow_softness", 0.04)
	
	var margin_ratio = SHADOW_MARGIN_RATIO + abs(shadow_offset_y_ratio) + shadow_softness_ratio
	var margin_pixels = margin_ratio * card_width
	
	var shadow_width = card_width + margin_pixels * 2
	var shadow_height = card_height + margin_pixels * 2
	
	custom_minimum_size = Vector2(shadow_width, shadow_height)
	size = custom_minimum_size
	
	# With centered anchors, offset is relative to parent center
	# Offset by half the size difference to center the shadow on the card
	position = Vector2(-margin_pixels, -margin_pixels)

func _update_shader_params() -> void:
	if not _container_state:
		return
	
	var shadow_color = _settings.get("shadow_color", Color(0, 0, 0, 0.5))
	var shadow_offset_x = _settings.get("shadow_offset_x", 0.0)
	var shadow_offset_y = _settings.get("shadow_offset_y", 0.05)
	var shadow_softness = _settings.get("shadow_softness", 0.04)
	var shadow_spread = _settings.get("shadow_spread", 0.0)
	var shadow_expand = _settings.get("shadow_expand", 0.02)
	
	var card_size = _container_state.container_size
	var card_width = card_size.x
	
	# Convert ratios to pixels for shader
	var shadow_offset = Vector2(shadow_offset_x * card_width, shadow_offset_y * card_width)
	var softness_pixels = shadow_softness * card_width
	var margin_pixels = (SHADOW_MARGIN_RATIO + abs(shadow_offset_y) + shadow_softness) * card_width
	
	_set_shader_param("card_size", card_size)
	_set_shader_param("corner_radius_ratio", _container_state.corner_radius_ratio)
	_set_shader_param("shadow_color", shadow_color)
	_set_shader_param("shadow_offset", shadow_offset)
	_set_shader_param("shadow_softness", softness_pixels)
	_set_shader_param("shadow_spread", shadow_spread)
	_set_shader_param("shadow_expand", shadow_expand)
	_set_shader_param("shadow_margin", margin_pixels)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var color_var = SettingsVar.new(Type.COLOR, Color(0, 0, 0, 0.5), State.ENABLED, "Shadow Color")
	color_var.property_name = "shadow_color"
	schema.append(color_var)
	
	var offset_x_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Shadow Offset X", "Ratio of card width", -0.1, 0.1, 0.001)
	offset_x_var.property_name = "shadow_offset_x"
	schema.append(offset_x_var)
	
	var offset_y_var = SettingsVar.new(Type.FLOAT, 0.05, State.ENABLED, "Shadow Offset Y", "Ratio of card width", -0.1, 0.1, 0.001)
	offset_y_var.property_name = "shadow_offset_y"
	schema.append(offset_y_var)
	
	var softness_var = SettingsVar.new(Type.FLOAT, 0.04, State.ENABLED, "Shadow Softness", "Ratio of card width", 0.0, 0.15, 0.001)
	softness_var.property_name = "shadow_softness"
	schema.append(softness_var)
	
	var spread_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Shadow Spread", "", 0.0, 1.0, 0.01)
	spread_var.property_name = "shadow_spread"
	schema.append(spread_var)
	
	var expand_var = SettingsVar.new(Type.FLOAT, 0.02, State.ENABLED, "Shadow Expand", "Ratio of card size", 0.0, 0.2, 0.001)
	expand_var.property_name = "shadow_expand"
	schema.append(expand_var)
	
	return schema
