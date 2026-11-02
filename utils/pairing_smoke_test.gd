## Headless smoke test for the RomM pairing implementation:
##  1. NetworkSubManager.version_at_least handles release/suffix/edge versions.
##  2. The vendored Kenyoni QR addon encodes a verification URL into a texture.
##  3. RommConnectionPanel builds in every mode without script errors.
## Run: godot --headless --path . res://utils/pairing_smoke_test.tscn
## (scene-based so autoloads register before panel scripts compile)
extends Node

const NetworkScript = preload("res://managers/system_manager/network_sub_manager.gd")
const PollerScript = preload("res://utils/device_auth_poller.gd")
const PanelScript = preload("res://components/sheets/romm_connection_panel.gd")
# Preloaded purely to prove the panel's call sites still compile.
const OobeScript = preload("res://components/dialogs/oobe_wizard.gd")
const PlatformsSettingsScript = preload("res://view/platforms_settings_view.gd")
const QRRectScript = preload("res://addons/kenyoni/qr_code/qr_code_rect.gd")
const QRScript = preload("res://addons/kenyoni/qr_code/qr_code.gd")

var _failures := 0

## Fake pairing endpoint: replays canned /auth/device/token responses through
## the same callback shape as the real network layer (no HTTP involved).
class FakeNetwork extends NetworkScript:
	var responses: Array = []
	var calls := 0
	func device_auth_token(_base_url: String, _device_code: String, callback: Callable) -> void:
		var r: Dictionary = responses[mini(calls, responses.size() - 1)]
		calls += 1
		(func(): callback.call(r)).call_deferred()

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("OK   ", msg)
	else:
		_failures += 1
		printerr("FAIL ", msg)

func _ready() -> void:
	_test_version_compare()
	_test_heartbeat_version()
	_test_qr()
	await _test_poller()
	_test_panel()

## Regression: RomM nests the version under SYSTEM.VERSION - reading it flat
## made pairing report "server is unknown" and fail the 5.0 gate.
func _test_heartbeat_version() -> void:
	_check(NetworkScript.heartbeat_version({"SYSTEM": {"VERSION": "5.3.0", "GIT_BRANCH": ""}}) == "5.3.0", "nested SYSTEM.VERSION parsed")
	_check(NetworkScript.heartbeat_version({"SYSTEM": {"VERSION": "4.9.0"}}) == "4.9.0", "nested pre-5.0 version parsed")
	_check(NetworkScript.heartbeat_version({"VERSION": "5.0.0"}) == "5.0.0", "flat VERSION fallback")
	_check(NetworkScript.heartbeat_version({"version": "5.0.0"}) == "5.0.0", "flat version fallback")
	_check(NetworkScript.heartbeat_version({"SYSTEM": {}}) == "", "missing version yields empty string")
	_check(NetworkScript.heartbeat_version({}) == "", "empty heartbeat yields empty string")

func _test_version_compare() -> void:
	var min_v: String = NetworkScript.DEVICE_AUTH_MIN_VERSION
	_check(NetworkScript.version_at_least("5.0.0", min_v), "5.0.0 supports device auth")
	_check(NetworkScript.version_at_least("5.1.0", min_v), "5.1.0 supports device auth")
	_check(NetworkScript.version_at_least("5.0.1-beta.2", min_v), "5.0.1-beta.2 supports device auth")
	_check(NetworkScript.version_at_least("v5.0.0", min_v), "v-prefixed 5.0.0 supports device auth")
	_check(NetworkScript.version_at_least("5.0", min_v), "short 5.0 supports device auth")
	_check(NetworkScript.version_at_least("development", min_v), "development supports device auth")
	_check(NetworkScript.version_at_least("10.0.0", min_v), "10.0.0 supports device auth")
	_check(not NetworkScript.version_at_least("4.9.0", min_v), "4.9.0 does not support device auth")
	_check(not NetworkScript.version_at_least("4.10.0", min_v), "4.10.0 does not support device auth (numeric, not string compare)")
	_check(not NetworkScript.version_at_least("", min_v), "empty version does not support device auth")
	_check(not NetworkScript.version_at_least("garbage", min_v), "garbage version does not support device auth")

func _test_qr() -> void:
	var qr = QRRectScript.new()
	qr.mode = QRScript.Mode.BYTE
	qr.custom_minimum_size = Vector2(180, 180)
	add_child(qr)
	qr.data = "https://demo.romm.app/pair/device?code=ABCD-1234".to_utf8_buffer()
	await get_tree().process_frame
	_check(qr.texture != null and qr.texture.get_width() > 0, "QR texture generated for verification URL")
	qr.queue_free()

func _run_poller_scenario(responses: Array, expires_in: int = 30) -> Dictionary:
	var net := FakeNetwork.new()
	net.responses = responses
	var poller = PollerScript.new()
	poller.start(net, "https://demo.romm.app", {"device_code": "d", "interval": 1, "expires_in": expires_in})
	var result: Array = await poller.finished
	var calls := net.calls
	net.free()
	return {"outcome": result[0], "data": result[1], "calls": calls}

func _test_poller() -> void:
	var pending := {"status": 400, "data": {"detail": "authorization_pending"}, "error": ""}

	# pending -> approved: token payload surfaces
	var r := await _run_poller_scenario([pending,
		{"status": 200, "data": {"access_token": "rmm_abc", "device_id": "dev1"}, "error": ""}])
	_check(r.outcome == "approved" and r.data.get("access_token", "") == "rmm_abc", "poller approves after pending")

	# denial ends the flow immediately
	r = await _run_poller_scenario([pending, {"status": 400, "data": {"detail": "access_denied"}, "error": ""}])
	_check(r.outcome == "denied", "poller reports denial")

	# pending until the monotonic deadline -> expired
	r = await _run_poller_scenario([pending], 1)
	_check(r.outcome == "expired", "poller expires at the deadline")

	# transport failures are retried, not fatal (one failure then approval)
	r = await _run_poller_scenario([
		{"status": 0, "data": {}, "error": "Request failed with result: 5"},
		{"status": 200, "data": {"access_token": "rmm_abc", "device_id": "dev1"}, "error": ""}])
	_check(r.outcome == "approved", "poller retries a transient transport failure")

	# cancel stops the loop with no further polls
	var net := FakeNetwork.new()
	net.responses = [pending]
	var poller = PollerScript.new()
	poller.start(net, "https://demo.romm.app", {"device_code": "d", "interval": 1, "expires_in": 30})
	poller.cancel()
	var cancelled: Array = await poller.finished
	_check(cancelled[0] == "cancelled" and net.calls == 0, "cancel stops before the first poll")
	net.free()

func _test_panel() -> void:
	var panel = PanelScript.new()
	add_child(panel)
	await get_tree().process_frame
	_check(panel._url_field != null, "panel builds URL field")
	_check(panel._main_button != null, "panel builds pair button")
	_check(panel._paired_box != null and panel._connect_box != null and panel._pairing_box != null, "panel builds all mode containers")
	_check(panel._poller == null, "no poller running by default")

	# Pairing view with a representative server payload (no network involved).
	panel._show_pairing_view("https://demo.romm.app", {
		"device_code": "secret",
		"user_code": "ABCD-1234",
		"verification_path": "/pair/device",
		"verification_path_complete": "/pair/device?code=ABCD-1234",
		"expires_in": 600,
		"interval": 5,
	})
	_check(panel._pairing_box.visible, "pairing view shown")
	_check(panel._user_code_label.text == "ABCD-1234", "user code displayed")
	_check(panel._verification_label.text == "or open on another device: https://demo.romm.app/pair/device", "verification URL absolutized")
	_check(panel._open_browser_button != null and panel._open_browser_button.visible, "browser-open button shown")
	_check(panel._verification_complete_url == "https://demo.romm.app/pair/device?code=ABCD-1234", "complete verification URL stored for shell_open")
	panel._cancel_polling()
	panel._pairing_active = false
	panel._update_mode_visibility()
	panel.queue_free()

	print("[pairing-smoke] %s" % ("all checks passed" if _failures == 0 else "%d checks FAILED" % _failures))
	get_tree().quit(1 if _failures > 0 else 0)
