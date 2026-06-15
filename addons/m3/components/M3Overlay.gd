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
	dismissed.emit()
	visible = false
	if not persistent:
		queue_free()

## Check if this overlay type is currently showing.
static func is_showing(type: String) -> bool:
	return _get_active_node(type) != null

## Dismiss the currently showing overlay of the given type.
static func dismiss_type(type: String):
	var overlay = _get_active_node(type)
	if overlay != null:
		overlay.dismiss()

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
