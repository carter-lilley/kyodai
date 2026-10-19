class_name ScreenshotLightbox
extends M3Overlay

## Fullscreen lightbox for game-details screenshots.
## A thin M3Overlay (not a dialog): dark scrim + image centered with dp
## margins, no card restructuring. Dismisses on scrim click, close button,
## or ui_cancel (base-class handling). Non-persistent: frees on dismiss.

const MARGIN_DP := 48.0
const CLOSE_BOX_DP := 40.0
const CLOSE_INSET_DP := 16.0
const SCRIM_ALPHA := 0.75

var _scrim: ColorRect
var _margin: MarginContainer
var _image: TextureRect
var _frame: PanelContainer
var _close_button: M3IconButton
var _url: String = ""
var _viewport: Viewport = null
var _anim_tween: Tween = null

func _init() -> void:
	super._init()
	overlay_type = "screenshot_lightbox"
	overlay_layer = 95
	_restore_focus_on_dismiss = true
	_build()

func _build() -> void:
	_scrim = ColorRect.new()
	_scrim.name = "Scrim"
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, SCRIM_ALPHA)
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.gui_input.connect(_on_scrim_input)
	add_child(_scrim)

	# Full-rect margin: the "UI offsets" that center the image with a
	# border of empty space. Pure anchors/offsets, no layout changes.
	_margin = MarginContainer.new()
	_margin.name = "ImageMargin"
	_margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_margin)

	var center := CenterContainer.new()
	center.name = "Center"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_margin.add_child(center)

	_frame = PanelContainer.new()
	_frame.name = "Frame"
	_frame.clip_contents = true
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(_frame)

	_image = TextureRect.new()
	_image.name = "Image"
	_image.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_image.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_image.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_child(_image)

	_close_button = M3IconButton.new()
	_close_button.name = "CloseButton"
	_close_button.icon_name = "close"
	_close_button.tooltip_text = "Close"
	_close_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_close_button.pressed.connect(dismiss)
	add_child(_close_button)

func _ready() -> void:
	super._ready()
	_apply_margins()
	_style_frame()
	_restamp()
	_track_viewport()
	_update_close_geometry()

func _notification(what: int) -> void:
	if what == NOTIFICATION_ENTER_TREE:
		_track_viewport()
	elif what == NOTIFICATION_EXIT_TREE:
		_untrack_viewport()

func _track_viewport() -> void:
	var viewport := get_viewport()
	if viewport == _viewport:
		return
	_untrack_viewport()
	_viewport = viewport
	if _viewport and not _viewport.size_changed.is_connected(_restamp):
		_viewport.size_changed.connect(_restamp)

func _untrack_viewport() -> void:
	if _viewport and is_instance_valid(_viewport):
		if _viewport.size_changed.is_connected(_restamp):
			_viewport.size_changed.disconnect(_restamp)
	_viewport = null

func _apply_margins() -> void:
	if not is_instance_valid(_margin):
		return
	var m := M3Units.dp(MARGIN_DP)
	# Top margin additionally clears the window-chrome strip (custom title
	# bar), which renders above this overlay.
	var chrome := M3Overlay.get_chrome_top_inset()
	_margin.add_theme_constant_override("margin_left", int(m))
	_margin.add_theme_constant_override("margin_top", int(m + chrome))
	_margin.add_theme_constant_override("margin_right", int(m))
	_margin.add_theme_constant_override("margin_bottom", int(m))

func _update_close_geometry() -> void:
	if not is_instance_valid(_close_button):
		return
	var box := M3Units.dp(CLOSE_BOX_DP)
	var inset := M3Units.dp(CLOSE_INSET_DP)
	# Below the window-chrome strip so the button stays visible and clickable.
	var top := M3Overlay.get_chrome_top_inset() + inset
	_close_button.offset_left = -box - inset
	_close_button.offset_top = top
	_close_button.offset_right = -inset
	_close_button.offset_bottom = top + box

func _style_frame() -> void:
	if not is_instance_valid(_frame):
		return
	var sb := M3Theme.make_shadow(
		Color.BLACK,
		M3Units.dpi(M3Theme.RADIUS_LARGE),
		M3Theme.ELEVATION_3["size"],
		M3Theme.ELEVATION_3["offset"],
		M3Theme.ELEVATION_3["color"]
	)
	_frame.add_theme_stylebox_override("panel", sb)

## Fit the image inside the viewport minus the margin offsets, preserving
## aspect. Falls back to 16:9 while the texture is still loading.
func _restamp() -> void:
	if not is_instance_valid(_image) or not is_inside_tree():
		return
	var viewport := M3Overlay.get_sizing_viewport(get_viewport())
	if viewport == null:
		return
	var margin := M3Units.dp(MARGIN_DP)
	var avail := viewport.get_visible_rect().size - Vector2(margin, margin) * 2.0
	avail.y -= M3Overlay.get_chrome_top_inset()  # the margin above clears the chrome strip
	avail.x = maxf(avail.x, 1.0)
	avail.y = maxf(avail.y, 1.0)
	var aspect := 16.0 / 9.0
	if _image.texture:
		var tex_size := _image.texture.get_size()
		if tex_size.x > 0.0 and tex_size.y > 0.0:
			aspect = tex_size.x / tex_size.y
	var fitted := avail
	if avail.x / avail.y > aspect:
		fitted.x = avail.y * aspect
	else:
		fitted.y = avail.x / aspect
	_image.custom_minimum_size = fitted

func _on_scrim_input(event: InputEvent) -> void:
	var tapped := false
	if event is InputEventMouseButton:
		tapped = event.pressed and event.button_index == MOUSE_BUTTON_LEFT
	elif event is InputEventScreenTouch:
		tapped = event.pressed
	if tapped:
		get_viewport().set_input_as_handled()
		dismiss()

func _animate_in() -> void:
	if Engine.is_editor_hint() or not is_inside_tree():
		return
	if _anim_tween and _anim_tween.is_valid():
		_anim_tween.kill()
	_scrim.color.a = 0.0
	_margin.modulate.a = 0.0
	_anim_tween = create_tween()
	_anim_tween.set_parallel(true)
	_anim_tween.set_trans(M3Motion.EASE_ENTER_TRANS)
	_anim_tween.set_ease(M3Motion.EASE_ENTER)
	_anim_tween.tween_property(_scrim, "color:a", SCRIM_ALPHA, M3Motion.OVERLAY)
	_anim_tween.tween_property(_margin, "modulate:a", 1.0, M3Motion.OVERLAY)

func show_overlay() -> void:
	super.show_overlay()
	_restamp()
	_animate_in()
	if is_instance_valid(_close_button):
		if UIManager and UIManager.has_method("suppress_next_focus_sound"):
			UIManager.suppress_next_focus_sound()
		_close_button.grab_focus.call_deferred()

func dismiss() -> void:
	if _anim_tween and _anim_tween.is_valid():
		_anim_tween.kill()
	if is_instance_valid(_image):
		M3Shimmer.detach(_image)
	super.dismiss()

## Settled-geometry hook (broadcast by OverlaySubManager on debounced
## resizes and DS swaps, and by M3Overlay.notify_chrome_inset_changed).
func on_viewport_settled() -> void:
	if visible and is_inside_tree():
		_apply_margins()
		_update_close_geometry()
		_restamp()

func refresh_scale() -> void:
	_apply_margins()
	_style_frame()
	_update_close_geometry()
	_restamp()

## Show a texture fullscreen. Pass the already-loaded thumb texture for an
## instant open; url covers the still-loading case (shimmer until it lands).
static func show_image(texture: Texture2D, url: String = "", summoner: Control = null) -> ScreenshotLightbox:
	var viewer := ScreenshotLightbox.new()
	if texture:
		viewer._image.texture = texture
	elif url != "":
		viewer._url = url
		M3Shimmer.attach(viewer._image, 0.05)
		DataManager.load_image(url, func(loaded: Texture2D, _r: int):
			if not is_instance_valid(viewer) or not is_instance_valid(viewer._image):
				return
			M3Shimmer.detach(viewer._image)
			if loaded:
				viewer._image.texture = loaded
				viewer._restamp()
			else:
				viewer.dismiss()
		)
	if summoner:
		viewer.set_focus_restore_target(summoner)
	viewer.show_overlay()
	return viewer
