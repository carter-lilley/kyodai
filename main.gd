extends Control

@onready var layout_container: BoxContainer = $VBoxContainer
@onready var tab_container: TabContainer = $VBoxContainer/TabContainer
@onready var bottom_bar: BottomBar = $VBoxContainer/BottomBar

# Auto-repeat navigation
var _held_dir: String = ""
var _delay_timer: Timer
var _repeat_timer: Timer
const INITIAL_DELAY: float = 0.5
const REPEAT_DELAY: float = 0.1
var _last_press: int = 0

func _ready():
	_setup_repeat()
	
	# Set window title
	DisplayServer.window_set_title("Kyodai - Game Launcher")
	
	# Initialize UIManager with the tab container, layout container, and bottom bar
	UIManager.initialize(tab_container, layout_container, bottom_bar)
	
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

func reset_focus_to_home_button() -> void:
	"""Reset focus to the Home button in the bottom bar."""
	if bottom_bar and bottom_bar.has_node("NavButtons/HomeButton"):
		var home_button = bottom_bar.get_node("NavButtons/HomeButton")
		if home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
			home_button.grab_focus()

func _setup_repeat():
	_delay_timer = Timer.new()
	_delay_timer.wait_time = INITIAL_DELAY
	_delay_timer.one_shot = true
	_delay_timer.timeout.connect(_on_delay_timeout)
	add_child(_delay_timer)
	
	_repeat_timer = Timer.new()
	_repeat_timer.wait_time = REPEAT_DELAY
	_repeat_timer.timeout.connect(_on_repeat)
	add_child(_repeat_timer)

func _input(event: InputEvent):
	var dirs = ["ui_left", "ui_right", "ui_up", "ui_down"]
	
	for dir in dirs:
		if event.is_action_pressed(dir):
			if event is InputEventKey:
				var now = Time.get_ticks_msec()
				if now - _last_press < 80:
					return
				_last_press = now
			
			_held_dir = dir
			_delay_timer.start()
			return
		
		if event.is_action_released(dir) and _held_dir == dir:
			# Ignore synthetic release events from our repeat system
			if event is InputEventAction:
				return
			_held_dir = ""
			_delay_timer.stop()
			_repeat_timer.stop()
			return
	
	# Handle ui_cancel to go back to Home
	if event.is_action_pressed("ui_cancel"):
		# Play return sound
		if AudioManager:
			AudioManager.play_sfx("return")
		# Switch to Home view
		UIManager.switch_to_tab("Home")
		# Set focus to Home button
		if bottom_bar and bottom_bar.has_node("NavButtons/HomeButton"):
			var home_button = bottom_bar.get_node("NavButtons/HomeButton")
			if home_button is Control and home_button.focus_mode != Control.FOCUS_NONE:
				home_button.grab_focus()
		return

func _on_delay_timeout():
	if _held_dir != "":
		_repeat_timer.start()
		_resend()

func _on_repeat():
	if _held_dir != "":
		_resend()

func _resend():
	if _held_dir != "":
		# Send press event
		var press = InputEventAction.new()
		press.action = _held_dir
		press.pressed = true
		Input.parse_input_event(press)
		
		# Send release event to reset action state (allows analog sticks to work)
		var release = InputEventAction.new()
		release.action = _held_dir
		release.pressed = false
		Input.parse_input_event(release)
