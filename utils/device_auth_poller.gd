class_name DeviceAuthPoller
extends RefCounted

## Drives the RomM device authorization poll loop (POST /api/auth/device/token)
## until the user approves/denies the pairing or the code expires.
##
## Port of Argosy's DeviceAuthPoller.kt behavior:
## - only access_denied and expired_token end the flow early; dropped requests,
##   5xx and proxy errors are retried with backoff so a user mid-approval in
##   the browser is never stranded by one bad response
## - slow_down (and 429, since the endpoint is rate-limited) backs the
##   interval off; pending nudges it back toward the server's base interval
## - the deadline is monotonic (Time.get_ticks_msec), not summed sleeps, so
##   request latency cannot push polling past the server's real expiry window

signal finished(outcome: String, data: Dictionary)
## outcome: "approved" (data = token payload: access_token, device_id, scopes,
## expires_at), "denied", "expired", "failed" (data.error), "cancelled".

const SLOW_DOWN_STEP_SECONDS := 5
const MAX_INTERVAL_SECONDS := 30
const MAX_CONSECUTIVE_FAILURES := 5

signal _poll_completed(result: Dictionary)

var _network: NetworkSubManager
var _base_url: String = ""
var _device_code: String = ""
var _interval: int = 5
var _expires_in: int = 600
var _cancelled := false
var _done := false

func start(network: NetworkSubManager, base_url: String, init_data: Dictionary) -> void:
	_network = network
	_base_url = base_url
	_device_code = str(init_data.get("device_code", ""))
	_interval = maxi(1, int(init_data.get("interval", 5)))
	_expires_in = maxi(1, int(init_data.get("expires_in", 600)))
	_cancelled = false
	_done = false
	_run()

func cancel() -> void:
	_cancelled = true

func _finish(outcome: String, data: Dictionary) -> void:
	if _done:
		return
	_done = true
	finished.emit(outcome, data)

func _run() -> void:
	var base_interval := _interval
	var interval := base_interval
	var failures := 0
	var deadline := Time.get_ticks_msec() + _expires_in * 1000

	while not _cancelled:
		await _sleep(interval)
		if _cancelled:
			break

		var result: Dictionary = await _poll_once()
		var status: int = int(result.get("status", 0))
		var data: Variant = result.get("data", {})

		if status == 200 and data is Dictionary and str(data.get("access_token", "")) != "":
			_finish("approved", data)
			return

		var detail := ""
		if data is Dictionary and data.get("detail") is String:
			detail = data.detail

		match detail:
			"authorization_pending":
				failures = 0
				interval = maxi(base_interval, interval - 1)
			"slow_down":
				failures = 0
				interval = mini(MAX_INTERVAL_SECONDS, interval + SLOW_DOWN_STEP_SECONDS)
			"access_denied":
				_finish("denied", {})
				return
			"expired_token":
				_finish("expired", {})
				return
			_:
				if status == 429:
					# Rate-limited: not a failure, just back off harder.
					failures = 0
					interval = mini(MAX_INTERVAL_SECONDS, interval + SLOW_DOWN_STEP_SECONDS)
				else:
					failures += 1
					if failures >= MAX_CONSECUTIVE_FAILURES:
						_finish("failed", {"error": str(result.get("error", "Pairing failed (HTTP %d)" % status))})
						return
					interval = mini(MAX_INTERVAL_SECONDS, interval * 2)

		if Time.get_ticks_msec() >= deadline:
			_finish("expired", {})
			return

	_finish("cancelled", {})

func _poll_once() -> Dictionary:
	_network.device_auth_token(_base_url, _device_code, func(result: Dictionary):
		_poll_completed.emit(result)
	)
	return await _poll_completed

func _sleep(seconds: float) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree:
		await tree.create_timer(seconds).timeout
