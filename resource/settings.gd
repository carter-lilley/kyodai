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

@export_subgroup("Card Appearance")
@export var card_orientations: Array[String] = ["Vertical", "Horizontal", "Square"]
@export var card_orientation := SettingsVar.new(Type.ARRAY, card_orientations[0], State.ENABLED, "Card Orientation", "", 0.0, 1.0, 0.1, card_orientations)
@export var corner_radius := SettingsVar.new(Type.INT, 12, State.ENABLED, "Corner Radius", "", 0.0, 50.0, 1.0)
@export var border_enabled := SettingsVar.new(Type.BOOL, false, State.ENABLED, "Show Border")
@export var border_size := SettingsVar.new(Type.FLOAT, 0.05, State.ENABLED, "Border Size", "", 0.0, 0.5, 0.01)
@export var border_fade_in := SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Border Fade In", "", 0.0, 10.0, 0.1)
@export var border_fade_out := SettingsVar.new(Type.FLOAT, 0.0, State.ENABLED, "Border Fade Out", "", 0.0, 10.0, 0.1)
@export var border_color := SettingsVar.new(Type.COLOR, Color.WHITE, State.ENABLED, "Border Color")
@export var fluid_glass_enabled := SettingsVar.new(Type.BOOL, false, State.ENABLED, "Fluid Glass Effect")
@export var fluid_chromatic_shift := SettingsVar.new(Type.FLOAT, 0.2, State.ENABLED, "Fluid Glass Chromatic", "", 0.0, 1.0, 0.01)
@export var fluid_bend_amount := SettingsVar.new(Type.FLOAT, 0.4, State.ENABLED, "Fluid Glass Bend", "", 0.0, 1.0, 0.05)
@export var fluid_curve_light := SettingsVar.new(Type.FLOAT, 0.5, State.ENABLED, "Fluid Glass Curve Light", "", 0.0, 1.0, 0.05)
@export var fluid_rim_light := SettingsVar.new(Type.FLOAT, 0.8, State.ENABLED, "Fluid Glass Rim Light", "", 0.0, 1.0, 0.05)
@export var fluid_noise_amount := SettingsVar.new(Type.FLOAT, 0.05, State.ENABLED, "Fluid Glass Noise", "", 0.0, 1.0, 0.01)
@export var fluid_edge_falloff := SettingsVar.new(Type.FLOAT, 50.0, State.ENABLED, "Fluid Glass Edge Falloff", "", 10.0, 200.0, 5.0)
