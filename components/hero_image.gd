class_name HeroImage
extends Control

signal game_changed(game: GameResource)

var _current_game: GameResource = null
var _gray_texture: ImageTexture = null
var _effect_stack: EffectStack = null
var _dual_screen_mode: bool = false

func set_dual_screen_mode(enabled: bool) -> void:
	_dual_screen_mode = enabled
	if enabled:
		# Hide when dual screen is active
		visible = false
	else:
		visible = true

func _ready():
	print("[HeroImage] _ready() called")
	
	# Create gray fallback texture
	_create_gray_texture()
	
	_setup_effect_stack()
	
	# Show gray initially
	clear()
	
	print("[HeroImage] _ready() complete on ", name, ", _effect_stack: ", _effect_stack)
	
	print("[HeroImage] Initialized with EffectStack, size: ", size)

func _setup_effect_stack():
	print("[HeroImage] Setting up EffectStack...")
	
	# Create EffectStack
	_effect_stack = EffectStack.new()
	_effect_stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	_effect_stack.name = "EffectStack"
	# Clip children to ensure effects don't draw outside the hero area
	_effect_stack.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	add_child(_effect_stack)
	print("[HeroImage] EffectStack added as child")
	
	# Load configuration
	_load_effect_config()

func _load_effect_config():
	if not _effect_stack:
		return
		
	var config = {}
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("hero_effect_config")
		if config_setting and config_setting.value is Dictionary:
			config = config_setting.value
	
	var state = EffectContainerState.for_hero()
	state.corner_radius_ratio = config.get("corner_radius", 0.06)
	state.effect_settings = config.get("effects", [])
	_effect_stack.initialize(state, state.effect_settings)
	print("[HeroImage] Loaded effect config with ", state.effect_settings.size(), " effects")

func _notification(what: int) -> void:
	# Update size when resized
	if what == NOTIFICATION_RESIZED:
		if _effect_stack and size.x > 0 and size.y > 0:
			# Update the container state with actual size
			var state = _effect_stack.get_container_state()
			if state:
				state.container_size = size
				print("[HeroImage] Size updated to: ", size)

func _create_gray_texture():
	var img = Image.create(4, 4, false, Image.FORMAT_RGB8)
	if img:
		img.fill(Color(0.5, 0.5, 0.5))
		_gray_texture = ImageTexture.create_from_image(img)

func _get_cache_path(game: GameResource) -> String:
	if game.cover_path and ResourceLoader.exists(game.cover_path):
		return game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		return "user://cache/covers/" + game.cover_url.md5_text() + ".jpg"
	return ""

func set_game(game: GameResource):
	print("[HeroImage] set_game called on ", name, " with: ", game.get_display_name() if game and game.has_method("get_display_name") else "null")
	
	if game == _current_game:
		print("[HeroImage] Same game, skipping")
		return
	
	_current_game = game
	
	if not game or not game.has_cover_art:
		print("[HeroImage] No game or no cover art")
		clear()
		return
	
	var cache_path = _get_cache_path(game)
	print("[HeroImage] Cache path: ", cache_path)
	if cache_path == "":
		clear()
		return
	
	# Load image - try all formats
	var file = FileAccess.open(cache_path, FileAccess.READ)
	if file:
		var buffer = file.get_buffer(file.get_length())
		file.close()
		
		var img = Image.new()
		var err = FAILED
		
		# Detect format from magic bytes
		if buffer.size() >= 2:
			if buffer[0] == 0xFF and buffer[1] == 0xD8:
				err = img.load_jpg_from_buffer(buffer)
			elif buffer[0] == 0x89 and buffer[1] == 0x50:
				err = img.load_png_from_buffer(buffer)
			else:
				err = img.load_webp_from_buffer(buffer)
		
		print("[HeroImage] Image load error: ", err, " on ", name)
		if err == OK:
			var tex = ImageTexture.create_from_image(img)
			if tex:
				print("[HeroImage] Texture created on ", name, ", size: ", tex.get_size())
				if _effect_stack:
					_effect_stack.set_game_texture(tex)
					print("[HeroImage] Texture set to EffectStack on ", name)
				else:
					print("[HeroImage] ERROR: _effect_stack is null on ", name)
				return
			else:
				print("[HeroImage] ERROR: Failed to create texture on ", name)
	
	clear()

func _set_texture(tex: Texture2D):
	if _effect_stack:
		_effect_stack.set_game_texture(tex)

func clear():
	_current_game = null
	if _gray_texture:
		_set_texture(_gray_texture)
	# EffectStack handles visibility - no legacy ColorRect to manage

func get_current_game() -> GameResource:
	return _current_game

func set_game_texture_direct(texture: Texture2D) -> void:
	"""Directly set the game texture - used for second screen copy."""
	if texture and _effect_stack:
		_effect_stack.set_game_texture(texture)
		visible = true
		print("[HeroImage] Texture set directly, size: ", texture.get_size())

func refresh_from_settings():
	"""Reload configuration from settings - called when settings change."""
	if _effect_stack:
		# Store current texture and size before reloading
		var current_texture = null
		var current_size = Vector2.ZERO
		if _effect_stack.get_container_state():
			current_texture = _effect_stack.get_container_state().game_texture
			current_size = _effect_stack.get_container_state().container_size
		print("[HeroImage] refresh_from_settings - preserving texture: ", current_texture, ", size: ", current_size)
		_load_effect_config()
		# Restore the texture and size after reloading
		if current_texture:
			_effect_stack.set_game_texture(current_texture)
			print("[HeroImage] Texture restored after refresh")
		# Restore the size to maintain aspect ratio
		if current_size != Vector2.ZERO:
			var state = _effect_stack.get_container_state()
			if state:
				state.container_size = current_size
				state._recalculate_shape()
				# Update all effects with the restored size
				for effect_id in _effect_stack._effects:
					var effect = _effect_stack._effects[effect_id]
					if effect and effect.visible:
						effect.update_state(state)
				print("[HeroImage] Size restored after refresh: ", current_size)
