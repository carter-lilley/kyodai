extends Manager
class_name CollectionSubManager

## Manages RomM collections: sync from server, local persistence, and queries.

var data_manager: Node

signal collections_synced(success: bool, message: String)

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
		if not error.is_empty():
			push_error("[CollectionSubManager] Failed to sync collections: " + error)
			_is_syncing = false
			if callback.is_valid():
				callback.call(false, error)
			collections_synced.emit(false, error)
			return

		var collections = result.get("collections", []) as Array
		data_manager.database.clear_all_collections()
		for collection in collections:
			_save_collection(collection)

		_is_syncing = false
		print("[CollectionSubManager] Synced %d collections" % collections.size())
		if callback.is_valid():
			callback.call(true, "Synced %d collections" % collections.size())
		collections_synced.emit(true, "Synced %d collections" % collections.size())
	)


func _save_collection(collection: Dictionary) -> void:
	var id: int = collection.get("id", 0)
	if id == 0:
		return

	var name: String = collection.get("name", "")
	if name.strip_edges() == "":
		return

	data_manager.database.save_collection({
		"id": id,
		"name": collection.get("name", ""),
		"description": collection.get("description", ""),
		"is_public": collection.get("is_public", false),
		"is_favorite": collection.get("is_favorite", false),
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


# Future: add/remove ROMs from a collection and push to server.
# func add_roms_to_collection(romm_id: int, rom_ids: Array[int], callback: Callable = Callable()) -> void:
# func remove_roms_from_collection(romm_id: int, rom_ids: Array[int], callback: Callable = Callable()) -> void:
