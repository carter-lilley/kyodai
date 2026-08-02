class_name EffectStack
extends RefCounted

var media_container: MediaContainer
var _effects: Dictionary = {}  # effect_id -> EffectBase instance
var _effect_configs: Array = []
var _context: String = "base_card"

var _parent_rid: RID = RID()
var _stack_canvas_item: RID = RID()
var _clip_children: bool = true
var _visible: bool = true

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

const EFFECT_LAYER_ORDER: Array = [
	"glow",
	"drop_shadow",
	"base",
	"hsl",
	"blur",
	"distort",
	"gradient_overlay",
	"border",
	"glass",
	"badge",
]

func free_rids() -> void:
	for effect in _effects.values():
		if is_instance_valid(effect):
			effect.free_rid()
	_effects.clear()
	if _stack_canvas_item.is_valid():
		RenderingServer.free_rid(_stack_canvas_item)
		_stack_canvas_item = RID()

func set_parent_rid(parent_rid: RID) -> void:
	_parent_rid = parent_rid
	_ensure_stack_canvas_item()

func _ensure_stack_canvas_item() -> void:
	if not _stack_canvas_item.is_valid():
		_stack_canvas_item = RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_visible(_stack_canvas_item, true)
	if _parent_rid.is_valid():
		RenderingServer.canvas_item_set_parent(_stack_canvas_item, _parent_rid)

func set_clip_children(value: bool) -> void:
	_clip_children = value
	if _stack_canvas_item.is_valid():
		RenderingServer.canvas_item_set_clip(_stack_canvas_item, value)

func set_visible(value: bool) -> void:
	_visible = value
	if _stack_canvas_item.is_valid():
		RenderingServer.canvas_item_set_visible(_stack_canvas_item, value)

func is_visible() -> bool:
	return _visible

func initialize(container: MediaContainer, effect_configs: Array, context: String = "base_card"):
	media_container = container
	_effect_configs = _clone_effect_configs(effect_configs)
	_context = context
	_rebuild_effects()

func update_effect_configs(effect_configs: Array, force_full_rebuild: bool = true):
	_effect_configs = _clone_effect_configs(effect_configs)
	if not force_full_rebuild:
		var active_effect_ids: Array[String] = []
		for config in _effect_configs:
			if config is Dictionary:
				var effect_id = config.get("effect_id", "")
				if effect_id and EFFECT_REGISTRY.has(effect_id):
					active_effect_ids.append(effect_id)
		if not "base" in active_effect_ids:
			active_effect_ids.append("base")

		if active_effect_ids.size() == _effects.size():
			var same_ids = true
			for effect_id in active_effect_ids:
				if not _effects.has(effect_id):
					same_ids = false
					break
			if same_ids:
				_update_effect_settings_only()
				return
	_rebuild_effects()

func set_game_texture(texture: Texture2D) -> void:
	if media_container and media_container.texture == texture:
		return
	if media_container:
		media_container.texture = texture
	for effect_id in _effects:
		var effect = _effects[effect_id]
		if effect:
			effect._mark_shader_params_dirty()

func _rebuild_effects():
	var active_effect_ids: Array[String] = []
	for config in _effect_configs:
		if config is Dictionary:
			var effect_id = config.get("effect_id", "")
			if effect_id and EFFECT_REGISTRY.has(effect_id):
				active_effect_ids.append(effect_id)

	if not "base" in active_effect_ids:
		active_effect_ids.append("base")

	# Free effects that are no longer active
	for effect_id in _effects.keys():
		if not effect_id in active_effect_ids:
			var effect = _effects[effect_id]
			if is_instance_valid(effect):
				effect.free_rid()
			_effects.erase(effect_id)

	if media_container and _context != "focus_card":
		media_container.border_inset_ratio = 0.0
		media_container.glass_inset_ratio = 0.0

	var config_map: Dictionary = {}
	for config in _effect_configs:
		if config is Dictionary:
			var id = config.get("effect_id", "")
			if id:
				config_map[id] = config

	for i in range(EFFECT_LAYER_ORDER.size()):
		var effect_id = EFFECT_LAYER_ORDER[i]
		if effect_id in active_effect_ids:
			var config = config_map.get(effect_id, {})
			var settings = config.get("settings", {})

			if _effects.has(effect_id):
				var effect = _effects[effect_id]
				effect.set_visible(true)
				effect.media_container = media_container
				effect.effect_stack = self
				effect.update_settings(settings)
			else:
				var effect = _create_effect(effect_id)
				if effect:
					var allowed_contexts = effect.get_allowed_contexts()
					if not allowed_contexts.has(_context):
						continue
					_effects[effect_id] = effect
					effect.effect_stack = self
					effect.initialize(media_container, settings)

			if _context != "focus_card":
				match effect_id:
					"border":
						if media_container:
							media_container.border_inset_ratio = settings.get("border_size", 0.0)
					"glass":
						if media_container:
							media_container.glass_inset_ratio = settings.get("additional_inset_ratio", 0.0)

			_effects[effect_id].set_z_index(i)

	_update_effect_draw_rects()
	_run_pipeline()

func _update_effect_settings_only() -> void:
	if media_container and _context != "focus_card":
		media_container.border_inset_ratio = 0.0
		media_container.glass_inset_ratio = 0.0

	var config_map: Dictionary = {}
	for config in _effect_configs:
		if config is Dictionary:
			var id = config.get("effect_id", "")
			if id:
				config_map[id] = config

	for i in range(EFFECT_LAYER_ORDER.size()):
		var effect_id = EFFECT_LAYER_ORDER[i]
		if _effects.has(effect_id):
			var config = config_map.get(effect_id, {})
			var settings = config.get("settings", {})
			var effect = _effects[effect_id]
			effect.set_visible(true)
			effect.media_container = media_container
			effect.effect_stack = self
			effect.update_settings(settings)

			if _context != "focus_card":
				match effect_id:
					"border":
						if media_container:
							media_container.border_inset_ratio = settings.get("border_size", 0.0)
					"glass":
						if media_container:
							media_container.glass_inset_ratio = settings.get("additional_inset_ratio", 0.0)

			effect.set_z_index(i)

	_update_effect_draw_rects()
	_run_pipeline()

func update_draw_rects() -> void:
	_update_effect_draw_rects()

func _update_effect_draw_rects() -> void:
	if not media_container:
		return
	_ensure_stack_canvas_item()
	var base_rect = Rect2(Vector2.ZERO, media_container.size)
	for effect_id in _effects:
		var effect = _effects[effect_id]
		if not effect or not effect.is_visible():
			continue
		var draw_rect = _compute_effect_rect(effect_id, effect, base_rect)
		effect.set_parent_rid(_stack_canvas_item)
		effect.set_offset_rect(draw_rect)

func _compute_effect_rect(effect_id: String, effect: EffectBase, base_rect: Rect2) -> Rect2:
	match effect_id:
		"glow", "drop_shadow":
			if effect.has_method("get_draw_rect"):
				return effect.get_draw_rect()
			return base_rect
		_:
			return base_rect

func _run_pipeline() -> void:
	if not media_container:
		return
	var layers: Array = []
	for effect_id in EFFECT_LAYER_ORDER:
		if effect_id in _effects and _effects[effect_id].is_visible():
			layers.append(_effects[effect_id])
	media_container.run_pipeline(layers)
	for effect_id in _effects:
		var effect = _effects[effect_id]
		if effect and effect.is_visible():
			effect._update_shader_params()

static var _script_cache: Dictionary[String, Script] = {}

func get_effects() -> Array:
	var result: Array = []
	for effect_id in EFFECT_LAYER_ORDER:
		if _effects.has(effect_id):
			result.append(_effects[effect_id])
	return result

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
		return null

	return effect

func get_effect(effect_id: String) -> EffectBase:
	return _effects.get(effect_id, null)

func has_effect(effect_id: String) -> bool:
	return _effects.has(effect_id) and _effects[effect_id].is_visible()

static func clear_script_cache() -> void:
	_script_cache.clear()
	EffectBase.clear_shared_caches()

func force_refresh() -> void:
	_update_effect_draw_rects()
	_run_pipeline()

func _clone_effect_configs(configs: Array) -> Array:
	var result: Array = []
	for config in configs:
		if config is Dictionary:
			var clone = {"effect_id": config.get("effect_id", "")}
			var settings = config.get("settings", {})
			if settings is Dictionary:
				clone["settings"] = settings.duplicate()
			result.append(clone)
	return result
