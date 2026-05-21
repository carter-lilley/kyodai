class_name M3Menu
extends M3Overlay

const M3MenuItem = preload("res://addons/m3/components/M3MenuItem.gd")
const M3MenuRenderer = preload("res://addons/m3/components/M3MenuRenderer.gd")

## Material 3 Menu Component
## Extends M3Overlay for consistent overlay behavior.
## Builds and shows M3-styled popup menus.

const M3Units = preload("res://addons/m3/M3Units.gd")

# ============================================
# EXPORTS
# ============================================

@export var menu_variant: M3MenuRenderer.ColorVariant = M3MenuRenderer.ColorVariant.STANDARD:
	set(value):
		if value == menu_variant:
			return
		menu_variant = value

# ============================================
# INTERNAL
# ============================================

var _items: Array[M3MenuItem] = []
var _renderer: M3MenuRenderer = null
var _summoner: Control = null
var _submenu: M3Menu = null
var _submenu_item_index: int = -1
var _summoner_start_pos: Vector2 = Vector2.ZERO
var _parent_menu: M3Menu = null
var _item_selected: bool = false

## When true, checkable items toggle without dismissing the menu.
var multi_select: bool = false

## When true, checkable items behave like radio buttons: only one can be checked at a time.
var radio_group: bool = false

## When true, the menu is automatically freed after dismissal.
## Set to false for reusable menus (e.g., checkable menus that need to persist state).
var auto_free: bool = true

## When true, the menu dismisses if the anchor control moves (e.g., scroll).
## Disable for menus anchored to scrolling items.
var track_summoner: bool = true

# ============================================
# LIFECYCLE
# ============================================

func _init():
	super._init()
	overlay_type = "menu"
	overlay_layer = 95

func _process(_delta):
	if not track_summoner:
		return
	# Dismiss if summoner has moved (e.g., page scrolled)
	if not visible or _summoner == null or not is_instance_valid(_summoner):
		return
	if _summoner.global_position.distance_to(_summoner_start_pos) > 1.0:
		dismiss()

# ============================================
# BUILDER API
# ============================================

## Add a normal menu item.
func add_item(text: String, callback: Callable = Callable(), icon: String = "", trailing_icon: String = ""):
	_items.append(M3MenuItem.make_normal(text, icon, callback, trailing_icon))

## Add a checkable menu item.
func add_check_item(text: String, checked: bool = false, callback: Callable = Callable(), icon: String = "", trailing_icon: String = ""):
	_items.append(M3MenuItem.make_checkable(text, checked, icon, callback, trailing_icon))

## Add a two-line menu item.
func add_two_line_item(primary: String, secondary: String, callback: Callable = Callable(), icon: String = "", trailing_icon: String = ""):
	_items.append(M3MenuItem.make_two_line(primary, secondary, icon, callback, trailing_icon))

## Add a section label (non-interactive heading).
func add_section_label(text: String):
	_items.append(M3MenuItem.make_section_label(text))

## Add a separator line.
func add_separator():
	_items.append(M3MenuItem.make_separator())

## Add a submenu item that opens another M3Menu when hovered or activated.
func add_submenu_item(text: String, submenu: M3Menu, icon: String = ""):
	_items.append(M3MenuItem.make_submenu(text, submenu, icon))

## Remove all items.
func clear():
	_items.clear()
	if _renderer and _renderer.is_open():
		_renderer.dismiss()

## Get the number of items.
func get_item_count() -> int:
	return _items.size()

## Get an item by index.
func get_item(index: int) -> M3MenuItem:
	if index >= 0 and index < _items.size():
		return _items[index]
	return null

# ============================================
# POPUP API
# ============================================

## Show the menu popup anchored to the given Control.
## as_submenu: when true, skips the M3Overlay singleton registry so the parent menu stays open.
func popup(anchor: Control, alignment: int = 0, auto_focus_first: bool = true, min_width: float = 0.0, as_submenu: bool = false):
	if _items.is_empty():
		return
	
	# Release previous summoner
	_release_summoner()
	_summoner = anchor
	_summoner_start_pos = anchor.global_position
	_set_summoner_active(true)
	
	# Reset item selection tracking for fresh popup
	_item_selected = false
	_parent_menu = null
	
	if as_submenu:
		# Just add to tree and show; don't register in _active so parent isn't dismissed
		var tree = Engine.get_main_loop()
		if tree and tree.root and get_parent() == null:
			tree.root.add_child(self)
		visible = true
	else:
		show_overlay()
	
	_ensure_renderer()
	_renderer.popup(_items, anchor, menu_variant, alignment, auto_focus_first, min_width, multi_select, radio_group, as_submenu)
	_renderer.item_pressed.connect(_on_item_pressed, CONNECT_ONE_SHOT)
	_renderer.dismissed.connect(_on_renderer_dismissed, CONNECT_ONE_SHOT)
	_renderer.submenu_requested.connect(_on_submenu_requested)
	_renderer.focus_changed.connect(_on_focus_changed)
	_renderer.navigated_off_edge.connect(_on_navigated_off_edge)

## Check if the menu is currently open.
func is_open() -> bool:
	return _renderer != null and _renderer.is_open()

# ============================================
# OVERRIDES
# ============================================

func show_overlay():
	var tree = Engine.get_main_loop()
	if tree and tree.root and get_parent() == null:
		tree.root.add_child(self)
	super.show_overlay()

# ============================================
# PRIVATE
# ============================================

func _ensure_renderer():
	if _renderer == null or not is_instance_valid(_renderer):
		_renderer = M3MenuRenderer.new()
		_renderer.name = "M3MenuRenderer"
		add_child(_renderer)

func _on_item_pressed(index: int):
	_item_selected = true

func refresh_theme():
	if _renderer:
		_renderer.refresh_theme()

func dismiss():
	# Return focus to the summoner before releasing it, but only if the user
	# didn't select an item (i.e., they cancelled or navigated away). When an
	# item is selected from a submenu, we skip focus restoration to prevent
	# re-triggering the submenu open via _on_item_focus_entered.
	if not _item_selected and _summoner != null and is_instance_valid(_summoner):
		_summoner.grab_focus()
	_release_summoner()
	_close_submenu()
	# Free any non-auto_free submenus so they don't leak
	for item in _items:
		if item.submenu != null and is_instance_valid(item.submenu):
			item.submenu.queue_free()
	# Don't reset _item_selected here — it's needed by _on_submenu_dismissed
	# to know whether the parent menu should also close. It's reset in popup().
	_parent_menu = null
	# Don't call super.dismiss() — M3Overlay.dismiss() queue_frees the node,
	# but M3Menu instances are often reused (e.g., checkable menus that need
	# to persist state across openings). Do the registry cleanup manually.
	if _active.get(overlay_type) == self:
		_active.erase(overlay_type)
	if _renderer and _renderer.focus_changed.is_connected(_on_focus_changed):
		_renderer.focus_changed.disconnect(_on_focus_changed)
	if _renderer and _renderer.submenu_requested.is_connected(_on_submenu_requested):
		_renderer.submenu_requested.disconnect(_on_submenu_requested)
	if _renderer and _renderer.navigated_off_edge.is_connected(_on_navigated_off_edge):
		_renderer.navigated_off_edge.disconnect(_on_navigated_off_edge)
	dismissed.emit()
	visible = false
	if auto_free:
		queue_free()

func _on_renderer_dismissed():
	# Renderer dismissed itself (outside click or item selection)
	# Call our own dismiss() (not super) so we don't get queue_freed
	if is_instance_valid(self):
		dismiss()

func _on_submenu_requested(index: int):
	if index < 0 or index >= _items.size():
		return
	var item = _items[index]
	if item.submenu == null:
		return
	
	# Close any existing submenu first
	_close_submenu()
	
	_submenu = item.submenu
	_submenu_item_index = index
	_submenu._parent_menu = self
	
	# Keep parent item visually focused while submenu is open
	if _renderer:
		_renderer.set_submenu_open(index, true)
		_renderer.set_forced_focus_index(index)
	
	# Anchor submenu to the item node
	var item_node: Control = null
	if _renderer and index < _renderer._item_nodes.size():
		item_node = _renderer._item_nodes[index]
	
	if item_node:
		_submenu.popup(item_node, 0, true, 0, true)
	else:
		_submenu.popup(_renderer, 0, true, 0, true)
	
	# Tell parent renderer about the submenu's rect so it doesn't dismiss on clicks inside it
	if _renderer and _submenu != null and is_instance_valid(_submenu):
		_renderer.set_submenu_rect(_submenu.get_menu_rect())
		_submenu.dismissed.connect(_on_submenu_dismissed, CONNECT_ONE_SHOT)

func _on_submenu_dismissed():
	# If the submenu had an item selected, close the parent menu too
	if _submenu and _submenu._item_selected:
		dismiss()
		return
	
	# Otherwise, restore chevron, clear forced focus, and return focus to parent item
	if _renderer and _submenu_item_index >= 0:
		_renderer._suppress_submenu = true
		_renderer.grab_item_focus(_submenu_item_index)
		_renderer._suppress_submenu = false
		_renderer.set_submenu_open(_submenu_item_index, false)
		_renderer.set_forced_focus_index(-1)
	if _renderer:
		_renderer.set_submenu_rect(Rect2())
	_submenu = null
	_submenu_item_index = -1

func _close_submenu():
	if _submenu and is_instance_valid(_submenu) and _submenu.is_open():
		_submenu.dismissed.disconnect(_on_submenu_dismissed)
		_submenu.dismiss()
	if _renderer and _submenu_item_index >= 0:
		_renderer._suppress_submenu = true
		_renderer.grab_item_focus(_submenu_item_index)
		_renderer._suppress_submenu = false
		_renderer.set_submenu_open(_submenu_item_index, false)
		_renderer.set_forced_focus_index(-1)
	if _renderer:
		_renderer.set_submenu_rect(Rect2())
	_submenu = null
	_submenu_item_index = -1

func _on_focus_changed(index: int):
	# Only close the submenu if focus moved to a different submenu item.
	# Hovering normal items in the parent menu keeps the submenu open.
	if _submenu and _submenu.is_open() and index != _submenu_item_index:
		if index >= 0 and index < _items.size() and _items[index].submenu != null:
			_close_submenu()

func _on_navigated_off_edge(direction: String):
	# Always close the menu when navigating off an edge
	dismiss()

func get_menu_rect() -> Rect2:
	if _renderer:
		return _renderer.get_global_rect()
	return Rect2()

func _input(event: InputEvent):
	if not visible:
		return
	
	# If a submenu is open, let it handle ui_cancel first
	if _submenu and _submenu.is_open():
		if event.is_action_pressed("ui_cancel"):
			return
		
		# Determine close direction based on submenu position relative to parent menu
		var parent_rect = get_menu_rect()
		var submenu_rect = _submenu.get_menu_rect()
		var submenu_on_right = submenu_rect.position.x >= parent_rect.position.x + parent_rect.size.x - 1
		
		# Close with the key that points back toward the parent menu
		if submenu_on_right and event.is_action_pressed("ui_left"):
			_close_submenu()
			if _renderer and _submenu_item_index >= 0:
				_renderer._suppress_submenu = true
				_renderer.grab_item_focus(_submenu_item_index)
				_renderer._suppress_submenu = false
			get_viewport().set_input_as_handled()
			return
		elif not submenu_on_right and event.is_action_pressed("ui_right"):
			_close_submenu()
			if _renderer and _submenu_item_index >= 0:
				_renderer._suppress_submenu = true
				_renderer.grab_item_focus(_submenu_item_index)
				_renderer._suppress_submenu = false
			get_viewport().set_input_as_handled()
			return
		return
	
	# Let base class handle ui_cancel dismissal
	super._input(event)

func _release_summoner():
	if _summoner != null:
		if is_instance_valid(_summoner):
			_set_summoner_active(false)
		_summoner = null
	_summoner_start_pos = Vector2.ZERO

func _set_summoner_active(active: bool):
	if _summoner == null or not is_instance_valid(_summoner):
		return
	if _summoner.has_method("set_menu_active"):
		_summoner.set_menu_active(active)
