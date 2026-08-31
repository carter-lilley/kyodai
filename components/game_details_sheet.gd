class_name GameDetailsSheet
extends M3BottomSheet

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")

## Game details bottom sheet.
## Extends M3BottomSheet so the details UI is a native Material 3 overlay
## instead of a full-screen tab.

const CONTENT_MARGIN_PATH := ^"MarginContainer"
const HEIGHT_FRACTION := 0.85
const WIDTH_FRACTION := 0.75
const MAX_WIDTH_DP := 1200.0
const H_MARGIN_DP := 32.0
const MAX_DETAILS_TEXTURE_SIZE: int = 1024


const TAB_MARGIN_TOP_DP := 12.0
const CARD_PADDING_DP := 16.0
const CARD_GAP_DP := 8.0
const STAR_SIZE_DP := 14.0
const STAR_GAP_DP := 2.0


# NOTE: The scene root is a CanvasLayer (M3BottomSheet base). The MarginContainer
# and its children are direct children of the root in the .tscn file, then
# _reparent_content() moves MarginContainer into the sheet's _content_slot.
@onready var _content_root: Control = $MarginContainer
@onready var _content_hbox: HBoxContainer = $MarginContainer/HBoxContainer
@onready var cover_container: VBoxContainer = $MarginContainer/HBoxContainer/CoverContainer
@onready var cover_texture: TextureRect = $MarginContainer/HBoxContainer/CoverContainer/CoverClip/CoverTexture
@onready var title_label: Label = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow/TitleLabel
@onready var metadata_row: HFlowContainer = $MarginContainer/HBoxContainer/ContentVBox/MetadataRow
@onready var content_tabs: TabContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs
@onready var overview_vbox: VBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox
@onready var desc_scroll: ScrollContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/DescScroll
@onready var description_label: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/DescScroll/DescriptionLabel
@onready var desc_fold_button: M3Button = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/DescFoldButton
@onready var related_section: VBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/RelatedSection
@onready var related_header: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/RelatedSection/RelatedHeader
@onready var related_scroll: ScrollContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/RelatedSection/RelatedScroll
@onready var related_row: HBoxContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Overview/OverviewVBox/RelatedSection/RelatedScroll/RowMargin/RelatedRow
@onready var files_card: PanelContainer = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesVBox/FilesCard
@onready var file_info_label: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesVBox/FilesCard/CardMargin/CardVBox/FileInfoLabel
@onready var file_size_label: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesVBox/FilesCard/CardMargin/CardVBox/FileSizeLabel
@onready var title_id_label: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesVBox/FilesCard/CardMargin/CardVBox/TitleIdLabel
@onready var status_chip: M3Chip = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesVBox/FilesCard/CardMargin/CardVBox/StatusChipRow/StatusChip
@onready var sync_status_label: Label = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesVBox/FilesCard/CardMargin/CardVBox/SyncStatusLabel
@onready var sibling_dropdown: M3OptionButton = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesVBox/SiblingDropdown
@onready var status_dropdown: M3OptionButton = $MarginContainer/HBoxContainer/ContentVBox/ContentTabs/Files/FilesVBox/StatusDropdown
@onready var action_button: M3Button = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow/ButtonRow/ActionButton
@onready var sync_button: M3Button = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow/ButtonRow/SyncButton
@onready var favorite_button: M3IconButton = $MarginContainer/HBoxContainer/ContentVBox/HeaderRow/ButtonRow/FavoriteButton

## RomM play-status options. The first five map to the mutually exclusive
## rom_user.status enum; the last three are independent boolean flags.
const STATUS_OPTIONS := [
	{"key": "incomplete", "label": "Incomplete", "icon": "timer-sand"},
	{"key": "finished", "label": "Finished", "icon": "check-bold"},
	{"key": "completed_100", "label": "Completed 100%", "icon": "trophy"},
	{"key": "retired", "label": "Retired", "icon": "flag"},
	{"key": "never_playing", "label": "Never Playing", "icon": "cancel"},
	{"key": "now_playing", "label": "Now Playing", "icon": "play"},
	{"key": "backlogged", "label": "Backlogged", "icon": "bookmark"},
	{"key": "hidden", "label": "Hidden", "icon": "eye-off"},
]
const STATUS_FLAG_KEYS := ["now_playing", "backlogged", "hidden"]

var _current_game: GameResource = null
var _sibling_options: Array[Dictionary] = []  # [{id, name, file_name, file_size}, ...]
var _desc_expanded: bool = false
var _related_games_count: int = 0

func _init():
	super._init()
	persistent = true

# Preloaded data while a context menu is open.
var _prepared_romm_id: int = 0
var _prepared_cover: Texture2D = null

func _ready():
	super._ready()
	# Never let content render past the sheet edge; the sheet must never grow
	# with its contents.
	if _sheet_container:
		_sheet_container.clip_contents = true
	_reparent_content()
	_setup_tabs()
	_setup_related_section_card()
	_setup_focus_neighbors()
	_connect_signals()
	_set_sheet_height()
	_reduce_top_padding()
	_apply_content_scaling()
	_reconnect_viewport_signals()

var _size_changed_viewport: Viewport = null

func _reconnect_viewport_signals() -> void:
	"""Keep the size_changed connection on the sheet's CURRENT viewport;
	DS-mode reparenting moves the sheet between the root window and the
	MainViewport SubViewport."""
	var viewport := get_viewport()
	if viewport == _size_changed_viewport:
		return
	if _size_changed_viewport and is_instance_valid(_size_changed_viewport):
		if _size_changed_viewport.size_changed.is_connected(_on_viewport_size_changed):
			_size_changed_viewport.size_changed.disconnect(_on_viewport_size_changed)
	_size_changed_viewport = null
	if viewport:
		viewport.size_changed.connect(_on_viewport_size_changed)
		_size_changed_viewport = viewport

func _on_viewport_size_changed() -> void:
	# Only recompute while hidden; a visible sheet keeps its current geometry
	# until the next show. _position_sheet() refreshes width/height/position
	# even when the peek_height setter no-ops on an unchanged value.
	if not visible:
		_set_sheet_height()
		_position_sheet()

func refresh_theme():
	super.refresh_theme()
	if is_node_ready():
		_apply_content_scaling()
		_apply_m3_control_styling()
		if _current_game:
			_populate_metadata_chips(_current_game)

func refresh_scale() -> void:
	if not is_node_ready():
		return
	_setup_tabs()
	_reduce_top_padding()
	_set_sheet_height()
	super.refresh_scale()

func _setup_tabs() -> void:
	if not content_tabs:
		return
	# Let the sheet background show through instead of the themed opaque panel.
	content_tabs.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	var tab_margin := M3Units.dpi(TAB_MARGIN_TOP_DP)
	for tab_name in [&"Overview", &"Files"]:
		var tab := content_tabs.get_node_or_null(NodePath(tab_name)) as MarginContainer
		if tab:
			tab.add_theme_constant_override("margin_top", tab_margin)
	_apply_m3_control_styling()

func _apply_m3_control_styling() -> void:
	"""M3-style the native TabContainer and the sheet's scrollbars."""
	if content_tabs:
		M3Theme.style_tab_container(content_tabs)
	if is_instance_valid(related_scroll):
		M3Theme.style_scrollbar(related_scroll.get_h_scroll_bar())
	if is_instance_valid(desc_scroll):
		M3Theme.style_scrollbar(desc_scroll.get_v_scroll_bar())

## Group the related-games row in a rounded section card (SettingsSection's
## surface language) sitting under the left-aligned header.
func _setup_related_section_card() -> void:
	if not is_instance_valid(related_section) or not is_instance_valid(related_scroll):
		return
	var section := SettingsSection.new()
	# One elevation step darker than the sheet (surface_container_low) so the
	# card reads as an inset group against it.
	section.bg_color_override = M3Theme.get_surface()
	related_section.add_child(section)
	related_section.move_child(section, 1)  # below RelatedHeader
	related_section.remove_child(related_scroll)
	section.add_content(related_scroll, false)

func _setup_focus_neighbors() -> void:
	if not content_tabs or not action_button:
		return
	action_button.focus_neighbor_bottom = action_button.get_path_to(content_tabs)
	if sync_button:
		sync_button.focus_neighbor_bottom = sync_button.get_path_to(content_tabs)
	if favorite_button:
		favorite_button.focus_neighbor_bottom = favorite_button.get_path_to(content_tabs)
	content_tabs.focus_neighbor_top = content_tabs.get_path_to(action_button)
	if desc_fold_button:
		desc_fold_button.focus_neighbor_top = desc_fold_button.get_path_to(content_tabs)

func _apply_content_scaling() -> void:
	if not is_instance_valid(_content_root):
		return
	var edge := M3Units.dpi(24.0)
	var margin := _content_root as MarginContainer
	if margin:
		margin.add_theme_constant_override("margin_left", edge)
		margin.add_theme_constant_override("margin_top", edge)
		margin.add_theme_constant_override("margin_right", edge)
		margin.add_theme_constant_override("margin_bottom", edge)
	var hbox := _content_root.get_node_or_null(^"HBoxContainer") as HBoxContainer
	if hbox:
		hbox.add_theme_constant_override("separation", edge)
	var vbox := _content_root.get_node_or_null(^"HBoxContainer/ContentVBox") as VBoxContainer
	if vbox:
		vbox.add_theme_constant_override("separation", M3Units.dpi(12.0))
	if is_instance_valid(metadata_row):
		metadata_row.add_theme_constant_override("h_separation", M3Units.dpi(8.0))
		metadata_row.add_theme_constant_override("v_separation", M3Units.dpi(8.0))
	if is_instance_valid(files_card):
		files_card.add_theme_stylebox_override("panel", _build_files_card_style())
		var card_margin := files_card.get_node_or_null(^"CardMargin") as MarginContainer
		if card_margin:
			var pad := M3Units.dpi(CARD_PADDING_DP)
			card_margin.add_theme_constant_override("margin_left", pad)
			card_margin.add_theme_constant_override("margin_top", pad)
			card_margin.add_theme_constant_override("margin_right", pad)
			card_margin.add_theme_constant_override("margin_bottom", pad)
		var card_vbox := files_card.get_node_or_null(^"CardMargin/CardVBox") as VBoxContainer
		if card_vbox:
			card_vbox.add_theme_constant_override("separation", M3Units.dpi(CARD_GAP_DP))
	if is_instance_valid(description_label):
		# Body text reads as secondary content; keep the style's 16dp size.
		description_label.remove_theme_font_size_override("font_size")

func _build_files_card_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color.TRANSPARENT
	style.border_color = M3Theme.get_outline_variant()
	style.set_border_width_all(maxi(1, M3Units.dpi(1.0)))
	style.set_corner_radius_all(M3Units.dpi(M3Theme.RADIUS_LARGE))
	style.anti_aliasing = true
	return style

func _reparent_content() -> void:
	var content_root := get_node_or_null(CONTENT_MARGIN_PATH) as Control
	if not content_root or not _content_slot:
		return
	if content_root.get_parent():
		content_root.get_parent().remove_child(content_root)
	_content_slot.add_child(content_root)
	content_root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_root.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# Visibility is controlled by set_game/clear_content.

func _connect_signals() -> void:
	if sibling_dropdown:
		sibling_dropdown.item_selected.connect(_on_sibling_selected)
	if action_button:
		action_button.pressed.connect(_on_action_button_pressed)
	if sync_button:
		sync_button.pressed.connect(_on_sync_button_pressed)
	if status_dropdown:
		status_dropdown.item_selected.connect(_on_status_item_selected)
	if favorite_button:
		favorite_button.pressed.connect(_on_favorite_button_pressed)
	if desc_fold_button:
		desc_fold_button.pressed.connect(_on_desc_fold_pressed)
	SystemManager.download.download_completed.connect(_on_download_completed)

func _set_sheet_height() -> void:
	var viewport := get_viewport()
	if not viewport:
		return
	var screen_dp := viewport.get_visible_rect().size.y / M3Units.get_scale()
	peek_height = screen_dp * HEIGHT_FRACTION

func _reduce_top_padding() -> void:
	# Tighten the default M3BottomSheet top padding.
	if not _sheet_container:
		return
	show_drag_handle = false
	var margin := _sheet_container.get_child(0) as MarginContainer
	if margin:
		margin.add_theme_constant_override("margin_top", int(M3Units.dp(4.0)))

func _get_sheet_width(screen_width: float) -> float:
	var ui_scale := M3Units.get_scale()
	var screen_dp := screen_width / ui_scale
	var legacy_dp := minf(MAX_WIDTH_DP, screen_dp - H_MARGIN_DP)
	var width_dp := maxf(legacy_dp, screen_dp * WIDTH_FRACTION)
	return minf(width_dp, screen_dp - H_MARGIN_DP) * ui_scale

func set_game(game: GameResource) -> void:
	_current_game = game

	if not is_node_ready():
		await ready

	if not is_instance_valid(self) or _current_game == null:
		return

	_populate_basic_info(game)
	if is_instance_valid(_content_root):
		_content_root.visible = true
	if action_button:
		if UIManager:
			UIManager.suppress_next_focus_sound()
		action_button.grab_focus.call_deferred()

	await Engine.get_main_loop().process_frame
	if not is_instance_valid(self) or _current_game == null:
		return
	_update_sync_ui()

	await Engine.get_main_loop().process_frame
	if not is_instance_valid(self) or _current_game == null:
		return
	_load_cover(game)

func clear_content() -> void:
	_current_game = null
	if is_instance_valid(_content_root):
		_content_root.visible = false
	_set_cover_texture(null)
	if is_instance_valid(content_tabs):
		content_tabs.current_tab = 0
	if is_instance_valid(related_section):
		related_section.visible = false
	if is_instance_valid(related_row):
		for child in related_row.get_children():
			child.queue_free()

func _populate_basic_info(game: GameResource) -> void:
	title_label.text = game.title if game.title else "Unknown Game"
	_populate_metadata_chips(game)

	_setup_sibling_dropdown(game)
	_setup_status_dropdown(game)
	_update_favorite_button()
	_update_file_info_display(game)
	_update_action_button()
	description_label.text = game.description if game.description else "No description available."
	_setup_description_fold(game)
	_populate_related_games(game)

func _populate_metadata_chips(game: GameResource) -> void:
	if not is_instance_valid(metadata_row):
		return
	for child in metadata_row.get_children():
		child.queue_free()
	_add_metadata_chip(game.platform if game.platform else "Unknown Platform", "gamepad-variant", true, true)
	if game.release_date > 0:
		var year := int(Time.get_datetime_dict_from_unix_time(int(game.release_date / 1000)).year)
		if year > 1971:
			_add_metadata_chip(_format_release_date(game.release_date), "calendar", false)
	# Genres from the IGDB blob (clean canonical list); fall back to the
	# merged genres column only when IGDB has none.
	var genre_list: Array = []
	var igdb_genres = game.igdb_metadata.get("genres", []) if game.igdb_metadata is Dictionary else []
	if igdb_genres is Array and not igdb_genres.is_empty():
		genre_list = igdb_genres
	else:
		genre_list = game.genres
	for genre in genre_list:
		_add_metadata_chip(str(genre), "", false)
	_populate_rating_stars(game)

func _populate_rating_stars(game: GameResource) -> void:
	if game.rating <= 0:
		var label := M3Label.new()
		label.label_style = M3Label.Style.BODY_MEDIUM
		label.use_on_surface_variant = true
		label.text = "No rating"
		metadata_row.add_child(label)
		return

	# Stars live in their own tight cluster, pushed to the row's right edge
	# by an expanding spacer.
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	metadata_row.add_child(spacer)

	var stars_box := HBoxContainer.new()
	stars_box.add_theme_constant_override("separation", int(M3Units.dp(STAR_GAP_DP)))
	stars_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	metadata_row.add_child(stars_box)

	var stars := clampi(int(round(game.rating * 5.0)), 1, 5)
	for i in range(5):
		var star := FontIcon.new()
		var settings := FontIconSettings.new()
		settings.icon_name = "star" if i < stars else "star-outline"
		settings.icon_size = clampi(M3Units.dpi(STAR_SIZE_DP), 12, 128)
		settings.icon_color = M3Theme.get_primary() if i < stars else M3Theme.get_on_surface_variant()
		star.icon_settings = settings
		star.mouse_filter = Control.MOUSE_FILTER_IGNORE
		stars_box.add_child(star)

func _add_metadata_chip(text: String, icon: String, elevated: bool, accent: bool = false) -> void:
	var chip := M3Chip.new()
	chip.chip_variant = M3Chip.ChipVariant.SUGGESTION
	chip.text = text
	chip.elevated = elevated
	chip.accent_colored = accent
	chip.focus_mode = Control.FOCUS_NONE
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if icon != "":
		chip.leading_icon = icon
	metadata_row.add_child(chip)

const MONTH_NAMES := ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

# ==================== DESCRIPTION FOLD ====================

const DESC_COLLAPSED_LINES := 3

## Pins the cover column height to the sheet's maximum Overview content:
## title row + chips row + tabs + 3-line description + More button + related
## row (when the game has related entries). Computed once per game; tab
## switches and description folding never resize the cover.
func _align_cover_height() -> void:
	if not is_instance_valid(cover_container) or not is_instance_valid(content_tabs):
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(self) or _current_game == null or not visible:
		return
	var bottom := 0.0
	for child in overview_vbox.get_children():
		if child is Control and child.visible:
			bottom = maxf(bottom, child.get_global_rect().end.y)
	if bottom <= 0.0:
		return
	var target := bottom - cover_container.global_position.y
	# Normalize up to the full budget: a short description still reserves
	# 3 lines plus the (hidden) More button, so cover height is consistent
	# across games regardless of actual text length.
	var line_h := maxf(float(description_label.get_line_height()), 1.0)
	var lines_now := mini(description_label.get_line_count(), DESC_COLLAPSED_LINES)
	if lines_now < DESC_COLLAPSED_LINES:
		target += (DESC_COLLAPSED_LINES - lines_now) * line_h
	if not desc_fold_button.visible:
		target += desc_fold_button.get_combined_minimum_size().y + float(overview_vbox.get_theme_constant("separation"))
	cover_container.custom_minimum_size.y = clampf(target, 0.0, _content_hbox.size.y)

func _setup_description_fold(game: GameResource) -> void:
	if not is_instance_valid(description_label) or not is_instance_valid(desc_fold_button):
		return
	_desc_expanded = false
	desc_fold_button.text = "More"
	desc_fold_button.visible = false
	# Collapsed scroll state: no scrolling, container tracks the clamped label.
	desc_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	desc_scroll.size_flags_vertical = Control.SIZE_FILL
	desc_scroll.custom_minimum_size.y = 0
	# Measure the full text first, then clamp if it exceeds the folded budget.
	description_label.max_lines_visible = -1
	description_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
	var for_romm_id := game.romm_id
	await get_tree().process_frame
	await get_tree().process_frame
	if not is_instance_valid(self) or _current_game == null or _current_game.romm_id != for_romm_id:
		return
	if _desc_expanded:
		return
	if description_label.get_line_count() > DESC_COLLAPSED_LINES:
		description_label.max_lines_visible = DESC_COLLAPSED_LINES
		description_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		desc_fold_button.visible = true
	# Measure the cover only after the description clamp has landed.
	_align_cover_height()

func _on_desc_fold_pressed() -> void:
	_desc_expanded = not _desc_expanded
	if _desc_expanded:
		# Trade space with the related row: hide it and give the description's
		# scroll area an explicit height — never more than the space above the
		# cover column's bottom, so the Less button can't be pushed off-screen.
		# Shorter texts get a snug area (button hugs the text); longer texts
		# scroll inside the capped area.
		if is_instance_valid(related_section):
			related_section.visible = false
		description_label.max_lines_visible = -1
		description_label.text_overrun_behavior = TextServer.OVERRUN_NO_TRIMMING
		desc_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
		desc_scroll.scroll_vertical = 0
		desc_fold_button.text = "Less"
		await get_tree().process_frame
		await get_tree().process_frame
		if not is_instance_valid(self) or not _desc_expanded:
			return
		var separation := float(overview_vbox.get_theme_constant("separation"))
		var cover_bottom := cover_container.global_position.y + cover_container.size.y
		var budget := cover_bottom - desc_scroll.global_position.y - desc_fold_button.get_combined_minimum_size().y - separation
		var text_h := description_label.get_combined_minimum_size().y
		var min_h := float(description_label.get_line_height()) * DESC_COLLAPSED_LINES
		desc_scroll.custom_minimum_size.y = clampf(minf(text_h, budget), min_h, maxf(budget, min_h))
	else:
		description_label.max_lines_visible = DESC_COLLAPSED_LINES
		description_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		desc_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		desc_scroll.custom_minimum_size.y = 0
		desc_scroll.scroll_vertical = 0
		desc_fold_button.text = "More"
		if is_instance_valid(related_section) and _related_games_count > 0:
			related_section.visible = true

# ==================== RELATED GAMES ====================

const RELATED_CARD_WIDTH_DP := 120.0
# Media is 3:4 (160dp tall at 120dp wide) plus the ~36dp caption-only text area.
const RELATED_CARD_HEIGHT_DP := 120.0 / 0.75 + 36.0
const RELATED_TYPE_LABELS := {
	"dlc": "DLC",
	"expansion": "Expansion",
	"remake": "Remake",
	"remaster": "Remaster",
	"port": "Port",
	"expanded": "Expanded",
	"similar": "Similar",
}

func _populate_related_games(game: GameResource) -> void:
	if not is_instance_valid(related_section) or not is_instance_valid(related_row):
		return
	for child in related_row.get_children():
		child.queue_free()
	related_section.visible = false

	var related := game.get_igdb_related_games()
	_related_games_count = related.size()
	if related.is_empty():
		return
	if is_instance_valid(related_header):
		related_header.text = "Related Games (%d)" % related.size()
	related_section.visible = true

	var igdb_ids: Array = []
	var titles: Array = []
	for entry in related:
		_add_related_card(entry)
		var raw_id = entry.get("id", 0)
		var igdb_id := int(raw_id) if raw_id != null else 0
		if igdb_id > 0:
			igdb_ids.append(igdb_id)
		titles.append(str(entry.get("name", "")))

	# Resolve which related games are owned on the DB thread, then badge and
	# link their cards. Exact igdb_id match first, title fallback after.
	var for_romm_id := game.romm_id
	SystemManager.memory.queue_db_task(
		func():
			var by_igdb: Dictionary = DataManager.get_games_by_igdb_ids(igdb_ids)
			var unmatched: Array = []
			for i in range(related.size()):
				var raw_id = related[i].get("id", 0)
				var igdb_id := int(raw_id) if raw_id != null else 0
				if igdb_id <= 0 or not by_igdb.has(igdb_id):
					unmatched.append(titles[i])
			var by_title: Dictionary = DataManager.get_games_by_titles(unmatched) if not unmatched.is_empty() else {}
			return {"by_igdb": by_igdb, "by_title": by_title},
		func(matches: Dictionary):
			if not is_instance_valid(self) or _current_game == null or _current_game.romm_id != for_romm_id:
				return
			if not is_instance_valid(related_row):
				return
			var by_igdb: Dictionary = matches.get("by_igdb", {})
			var by_title: Dictionary = matches.get("by_title", {})
			var cards := related_row.get_children()
			var owned_pos := 0
			for i in range(mini(cards.size(), related.size())):
				var romm_id := 0
				var raw_id = related[i].get("id", 0)
				var igdb_id := int(raw_id) if raw_id != null else 0
				if igdb_id > 0 and by_igdb.has(igdb_id):
					romm_id = by_igdb[igdb_id]
				elif by_title.has(titles[i].to_lower()):
					romm_id = by_title[titles[i].to_lower()]
				if romm_id > 0:
					_mark_related_card_owned(cards[i], romm_id)
					# Owned games surface to the front in stable relative order.
					related_row.move_child(cards[i], owned_pos)
					owned_pos += 1
	)

func _add_related_card(entry: Dictionary) -> void:
	var card := M3Card.new()
	card.card_variant = M3Card.Variant.FILLED
	card.enforce_min_height = false
	card.custom_minimum_size = Vector2(M3Units.dp(RELATED_CARD_WIDTH_DP), M3Units.dp(RELATED_CARD_HEIGHT_DP))
	card.media_aspect_ratio = 0.75  # IGDB covers are 3:4
	# Caption-only cards: the type label stands in for the title.
	var type_label: String = RELATED_TYPE_LABELS.get(str(entry.get("type", "")), str(entry.get("type", "")).capitalize())
	card.supporting_text = type_label
	card.set_meta("type_label", type_label)
	card.clickable = false
	card.focus_mode = Control.FOCUS_NONE
	related_row.add_child(card)

	var cover_url := str(entry.get("cover_url", ""))
	if cover_url != "":
		# Public IGDB CDN; t_cover_small keeps thumbs light.
		var thumb_url := cover_url.replace("t_1080p", "t_cover_small")
		DataManager.load_image(thumb_url, func(texture):
			if is_instance_valid(card) and texture:
				card.media_texture = texture
		)

func _mark_related_card_owned(card: Control, romm_id: int) -> void:
	if not card is M3Card:
		return
	var type_label := str(card.get_meta("type_label", ""))
	card.supporting_text = (type_label + " · ") if type_label != "" else ""
	card.supporting_text += "In Library"
	card.bg_color_override = M3Theme.get_primary_container()
	card.clickable = true
	card.focus_mode = Control.FOCUS_ALL
	card.pressed.connect(_on_related_card_pressed.bind(romm_id))

func _on_related_card_pressed(romm_id: int) -> void:
	UIManager.show_game_details(romm_id)

func _debug_tree_state() -> String:
	# CanvasLayer has no is_visible_in_tree(); walk ancestors for visibility
	# instead (a stranded sheet in DS mode sits under an invisible/disabled one).
	var state := "inside_tree=" + str(is_inside_tree()) + " can_process=" + str(can_process())
	var ancestor := get_parent()
	while ancestor:
		if ancestor is CanvasItem or ancestor is Window:
			state += " | " + str(ancestor.name) + ".visible=" + str(ancestor.visible)
		ancestor = ancestor.get_parent()
	return state

func show_overlay():
	super.show_overlay()
	print("[DSDebug] sheet show_overlay: visible=", visible, " screen=", _get_screen_size(), " sheet_pos=", _sheet_container.position if _sheet_container else Vector2.ZERO, " state=", _debug_tree_state())
	# Detect a dead slide-in tween (e.g. a process-disabled ancestor in DS mode):
	# if the sheet never leaves the off-screen start position, the tween didn't run.
	await get_tree().create_timer(0.5).timeout
	if visible:
		var expected_end_y := _get_screen_size().y - (_sheet_container.size.y if _sheet_container else 0.0)
		print("[DSDebug] sheet 0.5s after show: sheet_pos=", _sheet_container.position if _sheet_container else Vector2.ZERO, " expected_end_y=", expected_end_y, " state=", _debug_tree_state())

func _format_release_date(epoch_ms: int) -> String:
	var dict := Time.get_datetime_dict_from_unix_time(int(epoch_ms / 1000))
	var month: String = MONTH_NAMES[clampi(int(dict.month) - 1, 0, 11)]
	return "%s %d, %d" % [month, dict.day, dict.year]

func show_for_game(game: GameResource) -> GameDetailsSheet:
	clear_content()
	# Re-resolve the overlay parent on every show: the sheet is persistent and
	# M3Sheet.show_overlay() only parents it once, so without this it keeps
	# whatever parent it first landed in - which goes stale across DS mode
	# toggles (stranded in a disabled DualScreenSetup subtree, or left in the
	# root viewport while the UI lives in a SubViewport).
	var overlay_parent := M3Overlay.get_overlay_parent()
	if overlay_parent and get_parent() != null and get_parent() != overlay_parent:
		get_parent().remove_child(self)
		overlay_parent.add_child(self)
	_reconnect_viewport_signals()
	print("[DSDebug] show_for_game: romm_id=", game.romm_id, " parent=", get_parent(), " overlay_parent=", overlay_parent, " viewport_size=", get_viewport().get_visible_rect().size if get_viewport() else Vector2.ZERO)
	# Recompute height against the current viewport/scale: the sheet is
	# persistent, so the one-shot _ready sizing goes stale after screen or
	# scale changes (dual-screen swap, orientation, display-init ordering).
	# _position_sheet() refreshes size.x as well — _animate_in() only ever
	# recomputes position, never width.
	_set_sheet_height()
	_position_sheet()
	show_overlay()
	# Let the slide-in animation start on a clean frame before populating content.
	await Engine.get_main_loop().process_frame
	if is_instance_valid(self):
		set_game(game)
	return self

func prepare_for_game(romm_id: int) -> void:
	"""Preload heavy details while the context menu is open."""
	var game: GameResource = DataManager.get_game_by_id(romm_id)
	if not game:
		return

	_prepared_romm_id = romm_id
	_prepared_cover = null

	# Decode the local cover on a background thread so it's ready if Details is selected.
	if game.cover_path and FSM.file_exists(game.cover_path):
		DataManager.cover.note_cover_access(game.cover_path)
		var cache_key := MemorySubManager.cover_cache_key(game.cover_path, MAX_DETAILS_TEXTURE_SIZE)
		var cached := MemorySubManager.get_cached_texture(cache_key)
		if cached:
			_prepared_cover = cached
			return
		MemorySubManager.queue_image_task(
			func() -> Image:
				return MemorySubManager.prepare_image_for_texture(_decode_cover_downscaled(game.cover_path)),
			func(img: Image):
				if is_instance_valid(self) and img and not img.is_empty():
					_prepared_cover = MemorySubManager.create_texture_from_image(img)
					if _prepared_cover:
						MemorySubManager.cache_texture(cache_key, _prepared_cover)
		)

func _setup_sibling_dropdown(game: GameResource) -> void:
	if not sibling_dropdown:
		return

	sibling_dropdown.clear_items()
	_sibling_options = []

	# Add the main game as the first option
	var main_label := game.file_name if game.file_name else game.title
	var main_disc := GameResource.parse_disc_number(game.file_name)
	if main_disc > 0 and not main_label.to_lower().contains("(disc"):
		main_label = "Disc %d: %s" % [main_disc, main_label]
	_sibling_options.append({
		"id": game.romm_id,
		"name": game.file_name if game.file_name else game.title,
		"file_name": game.file_name,
		"file_size": game.file_size
	})
	sibling_dropdown.add_item(main_label)

	# Add siblings, ordered by RomM's sort_comparator when available
	var sorted_siblings = game.siblings.duplicate()
	var has_comparator := false
	for sibling in sorted_siblings:
		if str(sibling.get("sort_comparator", "")) != "":
			has_comparator = true
			break
	if has_comparator:
		sorted_siblings.sort_custom(func(a, b):
			var ca := str(a.get("sort_comparator", ""))
			var cb := str(b.get("sort_comparator", ""))
			if ca == cb:
				return str(a.get("name", "")) < str(b.get("name", ""))
			return ca < cb
		)
	for sibling in sorted_siblings:
		if sibling is Dictionary:
			_sibling_options.append(sibling)
			var sibling_label := str(sibling.get("name", "Unknown"))
			var disc_number: int = sibling.get("disc_number", 0)
			if disc_number > 0 and not sibling_label.to_lower().contains("(disc"):
				sibling_label = "Disc %d: %s" % [disc_number, sibling_label]
			sibling_dropdown.add_item(sibling_label)

	# Select the currently active sibling
	var active_id = game.selected_sibling_id if game.selected_sibling_id != 0 else game.romm_id
	for i in range(_sibling_options.size()):
		if _sibling_options[i].get("id", 0) == active_id:
			sibling_dropdown.selected = i
			break

	# Show/hide dropdown based on whether there are siblings
	sibling_dropdown.visible = _sibling_options.size() > 1

func _on_sibling_selected(index: int) -> void:
	if index < 0 or index >= _sibling_options.size():
		return

	var selected = _sibling_options[index]
	var selected_id = selected.get("id", 0)

	if _current_game and selected_id != 0:
		_current_game.selected_sibling_id = selected_id

		# Check if we need to fetch full sibling details (no file extension means incomplete data)
		var sibling_file_name = selected.get("file_name", "")
		if selected_id != _current_game.romm_id and not sibling_file_name.contains("."):
			_fetch_sibling_details(selected_id, index)
			return

		# Update display to show selected variant's info
		_update_file_info_display(_current_game)
		# Update action button based on new selection
		_update_action_button()
		# Update sync UI based on new selection
		_update_sync_ui()
		# Persist the selection
		DataManager.update_game(_current_game)

func _fetch_sibling_details(sibling_id: int, dropdown_index: int) -> void:
	"""Fetch full game details for a sibling to get proper file name with extension."""
	SystemManager.network.fetch_game_details(sibling_id, func(data: Dictionary, error: String):
		if not is_instance_valid(self):
			return
		if error == "" and data.has("fs_name"):
			var full_file_name = str(data.get("fs_name", ""))

			# Update the sibling data in _current_game
			for i in range(_current_game.siblings.size()):
				if _current_game.siblings[i].get("id", 0) == sibling_id:
					_current_game.siblings[i]["file_name"] = full_file_name
					_current_game.siblings[i]["file_size"] = data.get("fs_size_bytes", 0)
					break

			# Also update _sibling_options
			if dropdown_index < _sibling_options.size():
				_sibling_options[dropdown_index]["file_name"] = full_file_name
				_sibling_options[dropdown_index]["file_size"] = data.get("fs_size_bytes", 0)

			# Save updated game data
			DataManager.update_game(_current_game)

			# Update the display
			_update_file_info_display(_current_game)
			_update_action_button()
			_update_sync_ui()
		else:
			# Still update display with what we have
			_update_file_info_display(_current_game)
			_update_action_button()
			_update_sync_ui()
			DataManager.update_game(_current_game)
	)

func _setup_status_dropdown(game: GameResource) -> void:
	if not status_dropdown:
		return

	# Status/favorites are RomM features; hide for other sources (e.g. gamenative)
	var is_romm_game := game.source == "romm"
	status_dropdown.visible = is_romm_game
	if favorite_button:
		favorite_button.visible = is_romm_game
	if not is_romm_game:
		return

	status_dropdown.clear_items()
	for opt in STATUS_OPTIONS:
		status_dropdown.add_icon_item(opt["icon"], opt["label"])
	_update_status_selection()

func _update_status_selection() -> void:
	if not status_dropdown or not _current_game:
		return
	var indices: Array[int] = []
	for i in range(STATUS_OPTIONS.size()):
		var key: String = STATUS_OPTIONS[i]["key"]
		match key:
			"now_playing":
				if _current_game.now_playing:
					indices.append(i)
			"backlogged":
				if _current_game.backlogged:
					indices.append(i)
			"hidden":
				if _current_game.hidden:
					indices.append(i)
			_:
				if _current_game.status == key:
					indices.append(i)
	status_dropdown.set_selected_indices(indices)

func _on_status_item_selected(index: int) -> void:
	if not _current_game or index < 0 or index >= STATUS_OPTIONS.size():
		return

	var key: String = STATUS_OPTIONS[index]["key"]
	var selected := status_dropdown.is_selected(index)
	var props: Dictionary = {}

	if key in STATUS_FLAG_KEYS:
		props[key] = selected
	else:
		# The status enum is mutually exclusive: clear the other enum items
		for i in range(STATUS_OPTIONS.size()):
			var other_key: String = STATUS_OPTIONS[i]["key"]
			if other_key in STATUS_FLAG_KEYS or i == index:
				continue
			if status_dropdown.is_selected(i):
				status_dropdown.deselect_option(i)
		props["status"] = key if selected else null

	DataManager.set_game_user_props(_current_game, props)

func _update_favorite_button() -> void:
	if not favorite_button or not _current_game:
		return
	favorite_button.icon_name = "heart" if _current_game.is_favorite else "heart-outline"
	favorite_button.tooltip_text = "Remove from favorites" if _current_game.is_favorite else "Add to favorites"

func _on_favorite_button_pressed() -> void:
	if not _current_game:
		return
	DataManager.set_game_favorite(_current_game, not _current_game.is_favorite)
	_update_favorite_button()

func _update_file_info_display(game: GameResource) -> void:
	# Get the active file info (either main game or selected sibling)
	var active_file_name = game.get_active_file_name()
	var active_file_size = game.get_active_file_size()

	file_info_label.text = "File: " + (active_file_name if active_file_name else "N/A")
	file_size_label.text = "Size: " + _format_file_size(active_file_size)

	# Check if the selected variant has a local copy
	if game.is_active_variant_downloaded():
		status_chip.text = "Downloaded"
		status_chip.leading_icon = "check-circle"
	else:
		status_chip.text = "Not downloaded"
		status_chip.leading_icon = "download"

	# Show Title ID for platforms that use it
	if title_id_label:
		var active_title_id = game.get_active_title_id()
		if active_title_id != "":
			title_id_label.text = "Title ID: " + active_title_id
			title_id_label.visible = true
		else:
			title_id_label.visible = false

func _load_cover(game: GameResource) -> void:
	_set_cover_texture(null)

	# Use a cover that was decoded while the context menu was open.
	if _prepared_romm_id == game.romm_id and _prepared_cover:
		_set_cover_texture(_prepared_cover)
		_prepared_cover = null
		_prepared_romm_id = 0
		return

	var cache_path := ""
	if game.cover_path and FSM.file_exists(game.cover_path):
		cache_path = game.cover_path
	elif game.cover_url and game.cover_url.begins_with("http"):
		var url_path: String = DataManager.get_cached_image_path(game.cover_url)
		if FSM.file_exists(url_path):
			cache_path = url_path

	if cache_path != "":
		DataManager.cover.note_cover_access(cache_path)
		var cache_key := MemorySubManager.cover_cache_key(cache_path, MAX_DETAILS_TEXTURE_SIZE)
		var cached := MemorySubManager.get_cached_texture(cache_key)
		if cached:
			_set_cover_texture(cached)
			return
		if is_instance_valid(cover_texture):
			M3Shimmer.attach(cover_texture, 0.0)
		MemorySubManager.queue_image_task(
			func() -> Image:
				return MemorySubManager.prepare_image_for_texture(_decode_cover_downscaled(cache_path)),
			func(img: Image):
				if is_instance_valid(cover_texture):
					M3Shimmer.detach(cover_texture)
					if img and not img.is_empty():
						var tex := MemorySubManager.create_texture_from_image(img)
						if tex:
							MemorySubManager.cache_texture(cache_key, tex)
							_set_cover_texture(tex)
							return
				# Decode failed (corrupt or extension-mismatched cache file):
				# fall back to the remote path rather than showing nothing.
				_load_cover_remote(game)
		)
		return

	# Remote URL not yet on disk: keep the existing async path.
	_load_cover_remote(game)

func _load_cover_remote(game: GameResource) -> void:
	if game.cover_url and game.cover_url.begins_with("http"):
		if is_instance_valid(cover_texture):
			M3Shimmer.attach(cover_texture, 0.0)
		DataManager.load_image(game.cover_url, func(texture):
			if not is_instance_valid(cover_texture):
				return
			M3Shimmer.detach(cover_texture)
			if texture and _current_game and _current_game.romm_id == game.romm_id:
				_set_cover_texture(texture)
		)

func _set_cover_texture(texture: Texture2D) -> void:
	if not is_instance_valid(cover_texture):
		return
	cover_texture.texture = texture

static func _decode_cover_downscaled(path: String) -> Image:
	# Decode by content, not extension: RomM serves covers whose bytes don't
	# always match the URL extension (e.g. JPEG/WebP in a .png-named file),
	# and Image.load() picks its decoder by file extension.
	var bytes := FSM.read_file_bytes(path)
	if bytes.size() < 16:
		return null
	var img := Image.new()
	var err := FAILED
	match FSM.detect_image_format(bytes):
		FSM.ImageFormat.JPEG:
			err = img.load_jpg_from_buffer(bytes)
		FSM.ImageFormat.PNG:
			err = img.load_png_from_buffer(bytes)
		FSM.ImageFormat.WEBP:
			err = img.load_webp_from_buffer(bytes)
		_:
			return null
	if err != OK or img.is_empty():
		return null
	var max_dim: int = max(img.get_width(), img.get_height())
	if max_dim > MAX_DETAILS_TEXTURE_SIZE:
		var tex_scale := float(MAX_DETAILS_TEXTURE_SIZE) / max_dim
		img.resize(maxi(1, int(img.get_width() * tex_scale)), maxi(1, int(img.get_height() * tex_scale)), Image.INTERPOLATE_LANCZOS)
	return img

func _format_file_size(bytes: int) -> String:
	if bytes < 1024:
		return str(bytes) + " B"
	elif bytes < 1024 * 1024:
		return str(int(bytes / 1024.0)) + " KB"
	elif bytes < 1024 * 1024 * 1024:
		return "%.1f MB" % (bytes / (1024.0 * 1024.0))
	else:
		return "%.1f GB" % (bytes / (1024.0 * 1024.0 * 1024.0))

func _update_action_button() -> void:
	if not action_button or not _current_game:
		return

	if _current_game.is_active_variant_downloaded():
		action_button.text = "Launch"
		action_button.icon_name = "play"
	else:
		action_button.text = "Download"
		action_button.icon_name = "download"

func _update_sync_ui() -> void:
	if not sync_button or not sync_status_label or not _current_game:
		return

	var emulator_id = LaunchManager.resolve_emulator_for_game(_current_game)
	if emulator_id == "":
		sync_button.visible = false
		sync_status_label.visible = false
		return

	var extensions = DataManager.get_save_extensions(emulator_id, _current_game.platform_slug)
	if extensions.is_empty():
		sync_button.visible = false
		sync_status_label.visible = false
		return

	sync_button.visible = true
	sync_status_label.visible = true
	sync_button.text = "Sync Saves"
	sync_button.modulate = Color.WHITE
	sync_button.disabled = false
	sync_status_label.text = DataManager.get_save_sync_status_text(_current_game, emulator_id)

func _on_sync_button_pressed() -> void:
	if not _current_game:
		return

	var emulator_id = LaunchManager.resolve_emulator_for_game(_current_game)
	if emulator_id == "":
		return

	sync_button.disabled = true
	sync_button.text = "Syncing..."

	DataManager.sync_saves_for_game(_current_game, emulator_id, func(success: bool, message: String):
		if not is_instance_valid(sync_button):
			return
		sync_button.disabled = false
		sync_button.text = "Sync Saves"
		_update_sync_ui()

		if success:
			SystemManager.notifications.show_notification("Save sync complete", SystemManager.notifications.Type.INFO)
		else:
			SystemManager.notifications.show_notification("Save sync: " + message, SystemManager.notifications.Type.ERROR)
	)

func _on_action_button_pressed() -> void:
	if not _current_game:
		return

	# Skip file check for GameNative games - they don't have physical files
	if _current_game.source == "gamenative":
		_setup_launch_transition_source()
		LaunchManager.launch_game(_current_game)
		return

	if _current_game.is_active_variant_downloaded():
		# Check if the file actually exists before launching
		var root_folder = DataManager.get_setting("games_root_folder")
		if root_folder and root_folder.value != "":
			# Construct the full file path from known components (don't rely on file_path which may be relative)
			var active_file_name = _current_game.get_active_file_name()
			var file_path = FSM.join_paths(root_folder.value, _current_game.platform_slug, active_file_name)

			if not FSM.file_exists(file_path):
				# File is marked as downloaded but doesn't exist - redownload
				SystemManager.notifications.show_notification("File not found - redownloading", SystemManager.notifications.Type.WARNING)
				_queue_download()
				return

		# Launch the game
		_setup_launch_transition_source()
		LaunchManager.launch_game(_current_game)
	else:
		# Download the game - same logic as library view
		_queue_download()

func _setup_launch_transition_source() -> void:
	# Animate the launch transition from the cover art shown in this sheet.
	if is_instance_valid(cover_texture) and cover_texture.texture:
		LaunchTransitionOverlay.set_source(cover_texture.texture, Rect2(cover_texture.global_position, cover_texture.size))

func _queue_download() -> void:
	if not _current_game:
		return
	SystemManager.download.queue_game_download(_current_game)

func _on_download_completed(item_id: String, success: bool, message: String) -> void:
	# Check if this download is for our current game
	if not _current_game:
		return

	var item = SystemManager.download.get_item(item_id)
	if item and item.game_resource and item.game_resource.romm_id == _current_game.romm_id:
		if success:
			SystemManager.notifications.show_notification("Download completed", SystemManager.notifications.Type.INFO)
		else:
			SystemManager.notifications.show_notification("Download failed: " + message, SystemManager.notifications.Type.ERROR)

		# Reload game data from DataManager to get updated downloaded_sibling_ids
		var updated_game = DataManager.get_game_by_id(_current_game.romm_id)
		if updated_game:
			_current_game = updated_game

		# Refresh the action button state
		_update_action_button()
		# Also refresh the file info display
		_update_file_info_display(_current_game)
		# Also refresh the sync UI
		_update_sync_ui()
