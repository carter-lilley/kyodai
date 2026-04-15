class_name SearchOverlay
extends Control

signal search_submitted(query: String)
signal search_cancelled()

@onready var search_bar: SearchBar
@onready var results_label: Label
@onready var last_search_button: Button
@onready var background: ColorRect

var _is_active: bool = false
var _last_search_text: String = ""

func _ready():
	# Full screen overlay
	set_anchors_preset(Control.PRESET_FULL_RECT)
	z_index = 100  # Above most UI elements
	
	# Semi-transparent dark background
	background = ColorRect.new()
	background.name = "Background"
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0, 0, 0, 0.7)
	background.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(background)
	
	# Click background to cancel
	background.gui_input.connect(_on_background_clicked)
	
	# Center container to fill screen and center content
	var center_container = CenterContainer.new()
	center_container.name = "CenterContainer"
	center_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.add_child(center_container)
	
	# Main container for search elements
	var main_container = VBoxContainer.new()
	main_container.name = "MainContainer"
	main_container.alignment = BoxContainer.ALIGNMENT_CENTER
	center_container.add_child(main_container)
	
	# Search bar
	search_bar = SearchBar.new()
	search_bar.name = "SearchBar"
	search_bar.text_changed.connect(_on_search_text_changed)
	search_bar.text_submitted.connect(_on_search_submitted)
	main_container.add_child(search_bar)
	
	# Last search button
	var last_search_button = Button.new()
	last_search_button.name = "LastSearchButton"
	last_search_button.text = ""
	last_search_button.visible = false
	last_search_button.focus_mode = Control.FOCUS_ALL
	last_search_button.add_theme_font_size_override("font_size", 14)
	last_search_button.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9, 1.0))
	last_search_button.pressed.connect(_on_last_search_clicked)
	main_container.add_child(last_search_button)
	self.last_search_button = last_search_button
	
	# Set up focus neighbors so controller navigation cycles inside the overlay
	var line_edit = search_bar.get_line_edit()
	if line_edit:
		line_edit.focus_neighbor_bottom = last_search_button.get_path()
		last_search_button.focus_neighbor_top = line_edit.get_path()
	
	# Results label (shows "X results found" or live results)
	var results_label = Label.new()
	results_label.name = "ResultsLabel"
	results_label.text = ""
	results_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	results_label.add_theme_font_size_override("font_size", 14)
	results_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	main_container.add_child(results_label)
	self.results_label = results_label

func set_last_search(text: String) -> void:
	_last_search_text = text.strip_edges()
	if last_search_button:
		if _last_search_text.is_empty():
			last_search_button.visible = false
			last_search_button.text = ""
		else:
			last_search_button.visible = true
			last_search_button.text = "Last search: \"%s\"" % _last_search_text

func show_overlay():
	visible = true
	_is_active = true
	set_last_search(_last_search_text)
	
	# Connect focus guard to prevent controller focus leaking behind overlay
	var viewport = get_viewport()
	if viewport and not viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.connect(_on_focus_changed)
	
	search_bar.grab_focus_on_input()

func hide_overlay():
	visible = false
	_is_active = false
	search_bar.release_focus_from_input()
	search_bar.clear()
	results_label.text = ""
	
	# Disconnect focus guard
	var viewport = get_viewport()
	if viewport and viewport.gui_focus_changed.is_connected(_on_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_focus_changed)
	
	# Explicitly hide keyboard if open
	var keyboard = get_tree().get_root().get_node_or_null("Main/UILayer/OnscreenKeyboard")
	if keyboard and keyboard.visible:
		keyboard.hide()
	
	# Reset keyboard focus tracking so it will reopen on next search
	if keyboard:
		keyboard.reset_focus_tracking()

func is_active() -> bool:
	return _is_active

func update_results_count(count: int):
	if count == 0:
		results_label.text = "No results found"
	elif count == 1:
		results_label.text = "1 result found"
	else:
		results_label.text = "%d results found" % count

func _on_last_search_clicked() -> void:
	if not _last_search_text.is_empty():
		search_bar.set_text(_last_search_text)
		search_submitted.emit(_last_search_text)

func _on_search_text_changed(text: String):
	# Update live results count via signal to parent
	# Parent should call update_results_count() with actual count
	pass

func _on_search_submitted(text: String):
	if text.strip_edges().is_empty():
		search_cancelled.emit()
	else:
		search_submitted.emit(text)

func _on_background_clicked(event: InputEvent):
	if event is InputEventMouseButton and event.pressed:
		search_cancelled.emit()

func _on_focus_changed(control: Control) -> void:
	"""Focus guard: prevent controller focus from leaking behind the overlay."""
	if not _is_active or control == null:
		return
	
	# Allow focus inside the overlay
	if _is_child_of_overlay(control):
		return
	
	# Allow focus inside the on-screen keyboard
	var keyboard = get_tree().get_root().get_node_or_null("Main/UILayer/OnscreenKeyboard")
	if keyboard and _is_child_of_node(control, keyboard):
		return
	
	# Focus leaked outside — pull it back to the search bar
	search_bar.grab_focus_on_input()

func _is_child_of_overlay(node: Node) -> bool:
	var current = node
	while current != null:
		if current == self:
			return true
		current = current.get_parent()
	return false

func _is_child_of_node(node: Node, parent: Node) -> bool:
	var current = node
	while current != null:
		if current == parent:
			return true
		current = current.get_parent()
	return false

func _input(event: InputEvent):
	if not _is_active:
		return
	
	# Close on ui_cancel - also close keyboard if open
	if event.is_action_pressed("ui_cancel"):
		# Close keyboard first if it's open
		var keyboard = get_tree().get_root().get_node_or_null("Main/UILayer/OnscreenKeyboard")
		if keyboard and keyboard.visible:
			keyboard.hide()
		# Cancel the search
		search_cancelled.emit()
		get_viewport().set_input_as_handled()
