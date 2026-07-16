class_name CollectionPicker
extends M3Dialog

signal collection_selected(collection_id: int, collection_name: String)

var _option_button: M3OptionButton = null
var _refresh_hint: Label = null
var _collections: Array[Dictionary] = []
var _pinned_ids: Array[int] = []
var _is_syncing: bool = false

func _init():
	super._init()
	title_text = "Pin Collection"
	dismissible = true
	disable_default_action = true

func _ready():
	super._ready()
	_build_content()
	_add_actions()
	_load_collections()
	_refresh_collections()

func set_pinned_ids(ids: Array[int]) -> void:
	_pinned_ids = ids.duplicate()
	_update_option_items()

func _build_content() -> void:
	if not content_slot:
		return
	
	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", int(M3Units.dp(16)))
	content_slot.add_child(vbox)
	
	var body = Label.new()
	body.text = "Choose a RomM collection to pin to the navigation bar."
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(body)
	
	_option_button = M3OptionButton.new()
	_option_button.placeholder_text = "Select a collection..."
	_option_button.leading_icon = "star"
	_option_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_option_button.item_selected.connect(_on_collection_selected)
	vbox.add_child(_option_button)
	
	_refresh_hint = Label.new()
	_refresh_hint.name = "RefreshHint"
	_refresh_hint.text = "Syncing collections..."
	_refresh_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_refresh_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_refresh_hint.visible = false
	vbox.add_child(_refresh_hint)

func _add_actions() -> void:
	add_action("Cancel", _on_cancel, false)
	add_action("Pin", _on_pin, true)

func _on_cancel() -> void:
	dismiss()

func _on_pin() -> void:
	if _option_button == null:
		return
	var selected_idx = _option_button.selected
	if selected_idx < 0 or selected_idx >= _collections.size():
		return
	var collection = _collections[selected_idx]
	var id = collection.get("id", 0)
	var name = collection.get("name", "")
	if id == 0:
		return
	collection_selected.emit(id, name)
	dismiss()

func _on_collection_selected(_index: int) -> void:
	pass

func _load_collections() -> void:
	var raw = DataManager.get_collections()
	_collections = []
	for c in raw:
		var name = c.get("name", "")
		if name is String and name.strip_edges() != "":
			_collections.append(c)
	_update_option_items()

func _update_option_items() -> void:
	if _option_button == null:
		return
	_option_button.clear_items()
	var valid_count = 0
	for i in range(_collections.size()):
		var collection = _collections[i]
		var id = collection.get("id", 0)
		var name = collection.get("name", "")
		var disabled = id == 0 or _pinned_ids.has(id)
		_option_button.add_item(name, id)
		if disabled:
			_option_button.set_item_disabled(i, true)
		else:
			valid_count += 1
	
	if valid_count == 0 and _collections.size() > 0:
		_option_button.placeholder_text = "All collections already pinned"
	elif _collections.size() == 0:
		_option_button.placeholder_text = "No collections available"
	else:
		_option_button.placeholder_text = "Select a collection..."

func _refresh_collections() -> void:
	if _is_syncing:
		return
	if not SystemManager.network or not SystemManager.network.is_configured():
		return
	_is_syncing = true
	_set_refresh_hint(true)
	DataManager.sync_collections(func(success: bool, _message: String):
		_is_syncing = false
		_set_refresh_hint(false)
		if success:
			_load_collections()
	)

func _set_refresh_hint(visible: bool) -> void:
	if _refresh_hint == null:
		return
	_refresh_hint.visible = visible

func _on_action_pressed(label: String) -> void:
	action_pressed.emit(label)
	match label:
		"Pin":
			_on_pin()
		"Cancel":
			_on_cancel()

func _on_close_button_pressed() -> void:
	dismiss()
