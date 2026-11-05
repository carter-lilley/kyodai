class_name EffectCompositor
extends RefCounted

## Owns one optional interior-composition surface. The group is a sibling of
## the ordinary media canvas item, never a child whose inherited transform can
## diverge from the grid's render-fresh media transform.

var _group: CanvasGroup = null
var _material: ShaderMaterial = null

func attach(host: CanvasItem) -> void:
	if is_instance_valid(_group):
		return
	_group = CanvasGroup.new()
	_group.name = "EffectCompositor"
	_group.fit_margin = 1.0
	_group.clear_margin = 1.0
	_group.use_mipmaps = false
	_material = ShaderMaterial.new()
	_material.shader = preload("res://shaders/card/compositor_mask.gdshader")
	_group.material = _material
	host.add_child(_group)

func sync(transform: Transform2D, parent_rid: RID, size: Vector2, radius: float, draw_index: int) -> void:
	if not is_instance_valid(_group):
		return
	var rid := _group.get_canvas_item()
	RenderingServer.canvas_item_set_parent(rid, parent_rid)
	RenderingServer.canvas_item_set_transform(rid, transform)
	RenderingServer.canvas_item_set_draw_index(rid, draw_index)
	# An explicit media-local command avoids automatic child-bound fitting,
	# which can retain a stale origin during layout/theme transitions.
	RenderingServer.canvas_item_clear(rid)
	RenderingServer.canvas_item_add_rect(rid, Rect2(Vector2(-1.0, -1.0), size + Vector2(2.0, 2.0)), Color.WHITE)
	if _material:
		_material.set_shader_parameter("card_size", size)
		_material.set_shader_parameter("corner_radius_pixels", radius)

func get_canvas_item() -> RID:
	return _group.get_canvas_item() if is_instance_valid(_group) else RID()

func set_visible(value: bool) -> void:
	if is_instance_valid(_group):
		_group.visible = value

func free_rids() -> void:
	if is_instance_valid(_group):
		_group.queue_free()
	_group = null
	_material = null
