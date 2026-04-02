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
@onready var status_badge: Panel = $VisualContainer/CardInput/StatusBadge
@onready var platform_icon: TextureRect = $VisualContainer/CardInput/PlatformIcon
@onready var game_title_label: Label = $VisualContainer/CardInput/GameTitleLabel

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
const ICON_SIZE_RATIO: float = 0.16  # Icon slightly larger to fill badge

var _current_texture: Texture2D = null
var _card_state: CardState = CardState.new()

# Static cache for icon materials to reduce shader compilation overhead
static var _icon_material_cache: Dictionary = {}

var _base_effect: BaseCardEffect = null
var _border_effect: BorderEffect = null
var _badge_effect: BadgeEffect = null
var _drop_shadow_effect: DropShadowEffect = null
var _glow_effect: GlowEffect = null
var _glass_effect: GlassEffect = null
var _distort_effect: DistortEffect = null
var _gradient_overlay_effect: GradientOverlayEffect = null

# Focus effects - shown only when card is focused
var _focus_border_effect: BorderEffect = null
var _focus_badge_effect: BadgeEffect = null
var _focus_drop_shadow_effect: DropShadowEffect = null
var _focus_glow_effect: GlowEffect = null
var _focus_glass_effect: GlassEffect = null
var _focus_distort_effect: DistortEffect = null
var _focus_gradient_overlay_effect: GradientOverlayEffect = null

var _loading_game_id: String = ""
var _image_retry_count: int = 0
var _current_image_task_id: int = -1
const MAX_IMAGE_RETRIES: int = 3

# Track download retries separately from image load retries
var _download_retry_count: int = 0
const MAX_DOWNLOAD_RETRIES: int = 2

const FOCUSED_SCALE: float = 1.08
const FOCUS_TWEEN_DURATION: float = 0.12
const FOCUSED_BORDER_MULTIPLIER: float = 0.85  # Border is 65% of normal size when focused (smaller)
const FOCUS_EFFECT_FADE_DURATION: float = 0.15  # Duration for focus effects fade in/out
var _focus_tween: Tween = null
var _original_border_size: float = 0.05  # Default border size, will be set from config

# Enter animation constants
const ENTER_START_SCALE: float = 3.0
const ENTER_TWEEN_DURATION: float = 1.75
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
		"corner_radius_ratio": _card_state.corner_radius_ratio,
		"corner_radius_pixels": _card_state.corner_radius_pixels
	}

func _update_card_state_from_settings():
	if SettingsManager:
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting:
			if config_setting.value is Dictionary:
				#print("[GameCard] Loading from SettingsManager. focus_effects: ", config_setting.value.get("focus_effects", []))
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
			_badge_effect.visible = true
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
			_border_effect.visible = true
			_border_effect.update_state(_card_state)
			_border_effect.update_settings(border_config.get("settings", {}))
		
		# Calculate border inset (only solid border affects inset, fade overlays on top)
		var border_size = border_config.get("settings", {}).get("border_size", 0.05)
		_original_border_size = border_size
		_card_state.border_inset_ratio = border_size
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
	
	# Distort effect - optional texture distortion (rendered BEFORE glass so it appears behind)
	var distort_config = _get_effect_config("distort")
	if distort_config:
		if _distort_effect == null:
			_distort_effect = DistortEffect.new()
			_distort_effect.name = "DistortEffect"
			_distort_effect.anchor_right = 1.0
			_distort_effect.anchor_bottom = 1.0
			visual_container.add_child(_distort_effect)
			_distort_effect.initialize(_card_state, distort_config.get("settings", {}))
		else:
			_distort_effect.update_state(_card_state)
			_distort_effect.update_settings(distort_config.get("settings", {}))
			_distort_effect.visible = true
	elif _distort_effect != null:
		_distort_effect.visible = false
	
	# Gradient overlay effect - optional full-screen gradient (rendered BETWEEN distort and glass)
	var gradient_overlay_config = _get_effect_config("gradient_overlay")
	if gradient_overlay_config:
		if _gradient_overlay_effect == null:
			_gradient_overlay_effect = GradientOverlayEffect.new()
			_gradient_overlay_effect.name = "GradientOverlayEffect"
			_gradient_overlay_effect.anchor_right = 1.0
			_gradient_overlay_effect.anchor_bottom = 1.0
			visual_container.add_child(_gradient_overlay_effect)
			_gradient_overlay_effect.initialize(_card_state, gradient_overlay_config.get("settings", {}))
		else:
			_gradient_overlay_effect.update_state(_card_state)
			_gradient_overlay_effect.update_settings(gradient_overlay_config.get("settings", {}))
			_gradient_overlay_effect.visible = true
	elif _gradient_overlay_effect != null:
		_gradient_overlay_effect.visible = false
	
	# Glass effect - optional overlay (rendered AFTER distort so it appears on top)
	var glass_config = _get_effect_config("glass")
	if glass_config:
		if _glass_effect == null:
			_glass_effect = GlassEffect.new()
			_glass_effect.name = "GlassEffect"
			_glass_effect.anchor_right = 1.0
			_glass_effect.anchor_bottom = 1.0
			visual_container.add_child(_glass_effect)
			_glass_effect.initialize(_card_state, glass_config.get("settings", {}))
		else:
			_glass_effect.update_state(_card_state)
			_glass_effect.update_settings(glass_config.get("settings", {}))
			_glass_effect.visible = true
		
		# Calculate glass inset
		var glass_inset = glass_config.get("settings", {}).get("additional_inset_ratio", 0.0)
		_card_state.glass_inset_ratio = glass_inset
	elif _glass_effect != null:
		_glass_effect.visible = false
		_card_state.glass_inset_ratio = 0.0
	
	# Build focus effects from CardState
	_rebuild_focus_effects()
	
	# Ensure card_input is on top
	if card_input:
		visual_container.move_child(card_input, -1)
	
	if _current_texture:
		_set_texture(_current_texture)
	
	_update_platform_badge()
	_update_status_badge_layout()


func _rebuild_focus_effects():
	"""Rebuild focus effects - shown only when card is focused."""
	# Focus Border effect
	var focus_border_config = _get_focus_effect_config("border")
	if focus_border_config:
		if _focus_border_effect == null:
			_focus_border_effect = BorderEffect.new()
			_focus_border_effect.name = "FocusBorderEffect"
			_focus_border_effect.anchor_right = 1.0
			_focus_border_effect.anchor_bottom = 1.0
			# Set initial shader alpha (will be hidden via effect_alpha shader param)
			visual_container.add_child(_focus_border_effect)
			_focus_border_effect.initialize(_card_state, focus_border_config.get("settings", {}))
		else:
			_focus_border_effect.visible = true
			_focus_border_effect.update_state(_card_state)
			_focus_border_effect.update_settings(focus_border_config.get("settings", {}))
		if not _is_focused and not preview_mode:
			if _focus_border_effect.material is ShaderMaterial:
				_focus_border_effect.material.set_shader_parameter("effect_alpha", 0.0)
		else:
			if _focus_border_effect.material is ShaderMaterial:
				_focus_border_effect.material.set_shader_parameter("effect_alpha", 1.0)
	elif _focus_border_effect != null:
		print("[GameCard] Hiding border effect (removed from config)")
		_focus_border_effect.visible = false
		if _focus_border_effect.material is ShaderMaterial:
			_focus_border_effect.material.set_shader_parameter("effect_alpha", 0.0)
	
	# Focus Badge effect
	var focus_badge_config = _get_focus_effect_config("badge")
	if focus_badge_config:
		if _focus_badge_effect == null:
			_focus_badge_effect = BadgeEffect.new()
			_focus_badge_effect.name = "FocusBadgeEffect"
			_focus_badge_effect.anchor_right = 1.0
			_focus_badge_effect.anchor_bottom = 1.0
			# Set initial shader alpha (will be hidden via effect_alpha shader param)
			visual_container.add_child(_focus_badge_effect)
			_focus_badge_effect.initialize(_card_state, focus_badge_config.get("settings", {}))
		else:
			_focus_badge_effect.visible = true
			_focus_badge_effect.update_state(_card_state)
			_focus_badge_effect.update_settings(focus_badge_config.get("settings", {}))
		if not _is_focused and not preview_mode:
			if _focus_badge_effect.material is ShaderMaterial:
				_focus_badge_effect.material.set_shader_parameter("effect_alpha", 0.0)
		else:
			if _focus_badge_effect.material is ShaderMaterial:
				_focus_badge_effect.material.set_shader_parameter("effect_alpha", 1.0)
	elif _focus_badge_effect != null:
		_focus_badge_effect.visible = false
		if _focus_badge_effect.material is ShaderMaterial:
			_focus_badge_effect.material.set_shader_parameter("effect_alpha", 0.0)
	
	# Focus Drop Shadow effect
	var focus_drop_shadow_config = _get_focus_effect_config("drop_shadow")
	if focus_drop_shadow_config:
		if _focus_drop_shadow_effect == null:
			_focus_drop_shadow_effect = DropShadowEffect.new()
			_focus_drop_shadow_effect.name = "FocusDropShadowEffect"
			_focus_drop_shadow_effect.set_anchors_preset(Control.PRESET_CENTER)
			# Set initial shader alpha (will be hidden via effect_alpha shader param)
			visual_container.add_child(_focus_drop_shadow_effect)
			_focus_drop_shadow_effect.initialize(_card_state, focus_drop_shadow_config.get("settings", {}))
		else:
			_focus_drop_shadow_effect.visible = true
			_focus_drop_shadow_effect.update_state(_card_state)
			_focus_drop_shadow_effect.update_settings(focus_drop_shadow_config.get("settings", {}))
		if not _is_focused and not preview_mode:
			if _focus_drop_shadow_effect.material is ShaderMaterial:
				_focus_drop_shadow_effect.material.set_shader_parameter("effect_alpha", 0.0)
		else:
			if _focus_drop_shadow_effect.material is ShaderMaterial:
				_focus_drop_shadow_effect.material.set_shader_parameter("effect_alpha", 1.0)
	elif _focus_drop_shadow_effect != null:
		_focus_drop_shadow_effect.visible = false
		if _focus_drop_shadow_effect.material is ShaderMaterial:
			_focus_drop_shadow_effect.material.set_shader_parameter("effect_alpha", 0.0)
	
	# Focus Glow effect
	var focus_glow_config = _get_focus_effect_config("glow")
	if focus_glow_config:
		if _focus_glow_effect == null:
			_focus_glow_effect = GlowEffect.new()
			_focus_glow_effect.name = "FocusGlowEffect"
			_focus_glow_effect.set_anchors_preset(Control.PRESET_CENTER)
			# Set initial shader alpha (will be hidden via effect_alpha shader param)
			visual_container.add_child(_focus_glow_effect)
			_focus_glow_effect.initialize(_card_state, focus_glow_config.get("settings", {}))
		else:
			_focus_glow_effect.visible = true
			_focus_glow_effect.update_state(_card_state)
			_focus_glow_effect.update_settings(focus_glow_config.get("settings", {}))
		if not _is_focused and not preview_mode:
			if _focus_glow_effect.material is ShaderMaterial:
				_focus_glow_effect.material.set_shader_parameter("effect_alpha", 0.0)
		else:
			if _focus_glow_effect.material is ShaderMaterial:
				_focus_glow_effect.material.set_shader_parameter("effect_alpha", 1.0)
	elif _focus_glow_effect != null:
		_focus_glow_effect.visible = false
		if _focus_glow_effect.material is ShaderMaterial:
			_focus_glow_effect.material.set_shader_parameter("effect_alpha", 0.0)
	
	# Focus Distort effect
	var focus_distort_config = _get_focus_effect_config("distort")
	if focus_distort_config:
		if _focus_distort_effect == null:
			_focus_distort_effect = DistortEffect.new()
			_focus_distort_effect.name = "FocusDistortEffect"
			_focus_distort_effect.anchor_right = 1.0
			_focus_distort_effect.anchor_bottom = 1.0
			# Set initial shader alpha (will be hidden via effect_alpha shader param)
			visual_container.add_child(_focus_distort_effect)
			_focus_distort_effect.initialize(_card_state, focus_distort_config.get("settings", {}))
		else:
			_focus_distort_effect.visible = true
			_focus_distort_effect.update_state(_card_state)
			_focus_distort_effect.update_settings(focus_distort_config.get("settings", {}))
		if not _is_focused and not preview_mode:
			if _focus_distort_effect.material is ShaderMaterial:
				_focus_distort_effect.material.set_shader_parameter("effect_alpha", 0.0)
		else:
			if _focus_distort_effect.material is ShaderMaterial:
				_focus_distort_effect.material.set_shader_parameter("effect_alpha", 1.0)
	elif _focus_distort_effect != null:
		_focus_distort_effect.visible = false
		if _focus_distort_effect.material is ShaderMaterial:
			_focus_distort_effect.material.set_shader_parameter("effect_alpha", 0.0)
	
	# Focus Gradient Overlay effect
	var focus_gradient_config = _get_focus_effect_config("gradient_overlay")
	if focus_gradient_config:
		if _focus_gradient_overlay_effect == null:
			_focus_gradient_overlay_effect = GradientOverlayEffect.new()
			_focus_gradient_overlay_effect.name = "FocusGradientOverlayEffect"
			_focus_gradient_overlay_effect.anchor_right = 1.0
			_focus_gradient_overlay_effect.anchor_bottom = 1.0
			# Set initial shader alpha (will be hidden via effect_alpha shader param)
			visual_container.add_child(_focus_gradient_overlay_effect)
			_focus_gradient_overlay_effect.initialize(_card_state, focus_gradient_config.get("settings", {}))
		else:
			_focus_gradient_overlay_effect.visible = true
			_focus_gradient_overlay_effect.update_state(_card_state)
			_focus_gradient_overlay_effect.update_settings(focus_gradient_config.get("settings", {}))
		if not _is_focused and not preview_mode:
			if _focus_gradient_overlay_effect.material is ShaderMaterial:
				_focus_gradient_overlay_effect.material.set_shader_parameter("effect_alpha", 0.0)
		else:
			if _focus_gradient_overlay_effect.material is ShaderMaterial:
				_focus_gradient_overlay_effect.material.set_shader_parameter("effect_alpha", 1.0)
	elif _focus_gradient_overlay_effect != null:
		print("[GameCard] Hiding gradient overlay effect (removed from config)")
		_focus_gradient_overlay_effect.visible = false
		if _focus_gradient_overlay_effect.material is ShaderMaterial:
			_focus_gradient_overlay_effect.material.set_shader_parameter("effect_alpha", 0.0)
	
	# Focus Glass effect
	var focus_glass_config = _get_focus_effect_config("glass")
	if focus_glass_config:
		if _focus_glass_effect == null:
			_focus_glass_effect = GlassEffect.new()
			_focus_glass_effect.name = "FocusGlassEffect"
			_focus_glass_effect.anchor_right = 1.0
			_focus_glass_effect.anchor_bottom = 1.0
			# Set initial shader alpha (will be hidden via effect_alpha shader param)
			visual_container.add_child(_focus_glass_effect)
			_focus_glass_effect.initialize(_card_state, focus_glass_config.get("settings", {}))
		else:
			_focus_glass_effect.visible = true
			_focus_glass_effect.update_state(_card_state)
			_focus_glass_effect.update_settings(focus_glass_config.get("settings", {}))
			if not _is_focused and not preview_mode:
				if _focus_glass_effect.material is ShaderMaterial:
					_focus_glass_effect.material.set_shader_parameter("effect_alpha", 0.0)
			else:
				if _focus_glass_effect.material is ShaderMaterial:
					_focus_glass_effect.material.set_shader_parameter("effect_alpha", 1.0)
	elif _focus_glass_effect != null:
		_focus_glass_effect.visible = false
		if _focus_glass_effect.material is ShaderMaterial:
			_focus_glass_effect.material.set_shader_parameter("effect_alpha", 0.0)


func _get_focus_effect_config(effect_id: String) -> Dictionary:
	"""Get focus effect configuration from CardState."""
	for effect_data in _card_state.focus_effect_settings:
		if effect_data.get("effect_id") == effect_id:
			return effect_data
	return {}


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
	
	# Sync badge effect state so it has correct container_size for ratio calculations
	if _badge_effect and _badge_effect.visible:
		_badge_effect.update_state(_card_state)
	
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
	var show_on_all = false
	if SettingsManager:
		var setting = SettingsManager.get_setting("library_show_title_on_all_cards")
		if setting:
			show_on_all = setting.value
	
	# Show if: setting is enabled (show on all) OR card is focused
	game_title_label.visible = show_on_all or _is_focused

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
	# Use pre-calculated shape parameters from CardState (shared by all effects)
	var corner_radius_pixels = _card_state.corner_radius_pixels
	var total_inset = _card_state.total_inset_pixels
	
	# Effective corner radius at the inset position (min-dimension based for card)
	var effective_corner_radius = max(0, corner_radius_pixels - total_inset)
	
	# For badge: use the same calculation as the shader will use
	var effective_corner_radius_badge = effective_corner_radius
	
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
		# Cap top bar height at 25% of card width (smaller than corner badge max)
		var top_bar_max_size = card_width * 0.25
		var bar_height = min(base_badge_size * badge_size_setting, top_bar_max_size)
		
		# Calculate top bar safe zone - Y always at top, X constrained by corner radius
		# X: inset by radius from left/right rounded corners (inside point of bevel)
		# Y: always at top (total_inset)
		var top_bar_safe_x = total_inset + effective_corner_radius
		var top_bar_safe_width = (card_width - total_inset * 2) - (effective_corner_radius * 2)
		var top_bar_safe_y = total_inset
		var top_bar_safe_height = bar_height
		
		# Apply padding inside the safe zone (like corner mode)
		# Padding reduces the drawable area, not the safe zone itself
		var padding_x = top_bar_safe_width * icon_padding * 0.25
		var padding_y = top_bar_safe_height * icon_padding * 0.25
		var drawable_x = top_bar_safe_x + padding_x
		var drawable_y = top_bar_safe_y + padding_y
		var drawable_width = max(top_bar_safe_width - padding_x * 2, 10)
		var drawable_height = max(top_bar_safe_height - padding_y * 2, 10)
		
		# Calculate wordmark dimensions to fit within drawable area
		var draw_height = drawable_height
		var draw_width = draw_height * texture_aspect
		
		# Clamp width to fit within drawable width
		if draw_width > drawable_width:
			draw_width = drawable_width
			draw_height = draw_width / texture_aspect
		
		# Center within drawable area
		var offset_x = drawable_x + (drawable_width - draw_width) * 0.5
		var offset_y = drawable_y + (drawable_height - draw_height) * 0.5
		
		# Hide icon if drawable area is too small
		if draw_width < 10.0 or draw_height < 10.0:
			platform_icon.visible = false
		else:
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
			_badge_effect.set_border_inset_pixels(total_inset)
			# Pass the top bar safe zone (cyan debug overlay)
			_badge_effect.set_safe_zone_top_bar(top_bar_safe_x, top_bar_safe_y, top_bar_safe_width, top_bar_safe_height, false)
		
		return
	
	
	var corner_midpoint_factor = 1.0 - sqrt(2.0) / 2.0
	# effective_corner_radius is already the actual radius in pixels (min-dim based)
	# corner_margin is the distance from edge to the midpoint of the rounded curve
	# Minimum 3px margin to prevent collapse with tiny radii
	var corner_margin = effective_corner_radius * corner_midpoint_factor
	
	# Calculate badge size: independent of corner radius
	# Scales from 15% to 45% of card width based on badge_size_setting (0.5 to 2.0)
	# This ensures badge never disappears and has consistent sizing
	var raw_badge_size = BADGE_SIZE_RATIO * card_width * badge_size_setting
	var min_badge_size = card_width * 0.15  # 15% minimum - larger minimum for better visibility
	var max_badge_size = card_width * 0.45  # 45% maximum - larger maximum for bigger badges
	var target_badge_size = clamp(raw_badge_size, min_badge_size, max_badge_size)
	
	var badge_width: float
	var badge_height: float
	if texture_aspect >= 1.0:
		badge_width = target_badge_size * texture_aspect
		badge_height = target_badge_size
	else:
		badge_width = target_badge_size
		badge_height = target_badge_size / texture_aspect
	
	var base_min_dim = min(badge_width, badge_height)
	var base_inner_corner = (base_min_dim * 0.5) * clamp(inner_radius_setting, 0.0, 1.0)
	var inner_corner_margin = base_inner_corner * corner_midpoint_factor
	
	# Safe zone calculation:
	# Start at: total_inset + outer_corner_margin (after card's rounded edge midpoint)
	# End at: total_inset + badge_size - inner_corner_margin (before badge's inner rounded corner)
	# This creates a rectangular safe area between the two curved regions
	# Cap corner_margin so it never exceeds 80% of badge size (prevents negative safe zone)
	var max_corner_margin = badge_width * 0.8
	var clamped_corner_margin = min(corner_margin, max_corner_margin)
	
	var safe_x = total_inset + clamped_corner_margin
	var safe_y = total_inset + clamped_corner_margin
	var safe_width = badge_width - clamped_corner_margin - inner_corner_margin
	var safe_height = badge_height - clamped_corner_margin - inner_corner_margin
	
	# Safe zone can shrink to zero if needed - icon will scale proportionally or disappear
	safe_width = max(safe_width, 0.0)
	safe_height = max(safe_height, 0.0)
	
	if _badge_effect:
		_badge_effect.set_badge_dimensions(Vector2(badge_width, badge_height))
		_badge_effect.set_border_inset_pixels(total_inset)
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
	
	# Hide icon if safe zone is too small (less than 10px)
	if safe_width < 10.0 or safe_height < 10.0:
		platform_icon.visible = false
		return
	
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

# Helper function to update icon position during inset animation (focus/unfocus)
func _update_platform_icon_position_from_inset(current_border_inset_ratio: float) -> void:
	if not platform_icon:
		return
	
	var badge_config = _get_effect_config("badge")
	var settings = badge_config.get("settings", {})
	
	var badge_size_setting = settings.get("badge_size", 1.0)
	var inner_radius_setting = settings.get("badge_inner_radius", 0.0)
	var icon_padding = settings.get("icon_padding", 0.5)
	var badge_type = settings.get("badge_type", 0)
	
	var card_width = _card_state.card_size.x
	var corner_radius_pixels = _card_state.corner_radius_pixels
	
	# Calculate current total inset from the animated border inset ratio
	var current_border_inset_pixels = current_border_inset_ratio * card_width
	
	# Get glass inset directly from config (more reliable than state during animation)
	var glass_config = _get_effect_config("glass")
	var glass_inset_ratio = 0.0
	if glass_config:
		glass_inset_ratio = glass_config.get("settings", {}).get("additional_inset_ratio", 0.0)
	var glass_inset_pixels = glass_inset_ratio * card_width
	
	var total_inset = current_border_inset_pixels + glass_inset_pixels
	
	# Debug: Check if icon is being positioned off-screen
	if total_inset > card_width * 0.5:
		push_warning("[GameCard] total_inset (" + str(total_inset) + "px) is very large for card width " + str(card_width) + "px")
	
	var effective_corner_radius = max(0, corner_radius_pixels - total_inset)
	var base_badge_size = BADGE_SIZE_RATIO * card_width
	
	var texture_size = platform_icon.texture.get_size() if platform_icon.texture else Vector2(32, 32)
	var texture_aspect = texture_size.x / texture_size.y if texture_size.y > 0 else 1.0
	
	if badge_type != 1:
		texture_aspect = 1.0
	
	if badge_type == 1:
		# Top bar mode
		var top_bar_max_size = card_width * 0.25
		var bar_height = min(base_badge_size * badge_size_setting, top_bar_max_size)
		
		var top_bar_safe_x = total_inset + effective_corner_radius
		var top_bar_safe_width = (card_width - total_inset * 2) - (effective_corner_radius * 2)
		var top_bar_safe_y = total_inset
		var top_bar_safe_height = bar_height
		
		var padding_x = top_bar_safe_width * icon_padding * 0.25
		var padding_y = top_bar_safe_height * icon_padding * 0.25
		var drawable_x = top_bar_safe_x + padding_x
		var drawable_y = top_bar_safe_y + padding_y
		var drawable_width = max(top_bar_safe_width - padding_x * 2, 10)
		var drawable_height = max(top_bar_safe_height - padding_y * 2, 10)
		
		var draw_height = drawable_height
		var draw_width = draw_height * texture_aspect
		
		if draw_width > drawable_width:
			draw_width = drawable_width
			draw_height = draw_width / texture_aspect
		
		var offset_x = drawable_x + (drawable_width - draw_width) * 0.5
		var offset_y = drawable_y + (drawable_height - draw_height) * 0.5
		
		platform_icon.offset_left = offset_x
		platform_icon.offset_top = offset_y
		platform_icon.offset_right = offset_x + draw_width
		platform_icon.offset_bottom = offset_y + draw_height
	else:
		# Corner badge mode
		var corner_midpoint_factor = 1.0 - sqrt(2.0) / 2.0
		var corner_margin = effective_corner_radius * corner_midpoint_factor
		
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
		
		var base_min_dim = min(badge_width, badge_height)
		var base_inner_corner = (base_min_dim * 0.5) * clamp(inner_radius_setting, 0.0, 1.0)
		var inner_corner_margin = base_inner_corner * corner_midpoint_factor
		
		var max_corner_margin = badge_width * 0.8
		var clamped_corner_margin = min(corner_margin, max_corner_margin)
		
		var safe_x = total_inset + clamped_corner_margin
		var safe_y = total_inset + clamped_corner_margin
		var safe_width = badge_width - clamped_corner_margin - inner_corner_margin
		var safe_height = badge_height - clamped_corner_margin - inner_corner_margin
		
		safe_width = max(safe_width, 0.0)
		safe_height = max(safe_height, 0.0)
		
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
		
		platform_icon.offset_left = icon_offset_x
		platform_icon.offset_top = icon_offset_y
		platform_icon.offset_right = icon_offset_x + icon_draw_width
		platform_icon.offset_bottom = icon_offset_y + icon_draw_height

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
		
		# Retry loading the cover (file should now exist)
		_load_cover(high_priority)
	)

func _load_image_from_buffer(buffer: PackedByteArray) -> Image:
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
		return image
	return null

func _set_texture(tex: Texture2D) -> void:
	_current_texture = tex
	if _base_effect:
		_base_effect.set_game_texture(tex)
	_card_state.game_texture = tex
	# Update glow effect texture if it exists
	if _glow_effect:
		_glow_effect.set_game_texture(tex)
	# Update distort effect texture if it exists
	if _distort_effect:
		_distort_effect.set_game_texture(tex)

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
	# Only grab focus if mouse is recently active and controller doesn't have priority
	if UIManager and UIManager.should_card_grab_focus_on_hover():
		if card_input and not card_input.has_focus():
			# Mark this focus change as mouse-initiated so smooth scroll can skip it
			card_input.set_meta("mouse_hover_focus", true)
			card_input.grab_focus()

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

func _on_focus_entered() -> void:
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
	# Ensure pivot is set to center for proper scaling
	visual_container.pivot_offset = visual_container.size / 2
	z_index = 11
	
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
			# Update platform icon position with new inset
			_update_platform_icon_position_from_inset(current_inset)
		, 0.0, 1.0, FOCUS_TWEEN_DURATION)
	
	# Show focus effects with smooth fade
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
			# Update platform icon position with restored inset
			_update_platform_icon_position_from_inset(current_inset)
		, 0.0, 1.0, FOCUS_TWEEN_DURATION)
	
	# Hide focus effects with smooth fade
	_show_focus_effects(false)

## Restores the focus animation after layout changes (e.g., after queue_sort resets transforms)
## Called by VirtualScrollGridContainer to re-apply focus scale without triggering full focus_entered logic
func restore_focus_animation() -> void:
	# Kill existing focus tween
	if _focus_tween:
		_focus_tween.kill()
	
	# Re-apply focus scale animation on visual container (not self)
	# Ensure pivot is set to center for proper scaling
	visual_container.pivot_offset = visual_container.size / 2
	z_index = 11
	
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
			# Update platform icon position with new inset
			_update_platform_icon_position_from_inset(current_inset)
		, 0.0, 1.0, FOCUS_TWEEN_DURATION)
	
	# Show focus effects
	_show_focus_effects(true)

## Shows or hides focus effects with a smooth fade transition
func _show_focus_effects(show: bool) -> void:
	# In preview mode, always show focus effects so designer can see them
	if preview_mode:
		show = true
	
	# Map effect instances to their config check parameters
	var effect_configs: Array[Array] = [
		[_focus_border_effect, "border"],
		[_focus_badge_effect, "badge"],
		[_focus_drop_shadow_effect, "drop_shadow"],
		[_focus_glow_effect, "glow"],
		[_focus_glass_effect, "glass"],
		[_focus_distort_effect, "distort"],
		[_focus_gradient_overlay_effect, "gradient_overlay"]
	]
	
	var target_alpha: float = 1.0 if show else 0.0
	
	for item in effect_configs:
		var effect: CanvasItem = item[0]
		var effect_id: String = item[1]
		
		if not effect:
			continue
		
		# Skip showing effects that aren't configured (unless in preview mode)
		if show and not preview_mode:
			var config = _get_focus_effect_config(effect_id)
			if config.is_empty():
				continue
		
		# Make visible before fading in, or keep visible while fading out
		if show:
			effect.visible = true
			# Set initial alpha to 0
			if effect.material is ShaderMaterial:
				effect.material.set_shader_parameter("effect_alpha", 0.0)
		
		# Only tween if effect should be visible at end (show=true) or is currently visible (show=false)
		if show or effect.visible:
			# Create tween for smooth alpha transition via shader parameter
			var fade_tween = create_tween()
			fade_tween.set_trans(Tween.TRANS_QUAD)
			fade_tween.set_ease(Tween.EASE_OUT)
			
			# Tween the shader parameter instead of modulate
			var start_alpha = 0.0 if show else 1.0
			var end_alpha = target_alpha
			fade_tween.tween_method(func(t: float):
				if effect.material is ShaderMaterial:
					effect.material.set_shader_parameter("effect_alpha", t)
			, start_alpha, end_alpha, FOCUS_EFFECT_FADE_DURATION)
			
			# Hide after fade out completes
			if not show:
				fade_tween.finished.connect(func(): effect.visible = false)

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
	# Skip focus effects - they manage their own alpha via _show_focus_effects()
	if visual_container:
		for child in visual_container.get_children():
			if child is CardEffect and not child.name.begins_with("Focus"):
				_enter_tween_alpha.parallel().tween_property(child, "modulate", Color(1, 1, 1, 1), ENTER_TWEEN_DURATION)

## Sets the card's alpha immediately (for initial state before animations)
func set_card_alpha(alpha: float) -> void:
	if _base_effect:
		_base_effect.set_alpha(alpha)
	
	# Set opacity on card input (covers UI elements like status icons, platform icons)
	if card_input:
		card_input.modulate = Color(1, 1, 1, alpha)
	
	# Set opacity on all CardEffect children inside VisualContainer (border, badge, drop shadow)
	# Skip focus effects - they manage their own alpha via _show_focus_effects()
	if visual_container:
		for child in visual_container.get_children():
			if child is CardEffect and not child.name.begins_with("Focus"):
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
	_loading_game_id = ""
	_image_retry_count = 0
	_download_retry_count = 0
	game = null
	_is_focused = false
	_set_texture(_loading_texture)
	# Reset visual container scale when card is recycled
	if visual_container:
		visual_container.scale = Vector2.ONE
	# Hide title label when card is reset
	if game_title_label:
		game_title_label.visible = false
	# Hide all focus effects when card is recycled
	_hide_all_focus_effects()

func _hide_all_focus_effects():
	"""Hide all focus effects and reset their shader alpha."""
	var focus_effects = [
		_focus_border_effect,
		_focus_badge_effect,
		_focus_drop_shadow_effect,
		_focus_glow_effect,
		_focus_distort_effect,
		_focus_gradient_overlay_effect,
		_focus_glass_effect
	]
	
	for effect in focus_effects:
		if effect:
			effect.visible = false
			if effect.material is ShaderMaterial:
				effect.material.set_shader_parameter("effect_alpha", 0.0)

func refresh_settings():
	#print("[GameCard] === refresh_settings called on ", name, " ===")
	_update_card_state_from_settings()
	#print("[GameCard] Rebuilding effects...")
	_rebuild_effects()
	#print("[GameCard] === refresh_settings complete ===")

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
