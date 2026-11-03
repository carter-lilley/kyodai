extends Node

var _failures: Array[String] = []

func _ready() -> void:
	# Match other scene-based tests: let autoload settings/database startup
	# settle before running and quitting so worker callbacks don't race teardown.
	for i in 5:
		await get_tree().process_frame
	_run()

func _check(condition: bool, message: String) -> void:
	if not condition:
		_failures.append(message)
		push_error(message)

func _run() -> void:
	var media := MediaContainer.new()
	media.bounds = Rect2(Vector2.ZERO, Vector2(200, 100))
	media.corner_radius_ratio = 0.2
	var stack := EffectStack.new()
	var stroke_a := {
		"layer_id": "stroke_a",
		"effect_id": "stroke",
		"settings": {"stroke_width_ratio": 0.02, "advance": true},
	}
	var stroke_b := {
		"layer_id": "stroke_b",
		"effect_id": "stroke",
		"settings": {"stroke_width_ratio": 0.03, "advance": true},
	}
	var inset := {
		"layer_id": "gap",
		"effect_id": "inset",
		"settings": {"inset_ratio": 0.01},
	}
	var distort := {
		"layer_id": "distort",
		"effect_id": "distort",
		"settings": {},
	}
	stack.initialize(media, [stroke_a, distort, stroke_b, inset], "base_card")
	_check(stack.get_effects().size() == 5, "base plus four configured layers should exist")
	_check(stack.get_layer("stroke_a") != stack.get_layer("stroke_b"), "same-type layers must be distinct")
	_check(stack.get_layer("stroke_a").stroke_offset_pixels == 0.0, "first stroke starts at the outer edge")
	_check(stack.get_layer("stroke_b").stroke_offset_pixels == 4.0, "second stroke starts after the first")
	_check(stack.get_layer("distort").layer_inset_pixels == 4.0, "distort inherits only the depth preceding it")
	_check(stack.get_layer("stroke_b").stroke_width_pixels == 6.0, "stroke width uses card-relative geometry")
	_check(is_equal_approx(media.content_inset_pixels, 12.0), "strokes and inset produce the final aperture")
	_check(stack.get_layer("gap").is_geometry_only(), "inset is geometry-only")
	_check(not stack.get_layer("gap")._canvas_item_rid.is_valid(), "inset allocates no canvas item")

	var original_a: EffectBase = stack.get_layer("stroke_a")
	var original_b: EffectBase = stack.get_layer("stroke_b")
	stack.update_effect_configs([stroke_b, distort, stroke_a, inset])
	_check(stack.get_layer("stroke_a") == original_a, "reorder preserves stroke A instance")
	_check(stack.get_layer("stroke_b") == original_b, "reorder preserves stroke B instance")
	_check(stack.get_layer("stroke_b").stroke_offset_pixels == 0.0, "reordered stroke B moves to the outer edge")
	_check(stack.get_layer("stroke_a").stroke_offset_pixels == 6.0, "reordered stroke A follows stroke B")
	_check(stack.get_layer("distort").layer_inset_pixels == 6.0, "reordering updates only distort's local aperture")
	_check(is_equal_approx(media.content_inset_pixels, 12.0), "reorder preserves total advancing depth")

	var focus_stack := EffectStack.new()
	var focus_media := MediaContainer.new()
	focus_media.bounds = media.bounds
	focus_stack.initialize(focus_media, [{
		"layer_id": "focus_stroke_a",
		"effect_id": "stroke",
		"target_layer_id": "stroke_a",
		"settings": {"stroke_width_ratio": 0.04},
	}, {
		"layer_id": "focus_stroke_b",
		"effect_id": "stroke",
		"target_layer_id": "stroke_b",
		"settings": {"stroke_width_ratio": 0.05},
	}], "focus_card")
	_check(focus_stack.get_layer("focus_stroke_a").target_layer_id == "stroke_a", "focus override retains its explicit target")
	_check(stack.get_layer(focus_stack.get_layer("focus_stroke_a").target_layer_id) == original_a, "focus target resolves to the intended duplicate")

	var partition := GameCard._partition_focus_configs(focus_stack._effect_configs)
	_check(partition.overrides.size() == 2, "both same-type focus entries remain data-only overrides")
	_check(partition.overlays.is_empty(), "linked overrides do not become focus render layers")
	_check(stack.get_layer(partition.overrides[0].target_layer_id) == original_a, "first focus override targets only stroke A")
	_check(stack.get_layer(partition.overrides[1].target_layer_id) == original_b, "second focus override targets only stroke B")

	focus_stack.free_rids()

	stack.update_effect_configs([stroke_a, stroke_a])
	var unique_ids: Dictionary = {}
	for layer in stack._layers:
		var layer_id: String = layer.layer_id
		_check(not unique_ids.has(layer_id), "runtime reconciliation repairs duplicate layer IDs")
		unique_ids[layer_id] = true
	_check(stack._layers.size() == 2, "duplicate configs remain distinct render layers after identity repair")

	var rebound_media := MediaContainer.new()
	rebound_media.bounds = Rect2(Vector2.ZERO, Vector2(200, 100))
	stack.initialize(rebound_media, [stroke_a], "base_card")
	for effect in stack.get_effects():
		_check(effect.media_container == rebound_media, "initialize rebinds every effect to the new container")
		_check(rebound_media.changed.is_connected(effect._on_media_changed), "rebound effects receive media changes")
	stack.update_effect_configs([{
		"layer_id": "excessive_inset",
		"effect_id": "inset",
		"settings": {"inset_ratio": 0.75},
	}])
	_check(rebound_media.content_inset_pixels <= 49.5, "excessive inset is clamped to a minimal valid aperture")
	_check(rebound_media.size.x - rebound_media.get_total_inset_pixels() * 2.0 > 0.0, "clamped aperture keeps positive media width")
	_check(rebound_media.size.y - rebound_media.get_total_inset_pixels() * 2.0 > 0.0, "clamped aperture keeps positive media height")

	var avatar_stack := EffectStack.new()
	var avatar_media := MediaContainer.new()
	avatar_media.bounds = Rect2(Vector2.ZERO, Vector2(56, 56))
	avatar_stack.initialize(avatar_media, [{
		"layer_id": "avatar_ring_inset",
		"effect_id": "inset",
		"settings": {"inset_ratio": 0.07},
	}], "base_card")
	_check(is_equal_approx(avatar_media.content_inset_pixels, 56.0 * 0.07), "avatar inset survives stack geometry refresh")
	avatar_media.bounds = Rect2(Vector2.ZERO, Vector2(100, 100))
	avatar_stack.force_refresh()
	_check(is_equal_approx(avatar_media.content_inset_pixels, 7.0), "avatar inset is recomputed from ratio on resize")
	avatar_stack.free_rids()

	var crop_media := MediaContainer.new()
	crop_media.bounds = Rect2(Vector2.ZERO, Vector2(200, 100))
	var crop_image := Image.create(100, 50, false, Image.FORMAT_RGBA8)
	crop_media.texture = ImageTexture.create_from_image(crop_image)
	crop_media.content_inset_pixels = 25.0
	_check(crop_media.get_uv_scale().is_equal_approx(Vector2(1.0, 2.0 / 3.0)), "cover crop uses the symmetric content aperture")
	crop_media.wrap_inset_top_ratio = 0.25
	_check(crop_media.get_uv_scale().is_equal_approx(Vector2(1.0, 1.0 / 3.0)), "cover crop also includes directional insets")

	stack.free_rids()
	for i in 5:
		await get_tree().process_frame
	if _failures.is_empty():
		print("COMPOSITION_STACK_TEST_PASS")
		get_tree().quit(0)
	else:
		print("COMPOSITION_STACK_TEST_FAIL count=", _failures.size())
		get_tree().quit(1)
