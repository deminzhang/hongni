extends Node
## Settings and local sync index persistence under user:// (JSON only).

const SETTINGS_PATH := "user://settings.json"
const SYNC_INDEX_PATH := "user://sync_index.json"

var settings: Dictionary = {
	# Server nodes in priority order (index 0 wins): [{name, url, token}].
	"servers": [],
	"master_pin_hash": "",
	"master_pin_salt": "",
	"last_cursor": 0,
	"cache_clean_enabled": true,
	"cache_min_free_mb": 1024,
	"pending_deletes": [],
	# Album covers this device picked: album id (String) -> asset id (int).
	"album_covers": {},
	# Cloud assets pinned against the device-delete mirror: asset id (String) ->
	# true. Deleting a photo from the system gallery normally deletes the cloud
	# copy too; pinning is the explicit "本机删掉、云端留着" opt-out.
	"keep_assets": {},
}
var sync_index: Array = []
# sync_index keyed by local_id, rebuilt lazily after any mutation. A sync looks
# an entry up once per scanned file, and the device gallery holds thousands, so
# a linear scan there would make the whole pass quadratic.
var _index_by_id: Dictionary = {}
var _index_stale := true

# Index into servers() of the node that answered last: requests try it first,
# then the remaining nodes in priority order. Volatile (never persisted), so a
# fresh launch always retries from the top of the priority list.
var active_server: int = 0


func _ready() -> void:
	load_settings()
	load_sync_index()


func load_settings() -> void:
	if FileAccess.file_exists(SETTINGS_PATH):
		var f := FileAccess.open(SETTINGS_PATH, FileAccess.READ)
		if f:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary:
				settings = parsed
			f.close()
	if _migrate_legacy_server():
		save_settings()


## Older settings held a single `server_url`/`token` pair. Fold it into the
## node list as the sole (highest priority) node and drop the legacy keys.
## Returns true when the settings dict was rewritten and needs persisting.
func _migrate_legacy_server() -> bool:
	var raw = settings.get("servers", [])
	var list: Array = raw if raw is Array else []
	var legacy_url := str(settings.get("server_url", "")).strip_edges()
	var changed := settings.has("server_url") or settings.has("token")
	if list.is_empty() and legacy_url != "":
		list = [{"name": "", "url": legacy_url, "token": str(settings.get("token", ""))}]
	settings.erase("server_url")
	settings.erase("token")
	var cleaned := _normalize(list)
	settings["servers"] = cleaned
	return changed or JSON.stringify(cleaned) != JSON.stringify(list)


## Persists the settings JSON now, or marks them dirty when a batch is open.
func save_settings() -> void:
	_settings_dirty = true
	if _batch_depth == 0:
		_write_settings()


func _write_settings() -> void:
	_settings_dirty = false
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(settings, "  "))
		f.close()


# --- Batched persistence -----------------------------------------------------
#
# The in-memory state is what the running session reads, so a write can wait: a
# sync pass touches the index once per file, and writing the whole array each
# time is O(n²) bytes for a gallery of any size (the large-file end of this app's
# target). begin_batch()/end_batch() around a loop collapses that into one write;
# nesting is counted, so callers can wrap freely.
#
# Losing an unflushed write is safe by construction: an index entry that never
# reached disk is simply re-linked (or re-uploaded and deduplicated server-side)
# on the next pass, and settings fall back to their previous value — the failure
# direction is extra work, never lost photos.

var _batch_depth := 0
var _settings_dirty := false
var _index_dirty := false


func begin_batch() -> void:
	_batch_depth += 1


func end_batch() -> void:
	_batch_depth = maxi(0, _batch_depth - 1)
	if _batch_depth == 0:
		flush()


## Writes whatever the open batch left pending. Called automatically when the
## innermost batch closes and when the autoload goes away.
func flush() -> void:
	if _settings_dirty:
		_write_settings()
	if _index_dirty:
		_write_sync_index()


func _exit_tree() -> void:
	flush()


## A backgrounded app can be killed without further notice, so what an open batch
## is still holding gets persisted when the platform takes the app away.
func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED or what == NOTIFICATION_WM_CLOSE_REQUEST:
		flush()


## Server nodes, highest priority first. Always returns an Array of normalized
## {name, url, token} dictionaries (a copy: mutate through set_servers()).
func servers() -> Array:
	var raw = settings.get("servers", [])
	return raw.duplicate(true) if raw is Array else []


## Stores the node list (order == priority) and resets the sticky node choice.
func set_servers(list: Array) -> void:
	settings["servers"] = _normalize(list)
	active_server = 0
	save_settings()


## The node at `index`, clamped into range; {} when nothing is configured.
## Returns the stored dictionary — callers must treat it as read-only.
func server_at(index: int) -> Dictionary:
	var list = settings.get("servers", [])
	if not (list is Array) or list.is_empty():
		return {}
	return list[clampi(index, 0, list.size() - 1)]


## Where requests go first: the node that answered last (fallback: top priority).
func server_url() -> String:
	return str(server_at(active_server).get("url", ""))


func token() -> String:
	return str(server_at(active_server).get("token", ""))


## Marks the node index that just answered, so the next request hits it first.
func set_active_server(index: int) -> void:
	var list = settings.get("servers", [])
	var count: int = list.size() if list is Array else 0
	active_server = clampi(index, 0, maxi(0, count - 1))


## Configured enough to talk to a server: any node carrying address + token.
func is_configured() -> bool:
	for node in servers():
		if str(node.get("url", "")) != "" and str(node.get("token", "")) != "":
			return true
	return false


## Trimmed entries only: nodes without an address are dropped, a blank name
## falls back to the address host (so every row has something to show).
func _normalize(list: Array) -> Array:
	var out: Array = []
	for e in list:
		if not (e is Dictionary):
			continue
		var url := str(e.get("url", "")).strip_edges().trim_suffix("/")
		if url == "":
			continue
		var name := str(e.get("name", "")).strip_edges()
		out.append({
			"name": name if name != "" else _default_name(url),
			"url": url,
			"token": str(e.get("token", "")).strip_edges(),
		})
	return out


static func _default_name(url: String) -> String:
	var sep := url.find("://")
	return url.substr(sep + 3) if sep >= 0 else url


# --- Album covers (device-local) ---------------------------------------------

## The cover album `album_id` shows on this device: the asset the user picked via
## ⋮ 菜单 → 设为相册封面, 0 when never set (= the album's newest photo). Covers
## are deliberately local — the server has no cover field — so the choice stays
## on this device and the album's membership is untouched.
func album_cover(album_id: int) -> int:
	var covers = settings.get("album_covers", {})
	if not (covers is Dictionary):
		return 0
	var v = covers.get(str(album_id))
	return int(v) if v != null else 0


## Records `asset_id` as this album's cover and persists it; `asset_id` <= 0
## clears the choice (back to the album's newest photo).
func set_album_cover(album_id: int, asset_id: int) -> void:
	if album_id <= 0:
		return
	var covers: Dictionary = settings.get("album_covers", {})
	if not (covers is Dictionary):
		covers = {}
	if asset_id > 0:
		covers[str(album_id)] = asset_id
	else:
		covers.erase(str(album_id))
	settings["album_covers"] = covers
	save_settings()


## Whether cloud asset `asset_id` is pinned against the device-delete mirror —
## i.e. the user asked for it to outlive the device file.
func is_kept(asset_id: int) -> bool:
	var kept = settings.get("keep_assets", {})
	return kept is Dictionary and kept.has(str(asset_id))


## Pins or unpins `asset_id` and returns the resulting state.
func set_kept(asset_id: int, keep: bool) -> bool:
	if asset_id <= 0:
		return false
	var kept = settings.get("keep_assets", {})
	if not (kept is Dictionary):
		kept = {}
	if keep:
		kept[str(asset_id)] = true
	else:
		kept.erase(str(asset_id))
	settings["keep_assets"] = kept
	save_settings()
	return keep


func load_sync_index() -> void:
	if FileAccess.file_exists(SYNC_INDEX_PATH):
		var f := FileAccess.open(SYNC_INDEX_PATH, FileAccess.READ)
		if f:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Array:
				sync_index = parsed
			f.close()
	_index_stale = true


## Persists the index now, or marks it dirty when a batch is open (see
## begin_batch). The index is machine state, so it is written compactly.
func save_sync_index() -> void:
	_index_dirty = true
	if _batch_depth == 0:
		_write_sync_index()


func _write_sync_index() -> void:
	_index_dirty = false
	var f := FileAccess.open(SYNC_INDEX_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(sync_index))
		f.close()


## The sync index keyed by local_id (rebuilt after any mutation).
func _index_by_local_id() -> Dictionary:
	if _index_stale:
		_index_by_id.clear()
		for e in sync_index:
			_index_by_id[str(e.get("local_id", ""))] = e
		_index_stale = false
	return _index_by_id


func find_index_entry(local_id: String) -> Dictionary:
	return _index_by_local_id().get(local_id, {})


## Records (or refreshes) the entry for `local_id`. `stamp` is the change
## detector: the file mtime on desktop, MediaStore's DATE_TAKEN on Android —
## compared together with `size` to skip sources that have not changed.
func upsert_index_entry(local_id: String, hash: String, cloud_asset_id: int, media_type: String, stamp: int, size: int) -> void:
	# The map holds the same Dictionary instances as the array, so mutating the
	# entry found here updates sync_index in place and the map stays valid.
	var by_id := _index_by_local_id()
	var e: Dictionary = by_id.get(local_id, {})
	if e.is_empty():
		e = {"local_id": local_id}
		sync_index.append(e)
		by_id[local_id] = e
	e["hash"] = hash
	e["cloud_asset_id"] = cloud_asset_id
	e["media_type"] = media_type
	e["stamp"] = stamp
	e["size"] = size
	save_sync_index()


## Drops the entry for `local_id` and returns it ({} when there was none).
func erase_index_entry(local_id: String) -> Dictionary:
	for i in sync_index.size():
		if str(sync_index[i].get("local_id", "")) == local_id:
			var e: Dictionary = sync_index[i]
			sync_index.remove_at(i)
			_index_stale = true
			save_sync_index()
			return e
	return {}


## Drops the entry pointing at cloud asset `cloud_asset_id`, if any, and returns
## it ({} when the asset has no local source).
func erase_index_by_cloud_id(cloud_asset_id: int) -> Dictionary:
	if cloud_asset_id <= 0:
		return {}
	for i in sync_index.size():
		if int(sync_index[i].get("cloud_asset_id", 0)) == cloud_asset_id:
			var e: Dictionary = sync_index[i]
			sync_index.remove_at(i)
			_index_stale = true
			save_sync_index()
			return e
	return {}


## Replaces the whole index (bulk migration) and persists it.
func replace_sync_index(entries: Array) -> void:
	sync_index = entries
	_index_stale = true
	save_sync_index()

