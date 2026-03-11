class_name HeroImage
extends Control

@onready var color_rect: ColorRect = $ColorRect

var _current_game: GameResource = null
var _material: ShaderMaterial = null
var _gray_texture: ImageTexture = null
var _effect_stack: EffectStack = null

# Size validation and retry tracking
var _last_reported_size: Vector2 = Vector2.ZERO
var _size_retry_count: int = 0
const MAX_SIZE_RETRIES: int = 10
const MIN_VALID_SIZE: float = 10.0  # Minimum dimension to consider valid

# Feature flag: use new effect system or old shader
var _use_effect_stack: bool = true

func _ready():
	print("[HeroImage] _ready() called")
	
	# Create gray fallback texture
	_create_gray_texture()
	
	# Always use effect stack now (legacy shader is deprecated)
	_use_effect_stack = true
	_setup_effect_stack()
	
	# Show gray initially
	clear()
	
	print("[HeroImage] Initialized with EffectStack, size: ", size)

func _setup_effect_stack():
	print("[HeroImage] Setting up EffectStack...")
	
	# Remove the legacy ColorRect
	if color_rect:
		color_rect.visible = false
	
	# Create EffectStack
	_effect_stack = EffectStack.new()
	_effect_stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	_effect_stack.name = "EffectStack"
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

func _setup_legacy_shader():
	# Get the shader material
	if color_rect and color_rect.material is ShaderMaterial:
		_material = color_rect.material
		
		# Connect to resized signal
		color_rect.resized.connect(_on_resized)
		
		# Connect to root window resize
		if get_tree() and get_tree().root:
			get_tree().root.size_changed.connect(_on_resized)
		
		# Wait for container layout to complete
		await _safe_process_frames(2)
		if is_inside_tree():
			_update_shader_size_with_validation("_ready()")
	else:
		push_error("[HeroImage] No material found!")

func _notification(what: int) -> void:
	if not _use_effect_stack:
		# Legacy mode notifications
		if what == NOTIFICATION_VISIBILITY_CHANGED:
			if visible:
				await _safe_process_frames(2)
				if is_inside_tree():
					_update_shader_size_with_validation("visibility_changed")
		
		if what == NOTIFICATION_PARENTED:
			await _safe_process_frames(1)
			if not is_inside_tree():
				return
			var parent = get_parent()
			if parent is Control:
				if not parent.resized.is_connected(_on_resized):
					parent.resized.connect(_on_resized)
					_update_shader_size_with_validation("parented")
	
	# New effect stack - update size when resized
	if what == NOTIFICATION_RESIZED:
		if _use_effect_stack and _effect_stack and size.x > 0 and size.y > 0:
			# Update the container state with actual size
			var state = _effect_stack.get_container_state()
			if state:
				state.container_size = size
				print("[HeroImage] Size updated to: ", size)

func _safe_process_frames(count: int) -> void:
	"""Safely await process frames, checking if still in tree."""
	for i in range(count):
		if not is_inside_tree() or not get_tree():
			return
		await get_tree().process_frame

func _create_gray_texture():
	var img = Image.create(4, 4, false, Image.FORMAT_RGB8)
	if img:
		img.fill(Color(0.5, 0.5, 0.5))
		_gray_texture = ImageTexture.create_from_image(img)

func _on_resized():
	_update_shader_size_with_validation("_on_resized signal")

func _update_shader_size_with_validation(source: String = ""):
	if _use_effect_stack:
		return
	
	if not _material:
		return
	
	if not color_rect:
		return
	
	var current_size = color_rect.size
	
	# Check if size is valid
	if current_size.x < MIN_VALID_SIZE or current_size.y < MIN_VALID_SIZE:
		_size_retry_count += 1
		if _size_retry_count <= MAX_SIZE_RETRIES and get_tree():
			await get_tree().process_frame
			_update_shader_size_with_validation(source + " (retry " + str(_size_retry_count) + ")")
		else:
			_material.set_shader_parameter("hero_size", current_size)
			_last_reported_size = current_size
			_size_retry_count = 0
	else:
		# Size is valid, update shader
		_material.set_shader_parameter("hero_size", current_size)
		_last_reported_size = current_size
		_size_retry_count = 0

func _get_cache_path(game: GameResource) -> String:
	if game.cover_path and ResourceLoader.exists(game.cover_path):
		return game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		return "user://cache/covers/" + game.cover_url.md5_text() + ".jpg"
	return ""

func set_game(game: GameResource):
	print("[HeroImage] set_game called with: ", game.get_display_name() if game and game.has_method("get_display_name") else "null")
	
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
		
		print("[HeroImage] Image load error: ", err)
		if err == OK:
			var tex = ImageTexture.create_from_image(img)
			if tex:
				print("[HeroImage] Texture created, size: ", tex.get_size())
				print("[HeroImage] _use_effect_stack: ", _use_effect_stack, ", _effect_stack: ", _effect_stack)
				if _use_effect_stack and _effect_stack:
					_effect_stack.set_game_texture(tex)
					visible = true
					print("[HeroImage] Texture set to EffectStack")
				else:
					_set_texture(tex)
					visible = true
				return
	
	clear()

func _set_texture(tex: Texture2D):
	if _use_effect_stack:
		if _effect_stack:
			_effect_stack.set_game_texture(tex)
	elif _material:
		_material.set_shader_parameter("game_texture", tex)

func clear():
	_current_game = null
	if _gray_texture:
		_set_texture(_gray_texture)
	# Only set color_rect visibility, don't override parent's visibility control
	if color_rect:
		color_rect.visible = true

func get_current_game() -> GameResource:
	return _current_game

func refresh_from_settings():
	"""Reload configuration from settings - called when settings change."""
	if _use_effect_stack and _effect_stack:
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
