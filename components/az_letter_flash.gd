class_name AZLetterFlash
extends Control

## Grid-centered big-letter flash shown when the A-Z carousel swaps letters.
## Quick pop-in, brief hold, fade-out. Pure overlay: mouse_filter IGNORE on
## every node so it never eats input or focus; hidden at rest.
##
## Usage:
##   flash(letter)  # show/update the letter and (re)start the fade cycle
##   hide_flash()   # hide immediately (e.g. on view hide)

const SCRIM_ALPHA: float = 0.3
const LETTER_SIZE_DP: float = 96.0
const FADE_IN: float = 0.12
const HOLD: float = 0.6
const FADE_OUT: float = 0.25
const POP_FROM_SCALE: float = 0.8

var _scrim: ColorRect
var _center: CenterContainer
var _label: M3Label
var _tween: Tween = null


func _ready() -> void:
	z_index = 20
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	_apply_letter_size()


func _build() -> void:
	_scrim = ColorRect.new()
	_scrim.name = "Scrim"
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, SCRIM_ALPHA)
	_scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_scrim)

	_center = CenterContainer.new()
	_center.name = "Center"
	_center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_center)

	_label = M3Label.new()
	_label.name = "Letter"
	_label.label_style = M3Label.Style.DISPLAY_LARGE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center.add_child(_label)


func _apply_letter_size() -> void:
	if _label:
		_label.add_theme_font_size_override("font_size", int(M3Units.dp(LETTER_SIZE_DP)))


func refresh_theme() -> void:
	if _label and _label.has_method("refresh_theme"):
		_label.refresh_theme()
	_apply_letter_size()


## Show the letter and (re)start the pop-in/hold/fade-out cycle. Calling this
## again mid-flash (e.g. fast scrubbing) swaps the text and restarts the
## cycle instead of stacking flashes.
func flash(letter: String) -> void:
	if letter.is_empty() or not is_inside_tree():
		return
	_label.text = letter
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = null
	visible = true
	modulate.a = 0.0
	# Scale around the grid center so the pop-in grows in place.
	_center.pivot_offset = _center.size / 2.0
	_center.scale = Vector2.ONE * POP_FROM_SCALE
	_tween = create_tween()
	_tween.set_parallel(true)
	_tween.set_trans(M3Motion.EASE_ENTER_TRANS)
	_tween.set_ease(M3Motion.EASE_ENTER)
	_tween.tween_property(self, "modulate:a", 1.0, FADE_IN)
	_tween.tween_property(_center, "scale", Vector2.ONE, FADE_IN).set_trans(M3Motion.EASE_POP_TRANS).set_ease(M3Motion.EASE_POP)
	_tween.set_parallel(false)
	_tween.tween_interval(HOLD)
	_tween.set_parallel(true)
	_tween.set_trans(M3Motion.EASE_EXIT_TRANS)
	_tween.set_ease(M3Motion.EASE_EXIT)
	_tween.tween_property(self, "modulate:a", 0.0, FADE_OUT)
	_tween.set_parallel(false)
	_tween.tween_callback(_hide)


func hide_flash() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = null
	_hide()


func _hide() -> void:
	visible = false
