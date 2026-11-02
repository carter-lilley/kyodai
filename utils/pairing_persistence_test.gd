## Isolated roundtrip check for paired-token persistence:
## Settings -> duplicate+encrypt -> ResourceSaver -> ResourceLoader -> decrypt.
## Uses a throwaway file, never the real user_prefs.tres.
## The crafted token hits the old encryption bug: chars equal to the XOR key
## char at their aligned position produced embedded NULs and a mangled tail.
## Run: godot --headless --path . res://utils/pairing_persistence_test.tscn
## (scene-based so autoloads register before network scripts compile)
extends Node

const SettingsSub = preload("res://managers/data_manager/settings_sub_manager.gd")
const SettingsClass = preload("res://base_class/abstract/settings.gd")
const NetworkScript = preload("res://managers/system_manager/network_sub_manager.gd")

const TEST_PATH := "user://pairing_test_prefs.tres"

## "rmm_e3ea38a02d..." - 'd' at index 13 (and every later i where i%9==4)
## XORs with key[4]='d' to produce NUL. Seven NUL positions in total.
static func crafted_token() -> String:
	var chars: Array = []
	chars.resize(68)
	for i in range(68):
		chars[i] = "0"
	var prefix := "rmm_e3ea38a02d"
	for i in range(prefix.length()):
		chars[i] = prefix[i]
	for i in range(68):
		if i % 9 == 4 and i >= 13:
			chars[i] = "d"
	return "".join(chars)

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("OK   ", msg)
	else:
		_failures += 1
		printerr("FAIL ", msg)

func _ready() -> void:
	var token := crafted_token()
	_check(NetworkScript.is_valid_client_token(token), "crafted token is a valid rmm_ token shape")
	_check(not NetworkScript.is_valid_client_token("rmm_short"), "short token rejected")
	_check(not NetworkScript.is_valid_client_token(token.to_upper()), "uppercase token rejected")
	_check(not NetworkScript.is_valid_client_token("basic_password"), "non-token rejected")

	var mgr = SettingsSub.new()
	# Isolate from the real prefs loaded in _init.
	mgr.settings = SettingsClass.new()
	mgr.store_property_names(mgr.settings)

	mgr.set_setting(token, mgr.get_setting("romm_token"))
	mgr.set_setting("https://demo.romm.app", mgr.get_setting("romm_url"))
	mgr.set_setting("bound-device-123", mgr.get_setting("romm_bound_device_id"))
	mgr.set_setting("hunter2", mgr.get_setting("romm_password"))

	# Save exactly like save_settings() does.
	var to_save: Settings = mgr.settings.duplicate(true)
	mgr._encrypt_settings(to_save)
	var err := ResourceSaver.save(to_save, TEST_PATH)
	_check(err == OK, "settings saved")
	_check(to_save.get("romm_token").value != token, "token is not plaintext on disk")

	# Load exactly like load_settings() does.
	var loaded: Settings = ResourceLoader.load(TEST_PATH, "", ResourceLoader.CACHE_MODE_REPLACE)
	mgr.settings = loaded
	mgr.store_property_names(loaded)
	mgr._refresh_setting_metadata(loaded)
	mgr._decrypt_settings()

	_check(loaded.get("romm_token").value == token, "NUL-heavy token survives the encrypt/save/load/decrypt roundtrip")
	_check(NetworkScript.is_valid_client_token(loaded.get("romm_token").value), "loaded token passes the client-token validator")
	_check(loaded.get("romm_url").value == "https://demo.romm.app", "url roundtrip")
	_check(loaded.get("romm_bound_device_id").value == "bound-device-123", "bound device roundtrip")
	_check(loaded.get("romm_password").value == "hunter2", "legacy ASCII password roundtrip")

	# Second full cycle: a restart that re-saves must stay stable too.
	to_save = mgr.settings.duplicate(true)
	mgr._encrypt_settings(to_save)
	ResourceSaver.save(to_save, TEST_PATH)
	loaded = ResourceLoader.load(TEST_PATH, "", ResourceLoader.CACHE_MODE_REPLACE)
	mgr.settings = loaded
	mgr._decrypt_settings()
	_check(loaded.get("romm_token").value == token, "token survives a second save/load cycle")

	DirAccess.remove_absolute(TEST_PATH)
	mgr.settings = null
	mgr.free()
	print("[pairing-persistence] ", "all passed" if _failures == 0 else "%d FAILED" % _failures)
	get_tree().quit(1 if _failures > 0 else 0)
