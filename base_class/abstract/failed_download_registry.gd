class_name FailedDownloadRegistry
extends RefCounted

## Negative cache for cover URLs that failed to download. Replaces the bare
## static Dictionary with a real registry: TTL with lazy expiry, insertion-cap
## with oldest-first eviction, and explicit invalidation on network-state
## change (reconnect clears failures so dead art retries immediately).
##
## Shared by all cards via CardMediaLoader's static instance and queryable by
## placeholder rendering, so failed art gets its placeholder color immediately
## instead of a retry storm on every recycle.

const DEFAULT_TTL_SEC: int = 86400  # 1 day
const DEFAULT_MAX_ENTRIES: int = 512

## url -> unix failure time. Insertion-ordered: front key = oldest failure.
var _entries: Dictionary = {}
var ttl_sec: int = DEFAULT_TTL_SEC
var max_entries: int = DEFAULT_MAX_ENTRIES

func _init(p_ttl_sec: int = DEFAULT_TTL_SEC, p_max_entries: int = DEFAULT_MAX_ENTRIES) -> void:
	ttl_sec = p_ttl_sec
	max_entries = p_max_entries

func is_failed(url: String) -> bool:
	var t: float = _entries.get(url, 0.0)
	if t <= 0.0:
		return false
	if Time.get_unix_time_from_system() - t >= ttl_sec:
		# Lazy expiry: aged-out entries stop counting toward the cap.
		_entries.erase(url)
		return false
	return true

func mark_failed(url: String) -> void:
	if url == "":
		return
	_entries.erase(url)  # refresh recency on re-failure
	while _entries.size() >= max_entries:
		_entries.erase(_entries.keys()[0])
	_entries[url] = Time.get_unix_time_from_system()

func forget(url: String) -> void:
	_entries.erase(url)

func clear() -> void:
	_entries.clear()

func size() -> int:
	return _entries.size()
