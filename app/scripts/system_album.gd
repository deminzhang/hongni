extends Control
## Stage 4: browse the device system album in-app and import selected items into
## the cloud (upload + optional album membership).
##
## Sources differ by platform:
##   - Android: MediaStore items via the plugin (uri thumbnails, generated into a
##     PNG cache by Lock.load_thumbnail on the main thread, chunked).
##   - PC/desktop: the OS Pictures folder (%USERPROFILE%\Pictures) scanned by
##     path; thumbnails are decoded off the main thread by a worker (reusing a
##     PNG cache so each refresh doesn't re-decode full-resolution files).
##
## Both paths populate the same grid of toggleable Buttons (icon = thumbnail,
## tooltip = display name, selection drives the Import flow).

const THUMB_SIZE := 140
const APPLY_BATCH := 8
const IMAGE_EXTS := ["jpg", "jpeg", "png", "bmp", "webp", "gif"]
const VIDEO_EXTS := ["mp4", "mov", "mkv", "webm", "avi", "wmv", "3gp"]

var grid: GridContainer
var label_status: Label
var media: Array = []
# index-aligned with media[]; thumbnails are applied here as they load.
var _cells: Array = []

# Background decoder (PC paths only): Mutex-guarded job/result queues + a flag
# the worker sets once it has drained its job list.
var _thread: Thread = null
var _mutex: Mutex = null
var _jobs: Array = []
var _results: Array = []
var _thread_done := false
# Bumped on every refresh; the Android thumbnail coroutine bails if it sees a
# newer generation (the media list was replaced underneath it).
var _load_gen := 0


func _ready() -> void:
	_build_ui()
	_refresh.call_deferred()


func _exit_tree() -> void:
	# A scene change can happen while the worker is mid-decode: clear the backlog
	# and join so this thread is never left running against a freed object.
	_stop_worker()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var top := HBoxContainer.new()
	root.add_child(top)

	var btn_back := Button.new()
	btn_back.text = "← 返回"
	btn_back.pressed.connect(_go_back)
	top.add_child(btn_back)

	var title := Label.new()
	title.text = "系统相册"
	title.add_theme_font_size_override("font_size", 20)
	top.add_child(title)

	var btn_import := Button.new()
	btn_import.text = "导入所选"
	btn_import.pressed.connect(_import_selected)
	top.add_child(btn_import)

	var btn_refresh := Button.new()
	btn_refresh.text = "刷新"
	btn_refresh.pressed.connect(_refresh.call_deferred)
	top.add_child(btn_refresh)

	label_status = Label.new()
	label_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(label_status)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(scroll)

	grid = GridContainer.new()
	grid.columns = 5
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)


# --- Media collection --------------------------------------------------------

func _collect_media() -> Array:
	if OS.get_name() == "Android":
		var raw: Array = Lock.list_media("all")
		for m in raw:
			m["is_video"] = str(m.get("mime_type", "")).begins_with("video")
			m["path"] = ""
		return raw
	return _list_pc_pictures()


# --- Refresh / render --------------------------------------------------------

func _refresh() -> void:
	_stop_worker()
	_load_gen += 1
	for c in grid.get_children():
		c.queue_free()
	_cells.clear()
	media = _collect_media()
	# Responsive column count: fit THUMB_SIZE cells to the viewport (2..6 cols).
	grid.columns = clampi(int(get_viewport_rect().size.x / (THUMB_SIZE + 12)), 2, 6)
	for i in media.size():
		_add_cell(i, media[i])
	_start_thumbs()


func _add_cell(i: int, m: Dictionary) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(THUMB_SIZE, THUMB_SIZE)
	btn.expand_icon = true
	btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_CENTER
	btn.toggle_mode = true
	btn.tooltip_text = str(m.get("display_name", ""))
	# Video cells get a centered ▶ marker so they're identifiable even when a
	# thumbnail (desktop has no video decode path) can't be produced.
	if m.get("is_video", false):
		var badge := Label.new()
		badge.text = "▶"
		badge.add_theme_font_size_override("font_size", 24)
		badge.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0.5)
		sb.set_corner_radius_all(4)
		badge.add_theme_stylebox_override("normal", sb)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(badge)
		badge.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_cells.append(btn)  # index-aligned with media[]
	grid.add_child(btn)
	btn.pressed.connect(_on_cell_toggled)


func _start_thumbs() -> void:
	if media.is_empty():
		label_status.text = "本机 0 项"
		return
	label_status.text = "本机 %d 项 · 加载缩略图…" % media.size()
	if OS.get_name() == "Android":
		_load_android_thumbs(_load_gen)
	else:
		_start_pc_worker()


func _on_cell_toggled() -> void:
	var count := 0
	for c in grid.get_children():
		if c is Button and c.button_pressed:
			count += 1
	label_status.text = "本机 %d 项 · 已选 %d" % [media.size(), count]


func _selected() -> Array:
	var out: Array = []
	for i in grid.get_child_count():
		var c = grid.get_child(i)
		if c is Button and c.button_pressed:
			out.append(media[i])
	return out


# --- Android thumbnails (main thread, chunked; plugin generates PNG cache) ----

func _load_android_thumbs(gen: int) -> void:
	var cache_dir := ProjectSettings.globalize_path("user://system_thumbs")
	DirAccess.make_dir_recursive_absolute(cache_dir)
	for i in media.size():
		if gen != _load_gen or not is_inside_tree():
			return
		var m: Dictionary = media[i]
		var cache := _thumb_cache_path(str(m.get("id", i)))
		var img := Image.new()
		if FileAccess.file_exists(cache):
			var cached := Image.load_from_file(cache)
			if cached != null:
				img = cached
		if img.get_width() <= 0:
			if Lock.load_thumbnail(str(m.get("uri", "")), cache, THUMB_SIZE):
				var loaded := Image.load_from_file(cache)
				if loaded != null:
					img = loaded
		if img.get_width() > 0:
			_apply_cell_image(i, img)
		if i % 4 == 0:
			label_status.text = "本机 %d 项 · 加载缩略图 %d/%d" % [media.size(), i + 1, media.size()]
		await get_tree().process_frame
	label_status.text = "本机 %d 项" % media.size()


# --- PC thumbnails (background worker decodes originals into a PNG cache) -----

func _start_pc_worker() -> void:
	var cache_dir := ProjectSettings.globalize_path("user://system_thumbs")
	DirAccess.make_dir_recursive_absolute(cache_dir)
	_mutex = Mutex.new()
	_jobs.clear()
	_results.clear()
	_thread_done = false
	for i in media.size():
		var m: Dictionary = media[i]
		_jobs.append({
			"index": i,
			"src": str(m["path"]),
			"cache": _thumb_cache_path(str(m["path"])),
		})
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
		var src := str(job.get("src", ""))
		var cache := str(job.get("cache", ""))
		var img := Image.new()
		if FileAccess.file_exists(cache):
			var cached := Image.load_from_file(cache)
			if cached != null:
				img = cached
		if img.get_width() <= 0:
			var loaded := Image.load_from_file(src)
			if loaded != null and loaded.get_width() > 0:
				img = _square_crop(loaded, THUMB_SIZE)
				img.save_png(cache)
		_mutex.lock()
		_results.append({"index": int(job.get("index", -1)), "img": img})
		_mutex.unlock()


func _process(_dt: float) -> void:
	if _thread == null or _mutex == null:
		return
	var applied := 0
	while applied < APPLY_BATCH:
		_mutex.lock()
		if _results.is_empty():
			_mutex.unlock()
			break
		var r: Dictionary = _results.pop_front()
		_mutex.unlock()
		_apply_cell_image(int(r.get("index", -1)), r.get("img"))
		applied += 1
	var finished := false
	_mutex.lock()
	finished = _thread_done and _results.is_empty()
	_mutex.unlock()
	if finished and _thread != null:
		_thread.wait_to_finish()
		_thread = null
		_mutex = null


func _stop_worker() -> void:
	if _mutex != null:
		_mutex.lock()
		_jobs.clear()
		_thread_done = true
		_mutex.unlock()
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	_mutex = null


# --- Cell image application --------------------------------------------------

func _apply_cell_image(index: int, img: Image) -> void:
	if index < 0 or index >= _cells.size():
		return
	var btn: Button = _cells[index]
	if not is_instance_valid(btn):
		return
	if img == null or img.get_width() <= 0:
		return
	btn.icon = ImageTexture.create_from_image(img)


func _square_crop(src: Image, size: int) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	if w <= 0 or h <= 0:
		return src
	var side := mini(w, h)
	var x := int((w - side) / 2.0)
	var y := int((h - side) / 2.0)
	var crop := src.get_region(Rect2i(x, y, side, side))
	crop.resize(size, size, Image.INTERPOLATE_BILINEAR)
	return crop


# --- PC Pictures scan --------------------------------------------------------

func _list_pc_pictures() -> Array:
	var out: Array = []
	var profile := OS.get_environment("USERPROFILE")
	if profile == "":
		return out
	var root := profile + "/Pictures"
	if not DirAccess.dir_exists_absolute(root):
		return out
	_scan_dir(root, out)
	return out


func _scan_dir(path: String, out: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not n.begins_with("."):
			if dir.current_is_dir():
				_scan_dir(path + "/" + n, out)
			else:
				var ext := n.get_extension().to_lower()
				if IMAGE_EXTS.has(ext) or VIDEO_EXTS.has(ext):
					var p := path + "/" + n
					out.append({
						"path": p,
						"uri": "",
						"display_name": n,
						"mime_type": _mime_for(ext),
						"taken_at": int(FileAccess.get_modified_time(p)),
						"is_video": VIDEO_EXTS.has(ext),
					})
		n = dir.get_next()
	dir.list_dir_end()


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


func _thumb_cache_path(key: String) -> String:
	return ProjectSettings.globalize_path("user://system_thumbs/" + key.md5_text() + ".png")


# --- Import ------------------------------------------------------------------

func _import_selected() -> void:
	var sel := _selected()
	if sel.is_empty():
		return
	# The local staging dir must exist before any copy/write; Sync normally
	# creates it, but a fresh install may not have run yet.
	var photos := ProjectSettings.globalize_path("user://photos")
	if not DirAccess.dir_exists_absolute(photos):
		DirAccess.make_dir_recursive_absolute(photos)
	var total := sel.size()
	var done := 0
	for m in sel:
		var name: String = m.get("display_name", "import")
		var media_type: String = "video" if m.get("is_video", false) else "image"
		var dest := photos + "/" + name
		var ok := false
		var step_err := ""
		if OS.get_name() == "Android":
			ok = Lock.read_media_bytes(str(m["uri"]), dest)
		else:
			# Copying a potentially large video off the main thread.
			var src := str(m["path"])
			var res := [false]
			await Api._bg(func() -> void:
				res[0] = DirAccess.copy_absolute(src, dest) == OK
			)
			ok = res[0]
			if not ok:
				step_err = "复制失败"
		if ok:
			var taken_at := int(m.get("taken_at", 0))
			var r: Dictionary = await Api.upload_asset(dest, name, media_type, taken_at, Api.scatter_album_id)
			if r.has("error"):
				label_status.text = "导入失败：" + str(r.get("error", ""))
			# Remove the temp copy to avoid re-uploading on next backup.
			DirAccess.remove_absolute(dest)
		else:
			label_status.text = "导入失败：" + step_err + "（" + name + "）"
		done += 1
		label_status.text = "导入 %d/%d" % [done, total]
	label_status.text = "导入完成"


func _go_back() -> void:
	get_tree().change_scene_to_file("res://scenes/albums.tscn")
