extends Control
## Photo grid for one album (or the trunk "全部" aggregation). Selecting a photo
## opens viewer.tscn; long-press a photo for 收藏/移动到/复制到/改名/删除.
## Upload targets the current album, or the trunk's 散照 bucket for "全部".
##
## Album context (Api.current_album_id / current_album_name) is set by
## albums.gd before changing to this scene. When current_album_id equals the
## active trunk id this is the "全部" view (server aggregates trunk members).

const THUMB_SIZE := 140
const LONG_PRESS := 0.5
const RENDER_CHUNK := 150
const FAVORITE := "收藏"

enum MenuId { FAV_TOGGLE, MOVE, COPY, RENAME, DELETE }

var grid: GridContainer
var progress: ProgressBar
var status_label: Label
var scroll: ScrollContainer
var ctx_menu: PopupMenu
var label_title: Label

# Current album's full member list (viewer navigation) + chunked-render state.
var _assets_full: Array = []
var _rendered := 0
var _grid_gen := 0
var _rendering := false

# Album context resolved from Api at ready time.
var _album_id: int = 0
var _album_name: String = ""
var _is_all: bool = false
# asset_id(String) -> true for photos already in the trunk's 收藏 bucket.
var _favorite_ids: Dictionary = {}

# Long-press state.
var _lp_suppress := false
var _lp_held := false
var _lp_token := 0

# Context target for the active photo menu.
var _ctx_asset_id := 0
var _ctx_asset_name := ""
var _ctx_asset_ext := ""
# True once the album list failed to load (offline / weak cloud): thumbnails are
# then never fetched over the network, so the grid stays instant.
var _offline := false


func _ready() -> void:
	_album_id = Api.current_album_id
	_album_name = Api.current_album_name
	_is_all = (_album_id > 0 and _album_id == Api.current_trunk_id)
	_build_ui()
	if not Lock.photo_picker_result.is_connected(_on_picker_result):
		Lock.photo_picker_result.connect(_on_picker_result)
	_load.call_deferred()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# --- Top bar ---
	var top := HBoxContainer.new()
	root.add_child(top)

	var btn_back := Button.new()
	btn_back.text = "← 返回"
	btn_back.pressed.connect(_go_back)
	top.add_child(btn_back)

	label_title = Label.new()
	label_title.text = _album_name if _album_name != "" else "相册"
	label_title.add_theme_font_size_override("font_size", 20)
	top.add_child(label_title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	var btn_upload := Button.new()
	btn_upload.text = "上传"
	btn_upload.pressed.connect(_upload)
	top.add_child(btn_upload)

	progress = ProgressBar.new()
	progress.min_value = 0.0
	progress.max_value = 1.0
	progress.show_percentage = false
	root.add_child(progress)

	status_label = Label.new()
	root.add_child(status_label)

	# --- Asset grid (expands) ---
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.get_v_scroll_bar().value_changed.connect(_on_scroll)
	root.add_child(scroll)

	grid = GridContainer.new()
	grid.columns = 4
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)

	# --- Long-press context menu ---
	ctx_menu = PopupMenu.new()
	add_child(ctx_menu)
	ctx_menu.id_pressed.connect(_on_ctx_menu)


# --- Loading ----------------------------------------------------------------

func _load() -> void:
	if _album_id <= 0:
		status_label.text = "无效相册"
		return
	# 网格先用本地缓存即时渲染;收藏成员随后台加载,互不阻塞渲染与网络。
	_refresh_grid.call_deferred()
	_load_favorite_ids.call_deferred()


## Loads the trunk's favorite-bucket members once, so the menu can show
## 收藏/取消收藏 based on the current photo's membership.
func _load_favorite_ids() -> void:
	_favorite_ids.clear()
	var fav_id := Api.favorite_album_id
	if fav_id <= 0:
		return
	var fav: Dictionary = await _fetch_album_assets(fav_id)
	for a in fav["assets"]:
		_favorite_ids[str(int(a["id"]))] = true


## Loads one album's complete member list by paging the server (members are
## returned newest-first). Any network failure falls back to the offline
## snapshot; successful loads write the snapshot through to the cache.
func _fetch_album_assets(album_id: int) -> Dictionary:
	if _offline:
		return {"assets": Cache.offline_assets(album_id), "offline": true}
	var out: Array = []
	var cursor := ""
	while true:
		var r: Dictionary = await Api.list_assets("all", album_id, cursor)
		if r.has("error"):
			return {"assets": Cache.offline_assets(album_id), "offline": true}
		var data: Dictionary = r["data"]
		out.append_array(data["assets"])
		cursor = str(data.get("next_cursor", ""))
		if cursor == "":
			break
	Cache.snapshot_album_assets(album_id, out)
	return {"assets": out, "offline": false}


func _refresh_grid() -> void:
	_clear_grid()
	if _album_id <= 0:
		return
	# 离线/弱联是主线: 先用本地缓存立即铺网格(不等待网络);云端在后台线程
	# 刷新,返回后再替换。这样即使云不可达,网格也即时出现。
	var cached := Cache.offline_assets(_album_id)
	if _is_all:
		cached = _with_local_pending(cached)
	Api.viewer_assets = cached
	_assets_full = cached
	_render_cells(0)
	if not _offline:
		_update_from_cloud.call_deferred()


## Background cloud refresh (runs off the render path). On success it replaces
## the grid with the server list; on failure it keeps the cache and marks
## offline so later refreshes stop hitting the network.
func _update_from_cloud() -> void:
	var res: Dictionary = await _fetch_album_assets(_album_id)
	if _album_id <= 0:
		return
	_offline = res["offline"]
	if _offline:
		_set_mode_status(true)
		return
	_set_mode_status(false)
	var list: Array = res["assets"]
	if _is_all:
		list = _with_local_pending(list)
	Api.viewer_assets = list
	_clear_grid()
	_assets_full = list
	_render_cells(0)


## Adds RENDER_CHUNK grid cells starting at from_index. Called once on
## refresh and again when the user scrolls near the bottom of the rendered
## cells.
func _render_cells(from_index: int) -> void:
	if _rendering:
		return
	_rendering = true
	var gen := _grid_gen
	var hi := mini(_assets_full.size(), from_index + RENDER_CHUNK)
	for i in range(from_index, hi):
		if gen != _grid_gen:
			break
		_add_cell(_assets_full[i], i, gen)
	if gen != _grid_gen:
		_rendering = false
		return
	_rendered = hi
	_rendering = false


func _on_scroll(_value: float) -> void:
	if _rendered >= _assets_full.size():
		return
	var bar := scroll.get_v_scroll_bar()
	if bar.max_value - bar.page - bar.value < 24:
		_render_cells(_rendered)


func _clear_grid() -> void:
	_grid_gen += 1
	_rendered = 0
	_assets_full = []
	for c in grid.get_children():
		c.queue_free()


func _add_cell(a: Dictionary, index: int, gen: int) -> void:
	var asset_id := int(a.get("id", 0))
	if asset_id <= 0 and a.has("local_path"):
		_add_local_cell(a, index)
		return
	var btn := TextureButton.new()
	btn.custom_minimum_size = Vector2(THUMB_SIZE, THUMB_SIZE)
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	btn.set_meta("asset_id", asset_id)
	btn.set_meta("asset_index", index)
	btn.set_meta("asset_name", str(a.get("original_name", "")))
	btn.set_meta("asset_ext", str(a.get("ext", "")))
	_bind_long_press(btn)
	grid.add_child(btn)
	# 只存云(本地无原件)→ 云下载角标;两端都有则不标。
	if not _has_local_original(asset_id, str(a.get("original_name", "")), str(a.get("ext", ""))):
		_add_badge(btn, "↓")
	# 视频无服务端缩略图(解码不支持),用左上角 ▶ 标记,便于在网格中识别。
	if str(a.get("media_type", "image")) == "video":
		_add_badge(btn, "▶", Vector2(2, 2))
	_load_cell_thumb(btn, asset_id, gen)


## A local-only (not yet uploaded) photo cell, shown only in the 全部 view with
## an ↑ upload badge. Tapping it uploads the file into the trunk's 散照 bucket.
func _add_local_cell(a: Dictionary, index: int) -> void:
	var path := str(a.get("local_path", ""))
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(THUMB_SIZE, THUMB_SIZE)
	btn.text = (str(a.get("original_name", "")) + "\n↑ 待上传")
	btn.set_meta("local_path", path)
	btn.pressed.connect(_upload_local.bind(path))
	grid.add_child(btn)


func _upload_local(path: String) -> void:
	var name := path.get_file()
	var media_type := "video" if _is_video(name) else "image"
	await Api.upload_asset(path, name, media_type, int(FileAccess.get_modified_time(path)), _upload_album_id())
	_refresh_grid.call_deferred()


## Local files under user://photos not yet uploaded to the cloud (no sync-index
## cloud id). Merged into the 全部 grid with an ↑ upload badge.
func _local_pending() -> Array:
	var out: Array = []
	var dir := DirAccess.open("user://photos")
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir() and not n.begins_with("."):
			var local_id := "photos/" + n
			var e := Store.find_index_entry(local_id)
			var uploaded := false
			if not e.is_empty():
				uploaded = int(e.get("cloud_asset_id", 0)) > 0 and not e.get("deleted", false)
			if not uploaded:
				out.append({
					"local_path": "user://photos/" + n,
					"original_name": n,
					"id": 0,
				})
		n = dir.get_next()
	dir.list_dir_end()
	return out


func _with_local_pending(list: Array) -> Array:
	var pending := _local_pending()
	if pending.is_empty():
		return list
	var merged := pending
	merged.append_array(list)
	return merged


## True when a cloud asset's original also exists locally (either as a cached
## full-res copy or as the uploaded photos source file).
func _has_local_original(asset_id: int, name: String, ext: String = "") -> bool:
	if Cache.original_cached(asset_id, name, ext):
		return true
	for e in Store.sync_index:
		if int(e.get("cloud_asset_id", 0)) == asset_id:
			var local_id: String = e.get("local_id", "")
			if FileAccess.file_exists("user://photos/" + local_id.trim_prefix("photos/")):
				return true
	return false


## Overlays a small corner badge (cloud download ⇩ / upload ⇧ at top-right,
## video ▶ at top-left) on a cell.
func _add_badge(btn: Control, text: String, pos: Vector2 = Vector2(THUMB_SIZE - 30, 2)) -> void:
	var badge := Label.new()
	badge.text = text
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.add_theme_font_size_override("font_size", 18)
	badge.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.5)
	sb.set_corner_radius_all(4)
	badge.add_theme_stylebox_override("normal", sb)
	badge.position = pos
	btn.add_child(badge)


## Fills a cell thumbnail without blocking the render loop and without waiting
## on the network when offline: cached thumbs show immediately, missing ones load
## in the background (and are skipped entirely when offline/weak).
func _load_cell_thumb(btn: TextureButton, asset_id: int, gen: int) -> void:
	var body := Cache.read_thumb(asset_id)
	if body.is_empty():
		if _offline:
			return
		var r: Dictionary = await Api.fetch_thumb(asset_id)
		if r.has("error") or gen != _grid_gen or not is_instance_valid(btn):
			return
		body = r["body"]
		Cache.save_thumb(asset_id, body)
	if gen != _grid_gen or not is_instance_valid(btn) or body.is_empty():
		return
	var img := Image.new()
	if img.load_jpg_from_buffer(body) == OK:
		btn.texture_normal = ImageTexture.create_from_image(img)


# --- Connectivity hint -------------------------------------------------------

func _set_mode_status(offline: bool, message: String = "") -> void:
	if message != "":
		status_label.text = message
	elif offline:
		status_label.text = "离线模式 · 显示本地缓存"
	else:
		status_label.text = ""


# --- Long-press plumbing -----------------------------------------------------

func _bind_long_press(btn: BaseButton) -> void:
	btn.button_down.connect(_on_lp_down.bind(btn))
	btn.button_up.connect(_on_lp_up)
	btn.pressed.connect(_on_lp_pressed.bind(btn))


func _on_lp_down(btn: BaseButton) -> void:
	_lp_suppress = false
	_lp_held = true
	_lp_token += 1
	var token := _lp_token
	await get_tree().create_timer(LONG_PRESS).timeout
	if token != _lp_token or not _lp_held or not is_instance_valid(btn):
		return
	_lp_suppress = true
	_on_long_press(btn)


func _on_lp_up() -> void:
	_lp_held = false


func _on_lp_pressed(btn: BaseButton) -> void:
	if _lp_suppress:
		_lp_suppress = false
		return
	_on_short_press(btn)


func _on_short_press(btn: BaseButton) -> void:
	if btn.has_meta("asset_id"):
		Api.viewer_index = int(btn.get_meta("asset_index"))
		get_tree().change_scene_to_file("res://scenes/viewer.tscn")


func _on_long_press(btn: BaseButton) -> void:
	if btn.has_meta("asset_id"):
		_show_photo_menu(int(btn.get_meta("asset_id")), str(btn.get_meta("asset_name", "")), str(btn.get_meta("asset_ext", "")))


# --- Photo context menu ------------------------------------------------------

func _show_photo_menu(asset_id: int, asset_name: String, asset_ext: String = "") -> void:
	_ctx_asset_id = asset_id
	_ctx_asset_name = asset_name
	_ctx_asset_ext = asset_ext
	ctx_menu.clear()
	ctx_menu.add_item(_fav_label(asset_id), MenuId.FAV_TOGGLE)
	ctx_menu.add_item("移动到", MenuId.MOVE)
	ctx_menu.add_item("复制到", MenuId.COPY)
	ctx_menu.add_item("改名", MenuId.RENAME)
	ctx_menu.add_item("删除", MenuId.DELETE)
	ctx_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _fav_label(asset_id: int) -> String:
	return "取消收藏" if _favorite_ids.has(str(asset_id)) else "收藏"


func _on_ctx_menu(id: int) -> void:
	match id:
		MenuId.FAV_TOGGLE:
			await _toggle_favorite(_ctx_asset_id)
		MenuId.MOVE:
			await _prompt_target(_ctx_asset_id, true)
		MenuId.COPY:
			await _prompt_target(_ctx_asset_id, false)
		MenuId.RENAME:
			await _rename_asset(_ctx_asset_id, _ctx_asset_name, _ctx_asset_ext)
		MenuId.DELETE:
			await _delete_asset(_ctx_asset_id)


# --- Photo actions (favorite / move / copy / rename / delete) ----------------

func _toggle_favorite(asset_id: int) -> void:
	var fav_id := Api.favorite_album_id
	if fav_id <= 0:
		_set_mode_status(false, "未找到收藏相册")
		return
	if _favorite_ids.has(str(asset_id)):
		await Api.remove_asset_from_album(fav_id, asset_id)
		_favorite_ids.erase(str(asset_id))
	else:
		await Api.add_asset_to_album(fav_id, asset_id)
		_favorite_ids[str(asset_id)] = true


func _rename_asset(asset_id: int, current: String, preserve_ext: String = "") -> void:
	if asset_id <= 0:
		return
	# 改名不动扩展名:优先用索引记录的原始扩展名,否则用当前名自带的扩展名。
	if preserve_ext == "":
		preserve_ext = current.get_extension().to_lower()
	var popup := AcceptDialog.new()
	popup.title = "重命名照片"
	var edit := LineEdit.new()
	edit.text = current
	edit.name = "NameEdit"
	popup.add_child(edit)
	edit.text_submitted.connect(_do_rename_asset.bind(asset_id, popup, preserve_ext))
	add_child(popup)
	popup.popup_centered()


func _do_rename_asset(name: String, asset_id: int, popup: AcceptDialog, preserve_ext: String = "") -> void:
	var new_name := name.strip_edges()
	if new_name == "":
		return
	# 无论用户是否输入扩展名,都重新拼接回原始扩展名,确保改名不会弄丢文件类型。
	if preserve_ext != "":
		var base := new_name.get_basename()
		if base == "":
			base = new_name
		new_name = base + "." + preserve_ext
	await Api.update_asset(asset_id, {"original_name": new_name})
	popup.queue_free()


func _prompt_target(asset_id: int, move: bool) -> void:
	if asset_id <= 0:
		return
	var r: Dictionary = await Api.list_albums()
	if r.has("error"):
		return
	var targets: Array = []
	var trunk_id := Api.current_trunk_id
	for a in r["data"]["albums"]:
		var pid = a.get("parent_id")
		if pid == null or int(pid) != trunk_id:
			# Stay inside the current trunk: the 主相册 trunk never lists
			# 隐私 sub-albums and vice versa.
			continue
		if str(a.get("name", "")) == FAVORITE:
			continue
		if int(a["id"]) == _album_id:
			continue
		targets.append(a)
	if targets.is_empty():
		return

	var popup := AcceptDialog.new()
	popup.title = "移动到" if move else "复制到"
	var opt := OptionButton.new()
	for a in targets:
		opt.add_item(str(a["name"]))
		opt.set_item_metadata(opt.item_count - 1, int(a["id"]))
	popup.add_child(opt)
	add_child(popup)
	popup.popup_centered()
	popup.confirmed.connect(_apply_copy_move.bind(asset_id, opt, move, popup))


func _apply_copy_move(asset_id: int, opt: OptionButton, move: bool, popup: AcceptDialog) -> void:
	popup.queue_free()
	var target_id := int(opt.get_item_metadata(opt.selected))
	if target_id <= 0:
		return
	await Api.add_asset_to_album(target_id, asset_id)
	if move:
		await _remove_from_source(asset_id)
	_refresh_grid.call_deferred()


## Move semantics: in a normal album the source is the current album. In the
## 全部 (aggregate trunk) view, there is no single source, so moving a photo
## de-orphans it from the 散照 bucket (it was scattered there or already a
## member elsewhere) — the photo then belongs to the target album.
func _remove_from_source(asset_id: int) -> void:
	if _is_all:
		if Api.scatter_album_id > 0:
			await Api.remove_asset_from_album(Api.scatter_album_id, asset_id)
	else:
		await Api.remove_asset_from_album(_album_id, asset_id)


func _delete_asset(asset_id: int) -> void:
	if asset_id <= 0:
		return
	if not await Lock.require_unlock():
		return
	# Active delete = soft delete into the cloud recycle bin (7-day window).
	var r: Dictionary = await Api.delete_asset(asset_id)
	if r.has("error"):
		# Cloud unreachable: drop local artifacts now and queue the cloud
		# soft-delete as a tombstone to retry on the next sync.
		Sync.tombstone_delete(asset_id)
		_set_mode_status(false, "已标记删除,联网后同步删除")
	else:
		Sync.remove_local(asset_id)
	_refresh_grid.call_deferred()


# --- Upload (PC file dialog / Android photo picker) --------------------------

## Upload target: the current album; for the 全部 aggregate view the trunk's
## 散照 bucket (the data-layer home for un-orphaned photos).
func _upload_album_id() -> int:
	if _is_all:
		return Api.scatter_album_id
	return _album_id


func _upload() -> void:
	if _upload_album_id() <= 0:
		_set_mode_status(false, "无可用上传相册")
		return
	if OS.get_name() == "Android":
		Lock.open_photo_picker()
		return
	var fd := FileDialog.new()
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILES
	fd.filters = PackedStringArray([
		"*.png,*.jpg,*.jpeg,*.webp,*.gif ; 图片",
		"*.mp4,*.mov,*.mkv,*.webm ; 视频",
	])
	fd.files_selected.connect(_on_files_selected)
	add_child(fd)
	fd.popup_centered()


func _on_files_selected(paths: PackedStringArray) -> void:
	var total := paths.size()
	var done := 0
	for p in paths:
		var name := p.get_file()
		var media_type := "video" if _is_video(name) else "image"
		var taken_at := int(FileAccess.get_modified_time(p))
		await Api.upload_asset(p, name, media_type, taken_at, _upload_album_id())
		done += 1
		if total > 0:
			progress.value = float(done) / float(total)
	_refresh_grid.call_deferred()


func _on_picker_result(uris: Array) -> void:
	for uri in uris:
		var name := _name_from_uri(uri)
		var dest := ProjectSettings.globalize_path("user://photos/" + name)
		if Lock.read_media_bytes(uri, dest):
			var media_type := "video" if _is_video(name) else "image"
			await Api.upload_asset(dest, name, media_type, int(FileAccess.get_modified_time(dest)), _upload_album_id())
			DirAccess.remove_absolute(dest)
	_refresh_grid.call_deferred()


func _is_video(name: String) -> bool:
	match name.get_extension().to_lower():
		"mp4", "mov", "mkv", "webm":
			return true
		_:
			return false


func _name_from_uri(uri: String) -> String:
	var parts := uri.split("/")
	return parts[parts.size() - 1] if not parts.is_empty() else "import"


# --- Misc --------------------------------------------------------------------

func _go_back() -> void:
	get_tree().change_scene_to_file("res://scenes/albums.tscn")
