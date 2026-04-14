class_name GameCard
extends ColorRect

signal download_requested(game: GameResource)
signal enter_animation_completed()

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
@onready var status_badge: Panel = $VisualContainer/CardInput/StatusBadge
@onready var game_title_label: Label = $VisualContainer/GameTitleLabel

var _loading_texture: Texture2D = preload("res://icon.svg")
var _is_downloading: bool = false
var _is_focused: bool = false

# Base font size for the title label (at zoom = 1.0)
const BASE_TITLE_FONT_SIZE: int = 18

# Ratio-based constants (as fraction of card width)
const BADGE_SIZE_RATIO: float = 0.16  # Platform badge size (16% of card width)
const BADGE_MARGIN_RATIO: float = 0.025  # Platform badge margin
const STATUS_BADGE_SIZE_RATIO: float = 0.04  # Status badge size (4% of card width)
const STATUS_BADGE_MARGIN_RATIO: float = 0.05  # Status badge margin - sits deeper in card
const STATUS_BADGE_INSET_MARGIN: float = 0.015  # Additional margin to inset status badge from edges
const BADGE_CORNER_RATIO: float = 0.11  # ~23px at default width

# Debug
var _debug_safe_area: ColorRect = null

var _current_texture: Texture2D = null
var _card_state: EffectContainerState = EffectContainerState.for_card()

# EffectStack system - normal and focus stacks share _card_state
var _normal_stack: EffectStack = null
var _focus_stack: EffectStack = null

var _loading_game_id: String = ""
var _image_retry_count: int = 0
var _current_image_task_id: int = -1
const MAX_IMAGE_RETRIES: int = 3

# Track download retries separately from image load retries
var _download_retry_count: int = 0
const MAX_DOWNLOAD_RETRIES: int = 2

const FOCUSED_SCALE: float = 1.08
const FOCUS_TWEEN_DURATION: float = 0.12
const FOCUS_EFFECT_FADE_DURATION: float = 0.15  # Duration for focus effects fade in/out
var _focus_tween: Tween = null
var _focus_effect_tweens: Array[Tween] = []  # Track tweens created in _show_focus_effects

# Enter animation constants
const ENTER_START_SCALE: float = 3.0
const ENTER_TWEEN_DURATION: float = 1.2  # Animation duration - quicker (was 1.75)
var _enter_tween: Tween = null
var _enter_tween_alpha: Tween = null

# Android touch-and-hold detection
const LONG_PRESS_DURATION: float = 0.6  # 600ms
const LONG_PRESS_TOLERANCE: float = 20.0  # 20px position tolerance
var _touch_start_time: float = 0.0
var _touch_start_pos: Vector2 = Vector2.ZERO
var _touch_is_holding: bool = false
var _long_press_timer: Timer = null

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
	
	# Connect to state signals for reactivity
	_card_state.zoom_changed.connect(_on_zoom_changed)
	_card_state.orientation_changed.connect(_on_orientation_changed)
	
	_update_card_state_from_settings()
	_rebuild_effects()
	_update_display()
	
	# Connect input signals
	if card_input:
		card_input.pressed.connect(_on_card_pressed)
		card_input.gui_input.connect(_on_card_gui_input)
		card_input.focus_entered.connect(_on_focus_entered)
		card_input.focus_exited.connect(_on_focus_exited)
		card_input.mouse_entered.connect(_on_card_mouse_entered)
	
	if DownloadManager:
		DownloadManager.download_progress.connect(_on_download_progress)
		DownloadManager.download_completed.connect(_on_download_completed)
	
	# Setup long-press timer for Android
	if PlatformManager.is_android():
		_long_press_timer = Timer.new()
		_long_press_timer.wait_time = LONG_PRESS_DURATION
		_long_press_timer.one_shot = true
		_long_press_timer.timeout.connect(_on_long_press_timeout)
		add_child(_long_press_timer)

## Checks if animations are blocking focus - cards can't be focused during intro or launch animations
func _can_accept_focus() -> bool:
	# Check if we're in HomeView and intro animations are still running
	var home_view = _find_home_view()
	if home_view and home_view.has_method("are_intro_animations_complete"):
		if not home_view.are_intro_animations_complete():
			return false
	
	# Check if launch transition overlay is animating (static variable)
	if LaunchTransitionOverlay.is_transition_active:
		return false
	
	return true

## Finds the parent HomeView if this card is in one
func _find_home_view() -> Node:
	var current = get_parent()
	while current:
		if current is HomeView:
			return current
		current = current.get_parent()
	return null

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
	
	if game_title_label:
		game_title_label.visible = false
	
	if card_input:
		card_input.disabled = true
		card_input.mouse_filter = Control.MOUSE_FILTER_IGNORE

func set_card_state(state: EffectContainerState) -> void:
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

func get_card_state() -> EffectContainerState:
	return _card_state

func get_focus_shape_params() -> Dictionary:
	return {
		"shape_size": _card_state.card_size,
		"corner_radius_ratio": _card_state.corner_radius_ratio,
		"corner_radius_pixels": _card_state.corner_radius_pixels
	}

func _update_card_state_from_settings():
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting:
			if config_setting.value is Dictionary:
				_card_state.orientation = config_setting.value.get("card_orientation", 0)
				_card_state.effect_settings = config_setting.value.get("effects", [])
				_card_state.focus_effect_settings = config_setting.value.get("focus_effects", [])
				# Corner radius as ratio (0.0 to 1.0) - convert from old pixel format if needed
				var corner_value = config_setting.value.get("corner_radius", 0.06)
				# If value > 1.0, it's in old pixel format (default was 12px), convert to ratio
				if corner_value > 1.0:
					_card_state.corner_radius_ratio = corner_value / 202.0
				else:
					_card_state.corner_radius_ratio = corner_value

func _get_effect_config(effect_id: String) -> Dictionary:
	for effect_data in _card_state.effect_settings:
		if effect_data.get("effect_id") == effect_id:
			return effect_data
	return {}

func _get_focus_effect_config(effect_id: String) -> Dictionary:
	for effect_data in _card_state.focus_effect_settings:
		if effect_data.get("effect_id") == effect_id:
			return effect_data
	return {}

func _rebuild_effects():
	if not visual_container:
		push_warning("GameCard: visual_container is null, cannot add effects")
		return
	
	# Remove old stacks if they exist
	if _normal_stack:
		_normal_stack.queue_free()
		_normal_stack = null
	if _focus_stack:
		_focus_stack.queue_free()
		_focus_stack = null
	
	# Reset border inset before rebuilding
	_card_state.border_inset_ratio = 0.0
	_card_state.glass_inset_ratio = 0.0
	
	# Create normal EffectStack
	_normal_stack = EffectStack.new()
	_normal_stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	visual_container.add_child(_normal_stack)
	_normal_stack.initialize(_card_state, _card_state.effect_settings)
	if _current_texture:
		_normal_stack.set_game_texture(_current_texture)
	
	# Create focus EffectStack with its own state (duplicate to avoid clobbering normal stack's insets)
	var focus_state = _card_state.duplicate()
	focus_state.effect_settings = _card_state.focus_effect_settings.duplicate(true)
	
	# Create focus EffectStack (starts invisible, higher z-index than normal stack)
	_focus_stack = EffectStack.new()
	_focus_stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	_focus_stack.z_index = 100
	_focus_stack.visible = false
	visual_container.add_child(_focus_stack)
	_focus_stack.initialize(focus_state, _card_state.focus_effect_settings)
	if _current_texture:
		_focus_stack.set_game_texture(_current_texture)
	
	# Remove base effect from focus stack - focus effects are overlays only,
	# they should not draw the game texture (that's the normal stack's job)
	var focus_base = _focus_stack.get_effect("base")
	if focus_base:
		focus_base.visible = false
		focus_base.modulate.a = 0.0
	
	# Link overlapping focus effects to their base counterparts for tweening
	_link_overlapping_effects()
	
	# Initialize focus effects with effect_alpha = 0.0 so they start hidden
	# (shader default is 1.0, which would cause them to pop in before the tween)
	# Exception: in preview mode, always show focus effects so designer can see them
	var focus_alpha = 1.0 if preview_mode else 0.0
	for child in _focus_stack.get_children():
		if child is EffectBase and child.material is ShaderMaterial:
			child.material.set_shader_parameter("effect_alpha", focus_alpha)
	
	# In preview mode, make focus stack visible
	if preview_mode:
		_focus_stack.visible = true
	
	# Ensure card_input is on top
	if card_input:
		visual_container.move_child(card_input, -1)
	
	_update_platform_badge()
	_update_status_badge_layout()

func _link_overlapping_effects() -> void:
	"""Link focus effects that overlap with base effects so they can tween settings."""
	if not _normal_stack or not _focus_stack:
		return
	
	# Get base effect IDs
	var base_effect_ids: Array[String] = []
	for child in _normal_stack.get_children():
		if child is EffectBase:
			base_effect_ids.append(child.effect_id)
	
	# For each focus effect that exists in base, link them
	for child in _focus_stack.get_children():
		if child is EffectBase and child.effect_id in base_effect_ids:
			var base_effect = _normal_stack.get_effect(child.effect_id)
			if base_effect:
				child.set_base_effect(base_effect)
				
				# Only reset to base settings if card is NOT focused
				# Focused cards should keep their current tween state
				if not _is_focused and base_effect._settings.size() > 0:
					child.tween_settings(base_effect._settings, base_effect._settings, 1.0)

func _on_zoom_changed(_new_zoom: float) -> void:
	var card_size = _card_state.card_size
	custom_minimum_size = card_size
	size = card_size
	pivot_offset = card_size / 2
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	
	# Update title label font size based on zoom
	if game_title_label:
		var zoom = _card_state.zoom_level
		# Scale font size with zoom, but keep it readable (min 10, no max)
		var scaled_font_size = max(10, int(BASE_TITLE_FONT_SIZE * zoom))
		game_title_label.add_theme_font_size_override("font_size", scaled_font_size)
	
	_update_status_badge_layout()
	_update_platform_badge()

func _on_orientation_changed(_new_orientation: int) -> void:
	_on_zoom_changed(_card_state.zoom_level)

func _update_status_badge_layout():
	if not status_badge:
		return
	
	var card_size = _card_state.card_size
	var card_width = card_size.x
	var card_height = card_size.y
	var badge_size = STATUS_BADGE_SIZE_RATIO * card_width
	var border_inset_pixels = _card_state.border_inset_ratio * card_width
	var glass_inset_pixels = _card_state.glass_inset_ratio * card_width
	var total_inset = border_inset_pixels + glass_inset_pixels
	
	# Calculate effective corner radius at the inset position
	var effective_corner_radius = max(0, _card_state.corner_radius_pixels - total_inset)
	
	# Corner margin calculation (same as platform badge)
	var corner_midpoint_factor = 1.0 - sqrt(2.0) / 2.0
	var corner_margin = effective_corner_radius * corner_midpoint_factor
	
	# Additional margin to inset the status badge from the edges
	var inset_margin = STATUS_BADGE_INSET_MARGIN * card_width
	
	# Position in BOTTOM RIGHT corner (mirror of top-left logic)
	# Start from bottom-right corner and move inward by total_inset + corner_margin + inset_margin
	var safe_x = card_width - total_inset - corner_margin - badge_size - inset_margin
	var safe_y = card_height - total_inset - corner_margin - badge_size - inset_margin
	
	# Position the status badge
	status_badge.offset_left = safe_x
	status_badge.offset_top = safe_y
	status_badge.offset_right = safe_x + badge_size
	status_badge.offset_bottom = safe_y + badge_size
	
	# Update badge style - always a circle (radius = half the size)
	_update_status_badge_style()

func _update_status_badge_style():
	if not status_badge:
		return
	
	var card_width = _card_state.card_size.x
	var badge_size = STATUS_BADGE_SIZE_RATIO * card_width
	# Always a perfect circle (radius = half the size)
	var circle_radius = int(badge_size / 2.0)
	
	var new_style = StyleBoxFlat.new()
	# Set color based on download status
	if game and game.is_active_variant_downloaded():
		# Downloaded/ready to launch - green
		new_style.bg_color = Color(0.49, 0.714, 0.0, 1.0)  # #7db600
	else:
		# Not downloaded - blue
		new_style.bg_color = Color(0.0, 0.624, 0.922, 1.0)  # #009feb
	
	# Always a perfect circle
	new_style.corner_radius_top_left = circle_radius
	new_style.corner_radius_top_right = circle_radius
	new_style.corner_radius_bottom_left = circle_radius
	new_style.corner_radius_bottom_right = circle_radius
	status_badge.add_theme_stylebox_override("panel", new_style)

func _update_display():
	if not game:
		return
	if not is_node_ready():
		return
	_update_status_icon()
	_update_platform_badge()
	_load_cover(false)
	_update_game_title_label()

func _update_display_with_priority(high_priority: bool):
	if not game:
		return
	if not is_node_ready():
		return
	_update_status_icon()
	_update_platform_badge()
	_load_cover(high_priority)
	_update_game_title_label()

func _update_game_title_label():
	if not game_title_label:
		return
	
	if not game:
		game_title_label.visible = false
		return
	
	# Set the label text
	game_title_label.text = game.title
	
	# Update visibility based on focus state and setting
	_update_game_title_visibility()

func _update_game_title_visibility():
	if not game_title_label:
		return
	
	if not game:
		game_title_label.visible = false
		return
	
	# Check the setting
	var mode = 1  # default "Focused"
	if SettingsManager:
		var setting = SettingsManager.get_setting("library_show_title_mode")
		if setting:
			mode = setting.value
	
	# Show if: All (2) OR Focused (1) and card is focused
	game_title_label.visible = (mode == 2) or (mode == 1 and _is_focused)

func load_cover_with_priority(high_priority: bool = false):
	_load_cover(high_priority)

func _update_status_icon():
	if not status_badge:
		return
	if not game:
		status_badge.visible = false
		return
	
	if _is_downloading:
		status_badge.visible = false
	else:
		status_badge.visible = true
		_update_status_badge_style()

func _update_platform_badge():
	if not _normal_stack:
		return
	
	var normal_badge = _normal_stack.get_effect("badge") as BadgeEffect
	if not normal_badge:
		return
	
	if not game:
		normal_badge.set_icon_texture(null)
		return
	
	var platform_slug = game.platform_slug
	var icon_texture: Texture2D = null
	
	var badge_config = _get_effect_config("badge")
	var settings = badge_config.get("settings", {})
	var badge_type = settings.get("badge_type", 0)
	var badge_size_setting = settings.get("badge_size", 1.0)
	var inner_radius_setting = settings.get("badge_inner_radius", 0.0)
	
	var card_width = _card_state.card_size.x
	var corner_radius_pixels = _card_state.corner_radius_pixels
	var total_inset = _card_state.total_inset_pixels
	var effective_corner_radius = max(0, corner_radius_pixels - total_inset)
	
	if platform_slug:
		if badge_type == 1:
			var wordmark_path = "res://assets/platforms/wordmark/wordmark_" + platform_slug + ".png"
			if ResourceLoader.exists(wordmark_path):
				var wordmark_tex = load(wordmark_path)
				if wordmark_tex:
					icon_texture = wordmark_tex
		else:
			var icon_path = "res://assets/platforms/icon/icon_%s.png" % platform_slug
			if ResourceLoader.exists(icon_path):
				icon_texture = load(icon_path)
	
	var texture_aspect = 1.0
	if icon_texture:
		var tex_size = icon_texture.get_size()
		texture_aspect = tex_size.x / tex_size.y if tex_size.y > 0 else 1.0
		if badge_type != 1:
			texture_aspect = 1.0
	
	var bar_height: float = 0.0
	var top_bar_safe_x: float = 0.0
	var top_bar_safe_y: float = 0.0
	var top_bar_safe_width: float = 0.0
	var top_bar_safe_height: float = 0.0
	var badge_width: float = 0.0
	var badge_height: float = 0.0
	var safe_x: float = 0.0
	var safe_y: float = 0.0
	var safe_width: float = 0.0
	var safe_height: float = 0.0
	
	if badge_type == 1:
		var base_badge_size = BADGE_SIZE_RATIO * card_width
		var top_bar_max_size = card_width * 0.25
		bar_height = min(base_badge_size * badge_size_setting, top_bar_max_size)
		
		top_bar_safe_x = total_inset + effective_corner_radius
		top_bar_safe_width = (card_width - total_inset * 2) - (effective_corner_radius * 2)
		top_bar_safe_y = total_inset
		top_bar_safe_height = bar_height
		
		normal_badge.set_badge_dimensions(Vector2(card_width, bar_height))
		normal_badge.set_border_inset_pixels(total_inset)
		normal_badge.set_safe_zone_top_bar(top_bar_safe_x, top_bar_safe_y, top_bar_safe_width, top_bar_safe_height, false)
	else:
		var raw_badge_size = BADGE_SIZE_RATIO * card_width * badge_size_setting
		var min_badge_size = card_width * 0.15
		var max_badge_size = card_width * 0.45
		var target_badge_size = clamp(raw_badge_size, min_badge_size, max_badge_size)
		
		if texture_aspect >= 1.0:
			badge_width = target_badge_size * texture_aspect
			badge_height = target_badge_size
		else:
			badge_width = target_badge_size
			badge_height = target_badge_size / texture_aspect
		
		var corner_midpoint_factor = 1.0 - sqrt(2.0) / 2.0
		var corner_margin = effective_corner_radius * corner_midpoint_factor
		var base_min_dim = min(badge_width, badge_height)
		var base_inner_corner = (base_min_dim * 0.5) * clamp(inner_radius_setting, 0.0, 1.0)
		var inner_corner_margin = base_inner_corner * corner_midpoint_factor
		
		var max_corner_margin = badge_width * 0.8
		var clamped_corner_margin = min(corner_margin, max_corner_margin)
		
		safe_x = total_inset + clamped_corner_margin
		safe_y = total_inset + clamped_corner_margin
		safe_width = max(badge_width - clamped_corner_margin - inner_corner_margin, 0.0)
		safe_height = max(badge_height - clamped_corner_margin - inner_corner_margin, 0.0)
		
		normal_badge.set_badge_dimensions(Vector2(badge_width, badge_height))
		normal_badge.set_border_inset_pixels(total_inset)
		normal_badge.set_safe_zone(safe_x, safe_y, safe_width, safe_height, false)
	
	normal_badge.set_icon_texture(icon_texture)
	
	# Also update focus badge if it exists
	var focus_badge = _focus_stack.get_effect("badge") as BadgeEffect
	if focus_badge:
		focus_badge.set_icon_texture(icon_texture)
		if badge_type == 1:
			focus_badge.set_badge_dimensions(Vector2(card_width, bar_height))
			focus_badge.set_border_inset_pixels(total_inset)
			focus_badge.set_safe_zone_top_bar(top_bar_safe_x, top_bar_safe_y, top_bar_safe_width, top_bar_safe_height, false)
		else:
			focus_badge.set_badge_dimensions(Vector2(badge_width, badge_height))
			focus_badge.set_border_inset_pixels(total_inset)
			focus_badge.set_safe_zone(safe_x, safe_y, safe_width, safe_height, false)

func _load_cover(high_priority: bool = false):
	if not game:
		_set_texture(_loading_texture)
		return
	
	_loading_game_id = game.id
	_image_retry_count = 0
	_download_retry_count = 0  # Reset download retry counter for new game
	
	var cache_path = ""
	var cover_url = ""
	if game.cover_path and FileAccess.file_exists(game.cover_path):
		cache_path = game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		cover_url = game.cover_url
		cache_path = _get_cached_cover_path(cover_url)
		if not FileAccess.file_exists(cache_path):
			# Cache file missing - check if sync is in progress
			if DataManager.is_sync_in_progress():
				# During sync: sync handles cover downloads, just show loading
				_set_texture(_loading_texture)
				return
			else:
				# After sync: trigger download as fallback
				_download_cover_and_retry(cover_url, cache_path, high_priority)
				return
	
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
	# Extract extension from URL, default to jpg if not found
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
			return _load_image_from_buffer(buffer)
		return null
	
	var callback_callable = func(image):
		_current_image_task_id = -1
		if not is_instance_valid(self):
			return
		if not game or game.id != target_game_id:
			return
		
		if image:
			var texture = ImageTexture.create_from_image(image)
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

func _download_cover_and_retry(cover_url: String, cache_path: String, high_priority: bool = false):
	"""Trigger a cover download and retry loading when complete."""
	var target_game_id = _loading_game_id
	
	# Check download retry limit
	_download_retry_count += 1
	if _download_retry_count > MAX_DOWNLOAD_RETRIES:
		# Too many download attempts, just show loading texture
		_set_texture(_loading_texture)
		return
	
	# Show loading texture while downloading
	_set_texture(_loading_texture)
	
	# Trigger download via DataManager
	DataManager.load_image(cover_url, func(_texture: Texture2D):
		# Called when download completes (or fails)
		if not is_instance_valid(self):
			return
		if not game or game.id != target_game_id:
			return
		
		# Check if file actually exists now
		if FileAccess.file_exists(cache_path):
			# File exists - safe to retry loading
			_load_cover(high_priority)
		else:
			# Download failed or file still missing - show loading texture
			_set_texture(_loading_texture)
	)

func _load_image_from_buffer(buffer: PackedByteArray) -> Image:
	if buffer.size() < 16:
		return null
	
	var err = FAILED
	var image = Image.new()
	
	# Always use magic bytes to detect actual format, regardless of file extension
	# This handles cases where the extension doesn't match the actual content
	if buffer[0] == 0xFF and buffer[1] == 0xD8:
		# JPEG magic bytes
		err = image.load_jpg_from_buffer(buffer)
	elif buffer[0] == 0x89 and buffer[1] == 0x50:
		# PNG magic bytes (0x89 0x50 0x4E 0x47)
		err = image.load_png_from_buffer(buffer)
	elif buffer[0] == 0x52 and buffer[1] == 0x49:
		# WebP magic bytes (RIFF header)
		err = image.load_webp_from_buffer(buffer)
	else:
		# Try all formats as fallback
		err = image.load_jpg_from_buffer(buffer)
		if err != OK:
			image = Image.new()
			err = image.load_png_from_buffer(buffer)
		if err != OK:
			image = Image.new()
			err = image.load_webp_from_buffer(buffer)
	
	if err == OK:
		return image
	return null

func _set_texture(tex: Texture2D) -> void:
	# Skip if texture hasn't changed
	if tex == _current_texture:
		return
	_current_texture = tex
	if _normal_stack:
		_normal_stack.set_game_texture(tex)
	if _focus_stack:
		_focus_stack.set_game_texture(tex)

func _on_card_pressed():
	if not game:
		return
	
	# Get the virtual index immediately while we still have focus context
	var focus_index = self.get_meta("virtual_index", -1)
	
	# Skip file check for GameNative games - they don't have physical files
	if game.source == "gamenative":
		if LaunchManager:
			LaunchManager.launch_game(game, focus_index)
		return
	
	if game.is_active_variant_downloaded():
		var root_folder = SettingsManager.get_setting("games_root_folder") if SettingsManager else null
		if root_folder and root_folder.value != "":
			# Construct the full file path from known components (don't rely on file_path which may be relative)
			var active_file_name = game.get_active_file_name()
			var file_path = root_folder.value + "/" + game.platform_slug + "/" + active_file_name
			
			var file_exists = false
			
			# On Android with SAF paths, use plugin to check file existence
			if PlatformManager.is_android() and file_path.begins_with("content://"):
				var plugin = Engine.get_singleton("PackageChecker")
				if plugin:
					file_exists = plugin.call("safFileExists", file_path)
				else:
					push_warning("PackageChecker plugin not available for SAF file check")
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
			LaunchManager.launch_game(game, focus_index)
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

func _on_card_mouse_entered() -> void:
	# Check if we can accept focus (animations complete)
	if not _can_accept_focus():
		return
	
	# Only grab focus if mouse is recently active and controller doesn't have priority
	if UIManager and UIManager.should_card_grab_focus_on_hover():
		if card_input and not card_input.has_focus():
			# Mark this focus change as mouse-initiated so smooth scroll can skip it
			card_input.set_meta("mouse_hover_focus", true)
			card_input.grab_focus()

func _input(event: InputEvent) -> void:
	# Check if we can accept focus (animations complete)
	if not _can_accept_focus():
		return
	
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
	
	# Handle Android touch-and-hold
	if PlatformManager.is_android() and event is InputEventScreenTouch:
		if event.pressed:
			# Check if touch is over this card
			var touch_pos = event.position
			if get_global_rect().has_point(touch_pos):
				_touch_start_time = Time.get_ticks_msec() / 1000.0
				_touch_start_pos = touch_pos
				_touch_is_holding = true
				if _long_press_timer:
					_long_press_timer.start()
		else:
			# Touch released
			if _touch_is_holding:
				_touch_is_holding = false
				if _long_press_timer:
					_long_press_timer.stop()
	
	if PlatformManager.is_android() and event is InputEventScreenDrag:
		if _touch_is_holding:
			# Check if finger moved too far
			var current_pos = event.position
			var distance = _touch_start_pos.distance_to(current_pos)
			if distance > LONG_PRESS_TOLERANCE:
				# Cancel long press
				_touch_is_holding = false
				if _long_press_timer:
					_long_press_timer.stop()

func _on_long_press_timeout() -> void:
	if _touch_is_holding and game and UIManager:
		_touch_is_holding = false
		# Play sound for long press
		if AudioManager:
			AudioManager.play_sfx_modulate("click_03", 1.2, 1.2, 0.0)
		# Show context menu at touch position
		UIManager.show_game_context_menu(game.romm_id, _touch_start_pos, _get_show_delete())

func _get_grid_pivot_offset() -> Vector2:
	var container_size = visual_container.size
	if container_size.x <= 0 or container_size.y <= 0:
		return container_size / 2
	
	var virtual_index = get_meta("virtual_index", -1)
	if virtual_index < 0:
		return container_size / 2
	
	var grid_container = _find_virtual_scroll_grid_container()
	if not grid_container:
		return container_size / 2
	
	var items_per_line = grid_container._get_items_per_line() if grid_container.has_method("_get_items_per_line") else 1
	var total_items = grid_container._total_items if "_total_items" in grid_container else virtual_index + 1
	var vertical = grid_container.vertical if "vertical" in grid_container else true
	
	if vertical:
		var column = virtual_index % items_per_line
		var row = virtual_index / items_per_line
		var total_rows = ceili(float(total_items) / items_per_line)
		
		var is_leftmost = column == 0
		var is_rightmost = (column == items_per_line - 1) or (virtual_index == total_items - 1)
		var is_topmost = row == 0
		var is_bottommost = (row == total_rows - 1) or (virtual_index >= total_items - items_per_line)
		
		var pivot_x = container_size.x / 2
		if is_leftmost:
			pivot_x = 0
		elif is_rightmost:
			pivot_x = container_size.x
		
		var pivot_y = container_size.y / 2
		if is_topmost:
			pivot_y = 0
		elif is_bottommost:
			pivot_y = container_size.y
		
		return Vector2(pivot_x, pivot_y)
	else:
		var row = virtual_index % items_per_line
		var column = virtual_index / items_per_line
		var total_columns = ceili(float(total_items) / items_per_line)
		
		var is_topmost = row == 0
		var is_bottommost = (row == items_per_line - 1) or (virtual_index == total_items - 1)
		var is_leftmost = column == 0
		var is_rightmost = (column == total_columns - 1) or (virtual_index >= total_items - items_per_line)
		
		var pivot_y = container_size.y / 2
		if is_topmost:
			pivot_y = 0
		elif is_bottommost:
			pivot_y = container_size.y
		
		var pivot_x = container_size.x / 2
		if is_leftmost:
			pivot_x = 0
		elif is_rightmost:
			pivot_x = container_size.x
		
		return Vector2(pivot_x, pivot_y)

func _find_virtual_scroll_grid_container() -> Node:
	var current = get_parent()
	while current:
		if current.has_method("_get_items_per_line"):
			return current
		current = current.get_parent()
	return null

func _on_focus_entered() -> void:
	# Check if we can accept focus (animations complete)
	if not _can_accept_focus():
		return
	
	_is_focused = true
	_update_game_title_visibility()
	
	# Play focus sound with slight pitch variation
	if AudioManager:
		AudioManager.play_sfx_modulate("click_02", 0.98, 1.02)
	
	# Vibrate for tactile feedback (platform-specific)
	if PlatformManager.is_android():
		var plugin = Engine.get_singleton("PackageChecker")
		if plugin:
			plugin.call("vibrateDevice", 50)
	else:
		Input.start_joy_vibration(0, 0.08, 0.03, 0.08)
	
	# Scale up visual container when focused (not self, to avoid layout issues)
	# Set pivot based on grid position to prevent clipping at edges
	visual_container.pivot_offset = _get_grid_pivot_offset()
	z_index = 11
	
	if _focus_tween:
		_focus_tween.kill()
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_BACK)
	_focus_tween.set_ease(Tween.EASE_OUT)
	_focus_tween.tween_property(visual_container, "scale", Vector2(FOCUSED_SCALE, FOCUSED_SCALE), FOCUS_TWEEN_DURATION)
	
	# Show focus effects with smooth fade (overlapping effects will tween settings)
	_show_focus_effects(true)

func _on_focus_exited() -> void:
	_is_focused = false
	_update_game_title_visibility()
	
	z_index = 10
	# Scale visual container back to normal when unfocused
	if _focus_tween:
		_focus_tween.kill()
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_QUAD)
	_focus_tween.set_ease(Tween.EASE_OUT)
	_focus_tween.tween_property(visual_container, "scale", Vector2.ONE, FOCUS_TWEEN_DURATION)
	
	# Hide focus effects with smooth fade (overlapping effects will tween back)
	_show_focus_effects(false)

## Restores the focus animation after layout changes (e.g., after queue_sort resets transforms)
## Called by VirtualScrollGridContainer to re-apply focus scale without triggering full focus_entered logic
func restore_focus_animation() -> void:
	# Kill existing focus tween
	if _focus_tween:
		_focus_tween.kill()
	
	# Re-apply focus scale animation on visual container (not self)
	# Set pivot based on grid position to prevent clipping at edges
	visual_container.pivot_offset = _get_grid_pivot_offset()
	z_index = 11
	
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_BACK)
	_focus_tween.set_ease(Tween.EASE_OUT)
	_focus_tween.tween_property(visual_container, "scale", Vector2(FOCUSED_SCALE, FOCUSED_SCALE), FOCUS_TWEEN_DURATION)
	
	# Show focus effects (overlapping effects will be in their focused state)
	_show_focus_effects(true)

## Shows or hides focus effects with a smooth transition.
## For overlapping effects (present in both base and focus), tweens the base effect's shader settings directly.
## For non-overlapping effects, fades in/out via alpha overlay.
func _show_focus_effects(show: bool) -> void:
	# Kill any existing focus effect tweens to prevent callbacks on freed objects
	for tween in _focus_effect_tweens:
		if tween and is_instance_valid(tween):
			tween.kill()
	_focus_effect_tweens.clear()
	
	# In preview mode, always show focus effects so designer can see them
	if preview_mode:
		show = true
	
	if not _focus_stack or not _normal_stack:
		return
	
	# Separate effects into overlapping and non-overlapping
	var overlapping_effects: Array[EffectBase] = []
	var non_overlapping_effects: Array[EffectBase] = []
	
	for child in _focus_stack.get_children():
		if not (child is EffectBase):
			continue
		
		var focus_effect = child as EffectBase
		if focus_effect._base_effect != null:
			overlapping_effects.append(focus_effect)
		else:
			non_overlapping_effects.append(focus_effect)
	
	# Handle overlapping effects: tween the base effect directly, no overlay needed
	for focus_effect in overlapping_effects:
		var base_effect = focus_effect._base_effect
		if not base_effect:
			continue
		
		var base_settings = base_effect._settings
		var focus_settings = focus_effect._settings
		
		# Capture copies to avoid closure issues
		var base_copy = base_settings.duplicate(true)
		var focus_copy = focus_settings.duplicate(true)
		
		if show:
			# Focused: tween base effect from base settings to focus settings
			var settings_tween = create_tween()
			_focus_effect_tweens.append(settings_tween)
			settings_tween.set_trans(Tween.TRANS_QUAD)
			settings_tween.set_ease(Tween.EASE_OUT)
			
			var tween_callable = func(t: float):
				if base_effect and is_instance_valid(base_effect):
					base_effect.tween_settings(base_copy, focus_copy, t)
			
			settings_tween.tween_method(tween_callable, 0.0, 1.0, FOCUS_EFFECT_FADE_DURATION)
		else:
			# Unfocused: tween base effect from focus settings back to base settings
			var settings_tween = create_tween()
			_focus_effect_tweens.append(settings_tween)
			settings_tween.set_trans(Tween.TRANS_QUAD)
			settings_tween.set_ease(Tween.EASE_OUT)
			
			var tween_callable = func(t: float):
				if base_effect and is_instance_valid(base_effect):
					base_effect.tween_settings(focus_copy, base_copy, t)
			
			settings_tween.tween_method(tween_callable, 0.0, 1.0, FOCUS_EFFECT_FADE_DURATION)
	
	# Handle non-overlapping effects: use traditional alpha fade overlay
	if non_overlapping_effects.size() > 0:
		if show:
			_focus_stack.visible = true
			_focus_stack.modulate = Color(1, 1, 1, 1)
		
		for focus_effect in non_overlapping_effects:
			if focus_effect.material is ShaderMaterial:
				var start_alpha = 0.0 if show else 1.0
				var target_alpha = 1.0 if show else 0.0
				
				if show:
					focus_effect.material.set_shader_parameter("effect_alpha", 0.0)
				
				var fade_tween = create_tween()
				_focus_effect_tweens.append(fade_tween)
				fade_tween.set_trans(Tween.TRANS_QUAD)
				fade_tween.set_ease(Tween.EASE_OUT)
				fade_tween.tween_method(
					func(t: float, eff: EffectBase = focus_effect):
						if eff and is_instance_valid(eff) and eff.material is ShaderMaterial:
							eff.material.set_shader_parameter("effect_alpha", t),
					start_alpha, target_alpha, FOCUS_EFFECT_FADE_DURATION
				)
		
		# Hide stack after fade-out completes
		if not show:
			var hide_tween = create_tween()
			_focus_effect_tweens.append(hide_tween)
			hide_tween.set_trans(Tween.TRANS_QUAD)
			hide_tween.set_ease(Tween.EASE_OUT)
			hide_tween.tween_interval(FOCUS_EFFECT_FADE_DURATION)
			hide_tween.finished.connect(func(): 
				if _focus_stack and is_instance_valid(_focus_stack):
					_focus_stack.visible = false
			)

## Plays the enter animation: scales from 125% to 100% while fading opacity from 0% to 100%
func play_enter_animation() -> void:
	# Kill any existing enter tweens
	if _enter_tween:
		_enter_tween.kill()
	if _enter_tween_alpha:
		_enter_tween_alpha.kill()
	
	# Set initial scale on visual container
	# Use grid-based pivot for proper scaling at edges
	visual_container.pivot_offset = _get_grid_pivot_offset()
	visual_container.scale = Vector2(ENTER_START_SCALE, ENTER_START_SCALE)
	
	# Tween for scale (bouncy/elastic feel)
	_enter_tween = create_tween()
	_enter_tween.set_trans(Tween.TRANS_QUINT)
	_enter_tween.set_ease(Tween.EASE_OUT)
	_enter_tween.tween_property(visual_container, "scale", Vector2.ONE, ENTER_TWEEN_DURATION)
	
	# Separate tween for opacity (smooth fade)
	_enter_tween_alpha = create_tween()
	_enter_tween_alpha.set_trans(Tween.TRANS_CIRC)
	
	# Tween alpha on base effect using the stack
	# Capture self (not the node) so the lambda survives card recycles
	_enter_tween_alpha.parallel().tween_method(func(t):
		if _normal_stack:
			var be = _normal_stack.get_effect("base") as BaseCardEffect
			if is_instance_valid(be):
				be.set_alpha(t)
	, 0.0, 1.0, ENTER_TWEEN_DURATION)
	
	# Tween opacity on card input (covers UI elements like status icons)
	if card_input:
		_enter_tween_alpha.parallel().tween_property(card_input, "modulate", Color(1, 1, 1, 1), ENTER_TWEEN_DURATION)
	
	# Tween opacity on all normal stack effects
	if _normal_stack:
		for child in _normal_stack.get_children():
			if child is EffectBase:
				_enter_tween_alpha.parallel().tween_property(child, "modulate", Color(1, 1, 1, 1), ENTER_TWEEN_DURATION)
	
	# Connect to completion signal
	_enter_tween.finished.connect(func():
		enter_animation_completed.emit()
	)

## Sets the card's alpha immediately (for initial state before animations)
func set_card_alpha(alpha: float) -> void:
	if _normal_stack:
		var base_effect = _normal_stack.get_effect("base") as BaseCardEffect
		if base_effect:
			base_effect.set_alpha(alpha)
	
		# Set opacity on all normal stack effects
		for child in _normal_stack.get_children():
			if child is EffectBase:
				child.modulate = Color(1, 1, 1, alpha)
	
	# Set opacity on card input (covers UI elements like status icons)
	if card_input:
		card_input.modulate = Color(1, 1, 1, alpha)

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
		if status_badge:
			status_badge.visible = false
		if game_title_label:
			game_title_label.visible = false
	else:
		_update_display()

func reset():
	if _current_image_task_id > 0:
		MemoryManager.cancel_image_task(_current_image_task_id)
		_current_image_task_id = -1
	# Kill any running focus effect tweens to prevent callbacks on freed objects
	for tween in _focus_effect_tweens:
		if tween and is_instance_valid(tween):
			tween.kill()
	_focus_effect_tweens.clear()
	_loading_game_id = ""
	_image_retry_count = 0
	_download_retry_count = 0
	game = null
	_is_focused = false
	# Only set texture if it's different from current (avoid unnecessary shader updates)
	if _current_texture != _loading_texture:
		_set_texture(_loading_texture)
	# Reset visual container scale when card is recycled
	if visual_container:
		visual_container.scale = Vector2.ONE
	# Reset alpha to fully visible so recycled cards don't stay invisible
	set_card_alpha(1.0)
	# Hide title label when card is reset
	if game_title_label:
		game_title_label.visible = false
	# Hide focus stack when card is recycled
	if _focus_stack:
		_focus_stack.visible = false
		_focus_stack.modulate.a = 0.0
		# Reset shader effect_alpha for all focus effects
		for child in _focus_stack.get_children():
			if child is EffectBase and child.material is ShaderMaterial:
				child.material.set_shader_parameter("effect_alpha", 0.0)

func refresh_settings():
	"""Refresh card settings from global config. Rebuilds effects if orientation or effect settings changed."""
	var old_orientation = _card_state.orientation if _card_state else 0
	var old_zoom = _card_state.zoom_level if _card_state else 1.0
	var old_effects = _card_state.effect_settings.duplicate(true) if _card_state else []
	var old_focus_effects = _card_state.focus_effect_settings.duplicate(true) if _card_state else []
	_update_card_state_from_settings()
	
	# Update zoom if it changed
	if _card_state.zoom_level != old_zoom:
		_on_zoom_changed(_card_state.zoom_level)
	
	var effects_changed = _card_state.effect_settings != old_effects
	var focus_effects_changed = _card_state.focus_effect_settings != old_focus_effects
	
	# Rebuild effects if orientation or effect settings changed
	if _card_state.orientation != old_orientation or effects_changed or focus_effects_changed:
		_rebuild_effects()
		# If focused, restore focus state after rebuild
		if _is_focused:
			_show_focus_effects(true)

func set_image_priority(high_priority: bool):
	if _current_image_task_id > 0:
		MemoryManager.update_image_priority(_current_image_task_id, high_priority)
	elif high_priority and game:
		_load_cover(true)

# Called by VirtualScrollGridContainer when zoom changes
func set_card_zoom(new_zoom: float) -> void:
	_card_state.zoom_level = new_zoom

func get_current_texture() -> Texture2D:
	return _current_texture
