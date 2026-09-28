class_name ShufflerChoiceWindow
extends Window

## Balatro-style "choose 1 of 3" screen shown between shuffles. Summoned as a
## fullscreen, always-on-top OS window; dismissed after the player picks a card.

signal game_chosen(chosen: Dictionary, candidates: Array)

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const MAX_COVER_TEXTURE_SIZE := 512
const TILT_DEGREES := 4.0
const HOVER_AMPLITUDE_DP := 12.0
const HOVER_HALF_PERIOD := 2.2
const HOVER_TURN_DWELL := 0.5
const HOVER_PHASE_STAGGER := 0.45
const ENTRANCE_DURATION := 0.6
const ENTRANCE_STAGGER := 0.12

@onready var _card_a: M3Card = $Root/CenterBox/VBox/Row/CardA
@onready var _card_b: M3Card = $Root/CenterBox/VBox/Row/CardB
@onready var _card_c: M3Card = $Root/CenterBox/VBox/Row/CardC

var _candidates: Array = []
var _resolved := false
var _base_poses: Dictionary = {}

func _ready() -> void:
	# Same OS-window initialization pattern as ShufflerControlsWindow: a real
	# OS window is required so this viewport receives controller input.
	transparent = true
	transparent_bg = true
	theme = Theme.new()
	size = DisplayServer.screen_get_size()
	always_on_top = false
	popup()
	transient = false
	always_on_top = true
	position = DisplayServer.screen_get_position()
	move_to_foreground()

	# Cards use FOCUS_ALL via clickable; give them wrap-around left/right
	# neighbors so D-pad navigation cycles through all three.
	_card_a.focus_neighbor_left = _card_a.get_path_to(_card_c)
	_card_a.focus_neighbor_right = _card_a.get_path_to(_card_b)
	_card_b.focus_neighbor_left = _card_b.get_path_to(_card_a)
	_card_b.focus_neighbor_right = _card_b.get_path_to(_card_c)
	_card_c.focus_neighbor_left = _card_c.get_path_to(_card_b)
	_card_c.focus_neighbor_right = _card_c.get_path_to(_card_a)

	# FocusSubManager's global ring can't reach this separate OS window, and a
	# Button "focus" stylebox draws beneath M3Card's RS-rendered background
	# (only the ring's corners peek out). Instead each card gets a child Panel
	# ring: z_index lifts it above the card's visual canvas items (including
	# the focused +1000000 draw-index boost), and as a child it inherits the
	# offset transforms, so it tracks the fan tilt and hover bob exactly.
	var focus_style := StyleBoxFlat.new()
	focus_style.bg_color = Color(0, 0, 0, 0)
	focus_style.border_color = M3Theme.get_primary()
	focus_style.set_border_width_all(M3Units.dp(3))
	focus_style.set_corner_radius_all(M3Units.dp(12))
	for card in [_card_a, _card_b, _card_c]:
		card.custom_minimum_size = Vector2(M3Units.dp(320), M3Units.dp(418))
		var ring := Panel.new()
		ring.name = "FocusRing"
		ring.set_anchors_preset(Control.PRESET_FULL_RECT)
		ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
		ring.focus_mode = Control.FOCUS_NONE
		ring.z_index = 1
		ring.visible = false
		ring.add_theme_stylebox_override("panel", focus_style)
		card.add_child(ring)
		card.focus_entered.connect(ring.show)
		card.focus_exited.connect(ring.hide)

	$Root/CenterBox/VBox/Row.add_theme_constant_override("separation", M3Units.dp(24))

	# White title with a soft drop shadow so it reads over the gradient flow.
	var title: Label = $Root/CenterBox/VBox/Title
	title.add_theme_color_override("font_color", Color.WHITE)
	title.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.6))
	title.add_theme_constant_override("shadow_offset_x", 0)
	title.add_theme_constant_override("shadow_offset_y", M3Units.dp(3))

	_setup_background()
	_apply_card_poses()
	_play_entrance_animation()

	# No cancel path for now (testing): refuse to be closed without a pick.
	close_requested.connect(move_to_foreground.call)

## Gradient Flow behind the cards, rendered through the same LibraryBackground
## pipeline as the main library. Reuses the player's Gradient Flow settings
## (and base gradient) from their library background config when present.
func _setup_background() -> void:
	var config := {
		"base": {"settings": {}},
		# Half-speed drift for the fallback; the player's own saved Gradient
		# Flow settings win when present.
		"effects": [{"effect_id": "gradient_flow", "settings": {"time_scale": 0.5}}],
		"overlays": [],
	}
	var saved = DataManager.get_setting("library_background_config")
	if saved and saved.value is Dictionary:
		var lib_config := LibraryBackground.normalize_config(saved.value)
		var base_settings: Dictionary = lib_config.get("base", {}).get("settings", {})
		if not base_settings.is_empty():
			config["base"]["settings"] = base_settings
		for entry in lib_config.get("effects", []):
			if entry is Dictionary and entry.get("effect_id", "") == "gradient_flow":
				config["effects"][0]["settings"] = entry.get("settings", {})
				break
	$Root/LibraryBackground.set_background_config(config)

## Fans the cards out like a held hand: the two side cards tilt outward around
## their bottom edge and sit slightly lower than the middle card. Uses Godot
## 4.7's Control offset transform so the HBoxContainer layout is untouched.
func _apply_card_poses() -> void:
	_base_poses[_card_a] = Vector2(0, M3Units.dp(14))
	_base_poses[_card_b] = Vector2.ZERO
	_base_poses[_card_c] = Vector2(0, M3Units.dp(14))
	for card in [_card_a, _card_b, _card_c]:
		card.offset_transform_enabled = true
		card.offset_transform_visual_only = true
		card.offset_transform_pivot_ratio = Vector2(0.5, 1.0)
		card.offset_transform_position = _base_poses[card]
	_card_a.offset_transform_rotation = deg_to_rad(-TILT_DEGREES)
	_card_c.offset_transform_rotation = deg_to_rad(TILT_DEGREES)

## Cards fly up from below the screen into their fan poses, middle card first,
## then hand off to the hover loop. The BACK ease lets them overshoot and
## settle into place with a snap.
func _play_entrance_animation() -> void:
	var offscreen := Vector2(0, size.y + M3Units.dp(418))
	var order := [_card_b, _card_a, _card_c]
	for i in range(order.size()):
		var card: M3Card = order[i]
		var base: Vector2 = _base_poses[card]
		card.offset_transform_position = base + offscreen
		var tween := card.create_tween()
		tween.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_interval(ENTRANCE_STAGGER * i)
		tween.tween_property(card, "offset_transform_position", base, ENTRANCE_DURATION)
		tween.tween_callback(_start_hover.bind(card))

## Gentle cyclical float: each card bobs up and down around its fan pose with
## a staggered phase so they don't move in lockstep.
func _start_hover(card: M3Card) -> void:
	var phase_index := [_card_a, _card_b, _card_c].find(card)
	var base: Vector2 = _base_poses[card]
	var peak := base + Vector2(0, -M3Units.dp(HOVER_AMPLITUDE_DP))
	var tween := card.create_tween().set_loops()
	tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tween.tween_interval(HOVER_PHASE_STAGGER * phase_index)
	tween.tween_property(card, "offset_transform_position", peak, HOVER_HALF_PERIOD).from(base)
	tween.tween_interval(HOVER_TURN_DWELL)
	tween.tween_property(card, "offset_transform_position", base, HOVER_HALF_PERIOD)
	tween.tween_interval(HOVER_TURN_DWELL)

func present(candidates: Array) -> void:
	_candidates = candidates
	var cards := [_card_a, _card_b, _card_c]
	for i in range(mini(candidates.size(), cards.size())):
		var entry: Dictionary = candidates[i]
		var card: M3Card = cards[i]
		card.headline = entry.game.title
		_load_cover(card, entry.game)
		if not card.pressed.is_connected(_on_card_pressed):
			card.pressed.connect(_on_card_pressed.bind(entry))
	call_deferred("_focus_first_card")

func _focus_first_card() -> void:
	_card_a.grab_focus()

func _on_card_pressed(entry: Dictionary) -> void:
	if _resolved:
		return
	_resolved = true
	game_chosen.emit(entry, _candidates)
	hide()

func _load_cover(card: M3Card, game: GameResource) -> void:
	if not game:
		return
	var cache_path := ""
	var cover_url := ""
	if game.cover_path and FSM.file_exists(game.cover_path):
		cache_path = game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		cover_url = game.cover_url
		cache_path = DataManager.get_cached_image_path(cover_url)
	if cache_path == "":
		return
	if not FSM.file_exists(cache_path):
		# Not on disk yet: these games may never have appeared in the library
		# grid, so their covers were never downloaded. Fetch now (CoverSubManager
		# writes the cache file), then re-run the decode path. The file-exists
		# guard prevents a retry loop when the download itself fails.
		if cover_url != "":
			var card_ref_dl: WeakRef = weakref(card)
			DataManager.load_image(cover_url, func(_t: Texture2D):
				var c: M3Card = card_ref_dl.get_ref()
				if c and FSM.file_exists(cache_path):
					_load_cover(c, game)
			)
		return
	var cache_key := MemorySubManager.cover_cache_key(cache_path, MAX_COVER_TEXTURE_SIZE)
	var cached = SystemManager.memory.get_cached_texture(cache_key)
	if cached:
		card.media_texture = cached
		return
	DataManager.cover.note_cover_access(cache_path)
	var card_ref: WeakRef = weakref(card)
	SystemManager.memory.queue_image_task(
		func() -> Image:
			return MemorySubManager.prepare_image_for_texture(CardMediaLoader._load_image_from_buffer(FSM.read_file_bytes(cache_path))),
		func(image) -> void:
			var c: M3Card = card_ref.get_ref()
			if not c or not image or image.is_empty():
				return
			var texture = SystemManager.memory.create_texture_from_image(image)
			if texture:
				SystemManager.memory.cache_texture(cache_key, texture)
				c.media_texture = texture
	)
