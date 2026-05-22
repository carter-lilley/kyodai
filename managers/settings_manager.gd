@icon("res://Icons/BoxMesh.svg")
#settings_manager.gd
extends Manager

signal setting_changed(value: Variant, setting: SettingsVar)
signal settings_saved
signal apply_preset_begin
signal apply_preset_end

const SAVE_PATH := "user://user_prefs.tres"
const PRESETS_FOLDER := "user://themes/"
const BUILTIN_PRESETS_FOLDER := "res://themes/"
var settings: Settings
var settings_dict: Dictionary[String, SettingsVar] = {}

func _init() -> void:
	#print("[SettingsManager]: initialized.")
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
				#print("[SettingsManager] Checking subgroup '", subgroup, "' with ", settingsvars.size(), " settings")
				if settingsvars.size() > 0:
					dictionary[subgroup] = settingsvars.duplicate()
					#print("[SettingsManager] Added subgroup '", subgroup, "' to dictionary")
				#else:
					#print("[SettingsManager] Skipping empty subgroup '", subgroup, "'")
			subgroup = property.name
			settingsvars.clear()										# And then clear the array for re-use.
		if settings.get(property.name) is SettingsVar and not subgroup == "": 			#	If we've caught a SettingsVar and we already have a previous subgroup
			var settingsvar : SettingsVar = settings.get(property.name)
			# Skip INTERNAL settings - they shouldn't appear in the auto-generated menu
			if settingsvar.state != SettingsVar.SettingState.INTERNAL:
				settingsvars.append(settingsvar)
				#print("[SettingsManager] Added setting '", property.name, "' to subgroup '", subgroup, "'")
			#else:
				#print("[SettingsManager] Skipping INTERNAL setting '", property.name, "' in subgroup '", subgroup, "'")
	# Only add last subgroup if it has non-INTERNAL settings
	if settingsvars.size() > 0:
		#print("[SettingsManager] Adding final subgroup '", subgroup, "' with ", settingsvars.size(), " settings")
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

func set_setting(value: Variant, setting: SettingsVar):
	if not settings:
		push_error("No settings loaded, cannot change setting '%s'" % setting.property_name)
		return
	setting.value = value
	emit_signal("setting_changed", value, setting)

func get_setting(_name:String) -> SettingsVar:
	var settingsvar: SettingsVar = null
	if not settings:
		push_error("No settings loaded, but queried anyway.")
		return settingsvar
	settingsvar = settings.get(_name)
	return settingsvar

func load_settings() -> void:
	if FileAccess.file_exists(SAVE_PATH):
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
			if old_value is int and old_value >= 0 and old_value < default_var.options.size():
				saved_var.value = old_value
			else:
				saved_var.value = default_var.value
		elif default_var.type == SettingsVar.SettingType.INT or default_var.type == SettingsVar.SettingType.FLOAT:
			saved_var.value = clamp(old_value, default_var.min_value, default_var.max_value)
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
	if settings:
		_encrypt_settings()
		var err = ResourceSaver.save(settings, SAVE_PATH)
		_decrypt_settings()  # Restore decrypted values for runtime use
		
		if err != OK:
			push_error("Failed to save preferences: %s" % err)
		else:
			emit_signal("settings_saved")

const PASSWORD_KEY = "kyodai_v1"

func _encrypt_settings() -> void:
	for prop in settings.get_property_list():
		var setting = settings.get(prop.name)
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
	var dir = DirAccess.open("user://")
	if dir:
		if not dir.dir_exists("themes"):
			dir.make_dir("themes")

# List of built-in preset filenames (needed for Android where DirAccess doesn't work on res://)
const BUILTIN_PRESET_FILES: Array[String] = [
	# Add your built-in preset filenames here, e.g.:
	# "Default.tres",
	# "Neon.tres",
	# "Retro.tres",
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
		# Fallback: try DirAccess (works on desktop)
		var dir = DirAccess.open(BUILTIN_PRESETS_FOLDER)
		if dir:
			dir.list_dir_begin()
			var file_name = dir.get_next()
			while file_name != "":
				if not dir.current_is_dir() and (file_name.ends_with(".tres") or file_name.ends_with(".tres.remap")):
					# Strip .remap extension if present - it's a mapping file, load the actual resource
					var preset_path = BUILTIN_PRESETS_FOLDER + file_name
					if preset_path.ends_with(".remap"):
						preset_path = preset_path.substr(0, preset_path.length() - 6)
					var loaded_resource = ResourceLoader.load(preset_path)
					var preset = loaded_resource as ThemePreset
					if preset and preset.name not in loaded_names:
						presets.append(preset)
						loaded_names.append(preset.name)
				file_name = dir.get_next()
	
	# Load user presets (from user://) - these can override built-ins
	var user_dir = DirAccess.open(PRESETS_FOLDER)
	if user_dir:
		user_dir.list_dir_begin()
		var user_file_name = user_dir.get_next()
		while user_file_name != "":
			if not user_dir.current_is_dir() and (user_file_name.ends_with(".tres") or user_file_name.ends_with(".tres.remap")):
				var user_preset_path = PRESETS_FOLDER + user_file_name
				var user_preset = ResourceLoader.load(user_preset_path) as ThemePreset
				if user_preset and user_preset.name not in loaded_names:
					presets.append(user_preset)
					loaded_names.append(user_preset.name)
			user_file_name = user_dir.get_next()
	
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
	if not FileAccess.file_exists(preset_path):
		push_error("Preset file not found: %s" % preset_path)
		return null
	
	var preset = ResourceLoader.load(preset_path) as ThemePreset
	if not preset:
		push_error("Failed to load preset from: %s" % preset_path)
		return null
	
	return preset

func apply_preset(preset: ThemePreset) -> bool:
	if not preset:
		push_error("[SettingsManager] Cannot apply null preset")
		return false
	
	if not settings:
		push_error("[SettingsManager] No settings loaded, cannot apply preset")
		return false
	
	# Create a default preset for merging missing values
	var default_preset = ThemePreset.from_current_settings(Settings.new())
	preset.merge_with_defaults(default_preset)
	
	var success = preset.apply_to_settings(settings)
	
	if success:
		emit_signal("apply_preset_begin")
		
		# Emit setting_changed for all library settings so views get notified
		# Emit the SETTING VALUE (settings.X.value), not the preset value
		if settings.get("hero_effect_config") != null:
			emit_signal("setting_changed", settings.hero_effect_config.value, settings.hero_effect_config)
		if settings.get("library_navigation_type") != null:
			emit_signal("setting_changed", settings.library_navigation_type.value, settings.library_navigation_type)
		if settings.get("library_grid_padding") != null:
			emit_signal("setting_changed", settings.library_grid_padding.value, settings.library_grid_padding)
		if settings.get("library_card_zoom") != null:
			emit_signal("setting_changed", settings.library_card_zoom.value, settings.library_card_zoom)
		if settings.get("library_background_config") != null:
			emit_signal("setting_changed", settings.library_background_config.value, settings.library_background_config)
		if settings.get("library_show_title_mode") != null:
			emit_signal("setting_changed", settings.library_show_title_mode.value, settings.library_show_title_mode)
		if settings.get("library_card_display_mode") != null:
			emit_signal("setting_changed", settings.library_card_display_mode.value, settings.library_card_display_mode)
		if settings.get("library_card_content_alignment") != null:
			emit_signal("setting_changed", settings.library_card_content_alignment.value, settings.library_card_content_alignment)
		if settings.get("library_focus_scale") != null:
			emit_signal("setting_changed", settings.library_focus_scale.value, settings.library_focus_scale)
		if settings.get("library_layout_mode") != null:
			emit_signal("setting_changed", settings.library_layout_mode.value, settings.library_layout_mode)
		# Emit for card effect config - this triggers grid rebuild
		if settings.get("card_effect_config") != null:
			emit_signal("setting_changed", settings.card_effect_config.value, settings.card_effect_config)
		
		emit_signal("apply_preset_end")
		
		save_settings()
		emit_signal("settings_saved")
	else:
		push_error("[SettingsManager] preset.apply_to_settings returned false")
	
	return success

func export_preset(preset: ThemePreset, export_path: String) -> bool:
	if not preset:
		return false
	
	var err = ResourceSaver.save(preset, export_path)
	if err != OK:
		push_error("Failed to export preset: %s" % err)
		return false
	
	return true

func import_preset(import_path: String) -> ThemePreset:
	if not FileAccess.file_exists(import_path):
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
