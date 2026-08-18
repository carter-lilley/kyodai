extends Manager
class_name UserPropsSubManager

## Manages RomM per-user game state: play status props (status, now_playing,
## backlogged, hidden) via PUT /roms/{id}/props, and favorites via the user's
## regular collection flagged is_favorite=true. Changes are applied locally
## first, pushed to the server, and queued in the DB for retry when the push
## fails (offline etc.).

signal game_props_updated(game: GameResource)

var data_manager: Node

var _favourites_collection_id: int = 0
var _flushing: bool = false


func _ready() -> void:
	data_manager = get_parent()
	SystemManager.network.network_status_changed.connect(_on_network_status_changed)


# ==================== USER PROPS (status etc.) ====================

## Apply RomM user props to a game locally, persist to DB, and push to server.
## props keys: status (String or null), now_playing, backlogged, hidden (bool)
func set_game_props(game: GameResource, props: Dictionary, update_last_played: bool = false, notify: bool = true, callback: Callable = Callable()) -> void:
	if not game or props.is_empty():
		if callback.is_valid():
			callback.call(false)
		return

	_apply_props_local(game, props)

	if not SystemManager.network.is_online():
		_queue_props(game.romm_id, props, update_last_played)
		if notify:
			_notify("Saved - will sync to RomM when back online", SystemManager.notifications.Type.WARNING)
		game_props_updated.emit(game)
		if callback.is_valid():
			callback.call(false)
		return

	SystemManager.network.update_rom_user_props(game.romm_id, props, update_last_played, func(_data, error):
		if error != "":
			_queue_props(game.romm_id, props, update_last_played)
			if notify:
				_notify("Saved - will sync to RomM when back online", SystemManager.notifications.Type.WARNING)
		elif notify:
			_notify("Status synced to RomM", SystemManager.notifications.Type.INFO)
		game_props_updated.emit(game)
		if callback.is_valid():
			callback.call(error == "")
	)


func _apply_props_local(game: GameResource, props: Dictionary) -> void:
	for key in props.keys():
		match key:
			"status":
				game.status = str(props[key]) if props[key] != null else ""
			"now_playing":
				game.now_playing = props[key] == true
			"backlogged":
				game.backlogged = props[key] == true
			"hidden":
				game.hidden = props[key] == true
	data_manager.database.update_game_user_props(game.romm_id, props)


func _queue_props(romm_id: int, props: Dictionary, update_last_played: bool) -> void:
	data_manager.database.queue_pending_props(romm_id, "props", {
		"props": props,
		"update_last_played": update_last_played,
	})


# ==================== FAVOURITES ====================

## RomM favorites are a regular per-user collection flagged is_favorite=true.
## Membership lives in collection_roms (synced by CollectionSubManager).

## Mark games as favorites from the locally synced favorite collection.
func sync_favourites(callback: Callable = Callable()) -> void:
	if not data_manager.database.is_database_ready():
		if callback.is_valid():
			callback.call(false)
		return
	var fav_id = data_manager.database.get_favorite_collection_id()
	if fav_id == 0:
		print("[UserPropsSubManager] sync_favourites: no favorites collection in local DB - skipping")
		if callback.is_valid():
			callback.call(false)
		return
	_favourites_collection_id = fav_id
	data_manager.database.set_all_favorites(data_manager.database.get_romm_ids_for_collection(fav_id))
	# Re-apply locally queued favorite changes so pending offline edits win
	for entry in data_manager.database.get_pending_props_sync():
		if entry["kind"] == "fav":
			var fav: bool = entry["payload"].get("favorite", false)
			data_manager.database.update_game_user_props(entry["romm_id"], {"is_favorite": fav})
			if fav:
				data_manager.database.add_collection_roms(fav_id, [entry["romm_id"]])
			else:
				data_manager.database.remove_collection_rom(fav_id, entry["romm_id"])
	if callback.is_valid():
		callback.call(true)


## Resolve the favorites collection id: memory cache, then the locally synced
## collections table, then the server (creating the collection like the RomM UI
## does if none exists). Calls on_resolved(collection_id); 0 means unavailable.
func _resolve_favorites_collection_id(on_resolved: Callable) -> void:
	if _favourites_collection_id != 0:
		on_resolved.call(_favourites_collection_id)
		return

	var local_id = data_manager.database.get_favorite_collection_id()
	if local_id != 0:
		_favourites_collection_id = local_id
		on_resolved.call(local_id)
		return

	if not SystemManager.network.is_online():
		on_resolved.call(0)
		return

	SystemManager.network.fetch_collections(func(result: Dictionary, error: String):
		var fav_id := 0
		if error == "":
			for collection in result.get("collections", []):
				if collection is Dictionary and collection.get("is_favorite", false) == true:
					fav_id = int(collection.get("id", 0))
					break
		if fav_id != 0:
			_favourites_collection_id = fav_id
			on_resolved.call(fav_id)
			return
		# No favorite collection on the server yet - create it like the RomM UI does
		SystemManager.network.create_favorite_collection(func(data, create_error):
			var new_id := 0
			if create_error == "" and data is Dictionary:
				new_id = int(data.get("id", 0))
			if new_id != 0:
				_favourites_collection_id = new_id
				# Persist locally so collection views and future lookups see it
				data_manager.collections._save_collection(data)
			on_resolved.call(new_id)
		)
	, false)


func set_favorite(game: GameResource, favorite: bool, notify: bool = true, callback: Callable = Callable()) -> void:
	if not game:
		if callback.is_valid():
			callback.call(false)
		return

	game.is_favorite = favorite
	data_manager.database.update_game_user_props(game.romm_id, {"is_favorite": favorite})

	if not SystemManager.network.is_online():
		_queue_fav(game.romm_id, favorite)
		if notify:
			_notify("Saved - will sync to RomM when back online", SystemManager.notifications.Type.WARNING)
		game_props_updated.emit(game)
		if callback.is_valid():
			callback.call(false)
		return

	_push_favorite(game, favorite, notify, callback)


func _push_favorite(game: GameResource, favorite: bool, notify: bool, callback: Callable) -> void:
	_resolve_favorites_collection_id(func(collection_id: int):
		if not is_instance_valid(game) or collection_id == 0:
			_queue_fav(game.romm_id, favorite)
			if notify:
				_notify("Saved - will sync to RomM when back online", SystemManager.notifications.Type.WARNING)
			game_props_updated.emit(game)
			if callback.is_valid():
				callback.call(false)
			return

		# Keep the local collection link in sync optimistically
		if favorite:
			data_manager.database.add_collection_roms(collection_id, [game.romm_id])
		else:
			data_manager.database.remove_collection_rom(collection_id, game.romm_id)

		var on_done = func(_data, error):
			if error != "":
				_queue_fav(game.romm_id, favorite)
				if notify:
					_notify("Saved - will sync to RomM when back online", SystemManager.notifications.Type.WARNING)
			elif notify:
				_notify("Added to favorites" if favorite else "Removed from favorites", SystemManager.notifications.Type.INFO)
			game_props_updated.emit(game)
			if callback.is_valid():
				callback.call(error == "")

		if favorite:
			SystemManager.network.add_roms_to_collection(collection_id, [game.romm_id], on_done)
		else:
			SystemManager.network.remove_roms_from_collection(collection_id, [game.romm_id], on_done)
	)


func _queue_fav(romm_id: int, favorite: bool) -> void:
	data_manager.database.queue_pending_props(romm_id, "fav", {"favorite": favorite})


# ==================== PENDING QUEUE FLUSH ====================

func _on_network_status_changed(online: bool) -> void:
	if online:
		flush_pending()


func flush_pending() -> void:
	if _flushing or not SystemManager.network.is_online():
		return
	if not data_manager.database.is_database_ready():
		return
	var pending = data_manager.database.get_pending_props_sync()
	if pending.is_empty():
		return
	_flushing = true
	print("[UserPropsSubManager] Flushing %d pending prop writes" % pending.size())
	_flush_next(pending, 0)


func _flush_next(pending: Array[Dictionary], index: int) -> void:
	if index >= pending.size():
		_flushing = false
		return

	var entry = pending[index]
	var romm_id: int = entry["romm_id"]
	var kind: String = entry["kind"]
	var payload: Dictionary = entry["payload"]
	var advance := func(): _flush_next(pending, index + 1)

	match kind:
		"props":
			var props: Dictionary = payload.get("props", {})
			var update_last_played: bool = payload.get("update_last_played", false)
			SystemManager.network.update_rom_user_props(romm_id, props, update_last_played, func(_data, error):
				if error == "":
					data_manager.database.clear_pending_props(romm_id, kind)
				advance.call()
			)
		"fav":
			var favorite: bool = payload.get("favorite", false)
			_flush_fav_entry(romm_id, favorite, advance)
		_:
			advance.call()


func _flush_fav_entry(romm_id: int, favorite: bool, advance: Callable) -> void:
	_resolve_favorites_collection_id(func(collection_id: int):
		if collection_id == 0:
			# Can't resolve the favorites collection; keep queued for next reconnect
			advance.call()
			return
		var on_done = func(_data, error):
			if error == "":
				data_manager.database.clear_pending_props(romm_id, "fav")
			advance.call()
		if favorite:
			SystemManager.network.add_roms_to_collection(collection_id, [romm_id], on_done)
		else:
			SystemManager.network.remove_roms_from_collection(collection_id, [romm_id], on_done)
	)


func _notify(message: String, type: int) -> void:
	if SystemManager.notifications:
		SystemManager.notifications.show_notification(message, type)
