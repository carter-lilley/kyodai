class_name StatusBar
extends PanelContainer

## Slim status strip shown above the control bar: centered 12-hour clock and
## a right-aligned battery indicator. Refreshes on a timer and via
## refresh_theme() (called by ThemeSubManager on theme changes).
## Background is pure black in dark mode, pure white in light mode.
##
## Godot 4.7 removed the OS.get_power_* APIs, so battery data is read
## per-platform (Windows: Win32_Battery via PowerShell; Android: sysfs
## /sys/class/power_supply/battery) on a worker thread.
## The icon is hidden on platforms without a backend.

const BAR_HEIGHT_DP: int = 28
const BATTERY_ICON_SIZE_DP: int = 18
const BATTERY_LOW_PERCENT: int = 20
const POLL_INTERVAL_S: float = 8.0
const BATTERY_POLLS_PER_INTERVAL: int = 1

const ANDROID_BATTERY_CAPACITY_PATH := "/sys/class/power_supply/battery/capacity"
const ANDROID_BATTERY_STATUS_PATH := "/sys/class/power_supply/battery/status"

const CLOCK_FONT_PATH := "res://assets/fonts/MPLUS1-VariableFont_wght.ttf"
# OpenType 'wght' tag (0x77676874); M PLUS 1 supports 100-900.
const OPENTYPE_TAG_WGHT: int = 0x77676874
const CLOCK_FONT_WEIGHT: int = 850

enum PowerState { UNKNOWN, ON_BATTERY, NO_BATTERY, CHARGING, CHARGED }

var _clock_label: Label = null
var _battery_label: Label = null
var _battery_icon: FontIcon = null
var _poll_timer: Timer = null
var _poll_count: int = 0
var _battery_query_running: bool = false
var _battery_state: int = PowerState.UNKNOWN
var _battery_percent: int = -1
var _background: StyleBoxFlat = null
var _clock_font: FontVariation = null


static func _create_clock_font() -> FontVariation:
	var variation := FontVariation.new()
	variation.base_font = load(CLOCK_FONT_PATH)
	variation.variation_opentype = {OPENTYPE_TAG_WGHT: CLOCK_FONT_WEIGHT}
	return variation


func _ready() -> void:
	# Sit above the controlbar_mask vignette (z_index 5) like the toolbar does.
	z_index = 10
	custom_minimum_size = Vector2(0, M3Units.dp(BAR_HEIGHT_DP))
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_background = StyleBoxFlat.new()
	var h_padding := M3Units.dp(16)
	_background.content_margin_left = h_padding
	_background.content_margin_right = h_padding
	add_theme_stylebox_override("panel", _background)

	# PanelContainer fits each child into the same content rect, so the battery
	# cluster (right-aligned via expanding spacer) and the clock (center-aligned
	# over the full width) live in overlapping children. The clock stays dead
	# center regardless of whether the battery cluster is visible.
	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_theme_constant_override("separation", M3Units.dp(6))
	add_child(hbox)

	var right_spacer := Control.new()
	right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(right_spacer)

	_battery_label = Label.new()
	_battery_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_battery_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_battery_label.visible = false
	hbox.add_child(_battery_label)

	_battery_icon = FontIcon.new()
	_battery_icon.icon_settings = FontIconSettings.new()
	_battery_icon.icon_settings.icon_font = "MaterialIcons"
	_battery_icon.icon_settings.icon_size = M3Units.dp(BATTERY_ICON_SIZE_DP)
	_battery_icon.icon_settings.outline_color = Color.TRANSPARENT
	_battery_icon.icon_settings.shadow_color = Color.TRANSPARENT
	_battery_icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_battery_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(_battery_icon)

	# Added after hbox so it draws on top if the window gets extremely narrow.
	_clock_label = Label.new()
	_clock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_clock_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_clock_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_clock_label)

	_poll_timer = Timer.new()
	_poll_timer.wait_time = POLL_INTERVAL_S
	_poll_timer.timeout.connect(_on_poll)
	add_child(_poll_timer)
	_poll_timer.start()

	_update_clock()
	_refresh_battery()
	_apply_colors()


func refresh_theme() -> void:
	_apply_colors()


func _on_poll() -> void:
	_update_clock()
	_poll_count += 1
	if _poll_count % BATTERY_POLLS_PER_INTERVAL == 0:
		_refresh_battery()


func _update_clock() -> void:
	var t: Dictionary = Time.get_time_dict_from_system()
	var hour: int = t["hour"]
	var period: String = "AM" if hour < 12 else "PM"
	hour = hour % 12
	if hour == 0:
		hour = 12
	_clock_label.text = "%d:%02d %s" % [hour, t["minute"], period]


func _refresh_battery() -> void:
	if _battery_query_running:
		return
	match OS.get_name():
		"Windows":
			_battery_query_running = true
			WorkerThreadPool.add_task(_query_battery_windows)
		"Android":
			_battery_query_running = true
			WorkerThreadPool.add_task(_query_battery_android)
		_:
			_battery_icon.visible = false
			_battery_label.visible = false


func _query_battery_windows() -> void:
	var output: Array = []
	var exit_code := OS.execute("powershell", [
		"-NoProfile", "-NonInteractive", "-Command",
		"Get-CimInstance Win32_Battery | Select-Object EstimatedChargeRemaining,BatteryStatus | ConvertTo-Json -Compress"
	], output, true)
	var state := PowerState.UNKNOWN
	var percent := -1
	if exit_code == 0:
		var raw := ""
		if not output.is_empty():
			raw = str(output[0]).strip_edges()
		var parsed := false
		if not raw.is_empty():
			var json := JSON.new()
			if json.parse(raw) == OK:
				var data: Variant = json.data
				if data is Array:
					data = data[0] if not data.is_empty() else {}
				if data is Dictionary and data.has("EstimatedChargeRemaining"):
					parsed = true
					percent = int(data["EstimatedChargeRemaining"])
					var status := int(data.get("BatteryStatus", 0))
					# Win32_Battery.BatteryStatus: 1 = discharging, 6-9/11 = charging
					if status in [6, 7, 8, 9, 11]:
						state = PowerState.CHARGING
					elif status == 1:
						state = PowerState.ON_BATTERY
					elif percent >= 100:
						state = PowerState.CHARGED
					else:
						state = PowerState.ON_BATTERY
		if not parsed:
			# Query succeeded but found no battery: desktop plugged into AC.
			state = PowerState.NO_BATTERY
	else:
		print("[StatusBar] battery query failed, exit_code=", exit_code, " output=", output)
	call_deferred("_on_battery_queried", state, percent)


func _query_battery_android() -> void:
	# Android exposes battery info via sysfs, readable with no permissions.
	var state := PowerState.UNKNOWN
	var percent := -1

	var capacity_file := FileAccess.open(ANDROID_BATTERY_CAPACITY_PATH, FileAccess.READ)
	if capacity_file:
		# NOTE: sysfs files report a bogus st_size, so get_as_text() fails its
		# length check and returns "". get_line() reads byte-by-byte instead.
		percent = int(capacity_file.get_line().strip_edges())
		state = PowerState.ON_BATTERY

		var status_file := FileAccess.open(ANDROID_BATTERY_STATUS_PATH, FileAccess.READ)
		if status_file:
			match status_file.get_line().strip_edges():
				"Charging":
					state = PowerState.CHARGING
				"Full":
					state = PowerState.CHARGED
				_:
					state = PowerState.ON_BATTERY
	else:
		print("[StatusBar] android battery capacity not readable at ", ANDROID_BATTERY_CAPACITY_PATH)
	call_deferred("_on_battery_queried", state, percent)


func _on_battery_queried(state: int, percent: int) -> void:
	_battery_query_running = false
	_battery_state = state
	_battery_percent = percent
	_update_battery_icon()


func _update_battery_icon() -> void:
	if _battery_state == PowerState.UNKNOWN:
		_battery_icon.visible = false
		_battery_label.visible = false
		return

	if _battery_state == PowerState.NO_BATTERY:
		# No battery detected (desktop): show a plugged-in icon instead.
		_battery_icon.visible = true
		_battery_icon.icon_settings.icon_name = "power-plug-battery"
		_battery_label.visible = false
		_apply_colors()
		return

	_battery_icon.visible = true
	_battery_label.text = "%d%%" % _battery_percent
	_battery_label.visible = true
	match _battery_state:
		PowerState.CHARGING:
			_battery_icon.icon_settings.icon_name = "battery-charging"
		PowerState.CHARGED:
			_battery_icon.icon_settings.icon_name = "battery"
		_:
			if _battery_percent >= 95:
				_battery_icon.icon_settings.icon_name = "battery"
			elif _battery_percent < 10:
				_battery_icon.icon_settings.icon_name = "battery-outline"
			else:
				_battery_icon.icon_settings.icon_name = "battery-%d" % int(round(_battery_percent / 10.0) * 10)

	_apply_colors()


func _apply_colors() -> void:
	if _background:
		_background.bg_color = Color.BLACK if M3Theme.is_dark_mode else Color.WHITE
	if _clock_font == null:
		_clock_font = _create_clock_font()
	if _clock_label:
		_clock_label.add_theme_font_override("font", _clock_font)
		_clock_label.add_theme_font_size_override("font_size", M3Units.dp(14))
		_clock_label.add_theme_color_override("font_color", M3Theme.get_on_surface_variant())
	if not _battery_icon:
		return
	var color := M3Theme.get_on_surface_variant()
	if _battery_percent >= 0 and _battery_percent < BATTERY_LOW_PERCENT and _battery_state == PowerState.ON_BATTERY:
		color = M3Theme.get_error()
	_battery_icon.icon_settings.icon_color = color
	if _battery_label:
		_battery_label.add_theme_font_override("font", _clock_font)
		_battery_label.add_theme_font_size_override("font_size", M3Units.dp(14))
		_battery_label.add_theme_color_override("font_color", color)
