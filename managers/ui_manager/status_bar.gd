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
const ANDROID_NET_IFACES_PATH := "/sys/class/net"
const ANDROID_PROC_WIRELESS_PATH := "/proc/net/wireless"

const CLOCK_FONT_PATH := "res://assets/fonts/MPLUS1-VariableFont_wght.ttf"
# OpenType 'wght' tag (0x77676874); M PLUS 1 supports 100-900.
const OPENTYPE_TAG_WGHT: int = 0x77676874
const CLOCK_FONT_WEIGHT: int = 850

enum PowerState { UNKNOWN, ON_BATTERY, NO_BATTERY, CHARGING, CHARGED }
enum WifiState { UNKNOWN, OFF, CONNECTED, ETHERNET_UP, ETHERNET_DOWN }

var _clock_label: Label = null
var _battery_label: Label = null
var _battery_icon: FontIcon = null
var _wifi_icon: FontIcon = null
var _hbox: HBoxContainer = null
var _poll_timer: Timer = null
var _poll_count: int = 0
var _battery_query_running: bool = false
var _battery_state: int = PowerState.UNKNOWN
var _battery_percent: int = -1
var _wifi_query_running: bool = false
var _wifi_state: int = WifiState.UNKNOWN
var _wifi_percent: int = -1
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
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_background = StyleBoxFlat.new()
	add_theme_stylebox_override("panel", _background)

	# PanelContainer fits each child into the same content rect, so the battery
	# cluster (right-aligned via expanding spacer) and the clock (center-aligned
	# over the full width) live in overlapping children. The clock stays dead
	# center regardless of whether the battery cluster is visible.
	_hbox = HBoxContainer.new()
	_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_hbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_hbox)

	var right_spacer := Control.new()
	right_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hbox.add_child(right_spacer)

	_wifi_icon = FontIcon.new()
	_wifi_icon.icon_settings = FontIconSettings.new()
	_wifi_icon.icon_settings.icon_font = "MaterialIcons"
	_wifi_icon.icon_settings.outline_color = Color.TRANSPARENT
	_wifi_icon.icon_settings.shadow_color = Color.TRANSPARENT
	_wifi_icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_wifi_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_wifi_icon.visible = false
	_hbox.add_child(_wifi_icon)

	_battery_label = Label.new()
	_battery_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_battery_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_battery_label.visible = false
	_hbox.add_child(_battery_label)

	_battery_icon = FontIcon.new()
	_battery_icon.icon_settings = FontIconSettings.new()
	_battery_icon.icon_settings.icon_font = "MaterialIcons"
	_battery_icon.icon_settings.outline_color = Color.TRANSPARENT
	_battery_icon.icon_settings.shadow_color = Color.TRANSPARENT
	_battery_icon.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_battery_icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hbox.add_child(_battery_icon)

	_apply_scale()

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
	_refresh_wifi()
	_apply_colors()


func refresh_theme() -> void:
	_apply_colors()


func refresh_scale() -> void:
	_apply_scale()
	refresh_theme()


func _apply_scale() -> void:
	custom_minimum_size = Vector2(0, M3Units.dp(BAR_HEIGHT_DP))
	if _background:
		var h_padding := M3Units.dp(16)
		_background.content_margin_left = h_padding
		_background.content_margin_right = h_padding
	if _hbox:
		_hbox.add_theme_constant_override("separation", M3Units.dp(6))
	if _battery_icon and _battery_icon.icon_settings:
		_battery_icon.icon_settings.icon_size = M3Units.dp(BATTERY_ICON_SIZE_DP)
	if _wifi_icon and _wifi_icon.icon_settings:
		_wifi_icon.icon_settings.icon_size = M3Units.dp(BATTERY_ICON_SIZE_DP)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_RESUMED:
		_update_clock()
		_refresh_battery()
		_refresh_wifi()


func _on_poll() -> void:
	_update_clock()
	_poll_count += 1
	if _poll_count % BATTERY_POLLS_PER_INTERVAL == 0:
		_refresh_battery()
		_refresh_wifi()


func set_polling_enabled(enabled: bool) -> void:
	"""Start/stop the clock+battery poll timer (e.g. paused while a game runs)."""
	if not _poll_timer:
		return
	if enabled:
		if _poll_timer.is_stopped():
			_update_clock()
			_refresh_battery()
			_refresh_wifi()
			_poll_timer.start()
	else:
		_poll_timer.stop()


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


func _refresh_wifi() -> void:
	if _wifi_query_running:
		return
	match OS.get_name():
		"Windows":
			# Folded into the battery query's single PowerShell invocation.
			pass
		"Android":
			_wifi_query_running = true
			WorkerThreadPool.add_task(_query_wifi_android)
		_:
			_wifi_icon.visible = false


func _query_wifi_android() -> void:
	# Wifi state via sysfs/procfs, readable with no permissions.
	var state := WifiState.UNKNOWN
	var percent := -1

	var iface := ""
	var dir := DirAccess.open(ANDROID_NET_IFACES_PATH)
	if dir:
		for entry in dir.get_directories():
			if entry.begins_with("wlan"):
				iface = entry
				break

	if not iface.is_empty():
		# NOTE: sysfs files report a bogus st_size, so get_as_text() fails its
		# length check and returns "". get_line() reads byte-by-byte instead.
		var operstate := ""
		var operstate_file := FileAccess.open(ANDROID_NET_IFACES_PATH + "/" + iface + "/operstate", FileAccess.READ)
		if operstate_file:
			operstate = operstate_file.get_line().strip_edges()

		if operstate == "up":
			state = WifiState.CONNECTED
			# Signal quality from /proc/net/wireless: "wlan0: 0000   62.  -48. ..."
			var wireless_file := FileAccess.open(ANDROID_PROC_WIRELESS_PATH, FileAccess.READ)
			if wireless_file:
				while wireless_file.get_position() < wireless_file.get_length():
					var line := wireless_file.get_line().strip_edges()
					if line.begins_with(iface + ":"):
						var tokens := line.split(" ", false)
						if tokens.size() >= 3:
							var quality := float(tokens[2].trim_suffix("."))
							percent = int(round(quality / 70.0 * 100.0))
						break
		else:
			state = WifiState.OFF
	call_deferred("_on_wifi_queried", state, percent)


func _on_wifi_queried(state: int, percent: int) -> void:
	_wifi_query_running = false
	_wifi_state = state
	_wifi_percent = percent
	_update_wifi_icon()


func _update_wifi_icon() -> void:
	if _wifi_state == WifiState.UNKNOWN:
		_wifi_icon.visible = false
		return

	_wifi_icon.visible = true
	match _wifi_state:
		WifiState.OFF:
			_wifi_icon.icon_settings.icon_name = "wifi-off"
		WifiState.ETHERNET_UP:
			_wifi_icon.icon_settings.icon_name = "ethernet-cable"
		WifiState.ETHERNET_DOWN:
			_wifi_icon.icon_settings.icon_name = "ethernet-cable-off"
		_:
			if _wifi_percent < 0:
				_wifi_icon.icon_settings.icon_name = "wifi"
			elif _wifi_percent < 25:
				_wifi_icon.icon_settings.icon_name = "wifi-strength-1"
			elif _wifi_percent < 50:
				_wifi_icon.icon_settings.icon_name = "wifi-strength-2"
			elif _wifi_percent < 75:
				_wifi_icon.icon_settings.icon_name = "wifi-strength-3"
			else:
				_wifi_icon.icon_settings.icon_name = "wifi-strength-4"
	_apply_colors()


func _query_battery_windows() -> void:
	var output: Array = []
	var exit_code := OS.execute("powershell", [
		"-NoProfile", "-NonInteractive", "-Command",
		"$b = Get-CimInstance Win32_Battery | Select-Object EstimatedChargeRemaining,BatteryStatus; $w = netsh wlan show interfaces | Out-String; $e = Get-NetAdapter -Physical | Select-Object Status,MediaType | ConvertTo-Json -Compress; @{ battery = $b; wlan = $w; eth = $e } | ConvertTo-Json -Compress"
	], output, true)
	var state := PowerState.UNKNOWN
	var percent := -1
	var wifi_state := WifiState.UNKNOWN
	var wifi_percent := -1
	if exit_code == 0:
		var raw := ""
		if not output.is_empty():
			raw = str(output[0]).strip_edges()
		if not raw.is_empty():
			var json := JSON.new()
			if json.parse(raw) == OK and json.data is Dictionary:
				var data: Dictionary = json.data
				var bat: Variant = data.get("battery")
				if bat is Array:
					bat = bat[0] if not bat.is_empty() else {}
				if bat is Dictionary and bat.has("EstimatedChargeRemaining"):
					percent = int(bat["EstimatedChargeRemaining"])
					var status := int(bat.get("BatteryStatus", 0))
					# Win32_Battery.BatteryStatus: 1 = discharging, 6-9/11 = charging
					if status in [6, 7, 8, 9, 11]:
						state = PowerState.CHARGING
					elif status == 1:
						state = PowerState.ON_BATTERY
					elif percent >= 100:
						state = PowerState.CHARGED
					else:
						state = PowerState.ON_BATTERY
				else:
					# Query succeeded but found no battery: desktop plugged into AC.
					state = PowerState.NO_BATTERY

				# netsh prints an error string when there is no wireless
				# interface; fall back to wired ethernet state then.
				var wlan := str(data.get("wlan", ""))
				if wlan.contains("State"):
					wifi_state = WifiState.OFF
					for line in wlan.split("\n"):
						var trimmed := line.strip_edges()
						if trimmed.begins_with("State"):
							if trimmed.get_slice(":", 1).strip_edges() == "connected":
								wifi_state = WifiState.CONNECTED
						elif trimmed.begins_with("Signal"):
							wifi_percent = int(trimmed.get_slice(":", 1).strip_edges().trim_suffix("%"))
				else:
					# eth is a nested JSON string (Get-NetAdapter output
					# serialized into the outer payload).
					var eth: Variant = data.get("eth")
					if eth is String:
						var eth_json := JSON.new()
						eth = eth_json.data if eth_json.parse(eth) == OK else null
					if eth is Dictionary:
						eth = [eth]
					if eth is Array and not eth.is_empty():
						var any_wired := false
						var any_up := false
						for adapter in eth:
							if adapter is Dictionary and not str(adapter.get("MediaType", "")).contains("802.11"):
								any_wired = true
								if str(adapter.get("Status", "")) == "Up":
									any_up = true
						if any_up:
							wifi_state = WifiState.ETHERNET_UP
						elif any_wired:
							wifi_state = WifiState.ETHERNET_DOWN
		if state == PowerState.UNKNOWN:
			# Query succeeded but returned no battery data: desktop plugged into AC.
			state = PowerState.NO_BATTERY
	else:
		print("[StatusBar] battery query failed, exit_code=", exit_code, " output=", output)
	call_deferred("_on_battery_queried", state, percent)
	call_deferred("_on_wifi_queried", wifi_state, wifi_percent)


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
	if _wifi_icon:
		_wifi_icon.icon_settings.icon_color = M3Theme.get_on_surface_variant()
