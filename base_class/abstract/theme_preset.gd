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
@export var library_navigation_type: int = 0
@export var library_grid_padding: int = 10
@export var library_card_zoom: float = 1.0
@export var library_show_title_mode: int = 2
@export var library_card_display_mode: int = 0
@export var library_focus_scale: float = 0.08
@export var library_card_content_alignment: int = 0
@export var library_grid_vertical: bool = false
@export var card_media_aspect_ratio: int = 0
@export var library_background_config: Dictionary = {}
@export var library_primary_color: Color = Color("#6750A4")
@export var dark_mode: bool = false

# Card Designer Settings
@export var card_effect_config: Dictionary = {
	"effects": [],
	"card_orientation": 0,
	"card_rounding": 0.12
}

## Creates a ThemePreset from current settings
static func from_current_settings(settings: Settings) -> ThemePreset:
	var preset = ThemePreset.new()
	preset.name = "New Preset"
	preset.description = ""
	preset.created_at = Time.get_datetime_string_from_system()
	preset.version = 2
	
	# Library settings
	preset.library_layout_mode = settings.library_layout_mode.value if settings.library_layout_mode else 0
	preset.library_navigation_type = settings.library_navigation_type.value if settings.library_navigation_type else 0
	preset.library_grid_padding = settings.library_grid_padding.value if settings.library_grid_padding else 10
	preset.library_card_zoom = settings.library_card_zoom.value if settings.library_card_zoom else 1.0
	preset.library_show_title_mode = settings.library_show_title_mode.value if settings.library_show_title_mode else 2
	preset.library_card_display_mode = settings.library_card_display_mode.value if settings.library_card_display_mode else 0
	preset.library_focus_scale = settings.library_focus_scale.value if settings.library_focus_scale else 0.08
	preset.library_card_content_alignment = settings.library_card_content_alignment.value if settings.library_card_content_alignment else 0
	preset.library_grid_vertical = settings.library_grid_vertical.value if settings.library_grid_vertical else false
	preset.card_media_aspect_ratio = settings.card_media_aspect_ratio.value if settings.card_media_aspect_ratio else 0
	preset.library_background_config = settings.library_background_config.value.duplicate(true) if settings.library_background_config else {}
	preset.library_primary_color = settings.library_primary_color.value if settings.library_primary_color else Color("#6750A4")
	preset.dark_mode = settings.dark_mode.value if settings.dark_mode else false
	
	# Card settings
	preset.card_effect_config = settings.card_effect_config.value.duplicate(true) if settings.card_effect_config else {
		"effects": [],
		"card_orientation": 0,
		"card_rounding": 0.12
	}
	
	return preset

## Applies this preset to the given settings object
## Returns true if successful
func apply_to_settings(settings: Settings) -> bool:
	if settings == null:
		push_error("[ThemePreset] Cannot apply to null settings")
		return false
	
	# Apply library settings (with null checks)
	if settings.get("library_layout_mode") != null:
		settings.library_layout_mode.value = library_layout_mode
	if settings.get("library_navigation_type") != null:
		settings.library_navigation_type.value = library_navigation_type
	if settings.get("library_grid_padding") != null:
		settings.library_grid_padding.value = library_grid_padding
	if settings.get("library_card_zoom") != null:
		settings.library_card_zoom.value = library_card_zoom
	if settings.get("library_show_title_mode") != null:
		settings.library_show_title_mode.value = library_show_title_mode
	if settings.get("library_card_display_mode") != null:
		settings.library_card_display_mode.value = library_card_display_mode
	if settings.get("library_focus_scale") != null:
		settings.library_focus_scale.value = library_focus_scale
	if settings.get("library_card_content_alignment") != null:
		settings.library_card_content_alignment.value = library_card_content_alignment
	# Version 2 fields: only apply if preset was saved with these fields
	if version >= 2:
		if settings.get("library_grid_vertical") != null:
			settings.library_grid_vertical.value = library_grid_vertical
		if settings.get("card_media_aspect_ratio") != null:
			settings.card_media_aspect_ratio.value = card_media_aspect_ratio
	if settings.get("library_background_config") != null:
		settings.library_background_config.value = library_background_config.duplicate(true)
	if settings.get("library_primary_color") != null:
		settings.library_primary_color.value = library_primary_color
	if settings.get("dark_mode") != null:
		settings.dark_mode.value = dark_mode
	
	# Apply card settings
	if settings.get("card_effect_config") != null:
		settings.card_effect_config.value = card_effect_config.duplicate(true)
	
	return true

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

## Returns a display name for the preset
func get_display_name() -> String:
	if name.is_empty():
		return "Unnamed Preset"
	return name
