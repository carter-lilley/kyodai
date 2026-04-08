class_name LaunchTransitionOverlay
extends Control

## Overlay that plays a launch transition animation when launching a game.
## Animates from card position to fullscreen while applying HSL effects.
## Morphs from card aspect ratio to screen aspect ratio (cover fit).

signal animation_completed

@onready var _effect_stack: EffectStack = $EffectStack
@onready var _game_title_label: Label = $GameTitleLabel

const PHASE1_DURATION: float = 0.5
const HOLD_DURATION: float = 0.1
const PHASE2_DURATION: float = 0.5

var _is_animating: bool = false
var _original_card_rect: Rect2
var _game: GameResource

func _ready():
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	
	print("[LaunchTransitionOverlay] _ready() called")
	print("[LaunchTransitionOverlay] _effect_stack: ", _effect_stack)
	print("[LaunchTransitionOverlay] LaunchManager: ", LaunchManager)
	
	# Connect to LaunchManager signal
	if LaunchManager:
		print("[LaunchTransitionOverlay] Connecting to game_launch_initiated signal")
		LaunchManager.game_launch_initiated.connect(_on_game_launch_initiated)
	else:
		print("[LaunchTransitionOverlay] ERROR: LaunchManager is null!")

func _on_game_launch_initiated(game: GameResource, _focus_index: int):
	print("[LaunchTransitionOverlay] _on_game_launch_initiated() called")
	print("[LaunchTransitionOverlay] Game: ", game.get_display_name() if game else "null")
	
	# We get the texture from the focused card, not from the game resource
	# This avoids filesystem access and works on Android
	_start_transition()

func _start_transition():
	print("[LaunchTransitionOverlay] _start_transition() called")
	
	if _is_animating:
		print("[LaunchTransitionOverlay] Already animating, skipping")
		return
	
	_is_animating = true
	
	# Get the focused card and its texture
	print("[LaunchTransitionOverlay] Getting focused card and texture...")
	var card_info = _get_focused_card_and_texture()
	var texture = card_info.texture
	var card_rect = card_info.rect
	var card = card_info.card
	var start_corner_radius = card_info.corner_radius
	
	if not texture:
		print("[LaunchTransitionOverlay] ERROR: Failed to get texture from card, aborting")
		_is_animating = false
		return
	print("[LaunchTransitionOverlay] Texture retrieved successfully: ", texture)
	
	if card_rect.size.x <= 0 or card_rect.size.y <= 0:
		print("[LaunchTransitionOverlay] ERROR: Invalid card rect (size <= 0), aborting")
		_is_animating = false
		return
	
	_original_card_rect = card_rect
	_game = card.game if card else null
	
	# Setup the EffectStack at the card's position
	print("[LaunchTransitionOverlay] Setting up EffectStack at card position...")
	_setup_effect_stack(texture, card_rect, start_corner_radius)
	
	# Setup the game title label
	if _game_title_label:
		_game_title_label.text = _game.get_display_name().to_upper() if _game else ""
		# Set large font size for fullscreen display (10% of screen height)
		var viewport_height = get_viewport().size.y
		var font_size = int(viewport_height * 0.08)
		_game_title_label.add_theme_font_size_override("font_size", font_size)
		_game_title_label.visible = true
	
	# Show and animate
	print("[LaunchTransitionOverlay] Making visible and starting animation")
	visible = true
	z_index = 1000
	
	# Run the animation sequence
	_animate_transition()

func _get_focused_card_and_texture() -> Dictionary:
	print("[LaunchTransitionOverlay] _get_focused_card_and_texture() called")
	
	# Find the currently focused GameCard
	var viewport = get_viewport()
	print("[LaunchTransitionOverlay] Viewport: ", viewport)
	
	if not viewport:
		print("[LaunchTransitionOverlay] ERROR: Viewport is null")
		return {"card": null, "texture": null, "rect": Rect2(), "corner_radius": 0.0}
	
	var focused = viewport.gui_get_focus_owner()
	print("[LaunchTransitionOverlay] Focused control: ", focused)
	
	if not focused:
		print("[LaunchTransitionOverlay] ERROR: No focused control")
		return {"card": null, "texture": null, "rect": Rect2(), "corner_radius": 0.0}
	
	# Traverse up to find GameCard
	var current = focused
	var depth = 0
	while current:
		depth += 1
		if depth > 20:
			print("[LaunchTransitionOverlay] ERROR: Exceeded max search depth")
			return {"card": null, "texture": null, "rect": Rect2(), "corner_radius": 0.0}
		
		print("[LaunchTransitionOverlay] Checking node: ", current.name, " (", current.get_class(), ")")
		
		if current is GameCard:
			var card = current as GameCard
			print("[LaunchTransitionOverlay] Found GameCard!")
			print("[LaunchTransitionOverlay] Card visual_container: ", card.visual_container)
			
			# Get the visual container's global rect
			var card_rect = Rect2()
			if card.visual_container:
				var global_pos = card.visual_container.global_position
				var size = card.visual_container.size
				card_rect = Rect2(global_pos, size)
				print("[LaunchTransitionOverlay] Visual container pos: ", global_pos, " size: ", size)
			else:
				print("[LaunchTransitionOverlay] ERROR: Card has no visual_container")
			
			# Get the texture directly from the card
			var texture = card.get_current_texture()
			print("[LaunchTransitionOverlay] Got texture from card: ", texture)
			
			# Get the card's corner radius
			var card_state = card.get_card_state()
			var corner_radius = card_state.corner_radius_ratio if card_state else 0.06
			print("[LaunchTransitionOverlay] Card corner radius: ", corner_radius)
			
			return {"card": card, "texture": texture, "rect": card_rect, "corner_radius": corner_radius}
		
		current = current.get_parent()
	
	print("[LaunchTransitionOverlay] ERROR: No GameCard found in parent chain")
	return {"card": null, "texture": null, "rect": Rect2(), "corner_radius": 0.0}

func _setup_effect_stack(texture: Texture2D, card_rect: Rect2, start_corner_radius: float):
	print("[LaunchTransitionOverlay] _setup_effect_stack() called")
	print("[LaunchTransitionOverlay] _effect_stack exists: ", _effect_stack != null)
	print("[LaunchTransitionOverlay] Starting corner radius: ", start_corner_radius)
	
	if not _effect_stack:
		print("[LaunchTransitionOverlay] ERROR: _effect_stack is null")
		return
	
	# Position and size the EffectStack exactly at the card's location
	# Add 2px overshoot to compensate for shader AA edge
	print("[LaunchTransitionOverlay] Setting EffectStack position: ", card_rect.position)
	print("[LaunchTransitionOverlay] Setting EffectStack size: ", card_rect.size)
	_effect_stack.position = card_rect.position - Vector2(2, 2)
	_effect_stack.size = card_rect.size + Vector2(4, 4)
	
	# Create a container state for the effect stack
	print("[LaunchTransitionOverlay] Creating EffectContainerState...")
	var container_state = EffectContainerState.for_card()
	container_state.game_texture = texture
	container_state.container_size = card_rect.size
	container_state.corner_radius_ratio = start_corner_radius  # Start with card's corner radius
	
	# Setup minimal effect stack with just base + HSL
	# Disable smart crop for launch transition (scale from center, not bottom)
	var effect_configs = [
		{"effect_id": "base", "settings": {"smart_crop_enabled": false}},
		{"effect_id": "hsl", "settings": {"hue_shift": 0.0, "saturation_scale": 1.0, "lightness_scale": 1.0}}
	]
	print("[LaunchTransitionOverlay] Initializing effect stack with configs: ", effect_configs)
	
	_effect_stack.initialize(container_state, effect_configs)
	print("[LaunchTransitionOverlay] Effect stack initialized")
	
	# Set the game texture on the base effect
	var base_effect = _effect_stack.get_effect("base") as BaseCardEffect
	print("[LaunchTransitionOverlay] Base effect: ", base_effect)
	if base_effect and texture:
		print("[LaunchTransitionOverlay] Setting game texture on base effect")
		base_effect.set_game_texture(texture)
	
	print("[LaunchTransitionOverlay] EffectStack setup complete")

func _animate_transition():
	print("[LaunchTransitionOverlay] _animate_transition() called")
	print("[LaunchTransitionOverlay] Creating tween...")
	
	var tween = create_tween()
	if not tween:
		print("[LaunchTransitionOverlay] ERROR: Failed to create tween")
		return
	
	# Calculate fullscreen target (screen aspect ratio) with slight overshoot to hide AA edge
	var viewport_size = Vector2(get_viewport().size)
	var overshoot = 4.0  # Extend 4px beyond viewport to hide AA edge
	var target_size = viewport_size + Vector2(overshoot * 2, overshoot * 2)
	var target_pos = Vector2(-overshoot, -overshoot)  # Center the overshoot
	
	print("[LaunchTransitionOverlay] Viewport size: ", viewport_size)
	print("[LaunchTransitionOverlay] Target position: ", target_pos)
	print("[LaunchTransitionOverlay] Target size: ", target_size)
	print("[LaunchTransitionOverlay] Original card size: ", _original_card_rect.size)
	
	var container_state = _effect_stack.get_container_state()
	
	# PHASE 1: Scale and position with QUART + EASE_OUT
	print("[LaunchTransitionOverlay] PHASE 1: Scale/position animation (QUART + EASE_OUT)...")
	tween.set_trans(Tween.TRANS_QUART)
	tween.set_ease(Tween.EASE_OUT)
	tween.set_parallel(true)
	
	# Animate EffectStack position and size to fullscreen
	tween.tween_property(_effect_stack, "position", target_pos, PHASE1_DURATION)
	tween.tween_property(_effect_stack, "size", target_size, PHASE1_DURATION)
	
	# Animate UV transforms, vertical offset, and corner radius during scale
	if container_state and container_state.game_texture:
		var tex_size = container_state.game_texture.get_size()
		var tex_aspect = tex_size.x / tex_size.y
		
		tween.tween_method(
			func(t: float):
				var current_size = _original_card_rect.size.lerp(target_size, t)
				container_state.container_size = current_size
				
				# Calculate vertical offset to keep image centered during aspect ratio change
				var card_aspect = current_size.x / current_size.y
				if card_aspect > tex_aspect:
					# Scaling from portrait to landscape - image will be cropped vertically
					var scale_y = tex_aspect / card_aspect
					container_state.vertical_offset = (1.0 - scale_y) / 2.0
				else:
					container_state.vertical_offset = 0.0
				
				for effect_id in ["base", "hsl"]:
					var effect = _effect_stack.get_effect(effect_id)
					if effect:
						effect.update_state(container_state),
			0.0, 1.0, PHASE1_DURATION
		)
		
		var start_corner_radius = container_state.corner_radius_ratio
		tween.tween_method(
			func(t: float):
				container_state.corner_radius_ratio = lerpf(start_corner_radius, 0.0, t),
			0.0, 1.0, PHASE1_DURATION
		)
	
	# Hold after phase 1
	print("[LaunchTransitionOverlay] Hold for ", HOLD_DURATION, " seconds...")
	tween.chain().tween_interval(HOLD_DURATION)
	
	# PHASE 2: HSL fade with CIRC + EASE_IN
	print("[LaunchTransitionOverlay] PHASE 2: HSL fade (CIRC + EASE_IN)...")
	var hsl_effect = _effect_stack.get_effect("hsl") as HSLEffect
	
	if hsl_effect:
		tween.chain().tween_method(
			func(t: float):
				var sat = lerpf(1.0, 0.0, t)
				var light = lerpf(1.0, 0.3, t)
				hsl_effect._settings["saturation_scale"] = sat
				hsl_effect._settings["lightness_scale"] = light
				hsl_effect._update_shader_params(),
			0.0, 1.0, PHASE2_DURATION
		).set_trans(Tween.TRANS_CIRC).set_ease(Tween.EASE_IN)
	else:
		print("[LaunchTransitionOverlay] WARNING: HSL effect not found")
	
	# Complete
	print("[LaunchTransitionOverlay] Adding completion callback")
	tween.chain().tween_callback(_on_animation_complete)
	
	print("[LaunchTransitionOverlay] Tween setup complete, animation should start now")

func _on_animation_complete():
	return # DEBUG: HOLD THE FINAL STATE, KEEP FOR NOW
	print("[LaunchTransitionOverlay] _on_animation_complete() called")
	if _game_title_label:
		_game_title_label.visible = false
	visible = false
	_is_animating = false
	animation_completed.emit()
	print("[LaunchTransitionOverlay] Animation complete, overlay hidden")

func is_animating() -> bool:
	return _is_animating
