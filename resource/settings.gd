# settings.gd
extends Resource
class_name Settings
const State = SettingsVar.SettingState
const Type = SettingsVar.SettingType
# DEFAULTS....................................................................

@export_group("Settings")
@export_subgroup("Audio")
@export var dblevel_music := SettingsVar.new(Type.FLOAT,1.0,State.ENABLED,"Music Level")
@export var dblevel_sfx := SettingsVar.new(Type.FLOAT,1.0,State.ENABLED,"SFX Level")

@export_subgroup("Display")
@export var windowed := SettingsVar.new(Type.BOOL,true,State.ENABLED,"Windowed")
@export var resolutions: Array = [
	Vector2i(2560,1080),
	Vector2i(1920,1080),
	Vector2i(1366,768),
	Vector2i(1536,864),
	Vector2i(1280,720),
	Vector2i(1440,900),
	Vector2i(1600,900),
	Vector2i(1024,600),
	Vector2i(800,600)
]
@export var resolution := SettingsVar.new(Type.ARRAY,resolutions[0],State.ENABLED, "Windowed Resolution:", "", 0.0, 1.0, 0.1, resolutions)

@export_subgroup("RomM Connection")
@export var romm_url := SettingsVar.new(Type.STRING, "", State.ENABLED, "RomM URL")
@export var romm_username := SettingsVar.new(Type.STRING, "", State.ENABLED, "Username")
@export var romm_password := SettingsVar.new(Type.STRING, "", State.ENABLED, "Password", "", 0.0, 1.0, 0.1, [], true)
@export_subgroup("Storage")
@export var games_root_folder := SettingsVar.new(Type.PATH, "", State.ENABLED, "Games Folder")

# Internal platform sync settings (not displayed in auto-generated menu)
@export var enabled_platforms := SettingsVar.new(Type.DICTIONARY, {}, State.INTERNAL, "Enabled Platforms")

# Internal card effect configuration (managed by Card Designer)
@export var card_effect_config := SettingsVar.new(Type.DICTIONARY, {
	"effects": [],
	"card_orientation": 0,
	"corner_radius": 12.0
}, State.INTERNAL, "Card Effect Configuration")

@export_subgroup("Library Appearance")
@export var library_background_color := SettingsVar.new(Type.COLOR, Color(0.1, 0.1, 0.1, 1.0), State.ENABLED, "Background Color")
@export var library_vertical_layout := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Vertical Layout")
@export var library_bottom_bar_position := SettingsVar.new(Type.ARRAY, 0, State.ENABLED, "Bottom Bar Position", "Position of the navigation bar on screen", 0.0, 3.0, 1.0, ["bottom", "top", "left", "right"])
