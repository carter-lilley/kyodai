@tool
class_name M3Card
extends Button

## Material 3 Card Component
## Extends native Button so the whole card is focusable and clickable.
## Internal children use MOUSE_FILTER_IGNORE — only the card handles input.

enum Variant { ELEVATED, FILLED, OUTLINED }
enum LayoutMode { VERTICAL, HORIZONTAL }

# ============================================
# SIZE SPECS (all values in dp)
# ============================================

const CORNER_RADIUS := 12.0
const PADDING := 16.0

@export var corner_radius_dp: float = CORNER_RADIUS:
	set(value):
		if is_equal_approx(value, corner_radius_dp):
			return
		corner_radius_dp = value
		if _ready_called:
			queue_redraw()
			if _focus_ring:
				var focus_sb = _focus_ring.get_theme_stylebox("panel") as StyleBoxFlat
				if focus_sb:
					focus_sb.set_corner_radius_all(M3Units.dpi(corner_radius_dp))

const MEDIA_WIDTH_LIST := 256.0
const HEADLINE_FONT_SIZE := 22.0
const SUPPORTING_FONT_SIZE := 14.0
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

# ============================================
# INTERNAL
# ============================================

var _root_container: BoxContainer
var _media_panel: Panel
var _media_rect: TextureRect
var _text_margin: MarginContainer
var _text_content: VBoxContainer
var _headline_label: Label
var _supporting_label: Label
var _actions_hbox: HBoxContainer
var _focus_ring: Panel

var _cached_stylebox: StyleBoxFlat
var _cached_fonts: Dictionary = {}
var _action_labels: Array[String] = []
var _ready_called: bool = false
var _media_content: Control = null

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	print("[M3Card] _ready() called on ", name)
	flat = true
	text = ""
	set_clip_children_mode(CanvasItem.ClipChildrenMode.CLIP_CHILDREN_AND_DRAW)
	
	_cached_fonts = M3Theme.load_fonts()
	_initialize_styleboxes()
	_rebuild_layout()
	_update_media()
	_update_text()
	_update_appearance()
	
	# DEBUG: deferred redraw to ensure draw happens after full tree entry
	call_deferred("queue_redraw")
	
	# Suppress native focus stylebox; we use a child panel instead
	add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	
	# Mouse / focus state tracking
	mouse_entered.connect(queue_redraw)
	mouse_exited.connect(queue_redraw)
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
	else:
		focus_mode = Control.FOCUS_NONE
		button_mask = MouseButton.MOUSE_BUTTON_NONE
		_hovered = false
		_is_pressing = false
	queue_redraw()

func _initialize_styleboxes():
	_cached_stylebox = StyleBoxFlat.new()
	_cached_stylebox.anti_aliasing = true
	_cached_stylebox.anti_aliasing_size = 1.0
	_cached_stylebox.set_border_width_all(0)

func _rebuild_layout():
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
	
	# Create root container based on layout mode
	if card_layout_mode == LayoutMode.HORIZONTAL:
		_root_container = HBoxContainer.new()
	else:
		_root_container = VBoxContainer.new()
	
	_root_container.name = "RootContainer"
	_root_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_container.add_theme_constant_override("separation", 0)
	_root_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root_container)
	
	# Media panel with rounded-corner clipping
	_media_panel = Panel.new()
	_media_panel.name = "MediaPanel"
	_media_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_media_panel.clip_children = CanvasItem.CLIP_CHILDREN_ONLY
	var media_sb = StyleBoxFlat.new()
	media_sb.bg_color = Color.TRANSPARENT
	media_sb.anti_aliasing = false
	media_sb.set_border_width_all(0)
	_media_panel.add_theme_stylebox_override("panel", media_sb)
	
	if card_layout_mode == LayoutMode.HORIZONTAL:
		_media_panel.custom_minimum_size.x = M3Units.dp(MEDIA_WIDTH_LIST)
		_media_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		_media_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		_media_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_media_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	_root_container.add_child(_media_panel)
	
	if _media_content and is_instance_valid(_media_content):
		_media_panel.add_child(_media_content)
	else:
		_media_rect = TextureRect.new()
		_media_rect.name = "MediaRect"
		_media_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_media_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		_media_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_media_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		_media_rect.visible = false
		_media_panel.add_child(_media_rect)
	
	# Text area: MarginContainer wrapping content
	_text_margin = MarginContainer.new()
	_text_margin.name = "TextMargin"
	_text_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if card_layout_mode == LayoutMode.HORIZONTAL:
		_text_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		_text_margin.size_flags_vertical = Control.SIZE_SHRINK_CENTER
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
	
	_headline_label = Label.new()
	_headline_label.name = "Headline"
	_headline_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_headline_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_headline_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text_content.add_child(_headline_label)
	
	_supporting_label = Label.new()
	_supporting_label.name = "SupportingText"
	_supporting_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
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
	focus_sb.set_corner_radius_all(M3Units.dpi(corner_radius_dp))
	focus_sb.anti_aliasing = true
	focus_sb.anti_aliasing_size = 1.0
	_focus_ring.add_theme_stylebox_override("panel", focus_sb)
	add_child(_focus_ring)
	
	_rebuild_actions()

# ============================================
# DRAW
# ============================================

func _draw():
	print("[M3Card] _draw() called on ", name, " size=", size, " stylebox=", _cached_stylebox, " corner_radius_dp=", corner_radius_dp)
	self_modulate = Color(1.0, 0.3, 0.3)  # DEBUG: turn card red so we can visually confirm _draw() runs
	if not _cached_stylebox:
		print("[M3Card] _draw() aborting: _cached_stylebox is null")
		return
	
	var rect = Rect2(Vector2.ZERO, size)
	var radius = M3Units.dpi(corner_radius_dp)
	print("[M3Card] _draw() radius=", radius, " rect=", rect)
	
	_configure_stylebox_for_state()
	_cached_stylebox.set_corner_radius_all(radius)
	
	# Draw card background
	draw_style_box(_cached_stylebox, rect)

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

func _update_text():
	print("[M3Card] _update_text() headline=", headline, " supporting=", supporting_text, " labels_exist=", _headline_label != null and _supporting_label != null)
	if not _headline_label or not _supporting_label:
		print("[M3Card] _update_text() aborting: labels missing")
		return
	
	var fonts = _cached_fonts
	var headline_size = M3Units.dp(HEADLINE_FONT_SIZE)
	var supporting_size = M3Units.dp(SUPPORTING_FONT_SIZE)
	
	_headline_label.text = headline
	_headline_label.visible = not headline.is_empty()
	_headline_label.add_theme_font_override("font", fonts["medium"])
	_headline_label.add_theme_font_size_override("font_size", headline_size)
	_headline_label.add_theme_color_override("font_color", M3Theme.get_on_surface())
	
	_supporting_label.text = supporting_text
	_supporting_label.visible = not supporting_text.is_empty()
	_supporting_label.add_theme_font_override("font", fonts["regular"])
	_supporting_label.add_theme_font_size_override("font_size", supporting_size)
	_supporting_label.add_theme_color_override("font_color", M3Theme.get_on_surface_variant())

func _update_appearance():
	print("[M3Card] _update_appearance() text_margin=", _text_margin, " custom_min_size=", custom_minimum_size)
	if not _text_margin:
		print("[M3Card] _update_appearance() aborting: _text_margin missing")
		return
	
	var pad = M3Units.dp(PADDING)
	var half_pad = M3Units.dp(PADDING / 2.0)
	
	# Padding inside the text area
	_text_margin.add_theme_constant_override("margin_left", pad)
	_text_margin.add_theme_constant_override("margin_right", pad)
	_text_margin.add_theme_constant_override("margin_top", half_pad)
	_text_margin.add_theme_constant_override("margin_bottom", pad)
	
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
	queue_redraw()

# ============================================
# INPUT / STATE
# ============================================

var _hovered: bool = false
var _is_pressing: bool = false

func _notification(what: int):
	match what:
		NOTIFICATION_MOUSE_ENTER:
			if clickable:
				_hovered = true
				queue_redraw()
		NOTIFICATION_MOUSE_EXIT:
			if clickable:
				_hovered = false
				_is_pressing = false
				queue_redraw()
		NOTIFICATION_RESIZED:
			queue_redraw()
		NOTIFICATION_DRAW:
			print("[M3Card] NOTIFICATION_DRAW on ", name, " size=", size)

func _gui_input(event: InputEvent):
	if not clickable:
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_pressing = event.pressed
			queue_redraw()

func _on_focus_changed():
	if _focus_ring:
		_focus_ring.visible = has_focus() and not disabled
	queue_redraw()
