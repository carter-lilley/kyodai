class_name EffectBase
extends ColorRect

@export var effect_name: String = "Effect"
@export var effect_id: String = ""

var _settings: Dictionary = {}
var _container_state: EffectContainerState

# Reference to base effect (for focus effects that overlap with base)
var _base_effect: EffectBase = null

signal effect_enabled_changed(enabled: bool)
signal settings_changed(setting_name: String, value: Variant)

func _ready():
	if material == null:
		material = ShaderMaterial.new()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Make the ColorRect transparent so shader can control visibility
	color = Color.TRANSPARENT
	# If initialize() ran before _ready() (deferred), push shader params now that material exists
	if _container_state:
		_update_shader_params()

func initialize(container_state: EffectContainerState, settings: Dictionary) -> void:
	_container_state = container_state
	_settings = settings.duplicate()
	_setup_shader()
	_apply_settings()
	_connect_container_state_signals()
	_update_shader_params()

func set_base_effect(base: EffectBase) -> void:
	"""Set the base effect that this focus effect should tween from."""
	_base_effect = base

func update_state(container_state: EffectContainerState) -> void:
	_disconnect_container_state_signals()
	_container_state = container_state
	_connect_container_state_signals()
	# Manually trigger size update since the signal may have fired before we reconnected
	if _container_state:
		_on_size_changed(_container_state.container_size)
	_update_shader_params()

func update_settings(settings: Dictionary) -> void:
	_settings = settings.duplicate()
	_apply_settings()

func get_settings_schema() -> Array[SettingsVar]:
	return []

func get_tweenable_settings() -> Array[String]:
	"""Return list of setting property names that can be tweened numerically.
	Automatically detects tweenable types from the settings schema (FLOAT, INT, VECTOR2, COLOR)."""
	var tweenable: Array[String] = []
	var schema = get_settings_schema()
	
	for setting in schema:
		if setting.type == SettingsVar.SettingType.FLOAT or \
		   setting.type == SettingsVar.SettingType.INT or \
		   setting.type == SettingsVar.SettingType.VECTOR2 or \
		   setting.type == SettingsVar.SettingType.COLOR:
			tweenable.append(setting.property_name)
	
	return tweenable

var _is_tweening: bool = false  # Track if currently in a tween to prevent shader resets

func tween_settings(from_settings: Dictionary, to_settings: Dictionary, progress: float) -> void:
	"""Apply settings interpolated between from and to based on progress (0.0-1.0).
	Note: This applies interpolated values to the shader but does NOT modify _settings
	to preserve the original focus effect configuration."""
	var tweenables = get_tweenable_settings()
	
	# DEBUG: Print tween info for HSL effects
	if effect_id == "hsl":
		var from_sat = from_settings.get("saturation_scale", "N/A")
		var to_sat = to_settings.get("saturation_scale", "N/A")
		print("[HSL TWEEN] Progress: %.3f | From sat: %s | To sat: %s | Node: %s" % [progress, str(from_sat), str(to_sat), name])
	
	_is_tweening = true
	
	# Create a temporary settings dict for interpolation
	var temp_settings = _settings.duplicate()
	
	for setting_name in tweenables:
		if from_settings.has(setting_name) and to_settings.has(setting_name):
			var from_val = from_settings[setting_name]
			var to_val = to_settings[setting_name]
			
			# Interpolate based on type
			var current_val = _interpolate_value(from_val, to_val, progress)
			temp_settings[setting_name] = current_val
	
	# Apply the interpolated settings WITHOUT storing them in _settings
	_apply_tweened_settings(temp_settings)
	
	# Mark tween as complete when progress reaches 1.0
	if progress >= 1.0:
		_is_tweening = false

func _interpolate_value(from_val: Variant, to_val: Variant, progress: float) -> Variant:
	"""Interpolate between two values based on their type."""
	var from_type = typeof(from_val)
	var to_type = typeof(to_val)
	
	# Handle numeric types (both float and int)
	if (from_type == TYPE_FLOAT or from_type == TYPE_INT) and (to_type == TYPE_FLOAT or to_type == TYPE_INT):
		var from_f = float(from_val)
		var to_f = float(to_val)
		return lerpf(from_f, to_f, progress)
	elif from_val is Color and to_val is Color:
		return from_val.lerp(to_val, progress)
	elif from_val is Vector2 and to_val is Vector2:
		return from_val.lerp(to_val, progress)
	elif from_val is Vector3 and to_val is Vector3:
		return from_val.lerp(to_val, progress)
	else:
		# For non-interpolatable types, use threshold
		return to_val if progress >= 0.5 else from_val

func _setup_shader() -> void:
	pass

func _apply_settings() -> void:
	pass

func _apply_tweened_settings(temp_settings: Dictionary) -> void:
	"""Apply temporary interpolated settings to the shader without storing them.
	This preserves the original _settings for future tweens."""
	# Store original settings
	var original_settings = _settings
	# Temporarily use interpolated settings
	_settings = temp_settings
	# Apply to shader
	_apply_settings()
	# Restore original settings
	_settings = original_settings

func _update_shader_params() -> void:
	pass

func _set_shader_param(param: String, value: Variant) -> void:
	var mat = material as ShaderMaterial
	if mat:
		# DEBUG: Track saturation_scale changes for HSL
		if effect_id == "hsl" and param == "saturation_scale":
			var card = get_parent()
			var is_focus = card and card.get_parent() and card.get_parent().name == "FocusEffects"
			if is_focus:
				print("[HSL SHADER] Setting saturation_scale: %.3f on %s" % [value, name])
		mat.set_shader_parameter(param, value)

# Reactive signal connections
func _connect_container_state_signals() -> void:
	if not _container_state:
		return
	_container_state.zoom_changed.connect(_on_zoom_changed)
	_container_state.size_changed.connect(_on_size_changed)
	_container_state.orientation_changed.connect(_on_orientation_changed)
	_container_state.corner_radius_changed.connect(_on_corner_radius_changed)
	_container_state.border_inset_changed.connect(_on_border_inset_changed)
	_container_state.shape_changed.connect(_on_shape_changed)

func _disconnect_container_state_signals() -> void:
	if not _container_state:
		return
	if _container_state.zoom_changed.is_connected(_on_zoom_changed):
		_container_state.zoom_changed.disconnect(_on_zoom_changed)
	if _container_state.size_changed.is_connected(_on_size_changed):
		_container_state.size_changed.disconnect(_on_size_changed)
	if _container_state.orientation_changed.is_connected(_on_orientation_changed):
		_container_state.orientation_changed.disconnect(_on_orientation_changed)
	if _container_state.corner_radius_changed.is_connected(_on_corner_radius_changed):
		_container_state.corner_radius_changed.disconnect(_on_corner_radius_changed)
	if _container_state.border_inset_changed.is_connected(_on_border_inset_changed):
		_container_state.border_inset_changed.disconnect(_on_border_inset_changed)
	if _container_state.shape_changed.is_connected(_on_shape_changed):
		_container_state.shape_changed.disconnect(_on_shape_changed)

func _on_zoom_changed(_new_zoom: float) -> void:
	if _is_tweening:
		return
	_update_shader_params()

func _on_size_changed(_new_size: Vector2) -> void:
	if _is_tweening:
		return
	_update_shader_params()

func _on_orientation_changed(_new_orientation: int) -> void:
	if _is_tweening:
		return
	_update_shader_params()

func _on_corner_radius_changed(_new_ratio: float) -> void:
	if _is_tweening:
		return
	_update_shader_params()

func _on_border_inset_changed(_new_ratio: float) -> void:
	if _is_tweening:
		return
	_update_shader_params()

func _on_shape_changed() -> void:
	if _is_tweening:
		return
	_update_shader_params()
