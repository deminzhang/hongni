extends Node
## Unified two-way sync engine. Every local photo under user://photos is backed
## up to the cloud; remote changes are pulled into the local viewing cache
## (thumbnail on create, original on demand). Local storage is a re-usable
## cache: space pressure may drop cached originals and already-backed-up photos
## sources while the cloud keeps the authoritative copy. Deletes are two-way:
## user-initiated deletes remove locally and soft-delete the cloud asset into
## the recycle bin; if the cloud is unreachable the delete is queued as a
## tombstone and retried on the next sync.

signal progress_changed(done: int, total: int)
signal backup_finished(success: bool, message: String)

const PHOTOS_DIR := "user://photos"

var running := false


func _ready() -> void:
	_ensure_dirs()


func _ensure_dirs() -> void:
	if not DirAccess.dir_exists_absolute(PHOTOS_DIR):
		DirAccess.make_dir_recursive_absolute(PHOTOS_DIR)


## Enumerate local sources: files under user://photos/.
## Each entry: {path, local_id, name, media_type, mtime, size, taken_at}.
func scan_sources() -> Array:
	var results: Array = []
	var dir := DirAccess.open(PHOTOS_DIR)
	if dir == null:
		return results
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir() and not name.begins_with("."):
			var path := PHOTOS_DIR + "/" + name
			var f := FileAccess.open(path, FileAccess.READ)
			if f:
				var size := f.get_length()
				f.close()
				var mtime := int(FileAccess.get_modified_time(path))
				results.append({
					"path": path,
					"local_id": "photos/" + name,
					"name": name,
					"media_type": _media_type_for(name),
					"mtime": mtime,
					"size": size,
					"taken_at": mtime,
				})
		name = dir.get_next()
	dir.list_dir_end()
	return results


## Unified sync: upload local new/changed, flush queued delete tombstones, pull
## remote changes, then reclaim space at the end.
func run_sync() -> void:
	if running:
		return
	running = true
	var uploaded := await _upload_phase()
	await _process_pending_deletes()
	await _pull_changes()
	running = false
	Cache.enforce_cache()
	backup_finished.emit(true, "同步完成：上传 %d" % uploaded)


## Uploads local new/changed files, returning the number uploaded. Uses the
## same dedup logic as before — the cloud is authoritative for content.
func _upload_phase() -> int:
	var sources := scan_sources()
	var total := sources.size()
	var done := 0
	var uploaded := 0
	progress_changed.emit(done, total)

	for s in sources:
		var local_id: String = s["local_id"]
		var mtime: int = s["mtime"]
		var size: int = s["size"]
		var existing := Store.find_index_entry(local_id)
		if not existing.is_empty():
			if existing.get("deleted", false):
				# Tombstoned (already deleted locally) — never re-upload.
				done += 1
				progress_changed.emit(done, total)
				continue
			if existing.get("mtime", -1) == mtime and existing.get("size", -1) == size:
				done += 1
				progress_changed.emit(done, total)
				continue

		var hash := _sha256_file(s["path"])
		if hash == "":
			done += 1
			progress_changed.emit(done, total)
			continue

		var asset_id := 0
		var check: Dictionary = await Api.asset_by_hash(hash)
		if check.get("found", false):
			asset_id = int(check["asset"]["id"])
		else:
			# Land in the active trunk's 散照 bucket so the photo is visible
			# under 全部 (falls back to no-album when the bucket is unresolved).
			var up: Dictionary = await Api.upload_asset(s["path"], s["name"], s["media_type"], s["taken_at"], Api.scatter_album_id)
			if up.has("error"):
				done += 1
				progress_changed.emit(done, total)
				continue
			asset_id = int(up["data"]["id"])
			uploaded += 1

		Store.upsert_index_entry(local_id, hash, asset_id, s["media_type"], mtime, size)
		done += 1
		progress_changed.emit(done, total)

	return uploaded


## Retries queued cloud deletes (tombstones). Keeps them when still offline.
func _process_pending_deletes() -> void:
	var pending = Store.settings.get("pending_deletes", [])
	if not (pending is Array) or pending.is_empty():
		return
	var remaining: Array = []
	for cid in pending:
		var r: Dictionary = await Api.delete_asset(int(cid))
		if r.has("error"):
			remaining.append(cid)
	Store.settings["pending_deletes"] = remaining
	Store.save_settings()


## Pulls remote changes since last_cursor. asset create -> cache thumbnail (the
## original is fetched on demand by the viewer); asset delete -> drop local
## artifacts (thumbnail is kept for recycle-bin browsing).
func _pull_changes() -> void:
	var cursor := int(Store.settings.get("last_cursor", 0))
	var r: Dictionary = await Api.sync_changes(cursor)
	if r.has("error"):
		return
	var changes: Array = r["data"]["changes"]
	var max_seq := cursor
	for c in changes:
		var seq := int(c["seq"])
		if seq > max_seq:
			max_seq = seq
		var entity: String = c["entity"]
		var op: String = c["op"]
		var eid := int(c["entity_id"])
		if entity == "asset":
			if op == "create":
				await _cache_remote_thumb(eid)
			elif op == "delete":
				remove_local(eid)
		# album / album_asset changes carry no local copy to update; the UI
		# re-fetches album membership itself.
	Store.settings["last_cursor"] = max_seq
	Store.save_settings()


func _cache_remote_thumb(asset_id: int) -> void:
	if Cache.thumb_cached(asset_id):
		return
	var t: Dictionary = await Api.fetch_thumb(asset_id)
	if t.has("error"):
		return
	Cache.save_thumb(asset_id, t["body"])


## Removes the local artifacts of a cloud asset (photos source file + cached
## original), keeping the thumbnail so grid / recycle-bin browsing still works.
func remove_local(cloud_id: int) -> void:
	for e in Store.sync_index:
		if int(e.get("cloud_asset_id", 0)) == cloud_id:
			var local_id: String = e.get("local_id", "")
			var path := PHOTOS_DIR + "/" + local_id.trim_prefix("photos/")
			if FileAccess.file_exists(path):
				DirAccess.remove_absolute(path)
			Store.sync_index.erase(e)
			Store.save_sync_index()
			break
	Cache.remove_original_by_id(cloud_id)


## Queues a cloud delete as a tombstone (offline path): local files are dropped
## now and the cloud soft-delete is retried on the next sync.
func tombstone_delete(cloud_id: int) -> void:
	remove_local(cloud_id)
	var pending = Store.settings.get("pending_deletes", [])
	if not (pending is Array):
		pending = []
	if not pending.has(cloud_id):
		pending.append(cloud_id)
	Store.settings["pending_deletes"] = pending
	Store.save_settings()


func _media_type_for(name: String) -> String:
	match name.get_extension().to_lower():
		"mp4", "mov", "mkv", "webm", "avi", "m4v", "3gp":
			return "video"
		_:
			return "image"


func _sha256_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not f.eof_reached():
		ctx.update(f.get_buffer(1024 * 1024))
	var digest := ctx.finish()
	f.close()
	return digest.hex_encode()
