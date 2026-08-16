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


func update_save_sync_record(romm_id: int, emulator_id: String, file_name: String, file_path: String, last_synced_at: String, remote_save_id: int, slot: String = "", local_hash: String = "", server_hash: String = "", local_size: int = 0) -> bool:
	"""Insert or update a save sync record (atomic DELETE+INSERT in one transaction)."""
	if not data_manager.database.is_database_ready():
		return false

	var delete_bindings: Array = [romm_id, emulator_id, file_name]
	var delete_query = "DELETE FROM save_sync WHERE romm_id = ? AND emulator_id = ? AND file_name = ?"
	if slot != "":
		delete_query += " AND slot = ?"
		delete_bindings.append(slot)
	else:
		delete_query += " AND (slot IS NULL OR slot = '')"

	var insert_bindings: Array = [romm_id, emulator_id, file_name, file_path, last_synced_at, remote_save_id, local_hash, server_hash, local_size]
	var insert_query = """
		INSERT INTO save_sync (romm_id, emulator_id, file_name, file_path, last_synced_at, remote_save_id, slot, local_hash, server_hash, local_size)
		VALUES (?, ?, ?, ?, ?, ?, %s, ?, ?, ?)
	""" % ("?" if slot != "" else "NULL")
	if slot != "":
		insert_bindings.insert(6, slot)

	data_manager.database.lock()
	if not data_manager.database.query_bool_unlocked("BEGIN IMMEDIATE TRANSACTION"):
		data_manager.database.unlock()
		return false
	var delete_ok = data_manager.database.query_bool_unlocked(delete_query, delete_bindings)
	var insert_ok = delete_ok and data_manager.database.query_bool_unlocked(insert_query, insert_bindings)
	if insert_ok:
		var commit_ok = data_manager.database.query_bool_unlocked("COMMIT")
		if not commit_ok:
			data_manager.database.query_bool_unlocked("ROLLBACK")
		data_manager.database.unlock()
		return commit_ok
	data_manager.database.query_bool_unlocked("ROLLBACK")
	data_manager.database.unlock()
	return false


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
