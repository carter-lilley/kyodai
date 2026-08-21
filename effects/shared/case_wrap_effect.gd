class_name CaseWrapEffect
extends EffectBase

static func get_allowed_contexts() -> Array[String]:
	return ["base_card", "focus_card"]

static func is_material_shareable() -> bool:
	return true

var _gradient_texture: ImageTexture = null
var _gradient_hash_cache: String = ""
var _spine_gradient_texture: ImageTexture = null
var _spine_gradient_hash_cache: String = ""

func _init():
	super._init()
	effect_id = "case_wrap"

func _setup_shader() -> void:
	var mat = _material as ShaderMaterial
	mat.shader = preload("res://shaders/card/case_wrap.gdshader")

func _apply_settings() -> void:
	if not media_container:
		return
	var wrap_type = int(_settings.get("wrap_type", 0))
	media_container.wrap_inset_top_ratio = 0.0
	media_container.wrap_inset_left_ratio = 0.0
	match wrap_type:
		0:
			media_container.wrap_inset_top_ratio = _settings.get("banner_height_ratio", 0.10)
		1:
			media_container.wrap_inset_left_ratio = _settings.get("spine_width_ratio", 0.12)
		2:
			media_container.wrap_inset_top_ratio = _settings.get("swoop_edge_ratio", 0.03)
		3:
			media_container.wrap_inset_top_ratio = _settings.get("wii_header_ratio", 0.08)

func free_rid() -> void:
	if media_container:
		media_container.wrap_inset_top_ratio = 0.0
		media_container.wrap_inset_left_ratio = 0.0
	super.free_rid()

func _update_shader_params() -> void:
	if not media_container:
		return

	_ensure_shared_material()

	_set_shader_param("card_size", media_container.size)
	_set_shader_param("corner_radius_pixels", media_container.get_corner_radius_pixels())
	_set_shader_param("display_mode", 1 if media_container.edge_aa_enabled else 0)

	_set_shader_param("template_id", _settings.get("wrap_type", 0))
	_set_shader_param("banner_height_ratio", _settings.get("banner_height_ratio", 0.10))
	_set_shader_param("line_color", _settings.get("line_color", Color(0.75, 0.05, 0.10)))
	_set_shader_param("line_thickness_pixels", _settings.get("line_thickness_pixels", 2.0))

	var gradient = _settings.get("banner_gradient")
	if not gradient is Gradient:
		gradient = _default_banner_gradient()
	var key := gradient_content_hash(gradient)
	if key != _gradient_hash_cache:
		_gradient_hash_cache = key
		_gradient_texture = get_shared_gradient_texture(gradient)
	_set_shader_param("banner_gradient", _gradient_texture)

	_set_shader_param("spine_width_ratio", _settings.get("spine_width_ratio", 0.12))
	var spine_gradient = _settings.get("spine_gradient")
	if not spine_gradient is Gradient:
		spine_gradient = _default_spine_gradient()
	var spine_key := gradient_content_hash(spine_gradient)
	if spine_key != _spine_gradient_hash_cache:
		_spine_gradient_hash_cache = spine_key
		_spine_gradient_texture = get_shared_gradient_texture(spine_gradient)
	_set_shader_param("spine_gradient", _spine_gradient_texture)

	_set_shader_param("swoop_color", _settings.get("swoop_color", Color("#12a3c8")))
	_set_shader_param("swoop_edge_ratio", _settings.get("swoop_edge_ratio", 0.03))
	_set_shader_param("swoop_center_ratio", _settings.get("swoop_center_ratio", 0.10))
	_set_shader_param("swoop_exponent", _settings.get("swoop_exponent", 1.5))
	_set_shader_param("swoop_stroke_color", _settings.get("swoop_stroke_color", Color("#faf022")))
	_set_shader_param("swoop_stroke_thickness", _settings.get("swoop_stroke_thickness", 2.5))
	_set_shader_param("swoop_under_enabled", _settings.get("swoop_under_enabled", true))
	_set_shader_param("swoop_under_color", _settings.get("swoop_under_color", Color("#a39f9f")))

	_set_shader_param("wii_header_color", _settings.get("wii_header_color", Color("#f7f7f7")))
	_set_shader_param("wii_header_ratio", _settings.get("wii_header_ratio", 0.08))
	_set_shader_param("wii_cutout_start_ratio", _settings.get("wii_cutout_start_ratio", 0.55))
	_set_shader_param("wii_cutout_depth_ratio", _settings.get("wii_cutout_depth_ratio", 0.10))
	_set_shader_param("wii_stroke_enabled", _settings.get("wii_stroke_enabled", true))
	_set_shader_param("wii_stroke_color", _settings.get("wii_stroke_color", Color("#8a8f93")))
	_set_shader_param("wii_stroke_thickness", _settings.get("wii_stroke_thickness", 1.5))

static func _default_banner_gradient() -> Gradient:
	var gradient = Gradient.new()
	gradient.offsets = [0.0, 1.0]
	gradient.colors = [Color(0.03, 0.03, 0.04), Color(0.22, 0.22, 0.24)]
	return gradient

static func _default_spine_gradient() -> Gradient:
	var gradient = Gradient.new()
	gradient.offsets = [0.0, 0.5, 1.0]
	gradient.colors = [Color("#e9e924"), Color("#464775"), Color("#ca1c1e")]
	return gradient

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var wrap_type_var = SettingsVar.new(Type.ENUM, 0, State.ENABLED, "Wrap Type", "", 0, 0, 0, ["PS3 Banner", "3DO Spine", "Wii U Swoop", "Wii Corner"])
	wrap_type_var.property_name = "wrap_type"
	schema.append(wrap_type_var)

	var height_var = SettingsVar.new(Type.FLOAT, 0.10, State.ENABLED, "Banner Height", "", 0.02, 0.4, 0.01)
	height_var.property_name = "banner_height_ratio"
	height_var.metadata["visible_if"] = {"property": "wrap_type", "values": [0]}
	schema.append(height_var)

	var gradient_var = SettingsVar.new(Type.GRADIENT, _default_banner_gradient(), State.ENABLED, "Banner Gradient")
	gradient_var.property_name = "banner_gradient"
	gradient_var.metadata["visible_if"] = {"property": "wrap_type", "values": [0]}
	schema.append(gradient_var)

	var line_color_var = SettingsVar.new(Type.COLOR, Color(0.75, 0.05, 0.10), State.ENABLED, "Divider Color")
	line_color_var.property_name = "line_color"
	line_color_var.metadata["visible_if"] = {"property": "wrap_type", "values": [0]}
	schema.append(line_color_var)

	var line_thickness_var = SettingsVar.new(Type.FLOAT, 2.0, State.ENABLED, "Divider Thickness", "", 0.0, 16.0, 0.5)
	line_thickness_var.property_name = "line_thickness_pixels"
	line_thickness_var.metadata["visible_if"] = {"property": "wrap_type", "values": [0]}
	schema.append(line_thickness_var)

	var spine_gradient_var = SettingsVar.new(Type.GRADIENT, _default_spine_gradient(), State.ENABLED, "Spine Gradient")
	spine_gradient_var.property_name = "spine_gradient"
	spine_gradient_var.metadata["visible_if"] = {"property": "wrap_type", "values": [1]}
	schema.append(spine_gradient_var)

	var spine_width_var = SettingsVar.new(Type.FLOAT, 0.12, State.ENABLED, "Spine Width", "", 0.03, 0.4, 0.01)
	spine_width_var.property_name = "spine_width_ratio"
	spine_width_var.metadata["visible_if"] = {"property": "wrap_type", "values": [1]}
	schema.append(spine_width_var)

	var swoop_color_var = SettingsVar.new(Type.COLOR, Color("#12a3c8"), State.ENABLED, "Swoop Bar Color")
	swoop_color_var.property_name = "swoop_color"
	swoop_color_var.metadata["visible_if"] = {"property": "wrap_type", "values": [2]}
	schema.append(swoop_color_var)

	var swoop_edge_var = SettingsVar.new(Type.FLOAT, 0.03, State.ENABLED, "Swoop Edge Height", "", 0.0, 0.3, 0.01)
	swoop_edge_var.property_name = "swoop_edge_ratio"
	swoop_edge_var.metadata["visible_if"] = {"property": "wrap_type", "values": [2]}
	schema.append(swoop_edge_var)

	var swoop_center_var = SettingsVar.new(Type.FLOAT, 0.10, State.ENABLED, "Swoop Center Depth", "", 0.02, 0.4, 0.01)
	swoop_center_var.property_name = "swoop_center_ratio"
	swoop_center_var.metadata["visible_if"] = {"property": "wrap_type", "values": [2]}
	schema.append(swoop_center_var)

	var swoop_exponent_var = SettingsVar.new(Type.FLOAT, 1.5, State.ENABLED, "Swoop Curve", "", 0.5, 3.0, 0.1)
	swoop_exponent_var.property_name = "swoop_exponent"
	swoop_exponent_var.metadata["visible_if"] = {"property": "wrap_type", "values": [2]}
	schema.append(swoop_exponent_var)

	var swoop_stroke_color_var = SettingsVar.new(Type.COLOR, Color("#faf022"), State.ENABLED, "Stroke Color")
	swoop_stroke_color_var.property_name = "swoop_stroke_color"
	swoop_stroke_color_var.metadata["visible_if"] = {"property": "wrap_type", "values": [2]}
	schema.append(swoop_stroke_color_var)

	var swoop_stroke_thickness_var = SettingsVar.new(Type.FLOAT, 2.5, State.ENABLED, "Stroke Thickness", "", 0.0, 12.0, 0.5)
	swoop_stroke_thickness_var.property_name = "swoop_stroke_thickness"
	swoop_stroke_thickness_var.metadata["visible_if"] = {"property": "wrap_type", "values": [2]}
	schema.append(swoop_stroke_thickness_var)

	var swoop_under_enabled_var = SettingsVar.new(Type.BOOL, true, State.ENABLED, "Under Stroke")
	swoop_under_enabled_var.property_name = "swoop_under_enabled"
	swoop_under_enabled_var.metadata["visible_if"] = {"property": "wrap_type", "values": [2]}
	schema.append(swoop_under_enabled_var)

	var swoop_under_color_var = SettingsVar.new(Type.COLOR, Color("#a39f9f"), State.ENABLED, "Under Stroke Color")
	swoop_under_color_var.property_name = "swoop_under_color"
	swoop_under_color_var.metadata["visible_if"] = {"property": "wrap_type", "values": [2]}
	schema.append(swoop_under_color_var)

	var wii_header_color_var = SettingsVar.new(Type.COLOR, Color("#f7f7f7"), State.ENABLED, "Header Color")
	wii_header_color_var.property_name = "wii_header_color"
	wii_header_color_var.metadata["visible_if"] = {"property": "wrap_type", "values": [3]}
	schema.append(wii_header_color_var)

	var wii_header_var = SettingsVar.new(Type.FLOAT, 0.08, State.ENABLED, "Header Height", "", 0.0, 0.3, 0.01)
	wii_header_var.property_name = "wii_header_ratio"
	wii_header_var.metadata["visible_if"] = {"property": "wrap_type", "values": [3]}
	schema.append(wii_header_var)

	var wii_cutout_start_var = SettingsVar.new(Type.FLOAT, 0.55, State.ENABLED, "Cutout Start", "", 0.2, 0.9, 0.01)
	wii_cutout_start_var.property_name = "wii_cutout_start_ratio"
	wii_cutout_start_var.metadata["visible_if"] = {"property": "wrap_type", "values": [3]}
	schema.append(wii_cutout_start_var)

	var wii_cutout_depth_var = SettingsVar.new(Type.FLOAT, 0.10, State.ENABLED, "Cutout Depth", "", 0.0, 0.4, 0.01)
	wii_cutout_depth_var.property_name = "wii_cutout_depth_ratio"
	wii_cutout_depth_var.metadata["visible_if"] = {"property": "wrap_type", "values": [3]}
	schema.append(wii_cutout_depth_var)

	var wii_stroke_enabled_var = SettingsVar.new(Type.BOOL, true, State.ENABLED, "Stroke")
	wii_stroke_enabled_var.property_name = "wii_stroke_enabled"
	wii_stroke_enabled_var.metadata["visible_if"] = {"property": "wrap_type", "values": [3]}
	schema.append(wii_stroke_enabled_var)

	var wii_stroke_color_var = SettingsVar.new(Type.COLOR, Color("#8a8f93"), State.ENABLED, "Stroke Color")
	wii_stroke_color_var.property_name = "wii_stroke_color"
	wii_stroke_color_var.metadata["visible_if"] = {"property": "wrap_type", "values": [3]}
	schema.append(wii_stroke_color_var)

	var wii_stroke_thickness_var = SettingsVar.new(Type.FLOAT, 1.5, State.ENABLED, "Stroke Thickness", "", 0.0, 12.0, 0.5)
	wii_stroke_thickness_var.property_name = "wii_stroke_thickness"
	wii_stroke_thickness_var.metadata["visible_if"] = {"property": "wrap_type", "values": [3]}
	schema.append(wii_stroke_thickness_var)

	return schema
