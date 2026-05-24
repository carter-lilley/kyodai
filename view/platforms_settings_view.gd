#platforms_settings_view.gd
class_name PlatformsSettingsView
extends View

@onready var _scroll_container: ScrollContainer = $ScrollContainer
@onready var _platforms_container: VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer
@onready var _cards_left: VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer/CardsHBox/CardsLeft
@onready var _cards_right: VBoxContainer = $ScrollContainer/MarginContainer/VBoxContainer/CardsHBox/CardsRight

var _platforms_data: Array = []
var _platform_cards: Dictionary = {}  # slug -> PlatformCard

# Track platform selection state for lock-in behavior
var _sync_triggered: bool = false  # Tracks if sync button was pressed
var _last_active_platform_slug: String = ""  # Tracks last platform user interacted with

const NARROW_BREAKPOINT_DP := 850.0

func _is_narrow_screen() -> bool:
	var viewport = get_viewport()
	if viewport == null:
		return true
	var viewport_width = viewport.get_visible_rect().size.x
	return viewport_width < M3Units.dp(NARROW_BREAKPOINT_DP)

func _ready():
	view_name = "RomM"
	
	# Connect M3 checkbox signals and set initial values from settings
	var m3_dup_covers: M3Checkbox = _platforms_container.get_node("HboxSettingsRow/VboxCoverSettings/M3Checkbox_DuplicateCovers")
	var fold_covers_setting = SettingsManager.get_setting("fold_duplicate_covers")
	m3_dup_covers.button_pressed = fold_covers_setting.value if fold_covers_setting else false
	m3_dup_covers.toggled.connect(_on_fold_covers_toggled)
	
	var m3_hide: M3Checkbox = _platforms_container.get_node("HboxSettingsRow/VboxCoverSettings/M3Checkbox_Hide")
	var hide_no_covers_setting = SettingsManager.get_setting("hide_games_without_covers")
	m3_hide.button_pressed = hide_no_covers_setting.value if hide_no_covers_setting else true
	m3_hide.toggled.connect(_on_hide_no_covers_toggled)
	
	var m3_siblings: M3Checkbox = _platforms_container.get_node("HboxSettingsRow/VboxCoverSettings/M3Checkbox_Siblings")
	var fold_romm_setting = SettingsManager.get_setting("fold_romm_siblings")
	m3_siblings.button_pressed = fold_romm_setting.value if fold_romm_setting else true
	m3_siblings.toggled.connect(_on_fold_romm_siblings_toggled)
	
	# Connect RomM text field signals and set initial values
	var url_field: M3TextField = _platforms_container.get_node("HboxSettingsRow/VboxRommSettings/M3TextField_URL")
	var url_setting = SettingsManager.get_setting("romm_url")
	url_field.text = url_setting.value if url_setting else ""
	url_field.text_changed.connect(_on_romm_url_changed)
	
	var user_field: M3TextField = _platforms_container.get_node("HboxSettingsRow/VboxRommSettings/M3TextField_User")
	var user_setting = SettingsManager.get_setting("romm_username")
	user_field.text = user_setting.value if user_setting else ""
	user_field.text_changed.connect(_on_romm_username_changed)
	
	var pass_field: M3TextField = _platforms_container.get_node("HboxSettingsRow/VboxRommSettings/M3TextField_Pass")
	var pass_setting = SettingsManager.get_setting("romm_password")
	pass_field.text = pass_setting.value if pass_setting else ""
	pass_field.text_changed.connect(_on_romm_password_changed)
	
	# Connect button signals
	var check_updates_button: Button = _platforms_container.get_node("HboxButtonRow/M3Button_CheckUpdates")
	check_updates_button.pressed.connect(_on_check_updates_pressed)
	
	var select_all_button: Button = _platforms_container.get_node("HboxButtonRow/M3Button_SelectAll")
	select_all_button.pressed.connect(_on_select_all_pressed)
	
	var sync_button: Button = _platforms_container.get_node("HboxButtonRow/M3ButtonGroup/M3Button_Sync")
	sync_button.pressed.connect(_on_sync_pressed)
	
	var full_sync_button: Button = _platforms_container.get_node("HboxButtonRow/M3ButtonGroup/M3Button_FullSync")
	full_sync_button.pressed.connect(_on_full_sync_pressed)
	
	# Add connection status UI below the button row
	_add_connection_status_ui()
	
	# Connect to launch manager signals for extraction
	LaunchManager.emulator_extraction_started.connect(_on_emulator_extraction_started)
	LaunchManager.emulator_extraction_completed.connect(_on_emulator_extraction_completed)
	
	# Connect to viewport focus changes to ensure focused items are visible
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	# Connect to viewport resize to update card layout
	get_viewport().size_changed.connect(_on_viewport_size_changed)
	
	# Set initial column visibility
	_update_column_visibility()
	
	super._ready()

func _fetch_platforms():
	# Clear existing platform cards (keep UI controls)
	for child in _platforms_container.get_children():
		if child.name in ["InfoLabel", "HboxSettingsRow", "HboxButtonRow", "CardsHBox"]:
			continue
		if child.name == "LoadingLabel" or child.name == "ErrorLabel" or child.name == "NoPlatformsLabel":
			child.queue_free()
	for child in _cards_left.get_children():
		child.queue_free()
	for child in _cards_right.get_children():
		child.queue_free()
	_platform_cards.clear()
	
	# Show loading indicator
	var loading_label = Label.new()
	loading_label.text = "Loading platforms..."
	loading_label.name = "LoadingLabel"
	_platforms_container.add_child(loading_label)
	
	NetworkManager.fetch_platforms(func(data, error):
		# Remove loading label
		for child in _platforms_container.get_children():
			if child.name == "LoadingLabel":
				child.queue_free()
				break
		
		if error != "":
			push_error("[PlatformsSettingsView] Failed to fetch platforms: " + error)
			NotificationManager.show_notification("Failed to fetch platforms: " + error, NotificationManager.Type.ERROR)
			
			var error_label = Label.new()
			error_label.name = "ErrorLabel"
			error_label.text = "Failed to fetch platforms from RomM. Check connection settings."
			error_label.modulate = Color.RED
			_platforms_container.add_child(error_label)
			
			var retry_button = Button.new()
			retry_button.text = "Retry"
			retry_button.pressed.connect(_fetch_platforms)
			_platforms_container.add_child(retry_button)
			
			_load_platforms_from_database()
			return
		
		if not data is Array:
			push_error("[PlatformsSettingsView] Unexpected platform data format")
			return
		
		_platforms_data = data
		var enabled_platforms = _get_enabled_platforms()
		var fetched_slugs: Array[String] = []
		
		# Collect unique emulators and pre-validate them once
		var unique_emulators: Array[String] = []
		var emulator_platforms: Dictionary = {}  # emulator_id -> Array[slug]
		
		for platform_data in data:
			if not platform_data is Dictionary:
				continue
			
			var slug = platform_data.get("slug", "")
			if slug == "":
				continue
			
			# Get emulators for this platform
			var platform_emulators = LaunchManager.get_emulators_for_platform(slug)
			for emulator in platform_emulators:
				var emu_id = emulator.get("id", "")
				if emu_id != "" and not unique_emulators.has(emu_id):
					unique_emulators.append(emu_id)
					emulator_platforms[emu_id] = []
				if emu_id != "":
					emulator_platforms[emu_id].append(slug)
		
		# Pre-validate each unique emulator once
		print("[PlatformsSettingsView] Pre-validating " + str(unique_emulators.size()) + " unique emulators for " + str(data.size()) + " platforms")
		var precomputed_status: Dictionary = {}
		for emu_id in unique_emulators:
			var progress = LaunchManager.get_install_progress(emu_id)
			precomputed_status[emu_id] = progress["status"] == "complete"
		
		# Create platform cards with precomputed status
		for platform_data in data:
			if not platform_data is Dictionary:
				continue
			
			var slug = platform_data.get("slug", "")
			var platform_name = platform_data.get("name", slug)
			var romm_id = platform_data.get("id", 0)
			var icon_url = platform_data.get("icon_url", "")
			
			if slug == "" or romm_id == 0:
				continue
			
			fetched_slugs.append(slug)
			
			# Create platform card with precomputed validation results
			var card = _create_platform_card(slug, platform_name, romm_id, icon_url, enabled_platforms, precomputed_status)
			# Distribute cards: single column on narrow screens, two columns on wide
			if _is_narrow_screen():
				_cards_left.add_child(card)
			else:
				if _platform_cards.size() % 2 == 0:
					_cards_left.add_child(card)
				else:
					_cards_right.add_child(card)
			_platform_cards[slug] = card
		
		# Remove platforms that no longer exist on RomM
		_remove_deleted_platforms(fetched_slugs)
		
		# Update select all button text
		_update_select_all_button_text()
	)

func _create_platform_card(slug: String, platform_name: String, romm_id: int, _icon_url: String, enabled_platforms: Dictionary, precomputed_status: Dictionary = {}) -> PlatformCard:
	var card = PlatformCard.new()
	card.platform_slug = slug
	card.platform_name = platform_name
	
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
	if platform_config is Dictionary:
		emulator_id = platform_config.get("emulator_id", "")
	card.selected_emulator = emulator_id
	
	# Set registry default emulator for "Auto" display
	var registry_default = LaunchManager.get_default_emulator_for_platform(slug)
	card.registry_default_emulator = registry_default
	
	# Load available emulators for this platform
	var available_emulators = LaunchManager.get_emulators_for_platform(slug)
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
	
	card.emulator_changed.connect(func(emu_id: String):
		_set_platform_emulator(slug, emu_id)
	)
	
	# Connect download button
	card.download_requested.connect(func(emu_id: String):
		_on_emulator_download_requested(emu_id, card)
	)
	
	return card

func _load_platforms_from_database():
	# Remove loading label if exists
	for child in _platforms_container.get_children():
		if child.name == "LoadingLabel":
			child.queue_free()
			break
	
	var platforms = DataManager.get_all_platforms()
	var enabled_platforms = _get_enabled_platforms()
	
	# Clear existing cards
	for child in _cards_left.get_children():
		child.queue_free()
	for child in _cards_right.get_children():
		child.queue_free()
	_platform_cards.clear()
	
	for platform in platforms:
		var slug = platform.slug
		var platform_name = platform.name
		var icon_url = platform.icon_url
		
		if slug == "":
			continue
		
		# Create offline card (no romm_id available)
		var card = _create_platform_card(slug, platform_name, 0, icon_url, enabled_platforms)
		card.disabled = true
		card.tooltip_text = "Connect to RomM to configure this platform"
		if _is_narrow_screen():
			_cards_left.add_child(card)
		else:
			if _platform_cards.size() % 2 == 0:
				_cards_left.add_child(card)
			else:
				_cards_right.add_child(card)
		_platform_cards[slug] = card
	
	if platforms.size() == 0:
		var no_platforms_label = Label.new()
		no_platforms_label.name = "NoPlatformsLabel"
		no_platforms_label.text = "No platforms found. Please connect to RomM to fetch platforms."
		_cards_left.add_child(no_platforms_label)

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
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting:
		SettingsManager.set_setting(enabled_platforms, setting)

func _get_enabled_platforms() -> Dictionary:
	var setting = SettingsManager.get_setting("enabled_platforms")
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
		config = {"id": actual_platform_id, "enabled": config, "emulator_id": ""}
	elif config is Dictionary:
		config["enabled"] = enabled
		# Update ID if we found a valid one and current is 0
		if config.get("id", 0) == 0 and actual_platform_id > 0:
			config["id"] = actual_platform_id
	else:
		config = {"id": actual_platform_id, "enabled": enabled, "emulator_id": ""}
	
	# Preserve emulator_id if it exists
	if not config.has("emulator_id"):
		config["emulator_id"] = ""
	# Ensure ID is set (fallback to looked-up ID)
	if config.get("id", 0) == 0:
		config["id"] = actual_platform_id
	
	enabled_platforms[slug] = config
	
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting:
		SettingsManager.set_setting(enabled_platforms, setting)

func _set_platform_emulator(slug: String, emulator_id: String):
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
		config = {"id": platform_id, "enabled": config, "emulator_id": emulator_id}
	elif config is Dictionary:
		config["emulator_id"] = emulator_id
		# Ensure we have the correct ID
		if config.get("id", 0) == 0 and platform_id > 0:
			config["id"] = platform_id
	else:
		# Create new config with looked-up ID
		config = {"id": platform_id, "enabled": false, "emulator_id": emulator_id}
	
	# Preserve other fields
	if not config.has("enabled"):
		config["enabled"] = false
	# Ensure ID is set (fallback to looked-up ID)
	if config.get("id", 0) == 0:
		config["id"] = platform_id
	
	enabled_platforms[slug] = config
	
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting:
		SettingsManager.set_setting(enabled_platforms, setting)

func _save_settings():
	SettingsManager.save_settings()

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
		if 			effective_emu == emulator_id:
			# Update install status
			var progress = LaunchManager.get_install_progress(emulator_id)
			var is_installed = progress["status"] == "complete"
			var install_status = {emulator_id: is_installed}
			card.set_emulator_install_status(install_status)
			card.refresh_ui()

func _on_check_updates_pressed():
	var check_button: Button = _platforms_container.get_node("HboxButtonRow/M3Button_CheckUpdates")
	if check_button:
		check_button.disabled = true
	
	NotificationManager.show_notification("Checking for emulator updates...", NotificationManager.Type.INFO)
	
	LaunchManager.check_for_updates(func(_updated: Array, _up_to_date: Array, _failed: Array):
		if check_button:
			check_button.disabled = false
		
		if _updated.size() > 0:
			NotificationManager.show_notification("Updates found for %d emulator(s) - installing now..." % _updated.size(), NotificationManager.Type.SUCCESS)
		elif _failed.size() > 0:
			NotificationManager.show_notification("Failed to check %d emulator(s)" % _failed.size(), NotificationManager.Type.WARNING)
		else:
			NotificationManager.show_notification("All emulators are up to date", NotificationManager.Type.INFO)
	)

func _on_sync_pressed():
	# Lock in the selection - sync was triggered (even if it fails, user's intent was clear)
	_sync_triggered = true
	
	if not NetworkManager.is_online():
		NotificationManager.show_notification("Not connected to RomM - check settings", NotificationManager.Type.ERROR)
		return
	
	var sync_button: Button = _platforms_container.get_node("HboxButtonRow/M3ButtonGroup/M3Button_Sync")
	
	if sync_button:
		sync_button.disabled = true
	
	DataManager.sync_enabled_platforms(func(_success: bool, _message: String, _synced: int, _total: int):
		if sync_button:
			sync_button.disabled = false
		
		if _success:
			NotificationManager.show_notification("Sync complete! %s" % _message, NotificationManager.Type.SUCCESS)
		else:
			NotificationManager.show_notification("Sync failed: %s" % _message, NotificationManager.Type.ERROR)
	)

func _on_full_sync_pressed():
	# Lock in the selection - sync was triggered (even if it fails, user's intent was clear)
	_sync_triggered = true
	
	if not NetworkManager.is_online():
		NotificationManager.show_notification("Not connected to RomM - check settings", NotificationManager.Type.ERROR)
		return
	
	var full_sync_button: Button = _platforms_container.get_node("HboxButtonRow/M3ButtonGroup/M3Button_FullSync")
	var sync_button: Button = _platforms_container.get_node("HboxButtonRow/M3ButtonGroup/M3Button_Sync")
	
	if full_sync_button:
		full_sync_button.disabled = true
	
	if sync_button:
		sync_button.disabled = true
	
	# Call sync with force_full_sync = true
	DataManager.sync_enabled_platforms(func(_success: bool, _message: String, _synced: int, _total: int):
		if full_sync_button:
			full_sync_button.disabled = false
		
		if sync_button:
			sync_button.disabled = false
		
		if _success:
			NotificationManager.show_notification("Full sync complete! %s" % _message, NotificationManager.Type.SUCCESS)
		else:
			NotificationManager.show_notification("Full sync failed: %s" % _message, NotificationManager.Type.ERROR)
	, true)  # true = force_full_sync

func _update_select_all_button_text():
	var select_all_button: Button = _platforms_container.get_node("HboxButtonRow/M3Button_SelectAll")
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
	var select_all_button: Button = _platforms_container.get_node("HboxButtonRow/M3Button_SelectAll")
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

func _update_column_visibility() -> void:
	var is_narrow = _is_narrow_screen()
	_cards_right.visible = not is_narrow
	if is_narrow:
		_cards_right.custom_minimum_size = Vector2.ZERO
		_cards_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	else:
		_cards_right.custom_minimum_size = Vector2(M3Units.dp(300), 0)
		_cards_right.size_flags_horizontal = Control.SIZE_EXPAND_FILL

func _on_viewport_size_changed() -> void:
	"""Re-layout cards when viewport size crosses the narrow breakpoint."""
	_update_column_visibility()
	
	if not _platform_cards.is_empty():
		# Check if layout mode needs to change
		var is_narrow = _is_narrow_screen()
		var has_right_cards = _cards_right.get_child_count() > 0
		
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
	_fetch_platforms()
	super.on_view_show()

func on_view_hide():
	_save_settings()
	super.on_view_hide()

func _on_fold_covers_toggled(enabled: bool) -> void:
	var setting = SettingsManager.get_setting("fold_duplicate_covers")
	if setting:
		SettingsManager.set_setting(enabled, setting)

func _on_hide_no_covers_toggled(enabled: bool) -> void:
	var setting = SettingsManager.get_setting("hide_games_without_covers")
	if setting:
		SettingsManager.set_setting(enabled, setting)

func _on_fold_romm_siblings_toggled(enabled: bool) -> void:
	var setting = SettingsManager.get_setting("fold_romm_siblings")
	if setting:
		SettingsManager.set_setting(enabled, setting)

func _on_romm_url_changed(text: String) -> void:
	var setting = SettingsManager.get_setting("romm_url")
	if setting:
		SettingsManager.set_setting(text, setting)

func _on_romm_username_changed(text: String) -> void:
	var setting = SettingsManager.get_setting("romm_username")
	if setting:
		SettingsManager.set_setting(text, setting)

func _on_romm_password_changed(text: String) -> void:
	var setting = SettingsManager.get_setting("romm_password")
	if setting:
		SettingsManager.set_setting(text, setting)

# ============================================
# CONNECTION STATUS
# ============================================

func _add_connection_status_ui():
	var container = HBoxContainer.new()
	container.name = "ConnectionStatusUI"
	container.custom_minimum_size = Vector2(0, 30)
	
	var indicator = Indicator.new()
	indicator.name = "ConnectionIndicator"
	indicator.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_child(indicator)
	
	var test_button = M3Button.new()
	test_button.name = "TestButton"
	test_button.text = "Test"
	test_button.button_size = M3Button.Size.SMALL
	container.add_child(test_button)
	
	_platforms_container.add_child(container)
	
	# Set initial status
	_update_connection_status(indicator)
	
	# Connect test button
	test_button.pressed.connect(func():
		_test_connection(indicator)
	)

func _test_connection(indicator: Indicator):
	indicator.set_status(Indicator.Status.WARNING, "Testing connection...")
	
	NetworkManager.test_connection(func(online: bool):
		if online:
			indicator.set_status(Indicator.Status.SUCCESS, "Connected and authenticated")
			NotificationManager.show_notification("Connected to RomM successfully", NotificationManager.Type.SUCCESS)
		else:
			if not NetworkManager.is_configured():
				indicator.set_status(Indicator.Status.NEUTRAL, "Not configured (check URL, username, password)")
				NotificationManager.show_notification("RomM not configured - check URL, username, password", NotificationManager.Type.ERROR)
			else:
				indicator.set_status(Indicator.Status.ERROR, "Connection failed - check credentials")
				NotificationManager.show_notification("Connection failed - check credentials", NotificationManager.Type.ERROR)
	)

func _update_connection_status(indicator: Indicator):
	if NetworkManager.is_online():
		indicator.set_status(Indicator.Status.SUCCESS, "Connected and authenticated")
	elif not NetworkManager.is_configured():
		indicator.set_status(Indicator.Status.NEUTRAL, "Not configured")
	else:
		indicator.set_status(Indicator.Status.ERROR, "Disconnected")

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
