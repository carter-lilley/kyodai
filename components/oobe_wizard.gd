extends Control
class_name OobeWizard

signal wizard_completed

# Page indices
enum Page {
	WELCOME,
	STORAGE_PATHS,
	ANDROID_PERMISSIONS,
	ROMM_CONNECTION,
	DONE
}

var _current_page: int = Page.WELCOME
var _pages: Array[Control] = []
var _is_romm_skipped: bool = false

# UI references
var _content_panel: PanelContainer
var _page_container: Control
var _nav_bar: HBoxContainer
var _back_button: Button
var _next_button: Button
var _skip_button: Button
var _finish_button: Button

# Page content references
var _games_path_edit: LineEdit
var _emulators_path_edit: LineEdit
var _steam_path_edit: LineEdit
var _vita3k_path_edit: LineEdit

var _romm_url_edit: LineEdit
var _romm_username_edit: LineEdit
var _romm_password_edit: LineEdit
var _romm_indicator: Indicator

var _perm_storage_indicator: Indicator
var _perm_install_indicator: Indicator
var _perm_notifications_indicator: Indicator
var _perm_storage_button: Button
var _perm_install_button: Button
var _perm_notifications_button: Button

# Android validation
var _storage_warning_label: Label

func _ready():
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build_ui()
	_show_page(Page.WELCOME)
	_update_navigation()

func _build_ui():
	# Background overlay
	var overlay = ColorRect.new()
	overlay.name = "Overlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.color = Color(0, 0, 0, 0.85)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	
	# Center container
	var center = CenterContainer.new()
	center.name = "CenterContainer"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	
	# Content panel
	_content_panel = PanelContainer.new()
	_content_panel.name = "ContentPanel"
	_content_panel.custom_minimum_size = Vector2(600, 500)
	center.add_child(_content_panel)
	
	# Main VBox
	var main_vbox = VBoxContainer.new()
	main_vbox.name = "MainVBox"
	_content_panel.add_child(main_vbox)
	
	# Title label
	var title_label = Label.new()
	title_label.name = "TitleLabel"
	title_label.text = "Welcome to Kyodai"
	title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_label.add_theme_font_size_override("font_size", 24)
	main_vbox.add_child(title_label)
	
	main_vbox.add_child(HSeparator.new())
	
	# Page container
	_page_container = Control.new()
	_page_container.name = "PageContainer"
	_page_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(_page_container)
	
	# Build pages
	_build_welcome_page()
	_build_storage_paths_page()
	_build_android_permissions_page()
	_build_romm_connection_page()
	_build_done_page()
	
	# Hide all pages initially
	for page in _pages:
		page.visible = false
	
	main_vbox.add_child(HSeparator.new())
	
	# Navigation bar
	_nav_bar = HBoxContainer.new()
	_nav_bar.name = "NavBar"
	_nav_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_nav_bar.add_theme_constant_override("separation", 12)
	main_vbox.add_child(_nav_bar)
	
	_back_button = Button.new()
	_back_button.name = "BackButton"
	_back_button.text = "Back"
	_back_button.pressed.connect(_on_back_pressed)
	_nav_bar.add_child(_back_button)
	
	_next_button = Button.new()
	_next_button.name = "NextButton"
	_next_button.text = "Next"
	_next_button.pressed.connect(_on_next_pressed)
	_nav_bar.add_child(_next_button)
	
	_skip_button = Button.new()
	_skip_button.name = "SkipButton"
	_skip_button.text = "Skip"
	_skip_button.pressed.connect(_on_skip_pressed)
	_nav_bar.add_child(_skip_button)
	
	_finish_button = Button.new()
	_finish_button.name = "FinishButton"
	_finish_button.text = "Start Kyodai"
	_finish_button.pressed.connect(_on_finish_pressed)
	_nav_bar.add_child(_finish_button)

func _build_welcome_page():
	var page = _create_page("welcome")
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_child(vbox)
	
	var icon = TextureRect.new()
	icon.texture = load("res://icon.svg")
	icon.custom_minimum_size = Vector2(128, 128)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.expand_mode = TextureRect.EXPAND_KEEP_SIZE
	vbox.add_child(icon)
	
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	vbox.add_child(spacer)
	
	var desc = Label.new()
	desc.text = "Let's get your emulator launcher set up.\n\nWe'll configure storage paths, permissions, and your RomM connection."
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)

func _build_storage_paths_page():
	var page = _create_page("storage")
	
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.add_child(scroll)
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)
	
	var desc = Label.new()
	desc.text = "Choose where Kyodai will store your games and emulators."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)
	
	if PlatformManager.is_android():
		var android_desc = Label.new()
		android_desc.text = "On Android, you must select external storage folders. The app's private folder is too small for ROMs and emulator data."
		android_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		android_desc.add_theme_color_override("font_color", Color.YELLOW)
		vbox.add_child(android_desc)
	
	vbox.add_child(HSeparator.new())
	
	# Games folder - empty default on Android, user:// on desktop
	var games_default = "" if PlatformManager.is_android() else "user://roms/"
	_games_path_edit = _add_path_row(vbox, "Games Folder", games_default)
	
	# Emulators folder - empty default on Android, user:// on desktop
	var emu_default = "" if PlatformManager.is_android() else "user://emulators/"
	_emulators_path_edit = _add_path_row(vbox, "Emulators Folder", emu_default)
	
	# Warning label for Android validation
	if PlatformManager.is_android():
		_storage_warning_label = Label.new()
		_storage_warning_label.text = "Please select both folders to continue"
		_storage_warning_label.add_theme_color_override("font_color", Color.RED)
		_storage_warning_label.visible = false
		vbox.add_child(_storage_warning_label)
	
	# Platform-specific paths
	if PlatformManager.is_windows() or PlatformManager.is_linux():
		_steam_path_edit = _add_path_row(vbox, "Steam Installation Folder (optional)", "")
	
	if PlatformManager.is_android():
		_vita3k_path_edit = _add_path_row(vbox, "Vita3K Data Folder (optional)", "")

func _build_android_permissions_page():
	var page = _create_page("permissions")
	
	if not PlatformManager.is_android():
		# On non-Android, this page is just informational
		var label = Label.new()
		label.set_anchors_preset(Control.PRESET_FULL_RECT)
		label.text = "Permission setup is only needed on Android."
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		page.add_child(label)
		return
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(vbox)
	
	var desc = Label.new()
	desc.text = "Kyodai needs the following permissions to function properly."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)
	
	vbox.add_child(HSeparator.new())
	
	# Storage permission
	var storage_row = _add_permission_row(vbox, "Storage Access", "Required to access game files and emulator data")
	_perm_storage_indicator = storage_row.indicator
	_perm_storage_button = Button.new()
	_perm_storage_button.text = "Grant"
	_perm_storage_button.pressed.connect(_request_storage_permission)
	storage_row.container.add_child(_perm_storage_button)
	
	vbox.add_child(HSeparator.new())
	
	# Install unknown apps
	var install_row = _add_permission_row(vbox, "Install Unknown Apps", "Required to install emulator APKs. You'll be prompted when installing your first emulator.")
	_perm_install_indicator = install_row.indicator
	_perm_install_button = Button.new()
	_perm_install_button.text = "Open Settings"
	_perm_install_button.pressed.connect(_open_install_settings)
	install_row.container.add_child(_perm_install_button)
	
	vbox.add_child(HSeparator.new())
	
	# Notifications
	var notif_row = _add_permission_row(vbox, "Notifications", "Required for download progress alerts")
	_perm_notifications_indicator = notif_row.indicator
	_perm_notifications_button = Button.new()
	_perm_notifications_button.text = "Grant"
	_perm_notifications_button.pressed.connect(_request_notifications_permission)
	notif_row.container.add_child(_perm_notifications_button)

func _build_romm_connection_page():
	var page = _create_page("romm")
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	page.add_child(vbox)
	
	var desc = Label.new()
	desc.text = "Connect to your RomM server to browse and download games. You can skip this and configure it later in Settings."
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)
	
	vbox.add_child(HSeparator.new())
	
	# URL
	var url_label = Label.new()
	url_label.text = "RomM URL"
	vbox.add_child(url_label)
	
	_romm_url_edit = LineEdit.new()
	_romm_url_edit.placeholder_text = "https://your-romm-server.com"
	vbox.add_child(_romm_url_edit)
	
	# Username
	var user_label = Label.new()
	user_label.text = "Username"
	vbox.add_child(user_label)
	
	_romm_username_edit = LineEdit.new()
	_romm_username_edit.placeholder_text = "username"
	vbox.add_child(_romm_username_edit)
	
	# Password
	var pass_label = Label.new()
	pass_label.text = "Password"
	vbox.add_child(pass_label)
	
	_romm_password_edit = LineEdit.new()
	_romm_password_edit.secret = true
	_romm_password_edit.placeholder_text = "password"
	vbox.add_child(_romm_password_edit)
	
	# Connection test row
	var test_container = HBoxContainer.new()
	test_container.custom_minimum_size = Vector2(0, 30)
	vbox.add_child(test_container)
	
	_romm_indicator = Indicator.new()
	_romm_indicator.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_container.add_child(_romm_indicator)
	
	var test_button = Button.new()
	test_button.text = "Test Connection"
	test_button.pressed.connect(_test_romm_connection)
	test_container.add_child(test_button)

func _build_done_page():
	var page = _create_page("done")
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_child(vbox)
	
	var title = Label.new()
	title.text = "All Set!"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)
	
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	vbox.add_child(spacer)
	
	var desc = Label.new()
	desc.text = "Kyodai is ready to go.\n\nYou can change any of these settings later in the Settings tab."
	desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)

func _create_page(name: String) -> Control:
	var page = Control.new()
	page.name = name
	page.set_anchors_preset(Control.PRESET_FULL_RECT)
	_page_container.add_child(page)
	_pages.append(page)
	return page

func _add_path_row(parent: VBoxContainer, label_text: String, default_value: String) -> LineEdit:
	var label = Label.new()
	label.text = label_text
	parent.add_child(label)
	
	var container = HBoxContainer.new()
	parent.add_child(container)
	
	var edit = LineEdit.new()
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text = default_value
	edit.virtual_keyboard_enabled = false
	edit.focus_mode = Control.FOCUS_NONE
	container.add_child(edit)
	
	var browse = Button.new()
	browse.text = "Browse..."
	browse.pressed.connect(_on_browse_pressed.bind(edit))
	container.add_child(browse)
	
	return edit

func _add_permission_row(parent: VBoxContainer, title: String, description: String) -> Dictionary:
	var container = VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(container)
	
	# Title row with indicator
	var title_row = HBoxContainer.new()
	title_row.custom_minimum_size = Vector2(0, 30)
	container.add_child(title_row)
	
	var title_label = Label.new()
	title_label.text = title
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_label)
	
	var indicator = Indicator.new()
	indicator.custom_minimum_size = Vector2(80, 0)
	title_row.add_child(indicator)
	
	# Description
	var desc_label = Label.new()
	desc_label.text = description
	desc_label.add_theme_font_size_override("font_size", 11)
	desc_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	container.add_child(desc_label)
	
	return {"container": container, "indicator": indicator}

# Navigation

func _show_page(page_idx: int):
	for i in range(_pages.size()):
		_pages[i].visible = (i == page_idx)
	_current_page = page_idx
	
	# Update title
	var title_label = get_node_or_null("CenterContainer/ContentPanel/MainVBox/TitleLabel")
	if title_label:
		match page_idx:
			Page.WELCOME:
				title_label.text = "Welcome to Kyodai"
			Page.STORAGE_PATHS:
				title_label.text = "Storage Paths"
			Page.ANDROID_PERMISSIONS:
				title_label.text = "Permissions"
			Page.ROMM_CONNECTION:
				title_label.text = "RomM Connection"
			Page.DONE:
				title_label.text = "Setup Complete"
	
	# Refresh permission indicators when showing the permissions page
	if page_idx == Page.ANDROID_PERMISSIONS and PlatformManager.is_android():
		_update_permission_indicators()
	
	# Move focus to first interactive element on the new page
	call_deferred("_focus_first_element")

func _focus_first_element():
	match _current_page:
		Page.WELCOME:
			if _next_button:
				_next_button.grab_focus()
		Page.STORAGE_PATHS:
			if _next_button:
				_next_button.grab_focus()
		Page.ANDROID_PERMISSIONS:
			if _perm_storage_button and _perm_storage_button.visible:
				_perm_storage_button.grab_focus()
			elif _next_button:
				_next_button.grab_focus()
		Page.ROMM_CONNECTION:
			if _romm_url_edit:
				_romm_url_edit.grab_focus()
		Page.DONE:
			if _finish_button:
				_finish_button.grab_focus()

func _update_navigation():
	_back_button.visible = _current_page > Page.STORAGE_PATHS
	_next_button.visible = _current_page < Page.ROMM_CONNECTION
	_skip_button.visible = _current_page == Page.ROMM_CONNECTION
	_finish_button.visible = _current_page == Page.DONE
	
	if _current_page == Page.ANDROID_PERMISSIONS and not PlatformManager.is_android():
		_next_button.visible = true
	
	# Update next button text on last step before done
	if _current_page == Page.ROMM_CONNECTION:
		_next_button.text = "Finish"
		_next_button.visible = true
		_skip_button.visible = true
	else:
		_next_button.text = "Next"

func _on_back_pressed():
	if _current_page > Page.WELCOME:
		_show_page(_current_page - 1)
		_update_navigation()
		# Hide warning when navigating back to storage
		if _current_page == Page.STORAGE_PATHS and _storage_warning_label:
			_storage_warning_label.visible = false

func _on_next_pressed():
	if _current_page == Page.ROMM_CONNECTION:
		# Save RomM settings if entered
		_save_romm_settings()
		_show_page(Page.DONE)
	elif _current_page < Page.DONE:
		# Validate storage paths on Android before progressing
		if _current_page == Page.STORAGE_PATHS and PlatformManager.is_android():
			if not _validate_android_storage_paths():
				if _storage_warning_label:
					_storage_warning_label.visible = true
				return
			if _storage_warning_label:
				_storage_warning_label.visible = false
		# Skip permissions page on non-Android
		if _current_page == Page.STORAGE_PATHS and not PlatformManager.is_android():
			_show_page(Page.ROMM_CONNECTION)
		else:
			_show_page(_current_page + 1)
	_update_navigation()

func _validate_android_storage_paths() -> bool:
	if not PlatformManager.is_android():
		return true
	
	var games_path = _games_path_edit.text.strip_edges()
	var emulators_path = _emulators_path_edit.text.strip_edges()
	
	# Both must be non-empty and not user://
	if games_path.is_empty() or emulators_path.is_empty():
		if _storage_warning_label:
			_storage_warning_label.text = "Please select both folders to continue"
		return false
	
	if games_path.begins_with("user://") or emulators_path.begins_with("user://"):
		if _storage_warning_label:
			_storage_warning_label.text = "Cannot use app private folder. Please select external storage."
		return false
	
	return true

func _on_skip_pressed():
	_is_romm_skipped = true
	_save_romm_settings()
	_show_page(Page.DONE)
	_update_navigation()

func _on_finish_pressed():
	# Save all settings
	_save_storage_settings()
	
	# Mark first run as complete
	var first_run_setting = SettingsManager.get_setting("first_run_completed")
	if first_run_setting:
		SettingsManager.set_setting(true, first_run_setting)
		SettingsManager.save_settings()
	
	# Animate out
	var tween = create_tween()
	tween.tween_property(self, "modulate", Color(1, 1, 1, 0), 0.3)
	tween.tween_callback(func():
		visible = false
		wizard_completed.emit()
		queue_free()
	)

# Path browsing

func _on_browse_pressed(edit: LineEdit):
	var dialog = FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = true
	dialog.current_dir = edit.text if edit.text else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	
	add_child(dialog)
	
	dialog.dir_selected.connect(func(dir: String):
		edit.text = dir
		
		# On Android, persist SAF permission
		if dir.begins_with("content://") and PlatformManager.is_android():
			var plugin = Engine.get_singleton("PackageChecker")
			if plugin:
				plugin.call("persistSafPermission", dir)
		
		dialog.queue_free()
	)
	
	dialog.canceled.connect(func():
		dialog.queue_free()
	)
	
	dialog.show()

# Permission handling (Android)

func _request_storage_permission():
	if not PlatformManager.is_android():
		return
	
	OS.request_permissions()
	_update_permission_indicators()

func _request_notifications_permission():
	if not PlatformManager.is_android():
		return
	
	OS.request_permissions()
	_update_permission_indicators()

func _open_install_settings():
	if not PlatformManager.is_android():
		return
	
	PlatformManager.open_install_unknown_apps_settings()
	_update_permission_indicators()

func _update_permission_indicators():
	if not PlatformManager.is_android():
		return
	
	var granted = OS.get_granted_permissions()
	
	if _perm_storage_indicator:
		# Android 11+ uses MANAGE_EXTERNAL_STORAGE (all files access) instead of READ/WRITE
		var has_old_storage = "android.permission.READ_EXTERNAL_STORAGE" in granted and "android.permission.WRITE_EXTERNAL_STORAGE" in granted
		var has_manage_storage = "android.permission.MANAGE_EXTERNAL_STORAGE" in granted
		var has_storage = has_old_storage or has_manage_storage
		_perm_storage_indicator.set_status(Indicator.Status.SUCCESS if has_storage else Indicator.Status.ERROR, "Granted" if has_storage else "Not Granted")
		if _perm_storage_button:
			_perm_storage_button.text = "Granted" if has_storage else "Grant"
			_perm_storage_button.disabled = has_storage
	
	if _perm_notifications_indicator:
		var has_notif = "android.permission.POST_NOTIFICATIONS" in granted
		_perm_notifications_indicator.set_status(Indicator.Status.SUCCESS if has_notif else Indicator.Status.ERROR, "Granted" if has_notif else "Not Granted")
		if _perm_notifications_button:
			_perm_notifications_button.text = "Granted" if has_notif else "Grant"
			_perm_notifications_button.disabled = has_notif
	
	if _perm_install_indicator:
		# Install unknown apps cannot be checked via OS.get_granted_permissions()
		# We show a generic status
		_perm_install_indicator.set_status(Indicator.Status.WARNING, "Check in Settings")

# RomM connection

func _test_romm_connection():
	if not _romm_indicator:
		return
	
	var url = _romm_url_edit.text.strip_edges()
	var username = _romm_username_edit.text.strip_edges()
	var password = _romm_password_edit.text.strip_edges()
	
	if url.is_empty() or username.is_empty() or password.is_empty():
		_romm_indicator.set_status(Indicator.Status.ERROR, "Fill in all fields")
		return
	
	_romm_indicator.set_status(Indicator.Status.WARNING, "Testing...")
	
	# Save to settings first so NetworkManager picks them up
	var url_setting = SettingsManager.get_setting("romm_url")
	var user_setting = SettingsManager.get_setting("romm_username")
	var pass_setting = SettingsManager.get_setting("romm_password")
	
	if url_setting:
		SettingsManager.set_setting(url, url_setting)
	if user_setting:
		SettingsManager.set_setting(username, user_setting)
	if pass_setting:
		SettingsManager.set_setting(password, pass_setting)
	
	# Give NetworkManager a frame to process the setting changes
	await get_tree().process_frame
	
	NetworkManager.test_connection(func(online: bool):
		if online:
			_romm_indicator.set_status(Indicator.Status.SUCCESS, "Connected")
		else:
			_romm_indicator.set_status(Indicator.Status.ERROR, "Connection failed")
	)

func _save_romm_settings():
	var url = _romm_url_edit.text.strip_edges()
	var username = _romm_username_edit.text.strip_edges()
	var password = _romm_password_edit.text.strip_edges()
	
	if not url.is_empty() and not username.is_empty() and not password.is_empty():
		var url_setting = SettingsManager.get_setting("romm_url")
		var user_setting = SettingsManager.get_setting("romm_username")
		var pass_setting = SettingsManager.get_setting("romm_password")
		
		if url_setting:
			SettingsManager.set_setting(url, url_setting)
		if user_setting:
			SettingsManager.set_setting(username, user_setting)
		if pass_setting:
			SettingsManager.set_setting(password, pass_setting)

func _save_storage_settings():
	var games_path = _games_path_edit.text.strip_edges()
	var emulators_path = _emulators_path_edit.text.strip_edges()
	
	if not games_path.is_empty():
		var games_setting = SettingsManager.get_setting("games_root_folder")
		if games_setting:
			SettingsManager.set_setting(games_path, games_setting)
		# Ensure directory exists
		FileSystemManager.make_dir_recursive(games_path)
	
	if not emulators_path.is_empty():
		var emu_setting = SettingsManager.get_setting("emulators_folder")
		if emu_setting:
			SettingsManager.set_setting(emulators_path, emu_setting)
		# Ensure directory exists
		FileSystemManager.make_dir_recursive(emulators_path)
	
	if _steam_path_edit and not _steam_path_edit.text.strip_edges().is_empty():
		var steam_setting = SettingsManager.get_setting("steam_folder")
		if steam_setting:
			SettingsManager.set_setting(_steam_path_edit.text.strip_edges(), steam_setting)
	
	if _vita3k_path_edit and not _vita3k_path_edit.text.strip_edges().is_empty():
		var vita_setting = SettingsManager.get_setting("vita3k_data_folder_android")
		if vita_setting:
			SettingsManager.set_setting(_vita3k_path_edit.text.strip_edges(), vita_setting)

# Public API

func refresh_android_permissions():
	if _current_page == Page.ANDROID_PERMISSIONS and PlatformManager.is_android():
		_update_permission_indicators()

func _input(event: InputEvent) -> void:
	# Block ui_cancel from reaching the main UI
	if event.is_action_pressed("ui_cancel"):
		# On non-first page, act as back button
		if _current_page > Page.WELCOME and _current_page < Page.DONE:
			_on_back_pressed()
		get_viewport().set_input_as_handled()
		return

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		# User returned from system dialog or settings - refresh permission status
		if _current_page == Page.ANDROID_PERMISSIONS and PlatformManager.is_android():
			# Small delay to ensure Android has updated permission state
			await get_tree().create_timer(0.5).timeout
			_update_permission_indicators()

func start_wizard():
	visible = true
	modulate = Color(1, 1, 1, 0)
	var tween = create_tween()
	tween.tween_property(self, "modulate", Color(1, 1, 1, 1), 0.3)
	
	# Focus the first interactive element
	await get_tree().process_frame
	if _next_button:
		_next_button.grab_focus()
