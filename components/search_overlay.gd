class_name SearchOverlay
extends M3Overlay

signal search_submitted(query: String)
signal search_cancelled()

var search_bar: SearchBar
var results_label: Label
var last_search_button: M3Button

var _scrim: ColorRect
var _main_container: VBoxContainer
var _last_search_text: String = ""
var _is_active: bool = false

func _init():
	super._init()
	overlay_type = "search"
	overlay_layer = 85
	persistent = true
	_build_ui()

func _build_ui():
	# Scrim catches background clicks and controller nav
	_scrim = ColorRect.new()
	_scrim.name = "Scrim"
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.color = Color(0, 0, 0, 0.7)
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.gui_input.connect(_on_scrim_clicked)
	add_child(_scrim)
	
	# Center container
	var center_container = CenterContainer.new()
	center_container.name = "CenterContainer"
	center_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.add_child(center_container)
	
	# Main container
	_main_container = VBoxContainer.new()
	_main_container.name = "MainContainer"
	_main_container.alignment = BoxContainer.ALIGNMENT_CENTER
	center_container.add_child(_main_container)
	
	# Search bar
	search_bar = SearchBar.new()
	search_bar.name = "SearchBar"
	search_bar.text_changed.connect(_on_search_text_changed)
	search_bar.text_submitted.connect(_on_search_submitted)
	_main_container.add_child(search_bar)
	
	# Last search button
	var search_history_button = M3Button.new()
	search_history_button.name = "LastSearchButton"
	search_history_button.text = ""
	search_history_button.visible = false
	search_history_button.focus_mode = Control.FOCUS_ALL
	search_history_button.button_variant = M3Button.Variant.TEXT
	search_history_button.pressed.connect(_on_last_search_clicked)
	_main_container.add_child(search_history_button)
	self.last_search_button = search_history_button
	
	# Results label
	var results_count_label = M3Label.new()
	results_count_label.name = "ResultsLabel"
	results_count_label.text = ""
	results_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	results_count_label.label_style = M3Label.Style.BODY_SMALL
	results_count_label.use_on_surface_variant = true
	_main_container.add_child(results_count_label)
	self.results_label = results_count_label

func _ready():
	super._ready()
	# Set up focus neighbors once nodes are in the scene tree
	var line_edit = search_bar.get_line_edit()
	if line_edit and last_search_button:
		line_edit.focus_neighbor_bottom = last_search_button.get_path()
		last_search_button.focus_neighbor_top = line_edit.get_path()

func show_overlay():
	var parent = M3Overlay.get_overlay_parent()
	if parent and get_parent() == null:
		parent.add_child(self)
	
	_is_active = true
	set_last_search(_last_search_text)
	super.show_overlay()
	search_bar.grab_focus_on_input()

func dismiss():
	_is_active = false
	search_bar.release_focus_from_input()
	search_bar.clear()
	results_label.text = ""
	
	var keyboard = get_tree().root.find_child("OnscreenKeyboard", true, false)
	if keyboard and keyboard.visible:
		keyboard.hide()
	if keyboard:
		keyboard.reset_focus_tracking()
	
	super.dismiss()

func is_active() -> bool:
	return _is_active

func set_last_search(text: String) -> void:
	_last_search_text = text.strip_edges()
	if last_search_button:
		if _last_search_text.is_empty():
			last_search_button.visible = false
			last_search_button.text = ""
		else:
			last_search_button.visible = true
			last_search_button.text = "Last search: \"%s\"" % _last_search_text

func update_results_count(count: int):
	if count == 0:
		results_label.text = "No results found"
	elif count == 1:
		results_label.text = "1 result found"
	else:
		results_label.text = "%d results found" % count

func _on_last_search_clicked() -> void:
	if not _last_search_text.is_empty():
		search_bar.text = _last_search_text
		search_submitted.emit(_last_search_text)

func _on_search_text_changed(_text: String):
	pass

func _on_search_submitted(text: String):
	if text.strip_edges().is_empty():
		search_cancelled.emit()
	else:
		search_submitted.emit(text)

func _on_scrim_clicked(event: InputEvent):
	if event is InputEventMouseButton and event.pressed:
		search_cancelled.emit()

func _input(event: InputEvent):
	if not visible:
		return
	
	var focus_owner = get_viewport().gui_get_focus_owner()
	
	# Don't consume input while the on-screen keyboard has focus.
	if UIManager and UIManager.is_focus_in_onscreen_keyboard(focus_owner):
		return
	
	# Consume controller navigation events so they don't leak to the grid
	if event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down") or \
	   event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		get_viewport().set_input_as_handled()
		return
	
	# Allow LineEdit to receive Enter for text_submitted
	if event.is_action_pressed("ui_accept") and focus_owner == search_bar:
		return
	
	if event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		return
	
	# Let M3Overlay handle ui_cancel (dismisses overlay)
	super._input(event)
