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
## is correct for the layouts where Cemu sets user data path = config path:
##   portable:  {emulator_dir}/portable/settings.xml -> {emulator_dir}/portable
##   legacy:    {emulator_dir}/settings.xml          -> {emulator_dir}
##   android:   {app_data}/settings.xml              -> {app_data}
## The kyodai-managed Linux layout redirects XDG at launch, splitting config
## and data; Cemu's default mlc anchors at the user data path there, not the
## config's parent:
##   linux-xdg: {emulator_dir}/.config/Cemu/settings.xml -> {emulator_dir}/.local/share/Cemu
## Non-portable desktop installs outside kyodai's XDG redirect (%APPDATA%/Cemu,
## system XDG dirs) are out of scope; their configs are never candidates, so
## they resolve default-only.
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
		# XDG split layout: the config lives under .config/Cemu but the
		# default mlc anchors at the user data path, .local/share/Cemu.
		var normalized_anchor := anchor.replace("\\", "/")
		if normalized_anchor.ends_with("/.config/Cemu"):
			anchor = normalized_anchor.substr(0, normalized_anchor.length() - "/.config/Cemu".length()) + "/.local/share/Cemu"
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

## Reads one element's text from settings.xml for the caller's
## already-enforced check (CSM has no XML value reader). null when the
## element is absent or empty.
static func read_key(config_path: String, key: String) -> Variant:
	if key != "mlc_path" or not FSM.file_exists(config_path):
		return null
	var value := _extract_mlc_path(FSM.read_file(config_path))
	if value == "":
		return null
	return value

## Enforces Cemu's <mlc_path> element in settings.xml.
static func enforce_paths(context: Dictionary, sections: Dictionary) -> bool:
	var config_path: String = context.get("config_path", "")
	if config_path == "":
		push_error("[CemuXmlResolver] enforce_paths called without config_path")
		return false

	var flat: Dictionary = sections.get("", {})
	var mlc_path: String = flat.get("mlc_path", "")
	if mlc_path == "":
		# Nothing to enforce for this resolver.
		return true

	var text := ""
	if FSM.file_exists(config_path):
		text = FSM.read_file(config_path)
		var backup_path := config_path + ".kyodai-backup"
		if not FSM.file_exists(backup_path):
			FSM.write_file(backup_path, text)

	var paired := RegEx.new()
	paired.compile("<mlc_path[^>]*>(.*?)</mlc_path>")
	if paired.search(text) != null:
		text = paired.sub(text, "<mlc_path>" + _escape_xml(mlc_path) + "</mlc_path>", true)
	else:
		if not text.contains("<content>"):
			text += "<content>\n</content>\n"
		var content_open := RegEx.new()
		content_open.compile("<content>")
		text = content_open.sub(text, "<content>\n  <mlc_path>" + _escape_xml(mlc_path) + "</mlc_path>", true)

	var parent_dir := config_path.get_base_dir()
	if parent_dir != "" and not FSM.dir_exists(parent_dir):
		FSM.make_dir_recursive(parent_dir)

	if not FSM.write_file(config_path, text):
		push_error("[CemuXmlResolver] Failed to write enforced config: " + config_path)
		return false
	print("[CemuXmlResolver] Enforced paths in " + config_path)
	return true

static func _escape_xml(value: String) -> String:
	return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
