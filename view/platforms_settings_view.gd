#platforms_settings_view.gd
class_name PlatformsSettingsView
extends View

@onready var _scroll_container: ScrollContainer = $ScrollContainer
@onready var _platforms_container: VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer
@onready var _cards_hbox: HBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer/CardsHBox
@onready var _cards_left: VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer/CardsHBox/CardsLeft
@onready var _cards_right: VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer/CardsHBox/CardsRight

var _platforms_data: Array = []
var _platform_cards: Dictionary = {}  # slug -> PlatformCard
var _is_fetching_platforms: bool = false
var _fetch_generation: int = 0  # incremented each fetch to discard stale async callbacks
var _render_generation: int = 0  # incremented each render to discard stale precompute callbacks
var _platforms_data_dirty: bool = true  # true when cached data should be refreshed from network
var _platforms_data_loaded: bool = false  # true once we've loaded from DB or network at least once

# Track platform selection state for lock-in behavior
var _sync_triggered: bool = false  # Tracks if sync button was pressed
var _last_active_platform_slug: String = ""  # Tracks last platform user interacted with
var _was_narrow: bool = false

var _romm_connection_panel: RommConnectionPanel = null
var _loading_indicator: Control = null

# Action row buttons (built in code by _build_sections)
var _check_updates_button: M3Button = null
var _select_all_button: M3Button = null
var _sync_button: M3Button = null
var _full_sync_button: M3Button = null

# Shared timer for polling platform card install/download state. Each card used
# to create its own Timer, which added overhead when dozens of cards were built.
var _status_poll_timer: Timer = null

# Track any in-flight batched card creation so it can be cancelled if the view
# exits the tree before the batch finishes. Prevents pooled cards from being
# added to orphaned containers and leaked.
var _active_batch_id: int = -1

const NARROW_BREAKPOINT_DP := 850.0

func _is_narrow_screen() -> bool:
	if SystemManager.display:
		return SystemManager.display.is_narrow_viewport(NARROW_BREAKPOINT_DP)
	var viewport = get_viewport()
	if viewport == null:
		return true
	var viewport_width = viewport.get_visible_rect().size.x
	return viewport_width < M3Units.dp(NARROW_BREAKPOINT_DP)

func _ready():
	view_name = "RomM"

	_platforms_container.add_theme_constant_override("separation", int(M3Units.dp(16)))
	_build_sections()

	# Set initial column visibility
	_was_narrow = _is_narrow_screen()
	_update_column_visibility()

	# Create a single shared timer to refresh all platform cards' status
	# indicators, replacing per-card timers. Use autostart so it restarts itself
	# whenever the view re-enters the scene tree.
	_status_poll_timer = Timer.new()
	_status_poll_timer.wait_time = 1.0
	_status_poll_timer.autostart = true
	_status_poll_timer.timeout.connect(_refresh_all_card_status)
	add_child(_status_poll_timer)

	super._ready()

func refresh_scale() -> void:
	if not is_node_ready():
		return
	_platforms_container.add_theme_constant_override("separation", int(M3Units.dp(16)))
	# _cards_right's dp(300) width is re-baked by _update_column_visibility(),
	# which also runs on viewport resize.
	_update_column_visibility()
	if has_method("refresh_theme"):
		call("refresh_theme")

func _build_sections() -> void:
	"""Compose the page from SettingsSection cards: connection credentials,
	library display switches, and the platforms grid with its action row."""
	# --- Connection ---
	var connection_section := SettingsSection.new("Connection", "cloud-sync")
	_romm_connection_panel = RommConnectionPanel.new()
	_romm_connection_panel.test_button_text = "Test"
	_romm_connection_panel.test_button_size = M3Button.Size.SMALL
	_romm_connection_panel.show_separator = false
	_romm_connection_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_romm_connection_panel.connection_succeeded.connect(_on_romm_connection_succeeded)
	connection_section.add_content(_romm_connection_panel, false)
	_platforms_container.add_child(connection_section)
	_platforms_container.move_child(connection_section, 0)

	# --- Library display ---
	var library_menu := SettingsMenu.new()
	library_menu.add_theme_constant_override("separation", 0)
	_platforms_container.add_child(library_menu)
	_platforms_container.move_child(library_menu, 1)
	var library_vars: Array[SettingsVar] = []
	for prop in ["fold_duplicate_covers", "hide_games_without_covers", "fold_romm_siblings"]:
		var sv = DataManager.get_setting(prop)
		if sv:
			library_vars.append(sv)
	library_menu.build_controls_from_settingsvars(library_vars, "Library", "image-outline")
	library_menu.setting_changed.connect(func(value, setting): DataManager.set_setting(value, setting))

	# --- Platforms ---
	var platforms_section := SettingsSection.new("Platforms", "gamepad")
	platforms_section.add_content(_build_action_row(), false)
	_platforms_container.add_child(platforms_section)
	_platforms_container.move_child(platforms_section, _cards_hbox.get_index())

func _build_action_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", int(M3Units.dp(8)))

	_check_updates_button = M3Button.new()
	_check_updates_button.text = "Update"
	_check_updates_button.icon_name = "cloud-refresh"
	_check_updates_button.button_variant = M3Button.Variant.ELEVATED
	_check_updates_button.button_size = M3Button.Size.SMALL
	_check_updates_button.button_shape = M3Button.Shape.PILL
	_check_updates_button.m3_tooltip_text = "Check for emulator updates."
	_check_updates_button.pressed.connect(_on_check_updates_pressed)
	row.add_child(_check_updates_button)

	_select_all_button = M3Button.new()
	_select_all_button.text = "Select All"
	_select_all_button.button_variant = M3Button.Variant.TONAL
	_select_all_button.button_size = M3Button.Size.SMALL
	_select_all_button.m3_tooltip_text = "Bulk select platforms."
	_select_all_button.pressed.connect(_on_select_all_pressed)
	row.add_child(_select_all_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)

	var sync_label := M3Label.new()
	sync_label.text = "Sync:"
	sync_label.label_style = M3Label.Style.BODY_MEDIUM
	sync_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(sync_label)

	var group := M3ButtonGroup.new()
	group.mode = M3ButtonGroup.Mode.CONNECTED
	group.select_mode = M3ButtonGroup.SelectMode.NONE
	group.shape = M3ButtonGroup.Shape.ROUND

	_sync_button = M3Button.new()
	_sync_button.text = "Quick"
	_sync_button.icon_name = "sync"
	_sync_button.button_size = M3Button.Size.SMALL
	_sync_button.m3_tooltip_text = "Fetch new games and updates since last sync"
	_sync_button.pressed.connect(_on_sync_pressed)
	group.add_child(_sync_button)

	_full_sync_button = M3Button.new()
	_full_sync_button.text = "Full"
	_full_sync_button.button_size = M3Button.Size.SMALL
	_full_sync_button.m3_tooltip_text = "Clear library for full metadata refresh."
	_full_sync_button.pressed.connect(_on_full_sync_pressed)
	group.add_child(_full_sync_button)

	row.add_child(group)
	return row

func _fetch_platforms():
	if _is_fetching_platforms:
		return
	_is_fetching_platforms = true
	_fetch_generation += 1
	var current_generation = _fetch_generation

	# Load platforms from the local database first so the UI appears instantly,
	# even on a slow or unavailable network.
	var db_platforms = _get_platforms_from_database()
	if not db_platforms.is_empty():
		_platforms_data = db_platforms
		_platforms_data_loaded = true
		_render_platform_cards_from_data(_platforms_data)
	elif not _platforms_data_loaded:
		# No DB platforms yet; show a loading indicator while the network request runs.
		_show_loading_indicator()

	# Refresh from the network in the background. Use the response cache so
	# unchanged platform lists return immediately without rebuilding the UI.
	SystemManager.network.fetch_platforms(func(data, error):
		# Guard against callbacks from a fetch that was started before the view
		# was removed from the tree (e.g. user closed settings quickly).
		if current_generation != _fetch_generation or not is_inside_tree():
			_is_fetching_platforms = false
			_hide_loading_indicator()
			return

		_hide_loading_indicator()

		if error != "":
			push_error("[PlatformsSettingsView] Failed to fetch platforms: " + error)
			SystemManager.notifications.show_notification("Failed to fetch platforms: " + error, SystemManager.notifications.Type.ERROR)

			var error_label = M3Label.new()
			error_label.name = "ErrorLabel"
			error_label.text = "Failed to fetch platforms from RomM. Check connection settings."
			error_label.modulate = Color.RED
			_platforms_container.add_child(error_label)

			var retry_button = M3Button.new()
			retry_button.name = "RetryButton"
			retry_button.text = "Retry"
			retry_button.button_size = M3Button.Size.MEDIUM
			retry_button.pressed.connect(_fetch_platforms)
			_platforms_container.add_child(retry_button)

			_is_fetching_platforms = false
			return

		if not data is Array:
			push_error("[PlatformsSettingsView] Unexpected platform data format")
			_is_fetching_platforms = false
			return

		# Normalize the network response so it can be compared to the cached DB
		# data without false positives from extra RomM fields.
		var normalized_data = _normalize_platforms_data(data)

		# Only re-render if the platform list actually changed.
		if not _platforms_data_equal(_platforms_data, normalized_data):
			_platforms_data = normalized_data
			_platforms_data_loaded = true
			_render_platform_cards_from_data(_platforms_data, func():
				_is_fetching_platforms = false
				_platforms_data_dirty = false
			)
		else:
			_is_fetching_platforms = false
			_platforms_data_dirty = false
	, true)  # use cache for background refresh

func _normalize_platforms_data(data: Array) -> Array:
	"""Normalize a RomM platform response to the same shape used for DB data."""
	var result: Array = []
	for platform_data in data:
		if not platform_data is Dictionary:
			continue
		var slug = platform_data.get("slug", "")
		var platform_name = platform_data.get("name", slug)
		var romm_id = platform_data.get("id", 0)
		if slug == "" or romm_id == 0:
			continue
		result.append({
			"slug": slug,
			"name": platform_name,
			"id": romm_id,
			"icon_url": platform_data.get("icon_url", "")
		})
	return result

func _platforms_data_equal(a: Array, b: Array) -> bool:
	"""Deep-compare two platform data arrays by the fields the UI cares about."""
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if not a[i] is Dictionary or not b[i] is Dictionary:
			return false
		var ad = a[i] as Dictionary
		var bd = b[i] as Dictionary
		if ad.get("slug", "") != bd.get("slug", ""):
			return false
		if ad.get("name", "") != bd.get("name", ""):
			return false
		if ad.get("id", 0) != bd.get("id", 0):
			return false
	return true

func _get_platforms_from_database() -> Array:
	"""Return platforms stored in the local DB, normalized to the same format
	used by the live RomM response."""
	var result: Array = []
	var platforms = DataManager.get_all_platforms()
	for platform in platforms:
		var slug = platform.slug
		if slug == "":
			continue
		result.append({
			"slug": slug,
			"name": platform.name,
			"id": platform.romm_id,
			"icon_url": platform.icon_url
		})
	return result

func _show_loading_indicator() -> void:
	_hide_loading_indicator()
	# Skeleton rows mimic the platform card layout (two columns when wide) so
	# the list feels populated while the fetch/precompute runs.
	var wrapper = HBoxContainer.new()
	wrapper.name = "LoadingIndicator"
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.add_theme_constant_override("separation", 10)
	var column_count := 1 if _is_narrow_screen() else 2
	for c in range(column_count):
		var column := VBoxContainer.new()
		column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		column.add_theme_constant_override("separation", 10)
		var row_count := 4 if c == 0 else 3
		for i in range(row_count):
			var skeleton := Panel.new()
			skeleton.custom_minimum_size = Vector2(0, M3Units.dp(140))
			skeleton.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var style := StyleBoxFlat.new()
			style.bg_color = Color.WHITE
			skeleton.add_theme_stylebox_override("panel", style)
			M3Shimmer.attach(skeleton, 0.12)
			column.add_child(skeleton)
		wrapper.add_child(column)
	_platforms_container.add_child(wrapper)
	var cards_index = _platforms_container.get_node("CardsHBox").get_index()
	_platforms_container.move_child(wrapper, cards_index)
	_loading_indicator = wrapper

func _hide_loading_indicator() -> void:
	if is_instance_valid(_loading_indicator):
		_loading_indicator.queue_free()
	_loading_indicator = null
	# Sweep any stragglers. queue_free() is deferred, so a same-frame hide+show
	# can leave an auto-renamed duplicate ("@LoadingIndicator@2") that an exact
	# name match would never find.
	for child in _platforms_container.get_children():
		if child.name.contains("LoadingIndicator") or child.name == "LoadingLabel":
			child.queue_free()

func _render_platform_cards_from_data(data: Array, on_complete: Callable = Callable()) -> void:
	"""Build platform cards from the given data and add them to the tree."""
	# Cancel any active batch before rebuilding.
	if _active_batch_id != -1:
		MemorySubManager.cancel_batch(_active_batch_id)
		_active_batch_id = -1

	# Cards are kept alive across view hides. If the incoming data matches the
	# cards we already have, skip the rebuild entirely.
	if not _platform_cards.is_empty() and _cards_match_data(data):
		_update_column_visibility()
		# Re-balance columns if the narrow/wide state changed while hidden.
		_on_viewport_size_changed(Vector2.ZERO)
		_hide_loading_indicator()
		_update_select_all_button_text()
		if on_complete.is_valid():
			on_complete.call()
		return

	_return_all_cards()
	_clear_error_ui()
	_show_loading_indicator()

	_render_generation += 1
	var render_generation = _render_generation
	var enabled_platforms = _get_enabled_platforms()

	# Precompute emulator lists, defaults, firmware state, and install status on
	# the DB thread so the main thread stays free while the registry/filesystem
	# lookups run.
	var data_copy: Array = data.duplicate(true)
	SystemManager.memory.queue_db_task(
		func(): return _precompute_card_data(data_copy),
		func(precomputed: Dictionary):
			if render_generation != _render_generation or not is_inside_tree():
				if on_complete.is_valid():
					on_complete.call()
				return
			_start_card_batches(data, enabled_platforms, precomputed, on_complete)
	)

func _cards_match_data(data: Array) -> bool:
	"""True if the currently kept-alive cards fully represent the given data."""
	var valid_count := 0
	for platform_data in data:
		if not platform_data is Dictionary:
			continue
		var slug = platform_data.get("slug", "")
		var romm_id = platform_data.get("id", 0)
		if slug == "" or romm_id == 0:
			continue
		valid_count += 1
		var card: PlatformCard = _platform_cards.get(slug)
		if card == null or not is_instance_valid(card):
			return false
		# Cards from a cancelled batch are unparented or have unpopulated
		# dropdowns; treat those as stale and rebuild.
		if card.get_parent() == null or card._defer_dropdown:
			return false
		if card.platform_name != platform_data.get("name", slug):
			return false
	return valid_count == _platform_cards.size() and valid_count > 0

func _precompute_card_data(data: Array) -> Dictionary:
	"""Runs on the DB thread: gather emulator lists, defaults, firmware state,
	and install status for every platform so the main thread only does UI work."""
	var platform_emulator_cache: Dictionary = {}
	var platform_default_core_cache: Dictionary = {}
	var platform_default_emulator_cache: Dictionary = {}
	var unique_emulators: Array[String] = []

	for platform_data in data:
		if not platform_data is Dictionary:
			continue
		var slug = platform_data.get("slug", "")
		if slug == "":
			continue
		var platform_emulators = LaunchManager.get_emulators_for_platform(slug)
		platform_emulator_cache[slug] = platform_emulators
		var default_core_id = LaunchManager.get_default_core_id_for_platform("retroarch", slug)
		platform_default_core_cache[slug] = default_core_id
		var default_emulator = LaunchManager.get_default_emulator_for_platform(slug)
		platform_default_emulator_cache[slug] = default_emulator
		# Warm the firmware caches so the per-card firmware indicator refresh on
		# the main thread hits cache instead of touching the filesystem.
		LaunchManager.get_platform_firmware_expected_files(slug)
		if default_emulator != "":
			LaunchManager.is_platform_firmware_ready(slug, default_emulator, default_core_id if default_emulator == "retroarch" else "")
		for emulator in platform_emulators:
			var emu_id = emulator.get("id", "")
			if emu_id != "" and not unique_emulators.has(emu_id):
				unique_emulators.append(emu_id)

	# Pre-validate each unique emulator once (filesystem scans; cached after).
	var precomputed_status: Dictionary = {}
	for emu_id in unique_emulators:
		var progress = LaunchManager.get_install_progress(emu_id)
		precomputed_status[emu_id] = progress["status"] == "complete"

	return {
		"emulator_cache": platform_emulator_cache,
		"default_core_cache": platform_default_core_cache,
		"default_emulator_cache": platform_default_emulator_cache,
		"install_status": precomputed_status,
	}

func _start_card_batches(data: Array, enabled_platforms: Dictionary, precomputed: Dictionary, on_complete: Callable) -> void:
	"""Main-thread entry point once precomputed data is ready: create cards in
	batched chunks, then populate dropdowns in a second batch."""
	var platform_emulator_cache: Dictionary = precomputed["emulator_cache"]
	var platform_default_core_cache: Dictionary = precomputed["default_core_cache"]
	var platform_default_emulator_cache: Dictionary = precomputed["default_emulator_cache"]
	var precomputed_status: Dictionary = precomputed["install_status"]

	# Warm firmware caches for every platform/emulator off the critical path;
	# cards' indicator lookups are cache-only, and the completion callback
	# refreshes indicators once all combos are cached.
	_warm_firmware_caches_async(platform_emulator_cache, platform_default_core_cache)

	# Prepare card creation payloads so the work can be batched across frames.
	var fetched_slugs: Array[String] = []
	var card_payloads: Array[Dictionary] = []
	for platform_data in data:
		if not platform_data is Dictionary:
			continue
		var slug = platform_data.get("slug", "")
		var platform_name = platform_data.get("name", slug)
		var romm_id = platform_data.get("id", 0)
		if slug == "" or romm_id == 0:
			continue
		fetched_slugs.append(slug)
		card_payloads.append({
			"slug": slug,
			"platform_name": platform_name,
			"romm_id": romm_id,
			"icon_url": platform_data.get("icon_url", "")
		})

	if card_payloads.is_empty():
		_hide_loading_indicator()
		var no_platforms_label = M3Label.new()
		no_platforms_label.name = "NoPlatformsLabel"
		no_platforms_label.text = "No platforms found. Please connect to RomM to fetch platforms."
		_cards_left.add_child(no_platforms_label)
		if on_complete.is_valid():
			on_complete.call()
		return

	# Create AND add each card inside the budgeted batch item: the expensive
	# part of a card is the add_child _ready cascade + layout, so it must be
	# measured by the frame budget, not deferred to an unbudgeted callback.
	var card_batch_size = _get_card_batch_size()
	var dropdown_batch_size = _get_dropdown_batch_size()

	_active_batch_id = MemorySubManager.start_batch(
		card_payloads,
		func(payload: Dictionary, index: int) -> PlatformCard:
			var card = _create_platform_card(
				payload.slug,
				payload.platform_name,
				payload.romm_id,
				payload.icon_url,
				enabled_platforms,
				precomputed_status,
				platform_emulator_cache,
				platform_default_core_cache,
				platform_default_emulator_cache
			)
			_register_card(card, payload.slug)
			_add_card_to_column(card, index)
			card.end_bulk_layout()
			return card,
		SystemManager.memory.BatchMode.SYNC,
		card_batch_size,
		func(_processed: int, _total: int):
			# First chunk landed: swap the skeletons for real cards.
			_hide_loading_indicator(),
		func(_results: Array):
			_active_batch_id = -1

			if not is_inside_tree():
				_return_all_cards()
				if on_complete.is_valid():
					on_complete.call()
				return

			# Remove loading label now that the first batch has rendered.
			_hide_loading_indicator()

			# Remove platforms that no longer exist on RomM
			_remove_deleted_platforms(fetched_slugs)

			# Update select all button text
			_update_select_all_button_text()

			# Populate emulator dropdowns in a second batch so the cards appear first
			# and the heavy dropdown rebuild is spread across frames.
			var dropdown_cards: Array[PlatformCard] = []
			_active_batch_id = MemorySubManager.start_batch(
				_platform_cards.values(),
				func(card: PlatformCard, _index: int) -> PlatformCard:
					card.begin_bulk_layout()
					card.populate_dropdown()
					dropdown_cards.append(card)
					return card,
				SystemManager.memory.BatchMode.SYNC,
				dropdown_batch_size,
				func(_processed: int, _total: int):
					for card in dropdown_cards:
						card.end_bulk_layout()
					dropdown_cards.clear(),
				func(_dropdown_results: Array):
					_active_batch_id = -1
					for card in dropdown_cards:
						card.end_bulk_layout()
					dropdown_cards.clear()
					if on_complete.is_valid():
						on_complete.call()
			, _get_frame_budget_us())
	, _get_frame_budget_us())

func _warm_firmware_caches_async(emulator_cache: Dictionary, default_core_cache: Dictionary) -> void:
	"""Warm firmware-ready caches for every platform/emulator on the DB thread
	(off the card-creation critical path), then refresh card indicators once
	the lookups are all cached. Recursive directory walks never touch the main
	thread; cards use cache-only indicator lookups in the meantime."""
	var generation := _render_generation
	SystemManager.memory.queue_db_task(
		func():
			for slug in emulator_cache.keys():
				var default_core_id: String = default_core_cache.get(slug, "")
				for emulator in emulator_cache[slug]:
					var emu_id = emulator.get("id", "")
					if emu_id != "":
						LaunchManager.is_platform_firmware_ready(slug, emu_id, default_core_id if emu_id == "retroarch" else "")
			return true,
		func(_done):
			if generation != _render_generation or not is_inside_tree():
				return
			for card in _platform_cards.values():
				if is_instance_valid(card):
					card.refresh_firmware_indicator()
	)

func _create_platform_card(slug: String, platform_name: String, romm_id: int, _icon_url: String, enabled_platforms: Dictionary, precomputed_status: Dictionary = {}, emulator_cache: Dictionary = {}, default_core_cache: Dictionary = {}, default_emulator_cache: Dictionary = {}) -> PlatformCard:
	var card = PlatformCardPool.get_card(PlatformCardPool.POOL_PLATFORM_SETTINGS)
	# Suppress per-setter display/dropdown/status rebuilds while the card is
	# being configured; the card is refreshed once at the end instead.
	card._bulk_reset = true
	card.begin_bulk_layout()
	card.shuffler_mode = false
	card.platform_slug = slug
	card.platform_name = platform_name
	# Pass cached default core id so the card doesn't re-query the registry.
	if default_core_cache.has(slug):
		card.registry_default_core_id = default_core_cache[slug]

	# Set sync enabled status
	var platform_config = enabled_platforms.get(slug, {})
	var is_enabled = false
	if platform_config is bool:
		is_enabled = platform_config
	elif platform_config is Dictionary:
		is_enabled = platform_config.get("enabled", false)
	card.is_sync_enabled = is_enabled

	# Set selected emulator (user override only - empty means use registry default)
	var emulator_id = ""
	var core_id = ""
	if platform_config is Dictionary:
		emulator_id = platform_config.get("emulator_id", "")
		core_id = platform_config.get("core_id", "")
	# Drop stale selections that no longer exist on this OS
	emulator_id = LaunchManager.registry.canonicalize_emulator_id(emulator_id)
	if emulator_id != "" and not LaunchManager.registry.is_emulator_available(emulator_id):
		emulator_id = ""
	card.selected_emulator = emulator_id
	card.selected_core_id = core_id

	# Set registry default emulator for "Auto" display (precomputed on DB thread)
	card.registry_default_emulator = default_emulator_cache.get(slug, "")

	# Load available emulators for this platform (use cached lookup when available)
	var available_emulators: Array[Dictionary]
	if emulator_cache.has(slug):
		available_emulators = emulator_cache[slug]
	else:
		available_emulators = LaunchManager.get_emulators_for_platform(slug)
	card._defer_dropdown = true
	card.set_available_emulators(available_emulators)

	# Set install status for each emulator (use precomputed status if available)
	var install_status = {}
	for emulator in available_emulators:
		var emu_id = emulator.get("id", "")
		if emu_id != "":
			if precomputed_status.has(emu_id):
				# Use precomputed status (avoid redundant validation)
				install_status[emu_id] = precomputed_status[emu_id]
			else:
				# Fallback: compute status (shouldn't happen with proper precomputation)
				var progress = LaunchManager.get_install_progress(emu_id)
				install_status[emu_id] = progress["status"] == "complete"
	card.set_emulator_install_status(install_status)
	card._bulk_reset = false
	card.refresh_basic_ui()

	# Connect signals
	card.sync_toggled.connect(func(enabled: bool):
		_set_platform_enabled(slug, romm_id, enabled)
		_update_select_all_button_text()
	)

	card.emulator_changed.connect(func(emu_id: String, new_core_id: String):
		_set_platform_emulator(slug, emu_id, new_core_id)
	)

	# Connect download button
	card.download_requested.connect(func(emu_id: String):
		_on_emulator_download_requested(emu_id, card)
	)

	# Connect standalone launch button (test emulator without a game)
	card.launch_requested.connect(func(emu_id: String, _core_id: String):
		LaunchManager.launch_emulator_standalone(emu_id)
	)

	# Cards are now registered and added to the tree in bulk chunks by the caller
	# to avoid per-card layout/appearance passes and UI hitches.
	card.visible = true

	return card

func _register_card(card: PlatformCard, slug: String) -> void:
	"""Register a card in the slug map without adding it to a column yet."""
	_platform_cards[slug] = card

func _add_card_to_column(card: PlatformCard, index: int) -> void:
	"""Add an already-registered card to the left or right column based on index."""
	if _is_narrow_screen():
		_cards_left.add_child(card)
	else:
		if index % 2 == 0:
			_cards_left.add_child(card)
		else:
			_cards_right.add_child(card)

func _return_all_cards() -> void:
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		if card:
			PlatformCardPool.return_card(PlatformCardPool.POOL_PLATFORM_SETTINGS, card)
	_platform_cards.clear()

func _get_card_batch_size() -> int:
	# One card per frame on Android keeps each frame under budget; desktop can
	# afford larger chunks.
	return 1 if SystemManager.platform.is_android() else 8

func _get_frame_budget_us() -> int:
	# Per-frame main-thread time budget for batched card work. The batch always
	# processes at least one item per frame regardless, so this only paces
	# throughput — cards simply take more frames to appear instead of hitching.
	return 2500 if SystemManager.platform.is_android() else 6000

func _get_dropdown_batch_size() -> int:
	return 1 if SystemManager.platform.is_android() else 6

func _populate_card_dropdown(card: PlatformCard, _index: int = 0) -> void:
	card.populate_dropdown()

func _exit_tree() -> void:
	# Cards are intentionally kept alive (not returned to the pool) so reopening
	# the settings screen is instant; they are reused if the platform data is
	# unchanged, or returned/rebuilt by the next _render_platform_cards_from_data.
	if _active_batch_id != -1:
		MemorySubManager.cancel_batch(_active_batch_id)
		_active_batch_id = -1
	if _status_poll_timer:
		_status_poll_timer.stop()
	
	# Invalidate any in-flight fetch or precompute from this view session so
	# stale callbacks don't touch cards after we're removed from the tree.
	_is_fetching_platforms = false
	_fetch_generation += 1
	_render_generation += 1
	
	# Disconnect global signals so a pooled/reused view doesn't fire handlers while off-screen
	if SystemManager.network.network_status_changed.is_connected(_on_network_status_changed):
		SystemManager.network.network_status_changed.disconnect(_on_network_status_changed)
	if LaunchManager.emulator_extraction_started.is_connected(_on_emulator_extraction_started):
		LaunchManager.emulator_extraction_started.disconnect(_on_emulator_extraction_started)
	if LaunchManager.emulator_extraction_completed.is_connected(_on_emulator_extraction_completed):
		LaunchManager.emulator_extraction_completed.disconnect(_on_emulator_extraction_completed)
	if LaunchManager.firmware_download_completed.is_connected(_on_firmware_download_completed):
		LaunchManager.firmware_download_completed.disconnect(_on_firmware_download_completed)
	if DataManager.sync_completed.is_connected(_on_sync_completed):
		DataManager.sync_completed.disconnect(_on_sync_completed)
	if get_viewport().gui_focus_changed.is_connected(_on_focus_changed):
		get_viewport().gui_focus_changed.disconnect(_on_focus_changed)
	if SystemManager.display and SystemManager.display.viewport_size_changed.is_connected(_on_viewport_size_changed):
		SystemManager.display.viewport_size_changed.disconnect(_on_viewport_size_changed)

func _enter_tree() -> void:
	# _status_poll_timer is restarted automatically via autostart when this view
	# (and its children) re-enter the scene tree, so we don't start it manually here.
	
	# Reconnect global signals if this view instance was repooled/reparented
	if not SystemManager.network.network_status_changed.is_connected(_on_network_status_changed):
		SystemManager.network.network_status_changed.connect(_on_network_status_changed)
	if not LaunchManager.emulator_extraction_started.is_connected(_on_emulator_extraction_started):
		LaunchManager.emulator_extraction_started.connect(_on_emulator_extraction_started)
	if not LaunchManager.emulator_extraction_completed.is_connected(_on_emulator_extraction_completed):
		LaunchManager.emulator_extraction_completed.connect(_on_emulator_extraction_completed)
	if not LaunchManager.firmware_download_completed.is_connected(_on_firmware_download_completed):
		LaunchManager.firmware_download_completed.connect(_on_firmware_download_completed)
	if not DataManager.sync_completed.is_connected(_on_sync_completed):
		DataManager.sync_completed.connect(_on_sync_completed)
	
	var viewport = get_viewport()
	if viewport and not viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.connect(_on_focus_changed)
	
	if SystemManager.display and not SystemManager.display.viewport_size_changed.is_connected(_on_viewport_size_changed):
		SystemManager.display.viewport_size_changed.connect(_on_viewport_size_changed)

func _clear_error_ui():
	"""Remove transient platform-fetch UI (loading, error, retry, no-platforms) so they don't accumulate."""
	for child in _platforms_container.get_children():
		if child.name.contains("LoadingIndicator") or child.name in ["LoadingLabel", "ErrorLabel", "RetryButton"]:
			child.queue_free()
	
	# NoPlatformsLabel is added to the card columns, not the platforms container
	for column in [_cards_left, _cards_right]:
		for child in column.get_children():
			if child.name == "NoPlatformsLabel":
				child.queue_free()

func _remove_deleted_platforms(current_slugs: Array[String]):
	var enabled_platforms = _get_enabled_platforms()
	var slugs_to_remove: Array[String] = []

	for slug in enabled_platforms.keys():
		if not slug in current_slugs:
			slugs_to_remove.append(slug)
			# Remove games for this deleted platform
			DataManager.remove_platform_games(slug)

	for slug in slugs_to_remove:
		enabled_platforms.erase(slug)

	# Save updated enabled_platforms
	var setting = DataManager.get_setting("enabled_platforms")
	if setting:
		DataManager.set_setting(enabled_platforms, setting)

func _get_enabled_platforms() -> Dictionary:
	var setting = DataManager.get_setting("enabled_platforms")
	if setting and setting.value is Dictionary:
		return setting.value
	return {}

func _set_platform_enabled(slug: String, platform_id: int, enabled: bool):
	# Duplicate before mutating; see _set_platform_emulator for why.
	var enabled_platforms = _get_enabled_platforms().duplicate(true)

	# Look up the actual platform ID from our data if not provided or is 0
	var actual_platform_id = platform_id
	if actual_platform_id == 0:
		for platform_data in _platforms_data:
			if platform_data.get("slug", "") == slug:
				actual_platform_id = platform_data.get("id", 0)
				break

	# Get existing config or create new
	var config = enabled_platforms.get(slug, {})
	if config is bool:
		# Migrate old format
		config = {"id": actual_platform_id, "enabled": config, "emulator_id": "", "core_id": ""}
	elif config is Dictionary:
		config["enabled"] = enabled
		# Update ID if we found a valid one and current is 0
		if config.get("id", 0) == 0 and actual_platform_id > 0:
			config["id"] = actual_platform_id
	else:
		config = {"id": actual_platform_id, "enabled": enabled, "emulator_id": "", "core_id": ""}

	# Preserve emulator_id/core_id if they exist
	if not config.has("emulator_id"):
		config["emulator_id"] = ""
	if not config.has("core_id"):
		config["core_id"] = ""
	# Ensure ID is set (fallback to looked-up ID)
	if config.get("id", 0) == 0:
		config["id"] = actual_platform_id

	enabled_platforms[slug] = config

	var setting = DataManager.get_setting("enabled_platforms")
	if setting:
		DataManager.set_setting(enabled_platforms, setting)

func _set_platform_emulator(slug: String, emulator_id: String, core_id: String = ""):
	# Duplicate before mutating: _get_enabled_platforms() returns the live
	# setting.value reference, and in-place mutation would make set_setting's
	# change detection compare the dict to itself — never marking it dirty,
	# so save_settings() would silently skip the write.
	var enabled_platforms = _get_enabled_platforms().duplicate(true)

	# Get existing config or create new
	var config = enabled_platforms.get(slug, {})

	# Look up the actual platform ID from our data
	var platform_id = 0
	for platform_data in _platforms_data:
		if platform_data.get("slug", "") == slug:
			platform_id = platform_data.get("id", 0)
			break

	if config is bool:
		# Migrate old format - use looked-up ID
		config = {"id": platform_id, "enabled": config, "emulator_id": emulator_id, "core_id": core_id}
	elif config is Dictionary:
		config["emulator_id"] = emulator_id
		config["core_id"] = core_id
		# Ensure we have the correct ID
		if config.get("id", 0) == 0 and platform_id > 0:
			config["id"] = platform_id
	else:
		# Create new config with looked-up ID
		config = {"id": platform_id, "enabled": false, "emulator_id": emulator_id, "core_id": core_id}

	# Preserve other fields
	if not config.has("enabled"):
		config["enabled"] = false
	# Ensure ID is set (fallback to looked-up ID)
	if config.get("id", 0) == 0:
		config["id"] = platform_id

	enabled_platforms[slug] = config

	var setting = DataManager.get_setting("enabled_platforms")
	if setting:
		DataManager.set_setting(enabled_platforms, setting)

func _save_settings():
	DataManager.save_settings()

func _on_emulator_download_requested(emulator_id: String, card: PlatformCard):
	# Track which platform initiated the download for focus restoration later
	_last_active_platform_slug = card.platform_slug

	# Start the download
	var success = LaunchManager.download_emulator(emulator_id)
	if success:
		# Update install status for the emulator
		var install_status = {emulator_id: LaunchManager.scan_emulator_install_state(emulator_id)}
		card.set_emulator_install_status(install_status)
		card.refresh_ui()

func _on_emulator_extraction_started(emulator_id: String):
	# Refresh UI to show "Installing..." state for all cards using this emulator
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		var effective_emu = card.selected_emulator if card.selected_emulator != "" else card.registry_default_emulator
		if effective_emu == emulator_id:
			card.refresh_ui()

func _on_emulator_extraction_completed(emulator_id: String, _success: bool):
	# Refresh all cards that use this emulator (either explicitly or via auto)
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		var effective_emu = card.selected_emulator if card.selected_emulator != "" else card.registry_default_emulator
		if effective_emu == emulator_id:
			# Update install status
			var progress = LaunchManager.get_install_progress(emulator_id)
			var is_installed = progress["status"] == "complete"
			var install_status = {emulator_id: is_installed}
			card.set_emulator_install_status(install_status)
			card.refresh_ui()

func _on_firmware_download_completed(platform_slug: String, _success: bool):
	# Refresh the platform card so the firmware indicator updates immediately.
	LaunchManager.clear_firmware_cache_for_platform(platform_slug)
	var card = _platform_cards.get(platform_slug)
	if not card:
		return
	# Re-warm on the DB thread, then refresh: the card's indicator lookup is
	# cache-only, so the recursive filesystem walk must not run on this thread.
	var effective_emulator: String = card.selected_emulator if card.selected_emulator != "" else card.registry_default_emulator
	var core_id: String = card.selected_core_id if card.selected_emulator == "retroarch" else ""
	SystemManager.memory.queue_db_task(
		func():
			if effective_emulator != "":
				LaunchManager.is_platform_firmware_ready(platform_slug, effective_emulator, core_id)
			return true,
		func(_done):
			if is_instance_valid(card):
				card.refresh_ui()
	)

func _refresh_all_card_status() -> void:
	"""Refresh install/download status indicators for all platform cards."""
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		if is_instance_valid(card):
			card.refresh_ui()

func _on_check_updates_pressed():
	if _check_updates_button:
		_check_updates_button.disabled = true

	var checking_notification = SystemManager.notifications.show_notification(
		"Checking emulator updates...", SystemManager.notifications.Type.INFO,
		null, 999999.0,
		Callable(), Callable(), false, true
	)

	LaunchManager.check_for_updates(func(_updated: Array, _up_to_date: Array, _failed: Array, _failed_details: Dictionary):
		SystemManager.notifications.dismiss_notification(checking_notification)

		if _check_updates_button:
			_check_updates_button.disabled = false

		if _updated.size() > 0:
			SystemManager.notifications.show_notification("Updates found for %d emulator(s) - installing now..." % _updated.size(), SystemManager.notifications.Type.SUCCESS)

		if _failed.size() > 0:
			var failure_parts: Array[String] = []
			for emu_id in _failed:
				var reason = _failed_details.get(emu_id, "Unknown error")
				failure_parts.append(emu_id + " (" + reason + ")")
			var failure_msg = "Failed to check: " + ", ".join(failure_parts)
			SystemManager.notifications.show_notification(failure_msg, SystemManager.notifications.Type.WARNING)
		elif _updated.is_empty():
			SystemManager.notifications.show_notification("All emulators are up to date", SystemManager.notifications.Type.INFO)
	,
	func(completed: int, total: int):
		SystemManager.notifications.update_notification_text(
			checking_notification,
			"Checking emulator updates... (%d/%d)" % [completed, total]
		)
	)

func _on_sync_pressed():
	# Lock in the selection - sync was triggered (even if it fails, user's intent was clear)
	_sync_triggered = true

	if not SystemManager.network.is_online():
		SystemManager.notifications.show_notification("Not connected to RomM - check settings", SystemManager.notifications.Type.ERROR)
		return

	UIManager.show_confirm(
		"Sync Library?",
		"Sync enabled platforms and remove non-enabled entries. Only changed games will be updated.",
		func(): _run_sync(false),
		func(): pass
	)

func _on_full_sync_pressed():
	# Lock in the selection - sync was triggered (even if it fails, user's intent was clear)
	_sync_triggered = true

	if not SystemManager.network.is_online():
		SystemManager.notifications.show_notification("Not connected to RomM - check settings", SystemManager.notifications.Type.ERROR)
		return

	UIManager.show_confirm(
		"Full Sync Library?",
		"Sync enabled platforms and remove non-enabled entries. All platforms will be fully refreshed.",
		func(): _run_sync(true),
		func(): pass
	)

func _run_sync(force_full_sync: bool) -> void:
	if _sync_button:
		_sync_button.disabled = true
	if _full_sync_button:
		_full_sync_button.disabled = true

	DataManager.sync_enabled_platforms(func(_success: bool, _message: String, _synced: int, _total: int):
		if _sync_button:
			_sync_button.disabled = false
		if _full_sync_button:
			_full_sync_button.disabled = false

		if _success:
			if force_full_sync:
				SystemManager.notifications.show_notification("Full sync complete! %s" % _message, SystemManager.notifications.Type.SUCCESS)
			else:
				SystemManager.notifications.show_notification("Sync complete! %s" % _message, SystemManager.notifications.Type.SUCCESS)
		else:
			if force_full_sync:
				SystemManager.notifications.show_notification("Full sync failed: %s" % _message, SystemManager.notifications.Type.ERROR)
			else:
				SystemManager.notifications.show_notification("Sync failed: %s" % _message, SystemManager.notifications.Type.ERROR)
	, force_full_sync)

func _update_select_all_button_text():
	if not _select_all_button:
		return

	# Check if all platforms are currently selected
	var all_selected = true
	var has_platforms = false
	for card in _platform_cards.values():
		has_platforms = true
		if not card.is_sync_enabled:
			all_selected = false
			break

	if not has_platforms:
		_select_all_button.text = "Select All"
		return

	_select_all_button.text = "Deselect All" if all_selected else "Select All"

func _on_select_all_pressed():
	if not _select_all_button:
		return

	# Check if all platforms are currently selected
	var all_selected = true
	var has_platforms = false
	for card in _platform_cards.values():
		has_platforms = true
		if not card.is_sync_enabled:
			all_selected = false
			break

	if not has_platforms:
		return

	# Toggle all cards
	var new_state = not all_selected
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		card.is_sync_enabled = new_state

		# Find the platform ID
		var platform_id = 0
		for platform_data in _platforms_data:
			if platform_data.get("slug", "") == slug:
				platform_id = platform_data.get("id", 0)
				break

		_set_platform_enabled(slug, platform_id, new_state)

	# Update button text
	_select_all_button.text = "Deselect All" if new_state else "Select All"

func _update_column_visibility() -> void:
	var is_narrow = _is_narrow_screen()
	_cards_right.visible = not is_narrow
	if is_narrow:
		_cards_right.custom_minimum_size = Vector2.ZERO
		_cards_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		_cards_right.custom_minimum_size = Vector2(M3Units.dp(300), 0)
		_cards_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL

func _on_viewport_size_changed(_new_size: Vector2) -> void:
	"""Re-layout cards when viewport size crosses the narrow breakpoint.
	SystemManager.display debounces this signal, so this only runs after the user
	stops resizing."""
	_update_column_visibility()

	if _platform_cards.is_empty():
		return

	var is_narrow := _is_narrow_screen()
	if is_narrow == _was_narrow:
		return
	_was_narrow = is_narrow

	var has_right_cards := _cards_right.get_child_count() > 0

	if is_narrow and has_right_cards:
		# Move all cards from right to left
		for child in _cards_right.get_children():
			_cards_right.remove_child(child)
			_cards_left.add_child(child)
	elif not is_narrow and not has_right_cards and _cards_left.get_child_count() > 1:
		# Re-distribute cards evenly across both columns
		var all_cards = []
		for child in _cards_left.get_children():
			all_cards.append(child)
			_cards_left.remove_child(child)

		for i in range(all_cards.size()):
			if i % 2 == 0:
				_cards_left.add_child(all_cards[i])
			else:
				_cards_right.add_child(all_cards[i])

func refresh_cards() -> void:
	"""Refresh UI for all existing platform cards without re-fetching from network."""
	for slug in _platform_cards.keys():
		var card = _platform_cards[slug]
		if is_instance_valid(card):
			card.refresh_ui()

func restore_focus_to_last_active() -> void:
	"""Restore focus to the sync toggle of the last active platform card (e.g. after APK install)."""
	if _last_active_platform_slug.is_empty():
		return
	var card = _platform_cards.get(_last_active_platform_slug)
	if card and is_instance_valid(card):
		card.focus_sync_toggle()

func on_view_show():
	# Take snapshot of current enabled state before user makes changes
	_sync_triggered = false

	# Catch up if sync_completed fired while this view was disconnected;
	# the handler marks data dirty and starts a fetch, so the block below
	# skips its own load via the _is_fetching_platforms guard.
	_catch_up_missed_sync()

	if not _is_fetching_platforms:
		if _platforms_data_loaded and not _platforms_data_dirty:
			# Fast path: we already have fresh data, just render the cards again.
			_render_platform_cards_from_data(_platforms_data)
		else:
			# Load from the local DB first, then refresh from RomM in the background.
			_fetch_platforms()
	super.on_view_show()

func on_view_hide():
	_save_settings()
	super.on_view_hide()

func _on_sync_completed(success: bool, _message: String) -> void:
	"""When a library sync finishes, mark the cached platform list dirty so the
	platforms settings screen refreshes the next time it is visible."""
	_seen_library_generation = DataManager.library_generation
	if not success:
		return
	_platforms_data_dirty = true
	if is_inside_tree() and not _is_fetching_platforms:
		_fetch_platforms()

func _on_network_status_changed(online: bool) -> void:
	if online and not _is_fetching_platforms:
		_fetch_platforms()

	# Keep the indicator in sync regardless of how we got here
	if _romm_connection_panel:
		_romm_connection_panel.refresh_indicator()

func _on_romm_connection_succeeded() -> void:
	_fetch_platforms()

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting into a SubViewport."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return

	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)

	viewport.gui_focus_changed.connect(_on_focus_changed)

func _on_focus_changed(control: Control) -> void:
	"""Ensure focused controls are visible in the scroll container."""
	if not control:
		return
	if not is_instance_valid(_scroll_container):
		return
	if not _scroll_container.is_ancestor_of(control):
		return
	_scroll_container.ensure_control_visible(control)
