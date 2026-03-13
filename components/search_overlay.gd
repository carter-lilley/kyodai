class_name SearchOverlay
extends Control

signal search_submitted(query: String)
signal search_cancelled()

@onready var search_bar: SearchBar
@onready var results_label: Label
@onready var background: ColorRect

var _is_active: bool = false

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
	add_child(center_container)
	
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
	
	# Results label (shows "X results found" or live results)
	var results_label = Label.new()
	results_label.name = "ResultsLabel"
	results_label.text = ""
	results_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	results_label.add_theme_font_size_override("font_size", 14)
	results_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.7))
	main_container.add_child(results_label)
	self.results_label = results_label

func show_overlay():
	visible = true
	_is_active = true
	search_bar.grab_focus_on_input()

func hide_overlay():
	visible = false
	_is_active = false
	search_bar.release_focus_from_input()
	search_bar.clear()
	results_label.text = ""
	
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
