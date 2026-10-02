class_name ThemeSubManager
extends Manager

var ui_manager: Node

var _theme_refresh_pending: bool = false
var _preset_in_progress: bool = false
var _tab_container: TabContainer = null

## Full-tree refresh walks cost hundreds of ms at startup (every M3 control
## rebakes sizes/styles). During the startup window they are split into
## per-frame chunks so they spread across frames instead of hitching boot;
## in steady state they run synchronously exactly as before.
const WALK_CHUNK_US := 5000
const WALK_SCALE := 1
const WALK_THEME := 2
var _walk_queued: int = 0
var _walk_running: bool = false

func _ready():
	ui_manager = get_parent()

func setup(tab_container: TabContainer) -> void:
	_tab_container = tab_container
	_setup_library_appearance()

func _setup_library_appearance() -> void:
	"""Make the TabContainer panel transparent so the LibraryBackground shows through."""
	if not _tab_container:
		return
	var transparent_style := StyleBoxFlat.new()
	transparent_style.bg_color = Color(0, 0, 0, 0)
	transparent_style.border_color = Color(0, 0, 0, 0)
	transparent_style.border_width_bottom = 0
	transparent_style.border_width_left = 0
	transparent_style.border_width_right = 0
	transparent_style.border_width_top = 0
	_tab_container.add_theme_stylebox_override("panel", transparent_style)

func _apply_dark_mode(enabled: bool) -> void:
	# Skip the full-tree walk when the mode isn't actually changing: nodes bake
	# M3Theme values at build time, so an unchanged value can't leave staleness.
	if M3Theme.is_dark_mode == enabled:
		return
	M3Theme.is_dark_mode = enabled
	if not _theme_refresh_pending:
		_theme_refresh_pending = true
		call_deferred("_do_refresh_theme")

func _do_refresh_theme() -> void:
	_theme_refresh_pending = false
	var saved_focus: WeakRef = ui_manager.capture_focus() if ui_manager else null
	if WarmupBudget.is_startup_mode():
		_queue_walk(WALK_THEME)
	else:
		_refresh_theme_on_all_nodes(get_tree().root)
	if ui_manager:
		ui_manager.restore_focus(saved_focus, ui_manager.get_focus_restore_fallback_to_home())
	# Theme refresh resets stylebox overrides; restore TabContainer transparency
	# so the library background remains visible.
	_setup_library_appearance()

func _refresh_theme_on_all_nodes(node: Node) -> void:
	if node == self:
		return
	if node.has_method("refresh_theme"):
		node.refresh_theme()
	for child in node.get_children():
		_refresh_theme_on_all_nodes(child)

func _do_refresh_scale() -> void:
	var saved_focus: WeakRef = ui_manager.capture_focus() if ui_manager else null
	if WarmupBudget.is_startup_mode():
		_queue_walk(WALK_SCALE)
	else:
		_refresh_scale_on_all_nodes(get_tree().root)
	if ui_manager:
		ui_manager.restore_focus(saved_focus, ui_manager.get_focus_restore_fallback_to_home())

func _refresh_scale_on_all_nodes(node: Node) -> void:
	if node == self:
		return
	if node.has_method("refresh_scale"):
		node.refresh_scale()
	elif node.has_method("refresh_theme"):
		node.refresh_theme()
	for child in node.get_children():
		_refresh_scale_on_all_nodes(child)

## Startup path: serialize scale/theme walks through one chunked driver so two
## walks can't interleave on the same nodes. Focus capture/restore stays with
## the caller (same timing as the old synchronous walk).
func _queue_walk(kind: int) -> void:
	_walk_queued |= kind
	if _walk_running:
		return
	_walk_running = true
	_run_queued_walks()

func _run_queued_walks() -> void:
	while _walk_queued != 0:
		var kinds := _walk_queued
		_walk_queued = 0
		for kind: int in [WALK_SCALE, WALK_THEME]:
			if kinds & kind:
				var walk_start_us := Time.get_ticks_usec()
				var visited := await _walk_tree_chunked(kind)
				print("[ThemeManager] startup ", ("scale" if kind == WALK_SCALE else "theme"),
						" walk nodes=", visited, " elapsed_us=", Time.get_ticks_usec() - walk_start_us)
	_walk_running = false

## Depth-first preorder walk of the whole tree in time-bounded chunks. Nodes
## are validity-checked per pop: frames elapse between chunks and the tree can
## change while a walk is in flight.
func _walk_tree_chunked(kind: int) -> int:
	var label := "scale_walk" if kind == WALK_SCALE else "theme_walk"
	var visited := 0
	var chunk_start_us := Time.get_ticks_usec()
	WarmupBudget.tag(label)
	var stack: Array[Node] = [get_tree().root]
	while not stack.is_empty():
		# Pop untyped and validate BEFORE the typed assignment: nodes freed by
		# rebuilds between chunks are still in the stack, and assigning a
		# freed instance to a typed Node var raises a script error.
		var item: Variant = stack.pop_back()
		if not is_instance_valid(item) or item == self:
			continue
		var node := item as Node
		if kind == WALK_SCALE:
			if node.has_method("refresh_scale"):
				node.refresh_scale()
			elif node.has_method("refresh_theme"):
				node.refresh_theme()
		elif node.has_method("refresh_theme"):
			node.refresh_theme()
		visited += 1
		var children := node.get_children()
		for i in range(children.size() - 1, -1, -1):
			stack.append(children[i])
		if Time.get_ticks_usec() - chunk_start_us >= WALK_CHUNK_US:
			var tree := get_tree()
			if tree == null:
				return visited
			await tree.process_frame
			chunk_start_us = Time.get_ticks_usec()
			WarmupBudget.tag(label)
	return visited

func refresh_theme() -> void:
	_do_refresh_theme()

func _request_theme_refresh() -> void:
	if not _theme_refresh_pending:
		_theme_refresh_pending = true
		# During a preset the individual setting_changed handlers will request
		# refreshes; coalesce them into one refresh at preset end.
		if not _preset_in_progress:
			call_deferred("_do_refresh_theme")

func _trigger_refresh_if_pending() -> void:
	if _theme_refresh_pending:
		call_deferred("_do_refresh_theme")

func _on_apply_preset_begin() -> void:
	_preset_in_progress = true

func _on_apply_preset_end() -> void:
	_preset_in_progress = false
	# Coalesce any theme-refresh requests that accumulated during the preset
	# into a single deferred tree walk.
	_trigger_refresh_if_pending()
