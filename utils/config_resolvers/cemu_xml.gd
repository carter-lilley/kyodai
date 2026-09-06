## Config-first resolver for the Cemu family's settings.xml.
## The mlc01 location lives in a single top-level element:
##
##   <content>
##     <mlc_path>D:/somewhere/mlc01</mlc_path>
##
## This is deliberately NOT an XML parser: it matches only the mlc_path
## element (paired or self-closing), which CemuConfig reads via
## parser.get("mlc_path", "") - absent, empty, and self-closing all mean
## "use the built-in default", reported with the emulator-default caveat.
##
## The default anchor is derived from the matched config's parent dir, which
## is correct for every in-scope layout (Cemu sets user data path = config
## path in all of them):
##   portable:  {emulator_dir}/portable/settings.xml -> {emulator_dir}/portable
##   legacy:    {emulator_dir}/settings.xml          -> {emulator_dir}
##   android:   {app_data}/settings.xml              -> {app_data}
## Non-portable desktop installs (%APPDATA%/Cemu, XDG split dirs) are out of
## scope; their configs are never candidates, so they resolve default-only.
## Relative mlc_path values anchor at the config's parent (Cemu itself
## resolves them against its CWD, the exe dir; absolute paths are the norm).
##
## Pass 1 scope: save kind only (the wiiu platform declares no firmware
## contract); firmware resolves key-absent and the caller's defaults apply.
## The result points at the 00050000 root (<mlc>/usr/save/00050000/), the
## granularity discovery and the registry default both assume.
class_name CemuXmlResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

const DEFAULT_SUFFIX := "/mlc01/usr/save/00050000/"
const CUSTOM_SUFFIX := "/usr/save/00050000/"

## Resolves one placement from the context RSM built.
## context: {config_path, config_status} ("anchor" is intentionally unused;
## the default anchor is the matched config's parent dir)
static func resolve(kind: String, context: Dictionary) -> Dictionary:
	var result := {
		"path": "",
		"source": "default",
		"config_file": "",
		"key": "",
		"caveat": "",
	}

	if kind != "save":
		result.caveat = "key-absent"
		return result

	var config_path: String = context.get("config_path", "")
	if config_path == "" or context.get("config_status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-missing"
		return result

	var parsed: Dictionary = CSM.read_config(config_path, CSM.Format.RAW)
	if parsed.get("status", CSM.Status.MISSING) != CSM.Status.OK:
		result.caveat = "config-unreadable"
		return result

	return _resolve_from_text(str(parsed.get("text", "")), config_path)

## Core logic on raw settings.xml text, split from resolve() so it stays
## testable without the CSM/FSM autoload chain.
static func _resolve_from_text(text: String, config_path: String) -> Dictionary:
	var result := {
		"path": "",
		"source": "config",
		"config_file": config_path,
		"key": "mlc_path",
		"caveat": "",
	}

	var anchor := config_path.get_base_dir()
	var mlc := _extract_mlc_path(text)
	if mlc == "":
		result.caveat = "emulator-default"
		result.path = anchor + DEFAULT_SUFFIX
		return result

	# A configured mlc_path points AT the mlc root itself (Cemu's GetMlcPath
	# returns it verbatim), so only the save subtree is appended here.
	mlc = mlc.replace("\\", "/").rstrip("/")
	if not mlc.is_absolute_path():
		mlc = anchor + "/" + mlc
	result.path = mlc.simplify_path().rstrip("/") + CUSTOM_SUFFIX
	return result

## Extracts the mlc_path element's text. "" for absent, self-closing, or
## empty elements (all equivalent to Cemu's parser.get("mlc_path", "")).
static func _extract_mlc_path(text: String) -> String:
	var paired := RegEx.new()
	paired.compile("<mlc_path[^>]*>(.*?)</mlc_path>")
	var m := paired.search(text)
	var value := ""
	if m:
		value = m.get_string(1)
	return _unescape(value.strip_edges())

static func _unescape(value: String) -> String:
	value = value.replace("&lt;", "<").replace("&gt;", ">")
	value = value.replace("&quot;", "\"").replace("&apos;", "'")
	return value.replace("&amp;", "&")
