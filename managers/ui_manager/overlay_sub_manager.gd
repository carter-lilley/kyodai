class_name OverlaySubManager
extends Manager

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

var ui_manager: Node

# Settings dialog
var _settings_dialog = null

# Shuffler dialog
var _shuffler_dialog: ShufflerConfigDialog = null

# Game details sheet (owned by OverlayManager, not a static singleton)
var _game_details_sheet: GameDetailsSheet = null

# Modal management (now uses M3Menu)
var _active_menu: M3Menu = null
var _modal_context: Dictionary = {}
# Anchor of the most recent context menu, used to restore focus to the
# summoning card when the details sheet is dismissed.
var _last_menu_anchor: WeakRef = null

# Active generic dialogs tracked so we can flush deferred rebuilds only when
# the last dialog has closed.
var _active_dialogs: Array[M3Dialog] = []

## Emitted when the number of tracked dialogs changes; the launch transition
## overlay uses this to stop blocking input while a dialog is up.
signal active_dialog_count_changed(count: int)

func has_active_dialog() -> bool:
	return not _active_dialogs.is_empty()

var _root_control: Control = null

func _ready():
	ui_manager = get_parent()

func setup(root_control: Control) -> void:
	_root_control = root_control

func pre_create_settings_dialog(force: bool = false) -> void:
	"""Eagerly build the settings dialog in the background.
	If a valid dialog already exists and force is false, this is a no-op."""
	if _settings_dialog and is_instance_valid(_settings_dialog) and not force:
		return

	if _settings_dialog and is_instance_valid(_settings_dialog):
		_settings_dialog.queue_free()
		_settings_dialog = null

	# Use script .new() instead of scene instantiation to avoid CanvasLayer script attachment issues in SubViewports
	var settings_script = load("res://view/settings_dialog.gd")
	if not settings_script:
		push_error("[OverlayManager] Failed to load SettingsDialog script")
		return
	_settings_dialog = settings_script.new()
	if not _settings_dialog or not is_instance_valid(_settings_dialog):
		push_error("[OverlayManager] Failed to instantiate SettingsDialog")
		return
	if not _settings_dialog.has_signal("dismissed"):
		push_error("[OverlayManager] SettingsDialog instance missing 'dismissed' signal — script failed to attach. Class: " + _settings_dialog.get_class())
		return
	_settings_dialog.dismissed.connect(_on_settings_dialog_dismissed)

	if not _settings_dialog.is_inside_tree():
		_add_settings_dialog_to_correct_parent()

func show_settings_dialog() -> void:
	"""Show the settings popup dialog."""
	if not _settings_dialog or not is_instance_valid(_settings_dialog):
		pre_create_settings_dialog()

	if not _settings_dialog or not is_instance_valid(_settings_dialog):
		push_error("[OverlayManager] Settings dialog unavailable")
		return

	if not _settings_dialog.is_inside_tree():
		_add_settings_dialog_to_correct_parent()

	# Release scene-wide focus lock before opening settings so settings controls
	# can receive focus.
	if ui_manager:
		var current_view = ui_manager.get_current_view()
		if current_view and current_view.games_grid:
			ui_manager.exit_focus_lock(current_view.games_grid)

	_settings_dialog.show_overlay()

func _add_settings_dialog_to_correct_parent() -> void:
	"""Add SettingsDialog to a parent where its CanvasLayer script will attach correctly.
	SubViewports break CanvasLayer script attachment; keep it in the root viewport."""
	if _settings_dialog.is_inside_tree():
		return
	var tree = Engine.get_main_loop()
	if tree and tree.root:
		# Deferred to avoid "busy parent" during _ready, but check again at execution
		# time in case show_overlay() auto-added it to a SubViewport in the meantime.
		var add_fn = func():
			if is_instance_valid(_settings_dialog) and not _settings_dialog.is_inside_tree():
				tree.root.add_child(_settings_dialog)
		add_fn.call_deferred()
	else:
		var add_fn = func():
			if is_instance_valid(_settings_dialog) and not _settings_dialog.is_inside_tree():
				_root_control.add_child(_settings_dialog)
		add_fn.call_deferred()

func show_settings_dialog_with_category(category_id: String) -> void:
	"""Open the settings dialog and jump to a specific category."""
	show_settings_dialog()
	if _settings_dialog and is_instance_valid(_settings_dialog):
		_settings_dialog.select_category(category_id)

func is_settings_dialog_open() -> bool:
	return _settings_dialog and is_instance_valid(_settings_dialog) and _settings_dialog.visible

func get_settings_dialog_category() -> String:
	if _settings_dialog and is_instance_valid(_settings_dialog):
		return _settings_dialog.get_current_category()
	return ""

func reopen_settings_dialog() -> void:
	"""Cancel, close, and reopen the settings dialog at the same category."""
	if not _settings_dialog or not is_instance_valid(_settings_dialog) or not _settings_dialog.visible:
		return

	var category := get_settings_dialog_category()
	_settings_dialog.cancel_and_dismiss()
	_reopen_settings_dialog_async.call_deferred(category)

func _reopen_settings_dialog_async(category: String) -> void:
	# Wait two frames so the display sub-manager's swap scale update has applied.
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(_settings_dialog) and not _settings_dialog.visible:
		show_settings_dialog_with_category(category)

func set_card_designer_preview_game(romm_id: int) -> void:
	"""Tell the Card Designer preview which game's cover to display."""
	if not _settings_dialog or not is_instance_valid(_settings_dialog):
		pre_create_settings_dialog()
	
	if not _settings_dialog:
		return
	
	var game = DataManager.get_game_by_id(romm_id)
	if not game:
		return
	
	var card_designer = _settings_dialog.get_card_designer_view()
	if card_designer:
		card_designer.set_preview_game(game)

func _on_settings_dialog_dismissed() -> void:
	"""Handle settings dialog dismissal."""
	ui_manager.settings_dialog_dismissed.emit()

	# Trigger any deferred rebuilds on the currently visible view now that
	# the dialog is closed. If another dialog (e.g. a confirmation popup)
	# replaced this one, the rebuild stays deferred until that dialog closes.
	ui_manager.view.flush_pending_rebuilds_if_no_dialog()

	# If focus returns to a locked grid, re-apply scene-wide focus lock.
	ui_manager.refresh_focus_lock_state()


func _track_dialog(dialog: M3Dialog) -> void:
	if dialog in _active_dialogs:
		return
	_active_dialogs.append(dialog)
	dialog.dismissed.connect(_on_generic_dialog_dismissed.bind(dialog))
	active_dialog_count_changed.emit(_active_dialogs.size())

func _on_generic_dialog_dismissed(dialog: M3Dialog) -> void:
	_active_dialogs.erase(dialog)
	active_dialog_count_changed.emit(_active_dialogs.size())
	# Only flush deferred rebuilds once all tracked dialogs are closed.
	if _active_dialogs.is_empty():
		ui_manager.view.flush_pending_rebuilds_if_no_dialog()

func _add_overlay_to_root(overlay: Node) -> void:
	"""Add an overlay node to the correct parent for the current display mode."""
	var parent = M3Overlay.get_overlay_parent()
	if parent and overlay.get_parent() == null:
		parent.add_child(overlay)
	elif not overlay.is_inside_tree():
		if _root_control:
			_root_control.add_child(overlay)
		else:
			get_tree().root.add_child(overlay)

# ==================== FILE DIALOGS ====================

func show_folder_dialog(title: String, initial_dir: String, on_dir_selected: Callable, use_native: bool = true) -> FileDialog:
	"""Show a folder picker and return the dialog instance."""
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = use_native
	dialog.title = title
	dialog.current_dir = initial_dir if initial_dir else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)

	dialog.dir_selected.connect(func(dir: String):
		if on_dir_selected.is_valid():
			on_dir_selected.call(FSM.resolve_content_uri(dir))
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)

	_add_overlay_to_root(dialog)
	dialog.show()
	return dialog

func show_file_dialog(title: String, filters: PackedStringArray, initial_dir: String, on_file_selected: Callable, use_native: bool = true) -> FileDialog:
	"""Show a file picker and return the dialog instance."""
	var dialog := FileDialog.new()
	dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dialog.access = FileDialog.ACCESS_FILESYSTEM
	dialog.use_native_dialog = use_native
	dialog.title = title
	dialog.filters = filters
	dialog.current_dir = initial_dir if initial_dir else OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)

	dialog.file_selected.connect(func(path: String):
		if on_file_selected.is_valid():
			on_file_selected.call(path)
		dialog.queue_free()
	)
	dialog.canceled.connect(dialog.queue_free)

	_add_overlay_to_root(dialog)
	if use_native:
		dialog.show()
	else:
		dialog.popup_centered(Vector2(M3Units.dp(800), M3Units.dp(600)))
	return dialog

# ==================== GENERIC DIALOGS ====================

func show_confirm(title: String, body: String, on_accept: Callable = Callable(), on_cancel: Callable = Callable(), on_dismissed: Callable = Callable(), options: Dictionary = {}) -> M3Dialog:
	"""Show a confirmation dialog with Accept/Cancel actions."""
	var accept_text: String = options.get("accept_text", "Accept")
	var cancel_text: String = options.get("cancel_text", "Cancel")
	var auto_dismiss: bool = options.get("auto_dismiss", true)

	var dialog := M3Dialog.new()
	_apply_dialog_options(dialog, options)
	dialog.title_text = title
	dialog.body_text = body

	var wrapped_cancel = func():
		if on_cancel.is_valid():
			on_cancel.call()
		dialog.dismiss()

	var wrapped_accept = func():
		if on_accept.is_valid():
			on_accept.call()
		if auto_dismiss:
			dialog.dismiss()

	dialog.add_action(cancel_text, wrapped_cancel, false)
	dialog.add_action(accept_text, wrapped_accept, true)

	if on_dismissed.is_valid():
		dialog.dismissed.connect(on_dismissed)

	_add_overlay_to_root(dialog)
	dialog.show_overlay()
	_track_dialog(dialog)
	return dialog

func show_alert(title: String, body: String, on_ok: Callable = Callable(), on_dismissed: Callable = Callable(), options: Dictionary = {}) -> M3Dialog:
	"""Show an alert dialog with a single OK action."""
	var ok_text: String = options.get("ok_text", "OK")
	var auto_dismiss: bool = options.get("auto_dismiss", true)

	var dialog := M3Dialog.new()
	_apply_dialog_options(dialog, options)
	dialog.title_text = title
	dialog.body_text = body

	var wrapped_ok = func():
		if on_ok.is_valid():
			on_ok.call()
		if auto_dismiss:
			dialog.dismiss()

	dialog.add_action(ok_text, wrapped_ok, true)

	if on_dismissed.is_valid():
		dialog.dismissed.connect(on_dismissed)

	_add_overlay_to_root(dialog)
	dialog.show_overlay()
	_track_dialog(dialog)
	return dialog

func show_custom_dialog(build_fn: Callable, on_dismissed: Callable = Callable(), options: Dictionary = {}) -> M3Dialog:
	"""Show a dialog built by the caller. The build_fn receives the M3Dialog."""
	var dialog := M3Dialog.new()
	_apply_dialog_options(dialog, options)

	if build_fn.is_valid():
		build_fn.call(dialog)

	if on_dismissed.is_valid():
		dialog.dismissed.connect(on_dismissed)

	_add_overlay_to_root(dialog)
	dialog.show_overlay()
	_track_dialog(dialog)
	return dialog

func _apply_dialog_options(dialog: M3Dialog, options: Dictionary) -> void:
	"""Apply optional overlay styling to a generic dialog."""
	if options.has("overlay_type"):
		dialog.overlay_type = options["overlay_type"]
	if options.has("overlay_layer"):
		dialog.overlay_layer = options["overlay_layer"]
	if options.has("dismissible"):
		dialog.dismissible = options["dismissible"]
	if options.has("hero_icon_name"):
		dialog.hero_icon_name = options["hero_icon_name"]

func show_shuffler_dialog() -> void:
	"""Show the shuffler configuration dialog."""
	if LaunchManager.is_session_active():
		SystemManager.notifications.show_notification("A shuffler session is already active", SystemManager.notifications.Type.INFO)
		return

	if not _shuffler_dialog or not is_instance_valid(_shuffler_dialog):
		var scene = load("res://components/shuffler_config_dialog.tscn")
		if scene:
			_shuffler_dialog = scene.instantiate() as ShufflerConfigDialog
			if _shuffler_dialog:
				# Cold dialog: free after dismissal
				_shuffler_dialog.persistent = false
				_shuffler_dialog.start_session_requested.connect(_on_shuffler_start_requested)
		else:
			var dialog_script = load("res://components/shuffler_config_dialog.gd")
			if dialog_script:
				_shuffler_dialog = dialog_script.new() as ShufflerConfigDialog
				_shuffler_dialog.start_session_requested.connect(_on_shuffler_start_requested)

	if _shuffler_dialog and not _shuffler_dialog.is_inside_tree():
		get_tree().root.add_child(_shuffler_dialog)

	if _shuffler_dialog:
		_shuffler_dialog.show_overlay()

func _on_shuffler_start_requested(config: Dictionary) -> void:
	"""Handle shuffler session start request."""
	LaunchManager.start_shuffler_session(config)

func get_settings_dialog_platforms_view() -> PlatformsSettingsView:
	if _settings_dialog and is_instance_valid(_settings_dialog):
		return _settings_dialog.get_platforms_settings_view()
	return null

# ==================== MODAL MANAGEMENT ====================

func show_context_menu(items: Array[Dictionary], anchor: Control, context: Dictionary = {}) -> String:
	"""Show a context menu modal anchored to the given control. Returns modal ID."""
	dismiss_modal()
	_last_menu_anchor = weakref(anchor) if anchor != null else null

	var menu = M3Menu.new()

	# Store context
	_modal_context = context.duplicate()
	var modal_id = str(Time.get_unix_time_from_system())
	_modal_context["modal_id"] = modal_id

	# Build menu items with callbacks
	for item in items:
		var item_id = item.get("id", "")
		var item_text = item.get("text", "")
		var item_icon = item.get("icon", "")
		var item_disabled = item.get("disabled", false)

		var callback = func():
			ui_manager.modal_item_selected.emit(item_id, _modal_context.duplicate())
			dismiss_modal()

		menu.add_item(item_text, callback, item_icon)
		if item_disabled:
			menu.get_item(menu.get_item_count() - 1).disabled = true

	# Add scrim backdrop to block interaction with content below
	var scrim = ColorRect.new()
	scrim.color = Color(0, 0, 0, 0.5)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	scrim.z_index = -1
	menu.add_child(scrim)
	menu.move_child(scrim, 0)

	# Find and pause the scroll container so the anchor doesn't move
	var scroll_container = anchor
	while scroll_container:
		if scroll_container is SmoothScrollContainer:
			scroll_container.scroll_paused = true
			break
		scroll_container = scroll_container.get_parent()

	# Connect dismissed signal — cleanup happens here so dismiss_modal() doesn't double-fire
	menu.dismissed.connect(func():
		if scroll_container and is_instance_valid(scroll_container):
			scroll_container.scroll_paused = false
		_active_menu = null
		_modal_context.clear()
		ui_manager.modal_dismissed.emit(modal_id)
	, CONNECT_ONE_SHOT)

	_active_menu = menu
	menu.popup(anchor)

	ui_manager.modal_shown.emit(modal_id)
	return modal_id

func show_game_context_menu(romm_id: int, anchor: Control, show_delete: bool = true) -> String:
	"""Show the standard game context menu."""
	var items: Array[Dictionary] = [
		{"id": "launch", "text": "Launch", "icon": "play"},
		{"id": "details", "text": "Details", "icon": "information"}
	]

	# Add delete option only if game is downloaded and show_delete is true
	var game = DataManager.get_game_by_id(romm_id)
	if show_delete and game and game.is_active_variant_downloaded():
		items.append({"id": "delete", "text": "Delete", "icon": "trash-can"})

	# Add "Add to Steam" option if game is downloaded (desktop only)
	if game and game.is_active_variant_downloaded() and (SystemManager.platform.is_windows() or SystemManager.platform.is_linux()):
		items.append({"id": "add_to_steam", "text": "Add to Steam"})

	items.append({"id": "card_designer", "text": "Card Designer", "icon": "cards-outline"})
	items.append({"id": "hide", "text": "Hide", "icon": "eye-off"})

	# Start preloading heavy details while the menu is open.
	if _game_details_sheet:
		_game_details_sheet.prepare_for_game(romm_id)

	return show_context_menu(items, anchor, {"romm_id": romm_id})

func dismiss_modal() -> void:
	"""Dismiss the active menu if one exists.
	Cleanup and modal_dismissed emission are handled by the menu's dismissed signal."""
	if _active_menu != null and is_instance_valid(_active_menu) and _active_menu.is_open():
		_active_menu.dismiss()
	# If menu is already closed, the dismissed callback already cleaned up.

func is_modal_open() -> bool:
	"""Returns whether a modal is currently displayed."""
	return _active_menu != null and is_instance_valid(_active_menu) and _active_menu.is_open()

# ==================== GAME DETAILS VIEW ====================

func show_game_details(romm_id: int) -> void:
	"""Show the game details bottom sheet for a specific game."""
	var game = DataManager.get_game_by_id(romm_id)
	if not game:
		push_warning("[OverlayManager] Cannot show details - game not found: ", romm_id)
		return

	_ensure_game_details_sheet()
	_game_details_sheet.show_for_game(game)
	# show_overlay() captured focus while the context menu was still open, so
	# the auto-captured owner is a menu item that gets freed on menu dismissal.
	# Override it with the menu's anchor (the summoning card) so ui_cancel
	# returns focus to the card.
	var anchor: Control = _last_menu_anchor.get_ref() if _last_menu_anchor != null else null
	if anchor != null and is_instance_valid(anchor):
		_game_details_sheet.set_focus_restore_target(anchor)
	_game_details_sheet.set_focus_restore_fallback(ui_manager.get_focus_restore_fallback_to_home())

func _ensure_game_details_sheet() -> void:
	if _game_details_sheet and is_instance_valid(_game_details_sheet):
		return
	var sheet_scene = load("res://components/game_details_sheet.tscn")
	if sheet_scene:
		_game_details_sheet = sheet_scene.instantiate() as GameDetailsSheet
		_game_details_sheet.visible = false
	else:
		# Fallback to script instantiation if the scene is missing
		_game_details_sheet = GameDetailsSheet.new()
		_game_details_sheet.visible = false
	# Don't add to the tree here; M3Sheet.show_overlay() adds the sheet on its
	# first show, so we avoid "busy setting up children" errors during initialization.

func _release_overlays() -> void:
	"""Release cached overlay references when the manager exits the tree."""
	if _game_details_sheet and is_instance_valid(_game_details_sheet):
		if _game_details_sheet.get_parent() == null:
			_game_details_sheet.free()
		_game_details_sheet = null

	if _settings_dialog and is_instance_valid(_settings_dialog):
		if _settings_dialog.get_parent() == null:
			_settings_dialog.free()
		_settings_dialog = null

	if _shuffler_dialog and is_instance_valid(_shuffler_dialog):
		if _shuffler_dialog.get_parent() == null:
			_shuffler_dialog.free()
		_shuffler_dialog = null

	_active_menu = null
	_modal_context.clear()

func _exit_tree() -> void:
	_release_overlays()
