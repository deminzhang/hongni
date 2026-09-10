extends Control
## Photo grid for one album — a cloud album, one of the trunk virtual views
## (全部 = the trunk aggregation, 视频 = that aggregation restricted to videos),
## or a device (系统相册) album. Tapping a photo opens viewer.tscn; long-pressing
## one switches to multi-select (a checkbox on every cell), which the bottom
## bar's ⋮ menu turns into batch actions: 收藏/移动到/复制到/删除 for cloud
## assets, 上传到红泥/详细 for device media.
##
## Album context (Api.current_album_id / current_filter / current_device_bucket /
## current_album_name) is set by albums.gd before changing to this scene. When
## current_album_id equals the active trunk id this is the "全部" view (server
## aggregates trunk members); api.current_device_bucket set means a device album.

const ASSET_MENU := preload("res://scripts/asset_menu.gd")

const THUMB_SIZE := 140
const LONG_PRESS := 0.5
const RENDER_CHUNK := 150
# Device thumbnails per frame on Android: the plugin decodes on the calling
# thread (ContentResolver + PNG write), so a whole grid cannot be done at once.
const DEVICE_THUMB_PER_FRAME := 2

var grid: GridContainer
var progress: ProgressBar
var status_label: Label
var scroll: ScrollContainer
var label_title: Label
var btn_select: Button
var btn_all: Button
var btn_menu: Button
# Shared per-asset action menu (⋮): the former long-press menu + 详细.
var asset_menu: Control

# Current album's full member list (viewer navigation) + chunked-render state.
var _assets_full: Array = []
var _rendered := 0
var _grid_gen := 0
var _rendering := false

# Album context resolved from Api at ready time.
var _album_id: int = 0
var _album_name: String = ""
var _is_all: bool = false
# Server-side media filter of this view ("all", or "videos" for the virtual
# 视频 album, which is the trunk aggregation restricted to videos).
var _filter: String = "all"
# Non-empty when this grid shows the device gallery: the device bucket (or
# DeviceMedia.ALL_BUCKET), "" for the cloud trunks.
var _device_bucket: String = ""
var _is_device: bool = false

# Device cells by item key (thumbnails arrive asynchronously), and the device
# items still waiting for their Android thumbnail decode.
var _cell_by_key: Dictionary = {}
var _thumb_queue: Array = []

# Multi-select: entered by long-pressing a cell or the bottom 选择 button.
var _select_mode := false
# asset key (String) -> true for the cells currently checked.
var _selected: Dictionary = {}
# Last cell touched (tapped or long-pressed): the ⋮ menu's target while nothing
# is selected, so the menu still works outside multi-select.
var _ctx_asset: Dictionary = {}

# Long-press state.
var _lp_suppress := false
var _lp_held := false
var _lp_token := 0

# True once the album list failed to load (offline / weak cloud): thumbnails are
# then never fetched over the network, so the grid stays instant.
var _offline := false
# Status line without the selection counter on top, so leaving select mode
# restores it (the device trunk shows a live 本机 N 项 count there).
var _base_status := ""
# Video thumbnails are extracted on a background thread (Android). Track which
# asset ids are in flight (to avoid re-firing) and which failed permanently
# (never retry this session).
var _video_thumb_pending: Dictionary = {}
var _video_thumb_failed: Dictionary = {}


func _ready() -> void:
	_album_id = Api.current_album_id
	_album_name = Api.current_album_name
	_device_bucket = Api.current_device_bucket
	_is_device = _device_bucket != ""
	_is_all = (not _is_device and _album_id > 0 and _album_id == Api.current_trunk_id)
	# 设备相册由设备自己分组(视频卡走 VIDEO_BUCKET),云端才谈得上媒体过滤。
	_filter = "all" if _is_device else Api.current_filter
	_build_ui()
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

	# --- Bottom action row: 选择 / 全选 + the ⋮ menu (rightmost) ---
	var bottom := HBoxContainer.new()
	root.add_child(bottom)

	btn_select = Button.new()
	btn_select.text = "选择"
	btn_select.pressed.connect(_toggle_select_mode)
	bottom.add_child(btn_select)

	btn_all = Button.new()
	btn_all.text = "全选"
	btn_all.pressed.connect(_toggle_select_all)
	bottom.add_child(btn_all)

	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom.add_child(bottom_spacer)

	btn_menu = Button.new()
	btn_menu.text = "⋮"
	btn_menu.focus_mode = Control.FOCUS_NONE
	btn_menu.custom_minimum_size = Vector2(44, 44)
	btn_menu.pressed.connect(_show_asset_menu)
	bottom.add_child(btn_menu)

	# --- Shared asset menu (详细 / 收藏 / 移动到 / 复制到 / 重命名 / 删除) ---
	asset_menu = ASSET_MENU.new()
	asset_menu.changed.connect(_on_menu_changed)
	asset_menu.notice.connect(_on_menu_notice)
	asset_menu.setup(self, _move_source_album)
	_sync_select_ui()


# --- Loading ----------------------------------------------------------------

func _load() -> void:
	if _is_device:
		_refresh_device_grid()
		return
	if _album_id <= 0:
		status_label.text = "无效相册"
		return
	# 网格先用本地缓存即时渲染;云端在后台刷新,互不阻塞渲染与网络。
	_refresh_grid.call_deferred()


## Device (系统相册) album: items come straight from the device scan, so the grid
## renders at once and never waits on the cloud.
func _refresh_device_grid() -> void:
	_clear_grid()
	_assets_full = DeviceMedia.bucket_items(_device_bucket)
	Api.viewer_assets = _assets_full
	if _assets_full.is_empty():
		_set_mode_status(false, "该相册没有本机照片")
	else:
		_set_mode_status(false, "本机 %d 项" % _assets_full.size())
	_render_cells(0)


## Loads one album's complete member list by paging the server (members are
## returned newest-first). Any network failure falls back to the offline
## snapshot; successful loads write the snapshot through to the cache.
func _fetch_album_assets(album_id: int) -> Dictionary:
	if _offline:
		return {"assets": Cache.offline_assets(album_id, _filter), "offline": true}
	var out: Array = []
	var cursor := ""
	while true:
		var r: Dictionary = await Api.list_assets(_filter, album_id, cursor)
		if r.has("error"):
			return {"assets": Cache.offline_assets(album_id, _filter), "offline": true}
		var data: Dictionary = r["data"]
		out.append_array(data["assets"])
		cursor = str(data.get("next_cursor", ""))
		if cursor == "":
			break
	Cache.snapshot_album_assets(album_id, out, _filter)
	return {"assets": out, "offline": false}


func _refresh_grid() -> void:
	_clear_grid()
	if _album_id <= 0:
		return
	# 离线/弱联是主线: 先用本地缓存立即铺网格(不等待网络);云端在后台线程
	# 刷新,返回后再替换。这样即使云不可达,网格也即时出现。
	var cached := Cache.offline_assets(_album_id, _filter)
	if _is_all:
		cached = _with_local_pending(cached, _filter == "videos")
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
		list = _with_local_pending(list, _filter == "videos")
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
	_cell_by_key.clear()
	_thumb_queue.clear()
	for c in grid.get_children():
		c.queue_free()


func _add_cell(a: Dictionary, index: int, gen: int) -> void:
	if DeviceMedia.is_device(a):
		_add_device_cell(a, index)
		return
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
	# Multi-select checkbox (top-right, shown only in select mode). The cell
	# itself handles the tap, so the box never swallows input.
	var check := CheckBox.new()
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	check.visible = _select_mode
	check.button_pressed = _selected.has(str(asset_id))
	check.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	btn.add_child(check)
	# 只存云(本地无原件)→ 云下载角标;两端都有则不标。
	if asset_menu.local_source_path(a) == "":
		_add_badge(btn, "↓")
	# 视频无服务端缩略图(解码不支持),用居中 ▶ 标记,便于在网格中识别。
	if str(a.get("media_type", "image")) == "video":
		_add_badge(btn, "▶", Vector2.ZERO, true)
	_load_cell_thumb(btn, asset_id, gen, str(a.get("media_type", "image")))


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


## A device (系统相册) cell: same shape as a cloud cell — checkbox, ▶ badge for
## videos, long-press → multi-select, tap → viewer — but the thumbnail comes from
## the device and tapping opens the viewer instead of uploading.
func _add_device_cell(a: Dictionary, index: int) -> void:
	var key := DeviceMedia.key_of(a)
	var btn := TextureButton.new()
	btn.custom_minimum_size = Vector2(THUMB_SIZE, THUMB_SIZE)
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	btn.set_meta("device_key", key)
	btn.set_meta("asset_index", index)
	_bind_long_press(btn)
	grid.add_child(btn)
	var check := CheckBox.new()
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	check.visible = _select_mode
	check.button_pressed = _selected.has(_asset_key(a))
	check.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	btn.add_child(check)
	# Videos carry no server thumbnail; the centered ▶ identifies them.
	if a.get("is_video", false):
		_add_badge(btn, "▶", Vector2.ZERO, true)
	_cell_by_key[key] = btn
	_request_device_thumb(a)


## Shows a cached device thumbnail at once; otherwise DeviceMedia's worker decodes
## it (desktop) or it joins the per-frame Android decode budget.
func _request_device_thumb(a: Dictionary) -> void:
	var img := DeviceMedia.cached_thumb(a, THUMB_SIZE)
	if img.get_width() > 0:
		_apply_thumb(DeviceMedia.key_of(a), img)
	elif DeviceMedia.decodes_in_caller():
		_thumb_queue.append(a)
	else:
		DeviceMedia.queue_thumb(a, THUMB_SIZE)


func _apply_thumb(key: String, img: Image) -> void:
	if img == null or img.get_width() <= 0:
		return
	var btn = _cell_by_key.get(key)
	if btn == null or not is_instance_valid(btn):
		return
	btn.texture_normal = ImageTexture.create_from_image(img)


## Drains device thumbnail work: worker results (desktop) and the Android
## per-frame decode budget (the plugin bridge is main-thread only).
func _poll_device_thumbs() -> void:
	for r in DeviceMedia.poll_thumbs():
		_apply_thumb(str(r["key"]), r["image"])
	var budget := DEVICE_THUMB_PER_FRAME
	while budget > 0 and not _thumb_queue.is_empty():
		var a: Dictionary = _thumb_queue.pop_front()
		var key := DeviceMedia.key_of(a)
		if _cell_by_key.has(key):
			_apply_thumb(key, DeviceMedia.decode_thumb_now(a, THUMB_SIZE))
		budget -= 1


# --- Selection keys ----------------------------------------------------------

## Selection key for a grid cell: cloud assets key on their asset id, device
## media on its device key. "" for cells that cannot be selected.
func _cell_key(cell: Node) -> String:
	if cell.has_meta("device_key"):
		return "d:" + str(cell.get_meta("device_key"))
	if cell.has_meta("asset_id"):
		return str(int(cell.get_meta("asset_id")))
	return ""


## Selection key for a list entry (mirrors _cell_key).
func _asset_key(a: Dictionary) -> String:
	if DeviceMedia.is_device(a):
		return "d:" + DeviceMedia.key_of(a)
	return str(int(a.get("id", 0)))


## Cloud assets and device media can be selected; a not-yet-uploaded local file
## under 全部 cannot (its tap uploads it).
func _is_selectable(a: Dictionary) -> bool:
	if DeviceMedia.is_device(a):
		return true
	return int(a.get("id", 0)) > 0


## Local files under user://photos not yet uploaded to the cloud (no sync-index
## cloud id). Merged into the 全部 / 视频 grid with an ↑ upload badge;
## `videos_only` keeps just the video files (the 视频 view).
func _local_pending(videos_only: bool = false) -> Array:
	var out: Array = []
	var dir := DirAccess.open("user://photos")
	if dir == null:
		return out
	dir.list_dir_begin()
	var n := dir.get_next()
	while n != "":
		if not dir.current_is_dir() and not n.begins_with("."):
			if videos_only and not _is_video(n):
				n = dir.get_next()
				continue
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


func _with_local_pending(list: Array, videos_only: bool = false) -> Array:
	var pending := _local_pending(videos_only)
	if pending.is_empty():
		return list
	var merged := pending
	merged.append_array(list)
	return merged


## Overlays a small badge on a cell: cloud download ⇩ / upload ⇧ at top-right
## (default), or the video ▶ centered over the picture when `centered` is true.
## The cloud badge is hidden in select mode, where the checkbox takes that spot.
func _add_badge(btn: Control, text: String, pos: Vector2 = Vector2(THUMB_SIZE - 30, 2), centered: bool = false) -> void:
	var badge := Label.new()
	badge.text = text
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge.set_meta("kind", "video" if centered else "cloud")
	badge.add_theme_font_size_override("font_size", 24 if centered else 18)
	badge.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.5)
	sb.set_corner_radius_all(4)
	badge.add_theme_stylebox_override("normal", sb)
	if centered:
		badge.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	else:
		badge.position = pos
	btn.add_child(badge)


## Fills a cell thumbnail without blocking the render loop and without waiting
## on the network when offline: cached thumbs show immediately, missing ones load
## in the background (and are skipped entirely when offline/weak).
func _load_cell_thumb(btn: TextureButton, asset_id: int, gen: int, media_type: String = "image") -> void:
	var body := Cache.read_thumb(asset_id)
	if body.is_empty():
		if _offline:
			return
		if media_type == "video" and OS.get_name() == "Android":
			# The server only stores/serves the blob (no video decode). The
			# frontend extracts a frame: ensure a LOCAL copy (downloading on
			# demand), then ask the plugin to extract from that file — reliable
			# on any device, unlike seeking an HTTP-backed MediaMetadataRetriever.
			# Runs as a background coroutine; the result lands in the plugin queue
			# drained by _process -> _poll_video_thumbs().
			if not _video_thumb_pending.has(asset_id) and not _video_thumb_failed.has(asset_id):
				_video_thumb_pending[asset_id] = true
				var name := str(btn.get_meta("asset_name", ""))
				var ext := str(btn.get_meta("asset_ext", ""))
				if ext == "":
					ext = name.get_extension().to_lower()
				_extract_video_frame(asset_id, name, ext)
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


## Applies a just-finished video thumbnail (drained from the plugin queue in
## _process) back onto its grid cell, or fails/ignores accordingly.
func _poll_video_thumbs() -> void:
	if OS.get_name() != "Android":
		return
	var finished := Lock.poll_video_thumb_finished()
	if finished.is_empty():
		return
	for asset_id in finished:
		var aid := int(asset_id)
		var key := absi(aid)
		_video_thumb_pending.erase(key)
		if aid <= 0:
			_video_thumb_failed[key] = true
			continue
		var body := Cache.read_thumb(key)
		if body.is_empty():
			continue
		for c in grid.get_children():
			if c is TextureButton and int(c.get_meta("asset_id", -1)) == key:
				var img := Image.new()
				if img.load_jpg_from_buffer(body) == OK:
					c.texture_normal = ImageTexture.create_from_image(img)
				break


## Downloads a cloud video's original into the local original cache (no-op when
## already present) and returns its user:// path, "" on failure. Frontend does
## the work; the server just serves the blob. Marks it viewed so the LRU space
## policy keeps it (it was just displayed in the grid / will be played).
func _ensure_video_local(asset_id: int, name: String, ext: String) -> String:
	if asset_id <= 0:
		return ""
	if Cache.original_cached(asset_id, name, ext):
		Cache.mark_viewed(asset_id)
		return Cache.original_path(asset_id, name, ext)
	var r: Dictionary = await Api.fetch_original(asset_id)
	if r.has("error") or r.get("status", 0) != 200:
		return ""
	var body: PackedByteArray = r["body"]
	if body.is_empty():
		return ""
	await Cache.save_original_bg(asset_id, name, body, ext)
	Cache.mark_viewed(asset_id)
	return Cache.original_path(asset_id, name, ext)


## Local-copy fallback: ensures the video is cached, then asks the plugin to
## extract a frame from the LOCAL file (no token / no HTTP seek, always reliable).
## Runs as a fire-and-forget coroutine; the result lands in the same plugin queue
## that _poll_video_thumbs drains.
func _extract_video_frame(asset_id: int, name: String, ext: String) -> void:
	var local := await _ensure_video_local(asset_id, name, ext)
	if local == "":
		# Offline / unreachable: leave the ▶ placeholder; retry next open.
		_video_thumb_pending.erase(asset_id)
		_video_thumb_failed[asset_id] = true
		return
	var dest := ProjectSettings.globalize_path(Cache.thumb_path(asset_id))
	if not Lock.extract_video_thumb(ProjectSettings.globalize_path(local), "", dest, 256, asset_id):
		_video_thumb_pending.erase(asset_id)
		_video_thumb_failed[asset_id] = true


func _process(_dt: float) -> void:
	_poll_video_thumbs()
	if _is_device:
		_poll_device_thumbs()


# --- Connectivity hint -------------------------------------------------------

func _set_mode_status(offline: bool, message: String = "") -> void:
	if message != "":
		_base_status = message
	elif offline:
		_base_status = "离线模式 · 显示本地缓存"
	else:
		_base_status = ""
	if not _select_mode:
		status_label.text = _base_status


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
	if not btn.has_meta("asset_id") and not btn.has_meta("device_key"):
		return
	if _select_mode:
		_toggle_cell_selected(btn)
		return
	_remember_target(btn)
	Api.viewer_index = int(btn.get_meta("asset_index"))
	get_tree().change_scene_to_file("res://scenes/viewer.tscn")


## Long-press switches the grid into multi-select with that cell checked. The
## former long-press menu now lives behind the bottom ⋮ button.
func _on_long_press(btn: BaseButton) -> void:
	if not btn.has_meta("asset_id") and not btn.has_meta("device_key"):
		return
	_remember_target(btn)
	if not _select_mode:
		_set_select_mode(true)
	if not _selected.has(_cell_key(btn)):
		_toggle_cell_selected(btn)


# --- Multi-select ------------------------------------------------------------

func _toggle_select_mode() -> void:
	_set_select_mode(not _select_mode)


func _set_select_mode(on: bool) -> void:
	_select_mode = on
	if not on:
		_selected.clear()
	_sync_select_ui()


func _toggle_select_all() -> void:
	if not _select_mode:
		_set_select_mode(true)
	if _all_selected():
		_selected.clear()
	else:
		for a in _assets_full:
			if _is_selectable(a):
				_selected[_asset_key(a)] = true
	_sync_select_ui()


func _toggle_cell_selected(cell: BaseButton) -> void:
	var key := _cell_key(cell)
	if key == "":
		return
	if _selected.has(key):
		_selected.erase(key)
	else:
		_selected[key] = true
	_sync_select_ui()


## Pushes the mode/selection onto every cell and onto the bottom bar: checkbox
## visibility + tick, cloud-badge visibility, 选择/全选 labels, and the counter.
func _sync_select_ui() -> void:
	btn_select.text = "取消" if _select_mode else "选择"
	btn_all.text = "取消全选" if _all_selected() else "全选"
	for cell in grid.get_children():
		_sync_cell_select(cell)
	if _select_mode:
		status_label.text = "已选 %d 项" % _selected.size()
	else:
		status_label.text = _base_status


## True when every selectable entry of the album is checked (false when the
## album holds nothing selectable at all).
func _all_selected() -> bool:
	var any := false
	for a in _assets_full:
		if not _is_selectable(a):
			continue
		any = true
		if not _selected.has(_asset_key(a)):
			return false
	return any


func _sync_cell_select(cell: Node) -> void:
	if cell.has_meta("local_path"):
		# Local-only (not yet uploaded) cell: its tap uploads, so keep it out of
		# select mode rather than let it be mistaken for a selectable photo.
		if cell is BaseButton:
			cell.disabled = _select_mode
		return
	var key := _cell_key(cell)
	if key == "":
		return
	for child in cell.get_children():
		if child is CheckBox:
			child.visible = _select_mode
			child.button_pressed = _selected.has(key)
		elif child is Label and child.get_meta("kind", "") == "cloud":
			# The checkbox takes the top-right spot while selecting.
			child.visible = not _select_mode


# --- Asset menu (⋮) ----------------------------------------------------------

func _show_asset_menu() -> void:
	asset_menu.popup(_menu_targets())


## The menu's targets: the checked cells in select mode, else the last touched
## cell — so the menu works with or without an active selection.
func _menu_targets() -> Array:
	if _select_mode and not _selected.is_empty():
		var out: Array = []
		for a in _assets_full:
			if _selected.has(_asset_key(a)):
				out.append(a)
		return out
	return [_ctx_asset] if not _ctx_asset.is_empty() else []


func _remember_target(btn: BaseButton) -> void:
	var key := _cell_key(btn)
	if key == "":
		return
	for a in _assets_full:
		if _asset_key(a) == key:
			_ctx_asset = a
			return


## Album a 移动到 detaches the photo from: in a normal album the current album.
## In the 全部 (aggregate trunk) view there is no single source, so the move
## de-orphans the photo from the 散照 bucket (0 when there is no such bucket) and
## it then belongs to the target album.
func _move_source_album() -> int:
	if _is_all:
		return Api.scatter_album_id
	return _album_id


func _on_menu_changed(_ids: Array, op: String) -> void:
	_ctx_asset = {}
	if _select_mode:
		_set_select_mode(false)
	if op == "upload":
		# 上传 copies into the cloud: the device album itself is unchanged, so
		# keep the grid (and the notice it just showed) as they are.
		return
	if not _is_device:
		_refresh_grid.call_deferred()


func _on_menu_notice(text: String) -> void:
	_set_mode_status(false, text)


# --- Upload (PC file dialog / Android photo picker) --------------------------

## Upload target: the current album; for the 全部 aggregate view the trunk's
## 散照 bucket (the data-layer home for un-orphaned photos).
func _upload_album_id() -> int:
	if _is_all:
		return Api.scatter_album_id
	return _album_id


func _is_video(name: String) -> bool:
	match name.get_extension().to_lower():
		"mp4", "mov", "mkv", "webm":
			return true
		_:
			return false


# --- Misc --------------------------------------------------------------------

func _go_back() -> void:
	get_tree().change_scene_to_file("res://scenes/albums.tscn")
