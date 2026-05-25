class_name M3Theme
extends RefCounted

## Material 3 Theme Generator - v2
## Proper implementation following M3 design tokens

static var is_dark_mode: bool = false

# ============================================
# COLOR TOKENS
# ============================================

static var PRIMARY_LIGHT: Color = Color("#6750A4")
static var ON_PRIMARY_LIGHT: Color = Color("#FFFFFF")
static var PRIMARY_CONTAINER_LIGHT: Color = Color("#EADDFF")
static var ON_PRIMARY_CONTAINER_LIGHT: Color = Color("#21005D")

static var PRIMARY_DARK: Color = Color("#D0BCFF")
static var ON_PRIMARY_DARK: Color = Color("#381E72")
static var PRIMARY_CONTAINER_DARK: Color = Color("#4F378B")
static var ON_PRIMARY_CONTAINER_DARK: Color = Color("#EADDFF")

static var SECONDARY_LIGHT: Color = Color("#625B71")
static var ON_SECONDARY_LIGHT: Color = Color("#FFFFFF")
static var SECONDARY_CONTAINER_LIGHT: Color = Color("#E8DEF8")
static var ON_SECONDARY_CONTAINER_LIGHT: Color = Color("#1D192B")

static var SECONDARY_DARK: Color = Color("#CCC2DC")
static var ON_SECONDARY_DARK: Color = Color("#332D41")
static var SECONDARY_CONTAINER_DARK: Color = Color("#4A4458")
static var ON_SECONDARY_CONTAINER_DARK: Color = Color("#E8DEF8")

static var TERTIARY_LIGHT: Color = Color("#7D5260")
static var ON_TERTIARY_LIGHT: Color = Color("#FFFFFF")
static var TERTIARY_CONTAINER_LIGHT: Color = Color("#FFD8E4")
static var ON_TERTIARY_CONTAINER_LIGHT: Color = Color("#31111D")

static var TERTIARY_DARK: Color = Color("#EFB8C8")
static var ON_TERTIARY_DARK: Color = Color("#31111D")
static var TERTIARY_CONTAINER_DARK: Color = Color("#633B48")
static var ON_TERTIARY_CONTAINER_DARK: Color = Color("#FFD8E4")

static var ERROR_LIGHT: Color = Color("#B3261E")
static var ON_ERROR_LIGHT: Color = Color("#FFFFFF")
static var ERROR_CONTAINER_LIGHT: Color = Color("#F9DEDC")
static var ON_ERROR_CONTAINER_LIGHT: Color = Color("#410E0B")

static var ERROR_DARK: Color = Color("#F2B8B5")
static var ON_ERROR_DARK: Color = Color("#601410")
static var ERROR_CONTAINER_DARK: Color = Color("#8C1D18")
static var ON_ERROR_CONTAINER_DARK: Color = Color("#F9DEDC")

const SURFACE_LIGHT := Color("#FFFBFE")
const ON_SURFACE_LIGHT := Color("#1C1B1F")
const SURFACE_VARIANT_LIGHT := Color("#E7E0EC")
const ON_SURFACE_VARIANT_LIGHT := Color("#49454F")

const SURFACE_DARK := Color("#1C1B1F")
const ON_SURFACE_DARK := Color("#E6E1E5")
const SURFACE_VARIANT_DARK := Color("#49454F")
const ON_SURFACE_VARIANT_DARK := Color("#CAC4D0")

const OUTLINE_LIGHT := Color("#79747E")
const OUTLINE_VARIANT_LIGHT := Color("#CAC4D0")

const OUTLINE_DARK := Color("#938F99")
const OUTLINE_VARIANT_DARK := Color("#49454F")

const INVERSE_SURFACE_LIGHT := Color("#313033")
const INVERSE_ON_SURFACE_LIGHT := Color("#F4EFF4")

const INVERSE_SURFACE_DARK := Color("#E6E1E5")
const INVERSE_ON_SURFACE_DARK := Color("#1C1B1F")

# ============================================
# SHAPE
# ============================================

const RADIUS_NONE := 0
const RADIUS_SMALL := 4    # Buttons, chips, input fields
const RADIUS_MEDIUM := 8   # Cards, dialogs
const RADIUS_LARGE := 12   # Sheets, menus
const RADIUS_XLARGE := 28  # Floating sheets

# ============================================
# TYPOGRAPHY - M3 Type Scale
# ============================================

const TYPE_LABEL_LARGE := 14   # Buttons, tabs
const TYPE_LABEL_MEDIUM := 12  # Captions
const TYPE_BODY_LARGE := 16    # Primary body
const TYPE_BODY_MEDIUM := 14   # Secondary body
const TYPE_TITLE_SMALL := 14   # Small headings
const TYPE_TITLE_MEDIUM := 16  # Medium headings
const TYPE_TITLE_LARGE := 22   # App bar titles

# ============================================
# STATE LAYER OPACITY
# ============================================

const OPACITY_HOVER := 0.08
const OPACITY_FOCUS := 0.12
const OPACITY_PRESSED := 0.12
const OPACITY_DRAGGED := 0.16
const OPACITY_DISABLED := 0.38

# ============================================
# DIMENSIONS
# ============================================

const BUTTON_HEIGHT := 40
const BUTTON_PADDING_H := 24
const INPUT_HEIGHT := 56
const TAB_HEIGHT := 48
const SLIDER_TRACK_HEIGHT := 4
const PROGRESS_HEIGHT := 4
const SCROLLBAR_THICKNESS := 8
const SCROLLBAR_OPACITY := 0.70
const SCROLLBAR_OPACITY_HOVER := 0.85
const SCROLLBAR_OPACITY_PRESSED := 0.95

# ============================================
# ELEVATION SHADOWS
# ============================================

const ELEVATION_0 := {"size": 0, "offset": Vector2(0, 0), "color": Color(0, 0, 0, 0)}
const ELEVATION_1 := {"size": 2, "offset": Vector2(0, 1), "color": Color(0, 0, 0, 0.15)}
const ELEVATION_2 := {"size": 4, "offset": Vector2(0, 2), "color": Color(0, 0, 0, 0.18)}
const ELEVATION_3 := {"size": 6, "offset": Vector2(0, 3), "color": Color(0, 0, 0, 0.20)}
const ELEVATION_4 := {"size": 8, "offset": Vector2(0, 4), "color": Color(0, 0, 0, 0.22)}
const ELEVATION_5 := {"size": 10, "offset": Vector2(0, 5), "color": Color(0, 0, 0, 0.24)}

# ============================================
# COLOR GETTERS
# ============================================

static func get_primary() -> Color:
	return PRIMARY_DARK if is_dark_mode else PRIMARY_LIGHT

static func get_on_primary() -> Color:
	return ON_PRIMARY_DARK if is_dark_mode else ON_PRIMARY_LIGHT

static func get_primary_container() -> Color:
	return PRIMARY_CONTAINER_DARK if is_dark_mode else PRIMARY_CONTAINER_LIGHT

static func get_on_primary_container() -> Color:
	return ON_PRIMARY_CONTAINER_DARK if is_dark_mode else ON_PRIMARY_CONTAINER_LIGHT

static func get_secondary() -> Color:
	return SECONDARY_DARK if is_dark_mode else SECONDARY_LIGHT

static func get_on_secondary() -> Color:
	return ON_SECONDARY_DARK if is_dark_mode else ON_SECONDARY_LIGHT

static func get_secondary_container() -> Color:
	return SECONDARY_CONTAINER_DARK if is_dark_mode else SECONDARY_CONTAINER_LIGHT

static func get_on_secondary_container() -> Color:
	return ON_SECONDARY_CONTAINER_DARK if is_dark_mode else ON_SECONDARY_CONTAINER_LIGHT

static func get_tertiary() -> Color:
	return TERTIARY_DARK if is_dark_mode else TERTIARY_LIGHT

static func get_on_tertiary() -> Color:
	return ON_TERTIARY_DARK if is_dark_mode else ON_TERTIARY_LIGHT

static func get_tertiary_container() -> Color:
	return TERTIARY_CONTAINER_DARK if is_dark_mode else TERTIARY_CONTAINER_LIGHT

static func get_on_tertiary_container() -> Color:
	return ON_TERTIARY_CONTAINER_DARK if is_dark_mode else ON_TERTIARY_CONTAINER_LIGHT

static func get_surface_container_low() -> Color:
	return get_elevation_surface(1)

static func get_surface_container() -> Color:
	return get_elevation_surface(2)

static func get_error() -> Color:
	return ERROR_DARK if is_dark_mode else ERROR_LIGHT

static func get_on_error() -> Color:
	return ON_ERROR_DARK if is_dark_mode else ON_ERROR_LIGHT

static func get_error_container() -> Color:
	return ERROR_CONTAINER_DARK if is_dark_mode else ERROR_CONTAINER_LIGHT

static func get_on_error_container() -> Color:
	return ON_ERROR_CONTAINER_DARK if is_dark_mode else ON_ERROR_CONTAINER_LIGHT

static func get_surface() -> Color:
	return SURFACE_DARK if is_dark_mode else SURFACE_LIGHT

static func get_on_surface() -> Color:
	return ON_SURFACE_DARK if is_dark_mode else ON_SURFACE_LIGHT

static func get_surface_variant() -> Color:
	return SURFACE_VARIANT_DARK if is_dark_mode else SURFACE_VARIANT_LIGHT

static func get_on_surface_variant() -> Color:
	return ON_SURFACE_VARIANT_DARK if is_dark_mode else ON_SURFACE_VARIANT_LIGHT

static func get_outline() -> Color:
	return OUTLINE_DARK if is_dark_mode else OUTLINE_LIGHT

static func get_outline_variant() -> Color:
	return OUTLINE_VARIANT_DARK if is_dark_mode else OUTLINE_VARIANT_LIGHT

static func get_inverse_surface() -> Color:
	return INVERSE_SURFACE_DARK if is_dark_mode else INVERSE_SURFACE_LIGHT

static func get_inverse_on_surface() -> Color:
	return INVERSE_ON_SURFACE_DARK if is_dark_mode else INVERSE_ON_SURFACE_LIGHT

# ============================================
# DYNAMIC PALETTE GENERATION
# ============================================

static func _compute_on_color(bg: Color, hue: float, is_container: bool = false) -> Color:
	var luminance = bg.get_luminance()
	if luminance > 0.5:
		var sat = 0.7 if is_container else 0.5
		var val = 0.15 if is_container else 0.25
		return Color.from_hsv(hue, sat, val)
	else:
		var sat = 0.2 if is_container else 0.1
		return Color.from_hsv(hue, sat, 1.0)

static func set_primary_seed(seed: Color) -> void:
	var ref_s = 0.52
	var ref_v = 0.64

	var h = seed.h
	var s = clamp(seed.s, 0.2, 1.0)
	var v = clamp(seed.v, 0.3, 0.9)

	# Primary family
	PRIMARY_LIGHT = Color.from_hsv(h, s, v)
	ON_PRIMARY_LIGHT = _compute_on_color(PRIMARY_LIGHT, h)
	PRIMARY_CONTAINER_LIGHT = Color.from_hsv(h, s * 0.15, 1.0)
	ON_PRIMARY_CONTAINER_LIGHT = _compute_on_color(PRIMARY_CONTAINER_LIGHT, h, true)

	PRIMARY_DARK = Color.from_hsv(h, s * 0.5, 1.0)
	ON_PRIMARY_DARK = _compute_on_color(PRIMARY_DARK, h)
	PRIMARY_CONTAINER_DARK = Color.from_hsv(h, s * 1.15, v * 0.86)
	ON_PRIMARY_CONTAINER_DARK = _compute_on_color(PRIMARY_CONTAINER_DARK, h, true)

	# Secondary (same hue family, lower chroma)
	var sec_s = s * 0.31
	SECONDARY_LIGHT = Color.from_hsv(h, sec_s, v * 0.69)
	ON_SECONDARY_LIGHT = _compute_on_color(SECONDARY_LIGHT, h)
	SECONDARY_CONTAINER_LIGHT = Color.from_hsv(h, sec_s * 0.3, 0.92)
	ON_SECONDARY_CONTAINER_LIGHT = _compute_on_color(SECONDARY_CONTAINER_LIGHT, h, true)

	SECONDARY_DARK = Color.from_hsv(h, sec_s * 0.69, 0.85)
	ON_SECONDARY_DARK = _compute_on_color(SECONDARY_DARK, h)
	SECONDARY_CONTAINER_DARK = Color.from_hsv(h, sec_s * 1.5, 0.35)
	ON_SECONDARY_CONTAINER_DARK = _compute_on_color(SECONDARY_CONTAINER_DARK, h, true)

	# Tertiary (rotated hue, medium chroma)
	var tert_h = fmod(h + 0.227, 1.0)
	var tert_s = s * 0.65
	TERTIARY_LIGHT = Color.from_hsv(tert_h, tert_s, v * 0.77)
	ON_TERTIARY_LIGHT = _compute_on_color(TERTIARY_LIGHT, tert_h)
	TERTIARY_CONTAINER_LIGHT = Color.from_hsv(tert_h, tert_s * 0.15, 1.0)
	ON_TERTIARY_CONTAINER_LIGHT = _compute_on_color(TERTIARY_CONTAINER_LIGHT, tert_h, true)

	TERTIARY_DARK = Color.from_hsv(tert_h, tert_s * 0.48, 0.95)
	ON_TERTIARY_DARK = _compute_on_color(TERTIARY_DARK, tert_h)
	TERTIARY_CONTAINER_DARK = Color.from_hsv(tert_h, tert_s * 1.08, 0.4)
	ON_TERTIARY_CONTAINER_DARK = _compute_on_color(TERTIARY_CONTAINER_DARK, tert_h, true)

	# Error (fixed red family)
	ERROR_LIGHT = Color.from_hsv(0.01, 0.83, 0.70)
	ON_ERROR_LIGHT = _compute_on_color(ERROR_LIGHT, 0.01)
	ERROR_CONTAINER_LIGHT = Color.from_hsv(0.01, 0.20, 1.0)
	ON_ERROR_CONTAINER_LIGHT = _compute_on_color(ERROR_CONTAINER_LIGHT, 0.01, true)

	ERROR_DARK = Color.from_hsv(0.01, 0.26, 0.95)
	ON_ERROR_DARK = _compute_on_color(ERROR_DARK, 0.01)
	ERROR_CONTAINER_DARK = Color.from_hsv(0.01, 0.60, 0.35)
	ON_ERROR_CONTAINER_DARK = _compute_on_color(ERROR_CONTAINER_DARK, 0.01, true)

# ============================================
# ELEVATION
# ============================================

static func get_elevation_surface(level: int) -> Color:
	var surface = get_surface()
	var tint = get_primary()
	var opacity = 0.0
	match level:
		0: opacity = 0.0
		1: opacity = 0.05
		2: opacity = 0.08
		3: opacity = 0.11
		4: opacity = 0.12
		5: opacity = 0.14
	return surface.lerp(tint, opacity)

# ============================================
# STATE LAYER - M3 uses overlay, not color shift
# ============================================

static func state_overlay(base: Color, state_color: Color, opacity: float) -> Color:
	return base.lerp(state_color, opacity)

static func disabled_color(color: Color) -> Color:
	return Color(color.r, color.g, color.b, color.a * OPACITY_DISABLED)

# ============================================
# STYLEBOX FACTORIES
# ============================================

static func make_flat(bg: Color, radius: int = RADIUS_NONE,
					  border_w: int = 0, border_c: Color = Color.TRANSPARENT,
					  pad_h: int = -1, pad_v: int = -1) -> StyleBoxFlat:
	var s = StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	s.anti_aliasing = true
	s.anti_aliasing_size = 1.0
	if border_w > 0:
		s.border_color = border_c
		s.set_border_width_all(border_w)
	if pad_h >= 0:
		s.content_margin_left = pad_h
		s.content_margin_right = pad_h
	if pad_v >= 0:
		s.content_margin_top = pad_v
		s.content_margin_bottom = pad_v
	return s

static func make_shadow(bg: Color, radius: int, shadow_size: int, shadow_off: Vector2, shadow_col: Color) -> StyleBoxFlat:
	var s = make_flat(bg, radius)
	s.shadow_size = shadow_size
	s.shadow_offset = shadow_off
	s.shadow_color = shadow_col
	return s

static func make_empty() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()

# ============================================
# SHARED TEXTURE
# ============================================

static var _empty_texture: ImageTexture

static func get_empty_texture() -> ImageTexture:
	if _empty_texture == null:
		var empty_img := Image.create(1, 1, false, Image.FORMAT_RGBA8)
		empty_img.fill(Color.TRANSPARENT)
		_empty_texture = ImageTexture.create_from_image(empty_img)
	return _empty_texture

# ============================================
# SHARED HELPERS
# ============================================

## Bind an M3Tooltip to any Control node. Call from _ready().
static func setup_tooltip(node: Control, text: String, variant: int):
	M3Tooltip.bind(node, text, variant)

## Hide native CheckBox/CheckButton icon visuals.
## Applies to both CheckBox and CheckButton derived nodes.
static func hide_native_check_icons(node: Control):
	var empty_tex = get_empty_texture()
	for icon in ["checked", "unchecked", "checked_disabled", "unchecked_disabled"]:
		node.add_theme_icon_override(icon, empty_tex)
	node.add_theme_color_override("icon_normal_color", Color.TRANSPARENT)
	node.add_theme_color_override("icon_pressed_color", Color.TRANSPARENT)
	node.add_theme_color_override("icon_hover_color", Color.TRANSPARENT)
	node.add_theme_color_override("icon_hover_pressed_color", Color.TRANSPARENT)
	node.add_theme_color_override("icon_disabled_color", Color.TRANSPARENT)

## Hide native CheckButton stylebox visuals.
static func hide_native_checkbutton_styleboxes(node: CheckButton):
	var empty = make_empty()
	for style in ["normal", "pressed", "hover", "disabled", "focus", "hover_pressed",
				  "normal_mirrored", "pressed_mirrored", "hover_mirrored",
				  "disabled_mirrored", "focus_mirrored", "hover_pressed_mirrored"]:
		node.add_theme_stylebox_override(style, empty)

# ============================================
# FONTS
# ============================================

static var _cached_fonts: Dictionary = {}

static func load_fonts() -> Dictionary:
	if not _cached_fonts.is_empty():
		return _cached_fonts
	var d = {}
	var dir = "res://addons/m3/fonts/Roboto/"
	d["regular"] = load(dir + "Roboto-Regular.ttf")
	d["light"] = load(dir + "Roboto-Light.ttf")
	d["medium"] = load(dir + "Roboto-Medium.ttf")
	d["bold"] = load(dir + "Roboto-Bold.ttf")
	d["black"] = load(dir + "Roboto-Black.ttf")
	_cached_fonts = d
	return d

# ============================================
# MAIN THEME
# ============================================

static func generate_theme() -> Theme:
	var t = Theme.new()
	var f = load_fonts()
	t.default_font = f["regular"]
	
	var prim = get_primary()
	var on_prim = get_on_primary()
	var prim_cont = get_primary_container()
	var on_prim_cont = get_on_primary_container()
	var surf = get_surface()
	var on_surf = get_on_surface()
	var surf_var = get_surface_variant()
	var on_surf_var = get_on_surface_variant()
	var outl = get_outline()
	var outl_var = get_outline_variant()
	var err = get_error()
	
	# ========================================
	# LABEL
	# ========================================
	t.set_color("font_color", "Label", on_surf)
	t.set_font("font", "Label", f["regular"])
	t.set_font_size("font_size", "Label", TYPE_BODY_LARGE)
	
	# ========================================
	# RICHTEXTLABEL
	# ========================================
	t.set_color("default_color", "RichTextLabel", on_surf)
	t.set_font("normal_font", "RichTextLabel", f["regular"])
	t.set_font("bold_font", "RichTextLabel", f["bold"])
	t.set_font_size("normal_font_size", "RichTextLabel", TYPE_BODY_LARGE)
	
	# ========================================
	# BUTTON - M3 Filled Button
	# ========================================
	var btn_normal = make_flat(prim, RADIUS_SMALL, 0, Color.TRANSPARENT, BUTTON_PADDING_H, 10)
	var btn_hover = make_flat(state_overlay(prim, on_prim, OPACITY_HOVER), RADIUS_SMALL, 0, Color.TRANSPARENT, BUTTON_PADDING_H, 10)
	var btn_pressed = make_flat(state_overlay(prim, on_prim, OPACITY_PRESSED), RADIUS_SMALL, 0, Color.TRANSPARENT, BUTTON_PADDING_H, 10)
	var btn_disabled = make_flat(Color(on_surf_var.r, on_surf_var.g, on_surf_var.b, OPACITY_DISABLED), RADIUS_SMALL, 0, Color.TRANSPARENT, BUTTON_PADDING_H, 10)
	var btn_focus = make_flat(prim, RADIUS_SMALL, 3, on_prim, BUTTON_PADDING_H, 10)
	
	t.set_stylebox("normal", "Button", btn_normal)
	t.set_stylebox("hover", "Button", btn_hover)
	t.set_stylebox("pressed", "Button", btn_pressed)
	t.set_stylebox("disabled", "Button", btn_disabled)
	t.set_stylebox("focus", "Button", btn_focus)
	
	t.set_color("font_color", "Button", on_prim)
	t.set_color("font_hover_color", "Button", on_prim)
	t.set_color("font_pressed_color", "Button", on_prim)
	t.set_color("font_disabled_color", "Button", Color(on_surf_var.r, on_surf_var.g, on_surf_var.b, OPACITY_DISABLED))
	t.set_color("font_focus_color", "Button", on_prim)
	
	t.set_font("font", "Button", f["medium"])
	t.set_font_size("font_size", "Button", TYPE_LABEL_LARGE)
	
	# ========================================
	# CHECKBUTTON (Toggle/Switch)
	# ========================================
	t.set_stylebox("normal", "CheckButton", make_empty())
	t.set_stylebox("pressed", "CheckButton", make_empty())
	t.set_stylebox("hover", "CheckButton", make_empty())
	t.set_stylebox("disabled", "CheckButton", make_empty())
	
	t.set_color("font_color", "CheckButton", on_surf)
	t.set_color("font_pressed_color", "CheckButton", on_prim_cont)
	t.set_color("font_disabled_color", "CheckButton", disabled_color(on_surf))
	
	t.set_font("font", "CheckButton", f["medium"])
	t.set_font_size("font_size", "CheckButton", TYPE_LABEL_LARGE)
	
	# ========================================
	# CHECKBOX
	# ========================================
	t.set_stylebox("normal", "CheckBox", make_empty())
	t.set_stylebox("pressed", "CheckBox", make_empty())
	t.set_stylebox("hover", "CheckBox", make_empty())
	t.set_stylebox("disabled", "CheckBox", make_empty())
	
	t.set_color("font_color", "CheckBox", on_surf)
	t.set_color("font_pressed_color", "CheckBox", on_surf)
	t.set_color("font_disabled_color", "CheckBox", disabled_color(on_surf))
	
	t.set_font("font", "CheckBox", f["medium"])
	t.set_font_size("font_size", "CheckBox", TYPE_LABEL_LARGE)
	
	# ========================================
	# LINE EDIT - M3 Outlined Text Field
	# ========================================
	var le_normal = make_flat(surf, RADIUS_SMALL, 1, outl, 16, 16)
	var le_focus = make_flat(surf, RADIUS_SMALL, 2, prim, 16, 16)
	var le_readonly = make_flat(surf_var, RADIUS_SMALL, 1, outl_var, 16, 16)
	
	t.set_stylebox("normal", "LineEdit", le_normal)
	t.set_stylebox("focus", "LineEdit", le_focus)
	t.set_stylebox("read_only", "LineEdit", le_readonly)
	
	t.set_color("font_color", "LineEdit", on_surf)
	t.set_color("font_placeholder_color", "LineEdit", on_surf_var)
	t.set_color("caret_color", "LineEdit", prim)
	t.set_color("selection_color", "LineEdit", prim_cont)
	
	t.set_font("font", "LineEdit", f["regular"])
	t.set_font_size("font_size", "LineEdit", TYPE_BODY_LARGE)
	
	# ========================================
	# TEXT EDIT
	# ========================================
	var te_normal = make_flat(surf, RADIUS_SMALL, 1, outl, 12, 12)
	var te_focus = make_flat(surf, RADIUS_SMALL, 2, prim, 12, 12)
	var te_readonly = make_flat(surf_var, RADIUS_SMALL, 1, outl_var, 12, 12)
	
	t.set_stylebox("normal", "TextEdit", te_normal)
	t.set_stylebox("focus", "TextEdit", te_focus)
	t.set_stylebox("read_only", "TextEdit", te_readonly)
	
	t.set_color("font_color", "TextEdit", on_surf)
	t.set_color("font_placeholder_color", "TextEdit", on_surf_var)
	t.set_color("caret_color", "TextEdit", prim)
	t.set_color("selection_color", "TextEdit", prim_cont)
	
	t.set_font("font", "TextEdit", f["regular"])
	t.set_font_size("font_size", "TextEdit", TYPE_BODY_MEDIUM)
	
	# ========================================
	# SLIDER - M3 Slider
	# ========================================
	# Track background (inactive)
	var slider_track = StyleBoxFlat.new()
	slider_track.bg_color = surf_var
	slider_track.set_corner_radius_all(2)
	slider_track.content_margin_top = 6
	slider_track.content_margin_bottom = 6
	
	# Track active portion
	var slider_active = StyleBoxFlat.new()
	slider_active.bg_color = prim
	slider_active.set_corner_radius_all(2)
	slider_active.content_margin_top = 6
	slider_active.content_margin_bottom = 6
	
	# Grabber (thumb)
	var grabber = StyleBoxFlat.new()
	grabber.bg_color = prim
	grabber.set_corner_radius_all(10)
	grabber.shadow_size = 2
	grabber.shadow_offset = Vector2(0, 1)
	grabber.shadow_color = Color(0, 0, 0, 0.2)
	
	var grabber_hi = StyleBoxFlat.new()
	grabber_hi.bg_color = state_overlay(prim, Color.WHITE, 0.2)
	grabber_hi.set_corner_radius_all(10)
	grabber_hi.shadow_size = 4
	grabber_hi.shadow_offset = Vector2(0, 2)
	grabber_hi.shadow_color = Color(0, 0, 0, 0.3)
	
	# Enable anti-aliasing for slider elements
	for sb in [slider_track, slider_active, grabber, grabber_hi]:
		sb.anti_aliasing = true
		sb.anti_aliasing_size = 1.0
	
	# HSlider
	t.set_stylebox("slider", "HSlider", slider_track)
	t.set_stylebox("grabber_area", "HSlider", slider_active)
	t.set_stylebox("grabber_area_highlight", "HSlider", slider_active)
	t.set_stylebox("grabber", "HSlider", grabber)
	t.set_stylebox("grabber_highlight", "HSlider", grabber_hi)
	
	# VSlider
	t.set_stylebox("slider", "VSlider", slider_track)
	t.set_stylebox("grabber_area", "VSlider", slider_active)
	t.set_stylebox("grabber_area_highlight", "VSlider", slider_active)
	t.set_stylebox("grabber", "VSlider", grabber)
	t.set_stylebox("grabber_highlight", "VSlider", grabber_hi)
	
	# ========================================
	# PROGRESS BAR
	# ========================================
	var prog_bg = StyleBoxFlat.new()
	prog_bg.bg_color = surf_var
	prog_bg.set_corner_radius_all(2)
	prog_bg.content_margin_top = 4
	prog_bg.content_margin_bottom = 4
	
	var prog_fill = StyleBoxFlat.new()
	prog_fill.bg_color = prim
	prog_fill.set_corner_radius_all(2)
	
	for sb in [prog_bg, prog_fill]:
		sb.anti_aliasing = true
		sb.anti_aliasing_size = 1.0
	
	t.set_stylebox("background", "ProgressBar", prog_bg)
	t.set_stylebox("fill", "ProgressBar", prog_fill)
	
	t.set_color("font_color", "ProgressBar", on_surf)
	t.set_font("font", "ProgressBar", f["medium"])
	t.set_font_size("font_size", "ProgressBar", TYPE_LABEL_MEDIUM)
	
	# ========================================
	# SPIN BOX
	# ========================================
	t.set_stylebox("normal", "SpinBox", make_flat(surf, RADIUS_SMALL, 1, outl, 12, 10))
	t.set_color("font_color", "SpinBox", on_surf)
	t.set_font("font", "SpinBox", f["regular"])
	t.set_font_size("font_size", "SpinBox", TYPE_BODY_LARGE)
	
	# ========================================
	# TAB CONTAINER - M3 Primary Tabs (no jump)
	# ========================================
	t.set_stylebox("panel", "TabContainer", make_flat(surf, RADIUS_NONE))
	
	# KEY: All tab states must have IDENTICAL geometry
	var tab_pad = 16
	var tab_base = make_flat(Color.TRANSPARENT, RADIUS_NONE, 0, Color.TRANSPARENT, tab_pad, 12)
	
	var tab_selected = tab_base.duplicate()
	tab_selected.border_color = prim
	tab_selected.border_width_bottom = 3
	tab_selected.expand_margin_bottom = 2
	
	var tab_unselected = tab_base.duplicate()
	tab_unselected.border_color = Color.TRANSPARENT
	tab_unselected.border_width_bottom = 3
	tab_unselected.expand_margin_bottom = 2
	
	var tab_disabled = tab_base.duplicate()
	tab_disabled.border_color = Color.TRANSPARENT
	tab_disabled.border_width_bottom = 3
	tab_disabled.expand_margin_bottom = 2
	
	t.set_stylebox("tab_selected", "TabContainer", tab_selected)
	t.set_stylebox("tab_unselected", "TabContainer", tab_unselected)
	t.set_stylebox("tab_disabled", "TabContainer", tab_disabled)
	
	t.set_color("font_color", "TabContainer", on_surf_var)
	t.set_color("font_selected_color", "TabContainer", prim)
	t.set_color("font_disabled_color", "TabContainer", disabled_color(on_surf))
	
	t.set_font("font", "TabContainer", f["medium"])
	t.set_font_size("font_size", "TabContainer", TYPE_TITLE_SMALL)
	
	# ========================================
	# SCROLLBARS (M3 compliant)
	# ========================================
	var sb_track = StyleBoxFlat.new()
	sb_track.bg_color = Color.TRANSPARENT
	sb_track.corner_radius_top_left = 4
	sb_track.corner_radius_top_right = 4
	sb_track.corner_radius_bottom_left = 4
	sb_track.corner_radius_bottom_right = 4
	sb_track.content_margin_left = 2
	sb_track.content_margin_top = 2
	sb_track.content_margin_right = 2
	sb_track.content_margin_bottom = 2
	
	var sb_grabber = StyleBoxFlat.new()
	sb_grabber.bg_color = Color(outl.r, outl.g, outl.b, SCROLLBAR_OPACITY)
	sb_grabber.set_corner_radius_all(SCROLLBAR_THICKNESS / 2)
	
	var sb_grabber_hi = StyleBoxFlat.new()
	sb_grabber_hi.bg_color = Color(outl.r, outl.g, outl.b, SCROLLBAR_OPACITY_HOVER)
	sb_grabber_hi.set_corner_radius_all(SCROLLBAR_THICKNESS / 2)
	
	var sb_grabber_pressed = StyleBoxFlat.new()
	sb_grabber_pressed.bg_color = Color(on_surf.r, on_surf.g, on_surf.b, SCROLLBAR_OPACITY_PRESSED)
	sb_grabber_pressed.set_corner_radius_all(SCROLLBAR_THICKNESS / 2)
	
	for sb in [sb_grabber, sb_grabber_hi, sb_grabber_pressed]:
		sb.anti_aliasing = true
		sb.anti_aliasing_size = 1.0
	
	# VScrollBar
	t.set_stylebox("scroll", "VScrollBar", sb_track)
	t.set_stylebox("scroll_focus", "VScrollBar", sb_track)
	t.set_stylebox("grabber", "VScrollBar", sb_grabber)
	t.set_stylebox("grabber_highlight", "VScrollBar", sb_grabber_hi)
	t.set_stylebox("grabber_pressed", "VScrollBar", sb_grabber_pressed)
	
	# HScrollBar
	t.set_stylebox("scroll", "HScrollBar", sb_track)
	t.set_stylebox("scroll_focus", "HScrollBar", sb_track)
	t.set_stylebox("grabber", "HScrollBar", sb_grabber)
	t.set_stylebox("grabber_highlight", "HScrollBar", sb_grabber_hi)
	t.set_stylebox("grabber_pressed", "HScrollBar", sb_grabber_pressed)
	
	# ========================================
	# POPUP MENU (elevated)
	# ========================================
	var popup_bg = get_elevation_surface(2)
	var popup_panel = make_shadow(popup_bg, RADIUS_MEDIUM, 4, Vector2(0, 2), Color(0, 0, 0, 0.15))
	popup_panel.content_margin_left = 8
	popup_panel.content_margin_top = 8
	popup_panel.content_margin_right = 8
	popup_panel.content_margin_bottom = 8
	
	var popup_hover = make_flat(state_overlay(surf, on_surf, OPACITY_HOVER), RADIUS_SMALL, 0, Color.TRANSPARENT, 12, 8)
	
	var popup_sep = StyleBoxFlat.new()
	popup_sep.bg_color = outl_var
	popup_sep.content_margin_top = 8
	popup_sep.content_margin_bottom = 8
	
	t.set_stylebox("panel", "PopupMenu", popup_panel)
	t.set_stylebox("hover", "PopupMenu", popup_hover)
	t.set_stylebox("separator", "PopupMenu", popup_sep)
	
	t.set_color("font_color", "PopupMenu", on_surf)
	t.set_color("font_hover_color", "PopupMenu", on_surf)
	t.set_color("font_disabled_color", "PopupMenu", disabled_color(on_surf))
	
	t.set_font("font", "PopupMenu", f["regular"])
	t.set_font_size("font_size", "PopupMenu", TYPE_BODY_MEDIUM)
	
	# ========================================
	# PANEL (background)
	# ========================================
	t.set_stylebox("panel", "Panel", make_flat(surf, RADIUS_NONE))
	
	# ========================================
	# PANEL CONTAINER (elevated card)
	# ========================================
	var card = make_shadow(surf, RADIUS_MEDIUM, 2, Vector2(0, 1), Color(0, 0, 0, 0.12))
	t.set_stylebox("panel", "PanelContainer", card)
	
	# ========================================
	# OPTION BUTTON
	# ========================================
	var opt_normal = make_flat(surf, RADIUS_SMALL, 1, outl, 16, 10)
	var opt_hover = make_flat(state_overlay(surf, on_surf, OPACITY_HOVER), RADIUS_SMALL, 1, outl, 16, 10)
	var opt_pressed = make_flat(prim_cont, RADIUS_SMALL, 1, prim, 16, 10)
	var opt_disabled = make_flat(surf_var, RADIUS_SMALL, 1, outl_var, 16, 10)
	
	t.set_stylebox("normal", "OptionButton", opt_normal)
	t.set_stylebox("hover", "OptionButton", opt_hover)
	t.set_stylebox("pressed", "OptionButton", opt_pressed)
	t.set_stylebox("disabled", "OptionButton", opt_disabled)
	
	t.set_color("font_color", "OptionButton", on_surf)
	t.set_color("font_hover_color", "OptionButton", on_surf)
	t.set_color("font_pressed_color", "OptionButton", on_prim_cont)
	t.set_color("font_disabled_color", "OptionButton", disabled_color(on_surf))
	
	t.set_font("font", "OptionButton", f["regular"])
	t.set_font_size("font_size", "OptionButton", TYPE_BODY_LARGE)
	
	# ========================================
	# MENU BUTTON
	# ========================================
	t.set_stylebox("normal", "MenuButton", make_flat(Color.TRANSPARENT, RADIUS_NONE, 0, Color.TRANSPARENT, 12, 8))
	t.set_stylebox("pressed", "MenuButton", make_flat(prim_cont, RADIUS_NONE, 0, Color.TRANSPARENT, 12, 8))
	t.set_stylebox("hover", "MenuButton", make_flat(state_overlay(surf, on_surf, OPACITY_HOVER), RADIUS_NONE, 0, Color.TRANSPARENT, 12, 8))
	
	t.set_color("font_color", "MenuButton", prim)
	t.set_color("font_hover_color", "MenuButton", prim)
	t.set_color("font_pressed_color", "MenuButton", on_prim_cont)
	
	t.set_font("font", "MenuButton", f["medium"])
	t.set_font_size("font_size", "MenuButton", TYPE_LABEL_LARGE)
	
	# ========================================
	# LINK BUTTON
	# ========================================
	t.set_color("font_color", "LinkButton", prim)
	t.set_color("font_hover_color", "LinkButton", prim)
	t.set_color("font_pressed_color", "LinkButton", state_overlay(prim, Color.BLACK, 0.2))
	t.set_color("font_disabled_color", "LinkButton", disabled_color(on_surf))
	
	t.set_font("font", "LinkButton", f["medium"])
	t.set_font_size("font_size", "LinkButton", TYPE_LABEL_LARGE)
	
	# ========================================
	# SEPARATORS
	# ========================================
	var hsep = StyleBoxFlat.new()
	hsep.bg_color = outl_var
	hsep.content_margin_top = 8
	hsep.content_margin_bottom = 8
	
	var vsep = StyleBoxFlat.new()
	vsep.bg_color = outl_var
	vsep.content_margin_left = 8
	vsep.content_margin_right = 8
	
	t.set_stylebox("separator", "HSeparator", hsep)
	t.set_stylebox("separator", "VSeparator", vsep)
	
	return t
