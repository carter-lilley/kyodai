#platforms_settings_view.gd
class_name PlatformsSettingsView
extends View

@onready var _scroll_container: ScrollContainer = $ScrollContainer
@onready var _platforms_container: VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer
@onready var _settings_row: HFlowContainer = $ScrollContainer/MarginContainer/VBoxContainer/HboxSettingsRow
@onready var _cards_left: VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer/CardsHBox/CardsLeft
@onready var _cards_right: VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer/CardsHBox/CardsRight

var _platforms_data: Array = []
var _platform_cards: Dictionary = {}  # slug -> PlatformCard
var _is_fetching_platforms: bool = false
var _fetch_generation: int = 0  # incremented each fetch to discard stale async callbacks

# Track platform selection state for lock-in behavior
var _sync_triggered: bool = false  # Tracks if sync button was pressed
var _last_active_platform_slug: String = ""  # Tracks last platform user interacted with
var _was_narrow: bool = false
var _is_initializing: bool = false

var _romm_connection_panel: RommConnectionPanel = null

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
	_is_initializing = true

	# Connect M3 checkbox signals and set initial values from settings
	var m3_dup_covers: M3Checkbox = _platforms_container.get_node("HboxSettingsRow/VboxCoverSettings/M3Checkbox_DuplicateCovers")
	var fold_covers_setting = DataManager.get_setting("fold_duplicate_covers")
	m3_dup_covers.set_block_signals(true)
	m3_dup_covers.button_pressed = fold_covers_setting.value if fold_covers_setting else false
	m3_dup_covers.set_block_signals(false)
	m3_dup_covers.toggled.connect(_on_fold_covers_toggled)

	var m3_hide: M3Checkbox = _platforms_container.get_node("HboxSettingsRow/VboxCoverSettings/M3Checkbox_Hide")
	var hide_no_covers_setting = DataManager.get_setting("hide_games_without_covers")
	m3_hide.set_block_signals(true)
	m3_hide.button_pressed = hide_no_covers_setting.value if hide_no_covers_setting else true
	m3_hide.set_block_signals(false)
	m3_hide.toggled.connect(_on_hide_no_covers_toggled)

	var m3_siblings: M3Checkbox = _platforms_container.get_node("HboxSettingsRow/VboxCoverSettings/M3Checkbox_Siblings")
	var fold_romm_setting = DataManager.get_setting("fold_romm_siblings")
	m3_siblings.set_block_signals(true)
	m3_siblings.button_pressed = fold_romm_setting.value if fold_romm_setting else true
	m3_siblings.set_block_signals(false)
	m3_siblings.toggled.connect(_on_fold_romm_siblings_toggled)

	# Add reusable RomM connection panel to the settings row
	_romm_connection_panel = RommConnectionPanel.new()
	_romm_connection_panel.test_button_text = "Test"
	_romm_connection_panel.test_button_size = M3Button.Size.SMALL
	_romm_connection_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_romm_connection_panel.connection_succeeded.connect(_on_romm_connection_succeeded)
	_settings_row.add_child(_romm_connection_panel)

	_is_initializing = false

	# Connect button signals
	var check_updates_button: M3Button = _platforms_container.get_node("HboxButtonRow/M3Button_CheckUpdates")
	check_updates_button.pressed.connect(_on_check_updates_pressed)

	var select_all_button: M3Button = _platforms_container.get_node("HboxButtonRow/M3Button_SelectAll")
	select_all_button.pressed.connect(_on_select_all_pressed)

	var sync_button: M3Button = _platforms_container.get_node("HboxButtonRow/M3ButtonGroup/M3Button_Sync")
	sync_button.pressed.connect(_on_sync_pressed)

	var full_sync_button: M3Button = _platforms_container.get_node("HboxButtonRow/M3ButtonGroup/M3Button_FullSync")
	full_sync_button.pressed.connect(_on_full_sync_pressed)

	# Set initial column visibility
	_was_narrow = _is_narrow_screen()
	_update_column_visibility()
	_update_settings_row_layout()

	# Create a single shared timer to refresh all platform cards' status
	# indicators, replacing per-card timers.
	_status_poll_timer = Timer.new()
	_status_poll_timer.wait_time = 1.0
	_status_poll_timer.timeout.connect(_refresh_all_card_status)
	add_child(_status_poll_timer)
	_status_poll_timer.start()

	super._ready()

func _fetch_platforms():
	if _is_fetching_platforms:
		return
	_is_fetching_platforms = true
	_fetch_generation += 1
	var current_generation = _fetch_generation

	# Clear existing platform cards and any transient error UI (keep UI controls)
	_clear_error_ui()
	for child in _platforms_container.get_children():
		if child.name in ["InfoLabel", "HboxSettingsRow", "HboxButtonRow", "CardsHBox"]:
			continue
		# Remove any other dynamically added widgets that didn't get cleaned up
		child.queue_free()
	_return_all_cards()
	if _active_batch_id != -1:
		MemorySubManager.cancel_batch(_active_batch_id)
		_active_batch_id = -1

	# Show loading indicator
	var loading_label = M3Label.new()
	loading_label.text = "Loading platforms..."
	loading_label.name = "LoadingLabel"
	_platforms_container.add_child(loading_label)

	# Make sure the loading label sits right above the cards
	var cards_index = _platforms_container.get_node("CardsHBox").get_index()
	_platforms_container.move_child(loading_label, cards_index)

	SystemManager.network.fetch_platforms(func(data, error):
		# Guard against callbacks from a fetch that was started before the view
		# was removed from the tree (e.g. user closed settings quickly).
		if current_generation != _fetch_generation or not is_inside_tree():
			_is_fetching_platforms = false
			for child in _platforms_container.get_children():
				if child.name == "LoadingLabel":
					child.queue_free()
					break
			return

		# Remove loading label
		for child in _platforms_container.get_children():
			if child.name == "LoadingLabel":
				child.queue_free()
				break

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

			_load_platforms_from_database()
			_is_fetching_platforms = false
			return

		if not data is Array:
			push_error("[PlatformsSettingsView] Unexpected platform data format")
			_is_fetching_platforms = false
			return

		_platforms_data = data
		var enabled_platforms = _get_enabled_platforms()
		var fetched_slugs: Array[String] = []

		# Collect unique emulators and pre-validate them once.
		# Also cache emulator lists per platform and default core ids so cards
		# don't re-query the registry.
		var unique_emulators: Array[String] = []
		var emulator_platforms: Dictionary = {}  # emulator_id -> Array[slug]
		var platform_emulator_cache: Dictionary = {}
		var platform_default_core_cache: Dictionary = {}

		for platform_data in data:
			if not platform_data is Dictionary:
				continue

			var slug = platform_data.get("slug", "")
			if slug == "":
				continue

			# Get emulators for this platform and cache the result
			var platform_emulators = LaunchManager.get_emulators_for_platform(slug)
			platform_emulator_cache[slug] = platform_emulators
			# Cache the default RetroArch core id for this platform
			platform_default_core_cache[slug] = LaunchManager.get_default_core_id_for_platform("retroarch", slug)
			for emulator in platform_emulators:
				var emu_id = emulator.get("id", "")
				if emu_id != "" and not unique_emulators.has(emu_id):
					unique_emulators.append(emu_id)
					emulator_platforms[emu_id] = []
				if emu_id != "":
					emulator_platforms[emu_id].append(slug)

		# Pre-validate each unique emulator once
		print_verbose("[PlatformsSettingsView] Pre-validating " + str(unique_emulators.size()) + " unique emulators for " + str(data.size()) + " platforms")
		var precomputed_status: Dictionary = {}
		for emu_id in unique_emulators:
			var progress = LaunchManager.get_install_progress(emu_id)
			precomputed_status[emu_id] = progress["status"] == "complete"

		# Prepare card creation payloads so the work can be batched across frames.
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
		
		# Spread card creation across frames to avoid stuttering the UI.
		# Use SystemManager.memory's batch worker for smooth per-frame processing.
		_active_batch_id = MemorySubManager.start_batch(
			card_payloads,
			func(payload: Dictionary, _index: int) -> PlatformCard:
				return _create_platform_card(
					payload.slug,
					payload.platform_name,
					payload.romm_id,
					payload.icon_url,
					enabled_platforms,
					precomputed_status,
					platform_emulator_cache,
					platform_default_core_cache
				),
			SystemManager.memory.BatchMode.SYNC,
			3,
			func(_processed: int, _total: int):
				pass,
			func(_results: Array):
				_active_batch_id = -1
				if not is_inside_tree():
					_is_fetching_platforms = false
					_return_all_cards()
					return

				# Remove loading label now that the first batch has rendered.
				for child in _platforms_container.get_children():
					if child.name == "LoadingLabel":
						child.queue_free()
						break
				
				# Remove platforms that no longer exist on RomM
				_remove_deleted_platforms(fetched_slugs)
				
				# Update select all button text
				_update_select_all_button_text()
				
				_is_fetching_platforms = false
				
				# Populate emulator dropdowns in a second batch so the cards appear first
				# and the heavy dropdown rebuild is spread across frames.
				_active_batch_id = MemorySubManager.start_batch(
					_platform_cards.values(),
					_populate_card_dropdown,
					SystemManager.memory.BatchMode.SYNC,
					3,
					func(_processed: int, _total: int):
						pass,
					func(_dropdown_results: Array):
						_active_batch_id = -1
				)

	)
, false)  # bypass cache for explicit user-driven fetches

func _create_platform_card(slug: String, platform_name: String, romm_id: int, _icon_url: String, enabled_platforms: Dictionary, precomputed_status: Dictionary = {}, emulator_cache: Dictionary = {}, default_core_cache: Dictionary = {}) -> PlatformCard:
	var card = PlatformCardPool.get_card(PlatformCardPool.POOL_PLATFORM_SETTINGS)
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
	card.selected_emulator = emulator_id
	card.selected_core_id = core_id

	# Set registry default emulator for "Auto" display
	var registry_default = LaunchManager.get_default_emulator_for_platform(slug)
	card.registry_default_emulator = registry_default

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

	# Add to the tree immediately so cards appear progressively as they're created.
	card.visible = true
	if _is_narrow_screen():
		_cards_left.add_child(card)
	else:
		if _platform_cards.size() % 2 == 0:
			_cards_left.add_child(card)
		else:
			_cards_right.add_child(card)
	_platform_cards[slug] = card

	return card

func _return_all_cards() -> void:
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		if card:
			PlatformCardPool.return_card(PlatformCardPool.POOL_PLATFORM_SETTINGS, card)
	_platform_cards.clear()

func _populate_card_dropdown(card: PlatformCard, _index: int = 0) -> void:
	card.populate_dropdown()

func _exit_tree() -> void:
	_return_all_cards()
	if _active_batch_id != -1:
		MemorySubManager.cancel_batch(_active_batch_id)
		_active_batch_id = -1
	if _status_poll_timer:
		_status_poll_timer.stop()
	
	# Invalidate any in-flight fetch from this view session so stale network or
	# batch callbacks don't resurrect cards after we're removed from the tree.
	_is_fetching_platforms = false
	_fetch_generation += 1
	
	# Disconnect global signals so a pooled/reused view doesn't fire handlers while off-screen
	if SystemManager.network.network_status_changed.is_connected(_on_network_status_changed):
		SystemManager.network.network_status_changed.disconnect(_on_network_status_changed)
	if LaunchManager.emulator_extraction_started.is_connected(_on_emulator_extraction_started):
		LaunchManager.emulator_extraction_started.disconnect(_on_emulator_extraction_started)
	if LaunchManager.emulator_extraction_completed.is_connected(_on_emulator_extraction_completed):
		LaunchManager.emulator_extraction_completed.disconnect(_on_emulator_extraction_completed)
	if LaunchManager.firmware_download_completed.is_connected(_on_firmware_download_completed):
		LaunchManager.firmware_download_completed.disconnect(_on_firmware_download_completed)
	if get_viewport().gui_focus_changed.is_connected(_on_focus_changed):
		get_viewport().gui_focus_changed.disconnect(_on_focus_changed)
	if SystemManager.display and SystemManager.display.viewport_size_changed.is_connected(_on_viewport_size_changed):
		SystemManager.display.viewport_size_changed.disconnect(_on_viewport_size_changed)

func _enter_tree() -> void:
	if _status_poll_timer:
		_status_poll_timer.start()
	
	# Reconnect global signals if this view instance was repooled/reparented
	if not SystemManager.network.network_status_changed.is_connected(_on_network_status_changed):
		SystemManager.network.network_status_changed.connect(_on_network_status_changed)
	if not LaunchManager.emulator_extraction_started.is_connected(_on_emulator_extraction_started):
		LaunchManager.emulator_extraction_started.connect(_on_emulator_extraction_started)
	if not LaunchManager.emulator_extraction_completed.is_connected(_on_emulator_extraction_completed):
		LaunchManager.emulator_extraction_completed.connect(_on_emulator_extraction_completed)
	if not LaunchManager.firmware_download_completed.is_connected(_on_firmware_download_completed):
		LaunchManager.firmware_download_completed.connect(_on_firmware_download_completed)
	
	var viewport = get_viewport()
	if viewport and not viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.connect(_on_focus_changed)
	
	if SystemManager.display and not SystemManager.display.viewport_size_changed.is_connected(_on_viewport_size_changed):
		SystemManager.display.viewport_size_changed.connect(_on_viewport_size_changed)

func _clear_error_ui():
	"""Remove transient platform-fetch UI (loading, error, retry, no-platforms) so they don't accumulate."""
	for child in _platforms_container.get_children():
		if child.name in ["LoadingLabel", "ErrorLabel", "RetryButton"]:
			child.queue_free()
	
	# NoPlatformsLabel is added to the card columns, not the platforms container
	for column in [_cards_left, _cards_right]:
		for child in column.get_children():
			if child.name == "NoPlatformsLabel":
				child.queue_free()

func _load_platforms_from_database():
	# Remove transient UI that may have been shown by a previous failed fetch
	_clear_error_ui()

	var platforms = DataManager.get_all_platforms()
	var enabled_platforms = _get_enabled_platforms()

	# Clear existing cards
	_return_all_cards()
	if _active_batch_id != -1:
		MemorySubManager.cancel_batch(_active_batch_id)
		_active_batch_id = -1

	# Cache emulator lists to avoid duplicate registry queries during batch creation
	var emulator_cache: Dictionary = {}
	for platform in platforms:
		var slug = platform.slug
		if slug == "":
			continue
		emulator_cache[slug] = LaunchManager.get_emulators_for_platform(slug)

	var platform_payloads: Array[Dictionary] = []
	for platform in platforms:
		var slug = platform.slug
		var platform_name = platform.name
		var icon_url = platform.icon_url

		if slug == "":
			continue

		platform_payloads.append({
			"slug": slug,
			"platform_name": platform_name,
			"icon_url": icon_url
		})

	# Spread offline card creation across frames
	_active_batch_id = MemorySubManager.start_batch(
		platform_payloads,
		func(payload: Dictionary, _index: int) -> PlatformCard:
			var card = _create_platform_card(payload.slug, payload.platform_name, 0, payload.icon_url, enabled_platforms, {}, emulator_cache)
			card.disabled = true
			card.tooltip_text = "Connect to RomM to configure this platform"
			return card,
		SystemManager.memory.BatchMode.SYNC,
		5,
		func(_processed: int, _total: int):
			pass,
		func(_results: Array):
			_active_batch_id = -1
			if not is_inside_tree():
				_return_all_cards()
				return

			if platforms.size() == 0:
				var no_platforms_label = M3Label.new()
				no_platforms_label.name = "NoPlatformsLabel"
				no_platforms_label.text = "No platforms found. Please connect to RomM to fetch platforms."
				_cards_left.add_child(no_platforms_label)
			
			# Populate emulator dropdowns in a second batch so the cards appear first
			# and the heavy dropdown rebuild is spread across frames.
			_active_batch_id = MemorySubManager.start_batch(
				_platform_cards.values(),
				_populate_card_dropdown,
				SystemManager.memory.BatchMode.SYNC,
				5,
				func(_processed: int, _total: int):
					pass,
				func(_dropdown_results: Array):
					_active_batch_id = -1
			)
	)

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
	var enabled_platforms = _get_enabled_platforms()

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
	var enabled_platforms = _get_enabled_platforms()

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
	# Refresh the platform card so the firmware indicator updates immediately
	LaunchManager.clear_firmware_cache_for_platform(platform_slug)
	var card = _platform_cards.get(platform_slug)
	if card:
		card.refresh_ui()

func _refresh_all_card_status() -> void:
	"""Refresh install/download status indicators for all platform cards."""
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		if is_instance_valid(card):
			card.refresh_ui()

func _on_check_updates_pressed():
	var check_button: Button = _platforms_container.get_node("HboxButtonRow/M3Button_CheckUpdates")
	if check_button:
		check_button.disabled = true

	var checking_notification = SystemManager.notifications.show_notification(
		"Checking emulator updates...", SystemManager.notifications.Type.INFO,
		null, 999999.0,
		Callable(), Callable(), false, true
	)

	LaunchManager.check_for_updates(func(_updated: Array, _up_to_date: Array, _failed: Array, _failed_details: Dictionary):
		SystemManager.notifications.dismiss_notification(checking_notification)

		if check_button:
			check_button.disabled = false

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
	var sync_button: M3Button = _platforms_container.get_node("HboxButtonRow/M3ButtonGroup/M3Button_Sync")
	var full_sync_button: M3Button = _platforms_container.get_node("HboxButtonRow/M3ButtonGroup/M3Button_FullSync")

	if sync_button:
		sync_button.disabled = true
	if full_sync_button:
		full_sync_button.disabled = true

	DataManager.sync_enabled_platforms(func(_success: bool, _message: String, _synced: int, _total: int):
		if sync_button:
			sync_button.disabled = false
		if full_sync_button:
			full_sync_button.disabled = false

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
	var select_all_button: M3Button = _platforms_container.get_node("HboxButtonRow/M3Button_SelectAll")
	if not select_all_button:
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
		select_all_button.text = "Select All"
		return

	select_all_button.text = "Deselect All" if all_selected else "Select All"

func _on_select_all_pressed():
	var select_all_button: M3Button = _platforms_container.get_node("HboxButtonRow/M3Button_SelectAll")
	if not select_all_button:
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
	select_all_button.text = "Deselect All" if new_state else "Select All"

func _update_settings_row_layout() -> void:
	"""Ensure the settings row flows and the RomM panel fills available width."""
	if _settings_row:
		_settings_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _romm_connection_panel:
		_romm_connection_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

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
	_update_settings_row_layout()

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

	# Refresh platform list every time the view is shown
	if not _is_fetching_platforms:
		_fetch_platforms()
	super.on_view_show()

func on_view_hide():
	_save_settings()
	super.on_view_hide()

func _on_fold_covers_toggled(enabled: bool) -> void:
	if _is_initializing:
		return
	var setting = DataManager.get_setting("fold_duplicate_covers")
	if setting:
		DataManager.set_setting(enabled, setting)

func _on_hide_no_covers_toggled(enabled: bool) -> void:
	if _is_initializing:
		return
	var setting = DataManager.get_setting("hide_games_without_covers")
	if setting:
		DataManager.set_setting(enabled, setting)

func _on_fold_romm_siblings_toggled(enabled: bool) -> void:
	if _is_initializing:
		return
	var setting = DataManager.get_setting("fold_romm_siblings")
	if setting:
		DataManager.set_setting(enabled, setting)

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
