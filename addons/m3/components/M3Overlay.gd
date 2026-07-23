class_name M3Overlay
extends CanvasLayer

## Base class for M3 overlay components (dialogs, menus, snackbars).
## Provides singleton-per-type behavior, standard dismissal, and lifecycle management.

# ============================================
# STATIC REGISTRY
# ============================================

# Stores WeakRefs so the registry never keeps an overlay alive after its owner
# has freed it. Stale entries are cleaned up on access.
static var _active: Dictionary = {}
static var _max_layer: int = 0

# Temporary suppression for focus pull-back, used when an overlay (e.g. a menu)
# is returning focus to its summoner and the underlying overlay must not yank it
# back, which would otherwise cause infinite recursion.
static var _suppress_focus_pullback: bool = false

## Get the effective parent node for overlays.
## In dual-screen mode the "m3_overlay_parent" node group is used so overlays
## render in the correct SubViewport instead of the root viewport.
static func get_overlay_parent() -> Node:
	var tree = Engine.get_main_loop()
	if tree is SceneTree:
		var group = tree.get_first_node_in_group("m3_overlay_parent")
		if group and is_instance_valid(group) and group is Node:
			return group
	return tree.root if tree else null

# ============================================
# EXPORTS
# ============================================

@export var overlay_type: String = ""
@export var overlay_layer: int = 80
@export var persistent: bool = false

# When true, capture the current focus owner when the overlay is shown and
# restore it when the overlay is dismissed.
var _restore_focus_on_dismiss: bool = false
var _summoner_focus: WeakRef = null
var _focus_restore_fallback: Callable = Callable()

# ============================================
# SIGNALS
# ============================================

signal dismissed

# ============================================
# LIFECYCLE
# ============================================

func _init():
	pass

func _ready():
	visible = false
	if get_viewport():
		get_viewport().gui_focus_changed.connect(_on_overlay_focus_changed)

func _on_overlay_focus_changed(control: Control) -> void:
	if _suppress_focus_pullback:
		return
	if not visible:
		return
	var topmost = _get_topmost_overlay()
	if topmost != self:
		return
	if not is_instance_valid(control):
		return
	# Don't pull focus away from the on-screen keyboard while it's visible.
	if UIManager and UIManager.is_focus_in_onscreen_keyboard(control):
		return
	# If focus moved outside this overlay's subtree, pull it back to the first
	# focusable child. This prevents controller/gamepad focus from escaping to
	# controls behind the overlay.
	if control == self or control.is_ancestor_of(self) or is_ancestor_of(control):
		return
	_focus_first()

func _focus_first() -> void:
	var first = _find_first_focusable(self)
	if first and first != get_viewport().gui_get_focus_owner():
		if UIManager and UIManager.has_method("suppress_next_focus_sound"):
			UIManager.suppress_next_focus_sound()
		first.grab_focus()

func _find_first_focusable(node: Node) -> Control:
	if node is Control:
		var ctrl := node as Control
		if ctrl.focus_mode != Control.FOCUS_NONE and ctrl.visible:
			return ctrl
	for child in node.get_children():
		var found = _find_first_focusable(child)
		if found:
			return found
	return null

# ============================================
# STATIC HELPERS
# ============================================

static func _get_active_node(type: String) -> M3Overlay:
	if not _active.has(type):
		return null
	var ref = _active[type]
	if ref is WeakRef:
		var node = ref.get_ref()
		if node is M3Overlay and is_instance_valid(node):
			return node
		# Stale entry — clean it up.
		_active.erase(type)
		return null
	return null

static func _set_active_node(type: String, node: M3Overlay) -> void:
	_active[type] = weakref(node)

static func _cleanup_stale_entries() -> void:
	for type in _active.keys():
		_get_active_node(type)

## Return the currently active overlay of the given type, or null.
static func get_active_overlay(type: String) -> M3Overlay:
	return _get_active_node(type)

# ============================================
# PUBLIC API
# ============================================

## Show this overlay, dismissing any existing overlay of the same type.
func show_overlay():
	# Sync CanvasLayer.layer with overlay_layer (subclasses set overlay_layer after _init())
	layer = overlay_layer
	# Dismiss previous of same type
	var previous = _get_active_node(overlay_type)
	if previous != null and previous != self:
		previous.dismiss()
	_set_active_node(overlay_type, self)
	if overlay_layer > _max_layer:
		_max_layer = overlay_layer
	if _restore_focus_on_dismiss:
		_summoner_focus = UIManager.capture_focus() if UIManager else null
	visible = true

## Dismiss this overlay and clean up.
func dismiss():
	var current = _get_active_node(overlay_type)
	if current == self:
		_active.erase(overlay_type)
	# Recalculate max layer if we were the highest
	if overlay_layer >= _max_layer:
		_max_layer = 0
		_cleanup_stale_entries()
		for type in _active.keys():
			var overlay = _get_active_node(type)
			if overlay != null and overlay.overlay_layer > _max_layer:
				_max_layer = overlay.overlay_layer
	# Hide before emitting dismissed so focus callbacks can't pull focus back
	# into this overlay while it's still marked visible.
	visible = false
	dismissed.emit()
	if _restore_focus_on_dismiss:
		if UIManager:
			UIManager.restore_focus(_summoner_focus, _focus_restore_fallback)
	if not persistent:
		queue_free()

## Set an explicit control to restore focus to on dismiss, overriding the
## automatically captured focus owner.
func set_focus_restore_target(control: Control) -> void:
	_summoner_focus = weakref(control) if control != null else null

## Set a fallback callable invoked when the captured focus owner can no longer
## receive focus (freed or hidden).
func set_focus_restore_fallback(fallback: Callable) -> void:
	_focus_restore_fallback = fallback

## Check if this overlay type is currently showing.
static func is_showing(type: String) -> bool:
	return _get_active_node(type) != null

## Dismiss the currently showing overlay of the given type.
static func dismiss_type(type: String):
	var overlay = _get_active_node(type)
	if overlay != null:
		overlay.dismiss()

# Return the topmost active interactive overlay, or null if none.
static func _get_topmost_overlay() -> M3Overlay:
	_cleanup_stale_entries()
	var topmost: M3Overlay = null
	for type in _active.keys():
		var overlay = _get_active_node(type)
		if overlay != null and overlay.visible and (topmost == null or overlay.overlay_layer > topmost.overlay_layer):
			topmost = overlay
	return topmost

# ============================================
# INPUT
# ============================================

func _input(event: InputEvent):
	if not visible:
		return
	if event.is_action_pressed("ui_cancel"):
		# Only dismiss if we're the highest-layer active overlay
		if overlay_layer < _max_layer:
			return
		# Respect dismissible property if present (M3Dialog, M3Sheet, M3Snackbar)
		var dismissible_val = get("dismissible")
		if dismissible_val != null and dismissible_val == false:
			return
		get_viewport().set_input_as_handled()
		dismiss()
		return
