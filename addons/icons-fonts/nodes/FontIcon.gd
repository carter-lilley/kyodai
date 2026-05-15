@tool
@icon("res://addons/icons-fonts/nodes/FontIcon.svg")

# todo add description and docs links when ready
class_name FontIcon
extends Label

@export var icon_settings := FontIconSettings.new()

func _ready():
	_on_icon_settings_changed()
	Utils.connect_if_possible(icon_settings.changed, _on_icon_settings_changed)

func _on_icon_settings_changed():
	if !label_settings: label_settings = LabelSettings.new()
	
	icon_settings.update_label_settings(label_settings)
	
	# Prevent text server errors when font hasn't loaded or size is 0
	if label_settings.font_size <= 0:
		label_settings.font_size = 1
	
	var icon_char = IconsFonts.get_icon_char(
		icon_settings.icon_font,
		icon_settings.icon_name
	)
	
	# Only set text if we have a valid character and font is ready
	if icon_char.is_empty() or label_settings.font == null:
		text = ""
	else:
		text = icon_char

func _validate_property(property : Dictionary) -> void:
	if property.name in [&"text", &"label_settings"]:
		property.usage &= ~PROPERTY_USAGE_EDITOR
