class_name View
extends Control

signal view_ready()
signal view_shown()
signal view_hidden()

var view_name: String = ""

# Lazy rebuild pattern - views marked for rebuild when hidden, rebuilt when shown
var needs_rebuild: bool = false
var needs_rebuild_reason: String = ""

func _ready():
	view_ready.emit()

func on_view_show():
	print("[%s] on_view_show() called, needs_rebuild=%s" % [view_name, str(needs_rebuild)])
	view_shown.emit()
	# Check if view needs to be rebuilt before showing
	check_and_rebuild_if_needed()

func on_view_hide():
	view_hidden.emit()

func mark_for_rebuild(reason: String = "") -> void:
	"""Mark this view as needing a rebuild. Will be rebuilt when next shown."""
	needs_rebuild = true
	needs_rebuild_reason = reason
	print("[%s] Marked for rebuild. Reason: %s" % [view_name, reason])

func check_and_rebuild_if_needed() -> void:
	"""Override in subclasses to rebuild if needs_rebuild is true."""
	print("[%s] check_and_rebuild_if_needed() called, needs_rebuild=%s" % [view_name, str(needs_rebuild)])
	if needs_rebuild:
		print("[%s] Rebuilding due to: %s" % [view_name, needs_rebuild_reason])
		perform_rebuild()
		needs_rebuild = false
		needs_rebuild_reason = ""
		print("[%s] Rebuild complete" % view_name)
	else:
		print("[%s] No rebuild needed" % view_name)

func perform_rebuild() -> void:
	"""Override in subclasses to perform the actual rebuild."""
	pass
