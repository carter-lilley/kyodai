class_name ShufflerChoiceWindow
extends Window

## Balatro-style "choose 1 of 3" screen shown between shuffles. Summoned as a
## fullscreen, always-on-top OS window; dismissed after the player picks a card.

signal game_chosen(chosen: Dictionary, candidates: Array)

const FSM = preload("res://managers/system_manager/filesystem_sub_manager.gd")
const MAX_COVER_TEXTURE_SIZE := 512

@onready var _card_a: M3Card = $Root/CenterBox/Row/CardA
@onready var _card_b: M3Card = $Root/CenterBox/Row/CardB
@onready var _card_c: M3Card = $Root/CenterBox/Row/CardC

var _candidates: Array = []
var _resolved := false

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

	# Native focus border instead of FocusSubManager's global ring (this
	# window is outside the main UI's canvas layer).
	var focus_style := StyleBoxFlat.new()
	focus_style.bg_color = Color(0, 0, 0, 0)
	focus_style.border_color = M3Theme.get_primary()
	focus_style.set_border_width_all(M3Units.dp(3))
	focus_style.set_corner_radius_all(M3Units.dp(12))
	for card in [_card_a, _card_b, _card_c]:
		card.add_theme_stylebox_override("focus", focus_style)
		card.custom_minimum_size = Vector2(M3Units.dp(260), M3Units.dp(340))

	$Root/CenterBox/Row.add_theme_constant_override("separation", M3Units.dp(40))

	# No cancel path for now (testing): refuse to be closed without a pick.
	close_requested.connect(move_to_foreground.call)

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
