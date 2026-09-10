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
}
var sync_index: Array = []

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


func save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(settings, "  "))
		f.close()


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


func load_sync_index() -> void:
	if FileAccess.file_exists(SYNC_INDEX_PATH):
		var f := FileAccess.open(SYNC_INDEX_PATH, FileAccess.READ)
		if f:
			var parsed = JSON.parse_string(f.get_as_text())
			if parsed is Array:
				sync_index = parsed
			f.close()


func save_sync_index() -> void:
	var f := FileAccess.open(SYNC_INDEX_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(sync_index, "  "))
		f.close()


func find_index_entry(local_id: String) -> Dictionary:
	for e in sync_index:
		if e.get("local_id", "") == local_id:
			return e
	return {}


func upsert_index_entry(local_id: String, hash: String, cloud_asset_id: int, media_type: String, mtime: int, size: int) -> void:
	var found := false
	for e in sync_index:
		if e.get("local_id", "") == local_id:
			e["hash"] = hash
			e["cloud_asset_id"] = cloud_asset_id
			e["media_type"] = media_type
			e["mtime"] = mtime
			e["size"] = size
			found = true
			break
	if not found:
		sync_index.append({
			"local_id": local_id,
			"hash": hash,
			"cloud_asset_id": cloud_asset_id,
			"media_type": media_type,
			"mtime": mtime,
			"size": size,
		})
	save_sync_index()
