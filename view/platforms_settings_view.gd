#platforms_settings_view.gd
class_name PlatformsSettingsView
extends View

var _platforms_container: VBoxContainer
var _platforms_data: Array = []
var _checkboxes: Dictionary = {}

func _ready():
	view_name = "Platforms"
	_build_view()
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
	margin.add_child(_platforms_container)
	
	# Add info label
	var info_label = Label.new()
	info_label.text = "Select platforms to sync. Disabled platforms will have their games removed."
	info_label.name = "InfoLabel"
	_platforms_container.add_child(info_label)
	
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	_platforms_container.add_child(spacer)
	
	# Add sync button at the top
	var sync_button = Button.new()
	sync_button.text = "Sync Enabled Platforms"
	sync_button.name = "SyncButton"
	sync_button.pressed.connect(_on_sync_pressed)
	_platforms_container.add_child(sync_button)
	
	var spacer2 = Control.new()
	spacer2.custom_minimum_size = Vector2(0, 20)
	_platforms_container.add_child(spacer2)

func _fetch_platforms():
	# Clear existing checkboxes and buttons (keep info label and sync button)
	for child in _platforms_container.get_children():
		if child.name == "InfoLabel" or child.name == "SyncButton":
			continue
		if child is CheckBox or child is Button or child is Label:
			child.queue_free()
	_checkboxes.clear()
	
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
			
			if slug == "" or romm_id == 0:
				continue
			
			fetched_slugs.append(slug)
			
			# Create checkbox
			var checkbox = CheckBox.new()
			checkbox.text = name
			# Check if enabled (look for either old format bool or new format dict)
			var is_enabled = false
			var existing = enabled_platforms.get(slug)
			if existing is bool:
				is_enabled = existing
			elif existing is Dictionary:
				is_enabled = existing.get("enabled", false)
			checkbox.button_pressed = is_enabled
			checkbox.toggled.connect(func(checked: bool):
				_set_platform_enabled(slug, romm_id, checked)
			)
			
			_platforms_container.add_child(checkbox)
			_checkboxes[slug] = checkbox
		
		# Remove platforms that no longer exist on RomM
		_remove_deleted_platforms(fetched_slugs)
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
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting:
		SettingsManager.set_setting(enabled_platforms, setting)

func _load_platforms_from_database():
	# Remove loading label if exists
	for child in _platforms_container.get_children():
		if child.name == "LoadingLabel":
			child.queue_free()
			break
	
	var platforms = DataManager.get_all_platforms()
	var enabled_platforms = _get_enabled_platforms()
	
	# Clear existing checkboxes and buttons (keep info label and sync button)
	for child in _platforms_container.get_children():
		if child.name == "InfoLabel" or child.name == "SyncButton":
			continue
		if child is CheckBox or child is Button or child is Label:
			child.queue_free()
	_checkboxes.clear()
	
	for platform in platforms:
		var slug = platform.slug
		var name = platform.name
		
		if slug == "":
			continue
		
		# Check if enabled (look for either old format bool or new format dict)
		var is_enabled = false
		var existing = enabled_platforms.get(slug)
		if existing is bool:
			is_enabled = existing
		elif existing is Dictionary:
			is_enabled = existing.get("enabled", false)
		
		var checkbox = CheckBox.new()
		checkbox.text = name
		checkbox.button_pressed = is_enabled
		# Disable checkbox when offline since we don't have the platform ID
		checkbox.disabled = true
		checkbox.tooltip_text = "Connect to RomM to enable/disable platforms"
		
		_platforms_container.add_child(checkbox)
		_checkboxes[slug] = checkbox
	
	if platforms.size() == 0:
		var no_platforms_label = Label.new()
		no_platforms_label.text = "No platforms found. Please connect to RomM to fetch platforms."
		_platforms_container.add_child(no_platforms_label)

func _get_enabled_platforms() -> Dictionary:
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting and setting.value is Dictionary:
		return setting.value
	return {}

func _set_platform_enabled(slug: String, platform_id: int, enabled: bool):
	var enabled_platforms = _get_enabled_platforms()
	# Store as dictionary with id and enabled status
	enabled_platforms[slug] = {
		"id": platform_id,
		"enabled": enabled
	}
	
	var setting = SettingsManager.get_setting("enabled_platforms")
	if setting:
		SettingsManager.set_setting(enabled_platforms, setting)

func _save_settings():
	SettingsManager.save_settings()

func _on_sync_pressed():
	if not NetworkManager.is_online():
		var error_label = Label.new()
		error_label.text = "Not connected to RomM - check settings"
		error_label.modulate = Color.RED
		_platforms_container.add_child(error_label)
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
		
		var result_label = Label.new()
		if success:
			result_label.text = "Sync complete! Synced %d games" % synced
			result_label.modulate = Color.GREEN
		else:
			result_label.text = "Sync failed: %s" % message
			result_label.modulate = Color.RED
		_platforms_container.add_child(result_label)
	)

func on_view_show():
	# Refresh platform list every time the view is shown
	_fetch_platforms()
	super.on_view_show()

func on_view_hide():
	_save_settings()
	super.on_view_hide()
