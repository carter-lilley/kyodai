## Config-first resolver for the Dolphin family's Dolphin.ini.
## Save roots live in two sections of the plain INI at <user dir>/Config/Dolphin.ini:
##
##   [Core]
##   SlotA = GCI Folder          - memory card device (default: GCI Folder)
##   GCIFolderAPath =            - custom GCI folder base (region dir appended)
##   [General]
##   NANDRootPath =              - custom Wii NAND root
##
## This is deliberately NOT an INI parser: Dolphin writes plain "key = value"
## lines, and EXIDeviceType has appeared both as an int (older builds) and as
## the EnumFormatter display string ("GCI Folder"/"Memory Card"), so keys are
## matched by line scan and SlotA values are compared defensively.
##
## Semantics (dolphin-emu MainSettings.cpp / GetGCIFolderPath / GetMemcardPath):
##   SlotA absent or GCI Folder - saves live in GCI folders under <user>/GC;
##                                GCIFolderAPath, when set, replaces the base
##                                (the region dir is appended by Dolphin and by
##                                kyodai downstream, so it is stripped here).
##   SlotA Memory Card (raw)    - unsupported mode: kyodai mandates GCI folder
##                                (mirrors the ps2 folder-card mandate). The GC
##                                base is returned with the raw-memcard-mode
##                                caveat so provenance stays honest; the raw
##                                card image is never touched.
##   NANDRootPath set           - Wii saves under <NANDRootPath>/title/00010000
##   anything else              - built-in defaults under the config's
##                                grandparent dir (the User dir), reported with
##                                the emulator-default caveat.
## The default anchor is the config's grandparent: Dolphin.ini lives at
## <user dir>/Config/Dolphin.ini in every in-scope layout (portable installs,
## the only mode kyodai manages, and the libretro core's
## <save_root>/User/Config/Dolphin.ini). Non-portable installs are out of scope.
##
## Pass 1 scope: save kind only (ngc + wii); firmware resolves key-absent.
## Region subtrees (GC/<USA|JPN|EUR>/Card A) and the WiiWare 00010004 sibling
## are handled downstream in GameSaveSubManager.
class_name DolphinIniResolver

const CSM = preload("res://managers/system_manager/config_sub_manager.gd")

## SlotA serializations meaning "raw .raw card image" (int form from older
## builds, EnumFormatter display string from modern builds).
const RAW_CARD_VALUES := ["1", "memory card"]

## Dolphin region dirs appended to GC bases (Modern + Legacy styles).
const REGION_DIRS := ["USA", "JPN", "JAP", "EUR", "DEV", "KOR"]

## Resolves one placement from the context RSM built.
## context: {config_path, config_status, platform_slug}
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

	var platform_slug: String = context.get("platform_slug", "")
	if platform_slug != "ngc" and platform_slug != "wii":
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

	return _resolve_from_text(str(parsed.get("text", "")), config_path, platform_slug)

## Core logic on raw Dolphin.ini text, split from resolve() so it stays
## testable without the CSM/FSM autoload chain.
static func _resolve_from_text(text: String, config_path: String, platform_slug: String) -> Dictionary:
	var result := {
		"path": "",
		"source": "config",
		"config_file": config_path,
		"key": "",
		"caveat": "",
	}

	var anchor := config_path.get_base_dir().get_base_dir()
	var sections := _scan_sections(text)

	if platform_slug == "wii":
		result.key = "NANDRootPath"
		var nand := _normalize(str(sections.get("General", {}).get("NANDRootPath", "")))
		if nand == "":
			result.caveat = "emulator-default"
			result.path = anchor + "/Wii/title/00010000/"
			return result
		if not nand.is_absolute_path():
			nand = anchor + "/" + nand
		result.path = nand.simplify_path().rstrip("/") + "/title/00010000/"
		return result

	# ngc
	var core: Dictionary = sections.get("Core", {})
	result.key = "GCIFolderAPath"
	var slot_a := str(core.get("SlotA", "")).strip_edges().to_lower()
	if RAW_CARD_VALUES.has(slot_a):
		result.caveat = "raw-memcard-mode"
		result.key = "SlotA"
		result.path = anchor + "/GC/"
		return result

	var gci_base := _normalize(str(core.get("GCIFolderAPath", "")))
	if gci_base == "":
		result.caveat = "emulator-default"
		result.path = anchor + "/GC/"
		return result

	# Dolphin stores custom GCI bases with a "/<region>" suffix that it
	# replaces per game region; strip it so downstream region logic applies.
	gci_base = gci_base.rstrip("/")
	for region in REGION_DIRS:
		if gci_base.to_lower().ends_with("/" + region.to_lower()):
			gci_base = gci_base.substr(0, gci_base.length() - region.length() - 1)
			break
	if not gci_base.is_absolute_path():
		gci_base = anchor + "/" + gci_base
	result.path = gci_base.simplify_path().rstrip("/") + "/"
	return result

## Collects sections as {section_name: {key: value}}. Dolphin's INI is plain:
## "key = value" lines, no escaping, no companion keys.
static func _scan_sections(text: String) -> Dictionary:
	var sections := {}
	var current := ""
	for raw_line in text.split("\n"):
		var line := raw_line.rstrip("\r").strip_edges()
		if line == "":
			continue
		if line.begins_with("["):
			current = line.trim_prefix("[").trim_suffix("]").strip_edges()
			if not sections.has(current):
				sections[current] = {}
			continue
		if line.begins_with("#") or line.begins_with(";"):
			continue
		var sep := line.find("=")
		if sep < 0:
			continue
		sections[current][line.substr(0, sep).strip_edges()] = line.substr(sep + 1).strip_edges()
	return sections

static func _normalize(value: String) -> String:
	return value.replace("\\", "/").strip_edges()
