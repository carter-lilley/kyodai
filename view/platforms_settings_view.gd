#platforms_settings_view.gd
class_name PlatformsSettingsView
extends View

@onready var _platforms_container: VBoxContainer = $VBoxContainer
@onready var _cards_flow: HFlowContainer = $VBoxContainer/CardsFlow

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

var _romm_connection_panel: RommConnectionPanel = null

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

# Two-phase render state: loading cards are created first (phase A), then
# populated once both creation and the DB-thread precompute finish (phase B).
var _cards_created: bool = false
var _precompute_pending: bool = false
var _precompute_result: Dictionary = {}
var _pending_payloads: Array[Dictionary] = []

## Card minimum width. The HFlowContainer wraps from this alone — actual pane
## width decides 1 vs 2 cards per row, no viewport breakpoint math.
const CARD_MIN_WIDTH_DP := 380.0

func _ready():
	view_name = "RomM"

	_platforms_container.add_theme_constant_override("separation", int(M3Units.dp(16)))
	_build_sections()

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
	for child in _cards_flow.get_children():
		if child is PlatformCard:
			child.custom_minimum_size.x = M3Units.dp(CARD_MIN_WIDTH_DP)
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
	_platforms_container.move_child(platforms_section, _cards_flow.get_index())

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
	# even on a slow or unavailable network. (Timed: a main-thread query can
	# block on the DB worker's lock; that must not hide inside a net callback.)
	var db_start_us := Time.get_ticks_usec()
	var db_platforms = _get_platforms_from_database()
	var db_us := Time.get_ticks_usec() - db_start_us
	if db_us > 16000:
		print("[PlatformsSettingsView] _get_platforms_from_database elapsed_us=", db_us)
	if not db_platforms.is_empty():
		_platforms_data = db_platforms
		_platforms_data_loaded = true
		var db_render_start_us := Time.get_ticks_usec()
		_render_platform_cards_from_data(_platforms_data)
		var db_render_us := Time.get_ticks_usec() - db_render_start_us
		if db_render_us > 16000:
			print("[PlatformsSettingsView] db render prefix elapsed_us=", db_render_us)
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
		var norm_start_us := Time.get_ticks_usec()
		var normalized_data = _normalize_platforms_data(data)
		var changed = not _platforms_data_equal(_platforms_data, normalized_data)
		var norm_us := Time.get_ticks_usec() - norm_start_us
		if norm_us > 16000:
			print("[PlatformsSettingsView] normalize+compare elapsed_us=", norm_us)

		# Only re-render if the platform list actually changed.
		if changed:
			_platforms_data = normalized_data
			_platforms_data_loaded = true
			var render_start_us := Time.get_ticks_usec()
			_render_platform_cards_from_data(_platforms_data, func():
				_is_fetching_platforms = false
				_platforms_data_dirty = false
			)
			var render_us := Time.get_ticks_usec() - render_start_us
			if render_us > 16000:
				print("[PlatformsSettingsView] network render prefix elapsed_us=", render_us)
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
	return _deduplicate_platforms_by_slug(result)

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

func _deduplicate_platforms_by_slug(data: Array) -> Array:
	"""Return a copy of the platform array with duplicate slugs collapsed.
	Keeps the first occurrence and warns so upstream data issues are visible."""
	var seen: Dictionary = {}
	var result: Array = []
	for platform_data in data:
		if not platform_data is Dictionary:
			continue
		var slug = platform_data.get("slug", "")
		if slug == "":
			continue
		if seen.has(slug):
			push_warning("[PlatformsSettingsView] Duplicate platform slug '%s' in fetched data; ignoring duplicate" % slug)
			continue
		seen[slug] = true
		result.append(platform_data)
	return result

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
	return _deduplicate_platforms_by_slug(result)

func _show_loading_indicator() -> void:
	_hide_loading_indicator()
	# Unknown-count network wait: a label + spinner is the honest placeholder.
	# Once the platform list is known, real cards render in their loading state
	# instead of fake skeleton nodes.
	var row := HBoxContainer.new()
	row.name = "LoadingIndicator"
	row.add_theme_constant_override("separation", int(M3Units.dp(12)))
	var spinner := M3Progress.new()
	spinner.mode = M3Progress.Mode.CIRCULAR
	spinner.progress_size = M3Progress.Size.SMALL
	spinner.indeterminate = true
	row.add_child(spinner)
	var label := M3Label.new()
	label.text = "Loading platforms..."
	row.add_child(label)
	_cards_flow.add_child(row)

func _hide_loading_indicator() -> void:
	# Sweep by substring: queue_free() is deferred, so a same-frame hide+show
	# can leave an auto-renamed duplicate that an exact name match would miss.
	for child in _cards_flow.get_children():
		if child.name.contains("LoadingIndicator"):
			child.queue_free()
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
	# cards we already have, skip the rebuild entirely. The HFlowContainer
	# re-wraps itself, so no re-layout work is needed here.
	if not _platform_cards.is_empty() and _cards_match_data(data):
		_hide_loading_indicator()
		_update_select_all_button_text()
		if on_complete.is_valid():
			on_complete.call()
		return

	_return_all_cards()
	_clear_error_ui()
	_hide_loading_indicator()

	_render_generation += 1
	var render_generation = _render_generation
	var enabled_platforms = _get_enabled_platforms()

	# Prepare card payloads up front: loading-state cards are created from
	# these immediately, while the heavy precompute runs on the DB thread.
	# Defensive dedup by slug: the slug is the dictionary key for card tracking,
	# so duplicates would create untracked loading cards that never populate.
	var fetched_slugs: Array[String] = []
	var card_payloads: Array[Dictionary] = []
	var payload_slugs_seen: Dictionary = {}
	for platform_data in data:
		if not platform_data is Dictionary:
			continue
		var slug = platform_data.get("slug", "")
		var platform_name = platform_data.get("name", slug)
		var romm_id = platform_data.get("id", 0)
		if slug == "" or romm_id == 0:
			continue
		if payload_slugs_seen.has(slug):
			push_warning("[PlatformsSettingsView] Skipping duplicate slug '%s' while building card payloads" % slug)
			continue
		payload_slugs_seen[slug] = true
		fetched_slugs.append(slug)
		card_payloads.append({
			"slug": slug,
			"platform_name": platform_name,
			"romm_id": romm_id,
			"icon_url": platform_data.get("icon_url", "")
		})

	print("[PlatformsSettingsView] Preparing %d card payloads; first slugs: %s" % [card_payloads.size(), ", ".join(fetched_slugs.slice(0, 10))])

	if card_payloads.is_empty():
		var no_platforms_label = M3Label.new()
		no_platforms_label.name = "NoPlatformsLabel"
		no_platforms_label.text = "No platforms found. Please connect to RomM to fetch platforms."
		_cards_flow.add_child(no_platforms_label)
		if on_complete.is_valid():
			on_complete.call()
		return

	_cards_created = false
	_precompute_pending = true
	_precompute_result = {}
	_pending_payloads = card_payloads

	# Precompute emulator lists, defaults, firmware state, and install status on
	# the DB thread so the main thread stays free while the registry/filesystem
	# lookups run. Runs in parallel with loading-card creation below.
	var data_copy: Array = data.duplicate(true)
	SystemManager.memory.queue_db_task(
		func(): return _precompute_card_data(data_copy),
		func(precomputed):
			# null when the queue dropped the task (overflow): bail with the
			# pending flag cleared so the populate batch isn't blocked forever.
			if precomputed == null:
				_precompute_pending = false
				if on_complete.is_valid():
					on_complete.call()
				return
			if render_generation != _render_generation or not is_inside_tree():
				if on_complete.is_valid():
					on_complete.call()
				return
			_precompute_result = precomputed
			_precompute_pending = false
			_maybe_start_populate_batch(render_generation, enabled_platforms, fetched_slugs, on_complete)
	)

	# Create every card in its loading state right away so the final layout
	# materializes immediately; each card flips to live content as the populate
	# batch reaches it.
	_active_batch_id = MemorySubManager.start_batch(
		card_payloads,
		func(payload: Dictionary, _index: int) -> PlatformCard:
			return _create_loading_card(payload),
		SystemManager.memory.BatchMode.SYNC,
		_get_card_batch_size(),
		func(_processed: int, _total: int):
			pass,
		func(_results: Array):
			_active_batch_id = -1
			if not is_inside_tree():
				_return_all_cards()
				if on_complete.is_valid():
					on_complete.call()
				return
			_cards_created = true
			_maybe_start_populate_batch(render_generation, enabled_platforms, fetched_slugs, on_complete)
	, _get_frame_budget_us())

func _maybe_start_populate_batch(render_generation: int, enabled_platforms: Dictionary, fetched_slugs: Array[String], on_complete: Callable) -> void:
	"""Gate for the populate batch: it needs both the loading cards created and
	the DB-thread precompute finished, whichever comes last."""
	if render_generation != _render_generation or not is_inside_tree():
		return
	if not _cards_created or _precompute_pending:
		return
	_start_populate_batch(enabled_platforms, _precompute_result, fetched_slugs, on_complete)

func _create_loading_card(payload: Dictionary) -> PlatformCard:
	"""Phase A: create a card in its loading state — final geometry, shimmering,
	non-interactive — with no emulator data yet."""
	var card: PlatformCard = PlatformCardPool.get_card(PlatformCardPool.POOL_PLATFORM_SETTINGS)
	card._bulk_reset = true
	card.begin_bulk_layout()
	card.shuffler_mode = false
	card.platform_slug = payload.slug
	card.platform_name = payload.platform_name
	card._bulk_reset = false
	card.set_loading(true)
	_register_card(card, payload.slug)
	_add_card_to_flow(card)
	card.end_bulk_layout()
	card.visible = true
	print("[PlatformsSettingsView] Created loading card for slug '%s' (name='%s', node=%s)" % [payload.slug, payload.platform_name, card.name])
	return card

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
			print("[PlatformsSettingsView] _cards_match_data: slug '%s' has no tracked card; rebuild needed" % slug)
			return false
		# Cards still in their loading state, from a cancelled batch, or with
		# unpopulated dropdowns are stale; rebuild.
		if card.is_loading() or card.get_parent() == null or card._defer_dropdown:
			print("[PlatformsSettingsView] _cards_match_data: slug '%s' card state invalid (loading=%s, no_parent=%s, defer_dropdown=%s); rebuild needed" % [slug, card.is_loading(), card.get_parent() == null, card._defer_dropdown])
			return false
		if card.platform_name != platform_data.get("name", slug):
			print("[PlatformsSettingsView] _cards_match_data: slug '%s' name mismatch ('%s' vs '%s'); rebuild needed" % [slug, card.platform_name, platform_data.get("name", slug)])
			return false
	if valid_count != _platform_cards.size():
		print("[PlatformsSettingsView] _cards_match_data: valid count mismatch (%d data vs %d cards); rebuild needed" % [valid_count, _platform_cards.size()])
		return false
	if valid_count == 0:
		return false
	return true

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

func _start_populate_batch(enabled_platforms: Dictionary, precomputed: Dictionary, fetched_slugs: Array[String], on_complete: Callable) -> void:
	"""Phase B: fill each loading card with precomputed data and flip it to live
	content, then populate dropdowns in a second batch."""
	var platform_emulator_cache: Dictionary = precomputed["emulator_cache"]
	var platform_default_core_cache: Dictionary = precomputed["default_core_cache"]
	var platform_default_emulator_cache: Dictionary = precomputed["default_emulator_cache"]
	var precomputed_status: Dictionary = precomputed["install_status"]

	# Warm firmware caches for every platform/emulator off the critical path;
	# cards' indicator lookups are cache-only, and the completion callback
	# refreshes indicators once all combos are cached.
	_warm_firmware_caches_async(platform_emulator_cache, platform_default_core_cache)

	var dropdown_batch_size = _get_dropdown_batch_size()

	_active_batch_id = MemorySubManager.start_batch(
		_pending_payloads,
		func(payload: Dictionary, _index: int) -> PlatformCard:
			var card: PlatformCard = _platform_cards.get(payload.slug)
			if card == null or not is_instance_valid(card):
				push_warning("[PlatformsSettingsView] Populate batch skipped '%s': card missing from slug map" % payload.slug)
				return null
			_populate_card(
				card,
				payload,
				enabled_platforms,
				precomputed_status,
				platform_emulator_cache,
				platform_default_core_cache,
				platform_default_emulator_cache
			)
			card.set_loading(false)
			card.end_bulk_layout()
			return card,
		SystemManager.memory.BatchMode.SYNC,
		_get_card_batch_size(),
		func(_processed: int, _total: int):
			pass,
		func(_results: Array):
			_active_batch_id = -1

			if not is_inside_tree():
				_return_all_cards()
				if on_complete.is_valid():
					on_complete.call()
				return

			# Diagnostic: report any cards that are still loading after Phase B.
			var still_loading: Array[String] = []
			for slug in _platform_cards.keys():
				var card: PlatformCard = _platform_cards[slug]
				if card and is_instance_valid(card) and card.is_loading():
					still_loading.append(slug)
			if still_loading.size() > 0:
				push_warning("[PlatformsSettingsView] Populate batch finished but %d card(s) still loading: %s" % [still_loading.size(), ", ".join(still_loading)])
				# Safety net: don't leave skeletons stuck forever. The card may be
				# incomplete, but a visible incomplete card is easier to diagnose
				# (and less confusing to users) than a permanent shimmer block.
				for slug in still_loading:
					var card: PlatformCard = _platform_cards[slug]
					if card and is_instance_valid(card):
						card.set_loading(false)

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

func _populate_card(card: PlatformCard, payload: Dictionary, enabled_platforms: Dictionary, precomputed_status: Dictionary = {}, emulator_cache: Dictionary = {}, default_core_cache: Dictionary = {}, default_emulator_cache: Dictionary = {}) -> void:
	var slug: String = payload.slug
	var romm_id: int = payload.romm_id
	# Suppress per-setter display/dropdown/status rebuilds while the card is
	# being configured; the card is refreshed once at the end instead.
	card._bulk_reset = true
	card.begin_bulk_layout()
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

	# Connect per-emulator update check button
	card.update_check_requested.connect(func(emu_id: String):
		_on_emulator_update_check_requested(emu_id, card)
	)

func _register_card(card: PlatformCard, slug: String) -> void:
	"""Register a card in the slug map without adding it to a column yet."""
	_platform_cards[slug] = card

func _add_card_to_flow(card: PlatformCard) -> void:
	"""Add an already-registered card to the flow. The fixed minimum width is
	what the HFlowContainer wraps on; EXPAND_FILL lets cards share row slack."""
	card.custom_minimum_size.x = M3Units.dp(CARD_MIN_WIDTH_DP)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards_flow.add_child(card)

func _return_all_cards() -> void:
	# Return tracked cards first
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		if card:
			PlatformCardPool.return_card(PlatformCardPool.POOL_PLATFORM_SETTINGS, card)
	_platform_cards.clear()
	_pending_payloads.clear()
	_cards_created = false
	_precompute_pending = false
	
	# Defensive: return any PlatformCard children that escaped the slug map.
	# This prevents stale untracked cards from surviving a rebuild and showing
	# up as permanent skeletons between populated cards.
	for child in _cards_flow.get_children():
		if child is PlatformCard:
			push_warning("[PlatformsSettingsView] _return_all_cards found untracked PlatformCard '%s'; returning to pool" % child.name)
			PlatformCardPool.return_card(PlatformCardPool.POOL_PLATFORM_SETTINGS, child)

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
	if LaunchManager.update and LaunchManager.update.update_session_finished.is_connected(_on_update_session_finished):
		LaunchManager.update.update_session_finished.disconnect(_on_update_session_finished)
	if DataManager.sync_completed.is_connected(_on_sync_completed):
		DataManager.sync_completed.disconnect(_on_sync_completed)

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
	if LaunchManager.update and not LaunchManager.update.update_session_finished.is_connected(_on_update_session_finished):
		LaunchManager.update.update_session_finished.connect(_on_update_session_finished)
	if not DataManager.sync_completed.is_connected(_on_sync_completed):
		DataManager.sync_completed.connect(_on_sync_completed)

func _clear_error_ui():
	"""Remove transient platform-fetch UI (loading, error, retry, no-platforms) so they don't accumulate."""
	for child in _platforms_container.get_children():
		if child.name in ["LoadingIndicator", "LoadingLabel", "ErrorLabel", "RetryButton"]:
			child.queue_free()

	# NoPlatformsLabel and the loading indicator live in the card flow, not the platforms container
	for child in _cards_flow.get_children():
		if child.name == "NoPlatformsLabel" or child.name.contains("LoadingIndicator"):
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
	else:
		var emulator_name = RegistrySubManager.get_emulator_display_name(LaunchManager.get_emulator(emulator_id), emulator_id)
		SystemManager.notifications.show_notification(emulator_name + " is already downloading", SystemManager.notifications.Type.INFO)

func _on_emulator_update_check_requested(emulator_id: String, card: PlatformCard):
	if LaunchManager.update and LaunchManager.update.is_session_active():
		SystemManager.notifications.show_notification("Emulator updates already in progress", SystemManager.notifications.Type.INFO)
		return

	# Track which platform initiated a possible update for focus restoration later
	_last_active_platform_slug = card.platform_slug

	var emulator_name = RegistrySubManager.get_emulator_display_name(LaunchManager.get_emulator(emulator_id), emulator_id)
	var checking_notification = SystemManager.notifications.show_notification(
		"Checking " + emulator_name + " for updates...", SystemManager.notifications.Type.INFO,
		null, 999999.0,
		Callable(), Callable(), false, true
	)

	LaunchManager.check_emulator_for_update(emulator_id, func(update_available: bool, error: String):
		SystemManager.notifications.dismiss_notification(checking_notification)
		if error != "":
			SystemManager.notifications.show_notification("Failed to check " + emulator_name + ": " + error, SystemManager.notifications.Type.WARNING)
		elif update_available:
			# Reuse the update session machinery (aggregate snackbar, config
			# guard, concurrency) for a single emulator.
			LaunchManager.update.begin_session([emulator_id])
		else:
			SystemManager.notifications.show_notification(emulator_name + " is up to date", SystemManager.notifications.Type.INFO)
	)

func _on_emulator_extraction_started(emulator_id: String):
	# During an update-all session, per-step card refreshes flicker the whole
	# grid - the session's update_session_finished signal refreshes once instead.
	if LaunchManager.update and LaunchManager.update.is_session_active():
		return
	# Refresh UI to show "Installing..." state for all cards using this emulator
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		var effective_emu = card.selected_emulator if card.selected_emulator != "" else card.registry_default_emulator
		if effective_emu == emulator_id:
			card.refresh_ui()

func _on_emulator_extraction_completed(emulator_id: String, _success: bool):
	# See _on_emulator_extraction_started - deferred to update_session_finished.
	if LaunchManager.update and LaunchManager.update.is_session_active():
		return
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

func _on_update_session_finished(_succeeded: Array, _failed: Array):
	# One refresh for the whole update session: recompute install statuses
	# (validation cache may hold pre-update results) and repaint every card.
	LaunchManager.clear_validation_cache()
	var all_status := {}
	for emulator in LaunchManager.get_all_emulators():
		var emu_id: String = emulator.get("id", "")
		if emu_id != "":
			all_status[emu_id] = LaunchManager.get_install_progress(emu_id)["status"] == "complete"
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		if is_instance_valid(card):
			card.set_emulator_install_status(all_status)
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
	if LaunchManager.update and LaunchManager.update.is_session_active():
		SystemManager.notifications.show_notification("Emulator updates already in progress", SystemManager.notifications.Type.INFO)
		return
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

		# When updates were found, the update session's own aggregate progress
		# snackbar takes over from here - no per-emulator "installing" message.

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
		# This runs inside the /platforms connection-check callback via the
		# signal emit — time it so a slow sync prefix (DB read, card render)
		# is attributed instead of hiding inside the net_handler frame.
		var start_us := Time.get_ticks_usec()
		_fetch_platforms()
		var elapsed_us := Time.get_ticks_usec() - start_us
		if elapsed_us > 16000:
			print("[PlatformsSettingsView] network-online _fetch_platforms sync elapsed_us=", elapsed_us)

	# Keep the indicator in sync regardless of how we got here
	if _romm_connection_panel:
		_romm_connection_panel.refresh_indicator()

func _on_romm_connection_succeeded() -> void:
	_fetch_platforms()
