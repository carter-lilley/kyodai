# settings_var.gd
extends Resource
class_name SettingsVar

## Represents a single setting entry with metadata for menus, validation, etc.

enum SettingType { FLOAT, INT, BOOL, STRING, PATH, CURVE, VECTOR2, ENUM, ARRAY, DICTIONARY, INPUTACTIONLIST, COLOR, GRADIENT, VECTOR2I, ANGLE }
enum SettingState { ENABLED, DISABLED, INTERNAL }

var property_name: String = ""
@export var type: SettingType = SettingType.FLOAT
@export var state: SettingState = SettingState.ENABLED
@export var value: Variant
@export var display_name: String
@export var description: String = ""

# Optional numeric constraints
@export var min_value: float = 0.0
@export var max_value: float = 1.0
@export var step: float = 0.1
# Optional for dropdowns or enum-style choices
@export var options: Array = []
@export var encrypted: bool = false
## When true, this setting is captured into theme presets (ThemePreset.values).
## Set at the declaration site in settings.gd via the _preset() wrapper.
@export var include_in_preset: bool = false
@export var metadata: Dictionary = {}

func _init(
	_type: SettingType = SettingType.FLOAT,
	_value: Variant = null,
	_state: SettingState = SettingState.ENABLED,
	_display_name: String = "",
	_description: String = "",
	_min_value: float = 0.0,
	_max_value: float = 1.0,
	_step: float = 0.1,
	_options: Array = [],
	_encrypted: bool = false,
	_metadata: Dictionary = {}
):
	self.type = _type
	self.value = _value
	self.state = _state
	self.display_name = _display_name
	self.description = _description
	self.min_value = _min_value
	self.max_value = _max_value
	self.step = _step
	self.options = _options
	self.encrypted = _encrypted
	self.metadata = _metadata
	
