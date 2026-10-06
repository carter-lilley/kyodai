class_name EffectRegistry

## Runtime registry for card and background effects: the built-in registries
## (EffectStack.EFFECT_REGISTRY, LibraryBackground.EFFECT_REGISTRY) plus
## user-provided custom shaders scanned from user://effects/<kind>/.
##
## A custom effect is a single .gdshader file; an optional same-named .json
## sidecar overrides presentation (display_name, render_scale, per-uniform
## overrides). Custom effects may not shadow built-in ids — collisions are
## ignored with a warning.

const USER_EFFECTS_DIR := "user://effects/"
const CUSTOM_CARD_SCRIPT := preload("res://effects/shared/custom_card_effect.gd")
const CUSTOM_BACKGROUND_SCRIPT := preload("res://effects/background/custom_background_effect.gd")

# "card:<id>" / "background:<id>" -> descriptor
# {id, kind, shader, display_name, render_scale, schema}
static var _custom: Dictionary = {}
static var _scanned: bool = false
static var _script_cache: Dictionary = {}

static func ensure_scanned() -> void:
	if _scanned:
		return
	_scanned = true
	for kind in ["card", "background"]:
		# Create the directories so users can discover where to drop files.
		DirAccess.make_dir_recursive_absolute(USER_EFFECTS_DIR + kind + "/")
		_scan_kind(kind)

## Drops all custom registrations and script caches, then rescans. Live
## effects keep their already-compiled shaders until their stack rebuilds.
static func rescan() -> void:
	_custom.clear()
	_script_cache.clear()
	EffectBase.clear_shared_caches()
	_scanned = false
	ensure_scanned()

static func clear_script_cache() -> void:
	_script_cache.clear()

static func _scan_kind(kind: String) -> void:
	var dir_path := USER_EFFECTS_DIR + kind + "/"
	var dir := DirAccess.open(dir_path)
	if not dir:
		return
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".gdshader"):
			_register_custom(kind, dir_path + file_name, file_name.get_basename())
		file_name = dir.get_next()

static func _register_custom(kind: String, shader_path: String, id: String) -> void:
	if id == "":
		return
	if _is_builtin_id(kind, id):
		push_warning("[EffectRegistry] Custom %s effect '%s' collides with a built-in id; ignoring %s" % [kind, id, shader_path])
		return
	var key := kind + ":" + id
	if _custom.has(key):
		return

	var file := FileAccess.open(shader_path, FileAccess.READ)
	if not file:
		push_warning("[EffectRegistry] Cannot read custom effect shader: " + shader_path)
		return
	var source := file.get_as_text()
	file.close()

	# Both kinds render as 2D canvas items (card layers and ColorRect-hosted
	# background layers), so anything else cannot work.
	if not source.contains("shader_type") or not source.contains("canvas_item"):
		push_warning("[EffectRegistry] Custom effect shader %s must declare 'shader_type canvas_item'; ignoring" % shader_path)
		return

	var shader := Shader.new()
	shader.code = source

	var sidecar := _load_sidecar(shader_path.trim_suffix(".gdshader") + ".json")
	var schema := ShaderSchemaGenerator.generate(shader, source, sidecar)

	_custom[key] = {
		"id": id,
		"kind": kind,
		"shader": shader,
		"display_name": str(sidecar.get("display_name", id.replace("_", " ").capitalize())),
		"render_scale": clampf(float(sidecar.get("render_scale", 1.0)), 0.1, 1.0),
		"schema": schema,
	}
	print("[EffectRegistry] Registered custom %s effect '%s' (%d uniforms)" % [kind, id, schema.size()])

static func _load_sidecar(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if not file:
		return {}
	var json := JSON.new()
	var error := json.parse(file.get_as_text())
	file.close()
	if error != OK or not json.data is Dictionary:
		push_warning("[EffectRegistry] Invalid sidecar JSON (ignored): " + path)
		return {}
	return json.data

static func _is_builtin_id(kind: String, id: String) -> bool:
	if kind == "card":
		return EffectStack.EFFECT_REGISTRY.has(id)
	return LibraryBackground.EFFECT_REGISTRY.has(id) or LibraryBackground.OVERLAY_REGISTRY.has(id)

static func is_custom(effect_id: String) -> bool:
	ensure_scanned()
	return _custom.has("card:" + effect_id) or _custom.has("background:" + effect_id)

static func is_custom_kind(kind: String, effect_id: String) -> bool:
	ensure_scanned()
	return _custom.has(kind + ":" + effect_id)

static func card_effect_exists(effect_id: String) -> bool:
	ensure_scanned()
	return EffectStack.EFFECT_REGISTRY.has(effect_id) or _custom.has("card:" + effect_id)

static func background_effect_exists(effect_id: String) -> bool:
	ensure_scanned()
	return LibraryBackground.EFFECT_REGISTRY.has(effect_id) or _custom.has("background:" + effect_id)

## All custom descriptors of a kind, for designer discovery.
static func get_custom_descriptors(kind: String) -> Array:
	ensure_scanned()
	var out: Array = []
	for key in _custom.keys():
		if _custom[key].get("kind", "") == kind:
			out.append(_custom[key])
	return out

static func get_display_name(effect_id: String) -> String:
	ensure_scanned()
	for kind in ["card", "background"]:
		var d: Dictionary = _custom.get(kind + ":" + effect_id, {})
		if not d.is_empty():
			return d.get("display_name", effect_id)
	return LibraryBackground.EFFECT_DISPLAY_NAMES.get(effect_id, effect_id.replace("_", " ").capitalize())

static func get_schema(effect_id: String) -> Array[SettingsVar]:
	ensure_scanned()
	for kind in ["card", "background"]:
		var d: Dictionary = _custom.get(kind + ":" + effect_id, {})
		if not d.is_empty():
			var schema: Array[SettingsVar] = []
			schema.assign(d.get("schema", []))
			return schema
	return []

static func create_card_effect(effect_id: String) -> EffectBase:
	ensure_scanned()
	var d: Dictionary = _custom.get("card:" + effect_id, {})
	if not d.is_empty():
		var custom: CustomCardEffect = CUSTOM_CARD_SCRIPT.new()
		custom.setup(d)
		return custom
	var script := _load_script(EffectStack.EFFECT_REGISTRY.get(effect_id, ""))
	if not script:
		return null
	var effect = script.new()
	if not effect is EffectBase:
		push_error("[EffectRegistry] Effect script does not extend EffectBase: " + str(effect_id))
		return null
	return effect

static func create_background_effect(effect_id: String) -> BackgroundEffect:
	ensure_scanned()
	var d: Dictionary = _custom.get("background:" + effect_id, {})
	if not d.is_empty():
		var custom: CustomBackgroundEffect = CUSTOM_BACKGROUND_SCRIPT.new()
		custom.setup(d)
		return custom
	var script := _load_script(LibraryBackground.EFFECT_REGISTRY.get(effect_id, ""))
	if not script:
		return null
	var effect = script.new()
	if not effect is BackgroundEffect:
		push_error("[EffectRegistry] Effect script does not extend BackgroundEffect: " + str(effect_id))
		return null
	return effect

static func _load_script(script_path: String) -> Script:
	if script_path == "":
		return null
	var script: Script = _script_cache.get(script_path, null)
	if not script:
		script = load(script_path)
		if script:
			_script_cache[script_path] = script
	return script
