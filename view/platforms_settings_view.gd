#platforms_settings_view.gd
class_name PlatformsSettingsView
extends View

var _platforms_container: VBoxContainer
var _platforms_data: Array = []
var _platform_cards: Dictionary = {}  # slug -> PlatformCard

func _ready():
	view_name = "Platforms"
	_build_view()
	
	# Connect to launch manager signals for extraction
	LaunchManager.emulator_extraction_started.connect(_on_emulator_extraction_started)
	LaunchManager.emulator_extraction_progress.connect(_on_emulator_extraction_progress)
	LaunchManager.emulator_extraction_completed.connect(_on_emulator_extraction_completed)
	
	super._ready()

func _build_view():
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(scroll)
	
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	scroll.add_child(margin)
	
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
	
	# Add select all/deselect all button
	var select_all_button = Button.new()
	select_all_button.text = "Select All"
	select_all_button.name = "SelectAllButton"
	select_all_button.pressed.connect(_on_select_all_pressed)
	_platforms_container.add_child(select_all_button)
	
	var spacer2 = Control.new()
	spacer2.custom_minimum_size = Vector2(0, 10)
	_platforms_container.add_child(spacer2)
	
	# Add sync button
	var sync_button = Button.new()
	sync_button.text = "Sync Enabled Platforms"
	sync_button.name = "SyncButton"
	sync_button.pressed.connect(_on_sync_pressed)
	_platforms_container.add_child(sync_button)
	
	var spacer3 = Control.new()
	spacer3.custom_minimum_size = Vector2(0, 20)
	_platforms_container.add_child(spacer3)

func _fetch_platforms():
	# Clear existing platform cards (keep UI controls)
	for child in _platforms_container.get_children():
		if child.name in ["InfoLabel", "SyncButton", "SelectAllButton"]:
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
			
			# Create platform card
			var card = _create_platform_card(slug, name, romm_id, icon_url, enabled_platforms)
			_platforms_container.add_child(card)
			_platform_cards[slug] = card
		
		# Remove platforms that no longer exist on RomM
		_remove_deleted_platforms(fetched_slugs)
		
		# Update select all button text
		_update_select_all_button_text()
	)

func _create_platform_card(slug: String, name: String, romm_id: int, icon_url: String, enabled_platforms: Dictionary) -> PlatformCard:
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
	
	# Set install status for each emulator
	var install_status = {}
	for emulator in available_emulators:
		var emu_id = emulator.get("id", "")
		if emu_id != "":
			install_status[emu_id] = LaunchManager.is_emulator_installed(emu_id)
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
		if child.name in ["InfoLabel", "SyncButton", "SelectAllButton"]:
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
	var success = LaunchManager.download_emulator(emulator_id)
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

func _on_emulator_extraction_progress(emulator_id: String, progress: float):
	# Progress is handled by notification
	pass

func _on_emulator_extraction_completed(emulator_id: String, success: bool):
	# Refresh all cards that use this emulator (either explicitly or via auto)
	for slug in _platform_cards.keys():
		var card: PlatformCard = _platform_cards[slug]
		var effective_emu = card.selected_emulator if card.selected_emulator != "" else card.registry_default_emulator
		if effective_emu == emulator_id:
			# Update install status
			var is_installed = LaunchManager.is_emulator_installed(emulator_id)
			var install_status = {emulator_id: is_installed}
			card.set_emulator_install_status(install_status)
			card.refresh_ui()

func _on_sync_pressed():
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
			NotificationManager.show_notification("Sync complete! Synced %d games" % synced, Notification.Type.SUCCESS)
		else:
			NotificationManager.show_notification("Sync failed: %s" % message, Notification.Type.ERROR)
	)

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
	# Refresh platform list every time the view is shown
	_fetch_platforms()
	super.on_view_show()

func on_view_hide():
	_save_settings()
	super.on_view_hide()
