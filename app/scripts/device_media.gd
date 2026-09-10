extends Node
## Device ("system") album access, shared by the album browser (one card per
## device album) and the photo grid (same grid / viewer / multi-select as the
## cloud trunks). Sources:
##   - Android: MediaStore items via the HongniPlugin; the plugin's bucket
##     columns group them into the device gallery's own albums.
##   - Desktop/editor: the user's Pictures folder, one album per top-level
##     subfolder (files directly under Pictures form the "图片" album).
##
## Scans are cached: refresh() re-reads the device, items()/albums()/bucket_items()
## read the cache. Thumbnails are rendered into user://system_thumbs as PNG,
## keyed by item key + size, so nothing is decoded twice.
##
## Item dictionaries:
##   device       true — marks device media in the dictionaries shared with the
##                cloud asset shape (grid, viewer and asset menu branch on it).
##   key          stable id within a scan: MediaStore id, or the file path.
##   bucket_id    album the item belongs to (ALL_BUCKET = every item).
##   bucket_name  album name shown on the card.
##   uri          content:// URI (Android); "" on desktop.
##   path         absolute file path (desktop); "" on Android.
##   display_name / mime_type / size / taken_at (unix s) / is_video /
##   width / height / duration_ms (0 when the platform does not know).

const ALL_BUCKET := "__all__"
const ROOT_BUCKET := "__root__"
# 桌面导出（Pictures/红泥）重名时的编号上限；用满后退回时间戳名字，绝不覆盖。
const MAX_GALLERY_NAME_TRIES := 1000
# 同名文件是否「同一张照片」按内容哈希判定，与云端识别文件的方式一致。
const PROBE := preload("res://scripts/media_probe.gd")
# Virtual bucket: every video of the device, whatever album it lives in.
const VIDEO_BUCKET := "__video__"
const THUMB_DIR := "user://system_thumbs"
# Upload staging: hidden so a concurrent Sync scan never backs up a temp copy.
const TEMP_DIR := "user://import_tmp"
const VIDEO_DIR := "user://cache/device"
const PREVIEW_PX := 2048
const IMAGE_EXTS := ["jpg", "jpeg", "png", "bmp", "webp", "gif", "heic", "heif"]
const VIDEO_EXTS := ["mp4", "mov", "mkv", "webm", "avi", "wmv", "3gp", "m4v"]
# Formats Image.load_from_file() can decode by itself. Anything else (videos
# included) has no desktop decoder here: the grid keeps its placeholder and the
# ▶ marker instead of spamming decode errors.
const DECODABLE_EXTS := ["jpg", "jpeg", "png", "webp", "bmp"]

var _items: Array = []
var _albums: Array = []

# Desktop thumbnail worker: Android decodes through the plugin on the calling
# thread (the bridge is main-thread only), desktop must not decode a multi-MB
# JPEG on the render thread, so those go through a queue + background thread.
var _thread: Thread = null
var _mutex: Mutex = null
var _jobs: Array = []
var _results: Array = []
var _thread_done := false


func _ready() -> void:
	for d in [THUMB_DIR, TEMP_DIR, VIDEO_DIR]:
		if not DirAccess.dir_exists_absolute(d):
			DirAccess.make_dir_recursive_absolute(d)
	_clear_temp()


func _exit_tree() -> void:
	stop_worker()


# --- Scan --------------------------------------------------------------------

## Re-reads the device and rebuilds the album grouping (newest item first).
## Returns the fresh item list; blocking on Android (a MediaStore query).
func refresh() -> Array:
	stop_worker()
	_items = _collect()
	_items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["taken_at"]) > int(b["taken_at"]))
	_build_albums()
	return _items


func items() -> Array:
	return _items


## A fresh, newest-first device list that leaves the displayed cache and the
## thumbnail worker alone. The sync engine needs a current, trustworthy read
## while the grid may still be waiting on decodes that refresh() would cancel.
func scan_items() -> Array:
	var items := _collect()
	items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["taken_at"]) > int(b["taken_at"]))
	return items


## Whether a scan covers the whole gallery: on Android 14+ the user can grant a
## hand-picked subset of photos, and a scan listing only those is no evidence
## about the ones it leaves out. Desktop reads the folder directly, so it does.
func scan_is_complete() -> bool:
	return Lock.has_full_media_access()


## Albums in newest-first order: [{id, name, count, cover}] where `cover` is the
## album's newest item. Empty until refresh() has run.
func albums() -> Array:
	return _albums


func bucket_items(bucket_id: String) -> Array:
	if bucket_id == ALL_BUCKET:
		return _items
	var out: Array = []
	for it in _items:
		if bucket_id == VIDEO_BUCKET:
			if bool(it.get("is_video", false)):
				out.append(it)
		elif str(it["bucket_id"]) == bucket_id:
			out.append(it)
	return out


func key_of(item: Dictionary) -> String:
	return str(item.get("key", ""))


## Whether a dictionary came from the device gallery (as opposed to the cloud).
func is_device(a) -> bool:
	return a is Dictionary and bool(a.get("device", false))


## True when thumbnails must be decoded on the calling thread (Android plugin);
## callers then spread decodes over frames via decode_thumb_now().
func decodes_in_caller() -> bool:
	return OS.get_name() == "Android"


func _collect() -> Array:
	if OS.get_name() == "Android":
		return _collect_android()
	return _collect_pictures()


func _collect_android() -> Array:
	var out: Array = []
	for m in Lock.list_media("all"):
		if not (m is Dictionary):
			continue
		var name := str(m.get("display_name", ""))
		var mime := str(m.get("mime_type", ""))
		var bucket_name := str(m.get("bucket_name", "")).strip_edges()
		var bucket_id := str(m.get("bucket_id", "")).strip_edges()
		if bucket_id == "" or bucket_id == "0":
			bucket_id = bucket_name if bucket_name != "" else ROOT_BUCKET
		out.append({
			"device": true,
			"key": str(m.get("id", "")),
			"bucket_id": bucket_id,
			"bucket_name": bucket_name if bucket_name != "" else "未分类",
			"uri": str(m.get("uri", "")),
			"path": "",
			"display_name": name,
			"mime_type": mime,
			"size": int(m.get("size", 0)),
			"taken_at": int(m.get("taken_at", 0)),
			"is_video": mime.begins_with("video"),
			"width": int(m.get("width", 0)),
			"height": int(m.get("height", 0)),
			"duration_ms": int(m.get("duration_ms", 0)),
		})
	return out


func _collect_pictures() -> Array:
	var out: Array = []
	var profile := OS.get_environment("USERPROFILE")
	if profile == "":
		return out
	var root := profile + "/Pictures"
	if not DirAccess.dir_exists_absolute(root):
		return out
	_scan_dir(root, root, out)
	return out


func _scan_dir(path: String, root: String, out: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not n.begins_with("."):
			if dir.current_is_dir():
				_scan_dir(path + "/" + n, root, out)
			else:
				var ext := n.get_extension().to_lower()
				if IMAGE_EXTS.has(ext) or VIDEO_EXTS.has(ext):
					var file := path + "/" + n
					# First path segment under Pictures = the album, so nested
					# folders stay in the album they were filed under.
					var bucket := (path + "/" + n).trim_prefix(root + "/").get_base_dir().get_slice("/", 0)
					out.append({
						"device": true,
						"key": file,
						"bucket_id": bucket if bucket != "" else ROOT_BUCKET,
						"bucket_name": bucket if bucket != "" else "图片",
						"uri": "",
						"path": file,
						"display_name": n,
						"mime_type": _mime_for(ext),
						"size": _file_size(file),
						"taken_at": int(FileAccess.get_modified_time(file)),
						"is_video": VIDEO_EXTS.has(ext),
						"width": 0,
						"height": 0,
						"duration_ms": 0,
					})
		n = dir.get_next()
	dir.list_dir_end()


func _build_albums() -> void:
	var by_id: Dictionary = {}
	var order: Array = []
	for it in _items:
		var bid := str(it["bucket_id"])
		if not by_id.has(bid):
			by_id[bid] = {
				"id": bid,
				"name": str(it["bucket_name"]),
				"count": 0,
				"items": [],
				"cover": {},
			}
			order.append(bid)
		by_id[bid]["count"] = int(by_id[bid]["count"]) + 1
		by_id[bid]["items"].append(it)
	_albums = []
	for bid in order:
		by_id[bid]["cover"] = cover_item(by_id[bid]["items"])
		_albums.append(by_id[bid])


## The item to put on an album cover: the newest one this platform can actually
## render a thumbnail for (a video has no desktop decoder), else the newest item.
func cover_item(list: Array) -> Dictionary:
	if list.is_empty():
		return {}
	for it in list:
		if not bool(it.get("is_video", false)) and DECODABLE_EXTS.has(
			str(it.get("display_name", "")).get_extension().to_lower()
		):
			return it
	for it in list:
		if not bool(it.get("is_video", false)):
			return it
	return list[0]


# --- Thumbnails --------------------------------------------------------------

func thumb_path(item: Dictionary, size: int) -> String:
	return THUMB_DIR + "/" + key_of(item).md5_text() + "_%d.png" % size


func preview_path(item: Dictionary, max_px: int) -> String:
	return THUMB_DIR + "/" + key_of(item).md5_text() + "_p%d.jpg" % max_px


## A cached thumbnail, or an empty Image when none has been rendered yet (never
## decodes, never schedules work).
func cached_thumb(item: Dictionary, size: int) -> Image:
	return _load_image(thumb_path(item, size))


## Schedules a background decode (desktop only; the worker drains through
## poll_thumbs()). A no-op where the caller decodes itself.
func queue_thumb(item: Dictionary, size: int) -> void:
	if decodes_in_caller():
		return
	var cache := thumb_path(item, size)
	if FileAccess.file_exists(cache):
		return
	_ensure_worker()
	_mutex.lock()
	_jobs.append({"key": key_of(item), "path": str(item.get("path", "")), "size": size, "cache": cache})
	_mutex.unlock()


## Blocking decode for the Android plugin bridge. Callers must budget these per
## frame (a decode writes a PNG, so hundreds in one frame would stall the UI).
func decode_thumb_now(item: Dictionary, size: int) -> Image:
	var cache := thumb_path(item, size)
	var cached := _load_image(cache)
	if cached.get_width() > 0:
		return cached
	if not Lock.load_thumbnail(str(item.get("uri", "")), ProjectSettings.globalize_path(cache), size):
		return Image.new()
	return _load_image(cache)


## Drained thumbnails: [{"key": String, "image": Image}].
func poll_thumbs() -> Array:
	if _mutex == null:
		return []
	var out: Array = []
	var finished := false
	while true:
		_mutex.lock()
		if _results.is_empty():
			finished = _thread_done
			_mutex.unlock()
			break
		out.append(_results.pop_front())
		_mutex.unlock()
	if finished and _thread != null:
		_thread.wait_to_finish()
		_thread = null
		_mutex = null
	return out


func stop_worker() -> void:
	if _mutex != null:
		_mutex.lock()
		_jobs.clear()
		_thread_done = true
		_mutex.unlock()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	_mutex = null
	_results.clear()


func _ensure_worker() -> void:
	if _thread != null:
		return
	_mutex = Mutex.new()
	_thread_done = false
	_thread = Thread.new()
	_thread.start(_worker_main)


func _worker_main() -> void:
	while true:
		_mutex.lock()
		if _jobs.is_empty():
			_thread_done = true
			_mutex.unlock()
			return
		var job: Dictionary = _jobs.pop_front()
		_mutex.unlock()
		var img := _decode_file_thumb(job)
		if img.get_width() > 0:
			img.save_png(str(job["cache"]))
		_mutex.lock()
		_results.append({"key": str(job["key"]), "image": img})
		_mutex.unlock()


func _decode_file_thumb(job: Dictionary) -> Image:
	var cache := str(job["cache"])
	var cached := _load_image(cache)
	if cached.get_width() > 0:
		return cached
	var size := int(job["size"])
	var src := _load_image(str(job["path"]))
	if src.get_width() <= 0:
		return Image.new()
	return _cover_crop(src, size)


func _load_image(path: String) -> Image:
	if path == "" or not FileAccess.file_exists(path):
		return Image.new()
	if not DECODABLE_EXTS.has(path.get_extension().to_lower()):
		return Image.new()
	var img := Image.load_from_file(path)
	if img == null or img.get_width() <= 0:
		return Image.new()
	return img


## Center-cropped square thumbnail of `src`, scaled to size×size.
func _cover_crop(src: Image, size: int) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	if w <= 0 or h <= 0:
		return src
	var side := mini(w, h)
	var crop := src.get_region(Rect2i(int((w - side) / 2.0), int((h - side) / 2.0), side, side))
	crop.resize(size, size, Image.INTERPOLATE_BILINEAR)
	return crop


## Whether device media lives in MediaStore (Android) rather than the filesystem.
func is_android() -> bool:
	return OS.get_name() == "Android"


## Removes device items from the device itself and returns the keys that really
## went away. The verdict comes from a fresh scan, not from the platform's own
## report: whatever was removed is simply no longer listed, which also covers a
## declined confirmation. Only the items passed in are ever touched.
func delete_items(items: Array) -> Array:
	var keys: Array = []
	for it in items:
		keys.append(key_of(it))
	if keys.is_empty():
		return []
	if not is_android():
		for it in items:
			var path := str(it.get("path", ""))
			if path != "":
				DirAccess.remove_absolute(path)
		refresh()
		return _keys_gone(keys)
	var seq := Lock.media_delete_seq()
	if Lock.delete_media(items) < 0:
		seq = await Lock.await_media_delete(seq)
	refresh()
	var gone := _keys_gone(keys)
	if not gone.is_empty() and gone.size() < keys.size():
		# Android 10 removes what it can silently and only then asks about the
		# rest, so a partial answer came in before the dialog. Wait for the
		# dialog's own report before calling the remainder cancelled.
		await Lock.await_media_delete(seq, 15.0)
		refresh()
		gone = _keys_gone(keys)
	return gone


## Which of `keys` the last scan no longer lists.
func _keys_gone(keys: Array) -> Array:
	var live: Dictionary = {}
	for it in _items:
		live[key_of(it)] = true
	var gone: Array = []
	for k in keys:
		if not live.has(str(k)):
			gone.append(k)
	return gone


## Copies a local file into the device gallery. Android can only add media it
## owns without a prompt, so the copy lands in Pictures/红泥 — the device's own
## albums are the device's, not ours to write into; the system gallery app then
## lists it like any other photo. Desktop copies under Pictures/红泥 as well.
## `src_user_path` is a user:// path. False on failure.
func export_to_gallery(src_user_path: String, display_name: String, mime_type: String) -> bool:
	if src_user_path == "" or not FileAccess.file_exists(src_user_path):
		return false
	if is_android():
		return Lock.save_to_gallery(ProjectSettings.globalize_path(src_user_path), display_name, mime_type)
	var profile := OS.get_environment("USERPROFILE")
	if profile == "":
		return false
	var dir := profile + "/Pictures/红泥"
	if not DirAccess.dir_exists_absolute(dir) and DirAccess.make_dir_recursive_absolute(dir) != OK:
		return false
	var src := ProjectSettings.globalize_path(src_user_path)
	var target := _gallery_target(dir, display_name, src)
	if target == "":
		# 同一张照片已经在 Pictures/红泥 里（内容一致）：不必再写一遍，也算成功。
		return true
	return DirAccess.copy_absolute(src, dir + "/" + target) == OK


## Where a desktop export lands inside `dir`: `display_name` when it is free, the
## numbered "x (1).jpg" when a *different* photo already holds that name, and ""
## when the file already there is this very photo (same bytes — writing it again
## would only overwrite a copy with itself). Android needs none of this: the
## gallery insert renames duplicates on its own.
func _gallery_target(dir: String, display_name: String, src_path: String) -> String:
	var base := display_name
	var ext := ""
	var dot := display_name.rfind(".")
	if dot > 0:
		base = display_name.substr(0, dot)
		ext = display_name.substr(dot)
	var src_hash := PROBE.sha256_file(src_path)
	for n in MAX_GALLERY_NAME_TRIES:
		var candidate := display_name if n == 0 else "%s (%d)%s" % [base, n, ext]
		var target := dir + "/" + candidate
		if not FileAccess.file_exists(target):
			return candidate
		# 同名且同一张照片：合并不重写。同名但不是同一张：给后进的换个号。
		if src_hash != "" and PROBE.sha256_file(target) == src_hash:
			return ""
	# 同名文件多到撞满整个编号空间（现实中不会发生）：退回带时间戳的名字，
	# 无论如何都不覆盖别人的照片。
	return "%s (%d)%s" % [base, int(Time.get_unix_time_from_system()), ext]


# --- Full-screen previews ----------------------------------------------------

## A viewable image for the full-screen viewer: aspect ratio preserved, capped
## at max_px on the longest edge. Empty when the item cannot be decoded.
func get_preview(item: Dictionary, max_px: int = PREVIEW_PX) -> Image:
	if decodes_in_caller():
		var cache := preview_path(item, max_px)
		if not FileAccess.file_exists(cache):
			if not Lock.load_media_preview(
				str(item.get("uri", "")), ProjectSettings.globalize_path(cache), max_px
			):
				return Image.new()
		return _load_image(cache)
	var img := _load_image(str(item.get("path", "")))
	var longest := maxi(img.get_width(), img.get_height())
	if longest > max_px:
		var scale := float(max_px) / float(longest)
		img.resize(
			maxi(1, int(img.get_width() * scale)),
			maxi(1, int(img.get_height() * scale)),
			Image.INTERPOLATE_BILINEAR,
		)
	return img


# --- File access (upload staging / playback source) --------------------------

## Copies a device item into the hidden upload staging dir and returns its
## user:// path ("" on failure). The caller uploads it, then remove_temp().
func materialize(item: Dictionary) -> String:
	var name := str(item.get("display_name", "file"))
	var dest := TEMP_DIR + "/%d_%s" % [Time.get_ticks_usec(), name]
	if decodes_in_caller():
		if not Lock.read_media_bytes(str(item.get("uri", "")), ProjectSettings.globalize_path(dest)):
			return ""
		return dest
	var src := str(item.get("path", ""))
	if src == "" or not FileAccess.file_exists(src):
		return ""
	await _copy_async(src, ProjectSettings.globalize_path(dest))
	return dest if FileAccess.file_exists(dest) else ""


## A local file to hand to playback: the desktop item path, or (Android) a copy
## of the MediaStore item under user://cache/device. "" when unreadable.
func local_video_path(item: Dictionary) -> String:
	var path := str(item.get("path", ""))
	if path != "":
		return path
	var uri := str(item.get("uri", ""))
	if uri == "":
		return ""
	var ext := str(item.get("display_name", "")).get_extension().to_lower()
	if ext == "":
		ext = "mp4"
	var dest := VIDEO_DIR + "/" + key_of(item).md5_text() + "." + ext
	if FileAccess.file_exists(dest):
		return dest
	if not Lock.read_media_bytes(uri, ProjectSettings.globalize_path(dest)):
		return ""
	return dest


func remove_temp(user_path: String) -> void:
	if user_path == "":
		return
	var abs := ProjectSettings.globalize_path(user_path)
	if FileAccess.file_exists(abs):
		DirAccess.remove_absolute(abs)


# --- Helpers -----------------------------------------------------------------

func _copy_async(src: String, dest_abs: String) -> void:
	var done := [false]
	var t := Thread.new()
	t.start(func() -> void:
		DirAccess.copy_absolute(src, dest_abs)
		done[0] = true
	)
	while not done[0]:
		await get_tree().process_frame
	t.wait_to_finish()


## A stale staging copy from a previous run is dead weight (the upload either
## finished or was abandoned); drop them all at startup.
func _clear_temp() -> void:
	var dir := DirAccess.open(TEMP_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(TEMP_DIR + "/" + n)
		n = dir.get_next()
	dir.list_dir_end()


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var size := f.get_length()
	f.close()
	return size


func _mime_for(ext: String) -> String:
	match ext:
		"jpg", "jpeg":
			return "image/jpeg"
		"png":
			return "image/png"
		"webp":
			return "image/webp"
		"bmp":
			return "image/bmp"
		"gif":
			return "image/gif"
		"heic":
			return "image/heic"
		"heif":
			return "image/heif"
		"mp4":
			return "video/mp4"
		"mov":
			return "video/quicktime"
		"mkv":
			return "video/x-matroska"
		"webm":
			return "video/webm"
		"avi":
			return "video/x-msvideo"
		"3gp":
			return "video/3gpp"
		_:
			return "application/octet-stream"
