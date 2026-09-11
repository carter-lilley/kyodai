extends Manager
class_name CollectionSubManager

## Manages RomM collections: sync from server, local persistence, and queries.

var data_manager: Node

signal collections_synced(success: bool, message: String)
signal collection_membership_changed(collection_id: int, romm_id: int)

## Pending-sync queue kind for collection membership adds; the collection id is
## embedded in the kind so one ROM can queue adds to multiple collections.
const COLLECTION_ADD_KIND_PREFIX := "collection_add:"

var _is_syncing: bool = false

func _ready() -> void:
	data_manager = get_parent()


func sync_collections(callback: Callable = Callable()) -> void:
	"""Fetch regular user collections from RomM and persist them locally."""
	if _is_syncing:
		if callback.is_valid():
			callback.call(false, "Collection sync already in progress")
		return

	if not data_manager or not data_manager.database.is_database_ready():
		if callback.is_valid():
			callback.call(false, "Database not ready")
		return

	if not SystemManager.network or not SystemManager.network.is_configured():
		if callback.is_valid():
			callback.call(false, "RomM not configured")
		return

	_is_syncing = true
	print("[CollectionSubManager] Syncing collections...")

	SystemManager.network.fetch_collections(func(result: Dictionary, error: String):
		WarmupBudget.tag("collection_sync_cb")
		if not error.is_empty():
			push_error("[CollectionSubManager] Failed to sync collections: " + error)
			_is_syncing = false
			if SystemManager.notifications:
				SystemManager.notifications.show_notification("Failed to sync collections: " + error, SystemManager.notifications.Type.ERROR)
			if callback.is_valid():
				callback.call(false, error)
			collections_synced.emit(false, error)
			return

		var collections = result.get("collections", []) as Array

		# Persist on the DB worker: the write burst (clear + re-save every
		# collection + re-apply pending adds) is synchronous SQLite work that
		# previously ran inline on the main thread right at startup.
		var db_work := func():
			data_manager.database.clear_all_collections()
			for collection in collections:
				_save_collection(collection)

			# Re-apply locally queued collection adds so pending offline edits win
			for entry in data_manager.database.get_pending_props_sync():
				var kind := str(entry["kind"])
				if kind.begins_with(COLLECTION_ADD_KIND_PREFIX):
					data_manager.database.add_collection_roms(int(kind.split(":")[1]), [entry["romm_id"]])

		var db_done := func(_r):
			_is_syncing = false
			print("[CollectionSubManager] Synced %d collections" % collections.size())
			if callback.is_valid():
				callback.call(true, "Synced %d collections" % collections.size())
			collections_synced.emit(true, "Synced %d collections" % collections.size())

		if MemorySubManager.is_shutting_down():
			db_work.call()
			db_done.call(null)
		else:
			MemorySubManager.queue_db_task(db_work, db_done)
	)


func _save_collection(collection: Dictionary) -> void:
	var id: int = collection.get("id", 0)
	if id == 0:
		return

	var collection_name: String = collection.get("name", "")
	var is_favorite: bool = collection.get("is_favorite", false)
	if collection_name.strip_edges() == "":
		# Favorites collections can exist server-side with an empty name (e.g.
		# created via the API without a name); give it the canonical display name
		# so it persists locally and sync_favourites can resolve it.
		if is_favorite:
			collection_name = "Favourites"
		else:
			return

	data_manager.database.save_collection({
		"id": id,
		"name": collection_name,
		"description": collection.get("description", ""),
		"is_public": collection.get("is_public", false),
		"is_favorite": is_favorite,
		"rom_count": collection.get("rom_count", 0),
		"updated_at": collection.get("updated_at", "")
	})

	var rom_ids = collection.get("rom_ids", []) as Array
	data_manager.database.add_collection_roms(id, rom_ids)


func get_collections() -> Array[Dictionary]:
	if not data_manager or not data_manager.database.is_database_ready():
		return []
	return data_manager.database.get_collections()


func get_collection(romm_id: int) -> Dictionary:
	if not data_manager or not data_manager.database.is_database_ready():
		return {}
	return data_manager.database.get_collection(romm_id)


func get_romm_ids_for_collection(romm_id: int) -> Array[int]:
	if not data_manager or not data_manager.database.is_database_ready():
		return []
	return data_manager.database.get_romm_ids_for_collection(romm_id)


func get_favorite_collection_id() -> int:
	"""Return the locally synced favorites collection id, or 0 if unavailable."""
	if not data_manager or not data_manager.database.is_database_ready():
		return 0
	return data_manager.database.get_favorite_collection_id()


func get_games_for_collection_count(romm_id: int) -> int:
	if not data_manager or not data_manager.database.is_database_ready():
		return 0
	return data_manager.database.get_games_for_collection_count(romm_id)


func get_games_for_collection_paginated(romm_id: int, offset: int, limit: int, sort_field: String = "title", ascending: bool = true) -> Array[GameResource]:
	var games: Array[GameResource] = []
	if not data_manager or not data_manager.database.is_database_ready():
		return games
	return data_manager.database.get_games_for_collection_paginated(romm_id, offset, limit, sort_field, ascending)


func is_syncing() -> bool:
	return _is_syncing


func get_collection_ids_for_rom(romm_id: int) -> Array[int]:
	if not data_manager or not data_manager.database.is_database_ready():
		return []
	return data_manager.database.get_collection_ids_for_rom(romm_id)


## Add a ROM to a collection: apply locally, push to RomM, and queue the write
## for retry when the push fails (offline etc.), mirroring the favourites flow.
func add_rom_to_collection(romm_id: int, collection_id: int, callback: Callable = Callable()) -> void:
	if not data_manager or not data_manager.database.is_database_ready() or collection_id == 0:
		if callback.is_valid():
			callback.call(false)
		return

	var collection_name: String = get_collection(collection_id).get("name", "")

	data_manager.database.add_collection_roms(collection_id, [romm_id])
	collection_membership_changed.emit(collection_id, romm_id)

	if not SystemManager.network.is_online():
		_queue_collection_add(romm_id, collection_id)
		_notify("Saved - will sync to RomM when back online", SystemManager.notifications.Type.WARNING)
		if callback.is_valid():
			callback.call(false)
		return

	SystemManager.network.add_roms_to_collection(collection_id, [romm_id], func(_data, error):
		if error != "":
			_queue_collection_add(romm_id, collection_id)
			_notify("Saved - will sync to RomM when back online", SystemManager.notifications.Type.WARNING)
		else:
			_notify("Added to " + collection_name if collection_name != "" else "Added to collection", SystemManager.notifications.Type.SUCCESS)
		if callback.is_valid():
			callback.call(error == "")
	)


func _queue_collection_add(romm_id: int, collection_id: int) -> void:
	data_manager.database.queue_pending_props(romm_id, COLLECTION_ADD_KIND_PREFIX + str(collection_id), {})


func _notify(message: String, type: int) -> void:
	if SystemManager.notifications:
		SystemManager.notifications.show_notification(message, type)
