class_name EffectThemeAdapter
extends RefCounted

const LIGHT_CACHE_KEY := "light_settings"
const DARK_CACHE_KEY := "dark_settings"

const DARK_LIGHTNESS_SCALE := 0.25
const LIGHT_LIGHTNESS_SCALE := 0.15
const GAMUT_SEARCH_STEPS := 8

static func adapt_color(c: Color, to_dark: bool) -> Color:
	var lab := _srgb_to_oklab(c)
	var l: float = lab.x
	var chroma := sqrt(lab.y * lab.y + lab.z * lab.z)
	var hue := atan2(lab.z, lab.y)
	if to_dark:
		l *= DARK_LIGHTNESS_SCALE
	else:
		l = 1.0 - (1.0 - l) * LIGHT_LIGHTNESS_SCALE
	var rgb := _oklch_to_srgb(l, chroma, hue)
	return Color(rgb.x, rgb.y, rgb.z, c.a)

static func adapt_gradient(g: Gradient, to_dark: bool) -> Gradient:
	var out: Gradient = g.duplicate()
	for i in out.get_point_count():
		out.set_color(i, adapt_color(out.get_color(i), to_dark))
	return out

static func adapt_value(value: Variant, to_dark: bool) -> Variant:
	if value is Color:
		return adapt_color(value, to_dark)
	if value is Gradient:
		return adapt_gradient(value, to_dark)
	if value is Dictionary:
		return adapt_settings_dict(value, to_dark)
	if value is Array:
		var out: Array = []
		for item in value:
			out.append(adapt_value(item, to_dark))
		return out
	return value

static func adapt_settings_dict(d: Dictionary, to_dark: bool) -> Dictionary:
	var out := d.duplicate(true)
	for key in out:
		out[key] = adapt_value(out[key], to_dark)
	return out

static func swap_settings_mode(holder: Dictionary, to_dark: bool) -> Dictionary:
	var settings: Dictionary = holder.get("settings", {})
	var out := holder.duplicate(true)
	var prev_key := LIGHT_CACHE_KEY if to_dark else DARK_CACHE_KEY
	var next_key := DARK_CACHE_KEY if to_dark else LIGHT_CACHE_KEY
	out[prev_key] = settings.duplicate(true)
	if out.has(next_key):
		out["settings"] = out[next_key].duplicate(true)
	else:
		var generated := adapt_settings_dict(settings, to_dark)
		out[next_key] = generated.duplicate(true)
		out["settings"] = generated
	return out

static func swap_effect_list(config: Dictionary, to_dark: bool) -> Dictionary:
	var out := config.duplicate(true)
	for list_key in ["effects", "focus_effects"]:
		if not out.has(list_key) or not out[list_key] is Array:
			continue
		var new_list: Array = []
		for entry in out[list_key]:
			if entry is Dictionary:
				new_list.append(swap_settings_mode(entry, to_dark))
			else:
				new_list.append(entry)
		out[list_key] = new_list
	return out

static func on_dark_mode_changed(to_dark: bool) -> void:
	if not DataManager:
		return
	var bg = DataManager.get_setting("library_background_config")
	if bg and bg.value is Dictionary:
		DataManager.set_setting(swap_settings_mode(bg.value, to_dark), bg)
	var card = DataManager.get_setting("card_effect_config")
	if card and card.value is Dictionary:
		DataManager.set_setting(swap_effect_list(card.value, to_dark), card)
	var hero = DataManager.get_setting("hero_effect_config")
	if hero and hero.value is Dictionary:
		DataManager.set_setting(swap_effect_list(hero.value, to_dark), hero)

static func _cbrt(x: float) -> float:
	return signf(x) * pow(absf(x), 1.0 / 3.0)

static func _srgb_to_linear(x: float) -> float:
	if x <= 0.04045:
		return x / 12.92
	return pow((x + 0.055) / 1.055, 2.4)

static func _linear_to_srgb(x: float) -> float:
	if x <= 0.0031308:
		return x * 12.92
	return 1.055 * pow(x, 1.0 / 2.4) - 0.055

static func _srgb_to_oklab(c: Color) -> Vector3:
	var r := _srgb_to_linear(c.r)
	var g := _srgb_to_linear(c.g)
	var b := _srgb_to_linear(c.b)
	var l := _cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
	var m := _cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
	var s := _cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
	return Vector3(
		0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
		1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
		0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
	)

static func _oklab_to_linear_rgb(lab: Vector3) -> Vector3:
	var l := lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z
	var m := lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z
	var s := lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z
	l = l * l * l
	m = m * m * m
	s = s * s * s
	return Vector3(
		4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
		-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
		-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
	)

static func _oklch_to_srgb(l: float, chroma: float, hue: float) -> Vector3:
	var lo := 0.0
	var hi := chroma
	for i in GAMUT_SEARCH_STEPS:
		var c := (lo + hi) * 0.5
		var lab := Vector3(l, c * cos(hue), c * sin(hue))
		var rgb := _oklab_to_linear_rgb(lab)
		if rgb.x >= -0.001 and rgb.x <= 1.001 and rgb.y >= -0.001 and rgb.y <= 1.001 and rgb.z >= -0.001 and rgb.z <= 1.001:
			lo = c
		else:
			hi = c
	var lab := Vector3(l, lo * cos(hue), lo * sin(hue))
	var result := _oklab_to_linear_rgb(lab)
	return Vector3(
		clampf(_linear_to_srgb(result.x), 0.0, 1.0),
		clampf(_linear_to_srgb(result.y), 0.0, 1.0),
		clampf(_linear_to_srgb(result.z), 0.0, 1.0)
	)
