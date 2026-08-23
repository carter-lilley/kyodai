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

# ============================================================================
# Legacy (v1-v3) typed fields — kept solely so existing .tres files still load.
# migrate_legacy() folds them into `values`. Do not write new code against these.
# ============================================================================
@export var library_layout_mode: int = 0
@export var library_navigation_type: int = 1
@export var library_grid_padding: int = 22
@export var library_card_zoom: float = 0.25
@export var library_card_zoom_level: int = -1
@export var library_show_title_mode: int = 0
@export var library_card_display_mode: int = 0
@export var library_focus_scale: float = 0.09
@export var library_card_content_alignment: int = 0
@export var library_grid_vertical: bool = true
@export var card_media_aspect_ratio: int = 0
@export var library_focus_centering: int = 0
@export var library_pagination_view: bool = false
@export var library_grid_staggered: bool = false
@export var library_background_config: Dictionary = {
	"effect_id": "none",
	"settings": {}
}
@export var library_primary_color: Color = Color.WHITE
@export var dark_mode: bool = true
@export var card_effect_config: Dictionary = {
	"card_orientation": 2,
	"card_rounding": 0.24,
	"effects": [{
		"effect_id": "drop_shadow",
		"settings": {
			"shadow_color": Color(0, 0, 0, 0.5),
			"shadow_expand": 0.066,
			"shadow_offset_x": 0.0,
			"shadow_offset_y": 0.043,
			"shadow_softness": 0.15,
			"shadow_spread": 0.0
		}
	}],
	"focus_effects": [{
		"effect_id": "glow",
		"settings": {
			"blur_amount": 6.5,
			"glow_intensity": 0.3,
			"glow_radius": 0.14,
			"glow_spread": 0.06,
			"threshold": 0.41
		}
	}],
	"hero_height": 4
}

const LEGACY_FIELDS: Array[String] = [
	"library_layout_mode", "library_navigation_type", "library_grid_padding",
	"library_card_zoom", "library_card_zoom_level", "library_show_title_mode",
	"library_card_display_mode", "library_focus_scale", "library_card_content_alignment",
	"library_grid_vertical", "card_media_aspect_ratio", "library_focus_centering",
	"library_pagination_view", "library_background_config", "library_primary_color",
	"library_grid_staggered", "dark_mode", "card_effect_config",
]

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

## Folds legacy typed fields into `values` for pre-v4 presets. Idempotent.
func migrate_legacy() -> void:
	if not values.is_empty():
		version = CURRENT_VERSION
		return
	for field in LEGACY_FIELDS:
		values[field] = deep_dup_value(get(field))
	version = CURRENT_VERSION

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
