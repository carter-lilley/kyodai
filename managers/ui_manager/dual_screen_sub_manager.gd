class_name DualScreenSubManager
extends Manager

var ui_manager: Node

var _dual_screen_active: bool = false
var _dual_screen_viewport_mode: bool = false

# Node reparenting state for Android dual screen
var _main_ui_original_parent: Node = null
var _ui_layer_original_parent: Node = null
var _settings_dialog_original_parent: Node = null
var _is_nodes_reparented: bool = false
var _viewport_layout: Node = null

# Keyboard state for dual screen mode
var _keyboard: Node = null
var _keyboard_original_parent: Node = null
var _keyboard_original_anchors: Dictionary = {}
var _keyboard_is_in_second_viewport: bool = false

# Desktop fallback
var _hero_secondary_window: Window = null
var _hero_original_parent: Node = null

var _root_control: Control = null
var _hero_image: HeroImage = null

var _dual_screen_setup_scene: PackedScene = preload("res://scenes/dual_screen_setup.tscn")
var _dual_screen_setup: Control = null
var _main_viewport: SubViewport = null
var _second_viewport: SubViewport = null

func _ready():
	ui_manager = get_parent()

func setup(root_control: Control) -> void:
	_root_control = root_control

func ensure_dual_screen_setup() -> Control:
	"""Create or return the DualScreenSetup scene under /root/Main.
	Also re-resolves AynThorManager screen references if available."""
	if _dual_screen_setup and is_instance_valid(_dual_screen_setup):
		_enable_dual_screen_setup_node(_dual_screen_setup)
		return _dual_screen_setup

	var main = get_node_or_null("/root/Main")
	if not main:
		push_error("[DualScreenManager] Cannot create DualScreenSetup - Main node not found")
		return null

	_dual_screen_setup = _dual_screen_setup_scene.instantiate()
	_dual_screen_setup.name = "DualScreenSetup"
	main.add_child(_dual_screen_setup)

	_main_viewport = _dual_screen_setup.get_node_or_null("MainViewportContainer/MainViewport")
	_second_viewport = _dual_screen_setup.get_node_or_null("SecondViewportContainer/SecondViewport")
	_hero_image = _dual_screen_setup.get_node_or_null("SecondViewportContainer/SecondViewport/HeroImageSecondScreen")

	var ayn = main.get_node_or_null("AynThorManager")
	if ayn and ayn.has_method("set_screen_resources"):
		var main_screen = Screen.new()
		main_screen.container_path = NodePath("../DualScreenSetup/MainViewportContainer")
		main_screen.viewport_path = NodePath("../DualScreenSetup/MainViewportContainer/MainViewport")
		var second_screen = Screen.new()
		second_screen.container_path = NodePath("../DualScreenSetup/SecondViewportContainer")
		second_screen.viewport_path = NodePath("../DualScreenSetup/SecondViewportContainer/SecondViewport")
		ayn.set_screen_resources(main_screen, second_screen)

	_enable_dual_screen_setup_node(_dual_screen_setup)
	return _dual_screen_setup

func remove_dual_screen_setup() -> void:
	"""Disable DualScreenSetup without removing it from the tree."""
	if _dual_screen_setup and is_instance_valid(_dual_screen_setup):
		_disable_dual_screen_setup_node(_dual_screen_setup)

func get_hero_image() -> HeroImage:
	return _hero_image

func set_hero_game(game: GameResource) -> void:
	if _hero_image:
		_hero_image.set_game(game)

func get_main_viewport() -> SubViewport:
	return _main_viewport

func get_second_viewport() -> SubViewport:
	return _second_viewport

func _enable_dual_screen_setup_node(ds: Node) -> void:
	ds.process_mode = Node.PROCESS_MODE_INHERIT
	ds.visible = true
	ds.position = Vector2.ZERO
	for child in ds.get_children():
		if child is Control:
			child.mouse_filter = Control.MOUSE_FILTER_PASS
			child.focus_mode = Control.FOCUS_NONE

func _disable_dual_screen_setup_node(ds: Node) -> void:
	ds.process_mode = Node.PROCESS_MODE_DISABLED
	ds.visible = false
	ds.position = Vector2(-10000, -10000)
	for child in ds.get_children():
		if child is Control:
			child.mouse_filter = Control.MOUSE_FILTER_IGNORE
			child.focus_mode = Control.FOCUS_NONE

func _initialize_dual_screen() -> void:
	"""Initialize dual screen mode (called deferred to allow plugin initialization)."""
	_on_dual_screen_mode_changed(true, SystemManager.display.get_second_screen_index())

func _on_dual_screen_mode_changed(enabled: bool, second_screen_index: int) -> void:
	"""Handle dual screen mode changes from SystemManager.display."""
	if enabled:
		_enable_dual_screen_mode(second_screen_index)
	else:
		_disable_dual_screen_mode()

func _enable_dual_screen_mode(second_screen_index: int) -> void:
	"""Enable dual screen mode - show HeroImage on second display."""
	if _dual_screen_active:
		return

	# Ensure the DualScreenSetup scene exists and resolve the hero image from it.
	ensure_dual_screen_setup()

	if not _hero_image:
		push_error("[DualScreenManager] Cannot enable dual screen - hero image not available")
		return

	# Check if AynThor plugin is available (Android dual screen)
	var has_aynthor = Engine.has_singleton("AynThor")

	if has_aynthor and SystemManager.platform.is_android():
		# Use dual screen viewport plugin (works on any dual screen Android device)
		_enable_dual_screen_viewport_mode()
	else:
		# Desktop: use Godot Window approach
		_enable_dual_screen_mode_desktop.call_deferred(second_screen_index)

func _enable_dual_screen_viewport_mode() -> void:
	"""Enable dual screen using viewport plugin (generic dual screen support)."""

	# Ensure DualScreenSetup is in the tree
	var dual_screen_setup = ensure_dual_screen_setup()
	var second_viewport = _second_viewport

	if not dual_screen_setup or not second_viewport or not _hero_image:
		push_warning("[DualScreenManager] Dual screen setup nodes not found")
		return

	# Dismiss any active M3 overlays before reparenting so they don't get stranded
	M3Overlay.dismiss_type("menu")
	M3Overlay.dismiss_type("snackbar")
	M3Overlay.dismiss_type("dialog")
	M3Overlay.dismiss_type("tooltip")
	M3Overlay.dismiss_type("sheet")

	# REPARENTING: Move main UI nodes into MainViewport
	var main_viewport = _main_viewport
	if main_viewport:
		# Mark viewport as overlay parent so M3 components render inside it
		main_viewport.add_to_group("m3_overlay_parent")
		# Enable local input handling so touch/mouse events are processed inside the viewport
		main_viewport.handle_input_locally = true
		_reparent_ui_to_main_viewport(main_viewport)

	# Enable local input handling on second viewport as well
	if second_viewport:
		second_viewport.handle_input_locally = true

	# Reparent keyboard to SecondViewport for fullscreen display on secondary screen
	_reparent_keyboard_to_second_viewport(second_viewport)

	# Sync current game to second screen hero
	var current_game = null
	if _hero_image:
		if _hero_image.has_method("get_current_game"):
			current_game = _hero_image.get_current_game()
			if current_game and _hero_image.has_method("set_game"):
				_hero_image.set_game(current_game)

	# Position and make dual screen setup visible
	# MainViewportContainer will be at (0,0) relative to this, so position at (0,0)
	if dual_screen_setup:
		dual_screen_setup.position = Vector2.ZERO
		dual_screen_setup.visible = true

	_dual_screen_active = true
	_dual_screen_viewport_mode = true

	# Apply SubViewport-based UI scaling (disables Window scaling, scales inside SubViewports)
	SystemManager.display.enter_subviewport_dual_screen_mode()

func _disable_dual_screen_mode() -> void:
	"""Disable dual screen mode - restore HeroImage to main layout."""
	if not _dual_screen_active:
		return

	# Restore keyboard to original parent before restoring other UI
	_restore_keyboard_to_original_parent()

	# Remove main viewport from overlay parent group so M3 components attach to root viewport
	var dual_screen_setup = _dual_screen_setup
	if dual_screen_setup:
		var main_viewport = _main_viewport
		if main_viewport:
			main_viewport.remove_from_group("m3_overlay_parent")

	# Restore UI nodes to original parents first
	_restore_ui_to_original_parents()

	if _dual_screen_viewport_mode:
		# Restore input handling to default (forward to parent viewport)
		var main_vp = _main_viewport
		var second_vp = _second_viewport
		if main_vp:
			main_vp.handle_input_locally = false
		if second_vp:
			second_vp.handle_input_locally = false

		remove_dual_screen_setup()

		_dual_screen_viewport_mode = false
	else:
		# Desktop: close secondary window
		_disable_dual_screen_mode_desktop()

	# Clear SubViewport-based UI scaling and restore Window scaling
	SystemManager.display.exit_subviewport_dual_screen_mode()

	_dual_screen_active = false

func _reparent_keyboard_to_second_viewport(second_viewport: SubViewport) -> void:
	"""Move the on-screen keyboard into SecondViewport for fullscreen display on the secondary screen."""
	var keyboard = get_tree().root.find_child("OnscreenKeyboard", true, false)
	if not keyboard:
		return

	_keyboard = keyboard
	_keyboard_original_parent = keyboard.get_parent()

	# Store original anchor values (get_anchors_preset does not exist in Godot)
	_keyboard_original_anchors = {
		"anchor_left": keyboard.anchor_left,
		"anchor_top": keyboard.anchor_top,
		"anchor_right": keyboard.anchor_right,
		"anchor_bottom": keyboard.anchor_bottom,
		"offset_left": keyboard.offset_left,
		"offset_top": keyboard.offset_top,
		"offset_right": keyboard.offset_right,
		"offset_bottom": keyboard.offset_bottom,
		"grow_horizontal": keyboard.grow_horizontal,
		"grow_vertical": keyboard.grow_vertical
	}

	# Hide keyboard before reparenting to avoid visual glitches
	if keyboard.visible:
		if keyboard.has_method("hide"):
			keyboard.hide()

	# Remove from current parent
	if keyboard.get_parent():
		keyboard.get_parent().remove_child(keyboard)

	# Add to second viewport and make fullscreen
	second_viewport.add_child(keyboard)
	keyboard.set_anchors_preset(Control.PRESET_FULL_RECT)
	keyboard.offset_left = 0
	keyboard.offset_top = 0
	keyboard.offset_right = 0
	keyboard.offset_bottom = 0
	keyboard.grow_horizontal = Control.GROW_DIRECTION_BOTH
	keyboard.grow_vertical = Control.GROW_DIRECTION_BOTH

	# Reconnect keyboard to second viewport's focus system
	if keyboard.has_method("reconnect_viewport"):
		keyboard.reconnect_viewport()

	_keyboard_is_in_second_viewport = true

	print("[DualScreenManager] Keyboard reparented to SecondViewport")

func _restore_keyboard_to_original_parent() -> void:
	"""Restore the on-screen keyboard to its original parent and anchors."""
	if not _keyboard_is_in_second_viewport or not _keyboard or not is_instance_valid(_keyboard):
		_reset_keyboard_state()
		return

	# Hide keyboard before reparenting
	if _keyboard.visible:
		if _keyboard.has_method("hide"):
			_keyboard.hide()

	# Remove from second viewport
	if _keyboard.get_parent():
		_keyboard.get_parent().remove_child(_keyboard)

	# Restore to original parent
	if _keyboard_original_parent and is_instance_valid(_keyboard_original_parent):
		_keyboard_original_parent.add_child(_keyboard)
	else:
		# Fallback: add to Main node if original parent is invalid
		var main_node = get_node_or_null("/root/Main")
		if main_node:
			main_node.add_child(_keyboard)

	# Restore original layout (set_anchors_preset overwrites individual anchors, so restore manually)
	_keyboard.anchor_left = _keyboard_original_anchors.get("anchor_left", 0)
	_keyboard.anchor_top = _keyboard_original_anchors.get("anchor_top", 1)
	_keyboard.anchor_right = _keyboard_original_anchors.get("anchor_right", 1)
	_keyboard.anchor_bottom = _keyboard_original_anchors.get("anchor_bottom", 1)
	_keyboard.offset_left = _keyboard_original_anchors.get("offset_left", 0)
	_keyboard.offset_top = _keyboard_original_anchors.get("offset_top", -300)
	_keyboard.offset_right = _keyboard_original_anchors.get("offset_right", 0)
	_keyboard.offset_bottom = _keyboard_original_anchors.get("offset_bottom", 0)
	_keyboard.grow_horizontal = _keyboard_original_anchors.get("grow_horizontal", Control.GROW_DIRECTION_BOTH)
	_keyboard.grow_vertical = _keyboard_original_anchors.get("grow_vertical", Control.GROW_DIRECTION_BEGIN)

	# Reconnect keyboard to original viewport's focus system
	if _keyboard.has_method("reconnect_viewport"):
		_keyboard.reconnect_viewport()

	print("[DualScreenManager] Keyboard restored to original parent")

	_reset_keyboard_state()

func _reset_keyboard_state() -> void:
	_keyboard = null
	_keyboard_original_parent = null
	_keyboard_original_anchors = {}
	_keyboard_is_in_second_viewport = false

func _reparent_ui_to_main_viewport(main_viewport: SubViewport) -> void:
	"""Reparent RootLayout into MainViewport for dual screen.

	The RootLayout contains the full UI hierarchy including InnerLayout (which holds
	M3 nav and ContentWrapper), so we only need to reparent RootLayout.
	"""
	if _is_nodes_reparented:
		return

	# Store original parent
	if _root_control:
		_main_ui_original_parent = _root_control.get_parent()

	# Find and store UILayer original parent
	var ui_layer = get_node_or_null("/root/Main/UILayer")
	if ui_layer:
		_ui_layer_original_parent = ui_layer.get_parent()

	# Store SettingsDialog original parent and remove it from _root_control
	# CanvasLayers must not be nested inside VBoxContainer inside SubViewport
	var settings_dialog = ui_manager.overlay._settings_dialog
	if settings_dialog and settings_dialog.get_parent():
		_settings_dialog_original_parent = settings_dialog.get_parent()
		settings_dialog.get_parent().remove_child(settings_dialog)

	# Remove RootLayout from current parent (this includes M3 nav via InnerLayout)
	if _root_control and _root_control.get_parent():
		_root_control.get_parent().remove_child(_root_control)

	# Remove UILayer from its current parent
	if ui_layer and ui_layer.get_parent():
		ui_layer.get_parent().remove_child(ui_layer)

	# Create layout container within the viewport
	_viewport_layout = VBoxContainer.new()
	_viewport_layout.name = "ViewportLayout"
	_viewport_layout.set_anchors_preset(Control.PRESET_FULL_RECT)
	main_viewport.add_child(_viewport_layout)

	# Add RootLayout (fills viewport, includes InnerLayout with Navbar + ContentWrapper)
	_root_control.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_viewport_layout.add_child(_root_control)

	# Add UILayer directly to MainViewport (CanvasLayer can't go in VBoxContainer)
	if ui_layer:
		main_viewport.add_child(ui_layer)

	# Add SettingsDialog directly to MainViewport (same reason as UILayer)
	if settings_dialog:
		main_viewport.add_child(settings_dialog)

	_is_nodes_reparented = true

	# Reconnect OnscreenKeyboard to new viewport after reparenting
	var keyboard = get_node_or_null("/root/Main/UILayer/OnscreenKeyboard")
	if keyboard and keyboard.has_method("reconnect_viewport"):
		keyboard.reconnect_viewport()

	# Reconnect HomeView and LibraryView to new viewport after reparenting
	var home_view = ui_manager.view.get_view("Home")
	if home_view and home_view.has_method("reconnect_viewport"):
		home_view.reconnect_viewport()

	var library_view = ui_manager.view.get_view("Library")
	if library_view and library_view.has_method("reconnect_viewport"):
		library_view.reconnect_viewport()

	# Reconnect all other views that support viewport reconnection
	for view_name in ["Downloads", "Platforms"]:
		var view = ui_manager.view.get_view(view_name)
		if view and view.has_method("reconnect_viewport"):
			view.reconnect_viewport()

	# Reconnect feedback handlers to new viewport
	ui_manager.navigation._reconnect_feedback_viewport()

func _restore_ui_to_original_parents() -> void:
	"""Restore RootLayout to its original parent.

	RootLayout contains the full UI hierarchy including InnerLayout (which holds
	M3 nav and ContentWrapper), so restoring RootLayout restores everything.
	"""
	if not _is_nodes_reparented:
		return

	# Remove viewport layout from MainViewport
	if _viewport_layout:
		# Remove children first
		for child in _viewport_layout.get_children():
			_viewport_layout.remove_child(child)
		_viewport_layout.queue_free()
		_viewport_layout = null

	# Restore RootLayout (this restores the full hierarchy including InnerLayout with Navbar)
	if _root_control and _main_ui_original_parent:
		if _root_control.get_parent():
			_root_control.get_parent().remove_child(_root_control)
		_main_ui_original_parent.add_child(_root_control)

	# Restore UILayer
	var ui_layer = get_node_or_null("/root/Main/UILayer")
	if ui_layer and _ui_layer_original_parent:
		if ui_layer.get_parent():
			ui_layer.get_parent().remove_child(ui_layer)
		_ui_layer_original_parent.add_child(ui_layer)

	# Restore SettingsDialog to its original parent (or _root_control as fallback)
	var settings_dialog = ui_manager.overlay._settings_dialog
	if settings_dialog:
		if settings_dialog.get_parent():
			settings_dialog.get_parent().remove_child(settings_dialog)
		if _settings_dialog_original_parent:
			_settings_dialog_original_parent.add_child(settings_dialog)
		else:
			# Created after reparenting — move back to _root_control
			_root_control.add_child(settings_dialog)

	_is_nodes_reparented = false
	_main_ui_original_parent = null
	_ui_layer_original_parent = null
	_settings_dialog_original_parent = null

	# Reconnect OnscreenKeyboard to original viewport after restoring
	var keyboard = get_node_or_null("/root/Main/UILayer/OnscreenKeyboard")
	if keyboard and keyboard.has_method("reconnect_viewport"):
		keyboard.reconnect_viewport()

	# Reconnect HomeView and LibraryView to original viewport after restoring
	var home_view = ui_manager.view.get_view("Home")
	if home_view and home_view.has_method("reconnect_viewport"):
		home_view.reconnect_viewport()

	var library_view = ui_manager.view.get_view("Library")
	if library_view and library_view.has_method("reconnect_viewport"):
		library_view.reconnect_viewport()

	# Reconnect feedback handlers to original viewport
	ui_manager.navigation._reconnect_feedback_viewport()

# ==================== DUAL SCREEN DESKTOP FALLBACK ====================

func _enable_dual_screen_mode_desktop(second_screen_index: int) -> void:
	"""Desktop fallback: Use Godot Window for dual screen."""
	# Use call_deferred to avoid race conditions during _ready()
	_setup_desktop_dual_screen.call_deferred(second_screen_index)

func _setup_desktop_dual_screen(_second_screen_index: int) -> void:
	"""Setup desktop dual screen (called deferred to avoid race conditions)."""
	if not _hero_image:
		push_error("[DualScreenManager] Desktop dual screen requested but no hero image is available")
		return

	# Store reference to original parent
	_hero_original_parent = _hero_image.get_parent()

	# Get second screen bounds
	var screen_rect = SystemManager.display.get_second_screen_rect()
	if screen_rect.size == Vector2i.ZERO:
		push_warning("[DualScreenManager] Second screen has zero size, aborting dual screen mode")
		return

	# Create a secondary window for the hero image
	_hero_secondary_window = Window.new()
	_hero_secondary_window.title = "Kyodai - Hero"
	_hero_secondary_window.size = screen_rect.size
	_hero_secondary_window.position = screen_rect.position
	_hero_secondary_window.exclusive = false
	_hero_secondary_window.always_on_top = false
	_hero_secondary_window.borderless = true
	_hero_secondary_window.unresizable = true

	# Reparent hero image to secondary window
	if _hero_image.get_parent():
		_hero_image.get_parent().remove_child(_hero_image)

	_hero_secondary_window.add_child(_hero_image)

	# Make hero image fill the window
	_hero_image.set_anchors_preset(Control.PRESET_FULL_RECT)
	_hero_image.offset_bottom = 0
	_hero_image.position = Vector2.ZERO
	# DISABLED: Setting size on FULL_RECT controls fights Godot's layout system
	# and causes wrong sizes when the parent resizes between deferral and execution.
	# Anchors handle sizing automatically.
	# _hero_image.set_deferred("size", Vector2(screen_rect.size))

	# Add window to scene tree
	get_tree().root.add_child(_hero_secondary_window)

	_dual_screen_active = true

func _disable_dual_screen_mode_desktop() -> void:
	"""Desktop fallback: Close secondary window and restore hero."""
	# Remove hero from secondary window
	if _hero_image and _hero_image.get_parent() == _hero_secondary_window:
		_hero_secondary_window.remove_child(_hero_image)

	# Restore hero to original parent
	if _hero_original_parent and _hero_image:
		_hero_original_parent.add_child(_hero_image)
		_hero_image.visible = false

	# Close secondary window
	if _hero_secondary_window:
		_hero_secondary_window.queue_free()
		_hero_secondary_window = null

	_hero_original_parent = null

func _exit_tree() -> void:
	if _hero_secondary_window and is_instance_valid(_hero_secondary_window):
		if _hero_secondary_window.get_parent() == null:
			_hero_secondary_window.free()
		_hero_secondary_window = null
