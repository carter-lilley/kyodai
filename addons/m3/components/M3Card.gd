@tool
class_name M3Card
extends Button

const EffectStack = preload("res://components/effects/effect_stack.gd")
const EffectBase = preload("res://components/effects/effect_base.gd")

## Material 3 Card Component
## Extends native Button so the whole card is focusable and clickable.
## Internal children use MOUSE_FILTER_IGNORE — only the card handles input.

enum Variant { ELEVATED, FILLED, OUTLINED }
enum LayoutMode { VERTICAL, HORIZONTAL }
enum ContentAlignment { START, CENTER, END }

# ============================================
# SIZE SPECS (all values in dp)
# ============================================

const PADDING := 16.0

# Card corner rounding ratio: 0.0 = square, 1.0 = capsule (min(w,h)/2)
var card_rounding_ratio: float = 0.12:
	set(value):
		var clamped = clampf(value, 0.0, 1.0)
		if is_equal_approx(clamped, card_rounding_ratio):
			return
		card_rounding_ratio = clamped
		if _ready_called:
			queue_redraw()
			_update_focus_ring_radius()

const MEDIA_WIDTH_LIST := 256.0
# M3 type-scale tiers keyed by minimum card-height (dp).
# Headline uses medium weight; supporting uses regular weight.
const _HEADLINE_SCALE := [
	{ "threshold_dp": 280.0, "size": 22.0, "weight": "medium" },  # Title Large
	{ "threshold_dp": 200.0, "size": 16.0, "weight": "medium" },  # Title Medium
	{ "threshold_dp": 140.0, "size": 14.0, "weight": "medium" },  # Title Small
	{ "threshold_dp":   0.0, "size": 12.0, "weight": "medium" },  # Label Medium
]
const _SUPPORTING_SCALE := [
	{ "threshold_dp": 200.0, "size": 14.0, "weight": "regular" }, # Body Medium
	{ "threshold_dp": 140.0, "size": 12.0, "weight": "regular" }, # Body Small
	{ "threshold_dp":   0.0, "size": 11.0, "weight": "medium" },  # Label Small
]
const ACTIONS_GAP := 8.0
const LABEL_GAP := 4.0
const MIN_HEIGHT_VERTICAL_DP := 240.0
const MIN_HEIGHT_HORIZONTAL_DP := 80.0

# ============================================
# EXPORTS
# ============================================

@export var card_variant: Variant = Variant.ELEVATED:
	set(value):
		if value == card_variant:
			return
		card_variant = value
		if _ready_called:
			queue_redraw()

@export var card_layout_mode: LayoutMode = LayoutMode.VERTICAL:
	set(value):
		if value == card_layout_mode:
			return
		card_layout_mode = value
		if _ready_called:
			_rebuild_layout()
			_update_media()
			_update_text()
			_update_appearance()
			_rebuild_actions()

@export var content_alignment: ContentAlignment = ContentAlignment.START:
	set(value):
		if value == content_alignment:
			return
		content_alignment = value
		if _ready_called:
			_rebuild_layout()
			_update_media()
			_update_text()
			_update_appearance()
			_rebuild_actions()

var media_aspect_ratio: float = -1.0:
	set(value):
		if is_equal_approx(media_aspect_ratio, value):
			return
		# Sentinel -1.0 = fill mode; any other value must be positive
		if value != -1.0 and value <= 0.0:
			push_warning("M3Card: media_aspect_ratio must be > 0 or -1.0 (fill). Got %f, ignoring." % value)
			return
		media_aspect_ratio = value
		if _ready_called:
			_rebuild_layout()
			_update_text()
			_update_appearance()
			queue_redraw()

func set_media_aspect_ratio(ratio: float) -> void:
	media_aspect_ratio = ratio

func set_content_alignment(alignment: ContentAlignment) -> void:
	content_alignment = alignment

@export var media_texture: Texture2D:
	set(value):
		if value == media_texture:
			return
		media_texture = value
		if _ready_called:
			_update_media()

@export var headline: String = "":
	set(value):
		if value == headline:
			return
		headline = value
		if _ready_called:
			_update_text()

@export var supporting_text: String = "":
	set(value):
		if value == supporting_text:
			return
		supporting_text = value
		if _ready_called:
			_update_text()

@export var clickable: bool = true:
	set(value):
		if value == clickable:
			return
		clickable = value
		if _ready_called:
			_apply_clickable_state()

var show_background: bool = true:
	set(value):
		if show_background == value:
			return
		show_background = value
		if _ready_called:
			queue_redraw()
			_update_focus_ring_bounds()
			_update_media_panel_size(true)

var show_text_margin: bool = true:
	set(value):
		if show_text_margin == value:
			return
		show_text_margin = value
		if _ready_called:
			if _text_margin:
				_text_margin.visible = value
			_update_media_panel_size(true)
			queue_redraw()

# ============================================
# INTERNAL
# ============================================

var _root_container: Control
var _media_panel: Control
var _media_rect: TextureRect
var _text_margin: MarginContainer
var _text_content: VBoxContainer
var _headline_label: Label
var _supporting_label: Label
var _actions_hbox: HBoxContainer
var _focus_ring: Panel

# Media container shared with effect stack
var _media_container: MediaContainer

var _cached_stylebox: StyleBoxFlat
var _cached_fonts: Dictionary = {}
var _action_labels: Array[String] = []

# Deferred-call guard to prevent accumulation during rapid resize/zoom drags
var _focus_ring_bounds_queued: bool = false
var _ready_called: bool = false
var _media_content: Control = null
var _applied_headline_size_dp: float = -1.0
var _applied_supporting_size_dp: float = -1.0

# Computed media dimensions for focus-ring sizing in Transparent mode
var _focus_target_w: float = 0.0
var _focus_target_h: float = 0.0

# Cache last-applied theme values to avoid redundant overrides
var _applied_font_color: Color = Color(-1, -1, -1)
var _applied_supporting_color: Color = Color(-1, -1, -1)
var _applied_text_shadow_enabled: bool = false
var _applied_margin_left: int = -1
var _applied_margin_right: int = -1
var _applied_margin_top: int = -1
var _applied_margin_bottom: int = -1

# Cache last-set media panel min sizes to prevent layout thrashing
var _last_media_min_y: float = -1.0
var _last_media_min_x: float = -1.0
var _last_media_pos_x: float = -1.0
var _last_media_pos_y: float = -1.0

# ============================================
# CONTENT SCALE (visual pop without affecting parent layout)
# ============================================

var content_scale: Vector2 = Vector2.ONE:
	set(value):
		if content_scale.is_equal_approx(value):
			return
		content_scale = value
		_apply_content_scale()
		queue_redraw()

func _update_focus_ring_radius() -> void:
	if not _focus_ring:
		return
	var focus_sb = _focus_ring.get_theme_stylebox("panel") as StyleBoxFlat
	if not focus_sb:
		return
	# Use _focus_target_w/h which are set authoritatively by _update_media_panel_size.
	# Don't use _media_panel.size here — it may be stale during the immediate call
	# before Godot's layout system has finished resizing the panel.
	var target_w = _focus_target_w if _focus_target_w > 0.0 else _focus_ring.size.x
	var target_h = _focus_target_h if _focus_target_h > 0.0 else _focus_ring.size.y
	var max_radius = min(target_w, target_h) / 2.0
	var radius = card_rounding_ratio * max_radius
	# The focus ring is scaled by content_scale in _apply_content_scale().
	# StyleBoxFlat corner radius scales with the control, but the shader renders
	# in unscaled local space. Compensate so screen-space radii match.
	if not is_equal_approx(content_scale.x, 1.0):
		radius = radius / content_scale.x
	focus_sb.set_corner_radius_all(int(round(radius)))

func _update_focus_ring_bounds() -> void:
	_focus_ring_bounds_queued = false
	if not _focus_ring or not _media_panel:
		return
	# Use our computed targets (_focus_target_w/h are set authoritatively
	# by _update_media_panel_size). Don't overwrite them with _media_panel.size
	# which may be stale during immediate calls before layout settles.
	var target_w := _focus_target_w
	var target_h := _focus_target_h
	if target_w <= 0.0:
		target_w = size.x
	if target_h <= 0.0:
		target_h = size.y
	if not show_background:
		# Transparent / Media Only: focus ring only around the media area
		# Account for content alignment — media panel may be centered or offset
		var media_x := 0.0
		var media_y := 0.0
		var media_w := target_w
		var media_h := target_h
		if _media_panel:
			media_x = _media_panel.position.x
			media_y = _media_panel.position.y
			# Use actual media panel size when available — _focus_target_w/h may
			# be stale if the container allocated a different size than expected.
			if _media_panel.size.x > 0.0:
				media_w = _media_panel.size.x
			if _media_panel.size.y > 0.0:
				media_h = _media_panel.size.y
		_focus_ring.offset_top = media_y
		_focus_ring.offset_left = media_x
		_focus_ring.offset_bottom = -(size.y - media_y - media_h)
		_focus_ring.offset_right = -(size.x - media_x - media_w)
	else:
		# Standard: focus ring fills the card
		_focus_ring.offset_top = 0.0
		_focus_ring.offset_left = 0.0
		_focus_ring.offset_bottom = 0.0
		_focus_ring.offset_right = 0.0
	_update_focus_ring_radius()

func _apply_content_scale() -> void:
	if _root_container:
		_root_container.scale = content_scale
		_root_container.pivot_offset = _root_container.size / 2.0
	if _focus_ring:
		_focus_ring.scale = content_scale
		# Scale the focus ring around the card's centre so it stays in sync
		# with the content inside _root_container (which also pivots around
		# the card centre). The focus ring's local origin is at (media_x,
		# media_y) because of its FULL_RECT anchors + offsets, so we have to
		# offset the pivot by that amount.
		var media_x := 0.0
		var media_y := 0.0
		if _media_panel:
			media_x = _media_panel.position.x
			media_y = _media_panel.position.y
		_focus_ring.pivot_offset = Vector2(size.x / 2.0 - media_x, size.y / 2.0 - media_y)
		# In transparent/media-only mode the focus ring tracks the media panel,
		# so refresh bounds after scaling to stay in sync.
		if not show_background:
			_update_focus_ring_bounds()

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	flat = true
	text = ""
	set_clip_children_mode(CanvasItem.ClipChildrenMode.CLIP_CHILDREN_AND_DRAW)
	
	_media_container = MediaContainer.new()
	
	_cached_fonts = M3Theme.load_fonts()
	_initialize_styleboxes()
	_rebuild_layout()
	_update_media()
	_update_text()
	_update_appearance()
	
	# Suppress native focus stylebox; we use a child panel instead
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	
	# Mouse / focus state tracking
	# NOTE: mouse enter/exit redraws are handled by NOTIFICATION_MOUSE_ENTER/EXIT
	# below, which is more comprehensive (also updates focus ring, media panel,
	# text sizing, etc.). Do NOT connect mouse_entered/exited signals here or
	# queue_redraw() will fire twice per event.
	focus_entered.connect(_on_focus_changed)
	focus_exited.connect(_on_focus_changed)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	
	_apply_clickable_state()
	_ready_called = true

func _apply_clickable_state():
	if clickable:
		focus_mode = Control.FOCUS_ALL
		button_mask = MouseButtonMask.MOUSE_BUTTON_MASK_LEFT
		mouse_filter = Control.MOUSE_FILTER_STOP
	else:
		focus_mode = Control.FOCUS_NONE
		button_mask = MouseButton.MOUSE_BUTTON_NONE
		mouse_filter = Control.MOUSE_FILTER_PASS
		_hovered = false
		_is_pressing = false
	queue_redraw()

func _initialize_styleboxes():
	_cached_stylebox = StyleBoxFlat.new()
	_cached_stylebox.anti_aliasing = true
	_cached_stylebox.anti_aliasing_size = 1.0
	_cached_stylebox.set_border_width_all(0)

func _rebuild_layout():
	# Reset all applied-state trackers since the entire node tree is being recreated.
	# Without this, guards in _update_text(), _update_appearance(), and
	# _update_media_panel_size() will incorrectly skip applying values to new nodes.
	_applied_headline_size_dp = -1.0
	_applied_supporting_size_dp = -1.0
	_applied_font_color = Color(-1, -1, -1)
	_applied_supporting_color = Color(-1, -1, -1)
	_applied_margin_left = -1
	_applied_margin_right = -1
	_applied_margin_top = -1
	_applied_margin_bottom = -1
	_last_media_min_y = -1.0
	_last_media_min_x = -1.0
	_last_media_pos_x = -1.0
	_last_media_pos_y = -1.0
	
	# --- Preserve reusable children before destroying old tree ---
	# Extract media content/rect so they survive root container destruction
	var preserved_media_content: Control = null
	var preserved_media_rect: TextureRect = null
	if _media_panel and is_instance_valid(_media_panel):
		for child in _media_panel.get_children():
			if child == _media_content and is_instance_valid(child):
				preserved_media_content = child
				_media_panel.remove_child(child)
			elif child == _media_rect and is_instance_valid(child):
				preserved_media_rect = child
				_media_panel.remove_child(child)
	
	# Extract labels so they can be reparented
	var preserved_headline: Label = null
	var preserved_supporting: Label = null
	if _text_content and is_instance_valid(_text_content):
		for child in _text_content.get_children():
			if child == _headline_label and is_instance_valid(child):
				preserved_headline = child
				_text_content.remove_child(child)
			elif child == _supporting_label and is_instance_valid(child):
				preserved_supporting = child
				_text_content.remove_child(child)
	
	# Remove old root container and focus ring from the tree immediately
	# so the new nodes don't get auto-renamed by Godot.
	if _root_container and is_instance_valid(_root_container):
		if _root_container.get_parent() == self:
			remove_child(_root_container)
		_root_container.queue_free()
	if _focus_ring and is_instance_valid(_focus_ring):
		if _focus_ring.get_parent() == self:
			remove_child(_focus_ring)
		_focus_ring.queue_free()
	
	# Use a plain Control as root and manually position children.
	# BoxContainer's asynchronous layout was causing race conditions during mode switches.
	_root_container = Control.new()
	_root_container.name = "RootContainer"
	_root_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root_container)
	
	# Media panel
	_media_panel = Control.new()
	_media_panel.name = "MediaPanel"
	_media_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	
	if preserved_media_content:
		_media_panel.add_child(preserved_media_content)
	elif preserved_media_rect:
		_media_panel.add_child(preserved_media_rect)
	else:
		_media_rect = TextureRect.new()
		_media_rect.name = "MediaRect"
		_media_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_media_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_media_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_media_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_media_rect.visible = false
		_media_panel.add_child(_media_rect)
	_root_container.add_child(_media_panel)
	
	# Text margin
	_text_margin = MarginContainer.new()
	_text_margin.name = "TextMargin"
	_text_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_margin.visible = show_text_margin
	_root_container.add_child(_text_margin)
	
	if card_layout_mode == LayoutMode.HORIZONTAL:
		# Horizontal: text and actions in a row, vertically centered
		var text_row = HBoxContainer.new()
		text_row.name = "TextRow"
		text_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		text_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
		text_row.alignment = BoxContainer.ALIGNMENT_CENTER
		_text_margin.add_child(text_row)
		
		_text_content = VBoxContainer.new()
		_text_content.name = "TextContent"
		_text_content.add_theme_constant_override("separation", M3Units.dp(LABEL_GAP))
		_text_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_text_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_text_content.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		text_row.add_child(_text_content)
		
		_actions_hbox = HBoxContainer.new()
		_actions_hbox.name = "Actions"
		_actions_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_actions_hbox.visible = false
		_actions_hbox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_actions_hbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		text_row.add_child(_actions_hbox)
	else:
		# Vertical: text stacked with actions below
		_text_content = VBoxContainer.new()
		_text_content.name = "TextContent"
		_text_content.add_theme_constant_override("separation", M3Units.dp(LABEL_GAP))
		_text_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_text_margin.add_child(_text_content)
		
		_actions_hbox = HBoxContainer.new()
		_actions_hbox.name = "Actions"
		_actions_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_actions_hbox.visible = false
		_text_content.add_child(_actions_hbox)
	
	if preserved_headline:
		_headline_label = preserved_headline
	else:
		_headline_label = Label.new()
		_headline_label.name = "Headline"
		_headline_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_headline_label.max_lines_visible = 1
		_headline_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_headline_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_headline_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_content.add_child(_headline_label)
	
	if preserved_supporting:
		_supporting_label = preserved_supporting
	else:
		_supporting_label = Label.new()
		_supporting_label.name = "SupportingText"
		_supporting_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_supporting_label.max_lines_visible = 1
		_supporting_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_supporting_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_supporting_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_content.add_child(_supporting_label)
	
	# Focus ring panel (draws on top of everything)
	_focus_ring = Panel.new()
	_focus_ring.name = "FocusRing"
	_focus_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_focus_ring.set_anchors_preset(Control.PRESET_FULL_RECT)
	_focus_ring.visible = false
	_focus_ring.z_index = 10
	var focus_sb = StyleBoxFlat.new()
	focus_sb.bg_color = Color.TRANSPARENT
	focus_sb.border_color = M3Theme.get_primary()
	focus_sb.set_border_width_all(M3Units.dp(2))
	focus_sb.anti_aliasing = true
	focus_sb.anti_aliasing_size = 1.0
	_focus_ring.add_theme_stylebox_override("panel", focus_sb)
	_update_focus_ring_radius()
	add_child(_focus_ring)
	
	_rebuild_actions()
	_apply_content_scale()
	# _update_media_panel_size() needs the card's final size, which isn't
	# available until FlowContainer finishes its layout pass. Defer the call
	# so it runs after the card has been properly sized.
	call_deferred("_update_media_panel_size", true)

# ============================================
# DRAW
# ============================================

func _draw():
	if not _cached_stylebox:
		return
	
	var rect = Rect2(Vector2.ZERO, size)
	var max_radius = min(size.x, size.y) / 2.0
	var radius = int(round(card_rounding_ratio * max_radius))
	
	_configure_stylebox_for_state()
	_cached_stylebox.set_corner_radius_all(radius)
	
	# Draw card background — scale from center to match content_scale
	if show_background:
		if content_scale.is_equal_approx(Vector2.ONE):
			draw_style_box(_cached_stylebox, rect)
		else:
			var center = size / 2.0
			draw_set_transform(center, 0.0, content_scale)
			draw_style_box(_cached_stylebox, Rect2(-size / 2.0, size))
			draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

func _configure_stylebox_for_state():
	var bg: Color
	var outline_w: int = 0
	var outline_c: Color = Color.TRANSPARENT
	var shadow_size: int = 0
	var shadow_off: Vector2 = Vector2.ZERO
	var shadow_col: Color = Color.TRANSPARENT
	
	match card_variant:
		Variant.ELEVATED:
			bg = M3Theme.get_surface_container_low()
			shadow_size = M3Theme.ELEVATION_1["size"]
			shadow_off = M3Theme.ELEVATION_1["offset"]
			shadow_col = M3Theme.ELEVATION_1["color"]
		Variant.FILLED:
			bg = M3Theme.get_elevation_surface(5)
		Variant.OUTLINED:
			bg = M3Theme.get_surface()
			outline_w = M3Units.dp(1)
			outline_c = M3Theme.get_outline()
	
	if disabled:
		bg = M3Theme.disabled_color(bg)
	elif _is_pressing:
		bg = M3Theme.state_overlay(bg, M3Theme.get_on_surface(), M3Theme.OPACITY_PRESSED)
	elif _hovered:
		bg = M3Theme.state_overlay(bg, M3Theme.get_on_surface(), M3Theme.OPACITY_HOVER)
	
	_cached_stylebox.bg_color = bg
	_cached_stylebox.set_border_width_all(outline_w)
	_cached_stylebox.border_color = outline_c
	_cached_stylebox.shadow_size = shadow_size
	_cached_stylebox.shadow_offset = shadow_off
	_cached_stylebox.shadow_color = shadow_col

# ============================================
# UPDATES
# ============================================

func _update_media():
	if _media_content and is_instance_valid(_media_content):
		if _media_panel:
			_media_panel.visible = true
		return
	if not _media_rect:
		return
	_media_rect.texture = media_texture
	_media_rect.visible = media_texture != null
	if _media_panel:
		_media_panel.visible = media_texture != null

static func _pick_headline_spec(height_dp: float) -> Dictionary:
	for spec in _HEADLINE_SCALE:
		if height_dp >= spec.threshold_dp:
			return spec
	return _HEADLINE_SCALE[-1]

static func _pick_supporting_spec(height_dp: float) -> Dictionary:
	for spec in _SUPPORTING_SCALE:
		if height_dp >= spec.threshold_dp:
			return spec
	return _SUPPORTING_SCALE[-1]

static func get_min_text_height_dp(card_height_dp: float) -> float:
	"""Return the minimum height the text area needs for this card height in dp.
	
	Matches the padding, margins, and font thresholds used in _rebuild_layout
	and _update_text."""
	const PAD := 16.0
	const HALF_PAD := 8.0
	const LABEL_GAP := 4.0
	
	var headline_spec = _pick_headline_spec(card_height_dp)
	var headline_h = headline_spec.size
	
	# Supporting text is hidden when card is shorter than 100 dp
	if card_height_dp < 100.0:
		return HALF_PAD + headline_h + PAD
	
	var supporting_spec = _pick_supporting_spec(card_height_dp)
	var supporting_h = supporting_spec.size
	return HALF_PAD + headline_h + LABEL_GAP + supporting_h + PAD

func _get_horizontal_alignment() -> HorizontalAlignment:
	match content_alignment:
		ContentAlignment.START:
			return HORIZONTAL_ALIGNMENT_LEFT
		ContentAlignment.CENTER:
			return HORIZONTAL_ALIGNMENT_CENTER
		ContentAlignment.END:
			return HORIZONTAL_ALIGNMENT_RIGHT
	return HORIZONTAL_ALIGNMENT_LEFT

func _update_text():
	if not _headline_label or not _supporting_label:
		return
	
	var height_dp = size.y / M3Units.get_scale()
	if _cached_fonts.is_empty():
		_cached_fonts = M3Theme.load_fonts()
	var fonts = _cached_fonts
	var headline_spec = _pick_headline_spec(height_dp)
	var supporting_spec = _pick_supporting_spec(height_dp)
	
	_headline_label.text = headline
	_headline_label.visible = not headline.is_empty()
	if headline_spec.size != _applied_headline_size_dp:
		_applied_headline_size_dp = headline_spec.size
		_headline_label.add_theme_font_override("font", fonts[headline_spec.weight])
		_headline_label.add_theme_font_size_override("font_size", M3Units.dp(headline_spec.size))
	var font_color = M3Theme.get_on_surface()
	if font_color != _applied_font_color:
		_applied_font_color = font_color
		_headline_label.add_theme_color_override("font_color", font_color)
	
	# Apply content alignment to labels
	var h_align = _get_horizontal_alignment()
	if _headline_label.horizontal_alignment != h_align:
		_headline_label.horizontal_alignment = h_align
	
	_supporting_label.text = supporting_text
	_supporting_label.visible = not supporting_text.is_empty() and size.y >= M3Units.dp(100.0)
	if supporting_spec.size != _applied_supporting_size_dp:
		_applied_supporting_size_dp = supporting_spec.size
		_supporting_label.add_theme_font_override("font", fonts[supporting_spec.weight])
		_supporting_label.add_theme_font_size_override("font_size", M3Units.dp(supporting_spec.size))
	var supporting_color = M3Theme.get_on_surface_variant()
	if supporting_color != _applied_supporting_color:
		_applied_supporting_color = supporting_color
		_supporting_label.add_theme_color_override("font_color", supporting_color)
	
	if _supporting_label.horizontal_alignment != h_align:
		_supporting_label.horizontal_alignment = h_align
	
	# Text shadow in transparent mode for readability (headline only)
	var needs_shadow = not show_background
	if needs_shadow and not _applied_text_shadow_enabled:
		_applied_text_shadow_enabled = true
		var shadow_color = Color(0.0, 0.0, 0.0, 0.10)
		var shadow_offset_x = M3Units.dp(1.5)
		var shadow_offset_y = M3Units.dp(2.5)
		var shadow_outline = M3Units.dp(5.0)
		# Apply shadow to headline only, remove from supporting text
		_headline_label.add_theme_color_override("font_shadow_color", shadow_color)
		_headline_label.add_theme_constant_override("shadow_offset_x", shadow_offset_x)
		_headline_label.add_theme_constant_override("shadow_offset_y", shadow_offset_y)
		_headline_label.add_theme_constant_override("shadow_outline_size", shadow_outline)
		_supporting_label.remove_theme_color_override("font_shadow_color")
		_supporting_label.remove_theme_constant_override("shadow_offset_x")
		_supporting_label.remove_theme_constant_override("shadow_offset_y")
		_supporting_label.remove_theme_constant_override("shadow_outline_size")
	elif not needs_shadow and _applied_text_shadow_enabled:
		_applied_text_shadow_enabled = false
		for label in [_headline_label, _supporting_label]:
			label.remove_theme_color_override("font_shadow_color")
			label.remove_theme_constant_override("shadow_offset_x")
			label.remove_theme_constant_override("shadow_offset_y")
			label.remove_theme_constant_override("shadow_outline_size")

func _update_appearance():
	if not _text_margin:
		return
	
	var pad = M3Units.dp(PADDING)
	var half_pad = M3Units.dp(PADDING / 2.0)
	
	# Padding inside the text area
	var margin_left = int(pad)
	var margin_right = int(pad)
	var margin_top = int(half_pad)
	var margin_bottom = int(pad)
	if margin_left != _applied_margin_left:
		_applied_margin_left = margin_left
		_text_margin.add_theme_constant_override("margin_left", margin_left)
	if margin_right != _applied_margin_right:
		_applied_margin_right = margin_right
		_text_margin.add_theme_constant_override("margin_right", margin_right)
	if margin_top != _applied_margin_top:
		_applied_margin_top = margin_top
		_text_margin.add_theme_constant_override("margin_top", margin_top)
	if margin_bottom != _applied_margin_bottom:
		_applied_margin_bottom = margin_bottom
		_text_margin.add_theme_constant_override("margin_bottom", margin_bottom)
	
	# Set minimum card height based on layout mode (only if caller hasn't set one)
	var default_min_height = MIN_HEIGHT_VERTICAL_DP if card_layout_mode == LayoutMode.VERTICAL else MIN_HEIGHT_HORIZONTAL_DP
	if custom_minimum_size.y <= 0:
		custom_minimum_size.y = M3Units.dp(default_min_height)
	
	queue_redraw()

func _rebuild_actions():
	if not _actions_hbox:
		return
	for child in _actions_hbox.get_children():
		child.queue_free()
	
	for label_text in _action_labels:
		var btn = M3Button.new()
		btn.text = label_text
		btn.button_variant = M3Button.Variant.TEXT
		btn.button_size = M3Button.Size.SMALL
		btn.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.focus_mode = Control.FOCUS_NONE
		_actions_hbox.add_child(btn)
	
	_actions_hbox.visible = not _action_labels.is_empty()

# ============================================
# PUBLIC API
# ============================================

func add_action(label: String):
	_action_labels.append(label)
	if _ready_called:
		_rebuild_actions()

func clear_actions():
	_action_labels.clear()
	if _ready_called:
		_rebuild_actions()

func set_media_content(content: Control):
	# Remove existing custom content
	if _media_content and is_instance_valid(_media_content) and _media_content.get_parent() == _media_panel:
		_media_panel.remove_child(_media_content)

	_media_content = content

	# Remove default media rect if it exists
	if _media_rect and is_instance_valid(_media_rect) and _media_rect.get_parent() == _media_panel:
		_media_rect.queue_free()
		_media_rect = null

	if _media_content:
		_media_content.set_anchors_preset(Control.PRESET_FULL_RECT)
		_media_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if _media_panel:
			_media_panel.add_child(_media_content)
			_media_panel.visible = true
		# If it's the node-less EffectStack, pass our media container
		if _media_content.has_method("set_parent_rid") and _media_container:
			var stack = _media_content
			stack.media_container = _media_container
	else:
		# Restore default media rect
		if _media_panel and not _media_rect:
			_media_rect = TextureRect.new()
			_media_rect.name = "MediaRect"
			_media_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			_media_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
			_media_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_media_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
			_media_rect.visible = false
			_media_panel.add_child(_media_rect)
			_update_media()

func refresh_theme():
	_cached_fonts = M3Theme.load_fonts()
	_update_text()
	# Update focus ring color to match new primary accent
	if _focus_ring:
		var focus_sb = _focus_ring.get_theme_stylebox("panel") as StyleBoxFlat
		if focus_sb:
			focus_sb.border_color = M3Theme.get_primary()
	queue_redraw()

# ============================================
# INPUT / STATE
# ============================================

var _hovered: bool = false
var _is_pressing: bool = false

func _notification(what: int):
	match what:
		NOTIFICATION_RESIZED:
			# The FlowContainer (or any parent) has set our final size.
			# Recompute media panel and text now that size is authoritative.
			# This is essential because _rebuild_layout() runs before the
			# parent has laid us out, so _update_media_panel_size() sees
			# stale dimensions at that moment.
			if not is_node_ready() or size.x <= 0 or size.y <= 0:
				return
			_update_focus_ring_radius()
			queue_redraw()
			_update_media_panel_size(true)  # Force update with actual size
			_update_text()
			_apply_content_scale()
		NOTIFICATION_MOUSE_ENTER:
			if clickable:
				_hovered = true
				queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			if clickable:
				_hovered = false
				_is_pressing = false
				queue_redraw()
func _gui_input(event: InputEvent):
	if not clickable:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_pressing = event.pressed
			queue_redraw()
			# Inside a SubViewport, Button ignores clicks because is_hovered() is false.
			# Manually trigger press/release signals.
			var vp = get_viewport()
			if vp is SubViewport:
				accept_event()
				if event.pressed:
					grab_focus()
					button_down.emit()
				else:
					button_up.emit()
					pressed.emit()

func _update_media_panel_size(force: bool = false) -> void:
	if not _media_panel or not _text_margin:
		return
	
	# Use custom_minimum_size (set authoritatively by the grid) instead of size.
	# During mode switches, size still carries the old dimensions until FlowContainer
	# finishes its layout pass, which leads to media being sized for the wrong card.
	var card_w := custom_minimum_size.x
	var card_h := custom_minimum_size.y
	if card_w <= 0.0:
		card_w = size.x
	if card_h <= 0.0:
		card_h = size.y
	
	# Safety clamp: card must have reasonable dimensions
	card_w = maxf(card_w, M3Units.dp(40.0))
	card_h = maxf(card_h, M3Units.dp(40.0))
	
	var media_w: float
	var media_h: float
	var text_w: float
	var text_h: float
	var media_x: float
	var media_y: float
	var text_x: float
	var text_y: float
	
	if card_layout_mode == LayoutMode.VERTICAL:
		# VERTICAL: media on top, text below (or vice versa for END)
		text_w = card_w
		media_w = card_w
		
		if media_aspect_ratio > 0.0:
			var desired_h = card_w / media_aspect_ratio
			var max_h = card_h
			if show_text_margin:
				var min_text_h = M3Units.dp(get_min_text_height_dp(card_h / M3Units.get_scale()))
				max_h = card_h - min_text_h
			media_h = clampf(desired_h, M3Units.dp(40.0), maxf(M3Units.dp(40.0), max_h))
			# Maintain aspect ratio
			if desired_h > max_h and max_h > 0:
				media_w = max_h * media_aspect_ratio
		else:
			var min_text_h := 0.0
			if show_text_margin:
				min_text_h = M3Units.dp(get_min_text_height_dp(card_h / M3Units.get_scale()))
			media_h = maxf(M3Units.dp(40.0), card_h - min_text_h)
			if not show_text_margin:
				media_h = card_h
		
		media_h = minf(media_h, card_h)
		text_h = card_h - media_h
		
		# Position based on alignment
		if content_alignment == ContentAlignment.END:
			# Text at top, media at bottom
			text_y = 0
			media_y = text_h
		elif content_alignment == ContentAlignment.CENTER:
			if show_text_margin:
				# Fixed text height = minimum needed (including margins)
				text_h = M3Units.dp(get_min_text_height_dp(card_h / M3Units.get_scale()))
				var total_h = media_h + text_h
				var start_y = (card_h - total_h) / 2.0
				media_y = start_y
				text_y = start_y + media_h
			else:
				# Media Only: center media alone
				text_h = 0
				media_y = (card_h - media_h) / 2.0
				text_y = 0
		else:
			# Media at top, text at bottom (START)
			media_y = 0
			text_y = media_h
		
		media_x = (card_w - media_w) / 2.0  # Center horizontally
		text_x = 0
		
	elif card_layout_mode == LayoutMode.HORIZONTAL:
		# HORIZONTAL: media on one side, text on the other
		media_h = card_h
		text_h = card_h
		
		if media_aspect_ratio > 0.0:
			var desired_w = card_h * media_aspect_ratio
			var max_w = card_w
			if show_text_margin:
				max_w = card_w - M3Units.dp(80.0)
			media_w = clampf(desired_w, M3Units.dp(40.0), maxf(M3Units.dp(40.0), max_w))
			# Maintain aspect ratio
			if desired_w > max_w and max_w > 0:
				media_h = max_w / media_aspect_ratio
		else:
			media_w = M3Units.dp(MEDIA_WIDTH_LIST)
			if show_text_margin:
				media_w = minf(media_w, card_w - M3Units.dp(80.0))
			media_w = maxf(media_w, M3Units.dp(40.0))
			if not show_text_margin:
				media_w = card_w
		
		media_w = minf(media_w, card_w)
		media_h = minf(media_h, card_h)
		
		# Position based on alignment
		if content_alignment == ContentAlignment.END:
			# Text at left, media at right
			text_w = card_w - media_w
			text_x = 0
			media_x = text_w
		elif content_alignment == ContentAlignment.CENTER:
			if show_text_margin:
				# Fixed text content width (160dp), plus margin container padding
				var text_content_w = M3Units.dp(160.0)
				var margin_pad = M3Units.dp(PADDING)
				text_w = text_content_w + margin_pad * 2.0
				var total_w = media_w + text_w
				var start_x = (card_w - total_w) / 2.0
				media_x = start_x
				text_x = start_x + media_w
			else:
				# Media Only: center media alone
				text_w = 0
				media_x = (card_w - media_w) / 2.0
				text_x = 0
		else:
			# Media at left, text at right (START)
			text_w = card_w - media_w
			media_x = 0
			text_x = media_w
		
		media_y = (card_h - media_h) / 2.0  # Center vertically
		text_y = 0
	
	# Apply computed sizes and positions directly.
	# Using a plain Control root means we have full control — no container sorting races.
	if force or not is_equal_approx(media_w, _last_media_min_x) or not is_equal_approx(media_h, _last_media_min_y) or not is_equal_approx(media_x, _last_media_pos_x) or not is_equal_approx(media_y, _last_media_pos_y):
		_last_media_min_x = media_w
		_last_media_min_y = media_h
		_last_media_pos_x = media_x
		_last_media_pos_y = media_y
		_media_panel.position = Vector2(media_x, media_y)
		_media_panel.size = Vector2(media_w, media_h)
	
	_text_margin.position = Vector2(text_x, text_y)
	_text_margin.size = Vector2(text_w, text_h)
	
	_focus_target_w = media_w
	_focus_target_h = media_h
	
	# Update media container with authoritative bounds
	if _media_container:
		_media_container.bounds = Rect2(media_x, media_y, media_w, media_h)
		_media_container.corner_radius_ratio = card_rounding_ratio
		# Force an explicit refresh on all effects — the changed signal can be
		# missed when _is_tweening is stuck or when Godot defers layout.
		_refresh_media_effects()
	
	# Update text minimum sizes for consistent CENTER mode
	_update_text_content_sizes()
	
	_update_focus_ring_bounds()
	# Guard prevents accumulation during rapid resize/zoom drags.
	if not _focus_ring_bounds_queued:
		_focus_ring_bounds_queued = true
		call_deferred("_update_focus_ring_bounds")

func _refresh_media_effects() -> void:
	if not _media_content:
		return
	# If the media content is the node-less EffectStack, refresh directly.
	if _media_content.has_method("force_refresh"):
		var stack = _media_content
		stack.force_refresh()
		return
	# Legacy fallback for any remaining node-based effect stacks.
	var stack := []
	stack.append(_media_content)
	while stack.size() > 0:
		var node = stack.pop_back() as Node
		if node is EffectBase:
			var effect: EffectBase = node
			if effect.enabled:
				effect._update_shader_params()
		for child in node.get_children():
			stack.append(child)

func _update_text_content_sizes() -> void:
	if not _text_content or not _ready_called:
		return
	
	# Clear previous minimums first
	if _text_content.custom_minimum_size.x != 0:
		_text_content.custom_minimum_size.x = 0
	if _text_content.custom_minimum_size.y != 0:
		_text_content.custom_minimum_size.y = 0
	
	if card_layout_mode == LayoutMode.HORIZONTAL:
		# Horizontal mode: text needs a minimum width to be readable
		if content_alignment != ContentAlignment.CENTER:
			# START/END: set minimum so text is readable
			var min_text_w = M3Units.dp(80.0)
			if not is_equal_approx(_text_content.custom_minimum_size.x, min_text_w):
				_text_content.custom_minimum_size.x = min_text_w
		# CENTER: text width is fixed by _text_margin.size, let labels fill and truncate
	else:
		# Vertical mode: text needs a minimum height for fonts
		var min_text_h = M3Units.dp(get_min_text_height_dp(size.y / M3Units.get_scale()))
		if not is_equal_approx(_text_content.custom_minimum_size.y, min_text_h):
			_text_content.custom_minimum_size.y = min_text_h

func _on_focus_changed():
	if _focus_ring:
		_focus_ring.visible = has_focus() and not disabled
	queue_redraw()
