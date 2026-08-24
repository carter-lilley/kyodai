class_name ShaderPrewarmer
extends RefCounted

## Forces GPU pipeline compilation for all bundled canvas-item shaders at
## startup. Godot compiles pipelines lazily on first draw, so without this the
## first grid paint, first scroll, and first focus each pay a compile hitch
## per shader. Every shader is drawn once into a tiny hidden SubViewport, one
## per frame so the prewarm never stalls the startup critical path.

const SCAN_DIRS := ["res://shaders", "res://addons/m3/shaders"]

static func collect_shader_paths() -> Array[String]:
	var paths: Array[String] = []
	for dir_path in SCAN_DIRS:
		_collect_dir(dir_path, paths)
	paths.sort()
	return paths

static func _collect_dir(dir_path: String, out: Array[String]) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if dir.current_is_dir():
			_collect_dir(dir_path.path_join(entry), out)
		elif entry.ends_with(".gdshader"):
			out.append(dir_path.path_join(entry))
		entry = dir.get_next()
	dir.list_dir_end()

static func prewarm(tree: SceneTree) -> void:
	var start_us := Time.get_ticks_usec()
	var paths := collect_shader_paths()
	if paths.is_empty():
		return

	var viewport := SubViewport.new()
	viewport.name = "ShaderPrewarmer"
	viewport.size = Vector2i(8, 8)
	viewport.transparent_bg = true
	viewport.gui_disable_input = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	tree.root.add_child(viewport)

	var compiled := 0
	for path in paths:
		# Pipeline compilation is a frame-time spike by nature; skip frames
		# where the warmup budget is already spent so compiles never stack
		# onto grid settle or scroll work.
		while not WarmupBudget.try_spend(WarmupBudget.COST_SHADER_PREWARM_US):
			await tree.process_frame
		var shader: Shader = load(path)
		if shader == null:
			continue
		var material := ShaderMaterial.new()
		material.shader = shader
		var rect := ColorRect.new()
		rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		rect.material = material
		viewport.add_child(rect)
		# UPDATE_ONCE renders on the next frame, then disables again.
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		await tree.process_frame
		rect.queue_free()
		compiled += 1

	viewport.queue_free()
	print("[ShaderPrewarmer] compiled %d shader pipelines, elapsed_us=%d" % [compiled, Time.get_ticks_usec() - start_us])
