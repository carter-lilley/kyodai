@tool
class_name PlatformCard
extends M3Card

signal sync_toggled(enabled: bool)
signal emulator_changed(emulator_id: String)
signal download_requested(emulator_id: String)

@export var platform_slug: String = "":
	set(value):
		platform_slug = value
		_update_display()

@export var platform_name: String = "":
	set(value):
		platform_name = value
		_update_display()

@export var is_sync_enabled: bool = false:
	set(value):
		is_sync_enabled = value
		_update_display()

@export var selected_emulator: String = "":
	set(value):
		selected_emulator = value
		_update_display()

var registry_default_emulator: String = "":
	set(value):
		registry_default_emulator = value
		if is_node_ready():
			_update_emulator_dropdown()

var _available_emulators: Array[Dictionary] = []
var _emulator_install_status: Dictionary = {}

var _name_label: Label
var _sync_toggle: M3Checkbox
var _emulator_dropdown: M3OptionButton
var _status_indicator: Indicator
var _download_button: M3Button
var _version_label: Label

func _ready():
	card_layout_mode = LayoutMode.HORIZONTAL
	card_variant = Variant.ELEVATED
	clickable = false

	super._ready()
	# Allow card to grow to fit content; set a sane minimum for horizontal mode
	custom_minimum_size.y = M3Units.dp(140)

	_build_ui()
	_update_display()

	# If install status wasn't pre-set by parent, scan on ready
	if _emulator_install_status.is_empty():
		var _effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator
		if _effective_emulator != "" and LaunchManager:
			LaunchManager.scan_emulator_install_state(_effective_emulator)
			_update_status_indicator()

func _build_ui():
	# Platform cards have no media
	if _media_panel:
		_media_panel.visible = false

	# Hide M3Card's default text labels (we build our own layout inside _text_content)
	if _headline_label:
		_headline_label.visible = false
	if _supporting_label:
		_supporting_label.visible = false

	# Build custom content inside M3Card's _text_content VBoxContainer
	# Top row: Name + Sync toggle
	var top_row = HBoxContainer.new()
	top_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_content.add_child(top_row)

	_name_label = Label.new()
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(_name_label)

	_sync_toggle = M3Checkbox.new()
	_sync_toggle.toggled.connect(_on_sync_toggled)
	top_row.add_child(_sync_toggle)

	# Emulator row: Icon + Dropdown
	var emulator_row = HBoxContainer.new()
	emulator_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_content.add_child(emulator_row)

	var emulator_icon = FontIcon.new()
	emulator_icon.icon_settings = FontIconSettings.new()
	emulator_icon.icon_settings.icon_name = "gamepad-variant"
	emulator_icon.icon_settings.icon_size = M3Units.dp(20)
	emulator_icon.icon_settings.icon_color = M3Theme.get_on_surface_variant()
	emulator_row.add_child(emulator_icon)

	_emulator_dropdown = M3OptionButton.new()
	_emulator_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_emulator_dropdown.item_selected.connect(_on_emulator_selected)
	emulator_row.add_child(_emulator_dropdown)

	# Status row: Indicator + Download button + version label
	var status_row = HBoxContainer.new()
	status_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_content.add_child(status_row)

	_status_indicator = Indicator.new()
	_status_indicator.dot_size = Vector2(10, 10)
	_status_indicator.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_indicator)

	_download_button = M3Button.new()
	_download_button.text = "Download"
	_download_button.visible = false
	_download_button.button_size = M3Button.Size.EXTRA_SMALL
	_download_button.pressed.connect(_on_download_pressed)
	status_row.add_child(_download_button)

	_version_label = Label.new()
	_version_label.visible = false
	_version_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	status_row.add_child(_version_label)

	# Apply M3 fonts and colors
	_apply_m3_text_styles()

func _apply_m3_text_styles():
	var fonts = M3Theme.load_fonts()
	var on_surface = M3Theme.get_on_surface()
	var on_surface_variant = M3Theme.get_on_surface_variant()

	var headline_size = M3Units.dp(16)
	var body_size = M3Units.dp(14)
	var small_size = M3Units.dp(12)

	if _name_label:
		_name_label.add_theme_font_override("font", fonts["medium"])
		_name_label.add_theme_font_size_override("font_size", headline_size)
		_name_label.add_theme_color_override("font_color", on_surface)

	if _version_label:
		_version_label.add_theme_font_override("font", fonts["regular"])
		_version_label.add_theme_font_size_override("font_size", small_size)
		_version_label.add_theme_color_override("font_color", on_surface_variant)

func _update_display():
	if not is_node_ready():
		return

	_name_label.text = platform_name if platform_name else platform_slug
	_sync_toggle.button_pressed = is_sync_enabled

	# Update emulator dropdown
	_update_emulator_dropdown()

func _update_emulator_dropdown():
	if not _emulator_dropdown:
		return
	_emulator_dropdown.clear()

	# Determine effective emulator (what's actually being used)
	var _effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator
	var selected_index = 0

	# Add "Auto" option if we have a registry default
	if registry_default_emulator != "":
		var default_emu_name = _get_emulator_name(registry_default_emulator)
		var auto_text = "Auto (%s)" % default_emu_name
		_emulator_dropdown.add_item(auto_text, 0)

		if selected_emulator == "":
			selected_index = 0
	else:
		# No registry default - add "Not Configured" option
		_emulator_dropdown.add_item("Not Configured", 0)

	# Add available emulators
	for i in range(_available_emulators.size()):
		var emulator = _available_emulators[i]
		var emulator_id = emulator.get("id", "")
		var emulator_name = emulator.get("name", emulator_id)

		_emulator_dropdown.add_item(emulator_name, i + 1)

		if emulator_id == selected_emulator:
			selected_index = i + 1

	_emulator_dropdown.selected = selected_index
	_update_status_indicator()

func _get_emulator_name(emulator_id: String) -> String:
	for emu in _available_emulators:
		if emu.get("id", "") == emulator_id:
			return emu.get("name", emulator_id)
	return emulator_id

func _update_status_indicator():
	if not _status_indicator:
		return

	# Determine effective emulator (what's actually being used)
	var effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator

	if effective_emulator == "":
		_status_indicator.set_status(Indicator.Status.NEUTRAL, "Not configured", "Select an emulator to use for this platform")
		if _download_button:
			_download_button.visible = false
		return

	# Show whether this is using auto or manual selection
	var is_auto = selected_emulator == ""
	var mode_text = " (auto)" if is_auto else ""

	# Get install progress from registry
	var progress = LaunchManager.get_install_progress(effective_emulator) if LaunchManager else {"status": "not_started", "completed_steps": 0, "total_steps": 0, "next_step_display": ""}
	var progress_text = LaunchManager.get_emulator_install_progress(effective_emulator) if LaunchManager else ""

	# Check for active download/extraction via DownloadManager
	var is_downloading = false
	var is_extracting = false
	if DownloadManager:
		for item in DownloadManager.get_active():
			if item.name == effective_emulator:
				is_downloading = true
				break

	if LaunchManager and LaunchManager._emulator_install_progress.has(effective_emulator):
		var progress_str = LaunchManager._emulator_install_progress[effective_emulator]
		if progress_str.find("Extracting") >= 0 or progress_str.find("extracting") >= 0:
			is_extracting = true

	# Update version label
	if _version_label:
		if progress["status"] == "complete" and SettingsManager:
			var version_setting = SettingsManager.get_setting("installed_emulator_versions")
			if version_setting:
				var versions = version_setting.value as Dictionary
				if versions and versions.has(effective_emulator):
					var raw_version = versions[effective_emulator]
					var display_version = raw_version.trim_prefix("v").trim_prefix("V")
					_version_label.text = "v%s" % display_version
					_version_label.visible = true
				else:
					_version_label.visible = false
			else:
				_version_label.visible = false
		else:
			_version_label.visible = false

	if progress["status"] == "complete":
		_status_indicator.set_status(Indicator.Status.SUCCESS, "Installed%s" % mode_text, "Emulator is ready to use")
		if _download_button:
			_download_button.visible = false
	elif is_downloading:
		var display_text = progress_text if progress_text != "" else "Downloading..."
		_status_indicator.set_status(Indicator.Status.WARNING, display_text, "Emulator is being downloaded")
		if _download_button:
			_download_button.visible = true
			_download_button.disabled = true
			_download_button.text = "Downloading..."
	elif is_extracting:
		var extract_text = progress_text if progress_text != "" else "Extracting..."
		_status_indicator.set_status(Indicator.Status.WARNING, extract_text, "Extracting emulator files")
		if _download_button:
			_download_button.visible = true
			_download_button.disabled = true
			_download_button.text = "Installing..."
	elif progress["status"] == "partial":
		var next_step = progress["next_step_display"]
		_status_indicator.set_status(Indicator.Status.WARNING, next_step, "Installation incomplete - click to continue")
		if _download_button:
			_download_button.visible = true
			_download_button.disabled = false
			_download_button.text = "Resume"
	else:
		_status_indicator.set_status(Indicator.Status.ERROR, "Not downloaded", "Click Download to get the emulator")
		if _download_button:
			_download_button.visible = true
			_download_button.disabled = false
			_download_button.text = "Download"

func set_available_emulators(emulators: Array[Dictionary]):
	_available_emulators = emulators
	if is_node_ready():
		_update_emulator_dropdown()

func set_emulator_install_status(status: Dictionary):
	_emulator_install_status = status
	if is_node_ready():
		_update_status_indicator()

func _on_sync_toggled(enabled: bool):
	sync_toggled.emit(enabled)

func _on_emulator_selected(index: int):
	var emulator_id = ""
	if index >= 0:
		emulator_id = _emulator_dropdown.get_item_id(index)
	selected_emulator = emulator_id

	# Force step-based validation scan for this emulator
	var effective_emu = emulator_id if emulator_id != "" else registry_default_emulator
	if LaunchManager and effective_emu != "":
		LaunchManager.scan_emulator_install_state(effective_emu)

	emulator_changed.emit(emulator_id)
	refresh_ui()

func _on_download_pressed():
	var effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator
	if effective_emulator == "":
		return

	# Get install progress from registry
	var progress = LaunchManager.get_install_progress(effective_emulator) if LaunchManager else {"status": "not_started", "completed_steps": 0, "total_steps": 0, "next_step_display": ""}

	if progress["status"] == "partial":
		# Resume installation from first incomplete step
		LaunchManager.download_emulator(effective_emulator)
		refresh_ui()
	else:
		# For not_started, complete, or any other state, request download/install
		download_requested.emit(effective_emulator)

func focus_sync_toggle() -> void:
	if _sync_toggle and _sync_toggle.focus_mode != Control.FOCUS_NONE:
		_sync_toggle.grab_focus()

func refresh_ui():
	# Called by parent to refresh button states (e.g., when download starts/completes)
	var effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator
	if effective_emulator != "" and LaunchManager:
		LaunchManager.scan_emulator_install_state(effective_emulator)

	_update_status_indicator()
