extends Node
## Backup engine, driven by the system gallery (系统相册). Every photo and video
## the device reports — MediaStore on Android, the Pictures folder on desktop —
## is backed up to the cloud and indexed by its device key, so an unchanged item
## is skipped without touching its bytes and content the cloud already holds is
## linked instead of uploaded again.
##
## The device keeps its own storage model untouched: hongni only ever reads it
## (the one exception is an explicit 移动到系统相册 / 存到相册, which writes a copy
## into Pictures/红泥), and the system gallery app works with or without hongni.
## The cloud holds the backups, content-addressed and deduplicated, filed into
## the album mirroring the device album each item came from.
##
## Deletes mirror the device: an indexed item the gallery no longer reports is
## soft-deleted into the cloud's 7-day recycle bin. Remote changes are pulled
## into the local viewing cache (thumbnail on create, original on demand), and
## deletes that happened offline are retried from the tombstone queue.

signal progress_changed(done: int, total: int)
signal backup_finished(success: bool, message: String)

## Index-key prefix for a device item (MediaStore's _ID on Android, the absolute
## path on desktop). Distinguishes device sources from any other index entry.
const DEVICE_PREFIX := "device:"

var running := false


## Index entries written by an older build pointed at user://photos, a staging
## directory nothing writes any more (the system gallery is the upload source).
## They can never match a device item again, so drop them once.
func _ready() -> void:
	var kept: Array = []
	var dropped := 0
	for e in Store.sync_index:
		if str(e.get("local_id", "")).begins_with(DEVICE_PREFIX):
			kept.append(e)
		else:
			dropped += 1
	if dropped > 0:
		Store.replace_sync_index(kept)


# --- Device sources ----------------------------------------------------------

## The index key of one device item.
func device_local_id(key: String) -> String:
	return DEVICE_PREFIX + key


## The cloud asset this device item is already backed up as, 0 when it is not
## (or its upload never completed).
func backed_up_asset_id(item: Dictionary) -> int:
	var e := Store.find_index_entry(device_local_id(DeviceMedia.key_of(item)))
	return int(e.get("cloud_asset_id", 0))


## Everything the device gallery currently holds, as upload sources:
## {item, local_id, taken_at, size}.
func scan_device_sources() -> Array:
	var out: Array = []
	for item in DeviceMedia.scan_items():
		out.append({
			"item": item,
			"local_id": device_local_id(DeviceMedia.key_of(item)),
			"taken_at": int(item.get("taken_at", 0)),
			"size": int(item.get("size", 0)),
		})
	return out


## Cloud-side half of a sync: retry the queued deletes and pull remote changes
## so 红泥相册 / 隐私相册 stay current without a full pass. The album browser runs
## this on entry; uploading the device gallery stays manual (立即同步).
func sync_cloud() -> void:
	if running:
		return
	running = true
	await _process_pending_deletes()
	await _pull_changes()
	running = false


## Backs up ONE device item into the cloud album `album_id`: stages the file,
## hashes it, links an existing blob or uploads it, and records the sync index
## entry — so the grid shows ☁ 已备份 and later syncs skip the item. Returns
## {asset_id, uploaded}: the cloud asset id (0 on failure) and whether bytes were
## actually sent (false when the cloud already held them). The device's own file
## is never touched here.
func upload_device_item(item: Dictionary, album_id: int) -> Dictionary:
	var out := {"asset_id": 0, "uploaded": false}
	var local := await DeviceMedia.materialize(item)
	if local == "":
		return out
	var hash := sha256_file(local)
	var asset_id := 0
	var uploaded := false
	if hash != "":
		var check: Dictionary = await Api.asset_by_hash(hash)
		if check.get("found", false):
			asset_id = int(check["asset"].get("id", 0))
			if album_id > 0:
				await Api.add_asset_to_album(album_id, asset_id)
		else:
			var up: Dictionary = await Api.upload_asset(
				local, str(item.get("display_name", local.get_file())),
				"video" if item.get("is_video", false) else "image",
				int(item.get("taken_at", 0)), album_id
			)
			if not up.has("error"):
				asset_id = int(up["data"].get("id", 0))
				uploaded = true
	DeviceMedia.remove_temp(local)
	if asset_id > 0:
		Store.upsert_index_entry(
			device_local_id(DeviceMedia.key_of(item)), hash, asset_id,
			"video" if item.get("is_video", false) else "image",
			int(item.get("taken_at", 0)), int(item.get("size", 0))
		)
		out["asset_id"] = asset_id
		out["uploaded"] = uploaded
	return out


# --- Sync --------------------------------------------------------------------

## One pass: upload device new/changed, mirror device deletions into the cloud,
## flush queued tombstones, pull remote changes, then reclaim space.
func run_sync() -> void:
	if running:
		return
	running = true
	var sources := scan_device_sources()
	var uploaded := await _upload_phase(sources)
	var mirror: Dictionary = await _prune_device_deletions(sources)
	await _process_pending_deletes()
	await _pull_changes()
	running = false
	Cache.enforce_cache()
	var message := "同步完成：上传 %d" % uploaded
	if int(mirror["pruned"]) > 0:
		message += " · 同步删除 %d" % int(mirror["pruned"])
	if int(mirror["kept"]) > 0:
		message += " · 保留 %d" % int(mirror["kept"])
	backup_finished.emit(true, message)


## Uploads the device items that are new or changed, returning how many were
## actually sent. An item whose stamp and size are unchanged is skipped, and
## bytes the cloud already holds are linked into the mirrored album rather than
## stored a second time.
func _upload_phase(sources: Array) -> int:
	var total := sources.size()
	var done := 0
	var uploaded := 0
	progress_changed.emit(done, total)
	for s in sources:
		var existing := Store.find_index_entry(str(s["local_id"]))
		if not existing.is_empty() \
				and int(existing.get("cloud_asset_id", 0)) > 0 \
				and int(existing.get("stamp", -1)) == int(s["taken_at"]) \
				and int(existing.get("size", -1)) == int(s["size"]):
			done += 1
			progress_changed.emit(done, total)
			continue
		# The device file itself is never modified; it is staged to a hidden temp
		# copy, which is what gets hashed and uploaded.
		var album_id := await Api.resolve_device_album(str(s["item"].get("bucket_name", "")))
		var r: Dictionary = await upload_device_item(s["item"], album_id)
		if bool(r.get("uploaded", false)):
			uploaded += 1
		done += 1
		progress_changed.emit(done, total)
	return uploaded


## Mirrors device deletions into the cloud: an indexed item the gallery no longer
## reports is soft-deleted (7-day recycle bin, restorable) and dropped from the
## index. Returns how many were pruned and how many were held back by a 保留 pin.
##
## Deletes cloud data, so it refuses any scan it cannot trust as a statement
## about the whole gallery: an empty result, or one taken without full media
## access (Android 14 can grant a hand-picked subset of photos), means the read
## failed or is partial — not that the user deleted their library.
func _prune_device_deletions(sources: Array) -> Dictionary:
	var indexed: Dictionary = {}
	for e in Store.sync_index:
		var lid := str(e.get("local_id", ""))
		if lid.begins_with(DEVICE_PREFIX):
			indexed[lid] = e
	if indexed.is_empty():
		return {"pruned": 0, "kept": 0}
	var live: Dictionary = {}
	for s in sources:
		live[str(s["local_id"])] = true
	if live.is_empty() or not DeviceMedia.scan_is_complete():
		return {"pruned": 0, "kept": 0}
	# Cloud assets still claimed by a live item. A renamed or moved file keeps its
	# content, so its new key resolves to the same asset id: the stale entry must
	# be dropped without taking that asset with it.
	var claimed: Dictionary = {}
	for lid in live:
		var e := Store.find_index_entry(str(lid))
		if not e.is_empty():
			var cid := int(e.get("cloud_asset_id", 0))
			if cid > 0:
				claimed[cid] = true
	var pruned := 0
	var held := 0
	for lid in indexed:
		var key := str(lid)
		if live.has(key):
			continue
		var asset_id := int(indexed[key].get("cloud_asset_id", 0))
		if asset_id > 0 and Store.is_kept(asset_id):
			# 用户标记过保留：本机文件没了，云端那份留下，只摘掉索引。
			Store.erase_index_entry(key)
			held += 1
			continue
		if asset_id > 0 and not claimed.has(asset_id):
			var r: Dictionary = await Api.delete_asset(asset_id)
			if r.has("error"):
				continue  # cloud unreachable: keep the entry, retry next sync
			Cache.remove_original_by_id(asset_id)
		Store.erase_index_entry(key)
		pruned += 1
	return {"pruned": pruned, "kept": held}


## Retries queued cloud deletes (tombstones). Keeps them when still offline. An
## entry is either a bare id (whole-asset delete) or {id, album_id} for a delete
## made inside one album; the response says whether the asset reached the recycle
## bin, and only then do the local artifacts become useless.
func _process_pending_deletes() -> void:
	var pending = Store.settings.get("pending_deletes", [])
	if not (pending is Array) or pending.is_empty():
		return
	var remaining: Array = []
	for entry in pending:
		var cid := int(entry.get("id", 0)) if entry is Dictionary else int(entry)
		var album_id := int(entry.get("album_id", 0)) if entry is Dictionary else 0
		if cid <= 0:
			continue
		var r: Dictionary = await Api.delete_asset(cid, album_id)
		if r.has("error"):
			remaining.append(entry)
		elif bool(r.get("data", {}).get("trashed", false)):
			remove_local(cid)
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


## Drops what this device keeps for cloud asset `cloud_id`: its index entry and
## any cached original. The thumbnail stays, so the grid and the recycle bin can
## still show the photo.
func remove_local(cloud_id: int) -> void:
	Store.erase_index_by_cloud_id(cloud_id)
	Cache.remove_original_by_id(cloud_id)


## Queues a cloud delete as a tombstone (offline path) and retries it on the next
## sync. `album_id` is carried the same way as the online delete: a scoped
## tombstone only drops that album's reference, so a photo filed in several
## albums keeps the others — and only a whole-asset delete makes the local copy
## (index entry + cached original) useless now.
func tombstone_delete(cloud_id: int, album_id: int = 0) -> void:
	if album_id <= 0:
		remove_local(cloud_id)
	var pending = Store.settings.get("pending_deletes", [])
	if not (pending is Array):
		pending = []
	var entry = cloud_id if album_id <= 0 else {"id": cloud_id, "album_id": album_id}
	if not pending.has(entry):
		pending.append(entry)
	Store.settings["pending_deletes"] = pending
	Store.save_settings()


# --- Cloud -> device ---------------------------------------------------------

## Copies cloud assets into the device gallery under Pictures/红泥, one file each.
## Android may only add media it owns without a prompt, so the device's own
## albums cannot be written into — this is a gallery-level export, and the system
## gallery app lists the result like any other photo. With `move` the cloud copy
## is soft-deleted into the recycle bin afterwards. Videos are skipped on Android
## (the gallery insert writes into the image collection only).
## Returns {written, skipped_video, failed}.
func export_assets_to_device(assets: Array, move: bool) -> Dictionary:
	var written := 0
	var skipped_video := 0
	var failed := 0
	for a in assets:
		var id := int(a.get("id", 0))
		if id <= 0:
			continue
		if DeviceMedia.is_android() and str(a.get("media_type", "image")) == "video":
			skipped_video += 1
			continue
		var name := str(a.get("original_name", ""))
		var ext := str(a.get("ext", ""))
		if ext == "":
			ext = name.get_extension().to_lower()
		var mime := str(a.get("mime_type", ""))
		if mime == "":
			mime = "image/jpeg"
		var body := Cache.read_original(id, name, ext)
		if body.is_empty():
			var r: Dictionary = await Api.fetch_original(id)
			if r.has("error"):
				failed += 1
				continue
			body = r["body"]
			if body.is_empty():
				failed += 1
				continue
			await Cache.save_original_bg(id, name, body, ext)
		var tmp := "user://hongni_export_%d.%s" % [id, ext if ext != "" else "jpg"]
		var f := FileAccess.open(tmp, FileAccess.WRITE)
		if f == null:
			failed += 1
			continue
		f.store_buffer(body)
		f.close()
		var ok := DeviceMedia.export_to_gallery(tmp, _export_name(name, ext, id), mime)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
		if not ok:
			failed += 1
			continue
		written += 1
		if move:
			await Api.delete_asset(id)
			remove_local(id)
	return {"written": written, "skipped_video": skipped_video, "failed": failed}


## A display name the gallery can open: keep a well-formed name, otherwise give
## it the extension we know the file really has.
func _export_name(name: String, ext: String, asset_id: int) -> String:
	if name == "":
		return "hongni_%d.%s" % [asset_id, ext if ext != "" else "jpg"]
	if name.get_extension() != "" or ext == "":
		return name
	return name + "." + ext


## SHA-256 of a local file, hex-encoded ("" when unreadable). The content hash is
## the cloud's identity for an asset, so callers hash before uploading to let the
## server deduplicate.
func sha256_file(path: String) -> String:
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
