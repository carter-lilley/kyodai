extends Node

## Logo/title box cache manager.
##
## Runs the native LogoDetector GDExtension at sync time, scores candidates
## against the game title, and caches the result in user://cache/logo_boxes.json.

const CACHE_PATH := "user://cache/logo_boxes.json"
const MODEL_DIR := "res://addons/logo_detector/models"

var _detector: LogoDetector = null
var _cache: Dictionary = {}

func _ready() -> void:
	_load_cache()

func _load_cache() -> void:
	var file := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if file:
		var text := file.get_as_text()
		var parsed := JSON.parse_string(text)
		if parsed is Dictionary:
			_cache = parsed
		file.close()

func _save_cache() -> void:
	var dir := CACHE_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(_cache, "\t"))
		file.close()

func _ensure_detector() -> bool:
	if _detector != null:
		return _detector.is_yolo_model_loaded() and _detector.is_ocr_rec_model_loaded()

	_detector = LogoDetector.new()

	var err := _detector.load_yolo_model(MODEL_DIR + "/logo_detector.onnx")
	if err != OK:
		push_error("LogoBoxCache: Failed to load YOLO model: %d" % err)
		return false

	err = _detector.load_ocr_rec_model(MODEL_DIR + "/ch_PP-OCRv4_rec_infer.onnx")
	if err != OK:
		push_error("LogoBoxCache: Failed to load OCR rec model: %d" % err)
		return false

	return true

## Return the cached logo box for the given key, or compute it if missing.
## key should uniquely identify the cover (e.g. md5(cover_url) or cover_path).
func get_box(key: String, image: Image, title: String, force_refresh := false) -> Dictionary:
	if not force_refresh and _cache.has(key):
		return _cache[key]

	if not _ensure_detector():
		return {"detected": false}

	var candidates: Array = _detector.detect_candidates(image, 0.15, 0.45, 5)
	var ocr_words: Array = _detector.ocr_full_image(image)
	var best := _select_best(candidates, ocr_words, title, image)

	if best.get("detected", false):
		_cache[key] = best
		_save_cache()

	return best

func _select_best(candidates: Array, ocr_words: Array, title: String, image: Image) -> Dictionary:
	if candidates.is_empty():
		return {"detected": false}

	var title_lower := title.to_lower()
	var image_w := float(image.get_width())
	var image_h := float(image.get_height())
	var diag := sqrt(image_w * image_w + image_h * image_h)
	var best_score := -1.0
	var best_candidate: Dictionary = {}

	for candidate in candidates:
		var cx := (candidate["x1"] + candidate["x2"]) / 2.0
		var cy := (candidate["y1"] + candidate["y2"]) / 2.0
		var cand_conf: float = candidate["confidence"]

		var best_word_score := 0.0
		var matched_text := ""

		for word in ocr_words:
			var wcx := (word["x1"] + word["x2"]) / 2.0
			var wcy := (word["y1"] + word["y2"]) / 2.0
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
			var proximity := max(0.0, 1.0 - dist / (diag * 0.3))
			var word_score := sim * proximity

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

	best_candidate = candidates[0].duplicate()
	best_candidate["detected"] = true
	best_candidate["matched_text"] = ""
	best_candidate["title_score"] = 0.0
	best_candidate["combined_score"] = best_candidate["confidence"]
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

## Clear all cached boxes.
func clear() -> void:
	_cache.clear()
	_save_cache()

## Save the current cache to disk.
func save() -> void:
	_save_cache()
