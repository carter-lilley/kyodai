extends Manager
class_name SaveSyncSubManager

var data_manager: Node


func _ready():
	data_manager = get_parent()


func get_save_sync_records(romm_id: int, emulator_id: String = "") -> Array[Dictionary]:
	"""Get save sync records for a game. Optionally filter by emulator."""
	if not data_manager.database.is_database_ready():
		return []
	var bindings: Array = [romm_id]
	var query = "SELECT * FROM save_sync WHERE romm_id = ?"
	if emulator_id != "":
		query += " AND emulator_id = ?"
		bindings.append(emulator_id)
	var query_result = data_manager.database.query_array(query, bindings)
	return query_result.duplicate()


func update_save_sync_record(romm_id: int, emulator_id: String, file_name: String, file_path: String, last_synced_at: String, remote_save_id: int, slot: String = "") -> bool:
	"""Insert or update a save sync record."""
	if not data_manager.database.is_database_ready():
		return false

	var delete_bindings: Array = [romm_id, emulator_id, file_name]
	var delete_query = "DELETE FROM save_sync WHERE romm_id = ? AND emulator_id = ? AND file_name = ?"
	if slot != "":
		delete_query += " AND slot = ?"
		delete_bindings.append(slot)
	else:
		delete_query += " AND (slot IS NULL OR slot = '')"
	data_manager.database.query_bool(delete_query, delete_bindings)

	var insert_bindings: Array = [romm_id, emulator_id, file_name, file_path, last_synced_at, remote_save_id]
	var insert_query = """
		INSERT INTO save_sync (romm_id, emulator_id, file_name, file_path, last_synced_at, remote_save_id, slot)
		VALUES (?, ?, ?, ?, ?, ?, %s)
	""" % ("?" if slot != "" else "NULL")
	if slot != "":
		insert_bindings.append(slot)
	return data_manager.database.query_bool(insert_query, insert_bindings)


func delete_save_sync_record(romm_id: int, emulator_id: String, file_name: String, slot: String = "") -> bool:
	"""Delete a save sync record."""
	if not data_manager.database.is_database_ready():
		return false
	var bindings: Array = [romm_id, emulator_id, file_name]
	var query = "DELETE FROM save_sync WHERE romm_id = ? AND emulator_id = ? AND file_name = ?"
	if slot != "":
		query += " AND slot = ?"
		bindings.append(slot)
	else:
		query += " AND (slot IS NULL OR slot = '')"
	return data_manager.database.query_bool(query, bindings)
