class_name WarmupBudget
extends RefCounted

## Shared per-frame main-thread time budget for background warmup work —
## grid pool growth, buffer expansion, visual setup, effect rebuilds,
## platform-card warming, shader prewarm, texture-upload callbacks. Every
## warmer is polite in isolation; this caps their AGGREGATE so the startup
## window can't stack them into blown frames.

const STARTUP_BUDGET_US := 3000
const STEADY_BUDGET_US := 500
## Low-priority warmers (platform card pool) must leave this fraction of the
## frame budget untouched so interactive work always wins the frame.
const LOW_PRIORITY_RESERVE_RATIO := 0.4

## Frame-spike monitor: logs any main-thread frame past the threshold, with
## the tags of whoever ran warmup work in it, for the first seconds of runtime.
const SPIKE_THRESHOLD_STARTUP_US := 25000
const SPIKE_THRESHOLD_STEADY_US := 50000
const SPIKE_MONITOR_WINDOW_MS := 15000

# Rough per-unit cost estimates; precision doesn't matter, the cap does.
const COST_CARD_INSTANTIATE_US := 300
const COST_PLATFORM_CARD_US := 150
const COST_SHADER_PREWARM_US := 2000
const COST_SETTINGS_CATEGORY_US := 2000

static var last_input_msec: int = 0
static var home_grid_settled: bool = false

static var _frame_start_us: int = 0
static var _frame_id: int = -1
static var _startup_mode: bool = true
static var _frame_tags: Array[String] = []
static var _app_start_ms: int = 0

## Called once per frame from MemorySubManager._process (first autoload, so
## it runs before every warmer's drain).
static func begin_frame() -> void:
	var now_us := Time.get_ticks_usec()
	if _app_start_ms == 0:
		_app_start_ms = Time.get_ticks_msec()
	elif _frame_start_us != 0:
		var prev_frame_us := now_us - _frame_start_us
		var threshold: int = SPIKE_THRESHOLD_STARTUP_US if _startup_mode else SPIKE_THRESHOLD_STEADY_US
		if prev_frame_us > threshold and Time.get_ticks_msec() - _app_start_ms < SPIKE_MONITOR_WINDOW_MS:
			# proc_us = main-thread script/processing time for the frame (frame_us
			# minus a large proc_us => the main thread was genuinely busy;
			# proc_us far below frame_us => we blocked on the render thread or
			# frame pacing, e.g. a GPU pipeline compile stalling the queue).
			var proc_us := int(Performance.get_monitor(Performance.TIME_PROCESS) * 1_000_000.0)
			print("[FrameSpike] frame_us=", prev_frame_us, " proc_us=", proc_us, " tags=", _frame_tags, " idle_ms=", input_idle_ms(), " startup=", _startup_mode)
	_frame_start_us = now_us
	_frame_id = Engine.get_process_frames()
	_frame_tags.clear()

## Records that warmup work ran (or tried to run) in the current frame, so a
## frame spike can be attributed to whoever was active in it.
static func tag(label: String) -> void:
	if _frame_id == Engine.get_process_frames() and not _frame_tags.has(label):
		_frame_tags.append(label)

static func is_startup_mode() -> bool:
	return _startup_mode

static func set_startup_mode(enabled: bool) -> void:
	_startup_mode = enabled

static func notify_home_grid_settled() -> void:
	home_grid_settled = true

static func note_input() -> void:
	last_input_msec = Time.get_ticks_msec()

static func input_idle_ms() -> int:
	return Time.get_ticks_msec() - last_input_msec

## True when the frame still has room for one more unit of warmup work.
## try_spend measures real elapsed time, so callers must check before EACH
## unit of work — the frame's actual spend accrues between checks.
## Gating applies ONLY during the startup window: in steady state these
## drains ARE the interactive path (scroll recycling) and must never starve.
static func try_spend(estimated_us: int, tag_name: String = "") -> bool:
	if tag_name != "":
		tag(tag_name)
	if not _startup_mode:
		return true
	if _frame_id != Engine.get_process_frames():
		return true
	# Always permit a single oversized unit per frame so no drain can starve
	# permanently when its cost estimate exceeds the whole budget.
	if estimated_us > _budget_us():
		return true
	return Time.get_ticks_usec() - _frame_start_us + estimated_us <= _budget_us()

## Low-priority variant: refuses unless the interactive reserve stays intact.
static func try_spend_low(estimated_us: int, tag_name: String = "") -> bool:
	if tag_name != "":
		tag(tag_name)
	if not _startup_mode:
		return true
	if estimated_us > _budget_us():
		return true
	return remaining_us() - estimated_us > int(_budget_us() * LOW_PRIORITY_RESERVE_RATIO)

static func remaining_us() -> int:
	if _frame_id != Engine.get_process_frames():
		return _budget_us()
	return maxi(0, _budget_us() - (Time.get_ticks_usec() - _frame_start_us))

static func _budget_us() -> int:
	return STARTUP_BUDGET_US if _startup_mode else STEADY_BUDGET_US
