class_name ShaderSchemaGenerator

## Generates a SettingsVar schema from a custom effect shader's uniforms via
## introspection (Shader.get_shader_uniform_list). Each non-reserved uniform
## becomes a user-facing settings control; an optional sidecar dictionary
## overrides display names, descriptions, ranges, defaults, and visibility.
##
## Uniform default resolution order (per uniform):
##   1. sidecar uniforms.<name>.default
##   2. the uniform list's own default_value (engine-provided when available)
##   3. the `= <expr>` initializer parsed from the shader source
##   4. a type-appropriate zero value

## Uniforms the generic custom-effect layers feed themselves. Never exposed
## as user controls.
const RESERVED_UNIFORMS: Array[String] = [
	"game_texture",
	"card_size",
	"corner_radius_ratio",
	"corner_radius_pixels",
	"screen_size",
	"alpha",
	"display_mode",
	"quality_scale",
]

## Names with this prefix are reserved for future engine-provided uniforms.
const RESERVED_PREFIX := "kyo_"

static func generate(shader: Shader, source: String, sidecar: Dictionary) -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	if shader == null:
		return schema
	var overrides: Dictionary = sidecar.get("uniforms", {})
	if not overrides is Dictionary:
		overrides = {}
	for uniform in shader.get_shader_uniform_list():
		var uname: String = uniform.get("name", "")
		if uname == "" or uname in RESERVED_UNIFORMS or uname.begins_with(RESERVED_PREFIX):
			continue
		var entry: Dictionary = overrides.get(uname, {})
		if not entry is Dictionary:
			entry = {}
		if entry.get("hidden", false):
			continue
		var sv := _map_uniform(uniform, source, entry)
		if sv:
			schema.append(sv)
	return schema

static func _map_uniform(uniform: Dictionary, source: String, entry: Dictionary) -> SettingsVar:
	var uname: String = uniform.get("name", "")
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState
	var hint: int = uniform.get("hint", PROPERTY_HINT_NONE)
	var hint_string: String = uniform.get("hint_string", "")
	var vartype: int = uniform.get("type", TYPE_NIL)

	var sv: SettingsVar = null
	match vartype:
		TYPE_FLOAT:
			sv = _make_number(uniform, source, entry, Type.FLOAT)
		TYPE_INT:
			sv = _make_number(uniform, source, entry, Type.INT)
		TYPE_BOOL:
			var default_val: Variant = _default_for(uniform, source, entry, "bool")
			sv = SettingsVar.new(Type.BOOL, default_val if default_val != null else false, State.ENABLED, "", "")
		TYPE_VECTOR2:
			var default_val: Variant = _default_for(uniform, source, entry, "vec2")
			sv = SettingsVar.new(Type.VECTOR2, default_val if default_val != null else Vector2.ZERO, State.ENABLED, "", "")
		TYPE_COLOR:
			var default_val: Variant = _default_for(uniform, source, entry, "color")
			sv = SettingsVar.new(Type.COLOR, default_val if default_val != null else Color.WHITE, State.ENABLED, "", "")
		TYPE_VECTOR3, TYPE_VECTOR4:
			# Only expose vec3/vec4 uniforms annotated as colors; there is no
			# plain VECTOR3/VECTOR4 settings control.
			if hint == PROPERTY_HINT_COLOR_NO_ALPHA:
				var default_val: Variant = _default_for(uniform, source, entry, "color")
				sv = SettingsVar.new(Type.COLOR, default_val if default_val != null else Color.WHITE, State.ENABLED, "", "")
			else:
				return null
		TYPE_OBJECT:
			# sampler2D and friends: not user-controllable in v1.
			return null
		_:
			return null

	if sv == null:
		return null

	sv.property_name = uname
	sv.display_name = str(entry.get("display_name", uname.replace("_", " ").capitalize()))
	sv.description = str(entry.get("description", ""))
	if hint == PROPERTY_HINT_RANGE:
		var range_parts := hint_string.split(",")
		if range_parts.size() >= 2 and not entry.has("min"):
			sv.min_value = range_parts[0].to_float()
			sv.max_value = range_parts[1].to_float()
		if range_parts.size() >= 3 and not entry.has("step"):
			sv.step = range_parts[2].to_float()
	return sv

static func _make_number(uniform: Dictionary, source: String, entry: Dictionary, type: SettingsVar.SettingType) -> SettingsVar:
	var State = SettingsVar.SettingState
	var kind := "int" if type == SettingsVar.SettingType.INT else "float"
	var default_val = _default_for(uniform, source, entry, kind)
	if default_val == null:
		if type == SettingsVar.SettingType.INT:
			default_val = 0
		else:
			default_val = 0.0
	var sv = SettingsVar.new(type, default_val, State.ENABLED, "", "", 0.0, 1.0, 0.01 if type == SettingsVar.SettingType.FLOAT else 1.0)
	sv.min_value = float(entry.get("min", sv.min_value))
	sv.max_value = float(entry.get("max", sv.max_value))
	sv.step = float(entry.get("step", sv.step))
	return sv

## Resolves a uniform's default value. kind: "float", "int", "bool", "vec2",
## "color". Returns null when no default could be determined.
static func _default_for(uniform: Dictionary, source: String, entry: Dictionary, kind: String) -> Variant:
	if entry.has("default"):
		var coerced = _coerce_sidecar_default(entry["default"], kind)
		if coerced != null:
			return coerced
	if uniform.has("default_value"):
		var engine_val: Variant = uniform["default_value"]
		if _engine_default_usable(engine_val, kind):
			return engine_val
	var expr := _parse_initializer(source, uniform.get("name", ""))
	if expr != "":
		return _parse_expr(expr, kind)
	return null

static func _engine_default_usable(value: Variant, kind: String) -> bool:
	match kind:
		"float":
			return value is float or value is int
		"int":
			return value is int or value is float
		"bool":
			return value is bool
		"vec2":
			return value is Vector2
		"color":
			return value is Color or value is Vector3 or value is Vector4
	return false

static func _coerce_sidecar_default(value: Variant, kind: String) -> Variant:
	match kind:
		"float":
			if value is float or value is int:
				return float(value)
			if value is String and value.is_valid_float():
				return value.to_float()
		"int":
			if value is float or value is int:
				return int(value)
			if value is String and value.is_valid_int():
				return value.to_int()
		"bool":
			if value is bool:
				return value
		"vec2":
			if value is Vector2:
				return value
			if value is Array and value.size() == 2:
				return Vector2(float(value[0]), float(value[1]))
		"color":
			if value is Color:
				return value
			if value is String and Color.html_is_valid(value):
				return Color.html(value)
			if value is Array and (value.size() == 3 or value.size() == 4):
				return Color(float(value[0]), float(value[1]), float(value[2]), float(value[3]) if value.size() == 4 else 1.0)
	return null

## Extracts the initializer expression of
## `uniform <type> <name> [: hint] = <expr>;` from shader source. Returns ""
## when the uniform has no initializer.
static func _parse_initializer(source: String, uname: String) -> String:
	if uname == "":
		return ""
	var re := RegEx.new()
	if re.compile("uniform\\s+\\w+\\s+" + uname + "(?:\\s*:\\s*[^=;]+?)?\\s*=\\s*([^;]+);") != OK:
		return ""
	var m := re.search(source)
	return m.get_string(1).strip_edges() if m else ""

static func _parse_expr(expr: String, kind: String) -> Variant:
	match kind:
		"float":
			if expr.is_valid_float():
				return expr.to_float()
		"int":
			if expr.is_valid_int():
				return expr.to_int()
		"bool":
			if expr == "true":
				return true
			if expr == "false":
				return false
		"vec2":
			var components := _parse_constructor(expr, "vec2", 2)
			if components.size() == 2:
				return Vector2(components[0], components[1])
		"color":
			var components := _parse_constructor(expr, "vec4", 4)
			if components.size() == 4:
				return Color(components[0], components[1], components[2], components[3])
			components = _parse_constructor(expr, "vec3", 3)
			if components.size() == 3:
				return Color(components[0], components[1], components[2])
	return null

## Parses `name(a, b, ...)` constructor syntax into a float array. Returns []
## when the expression doesn't match the expected constructor/arity.
static func _parse_constructor(expr: String, constructor: String, arity: int) -> Array[float]:
	var prefix := constructor + "("
	if not expr.begins_with(prefix) or not expr.ends_with(")"):
		return []
	var inner := expr.substr(prefix.length(), expr.length() - prefix.length() - 1)
	var parts := inner.split(",")
	if parts.size() != arity:
		return []
	var out: Array[float] = []
	for part in parts:
		var trimmed := part.strip_edges()
		if not trimmed.is_valid_float():
			return []
		out.append(trimmed.to_float())
	return out
