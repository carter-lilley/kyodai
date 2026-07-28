@tool
class_name PlatformCard
extends M3Card

signal sync_toggled(enabled: bool)
signal emulator_changed(emulator_id: String, core_id: String)
signal download_requested(emulator_id: String)

## When true, the card is being used in the shuffler config dialog.
## Status indicators, the download button, and the version label are hidden,
## and the sync toggle means "include in shuffle".
@export var shuffler_mode: bool = false:
	set(value):
		shuffler_mode = value
		_update_shuffler_mode()

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

@export var selected_core_id: String = "":
	set(value):
		selected_core_id = value
		_update_display()

# Cached default core id supplied by the parent view. If set, the card avoids
# querying LaunchManager for the default core.
var registry_default_core_id: String = ""

var registry_default_emulator: String = "":
	set(value):
		registry_default_emulator = value
		if is_node_ready():
			_update_emulator_dropdown()
			refresh_firmware_indicator()

var _available_emulators: Array[Dictionary] = []
var _available_cores: Array[Dictionary] = []
var _emulator_install_status: Dictionary = {}

# When true, set_available_emulators() stores the list but does not rebuild the
# dropdown. This lets views create many cards cheaply and populate dropdowns
# in a second batch.
var _defer_dropdown: bool = false
var _pending_emulators: Array[Dictionary] = []

# Reentrancy guard for dropdown rebuilds. Setting selected_emulator/selected_core_id
# from _on_emulator_selected triggers _update_display() -> _update_emulator_dropdown(),
# and without this guard the menu items can be rebuilt/appended while a selection is
# still in flight.
var _is_rebuilding_dropdown: bool = false

# Tracks the dropdown entry type for each index.
# Each entry is {type: "auto"|"emulator"|"core", emulator_id: String, core_id: String}.
var _dropdown_entries: Array[Dictionary] = []

var _name_label: M3Label
var _sync_toggle: M3Switch
var _emulator_dropdown: M3OptionButton
var _status_indicator: Indicator
var _download_button: M3Button
var _version_label: M3Label
var _firmware_indicator: Indicator
var _status_row: HBoxContainer

# Track signal connections so we can disconnect them cleanly when the card is
# returned to a pool and rebound to a new consumer.
var _sync_toggle_connected: bool = false
var _emulator_dropdown_connected: bool = false
var _download_button_connected: bool = false

func _init():
	# Cards are created from PlatformCard.new() both directly and from the pool.
	# Set the minimum size early so the first layout pass uses the correct
	# width instead of the default Button width (which yields an 8 px card).
	custom_minimum_size = Vector2(M3Units.dp(320), M3Units.dp(140))
	size_flags_horizontal = Control.SIZE_EXPAND_FILL

func refresh_basic_ui() -> void:
	if not is_node_ready():
		return
	if _name_label:
		_name_label.text = platform_name if platform_name else platform_slug
	if _sync_toggle:
		_sync_toggle.set_pressed_no_signal(is_sync_enabled)
	_update_shuffler_mode()
	_update_status_indicator()

func _ready():
	card_layout_mode = LayoutMode.HORIZONTAL
	card_variant = Variant.ELEVATED
	clickable = false

	super._ready()
	set_visual_layer(null)

	_build_ui()
	refresh_basic_ui()

	# If install status wasn't pre-set by parent, scan on ready.
	# Parent passes precomputed status, so this fallback should rarely run.
	if _emulator_install_status.is_empty():
		var _effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator
		if _effective_emulator != "" and LaunchManager:
			LaunchManager.scan_emulator_install_state(_effective_emulator)
			_update_status_indicator()
	
	# Defer the first firmware check so creating many cards doesn't block the UI.
	call_deferred("refresh_firmware_indicator")
	_update_media_panel_size(true)

func _enter_tree():
	set_visual_layer(null)
	super._enter_tree()
	if _ready_called:
		refresh_basic_ui()

func _build_ui():
	# Platform cards have no media
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

	_name_label = M3Label.new()
	_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(_name_label)

	_sync_toggle = M3Switch.new()
	_sync_toggle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_sync_toggle.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top_row.add_child(_sync_toggle)
	_connect_sync_toggle()

	_firmware_indicator = Indicator.new()
	_firmware_indicator.dot_size = Vector2(M3Units.dp(8), M3Units.dp(8))
	_firmware_indicator.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_firmware_indicator.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top_row.add_child(_firmware_indicator)

	# Emulator row: Icon + Dropdown
	var emulator_row = HBoxContainer.new()
	emulator_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_content.add_child(emulator_row)

	var emulator_icon = FontIcon.new()
	emulator_icon.icon_settings = FontIconSettings.new()
	emulator_icon.icon_settings.icon_name = "gamepad"
	emulator_icon.icon_settings.icon_size = M3Units.dp(20)
	emulator_icon.icon_settings.icon_color = M3Theme.get_on_surface_variant()
	emulator_row.add_child(emulator_icon)

	_emulator_dropdown = M3OptionButton.new()
	_emulator_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Placeholder text shown while dropdown population is deferred.
	_emulator_dropdown.add_item("Loading...", 0)
	emulator_row.add_child(_emulator_dropdown)
	_connect_emulator_dropdown()

	# Status row: Indicator + Download button + version label
	_status_row = HBoxContainer.new()
	_status_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_content.add_child(_status_row)

	_status_indicator = Indicator.new()
	_status_indicator.dot_size = Vector2(M3Units.dp(10), M3Units.dp(10))
	_status_indicator.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_row.add_child(_status_indicator)

	_download_button = M3Button.new()
	_download_button.text = "Download"
	_download_button.visible = false
	_download_button.button_size = M3Button.Size.EXTRA_SMALL
	_status_row.add_child(_download_button)
	_connect_download_button()

	_version_label = M3Label.new()
	_version_label.visible = false
	_version_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_status_row.add_child(_version_label)

	# Apply M3 fonts and colors
	_apply_m3_text_styles()
	_update_shuffler_mode()

func _has_media_content() -> bool:
	return false

func _update_media_panel_size(force: bool = false) -> void:
	super._update_media_panel_size(force)
	if not is_node_ready():
		return
	# Size the text area to the card's actual rect, not the requested minimum,
	# so cards that are narrower than their custom_minimum_size still clip their
	# content correctly.
	var pad := M3Units.dp(PADDING)
	if card_layout_mode == LayoutMode.HORIZONTAL:
		if _text_row:
			_text_row.position = Vector2(pad, M3Units.dp(PADDING / 2.0))
			_text_row.size = Vector2(maxf(0.0, size.x - pad * 2.0), maxf(0.0, size.y - pad * 1.5))
	else:
		if _text_content:
			_text_content.position = Vector2(pad, M3Units.dp(PADDING / 2.0))
			_text_content.size = Vector2(maxf(0.0, size.x - pad * 2.0), maxf(0.0, size.y - pad * 1.5))

func _apply_m3_text_styles():
	if _name_label:
		_name_label.label_style = M3Label.Style.TITLE_MEDIUM

	if _version_label:
		_version_label.label_style = M3Label.Style.BODY_SMALL
		_version_label.use_on_surface_variant = true

func _update_display():
	if not is_node_ready():
		return

	_name_label.text = platform_name if platform_name else platform_slug
	_sync_toggle.set_pressed_no_signal(is_sync_enabled)

	# Update emulator dropdown
	_update_emulator_dropdown()

func _update_emulator_dropdown():
	if not _emulator_dropdown:
		return
	if _is_rebuilding_dropdown:
		return
	_is_rebuilding_dropdown = true
	
	# Disconnect the selection signal so restoring the selected index can't
	# re-trigger _on_emulator_selected while we're rebuilding.
	if _emulator_dropdown.item_selected.is_connected(_on_emulator_selected):
		_emulator_dropdown.item_selected.disconnect(_on_emulator_selected)
	
	# clear() is shadowed by LineEdit.clear(), so use the M3OptionButton API.
	_emulator_dropdown.clear_items()
	_dropdown_entries.clear()

	# Compute the available standalone emulators and RetroArch cores.
	var standalone_options: Array[Dictionary] = []
	for i in range(_available_emulators.size()):
		var emulator = _available_emulators[i]
		var emulator_id = emulator.get("id", "")
		if emulator_id == "" or emulator_id == "retroarch":
			continue
		standalone_options.append(emulator)
	
	var retroarch_cores: Array[Dictionary] = []
	if _has_retroarch():
		retroarch_cores = _get_available_retroarch_cores()
	
	# Determine the default core id for RetroArch when that's the platform default.
	# Prefer the cached value supplied by the parent view.
	var default_core_id = ""
	if registry_default_emulator == "retroarch":
		if registry_default_core_id != "":
			default_core_id = registry_default_core_id
		else:
			default_core_id = LaunchManager.get_default_core_id_for_platform("retroarch", platform_slug) if LaunchManager else ""

	# Add "Auto" option first if we have a registry default
	var selected_index = 0
	if registry_default_emulator != "":
		var default_text = _get_default_entry_text(registry_default_emulator)
		var auto_text = default_text + " (Auto)"
		_emulator_dropdown.add_item(auto_text, 0)
		_dropdown_entries.append({"type": "auto", "emulator_id": "", "core_id": ""})
	else:
		_emulator_dropdown.add_item("Not Configured", 0)
		_dropdown_entries.append({"type": "auto", "emulator_id": "", "core_id": ""})

	# Add non-default standalone emulators
	for emulator in standalone_options:
		var emulator_id = emulator.get("id", "")
		# Skip the default standalone emulator; it's represented by Auto.
		if emulator_id == registry_default_emulator:
			continue
		var emulator_name = emulator.get("name", emulator_id)
		var index = _dropdown_entries.size()
		_emulator_dropdown.add_item(emulator_name, index)
		_dropdown_entries.append({"type": "emulator", "emulator_id": emulator_id, "core_id": ""})
		if emulator_id == selected_emulator:
			selected_index = index

	# Add non-default RetroArch core options grouped together
	for core in retroarch_cores:
		var core_id = core.get("id", "")
		# Skip the default RetroArch core; it's represented by Auto.
		if registry_default_emulator == "retroarch" and core_id == default_core_id:
			continue
		var core_name = core.get("name", core_id)
		var index = _dropdown_entries.size()
		_emulator_dropdown.add_item("RetroArch - " + core_name, index)
		_dropdown_entries.append({"type": "core", "emulator_id": "retroarch", "core_id": core_id})
		if selected_emulator == "retroarch" and selected_core_id == core_id:
			selected_index = index

	# If the current selection matches the default, treat it as Auto so the UI
	# doesn't show a non-existent explicit entry.
	if registry_default_emulator != "":
		if selected_emulator == "":
			selected_index = 0
		elif selected_emulator == registry_default_emulator and registry_default_emulator != "retroarch":
			selected_index = 0
		elif selected_emulator == "retroarch" and selected_core_id == default_core_id:
			selected_index = 0

	_emulator_dropdown.selected = selected_index
	
	# Reconnect the selection signal now that the rebuild is done.
	if not _emulator_dropdown.item_selected.is_connected(_on_emulator_selected):
		_emulator_dropdown.item_selected.connect(_on_emulator_selected)
	
	_is_rebuilding_dropdown = false
	_update_status_indicator()

func _get_default_entry_text(emulator_id: String) -> String:
	if emulator_id == "retroarch":
		var default_core_id = registry_default_core_id
		if default_core_id == "" and LaunchManager:
			default_core_id = LaunchManager.get_default_core_id_for_platform("retroarch", platform_slug)
		var default_core_name = _get_core_display_name(default_core_id)
		return "RetroArch - " + default_core_name if default_core_name != "" else "RetroArch"
	return _get_emulator_name(emulator_id)

func _get_core_display_name(core_id: String) -> String:
	var cores = _get_available_retroarch_cores()
	for core in cores:
		if core.get("id", "") == core_id:
			return core.get("name", core_id)
	return core_id

func _has_retroarch() -> bool:
	for emu in _available_emulators:
		if emu.get("id", "") == "retroarch":
			return true
	return false

func _get_available_retroarch_cores() -> Array[Dictionary]:
	if platform_slug == "" or not LaunchManager:
		return []
	var all_cores = LaunchManager.get_cores_for_platform("retroarch", platform_slug)
	var filtered: Array[Dictionary] = []
	for core in all_cores:
		if core.get("desktop_only", false) and SystemManager.platform.is_android():
			continue
		if core.get("android_only", false) and not SystemManager.platform.is_android():
			continue
		filtered.append(core)
	return filtered

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

	# Check for active download/extraction via SystemManager.download
	var is_downloading = false
	var is_extracting = false
	var download_progress = -1.0
	if LaunchManager:
		var active_download = LaunchManager.get_emulator_active_download(effective_emulator)
		if active_download != null:
			if active_download.status == "downloading":
				is_downloading = true
				download_progress = active_download.progress
			elif active_download.status == "extracting" or active_download.status == "extract_pending":
				is_extracting = true

	if LaunchManager and LaunchManager.is_emulator_install_progress_extracting(effective_emulator):
		is_extracting = true

	# Update version label
	if _version_label:
		if progress["status"] == "complete" and DataManager:
			var version_setting = DataManager.get_setting("installed_emulator_versions")
			if version_setting:
				var versions = version_setting.value as Dictionary
				if versions and versions.has(effective_emulator):
					var raw_version = versions[effective_emulator]
					var display_version = _format_version_for_display(raw_version)
					_version_label.text = "v%s" % display_version
					_version_label.visible = true
				else:
					_version_label.text = "Unknown version"
					_version_label.visible = true
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
		if download_progress >= 0:
			display_text += " (%d%%)" % int(download_progress * 100)
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
	if _defer_dropdown:
		_pending_emulators = emulators
		return
	_available_emulators = emulators
	if is_node_ready():
		_update_emulator_dropdown()

## Populates the emulator dropdown after a deferred creation. Called by views
## that create many cards in a batch and want to split dropdown population into
## its own phase.
func populate_dropdown() -> void:
	if not _defer_dropdown:
		return
	_defer_dropdown = false
	_available_emulators = _pending_emulators
	_pending_emulators = []
	if is_node_ready():
		_update_emulator_dropdown()

func refresh_firmware_indicator() -> void:
	"""Refresh the firmware indicator. Safe to call frequently; the underlying
	LaunchManager call is cached, so repeated checks are cheap."""
	if not _firmware_indicator:
		return

	var effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator
	var core_id = selected_core_id if selected_emulator == "retroarch" else ""
	if effective_emulator == "" or platform_slug == "":
		_firmware_indicator.visible = false
		return

	if not LaunchManager:
		_firmware_indicator.visible = false
		return

	var expected_files = LaunchManager.get_platform_firmware_expected_files(platform_slug)
	if expected_files.is_empty():
		# No firmware required for this platform
		_firmware_indicator.visible = false
		return

	_firmware_indicator.visible = true
	var firmware_ready = LaunchManager.is_platform_firmware_ready(platform_slug, effective_emulator, core_id)
	var file_list = ", ".join(expected_files)
	if firmware_ready:
		_firmware_indicator.set_status(Indicator.Status.SUCCESS, "Firmware installed", "Expected firmware file(s): " + file_list)
	else:
		_firmware_indicator.set_status(Indicator.Status.ERROR, "Firmware missing", "Expected firmware file(s): " + file_list)

func _update_firmware_indicator() -> void:
	# Kept for backward compatibility; delegates to the cached refresh.
	refresh_firmware_indicator()

func set_emulator_install_status(status: Dictionary):
	_emulator_install_status = status
	if is_node_ready():
		_update_status_indicator()

func _update_shuffler_mode() -> void:
	if not is_node_ready():
		return
	if _status_row:
		_status_row.visible = not shuffler_mode
	if _firmware_indicator:
		_firmware_indicator.visible = not shuffler_mode
	refresh_firmware_indicator()

## Resets transient state and disconnects view-specific signals so this card
## can be safely returned to a pool and reused by a different view.
func reset_for_borrow() -> void:
	# Hide the card while it's being rebound so stale content doesn't flash.
	visible = false

	if _sync_toggle_connected:
		if _sync_toggle.toggled.is_connected(_on_sync_toggled):
			_sync_toggle.toggled.disconnect(_on_sync_toggled)
		_sync_toggle_connected = false

	if _emulator_dropdown_connected:
		if _emulator_dropdown.item_selected.is_connected(_on_emulator_selected):
			_emulator_dropdown.item_selected.disconnect(_on_emulator_selected)
		_emulator_dropdown_connected = false

	if _download_button_connected:
		if _download_button.pressed.is_connected(_on_download_pressed):
			_download_button.pressed.disconnect(_on_download_pressed)
		_download_button_connected = false

	# Disconnect any view-specific signal handlers so stale lambdas don't fire
	# when this card is reused by a different consumer.
	_disconnect_all("sync_toggled")
	_disconnect_all("emulator_changed")
	_disconnect_all("download_requested")

	# Clear per-view settings without triggering full display rebuilds
	shuffler_mode = false
	platform_slug = ""
	platform_name = ""
	registry_default_core_id = ""
	registry_default_emulator = ""
	selected_emulator = ""
	selected_core_id = ""
	is_sync_enabled = false
	_emulator_install_status = {}
	_available_emulators = []
	_available_cores = []
	_dropdown_entries = []
	_defer_dropdown = false
	_pending_emulators = []

	if _emulator_dropdown:
		_emulator_dropdown.clear()
		while _emulator_dropdown.get_item_count() > 0:
			_emulator_dropdown.remove_item(_emulator_dropdown.get_item_count() - 1)

	if _name_label:
		_name_label.text = ""

	if _sync_toggle:
		_sync_toggle.set_pressed_no_signal(false)

	if _status_indicator:
		_status_indicator.set_status(Indicator.Status.NEUTRAL, "", "")

	if _version_label:
		_version_label.text = ""
		_version_label.visible = false

	if _firmware_indicator:
		_firmware_indicator.visible = false

	if _download_button:
		_download_button.visible = false
		_download_button.disabled = false
		_download_button.text = "Download"

	if get_parent():
		get_parent().remove_child(self)

## Reconnects the card's internal control signals after a card has been
## returned to the pool. Call this before reusing a pooled card.
func prepare_for_borrow() -> void:
	_connect_sync_toggle()
	_connect_emulator_dropdown()
	_connect_download_button()

func _disconnect_all(signal_name: String) -> void:
	var connections = get_signal_connection_list(signal_name)
	for conn in connections:
		var callable := conn["callable"] as Callable
		if callable.is_valid():
			disconnect(signal_name, callable)

func _connect_sync_toggle() -> void:
	if not _sync_toggle_connected and _sync_toggle:
		_sync_toggle.toggled.connect(_on_sync_toggled)
		_sync_toggle_connected = true

func _connect_emulator_dropdown() -> void:
	if not _emulator_dropdown_connected and _emulator_dropdown:
		_emulator_dropdown.item_selected.connect(_on_emulator_selected)
		_emulator_dropdown_connected = true

func _connect_download_button() -> void:
	if not _download_button_connected and _download_button:
		_download_button.pressed.connect(_on_download_pressed)
		_download_button_connected = true

func _on_sync_toggled(enabled: bool):
	sync_toggled.emit(enabled)

func _on_emulator_selected(index: int):
	var entry = _dropdown_entries[index] if index >= 0 and index < _dropdown_entries.size() else {"type": "auto", "emulator_id": "", "core_id": ""}
	selected_emulator = entry["emulator_id"]
	selected_core_id = entry["core_id"]

	# Force step-based validation scan for this emulator
	var effective_emu = selected_emulator if selected_emulator != "" else registry_default_emulator
	if LaunchManager and effective_emu != "":
		LaunchManager.scan_emulator_install_state(effective_emu)
		LaunchManager.clear_firmware_cache(platform_slug, effective_emu, selected_core_id)

	emulator_changed.emit(selected_emulator, selected_core_id)
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

func refresh_ui() -> void:
	# Called by parent to refresh button states (e.g., when download starts/completes)
	var effective_emulator = selected_emulator if selected_emulator != "" else registry_default_emulator
	if effective_emulator != "" and LaunchManager:
		LaunchManager.scan_emulator_install_state(effective_emulator)

	_update_status_indicator()
	refresh_firmware_indicator()

## Formats a version string for display. If it's an ISO date, shows a friendly date.
## Otherwise returns the version string with v/V prefix stripped.
func _format_version_for_display(version: String) -> String:
	if version == "":
		return ""
	
	# Check if it looks like an ISO date
	var regex = RegEx.new()
	regex.compile("^(\\d{4})-(\\d{2})-(\\d{2})T")
	var match_result = regex.search(version)
	if match_result:
		var year = match_result.get_string(1)
		var month = match_result.get_string(2)
		var day = match_result.get_string(3)
		return year + "-" + month + "-" + day
	
	# Not a date - strip v/V prefix
	return version.trim_prefix("v").trim_prefix("V")
