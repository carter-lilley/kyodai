class_name SettingsDialog
extends M3Dialog

## Popup settings dialog with two-pane layout.
## Creates category content directly from DataManager subgroups.

const SUBGROUP_ICONS: Dictionary[String, String] = {
	"Audio": "volume-high",
	"Display": "monitor",
	"Save Sync": "sync",
	"Storage": "harddisk",
	"Library Appearance": "palette",
}

var _left_pane: VBoxContainer
var _left_scroll: ScrollContainer
var _left_column: VBoxContainer
var _left_margin: MarginContainer
var _right_pane: MarginContainer
var _right_scroll: ScrollContainer
var _right_content: Control
var _category_buttons: Dictionary[String, M3Button] = {}
var _category_contents: Dictionary[String, Control] = {}
var _current_category: String = ""
# Remember how each category button was built (icon-only vs text) so the
# sidebar can be rebuilt when the viewport crosses the compact breakpoint.
var _category_button_specs: Dictionary = {}  # id -> {label, icon}
var _sidebar_built_compact: bool = false

# Built-in ScrollContainer.follow_focus is enabled, but it binds to the
# viewport at NOTIFICATION_READY and never re-binds, so it dies when the
# dialog is reparented into the dual-screen SubViewport. We re-bind it in
# _reconnect_focus_follow and keep a manual ensure_control_visible fallback.
var _focus_follow_viewport: Viewport = null

const DEBUG_LAYOUT: bool = false
const DEBUG_FOCUS_GUARD: bool = true

# Snapshot of all SettingsVar values at dialog open, used to revert on Cancel.
var _snapshot: Dictionary = {}
var _cancelled: bool = false

func _init():
	dialog_variant = Variant.BASIC
	dialog_max_width = 1100.0
	title_text = "Settings"
	persistent = true
	fill_viewport_height = true
	# Stamped mode: the dialog's size is a pure function of the viewport and
	# tall pages scroll inside it; content never resizes the dialog.
	fixed_size = true
	# Ride DS swaps (reparent + on_viewport_settled re-stamp) instead of being
	# dismissed, so pending setting changes survive a screen swap.
	survive_ds_swap = true
	super._init()
	if UIManager:
		set_focus_restore_fallback(UIManager.get_focus_restore_fallback_to_home())

func _ready():
	super._ready()
	var phase_start_us := Time.get_ticks_usec()
	# Fullscreen variant has an outer scroll; BASIC does not. Each category page
	# already scrolls independently, so only touch fullscreen-specific nodes.
	if dialog_variant == Variant.FULL_SCREEN:
		if _scroll:
			_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		if _bottom_actions:
			_bottom_actions.visible = false
	_build_two_pane_layout()
	print("[SettingsDialog] two-pane layout elapsed_us=", Time.get_ticks_usec() - phase_start_us)
	phase_start_us = Time.get_ticks_usec()
	await _build_categories()
	print("[SettingsDialog] _build_categories (first burst) elapsed_us=", Time.get_ticks_usec() - phase_start_us)

	# Hide default body label; keep the title label as the popup title.
	if _body_label:
		_body_label.visible = false

	# Replace the default action with explicit Cancel / OK buttons.
	# OK applies changes and closes; Cancel reverts to the snapshot taken on open.
	clear_actions()
	add_action("Cancel", _on_cancel_pressed, false)
	add_action("OK", _on_ok_pressed, true)
	# Keep the bottom row out of controller navigation until the user explicitly
	# reaches the end of the settings page. This is a hard backstop for any
	# input-propagation path that bypasses the directional guard above.
	for btn in _actions:
		btn.focus_mode = Control.FOCUS_CLICK
	# The basic variant wraps content_slot in a body scroll for generic dialogs,
	# but the settings two-pane layout manages its own scrolling. Disable the
	# outer follow-focus so it doesn't fight the per-pane scroll/follow logic.
	if _body_scroll:
		_body_scroll.follow_focus = false

func _build_two_pane_layout() -> void:
	"""Build two-pane HBox inside content_slot: sidebar + divider + content pane."""

	for child in content_slot.get_children():
		child.queue_free()

	# M3Dialog's chrome firewall severs min-size propagation above the vbox, so
	# the slot is container-managed: claim the leftover dialog height directly.
	content_slot.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Page content propagates no further than the chrome firewall and can never
	# inflate the dialog's stamped size.
	var hbox = HBoxContainer.new()
	hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_slot.add_child(hbox)

	# Left sidebar. The category list lives in a ScrollContainer so its natural
	# height can never inflate the dialog's minimum size (a Control's rect can
	# never go below its minimum, which previously forced shrink-to-fit buttons).
	# The Exit button is the last item of the same scrollable list.
	_left_pane = VBoxContainer.new()
	_left_pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_pane.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_left_pane.alignment = BoxContainer.ALIGNMENT_BEGIN

	_left_scroll = ScrollContainer.new()
	_left_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# Handled manually via _on_focus_follow_changed (viewport-proof).
	_left_scroll.follow_focus = false
	_left_scroll.add_child(_left_pane)

	_left_column = VBoxContainer.new()
	_left_column.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_left_column.add_child(_left_scroll)

	_left_margin = MarginContainer.new()
	_left_margin.add_child(_left_column)
	hbox.add_child(_left_margin)

	# Divider
	var divider = VSeparator.new()
	var divider_sb = StyleBoxLine.new()
	divider_sb.color = Color(0.5, 0.5, 0.5, 0.2)
	divider_sb.thickness = 1
	divider.add_theme_stylebox_override("separator", divider_sb)
	hbox.add_child(divider)

	# Right content pane. All category pages live inside ONE ScrollContainer so
	# every page (generated or scene) is clipped to the dialog and scrollable.
	# A ScrollContainer reports ~0 minimum height, so page content can never
	# inflate the dialog's measured size.
	_right_pane = MarginContainer.new()
	_right_pane.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right_pane.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_right_scroll = ScrollContainer.new()
	_right_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_right_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Let Godot auto-scroll the pane for focus changes. We re-bind this after
	# dual-screen reparents in _reconnect_focus_follow; manual ensure_control_visible
	# remains as a viewport-proof fallback.
	_right_scroll.follow_focus = true
	_right_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_right_pane.add_child(_right_scroll)
	hbox.add_child(_right_pane)

	_apply_scale()

func _is_compact_sidebar() -> bool:
	"""Use icon-only category buttons on small screens."""
	return _is_small_screen()

## Waits out frames whose warmup budget is already spent so the pre-created
## category builds can't stack onto grid settle or shader prewarm work.
## No-op outside the startup window (try_spend always passes in steady mode).
func _await_build_budget() -> void:
	while not WarmupBudget.try_spend(WarmupBudget.COST_SETTINGS_CATEGORY_US, "settings_category"):
		await get_tree().process_frame

func _build_categories() -> void:
	"""Create category buttons and content directly from DataManager + scenes."""
	var subgroups = DataManager.get_settings_by_subgroup()

	# Regular subgroups — build SettingsMenu content directly
	for subgroup_name in subgroups.keys():
		if subgroup_name == "RomM Connection":
			continue

		var id = subgroup_name.to_snake_case()
		var icon = SUBGROUP_ICONS.get(subgroup_name, "tune")
		var settings_vars = subgroups[subgroup_name]

		# Filter out platform-specific settings
		if subgroup_name == "Storage":
			if not (SystemManager.platform.is_windows() or SystemManager.platform.is_linux()):
				settings_vars = settings_vars.filter(func(sv): return sv.display_name != "Steam Installation Folder")
			# Move Download Speed to the end so storage paths appear first.
			settings_vars.sort_custom(func(a, b): return int(b.display_name == "Download Speed") - int(a.display_name == "Download Speed"))
		elif subgroup_name == "Display":
			if SystemManager.platform.is_android():
				settings_vars = settings_vars.filter(func(sv): return sv.display_name not in ["Windowed", "Windowed Resolution:"])
		_add_category_button(id, subgroup_name, icon)

		var cat_start_us := Time.get_ticks_usec()
		if subgroup_name == "Library Appearance":
			# Library Appearance has complex custom UI — build it directly.
			_category_contents[id] = preload("res://view/library_appearance_settings_view.gd").new()
		else:
			# Regular subgroup: SettingsMenu in a scrollable wrapper
			_category_contents[id] = _create_settings_menu_content(subgroup_name, settings_vars, icon)
		print("[SettingsDialog] category '", id, "' build elapsed_us=", Time.get_ticks_usec() - cat_start_us)

		# The dialog is pre-created at startup; spread category builds over
		# frames so the whole dialog doesn't land in one synchronous burst.
		await get_tree().process_frame
		await _await_build_budget()

	# RomM — platform settings scene
	var cat_start_us := Time.get_ticks_usec()
	_add_category_button("romm", "RomM", "cloud-sync")
	var platforms_view = preload("res://view/platforms_settings_view.tscn").instantiate()
	platforms_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_category_contents["romm"] = platforms_view
	print("[SettingsDialog] category 'romm' build elapsed_us=", Time.get_ticks_usec() - cat_start_us)
	await get_tree().process_frame
	await _await_build_budget()

	# Card Designer
	cat_start_us = Time.get_ticks_usec()
	_add_category_button("card_designer", "Card Designer", "cards-outline")
	var card_designer = preload("res://view/card_designer_view.tscn").instantiate()
	card_designer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_category_contents["card_designer"] = card_designer
	print("[SettingsDialog] category 'card_designer' build elapsed_us=", Time.get_ticks_usec() - cat_start_us)
	await get_tree().process_frame
	await _await_build_budget()

	# Background Designer
	cat_start_us = Time.get_ticks_usec()
	_add_category_button("background_designer", "Background Designer", "image-outline")
	var background_designer = BackgroundDesignerView.new()
	background_designer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_category_contents["background_designer"] = background_designer
	print("[SettingsDialog] category 'background_designer' build elapsed_us=", Time.get_ticks_usec() - cat_start_us)
	await get_tree().process_frame
	await _await_build_budget()

	# GameNative (Android only)
	if SystemManager.platform.is_android():
		_add_category_button("gamenative", "GameNative", "android")
		var gamenative = preload("res://view/gamenative_settings_view.gd").new()
		_category_contents["gamenative"] = gamenative

	# Exit — closes the app via the shared shutdown path in main.gd. Added as
	# the last item of the scrollable category list (not a pinned slot) so
	# directional focus flows through it like any other category.
	_add_category_button("exit", "Exit", "logout")

	# Select first category that has content
	for btn_id in _category_buttons.keys():
		if _category_contents.has(btn_id):
			select_category(btn_id)
			break

func _add_category_button(id: String, label: String, icon: String, target: Container = null) -> void:
	var parent: Container = target if target else _left_pane
	_category_button_specs[id] = {"label": label, "icon": icon, "target": target}
	_sidebar_built_compact = _is_compact_sidebar()
	var btn: M3Button
	if _is_compact_sidebar():
		var icon_btn = M3IconButton.new()
		icon_btn.icon_name = icon
		icon_btn.icon_button_variant = M3IconButton.IconVariant.STANDARD
		icon_btn.icon_button_size = M3IconButton.IconSize.SMALL
		icon_btn.tooltip_text = label
		icon_btn.pressed.connect(_on_category_selected.bind(id))
		parent.add_child(icon_btn)
		btn = icon_btn
	else:
		var text_btn = M3Button.new()
		text_btn.text = label
		text_btn.icon_name = icon
		text_btn.button_variant = M3Button.Variant.TEXT
		text_btn.button_shape = M3Button.Shape.PILL
		text_btn.button_size = M3Button.Size.MEDIUM
		text_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		text_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		text_btn.pressed.connect(_on_category_selected.bind(id))
		parent.add_child(text_btn)
		btn = text_btn
	# Fixed pill height, top-stacked: the sidebar scrolls instead of compressing
	# buttons when space is tight.
	btn.custom_minimum_size.y = M3Units.dp(48)
	btn.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_category_buttons[id] = btn

func _create_settings_menu_content(setting_name: String, settings_vars: Array, icon: String = "") -> Control:
	"""Create a SettingsMenu in a MarginContainer + VBoxContainer. Scrolling is
	provided by the shared pane-level ScrollContainer (_right_scroll)."""
	var margin = MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.set_meta("category_margin", true)
	margin.add_theme_constant_override("margin_left", M3Units.dp(20))
	margin.add_theme_constant_override("margin_top", M3Units.dp(20))
	margin.add_theme_constant_override("margin_right", M3Units.dp(20))
	margin.add_theme_constant_override("margin_bottom", M3Units.dp(20))

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Use SHRINK_BEGIN so the ScrollContainer measures true content height
	# instead of expanding and inflating the popup's minimum size.
	vbox.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	var menu = SettingsMenu.new()
	menu.initialize_settings_menu(setting_name, settings_vars, icon)
	menu.setting_changed.connect(func(value, setting): DataManager.set_setting(value, setting))
	vbox.add_child(menu)

	margin.add_child(vbox)
	return margin

func _on_category_selected(id: String) -> void:
	if id == "exit":
		get_tree().root.propagate_notification(NOTIFICATION_WM_CLOSE_REQUEST)
		return
	select_category(id)

func select_category(id: String) -> void:
	if _current_category == id:
		return

	# Hide previous content
	if _right_content and _right_content.get_parent() == _right_scroll:
		if _right_content.has_method("on_view_hide"):
			_right_content.on_view_hide()
		_right_scroll.remove_child(_right_content)

	_current_category = id

	# Update button visuals
	for btn_id in _category_buttons.keys():
		var btn = _category_buttons[btn_id]
		if btn is M3IconButton:
			btn.icon_button_variant = M3IconButton.IconVariant.TONAL if btn_id == id else M3IconButton.IconVariant.STANDARD
		else:
			btn.button_variant = M3Button.Variant.TONAL if btn_id == id else M3Button.Variant.TEXT

	# Show new content
	if _category_contents.has(id):
		_right_content = _category_contents[id]
		# ScrollContainer sizes children by combined minimum size unless they
		# carry EXPAND_FILL - scene roots default to FILL and would collapse
		# to (0,0), so force the flags on every page before adding.
		_right_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_right_content.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_right_scroll.add_child(_right_content)
		_right_scroll.scroll_vertical = 0
		if _right_content.has_method("on_view_show"):
			_right_content.on_view_show()
		if DEBUG_LAYOUT:
			_dump_layout_metrics.call_deferred(id)

func _dump_layout_metrics(id: String) -> void:
	await get_tree().create_timer(0.5).timeout
	var viewport_size := Vector2.ZERO
	if get_viewport():
		viewport_size = get_viewport().get_visible_rect().size
	var window_size := Vector2i.ZERO
	if get_window():
		window_size = get_window().size
	print("[SettingsDialog] layout dump for category '%s': viewport=%s window=%s dp_scale=%.2f" % [id, viewport_size, window_size, M3Units.dp(1.0)])
	var hbox_node: Control = null
	if content_slot and content_slot.get_child_count() > 0:
		hbox_node = content_slot.get_child(0) as Control
	var layers: Array = [
		["dialog_container", _dialog_container],
		["content_slot", content_slot],
		["hbox", hbox_node],
		["right_pane", _right_pane],
		["right_scroll", _right_scroll],
		["right_content", _right_content],
	]
	for layer in layers:
		var c: Control = layer[1]
		if not is_instance_valid(c):
			print("  %s: <invalid>" % layer[0])
			continue
		print("  %s: size.y=%.1f min_size.y=%.1f" % [layer[0], c.size.y, c.get_combined_minimum_size().y])
	if is_instance_valid(_right_content) and _right_content.get_child_count() > 0:
		var inner = _right_content.get_child(0)
		if inner is Control:
			print("  right_content[0]: size.y=%.1f min_size.y=%.1f" % [inner.size.y, inner.get_combined_minimum_size().y])

func get_current_category() -> String:
	return _current_category

# ============================================================================
# Manual follow-focus (viewport-proof)
# ============================================================================

func _reconnect_focus_follow() -> void:
	_disconnect_focus_follow()
	var viewport := get_viewport()
	if not is_instance_valid(viewport):
		return
	if not viewport.gui_focus_changed.is_connected(_on_focus_follow_changed):
		viewport.gui_focus_changed.connect(_on_focus_follow_changed)
	_focus_follow_viewport = viewport
	# Re-bind built-in follow-focus to the current viewport after dual-screen
	# reparents. Toggling the flag forces Godot to re-attach to the new viewport.
	if _right_scroll:
		_right_scroll.follow_focus = false
		_right_scroll.follow_focus = true

func _disconnect_focus_follow() -> void:
	if _focus_follow_viewport and is_instance_valid(_focus_follow_viewport):
		if _focus_follow_viewport.gui_focus_changed.is_connected(_on_focus_follow_changed):
			_focus_follow_viewport.gui_focus_changed.disconnect(_on_focus_follow_changed)
	_focus_follow_viewport = null

func _on_focus_follow_changed(control: Control) -> void:
	if control == null:
		return
	if _left_scroll and _left_scroll.is_ancestor_of(control):
		_left_scroll.ensure_control_visible(control)
	else:
		var active_scroll := _get_active_scroll_container()
		if active_scroll and active_scroll.is_ancestor_of(control):
			active_scroll.ensure_control_visible(control)

	# Lock the bottom action row out of controller navigation again as soon as
	# focus leaves it, so the next traversal down the page cannot fall onto it.
	if not _is_action_button(control):
		for btn in _actions:
			if btn.focus_mode != Control.FOCUS_CLICK:
				btn.focus_mode = Control.FOCUS_CLICK

func _focus_first() -> void:
	# M3Dialog defaults to the first action button, but we keep action buttons
	# FOCUS_CLICK until the bottom of the page is reached. Fall back to the
	# current category button so overlay focus-pullback has a valid target.
	if _category_buttons.has(_current_category):
		var btn := _category_buttons[_current_category]
		if is_instance_valid(btn) and btn.focus_mode != Control.FOCUS_NONE:
			if UIManager:
				UIManager.suppress_next_focus_sound()
			btn.grab_focus()
			return
	for child in _left_pane.get_children():
		if child is Control and child.focus_mode != Control.FOCUS_NONE:
			if UIManager:
				UIManager.suppress_next_focus_sound()
			child.grab_focus()
			return

func cancel_and_dismiss() -> void:
	_cancelled = true
	dismiss()

func show_overlay() -> void:
	_cancelled = false
	_take_snapshot()
	super.show_overlay()
	if _right_content and _right_content.has_method("on_view_show"):
		_right_content.on_view_show()
	_set_initial_focus()

func _set_initial_focus() -> void:
	# Deferred one frame so layout settles and a select_category() issued right
	# after show_overlay() (show_settings_dialog_with_category) has landed.
	await get_tree().process_frame
	# Focus the button of the auto-opened category (last-used, or first) so the
	# focus ring matches the page being shown.
	if _category_buttons.has(_current_category):
		var btn := _category_buttons[_current_category]
		if is_instance_valid(btn) and btn.focus_mode != Control.FOCUS_NONE:
			if UIManager:
				UIManager.suppress_next_focus_sound()
			btn.grab_focus()
			return
	for child in _left_pane.get_children():
		if child is M3Button and child.focus_mode != Control.FOCUS_NONE:
			if UIManager:
				UIManager.suppress_next_focus_sound()
			child.grab_focus()
			return

func dismiss() -> void:
	if _right_content and _right_content.has_method("on_view_hide"):
		_right_content.on_view_hide()

	# Cancel reverts to the snapshot taken on open. All other dismiss paths
	# (OK, outside-click, ui_cancel, default close) apply pending settings.
	if _cancelled:
		_restore_snapshot()
		# On cancel, return focus to the Home button rather than the summoner.
		if UIManager:
			set_focus_restore_target(UIManager.find_home_button())

	if not _cancelled:
		# Suppress overlay focus pull-back while applying settings and dismissing.
		# The preset triggers grid layout rebuilds and deferred focus restoration;
		# without suppression the still-visible dialog would yank focus back.
		M3Overlay.push_focus_pullback_suppression()
		_apply_settings()

	if DataManager:
		DataManager.save_settings()

	super.dismiss()
	M3Overlay.pop_focus_pullback_suppression()

func _input(event: InputEvent) -> void:
	# Treat ui_cancel as Cancel so focus returns to the Home button.
	if visible and event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_on_cancel_pressed()
		return

	# Keep directional focus inside the right-hand scroll pane until the user
	# reaches the first/last focusable item in the current category. This stops
	# focus from leaking to the bottom action row while scrolling through a
	# long settings page.
	var active_scroll := _get_active_scroll_container()
	var is_dir := visible and active_scroll and _right_content and (event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up"))
	if DEBUG_FOCUS_GUARD and is_dir:
		var focused := get_viewport().gui_get_focus_owner()
		print("[SettingsDialogFocus] RAW ", "down" if event.is_action_pressed("ui_down") else "up",
			" focused=", focused.name if focused else "<null>",
			" inside_content=", focused != null and _right_content.is_ancestor_of(focused),
			" handled_already=", get_viewport().is_input_handled())
	if is_dir:
		var focused := get_viewport().gui_get_focus_owner()
		if focused and _right_content.is_ancestor_of(focused):
			var dir := 1 if event.is_action_pressed("ui_down") else -1
			if _handle_settings_focus_direction(focused, dir, active_scroll):
				get_viewport().set_input_as_handled()
				return

	super._input(event)

## Returns true if the directional event was consumed.
func _handle_settings_focus_direction(focused: Control, dir: int, active_scroll: ScrollContainer) -> bool:
	var candidate := focused.find_next_valid_focus() if dir == 1 else focused.find_prev_valid_focus()
	var focusables := _get_focusable_content_controls()
	var idx := focusables.find(focused)
	var boundary_idx := focusables.size() - 1 if dir == 1 else 0
	var at_boundary := idx >= 0 and idx == boundary_idx

	if DEBUG_FOCUS_GUARD:
		var v_scroll_bar := active_scroll.get_v_scroll_bar()
		var max_scroll := int(v_scroll_bar.max_value - v_scroll_bar.page) if v_scroll_bar else 0
		print("[SettingsDialogFocus] dir=%d focused=%s candidate=%s inside_scroll=%s idx=%d boundary=%d at_boundary=%s scroll=%d/%d page=%d" % [
			dir,
			focused.name if focused else "<null>",
			candidate.name if candidate else "<null>",
			candidate != null and active_scroll.is_ancestor_of(candidate),
			idx,
			boundary_idx,
			at_boundary,
			active_scroll.scroll_vertical,
			max_scroll,
			int(v_scroll_bar.page) if v_scroll_bar else 0
		])

	if candidate and active_scroll.is_ancestor_of(candidate) and not candidate is ScrollBar:
		# Godot's next target is still inside the scrollable content: let it go.
		return false

	if idx < 0:
		return false

	if at_boundary:
		# At the first/last focusable setting. Only allow focus to leave the
		# scroll pane if the pane is also scrolled all the way to that edge;
		# otherwise keep focus and scroll so non-focusable content below/above
		# can still be viewed.
		if dir == 1 and not _is_scroll_at_bottom(active_scroll):
			if DEBUG_FOCUS_GUARD:
				print("[SettingsDialogFocus] at last setting but not scrolled to bottom; scrolling instead")
			_scroll_content_by(active_scroll, int(M3Units.dp(120)))
			return true
		if dir == -1 and not _is_scroll_at_top(active_scroll):
			if DEBUG_FOCUS_GUARD:
				print("[SettingsDialogFocus] at first setting but not scrolled to top; scrolling instead")
			_scroll_content_by(active_scroll, -int(M3Units.dp(120)))
			return true
		# Reached the end of the page while scrolled to the edge: unlock the
		# bottom action row and move focus to the first action.
		if dir == 1 and not _actions.is_empty():
			if DEBUG_FOCUS_GUARD:
				print("[SettingsDialogFocus] at bottom; moving focus to bottom actions")
			for btn in _actions:
				btn.focus_mode = Control.FOCUS_ALL
			var first_action: Control = _actions[0]
			if is_instance_valid(first_action):
				if UIManager:
					UIManager.suppress_next_focus_sound()
				# Changing focus mode can take a frame to register with the focus
				# system; defer the grab so it actually succeeds.
				first_action.call_deferred("grab_focus")
				return true
		return false

	# Not at the boundary: move focus to the next/prev focusable inside the
	# content and scroll it into view.
	var next_idx := idx + dir
	if next_idx >= 0 and next_idx < focusables.size():
		var next := focusables[next_idx]
		if UIManager:
			UIManager.suppress_next_focus_sound()
		next.grab_focus()
		active_scroll.ensure_control_visible(next)
	else:
		_scroll_content_by(active_scroll, dir * int(M3Units.dp(120)))
	return true

func _is_scroll_at_top(scroll: ScrollContainer) -> bool:
	return scroll.scroll_vertical <= 0

func _is_scroll_at_bottom(scroll: ScrollContainer) -> bool:
	var v_scroll_bar := scroll.get_v_scroll_bar()
	if not v_scroll_bar:
		return true
	var max_scroll := int(v_scroll_bar.max_value - v_scroll_bar.page)
	return scroll.scroll_vertical >= max_scroll

func _scroll_content_by(scroll: ScrollContainer, amount: int) -> void:
	var v_scroll_bar := scroll.get_v_scroll_bar()
	var max_scroll := int(v_scroll_bar.max_value - v_scroll_bar.page) if v_scroll_bar else 0
	max_scroll = maxi(max_scroll, 0)
	scroll.scroll_vertical = clampi(scroll.scroll_vertical + amount, 0, max_scroll)

func _get_focusable_content_controls() -> Array[Control]:
	var out: Array[Control] = []
	if _right_content:
		_collect_focusable_content_controls(_right_content, out)
	out.sort_custom(func(a: Control, b: Control) -> bool:
		var ra := a.get_global_rect()
		var rb := b.get_global_rect()
		if abs(ra.position.y - rb.position.y) > 1.0:
			return ra.position.y < rb.position.y
		return ra.position.x < rb.position.x
	)
	return out

func _collect_focusable_content_controls(node: Node, out: Array[Control]) -> void:
	if node is Control:
		var ctrl := node as Control
		if _is_control_navigable(ctrl):
			out.append(ctrl)
	for child in node.get_children():
		_collect_focusable_content_controls(child, out)

func _is_control_navigable(ctrl: Control) -> bool:
	if not is_instance_valid(ctrl) or ctrl.is_queued_for_deletion():
		return false
	if not ctrl.visible or ctrl.focus_mode == Control.FOCUS_NONE:
		return false
	if ctrl is BaseButton and (ctrl as BaseButton).disabled:
		return false
	if "editable" in ctrl and not ctrl.editable:
		return false
	if "disabled" in ctrl and ctrl.disabled:
		return false
	return true

func _is_action_button(control: Control) -> bool:
	for btn in _actions:
		if btn == control:
			return true
	return false

func _get_active_scroll_container() -> ScrollContainer:
	# Scene-based category pages (card designer, background designer, etc.)
	# bring their own internal ScrollContainer. Use that for focus/scrolling
	# when present; otherwise fall back to the shared right-hand pane scroll.
	if _right_content and _right_content.is_inside_tree():
		var internal := _find_scroll_container_recursive(_right_content)
		if internal:
			return internal
	return _right_scroll

func _get_dialog_scroll_container() -> ScrollContainer:
	# Right-stick scrolling should target whichever scroll pane the current
	# category actually uses.
	return _get_active_scroll_container()

func _on_ok_pressed() -> void:
	dismiss()

func _on_cancel_pressed() -> void:
	_cancelled = true
	dismiss()

func _on_close_button_pressed() -> void:
	"""Top-right X behaves like Cancel."""
	_on_cancel_pressed()

func _take_snapshot() -> void:
	_snapshot.clear()
	if not DataManager.is_settings_loaded():
		return
	for property_name in DataManager.get_settings().keys():
		_snapshot[property_name] = _copy_value(DataManager.get_setting(property_name).value)

func _restore_snapshot() -> void:
	if _snapshot.is_empty() or not DataManager.is_settings_loaded():
		return
	for property_name in _snapshot.keys():
		var setting = DataManager.get_setting(property_name)
		if not setting:
			continue
		var snapshot_value = _snapshot[property_name]
		if not _values_equal(snapshot_value, setting.value):
			DataManager.set_setting(_copy_value(snapshot_value), setting)
	refresh_all_category_values()

func _values_equal(a: Variant, b: Variant) -> bool:
	if typeof(a) != typeof(b):
		return false
	if a is Dictionary or a is Array or (a is Object and a.has_method("duplicate")):
		# Deep-compare containers; for Objects, fall back to == if available.
		if a is Object and b is Object:
			return a == b or a.duplicate(true) == b.duplicate(true)
		return a == b
	return a == b

func _copy_value(value: Variant) -> Variant:
	if value is Dictionary:
		return value.duplicate(true)
	if value is Array:
		return value.duplicate(true)
	if value is Object and value.has_method("duplicate"):
		return value.duplicate(true)
	return value

func _apply_settings() -> void:
	if UIManager:
		UIManager.apply_settings_now()

func get_platforms_settings_view() -> PlatformsSettingsView:
	if _category_contents.has("romm") and _category_contents["romm"] is PlatformsSettingsView:
		return _category_contents["romm"] as PlatformsSettingsView
	return null

func get_card_designer_view() -> CardDesignerView:
	if _category_contents.has("card_designer") and _category_contents["card_designer"] is CardDesignerView:
		return _category_contents["card_designer"] as CardDesignerView
	return null

func refresh_theme() -> void:
	super.refresh_theme()
	for content in _category_contents.values():
		if is_instance_valid(content):
			_refresh_theme_recursive(content)

func refresh_scale() -> void:
	_apply_scale()
	refresh_theme()

## Settled-geometry hook (broadcast by OverlaySubManager): re-tier
## sidebar/pane spacing when the viewport crosses the small breakpoint.
## M3Dialog._ready's own connection still handles the fullscreen chrome.
func on_viewport_settled() -> void:
	_apply_scale()

func _apply_scale() -> void:
	var compact := _is_compact_sidebar()
	# The icon-only vs text button choice is made at build time; when the
	# viewport crosses the compact breakpoint while the dialog is alive,
	# rebuild the sidebar buttons in the other mode.
	if not _category_button_specs.is_empty() and compact != _sidebar_built_compact:
		_rebuild_category_buttons()
	
	if is_instance_valid(_left_pane):
		_left_pane.add_theme_constant_override("separation", int(M3Units.dp(4)))
	if is_instance_valid(_left_column):
		_left_column.custom_minimum_size = Vector2(M3Units.dp(64) if compact else M3Units.dp(200), 0)
		_left_column.add_theme_constant_override("separation", int(M3Units.dp(4)))
	if is_instance_valid(_left_margin):
		_left_margin.add_theme_constant_override("margin_left", int(M3Units.dp(4) if compact else M3Units.dp(8)))
		_left_margin.add_theme_constant_override("margin_right", int(M3Units.dp(4) if compact else M3Units.dp(8)))
		_left_margin.add_theme_constant_override("margin_top", int(M3Units.dp(12)))
		_left_margin.add_theme_constant_override("margin_bottom", int(M3Units.dp(12)))
	if is_instance_valid(_right_pane):
		_right_pane.add_theme_constant_override("margin_left", int(M3Units.dp(4) if compact else M3Units.dp(8)))
		_right_pane.add_theme_constant_override("margin_right", int(M3Units.dp(4) if compact else M3Units.dp(8)))
		_right_pane.add_theme_constant_override("margin_top", int(M3Units.dp(8) if compact else M3Units.dp(12)))
		_right_pane.add_theme_constant_override("margin_bottom", int(M3Units.dp(8) if compact else M3Units.dp(12)))
	for btn in _category_buttons.values():
		if is_instance_valid(btn):
			btn.custom_minimum_size.y = M3Units.dp(48)
	for content in _category_contents.values():
		if content is MarginContainer and content.has_meta("category_margin"):
			var content_margin := 10 if compact else 20
			content.add_theme_constant_override("margin_left", M3Units.dp(content_margin))
			content.add_theme_constant_override("margin_top", M3Units.dp(content_margin))
			content.add_theme_constant_override("margin_right", M3Units.dp(content_margin))
			content.add_theme_constant_override("margin_bottom", M3Units.dp(content_margin))

func _rebuild_category_buttons() -> void:
	"""Rebuild sidebar buttons in the opposite compact mode, preserving order
	and the current selection highlight."""
	var ordered_ids: Array = []
	var parent: Container = _left_pane
	for child in _left_pane.get_children():
		for id in _category_buttons.keys():
			if _category_buttons[id] == child:
				ordered_ids.append(id)
	# Fallback if the parent walk missed anything.
	for id in _category_button_specs.keys():
		if id not in ordered_ids:
			ordered_ids.append(id)

	for id in ordered_ids:
		var old_btn: M3Button = _category_buttons.get(id)
		var spec: Dictionary = _category_button_specs[id]
		var target: Container = spec.get("target")
		var insert_parent: Container = target if target else parent
		var insert_index := -1
		if is_instance_valid(old_btn):
			insert_index = old_btn.get_index()
			insert_parent.remove_child(old_btn)
			old_btn.queue_free()
		_category_buttons.erase(id)
		_add_category_button(id, spec["label"], spec["icon"], target)
		var new_btn: M3Button = _category_buttons[id]
		if insert_index >= 0:
			insert_parent.move_child(new_btn, mini(insert_index, insert_parent.get_child_count() - 1))
		# Restore selection highlight.
		if id == _current_category:
			if new_btn is M3IconButton:
				new_btn.icon_button_variant = M3IconButton.IconVariant.TONAL
			else:
				new_btn.button_variant = M3Button.Variant.TONAL
	_sidebar_built_compact = _is_compact_sidebar()

func _refresh_theme_recursive(node: Node) -> void:
	if node.has_method("refresh_theme"):
		node.refresh_theme()
	for child in node.get_children():
		_refresh_theme_recursive(child)

func refresh_all_category_values() -> void:
	"""Refresh all SettingsMenu control values to match current settings."""
	for content in _category_contents.values():
		if is_instance_valid(content):
			_refresh_settings_menu_values_recursive(content)

func _refresh_settings_menu_values_recursive(node: Node) -> void:
	if node is SettingsMenu:
		node.refresh_all_control_values()
		return
	for child in node.get_children():
		_refresh_settings_menu_values_recursive(child)

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		pass
	elif what == NOTIFICATION_ENTER_TREE:
		# Fires on every reparent (dual screen mode moves this dialog
		# between the root viewport and the MainViewport SubViewport).
		_reconnect_focus_follow()
	elif what == NOTIFICATION_EXIT_TREE:
		_disconnect_focus_follow()
