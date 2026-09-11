class_name PlatformIndicator
extends Control

signal platform_selected(platform_index: int)
signal cycle_prev_clicked()
signal cycle_next_clicked()
signal search_clicked()
signal filter_clicked()

@onready var _search_button: M3IconButton
@onready var _filter_button: M3IconButton
@onready var _platform_group: M3ButtonGroup
@onready var _platform_buttons: Array[M3Button] = []

const MAX_PLATFORM_COUNT: int = 5
const MIN_PLATFORM_COUNT: int = 1
var _platform_count: int = MAX_PLATFORM_COUNT

const WIDTH_THRESHOLD_5_SMALL: float = 720.0
const WIDTH_THRESHOLD_3_XSMALL: float = 480.0
const RESIZE_DEBOUNCE_TIME: float = 0.1

const MIN_HEIGHT_DP: float = 50.0
const VERTICAL_PADDING_DP: float = 8.0

var _current_button_size: M3Button.Size = M3Button.Size.SMALL
var _resize_debounce_timer: Timer

var _platforms: Array[Dictionary] = []
var _current_index: int = -1
var _all_games_label: String = "ALL"
var _visible_indices: Array[int] = []

func _ready():
	# Render above focused cards (z_index 1) and their effects.
	z_index = 5
	_setup_ui()

func _setup_ui():
	var hbox = HBoxContainer.new()
	hbox.name = "MainContainer"
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", int(M3Units.dp(8)))
	add_child(hbox)
	
	# Filter button (outside the group, on the left)
	_filter_button = M3IconButton.new()
	_filter_button.name = "FilterButton"
	_filter_button.icon_name = "filter-check-outline"
	_filter_button.icon_button_size = M3IconButton.IconSize.SMALL
	_filter_button.icon_button_variant = M3IconButton.IconVariant.STANDARD
	_filter_button.focus_mode = Control.FOCUS_NONE
	_filter_button.pressed.connect(_on_filter_clicked)
	hbox.add_child(_filter_button)
	
	# Search button (outside the group)
	_search_button = M3IconButton.new()
	_search_button.name = "SearchButton"
	_search_button.icon_name = "magnify"
	_search_button.icon_button_size = M3IconButton.IconSize.SMALL
	_search_button.icon_button_variant = M3IconButton.IconVariant.STANDARD
	_search_button.focus_mode = Control.FOCUS_NONE
	_search_button.pressed.connect(_on_search_clicked)
	# Badge: right stick click activates search
	_search_button.badge_icon_name = "analog-r"
	_search_button.badge_icon_font = "ControllerIcons"
	hbox.add_child(_search_button)
	
	# Resize debounce timer
	_resize_debounce_timer = Timer.new()
	_resize_debounce_timer.name = "ResizeDebounceTimer"
	_resize_debounce_timer.one_shot = true
	_resize_debounce_timer.wait_time = RESIZE_DEBOUNCE_TIME
	_resize_debounce_timer.timeout.connect(_apply_responsive_layout)
	add_child(_resize_debounce_timer)
	
	# Build initial platform group once size is known
	call_deferred("_apply_responsive_layout")

func _notification(what: int):
	if what == NOTIFICATION_RESIZED:
		if _resize_debounce_timer != null:
			_resize_debounce_timer.start()

func _apply_responsive_layout() -> void:
	var available_width := size.x
	if available_width <= 0:
		available_width = get_viewport_rect().size.x
	
	var new_count: int
	var new_size: M3Button.Size
	
	if available_width >= M3Units.dp(WIDTH_THRESHOLD_5_SMALL):
		new_count = 5
		new_size = M3Button.Size.SMALL
	elif available_width >= M3Units.dp(WIDTH_THRESHOLD_3_XSMALL):
		new_count = 3
		new_size = M3Button.Size.EXTRA_SMALL
	else:
		new_count = 1
		new_size = M3Button.Size.EXTRA_SMALL
	
	if new_count == _platform_count and new_size == _current_button_size and _platform_group != null:
		return
	
	_platform_count = new_count
	_current_button_size = new_size
	_update_icon_button_sizes()
	_rebuild_platform_group()
	_update_minimum_height()
	call_deferred("_update_minimum_height")
	_refresh_labels()

func _update_icon_button_sizes() -> void:
	var icon_size_int: int = int(_current_button_size)
	if _filter_button != null:
		_filter_button.icon_button_size = icon_size_int as M3IconButton.IconSize
	if _search_button != null:
		_search_button.icon_button_size = icon_size_int as M3IconButton.IconSize

func _get_center_platform_index() -> int:
	return int(_platform_count / 2.0)

func _rebuild_platform_group() -> void:
	var hbox = get_node_or_null("MainContainer")
	if hbox == null:
		return
	
	# Remove old group
	if _platform_group != null:
		hbox.remove_child(_platform_group)
		_platform_group.queue_free()
		_platform_group = null
	_platform_buttons.clear()
	
	var center = _get_center_platform_index()
	
	# Previous chevron with left-shoulder badge
	var prev_btn = M3Button.new()
	prev_btn.name = "PrevButton"
	prev_btn.icon_name = "chevron-left-circle"
	prev_btn.badge_icon_name = "nintendo-left-shoulder"
	prev_btn.badge_icon_font = "ControllerIcons"
	prev_btn.badge_corner = M3Button.BadgeCorner.BOTTOM_LEFT
	prev_btn.text = ""
	prev_btn.button_size = _current_button_size
	prev_btn.button_variant = M3Button.Variant.OUTLINED
	prev_btn.focus_mode = Control.FOCUS_NONE
	prev_btn.pressed.connect(_on_prev_clicked)
	
	# Platform buttons
	var platform_btns: Array[M3Button] = []
	for i in range(_platform_count):
		var btn = M3Button.new()
		btn.name = "PlatformButton" + str(i)
		btn.button_size = _current_button_size
		if i == center:
			btn.button_variant = M3Button.Variant.FILLED
		else:
			btn.button_variant = M3Button.Variant.ELEVATED
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_on_platform_button_clicked.bind(i))
		platform_btns.append(btn)
		_platform_buttons.append(btn)
	
	# Next chevron with right-shoulder badge
	var next_btn = M3Button.new()
	next_btn.name = "NextButton"
	next_btn.icon_name = "chevron-right-circle"
	next_btn.badge_icon_name = "nintendo-right-shoulder"
	next_btn.badge_icon_font = "ControllerIcons"
	next_btn.text = ""
	next_btn.button_size = _current_button_size
	next_btn.button_variant = M3Button.Variant.OUTLINED
	next_btn.focus_mode = Control.FOCUS_NONE
	next_btn.pressed.connect(_on_next_clicked)
	
	# Build the group with all children BEFORE adding to tree so _ready() runs once
	# with fully-initialized buttons and computes connected corners correctly.
	_platform_group = M3ButtonGroup.new()
	_platform_group.name = "PlatformGroup"
	_platform_group.select_mode = M3ButtonGroup.SelectMode.NONE
	_platform_group.mode = M3ButtonGroup.Mode.CONNECTED
	_platform_group.shape = M3ButtonGroup.Shape.ROUND
	_platform_group.add_child(prev_btn)
	for btn in platform_btns:
		_platform_group.add_child(btn)
	_platform_group.add_child(next_btn)
	hbox.add_child(_platform_group)
	hbox.move_child(_platform_group, 1)

func _update_minimum_height() -> void:
	var hbox = get_node_or_null("MainContainer")
	if hbox == null:
		return
	
	var max_child_height := 0.0
	for child in hbox.get_children():
		if child is Control:
			max_child_height = max(max_child_height, child.get_combined_minimum_size().y)
	
	var min_height_px := M3Units.dp(MIN_HEIGHT_DP)
	var padded_height_px := max_child_height + M3Units.dp(VERTICAL_PADDING_DP)
	custom_minimum_size.y = max(min_height_px, padded_height_px)

func update_display(platforms: Array[Dictionary], current_index: int):
	_platforms = platforms
	_current_index = current_index
	_refresh_labels()

func _refresh_labels():
	if _platform_buttons.is_empty():
		return
	
	var total_items = _platforms.size() + 1
	if total_items <= 1:
		for i in range(_platform_count):
			_platform_buttons[i].text = ""
			_platform_buttons[i].disabled = true
		return
	
	_visible_indices.clear()
	var center = _get_center_platform_index()
	
	for i in range(_platform_count):
		var offset = i - center
		var current_0_based = _current_index + 1
		var target_0_based = current_0_based + offset
		target_0_based = ((target_0_based % total_items) + total_items) % total_items
		var target_index = target_0_based - 1
		_visible_indices.append(target_index)
		
		var platform_name: String
		if target_index == -1:
			platform_name = _all_games_label
		else:
			platform_name = _platforms[target_index].get("name", "???")
		
		var btn = _platform_buttons[i]
		btn.text = platform_name.to_upper().replace(" ", "")
		btn.disabled = false
		
		# Update variant based on position
		if i == center:
			btn.button_variant = M3Button.Variant.FILLED
		else:
			btn.button_variant = M3Button.Variant.ELEVATED

func _on_platform_button_clicked(button_index: int) -> void:
	if button_index >= 0 and button_index < _visible_indices.size():
		var platform_index = _visible_indices[button_index]
		platform_selected.emit(platform_index)

func _on_prev_clicked() -> void:
	cycle_prev_clicked.emit()

func _on_next_clicked() -> void:
	cycle_next_clicked.emit()

func _on_search_clicked() -> void:
	search_clicked.emit()

func _on_filter_clicked() -> void:
	filter_clicked.emit()

func get_all_games_label() -> String:
	return _all_games_label

func set_all_games_label(label: String):
	_all_games_label = label
	_refresh_labels()

func set_search_active(is_active: bool) -> void:
	_search_button.icon_name = "close" if is_active else "magnify"

func set_filter_active(is_active: bool) -> void:
	_filter_button.icon_name = "filter-check" if is_active else "filter-check-outline"

func show_search_mode(query: String):
	if _platform_buttons.is_empty():
		return

	var center = _get_center_platform_index()

	for i in range(_platform_count):
		var btn = _platform_buttons[i]

		if i == center:
			btn.text = "SEARCH"
			btn.disabled = false
			btn.button_variant = M3Button.Variant.FILLED
		else:
			if abs(i - center) == 1:
				var display_query = query
				if display_query.length() > 12:
					display_query = display_query.substr(0, 9) + "..."
				btn.text = display_query
			else:
				btn.text = ""
			btn.disabled = true
			btn.button_variant = M3Button.Variant.ELEVATED

## Mirror of search mode for an externally-applied filter (e.g. a studio chip
## in the details sheet): center reads the kind label, neighbors show the value.
func show_filter_mode(center_text: String, label: String):
	if _platform_buttons.is_empty():
		return

	var center = _get_center_platform_index()

	for i in range(_platform_count):
		var btn = _platform_buttons[i]

		if i == center:
			btn.text = center_text
			btn.disabled = false
			btn.button_variant = M3Button.Variant.FILLED
		else:
			if abs(i - center) == 1:
				var display_label = label
				if display_label.length() > 12:
					display_label = display_label.substr(0, 9) + "..."
				btn.text = display_label
			else:
				btn.text = ""
			btn.disabled = true
			btn.button_variant = M3Button.Variant.ELEVATED
