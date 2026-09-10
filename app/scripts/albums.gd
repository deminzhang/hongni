extends Control
## Album browser: three parallel trunks — 红泥相册 (cloud), 系统相册 (this device's
## own gallery) and 红泥隐私相册 (cloud, hidden) — switched with the top-bar tabs.
## Each trunk shows the same multi-column card grid (收藏 / 全部 / 视频 / sub-albums
## in the cloud trunks, 全部 / 视频 / one card per device album in the system
## trunk); selecting a card opens album_view.tscn, the one photo grid all three
## share.
##
## The 散照 bucket is retained in the data layer only: it is folded into the
## 全部 card (a trunk aggregation) and never shown as a standalone card. The
## 视频 card is a virtual album too: the 全部 aggregation filtered to videos
## (server-side `?filter=videos`), hidden when there is no video at all.
## Long-press a cloud album card for the album menu (rename/delete); device
## albums are the device's own and have no menu (tap opens them).

const LONG_PRESS := 0.5
const TRUNK_ALBUM := "相册"
const TRUNK_SYSTEM := "系统相册"
const TRUNK_PRIVATE := "隐私"
const FAVORITE := "收藏"
# Virtual cards: 全部 is the trunk itself (server aggregates its members), 视频
# is that aggregation restricted to videos by the server-side media filter.
const ALL := "全部"
const VIDEO := "视频"
const VIDEO_FILTER := "videos"
const SCRATCH_BUCKETS := ["散照", "未分类散照"]
const TRUNK_COLUMNS := 2
# Card is just the preview icon (mostly) plus a single-line name label.
const CARD_SIZE := Vector2(336, 322)

enum MenuId { RENAME, DELETE_ALBUM }
enum MoreId { TRASH, SYNC, SETTINGS }

var card_grid: GridContainer
var progress: ProgressBar
var btn_trunk_album: Button
var btn_trunk_system: Button
var btn_trunk_private: Button
var btn_new: Button
var status_label: Label
var ctx_menu: PopupMenu
var more_menu: PopupMenu

var current_trunk: String = TRUNK_ALBUM
# True when the album list failed to load (offline / weak cloud). Card previews
# then read only from the cache and never wait on the network.
var _offline := false
# Device card (系统相册 trunk) previews still decoding on DeviceMedia's worker:
# device item key -> the card button waiting for that thumbnail.
var _device_cards: Dictionary = {}

# Long-press state. _lp_suppress swallows the 'pressed' signal that fires on
# release after a long-press, so the short-click action doesn't also run.
var _lp_suppress := false
var _lp_held := false
var _lp_token := 0

# Context target for the active album menu.
var _ctx_album_id := 0
var _ctx_album_name := ""


func _ready() -> void:
	# The active trunk survives the scene switches into album_view / viewer /
	# trash / 设置 — they all come back here — so 返回 lands where the user left
	# off instead of always resetting to 红泥相册.
	current_trunk = _restore_trunk()
	_build_ui()
	_sync_trunk_state()
	Cache.enforce_cache()
	_reload_context.call_deferred()


## Trunk to re-open on: the one loaded last this session (`Api.current_trunk`).
## 隐私 only when the session is unlocked — restoring the tab must not slip past
## the PIN gate. Anything unknown falls back to 红泥相册.
func _restore_trunk() -> String:
	match Api.current_trunk:
		TRUNK_SYSTEM:
			return TRUNK_SYSTEM
		TRUNK_PRIVATE:
			return TRUNK_PRIVATE if Lock.is_unlocked() else TRUNK_ALBUM
	return TRUNK_ALBUM


func _process(_dt: float) -> void:
	# Card previews decoded on DeviceMedia's background worker (desktop).
	if _device_cards.is_empty():
		return
	for r in DeviceMedia.poll_thumbs():
		_apply_device_card_thumb(str(r["key"]), r["image"])


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# --- Top bar: the three parallel trunks, then the album actions on the right ---
	var top := HBoxContainer.new()
	root.add_child(top)

	var trunk_group := ButtonGroup.new()
	btn_trunk_album = _make_trunk_button(TRUNK_ALBUM, "红泥相册", trunk_group)
	btn_trunk_system = _make_trunk_button(TRUNK_SYSTEM, "系统相册", trunk_group)
	btn_trunk_private = _make_trunk_button(TRUNK_PRIVATE, "隐私相册", trunk_group)
	top.add_child(btn_trunk_album)
	top.add_child(btn_trunk_system)
	top.add_child(btn_trunk_private)
	# The pressed tab + bar layout come from _sync_trunk_state() in _ready, which
	# knows whether the session was left in 系统相册 / 隐私.

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	# "新建相册" rendered as a compact "+" square, just left of the ⋮ menu.
	btn_new = Button.new()
	btn_new.text = "+"
	btn_new.focus_mode = Control.FOCUS_NONE
	btn_new.custom_minimum_size = Vector2(44, 44)
	btn_new.pressed.connect(_new_album)
	top.add_child(btn_new)

	# "更多" (four-dot ⋮) dropdown: 隐私相册 / 最近删除 / 立即同步 / 设置.
	var more_btn := Button.new()
	more_btn.text = "⋮"
	more_btn.focus_mode = Control.FOCUS_NONE
	more_btn.custom_minimum_size = Vector2(44, 44)
	more_btn.pressed.connect(_show_more_menu)
	top.add_child(more_btn)

	progress = ProgressBar.new()
	progress.min_value = 0.0
	progress.max_value = 1.0
	progress.show_percentage = false
	root.add_child(progress)

	status_label = Label.new()
	root.add_child(status_label)

	# --- Album card grid (multi-column, top-to-bottom) ---
	var card_scroll := ScrollContainer.new()
	card_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	card_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root.add_child(card_scroll)

	card_grid = GridContainer.new()
	card_grid.columns = TRUNK_COLUMNS
	card_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card_grid.add_theme_constant_override("h_separation", 16)
	card_grid.add_theme_constant_override("v_separation", 16)
	card_scroll.add_child(card_grid)

	# --- Long-press context menu (album rename/delete) ---
	ctx_menu = PopupMenu.new()
	add_child(ctx_menu)
	ctx_menu.id_pressed.connect(_on_ctx_menu)

	# --- "更多" dropdown: 最近删除 / 立即同步 / 设置 (rebuilt per trunk) ---
	more_menu = PopupMenu.new()
	add_child(more_menu)
	more_menu.id_pressed.connect(_on_more_menu)
	_rebuild_more_menu()


## One trunk tab. `value` is the trunk name the rest of the app switches on
## (the cloud trunks keep their server-side names), `label` what the bar shows.
func _make_trunk_button(value: String, label: String, group: ButtonGroup) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.toggle_mode = true
	btn.button_group = group
	btn.focus_mode = Control.FOCUS_NONE
	btn.add_theme_font_size_override("font_size", 15)
	btn.pressed.connect(_on_trunk.bind(value))
	return btn


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
	if btn.has_meta("album_id"):
		_open_album(int(btn.get_meta("album_id")), str(btn.get_meta("album_name", "")), str(btn.get_meta("album_filter", "all")))


func _on_long_press(btn: BaseButton) -> void:
	if btn.has_meta("album_id"):
		_show_album_menu(int(btn.get_meta("album_id")), str(btn.get_meta("album_name", "")))


# --- Navigation --------------------------------------------------------------

## `filter` is the server-side media filter the grid should use: "all" for real
## albums and 全部, "videos" for the 视频 virtual album.
func _open_album(album_id: int, name: String, filter: String = "all") -> void:
	Api.current_album_id = album_id
	Api.current_album_name = name
	Api.current_filter = filter
	get_tree().change_scene_to_file("res://scenes/album_view.tscn")


# --- Context (trunk + buckets + sub-albums) ----------------------------------

func _on_trunk(name: String) -> void:
	if name == current_trunk:
		return
	# 红泥隐私相册 is PIN/biometric gated; a refused unlock snaps the tab back.
	if name == TRUNK_PRIVATE and not await Lock.require_unlock():
		_sync_trunk_state()
		return
	current_trunk = name
	_sync_trunk_state()
	_reload_context.call_deferred()


## Reflects the active trunk on the three tabs and adapts the rest of the bar:
## the device trunk has no 新建相册 (its albums belong to the device) and no
## 最近删除 (the recycle bin is cloud-side).
func _sync_trunk_state() -> void:
	btn_trunk_album.button_pressed = current_trunk == TRUNK_ALBUM
	btn_trunk_system.button_pressed = current_trunk == TRUNK_SYSTEM
	btn_trunk_private.button_pressed = current_trunk == TRUNK_PRIVATE
	btn_new.visible = current_trunk != TRUNK_SYSTEM
	_rebuild_more_menu()


func _rebuild_more_menu() -> void:
	more_menu.clear()
	if current_trunk != TRUNK_SYSTEM:
		more_menu.add_item("最近删除", MoreId.TRASH)
	more_menu.add_item("立即同步", MoreId.SYNC)
	more_menu.add_item("设置", MoreId.SETTINGS)


func _reload_context() -> void:
	for c in card_grid.get_children():
		c.queue_free()
	_device_cards.clear()
	if current_trunk == TRUNK_SYSTEM:
		Api.current_trunk = TRUNK_SYSTEM
		Api.current_trunk_id = 0
		Api.current_device_bucket = ""
		_reload_device_context()
		return
	Api.current_device_bucket = ""
	var r: Dictionary = await Api.list_albums()
	var albums: Array = []
	_offline = r.has("error")
	if r.has("error"):
		albums = Cache.offline_albums()
		_set_mode_status(true)
	else:
		albums = r["data"]["albums"]
		Cache.snapshot_albums(albums)
		_set_mode_status(false)

	var trunk := _find_trunk(albums, current_trunk)
	if trunk.is_empty():
		if albums.is_empty():
			status_label.text = "离线:暂无本地缓存,联网打开一次后可离线浏览"
		return

	var trunk_id := int(trunk["id"])
	Api.current_trunk = current_trunk
	Api.current_trunk_id = trunk_id
	Api.favorite_album_id = 0
	Api.scatter_album_id = 0

	var favorite := {}
	var subs: Array = []
	for a in albums:
		var pid = a.get("parent_id")
		if pid == null or int(pid) != trunk_id:
			continue
		var n := str(a.get("name", ""))
		if n == FAVORITE:
			favorite = a
			Api.favorite_album_id = int(a["id"])
		elif n in SCRATCH_BUCKETS:
			Api.scatter_album_id = int(a["id"])
		else:
			subs.append(a)

	# Device-gallery uploads always land in 红泥相册 (its 散照 bucket), whichever
	# trunk is currently on screen; remember it while we have the list at hand.
	if current_trunk == TRUNK_ALBUM:
		Api.import_album_id = Api.scatter_album_id

	# Cards: 收藏 (only when non-empty), 全部 (= trunk aggregation), 视频 (that
	# aggregation restricted to videos, hidden when the trunk holds none), then
	# the custom sub-albums.
	if not favorite.is_empty() and await _album_has_items(int(favorite["id"])):
		_add_card(FAVORITE, int(favorite["id"]))
	_add_card(ALL, trunk_id)
	if await _album_has_items(trunk_id, VIDEO_FILTER):
		_add_card(VIDEO, trunk_id, 0, VIDEO_FILTER)
	for a in subs:
		_add_card(str(a["name"]), int(a["id"]), _cover_of(a))


## Whether an album (or a filtered virtual view of it) has any members. Offline
## uses the cache snapshot (empty when not cached); online asks for one page.
func _album_has_items(album_id: int, filter: String = "all") -> bool:
	if album_id <= 0:
		return false
	if _offline:
		return not Cache.offline_assets(album_id, filter).is_empty()
	var r: Dictionary = await Api.list_assets(filter, album_id)
	if r.has("error"):
		return false
	var arr = r.get("data", {}).get("assets", [])
	return arr is Array and not arr.is_empty()


func _find_trunk(albums: Array, name: String) -> Dictionary:
	for a in albums:
		if a.get("parent_id") == null and str(a.get("name", "")) == name:
			return a
	return {}


func _add_card(label: String, album_id: int, cover_id: int = 0, filter: String = "all") -> void:
	var btn := Button.new()
	btn.custom_minimum_size = CARD_SIZE
	btn.text = label
	btn.set_meta("album_id", album_id)
	btn.set_meta("album_name", label)
	btn.set_meta("album_filter", filter)
	_bind_long_press(btn)
	card_grid.add_child(btn)
	_load_card_preview.call_deferred(album_id, btn, cover_id, filter)


## The album's locally chosen cover, 0 when it has none (the card then falls back
## to the album's newest photo). Recorded by the asset menu's 设为相册封面.
func _cover_of(a: Dictionary) -> int:
	return Store.album_cover(int(a.get("id", 0)))


func _load_card_preview(album_id: int, btn: Button, cover_id: int = 0, filter: String = "all") -> void:
	if album_id <= 0:
		return
	var list: Array
	if _offline:
		list = Cache.offline_assets(album_id, filter)
	else:
		var r: Dictionary = await Api.list_assets(filter, album_id)
		if not is_instance_valid(btn):
			return
		if r.has("error"):
			return
		Cache.snapshot_album_assets(album_id, r["data"]["assets"], filter)
		list = r["data"]["assets"]
	# 封面优先,取不到(离线未缓存 / 该照片已不在)时退回最新一张。视频没有服务端
	# 缩略图(服务端不解码视频),跳过它们,别为一张必然 404 的图跑请求。
	var candidates: Array = []
	if cover_id > 0:
		candidates.append([cover_id, ""])
	if not list.is_empty():
		candidates.append([int(list[0]["id"]), str(list[0].get("media_type", "image"))])
	var body := PackedByteArray()
	for c in candidates:
		if str(c[1]) == "video":
			continue
		body = await _preview_thumb(int(c[0]))
		if not body.is_empty():
			break
	if not is_instance_valid(btn) or body.is_empty():
		return
	var img := Image.new()
	if img.load_jpg_from_buffer(body) == OK:
		img.resize(int(CARD_SIZE.x), int(CARD_SIZE.y * 0.88), Image.INTERPOLATE_BILINEAR)
		btn.icon = ImageTexture.create_from_image(img)
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP


## Thumbnail bytes for one asset id: the local cache first, then the server when
## online. Empty when neither has it (offline and never downloaded).
func _preview_thumb(asset_id: int) -> PackedByteArray:
	if asset_id <= 0:
		return PackedByteArray()
	var body := Cache.read_thumb(asset_id)
	if body.is_empty() and not _offline:
		var t: Dictionary = await Api.fetch_thumb(asset_id)
		if not t.has("error"):
			body = t["body"]
			Cache.save_thumb(asset_id, body)
	return body


# --- 系统相册 trunk (device gallery) ------------------------------------------

## The device's own albums as cards. Everything here is local: opening this trunk
## never waits on the cloud, so it works with the server unreachable.
func _reload_device_context() -> void:
	status_label.text = "读取本机相册…"
	DeviceMedia.refresh()
	var items := DeviceMedia.items()
	var albums := DeviceMedia.albums()
	if items.is_empty():
		_set_mode_status(false, "未找到本机照片（Android 需授予相册权限）")
		return
	_set_mode_status(false, "本机 %d 项 · %d 个相册" % [items.size(), albums.size()])
	_add_device_card(DeviceMedia.ALL_BUCKET, ALL, items.size(), DeviceMedia.cover_item(items))
	var videos := DeviceMedia.bucket_items(DeviceMedia.VIDEO_BUCKET)
	if not videos.is_empty():
		_add_device_card(DeviceMedia.VIDEO_BUCKET, VIDEO, videos.size(), DeviceMedia.cover_item(videos))
	for a in albums:
		_add_device_card(str(a["id"]), str(a["name"]), int(a["count"]), a["cover"])


## One device album card: same card shape as the cloud ones, but tap-only (the
## device owns these albums, so there is nothing to rename or delete here).
func _add_device_card(bucket_id: String, name: String, count: int, cover) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = CARD_SIZE
	btn.text = name
	btn.tooltip_text = "%d 项" % count
	btn.pressed.connect(_open_device_album.bind(bucket_id, name))
	card_grid.add_child(btn)
	if not (cover is Dictionary) or cover.is_empty():
		return
	var key := DeviceMedia.key_of(cover)
	if not _device_cards.has(key):
		_device_cards[key] = []
	_device_cards[key].append(btn)
	var img := DeviceMedia.cached_thumb(cover, int(CARD_SIZE.x))
	if img.get_width() > 0:
		_apply_device_card_thumb(key, img)
	else:
		DeviceMedia.queue_thumb(cover, int(CARD_SIZE.x))


func _apply_device_card_thumb(key: String, img: Image) -> void:
	if img == null or img.get_width() <= 0 or not _device_cards.has(key):
		return
	for btn in _device_cards[key]:
		if not is_instance_valid(btn):
			continue
		btn.icon = ImageTexture.create_from_image(img)
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP


func _open_device_album(bucket_id: String, name: String) -> void:
	Api.current_album_id = 0
	Api.current_album_name = name
	Api.current_device_bucket = bucket_id
	Api.current_filter = "all"
	get_tree().change_scene_to_file("res://scenes/album_view.tscn")


# --- Connectivity hint -------------------------------------------------------

func _set_mode_status(offline: bool, message: String = "") -> void:
	if message != "":
		status_label.text = message
	elif offline:
		status_label.text = "离线模式 · 显示本地缓存"
	else:
		status_label.text = ""


# --- Context menu (album rename/delete) --------------------------------------

func _show_album_menu(album_id: int, album_name: String) -> void:
	# The trunk and built-in buckets are protected: only user sub-albums can be
	# renamed or deleted from here.
	if album_id <= 0 or album_id == Api.current_trunk_id or album_id == Api.favorite_album_id:
		return
	_ctx_album_id = album_id
	_ctx_album_name = album_name
	ctx_menu.clear()
	ctx_menu.add_item("改名", MenuId.RENAME)
	ctx_menu.add_item("删除相册", MenuId.DELETE_ALBUM)
	ctx_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _on_ctx_menu(id: int) -> void:
	match id:
		MenuId.RENAME:
			await _rename_album(_ctx_album_id, _ctx_album_name)
		MenuId.DELETE_ALBUM:
			await _delete_album(_ctx_album_id)


# --- Album actions (rename / delete) -----------------------------------------

func _rename_album(album_id: int, current: String) -> void:
	if album_id <= 0:
		return
	var popup := AcceptDialog.new()
	popup.title = "重命名相册"
	var edit := LineEdit.new()
	edit.text = current
	edit.name = "NameEdit"
	popup.add_child(edit)
	add_child(popup)
	# Same wiring as _new_album: OK must submit, and the field must own the keys.
	edit.text_submitted.connect(_do_rename_album.bind(album_id, popup, edit))
	popup.confirmed.connect(_do_rename_album.bind("", album_id, popup, edit))
	popup.popup_centered()
	edit.grab_focus()


func _do_rename_album(name: String, album_id: int, popup: AcceptDialog, edit: LineEdit) -> void:
	if not is_instance_valid(popup):
		return
	var album_name := name.strip_edges() if name.strip_edges() != "" else edit.text.strip_edges()
	if album_name == "":
		_reopen_with_error(popup, edit, "", "改名失败：", "名称不能为空")
		return
	var res: Dictionary = await Api.update_album(album_id, {"name": album_name})
	if res.has("error"):
		_reopen_with_error(popup, edit, album_name, "改名失败：", str(res["error"]))
		return
	popup.queue_free()
	_reload_context.call_deferred()


func _delete_album(album_id: int) -> void:
	if album_id <= 0:
		return
	await Api.delete_album(album_id)
	_reload_context.call_deferred()


# --- Album creation ----------------------------------------------------------

func _new_album() -> void:
	var popup := AcceptDialog.new()
	popup.title = "新建相册（" + current_trunk + "）"
	var edit := LineEdit.new()
	edit.placeholder_text = "相册名称"
	edit.name = "NameEdit"
	popup.add_child(edit)
	add_child(popup)
	# AcceptDialog hands focus to its OK button on popup, so Enter would only
	# confirm an empty field: claim focus for the field and route OK through the
	# same handler (how asset_menu.gd does its rename).
	edit.text_submitted.connect(_do_create_album.bind(popup, edit))
	popup.confirmed.connect(_do_create_album.bind("", popup, edit))
	popup.popup_centered()
	edit.grab_focus()


func _do_create_album(name: String, popup: AcceptDialog, edit: LineEdit) -> void:
	if not is_instance_valid(popup):
		return
	var album_name := name.strip_edges() if name.strip_edges() != "" else edit.text.strip_edges()
	if album_name == "":
		_reopen_with_error(popup, edit, "", "创建失败：", "名称不能为空")
		return
	# The trunk id cached by _reload_context is only trusted when it belongs to
	# the trunk on screen (a failed reload leaves the previous trunk's id there).
	var trunk_id := Api.current_trunk_id if Api.current_trunk == current_trunk else 0
	if trunk_id <= 0:
		var r: Dictionary = await Api.list_albums()
		if r.has("error"):
			_reopen_with_error(popup, edit, album_name, "创建失败：", str(r["error"]))
			return
		var trunk := _find_trunk(r["data"]["albums"], current_trunk)
		if trunk.is_empty():
			_reopen_with_error(popup, edit, album_name, "创建失败：", "找不到「" + current_trunk + "」顶层相册")
			return
		trunk_id = int(trunk["id"])
	# Unified two-way sync: every album now syncs the same way.
	var res: Dictionary = await Api.create_album(album_name, trunk_id, current_trunk == TRUNK_PRIVATE, "two_way")
	if res.has("error"):
		_reopen_with_error(popup, edit, album_name, "创建失败：", str(res["error"]))
		return
	popup.queue_free()
	_reload_context.call_deferred()


## A rejected create/rename must not look like the button doing nothing: OK has
## already hidden the dialog by the time the request resolves, so bring it back
## with the reason and the name the user typed still in the field.
func _reopen_with_error(popup: AcceptDialog, edit: LineEdit, name: String, prefix: String, reason: String) -> void:
	if not is_instance_valid(popup):
		return
	popup.dialog_text = prefix + reason
	if is_instance_valid(edit):
		edit.text = name
	popup.popup_centered()
	if is_instance_valid(edit):
		edit.grab_focus()


func _open_trash() -> void:
	get_tree().change_scene_to_file("res://scenes/trash.tscn")


func _show_more_menu() -> void:
	more_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _on_more_menu(id: int) -> void:
	match id:
		MoreId.TRASH:
			_open_trash()
		MoreId.SYNC:
			_start_backup()
		MoreId.SETTINGS:
			_open_settings()


# --- Misc -------------------------------------------------------------------

func _start_backup() -> void:
	progress.value = 0.0
	if not Sync.progress_changed.is_connected(_on_progress):
		Sync.progress_changed.connect(_on_progress)
	Sync.run_sync.call_deferred()


func _on_progress(done: int, total: int) -> void:
	if total > 0:
		progress.value = float(done) / float(total)


func _open_settings() -> void:
	get_tree().change_scene_to_file("res://scenes/settings.tscn")
