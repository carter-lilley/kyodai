class_name GameCard
extends M3Card

signal download_requested(game: GameResource)

@export var game: GameResource:
	set(value):
		if game == value:
			return
		game = value
		_update_display()

func set_game_with_priority(value: GameResource, high_priority: bool):
	game = value
	_update_display_with_priority(high_priority)

@export var preview_mode: bool = false

var _loading_texture: Texture2D = preload("res://icon.svg")
var _is_downloading: bool = false
var _current_texture: Texture2D = null

# Media effect stack rendered inside M3Card's media panel
var _media_stack: EffectStack = null
var _focus_stack: EffectStack = null
var _focus_effect_tweens: Array[Tween] = []
var _card_state: EffectContainerState = EffectContainerState.for_card()

var _loading_game_id: String = ""
var _image_retry_count: int = 0
var _current_image_task_id: int = -1
const MAX_IMAGE_RETRIES: int = 3

var _download_retry_count: int = 0
const MAX_DOWNLOAD_RETRIES: int = 2
const MAX_COVER_TEXTURE_SIZE: int = 512

# Status badge overlay (direct child of GameCard, positioned over media panel)
var _status_badge: Panel = null
var _badge_update_pending: bool = false
const STATUS_BADGE_SIZE_RATIO: float = 0.04
const STATUS_BADGE_MARGIN_RATIO: float = 0.05

# Focus
const FOCUS_TWEEN_DURATION: float = 0.12
const FOCUS_EFFECT_FADE_DURATION: float = 0.15
var _focus_tween: Tween = null
var _is_focused: bool = false
var focus_scale: float = 1.08
var focus_scale_enabled: bool = true
# If true, card starts at 1.0/focus_scale and grows to 1.0 when focused (LIST/CAROUSEL).
# If false, card starts at 1.0 and grows to focus_scale when focused (GRID).
var focus_scale_inverted: bool = false

# Android touch-and-hold
const LONG_PRESS_DURATION: float = 0.6
const LONG_PRESS_TOLERANCE_DP: float = 20.0
var _touch_start_time: float = 0.0
var _touch_start_pos: Vector2 = Vector2.ZERO
var _touch_is_holding: bool = false
var _long_press_timer: Timer = null

func _ready():
	super._ready()
	_sync_focus_visuals()
	
	if preview_mode:
		_setup_preview_mode()
		return
	
	_update_card_state_from_settings()
	_update_display()
	
	# Connect M3Card signals
	pressed.connect(_on_card_pressed)
	gui_input.connect(_on_card_gui_input)
	focus_entered.connect(_on_focus_entered)
	focus_exited.connect(_on_focus_exited)
	mouse_entered.connect(_on_card_mouse_entered)
	
	if DownloadManager:
		DownloadManager.download_progress.connect(_on_download_progress)
		DownloadManager.download_completed.connect(_on_download_completed)
	
	_setup_status_badge()
	
	# Setup long-press timer for Android
	if PlatformManager.is_android():
		_long_press_timer = Timer.new()
		_long_press_timer.wait_time = LONG_PRESS_DURATION
		_long_press_timer.one_shot = true
		_long_press_timer.timeout.connect(_on_long_press_timeout)
		add_child(_long_press_timer)

func _setup_status_badge():
	_status_badge = Panel.new()
	_status_badge.name = "StatusBadge"
	_status_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_badge.visible = false
	_status_badge.set_anchors_preset(Control.PRESET_TOP_LEFT)
	add_child(_status_badge)
	_update_status_badge_style()
	_update_status_badge_layout()

func get_card_state() -> EffectContainerState:
	return _card_state

func get_focus_shape_params() -> Dictionary:
	return {
		"shape_size": _card_state.container_size,
		"corner_radius_ratio": _card_state.corner_radius_ratio,
		"corner_radius_pixels": _card_state.corner_radius_pixels
	}

func get_current_texture() -> Texture2D:
	return _current_texture

func _setup_preview_mode():
	_update_card_state_from_settings()
	_build_media_stack()
	
	if DataManager:
		var random_game = DataManager.get_random_game()
		if random_game:
			self.game = random_game
		else:
			_set_texture(_loading_texture)
	else:
		_set_texture(_loading_texture)
	
	if _status_badge:
		_status_badge.visible = false
	
	disabled = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _build_media_stack():
	var effect_settings := []
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			effect_settings = config_setting.value.get("effects", [])
	
	if _media_stack and is_instance_valid(_media_stack):
		# Hot-reload: update configs in-place instead of rebuilding the node tree
		_media_stack.update_effect_configs(effect_settings)
		if _current_texture:
			_media_stack.set_game_texture(_current_texture)
	else:
		_media_stack = EffectStack.new()
		_media_stack.initialize(_card_state, effect_settings, "base_card")
		if _current_texture:
			_media_stack.set_game_texture(_current_texture)
		set_media_content(_media_stack)
	
	_build_focus_stack()

func _build_focus_stack() -> void:
	var focus_effect_settings := []
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			focus_effect_settings = config_setting.value.get("focus_effects", [])
	
	# If no focus effects configured, hide existing stack and return
	if focus_effect_settings.is_empty():
		if _focus_stack and is_instance_valid(_focus_stack):
			_focus_stack.visible = false
		return
	
	if _focus_stack and is_instance_valid(_focus_stack):
		# Hot-reload: update configs in-place
		_focus_stack.visible = false
		_focus_stack.update_effect_configs(focus_effect_settings)
		
		# Re-apply focus state setup after config update
		var focus_base = _focus_stack.get_effect("base")
		if focus_base:
			focus_base.visible = false
			focus_base.modulate.a = 0.0
		
		var focus_alpha = 1.0 if preview_mode else 0.0
		for child in _focus_stack.get_children():
			if child is EffectBase and child.material is ShaderMaterial:
				child.material.set_shader_parameter("effect_alpha", focus_alpha)
		
		if preview_mode:
			_focus_stack.visible = true
		
		if _current_texture:
			_focus_stack.set_game_texture(_current_texture)
		_link_overlapping_effects()
		return
	
	_focus_stack = EffectStack.new()
	_focus_stack.set_anchors_preset(Control.PRESET_FULL_RECT)
	_focus_stack.z_index = 5
	_focus_stack.visible = false
	_focus_stack.size = size
	add_child(_focus_stack)
	
	# Use a duplicated state so focus stack insets don't clobber base stack
	var focus_state = _card_state.duplicate()
	focus_state.effect_settings = focus_effect_settings.duplicate(true)
	
	_focus_stack.initialize(focus_state, focus_effect_settings, "focus_card")
	if _current_texture:
		_focus_stack.set_game_texture(_current_texture)
	
	# Hide base effect in focus stack — focus effects are overlays only
	var focus_base = _focus_stack.get_effect("base")
	if focus_base:
		focus_base.visible = false
		focus_base.modulate.a = 0.0
	
	# Initialize focus effects with effect_alpha = 0.0 so they start hidden
	# (shader default is 1.0, which would cause them to pop in before tween)
	var focus_alpha = 1.0 if preview_mode else 0.0
	for child in _focus_stack.get_children():
		if child is EffectBase and child.material is ShaderMaterial:
			child.material.set_shader_parameter("effect_alpha", focus_alpha)
	
	if preview_mode:
		_focus_stack.visible = true
	
	_link_overlapping_effects()

func _link_overlapping_effects() -> void:
	if not _media_stack or not _focus_stack:
		return
	
	var base_effect_ids: Array[String] = []
	for child in _media_stack.get_children():
		if child is EffectBase:
			base_effect_ids.append(child.effect_id)
	
	for child in _focus_stack.get_children():
		if not (child is EffectBase):
			continue
		var focus_effect = child as EffectBase
		if focus_effect.effect_id in base_effect_ids:
			var base_effect = _media_stack.get_effect(focus_effect.effect_id)
			if base_effect:
				focus_effect.set_base_effect(base_effect)
				if not _is_focused and base_effect._settings.size() > 0:
					focus_effect.tween_settings(base_effect._settings, base_effect._settings, 1.0)

func _show_focus_effects(show: bool) -> void:
	# Kill any existing focus effect tweens to prevent callbacks on freed objects
	for tween in _focus_effect_tweens:
		if tween and is_instance_valid(tween):
			tween.kill()
	_focus_effect_tweens.clear()
	
	if preview_mode:
		show = true
	
	if not _focus_stack or not _media_stack:
		return
	
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
	
	# Overlapping effects: tween the base effect's shader settings directly
	for focus_effect in overlapping_effects:
		var base_effect = focus_effect._base_effect
		if not base_effect:
			continue
		
		var base_settings = base_effect._settings
		var focus_settings = focus_effect._settings
		var base_copy = base_settings.duplicate(true)
		var focus_copy = focus_settings.duplicate(true)
		
		if show:
			var settings_tween = create_tween()
			_focus_effect_tweens.append(settings_tween)
			settings_tween.set_trans(Tween.TRANS_QUAD)
			settings_tween.set_ease(Tween.EASE_OUT)
			var tween_callable = func(t: float):
				if base_effect and is_instance_valid(base_effect):
					base_effect.tween_settings(base_copy, focus_copy, t)
			settings_tween.tween_method(tween_callable, 0.0, 1.0, FOCUS_EFFECT_FADE_DURATION)
		else:
			var settings_tween = create_tween()
			_focus_effect_tweens.append(settings_tween)
			settings_tween.set_trans(Tween.TRANS_QUAD)
			settings_tween.set_ease(Tween.EASE_OUT)
			var tween_callable = func(t: float):
				if base_effect and is_instance_valid(base_effect):
					base_effect.tween_settings(focus_copy, base_copy, t)
			settings_tween.tween_method(tween_callable, 0.0, 1.0, FOCUS_EFFECT_FADE_DURATION)
	
	# Non-overlapping effects: fade in/out via alpha overlay
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

func _update_card_state_from_settings():
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			_card_state.effect_settings = config_setting.value.get("effects", [])
			_card_state.focus_effect_settings = config_setting.value.get("focus_effects", [])
			var corner_value = config_setting.value.get("corner_radius", 0.06)
			if corner_value > 1.0:
				# Backward compat: old configs stored absolute pixels against the 3:4 vertical base width
				const LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP: float = 202.0
				_card_state.corner_radius_ratio = corner_value / M3Units.dp(LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP)
			else:
				_card_state.corner_radius_ratio = corner_value

func set_card_zoom(_zoom: float) -> void:
	# EffectStack updates container_size automatically via NOTIFICATION_RESIZED.
	# Setting zoom_level here would trigger _recalculate_dimensions() and overwrite container_size
	# with an incorrect value before the layout pass corrects it.
	pass

func set_focus_scale(value: float) -> void:
	focus_scale = maxf(value, 1.0)
	_sync_focus_visuals()

func refresh_settings() -> void:
	_update_card_state_from_settings()
	_build_media_stack()
	_update_platform_badge()
	_update_display()

func reset() -> void:
	game = null
	_current_texture = null
	_is_downloading = false
	_is_focused = false
	_loading_game_id = ""
	_image_retry_count = 0
	_download_retry_count = 0
	set_meta("_cached_show_delete", null)
	if _focus_tween:
		_focus_tween.kill()
		_focus_tween = null
	if _focus_effect_tweens:
		for tween in _focus_effect_tweens:
			if tween and is_instance_valid(tween):
				tween.kill()
		_focus_effect_tweens.clear()
	_sync_focus_visuals()
	if _current_image_task_id > 0 and MemoryManager:
		MemoryManager.cancel_image_task(_current_image_task_id)
		_current_image_task_id = -1
	if _status_badge:
		_status_badge.visible = false
	headline = ""
	supporting_text = ""
	if _media_stack:
		_media_stack.set_game_texture(null)
	if _focus_stack:
		_focus_stack.set_game_texture(null)
		# Ensure focus stack is hidden after reset
		if _focus_stack.visible:
			_focus_stack.visible = false
			_focus_stack.modulate = Color(1, 1, 1, 1)
			for child in _focus_stack.get_children():
				if child is EffectBase and child.material is ShaderMaterial:
					child.material.set_shader_parameter("effect_alpha", 0.0)

func set_placeholder(_enabled: bool) -> void:
	# No-op for M3Card-based GameCard
	pass

func set_image_priority(high_priority: bool) -> void:
	if _current_texture and _current_texture != _loading_texture:
		return  # Already loaded
	
	if _current_image_task_id > 0:
		if MemoryManager:
			MemoryManager.update_image_priority(_current_image_task_id, high_priority)
	elif high_priority:
		# No task in flight and no texture - retry load with high priority
		_load_cover(true)

func restore_focus_animation() -> void:
	# Re-sync visuals without full tween when layout changes underneath us
	_sync_focus_visuals()
	_show_focus_effects(_is_focused)

func _update_display():
	if not game or not is_node_ready():
		return
	_update_status_icon()
	_update_platform_badge()
	_load_cover(false)
	headline = game.title
	supporting_text = game.platform if game.platform else ""

func _update_display_with_priority(high_priority: bool):
	if not game or not is_node_ready():
		return
	_update_status_icon()
	_update_platform_badge()
	_load_cover(high_priority)
	headline = game.title
	supporting_text = game.platform if game.platform else ""

func _deferred_update_badges():
	_badge_update_pending = false
	_update_status_badge_layout()
	_update_platform_badge()

func _update_status_badge_layout():
	if not _status_badge:
		return
	
	var media_panel = get_node_or_null("RootContainer/MediaPanel")
	var panel_width: float = size.x
	var panel_height: float = size.y
	if media_panel and is_instance_valid(media_panel):
		panel_width = media_panel.size.x
		panel_height = media_panel.size.y
	
	var badge_size = max(M3Units.dp(6.0), panel_width * STATUS_BADGE_SIZE_RATIO)
	var margin = max(M3Units.dp(4.0), panel_width * STATUS_BADGE_MARGIN_RATIO)
	
	if media_panel and is_instance_valid(media_panel):
		_status_badge.position = media_panel.position + Vector2(
			panel_width - margin - badge_size,
			panel_height - margin - badge_size
		)
	else:
		_status_badge.position = Vector2(
			panel_width - margin - badge_size,
			panel_height - margin - badge_size
		)
	_status_badge.size = Vector2(badge_size, badge_size)

func _update_status_badge_style():
	if not _status_badge:
		return
	var media_panel = get_node_or_null("RootContainer/MediaPanel")
	var panel_width = size.x if size.x > 0 else _card_state.container_size.x
	if media_panel and is_instance_valid(media_panel) and media_panel.size.x > 0:
		panel_width = media_panel.size.x
	var badge_size = max(M3Units.dp(6.0), panel_width * STATUS_BADGE_SIZE_RATIO)
	var circle_radius = int(badge_size / 2.0)
	
	var new_style = StyleBoxFlat.new()
	if game and game.is_active_variant_downloaded():
		new_style.bg_color = Color(0.49, 0.714, 0.0, 1.0)
	else:
		new_style.bg_color = Color(0.0, 0.624, 0.922, 1.0)
	
	new_style.corner_radius_top_left = circle_radius
	new_style.corner_radius_top_right = circle_radius
	new_style.corner_radius_bottom_left = circle_radius
	new_style.corner_radius_bottom_right = circle_radius
	_status_badge.add_theme_stylebox_override("panel", new_style)

func _update_status_icon():
	if not _status_badge:
		return
	if not game:
		_status_badge.visible = false
		return
	_status_badge.visible = not _is_downloading
	_update_status_badge_layout()
	_update_status_badge_style()

func _update_platform_badge():
	if not _media_stack:
		return
	
	var normal_badge = _media_stack.get_effect("badge") as BadgeEffect
	if not normal_badge:
		return
	
	if not game:
		normal_badge.set_icon_texture(null)
		return
	
	var platform_slug = game.platform_slug
	var icon_texture: Texture2D = null
	
	var badge_config := {}
	for effect_data in _card_state.effect_settings:
		if effect_data is Dictionary and effect_data.get("effect_id") == "badge":
			badge_config = effect_data
			break
	
	var settings = badge_config.get("settings", {})
	var badge_type = settings.get("badge_type", 0)
	var badge_size_setting = settings.get("badge_size", 1.0)
	var inner_radius_setting = settings.get("badge_inner_radius", 0.0)
	
	var card_width = _card_state.container_size.x
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
	
	const BADGE_SIZE_RATIO: float = 0.16
	const BADGE_CORNER_RATIO: float = 0.11
	
	if badge_type == 1:
		var base_badge_size = BADGE_SIZE_RATIO * card_width
		var top_bar_max_size = card_width * 0.25
		var bar_height = min(base_badge_size * badge_size_setting, top_bar_max_size)
		var top_bar_safe_x = total_inset + effective_corner_radius
		var top_bar_safe_width = (card_width - total_inset * 2) - (effective_corner_radius * 2)
		var top_bar_safe_y = total_inset
		var top_bar_safe_height = bar_height
		
		normal_badge.set_badge_dimensions(Vector2(card_width, bar_height))
		normal_badge.set_border_inset_pixels(total_inset)
		normal_badge.set_safe_zone_top_bar(top_bar_safe_x, top_bar_safe_y, top_bar_safe_width, top_bar_safe_height, false)
	else:
		var raw_badge_size = BADGE_SIZE_RATIO * card_width * badge_size_setting
		var min_badge_size = card_width * 0.15
		var max_badge_size = card_width * 0.45
		var target_badge_size = clamp(raw_badge_size, min_badge_size, max_badge_size)
		
		var badge_width: float
		var badge_height: float
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
		
		var safe_x = total_inset + clamped_corner_margin
		var safe_y = total_inset + clamped_corner_margin
		var safe_width = max(badge_width - clamped_corner_margin - inner_corner_margin, 0.0)
		var safe_height = max(badge_height - clamped_corner_margin - inner_corner_margin, 0.0)
		
		normal_badge.set_badge_dimensions(Vector2(badge_width, badge_height))
		normal_badge.set_border_inset_pixels(total_inset)
		normal_badge.set_safe_zone(safe_x, safe_y, safe_width, safe_height, false)
	
	normal_badge.set_icon_texture(icon_texture)

func _load_cover(high_priority: bool = false):
	if not game:
		_set_texture(_loading_texture)
		return
	
	_loading_game_id = game.id
	_image_retry_count = 0
	_download_retry_count = 0
	
	var cache_path = ""
	var cover_url = ""
	if game.cover_path and FileAccess.file_exists(game.cover_path):
		cache_path = game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		cover_url = game.cover_url
		cache_path = _get_cached_cover_path(cover_url)
		if not FileAccess.file_exists(cache_path):
			if DataManager.is_sync_in_progress():
				_set_texture(_loading_texture)
				return
			else:
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
	var target_game_id = _loading_game_id
	
	_download_retry_count += 1
	if _download_retry_count > MAX_DOWNLOAD_RETRIES:
		_set_texture(_loading_texture)
		return
	
	_set_texture(_loading_texture)
	
	DataManager.load_image(cover_url, func(loaded_texture: Texture2D):
		if not is_instance_valid(self):
			return
		if not game or game.id != target_game_id:
			return
		if loaded_texture:
			MemoryManager.cache_texture(cache_path, loaded_texture)
			_set_texture(loaded_texture)
		elif FileAccess.file_exists(cache_path):
			_load_cover(high_priority)
		else:
			_set_texture(_loading_texture)
	)

func _load_image_from_buffer(buffer: PackedByteArray) -> Image:
	if buffer.size() < 16:
		return null
	
	var err = FAILED
	var image = Image.new()
	
	if buffer[0] == 0xFF and buffer[1] == 0xD8:
		err = image.load_jpg_from_buffer(buffer)
	elif buffer[0] == 0x89 and buffer[1] == 0x50:
		err = image.load_png_from_buffer(buffer)
	elif buffer[0] == 0x52 and buffer[1] == 0x49:
		err = image.load_webp_from_buffer(buffer)
	else:
		err = image.load_jpg_from_buffer(buffer)
		if err != OK:
			image = Image.new()
			err = image.load_png_from_buffer(buffer)
		if err != OK:
			image = Image.new()
			err = image.load_webp_from_buffer(buffer)
	
	if err == OK:
		# Downscale large images to save GPU memory and improve sampling performance
		var max_dim = max(image.get_width(), image.get_height())
		if max_dim > MAX_COVER_TEXTURE_SIZE:
			var scale = float(MAX_COVER_TEXTURE_SIZE) / max_dim
			var new_width = max(1, int(image.get_width() * scale))
			var new_height = max(1, int(image.get_height() * scale))
			image.resize(new_width, new_height, Image.INTERPOLATE_LANCZOS)
		return image
	return null

func _set_texture(tex: Texture2D) -> void:
	if tex == _current_texture:
		return
	_current_texture = tex
	if _media_stack:
		_media_stack.set_game_texture(tex)
	if _focus_stack:
		_focus_stack.set_game_texture(tex)

func _on_card_pressed():
	if not game:
		return
	
	var focus_index = self.get_meta("virtual_index", -1)
	
	if game.source == "gamenative":
		if LaunchManager:
			LaunchManager.launch_game(game, focus_index)
		return
	
	if game.is_active_variant_downloaded():
		var root_folder = SettingsManager.get_setting("games_root_folder") if SettingsManager else null
		if root_folder and root_folder.value != "":
			var active_file_name = game.get_active_file_name()
			var file_path = root_folder.value + "/" + game.platform_slug + "/" + active_file_name
			if not FileAccess.file_exists(file_path):
				if NotificationManager:
					NotificationManager.show_notification("File not found - redownloading", NotificationManager.Type.WARNING)
				download_requested.emit(game)
				return
		
		if LaunchManager:
			LaunchManager.launch_game(game, focus_index)
	else:
		download_requested.emit(game)

func _get_show_delete() -> bool:
	# Cache the result to avoid parent traversal on every context menu open
	var cached = get_meta("_cached_show_delete", null)
	if cached != null:
		return cached
	
	var parent = get_parent()
	while parent:
		if parent is HomeView:
			set_meta("_cached_show_delete", true)
			return true
		elif parent is LibraryView:
			set_meta("_cached_show_delete", false)
			return false
		parent = parent.get_parent()
	set_meta("_cached_show_delete", false)
	return false

func _on_card_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			if game and UIManager:
				UIManager.show_game_context_menu(game.romm_id, self, _get_show_delete())

func _on_card_mouse_entered() -> void:
	if not _can_accept_focus():
		return
	if UIManager and UIManager.should_card_grab_focus_on_hover():
		if not has_focus():
			set_meta("mouse_hover_focus", true)
			grab_focus()

func _input(event: InputEvent) -> void:
	if not _can_accept_focus():
		return
	
	if event.is_action_pressed("ui_select"):
		var focused = get_viewport().gui_get_focus_owner()
		if focused == self and game and UIManager:
			if AudioManager:
				AudioManager.play_sfx_modulate("click_03", 1.2, 1.2, 0.0)
			UIManager.show_game_context_menu(game.romm_id, self, _get_show_delete())
			get_viewport().set_input_as_handled()
	
	if PlatformManager.is_android() and event is InputEventScreenTouch:
		if event.pressed:
			var touch_pos = event.position
			if get_global_rect().has_point(touch_pos):
				_touch_start_time = Time.get_ticks_msec() / 1000.0
				_touch_start_pos = touch_pos
				_touch_is_holding = true
				if _long_press_timer:
					_long_press_timer.start()
		else:
			if _touch_is_holding:
				_touch_is_holding = false
				if _long_press_timer:
					_long_press_timer.stop()
	
	if PlatformManager.is_android() and event is InputEventScreenDrag:
		if _touch_is_holding:
			var current_pos = event.position
			var distance = _touch_start_pos.distance_to(current_pos)
			if distance > M3Units.dp(LONG_PRESS_TOLERANCE_DP):
				_touch_is_holding = false
				if _long_press_timer:
					_long_press_timer.stop()

func _on_long_press_timeout() -> void:
	if _touch_is_holding and game and UIManager:
		_touch_is_holding = false
		if AudioManager:
			AudioManager.play_sfx_modulate("click_03", 1.2, 1.2, 0.0)
		UIManager.show_game_context_menu(game.romm_id, self, _get_show_delete())

func _can_accept_focus() -> bool:
	var home_view = _find_home_view()
	if home_view and home_view.has_method("are_intro_animations_complete"):
		if not home_view.are_intro_animations_complete():
			return false
	if LaunchTransitionOverlay.is_transition_active:
		return false
	return true

func _find_home_view() -> Node:
	var current = get_parent()
	while current:
		if current is HomeView:
			return current
		current = current.get_parent()
	return null

func _on_download_progress(_game_id: String, _progress: float):
	pass

func _on_download_completed(game_id: String, _success: bool):
	if game and game.id == game_id:
		_is_downloading = false
		_update_status_icon()

func _apply_content_scale() -> void:
	super._apply_content_scale()
	if _focus_stack and is_instance_valid(_focus_stack):
		_focus_stack.scale = content_scale
		_focus_stack.pivot_offset = _focus_stack.size / 2.0

func _sync_focus_visuals() -> void:
	if not focus_scale_enabled:
		content_scale = Vector2.ONE
		return
	var target_scale: Vector2
	if focus_scale_inverted:
		target_scale = Vector2.ONE if _is_focused else Vector2.ONE / focus_scale
	else:
		target_scale = Vector2.ONE * focus_scale if _is_focused else Vector2.ONE
	if not is_equal_approx(content_scale.x, target_scale.x) or not is_equal_approx(content_scale.y, target_scale.y):
		content_scale = target_scale

func _on_focus_entered():
	_is_focused = true
	_update_status_icon()
	z_index = 1
	if _focus_tween:
		_focus_tween.kill()
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_QUAD)
	_focus_tween.set_ease(Tween.EASE_OUT)
	if focus_scale_enabled:
		var start_scale = content_scale
		var target_scale = Vector2.ONE if focus_scale_inverted else Vector2.ONE * focus_scale
		_focus_tween.tween_method(
			func(t: float):
				if not is_instance_valid(self):
					return
				content_scale = start_scale.lerp(target_scale, t),
			0.0, 1.0, FOCUS_TWEEN_DURATION
		)
	_show_focus_effects(true)

func _on_focus_exited():
	_is_focused = false
	_update_status_icon()
	z_index = 0
	if _focus_tween:
		_focus_tween.kill()
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_QUAD)
	_focus_tween.set_ease(Tween.EASE_OUT)
	if focus_scale_enabled:
		var start_scale = content_scale
		var target_scale = Vector2.ONE / focus_scale if focus_scale_inverted else Vector2.ONE
		_focus_tween.tween_method(
			func(t: float):
				if not is_instance_valid(self):
					return
				content_scale = start_scale.lerp(target_scale, t),
			0.0, 1.0, FOCUS_TWEEN_DURATION
		)
	_show_focus_effects(false)

func _notification(what: int):
	super._notification(what)
	if what == NOTIFICATION_RESIZED:
		pivot_offset = size / 2.0
		if not _badge_update_pending:
			_badge_update_pending = true
			call_deferred("_deferred_update_badges")
		if _focus_stack and is_instance_valid(_focus_stack):
			_focus_stack.size = size
