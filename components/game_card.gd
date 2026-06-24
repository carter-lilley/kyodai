@tool
class_name GameCard
extends M3Card

const FSM := preload("res://managers/filesystem_manager.gd")

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
var _current_texture: Texture2D = null

# Media effect stack rendered inside M3Card's media panel
var _media_stack: EffectStack = null
var _focus_stack: EffectStack = null
var _focus_effect_tweens: Array[Tween] = []

# Focus stack needs its own bounds (full card vs media panel) independent of
# the media stack, which lives in media-panel-local space.
var _focus_media_container: MediaContainer = null

func _remove_focus_tween(tween: Tween) -> void:
	_focus_effect_tweens.erase(tween)

func _kill_focus_tweens() -> void:
	for tween in _focus_effect_tweens:
		if tween and is_instance_valid(tween):
			tween.kill()
	_focus_effect_tweens.clear()

	if _media_stack:
		for effect in _media_stack.get_effects():
			if effect is EffectBase:
				effect._is_tweening = false

# Cover/media loading is delegated to CardMediaLoader so GameCard stays focused
# on card behavior (focus, input, badges) rather than download/cache logic.
var _media_loader: CardMediaLoader = null

# Status badge overlay (direct child of GameCard, positioned over media panel)
var _status_badge_canvas_item: RID = RID()
var _status_badge_style: StyleBoxFlat = null
var _badge_update_pending: bool = false
const STATUS_BADGE_SIZE_RATIO: float = 0.04
const STATUS_BADGE_MARGIN_RATIO: float = 0.05

# Platform badge icon assets
const PLATFORM_ICON_DIR := "res://assets/icons/platforms"
const PLATFORM_ICON_MAP := {
	"psx": "ps",
	"ps4": "ps4--1",
	"genesis": "genesis-slash-megadrive",
	"tg16": "turbografx16--1",
	"turbografx-cd": "turbografx16--1",
}
static var _platform_icon_cache: Dictionary = {}
static var _platform_icon_missing_warnings: Dictionary = {}

static func clear_platform_icon_cache() -> void:
	_platform_icon_cache.clear()
	_platform_icon_missing_warnings.clear()

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

func _ready():
	super._ready()

	# Focus effects need a separate container so their bounds (full card or
	# media panel in card space) don't overwrite the media stack's bounds.
	_focus_media_container = MediaContainer.new()
	_sync_focus_container_properties()

	_sync_focus_visuals()

	_media_loader = CardMediaLoader.new(self)
	_media_loader.texture_loaded.connect(_on_media_texture_loaded)

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

	_setup_status_badge()

func _exit_tree():
	# Cancel any in-flight image operations to prevent callbacks from keeping this card alive
	if _media_loader:
		_media_loader.cancel()

	# Kill any focus effect tweens
	_kill_focus_tweens()

	if _media_stack:
		_media_stack.free_rids()
		_media_stack = null
	if _focus_stack:
		_focus_stack.free_rids()
		_focus_stack = null

	_free_status_badge_canvas_item()

func _free_status_badge_canvas_item() -> void:
	if _status_badge_canvas_item.is_valid():
		RenderingServer.free_rid(_status_badge_canvas_item)
		_status_badge_canvas_item = RID()
	_status_badge_style = null

func _setup_status_badge():
	_free_status_badge_canvas_item()
	_status_badge_style = StyleBoxFlat.new()
	_status_badge_style.anti_aliasing = true
	_status_badge_style.anti_aliasing_size = 1.0
	_status_badge_canvas_item = RenderingServer.canvas_item_create()
	RenderingServer.canvas_item_set_parent(_status_badge_canvas_item, get_canvas_item())
	RenderingServer.canvas_item_set_draw_index(_status_badge_canvas_item, 50)
	RenderingServer.canvas_item_set_visible(_status_badge_canvas_item, false)
	_update_status_badge_style()

func get_card_state() -> MediaContainer:
	return _media_container

func get_focus_shape_params() -> Dictionary:
	return {
		"shape_size": _media_container.size,
		"corner_radius_ratio": _media_container.corner_radius_ratio,
		"corner_radius_pixels": _media_container.get_corner_radius_pixels()
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

	if _status_badge_canvas_item.is_valid():
		RenderingServer.canvas_item_set_visible(_status_badge_canvas_item, false)

	disabled = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# Ensure focus effects match preview_show_focus after all setup
	_show_focus_effects(preview_show_focus)

func _build_media_stack(force_full_rebuild: bool = true):
	print("[GameCard] _build_media_stack force_full_rebuild=", force_full_rebuild, " _media_stack=", _media_stack != null, " _current_texture=", _current_texture != null)
	var effect_settings := []
	if UIManager and UIManager.card_settings_state:
		effect_settings = UIManager.card_settings_state.get_base_effects()
	elif SettingsManager:
		# Fallback if UIManager state is not yet available
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			effect_settings = config_setting.value.get("effects", [])

	if _media_stack:
		# Hot-reload: update configs in-place instead of rebuilding
		_media_stack.update_effect_configs(effect_settings, force_full_rebuild)
		# The media panel may have been recreated by a layout change (e.g. card
		# orientation/alignment), so always re-parent the existing stack canvas
		# item to the current panel to avoid rendering into a freed RID.
		if _media_panel:
			_media_stack.set_parent_rid(_media_panel.get_canvas_item())
			_media_panel.visible = true
		if _current_texture:
			_media_stack.set_game_texture(_current_texture)
		_media_stack.update_draw_rects()
	else:
		_media_stack = EffectStack.new()
		_media_stack.initialize(_media_container, effect_settings, "base_card")
		if _current_texture:
			_media_stack.set_game_texture(_current_texture)
		if _media_panel:
			_media_stack.set_parent_rid(_media_panel.get_canvas_item())
		# The base card shader handles rounded corners; don't clip on the
		# node-less stack (it has no geometry of its own to clip against).
		_media_stack.set_clip_children(false)
		_media_stack.update_draw_rects()
		if _media_panel:
			_media_panel.visible = true

	# Focus stack is built lazily when this card becomes focused (or in preview mode).
	if (_focus_stack) or preview_mode or _is_focused:
		_build_focus_stack(force_full_rebuild)

func _build_focus_stack(force_full_rebuild: bool = true) -> void:
	_sync_focus_container_properties()

	var focus_effect_settings := []
	if UIManager and UIManager.card_settings_state:
		focus_effect_settings = UIManager.card_settings_state.get_focus_effects()
	elif SettingsManager:
		# Fallback if UIManager state is not yet available
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			focus_effect_settings = config_setting.value.get("focus_effects", [])

	# If no focus effects configured, clear and hide existing stack
	if focus_effect_settings.is_empty():
		if _focus_stack:
			_focus_stack.update_effect_configs([], force_full_rebuild)
			_focus_stack.set_visible(false)
		return

	if _focus_stack:
		# Hot-reload: update configs in-place
		_focus_stack.set_visible(false)
		_focus_stack.update_effect_configs(focus_effect_settings, force_full_rebuild)

		# Re-apply focus state setup after config update
		var focus_base_node = _focus_stack.get_effect("base")
		if focus_base_node:
			focus_base_node.set_visible(false)
			focus_base_node.set_alpha(0.0)

		# In preview mode, respect preview_show_focus for initial alpha
		var target_focus_alpha = 1.0 if (preview_mode and preview_show_focus) else 0.0
		for effect in _focus_stack.get_effects():
			if effect is EffectBase and effect._material is ShaderMaterial:
				effect._material.set_shader_parameter("effect_alpha", target_focus_alpha)

		if preview_mode:
			_focus_stack.set_visible(preview_show_focus)

		if _current_texture:
			_focus_stack.set_game_texture(_current_texture)
		_link_overlapping_effects()
		return

	_focus_stack = EffectStack.new()
	_focus_stack.set_parent_rid(get_canvas_item())
	_focus_stack.set_clip_children(false)
	_focus_stack.set_visible(false)

	_sync_focus_container_properties()
	_focus_stack.initialize(_focus_media_container, focus_effect_settings, "focus_card")
	_update_effect_transforms()
	_update_focus_stack_bounds()
	if _current_texture:
		_focus_stack.set_game_texture(_current_texture)

	# Hide base effect in focus stack — focus effects are overlays only
	var focus_base = _focus_stack.get_effect("base")
	if focus_base:
		focus_base.set_visible(false)
		focus_base.set_alpha(0.0)

	# Initialize focus effects with effect_alpha based on preview_show_focus
	var focus_alpha = 1.0 if (preview_mode and preview_show_focus) else 0.0
	for effect in _focus_stack.get_effects():
		if effect is EffectBase and effect._material is ShaderMaterial:
			effect._material.set_shader_parameter("effect_alpha", focus_alpha)

	if preview_mode:
		_focus_stack.set_visible(preview_show_focus)

	_link_overlapping_effects()

func _link_overlapping_effects() -> void:
	if not _media_stack or not _focus_stack:
		return

	var base_effect_ids: Array[String] = []
	for effect in _media_stack.get_effects():
		if effect is EffectBase:
			base_effect_ids.append(effect.effect_id)

	for effect in _focus_stack.get_effects():
		if not (effect is EffectBase):
			continue
		var focus_effect = effect as EffectBase
		if focus_effect.effect_id in base_effect_ids:
			var base_effect = _media_stack.get_effect(focus_effect.effect_id)
			if base_effect:
				focus_effect.set_base_effect(base_effect)
				# In preview mode, respect preview_show_focus instead of _is_focused
				var show_focus = preview_show_focus if preview_mode else _is_focused
				if not show_focus and base_effect._settings.size() > 0:
					focus_effect.tween_settings(base_effect._settings, base_effect._settings, 1.0)

var preview_show_focus: bool = false

func set_preview_focus(show: bool) -> void:
	preview_show_focus = show
	_show_focus_effects(show)

func _show_focus_effects(p_show: bool) -> void:
	_kill_focus_tweens()

	if preview_mode:
		p_show = preview_show_focus

	if not _focus_stack or not _media_stack:
		return

	var overlapping_effects: Array[EffectBase] = []
	var non_overlapping_effects: Array[EffectBase] = []

	for effect in _focus_stack.get_effects():
		if not (effect is EffectBase):
			continue
		var focus_effect = effect as EffectBase
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

		var base_effect_ref = weakref(base_effect)
		if p_show:
			var settings_tween = create_tween()
			_focus_effect_tweens.append(settings_tween)
			settings_tween.finished.connect(_remove_focus_tween.bind(settings_tween))
			settings_tween.set_trans(Tween.TRANS_QUAD)
			settings_tween.set_ease(Tween.EASE_OUT)
			var tween_callable = func(t: float):
				var eff = base_effect_ref.get_ref()
				if eff:
					eff.tween_settings(base_copy, focus_copy, t)
			settings_tween.tween_method(tween_callable, 0.0, 1.0, FOCUS_EFFECT_FADE_DURATION)
		else:
			var settings_tween = create_tween()
			_focus_effect_tweens.append(settings_tween)
			settings_tween.finished.connect(_remove_focus_tween.bind(settings_tween))
			settings_tween.set_trans(Tween.TRANS_QUAD)
			settings_tween.set_ease(Tween.EASE_OUT)
			var tween_callable = func(t: float):
				var eff = base_effect_ref.get_ref()
				if eff:
					eff.tween_settings(focus_copy, base_copy, t)
			settings_tween.tween_method(tween_callable, 0.0, 1.0, FOCUS_EFFECT_FADE_DURATION)

	# Non-overlapping effects: fade in/out via alpha overlay
	if non_overlapping_effects.size() > 0:
		if p_show:
			_focus_stack.set_visible(true)

		for focus_effect in non_overlapping_effects:
			if focus_effect._material is ShaderMaterial:
				var start_alpha = 0.0 if p_show else 1.0
				var target_alpha = 1.0 if p_show else 0.0
				focus_effect._material.set_shader_parameter("effect_alpha", 0.0)

				var fade_tween = create_tween()
				_focus_effect_tweens.append(fade_tween)
				fade_tween.finished.connect(_remove_focus_tween.bind(fade_tween))
				fade_tween.set_trans(Tween.TRANS_QUAD)
				fade_tween.set_ease(Tween.EASE_OUT)
				fade_tween.tween_method(
					func(t: float, eff: EffectBase = focus_effect):
						if eff and eff._material is ShaderMaterial:
							eff._material.set_shader_parameter("effect_alpha", t),
					start_alpha, target_alpha, FOCUS_EFFECT_FADE_DURATION
				)

		if not p_show:
			var hide_tween = create_tween()
			_focus_effect_tweens.append(hide_tween)
			hide_tween.finished.connect(_remove_focus_tween.bind(hide_tween))
			hide_tween.set_trans(Tween.TRANS_QUAD)
			hide_tween.set_ease(Tween.EASE_OUT)
			hide_tween.tween_interval(FOCUS_EFFECT_FADE_DURATION)
			hide_tween.finished.connect(func():
				if _focus_stack:
					_focus_stack.set_visible(false)
			)

var _display_mode: int = 0

func _update_card_state_from_settings():
	var state = UIManager.card_settings_state if UIManager else null
	if state:
		var config = state.card_effect_config
		_media_container.effect_settings = state.get_base_effects()
		_media_container.focus_effect_settings = state.get_focus_effects()

		# Migrate old keys to unified card_rounding
		var config_dict = config.duplicate(true)
		if not config_dict.has("card_rounding"):
			if config_dict.has("art_rounding"):
				config_dict["card_rounding"] = config_dict["art_rounding"]
			elif config_dict.has("corner_radius"):
				config_dict["card_rounding"] = config_dict["corner_radius"]

		var corner_value = config_dict.get("card_rounding", 0.12)
		if corner_value is float and corner_value > 1.0:
			# Backward compat: old configs stored absolute pixels against the 3:4 vertical base width
			const LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP: float = 202.0
			_media_container.corner_radius_ratio = corner_value / M3Units.dp(LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP)
		else:
			_media_container.corner_radius_ratio = float(corner_value)

		# Apply the same rounding to the M3Card background clip
		card_rounding_ratio = _media_container.corner_radius_ratio

		# Apply insets immediately so the base card shader pushes the image inward
		# even if the effect-stack rebuild is delayed or skipped.
		_apply_effect_insets_to_media_container(_media_container.effect_settings)

		_display_mode = state.display_mode
	elif SettingsManager:
		# Fallback if UIManager state is not yet available
		var config_setting = SettingsManager.get_setting("card_effect_config")
		if config_setting and config_setting.value is Dictionary:
			_media_container.effect_settings = config_setting.value.get("effects", [])
			_media_container.focus_effect_settings = config_setting.value.get("focus_effects", [])
			var config_dict = config_setting.value.duplicate(true)
			if not config_dict.has("card_rounding"):
				if config_dict.has("art_rounding"):
					config_dict["card_rounding"] = config_dict["art_rounding"]
				elif config_dict.has("corner_radius"):
					config_dict["card_rounding"] = config_dict["corner_radius"]
			var corner_value = config_dict.get("card_rounding", 0.12)
			if corner_value > 1.0:
				const LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP: float = 202.0
				_media_container.corner_radius_ratio = corner_value / M3Units.dp(LEGACY_CORNER_RADIUS_REFERENCE_WIDTH_DP)
			else:
				_media_container.corner_radius_ratio = corner_value
			card_rounding_ratio = _media_container.corner_radius_ratio
			_apply_effect_insets_to_media_container(_media_container.effect_settings)

		var display_setting = SettingsManager.get_setting("library_card_display_mode")
		if display_setting and display_setting.value is int:
			_display_mode = display_setting.value

	_apply_display_mode()
	_sync_focus_container_properties()

func _apply_effect_insets_to_media_container(effects: Array) -> void:
	"""Scan base effects and set media-container insets from their settings."""
	var border_inset: float = 0.0
	var glass_inset: float = 0.0
	for effect in effects:
		if not effect is Dictionary:
			continue
		var effect_id = effect.get("effect_id", "")
		var settings = effect.get("settings", {})
		match effect_id:
			"border":
				border_inset = settings.get("border_size", 0.0)
			"glass":
				glass_inset = settings.get("additional_inset_ratio", 0.0)
	_media_container.border_inset_ratio = border_inset
	_media_container.glass_inset_ratio = glass_inset

func _apply_display_mode() -> void:
	# Map display mode to background/text visibility and edge AA
	match _display_mode:
		0: # Standard
			show_background = true
			show_text_margin = true
			_media_container.edge_aa_enabled = false
		1: # Transparent
			show_background = false
			show_text_margin = true
			_media_container.edge_aa_enabled = true
		2: # Media Only
			show_background = false
			show_text_margin = false
			_media_container.edge_aa_enabled = true

	# Push the new AA flag to the shader immediately so the edge doesn't stay
	# jagged when switching into transparent/media-only mode.
	if _media_stack:
		_media_stack.force_refresh()

	# Update text immediately so shadow state reflects the new display mode
	_update_text()

func set_focus_scale(value: float) -> void:
	focus_scale = maxf(value, 1.0)
	_sync_focus_visuals()

func refresh_settings() -> void:
	_update_card_state_from_settings()
	_build_media_stack()
	_update_platform_badge()
	_update_display()
	# Ensure focus effects match current preview state after rebuild
	if preview_mode:
		_show_focus_effects(preview_show_focus)

func refresh_effects(force_full_rebuild: bool = false) -> void:
	print("[GameCard] refresh_effects force_full_rebuild=", force_full_rebuild, " game=", game.title if game else null, " _media_stack=", _media_stack != null, " _focus_stack=", _focus_stack != null)
	"""Rebuild or hot-reload effects and re-apply card state (display mode, rounding, etc.)."""
	_update_card_state_from_settings()
	_build_media_stack(force_full_rebuild)
	_update_platform_badge()
	_update_display()
	if preview_mode:
		_show_focus_effects(preview_show_focus)

func reset(for_pooling: bool = false) -> void:
	"""Reset the card for reuse.
	
	when for_pooling is true, we keep the effect stacks and current texture
	allocated so recycled cards don't have to rebuild them from scratch. This
	avoids the empty-card flash when the grid recycles during zoom/resize."""
	game = null
	_is_focused = false
	set_meta("_cached_show_delete", null)
	if _focus_tween:
		_focus_tween.kill()
		_focus_tween = null
	_kill_focus_tweens()
	_sync_focus_visuals()
	if _media_loader:
		_media_loader.cancel()
	if _status_badge_canvas_item.is_valid():
		RenderingServer.canvas_item_set_visible(_status_badge_canvas_item, false)
	headline = ""
	supporting_text = ""

	if for_pooling:
		# Hide and clear textures but keep stacks allocated for fast reuse.
		# Retain _current_texture so the same game can be restored instantly.
		if _media_stack:
			_media_stack.set_game_texture(null)
		if _focus_stack:
			_focus_stack.set_game_texture(null)
			_focus_stack.set_visible(false)
	else:
		_current_texture = null
		if _media_stack:
			_media_stack.set_game_texture(null)
			_media_stack.free_rids()
			_media_stack = null
		if _focus_stack:
			_focus_stack.set_game_texture(null)
			_focus_stack.free_rids()
			_focus_stack = null

func set_placeholder(_enabled: bool) -> void:
	# No-op for M3Card-based GameCard
	pass

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
	# If the texture is already cached and the game hasn't changed, reuse it
	# synchronously to avoid the empty-card flash during recycling.
	if _current_texture and _current_texture != _loading_texture:
		_set_texture(_current_texture)
	else:
		_load_cover(high_priority)
	headline = game.title
	supporting_text = game.platform if game.platform else ""

func _deferred_update_badges():
	_badge_update_pending = false
	_update_status_badge_layout()
	_update_platform_badge()

func _update_status_badge_layout():
	if not _status_badge_canvas_item.is_valid():
		return

	var panel_width: float = size.x
	if _media_container.size.x > 0:
		panel_width = _media_container.size.x

	var badge_size = max(M3Units.dp(6.0), panel_width * STATUS_BADGE_SIZE_RATIO)
	var margin = max(M3Units.dp(4.0), panel_width * STATUS_BADGE_MARGIN_RATIO)

	var pos = Vector2(size.x - badge_size - margin, size.y - badge_size - margin)
	var rect = Rect2(pos, Vector2(badge_size, badge_size))

	RenderingServer.canvas_item_clear(_status_badge_canvas_item)
	_update_status_badge_style()
	_status_badge_style.draw(_status_badge_canvas_item, rect)

func _update_status_badge_style():
	if not _status_badge_style:
		return
	var panel_width = size.x if size.x > 0 else _media_container.size.x
	if _media_container.size.x > 0:
		panel_width = _media_container.size.x
	var badge_size = max(M3Units.dp(6.0), panel_width * STATUS_BADGE_SIZE_RATIO)
	var circle_radius = int(badge_size / 2.0)

	if game and game.is_active_variant_downloaded():
		_status_badge_style.bg_color = Color(0.49, 0.714, 0.0, 1.0)
	else:
		_status_badge_style.bg_color = Color(0.0, 0.624, 0.922, 1.0)

	_status_badge_style.set_corner_radius_all(circle_radius)

func _update_status_icon():
	if not _status_badge_canvas_item.is_valid():
		return
	if not game:
		RenderingServer.canvas_item_set_visible(_status_badge_canvas_item, false)
		return
	RenderingServer.canvas_item_set_visible(_status_badge_canvas_item, true)
	_update_status_badge_layout()

static func _resolve_platform_icon_name(slug: String) -> String:
	return PLATFORM_ICON_MAP.get(slug, slug)


static func _get_platform_icon_texture(slug: String, is_wordmark: bool) -> Texture2D:
	if slug.is_empty():
		return null

	var filename := _resolve_platform_icon_name(slug)
	var prefix := "wordmark_" if is_wordmark else "icon_"
	var path := PLATFORM_ICON_DIR + "/" + prefix + filename + ".png"

	if _platform_icon_cache.has(path):
		return _platform_icon_cache[path]

	if not ResourceLoader.exists(path):
		return null

	var tex := load(path) as Texture2D
	if tex:
		_platform_icon_cache[path] = tex
	return tex


static func _apply_badge_settings(badge: BadgeEffect, badge_type: int, icon_texture: Texture2D, badge_size_setting: float, inner_radius_setting: float, media_container: MediaContainer) -> void:
	if not badge:
		return

	var card_width = media_container.size.x
	var corner_radius_pixels = media_container.get_corner_radius_pixels()
	var total_inset = media_container.get_total_inset_pixels()
	var effective_corner_radius = max(0, corner_radius_pixels - total_inset)

	var texture_aspect = 1.0
	if icon_texture:
		var tex_size = icon_texture.get_size()
		texture_aspect = tex_size.x / tex_size.y if tex_size.y > 0 else 1.0
		if badge_type != 1:
			texture_aspect = 1.0

	const BADGE_SIZE_RATIO: float = 0.16

	if badge_type == 1:
		var base_badge_size = BADGE_SIZE_RATIO * card_width
		var top_bar_max_size = card_width * 0.25
		var bar_height = min(base_badge_size * badge_size_setting, top_bar_max_size)
		var top_bar_safe_x = total_inset + effective_corner_radius
		var top_bar_safe_width = (card_width - total_inset * 2) - (effective_corner_radius * 2)
		var top_bar_safe_y = total_inset
		var top_bar_safe_height = bar_height

		badge.set_badge_dimensions(Vector2(card_width, bar_height))
		badge.set_border_inset_pixels(total_inset)
		badge.set_safe_zone_top_bar(top_bar_safe_x, top_bar_safe_y, top_bar_safe_width, top_bar_safe_height, false)
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

		badge.set_badge_dimensions(Vector2(badge_width, badge_height))
		badge.set_border_inset_pixels(total_inset)
		badge.set_safe_zone(safe_x, safe_y, safe_width, safe_height, false)

	badge.set_icon_texture(icon_texture)


func _update_platform_badge():
	if not _media_stack:
		return

	var normal_badge = _media_stack.get_effect("badge") as BadgeEffect
	if not normal_badge:
		return

	if not game:
		normal_badge.set_icon_texture(null)
		var focus_badge_clear = _focus_stack.get_effect("badge") as BadgeEffect if _focus_stack else null
		if focus_badge_clear:
			focus_badge_clear.set_icon_texture(null)
		return

	var platform_slug = game.platform_slug
	var icon_texture: Texture2D = null

	var badge_config := {}
	for effect_data in _media_container.effect_settings:
		if effect_data is Dictionary and effect_data.get("effect_id") == "badge":
			badge_config = effect_data
			break

	var settings = badge_config.get("settings", {})
	var badge_type = settings.get("badge_type", 0)
	var badge_size_setting = settings.get("badge_size", 1.0)
	var inner_radius_setting = settings.get("badge_inner_radius", 0.0)

	if platform_slug:
		icon_texture = _get_platform_icon_texture(platform_slug, badge_type == 1)

		if not icon_texture and not _platform_icon_missing_warnings.has(platform_slug):
			_platform_icon_missing_warnings[platform_slug] = true
			push_warning("GameCard: No platform icon found for slug '%s' (looked in %s)" % [platform_slug, PLATFORM_ICON_DIR])

	_apply_badge_settings(normal_badge, badge_type, icon_texture, badge_size_setting, inner_radius_setting, _media_container)

	var focus_badge = _focus_stack.get_effect("badge") as BadgeEffect if _focus_stack else null
	if focus_badge:
		_apply_badge_settings(focus_badge, badge_type, icon_texture, badge_size_setting, inner_radius_setting, _media_container)

func _load_cover(high_priority: bool = false) -> void:
	if _media_loader:
		_media_loader.load_cover(game, high_priority)
	else:
		_set_texture(_loading_texture)

func _on_media_texture_loaded(texture: Texture2D) -> void:
	_set_texture(texture)

func _set_texture(tex: Texture2D) -> void:
	if tex == _current_texture:
		return
	_current_texture = tex
	if _media_panel:
		_media_panel.visible = true
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
			var file_path = FSM.join_paths(root_folder.value, game.platform_slug, active_file_name)
			if not FSM.file_exists(file_path):
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
		if parent is HomeView or parent is LibraryView:
			set_meta("_cached_show_delete", true)
			return true
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
	# Early-out for non-Android touch events — avoids _can_accept_focus() cost
	# for the vast majority of input events on desktop/console.
	var is_touch_event = (event is InputEventScreenTouch or event is InputEventScreenDrag)
	if is_touch_event and not PlatformManager.is_android():
		return

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
		else:
			if _touch_is_holding:
				# Check if this release qualifies as a long press
				if _is_long_press_elapsed():
					_trigger_long_press()
				_touch_is_holding = false

	if PlatformManager.is_android() and event is InputEventScreenDrag:
		if _touch_is_holding:
			var current_pos = event.position
			var distance = _touch_start_pos.distance_to(current_pos)
			if distance > M3Units.dp(LONG_PRESS_TOLERANCE_DP):
				_touch_is_holding = false
			else:
				# Check if we've held long enough during drag
				if _is_long_press_elapsed():
					_trigger_long_press()

func _is_long_press_elapsed() -> bool:
	if not _touch_is_holding:
		return false
	var elapsed = (Time.get_ticks_msec() / 1000.0) - _touch_start_time
	return elapsed >= LONG_PRESS_DURATION

func _trigger_long_press() -> void:
	if not _touch_is_holding or not game or not UIManager:
		return
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

func _apply_content_scale() -> void:
	super._apply_content_scale()
	_update_effect_transforms()

func _update_effect_transforms() -> void:
	# Sync the RS focus stack transform to match the Control content scale.
	# The media stack is clipped inside _media_panel, which inherits scaling from RootContainer.
	if not _focus_stack:
		return
	var ci = _focus_stack._stack_canvas_item
	if not ci.is_valid():
		return

	var pivot = size / 2.0
	# Scale around the card centre. Godot applies Transform2D operations
	# right-to-left, so translate(-pivot) first, then scale, then
	# translate(+pivot) to put the origin back.
	var scale_transform := Transform2D()
	scale_transform = scale_transform.translated(-pivot)
	scale_transform = scale_transform.scaled(content_scale)
	scale_transform = scale_transform.translated(pivot)

	var t := scale_transform
	# If the focus stack tracks the media panel (transparent/media-only),
	# prepend a translation to the panel's top-left so it lands in the same
	# place as the media stack after scaling.
	if _focus_media_container:
		t = scale_transform * Transform2D().translated(_focus_media_container.bounds.position)
	RenderingServer.canvas_item_set_transform(ci, t)

func _sync_focus_container_properties() -> void:
	if not _focus_media_container or not _media_container:
		return
	_focus_media_container.corner_radius_ratio = _media_container.corner_radius_ratio
	_focus_media_container.border_inset_ratio = _media_container.border_inset_ratio
	_focus_media_container.glass_inset_ratio = _media_container.glass_inset_ratio
	_focus_media_container.edge_aa_enabled = _media_container.edge_aa_enabled
	_focus_media_container.vertical_offset = _media_container.vertical_offset
	_focus_media_container.effect_settings = _media_container.effect_settings
	_focus_media_container.focus_effect_settings = _media_container.focus_effect_settings

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

	# Build the focus stack lazily the first time this card is focused.
	if not _focus_stack:
		_build_focus_stack(true)
		_update_platform_badge()

	if AudioManager:
		AudioManager.play_sfx_modulate("click_02", 0.98, 1.02)

	if PlatformManager.is_android():
		var plugin = Engine.get_singleton("PackageChecker")
		if plugin:
			plugin.call("vibrateDevice", 50)
	else:
		Input.start_joy_vibration(0, 0.08, 0.03, 0.08)

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
	_kill_focus_tweens()
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

func _update_focus_stack_bounds() -> void:
	if not _focus_stack or not _media_panel:
		return
	# Use the actual media panel size when available (authoritative after sort).
	var target_w := _focus_target_w
	var target_h := _focus_target_h
	if _media_panel.size.x > 0.0 and _media_panel.size.y > 0.0:
		target_w = _media_panel.size.x
		target_h = _media_panel.size.y
	if target_w <= 0.0:
		target_w = size.x
	if target_h <= 0.0:
		target_h = size.y

	# Update the media container bounds used by the focus stack so overlays align.
	# The focus stack's own canvas item is parented to the card's canvas item, so
	# we express the media region in card-local coordinates.
	var media_x := 0.0
	var media_y := 0.0
	if _media_panel:
		media_x = _media_panel.position.x
		media_y = _media_panel.position.y

	var new_bounds: Rect2
	if not show_background:
		# Transparent / Media Only: shrink focus stack to match media panel
		new_bounds = Rect2(media_x, media_y, target_w, target_h)
	else:
		new_bounds = Rect2(0.0, 0.0, size.x, size.y)

	var bounds_changed := not _focus_media_container.bounds.is_equal_approx(new_bounds)
	_focus_media_container.bounds = new_bounds

	_focus_stack.update_draw_rects()
	if bounds_changed:
		_focus_stack.force_refresh()
	_update_effect_transforms()

func _update_media_panel_size(force: bool = false) -> void:
	super._update_media_panel_size(force)
	if _media_container and _media_panel:
		# The media stack is parented to _media_panel, so its bounds must be
		# expressed in media-panel-local coordinates rather than card coords.
		_media_container.bounds = Rect2(Vector2.ZERO, _media_panel.size)
	if _media_stack:
		_media_stack.update_draw_rects()
		_media_stack.force_refresh()
	if _focus_stack:
		_update_focus_stack_bounds()

func _update_focus_ring_bounds() -> void:
	super._update_focus_ring_bounds()
	_update_focus_stack_bounds()

func _notification(what: int):
	super._notification(what)
	if what == NOTIFICATION_RESIZED:
		pivot_offset = size / 2.0
		if not _badge_update_pending:
			_badge_update_pending = true
			call_deferred("_deferred_update_badges")
		call_deferred("_deferred_refresh_media_stack")
	if what == NOTIFICATION_PARENTED:
		# Invalidate cached parent-chain lookup so _get_show_delete() recomputes
		remove_meta("_cached_show_delete")

func _deferred_refresh_media_stack() -> void:
	if _media_stack:
		_media_stack.update_draw_rects()
		_media_stack.force_refresh()
