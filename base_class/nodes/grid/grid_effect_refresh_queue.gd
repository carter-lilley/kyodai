class_name GridEffectRefreshQueue
extends RefCounted

## Effect-rebuild queue for the grid's cards. Full-grid effect refreshes
## rebuild the visible zone (plus a small buffer) immediately and queue the
## rest, drained a few cards per frame so large grids don't stall. Recycled
## cards are removed from the queue so they don't rebuild after pooling.
## Also owns the "refresh after layout" deferral: effect settings changes are
## applied only once the layout recalc has settled (final card bounds).
## Reads grid state via the backref; never writes it.

const BUFFER_LINES: int = 2
const CARDS_PER_FRAME: int = 2

var _grid: VirtualScrollGridContainer = null

var _pending: Array[Control] = []
var _pending_set: Dictionary = {}  # card -> true (dedup)
var _pending_force_full: bool = false

var _refresh_after_layout: bool = false
var _refresh_after_layout_force_full: bool = false

func _init(grid: VirtualScrollGridContainer) -> void:
	_grid = grid

## Defer an effect refresh until after the next layout recalc so cards are
## rebuilt against final bounds and newly added cards are included.
func request_after_layout(force_full: bool) -> void:
	_refresh_after_layout = true
	_refresh_after_layout_force_full = force_full

## Called after a settled layout recalc; applies a deferred refresh if one
## was requested.
func apply_after_layout() -> void:
	if not _refresh_after_layout:
		return
	_refresh_after_layout = false
	refresh_all(_refresh_after_layout_force_full)

## Single helper for the card visual refresh used by effect/config refresh
## and pending drains. Media bounds are updated inside the card's refresh path.
func refresh_card_visuals(card: Control, force_full_rebuild: bool = false) -> void:
	if not is_instance_valid(card):
		return
	if _grid._card_has_refresh_effects:
		card.refresh_effects(force_full_rebuild)
	elif _grid._card_has_refresh_settings:
		card.refresh_settings()

## Refresh effects on active cards. Cards in the visible zone plus a small
## buffer are rebuilt immediately; the rest are queued and drained over frames
## to avoid stalling on large grids.
func refresh_all(force_full_rebuild: bool = false) -> void:
	# A new full-grid refresh supersedes any still-pending queue.
	_pending.clear()
	_pending_set.clear()
	_pending_force_full = force_full_rebuild

	_grid._get_visible_range()

	var items_per_line = _grid._get_items_per_line()
	var eff = _grid._get_normal_stride()
	var stride_cards: int = items_per_line
	if eff > 0:
		var row_size: int = maxi(items_per_line, 1)
		stride_cards = row_size * BUFFER_LINES

	var sync_start: int = maxi(0, _grid._visible_start_idx - stride_cards)
	var sync_end: int = mini(_grid._visible_end_idx + stride_cards, _grid._total_items)

	for card in _grid._active_cards:
		if not is_instance_valid(card):
			continue
		var idx = card.get_meta("virtual_index", -1)
		var in_sync_zone = idx >= sync_start and idx < sync_end
		if in_sync_zone:
			refresh_card_visuals(card, force_full_rebuild)
		else:
			if not _pending_set.has(card):
				_pending.append(card)
				_pending_set[card] = true

func drain_pending() -> void:
	if _pending.is_empty():
		return

	var force_full_rebuild: bool = _pending_force_full
	var processed: int = 0
	# Not budget-gated: pending effect rebuilds belong to active cards;
	# starving the queue leaves stale/missing effect stacks on screen.
	while processed < CARDS_PER_FRAME and not _pending.is_empty():
		var card = _pending[0]
		_pending.remove_at(0)
		_pending_set.erase(card)
		if not is_instance_valid(card):
			continue
		# Skip cards that are no longer active.
		if not _grid._active_cards.has(card):
			continue
		# Make sure bounds and stack parenting are current before rebuilding;
		# cards that were queued during a layout change can otherwise rebuild
		# against stale/zero media bounds and stay blank.
		refresh_card_visuals(card, force_full_rebuild)
		processed += 1

func flush_for_visible_zone() -> void:
	if _pending.is_empty():
		return

	_grid._get_visible_range()

	var items_per_line = _grid._get_items_per_line()
	var eff = _grid._get_normal_stride()
	var stride_cards: int = items_per_line
	if eff > 0:
		var row_size: int = maxi(items_per_line, 1)
		stride_cards = row_size * BUFFER_LINES

	var sync_start: int = maxi(0, _grid._visible_start_idx - stride_cards)
	var sync_end: int = mini(_grid._visible_end_idx + stride_cards, _grid._total_items)

	var i: int = 0
	while i < _pending.size():
		var card = _pending[i]
		if not is_instance_valid(card):
			_pending.remove_at(i)
			_pending_set.erase(card)
			continue
		if not _grid._active_cards.has(card):
			_pending.remove_at(i)
			_pending_set.erase(card)
			continue
		var idx = card.get_meta("virtual_index", -1)
		if idx >= sync_start and idx < sync_end:
			_pending.remove_at(i)
			_pending_set.erase(card)
			refresh_card_visuals(card, _pending_force_full)
			continue
		i += 1

## Drop a card from the pending queue (recycle paths: a pooled card must not
## rebuild effects after it's returned).
func remove_card(card: Control) -> void:
	if _pending_set.has(card):
		_pending.erase(card)
		_pending_set.erase(card)

## Drop everything (buffer refresh rebuilds the card set from scratch).
func clear_all() -> void:
	_pending.clear()
	_pending_set.clear()
	_refresh_after_layout = false
