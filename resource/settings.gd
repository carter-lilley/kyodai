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
@export var dual_screen_mode := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Dual Screen Mode", "Automatically use second display for hero image when available")

@export_subgroup("RomM Connection")
@export var romm_url := SettingsVar.new(Type.STRING, "", State.ENABLED, "RomM URL")
@export var romm_username := SettingsVar.new(Type.STRING, "", State.ENABLED, "Username")
@export var romm_password := SettingsVar.new(Type.STRING, "", State.ENABLED, "Password", "", 0.0, 1.0, 0.1, [], true)
@export var fold_duplicate_covers := SettingsVar.new(Type.BOOL, false, State.ENABLED, "Fold duplicate covers into siblings", "During sync, games with identical cover art will be grouped together like RomM siblings")
@export_subgroup("Storage")
@export var games_root_folder := SettingsVar.new(Type.PATH, "", State.ENABLED, "Games Folder")
@export var emulators_folder := SettingsVar.new(Type.PATH, "user://emulators/", State.ENABLED, "Emulators Folder", "Directory where emulators are installed")
@export var steam_folder := SettingsVar.new(Type.PATH, "", State.ENABLED, "Steam Installation Folder", "Path to your Steam installation (e.g., C:\\Program Files (x86)\\Steam)")

# Internal GameNative games list (not displayed in settings menu)
@export var gamenative_games := SettingsVar.new(Type.ARRAY, [], State.INTERNAL, "GameNative Games")

# Internal platform sync settings (not displayed in auto-generated menu)
@export var enabled_platforms := SettingsVar.new(Type.DICTIONARY, {}, State.INTERNAL, "Enabled Platforms")

# Internal card effect configuration (managed by Card Designer)
@export var card_effect_config := SettingsVar.new(Type.DICTIONARY, {
	"effects": [],
	"card_orientation": 0,
	"corner_radius": 0.06
}, State.INTERNAL, "Card Effect Configuration")

# Internal hero effect configuration (managed by Hero Designer)
@export var hero_effect_config := SettingsVar.new(Type.DICTIONARY, {
	"effects": [],
	"corner_radius": 0.06
}, State.INTERNAL, "Hero Effect Configuration")

@export_subgroup("Library Appearance")
# General layout settings (always visible)
@export var library_hero_layout_height := SettingsVar.new(Type.ARRAY, 0, State.ENABLED, "Hero Height", "Height of hero image as percentage of viewport (0% = hidden)", 0.0, 4.0, 1.0, ["Full (100%)", "Two Thirds (66%)", "Half (50%)", "One Third (33%)", "Hidden (0%)"])
@export var library_vertical_layout := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Vertical Layout")
@export var library_navigation_bar_position := SettingsVar.new(Type.ARRAY, 0, State.ENABLED, "Navigation Bar Position", "Position of the navigation bar on screen", 0.0, 3.0, 1.0, ["bottom", "top", "left", "right"])
@export var library_grid_padding := SettingsVar.new(Type.INT, 10, State.ENABLED, "Grid Padding", "Space between game cards in pixels", 0.0, 50.0, 1.0)
@export var library_grid_margin_x := SettingsVar.new(Type.INT, 0, State.ENABLED, "Grid Margin X", "Left/right margin around the grid in pixels", 0.0, 600.0, 1.0)
@export var library_grid_margin_y := SettingsVar.new(Type.INT, 0, State.ENABLED, "Grid Margin Y", "Top/bottom margin around the grid in pixels", 0.0, 600.0, 1.0)
@export var library_card_zoom := SettingsVar.new(Type.FLOAT, 0.15, State.INTERNAL, "Card Zoom", "Card size as ratio of viewport", 0.05, 0.5, 0.01)
@export var library_bar_color := SettingsVar.new(Type.COLOR, Color(0.12, 0.12, 0.12, 0.95), State.ENABLED, "Bar Color", "Background color of the navigation bar")
@export var library_icon_color := SettingsVar.new(Type.COLOR, Color.WHITE, State.ENABLED, "Icon Color", "Color of navigation icons")
@export var library_show_title_on_all_cards := SettingsVar.new(Type.BOOL, false, State.ENABLED, "Show Titles on All Cards", "Display game titles below all cards (when off, only shows on focused card)")
@export var controls_bar_enabled := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Show Controls Bar", "Display the quick controls bar in game views")
@export var controls_bar_mode := SettingsVar.new(Type.ARRAY, 0, State.ENABLED, "Controls Bar Mode", "How the controls bar is displayed", 0.0, 1.0, 1.0, ["Floating", "Docked"])

# Internal background effect configuration (managed by Library Appearance settings)
@export var library_background_config := SettingsVar.new(Type.DICTIONARY, {
	"effect_id": "xmb",
	"settings": {
		"time_scale": 1.0,
		"show_dust": true,
		"wave_intensity": 1.0,
		"star_threshold": 0.99,
		"color_top_left": Color(0.7, 0.2, 0.2, 1.0),
		"color_top_right": Color(0.4, 0.1, 0.1, 1.0),
		"color_bottom_left": Color(0.45, 0.1, 0.1, 1.0),
		"color_bottom_right": Color(0.8, 0.3, 0.5, 1.0),
		"wave_blend_color": Color.WHITE
	}
}, State.INTERNAL, "Background Effect Configuration")
