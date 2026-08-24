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
var _current_download_id: int = 0

const MAX_IMAGE_RETRIES: int = 3
const MAX_DOWNLOAD_RETRIES: int = 2
const MAX_COVER_TEXTURE_SIZE: int = 512
const FAILURE_RETRY_TTL_SEC: int = 300
# Bound the static failure-TTL map so permanently-failing URLs don't grow it forever.
const MAX_FAILED_DOWNLOADS: int = 512
const DEBUG_LOG: bool = false

static var _failed_downloads: Dictionary = {}

static func clear_failed_downloads() -> void:
	_failed_downloads.clear()

## Warm the texture memory cache for a game with no card attached. Used by the
## grid's directional prefetch so cover art is decoded before rows scroll into
## view. Only reads files already on disk; never triggers downloads.
static func preload_cover(game: GameResource) -> void:
	if not game or not SystemManager.memory:
		return
	var cache_path := ""
	if game.cover_path and FSM.file_exists(game.cover_path):
		cache_path = game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		var p: String = DataManager.get_cached_image_path(game.cover_url)
		if FSM.file_exists(p):
			cache_path = p
	if cache_path == "":
		return
	var cache_key := MemorySubManager.cover_cache_key(cache_path, MAX_COVER_TEXTURE_SIZE)
	if SystemManager.memory.get_cached_texture(cache_key):
		return
	var load_callable = func():
		return MemorySubManager.prepare_image_for_texture(_load_image_from_buffer(FSM.read_file_bytes(cache_path)))
	var callback_callable = func(image):
		if image and not image.is_empty():
			var texture = SystemManager.memory.create_texture_from_image(image)
			if texture:
				SystemManager.memory.cache_texture(cache_key, texture)
	SystemManager.memory.queue_image_task(load_callable, callback_callable, false, cache_key)

func _init(card: GameCard) -> void:
	_card = card

func load_cover(game: GameResource, high_priority: bool = false) -> void:
	if not game:
		_set_loading_texture()
		return

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
	var cached_tex = SystemManager.memory.get_cached_texture(MemorySubManager.cover_cache_key(cache_path, MAX_COVER_TEXTURE_SIZE))
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

	var load_callable = func():
		return MemorySubManager.prepare_image_for_texture(_load_image_from_buffer(FSM.read_file_bytes(cache_path)))

	var callback_callable = func(image):
		_current_image_task_id = -1
		if not is_instance_valid(_card):
			return
		if not _card.game or _card.game.id != target_game_id:
			return

		if image and not image.is_empty():
			var texture = SystemManager.memory.create_texture_from_image(image)
			if texture:
				SystemManager.memory.cache_texture(MemorySubManager.cover_cache_key(cache_path, MAX_COVER_TEXTURE_SIZE), texture)
				_emit_texture(texture)
		else:
			_image_retry_count += 1
			if _image_retry_count < MAX_IMAGE_RETRIES:
				await _card.get_tree().create_timer(0.1 * _image_retry_count).timeout
				if is_instance_valid(_card) and _card.game and _card.game.id == target_game_id:
					_load_cached_cover(cache_path, high_priority)
			else:
				push_error("[CardMediaLoader] Cache file undecodable after %d retries: %s" % [MAX_IMAGE_RETRIES, cache_path])

	_current_image_task_id = SystemManager.memory.queue_image_task(load_callable, callback_callable, high_priority, MemorySubManager.cover_cache_key(cache_path, MAX_COVER_TEXTURE_SIZE))

func _download_cover_and_retry(cover_url: String, cache_path: String, high_priority: bool = false) -> void:
	var target_game_id = _loading_game_id

	_download_retry_count += 1
	if _download_retry_count > MAX_DOWNLOAD_RETRIES:
		_set_loading_texture()
		return

	_set_loading_texture(true)

	var download_id = _current_download_id + 1
	_current_download_id = download_id

	DataManager.load_image(cover_url, func(loaded_texture: Texture2D):
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
		else:
			# Insertion-ordered: front key is the oldest failure.
			while _failed_downloads.size() >= MAX_FAILED_DOWNLOADS:
				_failed_downloads.erase(_failed_downloads.keys()[0])
			_failed_downloads[cover_url] = Time.get_unix_time_from_system()
			_set_loading_texture()
	, high_priority)

## Decode the on-disk cover into the 512px card cache without touching the
## card's current texture. Used after a fresh download so subsequent recycles
## hit the cache instead of flashing the placeholder.
func _warm_card_cache_from_disk(cache_path: String) -> void:
	var cache_key := MemorySubManager.cover_cache_key(cache_path, MAX_COVER_TEXTURE_SIZE)
	if not SystemManager.memory or SystemManager.memory.get_cached_texture(cache_key):
		return
	var load_callable = func():
		return MemorySubManager.prepare_image_for_texture(_load_image_from_buffer(FSM.read_file_bytes(cache_path)))
	var callback_callable = func(image):
		if image and not image.is_empty():
			var texture = SystemManager.memory.create_texture_from_image(image)
			if texture:
				SystemManager.memory.cache_texture(cache_key, texture)
	SystemManager.memory.queue_image_task(load_callable, callback_callable, false, cache_key)

static func _load_image_from_buffer(buffer: PackedByteArray) -> Image:
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
	if max_dim > MAX_COVER_TEXTURE_SIZE:
		var resize_scale = float(MAX_COVER_TEXTURE_SIZE) / max_dim
		var new_width = max(1, int(image.get_width() * resize_scale))
		var new_height = max(1, int(image.get_height() * resize_scale))
		image.resize(new_width, new_height, Image.INTERPOLATE_LANCZOS)
	return image
