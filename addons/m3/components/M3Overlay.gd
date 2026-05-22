class_name M3Overlay
extends CanvasLayer

## Base class for M3 overlay components (dialogs, menus, snackbars).
## Provides singleton-per-type behavior, standard dismissal, and lifecycle management.

# ============================================
# STATIC REGISTRY
# ============================================

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
# PUBLIC API
# ============================================

## Show this overlay, dismissing any existing overlay of the same type.
func show_overlay():
	# Sync CanvasLayer.layer with overlay_layer (subclasses set overlay_layer after _init())
	layer = overlay_layer
	# Dismiss previous of same type
	if _active.has(overlay_type) and is_instance_valid(_active[overlay_type]) and _active[overlay_type] != self:
		_active[overlay_type].dismiss()
	_active[overlay_type] = self
	if overlay_layer > _max_layer:
		_max_layer = overlay_layer
	visible = true

## Dismiss this overlay and clean up.
func dismiss():
	if _active.get(overlay_type) == self:
		_active.erase(overlay_type)
	# Recalculate max layer if we were the highest
	if overlay_layer >= _max_layer:
		_max_layer = 0
		for overlay in _active.values():
			if is_instance_valid(overlay) and overlay.overlay_layer > _max_layer:
				_max_layer = overlay.overlay_layer
	dismissed.emit()
	visible = false
	if not persistent:
		queue_free()

## Check if this overlay type is currently showing.
static func is_showing(type: String) -> bool:
	return _active.has(type) and is_instance_valid(_active[type])

## Dismiss the currently showing overlay of the given type.
static func dismiss_type(type: String):
	if _active.has(type) and is_instance_valid(_active[type]):
		_active[type].dismiss()

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
