class_name SessionFeatureFlags
extends RefCounted

## Internal lifecycle feature switches. They intentionally live outside the
## user-facing Settings schema while the retained-session work is developed.
## Values can be overridden in project.godot or isolated tests with
## ProjectSettings.set_setting("kyodai/<flag>", value).
const ANDROID_RETAINED_SESSIONS := "android_retained_sessions"
const ANDROID_TASK_SNAPSHOTS := "android_task_snapshots"
const ANDROID_DISPLAY_TASK_MOVE := "android_display_task_move"

const DEFAULTS := {
	ANDROID_RETAINED_SESSIONS: false,
	ANDROID_TASK_SNAPSHOTS: false,
	ANDROID_DISPLAY_TASK_MOVE: false,
}

static func enabled(flag: String) -> bool:
	return bool(ProjectSettings.get_setting("kyodai/" + flag, DEFAULTS.get(flag, false)))

static func set_for_tests(flag: String, value: bool) -> void:
	ProjectSettings.set_setting("kyodai/" + flag, value)
