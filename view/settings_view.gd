class_name SettingsView
extends View

var _settings_container: TabContainer

func _ready():
	view_name = "Settings"
	_build_settings_view()
	super._ready()

func _build_settings_view():
	# Create sub-TabContainer for settings groups
	_settings_container = TabContainer.new()
	_settings_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_settings_container.tab_changed.connect(_on_settings_tab_changed)
	add_child(_settings_container)
	
	# Get settings by subgroup from SettingsManager
	var subgroups = SettingsManager.get_settings_by_subgroup()
	
	# Create a tab for each subgroup
	for subgroup_name in subgroups.keys():
		var settings_vars = subgroups[subgroup_name]
		var tab = _create_settings_tab(subgroup_name, settings_vars)
		_settings_container.add_child(tab)
		_settings_container.set_tab_title(_settings_container.get_tab_count() - 1, subgroup_name)
	
	# Add Platforms tab
	var platforms_tab = _create_platforms_tab()
	_settings_container.add_child(platforms_tab)
	_settings_container.set_tab_title(_settings_container.get_tab_count() - 1, "Platforms")

func _create_platforms_tab() -> Control:
	var platforms_view = preload("res://view/platforms_settings_view.gd").new()
	return platforms_view

func _create_settings_tab(name: String, settings_vars: Array) -> Control:
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	
	var menu = SettingsMenu.new()
	menu.initialize_settings_menu(name, settings_vars)
	menu.setting_changed.connect(_on_setting_changed)
	
	vbox.add_child(menu)
	
	# Add connection status UI for RomM Connection tab
	if name == "RomM Connection":
		var status_ui = _create_connection_status_ui()
		vbox.add_child(status_ui)
	
	margin.add_child(vbox)
	scroll.add_child(margin)
	
	return scroll

func _create_connection_status_ui() -> Control:
	var indicator = Indicator.new()
	indicator.custom_minimum_size = Vector2(0, 30)
	
	# Connect to ready signal to set initial status after node is initialized
	indicator.ready.connect(func():
		indicator.show_test_button(true)
		_update_connection_status(indicator)
	)
	
	# Connect test button signal
	indicator.test_requested.connect(func():
		_test_connection(indicator)
	)
	
	return indicator

func _test_connection(indicator: Indicator):
	indicator.set_status(Indicator.StatusEnum.TESTING, "Testing connection...")
	
	NetworkManager.test_connection(func(online: bool):
		if online:
			indicator.set_status(Indicator.StatusEnum.CONNECTED, "Connected and authenticated")
			NotificationManager.show_notification("Connected to RomM successfully", Notification.Type.SUCCESS)
		else:
			if not NetworkManager.is_configured():
				indicator.set_status(Indicator.StatusEnum.NOT_CONFIGURED, "Not configured (check URL, username, password)")
				NotificationManager.show_notification("RomM not configured - check URL, username, password", Notification.Type.ERROR)
			else:
				indicator.set_status(Indicator.StatusEnum.DISCONNECTED, "Connection failed - check credentials")
				NotificationManager.show_notification("Connection failed - check credentials", Notification.Type.ERROR)
	)

func _update_connection_status(indicator: Indicator):
	if NetworkManager.is_online():
		indicator.set_status(Indicator.StatusEnum.CONNECTED, "Connected and authenticated")
	elif not NetworkManager.is_configured():
		indicator.set_status(Indicator.StatusEnum.NOT_CONFIGURED, "Not configured")
	else:
		indicator.set_status(Indicator.StatusEnum.DISCONNECTED, "Disconnected")

func _on_setting_changed(value: Variant, setting: SettingsVar):
	SettingsManager.set_setting(value, setting)

func on_view_hide():
	SettingsManager.save_settings()
	super.on_view_hide()

func _on_settings_tab_changed(tab_idx: int):
	# Call on_view_show on the newly selected tab
	var tab = _settings_container.get_tab_control(tab_idx)
	if tab and tab.has_method("on_view_show"):
		tab.on_view_show()
