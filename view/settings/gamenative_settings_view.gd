class_name GamenativeSettingsView
extends View

var _games_container: VBoxContainer
var _app_id_input: LineEdit
var _add_button: Button
var _status_label: Label

func _ready():
	view_name = "GameNative"
	_build_view()
	_refresh_games_list()
	
	# Connect to manager signals
	GameNativeManager.games_updated.connect(_on_games_updated)
	
	super._ready()

func _build_view():
	var scroll = ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.follow_focus = true
	add_child(scroll)
	
	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 20)
	margin.add_theme_constant_override("margin_top", 20)
	margin.add_theme_constant_override("margin_right", 20)
	margin.add_theme_constant_override("margin_bottom", 20)
	scroll.add_child(margin)
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 15)
	margin.add_child(vbox)
	
	# Title
	var title = Label.new()
	title.text = "GameNative Steam Games"
	title.add_theme_font_size_override("font_size", 20)
	vbox.add_child(title)
	
	# Description
	var desc = Label.new()
	desc.text = "Add Steam games installed via GameNative to show in your library."
	desc.add_theme_font_size_override("font_size", 14)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(desc)
	
	# Spacer
	var spacer = Control.new()
	spacer.custom_minimum_size = Vector2(0, 10)
	vbox.add_child(spacer)
	
	# Check GameNative status
	if not GameNativeManager.is_game_native_installed():
		var warning = Label.new()
		warning.text = "⚠ GameNative app is not installed. Games cannot be launched."
		warning.modulate = Color.ORANGE
		warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(warning)
	
	# Add game section
	var add_section = HBoxContainer.new()
	add_section.add_theme_constant_override("separation", 10)
	vbox.add_child(add_section)
	
	var input_label = Label.new()
	input_label.text = "Steam App ID:"
	add_section.add_child(input_label)
	
	_app_id_input = LineEdit.new()
	_app_id_input.custom_minimum_size = Vector2(150, 0)
	_app_id_input.placeholder_text = "e.g., 480"
	_app_id_input.text_submitted.connect(_on_add_submitted)
	add_section.add_child(_app_id_input)
	
	_add_button = Button.new()
	_add_button.text = "Add Game"
	_add_button.pressed.connect(_on_add_pressed)
	add_section.add_child(_add_button)
	
	# Status label
	_status_label = Label.new()
	_status_label.text = ""
	_status_label.modulate = Color.GRAY
	vbox.add_child(_status_label)
	
	# Separator
	var separator = HSeparator.new()
	vbox.add_child(separator)
	
	# Games list
	var list_label = Label.new()
	list_label.text = "Configured Games"
	list_label.add_theme_font_size_override("font_size", 16)
	vbox.add_child(list_label)
	
	_games_container = VBoxContainer.new()
	_games_container.add_theme_constant_override("separation", 10)
	vbox.add_child(_games_container)

func _on_add_pressed():
	var text = _app_id_input.text.strip_edges()
	if text.is_empty():
		_status_label.text = "Please enter a Steam App ID"
		_status_label.modulate = Color.RED
		return
	
	if not text.is_valid_int():
		_status_label.text = "App ID must be a number"
		_status_label.modulate = Color.RED
		return
	
	var app_id = text.to_int()
	if app_id <= 0:
		_status_label.text = "App ID must be positive"
		_status_label.modulate = Color.RED
		return
	
	_add_button.disabled = true
	_status_label.text = "Validating App ID..."
	_status_label.modulate = Color.YELLOW
	
	GameNativeManager.add_game(app_id, func(success: bool, message: String):
		if success:
			_status_label.text = "Added: %s" % message
			_status_label.modulate = Color.GREEN
			_app_id_input.text = ""
		else:
			_status_label.text = "Error: %s" % message
			_status_label.modulate = Color.RED
		
		_add_button.disabled = false
	)

func _on_add_submitted(text: String):
	_on_add_pressed()

func _on_games_updated():
	_refresh_games_list()

func _refresh_games_list():
	# Clear existing
	for child in _games_container.get_children():
		child.queue_free()
	
	var games = GameNativeManager.get_games()
	
	if games.is_empty():
		var empty_label = Label.new()
		empty_label.text = "No games added yet."
		empty_label.modulate = Color.GRAY
		_games_container.add_child(empty_label)
		return
	
	for game_data in games:
		var app_id = game_data.get("app_id", 0)
		var name = game_data.get("name", "Unknown")
		
		var row = HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		_games_container.add_child(row)
		
		# Cover image (placeholder, loaded async)
		var cover = TextureRect.new()
		cover.custom_minimum_size = Vector2(120, 45)  # Steam header aspect ratio
		cover.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
		cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		row.add_child(cover)
		
		# Load cover image
		var cover_url = "https://cdn.cloudflare.steamstatic.com/steam/apps/%d/header.jpg" % app_id
		_load_cover_async(cover_url, cover)
		
		# Game info
		var info = VBoxContainer.new()
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		
		var name_label = Label.new()
		name_label.text = name
		name_label.add_theme_font_size_override("font_size", 14)
		info.add_child(name_label)
		
		var id_label = Label.new()
		id_label.text = "App ID: %d" % app_id
		id_label.add_theme_font_size_override("font_size", 12)
		id_label.modulate = Color.GRAY
		info.add_child(id_label)
		
		# Delete button
		var delete_btn = Button.new()
		delete_btn.text = "Remove"
		delete_btn.pressed.connect(func():
			GameNativeManager.remove_game(app_id)
		)
		row.add_child(delete_btn)

func _load_cover_async(url: String, texture_rect: TextureRect) -> void:
	"""Load cover image asynchronously."""
	var http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(result, response_code, headers, body):
		if response_code == 200 and body.size() > 0:
			var image = Image.new()
			var err = image.load_jpg_from_buffer(body)
			if err == OK:
				var texture = ImageTexture.create_from_image(image)
				texture_rect.texture = texture
		http.queue_free()
	)
	
	var error = http.request(url)
	if error != OK:
		http.queue_free()
