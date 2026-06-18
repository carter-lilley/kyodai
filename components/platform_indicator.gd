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

const PLATFORM_COUNT: int = 5
const TOTAL_GROUP_BUTTONS: int = PLATFORM_COUNT + 2
const CENTER_PLATFORM_INDEX: int = 2

const MIN_HEIGHT_DP: float = 50.0
const VERTICAL_PADDING_DP: float = 8.0

var _platforms: Array[Dictionary] = []
var _current_index: int = -1
var _all_games_label: String = "ALL"
var _visible_indices: Array[int] = []

func _ready():
	_setup_ui()

func _setup_ui():
	var hbox = HBoxContainer.new()
	hbox.name = "MainContainer"
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", M3Units.dp(8))
	add_child(hbox)
	
	# Previous chevron (index 0)
	var prev_btn = M3Button.new()
	prev_btn.name = "PrevButton"
	prev_btn.icon_name = "chevron-left-circle"
	prev_btn.text = ""
	prev_btn.button_size = M3Button.Size.SMALL
	prev_btn.button_variant = M3Button.Variant.OUTLINED
	prev_btn.focus_mode = Control.FOCUS_NONE
	prev_btn.pressed.connect(_on_prev_clicked)
	
	# Platform buttons (indices 1-5)
	var platform_btns: Array[M3Button] = []
	for i in range(PLATFORM_COUNT):
		var btn = M3Button.new()
		btn.name = "PlatformButton" + str(i)
		btn.button_size = M3Button.Size.SMALL
		if i == CENTER_PLATFORM_INDEX:
			btn.button_variant = M3Button.Variant.FILLED
		else:
			btn.button_variant = M3Button.Variant.ELEVATED
		btn.focus_mode = Control.FOCUS_NONE
		btn.pressed.connect(_on_platform_button_clicked.bind(i))
		platform_btns.append(btn)
	
	# Next chevron (index 6)
	var next_btn = M3Button.new()
	next_btn.name = "NextButton"
	next_btn.icon_name = "chevron-right-circle"
	next_btn.text = ""
	next_btn.button_size = M3Button.Size.SMALL
	next_btn.button_variant = M3Button.Variant.OUTLINED
	next_btn.focus_mode = Control.FOCUS_NONE
	next_btn.pressed.connect(_on_next_clicked)
	
	# Filter button (outside the group, on the left)
	_filter_button = M3IconButton.new()
	_filter_button.name = "FilterButton"
	_filter_button.icon_name = "filter-check-outline"
	_filter_button.icon_button_size = M3IconButton.IconSize.SMALL
	_filter_button.icon_button_variant = M3IconButton.IconVariant.STANDARD
	_filter_button.focus_mode = Control.FOCUS_NONE
	_filter_button.pressed.connect(_on_filter_clicked)
	hbox.add_child(_filter_button)
	
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
		_platform_buttons.append(btn)
	_platform_group.add_child(next_btn)
	hbox.add_child(_platform_group)
	
	# Search button (outside the group)
	_search_button = M3IconButton.new()
	_search_button.name = "SearchButton"
	_search_button.icon_name = "magnify"
	_search_button.icon_button_size = M3IconButton.IconSize.SMALL
	_search_button.icon_button_variant = M3IconButton.IconVariant.STANDARD
	_search_button.focus_mode = Control.FOCUS_NONE
	_search_button.pressed.connect(_on_search_clicked)
	hbox.add_child(_search_button)
	
	_update_minimum_height()
	# Child _ready() callbacks may run after setup; recalculate once the tree is stable.
	call_deferred("_update_minimum_height")

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
		for i in range(PLATFORM_COUNT):
			_platform_buttons[i].text = ""
			_platform_buttons[i].disabled = true
		return
	
	_visible_indices.clear()
	
	for i in range(PLATFORM_COUNT):
		var offset = i - 2
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
		if i == CENTER_PLATFORM_INDEX:
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
	
	for i in range(PLATFORM_COUNT):
		var btn = _platform_buttons[i]
		
		if i == CENTER_PLATFORM_INDEX:
			btn.text = "SEARCH"
			btn.disabled = false
			btn.button_variant = M3Button.Variant.FILLED
		else:
			if i == 1 or i == 3:
				var display_query = query
				if display_query.length() > 12:
					display_query = display_query.substr(0, 9) + "..."
				btn.text = display_query
			else:
				btn.text = ""
			btn.disabled = true
			btn.button_variant = M3Button.Variant.ELEVATED
