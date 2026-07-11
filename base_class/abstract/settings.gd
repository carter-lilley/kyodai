# settings.gd
extends Resource
class_name Settings
const State = SettingsVar.SettingState
const Type = SettingsVar.SettingType
# DEFAULTS....................................................................

@export_group("Settings")
@export_subgroup("Audio")
@export var dblevel_music := SettingsVar.new(Type.FLOAT, 100.0, State.ENABLED, "Music Level", "", 0.0, 100.0, 1.0, [], false, {"show_stops": false, "slider_size": "MEDIUM", "display_unit": "%"})
@export var dblevel_sfx := SettingsVar.new(Type.FLOAT, 100.0, State.ENABLED, "SFX Level", "", 0.0, 100.0, 1.0, [], false, {"show_stops": false, "slider_size": "MEDIUM", "display_unit": "%"})

@export_subgroup("Display")
@export var windowed := SettingsVar.new(Type.BOOL,true,State.ENABLED,"Windowed")
#@export var ui_scale := SettingsVar.new(Type.FLOAT, 1.5, State.ENABLED, "UI Scale", "Scale all interface elements (restart may be needed on some platforms)", 0.5, 2.0, 0.05)
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
@export var dual_screen_mode := SettingsVar.new(Type.BOOL, false, State.ENABLED, "Dual Screen Mode", "Automatically use second display for hero image when available")

# Internal DS screen swap state (managed by AynThorManager)
@export var dual_screen_swapped := SettingsVar.new(Type.BOOL, false, State.INTERNAL, "Dual Screen Swapped")

# Internal last windowed size (managed by SystemManager.display). 200x150 min, 16K max.
@export var last_window_size := SettingsVar.new(Type.VECTOR2I, Vector2i.ZERO, State.INTERNAL, "Last Window Size", "", 200.0, 16384.0, 1.0, [], false, {})

@export_subgroup("RomM Connection")
@export var romm_url := SettingsVar.new(Type.STRING, "", State.ENABLED, "RomM URL")
@export var romm_username := SettingsVar.new(Type.STRING, "", State.ENABLED, "Username")
@export var romm_password := SettingsVar.new(Type.STRING, "", State.ENABLED, "Password", "", 0.0, 1.0, 0.1, [], true)
@export var fold_duplicate_covers := SettingsVar.new(Type.BOOL, false, State.ENABLED, "Fold duplicate covers into siblings", "During sync, games with identical cover art will be grouped together like RomM siblings")
@export var hide_games_without_covers := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Hide games without cover art", "Games without cover art will be hidden from the library view")
@export var fold_romm_siblings := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Fold RomM siblings", "RomM-designated regional variants (siblings) will be grouped under a single library entry")
@export_subgroup("Storage")
@export var games_root_folder := SettingsVar.new(Type.PATH, "user://roms/", State.ENABLED, "Games Folder", "Directory where game ROMs are stored")
@export var emulators_folder := SettingsVar.new(Type.PATH, "user://emulators/", State.ENABLED, "Emulators Folder", "Directory where emulators are installed")
@export var steam_folder := SettingsVar.new(Type.PATH, "", State.ENABLED, "Steam Installation Folder", "Path to your Steam installation (e.g., C:\\Program Files (x86)\\Steam)")
@export var save_sync_auto := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Auto-sync saves", "Automatically upload saves after playing and download before launch")
@export var download_speed_profile := SettingsVar.new(Type.ARRAY, 1, State.ENABLED, "Download Speed", "Higher settings use more network connections per file and more simultaneous downloads", 0.0, 3.0, 1.0, ["Conservative", "Balanced", "Fast", "Unrestricted"])

# Internal GameNative games list (not displayed in settings menu)
@export var gamenative_games := SettingsVar.new(Type.ARRAY, [], State.INTERNAL, "GameNative Games")

# Internal platform sync settings (not displayed in auto-generated menu)
@export var enabled_platforms := SettingsVar.new(Type.DICTIONARY, {}, State.INTERNAL, "Enabled Platforms")

# Internal card effect configuration (managed by Card Designer)
@export var card_effect_config := SettingsVar.new(Type.DICTIONARY, {
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
}, State.INTERNAL, "Card Effect Configuration")

# Internal hero effect configuration (managed by Hero Designer)
@export var hero_effect_config := SettingsVar.new(Type.DICTIONARY, {
	"effects": [],
	"corner_radius": 0.06,
	"hero_height": 0
}, State.INTERNAL, "Hero Effect Configuration")

@export_subgroup("Library Appearance")
# General layout settings (always visible)
@export var dark_mode := SettingsVar.new(Type.BOOL, true, State.ENABLED, "Dark Mode", "Use dark colors for the Material 3 interface")
@export var library_layout_mode := SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Layout Mode", "How game cards are arranged in the library", 0.0, 2.0, 1.0, ["Grid", "List", "Carousel"])
@export var library_grid_vertical := SettingsVar.new(Type.BOOL, true, State.INTERNAL, "Grid Vertical", "Scroll grid vertically (true) or horizontally (false)")
@export var library_navigation_type := SettingsVar.new(Type.ARRAY, 1, State.ENABLED, "Navigation Type", "Use a bottom bar or side rail for navigation", 0.0, 1.0, 1.0, ["Bar", "Rail"])
@export var library_grid_padding := SettingsVar.new(Type.INT, 22, State.ENABLED, "Grid Padding", "Space between game cards in pixels", 0.0, 50.0, 1.0)
@export var library_card_zoom := SettingsVar.new(Type.FLOAT, 0.25, State.INTERNAL, "Card Zoom", "Card size as ratio of viewport", 0.05, 0.5, 0.01)
@export var library_show_title_mode := SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Gamecard Titles", "When to display game titles on cards", 0.0, 2.0, 1.0, ["None", "Focused", "All"])
@export var library_focus_scale := SettingsVar.new(Type.FLOAT, 0.09, State.ENABLED, "Focus Scale", "How much larger the focused card appears (0% to 50%)", 0.0, 0.5, 0.01)
@export var library_card_content_alignment := SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Content Alignment", "How card content is positioned within the card cell", 0.0, 2.0, 1.0, ["Left/Top", "Center/Middle", "Right/Bottom"])
@export var card_media_aspect_ratio := SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Card Media Ratio", "Aspect ratio of the card's media panel", 0.0, 4.0, 1.0, ["Fill", "2:3", "3:4", "1:1", "16:11"])
@export var library_card_display_mode := SettingsVar.new(Type.ARRAY, 0, State.INTERNAL, "Card Display Mode", "How game cards appear in the library", 0.0, 2.0, 1.0, ["Standard", "Transparent", "Media Only"])
@export var library_primary_color := SettingsVar.new(Type.COLOR, Color.WHITE, State.ENABLED, "Accent Color", "Primary color for the Material 3 interface theme")


# Internal first-run flag (tracks if OOBE wizard has been completed)
@export var first_run_completed := SettingsVar.new(Type.BOOL, false, State.INTERNAL, "First Run Completed")

# Internal last search query (managed by Library search)
@export var library_last_search := SettingsVar.new(Type.STRING, "", State.INTERNAL, "Last Search Query")

# Internal installed emulator versions (tracked for update checking)
@export var installed_emulator_versions := SettingsVar.new(Type.DICTIONARY, {}, State.INTERNAL, "Installed Emulator Versions")

# Internal background effect configuration (managed by Library Appearance settings)
@export var library_background_config := SettingsVar.new(Type.DICTIONARY, {
	"effect_id": "none",
	"settings": {}
}, State.INTERNAL, "Background Effect Configuration")
