class_name EffectThemeAdapter
extends RefCounted

## Converts effect settings between dark and light variants when dark_mode
## toggles: each entry keeps its canonical "settings" for the active mode and
## caches the generated counterpart as light_settings / dark_settings.
##
## Effects opt out with `static func is_theme_adaptive() -> false` on their
## script (declared on EffectBase, overridden per effect — currently shine).
## Locked entries keep identical settings in both modes, never gain mode
## caches, and have any existing ones erased on swap and on preset save.
## Unknown ids (custom shader effects) and id-less holders (the background
## base gradient) remain adaptive.

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

## True when the entry's effect declares is_theme_adaptive() == false: its
## settings are mode-invariant and must never be converted or cached per mode.
static func is_theme_locked(holder: Dictionary) -> bool:
	var effect_id: String = holder.get("effect_id", "")
	if effect_id == "":
		return false
	var script := _effect_script(effect_id)
	if script == null or not script.has_method("is_theme_adaptive"):
		return false
	return not script.call("is_theme_adaptive")

static func _effect_script(effect_id: String) -> Script:
	for registry in [EffectStack.EFFECT_REGISTRY, LibraryBackground.EFFECT_REGISTRY, LibraryBackground.OVERLAY_REGISTRY]:
		var path: String = registry.get(effect_id, "")
		if path != "":
			var script = load(path)
			return script if script is Script else null
	return null

static func swap_settings_mode(holder: Dictionary, to_dark: bool) -> Dictionary:
	var out := holder.duplicate(true)
	if is_theme_locked(out):
		# Mode-invariant: the canonical settings apply to both modes. Never
		# generate per-mode variants, and drop any already present (including
		# ones generated before the effect was declared locked).
		out.erase(LIGHT_CACHE_KEY)
		out.erase(DARK_CACHE_KEY)
		return out
	var settings: Dictionary = holder.get("settings", {})
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
	for list_key in ["effects", "focus_effects", "overlays"]:
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

# Layered background configs keep their base gradient in a settings-holder
# shaped like an effect entry, so swap_settings_mode applies directly.
static func swap_background_config(config: Dictionary, to_dark: bool) -> Dictionary:
	var out := swap_effect_list(config, to_dark)
	if out.has("base") and out["base"] is Dictionary:
		out["base"] = swap_settings_mode(out["base"], to_dark)
	return out

static func on_dark_mode_changed(to_dark: bool) -> void:
	if not DataManager:
		return
	var bg = DataManager.get_setting("library_background_config")
	if bg and bg.value is Dictionary:
		DataManager.set_setting(swap_background_config(LibraryBackground.normalize_config(bg.value), to_dark), bg)
	var card = DataManager.get_setting("card_effect_config")
	if card and card.value is Dictionary:
		DataManager.set_setting(swap_effect_list(card.value, to_dark), card)
	var hero = DataManager.get_setting("hero_effect_config")
	if hero and hero.value is Dictionary:
		DataManager.set_setting(swap_effect_list(hero.value, to_dark), hero)

# ============================================================================
# Preset save-time stripping
# Only authored light/dark variants belong in theme files. A cached variant
# that matches either the canonical settings or the deterministic conversion
# of them is regenerated on demand by swap_settings_mode(), so it is stripped.
# The canonical "settings" block (the mode active at save time) is never
# converted or removed. Locked effects (is_theme_adaptive() == false)
# contribute no variants at all: both keys are dropped unconditionally.
# ============================================================================

static func strip_generated_from_config(config: Dictionary) -> Dictionary:
	var out := config.duplicate(true)
	for list_key in ["effects", "focus_effects", "overlays"]:
		if not out.has(list_key) or not out[list_key] is Array:
			continue
		var new_list: Array = []
		for entry in out[list_key]:
			if entry is Dictionary:
				new_list.append(strip_generated_variants(entry))
			else:
				new_list.append(entry)
		out[list_key] = new_list
	if out.has("base") and out["base"] is Dictionary:
		out["base"] = strip_generated_variants(out["base"])
	return out

static func strip_generated_variants(holder: Dictionary) -> Dictionary:
	var out := holder.duplicate(true)
	if is_theme_locked(out):
		# Locked entries carry no mode variants at all.
		out.erase(LIGHT_CACHE_KEY)
		out.erase(DARK_CACHE_KEY)
		return out
	var settings: Dictionary = out.get("settings", {})
	for key in [LIGHT_CACHE_KEY, DARK_CACHE_KEY]:
		if not out.has(key) or not out[key] is Dictionary:
			continue
		var cached: Dictionary = out[key]
		# Round-trip swaps can leave a duplicate of the canonical settings
		# under the active mode's own cache key.
		if values_equal_approx(cached, settings):
			out.erase(key)
			continue
		var generated := adapt_settings_dict(settings, key == DARK_CACHE_KEY)
		if values_equal_approx(cached, generated):
			out.erase(key)
	return out

static func values_equal_approx(a: Variant, b: Variant) -> bool:
	if a is Color and b is Color:
		return a.is_equal_approx(b)
	if a is Gradient and b is Gradient:
		if a.get_point_count() != b.get_point_count():
			return false
		for i in a.get_point_count():
			if not is_equal_approx(a.get_offset(i), b.get_offset(i)):
				return false
			if not a.get_color(i).is_equal_approx(b.get_color(i)):
				return false
		return true
	if a is Dictionary and b is Dictionary:
		if a.size() != b.size():
			return false
		for k in a:
			if not b.has(k) or not values_equal_approx(a[k], b[k]):
				return false
		return true
	if a is Array and b is Array:
		if a.size() != b.size():
			return false
		for i in a.size():
			if not values_equal_approx(a[i], b[i]):
				return false
		return true
	if (a is float or a is int) and (b is float or b is int):
		return is_equal_approx(float(a), float(b))
	return a == b

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
