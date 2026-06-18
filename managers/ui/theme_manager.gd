class_name ThemeManager
extends Manager

var ui_manager: Node

var _theme_refresh_pending: bool = false
var _preset_in_progress: bool = false
var _tab_container: TabContainer = null

func _ready():
	ui_manager = get_parent()

func setup(tab_container: TabContainer) -> void:
	_tab_container = tab_container
	_setup_library_appearance()

func _setup_library_appearance() -> void:
	"""Make the TabContainer panel transparent so the LibraryBackground shows through."""
	if not _tab_container:
		return
	var transparent_style := StyleBoxFlat.new()
	transparent_style.bg_color = Color(0, 0, 0, 0)
	transparent_style.border_color = Color(0, 0, 0, 0)
	transparent_style.border_width_bottom = 0
	transparent_style.border_width_left = 0
	transparent_style.border_width_right = 0
	transparent_style.border_width_top = 0
	_tab_container.add_theme_stylebox_override("panel", transparent_style)

func _apply_dark_mode(enabled: bool) -> void:
	M3Theme.is_dark_mode = enabled
	if not _theme_refresh_pending:
		_theme_refresh_pending = true
		call_deferred("_do_refresh_theme")

func _do_refresh_theme() -> void:
	_theme_refresh_pending = false
	_refresh_theme_on_all_nodes(get_tree().root)

func _refresh_theme_on_all_nodes(node: Node) -> void:
	if node == self:
		return
	if node.has_method("refresh_theme"):
		node.refresh_theme()
	for child in node.get_children():
		_refresh_theme_on_all_nodes(child)

func refresh_theme() -> void:
	_do_refresh_theme()

func _request_theme_refresh() -> void:
	if not _theme_refresh_pending:
		_theme_refresh_pending = true
		call_deferred("_do_refresh_theme")

func _trigger_refresh_if_pending() -> void:
	if _theme_refresh_pending:
		call_deferred("_do_refresh_theme")

func _on_apply_preset_begin() -> void:
	_preset_in_progress = true

func _on_apply_preset_end() -> void:
	print("[ThemeManager] _on_apply_preset_end")
	_preset_in_progress = false
	# Update nav type from settings before rebuilding
	var old_nav_type = ui_manager.navigation.get_nav_type()
	var type_setting = SettingsManager.get_setting("library_navigation_type")
	var new_nav_type = old_nav_type
	if type_setting:
		new_nav_type = type_setting.value
	# Apply background config in case it changed
	ui_manager._apply_library_background_config()
	# Rebuild navigation FIRST if navigation type changed so grids calculate correctly
	if new_nav_type != old_nav_type:
		ui_manager.navigation.set_nav_type(new_nav_type)
		ui_manager.navigation._rebuild_nav_and_layout()
	# One rebuild after preset is fully applied
	# use_true=true to ensure card effects are fully refreshed
	ui_manager.view._rebuild_views("Preset applied", true)
	# Apply dark mode in case it changed during preset
	var dark_mode_setting = SettingsManager.get_setting("dark_mode")
	if dark_mode_setting:
		_apply_dark_mode(dark_mode_setting.value)
	# Apply primary color in case it changed during preset
	var primary_color_setting = SettingsManager.get_setting("library_primary_color")
	if primary_color_setting and primary_color_setting.value is Color:
		M3Theme.set_primary_seed(primary_color_setting.value)
	# Ensure theme is refreshed in case accent color or dark mode changed.
	# Always schedule the deferred refresh; if nav type changed the rebuild above
	# already ran, and the deferred refresh will pick up the new tree state.
	if not _theme_refresh_pending:
		_theme_refresh_pending = true
		call_deferred("_do_refresh_theme")
	# Re-apply tab container transparency after theme refresh in case overrides were reset
	call_deferred("_setup_library_appearance")
