class_name HeroArtBackgroundEffect
extends BackgroundEffect

## Fullscreen hero-artwork layer: tracks the focused GameCard and shows its
## cover cover-cropped over the whole background. Transparent until artwork
## is available, so it composites cleanly over the layers beneath.

const FSM := preload("res://managers/system_manager/filesystem_sub_manager.gd")
const MAX_TEXTURE_SIZE: int = 1024

var _current_game_id: String = ""
var _current_task_id: int = -1
var _fade_tween: Tween = null

func _ready():
	super._ready()
	effect_name = "Hero Artwork"
	effect_id = "hero_art"

	var viewport = get_viewport()
	if viewport and not viewport.gui_focus_changed.is_connected(_on_gui_focus_changed):
		viewport.gui_focus_changed.connect(_on_gui_focus_changed)

func _exit_tree():
	_cancel_pending_load()
	var viewport = get_viewport()
	if viewport and viewport.gui_focus_changed.is_connected(_on_gui_focus_changed):
		viewport.gui_focus_changed.disconnect(_on_gui_focus_changed)
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_set_shader_param("rect_size", size)

func _setup_shader() -> void:
	var mat = material as ShaderMaterial
	mat.shader = preload("res://shaders/background/library_background_hero.gdshader")

func _apply_settings() -> void:
	_set_shader_param("dim", _settings.get("dim", 0.35))
	_set_shader_param("blur", _settings.get("blur", 0.3))
	_set_shader_param("opacity", _settings.get("opacity", 1.0))
	_set_shader_param("rect_size", size)

func get_settings_schema() -> Array[SettingsVar]:
	var schema: Array[SettingsVar] = []
	var Type = SettingsVar.SettingType
	var State = SettingsVar.SettingState

	var dim_var = SettingsVar.new(Type.FLOAT, 0.35, State.ENABLED, "Dim", "Darken the artwork so the UI stays readable", 0.0, 1.0, 0.05)
	dim_var.property_name = "dim"
	schema.append(dim_var)

	var blur_var = SettingsVar.new(Type.FLOAT, 0.3, State.ENABLED, "Blur", "Soften the artwork so the UI stays readable", 0.0, 1.0, 0.05)
	blur_var.property_name = "blur"
	schema.append(blur_var)

	var opacity_var = SettingsVar.new(Type.FLOAT, 1.0, State.ENABLED, "Opacity", "Fade the artwork so layers beneath show through", 0.0, 1.0, 0.05)
	opacity_var.property_name = "opacity"
	schema.append(opacity_var)

	return schema

func _on_gui_focus_changed(control: Control) -> void:
	var node = control
	while node != null:
		if node is GameCard:
			if node.game:
				set_game(node.game)
			return
		node = node.get_parent()

func set_game(game: GameResource) -> void:
	if game and game.id == _current_game_id:
		return
	_current_game_id = game.id if game else ""

	var cache_path = _get_cache_path(game)
	if cache_path.is_empty():
		_clear_art()
		return

	DataManager.cover.note_cover_access(cache_path)

	var cached_tex = MemorySubManager.get_cached_texture(MemorySubManager.cover_cache_key(cache_path, MAX_TEXTURE_SIZE))
	if cached_tex:
		_set_art(cached_tex)
		return

	# Show the 512px card variant instantly while the full-res variant
	# decodes; _set_art runs again when it lands.
	var card_tex = MemorySubManager.get_cached_texture(MemorySubManager.cover_cache_key(cache_path, CardMediaLoader.MAX_COVER_TEXTURE_SIZE))
	if card_tex:
		_set_art(card_tex)

	_cancel_pending_load()
	var loading_id = _current_game_id

	var load_callable = func() -> Image:
		var buffer = FSM.read_file_bytes(cache_path)
		if buffer.is_empty():
			return null
		var img = Image.new()
		var err = FAILED
		if buffer.size() >= 2:
			if buffer[0] == 0xFF and buffer[1] == 0xD8:
				err = img.load_jpg_from_buffer(buffer)
			elif buffer[0] == 0x89 and buffer[1] == 0x50:
				err = img.load_png_from_buffer(buffer)
			else:
				err = img.load_webp_from_buffer(buffer)
		if err == OK:
			if img.is_empty():
				return null
			var max_dim = max(img.get_width(), img.get_height())
			if max_dim > MAX_TEXTURE_SIZE:
				var tex_scale = float(MAX_TEXTURE_SIZE) / max_dim
				img.resize(maxi(1, int(img.get_width() * tex_scale)), maxi(1, int(img.get_height() * tex_scale)), Image.INTERPOLATE_LANCZOS)
			return MemorySubManager.prepare_image_for_texture(img)
		return null

	var callback_callable = func(image: Image):
		_current_task_id = -1
		if not is_instance_valid(self):
			return
		if _current_game_id != loading_id:
			return
		if image and not image.is_empty():
			var tex = MemorySubManager.create_texture_from_image(image)
			if tex:
				MemorySubManager.cache_texture(MemorySubManager.cover_cache_key(cache_path, MAX_TEXTURE_SIZE), tex)
				_set_art(tex)
				return
		_clear_art()

	_current_task_id = MemorySubManager.queue_image_task(load_callable, callback_callable, true)

func _get_cache_path(game: GameResource) -> String:
	if not game or not game.has_cover_art:
		return ""
	if game.cover_path and ResourceLoader.exists(game.cover_path):
		return game.cover_path
	elif game.cover_url != "" and game.cover_url.begins_with("http"):
		return DataManager.get_cached_image_path(game.cover_url)
	return ""

func _cancel_pending_load() -> void:
	if _current_task_id > 0:
		MemorySubManager.cancel_image_task(_current_task_id)
		_current_task_id = -1

func _set_art(tex: Texture2D) -> void:
	_set_shader_param("art_texture", tex)
	_set_shader_param("has_art", true)
	if _fade_tween and _fade_tween.is_valid():
		_fade_tween.kill()
	_fade_tween = create_tween()
	modulate.a = 0.0
	_fade_tween.tween_property(self, "modulate:a", 1.0, 0.35)

func _clear_art() -> void:
	_cancel_pending_load()
	_set_shader_param("has_art", false)
	modulate.a = 1.0
