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

@onready var visual_container: Control = $VisualContainer
@onready var card_input: Button = $VisualContainer/CardInput
@onready var status_icon: TextureRect = $VisualContainer/CardInput/StatusBadge/StatusIcon
@onready var status_badge: Panel = $VisualContainer/CardInput/StatusBadge
@onready var platform_icon: TextureRect = $VisualContainer/CardInput/PlatformIcon

var _loading_texture: Texture2D = preload("res://icon.svg")
var _download_icon: Texture2D = preload("res://assets/ui/icons/download.png")
var _play_icon: Texture2D = preload("res://assets/ui/icons/play.png")
var _is_downloading: bool = false

# Ratio-based constants (as fraction of card width)
const BADGE_SIZE_RATIO: float = 0.12  # ~24px at default width (reduced from 0.16)
const BADGE_MARGIN_RATIO: float = 0.04  # ~8px at default width
const BADGE_CORNER_RATIO: float = 0.11  # ~23px at default width

# Debug
var _debug_safe_area: ColorRect = null
const ICON_SIZE_RATIO: float = 0.11  # ~22px at default width

var _current_texture: Texture2D = null
var _card_state: CardState = CardState.new()

# Static cache for icon materials to reduce shader compilation overhead
static var _icon_material_cache: Dictionary = {}

var _base_effect: BaseCardEffect = null
var _border_effect: BorderEffect = null
var _badge_effect: BadgeEffect = null
var _drop_shadow_effect: DropShadowEffect = null
var _glow_effect: GlowEffect = null

var _loading_game_id: String = ""
var _image_retry_count: int = 0
var _current_image_task_id: int = -1
const MAX_IMAGE_RETRIES: int = 3

const FOCUSED_SCALE: float = 1.08
const FOCUS_TWEEN_DURATION: float = 0.12
const FOCUSED_BORDER_MULTIPLIER: float = 0.85  # Border is 65% of normal size when focused (smaller)
var _focus_tween: Tween = null
var _original_border_size: float = 0.05  # Default border size, will be set from config

# Enter animation constants
const ENTER_START_SCALE: float = 3.0
const ENTER_TWEEN_DURATION: float = 1.75
var _enter_tween: Tween = null
var _enter_tween_alpha: Tween = null

func _ready():
	# Allow effects (like drop shadow) to render outside card bounds
	clip_contents = false
	# Cards render above UI backgrounds, shadows at -1 stay behind card but above backgrounds
	z_index = 10
	
	# Set pivot to center for proper scaling on visual container
	# Use custom_minimum_size as fallback since visual_container might not be laid out yet
	var pivot_size = visual_container.size if visual_container.size.x > 0 else custom_minimum_size
	visual_container.pivot_offset = pivot_size / 2
	
	if preview_mode:
		_setup_preview_mode()
		return
	
	# Connect to CardState signals for reactivity
	_card_state.zoom_changed.connect(_on_zoom_changed)
	_card_state.orientation_changed.connect(_on_orientation_changed)
	
	_update_card_state_from_settings()
	_rebuild_effects()
	_update_display()
	
	if card_input:
		card_input.pressed.connect(_on_card_pressed)
		card_input.gui_input.connect(_on_card_gui_input)
		card_input.focus_entered.connect(_on_focus_entered)
		card_input.focus_exited.connect(_on_focus_exited)
	
	if DownloadManager:
		DownloadManager.download_progress.connect(_on_download_progress)
		DownloadManager.download_completed.connect(_on_download_completed)

func _setup_preview_mode():
	_update_card_state_from_settings()
	_rebuild_effects()
	
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
	# Disconnect old signals safely
	if _card_state and _card_state.zoom_changed.is_connected(_on_zoom_changed):
		_card_state.zoom_changed.disconnect(_on_zoom_changed)
	if _card_state and _card_state.orientation_changed.is_connected(_on_orientation_changed):
		_card_state.orientation_changed.disconnect(_on_orientation_changed)
	
	_card_state = state.duplicate()
	_rebuild_effects()
	
	# Reconnect signals
	_card_state.zoom_changed.connect(_on_zoom_changed)
	_card_state.orientation_changed.connect(_on_orientation_changed)
	
	# Trigger updates
	_on_zoom_changed(_card_state.zoom_level)
	_on_orientation_changed(_card_state.orientation)

func get_card_state() -> CardState:
	return _card_state

func get_focus_shape_params() -> Dictionary:
	return {
		"shape_size": _card_state.card_size,
		"corner_radius_ratio": _card_state.corner_radius_ratio
	}

func _update_card_state_from_settings():
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			_card_state.orientation = config_setting.value.get("card_orientation", 0)
			_card_state.effect_settings = config_setting.value.get("effects", [])
			# Corner radius as ratio (0.0 to 0.5) - convert from pixels if needed
			var corner_pixels = config_setting.value.get("corner_radius", 12.0)
			# Default card width is 202, so 12px / 202 = ~0.06
			_card_state.corner_radius_ratio = corner_pixels / 202.0

func _get_effect_config(effect_id: String) -> Dictionary:
	for effect_data in _card_state.effect_settings:
		if effect_data.get("effect_id") == effect_id:
			return effect_data
	return {}

func _rebuild_effects():
	# Update or create effects - don't destroy existing ones
	# This reduces GC pressure and shader compilation stutter during scroll
	if not visual_container:
		push_warning("GameCard: visual_container is null, cannot add effects")
		return
	
	_card_state.border_inset_ratio = 0.0
	
	# Base effect - required
	if _base_effect == null:
		_base_effect = BaseCardEffect.new()
		_base_effect.name = "BaseEffect"
		_base_effect.anchor_right = 1.0
		_base_effect.anchor_bottom = 1.0
		visual_container.add_child(_base_effect)
		_base_effect.initialize(_card_state, {})
	else:
		_base_effect.update_state(_card_state)
	
	# Badge effect - optional
	var badge_config = _get_effect_config("badge")
	if badge_config:
		if _badge_effect == null:
			_badge_effect = BadgeEffect.new()
			_badge_effect.name = "BadgeEffect"
			_badge_effect.anchor_right = 1.0
			_badge_effect.anchor_bottom = 1.0
			visual_container.add_child(_badge_effect)
			_badge_effect.initialize(_card_state, badge_config.get("settings", {}))
		else:
			_badge_effect.update_state(_card_state)
			_badge_effect.update_settings(badge_config.get("settings", {}))
	elif _badge_effect != null:
		# Config removed but effect exists - hide it
		_badge_effect.visible = false
	
	# Border effect - optional
	var border_config = _get_effect_config("border")
	if border_config:
		if _border_effect == null:
			_border_effect = BorderEffect.new()
			_border_effect.name = "BorderEffect"
			_border_effect.anchor_right = 1.0
			_border_effect.anchor_bottom = 1.0
			visual_container.add_child(_border_effect)
			_border_effect.initialize(_card_state, border_config.get("settings", {}))
		else:
			_border_effect.update_state(_card_state)
			_border_effect.update_settings(border_config.get("settings", {}))
		
		# Calculate border inset
		var border_size = border_config.get("settings", {}).get("border_size", 0.05)
		_original_border_size = border_size
		var fade_in = border_config.get("settings", {}).get("border_fade_in", 0.0)
		_card_state.border_inset_ratio = border_size + fade_in
	elif _border_effect != null:
		_border_effect.visible = false
	
	# Configure badge with border info
	if _badge_effect and _badge_effect.visible:
		_badge_effect.set_border_width(_card_state.border_inset_ratio)
		_badge_effect.set_border_inset_pixels(_card_state.border_inset_ratio * _card_state.card_size.x)
	
	# Glow effect - optional
	var glow_config = _get_effect_config("glow")
	if glow_config:
		if _glow_effect == null:
			_glow_effect = GlowEffect.new()
			_glow_effect.name = "GlowEffect"
			_glow_effect.set_anchors_preset(Control.PRESET_CENTER)
			visual_container.add_child(_glow_effect)
			_glow_effect.initialize(_card_state, glow_config.get("settings", {}))
			visual_container.move_child(_glow_effect, 0)
		else:
			_glow_effect.update_state(_card_state)
			_glow_effect.update_settings(glow_config.get("settings", {}))
			_glow_effect.visible = true
	elif _glow_effect != null:
		_glow_effect.visible = false
	
	# Drop shadow effect - optional
	var drop_shadow_config = _get_effect_config("drop_shadow")
	if drop_shadow_config:
		if _drop_shadow_effect == null:
			_drop_shadow_effect = DropShadowEffect.new()
			_drop_shadow_effect.name = "DropShadowEffect"
			_drop_shadow_effect.set_anchors_preset(Control.PRESET_CENTER)
			visual_container.add_child(_drop_shadow_effect)
			_drop_shadow_effect.initialize(_card_state, drop_shadow_config.get("settings", {}))
			visual_container.move_child(_drop_shadow_effect, 0 if _glow_effect == null or not _glow_effect.visible else 1)
		else:
			_drop_shadow_effect.update_state(_card_state)
			_drop_shadow_effect.update_settings(drop_shadow_config.get("settings", {}))
			_drop_shadow_effect.visible = true
	elif _drop_shadow_effect != null:
		_drop_shadow_effect.visible = false
	
	# Ensure card_input is on top
	if card_input:
		visual_container.move_child(card_input, -1)
	
	if _current_texture:
		_set_texture(_current_texture)
	
	_update_platform_badge()

func _on_zoom_changed(_new_zoom: float) -> void:
	var card_size = _card_state.card_size
	custom_minimum_size = card_size
	size = card_size
	pivot_offset = card_size / 2
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	
	_update_status_badge_layout()
	_update_platform_badge()

func _on_orientation_changed(_new_orientation: int) -> void:
	_on_zoom_changed(_card_state.zoom_level)

func _update_status_badge_layout():
	if not status_badge:
		return
	
	var card_width = _card_state.card_size.x
	var badge_size = BADGE_SIZE_RATIO * card_width
	var badge_margin = BADGE_MARGIN_RATIO * card_width
	var badge_corner = int(BADGE_CORNER_RATIO * card_width)
	var border_inset_pixels = _card_state.border_inset_ratio * card_width
	
	# Account for border inset so badge doesn't overlap the border
	status_badge.offset_left = -badge_size - badge_margin - border_inset_pixels
	status_badge.offset_top = -badge_size - badge_margin - border_inset_pixels
	status_badge.offset_right = -badge_margin - border_inset_pixels
	status_badge.offset_bottom = -badge_margin - border_inset_pixels
	
	var new_style = StyleBoxFlat.new()
	new_style.bg_color = Color(0, 0, 0, 0.4)
	new_style.corner_radius_top_left = badge_corner
	new_style.corner_radius_top_right = badge_corner
	new_style.corner_radius_bottom_left = badge_corner
	new_style.corner_radius_bottom_right = badge_corner
	status_badge.add_theme_stylebox_override("panel", new_style)
	
	if status_icon:
		var icon_size = ICON_SIZE_RATIO * card_width * 0.5
		status_icon.offset_left = -icon_size
		status_icon.offset_top = -icon_size
		status_icon.offset_right = icon_size
		status_icon.offset_bottom = icon_size

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
		if ResourceLoader.exists(icon_path):
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
	var badge_type = settings.get("badge_type", 0)
	
	# For top bar mode, use wordmark instead of icon
	var texture_to_use = icon_texture
	if badge_type == 1 and game and game.platform_slug:
		var wordmark_path = "res://assets/platforms/wordmark/wordmark_" + game.platform_slug + ".png"
		if ResourceLoader.exists(wordmark_path):
			var wordmark_tex = load(wordmark_path)
			if wordmark_tex:
				texture_to_use = wordmark_tex
	
	var card_width = _card_state.card_size.x
	var corner_radius_pixels = _card_state.corner_radius_ratio * card_width
	var border_inset_pixels = _card_state.border_inset_ratio * card_width
	
	# Effective corner radius at the inset position
	var effective_corner_radius = max(0, corner_radius_pixels - border_inset_pixels)
	
	# Base badge size as ratio of card width
	var base_badge_size = BADGE_SIZE_RATIO * card_width
	var texture_size = texture_to_use.get_size()
	var texture_aspect = texture_size.x / texture_size.y if texture_size.y > 0 else 1.0
	
	# Clamp aspect ratio to square
	if badge_type != 1:
		texture_aspect = 1.0
	
	# Handle top bar badge type differently
	if badge_type == 1:
		# Top bar: full width, height based on badge size
		var bar_height = base_badge_size * badge_size_setting
		
		# Calculate horizontal safe zone based on corner radius (at inset position)
		var corner_midpoint_factor = 1.0 - sqrt(2.0) / 2.0
		var corner_margin = effective_corner_radius * corner_midpoint_factor
		var max_wordmark_width = (card_width - border_inset_pixels * 2) - (corner_margin * 2)
		var safe_x = border_inset_pixels + corner_margin
		
		# Padding slider: 0 = 60% height (minimum), 1 = 30% height (maximum padding)
		# Range: 60% down to 30% of bar height
		var available_height = bar_height * (0.6 - icon_padding * 0.3)
		
		# Calculate wordmark dimensions
		var draw_height = available_height
		var draw_width = available_height * texture_aspect
		
		# Clamp width to fit within safe zone between corners
		if draw_width > max_wordmark_width:
			draw_width = max_wordmark_width
			draw_height = draw_width / texture_aspect
		
		# Center horizontally within safe zone
		var offset_x = safe_x + (max_wordmark_width - draw_width) * 0.5
		var offset_y = border_inset_pixels + (bar_height - draw_height) * 0.5
		
		platform_icon.visible = true
		platform_icon.texture = texture_to_use
		platform_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		platform_icon.offset_left = offset_x
		platform_icon.offset_top = offset_y
		platform_icon.offset_right = offset_x + draw_width
		platform_icon.offset_bottom = offset_y + draw_height
		platform_icon.modulate = Color.WHITE
		
		var shader_material = ShaderMaterial.new()
		shader_material.shader = preload("res://shaders/icon_color_shader.gdshader")
		shader_material.set_shader_parameter("icon_color", icon_color)
		platform_icon.material = shader_material
		
		if _badge_effect:
			# For top bar, pass full card width and bar height
			_badge_effect.set_badge_dimensions(Vector2(card_width, bar_height))
			_badge_effect.set_border_inset_pixels(border_inset_pixels)
			_badge_effect.set_safe_zone(offset_x, offset_y, draw_width, draw_height, false)
		
		return
	
	
	var badge_width: float
	var badge_height: float
	if texture_aspect >= 1.0:
		badge_width = base_badge_size * texture_aspect
		badge_height = base_badge_size
	else:
		badge_width = base_badge_size
		badge_height = base_badge_size / texture_aspect
	
	var base_min_dim = min(badge_width, badge_height)
	var base_inner_corner = (base_min_dim * 0.5) * clamp(inner_radius_setting, 0.0, 1.0)
	
	var scale = badge_size_setting
	var scaled_width = badge_width * scale
	var scaled_height = badge_height * scale
	
	# Minimum size based on corner radius
	var min_badge_size = effective_corner_radius
	scaled_width = max(scaled_width, min_badge_size)
	scaled_height = max(scaled_height, min_badge_size)
	
	var scaled_min_dim = min(scaled_width, scaled_height)
	
	var corner_midpoint_factor = 1.0 - sqrt(2.0) / 2.0
	var scaled_outer = effective_corner_radius * corner_midpoint_factor
	var scaled_inner = base_inner_corner * scale * corner_midpoint_factor
	var max_outer = scaled_min_dim * 0.4
	scaled_outer = min(scaled_outer, max_outer)
	
	# Calculate safe zone (before padding), offset by border inset
	var safe_x = border_inset_pixels + scaled_outer
	var safe_y = border_inset_pixels + scaled_outer
	var safe_width = scaled_width - scaled_outer - scaled_inner
	var safe_height = scaled_height - scaled_outer - scaled_inner
	safe_width = max(safe_width, 1.0)
	safe_height = max(safe_height, 1.0)
	
	# Debug: print values for DS/3DS which seem to have issues
	if game and (game.platform_slug == "nds" or game.platform_slug == "3ds"):
		print("Platform: ", game.platform_slug)
		print("  texture_size: ", texture_to_use.get_size())
		print("  texture_aspect: ", texture_aspect)
		print("  badge_width: ", badge_width, " badge_height: ", badge_height)
		print("  scaled_width: ", scaled_width, " scaled_height: ", scaled_height)
		print("  scaled_outer: ", scaled_outer, " scaled_inner: ", scaled_inner)
		print("  safe_zone: ", safe_x, safe_y, safe_width, safe_height)
	
	if _badge_effect:
		_badge_effect.set_badge_dimensions(Vector2(scaled_width, scaled_height))
		_badge_effect.set_border_inset_pixels(border_inset_pixels)
		# Pass safe zone to shader for debugging (set last param to true to show debug)
		_badge_effect.set_safe_zone(safe_x, safe_y, safe_width, safe_height, false)
	
	# Apply padding to safe zone for icon placement
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
	
	if texture_aspect > safe_aspect:
		icon_draw_width = safe_width
		icon_draw_height = safe_width / texture_aspect
	else:
		icon_draw_height = safe_height
		icon_draw_width = safe_height * texture_aspect
	
	var icon_offset_x = safe_x + (safe_width - icon_draw_width) * 0.5
	var icon_offset_y = safe_y + (safe_height - icon_draw_height) * 0.5
	
	platform_icon.visible = true
	platform_icon.texture = texture_to_use
	platform_icon.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Use manual offsets (scene has expand_mode=1, stretch_mode=5)
	platform_icon.offset_left = icon_offset_x
	platform_icon.offset_top = icon_offset_y
	platform_icon.offset_right = icon_offset_x + icon_draw_width
	platform_icon.offset_bottom = icon_offset_y + icon_draw_height
	platform_icon.modulate = Color.WHITE
	
	# Use cached material for this color to reduce shader overhead
	var cache_key = str(icon_color)
	if not _icon_material_cache.has(cache_key):
		var cached_material = ShaderMaterial.new()
		cached_material.shader = preload("res://shaders/icon_color_shader.gdshader")
		cached_material.set_shader_parameter("icon_color", icon_color)
		_icon_material_cache[cache_key] = cached_material
	platform_icon.material = _icon_material_cache[cache_key]

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
	# Update glow effect texture if it exists
	if _glow_effect:
		_glow_effect.set_game_texture(tex)

func _on_card_pressed():
	if not game:
		return
	
	if game.is_active_variant_downloaded():
		var root_folder = SettingsManager.get_setting("games_root_folder") if SettingsManager else null
		if root_folder and root_folder.value != "":
			# Construct the full file path from known components (don't rely on file_path which may be relative)
			var active_file_name = game.get_active_file_name()
			var file_path = root_folder.value + "/" + game.platform_slug + "/" + active_file_name
			
			print("[GameCard] Checking file exists: %s (game: %s, has_local_copy: %s)" % [file_path, game.title, game.has_local_copy])
			
			var file_exists = false
			
			# On Android with SAF paths, use plugin to check file existence
			if PlatformManager.is_android() and file_path.begins_with("content://"):
				var plugin = Engine.get_singleton("PackageChecker")
				if plugin:
					file_exists = plugin.call("safFileExists", file_path)
					print("[GameCard] SAF file check result: " + str(file_exists))
				else:
					print("[GameCard] WARNING: PackageChecker plugin not available for SAF file check")
					file_exists = false
			else:
				# Standard file check for regular paths
				file_exists = FileAccess.file_exists(file_path)
			
			if not file_exists:
				if NotificationManager:
					NotificationManager.show_notification("File not found - redownloading", Notification.Type.WARNING)
				download_requested.emit(game)
				return
		
		if LaunchManager:
			LaunchManager.launch_game(game)
	else:
		download_requested.emit(game)

func _get_show_delete() -> bool:
	# Check if we're in the home view by traversing up the tree
	var parent = get_parent()
	while parent:
		if parent is HomeView:
			return true
		elif parent is LibraryView:
			return false
		parent = parent.get_parent()
	return false

func _on_card_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if game and UIManager:
				UIManager.show_game_context_menu(game.romm_id, get_viewport().get_mouse_position(), _get_show_delete())

func _input(event: InputEvent) -> void:
	# Handle ui_select (gamepad top button/Space) to open context menu
	if event.is_action_pressed("ui_select"):
		# Check if any child of this card has focus (the button gets focus, not the card)
		var focused = get_viewport().gui_get_focus_owner()
		if focused and is_ancestor_of(focused) and game and UIManager:
			# Play click_03 modulated up by a quarter octave (~1.03)
			if AudioManager:
				AudioManager.play_sfx_modulate("click_03", 1.2, 1.2, 0.0)
			var center_pos = global_position + (size / 2)
			UIManager.show_game_context_menu(game.romm_id, center_pos, _get_show_delete())
			get_viewport().set_input_as_handled()

func _on_focus_entered() -> void:
	# Play focus sound with slight pitch variation
	if AudioManager:
		AudioManager.play_sfx_modulate("click_02", 0.98, 1.02)
	
	# Vibrate controller for tactile feedback
	Input.start_joy_vibration(0, 0.08, 0.03, 0.08)
	
	# Scale up visual container when focused (not self, to avoid layout issues)
	# Ensure pivot is set to center for proper scaling
	visual_container.pivot_offset = visual_container.size / 2
	
	if _focus_tween:
		_focus_tween.kill()
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_BACK)
	_focus_tween.set_ease(Tween.EASE_OUT)
	_focus_tween.tween_property(visual_container, "scale", Vector2(FOCUSED_SCALE, FOCUSED_SCALE), FOCUS_TWEEN_DURATION)
	
	# Reduce border size when focused
	if _border_effect:
		var focused_border_size = _original_border_size * FOCUSED_BORDER_MULTIPLIER
		var fade_in = _get_effect_config("border").get("settings", {}).get("border_fade_in", 0.0)
		var original_inset = _original_border_size + fade_in
		var focused_inset = focused_border_size + fade_in
		
		# Tween border size and inset together
		var border_tween = _border_effect.tween_border_size(focused_border_size, FOCUS_TWEEN_DURATION)
		border_tween.parallel().tween_method(func(t):
			var current_inset = lerp(original_inset, focused_inset, t)
			_card_state.border_inset_ratio = current_inset
			# Update badge with new inset
			if _badge_effect:
				_badge_effect.set_border_width(current_inset)
				_badge_effect.set_border_inset_pixels(current_inset * _card_state.card_size.x)
		, 0.0, 1.0, FOCUS_TWEEN_DURATION)

func _on_focus_exited() -> void:
	# Scale visual container back to normal when unfocused
	if _focus_tween:
		_focus_tween.kill()
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_QUAD)
	_focus_tween.set_ease(Tween.EASE_OUT)
	_focus_tween.tween_property(visual_container, "scale", Vector2.ONE, FOCUS_TWEEN_DURATION)
	
	# Restore original border size and inset
	if _border_effect:
		var fade_in = _get_effect_config("border").get("settings", {}).get("border_fade_in", 0.0)
		var focused_border_size = _original_border_size * FOCUSED_BORDER_MULTIPLIER
		var focused_inset = focused_border_size + fade_in
		var original_inset = _original_border_size + fade_in
		
		# Tween border size and inset together
		var border_tween = _border_effect.tween_border_size(_original_border_size, FOCUS_TWEEN_DURATION)
		border_tween.parallel().tween_method(func(t):
			var current_inset = lerp(focused_inset, original_inset, t)
			_card_state.border_inset_ratio = current_inset
			# Update badge with restored inset
			if _badge_effect:
				_badge_effect.set_border_width(current_inset)
				_badge_effect.set_border_inset_pixels(current_inset * _card_state.card_size.x)
		, 0.0, 1.0, FOCUS_TWEEN_DURATION)

## Restores the focus animation after layout changes (e.g., after queue_sort resets transforms)
## Called by VirtualScrollGridContainer to re-apply focus scale without triggering full focus_entered logic
func restore_focus_animation() -> void:
	# Kill existing focus tween
	if _focus_tween:
		_focus_tween.kill()
	
	# Re-apply focus scale animation on visual container (not self)
	# Ensure pivot is set to center for proper scaling
	visual_container.pivot_offset = visual_container.size / 2
	
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_BACK)
	_focus_tween.set_ease(Tween.EASE_OUT)
	_focus_tween.tween_property(visual_container, "scale", Vector2(FOCUSED_SCALE, FOCUSED_SCALE), FOCUS_TWEEN_DURATION)
	
	# Re-apply border size reduction
	if _border_effect:
		var focused_border_size = _original_border_size * FOCUSED_BORDER_MULTIPLIER
		var fade_in = _get_effect_config("border").get("settings", {}).get("border_fade_in", 0.0)
		var original_inset = _original_border_size + fade_in
		var focused_inset = focused_border_size + fade_in
		
		var border_tween = _border_effect.tween_border_size(focused_border_size, FOCUS_TWEEN_DURATION)
		border_tween.parallel().tween_method(func(t):
			var current_inset = lerp(original_inset, focused_inset, t)
			_card_state.border_inset_ratio = current_inset
			if _badge_effect:
				_badge_effect.set_border_width(current_inset)
				_badge_effect.set_border_inset_pixels(current_inset * _card_state.card_size.x)
		, 0.0, 1.0, FOCUS_TWEEN_DURATION)

## Plays the enter animation: scales from 125% to 100% while fading opacity from 0% to 100%
func play_enter_animation() -> void:
	# Kill any existing enter tweens
	if _enter_tween:
		_enter_tween.kill()
	if _enter_tween_alpha:
		_enter_tween_alpha.kill()
	
	# Set initial scale on visual container
	# Ensure pivot is set to center for proper scaling
	visual_container.pivot_offset = visual_container.size / 2
	visual_container.scale = Vector2(ENTER_START_SCALE, ENTER_START_SCALE)
	
	# Tween for scale (bouncy/elastic feel)
	_enter_tween = create_tween()
	_enter_tween.set_trans(Tween.TRANS_QUINT)
	_enter_tween.set_ease(Tween.EASE_OUT)
	_enter_tween.tween_property(visual_container, "scale", Vector2.ONE, ENTER_TWEEN_DURATION)
	
	# Separate tween for opacity (smooth fade)
	_enter_tween_alpha = create_tween()
	_enter_tween_alpha.set_trans(Tween.TRANS_CIRC)
	#_enter_tween_alpha.set_ease(Tween.EASE_)
	
	# Tween alpha on base effect using the shader uniform
	if _base_effect:
		_enter_tween_alpha.parallel().tween_method(func(t): _base_effect.set_alpha(t), 0.0, 1.0, ENTER_TWEEN_DURATION)
	
	# Tween opacity on card input (covers UI elements like status icons, platform icons)
	if card_input:
		_enter_tween_alpha.parallel().tween_property(card_input, "modulate", Color(1, 1, 1, 1), ENTER_TWEEN_DURATION)
	
	# Tween opacity on all CardEffect children inside VisualContainer (border, badge, drop shadow)
	if visual_container:
		for child in visual_container.get_children():
			if child is CardEffect:
				_enter_tween_alpha.parallel().tween_property(child, "modulate", Color(1, 1, 1, 1), ENTER_TWEEN_DURATION)

## Sets the card's alpha immediately (for initial state before animations)
func set_card_alpha(alpha: float) -> void:
	if _base_effect:
		_base_effect.set_alpha(alpha)
	
	# Set opacity on card input (covers UI elements like status icons, platform icons)
	if card_input:
		card_input.modulate = Color(1, 1, 1, alpha)
	
	# Set opacity on all CardEffect children inside VisualContainer (border, badge, drop shadow)
	if visual_container:
		for child in visual_container.get_children():
			if child is CardEffect:
				child.modulate = Color(1, 1, 1, alpha)

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
	# Reset visual container scale when card is recycled
	if visual_container:
		visual_container.scale = Vector2.ONE

func refresh_settings():
	_update_card_state_from_settings()
	_rebuild_effects()

func set_image_priority(high_priority: bool):
	if _current_image_task_id > 0:
		MemoryManager.update_image_priority(_current_image_task_id, high_priority)
	elif high_priority and game:
		_load_cover(true)

# Called by VirtualScrollGridContainer when zoom changes
func set_card_zoom(new_zoom: float) -> void:
	_card_state.zoom_level = new_zoom

func get_current_zoom() -> float:
	return _card_state.zoom_level
