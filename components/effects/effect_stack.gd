class_name EffectStack
extends Control

signal effects_changed

var media_container: MediaContainer
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
	"glow",       # Behind everything
	"drop_shadow",# Behind card
	"base",       # Base texture
	"hsl",        # HSL color adjustment
	"blur",       # Blur overlay
	"distort",         # Distortion overlay
	"gradient_overlay", # Gradient overlay
	"border",           # Border overlay (rendered before glass so glass can shine over it)
	"glass",            # Glass overlay
	"badge",            # Badge overlay
]

func initialize(container: MediaContainer, effect_configs: Array, context: String = "base_card"):
	media_container = container
	_effect_configs = effect_configs.duplicate(true)
	_context = context
	_rebuild_effects()

func update_effect_configs(effect_configs: Array):
	_effect_configs = effect_configs.duplicate(true)
	_rebuild_effects()

func set_game_texture(texture: Texture2D):
	if media_container:
		media_container.texture = texture
	# Notify all effects that need the game texture
	for effect_id in _effects:
		var effect = _effects[effect_id]
		if effect and effect.has_method("set_game_texture"):
			effect.set_game_texture(texture)

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
	
	# Free effects that are no longer active
	for effect_id in _effects.keys():
		if not effect_id in active_effect_ids:
			var effect = _effects[effect_id]
			if is_instance_valid(effect):
				effect.queue_free()
			_effects.erase(effect_id)
	
	# Reset insets on media container
	if media_container:
		media_container.border_inset_ratio = 0.0
		media_container.glass_inset_ratio = 0.0
	
	# Create/update effects in layer order
	for effect_id in EFFECT_LAYER_ORDER:
		if effect_id in active_effect_ids:
			var config = _get_effect_config(effect_id)
			var settings = config.get("settings", {})
			
			if _effects.has(effect_id):
				# Update existing effect
				var effect = _effects[effect_id]
				effect.visible = true
				effect.media_container = media_container
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
					effect.initialize(media_container, settings)
			
			# Update insets based on effect settings (only for base card context;
			# focus effects should not permanently overwrite base insets)
			if _context != "focus_card":
				match effect_id:
					"border":
						if media_container:
							media_container.border_inset_ratio = settings.get("border_size", 0.0)
					"glass":
						if media_container:
							media_container.glass_inset_ratio = settings.get("additional_inset_ratio", 0.0)
			
			# Set layer order
			var layer_index = EFFECT_LAYER_ORDER.find(effect_id)
			if layer_index >= 0:
				_effects[effect_id].z_index = max(0, layer_index - 2)  # Clamp to prevent behind-background rendering
	
	# Ensure proper child order
	for effect_id in EFFECT_LAYER_ORDER:
		if effect_id in _effects and _effects[effect_id].visible:
			move_child(_effects[effect_id], -1)
	
	# Run pipeline to compute shared values
	_run_pipeline()
	
	effects_changed.emit()

func _run_pipeline() -> void:
	if not media_container:
		return
	var layers: Array = []
	for effect_id in EFFECT_LAYER_ORDER:
		if effect_id in _effects and _effects[effect_id].visible:
			layers.append(_effects[effect_id])
	media_container.run_pipeline(layers)
	# Update all effects after pipeline runs
	for effect_id in _effects:
		var effect = _effects[effect_id]
		if effect:
			effect._update_shader_params()

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

func force_refresh() -> void:
	"""Public method to force a full pipeline refresh."""
	_run_pipeline()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		# Update media container bounds with actual size
		if media_container and size.x > 0 and size.y > 0:
			media_container.bounds = Rect2(Vector2.ZERO, size)
