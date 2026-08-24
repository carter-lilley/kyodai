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

# Rough per-unit cost estimates; precision doesn't matter, the cap does.
const COST_CARD_INSTANTIATE_US := 300
const COST_CARD_VISUAL_SETUP_US := 400
const COST_EFFECT_REBUILD_US := 600
const COST_PLATFORM_CARD_US := 150
const COST_SHADER_PREWARM_US := 2000

static var last_input_msec: int = 0
static var home_grid_settled: bool = false

static var _frame_start_us: int = 0
static var _frame_id: int = -1
static var _startup_mode: bool = true

## Called once per frame from MemorySubManager._process (first autoload, so
## it runs before every warmer's drain).
static func begin_frame() -> void:
	_frame_start_us = Time.get_ticks_usec()
	_frame_id = Engine.get_process_frames()

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
static func try_spend(estimated_us: int) -> bool:
	if _frame_id != Engine.get_process_frames():
		return true
	return Time.get_ticks_usec() - _frame_start_us + estimated_us <= _budget_us()

## Low-priority variant: refuses unless the interactive reserve stays intact.
static func try_spend_low(estimated_us: int) -> bool:
	return remaining_us() - estimated_us > int(_budget_us() * LOW_PRIORITY_RESERVE_RATIO)

static func remaining_us() -> int:
	if _frame_id != Engine.get_process_frames():
		return _budget_us()
	return maxi(0, _budget_us() - (Time.get_ticks_usec() - _frame_start_us))

static func _budget_us() -> int:
	return STARTUP_BUDGET_US if _startup_mode else STEADY_BUDGET_US
