class_name EffectBase
extends ColorRect

@export var effect_name: String = "Effect"
@export var effect_id: String = ""

var _settings: Dictionary = {}
var media_container: MediaContainer = null

# Reference to base effect (for focus effects that overlap with base)
var _base_effect: EffectBase = null

var enabled: bool = true

# These signals are part of the public API for subclasses and external systems.
@warning_ignore("unused_signal")
signal effect_enabled_changed(enabled: bool)
@warning_ignore("unused_signal")
signal settings_changed(setting_name: String, value: Variant)

func _ready():
	if material == null:
		material = ShaderMaterial.new()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Make the ColorRect transparent so shader can control visibility
	color = Color.TRANSPARENT
	# If initialize() ran before _ready() (deferred), push shader params now that material exists
	if media_container:
		_update_shader_params()

func initialize(container: MediaContainer, settings: Dictionary) -> void:
	media_container = container
	_settings = settings.duplicate()
	if material == null:
		material = ShaderMaterial.new()
	_setup_shader()
	_apply_settings()
	if media_container:
		media_container.changed.connect(_on_media_changed)
	_update_shader_params()

func set_base_effect(base: EffectBase) -> void:
	"""Set the base effect that this focus effect should tween from."""
	_base_effect = base

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

func compute_pipeline(cache: Dictionary) -> void:
	"""Override to compute shared values and write to pipeline cache.
	Called in layer order before _update_shader_params()."""
	pass

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
		mat.set_shader_parameter(param, value)

func _on_media_changed() -> void:
	if _is_tweening:
		return
	_update_shader_params()
