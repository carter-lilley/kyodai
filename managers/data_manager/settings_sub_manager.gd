@icon("res://Icons/BoxMesh.svg")
#settings_sub_manager.gd
extends Manager
class_name SettingsSubManager

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

signal setting_changed(value: Variant, setting: SettingsVar)
signal settings_saved
signal apply_preset_begin
signal apply_preset_end

const SAVE_PATH := "user://user_prefs.tres"
const PRESETS_FOLDER := "user://themes/"
const BUILTIN_PRESETS_FOLDER := "res://themes/"
var settings: Settings
var _is_dirty: bool = false

func _init() -> void:
	#print("[SettingsSubManager]: initialized.")
	load_settings()

## === Accessors ===
func get_settings() -> Dictionary:
	var dictionary: Dictionary[String, SettingsVar] = {}
	if not settings:
		push_error("No settings loaded, but queried anyway.")
		return dictionary
	for property in settings.get_property_list():
		if settings.get(property.name) is SettingsVar: #Check each property for SettingsVars
			dictionary[property.name] = settings.get(property.name) #Property name is key, SettingsVAR is value. 
			#print("Storing ", property.value)
	return dictionary

# I hate this function. Its so messy. Fix pls. 
func get_settings_by_subgroup() -> Dictionary:
	var dictionary: Dictionary[String, Array] = {}
	if not settings:
		push_error("No settings loaded, but queried anyway.")
		return dictionary
	var subgroup :String = ""
	var settingsvars :Array[SettingsVar] = []
	for property in settings.get_property_list():	#					For every property in the list, 
		if property.usage == 256:  # 								If it's a @export subgroup..
			if not subgroup == "": # 								And we already have a previous subgroup
				# Only add subgroup if it has non-INTERNAL settings
				#print("[SettingsSubManager] Checking subgroup '", subgroup, "' with ", settingsvars.size(), " settings")
				if settingsvars.size() > 0:
					dictionary[subgroup] = settingsvars.duplicate()
					#print("[SettingsSubManager] Added subgroup '", subgroup, "' to dictionary")
				#else:
					#print("[SettingsSubManager] Skipping empty subgroup '", subgroup, "'")
			subgroup = property.name
			settingsvars.clear()										# And then clear the array for re-use.
		if settings.get(property.name) is SettingsVar and not subgroup == "": 			#	If we've caught a SettingsVar and we already have a previous subgroup
			var settingsvar : SettingsVar = settings.get(property.name)
			# Skip INTERNAL settings - they shouldn't appear in the auto-generated menu
			if settingsvar.state != SettingsVar.SettingState.INTERNAL:
				settingsvars.append(settingsvar)
				#print("[SettingsSubManager] Added setting '", property.name, "' to subgroup '", subgroup, "'")
			#else:
				#print("[SettingsSubManager] Skipping INTERNAL setting '", property.name, "' in subgroup '", subgroup, "'")
	# Only add last subgroup if it has non-INTERNAL settings
	if settingsvars.size() > 0:
		#print("[SettingsSubManager] Adding final subgroup '", subgroup, "' with ", settingsvars.size(), " settings")
		dictionary[subgroup] = settingsvars.duplicate()
	else:
		pass  # Skipping final empty subgroup
	return dictionary

func enable_setting(_name:String):
	var settingsvar: SettingsVar = get_setting(_name)
	settingsvar.state = SettingsVar.SettingState.ENABLED

func disable_setting(_name:String):
	var settingsvar: SettingsVar = get_setting(_name)
	settingsvar.state = SettingsVar.SettingState.DISABLED

func set_setting(value: Variant, setting: SettingsVar, force: bool = false):
	if not settings:
		push_error("No settings loaded, cannot change setting '%s'" % setting.property_name)
		return
	var changed = force or setting.value != value
	setting.value = value
	if changed:
		_is_dirty = true
		emit_signal("setting_changed", value, setting)

## Builds a ThemePreset from the live settings using the public get_setting() API.
func create_preset_from_current() -> ThemePreset:
	return create_preset_from_settings(settings)

## Builds a ThemePreset from the given Settings object.
func create_preset_from_settings(source_settings: Settings) -> ThemePreset:
	var preset := ThemePreset.new()
	preset.name = "New Preset"
	preset.description = ""
	preset.created_at = Time.get_datetime_string_from_system()
	preset.version = 2
	
	preset.library_layout_mode = _preset_value_from(source_settings, "library_layout_mode", 0)
	preset.library_navigation_type = _preset_value_from(source_settings, "library_navigation_type", 1)
	preset.library_grid_padding = _preset_value_from(source_settings, "library_grid_padding", 22)
	preset.library_card_zoom = _preset_value_from(source_settings, "library_card_zoom", 0.25)
	preset.library_card_zoom_level = _preset_value_from(source_settings, "library_card_zoom_level", -1)
	preset.library_show_title_mode = _preset_value_from(source_settings, "library_show_title_mode", 0)
	preset.library_card_display_mode = _preset_value_from(source_settings, "library_card_display_mode", 0)
	preset.library_focus_scale = _preset_value_from(source_settings, "library_focus_scale", 0.09)
	preset.library_card_content_alignment = _preset_value_from(source_settings, "library_card_content_alignment", 0)
	preset.library_grid_vertical = _preset_value_from(source_settings, "library_grid_vertical", true)
	preset.card_media_aspect_ratio = _preset_value_from(source_settings, "card_media_aspect_ratio", 0)
	preset.library_background_config = _preset_value_from(source_settings, "library_background_config", {
		"effect_id": "none",
		"settings": {}
	}).duplicate(true)
	preset.library_primary_color = _preset_value_from(source_settings, "library_primary_color", Color.WHITE)
	preset.dark_mode = _preset_value_from(source_settings, "dark_mode", true)
	preset.card_effect_config = _preset_value_from(source_settings, "card_effect_config", {
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
	}).duplicate(true)
	
	return preset

func _preset_value_from(source_settings: Settings, setting_name: String, default: Variant) -> Variant:
	if source_settings == null:
		return default
	var setting: SettingsVar = source_settings.get(setting_name)
	if setting == null:
		return default
	var value = setting.value
	if value == null:
		return default
	return value

func get_setting(_name:String) -> SettingsVar:
	var settingsvar: SettingsVar = null
	if not settings:
		push_error("No settings loaded, but queried anyway.")
		return settingsvar
	settingsvar = settings.get(_name)
	return settingsvar

func load_settings() -> void:
	if FSM.file_exists(SAVE_PATH):
		settings = ResourceLoader.load(SAVE_PATH) as Settings
	if settings:
		_refresh_setting_metadata(settings)
		store_property_names(settings)
		_decrypt_settings()
		return
	# fallback if load failed
	settings = Settings.new()
	store_property_names(settings)

## Syncs metadata (options, ranges, names, etc.) from fresh defaults onto loaded settings.
## Preserves the user's saved values.
func _refresh_setting_metadata(_settings: Settings) -> void:
	var defaults = Settings.new()
	for prop in defaults.get_property_list():
		var default_var = defaults.get(prop.name)
		if not (default_var is SettingsVar):
			continue
		var saved_var = _settings.get(prop.name)
		if not (saved_var is SettingsVar):
			continue
		
		# Preserve user's value and property_name, refresh everything else from code
		var old_value = saved_var.value
		var old_property_name = saved_var.property_name
		
		saved_var.type = default_var.type
		saved_var.state = default_var.state
		saved_var.display_name = default_var.display_name
		saved_var.description = default_var.description
		saved_var.min_value = default_var.min_value
		saved_var.max_value = default_var.max_value
		saved_var.step = default_var.step
		saved_var.options = default_var.options.duplicate()
		saved_var.encrypted = default_var.encrypted
		
		# Clamp value to new valid range/options if needed
		if default_var.type == SettingsVar.SettingType.ARRAY:
			if old_value is Array:
				# ARRAY type can store actual arrays (e.g., gamenative_games)
				# not just int indices for dropdown options
				saved_var.value = old_value
			elif old_value is int and old_value >= 0 and old_value < default_var.options.size():
				saved_var.value = old_value
			else:
				saved_var.value = default_var.value
		elif default_var.type == SettingsVar.SettingType.INT or default_var.type == SettingsVar.SettingType.FLOAT:
			saved_var.value = clamp(old_value, default_var.min_value, default_var.max_value)
		elif default_var.type == SettingsVar.SettingType.VECTOR2I:
			# Clamp each axis independently using the per-axis min/max from metadata.
			var min_limit := int(default_var.min_value)
			var max_limit := int(default_var.max_value)
			if max_limit <= 0:
				max_limit = 16384
			saved_var.value = Vector2i(
				clampi(int(old_value.x), min_limit, max_limit),
				clampi(int(old_value.y), min_limit, max_limit)
			)
		else:
			saved_var.value = old_value
		
		saved_var.property_name = old_property_name

# Here we're storing an internal reference to the properties the settingsvars are assigned to. 
func store_property_names(_settings : Settings):
	for prop in _settings.get_property_list():
		var setting = _settings.get(prop.name)
		if setting is SettingsVar:
			setting.property_name = prop.name

func save_settings() -> void:
	if not settings or not _is_dirty:
		return
	# Encrypt a disposable copy so runtime values are never mutated.
	var settings_to_save = settings.duplicate(true)
	_encrypt_settings(settings_to_save)
	var err = ResourceSaver.save(settings_to_save, SAVE_PATH)

	if err != OK:
		push_error("Failed to save preferences: %s" % err)
	else:
		_is_dirty = false
		emit_signal("settings_saved")

const PASSWORD_KEY = "kyodai_v1"

func _encrypt_settings(target: Settings) -> void:
	for prop in target.get_property_list():
		var setting = target.get(prop.name)
		if setting is SettingsVar and setting.encrypted and setting.value:
			if setting.value is String and not setting.value.is_empty():
				setting.value = _xor_encrypt(setting.value, PASSWORD_KEY)

func _decrypt_settings() -> void:
	for prop in settings.get_property_list():
		var setting = settings.get(prop.name)
		if setting is SettingsVar and setting.encrypted and setting.value:
			if setting.value is String and not setting.value.is_empty():
				# Check if value looks encrypted (base64)
				if _is_base64(setting.value):
					setting.value = _xor_decrypt(setting.value, PASSWORD_KEY)

func _is_base64(text: String) -> bool:
	# Simple check: base64 strings are typically divisible by 4 and contain specific chars
	if text.length() % 4 != 0:
		return false
	var base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/="
	for c in text:
		if not c in base64_chars:
			return false
	return text.length() > 0

func reset_settings() -> void:
	settings = Settings.new()
	_is_dirty = true
	save_settings()

func _xor_encrypt(text: String, key: String) -> String:
	var result = ""
	for i in range(text.length()):
		result += char(text.unicode_at(i) ^ key.unicode_at(i % key.length()))
	return Marshalls.raw_to_base64(result.to_utf8_buffer())

func _xor_decrypt(encrypted: String, key: String) -> String:
	var bytes = Marshalls.base64_to_raw(encrypted)
	var text = bytes.get_string_from_utf8()
	var result = ""
	for i in range(text.length()):
		result += char(text.unicode_at(i) ^ key.unicode_at(i % key.length()))
	return result

## === Theme Preset Management ===

func _ensure_presets_folder() -> void:
	FSM.make_dir_recursive(PRESETS_FOLDER)

# List of built-in preset filenames (needed for Android where DirAccess doesn't work on res://)
const BUILTIN_PRESET_FILES: Array[String] = [
	"CafeOS.tres",
	"Default.tres",
	"Horizon3D.tres",
	"Horizon3D_(Dark).tres",
	"Horizon_(Dark).tres",
	"Horizon_(Light).tres",
	"LiveArea.tres",
	"NSO_(Light).tres",
	"SteamOS.tres",
	"XMB.tres",
]

func list_presets() -> Array[ThemePreset]:
	_ensure_presets_folder()
	var presets: Array[ThemePreset] = []
	var loaded_names: Array[String] = []
	
	# Load built-in presets first (from res://)
	# On Android, DirAccess doesn't work for res://, so we use the hardcoded list
	if not BUILTIN_PRESET_FILES.is_empty():
		for file_name in BUILTIN_PRESET_FILES:
			var preset_path = BUILTIN_PRESETS_FOLDER + file_name
			if ResourceLoader.exists(preset_path):
				var preset = ResourceLoader.load(preset_path) as ThemePreset
				if preset and preset.name not in loaded_names:
					presets.append(preset)
					loaded_names.append(preset.name)
	else:
		# Fallback: try FSM (works on desktop)
		for file_name in FSM.list_dir(BUILTIN_PRESETS_FOLDER):
			if FSM.is_dir(FSM.join_paths(BUILTIN_PRESETS_FOLDER, file_name)):
				continue
			if file_name.ends_with(".tres") or file_name.ends_with(".tres.remap"):
				# Strip .remap extension if present - it's a mapping file, load the actual resource
				var preset_path = FSM.join_paths(BUILTIN_PRESETS_FOLDER, file_name)
				if preset_path.ends_with(".remap"):
					preset_path = preset_path.substr(0, preset_path.length() - 6)
				var loaded_resource = ResourceLoader.load(preset_path)
				var preset = loaded_resource as ThemePreset
				if preset and preset.name not in loaded_names:
					presets.append(preset)
					loaded_names.append(preset.name)
	
	# Load user presets (from user://) - these can override built-ins
	for file_name in FSM.list_dir(PRESETS_FOLDER):
		if FSM.is_dir(FSM.join_paths(PRESETS_FOLDER, file_name)):
			continue
		if file_name.ends_with(".tres") or file_name.ends_with(".tres.remap"):
			var user_preset_path = FSM.join_paths(PRESETS_FOLDER, file_name)
			var user_preset = ResourceLoader.load(user_preset_path) as ThemePreset
			if user_preset and user_preset.name not in loaded_names:
				presets.append(user_preset)
				loaded_names.append(user_preset.name)
	
	# Sort by name
	presets.sort_custom(func(a, b): return a.name < b.name)
	return presets

func save_preset(preset: ThemePreset) -> bool:
	_ensure_presets_folder()
	if preset.name.is_empty():
		push_error("Cannot save preset without a name")
		return false
	
	# Sanitize filename
	var safe_name = preset.name.replace(" ", "_").replace("/", "_").replace("\\", "_")
	var preset_path = PRESETS_FOLDER + safe_name + ".tres"
	
	var err = ResourceSaver.save(preset, preset_path)
	if err != OK:
		push_error("Failed to save preset: %s" % err)
		return false
	
	return true

func load_preset(preset_path: String) -> ThemePreset:
	if not FSM.file_exists(preset_path):
		push_error("Preset file not found: %s" % preset_path)
		return null
	
	var preset = ResourceLoader.load(preset_path) as ThemePreset
	if not preset:
		push_error("Failed to load preset from: %s" % preset_path)
		return null
	
	return preset

func apply_preset(preset: ThemePreset) -> bool:
	if not preset:
		push_error("[SettingsSubManager] Cannot apply null preset")
		return false
	
	if not settings:
		push_error("[SettingsSubManager] No settings loaded, cannot apply preset")
		return false
	
	# Create a default preset for merging missing values
	var default_preset = create_preset_from_settings(Settings.new())
	preset.merge_with_defaults(default_preset)
	
	emit_signal("apply_preset_begin")
	
	# Apply every preset field through the public setter so dirty flags and
	# setting_changed signals are emitted consistently.
	var mapping := {
		"library_layout_mode": preset.library_layout_mode,
		"library_navigation_type": preset.library_navigation_type,
		"library_grid_padding": preset.library_grid_padding,
		"library_card_zoom": preset.library_card_zoom,
		"library_card_zoom_level": preset.library_card_zoom_level,
		"library_show_title_mode": preset.library_show_title_mode,
		"library_card_display_mode": preset.library_card_display_mode,
		"library_focus_scale": preset.library_focus_scale,
		"library_card_content_alignment": preset.library_card_content_alignment,
		"library_grid_vertical": preset.library_grid_vertical,
		"card_media_aspect_ratio": preset.card_media_aspect_ratio,
		"library_background_config": preset.library_background_config.duplicate(true),
		"library_primary_color": preset.library_primary_color,
		"dark_mode": preset.dark_mode,
		"card_effect_config": preset.card_effect_config.duplicate(true),
		# NOTE: nav_pinned_shortcuts is intentionally excluded from presets so
		# theme changes never wipe the user’s pinned navigation items.
	}
	
	for key in mapping:
		var setting := get_setting(key)
		if setting:
			set_setting(mapping[key], setting, true)
	
	emit_signal("apply_preset_end")
	
	save_settings()
	
	return true

func export_preset(preset: ThemePreset, export_path: String) -> bool:
	if not preset:
		return false
	
	var err = ResourceSaver.save(preset, export_path)
	if err != OK:
		push_error("Failed to export preset: %s" % err)
		return false
	
	return true

func import_preset(import_path: String) -> ThemePreset:
	if not FSM.file_exists(import_path):
		push_error("Import file not found: %s" % import_path)
		return null
	
	var preset = ResourceLoader.load(import_path) as ThemePreset
	if not preset:
		push_error("Failed to import preset from: %s" % import_path)
		return null
	
	# Save to presets folder
	if save_preset(preset):
		return preset
	
	return null

func _exit_tree() -> void:
	"""Release the loaded settings resource so its SettingsVars don't leak."""
	settings = null
