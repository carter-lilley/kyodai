class_name GridFocusController
extends RefCounted

## Focus domain for VirtualScrollGridContainer: tracks the focused card's
## virtual index across recalcs, owns the focus-lock viewport connection
## (via the FocusSubManager hub, which survives dual-screen reparents),
## implements focus restore/release, and owns controller navigation
## (navigate_direction + compute_target_index). The grid keeps facades only
## for its public API (navigate_direction, restore_focus_to_index,
## focus_last_or_first_card, get_focused_virtual_index, refresh_focus_lock).

var _grid: VirtualScrollGridContainer = null

## Last focused card's virtual index — restored after layout recalculations.
var last_index: int = -1
## Monotonically-increasing ID used to cancel stale deferred-focus requests.
var request_id: int = 0
## Pending focus target set by scroll_to_index_and_focus; applied as soon as
## the card is created by the scroll pass.
var pending_index: int = -1

func _init(grid: VirtualScrollGridContainer) -> void:
	_grid = grid

func focused_virtual_index() -> int:
	var viewport := _grid.get_viewport()
	if not is_instance_valid(viewport):
		return -1
	var focused := viewport.gui_get_focus_owner()
	if not focused or not _grid.is_ancestor_of(focused):
		return -1
	var node := focused
	while node != _grid:
		if node.has_meta("virtual_index"):
			return node.get_meta("virtual_index", -1)
		node = node.get_parent()
	return -1

func connect_viewport() -> void:
	# Hub connection: FocusSubManager re-emits the UI viewport's focus changes,
	# so this survives dual-screen reparents without reconnecting.
	var hub := FocusSubManager.get_instance()
	if not hub:
		return
	if not hub.ui_focus_changed.is_connected(on_viewport_focus_changed):
		hub.ui_focus_changed.connect(on_viewport_focus_changed)

func disconnect_viewport() -> void:
	var hub := FocusSubManager.get_instance()
	if hub and hub.ui_focus_changed.is_connected(on_viewport_focus_changed):
		hub.ui_focus_changed.disconnect(on_viewport_focus_changed)

func reconnect_viewport() -> void:
	disconnect_viewport()
	connect_viewport()

func on_viewport_focus_changed(control: Control) -> void:
	if not control:
		return

	# Check if focus moved to a card inside this grid.
	if _grid.is_ancestor_of(control):
		var node = control
		while node != _grid:
			if node.has_meta("virtual_index"):
				last_index = node.get_meta("virtual_index", -1)
				break
			node = node.get_parent()
		# Tell UIManager to lock focus to this grid.
		if UIManager:
			UIManager.enter_focus_lock(_grid)
		return

	# Focus is outside this grid.
	if UIManager:
		UIManager.exit_focus_lock(_grid)

## Public focus-restore entry point: focus the card for `index` without
## scrolling, with follow-focus suppression handled internally. No-op when the
## card isn't in the buffer or isn't focusable.
func restore_focus_to_index(index: int) -> void:
	var card := _grid.get_card_at_index(index)
	if not card or not is_instance_valid(card) or not card.is_inside_tree():
		return
	if card is Control and card.focus_mode != Control.FOCUS_NONE:
		apply_focus_to_card(card)

## Re-grab focus on the card for `index` without changing the scroll
## position. Used after layout recalcs, where the scroll anchor already
## positioned the focused card. Falls back to the pending-focus path (applied
## by the next scroll rebuild) if the card hasn't been created yet.
func restore_focus_only(index: int) -> void:
	if not _grid.is_inside_tree():
		return
	var card := _grid.get_card_at_index(index)
	if card and is_instance_valid(card) and card.is_inside_tree():
		apply_focus_to_card(card)
	else:
		pending_index = index

## Focus a card and suppress the container's follow-focus auto-scroll.
## We intentionally do NOT stop an in-flight smooth scroll here: this helper is
## used by scroll-to-focus paths that already started a centered scroll, and
## interrupting it leaves offscreen targets sitting at the viewport edge.
func apply_focus_to_card(card: Control) -> void:
	if not window_has_focus():
		# Backgrounded (e.g. a shuffler session): grabbing focus would fire
		# focus_entered SFX/vibration nobody can see. Keep the target pending;
		# NOTIFICATION_WM_WINDOW_FOCUS_IN restores it when the user returns.
		var idx := int(card.get_meta("virtual_index", -1))
		if idx >= 0:
			pending_index = idx
		return
	card.set_meta("_suppress_smooth_scroll", true)
	SmoothScrollContainer._strace("focus-card idx=" + str(card.get_meta("virtual_index", -1)))
	card.grab_focus()
	pending_index = -1

## Focus the last focused card, or the first card if none was focused.
func focus_last_or_first_card() -> void:
	if not window_has_focus():
		return
	var card = _grid.get_card_at_index(last_index)
	if not card or not is_instance_valid(card) or not card.is_inside_tree():
		card = _grid.get_card_at_index(0)
	if card and is_instance_valid(card) and card.is_inside_tree():
		card.grab_focus()

## Release focus if the current focus owner is inside the given card.
func release_focus_if_inside(card: Control) -> void:
	var viewport := _grid.get_viewport()
	if not is_instance_valid(viewport):
		return
	var focused := viewport.gui_get_focus_owner()
	if focused and (focused == card or card.is_ancestor_of(focused)):
		viewport.gui_release_focus()
		# gui_focus_changed ignores the null owner, so the lock taken when the
		# card was focused would persist with no focus owner (swallowing input)
		# if the deferred focus restore fails. Release it; the restore re-locks.
		if UIManager:
			UIManager.exit_focus_lock(_grid)

## Release focus if it currently belongs to any card inside this grid.
func release_focus_inside_grid() -> void:
	var viewport := _grid.get_viewport()
	if not is_instance_valid(viewport):
		return
	var focused := viewport.gui_get_focus_owner()
	if focused and _grid.is_ancestor_of(focused):
		viewport.gui_release_focus()

func window_has_focus() -> bool:
	var w := _grid.get_window()
	return w == null or w.has_focus()

## Focus the pending card if it has been created by the latest scroll.
func try_apply_pending_focus() -> void:
	if pending_index < 0:
		return
	var card := _grid.get_card_at_index(pending_index)
	if card and is_instance_valid(card) and card.is_inside_tree():
		apply_focus_to_card(card)

## Move focus one step in the given direction. Returns true if the event was
## consumed (including at boundaries, so focus cannot leave the grid).
func navigate_direction(dir: String, from_index: int = -1) -> bool:
	if not _grid.visible or not _grid.is_inside_tree():
		return false
	if not UIManager or not UIManager.controller_has_priority():
		return false

	var row_delta := 0
	var col_delta := 0
	match dir:
		"ui_up":
			row_delta = -1
		"ui_down":
			row_delta = 1
		"ui_left":
			col_delta = -1
		"ui_right":
			col_delta = 1
		_:
			return false

	# For horizontal grids the "line" runs top-to-bottom, so swap axis meaning
	# so left/right always move along the line and up/down move between lines.
	if not _grid.vertical:
		var tmp := row_delta
		row_delta = col_delta
		col_delta = tmp

	var current_idx := from_index if from_index >= 0 else focused_virtual_index()
	if current_idx < 0:
		return false

	var target_idx := compute_target_index(current_idx, row_delta, col_delta)
	if target_idx < 0 or target_idx == current_idx:
		# Boundary: consume the event so focus cannot leave the grid.
		return true

	# Route visible and offscreen targets through the same scroll-and-focus path
	# so behavior is consistent; the centering mode decides whether a visible
	# target triggers any scroll at all.
	_grid.scroll_to_index_and_focus(target_idx, true)
	return true

## Compute the target virtual index from a 2D row/column delta.
##
## For vertical grids a "row" is a horizontal line and the column is the
## intra-line index. For horizontal grids a "row" is a vertical line and the
## column is the intra-line index. This lets left/right navigate within a
## line and up/down navigate between lines regardless of orientation.
func compute_target_index(current_idx: int, row_delta: int, col_delta: int) -> int:
	var source_total: int = _grid._source_total_items
	if source_total <= 0 or current_idx < 0 or current_idx >= source_total:
		return -1

	var items_per_line := _grid._get_items_per_line()
	if items_per_line <= 0:
		items_per_line = 1

	# LIST/CAROUSEL: simple linear movement.
	if _grid.view_mode == VirtualScrollGridContainer.ViewMode.LIST or _grid.view_mode == VirtualScrollGridContainer.ViewMode.CAROUSEL or items_per_line == 1:
		var target := current_idx + row_delta + col_delta
		return clamp(target, 0, source_total - 1)

	if _grid._is_staggered_active():
		var line := _grid._get_stagger_line_for_index(current_idx)
		var col := current_idx - _grid._get_stagger_first_index_for_line(line)
		var total_lines := _grid._get_stagger_line_for_index(source_total - 1) + 1
		# Horizontal moves stay on the current row, bounded by its capacity.
		if row_delta == 0 and col_delta != 0:
			var target_col_h := col + col_delta
			if target_col_h < 0 or target_col_h >= _grid._get_stagger_line_capacity(line):
				return -1
			var target_idx_h := _grid._get_stagger_first_index_for_line(line) + target_col_h
			if target_idx_h >= source_total:
				return -1
			return target_idx_h
		var target_line := line + row_delta
		if target_line < 0 or target_line >= total_lines:
			return -1
		# Vertical moves keep the column index, clamped to the target row's
		# capacity (offset rows hold one fewer card).
		var target_col := mini(col, _grid._get_stagger_line_capacity(target_line) - 1)
		var target_idx := _grid._get_stagger_first_index_for_line(target_line) + target_col
		# Placeholder slots (idx >= source count) are not navigation targets.
		if target_idx >= source_total:
			return -1
		return target_idx

	var line := int(current_idx / float(items_per_line))
	var col := current_idx % items_per_line
	var total_lines := ceili(float(source_total) / items_per_line)

	var target_line := line + row_delta
	var target_col := col + col_delta

	if target_line < 0 or target_line >= total_lines:
		return -1
	if target_col < 0 or target_col >= items_per_line:
		return -1

	var target_idx := target_line * items_per_line + target_col
	# Placeholder slots (idx >= source count) are not navigation targets.
	if target_idx >= source_total:
		return -1
	return target_idx
