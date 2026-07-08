class_name ShufflerConfigDialog
extends M3Dialog

signal start_session_requested(config: Dictionary)

var _platform_grid: VBoxContainer
var _cards_right: VBoxContainer
var _platform_cards: Dictionary[String, PlatformCard] = {}
var _selected_platforms: Array[String] = []
var _pending_cards: Array[PlatformCard] = []
var _active_batch_id: int = -1
var _toggle_all_button: M3Button

var _bag_size_slider: M3Slider
var _round_time_min_slider: M3Slider
var _round_time_max_slider: M3Slider

func _init():
	dialog_variant = Variant.FULL_SCREEN
	title_text = "Shuffler"
	persistent = true
	super._init()

func _ready():
	super._ready()
	
	# Reset any leftover temporary overrides from a previous session.
	if ShufflerManager:
		ShufflerManager.clear_shuffle_overrides()
	
	# Hide default title/body
	if _title_label:
		_title_label.visible = false
	if _body_label:
		_body_label.visible = false
	
	# Make sure content_slot expands horizontally and vertically so cards are
	# allocated space inside the ScrollContainer.
	content_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	
	_build_content()
	_build_actions()

func show_overlay():
	super.show_overlay()
	# Load platforms once the dialog is actually visible and laid out.
	if _platform_cards.is_empty():
		_load_after_layout()

func _load_after_layout() -> void:
	# Wait a couple of frames so the dialog and content containers have
	# authoritative sizes before inserting cards.
	await get_tree().process_frame
	await get_tree().process_frame
	_load_platforms()

func _build_content() -> void:
	# M3Dialog (FULL_SCREEN) already provides a ScrollContainer via _scroll.
	# We just add a MarginContainer directly to content_slot.
	var margin = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	margin.add_theme_constant_override("margin_left", int(M3Units.dp(24)))
	margin.add_theme_constant_override("margin_right", int(M3Units.dp(24)))
	margin.add_theme_constant_override("margin_top", int(M3Units.dp(16)))
	margin.add_theme_constant_override("margin_bottom", int(M3Units.dp(16)))
	
	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	vbox.add_theme_constant_override("separation", int(M3Units.dp(24)))
	
	# Bag size section
	var bag_size_label = _create_section_label("Bag Size")
	vbox.add_child(bag_size_label)
	
	_bag_size_slider = M3Slider.new()
	_bag_size_slider.min_value = 2
	_bag_size_slider.max_value = 12
	_bag_size_slider.step = 1
	_bag_size_slider.value = 4
	_bag_size_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_bag_size_slider)
	
	var bag_size_value_label = _create_value_label("4 games")
	_bag_size_slider.value_changed.connect(func(v): bag_size_value_label.text = str(int(v)) + " games")
	vbox.add_child(bag_size_value_label)
	
	# Round time section
	var time_label = _create_section_label("Round Time")
	vbox.add_child(time_label)
	
	var time_hbox = HBoxContainer.new()
	time_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	time_hbox.add_theme_constant_override("separation", int(M3Units.dp(16)))
	
	var min_vbox = VBoxContainer.new()
	min_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var min_label = _create_sub_label("Minimum")
	min_vbox.add_child(min_label)
	_round_time_min_slider = M3Slider.new()
	_round_time_min_slider.min_value = 10
	_round_time_min_slider.max_value = 300
	_round_time_min_slider.step = 5
	_round_time_min_slider.value = 30
	_round_time_min_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	min_vbox.add_child(_round_time_min_slider)
	var min_value_label = _create_value_label("30s")
	_round_time_min_slider.value_changed.connect(func(v): min_value_label.text = str(int(v)) + "s")
	min_vbox.add_child(min_value_label)
	time_hbox.add_child(min_vbox)
	
	var max_vbox = VBoxContainer.new()
	max_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var max_label = _create_sub_label("Maximum")
	max_vbox.add_child(max_label)
	_round_time_max_slider = M3Slider.new()
	_round_time_max_slider.min_value = 10
	_round_time_max_slider.max_value = 300
	_round_time_max_slider.step = 5
	_round_time_max_slider.value = 120
	_round_time_max_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	max_vbox.add_child(_round_time_max_slider)
	var max_value_label = _create_value_label("120s")
	_round_time_max_slider.value_changed.connect(func(v): max_value_label.text = str(int(v)) + "s")
	max_vbox.add_child(max_value_label)
	time_hbox.add_child(max_vbox)
	
	vbox.add_child(time_hbox)
	
	# Platforms section
	var platforms_header = HBoxContainer.new()
	platforms_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var platforms_label = _create_section_label("Platforms")
	platforms_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	platforms_header.add_child(platforms_label)
	
	_toggle_all_button = M3Button.new()
	_toggle_all_button.text = "Enable All"
	_toggle_all_button.button_variant = M3Button.Variant.TEXT
	_toggle_all_button.pressed.connect(_on_toggle_all_pressed)
	platforms_header.add_child(_toggle_all_button)
	
	vbox.add_child(platforms_header)
	
	var cards_hbox = HBoxContainer.new()
	cards_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cards_hbox.add_theme_constant_override("separation", int(M3Units.dp(8)))
	vbox.add_child(cards_hbox)

	_platform_grid = VBoxContainer.new()
	_platform_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_platform_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_platform_grid.add_theme_constant_override("separation", int(M3Units.dp(8)))
	cards_hbox.add_child(_platform_grid)

	var right_column = VBoxContainer.new()
	right_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_column.add_theme_constant_override("separation", int(M3Units.dp(8)))
	cards_hbox.add_child(right_column)
	_cards_right = right_column
	
	margin.add_child(vbox)
	content_slot.add_child(margin)

func _build_actions() -> void:
	add_action("Start Session", _on_start_pressed, true)
	add_action("Cancel", dismiss)

func _load_platforms() -> void:
	var platforms = DataManager.get_platforms_with_games()
	var enabled_platforms = _get_enabled_platforms()
	var platform_emulator_cache: Dictionary = {}
	var platform_default_core_cache: Dictionary = {}
	var precomputed_status: Dictionary = {}
	var unique_emulators: Array[String] = []

	for platform in platforms:
		var slug = platform["slug"]
		if slug == "":
			continue
		platform_emulator_cache[slug] = LaunchManager.get_emulators_for_platform(slug)
		platform_default_core_cache[slug] = LaunchManager.get_default_core_id_for_platform("retroarch", slug)
		for emulator in platform_emulator_cache[slug]:
			var emu_id = emulator.get("id", "")
			if emu_id != "" and not unique_emulators.has(emu_id):
				unique_emulators.append(emu_id)

	for emu_id in unique_emulators:
		var progress = LaunchManager.get_install_progress(emu_id)
		precomputed_status[emu_id] = progress["status"] == "complete"

	var card_payloads: Array[Dictionary] = []
	for platform in platforms:
		var slug: String = platform["slug"]
		var name: String = platform["name"]
		if slug == "":
			continue
		card_payloads.append({"slug": slug, "name": name})

	_active_batch_id = MemoryManager.start_batch(
		card_payloads,
		func(payload: Dictionary, _index: int) -> PlatformCard:
			return _create_platform_card(
				payload.slug,
				payload.name,
				enabled_platforms,
				precomputed_status,
				platform_emulator_cache,
				platform_default_core_cache
			),
		MemoryManager.BatchMode.SYNC,
		3,
		func(_processed: int, _total: int):
			pass,
		func(results: Array):
			_active_batch_id = -1
			if not is_inside_tree():
				_return_all_cards()
				return

			var column_index := 0
			for card in results:
				if not card is PlatformCard:
					continue
				if column_index % 2 == 0:
					_platform_grid.add_child(card)
				else:
					_cards_right.add_child(card)
				column_index += 1
				_platform_cards[card.platform_slug] = card

			_pending_cards.clear()
			_update_toggle_all_button()
	)

func _create_platform_card(
	slug: String,
	platform_name: String,
	enabled_platforms: Dictionary,
	precomputed_status: Dictionary,
	platform_emulator_cache: Dictionary,
	platform_default_core_cache: Dictionary
) -> PlatformCard:
	var card: PlatformCard = PlatformCardPool.get_card(PlatformCardPool.POOL_SHUFFLER)
	card.shuffler_mode = true
	card.platform_slug = slug
	card.platform_name = platform_name
	card.registry_default_core_id = platform_default_core_cache.get(slug, "")
	card.registry_default_emulator = LaunchManager.get_default_emulator_for_platform(slug)
	card.set_available_emulators(platform_emulator_cache.get(slug, []))

	var install_status = {}
	for emulator in platform_emulator_cache.get(slug, []):
		var emu_id = emulator.get("id", "")
		if emu_id != "":
			install_status[emu_id] = precomputed_status.get(emu_id, false)
	card.set_emulator_install_status(install_status)

	# In shuffler mode the sync toggle means "include in shuffle".
	var platform_config = enabled_platforms.get(slug, {})
	var is_enabled = false
	if platform_config is bool:
		is_enabled = platform_config
	elif platform_config is Dictionary:
		is_enabled = platform_config.get("enabled", false)
	card.is_sync_enabled = is_enabled
	if is_enabled and slug not in _selected_platforms:
		_selected_platforms.append(slug)

	var emulator_id = ""
	var core_id = ""
	if platform_config is Dictionary:
		emulator_id = platform_config.get("emulator_id", "")
		core_id = platform_config.get("core_id", "")
	card.selected_emulator = emulator_id
	card.selected_core_id = core_id

	card.sync_toggled.connect(func(enabled: bool):
		if enabled:
			if slug not in _selected_platforms:
				_selected_platforms.append(slug)
		else:
			_selected_platforms.erase(slug)
		_update_toggle_all_button()
	)

	card.emulator_changed.connect(func(emu_id: String, selected_core: String):
		if ShufflerManager:
			ShufflerManager.set_shuffle_override(slug, emu_id, selected_core)
	)

	_pending_cards.append(card)
	return card

func _get_enabled_platforms() -> Dictionary:
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting and setting.value is Dictionary:
		return setting.value
	return {}

func _on_toggle_all_pressed() -> void:
	var all_selected = _selected_platforms.size() == _platform_cards.size() and _platform_cards.size() > 0
	for slug in _platform_cards:
		var card = _platform_cards[slug]
		card.set_block_signals(true)
		card.is_sync_enabled = not all_selected
		card.set_block_signals(false)
	if all_selected:
		_selected_platforms.clear()
	else:
		_selected_platforms.clear()
		for slug in _platform_cards:
			_selected_platforms.append(slug)
	_update_toggle_all_button()

func _update_toggle_all_button() -> void:
	if _toggle_all_button == null:
		return
	if _platform_cards.is_empty():
		_toggle_all_button.text = "Enable All"
		_toggle_all_button.disabled = true
	else:
		_toggle_all_button.disabled = false
		_toggle_all_button.text = "Disable All" if _selected_platforms.size() == _platform_cards.size() else "Enable All"

func _on_start_pressed() -> void:
	if _selected_platforms.is_empty():
		NotificationManager.show_notification("Please select at least one platform", NotificationManager.Type.ERROR)
		return
	
	var min_time = _round_time_min_slider.value
	var max_time = _round_time_max_slider.value
	
	if min_time > max_time:
		NotificationManager.show_notification("Minimum round time must be less than maximum", NotificationManager.Type.ERROR)
		return
	
	var config = {
		"platforms": _selected_platforms.duplicate(),
		"bag_size": int(_bag_size_slider.value),
		"round_time_min": min_time,
		"round_time_max": max_time,
	}
	
	dismiss()
	start_session_requested.emit(config)

func dismiss() -> void:
	_return_all_cards()
	super.dismiss()

func _exit_tree() -> void:
	_return_all_cards()

func _return_all_cards() -> void:
	if _active_batch_id != -1:
		MemoryManager.cancel_batch(_active_batch_id)
		_active_batch_id = -1

	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		if card:
			PlatformCardPool.return_card(PlatformCardPool.POOL_SHUFFLER, card)
	_platform_cards.clear()
	_selected_platforms.clear()

	for card in _pending_cards:
		if is_instance_valid(card):
			PlatformCardPool.return_card(PlatformCardPool.POOL_SHUFFLER, card)
	_pending_cards.clear()

func _create_section_label(text: String) -> Label:
	var label = M3Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", M3Units.dp(20))
	return label

func _create_sub_label(text: String) -> Label:
	var label = M3Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", M3Units.dp(14))
	return label

func _create_value_label(text: String) -> Label:
	var label = M3Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", M3Units.dp(14))
	return label
