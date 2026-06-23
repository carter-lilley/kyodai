class_name GameDetailsSheet
extends M3BottomSheet

const FSM := preload("res://managers/filesystem_manager.gd")

## Game details bottom sheet.
## Extends M3BottomSheet so the details UI is a native Material 3 overlay
## instead of a full-screen tab.

const CONTENT_MARGIN_PATH := ^"MarginContainer"
const MAX_HEIGHT_DP := 640.0


# NOTE: The scene root is a CanvasLayer (M3BottomSheet base). The MarginContainer
# and its children are direct children of the root in the .tscn file, then
# _reparent_content() moves MarginContainer into the sheet's _content_slot.
@onready var _content_root: Control = $MarginContainer
@onready var cover_texture: TextureRect = $MarginContainer/HBoxContainer/CoverContainer/CoverTexture
@onready var title_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/TitleLabel
@onready var metadata_row: HBoxContainer = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/MetadataRow
@onready var platform_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/MetadataRow/PlatformLabel
@onready var genres_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/MetadataRow/GenresLabel
@onready var rating_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/MetadataRow/RatingLabel
@onready var file_info_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/FileInfoRow/FileInfoLabel
@onready var file_size_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/FileInfoRow/FileSizeLabel
@onready var status_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/FileInfoRow/StatusLabel
@onready var title_id_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/TitleIdLabel
@onready var description_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/DescriptionLabel
@onready var sibling_dropdown: M3OptionButton = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/SiblingDropdown
@onready var action_button: M3Button = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/ButtonRow/ActionButton
@onready var sync_button: M3Button = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/ButtonRow/SyncButton
@onready var sync_status_label: Label = $MarginContainer/HBoxContainer/ContentScroll/ContentVBox/SyncStatusLabel

var _current_game: GameResource = null
var _sibling_options: Array[Dictionary] = []  # [{id, name, file_name, file_size}, ...]

func _init():
    super._init()
    persistent = true

# Preloaded data while a context menu is open.
var _prepared_romm_id: int = 0
var _prepared_cover: Texture2D = null

func _ready():
    super._ready()
    _reparent_content()
    _connect_signals()
    _set_sheet_height()
    _reduce_top_padding()

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
    DownloadManager.download_completed.connect(_on_download_completed)

func _set_sheet_height() -> void:
    var viewport := get_viewport()
    if not viewport:
        return
    var screen_dp := viewport.get_visible_rect().size.y / M3Units.get_scale()
    peek_height = min(MAX_HEIGHT_DP, screen_dp * 0.75)

func _reduce_top_padding() -> void:
    # Tighten the default M3BottomSheet top padding.
    if not _sheet_container:
        return
    show_drag_handle = false
    var margin := _sheet_container.get_child(0) as MarginContainer
    if margin:
        margin.add_theme_constant_override("margin_top", M3Units.dp(4.0))

func _get_sheet_width(screen_width: float) -> float:
    # Make the details sheet wider than the default 640 dp bottom sheet.
    var max_width_px := M3Units.dp(1024.0)
    return min(screen_width - M3Units.dp(32.0), max_width_px)

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
    if is_instance_valid(cover_texture):
        cover_texture.texture = null

func _populate_basic_info(game: GameResource) -> void:
    title_label.text = game.title if game.title else "Unknown Game"
    platform_label.text = game.platform if game.platform else "Unknown Platform"

    if game.genres.size() > 0:
        genres_label.text = "• " + ", ".join(game.genres)
    else:
        genres_label.text = ""

    if game.rating > 0:
        var stars = clamp(round(game.rating * 5), 1, 5)
        var empty_stars = 5 - stars
        rating_label.text = "★".repeat(stars) + ("☆".repeat(empty_stars) if empty_stars > 0 else "")
    else:
        rating_label.text = "No rating"

    _setup_sibling_dropdown(game)
    _update_file_info_display(game)
    _update_action_button()
    description_label.text = game.description if game.description else "No description available."

func show_for_game(game: GameResource) -> GameDetailsSheet:
    clear_content()
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
        MemoryManager.queue_image_task(
            func() -> Image:
                var img := Image.new()
                if img.load(game.cover_path) == OK and not img.is_empty():
                    return img
                return null,
            func(img: Image):
                if is_instance_valid(self) and img and not img.is_empty():
                    _prepared_cover = ImageTexture.create_from_image(img.duplicate())
        )

func _setup_sibling_dropdown(game: GameResource) -> void:
    if not sibling_dropdown:
        return

    sibling_dropdown.clear()
    _sibling_options = []

    # Add the main game as the first option
    _sibling_options.append({
        "id": game.romm_id,
        "name": game.file_name if game.file_name else game.title,
        "file_name": game.file_name,
        "file_size": game.file_size
    })
    sibling_dropdown.add_item(game.file_name if game.file_name else game.title)

    # Add siblings
    for sibling in game.siblings:
        if sibling is Dictionary:
            _sibling_options.append(sibling)
            sibling_dropdown.add_item(sibling.get("name", "Unknown"))

    # Select the currently active sibling
    var active_id = game.selected_sibling_id if game.selected_sibling_id != 0 else game.romm_id
    for i in range(_sibling_options.size()):
        if _sibling_options[i].get("id", 0) == active_id:
            sibling_dropdown.selected = i
            break

    # Show/hide dropdown based on whether there are siblings
    sibling_dropdown.visible = _sibling_options.size() > 1

    # Debug: force visible to check if it's a visibility issue
    if _sibling_options.size() > 1:
        sibling_dropdown.visible = true

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
    NetworkManager.fetch_game_details(sibling_id, func(data: Dictionary, error: String):
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

func _update_file_info_display(game: GameResource) -> void:
    # Get the active file info (either main game or selected sibling)
    var active_file_name = game.get_active_file_name()
    var active_file_size = game.get_active_file_size()

    file_info_label.text = "File: " + (active_file_name if active_file_name else "N/A")
    file_size_label.text = "Size: " + _format_file_size(active_file_size)

    # Check if the selected variant has a local copy
    if game.is_active_variant_downloaded():
        status_label.text = "✓ Downloaded"
        status_label.modulate = Color.GREEN
    else:
        status_label.text = "☐ Not downloaded"
        status_label.modulate = Color.GRAY

    # Show Title ID for platforms that use it
    if title_id_label:
        var active_title_id = game.get_active_title_id()
        if active_title_id != "":
            title_id_label.text = "Title ID: " + active_title_id
            title_id_label.visible = true
        else:
            title_id_label.visible = false

func _load_cover(game: GameResource) -> void:
    if is_instance_valid(cover_texture):
        cover_texture.texture = null

    # Use a cover that was decoded while the context menu was open.
    if _prepared_romm_id == game.romm_id and _prepared_cover:
        if is_instance_valid(cover_texture):
            cover_texture.texture = _prepared_cover
        _prepared_cover = null
        _prepared_romm_id = 0
        return

    # Local file: decode on a background thread.
    if game.cover_path and FSM.file_exists(game.cover_path):
        MemoryManager.queue_image_task(
            func() -> Image:
                var img := Image.new()
                if img.load(game.cover_path) == OK and not img.is_empty():
                    return img
                return null,
            func(img: Image):
                if is_instance_valid(cover_texture) and img and not img.is_empty():
                    cover_texture.texture = ImageTexture.create_from_image(img.duplicate())
        )
        return

    # Remote URL: keep the existing async path.
    if game.cover_url and game.cover_url.begins_with("http"):
        DataManager.load_image(game.cover_url, func(texture):
            if not is_instance_valid(cover_texture):
                return
            if texture and _current_game and _current_game.romm_id == game.romm_id:
                cover_texture.texture = texture
        )

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

    var extensions = SaveManager.get_save_extensions(emulator_id, _current_game.platform_slug)
    if extensions.is_empty():
        sync_button.visible = false
        sync_status_label.visible = false
        return

    sync_button.visible = true
    sync_status_label.visible = true
    sync_button.text = "Sync Saves"
    sync_button.modulate = Color.WHITE
    sync_button.disabled = false
    sync_status_label.text = SaveManager.get_save_sync_status_text(_current_game, emulator_id)

func _on_sync_button_pressed() -> void:
    if not _current_game:
        return

    var emulator_id = LaunchManager.resolve_emulator_for_game(_current_game)
    if emulator_id == "":
        return

    sync_button.disabled = true
    sync_button.text = "Syncing..."

    SaveManager.sync_saves_for_game(_current_game, emulator_id, func(success: bool, message: String):
        if not is_instance_valid(sync_button):
            return
        sync_button.disabled = false
        sync_button.text = "Sync Saves"
        _update_sync_ui()

        if success:
            NotificationManager.show_notification("Save sync complete", NotificationManager.Type.INFO)
        else:
            NotificationManager.show_notification("Save sync: " + message, NotificationManager.Type.ERROR)
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
        var root_folder = SettingsManager.get_setting("games_root_folder")
        if root_folder and root_folder.value != "":
            # Construct the full file path from known components (don't rely on file_path which may be relative)
            var active_file_name = _current_game.get_active_file_name()
            var file_path = FSM.join_paths(root_folder.value, _current_game.platform_slug, active_file_name)

            if not FSM.file_exists(file_path):
                # File is marked as downloaded but doesn't exist - redownload
                NotificationManager.show_notification("File not found - redownloading", NotificationManager.Type.WARNING)
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

    # Use the selected sibling's ID and file name if one is selected
    var active_game_id = _current_game.get_active_game_id()
    var active_file_name = _current_game.get_active_file_name()

    var download_url = NetworkManager.get_romm_download_url(active_game_id, active_file_name)
    var root_folder = SettingsManager.get_setting("games_root_folder")
    if not root_folder or root_folder.value == "":
        NotificationManager.show_notification("Error: Games folder not set", NotificationManager.Type.ERROR)
        return

    var destination_path = root_folder.value + "/" + _current_game.platform_slug + "/" + active_file_name
    var item_id = DownloadManager.queue_download(download_url, destination_path, "game", _current_game.get_display_name(), false, "", _current_game, {}, active_game_id)

    if item_id != "":
        NotificationManager.show_notification("Queued: " + _current_game.get_display_name(), NotificationManager.Type.INFO)
    else:
        NotificationManager.show_notification("Failed to queue download", NotificationManager.Type.ERROR)

func _on_download_completed(item_id: String, success: bool, message: String) -> void:
    # Check if this download is for our current game
    if not _current_game:
        return

    var item = DownloadManager.get_item(item_id)
    if item and item.game_resource and item.game_resource.romm_id == _current_game.romm_id:
        if success:
            NotificationManager.show_notification("Download completed", NotificationManager.Type.INFO)
        else:
            NotificationManager.show_notification("Download failed: " + message, NotificationManager.Type.ERROR)

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
