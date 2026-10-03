extends Manager

@onready var filesystem: FileSystemSubManager = $FileSystemSubManager
@onready var network: NetworkSubManager = $NetworkSubManager
@onready var download: DownloadSubManager = $DownloadSubManager
@onready var notifications: NotificationSubManager = $NotificationSubManager
@onready var memory: MemorySubManager = $MemorySubManager
@onready var display: DisplaySubManager = $DisplaySubManager
@onready var audio: AudioSubManager = $AudioSubManager
@onready var platform: PlatformSubManager = $PlatformSubManager
@onready var config: ConfigSubManager = $ConfigSubManager
@onready var resolution: ResolutionSubManager = $ResolutionSubManager

func _ready():
	download._update_concurrency_from_settings()
	# No in-app vsync: frame timing measured clean 60fps internally while the
	# output still juddered under gamescope, so the stall lives in the
	# present path (XWayland honors mailbox poorly). Render unthrottled and
	# let the compositor sample the latest frame; low processor mode already
	# keeps idle rendering on-demand, so there's no spin-waste.
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# project.godot sets 8000us; halve the idle sleep so low processor mode's
	# frame pacing isn't coarse against a 60Hz compositor.
	OS.low_processor_usage_mode_sleep_usec = 2000
	print("[SystemManager] display_driver=", DisplayServer.get_name(),
		" vsync=", DisplayServer.window_get_vsync_mode(),
		" gamemode=", platform.is_gamemode(),
		" screen=", DisplayServer.screen_get_size())
	# Compile all shader pipelines during the remaining startup window — before
	# the first visible frame — so first paint/focus/scroll never pay lazy
	# pipeline-compile hitches. Paced per frame by WarmupBudget gates inside
	# the prewarmer; Main keeps a later fallback kick (prewarm is idempotent).
	call_deferred("_kick_shader_prewarm")
	RenderingServer.frame_post_draw.connect(_on_frame_post_draw)

# Temporary frame-pacing diagnostic (gamescope tuning): measures the cadence
# of actually-drawn frames and logs a 5s rolling summary to session.log.
var _ft_last_usec := -1
var _ft_window_start_msec := 0
var _ft_count := 0
var _ft_sum_ms := 0.0
var _ft_max_ms := 0.0
var _ft_janky := 0

func _on_frame_post_draw() -> void:
	var now_usec := Time.get_ticks_usec()
	var now_msec := Time.get_ticks_msec()
	if _ft_window_start_msec == 0:
		_ft_window_start_msec = now_msec
	if _ft_last_usec >= 0:
		var ms := (now_usec - _ft_last_usec) / 1000.0
		_ft_count += 1
		_ft_sum_ms += ms
		if ms > _ft_max_ms:
			_ft_max_ms = ms
		if ms > 20.0:
			_ft_janky += 1
	_ft_last_usec = now_usec
	var elapsed := now_msec - _ft_window_start_msec
	if elapsed >= 5000 and _ft_count > 0:
		print("[FrameTiming] frames=", _ft_count,
			" fps=", snappedf(1000.0 * _ft_count / elapsed, 0.1),
			" avg_ms=", snappedf(_ft_sum_ms / _ft_count, 0.01),
			" max_ms=", snappedf(_ft_max_ms, 0.01),
			" janky(>20ms)=", _ft_janky)
		_ft_count = 0
		_ft_sum_ms = 0.0
		_ft_max_ms = 0.0
		_ft_janky = 0
		_ft_window_start_msec = now_msec

func _kick_shader_prewarm() -> void:
	# Let the autoload chain finish constructing before touching the viewport.
	await get_tree().process_frame
	await get_tree().process_frame
	ShaderPrewarmer.prewarm(get_tree())
