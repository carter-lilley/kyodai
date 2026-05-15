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
var _card_state: EffectContainerState = EffectContainerState.for_card()

var _loading_game_id: String = ""
var _image_retry_count: int = 0
var _current_image_task_id: int = -1
const MAX_IMAGE_RETRIES: int = 3

var _download_retry_count: int = 0
const MAX_DOWNLOAD_RETRIES: int = 2

# Status badge overlay (child of M3Card media panel)
var _status_badge: Panel = null
const STATUS_BADGE_SIZE_RATIO: float = 0.04
const STATUS_BADGE_MARGIN_RATIO: float = 0.05

# Focus
const FOCUS_TWEEN_DURATION: float = 0.12
var _focus_tween: Tween = null
var _is_focused: bool = false

# Android touch-and-hold
const LONG_PRESS_DURATION: float = 0.6
const LONG_PRESS_TOLERANCE_DP: float = 20.0
var _touch_start_time: float = 0.0
var _touch_start_pos: Vector2 = Vector2.ZERO
var _touch_is_holding: bool = false
var _long_press_timer: Timer = null

func _ready():
	print("[GameCard] _ready() START ", name)
	super._ready()
	
	# Configure M3Card text labels to prevent variable-height grid breakage
	var headline_label = get_node_or_null("RootContainer/TextMargin/TextContent/Headline")
	if headline_label:
		headline_label.max_lines_visible = 2
		headline_label.clip_text = true
		headline_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var supporting_label = get_node_or_null("RootContainer/TextMargin/TextContent/SupportingText")
	if supporting_label:
		supporting_label.max_lines_visible = 1
		supporting_label.clip_text = true
		supporting_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	
	if preview_mode:
		_setup_preview_mode()
		print("[GameCard] _ready() END (preview mode) ", name)
		return
	
	_update_card_state_from_settings()
	_build_media_stack()
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
	
	print("[GameCard] _ready() END ", name)

func _rebuild_layout():
	# Remove status badge before M3Card rebuilds, or it would be freed
	# if it's inside the media panel (which gets recreated).
	if _status_badge and _status_badge.get_parent():
		_status_badge.get_parent().remove_child(_status_badge)
	
	super._rebuild_layout()
	# M3Card frees _media_stack when it rebuilds its internal layout.
	# Null the reference and rebuild so the media stack is restored.
	_media_stack = null
	_build_media_stack()
	
	# Add status badge into the new media panel so it sits over the art
	if _status_badge:
		var media_panel = get_node_or_null("RootContainer/MediaPanel")
		if media_panel:
			media_panel.add_child(_status_badge)
		else:
			add_child(_status_badge)

func _setup_status_badge():
	_status_badge = Panel.new()
	_status_badge.name = "StatusBadge"
	_status_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_status_badge.visible = false
	_status_badge.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	var media_panel = get_node_or_null("RootContainer/MediaPanel")
	if media_panel:
		media_panel.add_child(_status_badge)
	else:
		add_child(_status_badge)
	_update_status_badge_style()

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
	if _media_stack and is_instance_valid(_media_stack):
		_media_stack.queue_free()
	
	_media_stack = EffectStack.new()
	var effect_settings := []
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			effect_settings = config_setting.value.get("effects", [])
	
	_media_stack.initialize(_card_state, effect_settings, "base_card")
	if _current_texture:
		_media_stack.set_game_texture(_current_texture)
	
	# Connect signal BEFORE adding to tree, so we catch the initial resize
	# that may fire synchronously during add_child().
	if not _media_stack.resized.is_connected(_on_media_stack_resized):
		_media_stack.resized.connect(_on_media_stack_resized)
	
	set_media_content(_media_stack)
	
	# If add_child() triggered an immediate layout and the EffectStack already
	# has its final size, the resized signal may have fired before we connected.
	# Explicitly initialize shader params in that case.
	if _media_stack.size.x > 0 and _media_stack.size.y > 0:
		_on_media_stack_resized()

func _on_media_stack_resized():
	print("[GameCard] _on_media_stack_resized() size=", _media_stack.size if _media_stack else "null")
	if not _media_stack or _media_stack.size.x <= 0 or _media_stack.size.y <= 0:
		print("[GameCard] _on_media_stack_resized() aborting: invalid size")
		return
	
	_card_state.container_size = _media_stack.size
	
	# The user's corner_radius_ratio is the source of truth.
	# Convert it to an absolute pixel radius for the current media panel, then to DP for M3Card.
	var min_dim = min(_media_stack.size.x, _media_stack.size.y)
	var radius_pixels = clampf(_card_state.corner_radius_ratio * min_dim, 0.0, min_dim)
	var new_corner_radius_dp = radius_pixels / M3Units.get_scale()
	print("[GameCard] _on_media_stack_resized() min_dim=", min_dim, " radius_pixels=", radius_pixels, " new_corner_radius_dp=", new_corner_radius_dp, " current_dp=", corner_radius_dp)
	if not is_equal_approx(new_corner_radius_dp, corner_radius_dp):
		self.corner_radius_dp = new_corner_radius_dp
	
	_media_stack.update_state(_card_state)
	_update_status_badge_layout()
	_update_platform_badge()

func _update_card_state_from_settings():
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			_card_state.effect_settings = config_setting.value.get("effects", [])
			var corner_value = config_setting.value.get("corner_radius", 0.06)
			if corner_value > 1.0:
				# Backward compat: old configs stored absolute pixels against the 3:4 vertical base width
				const LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP: float = 202.0
				_card_state.corner_radius_ratio = corner_value / M3Units.dp(LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP)
			else:
				_card_state.corner_radius_ratio = corner_value

func set_card_zoom(_zoom: float) -> void:
	# container_size is managed by _on_media_stack_resized() based on actual media panel size.
	# Setting zoom_level here would trigger _recalculate_dimensions() and overwrite container_size
	# with an incorrect value before the layout pass corrects it.
	pass

func refresh_settings() -> void:
	_update_card_state_from_settings()
	_build_media_stack()
	_update_platform_badge()
	_update_display()

func reset() -> void:
	game = null
	_current_texture = null
	_is_downloading = false
	_loading_game_id = ""
	_image_retry_count = 0
	_download_retry_count = 0
	if _current_image_task_id > 0 and MemoryManager:
		MemoryManager.cancel_image_task(_current_image_task_id)
		_current_image_task_id = -1
	if _status_badge:
		_status_badge.visible = false
	headline = ""
	supporting_text = ""
	if _media_stack:
		_media_stack.set_game_texture(null)

func set_placeholder(_enabled: bool) -> void:
	# No-op for M3Card-based GameCard
	pass

func restore_focus_animation() -> void:
	if _is_focused:
		_on_focus_entered()
	else:
		_on_focus_exited()

func _update_display():
	print("[GameCard] _update_display() game=", game, " ready=", is_node_ready())
	if not game or not is_node_ready():
		print("[GameCard] _update_display() aborting")
		return
	_update_status_icon()
	_update_platform_badge()
	_load_cover(false)
	headline = game.title
	supporting_text = game.platform if game.platform else ""
	print("[GameCard] _update_display() headline=", headline, " supporting=", supporting_text)

func _update_display_with_priority(high_priority: bool):
	if not game or not is_node_ready():
		return
	_update_status_icon()
	_update_platform_badge()
	_load_cover(high_priority)
	headline = game.title
	supporting_text = game.platform if game.platform else ""

func _update_status_badge_layout():
	if not _status_badge:
		return
	
	var panel_width: float = size.x
	var panel_height: float = size.y
	var parent = _status_badge.get_parent()
	if parent and parent != self:
		panel_width = parent.size.x
		panel_height = parent.size.y
	
	var badge_size = max(M3Units.dp(6.0), panel_width * STATUS_BADGE_SIZE_RATIO)
	var margin = max(M3Units.dp(4.0), panel_width * STATUS_BADGE_MARGIN_RATIO)
	
	# Position in bottom-right of the media panel so it sits over the art
	_status_badge.offset_left = -margin - badge_size
	_status_badge.offset_top = -margin - badge_size
	_status_badge.offset_right = -margin
	_status_badge.offset_bottom = -margin

func _update_status_badge_style():
	if not _status_badge:
		return
	var panel_width = size.x if size.x > 0 else _card_state.container_size.x
	var parent = _status_badge.get_parent()
	if parent and parent != self and parent.size.x > 0:
		panel_width = parent.size.x
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
	
	DataManager.load_image(cover_url, func(_texture: Texture2D):
		if not is_instance_valid(self):
			return
		if not game or game.id != target_game_id:
			return
		if FileAccess.file_exists(cache_path):
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
		return image
	return null

func _set_texture(tex: Texture2D) -> void:
	if tex == _current_texture:
		return
	_current_texture = tex
	if _media_stack:
		_media_stack.set_game_texture(tex)

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
					NotificationManager.show_notification("File not found - redownloading", Notification.Type.WARNING)
				download_requested.emit(game)
				return
		
		if LaunchManager:
			LaunchManager.launch_game(game, focus_index)
	else:
		download_requested.emit(game)

func _get_show_delete() -> bool:
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
			var center_pos = global_position + (size / 2)
			UIManager.show_game_context_menu(game.romm_id, center_pos, _get_show_delete())
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
		UIManager.show_game_context_menu(game.romm_id, _touch_start_pos, _get_show_delete())

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

func _on_focus_entered():
	_is_focused = true
	_update_status_icon()
	z_index = 1
	if _focus_tween:
		_focus_tween.kill()
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_QUAD)
	_focus_tween.set_ease(Tween.EASE_OUT)
	_focus_tween.tween_property(self, "scale", Vector2(1.08, 1.08), FOCUS_TWEEN_DURATION)

func _on_focus_exited():
	_is_focused = false
	_update_status_icon()
	z_index = 0
	if _focus_tween:
		_focus_tween.kill()
	_focus_tween = create_tween()
	_focus_tween.set_trans(Tween.TRANS_QUAD)
	_focus_tween.set_ease(Tween.EASE_OUT)
	_focus_tween.tween_property(self, "scale", Vector2.ONE, FOCUS_TWEEN_DURATION)

func _notification(what: int):
	super._notification(what)
	if what == NOTIFICATION_RESIZED:
		pivot_offset = size / 2.0
		_update_status_badge_layout()
