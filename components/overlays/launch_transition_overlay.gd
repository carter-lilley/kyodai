class_name LaunchTransitionOverlay
extends Control

## Overlay that plays a launch transition animation when launching a game.
## Animates from card position to fullscreen while applying HSL effects.
## Morphs from card aspect ratio to screen aspect ratio (cover fit).

signal animation_completed

# Static variable to track if any launch transition is animating (accessible globally)
static var is_transition_active: bool = false

var _effect_stack: EffectStack = null
@onready var _margin_container: MarginContainer = $MarginContainer
@onready var _game_title_label: Label = $MarginContainer/GameTitleLabel
var _fallback_bg: ColorRect = null

const PHASE1_DURATION: float = 0.5
const HOLD_DURATION: float = 0.1
const PHASE2_DURATION: float = 0.5

var _is_animating: bool = false
var _tween: Tween = null
var _phase1_completed: bool = false
var _original_card_rect: Rect2
var _game: GameResource

# Optional explicit source (e.g., the cover art in the details sheet).
static var _source_override_texture: Texture2D = null
static var _source_override_rect: Rect2 = Rect2()
static var _source_override_corner_radius: float = 0.06
static var _has_source_override: bool = false

static func set_source(texture: Texture2D, rect: Rect2, corner_radius: float = 0.06) -> void:
	_source_override_texture = texture if is_instance_valid(texture) else null
	_source_override_rect = rect
	_source_override_corner_radius = corner_radius
	_has_source_override = _source_override_texture != null

static func _clear_source_override() -> void:
	_source_override_texture = null
	_source_override_rect = Rect2()
	_source_override_corner_radius = 0.06
	_has_source_override = false

func is_phase1_complete() -> bool:
	return _phase1_completed

func _ready():
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_preset(Control.PRESET_FULL_RECT)
	add_to_group("launch_transition_overlay")

	_effect_stack = EffectStack.new()
	_effect_stack.set_parent_rid(get_canvas_item())
	_effect_stack.set_clip_children(false)

	# Solid-black backing used when no GameCard is focused (e.g. shuffler
	# launches) so the fallback transition still covers the UI. Placed at the
	# bottom of the child stack so the title label (z_index 1001) stays on top.
	_fallback_bg = ColorRect.new()
	_fallback_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fallback_bg.color = Color.BLACK
	_fallback_bg.visible = false
	_fallback_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_fallback_bg)
	move_child(_fallback_bg, 0)

	# Connect to LaunchManager signal
	if LaunchManager:
		LaunchManager.game_launch_initiated.connect(_on_game_launch_initiated)

	# While a dialog (e.g. the pre-launch save conflict prompt) is open, this
	# overlay must neither cover it nor eat its input: it sits in UILayer
	# (canvas layer 1000, above all dialogs) and would otherwise deadlock the
	# launch against an unclickable dialog.
	UIManager.overlay.active_dialog_count_changed.connect(_on_dialog_count_changed)

func _on_dialog_count_changed(count: int) -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE if count > 0 else Control.MOUSE_FILTER_STOP

func _input(_event: InputEvent) -> void:
	if _is_animating and visible and not UIManager.has_active_dialog():
		# The window chrome (custom title bar) renders above this overlay and
		# must stay reachable even mid-animation.
		if OverlayLayers.is_mouse_over_chrome(_event):
			return
		get_viewport().set_input_as_handled()

func _on_game_launch_initiated(launched_game: GameResource, _focus_index: int):
	# Remember which game is launching for the title label.
	_game = launched_game
	# We get the texture from the focused card by default, but a caller can
	# override the source with LaunchTransitionOverlay.set_source().
	_start_transition()

## Replays the transition for a game whose launch was interrupted before the
## process started (e.g. resumed from an Android emulator install, where the
## RESUMED notification force-hid the overlay).
func restart(game: GameResource) -> void:
	_game = game
	_start_transition()

signal phase1_completed

func _start_transition():
	if _is_animating:
		return

	_is_animating = true
	is_transition_active = true  # Set global static flag
	_phase1_completed = false

	# Get the source texture/rect. Use an explicit override if one was set,
	# otherwise fall back to the currently focused GameCard.
	var card_info: Dictionary
	if _has_source_override and _source_override_texture != null:
		card_info = {
			"card": null,
			"texture": _source_override_texture,
			"rect": _source_override_rect,
			"corner_radius": _source_override_corner_radius
		}
		_clear_source_override()
	else:
		card_info = _get_focused_card_and_texture()

	var texture = card_info.texture
	var card_rect = card_info.rect
	var _card = card_info.card
	var start_corner_radius = card_info.corner_radius

	# No focused GameCard (e.g. shuffler launches) -> play a simple fade overlay
	# instead of the card-to-fullscreen hero animation so the launch still
	# proceeds and input remains blocked during the transition.
	if not texture or card_rect.size.x <= 0 or card_rect.size.y <= 0:
		_animate_fallback_transition()
		return

	_original_card_rect = card_rect

	# Setup margin container with 3% padding
	if _margin_container:
		var viewport_size = get_viewport().size
		var margin = int(viewport_size.x * 0.03)  # 3% of width
		_margin_container.add_theme_constant_override("margin_left", margin)
		_margin_container.add_theme_constant_override("margin_right", margin)
		_margin_container.add_theme_constant_override("margin_top", margin)
		_margin_container.add_theme_constant_override("margin_bottom", margin)

	# Setup the game title label
	if _game_title_label and _game:
		var game_name = _game.get_display_name().to_upper()
		_game_title_label.text = game_name

		# Calculate font size to fit text in 30% of screen width
		var viewport_width = get_viewport().size.x
		var max_width = viewport_width * 0.50  # 50% of screen width

		# Get the font from the label
		var label_font = _game_title_label.get_theme_font("font")
		if not label_font:
			label_font = ThemeDB.fallback_font

		# Start large and decrease until it fits
		var font_size = 200  # Start very large
		var text_width = label_font.get_string_size(game_name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

		while text_width > max_width and font_size > 12:
			font_size -= 5
			text_width = label_font.get_string_size(game_name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x

		_game_title_label.add_theme_font_size_override("font_size", font_size)
		_game_title_label.visible = true

	# Setup the EffectStack at the card's position
	if not _setup_effect_stack(texture, card_rect, start_corner_radius):
		_is_animating = false
		is_transition_active = false
		return

	# Show and animate
	visible = true
	z_index = 1000

	# Run the animation sequence
	_animate_transition()

func _get_focused_card_and_texture() -> Dictionary:
	# Find the currently focused GameCard
	var viewport = get_viewport()

	if not viewport:
		push_error("[LaunchTransitionOverlay] Viewport is null")
		return {"card": null, "texture": null, "rect": Rect2(), "corner_radius": 0.0}

	var focused = viewport.gui_get_focus_owner()

	if not focused:
		# Expected when the launch didn't originate from a focused library card.
		return {"card": null, "texture": null, "rect": Rect2(), "corner_radius": 0.0}

	# Traverse up to find GameCard
	var current = focused
	var depth = 0
	while current:
		depth += 1
		if depth > 20:
			push_error("[LaunchTransitionOverlay] Exceeded max search depth")
			return {"card": null, "texture": null, "rect": Rect2(), "corner_radius": 0.0}

		if current is GameCard:
			var card = current as GameCard

			# Get the visual container's global rect
			var card_rect = Rect2()
			if card is Control:
				var global_pos = card.global_position
				var card_size = card.size
				card_rect = Rect2(global_pos, card_size)
			else:
				push_error("[LaunchTransitionOverlay] Card is not a Control")

			# Get the texture directly from the card
			var texture = card.get_current_texture()

			# Get the card's corner radius
			var card_state = card.get_card_state()
			var corner_radius = card_state.corner_radius_ratio if card_state else 0.06

			return {"card": card, "texture": texture, "rect": card_rect, "corner_radius": corner_radius}

		current = current.get_parent()

	# No focused GameCard is expected for non-library launches (e.g. shuffler).
	return {"card": null, "texture": null, "rect": Rect2(), "corner_radius": 0.0}

func _setup_effect_stack(texture: Texture2D, card_rect: Rect2, start_corner_radius: float) -> bool:

	if not _effect_stack:
		push_error("[LaunchTransitionOverlay] _effect_stack is null")
		return false

	# Position and size the EffectStack exactly at the card's location
	# Add 2px overshoot to compensate for shader AA edge
	_effect_stack.set_parent_rid(get_canvas_item())
	var media_container = MediaContainer.new()
	media_container.texture = texture
	media_container.bounds = Rect2(Vector2.ZERO, card_rect.size + Vector2(4, 4))
	media_container.corner_radius_ratio = start_corner_radius

	# Setup minimal effect stack with base + HSL + gradient overlay
	# Disable smart crop for launch transition (scale from center, not bottom)
	# Gradient overlay: vertical black alpha-ramp; faded in via the effect_alpha
	# uniform so the gradient texture is generated once, not per tween frame.
	var initial_gradient = Gradient.new()
	initial_gradient.offsets = [0.0, 1.0]
	initial_gradient.colors = [Color(0, 0, 0, 0), Color(0, 0, 0, 1)]

	var effect_configs = [
		{"effect_id": "base", "settings": {}},
		{"effect_id": "hsl", "settings": {"hue_shift": 0.0, "saturation_scale": 1.0, "lightness_scale": 1.0}},
		{"effect_id": "gradient_overlay", "settings": {"gradient": initial_gradient, "gradient_angle": 180.0}}
	]

	_effect_stack.initialize(media_container, effect_configs)
	_effect_stack.update_draw_rects()

	# Set the game texture on the base effect
	var base_effect = _effect_stack.get_effect("base") as BaseCardEffect
	if base_effect and texture:
		base_effect.set_game_texture(texture)

	# Gradient starts fully faded out (phase 2 fades effect_alpha 0 -> 1)
	var gradient_effect = _effect_stack.get_effect("gradient_overlay") as GradientOverlayEffect
	if gradient_effect:
		gradient_effect._set_shader_param("effect_alpha", 0.0)

	# Position the RS canvas item in global/overlay space. The overlay is a
	# fullscreen control, so card_rect is already in global coordinates.
	var ci = _effect_stack._stack_canvas_item
	if ci.is_valid():
		RenderingServer.canvas_item_set_transform(ci, Transform2D(0.0, card_rect.position - Vector2(2, 2)))
	return true

func _animate_transition():
	if not _effect_stack:
		push_error("[LaunchTransitionOverlay] Cannot animate: _effect_stack is null")
		_is_animating = false
		is_transition_active = false
		return

	# Scene-tree tween so the sequence (including the phase1_completed signal
	# LaunchManager waits on) survives DS-mode reparenting of the UI subtree.
	var tween = get_tree().create_tween()
	if not tween:
		push_error("[LaunchTransitionOverlay] Failed to create tween")
		return
	_tween = tween

	# Calculate fullscreen target (screen aspect ratio) with slight overshoot to hide AA edge
	var viewport_size = Vector2(get_viewport().size)
	var overshoot = 4.0  # Extend 4px beyond viewport to hide AA edge
	var target_size = viewport_size + Vector2(overshoot * 2, overshoot * 2)
	var target_pos = Vector2(-overshoot, -overshoot)  # Center the overshoot

	var media_container = _effect_stack.media_container
	var start_rect_position = _original_card_rect.position - Vector2(2, 2)
	var start_rect_size = _original_card_rect.size + Vector2(4, 4)

	# PHASE 1: Scale and position with QUART + EASE_OUT
	tween.set_trans(Tween.TRANS_QUART)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_parallel(true)

	# Animate position, size, UV vertical offset, and corner radius in ONE tween
	# callback so the whole stack only force-refreshes once per frame.
	var ci = _effect_stack._stack_canvas_item
	var has_texture = media_container and media_container.texture
	var tex_aspect = 0.0
	if has_texture:
		var tex_size = media_container.texture.get_size()
		tex_aspect = tex_size.x / tex_size.y
	var start_corner_radius = media_container.corner_radius_ratio

	tween.tween_method(
		func(t: float):
			var current_pos = start_rect_position.lerp(target_pos, t)
			var current_size = start_rect_size.lerp(target_size, t)
			media_container.bounds = Rect2(Vector2.ZERO, current_size)
			if ci.is_valid():
				RenderingServer.canvas_item_set_transform(ci, Transform2D(0.0, current_pos))
			if has_texture:
				# Calculate vertical offset to keep image centered during aspect ratio change
				var card_aspect = current_size.x / current_size.y
				if card_aspect > tex_aspect:
					# Scaling from portrait to landscape - image will be cropped vertically
					var scale_y = tex_aspect / card_aspect
					media_container.vertical_offset = (1.0 - scale_y) / 2.0
				else:
					media_container.vertical_offset = 0.0
			media_container.corner_radius_ratio = lerpf(start_corner_radius, 0.0, t)
			_effect_stack.update_draw_rects()
			_effect_stack.force_refresh(),
		0.0, 1.0, PHASE1_DURATION
	)

	# After phase 1 completes, emit signal so LaunchManager can proceed with game launch
	tween.chain().tween_callback(func():
		_phase1_completed = true
		phase1_completed.emit()
	)

	# Hold after phase 1
	tween.chain().tween_interval(HOLD_DURATION)

	# PHASE 2: HSL fade + Gradient fade with CIRC + EASE_IN (parallel)
	var hsl_effect = _effect_stack.get_effect("hsl") as HSLEffect
	var gradient_effect = _effect_stack.get_effect("gradient_overlay") as GradientOverlayEffect

	# Chain to hold, then set parallel for phase 2
	tween.chain()
	tween.set_parallel(true)
	tween.set_trans(Tween.TRANS_CIRC)
	tween.set_ease(Tween.EASE_IN)

	if hsl_effect:
		tween.tween_method(
			func(t: float):
				var sat = lerpf(1.0, 0.0, t)
				var light = lerpf(1.0, 0.3, t)
				hsl_effect._settings["saturation_scale"] = sat
				hsl_effect._settings["lightness_scale"] = light
				hsl_effect._update_shader_params(),
			0.0, 1.0, PHASE2_DURATION
		)

	if gradient_effect:
		# Fade via the effect_alpha uniform: for a 0->1 alpha ramp this is
		# mathematically identical to lerping the gradient stop, but avoids
		# regenerating + re-uploading the gradient texture every frame.
		tween.tween_method(
			func(t: float):
				gradient_effect._set_shader_param("effect_alpha", t),
			0.0, 1.0, PHASE2_DURATION
		)

	# Stop parallel after phase 2
	tween.set_parallel(false)

	# Complete
	tween.chain().tween_callback(_on_animation_complete)

## Fallback transition used when no GameCard texture is available (e.g.
## shuffler launches). Fades a black overlay in, emits phase1_completed so the
## launch can proceed, then settles into the same "black overlay until game
## exits" state as the normal card-driven transition.
func _animate_fallback_transition() -> void:
	visible = true
	z_index = 1000
	_fallback_bg.visible = true
	modulate.a = 0.0

	# Setup the game title label
	if _game_title_label and _game:
		var game_name = _game.get_display_name().to_upper()
		_game_title_label.text = game_name
		_game_title_label.visible = true

		# Match the sizing logic from the card-driven path.
		var viewport_width = get_viewport().size.x
		var max_width = viewport_width * 0.50
		var label_font = _game_title_label.get_theme_font("font")
		if not label_font:
			label_font = ThemeDB.fallback_font
		var font_size = 200
		var text_width = label_font.get_string_size(game_name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		while text_width > max_width and font_size > 12:
			font_size -= 5
			text_width = label_font.get_string_size(game_name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		_game_title_label.add_theme_font_size_override("font_size", font_size)

	var tween = get_tree().create_tween()
	if not tween:
		push_error("[LaunchTransitionOverlay] Failed to create fallback tween")
		_is_animating = false
		is_transition_active = false
		return
	_tween = tween

	tween.tween_property(self, "modulate:a", 1.0, PHASE1_DURATION)
	tween.chain().tween_callback(func():
		_phase1_completed = true
		phase1_completed.emit()
	)
	tween.chain().tween_interval(HOLD_DURATION)
	tween.chain().tween_callback(_on_animation_complete)

func _on_animation_complete():
	_tween = null
	# On desktop, connect to background_state_exited signal when process polling detects exit
	# On Android, keep the overlay visible until NOTIFICATION_APPLICATION_RESUMED fires
	if LaunchManager:
		if not LaunchManager.background_state_exited.is_connected(_on_background_state_exited):
			LaunchManager.background_state_exited.connect(_on_background_state_exited)

	# Hide the title label but keep the black overlay
	if _game_title_label:
		_game_title_label.visible = false

	_is_animating = false
	is_transition_active = false
	animation_completed.emit()

func _on_background_state_exited(_exited_game: GameResource, _exit_code: int) -> void:
	# Emulator has exited, hide the overlay
	visible = false
	# Disconnect to avoid memory leaks
	if LaunchManager:
		if LaunchManager.background_state_exited.is_connected(_on_background_state_exited):
			LaunchManager.background_state_exited.disconnect(_on_background_state_exited)

## Aborts the transition and hides the overlay immediately. Required on every
## launch-failure path: when a launch fails after game_launch_initiated fired
## (e.g. game prep failed), no background state is entered and no Android
## RESUMED notification arrives - without this the fullscreen black overlay
## sticks forever, covering the error notification and eating all input.
func abort() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = null
	_is_animating = false
	is_transition_active = false
	_phase1_completed = false
	visible = false
	if _game_title_label:
		_game_title_label.visible = false
	if _fallback_bg:
		_fallback_bg.visible = false
	if LaunchManager and LaunchManager.background_state_exited.is_connected(_on_background_state_exited):
		LaunchManager.background_state_exited.disconnect(_on_background_state_exited)

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		if visible and SystemManager.platform.is_android():
			visible = false
			if LaunchManager and LaunchManager.background_state_exited.is_connected(_on_background_state_exited):
				LaunchManager.background_state_exited.disconnect(_on_background_state_exited)

func _exit_tree() -> void:
	if is_queued_for_deletion():
		if LaunchManager and LaunchManager.background_state_exited.is_connected(_on_background_state_exited):
			LaunchManager.background_state_exited.disconnect(_on_background_state_exited)
		if _effect_stack:
			_effect_stack.free_rids()
			_effect_stack = null
		return
	# Reparent (e.g. DS toggle), not deletion: settle any in-flight animation
	# so is_transition_active can't stick (cards gate input on it), and keep
	# the effect stack + game-exit listener alive for the running game.
	if _is_animating:
		_on_animation_complete()

func _enter_tree() -> void:
	# Re-establish the game-exit listener after reparenting while the overlay
	# is still covering during gameplay (it hides when the game exits).
	if visible and LaunchManager and not LaunchManager.background_state_exited.is_connected(_on_background_state_exited):
		LaunchManager.background_state_exited.connect(_on_background_state_exited)

func is_animating() -> bool:
	return _is_animating
