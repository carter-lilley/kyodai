class_name GameCard
extends ColorRect

signal download_requested(game: GameResource)

@export var game: GameResource:
	set(value):
		game = value
		_update_display()

@export var preview_mode: bool = false

@onready var card_input: Button = $CardInput
@onready var status_icon: TextureRect = $CardInput/StatusBadge/StatusIcon
@onready var status_badge: Panel = $CardInput/StatusBadge
@onready var platform_icon: TextureRect = $CardInput/PlatformIcon

var _loading_texture: Texture2D = preload("res://icon.svg")
var _download_icon: Texture2D = preload("res://assets/ui/icons/download.png")
var _play_icon: Texture2D = preload("res://assets/ui/icons/play.png")
var _is_downloading: bool = false

const BASE_BADGE_SIZE: float = 32.0
const BASE_BADGE_CORNER: int = 23
const BASE_ICON_SIZE: float = 22.0
const BASE_BADGE_MARGIN: float = 8.0

# Default dimensions for vertical orientation (202x270)
const VERTICAL_WIDTH: float = 202.0
const VERTICAL_HEIGHT: float = 270.0
const HORIZONTAL_WIDTH: float = 270.0
const HORIZONTAL_HEIGHT: float = 202.0
const SQUARE_WIDTH: float = 256.0
const SQUARE_HEIGHT: float = 256.0

var _current_zoom: float = 1.0
var _current_texture: Texture2D = null

var _loading_game_id: String = ""
var _image_retry_count: int = 0
const MAX_IMAGE_RETRIES: int = 3

func _ready():
	if material:
		material = material.duplicate()
	
	# Always connect to settings changes (needed for preview mode too)
	if SettingsManager:
		SettingsManager.setting_changed.connect(_on_setting_changed)
	
	if preview_mode:
		_setup_preview_mode()
		return
	
	set_card_zoom(_current_zoom)
	_update_shader_params()
	_update_display()
	
	if card_input:
		card_input.pressed.connect(_on_card_pressed)
		card_input.gui_input.connect(_on_card_gui_input)
	
	if DownloadManager:
		DownloadManager.download_progress.connect(_on_download_progress)
		DownloadManager.download_completed.connect(_on_download_completed)
	
	if DataManager:
		DataManager.image_loaded.connect(_on_cover_loaded)

func _setup_preview_mode():
	set_card_zoom(_current_zoom)
	_update_shader_params()
	
	# Load a random game for the preview
	if DataManager:
		var random_game = DataManager.get_random_game()
		if random_game:
			self.game = random_game
			_load_cover()
		else:
			_set_texture(_loading_texture)
	else:
		_set_texture(_loading_texture)
	
	if status_badge:
		status_badge.visible = false
	
	# Note: _update_platform_badge() will be called automatically via the game setter
	# which handles checking the platform_badge setting and loading the correct icon
	
	if card_input:
		card_input.disabled = true
		card_input.mouse_filter = Control.MOUSE_FILTER_IGNORE

func _update_display():
	if not game:
		return
	
	if not is_node_ready():
		return
	
	_update_status_icon()
	_update_platform_badge()
	_load_cover()

func _update_status_icon():
	if not status_icon or not status_badge:
		return
	
	if not game:
		status_icon.visible = false
		status_badge.visible = false
		return
	
	if game.is_active_variant_downloaded():
		status_icon.texture = _play_icon
		status_icon.visible = true
		status_icon.modulate = Color(1, 1, 1, 1)
		status_badge.visible = true
	elif _is_downloading:
		status_icon.visible = false
		status_badge.visible = false
	else:
		status_icon.texture = _download_icon
		status_icon.visible = true
		status_icon.modulate = Color(1, 1, 1, 0.8)
		status_badge.visible = true

func _update_platform_badge():
	if not game:
		_update_shader_platform_params(null)
		_update_platform_icon_rect(null)
		return
	
	# Check if platform badge is enabled
	var show_badge = false
	if SettingsManager:
		var badge_setting = SettingsManager.get_setting("platform_badge")
		if badge_setting:
			show_badge = badge_setting.value
	
	if not show_badge:
		_update_shader_platform_params(null)
		_update_platform_icon_rect(null)
		return
	
	# Load platform icon and pass to shader
	var platform_slug = game.platform_slug
	var icon_texture: Texture2D = null
	if platform_slug:
		var icon_path = "res://assets/platforms/icon/icon_%s.svg" % platform_slug
		if FileAccess.file_exists(icon_path):
			icon_texture = load(icon_path)
	
	_update_shader_platform_params(icon_texture)
	_update_platform_icon_rect(icon_texture)

func _load_cover():
	if not game:
		_set_texture(_loading_texture)
		return
	
	_loading_game_id = game.id
	_image_retry_count = 0
	
	if game.cover_path != "" and FileAccess.file_exists(game.cover_path):
		_load_local_cover()
		return
	
	_load_cover_from_url()

func _load_local_cover():
	var target_game_id = _loading_game_id
	
	if not MemoryManager:
		_set_texture(_loading_texture)
		return
	
	MemoryManager.queue_image_task(
		func():
			var img = Image.new()
			var err = img.load(game.cover_path)
			if err == OK:
				return ImageTexture.create_from_image(img)
			return null,
		func(texture):
			if not is_instance_valid(self):
				return
			if not game or game.id != target_game_id:
				return
			
			if texture:
				_set_texture(texture)
			else:
				_image_retry_count += 1
				if _image_retry_count < MAX_IMAGE_RETRIES:
					await get_tree().create_timer(0.1 * _image_retry_count).timeout
					if is_instance_valid(self) and game and game.id == target_game_id:
						_load_local_cover()
				else:
					_load_cover_from_url()
	)

func _load_cover_from_url():
	if not DataManager:
		_set_texture(_loading_texture)
		return
	
	if game.cover_url != "" and game.cover_url.begins_with("http"):
		var target_game_id = _loading_game_id
		var current_retry = _image_retry_count
		
		DataManager.load_image(game.cover_url, func(texture):
			if not is_instance_valid(self):
				return
			if not game or game.id != target_game_id:
				return
			
			if texture:
				_set_texture(texture)
			else:
				_image_retry_count = current_retry + 1
				if _image_retry_count < MAX_IMAGE_RETRIES:
					await get_tree().create_timer(0.1 * _image_retry_count).timeout
					if is_instance_valid(self) and game and game.id == target_game_id:
						_load_cover_from_url()
				else:
					_set_texture(_loading_texture)
		)
	else:
		_set_texture(_loading_texture)

func _set_texture(tex: Texture2D) -> void:
	_current_texture = tex
	var mat = material as ShaderMaterial
	if mat:
		mat.set_shader_parameter("game_texture", tex)

func _on_card_pressed():
	if not game:
		return
	
	if game.is_active_variant_downloaded():
		var root_folder = SettingsManager.get_setting("games_root_folder") if SettingsManager else null
		if root_folder and root_folder.value != "":
			var active_id = game.get_active_game_id()
			var file_path = game.get_sibling_file_path(active_id, root_folder.value)
			
			if not FileAccess.file_exists(file_path):
				if NotificationManager:
					NotificationManager.show_notification("File not found - redownloading", Notification.Type.WARNING)
				download_requested.emit(game)
				return
		
		if LaunchManager:
			LaunchManager.launch_game(game)
	else:
		download_requested.emit(game)

func _on_card_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if game and UIManager:
				UIManager.show_game_context_menu(game.romm_id, get_viewport().get_mouse_position())

func _on_download_progress(item_id: String, progress: float):
	if not DownloadManager:
		return
	var item = DownloadManager.get_item(item_id)
	if item and item.game_resource and game and item.game_resource.romm_id == game.romm_id:
		_is_downloading = true
		_update_status_icon()

func _on_download_completed(item_id: String, success: bool, message: String):
	if not DownloadManager:
		return
	var item = DownloadManager.get_item(item_id)
	if item and item.game_resource and game and item.game_resource.romm_id == game.romm_id:
		_is_downloading = false
		if success:
			if DataManager:
				var updated = DataManager.get_game_by_id(game.romm_id)
				if updated:
					game = updated
		_update_status_icon()

func _on_cover_loaded(url: String, texture: Texture2D):
	if not is_instance_valid(self) or not game:
		return
	if game.cover_url == url and texture:
		_set_texture(texture)

func set_placeholder(is_placeholder: bool):
	if is_placeholder:
		_set_texture(_loading_texture)
		if status_icon:
			status_icon.visible = false
		if status_badge:
			status_badge.visible = false
		# Disable platform badge in shader for placeholders
		var mat = material as ShaderMaterial
		if mat:
			mat.set_shader_parameter("platform_badge_enabled", false)
	else:
		_update_display()

func set_card_zoom(new_zoom: float) -> void:
	_current_zoom = new_zoom
	
	var base_dims = _get_base_dimensions()
	var card_width = base_dims.x * new_zoom
	var card_height = base_dims.y * new_zoom
	
	# Set both custom_minimum_size and size to ensure GridContainer respects our dimensions
	custom_minimum_size = Vector2(card_width, card_height)
	size = Vector2(card_width, card_height)
	
	# Prevent GridContainer from stretching the card
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	
	if status_badge:
		var badge_size = BASE_BADGE_SIZE * new_zoom
		var badge_margin = BASE_BADGE_MARGIN * new_zoom
		var badge_corner = int(BASE_BADGE_CORNER * new_zoom)
		
		status_badge.offset_left = -badge_size - badge_margin
		status_badge.offset_top = -badge_size - badge_margin
		status_badge.offset_right = -badge_margin
		status_badge.offset_bottom = -badge_margin
		
		var new_style = StyleBoxFlat.new()
		new_style.bg_color = Color(0, 0, 0, 0.6)
		new_style.corner_radius_top_left = badge_corner
		new_style.corner_radius_top_right = badge_corner
		new_style.corner_radius_bottom_left = badge_corner
		new_style.corner_radius_bottom_right = badge_corner
		status_badge.add_theme_stylebox_override("panel", new_style)
	
	if status_icon:
		var icon_size = BASE_ICON_SIZE * new_zoom / 2.0
		status_icon.offset_left = -icon_size
		status_icon.offset_top = -icon_size
		status_icon.offset_right = icon_size
		status_icon.offset_bottom = icon_size
	
	_update_shader_params()
	_update_platform_badge()  # Reload platform icon with new zoom scale

func get_current_zoom() -> float:
	return _current_zoom

func _update_shader_params() -> void:
	var mat = material as ShaderMaterial
	if not mat:
		return
	
	var corner_val = 12
	var enabled_val = false
	var size_val = 0.05
	var color_val = Color.WHITE
	
	var base_dims = _get_base_dimensions()
	var base_width = base_dims.x
	var base_height = base_dims.y
	
	if SettingsManager:
		var corner_setting = SettingsManager.get_setting("corner_radius")
		var border_enabled_setting = SettingsManager.get_setting("border_enabled")
		var border_size_setting = SettingsManager.get_setting("border_size")
		var border_fade_in_setting = SettingsManager.get_setting("border_fade_in")
		var border_color_setting = SettingsManager.get_setting("border_color")
		
		corner_val = corner_setting.value if corner_setting else 12
		enabled_val = border_enabled_setting.value if border_enabled_setting else false
		size_val = border_size_setting.value if border_size_setting else 0.05
		var fade_in_val = border_fade_in_setting.value if border_fade_in_setting else 0.0
		color_val = border_color_setting.value if border_color_setting else Color.WHITE
		
		var fade_in_pixels = fade_in_val * base_width * 2.0 * _current_zoom
		mat.set_shader_parameter("border_fade_in_pixels", fade_in_pixels)
	
	# Corner radius scales with zoom for consistent visual
	var corner_pixels = corner_val * _current_zoom
	
	# Border values in pixels (settings are proportional 0.0-0.5)
	var border_pixels = size_val * base_width * 2.0 * _current_zoom
	
	# Calculate actual card size
	var actual_width = base_width * _current_zoom
	var actual_height = base_height * _current_zoom
	
	mat.set_shader_parameter("card_size", Vector2(actual_width, actual_height))
	mat.set_shader_parameter("corner_radius_pixels", corner_pixels)
	mat.set_shader_parameter("border_width_pixels", border_pixels if enabled_val else 0.0)
	mat.set_shader_parameter("border_enabled", enabled_val)
	mat.set_shader_parameter("border_color", color_val)
	mat.set_shader_parameter("game_texture", _current_texture)

func _update_shader_platform_params(icon_texture: Texture2D) -> void:
	var mat = material as ShaderMaterial
	if not mat:
		return
	
	var show_badge = false
	if SettingsManager:
		var badge_setting = SettingsManager.get_setting("platform_badge")
		if badge_setting:
			show_badge = badge_setting.value
	
	# Show badge if setting is enabled (icon is optional for now)
	mat.set_shader_parameter("platform_badge_enabled", show_badge)
	if icon_texture:
		mat.set_shader_parameter("platform_badge_icon", icon_texture)
	
	# Set badge size scale - multiply by zoom to keep proportional to card
	var badge_size = 1.0
	if SettingsManager:
		var badge_size_setting = SettingsManager.get_setting("platform_badge_size")
		if badge_size_setting:
			badge_size = badge_size_setting.value
	# Scale badge size with card zoom to maintain proportions
	mat.set_shader_parameter("platform_badge_size", badge_size * _current_zoom)
	
	# Set inner corner radius
	var inner_radius = 0.0
	if SettingsManager:
		var inner_radius_setting = SettingsManager.get_setting("platform_badge_inner_radius")
		if inner_radius_setting:
			inner_radius = inner_radius_setting.value
	mat.set_shader_parameter("platform_badge_inner_radius", inner_radius)
	
	# Set icon padding
	var icon_padding = 0.5
	if SettingsManager:
		var icon_padding_setting = SettingsManager.get_setting("platform_badge_icon_padding")
		if icon_padding_setting:
			icon_padding = icon_padding_setting.value
	mat.set_shader_parameter("platform_badge_icon_padding", icon_padding)
	
	# Set icon color
	var icon_color = Color.WHITE
	if SettingsManager:
		var icon_color_setting = SettingsManager.get_setting("platform_badge_icon_color")
		if icon_color_setting:
			icon_color = icon_color_setting.value
	# Icon is now rendered via TextureRect, no need to pass to shader

func _update_platform_icon_rect(icon_texture: Texture2D) -> void:
	if not platform_icon:
		return
	
	if not icon_texture:
		platform_icon.visible = false
		return
	
	# Get all the values we need (same as shader)
	var badge_size_setting = 1.0
	var icon_padding_setting = 0.5
	var inner_radius_setting = 0.0
	var corner_radius = 12
	var icon_color = Color.WHITE
	
	if SettingsManager:
		var badge_size_var = SettingsManager.get_setting("platform_badge_size")
		if badge_size_var:
			badge_size_setting = badge_size_var.value
		
		var icon_padding_var = SettingsManager.get_setting("platform_badge_icon_padding")
		if icon_padding_var:
			icon_padding_setting = icon_padding_var.value
		
		var inner_radius_var = SettingsManager.get_setting("platform_badge_inner_radius")
		if inner_radius_var:
			inner_radius_setting = inner_radius_var.value
		
		var corner_var = SettingsManager.get_setting("corner_radius")
		if corner_var:
			corner_radius = corner_var.value
		
		var icon_color_setting = SettingsManager.get_setting("platform_badge_icon_color")
		if icon_color_setting:
			icon_color = icon_color_setting.value
	
	# Calculate badge size (same formula as shader)
	var base_badge_size = 32.0 * badge_size_setting * _current_zoom
	var badge_size = max(base_badge_size, corner_radius * _current_zoom)
	
	# Calculate padding (same formula as shader)
	var base_padding = 8.0 * badge_size_setting * _current_zoom * icon_padding_setting
	var outer_padding = corner_radius * _current_zoom * 0.3 * icon_padding_setting
	var total_padding = base_padding + outer_padding
	
	# Calculate available size for icon
	var available_size = badge_size - total_padding * 2.0
	available_size = max(available_size, badge_size * 0.4)
	
	# Calculate max inner radius
	var max_inner_radius = max(0.0, badge_size)
	var inner_radius = max_inner_radius * clamp(inner_radius_setting, 0.0, 1.0)
	
	# Calculate shifts (same formula as shader)
	var outer_shift = corner_radius * _current_zoom * 0.15
	var inner_shift = inner_radius * 0.15
	
	# Calculate position
	var padding_left = total_padding + outer_shift - inner_shift
	var padding_top = total_padding + outer_shift - inner_shift
	
	# Position and size the TextureRect
	platform_icon.visible = true
	platform_icon.texture = icon_texture
	platform_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	platform_icon.offset_left = padding_left
	platform_icon.offset_top = padding_top
	platform_icon.offset_right = padding_left + available_size
	platform_icon.offset_bottom = padding_top + available_size
	
	# Apply icon color using custom shader material
	var shader_material = ShaderMaterial.new()
	shader_material.shader = preload("res://shaders/icon_color_shader.gdshader")
	shader_material.set_shader_parameter("icon_color", icon_color)
	platform_icon.material = shader_material

func _get_base_dimensions() -> Vector2:
	if SettingsManager:
		var orientation_setting = SettingsManager.get_setting("card_orientation")
		if orientation_setting:
			# Array settings store the index, not the string
			var orientation_idx = orientation_setting.value
			match orientation_idx:
				1: # Horizontal
					return Vector2(HORIZONTAL_WIDTH, HORIZONTAL_HEIGHT)
				2: # Square
					return Vector2(SQUARE_WIDTH, SQUARE_HEIGHT)
				_: # 0 = Vertical (default)
					return Vector2(VERTICAL_WIDTH, VERTICAL_HEIGHT)
	return Vector2(VERTICAL_WIDTH, VERTICAL_HEIGHT)

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	if setting.property_name == "card_orientation":
		# Orientation changed - update card size for preview cards
		set_card_zoom(_current_zoom)
		# Also rebuild the grid layout for non-preview cards
		if not preview_mode and UIManager:
			UIManager.rebuild_game_grid()
	elif setting.property_name in ["corner_radius", "border_enabled", "border_size", "border_fade_in", "border_color"]:
		_update_shader_params()
		_update_platform_badge()
	elif setting.property_name == "platform_badge":
		_update_platform_badge()
	elif setting.property_name in ["platform_badge_size", "platform_badge_inner_radius", "platform_badge_icon_padding", "platform_badge_icon_color"]:
		_update_platform_badge()

func update_display() -> void:
	_update_display()
