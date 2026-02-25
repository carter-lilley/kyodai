extends Control

@onready var tab_container: TabContainer = $VBoxContainer/TabContainer
@onready var bottom_bar: BottomBar = $VBoxContainer/BottomBar

func _ready():
	# Set window title
	DisplayServer.window_set_title("Kyodai - Game Launcher")
	
	# Initialize UIManager with the tab container
	UIManager.initialize(tab_container, self)
	
	# Connect bottom bar signals
	if bottom_bar:
		print("[Main] BottomBar found, connecting signals")
		bottom_bar.nav_button_pressed.connect(_on_nav_button_pressed)
		bottom_bar.zoom_changed.connect(_on_zoom_changed)
		print("[Main] Zoom signal connected: ", bottom_bar.zoom_changed.is_connected(_on_zoom_changed))
	else:
		push_error("[Main] BottomBar not found!")
	
	# Connect to UIManager for tab changes
	UIManager.tab_changed.connect(_on_tab_changed)
	
	# Set initial view
	_update_bottom_bar_for_view("Home")

func _on_nav_button_pressed(view_name: String):
	UIManager.switch_to_tab(view_name)

func _on_tab_changed(view_name: String):
	_update_bottom_bar_for_view(view_name)

func _update_bottom_bar_for_view(view_name: String):
	bottom_bar.set_current_view(view_name)
	
	# Update zoom slider to match current view's grid
	var view = UIManager.get_view(view_name)
	if view and view_name in ["Home", "Library"]:
		var games_grid = _get_view_grid(view)
		if games_grid:
			bottom_bar.set_zoom_value(games_grid.target_card_width_ratio)

func _on_zoom_changed(value: float):
	print("[Main] Zoom changed to: ", value)
	# Apply zoom to current view's grid
	var current_view = UIManager.get_current_view()
	print("[Main] Current view: ", current_view)
	if current_view:
		var games_grid = _get_view_grid(current_view)
		print("[Main] Games grid found: ", games_grid != null)
		if games_grid:
			print("[Main] Setting target_card_width_ratio to: ", value)
			games_grid.target_card_width_ratio = value

func _get_view_grid(view: View) -> VirtualScrollGridContainer:
	# Safely get the games grid from a view
	if view.has_node("VBoxContainer/VirtualScrollGridContainer"):
		return view.get_node("VBoxContainer/VirtualScrollGridContainer")
	return null

func set_status_text(text: String):
	bottom_bar.set_status_text(text)
