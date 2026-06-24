class_name CardMediaLoader
extends RefCounted

const FSM := preload("res://managers/filesystem_manager.gd")

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
const CACHE_FOLDER: String = "user://cache/covers/"

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
		cache_path = _get_cached_cover_path(cover_url)
		if not FSM.file_exists(cache_path):
			if DataManager.is_sync_in_progress():
				_set_loading_texture()
				return
			else:
				_download_cover_and_retry(cover_url, cache_path, high_priority)
				return

	if cache_path == "":
		_set_loading_texture()
		return

	# Memory cache hit: apply immediately without queueing a worker task.
	var cached_tex = MemoryManager.get_cached_texture(cache_path)
	if cached_tex:
		_emit_texture(cached_tex)
		return

	_load_cached_cover(cache_path, high_priority)

func cancel() -> void:
	_loading_game_id = ""
	_image_retry_count = 0
	_download_retry_count = 0
	_current_download_id += 1
	if _current_image_task_id > 0 and MemoryManager:
		MemoryManager.cancel_image_task(_current_image_task_id)
		_current_image_task_id = -1

func set_priority(high_priority: bool, current_game: GameResource = null) -> void:
	if _current_image_task_id > 0 and MemoryManager:
		MemoryManager.update_image_priority(_current_image_task_id, high_priority)
	elif high_priority:
		# No task in flight and no texture - retry load with high priority
		load_cover(current_game, true)

func _set_loading_texture() -> void:
	if is_instance_valid(_card):
		emit_signal("texture_loaded", _card._loading_texture)

func _emit_texture(texture: Texture2D) -> void:
	if not is_instance_valid(_card):
		return
	emit_signal("texture_loaded", texture)

func _get_cached_cover_path(url: String) -> String:
	var extension = "jpg"
	var query_start = url.find("?")
	var url_without_query = url
	if query_start != -1:
		url_without_query = url.substr(0, query_start)

	var last_dot = url_without_query.rfind(".")
	if last_dot != -1 and last_dot < url_without_query.length() - 1:
		var ext = url_without_query.substr(last_dot + 1).to_lower()
		if ext in ["jpg", "jpeg", "png", "webp"]:
			extension = ext
			if extension == "jpeg":
				extension = "jpg"

	return CACHE_FOLDER + url.md5_text() + "." + extension

func _load_cached_cover(cache_path: String, high_priority: bool = false) -> void:
	var target_game_id = _loading_game_id

	if not MemoryManager:
		_set_loading_texture()
		return

	if _current_image_task_id > 0:
		MemoryManager.cancel_image_task(_current_image_task_id)

	var load_callable = func():
		return _load_image_from_buffer(FSM.read_file_bytes(cache_path))

	var callback_callable = func(image):
		_current_image_task_id = -1
		if not is_instance_valid(_card):
			return
		if not _card.game or _card.game.id != target_game_id:
			return

		if image and not image.is_empty():
			var texture = ImageTexture.create_from_image(image.duplicate())
			if texture:
				MemoryManager.cache_texture(cache_path, texture)
				_emit_texture(texture)
		else:
			_image_retry_count += 1
			if _image_retry_count < MAX_IMAGE_RETRIES:
				await _card.get_tree().create_timer(0.1 * _image_retry_count).timeout
				if is_instance_valid(_card) and _card.game and _card.game.id == target_game_id:
					_load_cached_cover(cache_path, high_priority)

	_current_image_task_id = MemoryManager.queue_image_task(load_callable, callback_callable, high_priority, cache_path)

func _download_cover_and_retry(cover_url: String, cache_path: String, high_priority: bool = false) -> void:
	var target_game_id = _loading_game_id

	_download_retry_count += 1
	if _download_retry_count > MAX_DOWNLOAD_RETRIES:
		_set_loading_texture()
		return

	_set_loading_texture()

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
			MemoryManager.cache_texture(cache_path, loaded_texture)
			_emit_texture(loaded_texture)
		elif FSM.file_exists(cache_path):
			load_cover(_card.game, high_priority)
		else:
			_set_loading_texture()
	)

func _load_image_from_buffer(buffer: PackedByteArray) -> Image:
	if buffer.size() < 16:
		return null

	var err = FAILED
	var image = Image.new()

	if buffer[0] == 0xFF and buffer[1] == 0xD8:
		err = image.load_jpg_from_buffer(buffer)
	elif buffer[0] == 0x89 and buffer[1] == 0x50:
		err = image.load_png_from_buffer(buffer)
	elif buffer[0] == 0x52 and buffer[1] == 0x49:
		err = image.load_webp_from_buffer(buffer)
	else:
		err = image.load_jpg_from_buffer(buffer)
		if err != OK:
			image = Image.new()
			err = image.load_png_from_buffer(buffer)
		if err != OK:
			image = Image.new()
			err = image.load_webp_from_buffer(buffer)

	if err == OK:
		if image.is_empty():
			return null
		var max_dim = max(image.get_width(), image.get_height())
		if max_dim > MAX_COVER_TEXTURE_SIZE:
			var resize_scale = float(MAX_COVER_TEXTURE_SIZE) / max_dim
			var new_width = max(1, int(image.get_width() * resize_scale))
			var new_height = max(1, int(image.get_height() * resize_scale))
			image.resize(new_width, new_height, Image.INTERPOLATE_LANCZOS)
		return image
	return null
