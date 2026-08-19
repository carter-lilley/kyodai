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
var _indicator: Indicator = null
var _test_button: M3Button = null

func _ready() -> void:
	_build_ui()
	load_from_settings()
	refresh_indicator()

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
