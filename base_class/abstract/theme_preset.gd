# theme_preset.gd
# Resource class for storing theme presets that combine library and card settings
extends Resource
class_name ThemePreset

const CURRENT_VERSION: int = 4

@export var name: String = ""
@export var description: String = ""
@export var created_at: String = ""
@export var version: int = CURRENT_VERSION

## v4 format: { setting_name: value } for every SettingsVar flagged
## include_in_preset in settings.gd. Missing keys apply as defaults.
@export var values: Dictionary = {}

## Builds a v4 preset from a Settings resource: captures every setting flagged
## include_in_preset, deep-copies values, and strips regenerable light/dark
## effect variants (only authored overrides are stored).
static func build_from_settings(source: Settings) -> ThemePreset:
	var preset := ThemePreset.new()
	preset.name = "New Preset"
	preset.description = ""
	preset.created_at = Time.get_datetime_string_from_system()
	preset.version = CURRENT_VERSION
	if source == null:
		return preset
	for prop in source.get_property_list():
		var s = source.get(prop.name)
		if s is SettingsVar and s.include_in_preset:
			preset.values[prop.name] = deep_dup_value(s.value)
	for key in ["card_effect_config", "hero_effect_config"]:
		if preset.values.has(key) and preset.values[key] is Dictionary:
			preset.values[key] = EffectThemeAdapter.strip_generated_from_config(preset.values[key])
	if preset.values.has("library_background_config") and preset.values["library_background_config"] is Dictionary:
		preset.values["library_background_config"] = EffectThemeAdapter.strip_generated_from_config(
			LibraryBackground.normalize_config(preset.values["library_background_config"]))
	return preset

static func deep_dup_value(v: Variant) -> Variant:
	if v is Dictionary or v is Array:
		return v.duplicate(true)
	if v is Resource:
		# Dictionary.duplicate(true) does not deep-copy nested Resources
		# (e.g. Gradients) — without this the preset would alias live settings.
		return v.duplicate()
	return v

## Creates a ThemePreset from current settings.
## DEPRECATED: Use DataManager.create_preset_from_current() instead.
## Kept for backwards compatibility with existing saved resources/tests.
static func from_current_settings(settings: Settings) -> ThemePreset:
	return build_from_settings(settings)

## Returns a display name for the preset
func get_display_name() -> String:
	if name.is_empty():
		return "Unnamed Preset"
	return name
