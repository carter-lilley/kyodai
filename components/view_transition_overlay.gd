class_name ViewTransitionOverlay
extends Control

## Fullscreen wipe transition played when switching between main views.
## A colored panel sweeps up from the bottom, the tab switches under cover,
## a centered icon slides in from the bottom with a springy bounce, then the
## panel exits off the top revealing the new view.

signal transition_finished

# Global flag so other systems can tell a view transition is mid-flight.
static var is_transition_active: bool = false

const COVER_DURATION: float = 0.26
const ICON_DURATION: float = 0.34
const HOLD_DURATION: float = 0.05
const REVEAL_DURATION: float = 0.3
const ICON_HEIGHT_RATIO: float = 0.22
const TILT_IN: float = 9.0

# Preloaded so the first transition doesn't hitch on the initial decode.
const SNAP_SFX: AudioStream = preload("res://assets/audio/sfx/snap.wav")

var _panel: ColorRect = null
var _icon: FontIcon = null
var _is_animating: bool = false
var _midpoint: Callable = Callable()
var _midpoint_called: bool = false

func _ready() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	z_index = OverlayLayers.VIEW_TRANSITION_Z
	add_to_group("view_transition_overlay")

	# Warm the icon font so the first transition doesn't hitch on the load.
	var _warm_font: Font = load(IconsFonts.material_icons_font)

	_panel = ColorRect.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)

	_icon = FontIcon.new()
	_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# Center anchors so position maps directly to a centered resting spot.
	_icon.anchor_left = 0.5
	_icon.anchor_right = 0.5
	_icon.anchor_top = 0.5
	_icon.anchor_bottom = 0.5
	_icon.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_icon.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(_icon)

func _input(_event: InputEvent) -> void:
	if _is_animating and visible:
		get_viewport().set_input_as_handled()

func is_animating() -> bool:
	return _is_animating

func play(icon_name: String, midpoint: Callable) -> void:
	play_extended(icon_name, midpoint, Callable(), 0)

## Variant that holds the full-cover midpoint until readiness.call() reports
## true (or max_hold_ms elapses). Lazy views settle their grid under cover, so
## the reveal never shows a half-built view; the screen is static during the
## hold, so the wait reads as a slightly longer cover, not a stutter.
func play_extended(icon_name: String, midpoint: Callable, readiness: Callable = Callable(), max_hold_ms: int = 400) -> void:
	if _is_animating:
		midpoint.call()
		return

	var viewport_size := Vector2(get_viewport().get_visible_rect().size)
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		midpoint.call()
		return

	_is_animating = true
	is_transition_active = true
	_midpoint = midpoint
	_midpoint_called = false

	# Refresh colors at play time so theme changes are picked up automatically.
	# Container colors are the muted M3 tonal pair: a colored dim in dark mode
	# rather than a fullscreen bright flash.
	_panel.color = M3Theme.get_primary_container()
	_icon.icon_settings.icon_color = M3Theme.get_on_primary_container()
	_icon.icon_settings.icon_name = icon_name

	# Cap the icon in dp so it stays charming-sized on large displays instead
	# of scaling unbounded with viewport height.
	var icon_px: float = maxf(48.0, minf(viewport_size.y * ICON_HEIGHT_RATIO, M3Units.dp(160.0)))
	_icon.icon_settings.icon_size = int(icon_px)
	_icon.custom_minimum_size = Vector2(icon_px, icon_px)
	_icon.size = Vector2(icon_px, icon_px)
	_icon.pivot_offset = Vector2(icon_px, icon_px) / 2.0
	_icon.offset_left = -icon_px / 2.0
	_icon.offset_right = icon_px / 2.0

	# Start positions: panel parked below the screen, icon at the bottom edge
	# of where the panel will be once it covers the screen.
	_panel.position = Vector2(0.0, viewport_size.y)
	var icon_rest_y: float = -icon_px / 2.0
	_icon.offset_top = viewport_size.y * 0.75
	_icon.offset_bottom = viewport_size.y * 0.75 + icon_px
	_icon.scale = Vector2(0.5, 0.5)
	_icon.rotation_degrees = TILT_IN
	_icon.modulate.a = 0.0

	visible = true

	if SystemManager.audio:
		SystemManager.audio.play_sfx_stream(SNAP_SFX)

	_animate(midpoint, viewport_size, icon_px, icon_rest_y, _travel_duration_scale(), readiness, max_hold_ms)

func _travel_duration_scale() -> float:
	# Large screens: the panel travels farther, so compress the cover/reveal
	# to keep the flash duration consistent with small screens.
	if SystemManager.display and not SystemManager.display.is_narrow_viewport():
		return 0.85
	return 1.0

func _animate(midpoint: Callable, viewport_size: Vector2, icon_px: float, icon_rest_y: float, travel_scale: float = 1.0, readiness: Callable = Callable(), max_hold_ms: int = 0) -> void:
	# Phase 1: panel sweeps up and covers the screen.
	# Tweens are scene-tree-bound so they keep running through DS-mode
	# reparenting; if the overlay is permanently removed mid-transition the
	# is_inside_tree guards route to _cancel_transition so state always resets.
	var cover := get_tree().create_tween()
	cover.set_trans(Tween.TRANS_CUBIC)
	cover.set_ease(Tween.EASE_OUT)
	cover.tween_property(_panel, "position:y", 0.0, COVER_DURATION * travel_scale)
	await cover.finished
	if not is_inside_tree():
		_cancel_transition()
		return

	# Midpoint: the actual tab switch happens under cover.
	midpoint.call()
	_midpoint_called = true

	# Hold the cover until the new view reports ready. No tweens are running
	# yet, so a wait here cannot break animation timing.
	if readiness.is_valid() and max_hold_ms > 0:
		var hold_start := Time.get_ticks_msec()
		while not readiness.call() and Time.get_ticks_msec() - hold_start < max_hold_ms:
			await get_tree().process_frame
		if not is_inside_tree():
			_cancel_transition()
			return

	# Phase 2: icon slides in from the bottom with a springy bounce, gently
	# straightening from its initial tilt as it lands.
	var entrance := get_tree().create_tween()
	entrance.set_parallel(true)
	entrance.set_trans(Tween.TRANS_BACK)
	entrance.set_ease(Tween.EASE_OUT)
	entrance.tween_property(_icon, "offset_top", icon_rest_y, ICON_DURATION)
	entrance.tween_property(_icon, "offset_bottom", icon_rest_y + icon_px, ICON_DURATION)
	entrance.tween_property(_icon, "scale", Vector2.ONE, ICON_DURATION)
	entrance.tween_property(_icon, "rotation_degrees", 0.0, ICON_DURATION)
	entrance.tween_property(_icon, "modulate:a", 1.0, ICON_DURATION * 0.5)

	# Start the exit just before the icon fully settles so the whole sequence
	# stays in motion; the reveal takes over from the icon's current position.
	await get_tree().create_timer(ICON_DURATION * 0.8).timeout
	if not is_inside_tree():
		_cancel_transition()
		return
	entrance.kill()

	# Barely a beat at the top of the bounce.
	await get_tree().create_timer(HOLD_DURATION).timeout
	if not is_inside_tree():
		_cancel_transition()
		return

	# Phase 3: panel and icon accelerate off the top together, revealing the
	# new view underneath.
	var reveal := get_tree().create_tween()
	reveal.set_parallel(true)
	reveal.set_trans(Tween.TRANS_CUBIC)
	reveal.set_ease(Tween.EASE_IN)
	reveal.tween_property(_panel, "position:y", -viewport_size.y, REVEAL_DURATION * travel_scale)
	reveal.tween_property(_icon, "offset_top", icon_rest_y - viewport_size.y * 0.75, REVEAL_DURATION * travel_scale)
	reveal.tween_property(_icon, "offset_bottom", icon_rest_y + icon_px - viewport_size.y * 0.75, REVEAL_DURATION * travel_scale)
	await reveal.finished

	_on_transition_finished()

## Aborts a transition whose coroutine was interrupted (tree exit, reparent).
## Runs the midpoint if it never ran so the pending tab switch isn't lost,
## then always resets state - a stranded overlay eats all view-layer input.
func _cancel_transition() -> void:
	if not _is_animating:
		return
	if not _midpoint_called and _midpoint.is_valid():
		_midpoint.call()
		_midpoint_called = true
	_on_transition_finished()

func _exit_tree() -> void:
	# DS-mode reparenting removes the UI subtree mid-transition; make sure a
	# transition in flight always settles instead of stranding input.
	if _is_animating:
		_cancel_transition()

func _on_transition_finished() -> void:
	if not _is_animating:
		return
	_midpoint = Callable()
	_midpoint_called = false
	visible = false
	_is_animating = false
	is_transition_active = false
	transition_finished.emit()
