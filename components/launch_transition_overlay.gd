class_name LaunchTransitionOverlay
extends Control

## Overlay that plays a launch transition animation when launching a game.
## Animates from card position to fullscreen while applying HSL effects.
## Morphs from card aspect ratio to screen aspect ratio (cover fit).

signal animation_completed

# Static variable to track if any launch transition is animating (accessible globally)
static var is_transition_active: bool = false

@onready var _effect_stack: EffectStack = $EffectStack
@onready var _margin_container: MarginContainer = $MarginContainer
@onready var _game_title_label: Label = $MarginContainer/GameTitleLabel

const PHASE1_DURATION: float = 0.5
const HOLD_DURATION: float = 0.1
const PHASE2_DURATION: float = 0.5

var _is_animating: bool = false
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
	
	# Connect to LaunchManager signal
	if LaunchManager:
		LaunchManager.game_launch_initiated.connect(_on_game_launch_initiated)

func _input(event: InputEvent) -> void:
	if _is_animating and visible:
		get_viewport().set_input_as_handled()

func _on_game_launch_initiated(launched_game: GameResource, _focus_index: int):
	# Remember which game is launching for the title label.
	_game = launched_game
	# We get the texture from the focused card by default, but a caller can
	# override the source with LaunchTransitionOverlay.set_source().
	_start_transition()

signal phase1_completed

func _start_transition():
	if _is_animating:
		return
	
	_is_animating = true
	is_transition_active = true	 # Set global static flag
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
	var card = card_info.card
	var start_corner_radius = card_info.corner_radius
	
	if not texture:
		push_error("[LaunchTransitionOverlay] Failed to get texture from card, aborting")
		_is_animating = false
		is_transition_active = false  # Reset global flag
		return
	
	if card_rect.size.x <= 0 or card_rect.size.y <= 0:
		push_error("[LaunchTransitionOverlay] Invalid card rect (size <= 0), aborting")
		_is_animating = false
		is_transition_active = false  # Reset global flag
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
		var font_size = 200	 # Start very large
		var text_width = label_font.get_string_size(game_name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		
		while text_width > max_width and font_size > 12:
			font_size -= 5
			text_width = label_font.get_string_size(game_name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		
		_game_title_label.add_theme_font_size_override("font_size", font_size)
		_game_title_label.visible = true
	
	# Setup the EffectStack at the card's position
	_setup_effect_stack(texture, card_rect, start_corner_radius)
	
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
		push_error("[LaunchTransitionOverlay] No focused control")
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
	
	push_error("[LaunchTransitionOverlay] No GameCard found in parent chain")
	return {"card": null, "texture": null, "rect": Rect2(), "corner_radius": 0.0}

func _setup_effect_stack(texture: Texture2D, card_rect: Rect2, start_corner_radius: float):
	
	if not _effect_stack:
		push_error("[LaunchTransitionOverlay] _effect_stack is null")
		return
	
	# Position and size the EffectStack exactly at the card's location
	# Add 2px overshoot to compensate for shader AA edge
	_effect_stack.position = card_rect.position - Vector2(2, 2)
	_effect_stack.size = card_rect.size + Vector2(4, 4)
	
	# Create a media container for the effect stack
	var media_container = MediaContainer.new()
	media_container.texture = texture
	media_container.bounds = Rect2(Vector2.ZERO, card_rect.size)
	media_container.corner_radius_ratio = start_corner_radius
	
	# Setup minimal effect stack with base + HSL + gradient overlay
	# Disable smart crop for launch transition (scale from center, not bottom)
	# Gradient overlay: vertical, 2 black stops, both initially transparent
	var initial_gradient = Gradient.new()
	initial_gradient.offsets = [0.0, 1.0]
	initial_gradient.colors = [Color(0, 0, 0, 0), Color(0, 0, 0, 0)]  # Both transparent
	
	var effect_configs = [
		{"effect_id": "base", "settings": {}},
		{"effect_id": "hsl", "settings": {"hue_shift": 0.0, "saturation_scale": 1.0, "lightness_scale": 1.0}},
		{"effect_id": "gradient_overlay", "settings": {"gradient": initial_gradient, "gradient_direction": 1}}
	]
	
	_effect_stack.initialize(media_container, effect_configs)
	
	# Set the game texture on the base effect
	var base_effect = _effect_stack.get_effect("base") as BaseCardEffect
	if base_effect and texture:
		base_effect.set_game_texture(texture)

func _animate_transition():
	var tween = create_tween()
	if not tween:
		push_error("[LaunchTransitionOverlay] Failed to create tween")
		return
	
	# Calculate fullscreen target (screen aspect ratio) with slight overshoot to hide AA edge
	var viewport_size = Vector2(get_viewport().size)
	var overshoot = 4.0	 # Extend 4px beyond viewport to hide AA edge
	var target_size = viewport_size + Vector2(overshoot * 2, overshoot * 2)
	var target_pos = Vector2(-overshoot, -overshoot)  # Center the overshoot
	
	var media_container = _effect_stack.media_container
	
	# PHASE 1: Scale and position with QUART + EASE_OUT
	tween.set_trans(Tween.TRANS_QUART)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_parallel(true)
	
	# Animate EffectStack position and size to fullscreen
	tween.tween_property(_effect_stack, "position", target_pos, PHASE1_DURATION)
	tween.tween_property(_effect_stack, "size", target_size, PHASE1_DURATION)
	
	# Animate UV transforms, vertical offset, and corner radius during scale
	if media_container and media_container.texture:
		var tex_size = media_container.texture.get_size()
		var tex_aspect = tex_size.x / tex_size.y
		
		tween.tween_method(
			func(t: float):
				var current_size = _effect_stack.size
				media_container.bounds = Rect2(Vector2.ZERO, current_size)
				
				# Calculate vertical offset to keep image centered during aspect ratio change
				var card_aspect = current_size.x / current_size.y
				if card_aspect > tex_aspect:
					# Scaling from portrait to landscape - image will be cropped vertically
					var scale_y = tex_aspect / card_aspect
					media_container.vertical_offset = (1.0 - scale_y) / 2.0
				else:
					media_container.vertical_offset = 0.0
				
				_effect_stack.force_refresh(),
			0.0, 1.0, PHASE1_DURATION
		)
		
		var start_corner_radius = media_container.corner_radius_ratio
		tween.tween_method(
			func(t: float):
				media_container.corner_radius_ratio = lerpf(start_corner_radius, 0.0, t),
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
		var start_color = Color(0, 0, 0, 0)
		var end_color = Color(0, 0, 0, 1.0)
		
		tween.tween_method(
			func(t: float):
				var current_color = start_color.lerp(end_color, t)
				var gradient = gradient_effect._settings.get("gradient")
				if gradient and gradient is Gradient:
					gradient.colors[1] = current_color
					gradient_effect._update_shader_params(),
			0.0, 1.0, PHASE2_DURATION
		)
	
	# Stop parallel after phase 2
	tween.set_parallel(false)
	
	# Complete
	tween.chain().tween_callback(_on_animation_complete)

func _on_animation_complete():
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

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		if visible and PlatformManager.is_android():
			visible = false
			if LaunchManager and LaunchManager.background_state_exited.is_connected(_on_background_state_exited):
				LaunchManager.background_state_exited.disconnect(_on_background_state_exited)

func _exit_tree() -> void:
	if LaunchManager and LaunchManager.background_state_exited.is_connected(_on_background_state_exited):
		LaunchManager.background_state_exited.disconnect(_on_background_state_exited)

func is_animating() -> bool:
	return _is_animating
