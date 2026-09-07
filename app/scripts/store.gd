extends Node
## Settings and local sync index persistence under user:// (JSON only).

const SETTINGS_PATH := "user://settings.json"
const SYNC_INDEX_PATH := "user://sync_index.json"

var settings: Dictionary = {
	"server_url": "",
	"token": "",
	"master_pin_hash": "",
	"master_pin_salt": "",
	"last_cursor": 0,
	"cache_clean_enabled": true,
	"cache_min_free_mb": 1024,
	"pending_deletes": [],
}
var sync_index: Array = []


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


func save_settings() -> void:
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(settings, "  "))
		f.close()


func server_url() -> String:
	return str(settings.get("server_url", ""))


func token() -> String:
	return str(settings.get("token", ""))


func set_server_url(v: String) -> void:
	settings["server_url"] = v.strip_edges().trim_suffix("/")
	save_settings()


func set_token(v: String) -> void:
	settings["token"] = v.strip_edges()
	save_settings()


func is_configured() -> bool:
	return server_url() != "" and token() != ""


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
