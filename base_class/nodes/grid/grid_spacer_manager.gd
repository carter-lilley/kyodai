class_name GridSpacerManager
extends RefCounted

## Owns the spacer lifecycle inside the grid's FlowContainer: page spacers
## (full-line blanks that force the wrap between pages, GRID mode pagination)
## and stagger spacers (half-cell indents at the start of odd rows). All
## boundary math (page composition, stagger lines, gap sizes) lives in
## GridGeometry — this module only creates/places/removes the plain Controls.
## Invariants: "a page spacer sits between every pair of consecutive cards
## that crosses a page boundary" and "a stagger spacer immediately precedes
## the first card of every odd row present in the flow; none elsewhere."
## Reads grid state via the backref; never writes it.

var _grid: VirtualScrollGridContainer = null

func _init(grid: VirtualScrollGridContainer) -> void:
	_grid = grid

func make_page_spacer() -> Control:
	var spacer := Control.new()
	spacer.set_meta("page_spacer", true)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.focus_mode = Control.FOCUS_NONE
	spacer.custom_minimum_size = page_spacer_size()
	return spacer

## Spacer dimensions: full line on the cross axis (forces the wrap). The
## scroll-axis extent is gap - separation because the FlowContainer adds its
## own line separation after the spacer line.
func page_spacer_size() -> Vector2:
	var extent = maxf(1.0, _grid._get_page_gap() - _grid.grid_separation)
	var items_per_line = maxi(1, _grid._get_items_per_line())
	if _grid.vertical:
		var row_width = items_per_line * _grid.card_size.x + max(0, items_per_line - 1) * _grid.grid_separation
		return Vector2(row_width, extent)
	var col_height = items_per_line * _grid.card_size.y + max(0, items_per_line - 1) * _grid.grid_separation
	return Vector2(extent, col_height)

func add_page_spacer(flow_index: int = -1) -> void:
	if not _grid._flow_container:
		return
	var spacer = make_page_spacer()
	_grid._flow_container.add_child(spacer)
	if flow_index >= 0:
		_grid._flow_container.move_child(spacer, flow_index)

func free_spacer(spacer: Control) -> void:
	_grid._flow_container.remove_child(spacer)
	spacer.queue_free()

## Removes any leading/trailing spacers (recycling is contiguous from the
## ends, so orphaned spacers can only ever appear at the edges).
func prune_edges() -> void:
	if not _grid._flow_container:
		return
	var flow := _grid._flow_container
	while flow.get_child_count() > 0:
		var first = flow.get_child(0)
		if first.has_meta("page_spacer"):
			free_spacer(first)
			continue
		if first.has_meta("stagger_spacer"):
			# A leading stagger spacer stays LIVE while any card of its odd row
			# still follows it: partial rows keep their half-cell indent while
			# the window recycles through them. Only a spacer whose row is fully
			# gone (next child is a spacer, an even-row card, or nothing) dies.
			var next = flow.get_child(1) if flow.get_child_count() > 1 else null
			if next and not next.has_meta("page_spacer") and not next.has_meta("stagger_spacer"):
				var next_idx: int = next.get_meta("virtual_index", -1)
				if next_idx >= 0 and _grid._is_staggered_active() and _grid._get_stagger_line_for_index(next_idx) % 2 == 1:
					break
			free_spacer(first)
			continue
		break
	while flow.get_child_count() > 0:
		var last = flow.get_child(flow.get_child_count() - 1)
		if last.has_meta("page_spacer") or last.has_meta("stagger_spacer"):
			free_spacer(last)
		else:
			break

func clear_all() -> void:
	if not _grid._flow_container:
		return
	for child in _grid._flow_container.get_children():
		if child.has_meta("page_spacer") or child.has_meta("stagger_spacer"):
			_grid._flow_container.remove_child(child)
			child.queue_free()

# --- Stagger spacers --------------------------------------------------------
# Half-cell spacers at the start of odd rows force the FlowContainer to wrap
# offset rows at N-1 cards and indent them half a stride.

func make_stagger_spacer() -> Control:
	var spacer := Control.new()
	spacer.set_meta("stagger_spacer", true)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.focus_mode = Control.FOCUS_NONE
	spacer.custom_minimum_size = stagger_spacer_size()
	return spacer

## Half a cell minus the separation the flow inserts after the spacer, so the
## odd row's first card lands exactly half a stride to the right.
func stagger_spacer_size() -> Vector2:
	var w = maxf(1.0, (_grid.card_size.x - _grid.grid_separation) / 2.0)
	return Vector2(w, _grid.card_size.y)

func add_stagger_spacer(flow_index: int = -1) -> void:
	if not _grid._flow_container:
		return
	var spacer = make_stagger_spacer()
	_grid._flow_container.add_child(spacer)
	if flow_index >= 0:
		_grid._flow_container.move_child(spacer, flow_index)

## True when idx is the first item of an odd (offset) row.
func is_stagger_row_opener(idx: int) -> bool:
	if not _grid._is_staggered_active() or idx < 0:
		return false
	var line := _grid._get_stagger_line_for_index(idx)
	return line % 2 == 1 and idx == _grid._get_stagger_first_index_for_line(line)

## Rebuilds spacer placement from scratch after a layout recalc. Zoom, resize,
## and orientation changes move every page boundary at once, so incremental
## spacer maintenance cannot keep up; this clears all spacers and re-inserts
## them wherever consecutive cards cross a boundary under the CURRENT page
## composition. Cheap (a handful of plain Controls) and idempotent.
func reconcile() -> void:
	if not _grid._flow_container:
		return
	clear_all()
	var cards := _grid._active_cards
	var paginate := _grid._is_pagination_active() and cards.size() >= 2
	var stagger := _grid._is_staggered_active() and not cards.is_empty()
	if not paginate and not stagger:
		return
	# Flow children are now exactly _active_cards in order; walk the run and
	# insert spacers at page boundaries and odd-row openers (stagger). When a
	# card opens both (tiny pages), the page spacer comes FIRST: it owns a
	# whole line, and the stagger spacer must stay attached to its row's cards.
	var flow_pos := 0
	for i in range(cards.size()):
		var idx: int = cards[i].get_meta("virtual_index", -1)
		if i > 0 and paginate:
			var prev_idx: int = cards[i - 1].get_meta("virtual_index", -1)
			if prev_idx >= 0 and idx >= 0 and _grid._get_page_for_index(idx) != _grid._get_page_for_index(prev_idx):
				add_page_spacer(flow_pos)
				flow_pos += 1
		if idx >= 0 and stagger and is_stagger_row_opener(idx):
			add_stagger_spacer(flow_pos)
			flow_pos += 1
		flow_pos += 1
