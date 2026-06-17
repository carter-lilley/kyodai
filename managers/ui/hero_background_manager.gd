class_name HeroBackgroundManager
extends Manager

var ui_manager: Node

# Default hero height ratio (will be overridden by settings)
const HERO_SIZE_RATIO_DEFAULT = 0.33
const HERO_HEIGHT_RATIOS = [1.0, 0.66, 0.5, 0.33, 0.0]

# Hero image management - ALWAYS PRESENT
var _hero_image: HeroImage = null
var _hero_spacer: Control = null  # ALWAYS present, size controls layout

# Library background management - ALWAYS PRESENT
var _library_background: LibraryBackground = null
var _content_wrapper: Control = null  # Layers background + content

var _tab_container: TabContainer = null

func _ready():
	ui_manager = get_parent()

func setup(hero_image: HeroImage, hero_spacer: Control, library_background: LibraryBackground, content_wrapper: Control, tab_container: TabContainer) -> void:
	_hero_image = hero_image
	_hero_spacer = hero_spacer
	_library_background = library_background
	_content_wrapper = content_wrapper
	_tab_container = tab_container

	_connect_viewport_resize()
	_update_hero_size()
	_apply_library_background_config()
	_setup_library_appearance()

func _connect_viewport_resize() -> void:
	"""Connect to viewport resize signal to update hero size."""
	if get_viewport():
		get_viewport().size_changed.connect(_update_hero_size)

func _update_hero_size() -> void:
	"""Update hero image size based on settings."""
	if not _hero_image:
		return

	if not is_instance_valid(_hero_image):
		push_error("[HeroBackgroundManager] CRITICAL: _hero_image is not valid!")
		return
	if not is_instance_valid(_hero_spacer):
		push_error("[HeroBackgroundManager] CRITICAL: _hero_spacer is not valid!")
		return

	if not _hero_image.is_inside_tree():
		push_error("[HeroBackgroundManager] CRITICAL: _hero_image is not in the tree!")
		return

	var viewport_size = get_viewport().size
	var height_ratio = HERO_SIZE_RATIO_DEFAULT
	var _raw_setting_value = null

	if SettingsManager:
		var hero_config_setting = SettingsManager.get_setting("hero_effect_config")
		if hero_config_setting and hero_config_setting.value is Dictionary:
			var hero_config = hero_config_setting.value
			var height_index = hero_config.get("hero_height", 0)
			# Better type checking that handles float/int conversion
			if height_index is int or height_index is float:
				var index = int(height_index)
				if index >= 0 and index < HERO_HEIGHT_RATIOS.size():
					height_ratio = HERO_HEIGHT_RATIOS[index]
					_raw_setting_value = index

	var target_height = viewport_size.y * height_ratio
	if target_height < 1.0:
		target_height = 1.0

	# Use preset-based layout - NO manual positioning!
	# Let Godot's layout system handle positioning based on anchors
	if height_ratio >= 1.0:
		# Full height - fills entire ContentWrapper (like LibraryBackground)
		_hero_image.set_anchors_preset(Control.PRESET_FULL_RECT)
		_hero_image.offset_bottom = 0
	else:
		# Partial height - anchored to top with fixed height via offset_bottom
		# PRESET_TOP_WIDE sets anchor_top=0, anchor_bottom=0, so height = offset_bottom
		_hero_image.set_anchors_preset(Control.PRESET_TOP_WIDE)
		_hero_image.offset_bottom = target_height

	# Update spacer to push grid down when hero is <100%
	var spacer_height = 0.0 if height_ratio >= 1.0 else target_height
	_hero_spacer.custom_minimum_size = Vector2(0, spacer_height)
	# Note: Don't set visibility here - _update_hero_visibility() controls that based on view

	# Force redraw to apply changes
	_hero_image.queue_redraw()

func _verify_hero_size() -> void:
	"""Debug function to verify hero size after layout update."""
	if _hero_image:
		pass

func _apply_library_background_config() -> void:
	"""Apply the library background configuration from settings."""
	if not _library_background:
		return

	var config_setting = SettingsManager.get_setting("library_background_config")
	if config_setting and config_setting.value is Dictionary:
		_library_background.set_background_config(config_setting.value.duplicate())
	else:
		# Apply default config
		var default_gradient = Gradient.new()
		default_gradient.offsets = [0.0, 1.0]
		default_gradient.colors = [Color(0.1, 0.1, 0.15), Color(0.05, 0.05, 0.08)]

		_library_background.set_background_config({
			"effect_id": "gradient",
			"settings": {
				"background_gradient": default_gradient,
				"gradient_direction": 0
			}
		})

func _setup_library_appearance() -> void:
	"""Apply library background configuration to the LibraryBackground."""
	# Update the library background configuration from settings
	_apply_library_background_config()

	# Make TabContainer background transparent so we can see the LibraryBackground behind it
	var transparent_style = StyleBoxFlat.new()
	transparent_style.bg_color = Color(0, 0, 0, 0)  # Transparent
	_tab_container.add_theme_stylebox_override("panel", transparent_style)

func _update_hero_visibility(_view_name: String) -> void:
	"""Show/hide hero image, spacer, and library background based on current view and settings."""
	var dual_screen_active = ui_manager.dual_screen._dual_screen_active if ui_manager.dual_screen else false

	# In dual screen mode, main hero should always be hidden (shown on second screen instead)
	if dual_screen_active:
		if _hero_image:
			_hero_image.visible = false
		if _hero_spacer:
			_hero_spacer.visible = false
		return

	# Hide hero background completely in non-dual-screen mode (single-screen Android/desktop)
	if _hero_image:
		_hero_image.visible = false
	if _hero_spacer:
		_hero_spacer.visible = false
	return

	# Check if hero height is set to 0% (hidden)
	var height_ratio = HERO_SIZE_RATIO_DEFAULT
	if SettingsManager:
		var hero_config_setting = SettingsManager.get_setting("hero_effect_config")
		if hero_config_setting and hero_config_setting.value is Dictionary:
			var hero_config = hero_config_setting.value
			var height_index = hero_config.get("hero_height", 0)
			# Better type checking that handles float/int conversion (same as _update_hero_size)
			if height_index is int or height_index is float:
				var index = int(height_index)
				if index >= 0 and index < HERO_HEIGHT_RATIOS.size():
					height_ratio = HERO_HEIGHT_RATIOS[index]
	var hero_enabled = height_ratio > 0.0

	# Show background for all main views (Settings is now a dialog overlay)
	var show_background = true

	# Update hero image visibility (only visible when enabled AND showing background)
	if _hero_image:
		_hero_image.visible = show_background and hero_enabled

		if show_background and hero_enabled:
			# Clear hero when switching to a view that shows it
			_hero_image.clear()

	# Update spacer visibility (only when hero is enabled)
	if _hero_spacer:
		_hero_spacer.visible = show_background and hero_enabled

	# Update library background visibility (always show)
	if _library_background:
		_library_background.visible = true

func _on_hero_game_changed(game: GameResource) -> void:
	"""Handle hero game change from views."""
	if not _hero_image:
		return

	# Only update hero image if we're in Home or Library view
	var current_view = ui_manager.view.get_current_view()
	var current_view_name = current_view.view_name if current_view else ""

	if current_view_name not in ["Home", "Library"]:
		return

	# Check if hero height is set to 0% (hidden)
	var height_ratio = HERO_SIZE_RATIO_DEFAULT
	if SettingsManager:
		var hero_config_setting = SettingsManager.get_setting("hero_effect_config")
		if hero_config_setting and hero_config_setting.value is Dictionary:
			var hero_config = hero_config_setting.value
			var height_index = hero_config.get("hero_height", 0)
			if height_index is int and height_index >= 0 and height_index < HERO_HEIGHT_RATIOS.size():
				height_ratio = HERO_HEIGHT_RATIOS[height_index]
	if height_ratio == 0.0:
		return

	var dual_screen = ui_manager.dual_screen

	if game:
		_hero_image.set_game(game)
		# Also set game on second screen hero if dual screen is active
		if dual_screen and dual_screen._dual_screen_active and dual_screen._hero_copy_in_second_viewport and dual_screen._hero_copy_in_second_viewport.has_method("set_game"):
			dual_screen._hero_copy_in_second_viewport.set_game(game)
		# Force viewport update for UPDATE_ONCE mode
		if dual_screen and dual_screen._dual_screen_active:
			var ayn_thor_manager = get_node_or_null("/root/Main/AynThorManager")
			if ayn_thor_manager and ayn_thor_manager.has_method("force_hero_viewport_update"):
				ayn_thor_manager.force_hero_viewport_update()
	else:
		_hero_image.clear()
		if dual_screen and dual_screen._dual_screen_active and dual_screen._hero_copy_in_second_viewport and dual_screen._hero_copy_in_second_viewport.has_method("clear"):
			dual_screen._hero_copy_in_second_viewport.clear()
