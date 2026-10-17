class_name AndroidAppPicker
extends M3BottomSheet

## Bottom sheet for picking an installed Android app to pin to the nav bar.

signal app_selected(package: String, name: String, icon_base64: String)

const COLUMNS: int = 4
const MAX_SHEET_WIDTH_DP: float = 640.0
const MARGIN_H_DP: float = 16.0 + 24.0  # M3BottomSheet content margins
const CELL_SEPARATION_DP: float = 8.0

var _scroll: ScrollContainer = null
var _grid: GridContainer = null
var _loading_label: Label = null

var _apps: Array = []
var _cell_size: float = 64.0
var _texture_batch_id: int = -1
var _button_batch_id: int = -1

func _ready() -> void:
	super._ready()
	headline_text = "Select App"
	_build_content()

func _build_content() -> void:
	_loading_label = Label.new()
	_loading_label.text = "Loading apps..."
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_slot.add_child(_loading_label)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	_scroll.visible = false
	_content_slot.add_child(_scroll)

	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("hseparation", int(M3Units.dp(CELL_SEPARATION_DP)))
	_grid.add_theme_constant_override("vseparation", int(M3Units.dp(CELL_SEPARATION_DP)))
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_grid)

	call_deferred("_load_apps")

func _compute_cell_size() -> void:
	var viewport_width := get_viewport().get_visible_rect().size.x
	var sheet_width := minf(viewport_width, M3Units.dp(MAX_SHEET_WIDTH_DP))
	var content_width := maxf(sheet_width - M3Units.dp(MARGIN_H_DP), 1.0)
	var separation := M3Units.dp(CELL_SEPARATION_DP)
	_cell_size = (content_width - separation * (COLUMNS - 1)) / float(COLUMNS)

func _load_apps() -> void:
	if not Engine.has_singleton("KyodaiBridge"):
		push_error("[AndroidAppPicker] KyodaiBridge plugin not available")
		_loading_label.text = "Error: plugin not available"
		return

	var plugin = Engine.get_singleton("KyodaiBridge")
	var json_str: String = plugin.call("getInstalledLaunchableApps")
	if json_str.is_empty():
		_loading_label.text = "No apps found"
		return

	var parsed = JSON.parse_string(json_str)
	if parsed == null or not (parsed is Array):
		push_error("[AndroidAppPicker] Failed to parse app list")
		_loading_label.text = "Error parsing app list"
		return

	_apps = parsed
	_apps.sort_custom(func(a, b):
		return str(a.get("name", "")).to_lower() < str(b.get("name", "")).to_lower()
	)

	_compute_cell_size()
	_loading_label.visible = false
	_scroll.visible = true

	_texture_batch_id = MemorySubManager.start_batch(
		_apps,
		_decode_app_icon,
		MemorySubManager.BatchMode.IMAGE_THREAD,
		8,
		Callable(),
		_on_all_icons_decoded
	)

func _decode_app_icon(app: Dictionary, _index: int) -> Dictionary:
	var base64_str: String = app.get("icon", "")
	var image: Image = null
	if not base64_str.is_empty():
		var bytes = Marshalls.base64_to_raw(base64_str)
		if bytes.size() > 0:
			var img = Image.new()
			if img.load_png_from_buffer(bytes) == OK:
				image = img
	return {
		"image": image,
		"icon_base64": base64_str,
		"name": app.get("name", ""),
		"package": app.get("package", "")
	}

func _on_all_icons_decoded(results: Array) -> void:
	# Image threads may finish out of order; re-sort alphabetically before layout.
	results.sort_custom(func(a, b):
		return str(a.get("name", "")).to_lower() < str(b.get("name", "")).to_lower()
	)

	_button_batch_id = MemorySubManager.start_batch(
		results,
		_create_app_button,
		MemorySubManager.BatchMode.SYNC,
		4,
		Callable(),
		_on_all_buttons_created
	)

func _create_app_button(result: Dictionary, _index: int) -> void:
	var image = result.get("image")
	var texture: Texture2D = null
	if image is Image and not image.is_empty():
		texture = MemorySubManager.create_texture_from_image(image)

	var btn = AppPickerButton.new()
	btn.flat = true
	btn.icon = texture
	btn.expand_icon = true
	btn.alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	btn.custom_minimum_size = Vector2(_cell_size, _cell_size)
	btn.focus_mode = Control.FOCUS_ALL
	btn.pressed.connect(_on_app_pressed.bind(result.get("package", ""), result.get("name", ""), result.get("icon_base64", "")))
	_grid.add_child(btn)

func _on_all_buttons_created(_results: Array) -> void:
	"""Grab focus on the first app button so controller/keyboard users can navigate."""
	if _grid and _grid.get_child_count() > 0:
		var first_btn = _grid.get_child(0)
		if first_btn is Control and first_btn.focus_mode != Control.FOCUS_NONE:
			first_btn.grab_focus()

func _on_app_pressed(package_name: String, app_name: String, icon_base64: String) -> void:
	app_selected.emit(package_name, app_name, icon_base64)
	dismiss()

func _exit_tree() -> void:
	if _texture_batch_id >= 0:
		MemorySubManager.cancel_batch(_texture_batch_id)
		_texture_batch_id = -1
	if _button_batch_id >= 0:
		MemorySubManager.cancel_batch(_button_batch_id)
		_button_batch_id = -1
