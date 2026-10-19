class_name GamenativeSettingsView
extends View

var _games_container: VBoxContainer
var _app_id_input: M3TextField
var _add_button: M3Button
var _status_label: M3Label
var _backend_option: M3OptionButton
var _scroll_container: ScrollContainer
var _margin: MarginContainer
var _vbox: VBoxContainer
var _add_row: HBoxContainer
var _bottom_buffer: Control
var _is_initializing: bool = false

func _ready():
	view_name = "GameNative"
	_is_initializing = true
	_build_view()
	_refresh_games_list()
	_is_initializing = false
	
	# Connect to manager signals
	LaunchManager.gamenative_games_updated.connect(_on_games_updated)
	
	# Connect to viewport focus changes to ensure focused items are visible
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	
	super._ready()

func _build_view():
	_scroll_container = ScrollContainer.new()
	_scroll_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll_container.follow_focus = true
	_scroll_container.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll_container)
	
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll_container.add_child(margin)
	_margin = margin

	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# KEY: Use SHRINK_BEGIN so the VBox reports its true content height
	# to the ScrollContainer instead of trying to fill the viewport.
	vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	margin.add_child(vbox)
	_vbox = vbox

	# Add game section
	var add_section := SettingsSection.new("Add Game", "plus")
	vbox.add_child(add_section)

	var desc = M3Label.new()
	desc.text = "Add Steam games installed via GameNative or DroidDeck to show in your library."
	desc.label_style = M3Label.Style.BODY_MEDIUM
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_section.add_content(desc, false)

	# Launch backend status + preference
	var backend_section := SettingsSection.new("Launch Backend", "controller")
	vbox.add_child(backend_section)
	vbox.move_child(backend_section, 1)

	var backend_row = HBoxContainer.new()
	backend_row.add_theme_constant_override("separation", int(M3Units.dp(10)))
	backend_section.add_content(backend_row, false)

	_backend_option = M3OptionButton.new()
	_backend_option.label_text = ""
	_backend_option.fit_to_longest_item = false
	_backend_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_backend_option.add_item("Auto (detect)", 0)
	_backend_option.add_item("GameNative", 1)
	_backend_option.add_item("DroidDeck", 2)
	match LaunchManager.gamenative_get_preferred_backend():
		"gamenative":
			_backend_option.selected = 1
		"droiddeck":
			_backend_option.selected = 2
		_:
			_backend_option.selected = 0
	_backend_option.item_selected.connect(_on_backend_selected)
	backend_row.add_child(_backend_option)

	var status := M3Label.new()
	var gn_installed := LaunchManager.gamenative_is_backend_installed("gamenative")
	var dd_installed := LaunchManager.gamenative_is_backend_installed("droiddeck")
	if gn_installed and dd_installed:
		status.text = "GameNative and DroidDeck are installed."
	elif gn_installed:
		status.text = "GameNative is installed."
	elif dd_installed:
		status.text = "DroidDeck is installed."
	else:
		status.text = "Neither GameNative nor DroidDeck is installed. Games cannot be launched."
		status.modulate = M3Theme.get_error()
	status.label_style = M3Label.Style.BODY_MEDIUM
	status.use_on_surface_variant = gn_installed or dd_installed
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	backend_section.add_content(status, false)

	var add_row = HBoxContainer.new()
	add_section.add_content(add_row)
	_add_row = add_row

	_app_id_input = M3TextField.new()
	_app_id_input.label_text = "Steam App ID"
	_app_id_input.placeholder_text = "e.g., 480"
	_app_id_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_app_id_input.text_submitted.connect(_on_add_submitted)
	add_row.add_child(_app_id_input)

	_add_button = M3Button.new()
	_add_button.text = "Add Game"
	_add_button.button_variant = M3Button.Variant.FILLED
	_add_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_add_button.pressed.connect(_on_add_pressed)
	add_row.add_child(_add_button)

	# Status label
	_status_label = M3Label.new()
	_status_label.text = ""
	_status_label.label_style = M3Label.Style.BODY_SMALL
	_status_label.use_on_surface_variant = true
	add_section.add_content(_status_label, false)

	# Games list
	var games_section := SettingsSection.new("Configured Games", "controller")
	vbox.add_child(games_section)

	_games_container = VBoxContainer.new()
	games_section.add_content(_games_container, false)

	# Bottom buffer so content isn't clipped by Android keyboard / nav bar
	var bottom_buffer = Control.new()
	vbox.add_child(bottom_buffer)
	_bottom_buffer = bottom_buffer

	_apply_scale()

	# Force recalculation now that all children are added
	vbox.queue_sort()

func _apply_scale() -> void:
	if is_instance_valid(_margin):
		_margin.add_theme_constant_override("margin_left", int(M3Units.dp(20)))
		_margin.add_theme_constant_override("margin_top", int(M3Units.dp(20)))
		_margin.add_theme_constant_override("margin_right", int(M3Units.dp(20)))
		_margin.add_theme_constant_override("margin_bottom", int(M3Units.dp(20)))
	if is_instance_valid(_vbox):
		_vbox.add_theme_constant_override("separation", int(M3Units.dp(16)))
	if is_instance_valid(_add_row):
		_add_row.add_theme_constant_override("separation", int(M3Units.dp(10)))
	if is_instance_valid(_app_id_input):
		_app_id_input.custom_minimum_size = Vector2(M3Units.dp(200), 0)
	if is_instance_valid(_games_container):
		_games_container.add_theme_constant_override("separation", int(M3Units.dp(10)))
	if is_instance_valid(_bottom_buffer):
		_bottom_buffer.custom_minimum_size = Vector2(0, M3Units.dp(60))

func refresh_scale() -> void:
	if not is_node_ready():
		return
	_apply_scale()
	# Rebuild the games list so per-row cover sizes re-bake.
	_refresh_games_list()
	if has_method("refresh_theme"):
		call("refresh_theme")

func _on_add_pressed():
	var text = _app_id_input.text.strip_edges()
	if text.is_empty():
		_status_label.text = "Please enter a Steam App ID"
		_status_label.use_on_surface_variant = false
		_status_label.modulate = M3Theme.get_error()
		return
	
	if not text.is_valid_int():
		_status_label.text = "App ID must be a number"
		_status_label.use_on_surface_variant = false
		_status_label.modulate = M3Theme.get_error()
		return
	
	var app_id = text.to_int()
	if app_id <= 0:
		_status_label.text = "App ID must be positive"
		_status_label.use_on_surface_variant = false
		_status_label.modulate = M3Theme.get_error()
		return
	
	_add_button.disabled = true
	_status_label.text = "Validating App ID..."
	_status_label.use_on_surface_variant = false
	_status_label.modulate = M3Theme.get_primary()
	
	LaunchManager.gamenative_add_game(app_id, func(success: bool, message: String):
		if success:
			_status_label.text = "Added: %s" % message
			_status_label.use_on_surface_variant = false
			_status_label.modulate = M3Theme.get_tertiary()
			_app_id_input.text = ""
		else:
			_status_label.text = "Error: %s" % message
			_status_label.use_on_surface_variant = false
			_status_label.modulate = M3Theme.get_error()
		
		_add_button.disabled = false
	)

func _on_add_submitted(_text: String):
	_on_add_pressed()

func _on_backend_selected(index: int):
	match index:
		1:
			LaunchManager.gamenative_set_preferred_backend("gamenative")
		2:
			LaunchManager.gamenative_set_preferred_backend("droiddeck")
		_:
			LaunchManager.gamenative_set_preferred_backend("")

func _on_games_updated():
	_refresh_games_list()

func _refresh_games_list():
	# Clear existing
	for child in _games_container.get_children():
		child.queue_free()
	
	var games = LaunchManager.gamenative_get_games()
	
	if games.is_empty():
		var empty_label = M3Label.new()
		empty_label.text = "No games added yet."
		empty_label.label_style = M3Label.Style.BODY_MEDIUM
		empty_label.use_on_surface_variant = true
		_games_container.add_child(empty_label)
		return
	
	for game_data in games:
		var app_id = game_data.get("app_id", 0)
		var game_name = game_data.get("name", "Unknown")
		
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", int(M3Units.dp(10)))
		_games_container.add_child(row)
		
		# Cover image (placeholder, loaded async)
		var cover = TextureRect.new()
		cover.custom_minimum_size = Vector2(M3Units.dp(120), M3Units.dp(45))  # Steam header aspect ratio
		cover.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(cover)
		
		# Load cover image (persisted canonical URL; legacy CDN pattern fallback)
		var cover_url = game_data.get("cover_url", "")
		if cover_url == "":
			cover_url = "https://cdn.cloudflare.steamstatic.com/steam/apps/%d/header.jpg" % app_id
		_load_cover_async(cover_url, cover)
		
		# Game info
		var info = VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		
		var name_label = M3Label.new()
		name_label.text = game_name
		name_label.label_style = M3Label.Style.BODY_MEDIUM
		name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(name_label)
		
		var id_label = M3Label.new()
		id_label.text = "App ID: %d" % app_id
		id_label.label_style = M3Label.Style.BODY_SMALL
		id_label.use_on_surface_variant = true
		info.add_child(id_label)
		
		# Delete button
		var delete_btn = M3IconButton.new()
		delete_btn.icon_name = "delete"
		delete_btn.icon_button_variant = M3IconButton.IconVariant.STANDARD
		delete_btn.tooltip_text = "Remove game"
		delete_btn.pressed.connect(func():
			LaunchManager.gamenative_remove_game(app_id)
		)
		row.add_child(delete_btn)

func _load_cover_async(url: String, texture_rect: TextureRect) -> void:
	"""Load cover image asynchronously."""
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result, response_code, _headers, body):
		if response_code == 200 and body.size() > 0:
			MemorySubManager.queue_image_task(
				func() -> Image:
					var image = Image.new()
					if image.load_jpg_from_buffer(body) == OK and not image.is_empty():
						return MemorySubManager.prepare_image_for_texture(image)
					return null,
				func(img: Image):
					if is_instance_valid(texture_rect) and img and not img.is_empty():
						var texture = MemorySubManager.create_texture_from_image(img)
						if texture:
							texture_rect.texture = texture
			)
		http.queue_free()
	)
	
	var error = http.request(url)
	if error != OK:
		http.queue_free()

func reconnect_viewport() -> void:
	"""Reconnect to the current viewport's gui_focus_changed signal.
	Call this after reparenting into a SubViewport."""
	var viewport = get_viewport()
	if not is_instance_valid(viewport):
		return
	
	if viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)
	
	viewport.gui_focus_changed.connect(_on_focus_changed)

func _on_focus_changed(control: Control) -> void:
	"""Ensure focused controls are visible in the scroll container."""
	if not control:
		return
	if not is_instance_valid(_scroll_container):
		return
	if not _scroll_container.is_ancestor_of(control):
		return
	_scroll_container.ensure_control_visible(control)
