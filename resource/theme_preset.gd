# theme_preset.gd
# Resource class for storing theme presets that combine library and card settings
extends Resource
class_name ThemePreset

@export var name: String = ""
@export var description: String = ""
@export var created_at: String = ""
@export var version: int = 1  # For backwards compatibility

# Library Appearance Settings
@export var library_hide_hero_image: bool = false
@export var library_vertical_layout: bool = true
@export var library_bottom_bar_position: int = 0
@export var library_grid_padding: int = 10
@export var library_grid_margin_x: int = 20
@export var library_grid_margin_y: int = 20
@export var library_card_zoom: float = 1.0
@export var library_bar_color: Color = Color(0.1, 0.1, 0.1, 1.0)
@export var library_icon_color: Color = Color(0.8, 0.8, 0.8, 1.0)
@export var library_background_config: Dictionary = {}

# Card Designer Settings
@export var card_effect_config: Dictionary = {
	"effects": [],
	"card_orientation": 0,
	"corner_radius": 0.06
}

## Creates a ThemePreset from current settings
static func from_current_settings(settings: Settings) -> ThemePreset:
	var preset = ThemePreset.new()
	preset.name = "New Preset"
	preset.description = ""
	preset.created_at = Time.get_datetime_string_from_system()
	preset.version = 1
	
	# Library settings
	preset.library_hide_hero_image = settings.library_hide_hero_image.value if settings.library_hide_hero_image else false
	preset.library_vertical_layout = settings.library_vertical_layout.value if settings.library_vertical_layout else true
	preset.library_bottom_bar_position = settings.library_bottom_bar_position.value if settings.library_bottom_bar_position else 0
	preset.library_grid_padding = settings.library_grid_padding.value if settings.library_grid_padding else 10
	preset.library_grid_margin_x = settings.library_grid_margin_x.value if settings.library_grid_margin_x else 20
	preset.library_grid_margin_y = settings.library_grid_margin_y.value if settings.library_grid_margin_y else 20
	preset.library_card_zoom = settings.library_card_zoom.value if settings.library_card_zoom else 1.0
	preset.library_bar_color = settings.library_bar_color.value if settings.library_bar_color else Color(0.1, 0.1, 0.1, 1.0)
	preset.library_icon_color = settings.library_icon_color.value if settings.library_icon_color else Color(0.8, 0.8, 0.8, 1.0)
	preset.library_background_config = settings.library_background_config.value.duplicate() if settings.library_background_config else {}
	
	# Card settings
	preset.card_effect_config = settings.card_effect_config.value.duplicate() if settings.card_effect_config else {
		"effects": [],
		"card_orientation": 0,
		"corner_radius": 0.06
	}
	
	return preset

## Applies this preset to the given settings object
## Returns true if successful
func apply_to_settings(settings: Settings) -> bool:
	if settings == null:
		push_error("[ThemePreset] Cannot apply to null settings")
		return false
	
	# Apply library settings (with null checks)
	if settings.get("library_hide_hero_image") != null:
		settings.library_hide_hero_image.value = library_hide_hero_image
	if settings.get("library_vertical_layout") != null:
		settings.library_vertical_layout.value = library_vertical_layout
	if settings.get("library_bottom_bar_position") != null:
		settings.library_bottom_bar_position.value = library_bottom_bar_position
	if settings.get("library_grid_padding") != null:
		settings.library_grid_padding.value = library_grid_padding
	if settings.get("library_grid_margin_x") != null:
		settings.library_grid_margin_x.value = library_grid_margin_x
	if settings.get("library_grid_margin_y") != null:
		settings.library_grid_margin_y.value = library_grid_margin_y
	if settings.get("library_card_zoom") != null:
		settings.library_card_zoom.value = library_card_zoom
	if settings.get("library_bar_color") != null:
		settings.library_bar_color.value = library_bar_color
	if settings.get("library_icon_color") != null:
		settings.library_icon_color.value = library_icon_color
	if settings.get("library_background_config") != null:
		settings.library_background_config.value = library_background_config.duplicate()
	
	# Apply card settings
	if settings.get("card_effect_config") != null:
		settings.card_effect_config.value = card_effect_config.duplicate()
	
	return true

## Merges missing settings from another preset (for defaults/updates)
func merge_with_defaults(default_preset: ThemePreset) -> void:
	# Only copy values that we don't have (for backwards compatibility)
	# Library settings
	if library_background_config.is_empty() and not default_preset.library_background_config.is_empty():
		library_background_config = default_preset.library_background_config.duplicate()
	
	# Card settings
	if card_effect_config.is_empty() or card_effect_config.get("effects", []).is_empty():
		if not default_preset.card_effect_config.is_empty():
			card_effect_config = default_preset.card_effect_config.duplicate()

## Returns a display name for the preset
func get_display_name() -> String:
	if name.is_empty():
		return "Unnamed Preset"
	return name
