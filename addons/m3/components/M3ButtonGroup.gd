@tool
class_name M3ButtonGroup
extends BoxContainer

## Material 3 Button Group Component
## Manages M3Button and M3IconButton children as a cohesive group.
## Supports standard (spaced) and connected visual modes,
## single-select and multi-select interaction modes, and round/square shapes.
## Supports both horizontal and vertical orientations.

enum Mode { STANDARD, CONNECTED }
enum SelectMode { SINGLE, MULTI, NONE }
enum Shape { ROUND, SQUARE }

# ============================================
# INNER PADDING SPECS (gap between buttons, in dp)
# ============================================

const STANDARD_INNER_PADDING = {
	0: 18,  # XS
	1: 12,  # S
	2: 8,   # M
	3: 8,   # L
	4: 8,   # XL
}

const CONNECTED_INNER_PADDING = 2

# ============================================
# CONNECTED CORNER SPECS (in dp)
# ============================================

# Inner corners for round connected mode (and outer for square connected)
const CONNECTED_INNER_CORNERS = {
	0: 4,   # XS
	1: 8,   # S
	2: 8,   # M
	3: 16,  # L
	4: 20,  # XL
}

# ============================================
# EXPORTS
# ============================================

@export var mode: Mode = Mode.STANDARD:
	set(value):
		if value == mode:
			return
		mode = value
		if _ready_called:
			_update_mode()

@export var select_mode: SelectMode = SelectMode.SINGLE:
	set(value):
		if value == select_mode:
			return
		select_mode = value
		if _ready_called:
			_ensure_valid_selection()

@export var shape: Shape = Shape.SQUARE:
	set(value):
		if value == shape:
			return
		shape = value
		if _ready_called:
			_update_shape()

@export var initial_selection: Array[int] = [0]:
	set(value):
		initial_selection = value
		if _ready_called:
			_apply_initial_selection()

@export var disabled: bool = false:
	set(value):
		if value == disabled:
			return
		disabled = value
		if _ready_called:
			_update_disabled_state()

# ============================================
# SIGNALS
# ============================================

signal selection_changed(selected_indices: Array[int])

# ============================================
# INTERNAL
# ============================================

var _buttons: Array[Button] = []
var _selected_indices: Array[int] = []
var _ready_called: bool = false
var _button_disabled_states: Dictionary = {}
var _button_callables: Dictionary = {}

# ============================================
# LIFECYCLE
# ============================================

func _ready():
	_scan_buttons()
	_apply_initial_selection()
	_update_mode()
	_update_shape()
	_update_disabled_state()
	_ready_called = true
	
	child_entered_tree.connect(_on_child_entered)
	child_exiting_tree.connect(_on_child_exiting)

# ============================================
# BUTTON TRACKING
# ============================================

func _scan_buttons():
	for btn in _buttons:
		_disconnect_button(btn)
	
	_buttons.clear()
	for child in get_children():
		if _is_valid_button(child):
			_buttons.append(child)
			_connect_button(child)

func _is_valid_button(node: Node) -> bool:
	return node is M3Button or node is M3IconButton or node is Button

func _connect_button(btn: Button):
	# Ensure toggle mode for group behavior (unless in NONE mode)
	if select_mode != SelectMode.NONE:
		if btn is M3Button and btn.button_type != M3Button.Type.TOGGLE:
			btn.button_type = M3Button.Type.TOGGLE
	
	if not _button_callables.has(btn):
		var callable = _on_button_pressed.bind(btn)
		_button_callables[btn] = callable
		btn.pressed.connect(callable)

func _disconnect_button(btn: Button):
	if _button_callables.has(btn):
		var callable = _button_callables[btn]
		if btn.pressed.is_connected(callable):
			btn.pressed.disconnect(callable)
		_button_callables.erase(btn)

func _on_child_entered(node: Node):
	if _is_valid_button(node):
		_buttons.append(node)
		_connect_button(node)
		if _ready_called:
			_update_mode()
			_update_shape()

func _on_child_exiting(node: Node):
	if node in _buttons:
		var removed_idx = _buttons.find(node)
		_buttons.erase(node)
		_disconnect_button(node)
		
		if select_mode == SelectMode.NONE:
			return
		
		# Adjust selected indices after removal
		var new_selection: Array[int] = []
		for sel_idx in _selected_indices:
			if sel_idx < removed_idx:
				new_selection.append(sel_idx)
			elif sel_idx > removed_idx:
				new_selection.append(sel_idx - 1)
			# If sel_idx == removed_idx, selected button was removed
		
		_selected_indices = new_selection
		
		# In single-select, ensure something remains selected
		if select_mode == SelectMode.SINGLE and _selected_indices.is_empty() and not _buttons.is_empty():
			_selected_indices = [0]
		
		_update_button_states()

# ============================================
# SELECTION HANDLING
# ============================================

func _on_button_pressed(btn: Button):
	if disabled:
		return
	
	var index = _buttons.find(btn)
	if index < 0:
		return
	
	match select_mode:
		SelectMode.SINGLE:
			if _selected_indices != [index]:
				_selected_indices = [index]
				_update_button_states()
				selection_changed.emit(_selected_indices.duplicate())
			else:
				# Already selected: ensure it stays pressed
				btn.button_pressed = true
		SelectMode.MULTI:
			if index in _selected_indices:
				_selected_indices.erase(index)
			else:
				_selected_indices.append(index)
			_update_button_states()
			selection_changed.emit(_selected_indices.duplicate())
		SelectMode.NONE:
			# Normal push button behavior — just emit with empty selection
			selection_changed.emit([])

func _apply_initial_selection():
	_selected_indices.clear()
	
	if _buttons.is_empty():
		return
	
	match select_mode:
		SelectMode.SINGLE:
			var idx = 0
			if not initial_selection.is_empty():
				idx = initial_selection[0]
			if idx < 0 or idx >= _buttons.size():
				idx = 0
			_selected_indices = [idx]
		SelectMode.MULTI:
			for idx in initial_selection:
				if idx >= 0 and idx < _buttons.size() and idx not in _selected_indices:
					_selected_indices.append(idx)
		SelectMode.NONE:
			pass  # No selection tracking in NONE mode
	
	_update_button_states()

func _ensure_valid_selection():
	if select_mode == SelectMode.SINGLE and _selected_indices.size() != 1:
		_apply_initial_selection()

func _update_button_states():
	if select_mode == SelectMode.NONE:
		return
	
	for i in range(_buttons.size()):
		var btn = _buttons[i]
		var should_be_pressed = i in _selected_indices
		if btn.button_pressed != should_be_pressed:
			btn.button_pressed = should_be_pressed

# ============================================
# SIZE DETECTION
# ============================================

func _get_button_size_index(btn: Button) -> int:
	if btn is M3IconButton:
		return int(btn.icon_button_size)
	elif btn is M3Button:
		return int(btn.button_size)
	return 2  # Default to MEDIUM

# ============================================
# VISUAL MODE
# ============================================

func _update_mode():
	match mode:
		Mode.STANDARD:
			_update_standard_separation()
			_reset_button_corners()
		Mode.CONNECTED:
			add_theme_constant_override("separation", M3Units.dp(CONNECTED_INNER_PADDING))
			_update_connected_corners()

func _update_standard_separation():
	if _buttons.is_empty():
		remove_theme_constant_override("separation")
		return
	
	var size_idx = _get_button_size_index(_buttons[0])
	var padding = STANDARD_INNER_PADDING.get(size_idx, 8)
	add_theme_constant_override("separation", M3Units.dp(padding))

func _update_shape():
	if mode == Mode.CONNECTED:
		_update_connected_corners()
	else:
		_update_standard_separation()

func _update_connected_corners():
	if mode != Mode.CONNECTED or _buttons.is_empty():
		return
	
	var count = _buttons.size()
	var size_idx = _get_button_size_index(_buttons[0])
	var inner_radius = M3Units.dp(CONNECTED_INNER_CORNERS.get(size_idx, 8))
	
	for i in range(count):
		var btn = _buttons[i]
		var tl = 0
		var tr = 0
		var bl = 0
		var br = 0
		
		if shape == Shape.ROUND:
			# Round connected: outer = fully round (pill), inner = listed size
			var outer_radius = _get_pill_radius(btn)
			
			if vertical:
				# Vertical: first=top, last=bottom
				if i == 0:
					# First button: round top side
					tl = outer_radius
					tr = outer_radius
					# Bottom side: inner corner size
					bl = inner_radius
					br = inner_radius
				elif i == count - 1:
					# Last button: round bottom side
					bl = outer_radius
					br = outer_radius
					# Top side: inner corner size
					tl = inner_radius
					tr = inner_radius
				else:
					# Middle buttons: inner corner size on all corners
					tl = inner_radius
					tr = inner_radius
					bl = inner_radius
					br = inner_radius
			else:
				# Horizontal: first=left, last=right
				if i == 0:
					# First button: round left side
					tl = outer_radius
					bl = outer_radius
					# Right side: inner corner size
					tr = inner_radius
					br = inner_radius
				elif i == count - 1:
					# Last button: round right side
					tr = outer_radius
					br = outer_radius
					# Left side: inner corner size
					tl = inner_radius
					bl = inner_radius
				else:
					# Middle buttons: inner corner size on all corners
					tl = inner_radius
					tr = inner_radius
					bl = inner_radius
					br = inner_radius
		else:
			# Square connected: outer = listed size, inner = 0 (square)
			var outer_radius = inner_radius  # Same lookup for square outer
			
			if vertical:
				# Vertical: first=top, last=bottom
				if i == 0:
					# First button: outer size on top, 0 on bottom
					tl = outer_radius
					tr = outer_radius
					# Bottom side: square (0)
					bl = 0
					br = 0
				elif i == count - 1:
					# Last button: outer size on bottom, 0 on top
					bl = outer_radius
					br = outer_radius
					# Top side: square (0)
					tl = 0
					tr = 0
				else:
					# Middle buttons: all square (0)
					pass  # All remain 0
			else:
				# Horizontal: first=left, last=right
				if i == 0:
					# First button: outer size on left, 0 on right
					tl = outer_radius
					bl = outer_radius
					# Right side: square (0)
					tr = 0
					br = 0
				elif i == count - 1:
					# Last button: outer size on right, 0 on left
					tr = outer_radius
					br = outer_radius
					# Left side: square (0)
					tl = 0
					bl = 0
				else:
					# Middle buttons: all square (0)
					pass  # All remain 0
		
		_set_button_corners(btn, tl, tr, bl, br)

func _get_pill_radius(btn: Button) -> int:
	var h = max(btn.size.y, btn.custom_minimum_size.y)
	if h <= 0:
		h = M3Units.dp(40)  # Fallback
	return int(h / 2.0)

func _reset_button_corners():
	for btn in _buttons:
		if btn.has_method("set_corner_radii"):
			btn.call("set_corner_radii", 0, 0, 0, 0)

func _set_button_corners(btn: Button, tl: int, tr: int, bl: int, br: int):
	if btn.has_method("set_corner_radii"):
		btn.call("set_corner_radii", tl, tr, bl, br)

# ============================================
# DISABLED STATE
# ============================================

func _update_disabled_state():
	if disabled:
		_button_disabled_states.clear()
		for btn in _buttons:
			_button_disabled_states[btn] = btn.disabled
			btn.disabled = true
	else:
		for btn in _buttons:
			if btn in _button_disabled_states:
				btn.disabled = _button_disabled_states[btn]
			else:
				btn.disabled = false
		_button_disabled_states.clear()

# ============================================
# PUBLIC API
# ============================================

func get_selected_indices() -> Array[int]:
	return _selected_indices.duplicate()

func get_selected_buttons() -> Array[Button]:
	var result: Array[Button] = []
	for idx in _selected_indices:
		if idx >= 0 and idx < _buttons.size():
			result.append(_buttons[idx])
	return result

func select_button(index: int):
	if index < 0 or index >= _buttons.size():
		return
	
	match select_mode:
		SelectMode.SINGLE:
			if _selected_indices != [index]:
				_selected_indices = [index]
				_update_button_states()
				selection_changed.emit(_selected_indices.duplicate())
		SelectMode.MULTI:
			if index not in _selected_indices:
				_selected_indices.append(index)
				_update_button_states()
				selection_changed.emit(_selected_indices.duplicate())

func deselect_button(index: int):
	if index < 0 or index >= _buttons.size():
		return
	
	if index in _selected_indices:
		_selected_indices.erase(index)
		_update_button_states()
		selection_changed.emit(_selected_indices.duplicate())
