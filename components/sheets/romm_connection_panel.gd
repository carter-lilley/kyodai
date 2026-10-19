class_name RommConnectionPanel
extends VBoxContainer

signal connection_tested(success: bool)
signal connection_succeeded
signal connection_failed

@export var test_button_text: String = "Test"
@export var test_button_variant: M3Button.Variant = M3Button.Variant.TONAL
@export var test_button_size: M3Button.Size = M3Button.Size.MEDIUM
@export var show_description: bool = true
@export var description_text: String = "Connect to your RomM server to browse and download games."
## Draw a rule under the description. Disable when the panel lives inside a
## SettingsSection card, which already provides visual separation.
@export var show_separator: bool = true

var _description_label: M3Label = null
var _url_field: M3TextField = null
var _username_field: M3TextField = null
var _password_field: M3TextField = null
var _http_warning_label: M3Label = null
var _http_ack_checkbox: M3Checkbox = null
var _last_eval_origin: String = ""
var _indicator: Indicator = null
var _test_button: M3Button = null

func _ready() -> void:
	_build_ui()
	load_from_settings()
	refresh_indicator()
	_update_http_warning()

## Plain http:// sends the Basic-auth credentials (and all traffic) in
## cleartext. Legitimate on a trusted LAN, so we warn instead of banning -
## but the user must explicitly acknowledge before connecting (KYD-07).
func _is_insecure_http(url: String) -> bool:
	return url.strip_edges().to_lower().begins_with("http://")

## Normalized "http://host:port" for an insecure URL ("" otherwise), matched
## against the persisted one-time acknowledgment.
func _http_origin(url: String) -> String:
	if not _is_insecure_http(url):
		return ""
	var parts: Dictionary = SystemManager.network.parse_url(url.strip_edges())
	if parts.host == "":
		return ""
	return parts.protocol.to_lower() + "://" + parts.host.to_lower() + ":" + str(parts.port)

func _update_http_warning() -> void:
	var insecure := _is_insecure_http(_url_field.text) if _url_field else false
	if _http_warning_label:
		_http_warning_label.visible = insecure
	if _http_ack_checkbox:
		_http_ack_checkbox.visible = insecure
		var origin := _http_origin(_url_field.text) if insecure else ""
		if origin == _last_eval_origin:
			return  # keep the user's manual tick stable while typing
		_last_eval_origin = origin
		# Pre-tick when this exact origin was acknowledged in a previous
		# session; a new or different http origin must be re-acknowledged.
		var ack := ""
		var ack_setting = DataManager.get_setting("romm_insecure_http_ack")
		if ack_setting:
			ack = str(ack_setting.value)
		_http_ack_checkbox.set_pressed_no_signal(origin != "" and origin == ack)

func _build_ui() -> void:
	if show_description and not description_text.is_empty():
		_description_label = M3Label.new()
		_description_label.text = description_text
		_description_label.label_style = M3Label.Style.BODY_MEDIUM
		add_child(_description_label)
		if show_separator:
			add_child(HSeparator.new())

	_url_field = M3TextField.new()
	_url_field.label_text = "RomM URL"
	_url_field.placeholder_text = "https://your-romm-server.com"
	_url_field.text_changed.connect(func(_new_text: String): _update_http_warning())
	add_child(_url_field)

	_username_field = M3TextField.new()
	_username_field.label_text = "Username"
	_username_field.placeholder_text = "username"
	add_child(_username_field)

	_password_field = M3TextField.new()
	_password_field.label_text = "Password"
	_password_field.placeholder_text = "password"
	_password_field.secret = true
	add_child(_password_field)

	_http_warning_label = M3Label.new()
	_http_warning_label.text = "Warning: http:// sends your username, password, and all downloads unencrypted. Only use it on trusted local networks - use HTTPS if this server is reachable from the internet."
	_http_warning_label.label_style = M3Label.Style.BODY_SMALL
	_http_warning_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_http_warning_label.visible = false
	add_child(_http_warning_label)

	_http_ack_checkbox = M3Checkbox.new()
	_http_ack_checkbox.text = "I understand the risk - allow insecure http://"
	_http_ack_checkbox.visible = false
	add_child(_http_ack_checkbox)

	var test_row := HBoxContainer.new()
	test_row.custom_minimum_size = Vector2(0, M3Units.dp(40))
	add_child(test_row)

	_indicator = Indicator.new()
	_indicator.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_indicator.set_status(Indicator.Status.NEUTRAL)
	test_row.add_child(_indicator)

	_test_button = M3Button.new()
	_test_button.text = test_button_text
	_test_button.button_variant = test_button_variant
	_test_button.button_size = test_button_size
	_test_button.pressed.connect(_on_test_pressed)
	test_row.add_child(_test_button)

func load_from_settings() -> void:
	var url_setting = DataManager.get_setting("romm_url")
	_url_field.text = url_setting.value if url_setting else ""

	var user_setting = DataManager.get_setting("romm_username")
	_username_field.text = user_setting.value if user_setting else ""

	var pass_setting = DataManager.get_setting("romm_password")
	_password_field.text = pass_setting.value if pass_setting else ""

func save_to_settings(only_if_complete: bool = false) -> void:
	var url := _url_field.text.strip_edges()
	var username := _username_field.text.strip_edges()
	var password := _password_field.text.strip_edges()

	if only_if_complete and (url.is_empty() or username.is_empty() or password.is_empty()):
		return

	# Never persist an insecure http:// configuration the user hasn't
	# explicitly acknowledged - the OOBE wizard saves without testing (KYD-07).
	if _is_insecure_http(url) and _http_ack_checkbox and not _http_ack_checkbox.button_pressed:
		if _indicator:
			_indicator.set_status(Indicator.Status.ERROR, "Insecure http:// connection - tick the acknowledgment to save")
		return

	# Persist the acknowledgment for this origin so it survives restarts;
	# switching to https leaves any stored ack untouched (it may be needed
	# again if the user switches back to the same http origin).
	var ack_setting = DataManager.get_setting("romm_insecure_http_ack")
	if ack_setting and _is_insecure_http(url):
		DataManager.set_setting(_http_origin(url), ack_setting)

	var url_setting = DataManager.get_setting("romm_url")
	var user_setting = DataManager.get_setting("romm_username")
	var pass_setting = DataManager.get_setting("romm_password")

	if url_setting:
		DataManager.set_setting(url, url_setting)
	if user_setting:
		DataManager.set_setting(username, user_setting)
	if pass_setting:
		DataManager.set_setting(password, pass_setting)

func test_connection() -> void:
	var url := _url_field.text.strip_edges()
	var username := _username_field.text.strip_edges()
	var password := _password_field.text.strip_edges()

	if url.is_empty() or username.is_empty() or password.is_empty():
		_indicator.set_status(Indicator.Status.ERROR, "Fill in all fields")
		connection_tested.emit(false)
		connection_failed.emit()
		return

	if _is_insecure_http(url) and _http_ack_checkbox and not _http_ack_checkbox.button_pressed:
		_indicator.set_status(Indicator.Status.ERROR, "Insecure http:// connection - tick the acknowledgment below to continue")
		connection_tested.emit(false)
		connection_failed.emit()
		return

	if _test_button:
		_test_button.disabled = true
	_indicator.set_status(Indicator.Status.WARNING, "Testing connection...")

	save_to_settings()
	DataManager.save_settings()

	SystemManager.network.test_connection(func(online: bool):
		if _test_button:
			_test_button.disabled = false

		if online:
			_indicator.set_status(Indicator.Status.SUCCESS, "Connected and authenticated")
			SystemManager.notifications.show_notification("Connected to RomM successfully", SystemManager.notifications.Type.SUCCESS)
			connection_tested.emit(true)
			connection_succeeded.emit()
		else:
			if not SystemManager.network.is_configured():
				_indicator.set_status(Indicator.Status.NEUTRAL, "Not configured (check URL, username, password)")
				SystemManager.notifications.show_notification("RomM not configured - check URL, username, password", SystemManager.notifications.Type.ERROR)
			else:
				_indicator.set_status(Indicator.Status.ERROR, "Connection failed - check credentials")
				SystemManager.notifications.show_notification("Connection failed - check credentials", SystemManager.notifications.Type.ERROR)
			connection_tested.emit(false)
			connection_failed.emit()
	)

func refresh_indicator() -> void:
	if not _indicator:
		return

	if SystemManager.network.is_online():
		_indicator.set_status(Indicator.Status.SUCCESS, "Connected and authenticated")
	elif not SystemManager.network.is_configured():
		_indicator.set_status(Indicator.Status.NEUTRAL, "Not configured")
	else:
		_indicator.set_status(Indicator.Status.ERROR, "Disconnected")

func focus_url_field() -> void:
	if _url_field:
		_url_field.grab_focus()

func get_url() -> String:
	return _url_field.text if _url_field else ""

func get_username() -> String:
	return _username_field.text if _username_field else ""

func get_password() -> String:
	return _password_field.text if _password_field else ""

func _on_test_pressed() -> void:
	test_connection()
