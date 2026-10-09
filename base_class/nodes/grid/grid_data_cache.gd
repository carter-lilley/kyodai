class_name GridDataCache
extends RefCounted

## The grid's item-data cache: index → GameResource, with an insertion-ordered
## LRU (count-capped), the in-flight request ledger (offset → limit, mutex-
## guarded for DB worker threads), and duplicate-game tracking.
## Emits items_requested; the grid relays it to views. Stale DB results
## (superseded by jumps/refreshes while the task was in flight) are dropped
## here, before any cover warm or card assignment.

signal items_requested(offset: int, limit: int)

const DEBUG_LOG: bool = false

var _grid: VirtualScrollGridContainer = null

const MAX_SIZE: int = 5000
## Cap batch size: legitimate requests cover one buffer window (a few dozen
## items) or a preload span. Multi-thousand-item queries only ever come from
## a pathological active-set state and can stall the DB worker for seconds.
const MAX_REQUEST_ITEMS: int = 500

var _data: Dictionary = {}                  # idx -> GameResource
var _pending: Dictionary = {}               # offset -> limit
## Guards _pending: DB worker threads check is_load_pending() to skip stale
## queries superseded by jumps/refreshes while they were queued.
var _pending_mutex: Mutex = Mutex.new()
# Deduplication tracking - prevents duplicate game entries
var _game_ids: Dictionary = {}              # romm_id -> cache_key
# Insertion-ordered LRU: front = least recently used, back = most recent.
var _lru_tick: Dictionary[int, bool] = {}

func _init(grid: VirtualScrollGridContainer) -> void:
	_grid = grid

func has_index(idx: int) -> bool:
	return _data.has(idx)

func get_game(idx: int) -> GameResource:
	return _data.get(idx, null)

func size() -> int:
	return _data.size()

func is_index_pending(idx: int) -> bool:
	_pending_mutex.lock()
	for offset in _pending.keys():
		var limit: int = _pending[offset]
		if idx >= offset and idx < offset + limit:
			_pending_mutex.unlock()
			return true
	_pending_mutex.unlock()
	return false

## Thread-safe check used by DB worker tasks to skip queries whose results
## would be discarded anyway (superseded by a jump or buffer refresh).
func is_load_pending(offset: int) -> bool:
	_pending_mutex.lock()
	var pending := _pending.has(offset)
	_pending_mutex.unlock()
	return pending

## Drop pending requests fully outside [range_start, range_end) (the new
## buffer window).
func prune_pending_outside(range_start: int, range_end: int) -> void:
	_pending_mutex.lock()
	var pruned: int = 0
	for offset in _pending.keys():
		var limit: int = _pending[offset]
		# Keep requests that still overlap the new buffer window.
		if offset + limit <= range_start or offset >= range_end:
			_pending.erase(offset)
			pruned += 1
	var remaining: int = _pending.size()
	_pending_mutex.unlock()
	if _grid.trace_verbose:
		if DEBUG_LOG: print("[GridTrace] prune-loads: pruned=", pruned, " remaining=", remaining, " window=", range_start, "-", range_end, " t=", Time.get_ticks_msec())

func request(offset: int, limit: int) -> void:
	var total_items: int = _grid._total_items
	if limit <= 0 or offset < 0 or offset >= total_items:
		return
	limit = mini(limit, MAX_REQUEST_ITEMS)
	limit = mini(limit, total_items - offset)
	if _grid.trace_verbose:
		if DEBUG_LOG: print("[GridTrace] request-data: offset=", offset, " limit=", limit, " t=", Time.get_ticks_msec())
	_pending_mutex.lock()
	_pending[offset] = limit
	_pending_mutex.unlock()
	items_requested.emit(offset, limit)

## Ingest a DB batch. Returns the landed cache keys ([] when the result was
## stale — the request was superseded by a jump or buffer refresh while its
## DB task was in flight — or the batch was empty).
func ingest(items: Array[GameResource], offset: int) -> Array[int]:
	_pending_mutex.lock()
	var was_pending := _pending.has(offset)
	_pending.erase(offset)
	_pending_mutex.unlock()
	if not was_pending or items.is_empty():
		return []

	# Clear deduplication tracking for each batch to avoid false positives
	# when scrolling causes overlapping ranges from the parent view
	_game_ids.clear()

	var duplicates_found: int = 0
	var landed: Array[int] = []

	for i in range(items.size()):
		var cache_key = offset + i
		var game = items[i]

		# Deduplication check: warn if this game ID is already cached at a
		# different index but still cache it at the new index so cards get
		# their data
		if game and game.romm_id != 0:
			if _game_ids.has(game.romm_id):
				var existing_key = _game_ids[game.romm_id]
				# Stale mapping check: evicted or replaced game at existing_key
				if not _data.has(existing_key) or _data[existing_key] != game:
					_game_ids.erase(game.romm_id)
				elif existing_key != cache_key:
					duplicates_found += 1
					push_warning("[GridDataCache] Duplicate game detected: '%s' (romm_id: %d) at indices %d and %d" % [game.title, game.romm_id, existing_key, cache_key])
			else:
				_game_ids[game.romm_id] = cache_key

		if _data.size() >= MAX_SIZE and not _data.has(cache_key):
			evict_oldest(items.size())

		_data[cache_key] = game
		touch(cache_key)
		landed.append(cache_key)

	if duplicates_found > 0:
		push_warning("[GridDataCache] Found %d duplicate game(s) in batch starting at offset %d" % [duplicates_found, offset])

	return landed

func touch(cache_key: int) -> void:
	# Dictionary preserves insertion order: erase + re-insert moves the key to
	# the back (most recently used), keeping eviction O(1).
	_lru_tick.erase(cache_key)
	_lru_tick[cache_key] = true

func evict_oldest(count: int) -> void:
	var to_evict = mini(count, _data.size())
	if to_evict <= 0:
		return

	# Front of the insertion-ordered LRU is the least recently used entry.
	var evicted := 0
	for oldest_key in _lru_tick.keys():
		if evicted >= to_evict:
			break
		_lru_tick.erase(oldest_key)
		if _data.has(oldest_key):
			var game = _data[oldest_key]
			if game and game.romm_id != 0:
				_game_ids.erase(game.romm_id)
			_data.erase(oldest_key)
		evicted += 1

func update_game(game: GameResource) -> void:
	if game == null:
		return
	for key in _data:
		var cached = _data[key]
		if cached and cached is GameResource and cached.romm_id == game.romm_id:
			_data[key] = game

func clear() -> void:
	_data.clear()
	_game_ids.clear()
	_lru_tick.clear()
	_pending_mutex.lock()
	_pending.clear()
	_pending_mutex.unlock()
