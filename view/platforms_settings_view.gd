#platforms_settings_view.gd
class_name PlatformsSettingsView
extends View

var _platforms_container: VBoxContainer
var _platforms_data: Array = []
var _platform_cards: Dictionary = {}  # slug -> PlatformCard
var _scroll_container: ScrollContainer

# Track platform selection state for lock-in behavior
var _sync_triggered: bool = false  # Tracks if sync button was pressed

func _ready():
	view_name = "Platforms"
	_build_view()
	
	# Connect to launch manager signals for extraction
	LaunchManager.emulator_extraction_started.connect(_on_emulator_extraction_started)
	LaunchManager.emulator_extraction_completed.connect(_on_emulator_extraction_completed)
	
	# Connect to viewport focus changes to ensure focused items are visible
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	super._ready()

func _build_view():
	_scroll_container = ScrollContainer.new()
	_scroll_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll_container.follow_focus = true
	add_child(_scroll_container)
	
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	_scroll_container.add_child(margin)
	
	_platforms_container = VBoxContainer.new()
	_platforms_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_platforms_container.add_theme_constant_override("separation", 10)
	margin.add_child(_platforms_container)
	
	# Add info label
	var info_label = Label.new()
	info_label.text = "Configure platform sync and emulators. Disabled platforms will have their games removed."
	info_label.name = "InfoLabel"
	info_label.add_theme_font_size_override("font_size", 14)
	_platforms_container.add_child(info_label)
	
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	_platforms_container.add_child(spacer)
	
	# Add fold duplicate covers toggle
	var fold_covers_hbox = HBoxContainer.new()
	fold_covers_hbox.name = "FoldCoversContainer"
	
	var fold_covers_checkbox = CheckBox.new()
	fold_covers_checkbox.name = "FoldCoversCheckbox"
	var fold_covers_setting = SettingsManager.get_setting("fold_duplicate_covers")
	fold_covers_checkbox.button_pressed = fold_covers_setting.value if fold_covers_setting else false
	fold_covers_checkbox.toggled.connect(_on_fold_covers_toggled)
	
	var fold_covers_label = Label.new()
	fold_covers_label.text = "Fold duplicate covers into siblings"
	fold_covers_label.tooltip_text = "During sync, games with identical cover art will be grouped together like RomM siblings"
	
	fold_covers_hbox.add_child(fold_covers_checkbox)
	fold_covers_hbox.add_child(fold_covers_label)
	_platforms_container.add_child(fold_covers_hbox)
	
	# Add hide games without covers toggle
	var hide_no_covers_hbox = HBoxContainer.new()
	hide_no_covers_hbox.name = "HideNoCoversContainer"
	
	var hide_no_covers_checkbox = CheckBox.new()
	hide_no_covers_checkbox.name = "HideNoCoversCheckbox"
	var hide_no_covers_setting = SettingsManager.get_setting("hide_games_without_covers")
	hide_no_covers_checkbox.button_pressed = hide_no_covers_setting.value if hide_no_covers_setting else true
	hide_no_covers_checkbox.toggled.connect(_on_hide_no_covers_toggled)
	
	var hide_no_covers_label = Label.new()
	hide_no_covers_label.text = "Hide games without cover art"
	hide_no_covers_label.tooltip_text = "Games without cover art will be hidden from the library view"
	
	hide_no_covers_hbox.add_child(hide_no_covers_checkbox)
	hide_no_covers_hbox.add_child(hide_no_covers_label)
	_platforms_container.add_child(hide_no_covers_hbox)
	
	# Add fold RomM siblings toggle
	var fold_romm_hbox = HBoxContainer.new()
	fold_romm_hbox.name = "FoldRommSiblingsContainer"
	
	var fold_romm_checkbox = CheckBox.new()
	fold_romm_checkbox.name = "FoldRommSiblingsCheckbox"
	var fold_romm_setting = SettingsManager.get_setting("fold_romm_siblings")
	fold_romm_checkbox.button_pressed = fold_romm_setting.value if fold_romm_setting else true
	fold_romm_checkbox.toggled.connect(_on_fold_romm_siblings_toggled)
	
	var fold_romm_label = Label.new()
	fold_romm_label.text = "Fold RomM siblings"
	fold_romm_label.tooltip_text = "RomM-designated regional variants (siblings) will be grouped under a single library entry"
	
	fold_romm_hbox.add_child(fold_romm_checkbox)
	fold_romm_hbox.add_child(fold_romm_label)
	_platforms_container.add_child(fold_romm_hbox)
	
	var spacer2 = Control.new()
	spacer2.custom_minimum_size = Vector2(0, 10)
	_platforms_container.add_child(spacer2)
	
	# Add check for updates button
	var check_updates_button = Button.new()
	check_updates_button.text = "Check for Updates"
	check_updates_button.name = "CheckUpdatesButton"
	check_updates_button.tooltip_text = "Check all installed emulators for updates and install them automatically"
	check_updates_button.pressed.connect(_on_check_updates_pressed)
	_platforms_container.add_child(check_updates_button)
	
	var spacer2b = Control.new()
	spacer2b.custom_minimum_size = Vector2(0, 10)
	_platforms_container.add_child(spacer2b)
	
	# Add select all/deselect all button
	var select_all_button = Button.new()
	select_all_button.text = "Select All"
	select_all_button.name = "SelectAllButton"
	select_all_button.pressed.connect(_on_select_all_pressed)
	_platforms_container.add_child(select_all_button)
	
	var spacer3 = Control.new()
	spacer3.custom_minimum_size = Vector2(0, 10)
	_platforms_container.add_child(spacer3)
	
	# Add sync button
	var sync_button = Button.new()
	sync_button.text = "Sync Enabled Platforms"
	sync_button.name = "SyncButton"
	sync_button.pressed.connect(_on_sync_pressed)
	_platforms_container.add_child(sync_button)
	
	# Add full sync button
	var full_sync_button = Button.new()
	full_sync_button.text = "Full Sync"
	full_sync_button.name = "FullSyncButton"
	full_sync_button.tooltip_text = "Force a complete resync of all platforms (ignores incremental sync)"
	full_sync_button.pressed.connect(_on_full_sync_pressed)
	_platforms_container.add_child(full_sync_button)
	
	var spacer4 = Control.new()
	spacer4.custom_minimum_size = Vector2(0, 20)
	_platforms_container.add_child(spacer4)

func _fetch_platforms():
	# Clear existing platform cards (keep UI controls)
	for child in _platforms_container.get_children():
		if child.name in ["InfoLabel", "SyncButton", "FullSyncButton", "SelectAllButton", "CheckUpdatesButton", "FoldCoversContainer", "HideNoCoversContainer", "FoldRommSiblingsContainer"]:
			continue
		if child is PlatformCard or child.name == "LoadingLabel" or child.name == "ErrorLabel" or child.name == "NoPlatformsLabel":
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
			NotificationManager.show_notification("Failed to fetch platforms: " + error, Notification.Type.ERROR)
			
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
			var name = platform_data.get("name", slug)
			var romm_id = platform_data.get("id", 0)
			var icon_url = platform_data.get("icon_url", "")
			
			if slug == "" or romm_id == 0:
				continue
			
			fetched_slugs.append(slug)
			
			# Create platform card with precomputed validation results
			var card = _create_platform_card(slug, name, romm_id, icon_url, enabled_platforms, precomputed_status)
			_platforms_container.add_child(card)
			_platform_cards[slug] = card
		
		# Remove platforms that no longer exist on RomM
		_remove_deleted_platforms(fetched_slugs)
		
		# Update select all button text
		_update_select_all_button_text()
	)

func _create_platform_card(slug: String, name: String, romm_id: int, icon_url: String, enabled_platforms: Dictionary, precomputed_status: Dictionary = {}) -> PlatformCard:
	var card = PlatformCard.new()
	card.platform_slug = slug
	card.platform_name = name
	
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
	for child in _platforms_container.get_children():
		if child.name in ["InfoLabel", "SyncButton", "FullSyncButton", "SelectAllButton", "CheckUpdatesButton"]:
			continue
		if child is PlatformCard:
			child.queue_free()
	_platform_cards.clear()
	
	for platform in platforms:
		var slug = platform.slug
		var name = platform.name
		var icon_url = platform.icon_url
		
		if slug == "":
			continue
		
		# Create offline card (no romm_id available)
		var card = _create_platform_card(slug, name, 0, icon_url, enabled_platforms)
		card.disabled = true
		card.tooltip_text = "Connect to RomM to configure this platform"
		_platforms_container.add_child(card)
		_platform_cards[slug] = card
	
	if platforms.size() == 0:
		var no_platforms_label = Label.new()
		no_platforms_label.name = "NoPlatformsLabel"
		no_platforms_label.text = "No platforms found. Please connect to RomM to fetch platforms."
		_platforms_container.add_child(no_platforms_label)

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
	# Start the download
	var success = await LaunchManager.download_emulator(emulator_id)
	if success:
		# Update install status for the emulator
		var install_status = {emulator_id: LaunchManager.get_emulator_install_state(emulator_id)}
		card.set_emulator_install_status(install_status)
		card.refresh_ui()

func _on_emulator_extraction_started(emulator_id: String):
	# Refresh UI to show "Installing..." state for all cards using this emulator
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		var effective_emu = card.selected_emulator if card.selected_emulator != "" else card.registry_default_emulator
		if effective_emu == emulator_id:
			card.refresh_ui()

func _on_emulator_extraction_completed(emulator_id: String, success: bool):
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
	var check_button: Button = _platforms_container.get_node("CheckUpdatesButton")
	if check_button:
		check_button.disabled = true
		check_button.text = "Checking..."
	
	NotificationManager.show_notification("Checking for emulator updates...", Notification.Type.INFO)
	
	LaunchManager.check_for_updates(func(updated: Array, up_to_date: Array, failed: Array):
		if check_button:
			check_button.disabled = false
			check_button.text = "Check for Updates"
		
		if updated.size() > 0:
			NotificationManager.show_notification("Updates found for %d emulator(s) - installing now..." % updated.size(), Notification.Type.SUCCESS)
		elif failed.size() > 0:
			NotificationManager.show_notification("Failed to check %d emulator(s)" % failed.size(), Notification.Type.WARNING)
		else:
			NotificationManager.show_notification("All emulators are up to date", Notification.Type.INFO)
	)

func _on_sync_pressed():
	# Lock in the selection - sync was triggered (even if it fails, user's intent was clear)
	_sync_triggered = true
	
	if not NetworkManager.is_online():
		NotificationManager.show_notification("Not connected to RomM - check settings", Notification.Type.ERROR)
		return
	
	var sync_button: Button = _platforms_container.get_node("SyncButton")
	
	if sync_button:
		sync_button.disabled = true
		sync_button.text = "Syncing..."
	
	DataManager.sync_enabled_platforms(func(success: bool, message: String, synced: int, total: int):
		if sync_button:
			sync_button.disabled = false
			sync_button.text = "Sync Enabled Platforms"
		
		if success:
			NotificationManager.show_notification("Sync complete! %s" % message, Notification.Type.SUCCESS)
		else:
			NotificationManager.show_notification("Sync failed: %s" % message, Notification.Type.ERROR)
	)

func _on_full_sync_pressed():
	# Lock in the selection - sync was triggered (even if it fails, user's intent was clear)
	_sync_triggered = true
	
	if not NetworkManager.is_online():
		NotificationManager.show_notification("Not connected to RomM - check settings", Notification.Type.ERROR)
		return
	
	var full_sync_button: Button = _platforms_container.get_node("FullSyncButton")
	var sync_button: Button = _platforms_container.get_node("SyncButton")
	
	if full_sync_button:
		full_sync_button.disabled = true
		full_sync_button.text = "Full Syncing..."
	
	if sync_button:
		sync_button.disabled = true
	
	# Call sync with force_full_sync = true
	DataManager.sync_enabled_platforms(func(success: bool, message: String, synced: int, total: int):
		if full_sync_button:
			full_sync_button.disabled = false
			full_sync_button.text = "Full Sync"
		
		if sync_button:
			sync_button.disabled = false
			sync_button.text = "Sync Enabled Platforms"
		
		if success:
			NotificationManager.show_notification("Full sync complete! %s" % message, Notification.Type.SUCCESS)
		else:
			NotificationManager.show_notification("Full sync failed: %s" % message, Notification.Type.ERROR)
	, true)  # true = force_full_sync

func _update_select_all_button_text():
	var select_all_button: Button = _platforms_container.get_node("SelectAllButton")
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
	var select_all_button: Button = _platforms_container.get_node("SelectAllButton")
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
