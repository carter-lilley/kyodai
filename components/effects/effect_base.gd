class_name EffectBase
extends RefCounted

var effect_id: String = ""

var _settings: Dictionary = {}
var media_container: MediaContainer = null

var _base_effect: EffectBase = null
var effect_stack: EffectStack = null

var enabled: bool = true

var _canvas_item_rid: RID = RID()
var _material: ShaderMaterial = null
var _visible: bool = true
var _z_index: int = 0

var _shader_params_dirty: bool = false

static var _fallback_texture: Texture2D = null

static func get_fallback_texture() -> Texture2D:
	if _fallback_texture == null:
		var img = Image.create(2, 2, false, Image.FORMAT_RGBA8)
		img.fill(M3Theme.get_elevation_surface(5))
		_fallback_texture = ImageTexture.create_from_image(img)
	return _fallback_texture

func _init():
	_material = ShaderMaterial.new()
	_setup_shader()

func free_rid() -> void:
	if media_container and media_container.changed.is_connected(_on_media_changed):
		media_container.changed.disconnect(_on_media_changed)
	media_container = null
	effect_stack = null
	_base_effect = null

	if _canvas_item_rid.is_valid():
		RenderingServer.free_rid(_canvas_item_rid)
		_canvas_item_rid = RID()
	_material = null

func ensure_canvas_item(parent_rid: RID) -> RID:
	if not _canvas_item_rid.is_valid():
		_canvas_item_rid = RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_material(_canvas_item_rid, _material.get_rid())
		RenderingServer.canvas_item_set_draw_index(_canvas_item_rid, _z_index)
	if parent_rid.is_valid():
		RenderingServer.canvas_item_set_parent(_canvas_item_rid, parent_rid)
	return _canvas_item_rid

func set_parent_rid(parent_rid: RID) -> void:
	ensure_canvas_item(parent_rid)

func set_z_index(value: int) -> void:
	_z_index = value
	if _canvas_item_rid.is_valid():
		RenderingServer.canvas_item_set_draw_index(_canvas_item_rid, value)

func get_z_index() -> int:
	return _z_index

func set_visible(value: bool) -> void:
	_visible = value
	if _canvas_item_rid.is_valid():
		RenderingServer.canvas_item_set_visible(_canvas_item_rid, value)

func is_visible() -> bool:
	return _visible

func set_offset_rect(rect: Rect2) -> void:
	ensure_canvas_item(RID())
	RenderingServer.canvas_item_clear(_canvas_item_rid)
	# Add the visible rect used by the shader. We also draw a tiny placeholder
	# rect when collapsed to keep the canvas item valid for transforms.
	var draw_rect := rect
	if draw_rect.size.x <= 0.0 or draw_rect.size.y <= 0.0:
		draw_rect = Rect2(Vector2.ZERO, Vector2(1, 1))
	RenderingServer.canvas_item_add_rect(_canvas_item_rid, draw_rect, Color.WHITE)
	RenderingServer.canvas_item_set_visible(_canvas_item_rid, _visible)

var _base_settings: Dictionary = {}

func initialize(container: MediaContainer, settings: Dictionary) -> void:
	if media_container and media_container.changed.is_connected(_on_media_changed):
		media_container.changed.disconnect(_on_media_changed)

	media_container = container
	_settings = settings.duplicate()
	_base_settings = settings.duplicate()
	_setup_shader()
	_apply_settings()
	if media_container:
		media_container.changed.connect(_on_media_changed)
	_update_shader_params()

func set_base_effect(base: EffectBase) -> void:
	_base_effect = base

func update_settings(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	_base_settings = settings.duplicate()
	_apply_settings()
	_update_shader_params()

func get_settings_schema() -> Array[SettingsVar]:
	return []

func get_tweenable_settings() -> Array[String]:
	var tweenable: Array[String] = []
	var schema = get_settings_schema()

	for setting in schema:
		if setting.type == SettingsVar.SettingType.FLOAT or \
		   setting.type == SettingsVar.SettingType.INT or \
		   setting.type == SettingsVar.SettingType.VECTOR2 or \
		   setting.type == SettingsVar.SettingType.COLOR:
			tweenable.append(setting.property_name)

	return tweenable

var _is_tweening: bool = false

func tween_settings(from_settings: Dictionary, to_settings: Dictionary, progress: float) -> void:
	print("[EffectBase] tween_settings effect_id=", effect_id,
		" progress=", progress,
		" from_border=", from_settings.get("border_size", "N/A"),
		" to_border=", to_settings.get("border_size", "N/A"),
		" current_border=", _settings.get("border_size", "N/A"),
		" _is_tweening=", _is_tweening)
	var tweenables = get_tweenable_settings()

	_is_tweening = true

	var temp_settings = _settings.duplicate()

	for setting_name in tweenables:
		if from_settings.has(setting_name) and to_settings.has(setting_name):
			var from_val = from_settings[setting_name]
			var to_val = to_settings[setting_name]
			temp_settings[setting_name] = _interpolate_value(from_val, to_val, progress)

	_apply_tweened_settings(temp_settings)

	if progress >= 1.0:
		# Snap to the exact target settings so non-tweenable parameters don't
		# linger with stale values from the starting configuration.
		_settings = to_settings.duplicate(true)
		_apply_settings()
		_update_shader_params()
		_is_tweening = false

func _interpolate_value(from_val: Variant, to_val: Variant, progress: float) -> Variant:
	var from_type = typeof(from_val)
	var to_type = typeof(to_val)

	if (from_type == TYPE_FLOAT or from_type == TYPE_INT) and (to_type == TYPE_FLOAT or to_type == TYPE_INT):
		return lerpf(float(from_val), float(to_val), progress)
	elif from_val is Color and to_val is Color:
		return from_val.lerp(to_val, progress)
	elif from_val is Vector2 and to_val is Vector2:
		return from_val.lerp(to_val, progress)
	elif from_val is Vector3 and to_val is Vector3:
		return from_val.lerp(to_val, progress)
	else:
		return to_val if progress >= 0.5 else from_val

func compute_pipeline(cache: Dictionary) -> void:
	pass

func _setup_shader() -> void:
	pass

func _apply_settings() -> void:
	pass

func _apply_tweened_settings(temp_settings: Dictionary) -> void:
	# Tweened values become the active visual state. We intentionally do NOT
	# restore the original _settings afterwards; otherwise shader params and
	# geometry can snap back to base values while the card is still focused,
	# causing effects like glow to misalign.
	_settings = temp_settings
	_apply_settings()

	# Push interpolated values to the shader while _settings holds the tweened
	# values. Without this, effects like glow keep their base uniforms during
	# the focus tween and scale from the wrong size/center.
	_update_shader_params()

	if media_container:
		var needs_refresh = false
		match effect_id:
			"border":
				var new_inset = temp_settings.get("border_size", media_container.border_inset_ratio)
				if not is_equal_approx(new_inset, media_container.border_inset_ratio):
					media_container.border_inset_ratio = new_inset
					needs_refresh = true
			"glass":
				var new_inset = temp_settings.get("additional_inset_ratio", media_container.glass_inset_ratio)
				if not is_equal_approx(new_inset, media_container.glass_inset_ratio):
					media_container.glass_inset_ratio = new_inset
					needs_refresh = true
			"glow", "drop_shadow":
				# These effects change their canvas draw rect with their settings,
				# so refresh geometry during the tween to keep alignment.
				needs_refresh = true

		if needs_refresh and effect_stack:
			effect_stack.force_refresh()

func _update_shader_params() -> void:
	pass

func _set_shader_param(param: String, value: Variant) -> void:
	if not _material:
		return
	if param == "game_texture" and (value == null or not value is Texture2D):
		_material.set_shader_parameter(param, get_fallback_texture())
		return
	_material.set_shader_parameter(param, value)

func _on_media_changed() -> void:
	if _is_tweening:
		return
	_mark_shader_params_dirty()

func _mark_shader_params_dirty() -> void:
	if _shader_params_dirty:
		return
	_shader_params_dirty = true
	call_deferred("_flush_shader_params")

func _flush_shader_params() -> void:
	if not is_instance_valid(self):
		return
	_shader_params_dirty = false
	_update_shader_params()

func set_game_texture(texture: Texture2D) -> void:
	pass

func set_alpha(value: float) -> void:
	_set_shader_param("alpha", value)
