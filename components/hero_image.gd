class_name HeroImage
extends Control

@onready var color_rect: ColorRect = $ColorRect

var _current_game: GameResource = null
var _material: ShaderMaterial = null
var _gray_texture: ImageTexture = null

func _ready():
	# Create gray fallback texture
	_create_gray_texture()
	
	# Get the shader material
	if color_rect and color_rect.material is ShaderMaterial:
		_material = color_rect.material
		
		# Connect to resized signal
		color_rect.resized.connect(_on_resized)
		
		# Update size after layout
		get_tree().root.size_changed.connect(_on_resized)
		call_deferred("_on_resized")
	else:
		push_error("[HeroImage] No material found!")
	
	# Show gray initially
	clear()

func _create_gray_texture():
	var img = Image.new()
	img.create(4, 4, false, Image.FORMAT_RGB8)
	img.fill(Color(0.5, 0.5, 0.5))
	_gray_texture = ImageTexture.create_from_image(img)

func _on_resized():
	if _material and color_rect:
		_material.set_shader_parameter("hero_size", color_rect.size)

func _get_cache_path(game: GameResource) -> String:
	if game.cover_path and FileAccess.file_exists(game.cover_path):
		return game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		return "user://cache/covers/" + game.cover_url.md5_text() + ".jpg"
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
	
	# Try cache first
	if MemoryManager:
		var cached = MemoryManager.get_cached_texture(cache_path)
		if cached:
			_set_texture(cached)
			visible = true
			return
	
	# Load from file
	if FileAccess.file_exists(cache_path):
		var img = Image.new()
		if img.load(cache_path) == OK:
			var tex = ImageTexture.create_from_image(img)
			if tex:
				if MemoryManager:
					MemoryManager.cache_texture(cache_path, tex)
				_set_texture(tex)
				visible = true
				return
	
	clear()

func _set_texture(tex: Texture2D):
	if _material:
		_material.set_shader_parameter("game_texture", tex)

func clear():
	_current_game = null
	if _gray_texture:
		_set_texture(_gray_texture)
	visible = true
	if color_rect:
		color_rect.visible = true

func get_current_game() -> GameResource:
	return _current_game
