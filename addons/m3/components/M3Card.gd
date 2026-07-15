@tool
class_name M3Card
extends Button

const EffectStack = preload("res://components/effects/effect_stack.gd")
const EffectBase = preload("res://components/effects/effect_base.gd")
const RoundedMediaShader = preload("res://addons/m3/shaders/card/rounded_media.gdshader")

enum Variant { ELEVATED, FILLED, OUTLINED }
enum LayoutMode { VERTICAL, HORIZONTAL }
enum ContentAlignment { START, CENTER, END }

const PADDING := 16.0
const MEDIA_WIDTH_LIST := 256.0
const _HEADLINE_SCALE := [
	{ "threshold_dp": 280.0, "size": 22.0, "weight": "medium" },
	{ "threshold_dp": 200.0, "size": 16.0, "weight": "medium" },
	{ "threshold_dp": 140.0, "size": 14.0, "weight": "medium" },
	{ "threshold_dp":   0.0, "size": 12.0, "weight": "medium" },
]
const _SUPPORTING_SCALE := [
	{ "threshold_dp": 200.0, "size": 14.0, "weight": "regular" },
	{ "threshold_dp": 140.0, "size": 12.0, "weight": "regular" },
	{ "threshold_dp":   0.0, "size": 11.0, "weight": "medium" },
]
const ACTIONS_GAP := 8.0
const LABEL_GAP := 4.0
const MIN_HEIGHT_VERTICAL_DP := 240.0
const MIN_HEIGHT_HORIZONTAL_DP := 80.0

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
		if not _ready_called:
			return
		if _bulk_layout_active:
			_bulk_layout_needs_rebuild = true
			_bulk_layout_needs_media = true
			_bulk_layout_needs_text = true
			_bulk_layout_needs_appearance = true
			_bulk_layout_needs_actions = true
			return
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
		if not _ready_called:
			return
		if _bulk_layout_active:
			_bulk_layout_needs_rebuild = true
			_bulk_layout_needs_media = true
			_bulk_layout_needs_text = true
			_bulk_layout_needs_appearance = true
			_bulk_layout_needs_actions = true
			return
		_rebuild_layout()
		_update_media()
		_update_text()
		_update_appearance()
		_rebuild_actions()

var media_aspect_ratio: float = -1.0:
	set(value):
		if is_equal_approx(media_aspect_ratio, value):
			return
		if value != -1.0 and value <= 0.0:
			push_warning("M3Card: media_aspect_ratio must be > 0 or -1.0 (fill). Got %f, ignoring." % value)
			return
		media_aspect_ratio = value
		if not _ready_called:
			return
		if _bulk_layout_active:
			_bulk_layout_needs_rebuild = true
			_bulk_layout_needs_text = true
			_bulk_layout_needs_appearance = true
			return
		_rebuild_layout()
		_update_text()
		_update_appearance()
		queue_redraw()

func set_media_aspect_ratio(ratio: float) -> void:
	media_aspect_ratio = ratio

func set_content_alignment(alignment: ContentAlignment) -> void:
	content_alignment = alignment

func begin_bulk_layout() -> void:
	_bulk_layout_active = true
	_bulk_layout_needs_rebuild = false
	_bulk_layout_needs_media = false
	_bulk_layout_needs_text = false
	_bulk_layout_needs_appearance = false
	_bulk_layout_needs_actions = false

func end_bulk_layout() -> void:
	if not _bulk_layout_active:
		return
	_bulk_layout_active = false

	if _bulk_layout_needs_rebuild:
		_rebuild_layout()
	else:
		if _bulk_layout_needs_actions:
			_rebuild_actions()
		if _bulk_layout_needs_media:
			_update_media()
		if _bulk_layout_needs_text:
			_update_text()

	if _bulk_layout_needs_appearance:
		_update_appearance()

	_bulk_layout_needs_rebuild = false
	_bulk_layout_needs_media = false
	_bulk_layout_needs_text = false
	_bulk_layout_needs_appearance = false
	_bulk_layout_needs_actions = false

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
			_update_media_panel_size(true)
			queue_redraw()

var card_rounding_ratio: float = 0.12:
	set(value):
		var clamped = clampf(value, 0.0, 1.0)
		if is_equal_approx(clamped, card_rounding_ratio):
			return
		card_rounding_ratio = clamped
		if _ready_called:
			queue_redraw()
			_update_focus_ring_bounds()

var content_scale: Vector2 = Vector2.ONE:
	set(value):
		if content_scale.is_equal_approx(value):
			return
		content_scale = value
		_apply_content_scale()

var _text_content: VBoxContainer
var _text_row: HBoxContainer
var _headline_label: Label = null
var _supporting_label: Label = null
var _actions_hbox: HBoxContainer
var _media_content: Control = null

var _headline_text_line: TextLine = null
var _supporting_text_line: TextLine = null

var _media_container: MediaContainer

var _cached_stylebox: StyleBoxFlat
var _cached_fonts: Dictionary = {}
var _action_labels: Array[String] = []

var _focus_ring_bounds_queued: bool = false
var _ready_called: bool = false

var _bulk_layout_active: bool = false
var _bulk_layout_needs_rebuild: bool = false
var _bulk_layout_needs_media: bool = false
var _bulk_layout_needs_text: bool = false
var _bulk_layout_needs_appearance: bool = false
var _bulk_layout_needs_actions: bool = false

var _focus_target_w: float = 0.0
var _focus_target_h: float = 0.0

var _media_bounds: Rect2 = Rect2()
var _text_bounds: Rect2 = Rect2()

var _media_canvas_item: RID = RID()
var _focus_ring_canvas_item: RID = RID()
var _focus_ring_style: StyleBoxFlat
var _rounded_media_material: ShaderMaterial
var _text_canvas_item: RID = RID()

var _visual_layer: Control = null
var _visual_layer_rid: RID = RID()
var _base_visual_draw_index: int = 0
var _visual_bg_canvas_item: RID = RID()
var _visuals_position_synced: bool = false

var _applied_headline_size_dp: float = -1.0
var _applied_supporting_size_dp: float = -1.0
var _applied_font_color: Color = Color(-1, -1, -1)
var _applied_supporting_color: Color = Color(-1, -1, -1)
var _applied_text_shadow_enabled: bool = false
var _applied_headline_text: String = ""
var _applied_supporting_text: String = ""
var _applied_h_align: int = -1
var _applied_text_bounds: Rect2 = Rect2()
var _applied_show_background: bool = true
var _applied_fonts: Dictionary = {}

var _last_media_min_x: float = -1.0
var _last_media_min_y: float = -1.0
var _last_media_pos_x: float = -1.0
var _last_media_pos_y: float = -1.0

func _update_focus_ring_bounds() -> void:
	_focus_ring_bounds_queued = false
	if not _focus_ring_canvas_item.is_valid():
		return
	# Skip expensive draw command rebuilds while the ring is hidden and the card
	# is not focused. It will be rebuilt on the next focus change anyway.
	if not has_focus() and not _focus_ring_canvas_item.is_valid():
		return
	if not has_focus():
		# If the ring is currently hidden, we can bail unless its geometry was
		# never built yet (target size is zero means it hasn't been initialized).
		if _focus_target_w > 0.0 and _focus_target_h > 0.0:
			return
	var target_w := _focus_target_w
	var target_h := _focus_target_h
	if target_w <= 0.0:
		target_w = size.x
	if target_h <= 0.0:
		target_h = size.y
	var ring_rect: Rect2
	if not show_background:
		var media_w := _media_bounds.size.x if _media_bounds.size.x > 0.0 else target_w
		var media_h := _media_bounds.size.y if _media_bounds.size.y > 0.0 else target_h
		ring_rect = Rect2(_media_bounds.position, Vector2(media_w, media_h))
	else:
		ring_rect = Rect2(Vector2.ZERO, size)
	_update_focus_ring_radius(target_w, target_h)
	RenderingServer.canvas_item_clear(_focus_ring_canvas_item)
	_focus_ring_style.draw(_focus_ring_canvas_item, ring_rect)

func _update_focus_ring_radius(target_w: float, target_h: float) -> void:
	var max_radius: float = min(target_w, target_h) / 2.0
	var radius: float = card_rounding_ratio * max_radius
	_focus_ring_style.set_corner_radius_all(int(round(radius)))

func set_visual_layer(layer: Control) -> void:
	"""Move this card's visual RS items to an unclipped visual layer.

	The card Control remains inside the clipped scroll container for input; only
	the rendering canvas items are reparented so they can draw outside the
	scroll viewport. When no layer is set, the card falls back to normal Control
	rendering for its background and text.
	"""
	if _visual_layer == layer:
		return
	_visual_layer = layer
	_visual_layer_rid = layer.get_canvas_item() if layer else RID()
	set_notify_transform(layer != null)
	set_process(false)
	_visuals_position_synced = false
	
	# If we are promoting this card to a visual layer, make sure the visual-only
	# RS items exist. Cards created for pools without a layer don't allocate them.
	if _uses_visual_layer() and (not _visual_bg_canvas_item.is_valid() or not _text_canvas_item.is_valid()):
		_create_visual_layer_rs_items()
	
	_reparent_visual_items()
	if _visual_layer and _visual_layer.is_inside_tree() and is_inside_tree():
		sync_visual_transform()
		call_deferred("_mark_visuals_position_synced")
	_update_media_panel_size(true)
	queue_redraw()

func _reparent_visual_items() -> void:
	var parent_rid := _visual_layer_rid if _visual_layer_rid.is_valid() else get_canvas_item()
	if _visual_bg_canvas_item.is_valid():
		RenderingServer.canvas_item_set_parent(_visual_bg_canvas_item, parent_rid)
	if _media_canvas_item.is_valid():
		RenderingServer.canvas_item_set_parent(_media_canvas_item, parent_rid)
	if _text_canvas_item.is_valid():
		RenderingServer.canvas_item_set_parent(_text_canvas_item, parent_rid)
	if _focus_ring_canvas_item.is_valid():
		RenderingServer.canvas_item_set_parent(_focus_ring_canvas_item, parent_rid)

func sync_visual_transform() -> void:
	"""Sync visual RS item positions to the card's global transform and focus scale.

	Called when the card moves, scrolls, or its focus scale changes. The card
	Control itself stays clipped; only the visual canvas items are moved.
	"""
	if not _visual_layer or not _visual_layer.is_inside_tree() or not is_inside_tree():
		return

	var layer_global := _visual_layer.global_position
	var card_global := global_position
	var base_offset := card_global - layer_global

	var base_transform := Transform2D().translated(base_offset)
	if not content_scale.is_equal_approx(Vector2.ONE):
		var pivot := size * 0.5
		base_transform = base_transform * Transform2D().translated(pivot) * Transform2D().scaled(content_scale) * Transform2D().translated(-pivot)

	if _visual_bg_canvas_item.is_valid():
		RenderingServer.canvas_item_set_transform(_visual_bg_canvas_item, base_transform)

	if _media_canvas_item.is_valid():
		var media_transform := base_transform * Transform2D().translated(_media_bounds.position)
		RenderingServer.canvas_item_set_transform(_media_canvas_item, media_transform)

	if _text_canvas_item.is_valid():
		RenderingServer.canvas_item_set_transform(_text_canvas_item, base_transform)

	if _focus_ring_canvas_item.is_valid():
		# The focus ring stylebox is drawn at ring_rect in local space, so its
		# canvas item only needs the base card transform (position + scale).
		RenderingServer.canvas_item_set_transform(_focus_ring_canvas_item, base_transform)

func _mark_visuals_position_synced() -> void:
	if _visuals_position_synced:
		return
	_visuals_position_synced = true
	_update_visual_items_visibility()

func set_visual_draw_index(base_index: int) -> void:
	_base_visual_draw_index = base_index
	_apply_visual_draw_index()

func _apply_visual_draw_index() -> void:
	var boost := 1000000 if has_focus() else 0
	var idx := _base_visual_draw_index + boost
	if _visual_bg_canvas_item.is_valid():
		RenderingServer.canvas_item_set_draw_index(_visual_bg_canvas_item, idx)
	if _media_canvas_item.is_valid():
		RenderingServer.canvas_item_set_draw_index(_media_canvas_item, idx + 1)
	if _text_canvas_item.is_valid():
		RenderingServer.canvas_item_set_draw_index(_text_canvas_item, idx + 2)
	if _focus_ring_canvas_item.is_valid():
		RenderingServer.canvas_item_set_draw_index(_focus_ring_canvas_item, idx + 3)

func _apply_content_scale() -> void:
	sync_visual_transform()


func _ready():
	flat = true
	text = ""
	set_clip_children_mode(CanvasItem.ClipChildrenMode.CLIP_CHILDREN_AND_DRAW)
	
	_media_container = MediaContainer.new()
	
	_cached_fonts = M3Theme.load_fonts()
	_initialize_styleboxes()
	_setup_rs_items()
	_rebuild_layout()
	_update_media()
	_update_text()
	_update_appearance()
	
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	
	focus_entered.connect(_on_focus_changed)
	focus_exited.connect(_on_focus_changed)
	button_down.connect(queue_redraw)
	button_up.connect(queue_redraw)
	
	_apply_clickable_state()
	_ready_called = true

func _exit_tree():
	# Keep the flattened RS items allocated while the card is pooled. They are
	# freed in NOTIFICATION_PREDELETE when the card is truly destroyed.
	pass

func _free_rs_items() -> void:
	if _visual_bg_canvas_item.is_valid():
		RenderingServer.free_rid(_visual_bg_canvas_item)
		_visual_bg_canvas_item = RID()
	if _media_canvas_item.is_valid():
		RenderingServer.free_rid(_media_canvas_item)
		_media_canvas_item = RID()
	if _text_canvas_item.is_valid():
		RenderingServer.free_rid(_text_canvas_item)
		_text_canvas_item = RID()
	if _focus_ring_canvas_item.is_valid():
		RenderingServer.free_rid(_focus_ring_canvas_item)
		_focus_ring_canvas_item = RID()
	_headline_text_line = null
	_supporting_text_line = null

func _update_visual_items_visibility() -> void:
	var base_visible := visible and is_inside_tree()
	var has_text := not headline.is_empty() or (not supporting_text.is_empty() and size.y >= M3Units.dp(100.0))
	var using_layer := _uses_visual_layer()
	
	# Background and text are only drawn through RS when a visual layer is active.
	if _visual_bg_canvas_item.is_valid():
		var bg_visible := base_visible and show_background and using_layer
		if using_layer:
			bg_visible = bg_visible and _visuals_position_synced
		RenderingServer.canvas_item_set_visible(_visual_bg_canvas_item, bg_visible)
	if _media_canvas_item.is_valid():
		var media_visible := base_visible and _has_media_content()
		if using_layer:
			media_visible = media_visible and _visuals_position_synced
		RenderingServer.canvas_item_set_visible(_media_canvas_item, media_visible)
	if _text_canvas_item.is_valid():
		var text_visible := base_visible and has_text and show_text_margin and using_layer
		if using_layer:
			text_visible = text_visible and _visuals_position_synced
		RenderingServer.canvas_item_set_visible(_text_canvas_item, text_visible)
	if _focus_ring_canvas_item.is_valid():
		var ring_visible := base_visible and has_focus() and not disabled
		if using_layer:
			ring_visible = ring_visible and _visuals_position_synced
		RenderingServer.canvas_item_set_visible(_focus_ring_canvas_item, ring_visible)

func _create_visual_layer_rs_items(parent_rid: RID = RID()) -> void:
	"""Create the RS items used only when a visual layer is active."""
	var target_parent := parent_rid if parent_rid.is_valid() else _visual_layer_rid if _visual_layer_rid.is_valid() else get_canvas_item()
	if not _visual_bg_canvas_item.is_valid():
		_visual_bg_canvas_item = RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(_visual_bg_canvas_item, target_parent)
		RenderingServer.canvas_item_set_draw_index(_visual_bg_canvas_item, 0)
		RenderingServer.canvas_item_set_visible(_visual_bg_canvas_item, true)
	if not _text_canvas_item.is_valid():
		_text_canvas_item = RenderingServer.canvas_item_create()
		RenderingServer.canvas_item_set_parent(_text_canvas_item, target_parent)
		RenderingServer.canvas_item_set_draw_index(_text_canvas_item, 2)
		RenderingServer.canvas_item_set_visible(_text_canvas_item, true)


func _setup_rs_items() -> void:
	_free_rs_items()
	var parent_rid := _visual_layer_rid if _visual_layer_rid.is_valid() else get_canvas_item()
	
	# Media and focus ring are always needed.
	_media_canvas_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_media_canvas_item, parent_rid)
	RenderingServer.canvas_item_set_draw_index(_media_canvas_item, 1)
	RenderingServer.canvas_item_set_visible(_media_canvas_item, true)
	
	_focus_ring_canvas_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_focus_ring_canvas_item, parent_rid)
	RenderingServer.canvas_item_set_draw_index(_focus_ring_canvas_item, 3)
	RenderingServer.canvas_item_set_visible(_focus_ring_canvas_item, false)
	
	# Visual-layer background and text are only used when a visual layer is active.
	# This avoids creating RS items for cards that never use the overflow layer,
	# such as PlatformCard, which dramatically reduces per-card cost.
	if _uses_visual_layer():
		_create_visual_layer_rs_items(parent_rid)
	
	_visuals_position_synced = false
	_applied_text_bounds = Rect2()


func _enter_tree():
	if not _ready_called:
		return
	_visuals_position_synced = false
	var missing := false
	if not _media_canvas_item.is_valid() or not _focus_ring_canvas_item.is_valid():
		missing = true
	if _uses_visual_layer() and (not _visual_bg_canvas_item.is_valid() or not _text_canvas_item.is_valid()):
		missing = true
	if missing:
		_setup_rs_items()
		_update_media()
		_update_focus_ring_bounds()
	# Subclasses may need to rebuild node-less effect stacks after RS items are
	# recreated (e.g. when a pooled card re-enters the tree).
	_on_rs_items_recreated()
	# Recompute media bounds now that subclasses have had a chance to recreate
	# their node-less media content. Without this, _has_media_content() can
	# return false for flattened cards and bounds end up zeroed/blank.
	_update_media_panel_size(true)
	if not _uses_visual_layer():
		_visuals_position_synced = true
	_update_visual_items_visibility()

func _on_rs_items_recreated() -> void:
	pass

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
	
	_focus_ring_style = StyleBoxFlat.new()
	_focus_ring_style.bg_color = Color.TRANSPARENT
	_focus_ring_style.border_color = M3Theme.get_primary()
	_focus_ring_style.set_border_width_all(M3Units.dp(2))
	_focus_ring_style.anti_aliasing = true
	_focus_ring_style.anti_aliasing_size = 1.0
	
	_rounded_media_material = ShaderMaterial.new()
	_rounded_media_material.shader = RoundedMediaShader

func _rebuild_layout():
	_applied_headline_size_dp = -1.0
	_applied_supporting_size_dp = -1.0
	_applied_font_color = Color(-1, -1, -1)
	_applied_supporting_color = Color(-1, -1, -1)
	_applied_text_shadow_enabled = false
	_applied_headline_text = ""
	_applied_supporting_text = ""
	_applied_h_align = -1
	_applied_text_bounds = Rect2()
	_applied_show_background = true
	_applied_fonts = {}
	_last_media_min_x = -1.0
	_last_media_min_y = -1.0
	_last_media_pos_x = -1.0
	_last_media_pos_y = -1.0
	
	var preserved_media_content: Control = null
	if _media_content and is_instance_valid(_media_content) and _media_content.get_parent() == self:
		preserved_media_content = _media_content
		remove_child(_media_content)
	
	var preserved_headline: Label = null
	var preserved_supporting: Label = null
	if _headline_label and is_instance_valid(_headline_label) and _headline_label.get_parent():
		preserved_headline = _headline_label
		_headline_label.get_parent().remove_child(_headline_label)
	if _supporting_label and is_instance_valid(_supporting_label) and _supporting_label.get_parent():
		preserved_supporting = _supporting_label
		_supporting_label.get_parent().remove_child(_supporting_label)
	
	if _text_row and is_instance_valid(_text_row):
		if _text_row.get_parent() == self:
			remove_child(_text_row)
		_text_row.queue_free()
		_text_row = null
		_text_content = null
		_actions_hbox = null
	
	if _text_content and is_instance_valid(_text_content):
		if _text_content.get_parent() == self:
			remove_child(_text_content)
		_text_content.queue_free()
		_text_content = null
		_actions_hbox = null
	
	if preserved_media_content:
		add_child(preserved_media_content)
	
	if card_layout_mode == LayoutMode.HORIZONTAL:
		_text_row = HBoxContainer.new()
		_text_row.name = "TextRow"
		_text_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_text_row.visible = false
		add_child(_text_row)
		
		_text_content = VBoxContainer.new()
		_text_content.name = "TextContent"
		_text_content.add_theme_constant_override("separation", M3Units.dp(LABEL_GAP))
		_text_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_text_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_text_content.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_text_content.visible = false
		_text_row.add_child(_text_content)
		
		_actions_hbox = HBoxContainer.new()
		_actions_hbox.name = "Actions"
		_actions_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_actions_hbox.visible = false
		_actions_hbox.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_actions_hbox.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		_text_row.add_child(_actions_hbox)
	else:
		_text_content = VBoxContainer.new()
		_text_content.name = "TextContent"
		_text_content.add_theme_constant_override("separation", M3Units.dp(LABEL_GAP))
		_text_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_text_content.visible = false
		add_child(_text_content)
		
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
	
	_rebuild_actions()
	call_deferred("_update_media_panel_size", true)

func _draw():
	if not _cached_stylebox or not show_background:
		return
	var rect = Rect2(Vector2.ZERO, size)
	var max_radius = min(size.x, size.y) / 2.0
	var radius = int(round(card_rounding_ratio * max_radius))
	_configure_stylebox_for_state()
	_cached_stylebox.set_corner_radius_all(radius)
	if _uses_visual_layer():
		_redraw_visual_background(rect)
	else:
		draw_style_box(_cached_stylebox, rect)

func _redraw_visual_background(rect: Rect2) -> void:
	if not _visual_bg_canvas_item.is_valid():
		return
	RenderingServer.canvas_item_clear(_visual_bg_canvas_item)
	_cached_stylebox.draw(_visual_bg_canvas_item, rect)

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

func _has_media_content() -> bool:
	return _media_content != null or media_texture != null

func _update_media():
	var has_media := _has_media_content()
	var card_visible := visible and is_inside_tree()
	if _uses_visual_layer():
		card_visible = card_visible and _visuals_position_synced
	if _media_canvas_item.is_valid():
		RenderingServer.canvas_item_set_visible(_media_canvas_item, has_media and card_visible)
	if _media_content and is_instance_valid(_media_content):
		_media_content.visible = has_media
	if not has_media or _media_content != null or media_texture == null:
		if _media_canvas_item.is_valid():
			RenderingServer.canvas_item_clear(_media_canvas_item)
		queue_redraw()
		return
	_draw_default_media()
	queue_redraw()

func _draw_default_media():
	if not _media_canvas_item.is_valid() or not media_texture:
		return
	var media_size := _media_bounds.size
	if media_size.x <= 0.0 or media_size.y <= 0.0:
		return
	var rect := Rect2(Vector2.ZERO, media_size)
	var radius := int(round(card_rounding_ratio * min(media_size.x, media_size.y) / 2.0))
	var tex_size := Vector2(media_texture.get_width(), media_texture.get_height())
	var uv := _compute_cover_uv(media_size, tex_size)
	_rounded_media_material.set_shader_parameter("game_texture", media_texture)
	_rounded_media_material.set_shader_parameter("card_size", media_size)
	_rounded_media_material.set_shader_parameter("corner_radius_pixels", float(radius))
	_rounded_media_material.set_shader_parameter("uv_transform_scale", uv.scale)
	_rounded_media_material.set_shader_parameter("uv_transform_offset", uv.offset)
	_rounded_media_material.set_shader_parameter("alpha", 1.0)
	RenderingServer.canvas_item_set_material(_media_canvas_item, _rounded_media_material.get_rid())
	RenderingServer.canvas_item_clear(_media_canvas_item)
	RenderingServer.canvas_item_add_rect(_media_canvas_item, rect, Color.WHITE)

func _compute_cover_uv(target_size: Vector2, tex_size: Vector2) -> Dictionary:
	var scale := Vector2.ONE
	var offset := Vector2.ZERO
	if target_size.x <= 0.0 or target_size.y <= 0.0 or tex_size.x <= 0.0 or tex_size.y <= 0.0:
		return { "scale": scale, "offset": offset }
	var card_aspect := target_size.x / target_size.y
	var tex_aspect := tex_size.x / tex_size.y
	if card_aspect > tex_aspect:
		scale.y = tex_aspect / card_aspect
	else:
		scale.x = card_aspect / tex_aspect
	offset = (Vector2.ONE - scale) * 0.5
	return { "scale": scale, "offset": offset }

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
	const PAD := 16.0
	const HALF_PAD := 8.0
	const LABEL_GAP := 4.0
	var headline_spec = _pick_headline_spec(card_height_dp)
	var headline_h = headline_spec.size
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


func _uses_visual_layer() -> bool:
	return _visual_layer_rid.is_valid()

func _update_text() -> void:
	if not _uses_visual_layer():
		_update_text_labels()
		return
	if not _text_canvas_item.is_valid():
		return
	_update_visual_items_visibility()
	if _cached_fonts.is_empty():
		_cached_fonts = M3Theme.load_fonts()
	var fonts = _cached_fonts
	
	var height_dp := size.y / M3Units.get_scale()
	var headline_spec := _pick_headline_spec(height_dp)
	var supporting_spec := _pick_supporting_spec(height_dp)
	var font_color := M3Theme.get_on_surface()
	var supporting_color := M3Theme.get_on_surface_variant()
	var h_align: int = _get_horizontal_alignment()
	var needs_shadow := not show_background
	var has_headline := not headline.is_empty()
	var has_supporting := not supporting_text.is_empty() and size.y >= M3Units.dp(100.0)
	var text_rect := _text_bounds
	
	var text_changed: bool = (
		headline != _applied_headline_text
		or supporting_text != _applied_supporting_text
		or headline_spec.size != _applied_headline_size_dp
		or supporting_spec.size != _applied_supporting_size_dp
		or font_color != _applied_font_color
		or supporting_color != _applied_supporting_color
		or h_align != _applied_h_align
		or needs_shadow != _applied_text_shadow_enabled
		or show_background != _applied_show_background
		or not text_rect.is_equal_approx(_applied_text_bounds)
		or fonts != _applied_fonts
	)
	if not text_changed:
		return
	
	_applied_headline_text = headline
	_applied_supporting_text = supporting_text
	_applied_headline_size_dp = headline_spec.size
	_applied_supporting_size_dp = supporting_spec.size
	_applied_font_color = font_color
	_applied_supporting_color = supporting_color
	_applied_h_align = h_align
	_applied_text_shadow_enabled = needs_shadow
	_applied_show_background = show_background
	_applied_text_bounds = text_rect
	_applied_fonts = fonts
	
	RenderingServer.canvas_item_clear(_text_canvas_item)
	
	if not has_headline and not has_supporting:
		return
	if text_rect.size.x <= 0.0 or text_rect.size.y <= 0.0:
		return
	
	var pad := M3Units.dp(PADDING)
	var half_pad := M3Units.dp(PADDING / 2.0)
	var inner_x := text_rect.position.x + pad
	var inner_y := text_rect.position.y + half_pad
	var inner_w := text_rect.size.x - pad * 2.0
	var inner_h := text_rect.size.y - half_pad * 2.0
	if inner_w <= 0.0 or inner_h <= 0.0:
		return
	
	var label_gap := M3Units.dp(LABEL_GAP)
	var shadow_offset := Vector2(M3Units.dp(1.5), M3Units.dp(2.5))
	var shadow_color := Color(0.0, 0.0, 0.0, 0.5)
	var use_text_line := ClassDB.class_exists("TextLine")
	var headline_h := 0.0
	
	if has_headline:
		var headline_font: Font = fonts[headline_spec.weight]
		var headline_size := int(M3Units.dp(headline_spec.size))
		var headline_y := inner_y
		if use_text_line:
			if _headline_text_line == null:
				_headline_text_line = TextLine.new()
			else:
				_headline_text_line.clear()
			_headline_text_line.add_string(headline, headline_font, headline_size)
			_headline_text_line.set_width(inner_w)
			_headline_text_line.set_horizontal_alignment(h_align)
			_headline_text_line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			if needs_shadow:
				_headline_text_line.draw(_text_canvas_item, Vector2(inner_x, headline_y) + shadow_offset, shadow_color)
			_headline_text_line.draw(_text_canvas_item, Vector2(inner_x, headline_y), font_color)
			headline_h = _headline_text_line.get_size().y
		else:
			var baseline: float = headline_y + headline_font.get_ascent(headline_size)
			if needs_shadow:
				headline_font.draw_string(_text_canvas_item, Vector2(inner_x, baseline) + shadow_offset, headline, HORIZONTAL_ALIGNMENT_LEFT, -1, headline_size, shadow_color)
			headline_font.draw_string(_text_canvas_item, Vector2(inner_x, baseline), headline, h_align, inner_w, headline_size, font_color)
			headline_h = headline_font.get_height(headline_size)
	
	if has_supporting:
		var supporting_font: Font = fonts[supporting_spec.weight]
		var supporting_size := int(M3Units.dp(supporting_spec.size))
		var gap := label_gap if has_headline else 0.0
		var supporting_y := inner_y + headline_h + gap
		if supporting_y + supporting_size > inner_y + inner_h:
			return
		if use_text_line:
			if _supporting_text_line == null:
				_supporting_text_line = TextLine.new()
			else:
				_supporting_text_line.clear()
			_supporting_text_line.add_string(supporting_text, supporting_font, supporting_size)
			_supporting_text_line.set_width(inner_w)
			_supporting_text_line.set_horizontal_alignment(h_align)
			_supporting_text_line.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			_supporting_text_line.draw(_text_canvas_item, Vector2(inner_x, supporting_y), supporting_color)
		else:
			var baseline: float = supporting_y + supporting_font.get_ascent(supporting_size)
			supporting_font.draw_string(_text_canvas_item, Vector2(inner_x, baseline), supporting_text, h_align, inner_w, supporting_size, supporting_color)


func _update_text_labels() -> void:
	"""Update the built-in headline/supporting labels for cards without a visual layer."""
	if not _headline_label or not _supporting_label:
		return
	if _cached_fonts.is_empty():
		_cached_fonts = M3Theme.load_fonts()
	var fonts = _cached_fonts
	
	var height_dp := size.y / M3Units.get_scale()
	var headline_spec := _pick_headline_spec(height_dp)
	var supporting_spec := _pick_supporting_spec(height_dp)
	var font_color := M3Theme.get_on_surface()
	var supporting_color := M3Theme.get_on_surface_variant()
	var h_align := _get_horizontal_alignment()
	var needs_shadow := not show_background
	
	_headline_label.text = headline
	_headline_label.visible = not headline.is_empty()
	if _headline_label.visible:
		_headline_label.add_theme_font_override("font", fonts[headline_spec.weight])
		_headline_label.add_theme_font_size_override("font_size", M3Units.dp(headline_spec.size))
		_headline_label.add_theme_color_override("font_color", font_color)
		_headline_label.horizontal_alignment = h_align
		if needs_shadow:
			_headline_label.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.10))
			_headline_label.add_theme_constant_override("shadow_offset_x", M3Units.dp(1.5))
			_headline_label.add_theme_constant_override("shadow_offset_y", M3Units.dp(2.5))
			_headline_label.add_theme_constant_override("shadow_outline_size", M3Units.dp(5.0))
		else:
			_headline_label.remove_theme_color_override("font_shadow_color")
			_headline_label.remove_theme_constant_override("shadow_offset_x")
			_headline_label.remove_theme_constant_override("shadow_offset_y")
			_headline_label.remove_theme_constant_override("shadow_outline_size")
	
	_supporting_label.text = supporting_text
	_supporting_label.visible = not supporting_text.is_empty() and size.y >= M3Units.dp(100.0)
	if _supporting_label.visible:
		_supporting_label.add_theme_font_override("font", fonts[supporting_spec.weight])
		_supporting_label.add_theme_font_size_override("font_size", M3Units.dp(supporting_spec.size))
		_supporting_label.add_theme_color_override("font_color", supporting_color)
		_supporting_label.horizontal_alignment = h_align
		_supporting_label.remove_theme_color_override("font_shadow_color")
		_supporting_label.remove_theme_constant_override("shadow_offset_x")
		_supporting_label.remove_theme_constant_override("shadow_offset_y")
		_supporting_label.remove_theme_constant_override("shadow_outline_size")

func _update_appearance():
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

func add_action(label: String):
	_action_labels.append(label)
	if _ready_called:
		_rebuild_actions()

func clear_actions():
	_action_labels.clear()
	if _ready_called:
		_rebuild_actions()

func set_media_content(content: Control):
	if _media_content and is_instance_valid(_media_content) and _media_content.get_parent() == self:
		remove_child(_media_content)
		if _media_content != content:
			_media_content.queue_free()
	
	_media_content = content
	
	if _media_content:
		add_child(_media_content)
		_media_content.set_anchors_preset(Control.PRESET_TOP_LEFT)
		_media_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if _media_content.has_method("set_parent_rid") and _media_canvas_item.is_valid():
			_media_content.set_parent_rid(_media_canvas_item)
		if _media_content.has_method("set_media_container") and _media_container:
			_media_content.set_media_container(_media_container)
		elif _media_container:
			_media_content.set("media_container", _media_container)
		_update_media_panel_size(true)
	else:
		_update_media()

func refresh_theme():
	_cached_fonts = M3Theme.load_fonts()
	_update_text()
	if _focus_ring_style:
		_focus_ring_style.border_color = M3Theme.get_primary()
	queue_redraw()

var _hovered: bool = false
var _is_pressing: bool = false

func _notification(what: int):
	match what:
		NOTIFICATION_RESIZED:
			if not is_node_ready() or size.x <= 0 or size.y <= 0:
				return
			queue_redraw()
			_update_media_panel_size(true)
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
		NOTIFICATION_VISIBILITY_CHANGED:
			_update_visual_items_visibility()
		NOTIFICATION_PREDELETE:
			_free_rs_items()
		NOTIFICATION_TRANSFORM_CHANGED:
			if _visual_layer and _visual_layer.is_inside_tree() and is_inside_tree():
				sync_visual_transform()
				_mark_visuals_position_synced()

func _gui_input(event: InputEvent):
	if not clickable:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_pressing = event.pressed
			queue_redraw()
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
	if not _text_content:
		return
	
	var card_w := custom_minimum_size.x
	var card_h := custom_minimum_size.y
	if card_w <= 0.0:
		card_w = size.x
	if card_h <= 0.0:
		card_h = size.y
	
	card_w = maxf(card_w, M3Units.dp(40.0))
	card_h = maxf(card_h, M3Units.dp(40.0))
	
	var media_w: float = 0.0
	var media_h: float = 0.0
	var text_w: float = card_w
	var text_h: float = card_h
	var media_x: float = 0.0
	var media_y: float = 0.0
	var text_x: float = 0.0
	var text_y: float = 0.0
	
	if _has_media_content():
		if card_layout_mode == LayoutMode.VERTICAL:
			text_w = card_w
			media_w = card_w
			
			if media_aspect_ratio > 0.0:
				var desired_h = card_w / media_aspect_ratio
				var max_h = card_h
				if show_text_margin:
					var min_text_h = M3Units.dp(get_min_text_height_dp(card_h / M3Units.get_scale()))
					max_h = card_h - min_text_h
				media_h = clampf(desired_h, M3Units.dp(40.0), maxf(M3Units.dp(40.0), max_h))
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
			
			if content_alignment == ContentAlignment.END:
				text_y = 0
				media_y = text_h
			elif content_alignment == ContentAlignment.CENTER:
				if show_text_margin:
					text_h = M3Units.dp(get_min_text_height_dp(card_h / M3Units.get_scale()))
					var total_h = media_h + text_h
					var start_y = (card_h - total_h) / 2.0
					media_y = start_y
					text_y = start_y + media_h
				else:
					text_h = 0
					media_y = (card_h - media_h) / 2.0
					text_y = 0
			else:
				media_y = 0
				text_y = media_h
			
			media_x = (card_w - media_w) / 2.0
			text_x = 0
			
		elif card_layout_mode == LayoutMode.HORIZONTAL:
			media_h = card_h
			text_h = card_h
			
			if media_aspect_ratio > 0.0:
				var desired_w = card_h * media_aspect_ratio
				var max_w = card_w
				if show_text_margin:
					max_w = card_w - M3Units.dp(80.0)
				media_w = clampf(desired_w, M3Units.dp(40.0), maxf(M3Units.dp(40.0), max_w))
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
			
			if content_alignment == ContentAlignment.END:
				text_w = card_w - media_w
				text_x = 0
				media_x = text_w
			elif content_alignment == ContentAlignment.CENTER:
				if show_text_margin:
					var text_content_w = M3Units.dp(160.0)
					var margin_pad = M3Units.dp(PADDING)
					text_w = text_content_w + margin_pad * 2.0
					var total_w = media_w + text_w
					var start_x = (card_w - total_w) / 2.0
					media_x = start_x
					text_x = start_x + media_w
				else:
					text_w = 0
					media_x = (card_w - media_w) / 2.0
					text_x = 0
			else:
				text_w = card_w - media_w
				media_x = 0
				text_x = media_w
			
			media_y = (card_h - media_h) / 2.0
			text_y = 0
	
	_media_bounds = Rect2(media_x, media_y, media_w, media_h)
	_text_bounds = Rect2(text_x, text_y, text_w, text_h)
	
	if _media_canvas_item.is_valid():
		RenderingServer.canvas_item_set_transform(_media_canvas_item, Transform2D().translated(_media_bounds.position))
	
	var pad = M3Units.dp(PADDING)
	var half_pad = M3Units.dp(PADDING / 2.0)
	var text_visible := show_text_margin
	if _uses_visual_layer():
		text_visible = false
	if card_layout_mode == LayoutMode.HORIZONTAL:
		if _text_row:
			_text_row.position = Vector2(text_x + pad, text_y + half_pad)
			_text_row.size = Vector2(text_w - pad * 2.0, text_h - half_pad - pad)
			_text_row.visible = text_visible
		if _text_content:
			_text_content.visible = text_visible
	else:
		if _text_content:
			_text_content.position = Vector2(text_x + pad, text_y + half_pad)
			_text_content.size = Vector2(text_w - pad * 2.0, text_h - half_pad - pad)
			_text_content.visible = text_visible
	
	if _media_content and is_instance_valid(_media_content):
		_media_content.position = _media_bounds.position
		_media_content.size = _media_bounds.size
		if _media_content.has_method("set_parent_rid") and _media_canvas_item.is_valid():
			_media_content.set_parent_rid(_media_canvas_item)
	
	_focus_target_w = media_w
	_focus_target_h = media_h
	
	if _media_container:
		_media_container.bounds = Rect2(Vector2.ZERO, _media_bounds.size)
		_media_container.corner_radius_ratio = card_rounding_ratio
		_refresh_media_effects()
	
	_update_text_content_sizes()
	_update_media()
	sync_visual_transform()
	_update_focus_ring_bounds()
	_update_text()
	if not _focus_ring_bounds_queued:
		_focus_ring_bounds_queued = true
		call_deferred("_update_focus_ring_bounds")

func _refresh_media_effects() -> void:
	if not _media_content:
		return
	if _media_content.has_method("force_refresh"):
		var stack = _media_content
		stack.force_refresh()
		return
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
	if _text_content.custom_minimum_size.x != 0:
		_text_content.custom_minimum_size.x = 0
	if _text_content.custom_minimum_size.y != 0:
		_text_content.custom_minimum_size.y = 0
	
	if card_layout_mode == LayoutMode.HORIZONTAL:
		if content_alignment != ContentAlignment.CENTER:
			var min_text_w = M3Units.dp(80.0)
			if not is_equal_approx(_text_content.custom_minimum_size.x, min_text_w):
				_text_content.custom_minimum_size.x = min_text_w
	else:
		var min_text_h = M3Units.dp(get_min_text_height_dp(size.y / M3Units.get_scale()))
		if not is_equal_approx(_text_content.custom_minimum_size.y, min_text_h):
			_text_content.custom_minimum_size.y = min_text_h

func _on_focus_changed():
	if _focus_ring_canvas_item.is_valid():
		var should_show := has_focus() and not disabled
		if _uses_visual_layer():
			should_show = should_show and _visuals_position_synced
		RenderingServer.canvas_item_set_visible(_focus_ring_canvas_item, should_show)
		if should_show:
			_update_focus_ring_bounds()
	_apply_visual_draw_index()
	queue_redraw()

