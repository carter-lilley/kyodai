extends Control

const CONTENT_PADDING := 20.0

const M3Menu = preload("res://addons/m3/components/M3Menu.gd")
const M3MenuRenderer = preload("res://addons/m3/components/M3MenuRenderer.gd")

var _checkable_menu: M3Menu = null
var _multi_select_menu: M3Menu = null
var _submenu_menu: M3Menu = null

@export var dark_mode: bool = false:
	set(value):
		dark_mode = value
		M3Theme.is_dark_mode = dark_mode
		apply_theme()

func _ready():
	M3Theme.is_dark_mode = dark_mode
	apply_theme()
	
	# Connect dark mode toggle
	var dark_mode_toggle = $MarginContainer/ScrollContainer/VBoxContainer/DarkmodeToggle
	dark_mode_toggle.button_pressed = dark_mode
	dark_mode_toggle.toggled.connect(_on_dark_mode_toggled)
	
	# Populate MenuButton
	if has_node("MarginContainer/ScrollContainer/VBoxContainer/RowBasicControls/MenuButton"):
		var menu_btn = $MarginContainer/ScrollContainer/VBoxContainer/RowBasicControls/MenuButton
		var menu = menu_btn.get_popup()
		menu.add_item("Item 1")
		menu.add_item("Item 2")
		menu.add_item("Item 3")
	
	# Populate OptionButton
	if has_node("MarginContainer/ScrollContainer/VBoxContainer/RowBasicControls/OptionButton"):
		var option = $MarginContainer/ScrollContainer/VBoxContainer/RowBasicControls/OptionButton
		option.add_item("Option 1")
		option.add_item("Option 2")
		option.add_item("Option 3")
		option.select(0)
	
	# Set RichTextLabel content
	$MarginContainer/ScrollContainer/VBoxContainer/RowTextAreas/RichTextLabel.text = "[b]Bold[/b] and [i]italic[/i] text\n[color=red]Colored text[/color]\n[code]Code snippet[/code]"
	
	# Configure NavigationRail
	var nav_rail = $NavigationRail
	var nav_destinations = [
		_create_nav_dest("home", "Home"),
		_create_nav_dest("star", "Favorites"),
		_create_nav_dest("search", "Search"),
		_create_nav_dest("", "Section A"),
		_create_nav_dest("settings", "Settings"),
		_create_nav_dest("info", "About"),
	]
	nav_rail.destinations = nav_destinations
	
	# Configure NavigationBar
	var nav_bar = $NavigationBar
	var bar_destinations = [
		_create_nav_dest("home", "Home"),
		_create_nav_dest("star", "Favorites"),
		_create_nav_dest("search", "Search"),
		_create_nav_dest("settings", "Settings"),
	]
	nav_bar.destinations = bar_destinations
	
	# Set up content slot for integrated mode
	var margin_container = $MarginContainer
	nav_rail.content_node = margin_container
	nav_bar.content_node = margin_container
	
	# Connect snackbar test button
	var snackbar_btn = $MarginContainer/ScrollContainer/VBoxContainer/SnackbarTestButton
	if snackbar_btn:
		snackbar_btn.pressed.connect(_on_snackbar_test_pressed)
	
	# Configure M3OptionButtons
	_configure_option_buttons()
	
	# Configure Dialog test buttons
	_configure_dialog_buttons()
	
	# Configure Menu test buttons
	_configure_menu_buttons()
	
	# Configure Chips
	_configure_chips()
	
	# Configure Sheet test buttons
	_configure_sheet_buttons()
	
	# Configure Split buttons
	_configure_split_buttons()
	
	# Build persistent checkable menus so checked states survive across openings
	_build_persistent_menus()

func _configure_option_buttons():
	var option_section = $MarginContainer/ScrollContainer/VBoxContainer/M3OptionButtonTests
	if not option_section:
		return
	
	var m3_option = option_section.get_node("OptionRow/M3OptionButton")
	m3_option.add_item("Apple", 0)
	m3_option.add_item("Banana", 1)
	m3_option.add_item("Cherry", 2)
	m3_option.add_item("Date", 3)
	m3_option.add_item("Elderberry", 4)
	m3_option.selected = 0
	m3_option.item_selected.connect(func(idx): print("Selected item: %d" % idx))
	
	var m3_option_outlined = option_section.get_node("OptionRow/M3OptionButtonOutlined")
	m3_option_outlined.add_item("Small", 0)
	m3_option_outlined.add_item("Medium", 1)
	m3_option_outlined.add_item("Large", 2)
	m3_option_outlined.add_item("Extra Large", 3)
	m3_option_outlined.selected = 1
	
	var m3_option_multi = option_section.get_node("OptionRow/M3OptionButtonMulti")
	m3_option_multi.add_item("Vegetarian", 0)
	m3_option_multi.add_item("Vegan", 1)
	m3_option_multi.add_item("Gluten-free", 2)
	m3_option_multi.add_item("Nut-free", 3)
	m3_option_multi.add_item("Dairy-free", 4)
	var selected_indices: Array[int] = [0, 2]
	m3_option_multi.set_selected_indices(selected_indices)
	m3_option_multi.item_selected.connect(func(idx): print("Toggled dietary: %d" % idx))

func _configure_dialog_buttons():
	var dialog_section = $MarginContainer/ScrollContainer/VBoxContainer/DialogTests
	if not dialog_section:
		return
	
	dialog_section.get_node("DialogBtnRow/BasicDialogBtn").pressed.connect(_on_dialog_basic_test_pressed)
	dialog_section.get_node("DialogBtnRow/ConfirmDialogBtn").pressed.connect(_on_dialog_confirm_test_pressed)
	dialog_section.get_node("DialogBtnRow/AlertDialogBtn").pressed.connect(_on_dialog_alert_test_pressed)
	dialog_section.get_node("DialogBtnRow/FullscreenDialogBtn").pressed.connect(_on_dialog_fullscreen_test_pressed)

func _configure_menu_buttons():
	var menu_section = $MarginContainer/ScrollContainer/VBoxContainer/MenuTests
	if not menu_section:
		return
	
	menu_section.get_node("MenuBtnRow/StandardMenuBtn").pressed.connect(_on_standard_menu_test_pressed)
	menu_section.get_node("MenuBtnRow/VibrantMenuBtn").pressed.connect(_on_vibrant_menu_test_pressed)
	menu_section.get_node("MenuBtnRow/CheckableMenuBtn").pressed.connect(_on_checkable_menu_test_pressed)
	menu_section.get_node("MenuBtnRow/TwolineMenuBtn").pressed.connect(_on_twoline_menu_test_pressed)
	menu_section.get_node("MenuBtnRow/IconMenuBtn").pressed.connect(_on_icon_menu_test_pressed)
	menu_section.get_node("MenuBtnRow/MultiSelectMenuBtn").pressed.connect(_on_multi_select_menu_test_pressed)
	menu_section.get_node("MenuBtnRow/SubmenuMenuBtn").pressed.connect(_on_submenu_menu_test_pressed)

func _configure_chips():
	var chip_section = $MarginContainer/ScrollContainer/VBoxContainer/ChipTests
	if not chip_section:
		return
	
	chip_section.get_node("ChipRow/AssistChip").pressed.connect(func(): print("Assist chip pressed"))
	
	var filter_chip = chip_section.get_node("ChipRow/FilterChip")
	filter_chip.checked_changed.connect(func(c): print("Filter chip: %s" % c))
	
	var filter_dropdown_chip = chip_section.get_node("ChipRow/FilterDropdownChip")
	filter_dropdown_chip.menu_requested.connect(func():
		var menu = M3Menu.new()
		menu.add_item("Name", func():
			print("Sort by name")
			filter_dropdown_chip.checked = true
		)
		menu.add_item("Date", func():
			print("Sort by date")
			filter_dropdown_chip.checked = true
		)
		menu.add_item("Rating", func():
			print("Sort by rating")
			filter_dropdown_chip.checked = true
		)
		menu.popup(filter_dropdown_chip)
	)
	
	chip_section.get_node("ChipRow/InputChip").close_requested.connect(func(): print("Input chip close"))
	chip_section.get_node("ChipRow/SuggestionChip").pressed.connect(func(): print("Suggestion chip pressed"))
	chip_section.get_node("ChipRow/ElevatedChip").pressed.connect(func(): print("Elevated chip pressed"))

func _configure_sheet_buttons():
	var sheet_section = $MarginContainer/ScrollContainer/VBoxContainer/SheetTests
	if not sheet_section:
		return
	
	sheet_section.get_node("SheetBtnRow/SideSheetBtn").pressed.connect(_on_side_sheet_test_pressed)
	sheet_section.get_node("SheetBtnRow/BottomSheetBtn").pressed.connect(_on_bottom_sheet_test_pressed)

func _configure_split_buttons():
	var split_section = $MarginContainer/ScrollContainer/VBoxContainer/SplitButtonTests
	if not split_section:
		return
	
	var split_filled = split_section.get_node("SplitRow1/SplitFilled")
	split_filled.pressed.connect(func(): print("Split button main action: Edit"))
	var edit_menu = M3Menu.new()
	edit_menu.add_item("Cut", func(): print("Cut"))
	edit_menu.add_item("Copy", func(): print("Copy"))
	edit_menu.add_item("Paste", func(): print("Paste"))
	split_filled.menu = edit_menu
	
	var split_tonal = split_section.get_node("SplitRow1/SplitTonal")
	var download_menu = M3Menu.new()
	download_menu.add_item("PDF", func(): print("Download PDF"))
	download_menu.add_item("PNG", func(): print("Download PNG"))
	download_menu.add_item("SVG", func(): print("Download SVG"))
	split_tonal.menu = download_menu
	
	var split_outlined = split_section.get_node("SplitRow1/SplitOutlined")
	var share_menu = M3Menu.new()
	share_menu.add_item("Email", func(): print("Share via Email"))
	share_menu.add_item("Message", func(): print("Share via Message"))
	share_menu.add_item("Copy link", func(): print("Copy link"))
	split_outlined.menu = share_menu
	
	var split_small = split_section.get_node("SplitRow2/SplitSmall")
	var small_menu = M3Menu.new()
	small_menu.add_item("Option A", func(): print("Small A"))
	small_menu.add_item("Option B", func(): print("Small B"))
	split_small.menu = small_menu
	
	var split_large = split_section.get_node("SplitRow2/SplitLarge")
	var large_menu = M3Menu.new()
	large_menu.add_item("Favorite", func(): print("Favorite"))
	large_menu.add_item("Bookmark", func(): print("Bookmark"))
	split_large.menu = large_menu
	
	var split_xl = split_section.get_node("SplitRow2/SplitXL")
	var xl_menu = M3Menu.new()
	xl_menu.add_item("General", func(): print("General settings"))
	xl_menu.add_item("Display", func(): print("Display settings"))
	xl_menu.add_item("Network", func(): print("Network settings"))
	split_xl.menu = xl_menu
	
	var split_text = split_section.get_node("SplitRow3/SplitText")
	var filter_menu = M3Menu.new()
	filter_menu.add_check_item("Active", true, func(): print("Toggle active"))
	filter_menu.add_check_item("Archived", false, func(): print("Toggle archived"))
	split_text.menu = filter_menu

func _build_persistent_menus():
	_checkable_menu = M3Menu.new()
	_checkable_menu.auto_free = false
	_checkable_menu.add_check_item("Show bounding box", false, func(): print("Toggle bounding box"))
	_checkable_menu.add_check_item("Show grid", true, func(): print("Toggle grid"))
	_checkable_menu.add_separator()
	_checkable_menu.add_section_label("View options")
	_checkable_menu.add_check_item("Night mode", false, func(): print("Toggle night mode"))
	
	_multi_select_menu = M3Menu.new()
	_multi_select_menu.auto_free = false
	_multi_select_menu.multi_select = true
	_multi_select_menu.add_check_item("Wi-Fi", true, func(): print("Toggle Wi-Fi"))
	_multi_select_menu.add_check_item("Bluetooth", false, func(): print("Toggle Bluetooth"))
	_multi_select_menu.add_check_item("Airplane mode", false, func(): print("Toggle Airplane mode"))
	_multi_select_menu.add_separator()
	_multi_select_menu.add_check_item("Dark theme", false, func(): print("Toggle Dark theme"))
	_multi_select_menu.add_check_item("High contrast", false, func(): print("Toggle High contrast"))
	
	# Build submenu test
	var sub = M3Menu.new()
	sub.auto_free = false
	sub.add_item("Sub-item 1", func(): print("Sub-item 1"))
	sub.add_item("Sub-item 2", func(): print("Sub-item 2"))
	sub.add_separator()
	sub.add_item("Sub-item 3", func(): print("Sub-item 3"))
	
	_submenu_menu = M3Menu.new()
	_submenu_menu.auto_free = false
	_submenu_menu.add_item("Regular item", func(): print("Regular item"))
	_submenu_menu.add_submenu_item("More options", sub, "expand_more")
	_submenu_menu.add_item("Another item", func(): print("Another item"))

func _on_snackbar_test_pressed():
	M3Snackbar.show_message(
		"Item deleted",
		"Undo",
		func(): print("Undo clicked!"),
		true
	)

func _on_dialog_basic_test_pressed():
	var dialog = M3Dialog.new()
	dialog.title_text = "Reset settings?"
	dialog.body_text = "This will reset your app preferences back to their default settings."
	dialog.hero_icon_name = "settings_backup_restore"
	dialog.add_action("Cancel", Callable(), false)
	dialog.add_action("Accept", func(): print("Accept clicked!"), true)
	M3Dialog.show_dialog(dialog)

func _on_dialog_confirm_test_pressed():
	M3Dialog.show_confirm(
		"Delete account?",
		"This action cannot be undone. All your data will be permanently removed.",
		func(): print("Account deleted!"),
		func(): print("Cancelled")
	)

func _on_dialog_alert_test_pressed():
	M3Dialog.show_alert(
		"Update complete",
		"Your app has been updated to the latest version.",
		func(): print("OK clicked")
	)

func _on_side_sheet_test_pressed():
	var sheet = M3SideSheet.show_side_sheet("Side Sheet", M3Sheet.Variant.MODAL)
	print("Side sheet opened")

func _on_bottom_sheet_test_pressed():
	var sheet = M3BottomSheet.show_bottom_sheet("Bottom Sheet", M3Sheet.Variant.MODAL)
	print("Bottom sheet opened")

func _on_standard_menu_test_pressed():
	var menu = M3Menu.new()
	menu.add_item("Preview", func(): print("Preview"), "visibility")
	menu.add_item("Share", func(): print("Share"), "share")
	menu.add_separator()
	menu.add_item("Get link", func(): print("Get link"), "link")
	menu.add_item("Remove", func(): print("Remove"), "delete", "chevron-right")
	var btn = $MarginContainer/ScrollContainer/VBoxContainer/MenuTests/MenuBtnRow/StandardMenuBtn
	menu.popup(btn)

func _on_vibrant_menu_test_pressed():
	var menu = M3Menu.new()
	menu.menu_variant = M3MenuRenderer.ColorVariant.VIBRANT
	menu.add_item("Preview", func(): print("Preview"), "visibility")
	menu.add_item("Share", func(): print("Share"), "share")
	menu.add_separator()
	menu.add_item("Get link", func(): print("Get link"), "link")
	menu.add_item("Remove", func(): print("Remove"), "delete")
	var btn = $MarginContainer/ScrollContainer/VBoxContainer/MenuTests/MenuBtnRow/VibrantMenuBtn
	menu.popup(btn)

func _on_checkable_menu_test_pressed():
	var btn = $MarginContainer/ScrollContainer/VBoxContainer/MenuTests/MenuBtnRow/CheckableMenuBtn
	_checkable_menu.popup(btn)

func _on_twoline_menu_test_pressed():
	var menu = M3Menu.new()
	menu.add_two_line_item("Headline", "Supporting text", func(): print("Headline"), "article")
	menu.add_two_line_item("List item", "Secondary text", func(): print("List item"), "list")
	menu.add_separator()
	menu.add_item("Simple item", func(): print("Simple"))
	var btn = $MarginContainer/ScrollContainer/VBoxContainer/MenuTests/MenuBtnRow/TwolineMenuBtn
	menu.popup(btn)

func _on_icon_menu_test_pressed():
	var menu = M3Menu.new()
	menu.add_item("Settings", func(): print("Settings"), "settings")
	menu.add_item("Profile", func(): print("Profile"), "person")
	menu.add_separator()
	menu.add_item("Help", func(): print("Help"), "help")
	menu.add_item("Logout", func(): print("Logout"), "logout")
	var btn = $MarginContainer/ScrollContainer/VBoxContainer/MenuTests/MenuBtnRow/IconMenuBtn
	menu.popup(btn)

func _on_multi_select_menu_test_pressed():
	var btn = $MarginContainer/ScrollContainer/VBoxContainer/MenuTests/MenuBtnRow/MultiSelectMenuBtn
	_multi_select_menu.popup(btn)

func _on_submenu_menu_test_pressed():
	var btn = $MarginContainer/ScrollContainer/VBoxContainer/MenuTests/MenuBtnRow/SubmenuMenuBtn
	_submenu_menu.popup(btn)

func _on_dialog_fullscreen_test_pressed():
	var dialog = M3Dialog.new()
	dialog.dialog_variant = M3Dialog.Variant.FULL_SCREEN
	dialog.title_text = "Settings"
	dialog.body_text = "Configure your app preferences below."
	dialog.hero_icon_name = "settings"
	
	# Add some sample content
	var checkbox = M3Checkbox.new()
	checkbox.text = "Enable notifications"
	dialog.content_slot.add_child(checkbox)
	
	var checkbox2 = M3Checkbox.new()
	checkbox2.text = "Dark mode"
	dialog.content_slot.add_child(checkbox2)
	
	dialog.add_action("Cancel", Callable(), false)
	dialog.add_action("Save", func(): print("Saved!"), true)
	M3Dialog.show_dialog(dialog)

func _on_dark_mode_toggled(pressed: bool):
	dark_mode = pressed

func _create_nav_dest(icon: String, label: String) -> M3NavigationDestinationData:
	var data = M3NavigationDestinationData.new()
	data.icon_name = icon
	data.label = label
	return data

func apply_theme():
	var theme = M3Theme.generate_theme()
	self.theme = theme
	
	# Background is now a Panel, uses theme's Panel stylebox automatically
	# But we need to make sure it picks up the theme
	$Background.queue_redraw()
	
	# Update the ColorRect to show surface variant color
	if has_node("MarginContainer/ScrollContainer/VBoxContainer/RowToggles/ColorRect"):
		var color_rect = $MarginContainer/ScrollContainer/VBoxContainer/RowToggles/ColorRect
		color_rect.color = M3Theme.get_surface_variant()
	
	# Update elevation preview panels
	var elevation_row = $MarginContainer/ScrollContainer/VBoxContainer/RowElevation
	for i in range(6):
		var panel = elevation_row.get_node("Elevation%d" % i)
		if panel:
			var shadow_size = int(M3Theme.ELEVATION_1["size"] * i / 2.0)
			var shadow_offset = M3Theme.ELEVATION_1["offset"] * (i / 2.0)
			var style = M3Theme.make_shadow(
				M3Theme.get_elevation_surface(i),
				M3Theme.RADIUS_MEDIUM,
				shadow_size,
				shadow_offset,
				M3Theme.ELEVATION_1["color"]
			)
			panel.add_theme_stylebox_override("panel", style)
			
	# Force redraw of all controls
	queue_redraw()
	
	# Update all M3 component instances
	_update_m3_components(self)

func _update_m3_components(node: Node):
	for child in node.get_children():
		if child is M3Slider or child is M3Button or child is M3IconButton or child is M3Navigation or child is M3Switch or child is M3TextField or child is M3Checkbox or child is M3Tooltip or child is M3Dialog or child is M3Snackbar or child is M3Menu or child is M3OptionButton or child is M3Chip or child is M3Progress or child is M3SplitButton or child is M3Sheet or child is M3SideSheet or child is M3BottomSheet:
			child.refresh_theme()
		if child.get_child_count() > 0:
			_update_m3_components(child)
