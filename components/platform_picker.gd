@tool
class_name PlatformPicker
extends M3Dialog

signal platform_selected(platform_slug: String, platform_name: String)

var _option_button: M3OptionButton = null
var _platforms: Array[Dictionary] = []
var _disabled_slugs: Array[String] = []

func _init():
	super._init()
	dismissible = true
	disable_default_action = true

func _ready():
	super._ready()
	title_text = "Pin Platform"
	_build_content()
	_add_actions()
	_load_platforms()

func set_disabled_slugs(slugs: Array[String]) -> void:
	_disabled_slugs = slugs.duplicate()
	_update_option_items()

func _build_content() -> void:
	if not content_slot:
		return

	var vbox = VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", int(M3Units.dp(16)))
	content_slot.add_child(vbox)

	var body = Label.new()
	body.text = "Choose a synced platform to pin to the navigation bar."
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(body)

	_option_button = M3OptionButton.new()
	_option_button.placeholder_text = "Select a platform..."
	_option_button.leading_icon = "gamepad-variant"
	_option_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(_option_button)

func _add_actions() -> void:
	add_action("Cancel", _on_cancel, false)
	add_action("Pin", _on_confirm, true)

func _on_cancel() -> void:
	dismiss()

func _on_confirm() -> void:
	if _option_button == null:
		return
	var selected_idx = _option_button.selected
	if selected_idx < 0 or selected_idx >= _platforms.size():
		return
	var platform = _platforms[selected_idx]
	var slug = platform.get("slug", "")
	if slug.is_empty():
		return
	platform_selected.emit(slug, platform.get("name", ""))
	dismiss()

func _load_platforms() -> void:
	_platforms = DataManager.get_platforms_with_games()
	_update_option_items()

func _update_option_items() -> void:
	if _option_button == null:
		return
	_option_button.clear_items()
	var valid_count = 0
	for i in range(_platforms.size()):
		var platform = _platforms[i]
		var slug = platform.get("slug", "")
		var platform_name = platform.get("name", "")
		var disabled = slug.is_empty() or _disabled_slugs.has(slug)
		_option_button.add_item(platform_name, i)
		if disabled:
			_option_button.set_item_disabled(i, true)
		else:
			valid_count += 1

	if valid_count == 0 and _platforms.size() > 0:
		_option_button.placeholder_text = "All platforms already pinned"
	elif _platforms.size() == 0:
		_option_button.placeholder_text = "No platforms available"
	else:
		_option_button.placeholder_text = "Select a platform..."

func _on_action_pressed(label: String) -> void:
	action_pressed.emit(label)
	if label == "Pin":
		_on_confirm()
	elif label == "Cancel":
		_on_cancel()

func _on_close_button_pressed() -> void:
	dismiss()
