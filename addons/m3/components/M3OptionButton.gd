@tool
class_name M3OptionButton
extends M3TextField

const M3MenuRenderer = preload("res://addons/m3/components/M3MenuRenderer.gd")

## Material 3 Option Button / Exposed Dropdown Menu
## Extends M3TextField with dropdown selection behavior.
## Opens an M3Menu below the field; selecting an item updates the field text.
## Supports filtering by typing when the menu is open.

# ============================================
# ITEM DATA
# ============================================

class ItemData:
	var text: String = ""
	var id: int = -1
	var icon: String = ""
	var disabled: bool = false
	
	func _init(p_text: String = "", p_id: int = -1, p_icon: String = "", p_disabled: bool = false):
		text = p_text
		id = p_id
		icon = p_icon
		disabled = p_disabled

# ============================================
# CONSTANTS
# ============================================

const NONE_SELECTED := -1
const DROPDOWN_ICON := "triangle-small-down"
const DROPDOWN_ICON_OPEN := "triangle-small-up"

# ============================================
# SIGNALS
# ============================================

signal item_selected(index: int)
signal item_focused(index: int)

# ============================================
# EXPORTS
# ============================================

@export var fit_to_longest_item: bool = true:
	set(value):
		if value == fit_to_longest_item:
			return
		fit_to_longest_item = value
		if _ready_called:
			_update_minimum_size()

@export var allow_reselect: bool = false

@export var multi_select: bool = false:
	set(value):
		if value == multi_select:
			return
		multi_select = value
		if _ready_called:
			_update_selected_text()

## Backward-compat convenience for single-select mode.
## In multi-select mode, this gets/sets the first selected index.
var selected: int:
	get:
		if _chosen_item_indices.is_empty():
			return NONE_SELECTED
		return _chosen_item_indices[0]
	set(value):
		if multi_select:
			if value == NONE_SELECTED:
				_chosen_item_indices.clear()
			else:
				_chosen_item_indices = [value]
		else:
			if value == NONE_SELECTED:
				_chosen_item_indices.clear()
			elif _chosen_item_indices.is_empty() or _chosen_item_indices[0] != value:
				_chosen_item_indices = [value]
		if _ready_called:
			_update_selected_text()

# ============================================
# INTERNAL
# ============================================

var _items: Array[ItemData] = []
var _menu: M3Menu = null
var _is_menu_open: bool = false
var _filter_text: String = ""
var _chosen_item_indices: Array[int] = []

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	# Set trailing icon BEFORE parent _ready() initializes visuals
	trailing_icon = DROPDOWN_ICON
	
	# Call parent initialization
	super._ready()
	
	# OptionButton should not be editable; editable toggles to true only while filtering
	editable = false
	
	# Connect our own text changed handler for filtering
	text_changed.connect(_on_filter_text_changed)

func _gui_input(event: InputEvent):
	if _is_menu_open:
		# Let native text editing happen when filtering
		return
	
	# When menu is closed, swallow all input that would modify text
	if event is InputEventKey and event.pressed:
		if event.is_action_pressed("ui_accept") or event.is_action_pressed("ui_select"):
			_show_menu()
			accept_event()
		elif event.is_action_pressed("ui_focus_next") or event.is_action_pressed("ui_focus_prev"):
			# Allow Tab/Shift+Tab focus navigation
			pass
		elif event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down") or event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
			# Allow arrow-key focus navigation (gamepad / controller)
			pass
		else:
			# Block all other key presses (typing, backspace, etc.)
			accept_event()
		return
	
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_show_menu()
			accept_event()

# ============================================
# MENU
# ============================================

func _show_menu():
	if _items.is_empty():
		return
	
	# Clear text for filtering
	_filter_text = ""
	text = ""
	
	# Enable editing so the user can type to filter
	editable = true
	
	# Show focused/active visual state
	set_menu_active(true)
	
	# Update arrow icon
	trailing_icon = DROPDOWN_ICON_OPEN
	_update_icons()
	_update_layout()
	queue_redraw()
	
	_build_and_show_menu(true)
	_is_menu_open = true

func _build_and_show_menu(auto_focus_first: bool = false):
	if _menu:
		# Disconnect dismissed signal before dismissing to prevent
		# state corruption during filtering rebuilds
		if _menu.dismissed.is_connected(_on_menu_dismissed):
			_menu.dismissed.disconnect(_on_menu_dismissed)
		_menu.dismiss()
		_menu = null
	
	_menu = M3Menu.new()
	_menu.menu_variant = M3MenuRenderer.ColorVariant.STANDARD
	_menu.multi_select = multi_select
	
	var has_matches = false
	for i in range(_items.size()):
		var item = _items[i]
		if item.disabled:
			continue
		
		# Filter by text
		if not _filter_text.is_empty():
			var item_text_lower = item.text.to_lower()
			var filter_lower = _filter_text.to_lower()
			if not item_text_lower.contains(filter_lower):
				continue
		
		var idx = i
		if multi_select:
			_menu.add_check_item(item.text, _chosen_item_indices.has(idx), func(): _on_item_selected(idx), item.icon)
		else:
			_menu.add_item(item.text, func(): _on_item_selected(idx), item.icon)
		has_matches = true
	
	if not has_matches:
		_menu.queue_free()
		_menu = null
		return
	
	_menu.popup(self, 0, auto_focus_first, size.x)
	
	# Connect to M3Overlay dismissed signal (emitted when menu closes)
	if not _menu.dismissed.is_connected(_on_menu_dismissed):
		_menu.dismissed.connect(_on_menu_dismissed)

func _close_menu():
	if _menu:
		if _menu.dismissed.is_connected(_on_menu_dismissed):
			_menu.dismissed.disconnect(_on_menu_dismissed)
		_menu.dismiss()
		_menu = null
	_is_menu_open = false
	
	# Disable editing so arrow keys navigate focus instead of moving cursor
	editable = false
	
	# Remove focused/active visual state
	set_menu_active(false)
	
	# Restore selected text
	_update_selected_text()
	
	# Restore arrow icon
	trailing_icon = DROPDOWN_ICON
	_update_icons()
	_update_layout()
	queue_redraw()

func _on_item_selected(index: int):
	if index < 0 or index >= _items.size():
		_close_menu()
		return
	
	if multi_select:
		# Toggle selection without closing
		if _chosen_item_indices.has(index):
			_chosen_item_indices.erase(index)
		else:
			_chosen_item_indices.append(index)
		_update_selected_text()
		item_selected.emit(index)
		return
	
	# Single-select mode
	if index == selected and not allow_reselect:
		_close_menu()
		return
	
	selected = index
	item_selected.emit(index)
	_close_menu()

func _on_menu_dismissed():
	_is_menu_open = false
	_menu = null
	
	# Disable editing so arrow keys navigate focus instead of moving cursor
	editable = false
	
	# Remove focused/active visual state
	set_menu_active(false)
	
	# Restore selected text
	_update_selected_text()
	
	trailing_icon = DROPDOWN_ICON
	_update_icons()
	_update_layout()
	queue_redraw()

func _on_filter_text_changed(new_text: String):
	if not _is_menu_open:
		# User typed while menu is closed — restore selected text
		_update_selected_text()
		return
	_filter_text = new_text
	_build_and_show_menu(false)

# ============================================
# SELECTION
# ============================================

func _update_selected_text():
	if not _ready_called:
		return
	if _chosen_item_indices.is_empty():
		text = ""
	elif multi_select:
		var parts: Array[String] = []
		for idx in _chosen_item_indices:
			if idx >= 0 and idx < _items.size():
				parts.append(_items[idx].text)
		text = ", ".join(parts)
	else:
		var idx = _chosen_item_indices[0]
		if idx >= 0 and idx < _items.size():
			text = _items[idx].text
		else:
			text = ""

# ============================================
# PUBLIC API (mirrors native OptionButton)
# ============================================

func add_item(label: String, id: int = -1):
	var item_id = id if id >= 0 else _items.size()
	_items.append(ItemData.new(label, item_id))
	if fit_to_longest_item:
		_update_minimum_size()

func add_icon_item(icon_name: String, label: String, id: int = -1):
	var item_id = id if id >= 0 else _items.size()
	_items.append(ItemData.new(label, item_id, icon_name))
	if fit_to_longest_item:
		_update_minimum_size()

func set_item_text(idx: int, p_text: String):
	if idx >= 0 and idx < _items.size():
		_items[idx].text = p_text
		if _chosen_item_indices.has(idx):
			_update_selected_text()
		if fit_to_longest_item:
			_update_minimum_size()

func set_item_icon(idx: int, icon_name: String):
	if idx >= 0 and idx < _items.size():
		_items[idx].icon = icon_name

func set_item_disabled(idx: int, disabled: bool):
	if idx >= 0 and idx < _items.size():
		_items[idx].disabled = disabled

func set_item_id(idx: int, id: int):
	if idx >= 0 and idx < _items.size():
		_items[idx].id = id

func get_item_text(idx: int) -> String:
	if idx >= 0 and idx < _items.size():
		return _items[idx].text
	return ""

func get_item_icon(idx: int) -> String:
	if idx >= 0 and idx < _items.size():
		return _items[idx].icon
	return ""

func get_item_id(idx: int) -> int:
	if idx >= 0 and idx < _items.size():
		return _items[idx].id
	return NONE_SELECTED

func get_item_index(id: int) -> int:
	for i in range(_items.size()):
		if _items[i].id == id:
			return i
	return NONE_SELECTED

func is_item_disabled(idx: int) -> bool:
	if idx >= 0 and idx < _items.size():
		return _items[idx].disabled
	return false

func add_separator(text: String = ""):
	_items.append(ItemData.new(text, NONE_SELECTED, "", true))

func clear():
	_items.clear()
	_chosen_item_indices.clear()
	_update_selected_text()
	if fit_to_longest_item:
		_update_minimum_size()

func _select_index(idx: int):
	if idx >= -1 and idx < _items.size():
		if multi_select:
			if idx == NONE_SELECTED:
				_chosen_item_indices.clear()
			elif not _chosen_item_indices.has(idx):
				_chosen_item_indices.append(idx)
		else:
			if idx == NONE_SELECTED:
				_chosen_item_indices.clear()
			else:
				_chosen_item_indices = [idx]
		_update_selected_text()

func get_selected() -> int:
	if _chosen_item_indices.is_empty():
		return NONE_SELECTED
	return _chosen_item_indices[0]

func get_selected_id() -> int:
	return get_item_id(get_selected())

func get_item_count() -> int:
	return _items.size()

func remove_item(idx: int):
	if idx >= 0 and idx < _items.size():
		_items.remove_at(idx)
		var changed = false
		var new_selected: Array[int] = []
		for s in _chosen_item_indices:
			if s == idx:
				changed = true
				continue
			if s > idx:
				new_selected.append(s - 1)
				changed = true
			else:
				new_selected.append(s)
		if changed:
			_chosen_item_indices = new_selected
			_update_selected_text()
		if fit_to_longest_item:
			_update_minimum_size()

# ============================================
# MULTI-SELECT API
# ============================================

func select_option(idx: int) -> void:
	if idx < 0 or idx >= _items.size():
		return
	if not _chosen_item_indices.has(idx):
		_chosen_item_indices.append(idx)
		_update_selected_text()

func deselect_option(idx: int) -> void:
	if idx < 0 or idx >= _items.size():
		return
	if _chosen_item_indices.has(idx):
		_chosen_item_indices.erase(idx)
		_update_selected_text()

func is_selected(idx: int) -> bool:
	return idx >= 0 and idx < _items.size() and _chosen_item_indices.has(idx)

func get_selected_indices() -> Array[int]:
	return _chosen_item_indices.duplicate()

func clear_selection() -> void:
	_chosen_item_indices.clear()
	_update_selected_text()

func set_selected_indices(indices: Array[int]) -> void:
	_chosen_item_indices.clear()
	for idx in indices:
		if idx >= 0 and idx < _items.size():
			_chosen_item_indices.append(idx)
	_update_selected_text()

# ============================================
# SIZE
# ============================================

func _update_minimum_size():
	if not fit_to_longest_item:
		return
	
	var longest = ""
	for item in _items:
		if item.text.length() > longest.length():
			longest = item.text
	
	var fonts = M3Theme.load_fonts()
	var text_width = fonts["regular"].get_string_size(longest, HORIZONTAL_ALIGNMENT_LEFT, -1, M3Units.dp(INPUT_FONT_SIZE)).x
	var min_w = M3Units.dp(H_PADDING * 2)
	if not leading_icon.is_empty():
		min_w += M3Units.dp(ICON_SIZE + ICON_GAP)
	min_w += M3Units.dp(ICON_SIZE + ICON_GAP)  # dropdown arrow always present
	min_w += text_width
	
	custom_minimum_size.x = max(custom_minimum_size.x, min_w)

func _get_minimum_size() -> Vector2:
	var min_size = super._get_minimum_size()
	# Ensure dropdown arrow is accounted for
	var min_w = M3Units.dp(H_PADDING * 2 + ICON_SIZE + ICON_GAP)
	if not leading_icon.is_empty():
		min_w += M3Units.dp(ICON_SIZE + ICON_GAP)
	min_size.x = max(min_size.x, min_w)
	return min_size

# ============================================
# THEME
# ============================================

func _update_theme():
	# Temporarily pretend editable so M3TextField applies active colors
	var was_editable = editable
	editable = true
	super._update_theme()
	editable = was_editable
	# Override Godot's native uneditable color
	add_theme_color_override("font_uneditable_color", M3Theme.get_on_surface())

func refresh_theme():
	super.refresh_theme()
	_update_icons()
