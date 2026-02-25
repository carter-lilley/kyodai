class_name DropShadowEffect
extends CardEffect

# Extra margin for shadow to extend beyond card bounds
const SHADOW_MARGIN = 50.0

func _ready():
	super._ready()
	effect_name = "Drop Shadow"
	effect_id = "drop_shadow"
	# Render shadow behind the card and all card content
	z_index = -1

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/card/drop_shadow.gdshader")

func _apply_settings() -> void:
	_update_shadow_offsets()
	_update_shader_params()

func _update_shadow_offsets():
	if not _card_state:
		return
	
	# Use anchors to fill the card like border effect does
	anchor_right = 1.0
	anchor_bottom = 1.0
	
	# Use negative offsets to extend beyond card bounds
	# This makes the shadow node larger than the card
	var shadow_offset_y = _settings.get("shadow_offset_y", 10.0)
	var shadow_softness = _settings.get("shadow_softness", 8.0)
	var margin = SHADOW_MARGIN + abs(shadow_offset_y) + shadow_softness
	
	offset_left = -margin
	offset_top = -margin
	offset_right = margin
	offset_bottom = margin

func _update_shader_params() -> void:
	if not _card_state:
		return
	
	var shadow_color = _settings.get("shadow_color", Color(0, 0, 0, 0.5))
	var shadow_offset_x = _settings.get("shadow_offset_x", 0.0)
	var shadow_offset_y = _settings.get("shadow_offset_y", 10.0)
	var shadow_softness = _settings.get("shadow_softness", 8.0)
	var shadow_spread = _settings.get("shadow_spread", 0.0)
	var shadow_expand = _settings.get("shadow_expand", 0.02)
	
	var card_size = _card_state.card_size
	var shadow_offset = Vector2(shadow_offset_x, shadow_offset_y)
	var margin = SHADOW_MARGIN + abs(shadow_offset_y) + shadow_softness
	
	_set_shader_param("card_size", card_size)
	_set_shader_param("corner_radius_ratio", _card_state.corner_radius_ratio)
	_set_shader_param("shadow_color", shadow_color)
	_set_shader_param("shadow_offset", shadow_offset)
	_set_shader_param("shadow_softness", shadow_softness)
	_set_shader_param("shadow_spread", shadow_spread)
	_set_shader_param("shadow_expand", shadow_expand)
	_set_shader_param("shadow_margin", margin)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	var color_var = SettingsVar.new(Type.COLOR, Color(0, 0, 0, 0.5), State.ENABLED, "Shadow Color")
	color_var.property_name = "shadow_color"
	schema.append(color_var)
	
	var offset_x_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Shadow Offset X", "", -50.0, 50.0, 1.0)
	offset_x_var.property_name = "shadow_offset_x"
	schema.append(offset_x_var)
	
	var offset_y_var = SettingsVar.new(Type.FLOAT, 10.0, State.ENABLED, "Shadow Offset Y", "", -50.0, 50.0, 1.0)
	offset_y_var.property_name = "shadow_offset_y"
	schema.append(offset_y_var)
	
	var softness_var = SettingsVar.new(Type.FLOAT, 8.0, State.ENABLED, "Shadow Softness", "", 0.0, 64.0, 1.0)
	softness_var.property_name = "shadow_softness"
	schema.append(softness_var)
	
	var spread_var = SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Shadow Spread", "", 0.0, 1.0, 0.01)
	spread_var.property_name = "shadow_spread"
	schema.append(spread_var)
	
	var expand_var = SettingsVar.new(Type.FLOAT, 0.02, State.ENABLED, "Shadow Expand", "Ratio of card size", 0.0, 0.5, 0.001)
	expand_var.property_name = "shadow_expand"
	schema.append(expand_var)
	
	return schema
