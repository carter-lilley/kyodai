extends RefCounted

## Shared cover-loading pipeline for the shuffler OS windows (intro + pick-3).
## Resolves a game's cover through the memory cache, fetching the remote URL
## first when the cache file isn't on disk yet, and invokes apply(texture) on
## the main thread. Callers pass a weakref-guarded callable so a window/card
## freed mid-fetch turns apply into a no-op.

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")

static func request_cover(game: GameResource, max_size: int, apply: Callable) -> void:
	if not game:
		return
	var cache_path := ""
	var cover_url := ""
	if game.cover_path and FSM.file_exists(game.cover_path):
		cache_path = game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		cover_url = game.cover_url
		cache_path = DataManager.get_cached_image_path(cover_url)
	if cache_path == "":
		return
	if not FSM.file_exists(cache_path):
		# Not on disk yet: these games may never have appeared in the library
		# grid, so their covers were never downloaded. Fetch now (CoverSubManager
		# writes the cache file), then re-run the decode path. The file-exists
		# guard prevents a retry loop when the download itself fails.
		if cover_url != "":
			DataManager.load_image(cover_url, func(_t: Texture2D, _r: int):
				if FSM.file_exists(cache_path):
					request_cover(game, max_size, apply)
			)
		return
	var cache_key := MemorySubManager.cover_cache_key(cache_path, max_size)
	var cached = SystemManager.memory.get_cached_texture(cache_key)
	if cached:
		apply.call(cached)
		return
	DataManager.cover.note_cover_access(cache_path)
	SystemManager.memory.queue_image_task(
		func() -> Image:
			return MemorySubManager.prepare_image_for_texture(CardMediaLoader._load_image_from_buffer(FSM.read_file_bytes(cache_path))),
		func(image) -> void:
			if not image or image.is_empty():
				return
			var texture = SystemManager.memory.create_texture_from_image(image)
			if texture:
				SystemManager.memory.cache_texture(cache_key, texture)
				apply.call(texture)
	)
