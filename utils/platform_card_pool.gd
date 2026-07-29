class_name PlatformCardPool
extends RefCounted

# Object pool for PlatformCard instances to reduce lag spikes when opening
# screens that create many cards.

## Maximum cards kept in each named pool. Kept conservative for Android.
const MAX_SHUFFLER_POOL_SIZE := 40
const MAX_PLATFORM_POOL_SIZE := 40

## Number of cards to pre-create for each pool at startup.
const PREWARM_PER_POOL := 3

## How many cards to create per process frame during startup warmup.
const PREWARM_BATCH_PER_FRAME := 2

## How many cards to create per process frame during continuous background warmup.
const BACKGROUND_WARM_BATCH_PER_FRAME := 2

const POOL_SHUFFLER := "shuffler"
const POOL_PLATFORM_SETTINGS := "platform_settings"

static var _pools: Dictionary = {}
static var _warmup_remaining: int = 0
static var _warmup_pool_index: int = 0
static var _initialized: bool = false


static func _initialize() -> void:
	if _initialized:
		return
	_initialized = true
	_start_warmup()


static func _start_warmup() -> void:
	var pool_names := _get_pool_names()
	_warmup_remaining = pool_names.size() * PREWARM_PER_POOL


static func _get_pool_names() -> Array[String]:
	return [POOL_SHUFFLER, POOL_PLATFORM_SETTINGS]


## True once the initial prewarm is done and both pools are at target size.
static func is_warm() -> bool:
	if not _initialized:
		return false
	if _warmup_remaining > 0:
		return false
	return _pools.get(POOL_PLATFORM_SETTINGS, []).size() >= MAX_PLATFORM_POOL_SIZE \
		and _pools.get(POOL_SHUFFLER, []).size() >= MAX_SHUFFLER_POOL_SIZE


## Drive background warmup and card creation. Call from a node's _process.
static func process(_delta: float = 0.0) -> void:
	_initialize()
	if _warmup_remaining > 0:
		_warmup_step()
	else:
		_background_warm_step()


static func _warmup_step() -> void:
	var pool_names := _get_pool_names()
	var frames_left := PREWARM_BATCH_PER_FRAME
	while frames_left > 0 and _warmup_remaining > 0:
		var pool_name: String = pool_names[_warmup_pool_index % pool_names.size()]
		var card := PlatformCard.new()
		card.visible = false
		_add_to_pool(pool_name, card)
		_warmup_remaining -= 1
		_warmup_pool_index += 1
		frames_left -= 1


static func _background_warm_step() -> void:
	# Warm platform cards first (they're the laggy screen), then shuffler cards.
	# This runs continuously after the initial prewarm until both pools are full.
	var frames_left := BACKGROUND_WARM_BATCH_PER_FRAME
	while frames_left > 0:
		var target_pool: String = ""
		if _pools.get(POOL_PLATFORM_SETTINGS, []).size() < MAX_PLATFORM_POOL_SIZE:
			target_pool = POOL_PLATFORM_SETTINGS
		elif _pools.get(POOL_SHUFFLER, []).size() < MAX_SHUFFLER_POOL_SIZE:
			target_pool = POOL_SHUFFLER
		if target_pool == "":
			return
		var card := PlatformCard.new()
		card.visible = false
		_add_to_pool(target_pool, card)
		frames_left -= 1


static func _add_to_pool(pool_name: String, card: PlatformCard) -> void:
	if not _pools.has(pool_name):
		_pools[pool_name] = []
	var pool: Array = _pools[pool_name]
	var max_size := MAX_PLATFORM_POOL_SIZE if pool_name == POOL_PLATFORM_SETTINGS else MAX_SHUFFLER_POOL_SIZE
	if pool.size() < max_size:
		pool.append(card)
	else:
		card.queue_free()


## Get a card from the named pool, or create a new one if the pool is empty.
static func get_card(pool_name: String) -> PlatformCard:
	_initialize()
	if not _pools.has(pool_name):
		_pools[pool_name] = []
	var pool: Array = _pools[pool_name]
	if pool.size() > 0:
		var card: PlatformCard = pool.pop_back()
		card.prepare_for_borrow()
		card.visible = true
		return card
	return PlatformCard.new()


## Return a card to the named pool. If the pool is full, the card is freed.
static func return_card(pool_name: String, card: PlatformCard) -> void:
	if card == null or not is_instance_valid(card):
		return
	_initialize()
	card.reset_for_borrow()
	_add_to_pool(pool_name, card)


## Free all pooled cards and reset pool state. Call on shutdown.
static func clear() -> void:
	for pool_name in _pools.keys():
		var pool: Array = _pools[pool_name]
		for card in pool:
			if is_instance_valid(card):
				card.free()
		pool.clear()
	_pools.clear()
	_warmup_remaining = 0
	_warmup_pool_index = 0
	_initialized = false
