class_name ShufflerBag
extends RefCounted

## Manages the shuffler's random bag of games and the reroll candidate pool.

enum EntryStatus { QUEUED, DOWNLOADING, PREPARING, READY, FAILED }

var entries: Array[Dictionary] = []
var candidates: Array[GameResource] = []

# Candidate pool state. The pool is filled in the background by
# ShufflerSubManager after the session starts; pickers must wait for
# candidates_building to clear before drawing.
var candidates_built: bool = false
var candidates_building: bool = false

func build(games: Array[GameResource], bag_size: int) -> void:
	entries.clear()
	candidates.clear()
	candidates_built = false
	candidates_building = false

	var added_ids: Array[int] = []
	for game in games:
		if game.romm_id in added_ids:
			continue
		added_ids.append(game.romm_id)
		entries.append(_create_entry(game))
		if entries.size() >= bag_size:
			break


func _create_entry(game: GameResource) -> Dictionary:
	return {
		"game": game,
		"temp_path": "",
		"pid": -1,
		"started": false,
		"active": false,
		"emulator_id": "",
		"suspend_method": "",
		"status": EntryStatus.QUEUED,
		"download_id": "",
		# Set between _launch_game() and the pid callback firing. Restart/switch
		# must wait for it to clear before relaunching, otherwise the per-game
		# launch guard rejects the relaunch and the shuffler misreads that as a
		# failed launch (spurious skip + late-pid kill).
		"launch_pending": false,
	}


func get_bag_ids() -> Array[int]:
	var ids: Array[int] = []
	for entry in entries:
		ids.append(entry.game.romm_id)
	return ids


func get_ready_indices(exclude_index: int = -1) -> Array[int]:
	var result: Array[int] = []
	for i in range(entries.size()):
		if i == exclude_index:
			continue
		if entries[i].status == EntryStatus.READY:
			result.append(i)
	return result


func pick_random_ready(exclude_index: int = -1) -> int:
	var ready := get_ready_indices(exclude_index)
	if ready.is_empty():
		return -1
	return ready[randi() % ready.size()]


func pick_reroll_candidate(existing_ids: Array[int]) -> GameResource:
	for i in range(candidates.size()):
		if not candidates[i].romm_id in existing_ids:
			var game = candidates[i]
			# Consume the pick: a game that has been in the bag must never
			# become eligible again, even after being rerolled away.
			candidates.remove_at(i)
			return game
	return null


func replace_entry(index: int, game: GameResource, temp_path: String = "") -> void:
	if index < 0 or index >= entries.size():
		return
	entries[index] = _create_entry(game)
	entries[index].temp_path = temp_path
	if temp_path != "" and FileAccess.file_exists(temp_path):
		entries[index].status = EntryStatus.READY
	else:
		entries[index].status = EntryStatus.QUEUED


func is_empty() -> bool:
	return entries.is_empty()


func size() -> int:
	return entries.size()


func has_any_ready() -> bool:
	for entry in entries:
		if entry.status == EntryStatus.READY:
			return true
	return false
