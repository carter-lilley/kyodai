class_name LibraryFilterSheet
extends M3SideSheet

## Side sheet for library filters.
## Chip rows built from the normalized IGDB filter values (genres, game modes,
## ESRB/PEGI age ratings). Selections apply live and reset each session.

signal filters_changed(filters: Dictionary)

static var _instance: LibraryFilterSheet = null

var _selected: Dictionary = {}  # kind -> {value: true}
var _scroll: ScrollContainer = null
var _sections_vbox: VBoxContainer = null
var _clear_button: M3Button = null

func _init():
	super._init()
	persistent = true

func _ready():
	super._ready()
	_build_content()

func _build_content() -> void:
	if not _content_slot:
		return

	for child in _content_slot.get_children():
		child.queue_free()

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_content_slot.add_child(_scroll)

	_sections_vbox = VBoxContainer.new()
	_sections_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sections_vbox.add_theme_constant_override("separation", int(M3Units.dp(16)))
	_scroll.add_child(_sections_vbox)

	var loading := M3Label.new()
	loading.text = "Loading filters..."
	loading.use_on_surface_variant = true
	_sections_vbox.add_child(loading)

	# Bottom bar with clear action
	var bar := HBoxContainer.new()
	bar.alignment = BoxContainer.ALIGNMENT_END
	_clear_button = M3Button.new()
	_clear_button.text = "Clear all"
	_clear_button.button_variant = M3Button.Variant.TEXT
	_clear_button.visible = false
	_clear_button.pressed.connect(_on_clear_all)
	bar.add_child(_clear_button)
	_content_slot.add_child(bar)

func reload_options() -> void:
	"""Fetch distinct filter values and rebuild the chip rows."""
	if not DataManager or not DataManager.is_database_ready():
		return
	var options: Dictionary = DataManager.get_filter_options()
	_populate(options)

func _populate(options: Dictionary) -> void:
	if not _sections_vbox or not is_instance_valid(_sections_vbox):
		return
	for child in _sections_vbox.get_children():
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
		_sections_vbox.add_child(empty)
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

func _make_section(title: String) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", int(M3Units.dp(8)))
	var header := M3Label.new()
	header.text = title
	header.label_style = M3Label.Style.TITLE_MEDIUM
	section.add_child(header)
	_sections_vbox.add_child(section)
	return section

func _add_play_state_section(flags: Array, statuses: Array) -> void:
	if flags.is_empty() and statuses.is_empty():
		return
	var section := _make_section("Play State")
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", int(M3Units.dp(8)))
	flow.add_theme_constant_override("v_separation", int(M3Units.dp(8)))
	section.add_child(flow)
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
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", int(M3Units.dp(8)))
	flow.add_theme_constant_override("v_separation", int(M3Units.dp(8)))
	section.add_child(flow)
	for value in values:
		_add_chip(kind, str(value), flow)

func _add_chip_subgroup(section: VBoxContainer, title: String, kind: String, values: Array) -> void:
	var sub := M3Label.new()
	sub.text = title
	sub.label_style = M3Label.Style.LABEL_SMALL
	sub.use_on_surface_variant = true
	section.add_child(sub)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", int(M3Units.dp(8)))
	flow.add_theme_constant_override("v_separation", int(M3Units.dp(8)))
	section.add_child(flow)
	for value in values:
		_add_chip(kind, str(value), flow)

func _add_chip(kind: String, value: String, flow: HFlowContainer, display_text: String = "") -> void:
	var chip := M3Chip.new()
	chip.chip_variant = M3Chip.ChipVariant.FILTER
	chip.text = display_text if display_text != "" else value
	# Set checked before connecting so no spurious toggled fires.
	chip.checked = _selected.get(kind, {}).has(value)
	chip.toggled.connect(_on_chip_toggled.bind(kind, value))
	flow.add_child(chip)

func _on_chip_toggled(pressed: bool, kind: String, value: String) -> void:
	if not _selected.has(kind):
		_selected[kind] = {}
	if pressed:
		_selected[kind][value] = true
	else:
		_selected[kind].erase(value)
	_update_clear_button()
	filters_changed.emit(get_active_filters())

func _on_clear_all() -> void:
	_selected.clear()
	_update_clear_button()
	# Rebuild chips to reset their checked state without a toggled signal storm.
	reload_options()
	filters_changed.emit({})

func _update_clear_button() -> void:
	if _clear_button:
		_clear_button.visible = not get_active_filters().is_empty()

func get_active_filters() -> Dictionary:
	var out: Dictionary = {}
	for kind in _selected:
		var values := (_selected[kind] as Dictionary).keys()
		if not values.is_empty():
			out[kind] = values
	return out

static func prepare() -> void:
	"""Pre-create the sheet so the first open doesn't stutter."""
	_ensure_instance(true)

static func show_sheet() -> LibraryFilterSheet:
	_ensure_instance(false)

	_instance.headline_text = "Filters"
	_instance.sheet_variant = Variant.MODAL
	_instance.show_overlay()
	_instance.reload_options()
	return _instance

static func cleanup_instance() -> void:
	if _instance != null and is_instance_valid(_instance):
		if _instance.get_parent() == null:
			_instance.free()
	_instance = null

static func _ensure_instance(deferred_add: bool = false) -> void:
	if _instance != null and is_instance_valid(_instance):
		return

	_instance = LibraryFilterSheet.new()
	_instance.headline_text = "Filters"
	_instance.sheet_variant = Variant.MODAL
	_instance.persistent = true

	# Add to the overlay parent so _ready() runs and the UI is built in advance.
	# _ready() sets visible=false, so it stays hidden until show_sheet().
	# Use call_deferred when prepare() is called during a parent's _ready().
	var parent = M3Overlay.get_overlay_parent()
	if parent and _instance.get_parent() == null:
		if deferred_add:
			parent.add_child.call_deferred(_instance)
		else:
			parent.add_child(_instance)
