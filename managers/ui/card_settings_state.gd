class_name CardSettingsState
extends RefCounted

## Centralized, typed state for all grid/card-related settings.
##
## Owned by UIManager. Updated only from SettingsManager preset/apply paths.
## Broadcasts bitmask-based change events so consumers can react with the
## minimum work required (layout recalc, effect rebuild, display refresh, etc.).

enum ChangeMask {
	NONE = 0,
	LAYOUT = 1,       ## layout_mode, grid_vertical, card_zoom_ratio, grid_padding, focus_scale_ratio
	EFFECTS = 2,      ## card_effect_config (base + focus effects, corner rounding)
	DISPLAY = 4,      ## display_mode, show_title_mode, content_alignment
	MEDIA_SHAPE = 8,  ## media_aspect_ratio
	THEME = 16,       ## dark_mode, primary_color
	FOCUS_LOCK = 32,  ## focus_lock_enabled
}

# ---------------------------------------------------------------------------
# State fields (mirrors Settings, but is the canonical runtime copy for UI)
# ---------------------------------------------------------------------------
var layout_mode: int = 0
var grid_vertical: bool = true
var card_zoom_ratio: float = 0.25
var grid_padding: int = 22
var focus_scale_ratio: float = 0.09
var display_mode: int = 0
var content_alignment: int = 0
var media_aspect_ratio: int = 0
var show_title_mode: int = 0
var card_effect_config: Dictionary = {}
var dark_mode: bool = true
var primary_color: Color = Color.WHITE
var focus_lock_enabled: bool = false

# ---------------------------------------------------------------------------
# Batch / change coalescing
# ---------------------------------------------------------------------------
var pending_mask: int = 0
var _batch_depth: int = 0

signal changed(mask: int)

func begin_batch() -> void:
	_batch_depth += 1

func end_batch() -> void:
	_batch_depth = max(0, _batch_depth - 1)
	if _batch_depth == 0 and pending_mask != 0:
		var mask := pending_mask
		pending_mask = 0
		changed.emit(mask)

func _mark(mask: int) -> void:
	if _batch_depth > 0:
		pending_mask |= mask
	else:
		changed.emit(mask)

# ---------------------------------------------------------------------------
# Setters (return true when value changed)
# ---------------------------------------------------------------------------
func set_layout_mode(value: int) -> bool:
	if layout_mode == value:
		return false
	layout_mode = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_grid_vertical(value: bool) -> bool:
	if grid_vertical == value:
		return false
	grid_vertical = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_card_zoom_ratio(value: float) -> bool:
	if is_equal_approx(card_zoom_ratio, value):
		return false
	card_zoom_ratio = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_grid_padding(value: int) -> bool:
	if grid_padding == value:
		return false
	grid_padding = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_focus_scale_ratio(value: float) -> bool:
	if is_equal_approx(focus_scale_ratio, value):
		return false
	focus_scale_ratio = value
	_mark(ChangeMask.LAYOUT)
	return true

func set_display_mode(value: int) -> bool:
	if display_mode == value:
		return false
	display_mode = value
	_mark(ChangeMask.DISPLAY)
	return true

func set_content_alignment(value: int) -> bool:
	if content_alignment == value:
		return false
	content_alignment = value
	_mark(ChangeMask.DISPLAY)
	return true

func set_show_title_mode(value: int) -> bool:
	if show_title_mode == value:
		return false
	show_title_mode = value
	_mark(ChangeMask.DISPLAY)
	return true

func set_media_aspect_ratio(value: int) -> bool:
	if media_aspect_ratio == value:
		return false
	media_aspect_ratio = value
	_mark(ChangeMask.MEDIA_SHAPE)
	return true

func set_card_effect_config(value: Dictionary) -> bool:
	# Compare by hash to avoid redundant emissions when dictionaries are identical
	if card_effect_config.hash() == value.hash():
		return false
	card_effect_config = value.duplicate(true)
	_mark(ChangeMask.EFFECTS)
	return true

func set_dark_mode(value: bool) -> bool:
	if dark_mode == value:
		return false
	dark_mode = value
	_mark(ChangeMask.THEME)
	return true

func set_primary_color(value: Color) -> bool:
	if primary_color.is_equal_approx(value):
		return false
	primary_color = value
	_mark(ChangeMask.THEME)
	return true

func set_focus_lock_enabled(value: bool) -> bool:
	if focus_lock_enabled == value:
		return false
	focus_lock_enabled = value
	_mark(ChangeMask.FOCUS_LOCK)
	return true

# ---------------------------------------------------------------------------
# Derived helpers
# ---------------------------------------------------------------------------
func get_corner_rounding() -> float:
	if card_effect_config.is_empty():
		return 0.12
	var rounding = card_effect_config.get("card_rounding", 0.12)
	if rounding == null:
		return 0.12
	return float(rounding)

func get_base_effects() -> Array:
	if card_effect_config.is_empty():
		return []
	var effects = card_effect_config.get("effects", [])
	if effects is Array:
		return effects.duplicate(true)
	return []

func get_focus_effects() -> Array:
	if card_effect_config.is_empty():
		return []
	var effects = card_effect_config.get("focus_effects", [])
	if effects is Array:
		return effects.duplicate(true)
	return []

# ---------------------------------------------------------------------------
# Sync from SettingsManager
# ---------------------------------------------------------------------------
func sync_from_settings_manager() -> int:
	if not SettingsManager or not SettingsManager.settings:
		return ChangeMask.NONE

	begin_batch()
	set_layout_mode(_get_int_setting("library_layout_mode", 0))
	set_grid_vertical(_get_bool_setting("library_grid_vertical", true))
	set_card_zoom_ratio(_get_float_setting("library_card_zoom", 0.25))
	set_grid_padding(_get_int_setting("library_grid_padding", 22))
	set_focus_scale_ratio(_get_float_setting("library_focus_scale", 0.09))
	set_display_mode(_get_int_setting("library_card_display_mode", 0))
	set_content_alignment(_get_int_setting("library_card_content_alignment", 0))
	set_media_aspect_ratio(_get_int_setting("card_media_aspect_ratio", 0))
	set_show_title_mode(_get_int_setting("library_show_title_mode", 0))
	set_card_effect_config(_get_dict_setting("card_effect_config", {}))
	set_dark_mode(_get_bool_setting("dark_mode", true))
	set_primary_color(_get_color_setting("library_primary_color", Color.WHITE))
	set_focus_lock_enabled(_get_bool_setting("focus_lock_enabled", false))
	end_batch()

	return pending_mask if _batch_depth > 0 else ChangeMask.NONE

func apply_setting(property_name: String, value: Variant) -> int:
	match property_name:
		"library_layout_mode":
			return ChangeMask.LAYOUT if set_layout_mode(_coerce_int(value, 0)) else ChangeMask.NONE
		"library_grid_vertical":
			return ChangeMask.LAYOUT if set_grid_vertical(_coerce_bool(value, true)) else ChangeMask.NONE
		"library_card_zoom":
			return ChangeMask.LAYOUT if set_card_zoom_ratio(_coerce_float(value, 0.25)) else ChangeMask.NONE
		"library_grid_padding":
			return ChangeMask.LAYOUT if set_grid_padding(_coerce_int(value, 22)) else ChangeMask.NONE
		"library_focus_scale":
			return ChangeMask.LAYOUT if set_focus_scale_ratio(_coerce_float(value, 0.09)) else ChangeMask.NONE
		"library_card_display_mode":
			return ChangeMask.DISPLAY if set_display_mode(_coerce_int(value, 0)) else ChangeMask.NONE
		"library_card_content_alignment":
			return ChangeMask.DISPLAY if set_content_alignment(_coerce_int(value, 0)) else ChangeMask.NONE
		"card_media_aspect_ratio":
			return ChangeMask.MEDIA_SHAPE if set_media_aspect_ratio(_coerce_int(value, 0)) else ChangeMask.NONE
		"library_show_title_mode":
			return ChangeMask.DISPLAY if set_show_title_mode(_coerce_int(value, 0)) else ChangeMask.NONE
		"card_effect_config":
			return ChangeMask.EFFECTS if set_card_effect_config(_coerce_dict(value, {})) else ChangeMask.NONE
		"dark_mode":
			return ChangeMask.THEME if set_dark_mode(_coerce_bool(value, true)) else ChangeMask.NONE
		"library_primary_color":
			return ChangeMask.THEME if set_primary_color(_coerce_color(value, Color.WHITE)) else ChangeMask.NONE
		"focus_lock_enabled":
			return ChangeMask.FOCUS_LOCK if set_focus_lock_enabled(_coerce_bool(value, false)) else ChangeMask.NONE
	return ChangeMask.NONE

# ---------------------------------------------------------------------------
# Debug assertion
# ---------------------------------------------------------------------------
func assert_in_sync_with_settings_manager() -> bool:
	if not SettingsManager or not SettingsManager.settings:
		return true

	var mismatches: Array[String] = []
	_check(mismatches, "library_layout_mode", layout_mode, _get_int_setting("library_layout_mode", 0))
	_check(mismatches, "library_grid_vertical", grid_vertical, _get_bool_setting("library_grid_vertical", true))
	_check(mismatches, "library_card_zoom", card_zoom_ratio, _get_float_setting("library_card_zoom", 0.25))
	_check(mismatches, "library_grid_padding", grid_padding, _get_int_setting("library_grid_padding", 22))
	_check(mismatches, "library_focus_scale", focus_scale_ratio, _get_float_setting("library_focus_scale", 0.09))
	_check(mismatches, "library_card_display_mode", display_mode, _get_int_setting("library_card_display_mode", 0))
	_check(mismatches, "library_card_content_alignment", content_alignment, _get_int_setting("library_card_content_alignment", 0))
	_check(mismatches, "card_media_aspect_ratio", media_aspect_ratio, _get_int_setting("card_media_aspect_ratio", 0))
	_check(mismatches, "library_show_title_mode", show_title_mode, _get_int_setting("library_show_title_mode", 0))
	_check(mismatches, "dark_mode", dark_mode, _get_bool_setting("dark_mode", true))
	_check(mismatches, "focus_lock_enabled", focus_lock_enabled, _get_bool_setting("focus_lock_enabled", false))

	if mismatches.size() > 0:
		push_warning("[CardSettingsState] Out of sync with SettingsManager:\n" + "\n".join(mismatches))
		return false
	return true

func _check(out: Array[String], name: String, a: Variant, b: Variant) -> void:
	if a is float and b is float:
		if not is_equal_approx(a, b):
			out.append("%s: state=%s settings=%s" % [name, a, b])
	elif a is Color and b is Color:
		if not a.is_equal_approx(b):
			out.append("%s: state=%s settings=%s" % [name, a, b])
	elif a != b:
		out.append("%s: state=%s settings=%s" % [name, a, b])

# ---------------------------------------------------------------------------
# Private coercion helpers
# ---------------------------------------------------------------------------
func _get_int_setting(name: String, default: int) -> int:
	var setting = SettingsManager.get_setting(name)
	if setting and setting.value is int:
		return setting.value
	return default

func _get_float_setting(name: String, default: float) -> float:
	var setting = SettingsManager.get_setting(name)
	if setting and (setting.value is float or setting.value is int):
		return float(setting.value)
	return default

func _get_bool_setting(name: String, default: bool) -> bool:
	var setting = SettingsManager.get_setting(name)
	if setting and setting.value is bool:
		return setting.value
	return default

func _get_dict_setting(name: String, default: Dictionary) -> Dictionary:
	var setting = SettingsManager.get_setting(name)
	if setting and setting.value is Dictionary:
		return setting.value.duplicate(true)
	return default.duplicate()

func _get_color_setting(name: String, default: Color) -> Color:
	var setting = SettingsManager.get_setting(name)
	if setting and setting.value is Color:
		return setting.value
	return default

func _coerce_int(value: Variant, default: int) -> int:
	if value is int:
		return value
	if value is float:
		return int(value)
	return default

func _coerce_float(value: Variant, default: float) -> float:
	if value is float or value is int:
		return float(value)
	return default

func _coerce_bool(value: Variant, default: bool) -> bool:
	if value is bool:
		return value
	return default

func _coerce_dict(value: Variant, default: Dictionary) -> Dictionary:
	if value is Dictionary:
		return value.duplicate(true)
	return default.duplicate()

func _coerce_color(value: Variant, default: Color) -> Color:
	if value is Color:
		return value
	return default
