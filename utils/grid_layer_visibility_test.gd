## Regression test for the view-switch ghosting bug:
## the grid's top_level visual layer must hide with its owning view.
##
## Background: the layer is top_level, so its canvas item is re-rooted to the
## viewport canvas — engine scene-tree visibility propagation is the ONLY
## thing that hides it. That propagation only recurses into CanvasItem
## children (CanvasItem._handle_visibility_change), so when the layer lived
## under GridVisualSync (a plain Node) it stayed visible forever after a tab
## hide, leaving the last stamped card art frozen behind the shown view.
##
## Asserts (all pure scene state, no rendering needed):
##  1. The layer is a direct child of the grid (CanvasItem propagation path).
##  2. Hiding the grid's ancestor hides the layer (is_visible_in_tree false).
##  3. Re-showing restores it.
## Run: godot --headless --path . res://utils/grid_layer_visibility_test.tscn
## (scene-based so autoloads register before grid scripts compile)
extends Node

var _failures := 0
var _grid: VirtualScrollGridContainer
var _items: Array = []

func _make_game(i: int) -> GameResource:
	var g := GameResource.new()
	g.id = "test-%d" % i
	g.romm_id = i
	g.title = "Game %d" % i
	g.platform = "Test"
	return g

func _check(cond: bool, label: String) -> void:
	if cond:
		print("OK   ", label)
	else:
		_failures += 1
		print("FAIL ", label)

func _ready() -> void:
	for i in 5:
		await get_tree().process_frame

	get_tree().root.size = Vector2i(1600, 900)
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	get_tree().root.add_child(host)

	_grid = VirtualScrollGridContainer.new()
	host.add_child(_grid)

	for i in 100:
		_items.append(_make_game(i))

	_grid.items_requested.connect(func(offset: int, limit: int):
		var batch: Array[GameResource] = []
		for i in range(offset, mini(offset + limit, _items.size())):
			batch.append(_items[i])
		_grid.on_items_loaded(batch, offset, false)
	)

	VirtualScrollGridContainer.startup_layout_suppressed = false
	var card_scene: PackedScene = load("res://components/cards/game_card.tscn")
	_grid.setup(card_scene, _items.size())
	_grid.size = Vector2(1600, 900)
	for i in 10:
		await get_tree().process_frame

	var layer := _grid._visual_sync.layer
	_check(layer != null, "visual layer exists")
	_check(layer.get_parent() == _grid, "layer is a direct child of the grid (CanvasItem propagation path)")
	_check(layer.top_level, "layer is top_level (unclipped overflow drawing)")
	_check(_grid._active_cards.size() > 0, "grid has active cards (got %d)" % _grid._active_cards.size())
	_check(layer.is_visible_in_tree(), "layer visible while grid visible")

	# Simulate the view manager hiding this view's tab.
	host.visible = false
	for i in 2:
		await get_tree().process_frame
	_check(not _grid.is_visible_in_tree(), "grid reports hidden after host hide")
	_check(not layer.is_visible_in_tree(), "layer hidden after host hide")

	# Re-show (switching back to the tab).
	host.visible = true
	for i in 2:
		await get_tree().process_frame
	_check(layer.is_visible_in_tree(), "layer visible again after host show")

	if _failures == 0:
		print("GRID LAYER VISIBILITY TEST PASSED")
	else:
		print("GRID LAYER VISIBILITY TEST FAILED: ", _failures)
	get_tree().quit(_failures)
