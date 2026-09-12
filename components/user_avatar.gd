class_name UserAvatar
extends Control

## Circular profile avatar for the controls bar. Shows the current RomM
## user's avatar image, falling back to a generic account icon when no
## avatar is set or the image has not loaded yet. Decorative only: all
## input is ignored.
##
## Rendering reuses the card effect pipeline (EffectStack + MediaContainer):
## the base effect center-crops the image and clips it to a circle via the
## rounded-rect SDF (corner_radius_ratio = 1.0), and the border effect draws
## the ring around it.

const SIZE_DP := 76

## Ring width as a ratio of the avatar width.
const BORDER_RATIO := 0.07

## Ring color, applied as a single-stop gradient (solid color resolution).
const BORDER_COLOR := Color.WHITE

## Center-crop factor applied before upload so the subject fills the circle.
const CENTER_CROP := 0.9

## Sources at or below this width are treated as pixel art and sampled with
## nearest-neighbor filtering so they stay crisp; larger sources use linear.
const PIXEL_ART_MAX_WIDTH := 128

var _fallback_icon: FontIcon = null
var _media_container: MediaContainer = null
var _stack: EffectStack = null

func _ready() -> void:
	custom_minimum_size = Vector2.ONE * M3Units.dp(SIZE_DP)
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_fallback_icon = FontIcon.new()
	_fallback_icon.icon_settings = FontIconSettings.new()
	_fallback_icon.icon_settings.icon_font = "MaterialIcons"
	_fallback_icon.icon_settings.icon_name = "account-circle"
	_fallback_icon.icon_settings.icon_size = M3Units.dp(SIZE_DP)
	_fallback_icon.icon_settings.icon_color = M3Theme.get_on_surface_variant()
	_fallback_icon.icon_settings.outline_color = Color.TRANSPARENT
	_fallback_icon.icon_settings.shadow_color = Color.TRANSPARENT
	_fallback_icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_fallback_icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_fallback_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fallback_icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_fallback_icon)

	_media_container = MediaContainer.new()
	_media_container.corner_radius_ratio = 1.0
	_media_container.edge_aa_enabled = true
	_media_container.bounds = Rect2(Vector2.ZERO, size)

	_stack = EffectStack.new()
	_stack.set_parent_rid(get_canvas_item())
	_stack.set_clip_children(false)
	var ring_gradient := Gradient.new()
	ring_gradient.offsets = [0.0]
	ring_gradient.colors = [BORDER_COLOR]
	_stack.initialize(_media_container, [
		{"effect_id": "border", "settings": {
			"border_size": BORDER_RATIO,
			"border_gradient": ring_gradient,
		}},
	], "base_card")
	# The stack insets the media by border_size, which makes the image's AA
	# edge expose the background between image and ring (visible as a dark
	# jagged seam). Zero the inset so the image fills the whole circle and
	# the ring draws on top of it instead.
	_media_container.border_inset_ratio = 0.0
	_stack.force_refresh()
	# Hidden until an avatar image arrives; the fallback icon shows instead.
	_stack.set_visible(false)

	resized.connect(_on_resized)

func _on_resized() -> void:
	if _media_container:
		_media_container.bounds = Rect2(Vector2.ZERO, size)
	if _stack:
		_stack.update_draw_rects()
		_reapply_texture_filter()

func set_avatar_image(image: Image) -> void:
	if image == null or image.is_empty() or not _stack:
		clear_avatar()
		return
	var cropped := _center_crop(image)
	_stack.set_game_texture(ImageTexture.create_from_image(cropped))
	_pixel_art = cropped.get_width() <= PIXEL_ART_MAX_WIDTH
	_reapply_texture_filter()
	_stack.set_visible(true)
	_fallback_icon.visible = false

func clear_avatar() -> void:
	if _stack:
		_stack.set_visible(false)
	_fallback_icon.visible = true

var _pixel_art: bool = false

func _reapply_texture_filter() -> void:
	var base_effect := _stack.get_effect("base") if _stack else null
	if base_effect:
		base_effect.set_texture_filter(
			RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_NEAREST if _pixel_art
			else RenderingServer.CANVAS_ITEM_TEXTURE_FILTER_LINEAR)

func _center_crop(image: Image) -> Image:
	var w := image.get_width()
	var h := image.get_height()
	var cw := int(w * CENTER_CROP)
	var ch := int(h * CENTER_CROP)
	if cw <= 0 or ch <= 0 or (cw == w and ch == h):
		return image
	return image.get_region(Rect2i((w - cw) / 2, (h - ch) / 2, cw, ch))
