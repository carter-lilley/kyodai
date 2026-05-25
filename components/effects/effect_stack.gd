class_name EffectStack
extends Control

signal effects_changed

var _container_state: EffectContainerState
var _effects: Dictionary = {}  # effect_id -> EffectBase instance
var _effect_configs: Array = []  # Array of {effect_id, settings} dictionaries
var _context: String = "base_card"

# Effect factory - maps effect_id to script path
const EFFECT_REGISTRY: Dictionary = {
	"base": "res://effects/shared/base_card_effect.gd",
	"border": "res://effects/shared/border_effect.gd",
	"badge": "res://effects/shared/badge_effect.gd",
	"drop_shadow": "res://effects/shared/drop_shadow_effect.gd",
	"glow": "res://effects/shared/glow_effect.gd",
	"glass": "res://effects/shared/glass_effect.gd",
	"distort": "res://effects/shared/distort_effect.gd",
	"gradient_overlay": "res://effects/shared/gradient_overlay_effect.gd",
	"hsl": "res://effects/shared/hsl_effect.gd",
	"blur": "res://effects/shared/blur_effect.gd",
}

# Layer order (z-index / child order) - lower = behind, higher = in front
const EFFECT_LAYER_ORDER: Array = [
	"glow",       # -2: Behind everything
	"drop_shadow",# -1: Behind card
	"base",       # 0: Base texture
	"hsl",        # 1: HSL color adjustment
	"blur",       # 2: Blur overlay
	"distort",         # 3: Distortion overlay
	"gradient_overlay", # 3: Gradient overlay
	"glass",            # 4: Glass overlay
	"border",           # 5: Border overlay
	"badge",            # 6: Badge overlay
]

func _init(container_state: EffectContainerState = null):
	if container_state:
		_container_state = container_state
	else:
		_container_state = EffectContainerState.new()

func initialize(container_state: EffectContainerState, effect_configs: Array, context: String = "base_card"):
	_container_state = container_state
	_effect_configs = effect_configs.duplicate(true)
	_context = context
	_rebuild_effects()

func update_state(container_state: EffectContainerState):
	_container_state = container_state
	for effect_id in _effects:
		var effect = _effects[effect_id]
		if effect:
			effect.update_state(_container_state)

func update_effect_configs(effect_configs: Array):
	_effect_configs = effect_configs.duplicate(true)
	_rebuild_effects()

func set_game_texture(texture: Texture2D):
	_container_state.game_texture = texture
	# Notify all effects that need the game texture
	for effect_id in _effects:
		var effect = _effects[effect_id]
		if effect and effect.has_method("set_game_texture"):
			effect.set_game_texture(texture)

func get_container_state() -> EffectContainerState:
	return _container_state

func get_effect_configs() -> Array:
	return _effect_configs.duplicate(true)

func _rebuild_effects():
	# Track which effects should be visible
	var active_effect_ids: Array[String] = []
	for config in _effect_configs:
		if config is Dictionary:
			var effect_id = config.get("effect_id", "")
			if effect_id and EFFECT_REGISTRY.has(effect_id):
				active_effect_ids.append(effect_id)
	
	# Ensure base effect always exists
	if not "base" in active_effect_ids:
		active_effect_ids.append("base")
	
	# Hide effects that are no longer active
	for effect_id in _effects.keys():
		if not effect_id in active_effect_ids:
			_effects[effect_id].visible = false
	
	# Reset insets
	_container_state.border_inset_ratio = 0.0
	_container_state.glass_inset_ratio = 0.0
	
	# Create/update effects in layer order
	for effect_id in EFFECT_LAYER_ORDER:
		if effect_id in active_effect_ids:
			var config = _get_effect_config(effect_id)
			var settings = config.get("settings", {})
			
			if _effects.has(effect_id):
				# Update existing effect
				var effect = _effects[effect_id]
				effect.visible = true
				effect.update_state(_container_state)
				effect.update_settings(settings)
			else:
				# Create new effect
				var effect = _create_effect(effect_id)
				if effect:
					# Skip effects that are not allowed in the current context
					var allowed_contexts = effect.get_allowed_contexts()
					if not allowed_contexts.has(_context):
						continue
					_effects[effect_id] = effect
					add_child(effect)
					effect.initialize(_container_state, settings)
			
			# Update insets based on effect settings
			match effect_id:
				"border":
					_container_state.border_inset_ratio = settings.get("border_size", 0.05)
				"glass":
					_container_state.glass_inset_ratio = settings.get("additional_inset_ratio", 0.0)
			
			# Set layer order
			var layer_index = EFFECT_LAYER_ORDER.find(effect_id)
			if layer_index >= 0:
				_effects[effect_id].z_index = max(0, layer_index - 2)  # Clamp to prevent behind-background rendering
	
	# Ensure proper child order
	for effect_id in EFFECT_LAYER_ORDER:
		if effect_id in _effects and _effects[effect_id].visible:
			move_child(_effects[effect_id], -1)
	
	effects_changed.emit()

static var _script_cache: Dictionary[String, Script] = {}

func _create_effect(effect_id: String) -> EffectBase:
	var script_path = EFFECT_REGISTRY.get(effect_id, "")
	if script_path == "":
		push_error("EffectStack: Unknown effect_id: " + effect_id)
		return null
	
	var script: Script = _script_cache.get(script_path, null)
	if not script:
		script = load(script_path)
		if not script:
			push_error("EffectStack: Failed to load script: " + script_path)
			return null
		_script_cache[script_path] = script
	
	var effect = script.new()
	if not effect is EffectBase:
		push_error("EffectStack: Effect script does not extend EffectBase: " + script_path)
		effect.queue_free()
		return null
	
	# Set anchors based on effect type
	if effect_id in ["glow", "drop_shadow"]:
		effect.set_anchors_preset(Control.PRESET_CENTER)
	else:
		effect.anchor_right = 1.0
		effect.anchor_bottom = 1.0
	
	return effect

func _get_effect_config(effect_id: String) -> Dictionary:
	for config in _effect_configs:
		if config is Dictionary and config.get("effect_id") == effect_id:
			return config
	return {}

func get_effect(effect_id: String) -> EffectBase:
	return _effects.get(effect_id, null)

func has_effect(effect_id: String) -> bool:
	return _effects.has(effect_id) and _effects[effect_id].visible

static func get_available_effects() -> Dictionary:
	return EFFECT_REGISTRY.duplicate()

static func get_effect_display_name(effect_id: String) -> String:
	return effect_id.replace("_", " ").capitalize()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		# Update container state with actual size
		if _container_state and size.x > 0 and size.y > 0:
			_container_state.container_size = size
			# Update all effects with new size (even hidden ones, so they have correct params when shown)
			for effect_id in _effects:
				var effect = _effects[effect_id]
				if effect:
					effect.update_state(_container_state)
