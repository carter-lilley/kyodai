## Runner for the bundled argosy-sigil CLI.
## Extracts platform-native title IDs from ROM files via an external process.
## Binary lives at res://bin/sigil/<platform>/ and is extracted to user://bin/
## on packaged builds.
class_name SigilRunner

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const _AndroidBinaryExtractor = preload("res://utils/launch/android_binary_extractor.gd")

## Kyodai slug -> sigil slug (all others match 1:1)
const SLUG_MAP := {
	"ngc": "gamecube",
}

const SUPPORTED_SLUGS := ["psp", "psx", "ps2", "switch", "3ds", "wii", "wiiu", "gamecube"]

static func sigil_slug_for(platform_slug: String) -> String:
	var slug: String = SLUG_MAP.get(platform_slug, platform_slug)
	return slug if slug in SUPPORTED_SLUGS else ""

static func is_supported(platform_slug: String) -> bool:
	return sigil_slug_for(platform_slug) != ""

static func _get_sigil_path() -> String:
	var base_path = "res://bin/sigil/"
	if SystemManager.platform.is_windows():
		return _AndroidBinaryExtractor.extract_binary(base_path + "win/sigil.exe", "sigil.exe")
	elif SystemManager.platform.is_linux():
		return _AndroidBinaryExtractor.extract_binary(base_path + "linux/sigil", "sigil")
	elif SystemManager.platform.is_android():
		# Android 10+ (targetSdk 29+) SELinux policy denies executing binaries from
		# the app's private data dir. Sigil is shipped as a fake native library
		# (libsigil.so in jniLibs) so the package manager extracts it to
		# nativeLibraryDir, where execution is allowed.
		var plugin = Engine.get_singleton("PackageChecker") if Engine.has_singleton("PackageChecker") else null
		if plugin == null:
			push_error("[SigilRunner] PackageChecker plugin not available")
			return ""
		var lib_dir: String = plugin.call("getNativeLibraryDir")
		if lib_dir == "":
			push_error("[SigilRunner] Failed to resolve nativeLibraryDir")
			return ""
		var sigil_path = lib_dir + "/libsigil.so"
		if not FileAccess.file_exists(sigil_path):
			push_error("[SigilRunner] libsigil.so not found in nativeLibraryDir: " + sigil_path)
			return ""
		return sigil_path
	else:
		push_error("[SigilRunner] Unsupported platform for sigil")
		return ""

## Runs sigil on a ROM and returns the parsed result:
## {title_id, save_id, raw_serial, usage, source, experimental}
## Returns an empty Dictionary on any failure.
static func extract(rom_path: String, platform_slug: String, prod_keys_path: String = "") -> Dictionary:
	var slug = sigil_slug_for(platform_slug)
	if slug == "" or rom_path == "":
		return {}

	var sigil_path = _get_sigil_path()
	if sigil_path == "":
		return {}

	var abs_sigil = FSM.resolve_path(sigil_path, {"format": FSM.PathFormat.ABSOLUTE})
	var abs_rom = FSM.resolve_path(rom_path, {"format": FSM.PathFormat.ABSOLUTE})

	var args = ["--platform=" + slug]
	if prod_keys_path != "":
		var usable_keys = _stage_prod_keys_if_needed(prod_keys_path)
		if usable_keys != "":
			args.append("--prod-keys=" + FSM.resolve_path(usable_keys, {"format": FSM.PathFormat.ABSOLUTE}))
	args.append(abs_rom)

	var output = []
	var exit_code = OS.execute(abs_sigil, args, output, true)
	if exit_code != 0:
		push_warning("[SigilRunner] sigil exited with code " + str(exit_code) + " for: " + rom_path)
		return {}

	return _parse_output(output, rom_path, slug)

static func _parse_output(lines: Array, rom_path: String, slug: String) -> Dictionary:
	var fields := {}
	for line in lines:
		for token in String(line).strip_edges().split(" ", false):
			var kv = token.split("=", false, 1)
			if kv.size() == 2:
				fields[kv[0]] = kv[1]

	var result := {
		"title_id": _normalize_hex_id(fields.get("title_id", ""), slug),
		"save_id": _normalize_hex_id(fields.get("save_id", ""), slug),
		"raw_serial": fields.get("raw_serial", ""),
		"usage": fields.get("usage", ""),
		"source": fields.get("source", ""),
		"experimental": fields.get("experimental", "0") == "1",
	}

	if result.title_id == "":
		push_warning("[SigilRunner] sigil returned no title_id for: " + rom_path)
		return {}

	if result.experimental:
		print("[SigilRunner] experimental extractor result for: " + rom_path)
	if result.source == "filename":
		print("[SigilRunner] title_id derived from filename (low confidence): " + rom_path)

	return result

## Sigil runs as an external process, which cannot read SAF-protected
## /Android/data/ paths (e.g. prod.keys inside an emulator's data dir).
## Stage a copy under user:// (directly readable) in that case.
static func _stage_prod_keys_if_needed(prod_keys_path: String) -> String:
	if prod_keys_path == "":
		return ""
	var normalized = prod_keys_path.replace("\\", "/")
	if not (normalized.contains("/Android/data/") or normalized.contains("/Android/obb/")):
		return prod_keys_path

	var staged_path = "user://temp/sigil/prod.keys"
	var data = FSM.read_file_bytes(prod_keys_path)
	if data.is_empty():
		push_warning("[SigilRunner] Failed to read prod keys for staging: " + prod_keys_path)
		return ""
	FSM.make_dir_recursive("user://temp/sigil")
	if not FSM.write_file_bytes(staged_path, data):
		push_warning("[SigilRunner] Failed to stage prod keys to: " + staged_path)
		return ""
	return staged_path

## Sigil emits hex-format IDs uppercase; kyodai's stored case differs per
## platform: switch legacy IDs are uppercase hex, everything else lowercase.
## Only touches values that are pure hex (ignoring / and - separators),
## so serials like SLUS-20152 or ULUS10064 pass through unchanged.
static func _normalize_hex_id(id: String, slug: String) -> String:
	var stripped = id.replace("/", "").replace("-", "")
	if stripped == "":
		return id
	for i in range(stripped.length()):
		var c = stripped[i]
		if not ((c >= '0' and c <= '9') or (c >= 'A' and c <= 'F') or (c >= 'a' and c <= 'f')):
			return id
	return id.to_upper() if slug == "switch" else id.to_lower()
