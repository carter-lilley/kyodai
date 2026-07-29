class_name HeroImage
extends Control

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

var _current_game: GameResource = null
var _gray_texture: ImageTexture = null
var _current_texture: Texture2D = null
var _effect_stack: EffectStack = null
var _media_container: MediaContainer = null

var _current_image_task_id: int = -1
var _loading_game_id: String = ""

func _ready():
	# Create gray fallback texture
	_create_gray_texture()

	_setup_effect_stack()

	# Show gray initially
	clear()

func _setup_effect_stack():
	# Create MediaContainer and EffectStack
	_media_container = MediaContainer.new()

	_effect_stack = EffectStack.new()
	_effect_stack.set_parent_rid(get_canvas_item())
	# The node-less stack has no geometry of its own, so clipping against it
	# would hide everything. The base shader handles the rounded corners.
	_effect_stack.set_clip_children(false)
	# Load configuration
	_load_effect_config()

func _load_effect_config():
	if not _effect_stack:
		return

	var config = {}
	if DataManager:
		var config_setting = DataManager.get_setting("hero_effect_config")
		if config_setting and config_setting.value is Dictionary:
			config = config_setting.value

	_media_container.corner_radius_ratio = config.get("corner_radius", 0.06)
	_media_container.effect_settings = config.get("effects", [])
	_effect_stack.initialize(_media_container, _media_container.effect_settings, "hero")
	_effect_stack.update_draw_rects()

func _notification(what: int) -> void:
	# Update size when resized
	if what == NOTIFICATION_RESIZED:
		if _media_container and size.x > 0 and size.y > 0:
			_media_container.bounds = Rect2(Vector2.ZERO, size)
			if _effect_stack:
				_effect_stack.update_draw_rects()
	elif what == NOTIFICATION_PARENTED:
		# When the hero is reparented (e.g., desktop dual screen moves it into a
		# secondary Window), the EffectStack must be reattached to the new CanvasItem.
		if _effect_stack == null and _gray_texture:
			# _exit_tree() freed the stack; rebuild it for the new parent and
			# re-apply the texture that was showing.
			_setup_effect_stack()
			if _media_container and size.x > 0 and size.y > 0:
				_media_container.bounds = Rect2(Vector2.ZERO, size)
				_effect_stack.update_draw_rects()
			if _current_texture:
				_effect_stack.set_game_texture(_current_texture)
		elif _effect_stack:
			_effect_stack.set_parent_rid(get_canvas_item())
			_effect_stack.update_draw_rects()

func _exit_tree() -> void:
	if _effect_stack:
		_effect_stack.free_rids()
		_effect_stack = null
	_media_container = null

func _create_gray_texture():
	var img = Image.create(4, 4, false, Image.FORMAT_RGBA8)
	if img:
		img.fill(Color(0.5, 0.5, 0.5, 1.0))
		_gray_texture = ImageTexture.create_from_image(img)

func _get_cache_path(game: GameResource) -> String:
	if game.cover_path and ResourceLoader.exists(game.cover_path):
		return game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		# Use DataManager's path calculation to ensure consistent extension handling
		return DataManager.get_cached_image_path(game.cover_url)
	return ""

func set_game(game: GameResource):
	if game == _current_game:
		return

	_current_game = game

	if not game or not game.has_cover_art:
		clear()
		return

	var cache_path = _get_cache_path(game)
	if cache_path == "":
		clear()
		return

	# Check texture cache first
	var cached_tex = MemorySubManager.get_cached_texture(cache_path)
	if cached_tex:
		_set_texture(cached_tex)
		return

	# Cancel any pending image load
	if _current_image_task_id > 0:
		MemorySubManager.cancel_image_task(_current_image_task_id)

	_loading_game_id = game.id if game else ""

	const MAX_HERO_TEXTURE_SIZE: int = 1024

	var load_callable = func() -> Image:
		var buffer = FSM.read_file_bytes(cache_path)
		if buffer.is_empty():
			return null

		var img = Image.new()
		var err = FAILED
		if buffer.size() >= 2:
			if buffer[0] == 0xFF and buffer[1] == 0xD8:
				err = img.load_jpg_from_buffer(buffer)
			elif buffer[0] == 0x89 and buffer[1] == 0x50:
				err = img.load_png_from_buffer(buffer)
			else:
				err = img.load_webp_from_buffer(buffer)

		if err == OK:
			if img.is_empty():
				return null
			# Downscale large images to save GPU memory
			var max_dim = max(img.get_width(), img.get_height())
			if max_dim > MAX_HERO_TEXTURE_SIZE:
				var tex_scale = float(MAX_HERO_TEXTURE_SIZE) / max_dim
				var new_width = max(1, int(img.get_width() * tex_scale))
				var new_height = max(1, int(img.get_height() * tex_scale))
				img.resize(new_width, new_height, Image.INTERPOLATE_LANCZOS)
			return MemorySubManager.prepare_image_for_texture(img)
		return null

	var callback_callable = func(image: Image):
		_current_image_task_id = -1
		if not is_instance_valid(self):
			return
		if not _current_game or _current_game.id != _loading_game_id:
			return

		if image and not image.is_empty():
			var tex = MemorySubManager.create_texture_from_image(image)
			if tex:
				MemorySubManager.cache_texture(cache_path, tex)
				_set_texture(tex)
				return

		clear()

	_current_image_task_id = MemorySubManager.queue_image_task(load_callable, callback_callable, true)

func _set_texture(tex: Texture2D):
	_current_texture = tex
	if _effect_stack:
		_effect_stack.set_game_texture(tex)

func clear():
	_current_game = null
	if _current_image_task_id > 0 and SystemManager.memory:
		MemorySubManager.cancel_image_task(_current_image_task_id)
		_current_image_task_id = -1
	if _gray_texture:
		_set_texture(_gray_texture)

func get_current_game() -> GameResource:
	return _current_game

func refresh_from_settings():
	"""Reload configuration from settings - called when settings change."""
	if _effect_stack:
		# Store current texture and size before reloading
		var current_texture = null
		var current_size = Vector2.ZERO
		if _media_container:
			current_texture = _media_container.texture
			current_size = _media_container.size
		_load_effect_config()
		# Restore the texture and size after reloading
		if current_texture:
			_effect_stack.set_game_texture(current_texture)
		# Restore the size to maintain aspect ratio
		if current_size != Vector2.ZERO:
			_media_container.bounds = Rect2(Vector2.ZERO, current_size)
			_effect_stack.update_draw_rects()
