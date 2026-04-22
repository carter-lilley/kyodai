class_name LibraryBackground
extends Control

var _current_effect: BackgroundEffect = null
var _background_state: BackgroundState = null
var _background_gradient_rect: ColorRect = null
var _gradient_texture: ImageTexture = null

func _ready():
	_initialize_background()
	resized.connect(_on_resized)

func _on_resized() -> void:
	# Children use anchors to fill parent automatically
	# No manual sizing needed with PRESET_FULL_RECT
	pass

func _initialize_background() -> void:
	# Create background gradient layer (bottom)
	_background_gradient_rect = ColorRect.new()
	_background_gradient_rect.name = "BackgroundGradient"
	_background_gradient_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_background_gradient_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_background_gradient_rect.z_index = -1
	# Initial size in case parent already has size
	# DISABLED: Setting size on FULL_RECT controls fights Godot's layout system
	# and causes wrong sizes when the parent resizes between deferral and execution.
	# Anchors handle sizing automatically.
	# if size.x > 0 and size.y > 0:
	# 	_background_gradient_rect.set_deferred("size", size)
	
	# Create shader material for gradient
	var shader_material = ShaderMaterial.new()
	shader_material.shader = preload("res://shaders/background/library_background_gradient.gdshader")
	_background_gradient_rect.material = shader_material
	
	add_child(_background_gradient_rect)
	
	# Get initial config from settings if available
	var config = _get_initial_config()
	_background_state = BackgroundState.new(config)
	_background_state.effect_changed.connect(_on_effect_changed)
	_background_state.setting_changed.connect(_on_setting_changed)
	_background_state.background_gradient_changed.connect(_on_background_gradient_changed)
	_background_state.gradient_direction_changed.connect(_on_gradient_direction_changed)
	_apply_background_state()

func _get_initial_config() -> Dictionary:
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("library_background_config")
		if config_setting and config_setting.value is Dictionary:
			return config_setting.value.duplicate()
	
	# Default config
	var default_gradient = Gradient.new()
	default_gradient.offsets = [0.0, 1.0]
	default_gradient.colors = [Color(0.1, 0.1, 0.15), Color(0.05, 0.05, 0.08)]
	
	return {
		"effect_id": "xmb",
		"background_gradient": default_gradient,
		"gradient_direction": 0,
		"settings": {
			"time_scale": 1.0,
			"show_dust": true,
			"wave_intensity": 1.0,
			"star_threshold": 0.99,
			"color_top_left": Color(0.7, 0.2, 0.2, 1.0),
			"color_top_right": Color(0.4, 0.1, 0.1, 1.0),
			"color_bottom_left": Color(0.45, 0.1, 0.1, 1.0),
			"color_bottom_right": Color(0.8, 0.3, 0.5, 1.0),
			"wave_blend_color": Color.WHITE
		}
	}

func _apply_background_state() -> void:
	if not _background_state:
		return
	
	# Update background gradient
	if _background_gradient_rect and _background_gradient_rect.material:
		_update_gradient_texture(_background_state.background_gradient)
		_background_gradient_rect.material.set_shader_parameter("gradient_direction", _background_state.gradient_direction)
	
	# Remove current effect if any
	if _current_effect:
		_current_effect.queue_free()
		_current_effect = null
	
	# Create and add new effect as sibling of background gradient
	_current_effect = _create_effect(_background_state.effect_id)
	if _current_effect:
		add_child(_current_effect)
		_current_effect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_current_effect.visible = true
		# Initial size in case parent already has size
		# DISABLED: Setting size on FULL_RECT controls fights Godot's layout system
		# and causes wrong sizes when the parent resizes between deferral and execution.
		# Anchors handle sizing automatically.
		# if size.x > 0 and size.y > 0:
		# 	_current_effect.set_deferred("size", size)
		_current_effect.initialize(_background_state.effect_settings)

func _gradient_to_texture(gradient: Gradient) -> ImageTexture:
	var image = Image.create(256, 1, false, Image.FORMAT_RGBA8)
	
	for i in range(256):
		var t = i / 255.0
		var color = gradient.sample(t)
		image.set_pixel(i, 0, color)
	
	return ImageTexture.create_from_image(image)

func _update_gradient_texture(gradient: Gradient) -> void:
	if _gradient_texture:
		_gradient_texture = _gradient_to_texture(gradient)
		if _background_gradient_rect and _background_gradient_rect.material:
			_background_gradient_rect.material.set_shader_parameter("gradient_texture", _gradient_texture)
	else:
		_gradient_texture = _gradient_to_texture(gradient)
		if _background_gradient_rect and _background_gradient_rect.material:
			_background_gradient_rect.material.set_shader_parameter("gradient_texture", _gradient_texture)

func _create_effect(effect_id: String) -> BackgroundEffect:
	match effect_id:
		"none":
			return null
		"xmb":
			return XmbBackgroundEffect.new()
		"motes":
			return MotesBackgroundEffect.new()
		"osdsys":
			return OsdSysBackgroundEffect.new()
		"cafeos":
			return CafeOSBackgroundEffect.new()
		_:
			return XmbBackgroundEffect.new()

func _on_effect_changed(_new_effect_id: String) -> void:
	_apply_background_state()

func _on_setting_changed(setting_name: String, value: Variant) -> void:
	if _current_effect:
		_current_effect.update_settings(_background_state.effect_settings)

func _on_background_gradient_changed(gradient: Gradient) -> void:
	_update_gradient_texture(gradient)

func _on_gradient_direction_changed(direction: int) -> void:
	if _background_gradient_rect and _background_gradient_rect.material:
		_background_gradient_rect.material.set_shader_parameter("gradient_direction", direction)

# Public API for updating background configuration
func set_background_config(config: Dictionary) -> void:
	if not _background_state:
		_background_state = BackgroundState.new(config)
		_background_state.effect_changed.connect(_on_effect_changed)
		_background_state.setting_changed.connect(_on_setting_changed)
		_background_state.background_gradient_changed.connect(_on_background_gradient_changed)
		_background_state.gradient_direction_changed.connect(_on_gradient_direction_changed)
		_apply_background_state()
	else:
		var old_effect_id = _background_state.effect_id
		_background_state.effect_id = config.get("effect_id", "xmb")
		_background_state.effect_settings = config.get("settings", {}).duplicate()
		
		# Update gradient if provided
		if config.has("background_gradient"):
			if config.background_gradient is Gradient:
				_background_state.background_gradient = config.background_gradient
			
		if config.has("gradient_direction"):
			_background_state.gradient_direction = config.get("gradient_direction", 0)
		
		if _background_state.effect_id != old_effect_id:
			_apply_background_state()
		else:
			# Same effect, just update settings and gradient
			if _current_effect:
				_current_effect.update_settings(_background_state.effect_settings)
			_update_gradient_texture(_background_state.background_gradient)
			if _background_gradient_rect and _background_gradient_rect.material:
				_background_gradient_rect.material.set_shader_parameter("gradient_direction", _background_state.gradient_direction)

func get_background_config() -> Dictionary:
	if _background_state:
		return _background_state.get_config()
	return _get_initial_config()

# Legacy method for backward compatibility
func set_background_color(color: Color) -> void:
	if _background_state:
		# Convert solid color to single-color gradient
		var gradient = Gradient.new()
		gradient.offsets = [0.0, 1.0]
		gradient.colors = [color, color]
		_background_state.background_gradient = gradient

# Get available effect IDs for dropdown
static func get_available_effects() -> Array[String]:
	return ["none", "xmb", "motes", "osdsys", "cafeos"]

# Get effect display name
static func get_effect_display_name(effect_id: String) -> String:
	match effect_id:
		"none": return "None"
		"xmb": return "XMB"
		"motes": return "Motes"
		"osdsys": return "OSDSYS"
		"cafeos": return "CafeOS"
		_: return "Unknown"

# Get settings schema for an effect
static func get_effect_schema(effect_id: String) -> Array[SettingsVar]:
	if effect_id == "none":
		return []
	
	var effect: BackgroundEffect
	match effect_id:
		"xmb":
			effect = XmbBackgroundEffect.new()
		"motes":
			effect = MotesBackgroundEffect.new()
		"osdsys":
			effect = OsdSysBackgroundEffect.new()
		"cafeos":
			effect = CafeOSBackgroundEffect.new()
		_:
			effect = XmbBackgroundEffect.new()
	
	var schema = effect.get_settings_schema()
	effect.queue_free()
	return schema

# Get background gradient settings schema (global)
static func get_background_gradient_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	
	# Background Gradient
	var gradient = Gradient.new()
	gradient.offsets = [0.0, 1.0]
	gradient.colors = [Color(0.1, 0.1, 0.15), Color(0.05, 0.05, 0.08)]
	var gradient_var = SettingsVar.new(Type.GRADIENT, gradient, State.ENABLED, "Background Gradient")
	gradient_var.property_name = "background_gradient"
	schema.append(gradient_var)
	
	# Gradient Direction
	var direction_var = SettingsVar.new(Type.ENUM, 0, State.ENABLED, "Gradient Direction", "", 0.0, 2.0, 1.0, ["Horizontal", "Vertical", "Diagonal"])
	direction_var.property_name = "gradient_direction"
	schema.append(direction_var)
	
	return schema
