class_name HeroImage
extends Control

@onready var color_rect: ColorRect = $ColorRect

var _current_game: GameResource = null
var _material: ShaderMaterial = null
var _gray_texture: ImageTexture = null

# Size validation and retry tracking
var _last_reported_size: Vector2 = Vector2.ZERO
var _size_retry_count: int = 0
const MAX_SIZE_RETRIES: int = 10
const MIN_VALID_SIZE: float = 10.0  # Minimum dimension to consider valid

func _ready():
	print("[HeroImage] _ready() called - node: ", name, " is_inside_tree: ", is_inside_tree())
	
	# Create gray fallback texture
	_create_gray_texture()
	
	# Get the shader material
	if color_rect and color_rect.material is ShaderMaterial:
		_material = color_rect.material
		print("[HeroImage] Material obtained successfully")
		
		# Connect to resized signal
		color_rect.resized.connect(_on_resized)
		print("[HeroImage] Connected color_rect.resized signal")
		
		# Connect to root window resize
		if get_tree() and get_tree().root:
			get_tree().root.size_changed.connect(_on_resized)
			print("[HeroImage] Connected root.size_changed signal")
		
		print("[HeroImage] In active view, proceeding with initialization")
		print("[HeroImage] About to wait for process frames...")
		# Wait for container layout to complete before setting initial shader size
		await _safe_process_frames(2)
		if is_inside_tree():
			print("[HeroImage] After process frames - color_rect.size: ", color_rect.size, " is_visible: ", is_visible_in_tree())
			_update_shader_size_with_validation("_ready()")
	else:
		push_error("[HeroImage] No material found!")
	
	# Show gray initially
	print("[HeroImage] Calling clear() in _ready()")
	clear()

func _notification(what: int) -> void:
	# Handle visibility changes to catch layout updates when becoming visible
	if what == NOTIFICATION_VISIBILITY_CHANGED and visible:
		print("[HeroImage] NOTIFICATION_VISIBILITY_CHANGED - visible: ", visible)
		
		# Wait for layout to settle after visibility change
		await _safe_process_frames(2)
		if is_inside_tree():
			_update_shader_size_with_validation("visibility_changed")
	
	# Handle when parent layout changes
	if what == NOTIFICATION_PARENTED:
		print("[HeroImage] NOTIFICATION_PARENTED - parent: ", get_parent().name if get_parent() else "none")
		
		# Connect to parent's resized signal when we're added to a new parent
		await _safe_process_frames(1)
		if not is_inside_tree():
			return
		var parent = get_parent()
		if parent is Control:
			print("[HeroImage] Parent is Control: ", parent.name, " connecting to resized signal")
			if not parent.resized.is_connected(_on_resized):
				parent.resized.connect(_on_resized)
				_update_shader_size_with_validation("parented")

func _enter_tree():
	print("[HeroImage] _enter_tree() - name: ", name)

func _exit_tree():
	print("[HeroImage] _exit_tree() - name: ", name)

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
	print("[HeroImage] _on_resized() called - color_rect.size: ", color_rect.size if color_rect else "no color_rect")
	_update_shader_size_with_validation("_on_resized signal")

func _update_shader_size_with_validation(source: String = ""):
	print("[HeroImage] _update_shader_size_with_validation() called from: ", source)
	
	if not _material:
		print("[HeroImage] ERROR: No material!")
		return
	
	if not color_rect:
		print("[HeroImage] ERROR: No color_rect!")
		return
	
	var current_size = color_rect.size
	print("[HeroImage] Current size from color_rect: ", current_size, " retry_count: ", _size_retry_count)
	
	# Check if size is valid (non-zero and above minimum threshold)
	if current_size.x < MIN_VALID_SIZE or current_size.y < MIN_VALID_SIZE:
		_size_retry_count += 1
		print("[HeroImage] Size invalid (below MIN_VALID_SIZE: ", MIN_VALID_SIZE, "), retry: ", _size_retry_count, "/", MAX_SIZE_RETRIES)
		if _size_retry_count <= MAX_SIZE_RETRIES and get_tree():
			# Size is invalid, retry after a frame
			await get_tree().process_frame
			_update_shader_size_with_validation(source + " (retry " + str(_size_retry_count) + ")")
		else:
			push_warning("[HeroImage] Max retries reached, using size: ", current_size)
			print("[HeroImage] Setting shader param hero_size to: ", current_size, " (MAX RETRIES)")
			_material.set_shader_parameter("hero_size", current_size)
			_last_reported_size = current_size
			_size_retry_count = 0
	else:
		# Size is valid, update shader
		print("[HeroImage] Size valid! Setting shader param hero_size to: ", current_size)
		_material.set_shader_parameter("hero_size", current_size)
		_last_reported_size = current_size
		_size_retry_count = 0

func _get_cache_path(game: GameResource) -> String:
	if game.cover_path and FileAccess.file_exists(game.cover_path):
		return game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		return "user://cache/covers/" + game.cover_url.md5_text() + ".jpg"
	return ""

func set_game(game: GameResource):
	print("[HeroImage] set_game() called with game: ", game.get_display_name() if game else "null")
	
	if game == _current_game:
		print("[HeroImage] Same game, skipping")
		return
	
	_current_game = game
	
	if not game or not game.has_cover_art:
		print("[HeroImage] No game or no cover art, clearing")
		clear()
		return
	
	var cache_path = _get_cache_path(game)
	if cache_path == "":
		print("[HeroImage] No cache path, clearing")
		clear()
		return
	
	# Load image - try all formats (files may have wrong extension)
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
		
		if err == OK:
			var tex = ImageTexture.create_from_image(img)
			if tex:
				print("[HeroImage] Successfully loaded texture, setting and making visible")
				_set_texture(tex)
				visible = true
				return
	
	print("[HeroImage] Failed to load image, clearing")
	clear()

func _set_texture(tex: Texture2D):
	if _material:
		print("[HeroImage] _set_texture() setting game_texture shader param")
		_material.set_shader_parameter("game_texture", tex)

func clear():
	print("[HeroImage] clear() called")
	_current_game = null
	if _gray_texture:
		_set_texture(_gray_texture)
	visible = true
	if color_rect:
		color_rect.visible = true

func get_current_game() -> GameResource:
	return _current_game
