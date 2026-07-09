# theme_preset.gd
# Resource class for storing theme presets that combine library and card settings
extends Resource
class_name ThemePreset

@export var name: String = ""
@export var description: String = ""
@export var created_at: String = ""
@export var version: int = 2  # For backwards compatibility

# Library Appearance Settings
@export var library_layout_mode: int = 0
@export var library_navigation_type: int = 1
@export var library_grid_padding: int = 22
@export var library_card_zoom: float = 0.25
@export var library_show_title_mode: int = 0
@export var library_card_display_mode: int = 0
@export var library_focus_scale: float = 0.09
@export var library_card_content_alignment: int = 0
@export var library_grid_vertical: bool = true
@export var card_media_aspect_ratio: int = 0
@export var library_background_config: Dictionary = {
	"effect_id": "none",
	"settings": {}
}
@export var library_primary_color: Color = Color.WHITE
@export var dark_mode: bool = true

# Card Designer Settings
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

## Creates a ThemePreset from current settings.
## DEPRECATED: Use DataManager.create_preset_from_current() instead.
## Kept for backwards compatibility with existing saved resources/tests.
static func from_current_settings(settings: Settings) -> ThemePreset:
	if settings == null:
		push_error("[ThemePreset] Cannot create preset from null settings")
		return null
	
	var preset = ThemePreset.new()
	preset.name = "New Preset"
	preset.description = ""
	preset.created_at = Time.get_datetime_string_from_system()
	preset.version = 2
	
	# Library settings
	preset.library_layout_mode = settings.library_layout_mode.value if settings.library_layout_mode else 0
	preset.library_navigation_type = settings.library_navigation_type.value if settings.library_navigation_type else 1
	preset.library_grid_padding = settings.library_grid_padding.value if settings.library_grid_padding else 22
	preset.library_card_zoom = settings.library_card_zoom.value if settings.library_card_zoom else 0.25
	preset.library_show_title_mode = settings.library_show_title_mode.value if settings.library_show_title_mode else 0
	preset.library_card_display_mode = settings.library_card_display_mode.value if settings.library_card_display_mode else 0
	preset.library_focus_scale = settings.library_focus_scale.value if settings.library_focus_scale else 0.09
	preset.library_card_content_alignment = settings.library_card_content_alignment.value if settings.library_card_content_alignment else 0
	preset.library_grid_vertical = settings.library_grid_vertical.value if settings.library_grid_vertical else true
	preset.card_media_aspect_ratio = settings.card_media_aspect_ratio.value if settings.card_media_aspect_ratio else 0
	preset.library_background_config = settings.library_background_config.value.duplicate(true) if settings.library_background_config else {
		"effect_id": "none",
		"settings": {}
	}
	preset.library_primary_color = settings.library_primary_color.value if settings.library_primary_color else Color.WHITE
	preset.dark_mode = settings.dark_mode.value if settings.dark_mode else true
	
	# Card settings
	preset.card_effect_config = settings.card_effect_config.value.duplicate(true) if settings.card_effect_config else {
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
	
	return preset

## Returns a display name for the preset
func get_display_name() -> String:
	if name.is_empty():
		return "Unnamed Preset"
	return name

## Merges missing settings from another preset (for defaults/updates)
func merge_with_defaults(default_preset: ThemePreset) -> void:
	# Only copy values that we don't have (for backwards compatibility)
	# Library settings
	if library_background_config.is_empty() and not default_preset.library_background_config.is_empty():
		library_background_config = default_preset.library_background_config.duplicate(true)
	
	# Version 2 fields: merge from defaults if this is an old preset
	if version < 2:
		library_grid_vertical = default_preset.library_grid_vertical
		card_media_aspect_ratio = default_preset.card_media_aspect_ratio
		version = 2
	
	# Card settings
	# Only merge if the entire config dict is empty, not if effects array is empty
	# (themes can intentionally have zero effects)
	if card_effect_config.is_empty():
		if not default_preset.card_effect_config.is_empty():
			card_effect_config = default_preset.card_effect_config.duplicate(true)
