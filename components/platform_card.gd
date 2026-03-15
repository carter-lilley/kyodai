class_name PlatformCard
extends PanelContainer

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

@export var platform_icon: Texture2D = null:
	set(value):
		platform_icon = value
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
var _emulator_install_status: Dictionary = {}  # emulator_id -> bool

@onready var _icon_texture: TextureRect
@onready var _name_label: Label
@onready var _sync_toggle: CheckButton
@onready var _emulator_dropdown: OptionButton
@onready var _status_indicator: Indicator
@onready var _download_button: Button

func _ready():
	_build_ui()
	_update_display()
	
	# Connect to scan completion signal to refresh state
	if LaunchManager:
		if not LaunchManager.emulator_installations_scanned.is_connected(_on_installations_scanned):
			LaunchManager.emulator_installations_scanned.connect(_on_installations_scanned)
	
	# Scan install state on ready to detect partial installs
	var effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator
	if effective_emulator != "" and LaunchManager:
		LaunchManager.scan_emulator_install_state(effective_emulator)
		_update_status_indicator()

func _on_installations_scanned():
	# Refresh UI when disk scan completes
	refresh_ui()

func _build_ui():
	var margin = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)
	
	var main_hbox = HBoxContainer.new()
	main_hbox.add_theme_constant_override("separation", 12)
	margin.add_child(main_hbox)
	
	# Icon
	_icon_texture = TextureRect.new()
	_icon_texture.custom_minimum_size = Vector2(48, 48)
	_icon_texture.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	_icon_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	main_hbox.add_child(_icon_texture)
	
	# Content container
	var content_vbox = VBoxContainer.new()
	content_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_hbox.add_child(content_vbox)
	
	# Top row: Name + Sync toggle
	var top_row = HBoxContainer.new()
	content_vbox.add_child(top_row)
	
	_name_label = Label.new()
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_label.add_theme_font_size_override("font_size", 14)
	top_row.add_child(_name_label)
	
	_sync_toggle = CheckButton.new()
	_sync_toggle.text = "Sync"
	_sync_toggle.toggled.connect(_on_sync_toggled)
	top_row.add_child(_sync_toggle)
	
	# Bottom row: Emulator dropdown + Status
	var bottom_row = HBoxContainer.new()
	content_vbox.add_child(bottom_row)
	
	var emulator_label = Label.new()
	emulator_label.text = "Emulator:"
	bottom_row.add_child(emulator_label)
	
	_emulator_dropdown = OptionButton.new()
	_emulator_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_emulator_dropdown.item_selected.connect(_on_emulator_selected)
	bottom_row.add_child(_emulator_dropdown)
	
	_status_indicator = Indicator.new()
	_status_indicator.dot_size = Vector2(12, 12)
	_status_indicator.custom_minimum_size = Vector2(120, 20)
	bottom_row.add_child(_status_indicator)
	
	# Download button (shown when emulator not installed)
	_download_button = Button.new()
	_download_button.text = "Download"
	_download_button.visible = false
	_download_button.pressed.connect(_on_download_pressed)
	bottom_row.add_child(_download_button)

func _update_display():
	if not is_node_ready():
		return
	
	_icon_texture.texture = platform_icon
	_name_label.text = platform_name if platform_name else platform_slug
	_sync_toggle.button_pressed = is_sync_enabled
	
	# Update emulator dropdown
	_update_emulator_dropdown()

func _update_emulator_dropdown():
	if not _emulator_dropdown:
		return
	_emulator_dropdown.clear()
	
	# Determine effective emulator (what's actually being used)
	var effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator
	var selected_index = 0
	
	# Add "Auto" option if we have a registry default
	if registry_default_emulator != "":
		var default_emu_name = _get_emulator_name(registry_default_emulator)
		var auto_text = "Auto (%s)" % default_emu_name
		_emulator_dropdown.add_item(auto_text, 0)
		_emulator_dropdown.set_item_metadata(0, "")  # Empty = use registry default
		
		if selected_emulator == "":
			selected_index = 0
	else:
		# No registry default - add "Not Configured" option
		_emulator_dropdown.add_item("Not Configured", 0)
		_emulator_dropdown.set_item_metadata(0, "")
	
	# Add available emulators
	for i in range(_available_emulators.size()):
		var emulator = _available_emulators[i]
		var emulator_id = emulator.get("id", "")
		var emulator_name = emulator.get("name", emulator_id)
		
		_emulator_dropdown.add_item(emulator_name, i + 1)
		_emulator_dropdown.set_item_metadata(i + 1, emulator_id)
		
		if emulator_id == selected_emulator:
			selected_index = i + 1
	
	_emulator_dropdown.select(selected_index)
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
	# Check for active downloads via DownloadManager
	if DownloadManager:
		for item in DownloadManager.get_active():
			if item.name == effective_emulator:
				is_downloading = true
				break
	
	# Check for active extraction via LaunchManager._emulator_install_progress
	if LaunchManager and LaunchManager._emulator_install_progress.has(effective_emulator):
		var progress_str = LaunchManager._emulator_install_progress[effective_emulator]
		# Check if progress text indicates extraction
		if progress_str.find("Extracting") >= 0 or progress_str.find("extracting") >= 0:
			is_extracting = true
	
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
		# Partial install - show resume option
		var next_step = progress["next_step_display"]
		_status_indicator.set_status(Indicator.Status.WARNING, "Resume: %s" % next_step, "Installation incomplete - click to continue")
		if _download_button:
			_download_button.visible = true
			_download_button.disabled = false
			_download_button.text = "Resume"
	else:  # not_started
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
	var emulator_id = _emulator_dropdown.get_item_metadata(index)
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
		await LaunchManager.download_emulator(effective_emulator)
		refresh_ui()
	else:
		# For not_started, complete, or any other state, request download/install
		download_requested.emit(effective_emulator)

func refresh_ui():
	# Called by parent to refresh button states (e.g., when download starts/completes)
	# First, scan the install state to detect partial installs
	var effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator
	if effective_emulator != "" and LaunchManager:
		LaunchManager.scan_emulator_install_state(effective_emulator)
	
	_update_status_indicator()
