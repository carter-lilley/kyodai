class_name CardMediaLoader
extends RefCounted

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

## Loads and caches cover art for a GameCard.
##
## Owned by GameCard. Encapsulates image download, cache lookup, retry logic,
## and texture lifetime so GameCard doesn't mix cover-loading code with input,
## focus, and badge logic.

signal texture_loaded(texture: Texture2D)

var _card: GameCard = null
var _loading_game_id: String = ""
var _image_retry_count: int = 0
var _current_image_task_id: int = -1
var _download_retry_count: int = 0
var _drop_retry_count: int = 0
var _current_download_id: int = 0

const MAX_IMAGE_RETRIES: int = 3
const MAX_DOWNLOAD_RETRIES: int = 2
# Backpressure (DROPPED) retries: bounded with a short delay so a viewport
# settled after a scroll storm self-heals once the queue drains, without
# hammering a full queue forever.
const MAX_DROP_RETRIES: int = 5
const DROP_RETRY_DELAY_SEC: float = 1.0
## Fallback decode size when the card's rendered pixel size isn't known yet
## (pre-layout). Covers decode at the card's ACTUAL pixel size (bucketed) so a
## 4K grid of 6 cards gets ~1K textures, not blurry 512px ones (Playnite's
## decode-to-card-size policy).
const MAX_COVER_TEXTURE_SIZE: int = 512
## Decode sizes are rounded up to this bucket so smooth zoom/resize doesn't
## mint a new cache key per pixel step.
const DECODE_SIZE_BUCKET: int = 128
const DECODE_SIZE_MIN: int = 256
const DECODE_SIZE_MAX: int = 2048
## Known-missing negative cache TTL (Argosy's MissingArtRegistry policy):
## a cover URL that failed is not retried for a day, so scrolling back and
## forth over games with dead art doesn't re-attempt the download every pass.
const FAILURE_RETRY_TTL_SEC: int = 86400
# Bound the static failure-TTL map so permanently-failing URLs don't grow it forever.
const MAX_FAILED_DOWNLOADS: int = 512
const DEBUG_LOG: bool = false

static var _failed_downloads: Dictionary = {}
## While true (grid fast-scrolling or A-Z scrubbing), covers that aren't on
## disk render the placeholder instead of queueing downloads; the grid lifts
## the flag on settle and asks visible placeholder cards to retry.
static var downloads_suppressed: bool = false

## Grid-assigned decode bucket (0 = fall back to the card's live size). The
## grid computes it from ITS card_size at layout time and assigns it before
## any load, so live card.size is never a decode basis and layout transitions
## (zoom, resize) can't mint duplicate (path, bucket) cache entries.
var _assigned_decode_bucket: int = 0

static func clear_failed_downloads() -> void:
	_failed_downloads.clear()

## Round a pixel dimension up to the decode-size bucket. Single source of
## truth so the grid's prefetch and the card's own load derive matching keys.
static func decode_bucket_for_size(px: float) -> int:
	if px <= 0.0:
		return MAX_COVER_TEXTURE_SIZE
	var bucket := int(ceil(px / DECODE_SIZE_BUCKET)) * DECODE_SIZE_BUCKET
	return clampi(bucket, DECODE_SIZE_MIN, DECODE_SIZE_MAX)

## Decode bucket for a GRID-COMPUTED card size at a display pixel density.
## The one decode-basis formula: bucket128(clamp(max_axis × dpr, 256, 2048)).
static func decode_bucket_for_card_size(card_size: Vector2, dpr: float) -> int:
	return decode_bucket_for_size(maxf(card_size.x, card_size.y) * maxf(dpr, 0.01))

## Physical pixel density of the current screen (1.0 headless / unknown).
static func current_dpr() -> float:
	if DisplayServer.get_name() == "headless":
		return 1.0
	var scale := DisplayServer.screen_get_scale(DisplayServer.window_get_current_screen())
	return scale if scale > 0.0 else 1.0

## Assign the grid-computed decode bucket. Called by the grid's layout pass
## (_configure_card_size_flags); takes effect on the next load.
func set_assigned_decode_bucket(bucket: int) -> void:
	_assigned_decode_bucket = bucket

## Warm the texture memory cache for a game with no card attached. Used by the
## grid's directional prefetch so cover art is decoded before rows scroll into
## view. Only reads files already on disk; never triggers downloads.
## `decode_size` should be the grid's current card-pixel bucket so the warmed
## entry matches what cards will look up (0 = fallback size).
static func preload_cover(game: GameResource, decode_size: int = 0) -> void:
	if not game or not SystemManager.memory:
		return
	var size := decode_size if decode_size > 0 else MAX_COVER_TEXTURE_SIZE
	var cache_path := ""
	if game.cover_path and FSM.file_exists(game.cover_path):
		cache_path = game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		var p: String = DataManager.get_cached_image_path(game.cover_url)
		if FSM.file_exists(p):
			cache_path = p
	if cache_path == "":
		return
	DataManager.cover.note_cover_access(cache_path)
	var cache_key := MemorySubManager.cover_cache_key(cache_path, size)
	if SystemManager.memory.get_cached_texture(cache_key):
		return
	var load_callable = func():
		return MemorySubManager.prepare_image_for_texture(_load_image_from_buffer(FSM.read_file_bytes(cache_path), size))
	var callback_callable = func(image):
		if image and not image.is_empty():
			var texture = SystemManager.memory.create_texture_from_image(image)
			if texture:
				SystemManager.memory.cache_texture(cache_key, texture)
	SystemManager.memory.queue_image_task(load_callable, callback_callable, false, cache_key)

func _init(card: GameCard) -> void:
	_card = card

## Decode size for THIS card: the grid-assigned bucket when set (preferred —
## grid-computed card size is stable across layout transitions), else its
## rendered pixel size bucketed, else the fixed pre-layout fallback.
func _decode_size() -> int:
	if _assigned_decode_bucket > 0:
		return _assigned_decode_bucket
	if is_instance_valid(_card) and _card.size.x > 0.0 and _card.size.y > 0.0:
		return decode_bucket_for_size(maxf(_card.size.x, _card.size.y) * current_dpr())
	return MAX_COVER_TEXTURE_SIZE

## Returns the memory-cache key this loader would use for `game`, or "" if no
## cover source exists. Used by the owning card to pin visible textures.
## Instance method (not static) so the key includes this card's decode-size
## bucket — a pin only protects the texture the loader actually writes.
## Intentionally does not hit the filesystem: pinning is best-effort and must
## be cheap enough to run every frame for all visible cards.
func get_cover_cache_key(game: GameResource) -> String:
	if not game:
		return ""
	var cache_path := ""
	if game.cover_path and game.cover_path != "":
		cache_path = game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		cache_path = DataManager.get_cached_image_path(game.cover_url)
	if cache_path == "":
		return ""
	return MemorySubManager.cover_cache_key(cache_path, _decode_size())

func load_cover(game: GameResource, high_priority: bool = false) -> void:
	if not game:
		_set_loading_texture()
		return

	# Drop-retry budget resets per game, not per call: drop retries re-enter
	# through load_cover and must not refill their own budget.
	if _loading_game_id != game.id:
		_drop_retry_count = 0
	_loading_game_id = game.id
	_image_retry_count = 0
	_download_retry_count = 0

	var cache_path = ""
	var cover_url = ""
	if game.cover_path and FSM.file_exists(game.cover_path):
		cache_path = game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		cover_url = game.cover_url
		cache_path = DataManager.get_cached_image_path(cover_url)
		if not FSM.file_exists(cache_path):
			# Fast scroll/scrub suppression: placeholder now, retry on settle.
			# No download, no failure TTL - the cover isn't being looked at
			# long enough to be worth network contention.
			if downloads_suppressed:
				_set_loading_texture(false)
				return
			if DataManager.is_sync_in_progress():
				if DEBUG_LOG: print("[CardMediaLoader] No cached cover, waiting for sync: %s" % cover_url)
				_set_loading_texture(true)
				return
			else:
				var fail_time: float = _failed_downloads.get(cover_url, 0.0)
				if Time.get_unix_time_from_system() - fail_time < FAILURE_RETRY_TTL_SEC:
					if DEBUG_LOG: print("[CardMediaLoader] Skipping cover (failed recently, TTL active): %s" % cover_url)
					_set_loading_texture()
					return
				_download_cover_and_retry(cover_url, cache_path, high_priority)
				return

	if cache_path == "":
		if DEBUG_LOG: print("[CardMediaLoader] No cover path or URL for game id=%s" % game.id)
		_set_loading_texture()
		return

	# Memory cache hit: apply immediately without queueing a worker task.
	DataManager.cover.note_cover_access(cache_path)
	var cached_tex = SystemManager.memory.get_cached_texture(MemorySubManager.cover_cache_key(cache_path, _decode_size()))
	if cached_tex:
		_emit_texture(cached_tex)
		return

	# No memory cache: show the loading texture immediately, then queue the
	# async file read so cards never render blank while waiting.
	_set_loading_texture(true)
	_load_cached_cover(cache_path, high_priority)

func cancel() -> void:
	_loading_game_id = ""
	_image_retry_count = 0
	_download_retry_count = 0
	_drop_retry_count = 0
	_current_download_id += 1
	if _current_image_task_id > 0 and SystemManager.memory:
		SystemManager.memory.cancel_image_task(_current_image_task_id)
		_current_image_task_id = -1

func set_priority(high_priority: bool, current_game: GameResource = null) -> void:
	if _current_image_task_id > 0 and SystemManager.memory:
		SystemManager.memory.update_image_priority(_current_image_task_id, high_priority)
	elif high_priority:
		# No task in flight and no texture - retry load with high priority
		load_cover(current_game, true)

## Emits the placeholder texture. `animated` marks whether a fetch/decode is
## genuinely in flight (shimmer) or the card is settling for a static blank
## (no cover, failed download, retry cooldown).
func _set_loading_texture(animated: bool = false) -> void:
	if is_instance_valid(_card):
		_card._media_loading = animated
		emit_signal("texture_loaded", _card._loading_texture)

func _emit_texture(texture: Texture2D) -> void:
	if not is_instance_valid(_card):
		return
	emit_signal("texture_loaded", texture)

func _load_cached_cover(cache_path: String, high_priority: bool = false) -> void:
	var target_game_id = _loading_game_id

	if not SystemManager.memory:
		_set_loading_texture()
		return

	if _current_image_task_id > 0:
		SystemManager.memory.cancel_image_task(_current_image_task_id)

	var decode_size := _decode_size()
	var load_callable = func():
		return MemorySubManager.prepare_image_for_texture(_load_image_from_buffer(FSM.read_file_bytes(cache_path), decode_size))

	var callback_callable = func(image):
		_current_image_task_id = -1
		if not is_instance_valid(_card):
			return
		if not _card.game or _card.game.id != target_game_id:
			return

		if image and not image.is_empty():
			var texture = SystemManager.memory.create_texture_from_image(image)
			if texture:
				SystemManager.memory.cache_texture(MemorySubManager.cover_cache_key(cache_path, decode_size), texture)
				_emit_texture(texture)
		else:
			_image_retry_count += 1
			if _image_retry_count < MAX_IMAGE_RETRIES:
				await _card.get_tree().create_timer(0.1 * _image_retry_count).timeout
				if is_instance_valid(_card) and _card.game and _card.game.id == target_game_id:
					_load_cached_cover(cache_path, high_priority)
			else:
				push_error("[CardMediaLoader] Cache file undecodable after %d retries: %s" % [MAX_IMAGE_RETRIES, cache_path])

	_current_image_task_id = SystemManager.memory.queue_image_task(load_callable, callback_callable, high_priority, MemorySubManager.cover_cache_key(cache_path, decode_size))

func _download_cover_and_retry(cover_url: String, cache_path: String, high_priority: bool = false) -> void:
	_download_retry_count += 1
	if _download_retry_count > MAX_DOWNLOAD_RETRIES:
		_set_loading_texture()
		return
	_start_cover_download(cover_url, cache_path, high_priority)

func _start_cover_download(cover_url: String, cache_path: String, high_priority: bool = false) -> void:
	var target_game_id = _loading_game_id

	_set_loading_texture(true)

	var download_id = _current_download_id + 1
	_current_download_id = download_id

	DataManager.load_image(cover_url, func(loaded_texture: Texture2D, result: int):
		if not is_instance_valid(_card):
			return
		if download_id != _current_download_id:
			return
		if not _card.game or _card.game.id != target_game_id:
			return
		if loaded_texture:
			_failed_downloads.erase(cover_url)
			# loaded_texture is full-res (CoverSubManager does not downscale),
			# so it isn't cached under the 512px card key. Show it now, then
			# warm the proper card variant from the file just written to disk
			# so the next recycle is a cache hit instead of a decode flash.
			_emit_texture(loaded_texture)
			_warm_card_cache_from_disk(cache_path)
		elif FSM.file_exists(cache_path):
			load_cover(_card.game, high_priority)
		elif result == DownloadSubManager.ImageResult.DROPPED:
			# Backpressure (queue full / a teleport pruned the queued request),
			# not a content failure: no failure TTL - that's what used to leave
			# covers blank for FAILURE_RETRY_TTL_SEC after a scroll storm.
			# Bounded short-delay retry so a settled viewport self-heals.
			_schedule_drop_retry(cover_url, cache_path, high_priority, target_game_id, download_id)
		else:
			# Insertion-ordered: front key is the oldest failure.
			while _failed_downloads.size() >= MAX_FAILED_DOWNLOADS:
				_failed_downloads.erase(_failed_downloads.keys()[0])
			_failed_downloads[cover_url] = Time.get_unix_time_from_system()
			_set_loading_texture()
	, high_priority)

## DROPPED (backpressure) recovery: retry through the download path after a
## short delay, bounded so a persistently full queue can't loop forever.
## Guards discard the retry if the card was recycled or reassigned meanwhile.
func _schedule_drop_retry(cover_url: String, cache_path: String, high_priority: bool, target_game_id: String, download_id: int) -> void:
	if not is_instance_valid(_card) or not _card.is_inside_tree():
		return
	if _drop_retry_count >= MAX_DROP_RETRIES:
		_set_loading_texture()
		return
	_drop_retry_count += 1
	var tree := _card.get_tree()
	if tree == null:
		return
	await tree.create_timer(DROP_RETRY_DELAY_SEC).timeout
	if not is_instance_valid(_card):
		return
	if download_id != _current_download_id or _loading_game_id != target_game_id:
		return
	if not _card.game or _card.game.id != target_game_id:
		return
	if downloads_suppressed:
		_set_loading_texture(false)
		return
	if FSM.file_exists(cache_path):
		load_cover(_card.game, high_priority)
		return
	_start_cover_download(cover_url, cache_path, high_priority)

## Decode the on-disk cover into the 512px card cache without touching the
## card's current texture. Used after a fresh download so subsequent recycles
## hit the cache instead of flashing the placeholder.
func _warm_card_cache_from_disk(cache_path: String) -> void:
	var decode_size := _decode_size()
	var cache_key := MemorySubManager.cover_cache_key(cache_path, decode_size)
	if not SystemManager.memory or SystemManager.memory.get_cached_texture(cache_key):
		return
	var load_callable = func():
		return MemorySubManager.prepare_image_for_texture(_load_image_from_buffer(FSM.read_file_bytes(cache_path), decode_size))
	var callback_callable = func(image):
		if image and not image.is_empty():
			var texture = SystemManager.memory.create_texture_from_image(image)
			if texture:
				SystemManager.memory.cache_texture(cache_key, texture)
	SystemManager.memory.queue_image_task(load_callable, callback_callable, false, cache_key)

static func _load_image_from_buffer(buffer: PackedByteArray, max_size: int = MAX_COVER_TEXTURE_SIZE) -> Image:
	if buffer.size() < 16:
		return null

	var image = Image.new()
	var err = FAILED
	var format = FSM.detect_image_format(buffer)

	match format:
		FSM.ImageFormat.JPEG:
			err = image.load_jpg_from_buffer(buffer)
		FSM.ImageFormat.PNG:
			err = image.load_png_from_buffer(buffer)
		FSM.ImageFormat.WEBP:
			err = image.load_webp_from_buffer(buffer)
		_:
			# Unknown magic bytes: not a supported image.
			if DEBUG_LOG: print("[CardMediaLoader] Unknown magic bytes (%d bytes, first16=%s)" % [buffer.size(), buffer.slice(0, 16).hex_encode()])
			return null

	if err != OK or image.is_empty():
		if DEBUG_LOG: print("[CardMediaLoader] Decode error: format=%d err=%d (%d bytes)" % [format, err, buffer.size()])
		return null

	var max_dim = max(image.get_width(), image.get_height())
	if max_dim > max_size:
		var resize_scale = float(max_size) / max_dim
		var new_width = max(1, int(image.get_width() * resize_scale))
		var new_height = max(1, int(image.get_height() * resize_scale))
		image.resize(new_width, new_height, Image.INTERPOLATE_LANCZOS)
	return image
