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
	
	# Add "Not Configured" option
	_emulator_dropdown.add_item("Not Configured", 0)
	_emulator_dropdown.set_item_metadata(0, "")
	
	var selected_index = 0
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

func _update_status_indicator():
	if not _status_indicator:
		return
	if selected_emulator == "":
		_status_indicator.set_status(Indicator.Status.NEUTRAL, "Not configured", "Select an emulator to use for this platform")
		if _download_button:
			_download_button.visible = false
		return
	
	var is_installed = LaunchManager.is_emulator_installed(selected_emulator) if LaunchManager else false
	var is_downloaded = LaunchManager.is_emulator_downloaded(selected_emulator) if LaunchManager else false
	var is_downloading = LaunchManager.is_emulator_downloading(selected_emulator) if LaunchManager else false
	var is_queued = LaunchManager.is_emulator_queued(selected_emulator) if LaunchManager else false
	var is_extracting = LaunchManager.is_emulator_extracting(selected_emulator) if LaunchManager else false
	
	if is_installed:
		# Fully installed - green status, no button
		_status_indicator.set_status(Indicator.Status.SUCCESS, "Installed", "Emulator is ready to use")
		if _download_button:
			_download_button.visible = false
	elif is_extracting:
		# Currently extracting/installing
		_status_indicator.set_status(Indicator.Status.WARNING, "Installing...", "Extracting emulator files")
		if _download_button:
			_download_button.visible = true
			_download_button.disabled = true
			_download_button.text = "Installing..."
	elif is_downloading or is_queued:
		# Currently downloading
		_status_indicator.set_status(Indicator.Status.WARNING, "Downloading...", "Emulator is being downloaded")
		if _download_button:
			_download_button.visible = true
			_download_button.disabled = true
			_download_button.text = "Downloading..." if is_downloading else "Queued"
	elif not is_installed and is_downloaded:
		# Downloaded but not extracted - show Install button
		_status_indicator.set_status(Indicator.Status.WARNING, "Downloaded", "Ready to install")
		if _download_button:
			_download_button.visible = true
			_download_button.disabled = false
			_download_button.text = "Install"
	else:
		# Not downloaded - show Download button
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
	emulator_changed.emit(emulator_id)

func _on_download_pressed():
	if selected_emulator != "":
		var is_downloaded = LaunchManager.is_emulator_downloaded(selected_emulator) if LaunchManager else false
		var is_installed = _emulator_install_status.get(selected_emulator, false)
		
		if is_downloaded and not is_installed:
			# Install the downloaded archive
			LaunchManager.extract_emulator(selected_emulator)
			refresh_ui()
		else:
			# Download the emulator
			download_requested.emit(selected_emulator)

func refresh_ui():
	# Called by parent to refresh button states (e.g., when download starts/completes)
	_update_status_indicator()
