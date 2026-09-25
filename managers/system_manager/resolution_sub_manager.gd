# SystemManager.resolution - Config-first emulator path resolution.
## Orchestrates the universal flow for every emulator: read the emulator's
## "resolution" block from the registry, locate its config on the machine,
## dispatch to the named strategy, and return a provenance-carrying result.
## Emulators without a resolution block resolve as source "default" and the
## caller's JSON default paths apply. Results are cached per config mtime.
##
## Result shape:
##   path                 resolved directory with trailing "/", "" when unset
##   source               "config" | "default" | "unknown"
##   config_file          the config file that produced the value
##   key                  the key that produced the value
##   caveat               "" | no-resolution-block | config-missing |
##                        config-unreadable | key-absent | default-value |
##                        emulator-default | file-card | raw-memcard-mode |
##                        unknown-emulator | unknown-strategy

extends Manager
class_name ResolutionSubManager

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const CSM = preload("res://managers/system_manager/config_sub_manager.gd")
const RetroArchCfg = preload("res://utils/config_resolvers/retroarch_cfg.gd")
const Pcsx2Ini = preload("res://utils/config_resolvers/pcsx2_ini.gd")
const Rpcs3Vfs = preload("res://utils/config_resolvers/rpcs3_vfs.gd")
const CemuXml = preload("res://utils/config_resolvers/cemu_xml.gd")
const AzaharIni = preload("res://utils/config_resolvers/azahar_ini.gd")
const DolphinIni = preload("res://utils/config_resolvers/dolphin_ini.gd")
const MelondsIni = preload("res://utils/config_resolvers/melonds_ini.gd")
const PpssppIni = preload("res://utils/config_resolvers/ppsspp_ini.gd")
const EdenIni = preload("res://utils/config_resolvers/eden_ini.gd")
const XeniaToml = preload("res://utils/config_resolvers/xenia_toml.gd")
const Vita3kYml = preload("res://utils/config_resolvers/vita3k_yml.gd")
const XemuToml = preload("res://utils/config_resolvers/xemu_toml.gd")
const JsonKv = preload("res://utils/config_resolvers/json_kv.gd")

## Converts Godot virtual paths (user://, res://) to OS-native absolute paths
## so external emulators can read them. Other paths pass through unchanged.
static func _globalize_path(path: String) -> String:
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	return path

## Resolution cache: cache key -> {mtime, result}. Entries are only stored
## when a config file was actually read; a missing config is re-probed.
## Access is mutex-guarded: firmware precompute resolves on the DB worker
## thread while the main thread resolves for launches.
static var _cache: Dictionary = {}
static var _cache_mutex := Mutex.new()
const CACHE_VERSION: int = 1  # Bump when resolver logic changes

static func resolve_save_dir(emulator_id: String, platform_slug: String = "", core_id: String = "", allow_core_override: bool = true) -> Dictionary:
	return _resolve("save", emulator_id, platform_slug, core_id, allow_core_override)

static func resolve_firmware_dir(emulator_id: String, platform_slug: String = "", core_id: String = "", allow_core_override: bool = true) -> Dictionary:
	return _resolve("firmware", emulator_id, platform_slug, core_id, allow_core_override)

## Enforces Kyodai-managed data paths in the emulator's live config file.
## Uses the same config candidate selection that resolve() uses, so the writer
## always targets the config the emulator is actually reading. If no candidate
## exists yet, the first/preferred candidate is created.
static func enforce_paths(emulator_id: String, platform_slug: String = "", core_id: String = "") -> bool:
	if not is_instance_valid(LaunchManager):
		return false
	var emulator: Dictionary = LaunchManager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		return false

	var block: Dictionary = emulator.get("resolution", {})
	if core_id != "":
		var core_res: Dictionary = LaunchManager.registry.get_core_config(emulator_id, platform_slug, core_id).get("resolution", {})
		if not core_res.is_empty():
			block = core_res

	var enforce_cfg: Dictionary = block.get("enforce", {})
	if enforce_cfg.is_empty():
		return true

	var platform_name: String = SystemManager.platform.get_platform_name().to_lower()
	var platform_enforce: Dictionary = enforce_cfg.get(platform_name, {})
	if platform_enforce.is_empty():
		platform_enforce = enforce_cfg.get("_default", {})
	if platform_enforce.is_empty():
		return true

	# Target Kyodai's preferred config candidate (first in the list), creating
	# it if necessary so enforcement always writes the layout we want.
	var config_info := _resolve_config_path(block, emulator_id, platform_slug, core_id, true)
	var config_path: String = config_info.get("path", "")
	if config_path == "":
		push_error("[ResolutionManager] Could not resolve a config path to enforce for %s" % emulator_id)
		return false

	var sections_raw: Dictionary = platform_enforce.get("sections", {})
	var sections: Dictionary = {}
	for section_name in sections_raw:
		sections[section_name] = {}
		for key in sections_raw[section_name]:
			var value_template: String = str(sections_raw[section_name][key])
			# Only treat values with wildcards as paths; literals (booleans,
			# numeric strings, etc.) pass through unchanged.
			var resolved := value_template
			if value_template.contains("{") and value_template.contains("}"):
				resolved = FSM.resolve_emulator_path(value_template, emulator_id, platform_slug)
			# External emulators need OS-native paths, not Godot virtual paths.
			sections[section_name][key] = _globalize_path(resolved)

	var context := {
		"emulator_id": emulator_id,
		"platform_slug": platform_slug,
		"core_id": core_id,
		"config_path": config_path,
		"config_status": CSM.Status.OK if FSM.file_exists(config_path) else CSM.Status.MISSING,
	}

	var strategy: String = block.get("strategy", "")
	match strategy:
		"eden_ini":
			return EdenIni.enforce_paths(context, sections)
		"azahar_ini":
			return AzaharIni.enforce_paths(context, sections)
		"pcsx2_ini":
			return Pcsx2Ini.enforce_paths(context, sections)
		"dolphin_ini":
			return DolphinIni.enforce_paths(context, sections)
		"ppsspp_ini":
			return PpssppIni.enforce_paths(context, sections)
		"retroarch_cfg":
			return RetroArchCfg.enforce_paths(context, sections)
		"rpcs3_vfs":
			return Rpcs3Vfs.enforce_paths(context, sections)
		"cemu_xml":
			return CemuXml.enforce_paths(context, sections)
		"melonds_ini":
			return MelondsIni.enforce_paths(context, sections)
		"xenia_toml":
			return XeniaToml.enforce_paths(context, sections)
		"vita3k_yml":
			return Vita3kYml.enforce_paths(context, sections)
		"xemu_toml":
			return XemuToml.enforce_paths(context, sections)
		"json_kv":
			return JsonKv.enforce_paths(context, sections)
		_:
			# No writer implemented for this strategy yet; not an error.
			return true

## Composes a registry path template anchored on {save_root}/{system_root}
## against the config-resolved roots. Fallback roots come from the emulator's
## default_saves/default_firmware (save fallback appends the core save_name,
## reproducing the layout the registry's old baked paths assumed).
## Returns {path, source, caveat}.
static func compose_template(template: String, emulator_id: String, platform_slug: String = "", core_id: String = "", allow_core_override: bool = true) -> Dictionary:
	var result := {"path": "", "source": "default", "caveat": ""}
	if template.is_empty():
		return result
	var source := "default"
	var caveat := ""

	if template.contains("{save_root}"):
		var sr := resolve_save_dir(emulator_id, platform_slug, core_id, allow_core_override)
		var save_root: String = sr.get("path", "")
		if sr.get("source", "") == "config" and save_root != "":
			source = "config"
		else:
			caveat = sr.get("caveat", "")
			save_root = _default_root("save", emulator_id, platform_slug)
			var save_name := _core_save_name(emulator_id, platform_slug, core_id)
			if save_root != "" and save_name != "":
				save_root = save_root.rstrip("/") + "/" + save_name + "/"
		if save_root == "":
			result.caveat = caveat
			return result
		template = template.replace("{save_root}", save_root.rstrip("/"))

	if template.contains("{system_root}"):
		var fr := resolve_firmware_dir(emulator_id, platform_slug, core_id, allow_core_override)
		var sys_root: String = fr.get("path", "")
		if fr.get("source", "") == "config" and sys_root != "":
			source = "config"
		else:
			if caveat == "":
				caveat = fr.get("caveat", "")
			sys_root = _default_root("firmware", emulator_id, platform_slug)
		if sys_root == "":
			result.caveat = caveat
			return result
		template = template.replace("{system_root}", sys_root.rstrip("/"))

	result.source = source
	result.caveat = caveat
	result.path = FSM.resolve_emulator_path(template, emulator_id, platform_slug)
	M3Debug.geom("RSM", "compose %s/%s/%s -> %s (%s%s)" % [
		emulator_id, platform_slug, core_id,
		result.path, source, " caveat=" + caveat if caveat != "" else "",
	])
	return result

## Resolves the emulator-level default root ("default_saves"/"default_firmware"
## _default block) with wildcards. "" when the registry declares none.
static func _default_root(kind: String, emulator_id: String, platform_slug: String) -> String:
	if not is_instance_valid(LaunchManager):
		return ""
	var emulator: Dictionary = LaunchManager.registry.get_emulator(emulator_id)
	var key := "default_saves" if kind == "save" else "default_firmware"
	var cfg: Dictionary = emulator.get("paths", {}).get(key, {}).get("_default", {})
	var directories: Dictionary = cfg.get("directories", {})
	var platform_name: String = SystemManager.platform.get_platform_name().to_lower()
	var dir: String = directories.get(platform_name, directories.get("all", ""))
	if dir == "":
		return ""
	return FSM.resolve_emulator_path(dir, emulator_id, platform_slug).rstrip("/") + "/"

static func _core_save_name(emulator_id: String, platform_slug: String, core_id: String) -> String:
	if core_id == "" or platform_slug == "" or not is_instance_valid(LaunchManager):
		return ""
	return LaunchManager.registry.get_core_config(emulator_id, platform_slug, core_id).get("save_name", "")

## Resolves a config path from a resolution block's config_candidates.
## Returns {path, status}.
##   prefer_first=false (resolve/read mode): first existing candidate wins;
##     with candidate_selection="newest_mtime", the newest existing candidate
##     wins. If none exist, returns empty.
##   prefer_first=true (enforce/write mode): always returns the first candidate,
##     creating its parent directories if missing. This lets Kyodai force its
##     preferred layout (e.g. portable user/) even when a non-preferred config
##     already exists elsewhere.
## allow_core_override=false prevents recursion when a core-level block uses
## {save_root}/{system_root} placeholders.
static func _resolve_config_path(block: Dictionary, emulator_id: String, platform_slug: String, core_id: String, prefer_first: bool = false, allow_core_override: bool = false) -> Dictionary:
	var result := {"path": "", "status": CSM.Status.MISSING}
	var platform_name: String = SystemManager.platform.get_platform_name().to_lower()
	var candidates: Array = block.get("config_candidates", {}).get(platform_name, [])
	if candidates.is_empty():
		return result

	if prefer_first:
		var first := str(candidates[0])
		var resolved := ""
		if first.contains("{save_root}") or first.contains("{system_root}"):
			resolved = compose_template(first, emulator_id, platform_slug, core_id, allow_core_override).get("path", "")
		else:
			resolved = FSM.resolve_emulator_path(first, emulator_id, platform_slug)
		if resolved != "":
			var parent_dir := resolved.get_base_dir()
			if parent_dir != "" and not FSM.dir_exists(parent_dir):
				FSM.make_dir_recursive(parent_dir)
			result.path = resolved
		return result

	var select_newest := str(block.get("candidate_selection", "")) == "newest_mtime"
	var best_mtime := -1
	var best_path := ""
	for candidate in candidates:
		var candidate_str := str(candidate)
		var resolved := ""
		if candidate_str.contains("{save_root}") or candidate_str.contains("{system_root}"):
			resolved = compose_template(candidate_str, emulator_id, platform_slug, core_id, allow_core_override).get("path", "")
		else:
			resolved = FSM.resolve_emulator_path(candidate_str, emulator_id, platform_slug)
		if resolved == "" or not FSM.file_exists(resolved):
			continue
		if select_newest:
			var candidate_mtime := int(FileAccess.get_modified_time(resolved))
			if candidate_mtime > best_mtime:
				best_mtime = candidate_mtime
				best_path = resolved
		else:
			result.path = resolved
			result.status = CSM.Status.OK
			return result

	if select_newest and best_path != "":
		result.path = best_path
		result.status = CSM.Status.OK
		return result

	return result

static func _resolve(kind: String, emulator_id: String, platform_slug: String, core_id: String, allow_core_override: bool = true) -> Dictionary:
	var result := {
		"path": "",
		"source": "unknown",
		"config_file": "",
		"key": "",
		"caveat": "",
	}

	if not is_instance_valid(LaunchManager):
		result.caveat = "unknown-emulator"
		return result
	var emulator: Dictionary = LaunchManager.registry.get_emulator(emulator_id)
	if emulator.is_empty():
		result.caveat = "unknown-emulator"
		return result

	var block: Dictionary = emulator.get("resolution", {})
	# A core block may carry its own resolution block (strategy + candidates);
	# it overrides the emulator-level one. allow_core_override=false suppresses
	# this so root composition for {save_root} candidates cannot recurse into
	# the same core-level resolver.
	if allow_core_override and core_id != "":
		var core_res: Dictionary = LaunchManager.registry.get_core_config(emulator_id, platform_slug, core_id).get("resolution", {})
		if not core_res.is_empty():
			block = core_res
	if block.is_empty():
		result.source = "default"
		result.caveat = "no-resolution-block"
		return result

	var strategy: String = block.get("strategy", "")
	var platform_name: String = SystemManager.platform.get_platform_name().to_lower()

	# First existing config candidate wins; candidates may carry wildcards,
	# including {save_root}/{system_root} (composed config-first via the
	# emulator-level resolution so a core-level block cannot recurse).
	# candidate_selection="newest_mtime" instead picks the existing candidate
	# with the newest mtime (android PPSSPP: live ini follows the memstick,
	# stale copies may linger at prior locations).
	var config_info := _resolve_config_path(block, emulator_id, platform_slug, core_id, false, false)
	var config_path: String = config_info.get("path", "")
	var config_status: int = config_info.get("status", CSM.Status.MISSING)

	var core_save_name := _core_save_name(emulator_id, platform_slug, core_id)

	var anchor_raw := str(block.get("anchor", ""))
	var context := {
		"kind": kind,
		"emulator_id": emulator_id,
		"platform_slug": platform_slug,
		"core_id": core_id,
		"core_save_name": core_save_name,
		"config_path": config_path,
		"config_status": config_status,
		"anchor": FSM.resolve_emulator_path(anchor_raw, emulator_id, platform_slug).rstrip("/") if anchor_raw != "" else "",
	}

	# mtime-keyed cache: re-resolve only when the config changed on disk.
	# The no-override variant resolves through a different block, so it gets
	# its own cache namespace.
	var cache_key := "%s:%s:%s:%s:%d%s" % [kind, emulator_id, platform_slug, core_id, CACHE_VERSION, "" if allow_core_override else ":nooverride"]
	var mtime := 0
	if config_status == CSM.Status.OK:
		mtime = int(FileAccess.get_modified_time(config_path))
	_cache_mutex.lock()
	if config_status != CSM.Status.OK:
		_cache.erase(cache_key)
	elif _cache.has(cache_key) and _cache[cache_key].get("mtime", -1) == mtime:
		var cached: Dictionary = _cache[cache_key].result
		_cache_mutex.unlock()
		return cached
	_cache_mutex.unlock()

	match strategy:
		"retroarch_cfg":
			result = RetroArchCfg.resolve(kind, context)
		"pcsx2_ini":
			result = Pcsx2Ini.resolve(kind, context)
		"rpcs3_vfs":
			result = Rpcs3Vfs.resolve(kind, context)
		"cemu_xml":
			result = CemuXml.resolve(kind, context)
		"azahar_ini":
			result = AzaharIni.resolve(kind, context)
		"dolphin_ini":
			result = DolphinIni.resolve(kind, context)
		"melonds_ini":
			result = MelondsIni.resolve(kind, context)
		"ppsspp_ini":
			result = PpssppIni.resolve(kind, context)
		"eden_ini":
			result = EdenIni.resolve(kind, context)
		"xenia_toml":
			result = XeniaToml.resolve(kind, context)
		"vita3k_yml":
			result = Vita3kYml.resolve(kind, context)
		"xemu_toml":
			result = XemuToml.resolve(kind, context)
		"json_kv":
			result = JsonKv.resolve(kind, context)
		_:
			result.caveat = "unknown-strategy"

	if config_status == CSM.Status.OK:
		_cache_mutex.lock()
		_cache[cache_key] = {"mtime": mtime, "result": result}
		_cache_mutex.unlock()

	M3Debug.geom("RSM", "%s %s/%s/%s -> %s (%s%s)" % [
		kind, emulator_id, platform_slug, core_id,
		result.get("path", "?"), result.get("source", "?"),
		" caveat=" + result.caveat if result.get("caveat", "") != "" else "",
	])
	return result
