extends Control

@onready var tab_container: TabContainer = $TabContainer

func _ready():
	# Set window title
	DisplayServer.window_set_title("Kyodai - Game Launcher")
	
	# Initialize UIManager with the tab container
	# UIManager will set up Library, Downloads, and Settings views
	UIManager.initialize(tab_container)
