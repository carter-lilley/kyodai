class_name GameSession
extends RefCounted

## Shared runtime-session model. RETAINED is reserved for later platform
## policies; Phase 1 uses LAUNCHING -> ACTIVE -> ENDED for ordinary launches.
enum State { LAUNCHING, ACTIVE, RETAINED, LOST, CLOSING, ENDED }
enum Backend { UNKNOWN, DESKTOP_PROCESS, ANDROID_TASK }

const MAX_RECOVERED_SESSION_SECONDS := 12 * 3600

var session_id: String = ""
var game: GameResource = null
var romm_id: int = 0
var title: String = ""
var platform_slug: String = ""
var emulator_id: String = ""
var backend: Backend = Backend.UNKNOWN
var state: State = State.LAUNCHING
var policy: Dictionary = {}

var start_unix: float = 0.0
var session_start_ms: int = 0
var runtime: Dictionary = {}
var owner: Dictionary = {}
var pending_path: String = ""
var active_elapsed_ms: int = 0
var last_resume_ms: int = 0
var last_resume_unix: float = 0.0
var has_active_timing := false

static func current_owner() -> Dictionary:
	return {
		"pid": OS.get_process_id(),
		"start_ticks": LaunchManager.process._process_start_ticks(OS.get_process_id()),
		"boot_id": LaunchManager.process._current_boot_id(),
	}

static func new_session(game: GameResource, backend: Backend, metadata: Dictionary = {}) -> GameSession:
	var session = GameSession.new()
	session.game = game
	session.romm_id = game.romm_id if game else int(metadata.get("romm_id", 0))
	session.title = game.get_display_name() if game else str(metadata.get("title", ""))
	session.platform_slug = game.platform_slug if game else str(metadata.get("platform_slug", ""))
	session.emulator_id = str(metadata.get("emulator_id", ""))
	session.backend = backend
	session.policy = metadata.get("policy", {}).duplicate(true)
	session.start_unix = Time.get_unix_time_from_system()
	session.session_start_ms = Time.get_ticks_msec()
	session.runtime = metadata.get("runtime", {}).duplicate(true)
	session.owner = metadata.get("owner", {}).duplicate(true)
	if session.owner.is_empty():
		session.owner = current_owner()
	var nonce := Crypto.new().generate_random_bytes(6).hex_encode()
	session.session_id = "%d-%d-%s" % [session.romm_id, int(session.start_unix * 1000.0), nonce]
	return session

static func from_pending(record: Dictionary, game: GameResource = null) -> GameSession:
	var session = GameSession.new()
	session.game = game
	session.session_id = str(record.get("session_id", ""))
	session.romm_id = int(record.get("romm_id", game.romm_id if game else 0))
	session.title = str(record.get("title", game.get_display_name() if game else ""))
	session.platform_slug = str(record.get("platform_slug", game.platform_slug if game else ""))
	session.emulator_id = str(record.get("emulator_id", ""))
	session.backend = backend_from_string(str(record.get("backend", "")))
	session.policy = record.get("policy", {}).duplicate(true)
	session.start_unix = float(record.get("start_unix", 0.0))
	session.runtime = record.get("runtime", {}).duplicate(true)
	session.owner = record.get("owner", {}).duplicate(true)
	session.pending_path = str(record.get("_pending_path", ""))
	# A restored session keeps wall-clock accounting anchored to the original
	# launch while subsequent finalization can still use a monotonic clock.
	var elapsed := maxi(0, int(Time.get_unix_time_from_system() - session.start_unix))
	session.session_start_ms = Time.get_ticks_msec() - elapsed * 1000
	session.active_elapsed_ms = int(record.get("active_elapsed_ms", 0))
	session.last_resume_unix = float(record.get("last_resume_unix", 0.0))
	session.has_active_timing = record.has("active_elapsed_ms") or record.has("last_resume_unix")
	if session.last_resume_unix > 0.0:
		session.last_resume_ms = Time.get_ticks_msec() - maxi(0, int((Time.get_unix_time_from_system() - session.last_resume_unix) * 1000.0))
	session.state = State.ACTIVE
	return session

static func backend_from_string(value: String) -> Backend:
	match value:
		"desktop_process": return Backend.DESKTOP_PROCESS
		"android_task": return Backend.ANDROID_TASK
		_: return Backend.UNKNOWN

static func backend_to_string(backend: Backend) -> String:
	match backend:
		Backend.DESKTOP_PROCESS: return "desktop_process"
		Backend.ANDROID_TASK: return "android_task"
		_: return "unknown"

func pending_record() -> Dictionary:
	return {
		"session_id": session_id,
		"romm_id": romm_id,
		"title": title,
		"platform_slug": platform_slug,
		"emulator_id": emulator_id,
		"backend": backend_to_string(backend),
		"policy": policy.duplicate(true),
		"start_unix": start_unix,
		"active_elapsed_ms": active_elapsed_ms,
		"last_resume_unix": last_resume_unix,
		"runtime": runtime.duplicate(true),
		"owner": owner.duplicate(true),
	}

func is_shuffler() -> bool:
	return str(policy.get("origin", "")) == "shuffler"

func resume_playtime() -> void:
	if last_resume_ms > 0:
		return
	last_resume_ms = Time.get_ticks_msec()
	last_resume_unix = Time.get_unix_time_from_system()

func pause_playtime() -> void:
	if last_resume_ms <= 0:
		return
	active_elapsed_ms += maxi(0, Time.get_ticks_msec() - last_resume_ms)
	last_resume_ms = 0
	last_resume_unix = 0.0

func active_seconds(end_unix: float = 0.0) -> int:
	var elapsed := active_elapsed_ms
	if last_resume_ms > 0:
		var end_ms := last_resume_ms
		if end_unix > 0.0:
			end_ms += maxi(0, int((end_unix - last_resume_unix) * 1000.0))
		else:
			end_ms = Time.get_ticks_msec()
		elapsed += maxi(0, end_ms - last_resume_ms)
	return maxi(0, int(elapsed / 1000))

func elapsed_seconds(end_unix: float = 0.0) -> int:
	if backend == Backend.ANDROID_TASK:
		return active_seconds(end_unix)
	var elapsed := maxi(0, int((Time.get_ticks_msec() - session_start_ms) / 1000))
	if end_unix > start_unix and start_unix > 0.0:
		elapsed = mini(elapsed, int(end_unix - start_unix))
	return elapsed

func recovered_elapsed_seconds(end_unix: float = 0.0) -> int:
	if backend == Backend.ANDROID_TASK and has_active_timing:
		if end_unix > 0.0:
			return active_seconds(end_unix)
		var elapsed := active_elapsed_ms
		if last_resume_ms > 0:
			elapsed += mini(maxi(0, Time.get_ticks_msec() - last_resume_ms), MAX_RECOVERED_SESSION_SECONDS * 1000)
		return maxi(0, int(elapsed / 1000))
	if start_unix <= 0.0:
		return 0
	if end_unix > start_unix:
		return maxi(0, int(end_unix - start_unix))
	return mini(maxi(0, int(Time.get_unix_time_from_system() - start_unix)), MAX_RECOVERED_SESSION_SECONDS)
