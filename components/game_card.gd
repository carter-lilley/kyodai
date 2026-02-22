class_name GameCard
extends ColorRect

signal download_requested(game: GameResource)

@export var game: GameResource:
	set(value):
		game = value
		_update_display()

func set_game_with_priority(value: GameResource, high_priority: bool):
	game = value
	_update_display_with_priority(high_priority)

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

const VERTICAL_WIDTH: float = 202.0
const VERTICAL_HEIGHT: float = 270.0
const HORIZONTAL_WIDTH: float = 270.0
const HORIZONTAL_HEIGHT: float = 202.0
const SQUARE_WIDTH: float = 256.0
const SQUARE_HEIGHT: float = 256.0

var _current_zoom: float = 1.0
var _current_texture: Texture2D = null
var _card_state: CardState = CardState.new()

var _base_effect: BaseCardEffect = null
var _border_effect: BorderEffect = null
var _badge_effect: BadgeEffect = null

var _loading_game_id: String = ""
var _image_retry_count: int = 0
var _current_image_task_id: int = -1
const MAX_IMAGE_RETRIES: int = 3

func _ready():
	if SettingsManager:
		SettingsManager.setting_changed.connect(_on_setting_changed)
	
	if preview_mode:
		_setup_preview_mode()
		return
	
	_update_card_state_from_settings()
	_rebuild_effects()
	set_card_zoom(_current_zoom)
	_update_display()
	
	if card_input:
		card_input.pressed.connect(_on_card_pressed)
		card_input.gui_input.connect(_on_card_gui_input)
	
	if DownloadManager:
		DownloadManager.download_progress.connect(_on_download_progress)
		DownloadManager.download_completed.connect(_on_download_completed)

func _setup_preview_mode():
	_update_card_state_from_settings()
	_rebuild_effects()
	set_card_zoom(_current_zoom)
	
	if DataManager:
		var random_game = DataManager.get_random_game()
		if random_game:
			self.game = random_game
		else:
			_set_texture(_loading_texture)
	else:
		_set_texture(_loading_texture)
	
	if status_badge:
		status_badge.visible = false
	
	if card_input:
		card_input.disabled = true
		card_input.mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_card_state(state: CardState) -> void:
	_card_state = state.duplicate()
	_rebuild_effects()
	if _base_effect:
		_base_effect.update_state(_card_state)
	if _border_effect:
		_border_effect.update_state(_card_state)
	if _badge_effect:
		_badge_effect.update_state(_card_state)
	set_card_zoom(_card_state.zoom_level)

func get_card_state() -> CardState:
	return _card_state

func _update_card_state_from_settings():
	_card_state.zoom_level = _current_zoom
	_card_state.orientation = _get_orientation_index()
	_card_state.corner_radius = _get_corner_radius_from_settings()
	_card_state.update_from_zoom(_current_zoom)
	
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			_card_state.effect_settings = config_setting.value.get("effects", [])

func _get_orientation_index() -> int:
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			return config_setting.value.get("card_orientation", 0)
	return 0

func _get_corner_radius_from_settings() -> float:
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			return config_setting.value.get("corner_radius", 12.0)
	return 12.0

func _rebuild_effects():
	for child in get_children():
		if child is CardEffect:
			child.queue_free()
	
	_base_effect = null
	_border_effect = null
	_badge_effect = null
	
	_base_effect = BaseCardEffect.new()
	_base_effect.name = "BaseEffect"
	_base_effect.anchor_right = 1.0
	_base_effect.anchor_bottom = 1.0
	add_child(_base_effect)
	_base_effect.initialize(_card_state, {})
	
	var border_config = _get_effect_config("border")
	if border_config:
		_border_effect = BorderEffect.new()
		_border_effect.name = "BorderEffect"
		_border_effect.anchor_right = 1.0
		_border_effect.anchor_bottom = 1.0
		add_child(_border_effect)
		_border_effect.initialize(_card_state, border_config.get("settings", {}))
	
	var badge_config = _get_effect_config("badge")
	if badge_config:
		_badge_effect = BadgeEffect.new()
		_badge_effect.name = "BadgeEffect"
		_badge_effect.anchor_right = 1.0
		_badge_effect.anchor_bottom = 1.0
		add_child(_badge_effect)
		_badge_effect.initialize(_card_state, badge_config.get("settings", {}))
		
		if _border_effect:
			var border_size = border_config.get("settings", {}).get("border_size", 0.05)
			var border_pixels = border_size * _card_state.base_width * 2.0 * _card_state.zoom_level
			_badge_effect.set_border_width(border_pixels)
	
	if card_input:
		move_child(card_input, -1)
	
	if _current_texture:
		_set_texture(_current_texture)
	
	_update_platform_badge()

func _get_effect_config(effect_id: String) -> Dictionary:
	for effect_data in _card_state.effect_settings:
		if effect_data.get("effect_id") == effect_id:
			return effect_data
	return {}

func _update_display():
	if not game:
		return
	if not is_node_ready():
		return
	_update_status_icon()
	_update_platform_badge()
	_load_cover(false)

func _update_display_with_priority(high_priority: bool):
	if not game:
		return
	if not is_node_ready():
		return
	_update_status_icon()
	_update_platform_badge()
	_load_cover(high_priority)

func load_cover_with_priority(high_priority: bool = false):
	_load_cover(high_priority)

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
	if not _badge_effect:
		if platform_icon:
			platform_icon.visible = false
		return
	
	if not game:
		if platform_icon:
			platform_icon.visible = false
		return
	
	var platform_slug = game.platform_slug
	var icon_texture: Texture2D = null
	if platform_slug:
		var icon_path = "res://assets/platforms/icon/icon_%s.png" % platform_slug
		if FileAccess.file_exists(icon_path):
			icon_texture = load(icon_path)
	
	if icon_texture:
		_update_platform_icon_rect(icon_texture)
	else:
		if platform_icon:
			platform_icon.visible = false

func _update_platform_icon_rect(icon_texture: Texture2D):
	if not platform_icon:
		return
	if not icon_texture:
		platform_icon.visible = false
		return
	
	platform_icon.visible = true
	
	var badge_config = _get_effect_config("badge")
	var settings = badge_config.get("settings", {})
	
	var badge_size_setting = settings.get("badge_size", 1.0)
	var inner_radius_setting = settings.get("badge_inner_radius", 0.0)
	var icon_padding = settings.get("icon_padding", 0.5)
	var icon_color = settings.get("icon_color", Color.WHITE)
	var card_corner = _card_state.corner_radius / _current_zoom
	
	var base_badge_size = 32.0
	var icon_size = icon_texture.get_size()
	var icon_aspect = icon_size.x / icon_size.y if icon_size.y > 0 else 1.0
	
	var badge_width: float
	var badge_height: float
	if icon_aspect >= 1.0:
		badge_width = base_badge_size * icon_aspect
		badge_height = base_badge_size
	else:
		badge_width = base_badge_size
		badge_height = base_badge_size / icon_aspect
	
	var base_min_dim = min(badge_width, badge_height)
	var base_inner_corner = (base_min_dim * 0.5) * clamp(inner_radius_setting, 0.0, 1.0)
	
	var scale = badge_size_setting * _current_zoom
	var scaled_width = badge_width * scale
	var scaled_height = badge_height * scale
	
	var scaled_min_dim = min(scaled_width, scaled_height)
	
	var corner_midpoint_factor = 1.0 - sqrt(2.0) / 2.0
	var scaled_outer = _card_state.corner_radius * corner_midpoint_factor
	var scaled_inner = base_inner_corner * scale * corner_midpoint_factor
	var max_outer = scaled_min_dim * 0.4
	scaled_outer = min(scaled_outer, max_outer)
	
	if _badge_effect:
		_badge_effect.set_badge_dimensions(Vector2(scaled_width, scaled_height))
	
	var safe_x = scaled_outer
	var safe_y = scaled_outer
	var safe_width = scaled_width - scaled_outer - scaled_inner
	var safe_height = scaled_height - scaled_outer - scaled_inner
	safe_width = max(safe_width, 1.0)
	safe_height = max(safe_height, 1.0)
	
	var padding = min(safe_width, safe_height) * icon_padding * 0.25
	safe_x += padding
	safe_y += padding
	safe_width -= padding * 2.0
	safe_height -= padding * 2.0
	safe_width = max(safe_width, 1.0)
	safe_height = max(safe_height, 1.0)
	
	var icon_draw_width: float
	var icon_draw_height: float
	var safe_aspect = safe_width / safe_height
	
	if icon_aspect > safe_aspect:
		icon_draw_width = safe_width
		icon_draw_height = safe_width / icon_aspect
	else:
		icon_draw_height = safe_height
		icon_draw_width = safe_height * icon_aspect
	
	var icon_offset_x = safe_x + (safe_width - icon_draw_width) * 0.5
	var icon_offset_y = safe_y + (safe_height - icon_draw_height) * 0.5
	
	platform_icon.visible = true
	platform_icon.texture = icon_texture
	platform_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	platform_icon.offset_left = icon_offset_x
	platform_icon.offset_top = icon_offset_y
	platform_icon.offset_right = icon_offset_x + icon_draw_width
	platform_icon.offset_bottom = icon_offset_y + icon_draw_height
	platform_icon.modulate = Color.WHITE
	
	var shader_material = ShaderMaterial.new()
	shader_material.shader = preload("res://shaders/icon_color_shader.gdshader")
	shader_material.set_shader_parameter("icon_color", icon_color)
	platform_icon.material = shader_material

func _load_cover(high_priority: bool = false):
	if not game:
		_set_texture(_loading_texture)
		return
	
	_loading_game_id = game.id
	_image_retry_count = 0
	
	var cache_path = ""
	if game.cover_path and FileAccess.file_exists(game.cover_path):
		cache_path = game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		cache_path = _get_cached_cover_path(game.cover_url)
		if not FileAccess.file_exists(cache_path):
			cache_path = ""
	
	if cache_path == "":
		_set_texture(_loading_texture)
		return
	
	var cached_tex = MemoryManager.get_cached_texture(cache_path)
	if cached_tex:
		_set_texture(cached_tex)
		return
	
	_load_cached_cover(cache_path, high_priority)

func _get_cached_cover_path(url: String) -> String:
	const CACHE_FOLDER = "user://cache/covers/"
	return CACHE_FOLDER + url.md5_text() + ".jpg"

func _load_cached_cover(cache_path: String, high_priority: bool = false):
	var target_game_id = _loading_game_id
	
	if not MemoryManager:
		_set_texture(_loading_texture)
		return
	
	if _current_image_task_id > 0:
		MemoryManager.cancel_image_task(_current_image_task_id)
	
	var load_callable = func():
		var file = FileAccess.open(cache_path, FileAccess.READ)
		if file:
			var buffer = file.get_buffer(file.get_length())
			file.close()
			return _load_texture_from_buffer(buffer)
		return null
	
	var callback_callable = func(texture):
		_current_image_task_id = -1
		if not is_instance_valid(self):
			return
		if not game or game.id != target_game_id:
			return
		
		if texture:
			MemoryManager.cache_texture(cache_path, texture)
			_set_texture(texture)
		else:
			_image_retry_count += 1
			if _image_retry_count < MAX_IMAGE_RETRIES:
				await get_tree().create_timer(0.1 * _image_retry_count).timeout
				if is_instance_valid(self) and game and game.id == target_game_id:
					_load_cached_cover(cache_path, high_priority)
	
	_current_image_task_id = MemoryManager.queue_image_task(load_callable, callback_callable, high_priority)

func _load_texture_from_buffer(buffer: PackedByteArray) -> Texture2D:
	if buffer.size() < 16:
		return null
	
	var image = Image.new()
	var err = FAILED
	
	if buffer[0] == 0xFF and buffer[1] == 0xD8:
		err = image.load_jpg_from_buffer(buffer)
	elif buffer[0] == 0x89 and buffer[1] == 0x50:
		err = image.load_png_from_buffer(buffer)
	else:
		err = image.load_webp_from_buffer(buffer)
	
	if err == OK:
		return ImageTexture.create_from_image(image)
	return null

func _set_texture(tex: Texture2D) -> void:
	_current_texture = tex
	if _base_effect:
		_base_effect.set_game_texture(tex)
	_card_state.game_texture = tex

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

func set_placeholder(is_placeholder: bool):
	if is_placeholder:
		_set_texture(_loading_texture)
		if status_icon:
			status_icon.visible = false
		if status_badge:
			status_badge.visible = false
	else:
		_update_display()

func reset():
	if _current_image_task_id > 0:
		MemoryManager.cancel_image_task(_current_image_task_id)
		_current_image_task_id = -1
	_loading_game_id = ""
	_image_retry_count = 0
	game = null
	_set_texture(_loading_texture)

func set_image_priority(high_priority: bool):
	if _current_image_task_id > 0:
		MemoryManager.update_image_priority(_current_image_task_id, high_priority)
	elif high_priority and game:
		_load_cover(true)

func set_card_zoom(new_zoom: float) -> void:
	_current_zoom = new_zoom
	
	var base_dims = _get_base_dimensions()
	var card_width = base_dims.x * new_zoom
	var card_height = base_dims.y * new_zoom
	
	custom_minimum_size = Vector2(card_width, card_height)
	size = Vector2(card_width, card_height)
	
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
	
	_card_state.update_from_zoom(new_zoom)
	
	if _base_effect:
		_base_effect.update_state(_card_state)
	if _border_effect:
		_border_effect.update_state(_card_state)
	if _badge_effect:
		_badge_effect.update_state(_card_state)
	
	_update_platform_badge()

func get_current_zoom() -> float:
	return _current_zoom

func _get_base_dimensions() -> Vector2:
	match _card_state.orientation:
		1: return Vector2(HORIZONTAL_WIDTH, HORIZONTAL_HEIGHT)
		2: return Vector2(SQUARE_WIDTH, SQUARE_HEIGHT)
		_: return Vector2(VERTICAL_WIDTH, VERTICAL_HEIGHT)

func _on_setting_changed(_value: Variant, setting: SettingsVar) -> void:
	if setting.property_name == "card_effect_config":
		var old_orientation = _card_state.orientation
		var new_orientation = _get_orientation_index()
		
		if old_orientation != new_orientation:
			_card_state.orientation = new_orientation
			if not preview_mode and UIManager:
				UIManager.rebuild_game_grid()
				return
		
		_rebuild_effects()
		set_card_zoom(_current_zoom)

func update_display() -> void:
	_update_display()
