class_name ShufflerIntroWindow
extends Window

## Ported from the old game_shuffler's notif_intro: the incoming game's cover
## flies up to center screen, slides aside while fading, and a clipped banner
## sweeps in from the right edge revealing the title + platform/year before
## everything fades out. Plays once per game per shuffler session, over the
## emulator while it boots. Purely presentational: unfocusable and
## click-through so the game keeps controller/keyboard focus and mouse input.

signal intro_finished()

const CoverLoader = preload("res://components/shuffler/shuffler_cover_loader.gd")
const MAX_COVER_TEXTURE_SIZE := 512

const COVER_ASPECT_FALLBACK := 0.75  # 3:4 placeholder when no cover exists
const BANNER_HEIGHT_DP := 200.0
const BANNER_MARGIN_DP := 36.0
const TITLE_MAX_SIZE_DP := 52.0
const TITLE_MIN_SIZE_DP := 20.0
const INFO_SIZE_DP := 26.0

@onready var _cover_pivot: Control = $Root/CoverPivot
@onready var _cover: TextureRect = $Root/CoverPivot/Cover
@onready var _cover_placeholder: ColorRect = $Root/CoverPivot/CoverPlaceholder
@onready var _banner: Panel = $Root/Banner
@onready var _title_label: Label = $Root/Banner/Margin/VBox/Title
@onready var _info_label: Label = $Root/Banner/Margin/VBox/Info

var _screen: Vector2 = Vector2.ZERO
var _cover_size: Vector2 = Vector2.ZERO
# The manager pools one intro window per session and re-presents it per game,
# possibly mid-animation; every tween is tracked so a re-present can kill the
# previous run before resetting state.
var _tweens: Array[Tween] = []
# Bumped per present: async cover loads from a previous game check it so a
# late texture can't land on the new game's intro (the weakref alone no
# longer guards this now that the window survives between presents).
var _present_generation := 0

func _ready() -> void:
	# Same OS-window initialization pattern as ShufflerChoiceWindow, plus
	# unfocusable so the emulator keeps input focus.
	transparent = true
	transparent_bg = true
	theme = Theme.new()
	size = DisplayServer.screen_get_size()
	always_on_top = false
	popup()
	transient = false
	always_on_top = true
	unfocusable = true
	# Clicks fall straight through to the game (same trick the old shuffler
	# used with set_mouse_passthrough_polygon([])).
	mouse_passthrough_polygon = PackedVector2Array()
	position = DisplayServer.screen_get_position()
	_screen = Vector2(size)

	var fonts := M3Theme.load_fonts()
	_title_label.add_theme_font_override("font", fonts.get("black", fonts.get("bold")))
	_title_label.add_theme_color_override("font_color", Color.WHITE)
	_title_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.5))
	_title_label.add_theme_constant_override("shadow_offset_y", M3Units.dp(2))
	_info_label.add_theme_font_override("font", fonts.get("medium", fonts.get("regular")))
	_info_label.add_theme_font_size_override("font_size", M3Units.dp(INFO_SIZE_DP))
	_info_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.75))

	var banner_style := StyleBoxFlat.new()
	banner_style.bg_color = Color(0.05, 0.05, 0.09, 0.95)
	banner_style.set_corner_radius_all(M3Units.dp(20))
	_banner.add_theme_stylebox_override("panel", banner_style)
	_banner.custom_minimum_size = Vector2(0, M3Units.dp(BANNER_HEIGHT_DP))
	_banner.resized.connect(_fit_title)

	var margin: MarginContainer = $Root/Banner/Margin
	margin.add_theme_constant_override("margin_left", M3Units.dp(BANNER_MARGIN_DP))
	margin.add_theme_constant_override("margin_right", M3Units.dp(BANNER_MARGIN_DP))
	margin.add_theme_constant_override("margin_top", M3Units.dp(16))
	margin.add_theme_constant_override("margin_bottom", M3Units.dp(16))

func present(game: GameResource) -> void:
	_reset_for_present()
	_title_label.text = game.title
	var platform_name := game.platform if game.platform != "" else game.platform_slug.capitalize()
	var info := platform_name
	if game.release_date > 0:
		var year := int(Time.get_datetime_dict_from_unix_time(int(game.release_date / 1000)).year)
		info += "  •  " + str(year)
	_info_label.text = info
	_load_cover(game)
	if not visible:
		show()
		move_to_foreground()
	call_deferred("_play")

## Kills any in-flight animation and restores every animated property to its
## pre-show state so a pooled window can run the sequence again cleanly.
func _reset_for_present() -> void:
	for tw in _tweens:
		if tw and tw.is_valid():
			tw.kill()
	_tweens.clear()
	_cover.texture = null
	_cover.visible = false
	_cover.modulate.a = 1.0
	_cover_placeholder.visible = true
	_cover_placeholder.modulate.a = 1.0
	_cover_pivot.visible = false
	_banner.modulate.a = 1.0
	_banner.custom_minimum_size.x = 0.0
	_present_generation += 1

# ============================================================================
# ANIMATION (ported beat-for-beat from notif_intro.gd)
# ============================================================================

func _play() -> void:
	if not is_inside_tree() or _screen == Vector2.ZERO:
		return
	_layout_cover()
	_fit_title()
	# Beat 1: cover starts fully below the screen and flies up to center.
	_cover_pivot.position = _screen * 0.5 + Vector2(0, _screen.y)
	_cover_pivot.visible = true
	var tw := create_tween()
	_tweens.append(tw)
	tw.set_trans(Tween.TRANS_CIRC).set_ease(Tween.EASE_OUT)
	tw.tween_property(_cover_pivot, "position", _screen * 0.5, 0.7)
	tw.tween_callback(_beat_two)

func _beat_two() -> void:
	# Beat 2: the cover slides left until it's flush with the screen's left
	# edge (the old clip_2 targeted an absolute x of half the art width),
	# dwells, then fades; meanwhile the banner sweeps in from the right edge,
	# its clip_contents revealing the labels as it grows, then fades too.
	var cover_tw := create_tween()
	_tweens.append(cover_tw)
	cover_tw.tween_interval(0.2)
	cover_tw.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	cover_tw.tween_property(_cover_pivot, "position", Vector2(_cover_size.x * 0.5, _screen.y * 0.5), 1.7)
	cover_tw.tween_interval(1.2)
	cover_tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	cover_tw.tween_property(_cover, "modulate:a", 0.0, 1.5)
	cover_tw.parallel().tween_property(_cover_placeholder, "modulate:a", 0.0, 1.5)

	var banner_tw := create_tween()
	_tweens.append(banner_tw)
	banner_tw.tween_interval(0.8)
	banner_tw.set_trans(Tween.TRANS_QUINT).set_ease(Tween.EASE_OUT)
	var target_w: float = maxf(_screen.x - _cover_size.x, 0.0)
	banner_tw.tween_property(_banner, "custom_minimum_size:x", target_w, 2.0)
	banner_tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	banner_tw.tween_property(_banner, "modulate:a", 0.0, 1.5)
	banner_tw.tween_callback(_beat_three)

func _beat_three() -> void:
	intro_finished.emit()
	# Pooled by the manager for the whole session: hide, don't free.
	hide()

# ============================================================================
# COVER LOADING (same cache pipeline as ShufflerChoiceWindow)
# ============================================================================

func _layout_cover() -> void:
	var aspect := COVER_ASPECT_FALLBACK
	if _cover.texture:
		aspect = float(_cover.texture.get_width()) / float(_cover.texture.get_height())
	_cover_size = Vector2(_screen.y * aspect, _screen.y)
	_cover.size = _cover_size
	_cover.position = -_cover_size * 0.5
	_cover_placeholder.size = _cover_size
	_cover_placeholder.position = -_cover_size * 0.5

func _apply_texture(tex: Texture2D) -> void:
	_cover.texture = tex
	_cover.visible = true
	_cover_placeholder.visible = false
	if _screen != Vector2.ZERO:
		_layout_cover()

func _load_cover(game: GameResource) -> void:
	var generation := _present_generation
	var self_ref: WeakRef = weakref(self)
	CoverLoader.request_cover(game, MAX_COVER_TEXTURE_SIZE, func(tex: Texture2D):
		var w = self_ref.get_ref()
		if w and w._present_generation == generation:
			w._apply_texture(tex)
	)

# ============================================================================
# TITLE FIT (port of autoscale_label.gd: shrink-to-fit, grows with the banner)
# ============================================================================

func _fit_title() -> void:
	var avail := _banner.size.x - M3Units.dp(BANNER_MARGIN_DP) * 2.0
	if avail <= 0:
		return
	var font: Font = _title_label.get_theme_font("font")
	if not font:
		return
	var size_px := int(M3Units.dp(TITLE_MAX_SIZE_DP))
	var min_px := int(M3Units.dp(TITLE_MIN_SIZE_DP))
	while size_px > min_px \
			and font.get_string_size(_title_label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size_px).x > avail:
		size_px -= 2
	_title_label.add_theme_font_size_override("font_size", size_px)
