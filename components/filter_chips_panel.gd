class_name FilterChipsPanel
extends VBoxContainer

## Reusable filter chip rows built from the normalized library filter values
## (play states, genres, game modes, ESRB/PEGI age ratings). Chips are
## tri-state: click once to include, again to exclude, a third time for
## neutral. Used by the library filter sheet and the shuffler config dialog.

signal filters_changed(filters: Dictionary)
signal content_rebuilt()

var _selected: Dictionary = {}  # kind -> {value: ChipState}

func _init() -> void:
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", int(M3Units.dp(16)))

func _ready() -> void:
	var loading := M3Label.new()
	loading.text = "Loading filters..."
	loading.use_on_surface_variant = true
	add_child(loading)

func refresh_scale() -> void:
	if not is_node_ready():
		return
	add_theme_constant_override("separation", int(M3Units.dp(16)))
	# Rebuilding the chip rows re-bakes the section/flow separations; _selected
	# survives, so chip states are preserved.
	load_options()

func load_options() -> void:
	"""Fetch distinct filter values and rebuild the chip rows."""
	if not DataManager or not DataManager.is_database_ready():
		return
	var options: Dictionary = DataManager.get_filter_options()
	_populate(options)

func clear_all() -> void:
	_selected.clear()
	# Rebuild chips to reset their state without a state_changed signal storm.
	load_options()
	filters_changed.emit({})

func has_active_filters() -> bool:
	return not get_active_filters().is_empty()

func get_active_filters() -> Dictionary:
	var out: Dictionary = {}
	for kind in _selected:
		var include: Array = []
		var exclude: Array = []
		for value in _selected[kind]:
			match _selected[kind][value]:
				M3Chip.ChipState.INCLUDE:
					include.append(value)
				M3Chip.ChipState.EXCLUDE:
					exclude.append(value)
		if not include.is_empty() or not exclude.is_empty():
			out[kind] = {"include": include, "exclude": exclude}
	return out

func _populate(options: Dictionary) -> void:
	for child in get_children():
		child.queue_free()

	var any_options := false
	for kind in options:
		if not (options[kind] as Array).is_empty():
			any_options = true
			break

	if not any_options:
		var empty := M3Label.new()
		empty.text = "No IGDB metadata available.\nSync your library to enable filters."
		empty.use_on_surface_variant = true
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		add_child(empty)
		content_rebuilt.emit()
		return

	_add_play_state_section(options.get("flag", []), options.get("status", []))
	_add_chip_section("Genres", "genre", options.get("genre", []))
	_add_chip_section("Game Modes", "game_mode", options.get("game_mode", []))

	var esrb: Array = options.get("esrb", [])
	var pegi: Array = options.get("pegi", [])
	if not esrb.is_empty() or not pegi.is_empty():
		var section := _make_section("Rating")
		if not esrb.is_empty():
			_add_chip_subgroup(section, "ESRB", "esrb", esrb)
		if not pegi.is_empty():
			_add_chip_subgroup(section, "PEGI", "pegi", pegi)
	content_rebuilt.emit()

func _make_section(title: String) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", int(M3Units.dp(8)))
	var header := M3Label.new()
	header.text = title
	header.label_style = M3Label.Style.TITLE_MEDIUM
	section.add_child(header)
	add_child(section)
	return section

func _add_play_state_section(flags: Array, statuses: Array) -> void:
	if flags.is_empty() and statuses.is_empty():
		return
	var section := _make_section("Play State")
	var flow := _make_flow(section)
	for value in flags:
		_add_chip("flag", str(value), flow)
	for value in statuses:
		# RomM statuses are stored lowercase ("finished"); capitalize for display
		# but keep the raw value for matching.
		_add_chip("status", str(value), flow, str(value).capitalize())

func _add_chip_section(title: String, kind: String, values: Array) -> void:
	if values.is_empty():
		return
	var section := _make_section(title)
	var flow := _make_flow(section)
	for value in values:
		_add_chip(kind, str(value), flow)

func _add_chip_subgroup(section: VBoxContainer, title: String, kind: String, values: Array) -> void:
	var sub := M3Label.new()
	sub.text = title
	sub.label_style = M3Label.Style.LABEL_SMALL
	sub.use_on_surface_variant = true
	section.add_child(sub)
	var flow := _make_flow(section)
	for value in values:
		_add_chip(kind, str(value), flow)

func _make_flow(section: VBoxContainer) -> HFlowContainer:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", int(M3Units.dp(8)))
	flow.add_theme_constant_override("v_separation", int(M3Units.dp(8)))
	section.add_child(flow)
	return flow

func _add_chip(kind: String, value: String, flow: HFlowContainer, display_text: String = "") -> void:
	var chip := M3Chip.new()
	chip.chip_variant = M3Chip.ChipVariant.FILTER
	chip.tri_state = true
	chip.text = display_text if display_text != "" else value
	# Restore state before connecting so no spurious state_changed fires.
	chip.set_chip_state(_selected.get(kind, {}).get(value, M3Chip.ChipState.NEUTRAL))
	chip.state_changed.connect(_on_chip_state_changed.bind(kind, value))
	flow.add_child(chip)

func _on_chip_state_changed(state: M3Chip.ChipState, kind: String, value: String) -> void:
	if not _selected.has(kind):
		_selected[kind] = {}
	if state == M3Chip.ChipState.NEUTRAL:
		_selected[kind].erase(value)
	else:
		_selected[kind][value] = state
	filters_changed.emit(get_active_filters())
