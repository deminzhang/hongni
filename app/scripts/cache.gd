extends Node
## Offline cache singleton (autoload "Cache"). Owns everything under
## user://cache and keeps it self-managing:
##   - catalog.json: snapshot of the cloud album tree (album list + per-album
##     asset membership) and the last-viewed timestamps used for LRU eviction,
##     so grids / albums can be browsed without a server connection.
##   - thumbs/<asset_id>.jpg: small local thumbnails (grids always render from
##     these; written through on every server thumb fetch).
##   - originals/<asset_id>.<ext>: full-res copies downloaded on demand when an
##     asset is opened, so previously viewed content works offline.
##
## Free-space policy: when enabled and free space on this volume drops below
## the configured threshold (Store.settings "cache_min_free_mb", default
## 1024 = 1 GiB), cached originals are deleted in least-recently-viewed order
## until free space is back above the threshold. Thumbnails always remain.
## Only cloud-backed originals live here (every entry is downloaded from the
## server by cloud asset id), so deletion never loses the only copy. The device
## gallery is never touched: it belongs to the user and to the system gallery
## app, and this cache is 100 % disposable.

const CACHE_DIR := "user://cache"
const THUMB_DIR := CACHE_DIR + "/thumbs"
const ORIG_DIR := CACHE_DIR + "/originals"
const CATALOG_PATH := CACHE_DIR + "/catalog.json"

const MB := 1024 * 1024

# Album list as returned by Api.list_albums (trimmed to known keys).
var albums_cache: Array = []
# album_id as String -> Array of asset dicts in server order (id DESC).
var members_cache: Dictionary = {}
# asset_id as String -> last-viewed unix time (int).
var viewed: Dictionary = {}

var _save_pending := false


func _ready() -> void:
	_ensure_dirs()
	_load_catalog()


func _ensure_dirs() -> void:
	for d in [THUMB_DIR, ORIG_DIR]:
		if not DirAccess.dir_exists_absolute(d):
			DirAccess.make_dir_recursive_absolute(d)


# --- catalog persistence -----------------------------------------------------

func _load_catalog() -> void:
	if not FileAccess.file_exists(CATALOG_PATH):
		return
	var f := FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if not (parsed is Dictionary):
		return
	if parsed.get("albums") is Array:
		albums_cache = parsed["albums"]
	if parsed.get("members") is Dictionary:
		members_cache = parsed["members"]
	if parsed.get("viewed") is Dictionary:
		viewed = parsed["viewed"]


func _queue_save() -> void:
	if _save_pending:
		return
	_save_pending = true
	_save_catalog.call_deferred()


func _save_catalog() -> void:
	_save_pending = false
	var f := FileAccess.open(CATALOG_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({
		"albums": albums_cache,
		"members": members_cache,
		"viewed": viewed,
	}))
	f.close()


# --- catalog write-through (online) / read-back (offline) --------------------

func snapshot_albums(albums: Array) -> void:
	albums_cache = _strip_albums(albums)
	_queue_save()


## Writes one album's member snapshot. `filter` distinguishes the virtual views
## that reuse an album id (the 视频 card is the trunk with filter=videos), so a
## filtered view never overwrites the plain album snapshot.
func snapshot_album_assets(album_id: int, assets: Array, filter: String = "all") -> void:
	members_cache[_member_key(album_id, filter)] = _strip_assets(assets)
	_queue_save()


func offline_albums() -> Array:
	return albums_cache


func offline_assets(album_id: int, filter: String = "all") -> Array:
	var list: Array = members_cache.get(_member_key(album_id, filter), [])
	return list


## Plain albums keep the historical bare-id key, so catalog.json written by an
## older build still reads back.
static func _member_key(album_id: int, filter: String) -> String:
	return str(album_id) if filter == "all" else "%d:%s" % [album_id, filter]


# --- last-viewed tracking (LRU input) ---------------------------------------

func mark_viewed(asset_id: int) -> void:
	if asset_id <= 0:
		return
	var now := int(Time.get_unix_time_from_system())
	if int(viewed.get(str(asset_id), 0)) == now:
		return
	viewed[str(asset_id)] = now
	_queue_save()


func last_viewed(asset_id: int) -> int:
	return int(viewed.get(str(asset_id), 0))


# --- thumbnail cache ---------------------------------------------------------

func thumb_path(asset_id: int) -> String:
	return THUMB_DIR + "/%d.jpg" % asset_id


func thumb_cached(asset_id: int) -> bool:
	return FileAccess.file_exists(thumb_path(asset_id))


func save_thumb(asset_id: int, body: PackedByteArray) -> void:
	if asset_id <= 0 or body.is_empty():
		return
	var f := FileAccess.open(thumb_path(asset_id), FileAccess.WRITE)
	if f:
		f.store_buffer(body)
		f.close()


func read_thumb(asset_id: int) -> PackedByteArray:
	var f := FileAccess.open(thumb_path(asset_id), FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var body := f.get_buffer(f.get_length())
	f.close()
	return body


# --- full-res original cache -------------------------------------------------

func original_path(asset_id: int, original_name: String, ext: String = "") -> String:
	# Prefer the recorded extension so the cache filename keeps its type even
	# after the display name is renamed without an extension.
	if ext == "":
		ext = original_name.get_extension().to_lower()
	var fname := str(asset_id) + ("." + ext if ext != "" else ".bin")
	return ORIG_DIR + "/" + fname


func original_cached(asset_id: int, original_name: String, ext: String = "") -> bool:
	return FileAccess.file_exists(original_path(asset_id, original_name, ext))


func save_original(asset_id: int, original_name: String, body: PackedByteArray, ext: String = "") -> void:
	if asset_id <= 0 or body.is_empty():
		return
	var f := FileAccess.open(original_path(asset_id, original_name, ext), FileAccess.WRITE)
	if f:
		f.store_buffer(body)
		f.close()
	# Re-evaluate free space at the end of the frame (cheap: deletes only when
	# below the configured threshold).
	enforce_cache.call_deferred()


## Like save_original but writes the (possibly large) body on a background
## thread; callers `await` it. The main loop stays live during the write.
func save_original_bg(asset_id: int, original_name: String, body: PackedByteArray, ext: String = "") -> void:
	if asset_id <= 0 or body.is_empty():
		return
	var path := original_path(asset_id, original_name, ext)
	var done := [false]
	var t := Thread.new()
	t.start(func() -> void:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_buffer(body)
			f.close()
		done[0] = true
	)
	while not done[0]:
		await get_tree().process_frame
	t.wait_to_finish()
	enforce_cache.call_deferred()


func read_original(asset_id: int, original_name: String, ext: String = "") -> PackedByteArray:
	var f := FileAccess.open(original_path(asset_id, original_name, ext), FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var body := f.get_buffer(f.get_length())
	f.close()
	return body


## Removes every cached original for a cloud asset id (originals/<id>.*) without
## touching its thumbnail, so thumbnail grid / recycle-bin browsing still works.
func remove_original_by_id(asset_id: int) -> void:
	if asset_id <= 0:
		return
	var dir := DirAccess.open(ORIG_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if n.get_basename() == str(asset_id):
			DirAccess.remove_absolute(ORIG_DIR + "/" + n)
		n = dir.get_next()
	dir.list_dir_end()


## Removes the cached thumbnail (used when permanently deleting a recycle-bin
## asset; thumbnails are otherwise retained).
func remove_thumb_by_id(asset_id: int) -> void:
	if asset_id <= 0:
		return
	if FileAccess.file_exists(thumb_path(asset_id)):
		DirAccess.remove_absolute(thumb_path(asset_id))


# --- free-space policy -------------------------------------------------------

func free_space_bytes() -> int:
	var dir := DirAccess.open(CACHE_DIR)
	if dir == null:
		return 0
	return dir.get_space_left()


## LRU eviction. Deletes cached originals oldest-viewed-first until free space
## is back above the configured threshold (or no originals remain). Never
## removes thumbnails or the catalog.
func enforce_cache() -> void:
	if not Store.settings.get("cache_clean_enabled", true):
		return
	var threshold := int(Store.settings.get("cache_min_free_mb", 1024)) * MB
	var free := free_space_bytes()
	if free <= 0 or free >= threshold:
		return

	var dir := DirAccess.open(ORIG_DIR)
	if dir == null:
		return
	var items: Array = []
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir() and n.get_basename().is_valid_int():
			var asset_id := n.get_basename().to_int()
			items.append({
				"path": ORIG_DIR + "/" + n,
				"ts": last_viewed(asset_id),
			})
		n = dir.get_next()
	dir.list_dir_end()

	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["ts"] < b["ts"])

	for it in items:
		if free >= threshold:
			break
		if DirAccess.remove_absolute(it["path"]) == OK:
			free = free_space_bytes()

	# Still short: the device-side caches are regenerable too (a device thumbnail
	# is decoded again, a device video copy re-read from MediaStore), so they are
	# evictable under the same policy. DeviceMedia owns those directories and does
	# the removing; this singleton keeps owning the policy.
	if free < threshold:
		DeviceMedia.evict_cached_files(threshold)


## Cache stats for the settings screen: {count, bytes}.
func originals_stats() -> Dictionary:
	var count := 0
	var total := 0
	var dir := DirAccess.open(ORIG_DIR)
	if dir:
		dir.list_dir_begin()
		var n := dir.get_next()
		while n != "":
			if not dir.current_is_dir():
				var f := FileAccess.open(ORIG_DIR + "/" + n, FileAccess.READ)
				if f:
					total += f.get_length()
					f.close()
					count += 1
			n = dir.get_next()
		dir.list_dir_end()
	return {"count": count, "bytes": total}


# --- field trimming (keeps catalog.json compact) -----------------------------

func _strip_albums(list: Array) -> Array:
	var out: Array = []
	for a in list:
		if a is Dictionary:
			out.append({
				"id": int(a.get("id", 0)),
				"name": str(a.get("name", "")),
				"parent_id": a.get("parent_id"),
				"is_hidden": int(a.get("is_hidden", 0)),
				"sync_mode": str(a.get("sync_mode", "backup")),
			})
	return out


func _strip_assets(list: Array) -> Array:
	var out: Array = []
	for a in list:
		if a is Dictionary:
			out.append({
				"id": int(a.get("id", 0)),
				"hash": str(a.get("hash", "")),
				"original_name": str(a.get("original_name", "")),
				"ext": str(a.get("ext", "")),
				"media_type": str(a.get("media_type", "image")),
				"mime_type": str(a.get("mime_type", "")),
				"size": int(a.get("size", 0)),
				"width": a.get("width"),
				"height": a.get("height"),
				"taken_at": a.get("taken_at"),
				"created_at": int(a.get("created_at", 0)),
			})
	return out
