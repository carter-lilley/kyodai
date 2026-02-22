@icon("res://Icons/BoxMesh.svg")
#settings_manager.gd
extends Manager

signal setting_changed(value: Variant, setting: SettingsVar)
signal settings_saved

const SAVE_PATH := "user://user_prefs.tres"
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
			print("[SettingsManager]:",settings.get(property.name))
			#dictionary[property.name] = settings.get(property.name) #Property name is key, SettingsVAR is value. 
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
				print("[SettingsManager] Checking subgroup '", subgroup, "' with ", settingsvars.size(), " settings")
				if settingsvars.size() > 0:
					dictionary[subgroup] = settingsvars.duplicate()
					print("[SettingsManager] Added subgroup '", subgroup, "' to dictionary")
				else:
					print("[SettingsManager] Skipping empty subgroup '", subgroup, "'")
			subgroup = property.name
			settingsvars.clear()										# And then clear the array for re-use.
		if settings.get(property.name) is SettingsVar and not subgroup == "": 			#	If we've caught a SettingsVar and we already have a previous subgroup
			var settingsvar : SettingsVar = settings.get(property.name)
			# Skip INTERNAL settings - they shouldn't appear in the auto-generated menu
			if settingsvar.state != SettingsVar.SettingState.INTERNAL:
				settingsvars.append(settingsvar)
				print("[SettingsManager] Added setting '", property.name, "' to subgroup '", subgroup, "'")
			else:
				print("[SettingsManager] Skipping INTERNAL setting '", property.name, "' in subgroup '", subgroup, "'")
	# Only add last subgroup if it has non-INTERNAL settings
	if settingsvars.size() > 0:
		print("[SettingsManager] Adding final subgroup '", subgroup, "' with ", settingsvars.size(), " settings")
		dictionary[subgroup] = settingsvars.duplicate()
	else:
		print("[SettingsManager] Skipping final empty subgroup '", subgroup, "'")
	print("[SettingsManager] Returning subgroups: ", dictionary.keys())
	return dictionary

func enable_setting(_name:String):
	var settingsvar: SettingsVar = get_setting(_name)
	settingsvar.state = SettingsVar.SettingState.ENABLED

func disable_setting(_name:String):
	var settingsvar: SettingsVar = get_setting(_name)
	settingsvar.state = SettingsVar.SettingState.DISABLED
	print("[SettingsManager]: Disabling setting ",_name, settingsvar.state )

func set_setting(value: Variant, setting: SettingsVar):
	if not settings:
		push_error("No settings loaded, cannot change setting '%s'" % setting.property_name)
		return
	setting.value = value
	emit_signal("setting_changed", value, setting)
	print("[SettingsManager]: Changed setting '%s' to %s" % [setting.property_name, str(value)])

func get_setting(_name:String) -> SettingsVar:
	var settingsvar: SettingsVar
	if not settings:
		push_error("No settings loaded, but queried anyway.")
		return settingsvar
	settingsvar = settings.get(_name)
	return settingsvar

func load_settings() -> void:
	if FileAccess.file_exists(SAVE_PATH):
		settings = ResourceLoader.load(SAVE_PATH) as Settings
		if settings:
			print("[SettingsManager]: Loaded preferences from disk.")
			store_property_names(settings)
			_decrypt_settings()
			return
	# fallback if load failed
	settings = Settings.new()
	store_property_names(settings)
	print("[SettingsManager]: Created new default preferences.")

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
			print("[SettingsManager]: Preferences saved.")
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
