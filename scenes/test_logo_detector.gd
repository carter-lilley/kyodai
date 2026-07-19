extends Node2D

# Ugly test scene for the native logo detector. Direct detection, no cache.

@onready var cover_image: TextureRect = $CoverImage
@onready var status_label: Label = $StatusLabel

var _game: GameResource = null
var _candidates: Array = []
var _ocr_words: Array = []
var _best_box: Dictionary = {}

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

func _ready():
	status_label.text = "Loading random game..."
	_pick_random_game()

func _pick_random_game():
	_game = DataManager.get_random_game()
	if _game == null:
		status_label.text = "No games in database"
		return

	_candidates = []
	_ocr_words = []
	_best_box = {}
	queue_redraw()

	status_label.text = "Game: %s" % _game.title

	if _game.cover_path and FSM.file_exists(_game.cover_path):
		var image = Image.new()
		var err = image.load(_game.cover_path)
		if err == OK:
			_on_image_loaded(image)
			return
	_load_from_url()

func _load_from_url():
	if _game.cover_url and _game.cover_url.begins_with("http"):
		status_label.text = "Downloading cover..."
		DataManager.load_image(_game.cover_url, _on_texture_loaded)
	else:
		status_label.text = "No cover available"

func _on_texture_loaded(texture: Texture2D):
	if texture == null:
		status_label.text = "Failed to load cover texture"
		return
	var image = texture.get_image()
	if image == null:
		status_label.text = "Failed to get image from texture"
		return
	_on_image_loaded(image)

func _on_image_loaded(image: Image):
	var display_image = image.duplicate()
	if display_image.get_format() != Image.FORMAT_RGBA8:
		display_image.convert(Image.FORMAT_RGBA8)

	cover_image.texture = ImageTexture.create_from_image(display_image)
	cover_image.size = Vector2(display_image.get_width(), display_image.get_height())

	status_label.text = "Running logo detection on '%s'..." % _game.title
	var detector = LogoDetector.new()

	var err = detector.load_yolo_model("res://addons/logo_detector/models/logo_detector.onnx")
	if err != OK:
		status_label.text = "Failed to load YOLO model: %d" % err
		return

	err = detector.load_ocr_rec_model("res://addons/logo_detector/models/ch_PP-OCRv4_rec_infer.onnx")
	if err != OK:
		status_label.text = "Failed to load OCR rec model: %d" % err
		return

	_candidates = detector.detect_candidates(image, 0.15, 0.45, 10)
	_ocr_words = detector.ocr_full_image(image)
	_best_box = _select_best_box(_game.title)

	status_label.text = "Title: %s | Candidates: %d | OCR words: %d | Detected: %s" % [
		_game.title,
		_candidates.size(),
		_ocr_words.size(),
		"YES" if _best_box.get("detected", false) else "NO"
	]

	queue_redraw()

func _select_best_box(title: String) -> Dictionary:
	if _candidates.is_empty():
		return {"detected": false}

	var title_lower := title.to_lower()
	var best_score := -1.0
	var best_candidate: Dictionary = {}
	var image_w := 1.0
	var image_h := 1.0
	if cover_image.texture != null:
		image_w = float(cover_image.texture.get_width())
		image_h = float(cover_image.texture.get_height())
	var diag := sqrt(image_w * image_w + image_h * image_h)

	for candidate in _candidates:
		var cx := (float(candidate["x1"]) + float(candidate["x2"])) / 2.0
		var cy := (float(candidate["y1"]) + float(candidate["y2"])) / 2.0
		var cand_conf := float(candidate["confidence"])

		var best_word_score := 0.0
		var matched_text := ""

		for word in _ocr_words:
			var wcx := (float(word["x1"]) + float(word["x2"])) / 2.0
			var wcy := (float(word["y1"]) + float(word["y2"])) / 2.0
			var text: String = word["text"]
			var text_lower := text.to_lower()

			var sim := 0.0
			if not text_lower.is_empty() and not title_lower.is_empty():
				var title_tokens := title_lower.split(" ", false)
				for token in title_tokens:
					if token.length() <= 2:
						continue
					var token_sim := _token_similarity(text_lower, token)
					if token_sim > sim:
						sim = token_sim

				var full_sim := _text_similarity(text_lower, title_lower)
				if full_sim > sim:
					sim = full_sim

			var dx := cx - wcx
			var dy := cy - wcy
			var dist := sqrt(dx * dx + dy * dy)
			var proximity: float = max(0.0, 1.0 - dist / (diag * 0.3))
			var word_score: float = sim * proximity

			if word_score > best_word_score:
				best_word_score = word_score
				matched_text = text

		var combined := cand_conf * 0.3 + best_word_score * 0.7
		if combined > best_score:
			best_score = combined
			best_candidate = candidate.duplicate()
			best_candidate["matched_text"] = matched_text
			best_candidate["title_score"] = best_word_score
			best_candidate["combined_score"] = combined

	if best_score > 0.0:
		best_candidate["detected"] = true
		return best_candidate

	best_candidate = _candidates[0].duplicate()
	best_candidate["detected"] = true
	best_candidate["matched_text"] = ""
	best_candidate["title_score"] = 0.0
	best_candidate["combined_score"] = float(best_candidate["confidence"])
	return best_candidate

func _text_similarity(a: String, b: String) -> float:
	if a == b:
		return 1.0
	if a.is_empty() or b.is_empty():
		return 0.0
	if a.contains(b) or b.contains(a):
		return 0.8
	return 0.0

func _token_similarity(a: String, b: String) -> float:
	if a == b:
		return 1.0
	if a.is_empty() or b.is_empty():
		return 0.0
	if a.contains(b) or b.contains(a):
		return 0.95
	return 0.0

func _draw():
	var font := ThemeDB.fallback_font
	if font == null:
		font = SystemFont.new()

	var font_size := 14
	var bg_color := Color.BLACK
	bg_color.a = 0.6

	# Draw candidate boxes in red with confidence.
	for candidate in _candidates:
		var x1 := float(candidate["x1"])
		var y1 := float(candidate["y1"])
		var x2 := float(candidate["x2"])
		var y2 := float(candidate["y2"])
		var conf := float(candidate["confidence"])
		draw_rect(Rect2(x1, y1, x2 - x1, y2 - y1), Color.RED, false, 1.0)
		var label := "c:%.2f" % conf
		_draw_label(x1, y1 - font_size - 2, label, font, font_size, Color.RED, bg_color)

	# Draw OCR word boxes in blue with recognized text.
	for word in _ocr_words:
		var x1 := float(word["x1"])
		var y1 := float(word["y1"])
		var x2 := float(word["x2"])
		var y2 := float(word["y2"])
		var text: String = word["text"]
		draw_rect(Rect2(x1, y1, x2 - x1, y2 - y1), Color.BLUE, false, 1.0)
		_draw_label(x1, y2 + 2, text, font, font_size, Color.BLUE, bg_color)

	# Draw best box in green with details.
	if _best_box.get("detected", false):
		var x1 := float(_best_box["x1"])
		var y1 := float(_best_box["y1"])
		var x2 := float(_best_box["x2"])
		var y2 := float(_best_box["y2"])
		var matched: String = _best_box.get("matched_text", "")
		var cand_conf := float(_best_box.get("confidence", 0.0))
		var title_score := float(_best_box.get("title_score", 0.0))
		var combined := float(_best_box.get("combined_score", 0.0))

		draw_rect(Rect2(x1, y1, x2 - x1, y2 - y1), Color.GREEN, false, 3.0)
		var lines := [
			"BEST: %s" % (matched if not matched.is_empty() else "<no text match>"),
			"cand:%.2f title:%.2f combined:%.2f" % [cand_conf, title_score, combined]
		]
		var ty := y1 - float(font_size * lines.size()) - 4.0
		for line in lines:
			_draw_label(x1, ty, line, font, font_size, Color.GREEN, bg_color)
			ty += float(font_size) + 2.0

func _draw_label(x: float, y: float, text: String, font: Font, font_size: int, color: Color, bg: Color):
	if text.is_empty() or font == null:
		return
	var size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_rect(Rect2(x, y, size.x + 4, size.y + 2), bg)
	draw_string(font, Vector2(x + 2, y + size.y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)

func _unhandled_input(event: InputEvent):
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_R or event.keycode == KEY_SPACE:
			_pick_random_game()
