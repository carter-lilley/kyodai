class_name LibraryFilterSheet
extends M3SideSheet

## Side sheet for library filters.
## Currently a placeholder for upcoming IGDB metadata filters.

static var _instance: LibraryFilterSheet = null

func _init():
	super._init()
	persistent = true

func _ready():
	super._ready()
	_build_content()

func _build_content() -> void:
	if not _content_slot:
		return
	
	# Clear any existing placeholder content
	for child in _content_slot.get_children():
		child.queue_free()
	
	var placeholder := M3Label.new()
	placeholder.text = "IGDB filters coming soon"
	placeholder.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	placeholder.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	placeholder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	placeholder.use_on_surface_variant = true
	_content_slot.add_child(placeholder)

static func prepare() -> void:
	"""Pre-create the sheet so the first open doesn't stutter."""
	_ensure_instance(true)

static func show_sheet() -> LibraryFilterSheet:
	_ensure_instance(false)
	
	_instance.headline_text = "Filters"
	_instance.sheet_variant = Variant.MODAL
	_instance.show_overlay()
	return _instance

static func cleanup_instance() -> void:
	if _instance != null and is_instance_valid(_instance):
		if _instance.get_parent() == null:
			_instance.free()
	_instance = null

static func _ensure_instance(deferred_add: bool = false) -> void:
	if _instance != null and is_instance_valid(_instance):
		return
	
	_instance = LibraryFilterSheet.new()
	_instance.headline_text = "Filters"
	_instance.sheet_variant = Variant.MODAL
	_instance.persistent = true
	
	# Add to the overlay parent so _ready() runs and the UI is built in advance.
	# _ready() sets visible=false, so it stays hidden until show_sheet().
	# Use call_deferred when prepare() is called during a parent's _ready().
	var parent = M3Overlay.get_overlay_parent()
	if parent and _instance.get_parent() == null:
		if deferred_add:
			parent.add_child.call_deferred(_instance)
		else:
			parent.add_child(_instance)
