extends Control
## Album browser: three parallel trunks — 系统相册 (this device's own gallery, the
## one the app opens on), 红泥相册 (the cloud backup) and 红泥隐私相册 (cloud,
## hidden) — switched with the top-bar tabs. Each trunk shows the same
## multi-column card grid (收藏 / 全部 / 视频 / sub-albums in the cloud trunks,
## 全部 / 视频 / one card per device album in the system trunk); selecting a card
## opens album_view.tscn, the one photo grid all three share.
##
## 系统相册 is the browsing surface: the device keeps its own storage, its own
## app still works without hongni, and the cloud shows up as the ☁ 已备份 state
## on each item plus an album mirroring each device album. 红泥相册 is where the
## cloud side is managed (albums, favourites, recycle bin).
##
## The 散照 bucket is retained in the data layer only: it is folded into the
## 全部 card (a trunk aggregation) and never shown as a standalone card. The
## 视频 card is a virtual album too: the 全部 aggregation filtered to videos
## (server-side `?filter=videos`), hidden when there is no video at all.
## Long-press a cloud album card for the album menu (rename/delete); device
## albums are the device's own and have no menu (tap opens them).

const LONG_PRESS := 0.5
const TRUNK_SYSTEM := "系统相册"
const FAVORITE := "收藏"
# Virtual cards: 全部 is the trunk itself (server aggregates its members), 视频
# is that aggregation restricted to videos by the server-side media filter.
const ALL := "全部"
# Only for its static dropdown-sizing helper: the move picker must measure names
# the same way the asset menu's does, and that logic lives in one place.
const ASSET_MENU := preload("res://scripts/asset_menu.gd")
const VIDEO := "视频"
const VIDEO_FILTER := "videos"
const TRUNK_COLUMNS := 2
# Card is just the preview icon (mostly) plus a single-line name label. Width is
# what caps this: 2 columns + the 16px h_separation must fit the 600px base
# viewport (592 of 600).
const CARD_SIZE := Vector2(288, 276)
# Top-bar icon buttons (+ / ⋮): square touch targets sized like 返回.
const TOP_BTN_SIZE := Vector2(72, 72)

enum MenuId { RENAME, DELETE_ALBUM, MOVE_ALBUM, COPY_ALBUM }
enum MoreId { TRASH, SYNC, SETTINGS }

## Destination of an album-level 移动/复制: one of the three trunks' roots. An
## album only ever hangs off a trunk root — its photos are what choose freely
## between the other trunks' 散件 and this trunk's other sub-albums.
enum TargetId { CLOUD, PRIVATE, DEVICE }

var card_grid: GridContainer
var progress: ProgressBar
var btn_trunk_album: Button
var btn_trunk_system: Button
var btn_trunk_private: Button
var btn_new: Button
var status_label: Label
var ctx_menu: PopupMenu
var more_menu: PopupMenu

var current_trunk: String = TRUNK_SYSTEM
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

# Context target for the active album menu: a cloud album id + name, or a
# device album's bucket id (empty for a cloud album).
var _ctx_album_id := 0
var _ctx_album_name := ""
var _ctx_device_bucket := ""


func _ready() -> void:
	# The active trunk survives the scene switches into album_view / viewer /
	# trash / 设置 — they all come back here — so 返回 lands where the user left
	# off instead of always resetting to 红泥相册.
	current_trunk = _restore_trunk()
	_build_ui()
	_sync_trunk_state()
	Cache.enforce_cache()
	_reload_context.call_deferred()
	# 红泥相册 / 隐私相册 keep themselves current: entering the album browser pulls
	# the cloud side (remote changes, queued deletes). The device gallery is only
	# backed up when the user asks for it — 立即同步.
	if Store.is_configured():
		Sync.sync_cloud.call_deferred()


## Trunk to re-open on: the one loaded last this session (`Api.current_trunk`),
## which starts on 系统相册. 隐私 only when the session is unlocked — restoring
## the tab must not slip past the PIN gate.
func _restore_trunk() -> String:
	match Api.current_trunk:
		Api.TRUNK_CLOUD:
			return Api.TRUNK_CLOUD
		Api.TRUNK_PRIVATE:
			return Api.TRUNK_PRIVATE if Lock.is_unlocked() else TRUNK_SYSTEM
	return TRUNK_SYSTEM


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
	btn_trunk_album = _make_trunk_button(Api.TRUNK_CLOUD, "红泥相册", trunk_group)
	btn_trunk_system = _make_trunk_button(TRUNK_SYSTEM, "系统相册", trunk_group)
	btn_trunk_private = _make_trunk_button(Api.TRUNK_PRIVATE, "隐私相册", trunk_group)
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
	btn_new.custom_minimum_size = TOP_BTN_SIZE
	btn_new.add_theme_font_size_override("font_size", 24)
	btn_new.pressed.connect(_new_album)
	top.add_child(btn_new)

	# "更多" (four-dot ⋮) dropdown: 隐私相册 / 最近删除 / 立即同步 / 设置.
	var more_btn := Button.new()
	more_btn.text = "⋮"
	more_btn.focus_mode = Control.FOCUS_NONE
	more_btn.custom_minimum_size = TOP_BTN_SIZE
	more_btn.add_theme_font_size_override("font_size", 24)
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
	if btn.has_meta("device_bucket"):
		_open_device_album(str(btn.get_meta("device_bucket")), str(btn.get_meta("album_name", "")))
	elif btn.has_meta("album_id"):
		_open_album(int(btn.get_meta("album_id")), str(btn.get_meta("album_name", "")), str(btn.get_meta("album_filter", "all")))


func _on_long_press(btn: BaseButton) -> void:
	if btn.has_meta("device_bucket"):
		_show_device_album_menu(str(btn.get_meta("device_bucket")), str(btn.get_meta("album_name", "")))
	elif btn.has_meta("album_id"):
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
	if name == Api.TRUNK_PRIVATE and not await Lock.require_unlock():
		_sync_trunk_state()
		return
	current_trunk = name
	_sync_trunk_state()
	_reload_context.call_deferred()


## Reflects the active trunk on the three tabs and adapts the rest of the bar:
## the device trunk has no 新建相册 (its albums belong to the device) and no
## 最近删除 (the recycle bin is cloud-side).
func _sync_trunk_state() -> void:
	btn_trunk_album.button_pressed = current_trunk == Api.TRUNK_CLOUD
	btn_trunk_system.button_pressed = current_trunk == TRUNK_SYSTEM
	btn_trunk_private.button_pressed = current_trunk == Api.TRUNK_PRIVATE
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
		elif n in Api.SCRATCH_BUCKETS:
			Api.scatter_album_id = int(a["id"])
		else:
			subs.append(a)

	# Device-gallery uploads always land in 红泥相册 (its 散照 bucket), whichever
	# trunk is currently on screen; remember it while we have the list at hand.
	if current_trunk == Api.TRUNK_CLOUD:
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
		_add_device_card(str(a["id"]), str(a["name"]), int(a["count"]), a["cover"], true)


## One device album card: same card shape as the cloud ones. Real device albums
## (album_card = true) also answer a long press with the menu that sends them to
## a cloud trunk — 全部/视频 are virtual aggregations and stay tap-only, as does
## the album itself being the device's own.
func _add_device_card(bucket_id: String, name: String, count: int, cover, album_card := false) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = CARD_SIZE
	btn.text = name
	btn.tooltip_text = "%d 项" % count
	btn.set_meta("album_name", name)
	if album_card:
		btn.set_meta("device_bucket", bucket_id)
		_bind_long_press(btn)
	else:
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
	# renamed, deleted, or handed to another trunk from here.
	if album_id <= 0 or album_id == Api.current_trunk_id or album_id == Api.favorite_album_id:
		return
	_ctx_album_id = album_id
	_ctx_album_name = album_name
	_ctx_device_bucket = ""
	ctx_menu.clear()
	ctx_menu.add_item("移动到", MenuId.MOVE_ALBUM)
	ctx_menu.add_item("复制到", MenuId.COPY_ALBUM)
	ctx_menu.add_item("改名", MenuId.RENAME)
	ctx_menu.add_item("删除相册", MenuId.DELETE_ALBUM)
	ctx_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


## Menu for a device album (系统相册). The device owns the album and its files, so
## the only actions are pushing them into a cloud trunk: 移动到 红泥相册/隐私相册,
## or 复制到 (which leaves the device's own files in place).
func _show_device_album_menu(bucket_id: String, album_name: String) -> void:
	if bucket_id == "" or bucket_id == DeviceMedia.ALL_BUCKET or bucket_id == DeviceMedia.VIDEO_BUCKET:
		return
	_ctx_album_id = 0
	_ctx_album_name = album_name
	_ctx_device_bucket = bucket_id
	ctx_menu.clear()
	ctx_menu.add_item("移动到", MenuId.MOVE_ALBUM)
	ctx_menu.add_item("复制到", MenuId.COPY_ALBUM)
	ctx_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _on_ctx_menu(id: int) -> void:
	var device_source := _ctx_device_bucket != ""
	match id:
		MenuId.MOVE_ALBUM:
			_prompt_album_target("移动「%s」到" % _ctx_album_name, device_source,
				_apply_album_transfer.bind(true, _ctx_device_bucket, _ctx_album_id, _ctx_album_name))
		MenuId.COPY_ALBUM:
			_prompt_album_target("复制「%s」到" % _ctx_album_name, device_source,
				_apply_album_transfer.bind(false, _ctx_device_bucket, _ctx_album_id, _ctx_album_name))
		MenuId.RENAME:
			await _rename_album(_ctx_album_id, _ctx_album_name)
		MenuId.DELETE_ALBUM:
			await _delete_album(_ctx_album_id, _ctx_album_name)


# --- 移动到 / 复制到 (album) --------------------------------------------------

## Album destination picker. The targets are the THREE trunks' roots only — an
## album is never nested inside another album, while the photos *within* an album
## choose freely (other trunks' 散件 + this trunk's other sub-albums, see the asset
## menu). A cloud album's own trunk is left out: moving there would change
## nothing, and copying there would only duplicate the album beside itself.
## `on_pick(target)` receives {kind, trunk, label}.
func _prompt_album_target(title: String, device_source: bool, on_pick: Callable) -> void:
	var options: Array = []
	for t in [Api.TRUNK_CLOUD, Api.TRUNK_PRIVATE]:
		if not device_source and t == current_trunk:
			continue
		options.append({
			"kind": TargetId.CLOUD if t == Api.TRUNK_CLOUD else TargetId.PRIVATE,
			"trunk": t,
			"label": _target_label(t, device_source),
		})
	if not device_source:
		options.append({
			"kind": TargetId.DEVICE,
			"trunk": "",
			"label": "系统相册（Pictures/%s）" % ASSET_MENU.EXPORT_DIR_NAME,
		})
	if options.is_empty():
		_set_status_notice("没有可移动到的相册")
		return

	var labels: Array = []
	var popup := AcceptDialog.new()
	popup.title = title
	var opt := OptionButton.new()
	for o in options:
		opt.add_item(str(o["label"]))
		opt.set_item_metadata(opt.item_count - 1, o)
		labels.append(str(o["label"]))
	popup.add_child(opt)
	add_child(popup)
	opt.custom_minimum_size.x = ASSET_MENU.picker_width(opt, labels)
	popup.confirmed.connect(_on_target_picked.bind(opt, popup, on_pick))
	popup.canceled.connect(popup.queue_free)
	popup.popup_centered()


## How a trunk is offered as a destination: a device album keeps its own
## grouping in 红泥相册 (one cloud album per device album) but has no counterpart
## in 隐私相册, where everything lands in 散照.
func _target_label(trunk: String, device_source: bool) -> String:
	if trunk == Api.TRUNK_CLOUD:
		return "红泥相册（按本机相册归位）" if device_source else "红泥相册"
	return "隐私相册（散照）" if device_source else "隐私相册"


func _on_target_picked(opt: OptionButton, popup: AcceptDialog, on_pick: Callable) -> void:
	var target = opt.get_item_metadata(opt.selected)
	if is_instance_valid(popup):
		popup.queue_free()
	if target is Dictionary and not (target as Dictionary).is_empty():
		on_pick.call(target)


## Runs a picked album destination. A device album's photos are uploaded into the
## target trunk; a cloud album is re-parented (移动) or duplicated (复制) there, or
## exported to the device gallery.
func _apply_album_transfer(target: Dictionary, move: bool, bucket: String, album_id: int, album_name: String) -> void:
	if bucket != "":
		await _upload_device_album(bucket, album_name, move, target)
		return
	if int(target["kind"]) == TargetId.DEVICE:
		await _album_to_device(album_id, move)
	elif move:
		await _reparent_album(album_id, target)
	else:
		await _duplicate_album(album_id, album_name, target)


## 移动到 (cloud): the album itself changes hands — the server re-parents it under
## the target trunk's root, merging it into a same-named album already sitting
## there (its photos move in, its child albums are re-parented) in one
## transaction; a client-side sequence of membership calls could not do that
## safely, and would also mean one request per photo.
func _reparent_album(album_id: int, target: Dictionary) -> void:
	var trunk := str(target["trunk"])
	if trunk == Api.TRUNK_PRIVATE and not await Lock.require_unlock():
		return
	var root := await _trunk_root_id(trunk)
	if root <= 0:
		_set_status_notice("找不到「%s」顶层相册" % target["label"])
		return
	var res: Dictionary = await Api.move_album(album_id, root)
	if res.has("error"):
		_set_status_notice("移动失败：" + str(res["error"]))
		_reload_context.call_deferred()
		return
	var data: Dictionary = res.get("data", {})
	if data.get("merged_into") != null:
		_set_status_notice("已并入同名相册（并入 %d 项）" % int(data.get("moved", 0)))
	else:
		_set_status_notice("已移动到 %s" % target["label"])
	_reload_context.call_deferred()


## 复制到 (cloud): the album is duplicated under the target trunk — same name
## (merged into an existing same-named album there, exactly like a move), same
## members. Assets are shared, never re-uploaded: a copy adds album memberships.
func _duplicate_album(album_id: int, album_name: String, target: Dictionary) -> void:
	var trunk := str(target["trunk"])
	if trunk == Api.TRUNK_PRIVATE and not await Lock.require_unlock():
		return
	var root := await _trunk_root_id(trunk)
	if root <= 0:
		_set_status_notice("找不到「%s」顶层相册" % target["label"])
		return
	var members: Dictionary = await _album_assets(album_id)
	if not bool(members["complete"]):
		_set_status_notice("无法读取相册内容，已取消")
		return
	var host := await _find_or_create_album(root, album_name, trunk == Api.TRUNK_PRIVATE)
	if host <= 0:
		_set_status_notice("复制失败：无法建立目标相册")
		return
	var assets: Array = members["assets"]
	var copied := 0
	for a in assets:
		var id := int(a.get("id", 0))
		if id <= 0:
			continue
		var r: Dictionary = await Api.add_asset_to_album(host, id)
		if not r.has("error"):
			copied += 1
	var note := "已复制到 %s（%d 项）" % [target["label"], copied]
	if copied < assets.size():
		note += "；%d 项失败" % (assets.size() - copied)
	_set_status_notice(note)
	_reload_context.call_deferred()


## 复制/移动到系统相册: the album's photos are written into Pictures/红泥 (Android's
## gallery insert is images-only, so videos are counted separately) and, for a
## move, the cloud copies are soft-deleted into the recycle bin. The emptied
## album is dropped too — but only when every member really made it across, so a
## video that had to be skipped keeps its album (and its place in the gallery).
func _album_to_device(album_id: int, move: bool) -> void:
	var members: Dictionary = await _album_assets(album_id)
	if not bool(members["complete"]):
		_set_status_notice("无法读取相册内容，已取消")
		return
	var assets: Array = members["assets"]
	if assets.is_empty():
		_set_status_notice("该相册是空的")
		return
	var r: Dictionary = await Sync.export_assets_to_device(assets, move)
	var written := int(r["written"])
	var note := "已%s到系统相册 %d 项" % ["移动" if move else "复制", written]
	if int(r["skipped_video"]) > 0:
		note += "（跳过视频 %d）" % int(r["skipped_video"])
	if move and written == assets.size():
		if await _has_child_albums(album_id):
			note += "；相册保留（含子相册）"
		else:
			await Api.delete_album(album_id)
	_set_status_notice(note)
	_reload_context.call_deferred()


## 系统相册 → cloud: uploads one device album's items into the target trunk, then
## 移动 removes the device's own files — but only the ones whose cloud copy is
## really there (Android shows its own confirmation for the delete).
func _upload_device_album(bucket_id: String, album_name: String, move: bool, target: Dictionary) -> void:
	var trunk := str(target["trunk"])
	if trunk == Api.TRUNK_PRIVATE and not await Lock.require_unlock():
		return
	var items := DeviceMedia.bucket_items(bucket_id)
	if items.is_empty():
		_set_status_notice("「%s」没有可上传的项目" % album_name)
		return
	# 红泥相册 keeps the device album's own grouping (a cloud album per device
	# album); 隐私相册 has no counterpart, so its files land in that trunk's 散照.
	var album_id := 0
	if int(target["kind"]) == TargetId.CLOUD:
		album_id = await Api.resolve_device_album(album_name)
	else:
		album_id = await Api.resolve_scatter_album(Api.TRUNK_PRIVATE)
	if album_id <= 0:
		_set_status_notice("无法准备目标相册")
		return

	var done: Array = []
	var failed := 0
	progress.value = 0.0
	progress.max_value = float(items.size())
	# One index write for the whole album instead of one per uploaded photo.
	Store.begin_batch()
	for it in items:
		var r: Dictionary = await Sync.upload_device_item(it, album_id)
		if int(r.get("asset_id", 0)) > 0:
			done.append(it)
		else:
			failed += 1
		progress.value = float(done.size() + failed)
	Store.end_batch()
	progress.max_value = 1.0
	progress.value = 0.0

	var note := "已上传 %d 项到 %s" % [done.size(), str(target["label"])]
	if move and not done.is_empty():
		note += "；已从本机删除 %d 项" % (await DeviceMedia.delete_items(done)).size()
	if failed > 0:
		note += "（%d 项失败）" % failed
	_set_status_notice(note)
	_reload_context.call_deferred()


## Every asset of an album, following the server's cursor paging.
## {"assets": [...], "complete": bool} — complete is false when a page failed, and
## the callers then abort instead of acting on a partial album.
func _album_assets(album_id: int) -> Dictionary:
	var out: Array = []
	var cursor := ""
	while true:
		var r: Dictionary = await Api.list_assets("all", album_id, cursor)
		if r.has("error"):
			return {"assets": out, "complete": false}
		var data: Dictionary = r["data"]
		var page = data.get("assets", [])
		if page is Array:
			out.append_array(page)
		cursor = str(data.get("next_cursor", ""))
		if cursor == "":
			break
	return {"assets": out, "complete": true}


## Host album for a copy: the same-named child of `root` when one is already
## there (copying into it merges, as the server's move does), otherwise a new one.
func _find_or_create_album(root: int, name: String, hidden: bool) -> int:
	var r: Dictionary = await Api.list_albums()
	if r.has("error"):
		return 0
	for a in r["data"]["albums"]:
		var pid = a.get("parent_id")
		if pid != null and int(pid) == root and str(a.get("name", "")) == name:
			return int(a["id"])
	var created: Dictionary = await Api.create_album(name, root, hidden, "two_way")
	if created.has("error"):
		return 0
	return int(created["data"]["id"])


func _has_child_albums(album_id: int) -> bool:
	var r: Dictionary = await Api.list_albums()
	if r.has("error"):
		return true  # unknown: keep the album rather than risk orphaning children
	for a in r["data"]["albums"]:
		var pid = a.get("parent_id")
		if pid != null and int(pid) == album_id:
			return true
	return false


func _trunk_root_id(trunk: String) -> int:
	var r: Dictionary = await Api.list_albums()
	if r.has("error"):
		return 0
	return _top_level_id(r["data"]["albums"], trunk)


func _top_level_id(albums: Array, name: String) -> int:
	for a in albums:
		if a.get("parent_id") == null and str(a.get("name", "")) == name:
			return int(a["id"])
	return 0


## One-off status line (the album list keeps its own status otherwise).
func _set_status_notice(text: String) -> void:
	status_label.text = text


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


## Album deletion. An empty album (no members, no sub-albums) goes out on the
## tap; anything still holding something asks first, because the server's
## `ON DELETE CASCADE` sweeps the whole sub-album sub-tree in one statement and
## the album row is what its photos hang off. The server trashes whatever it
## would otherwise orphan (store.DeleteAlbum), so the confirmation is about the
## album tree going away — the photos land in the recycle bin, not in limbo.
func _delete_album(album_id: int, album_name: String) -> void:
	if album_id <= 0:
		return
	var scope: Dictionary = await _album_delete_scope(album_id)
	if bool(scope["empty"]):
		await _do_delete_album(album_id)
		return
	var popup := ConfirmationDialog.new()
	popup.title = "删除相册"
	popup.ok_button_text = "删除"
	popup.dialog_text = _delete_album_warning(album_name, scope)
	popup.confirmed.connect(_on_delete_album_confirmed.bind(popup, album_id))
	popup.canceled.connect(popup.queue_free)
	add_child(popup)
	popup.popup_centered()


## What deleting `album_id` would take with it: its own members (first page —
## enough to tell empty from not empty, `more` says the count is a floor) and its
## direct sub-albums, which the cascade deletes as well. `empty` is true only
## when both are; an unreadable scope reports non-empty so the confirm still
## shows rather than risking a blind cascade.
func _album_delete_scope(album_id: int) -> Dictionary:
	var members := 0
	var more := false
	var children: Array = []
	var known := true
	var ra: Dictionary = await Api.list_assets("all", album_id)
	if ra.has("error"):
		known = false
	else:
		var page = ra["data"].get("assets", [])
		if page is Array:
			members = page.size()
		more = str(ra["data"].get("next_cursor", "")) != ""
	var rl: Dictionary = await Api.list_albums()
	if rl.has("error"):
		known = false
	else:
		for a in rl["data"]["albums"]:
			var pid = a.get("parent_id")
			if pid != null and int(pid) == album_id:
				children.append(str(a.get("name", "")))
	return {
		"members": members,
		"more": more,
		"children": children,
		"empty": known and members == 0 and children.is_empty(),
	}


## The one line the confirmation shows: what is about to be lost, and what is not.
## The server trashes the members it would otherwise orphan (with the album's name
## attached), so the promise here is the recycle bin, not 全部.
func _delete_album_warning(album_name: String, scope: Dictionary) -> String:
	var bits: Array = []
	var members := int(scope["members"])
	if members > 0:
		bits.append("超过 %d 张照片" % members if bool(scope["more"]) else "%d 张照片" % members)
	var children: Array = scope["children"]
	if not children.is_empty():
		var shown: Array = children.slice(0, 3)
		if shown.size() < children.size():
			shown.append("…")
		bits.append("%d 个子相册：%s" % [children.size(), "、".join(shown)])
	var holding := "（%s）" % "、".join(bits) if not bits.is_empty() else ""
	return "删除相册「%s」%s？\n相册会连同子相册一并删除；里面的照片移入最近删除（30 天内可恢复，恢复时按名字重建相册），与别的相册共享的照片不受影响。" % [album_name, holding]


func _on_delete_album_confirmed(popup: ConfirmationDialog, album_id: int) -> void:
	if is_instance_valid(popup):
		popup.queue_free()
	await _do_delete_album(album_id)


## Sends the delete and reports the server's answer: nothing is dropped locally,
## so a rejected request leaves the grid exactly as it was.
func _do_delete_album(album_id: int) -> void:
	var r: Dictionary = await Api.delete_album(album_id)
	if r.has("error"):
		_set_status_notice("删除相册失败：%s" % str(r["error"]))
		return
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
	var res: Dictionary = await Api.create_album(album_name, trunk_id, current_trunk == Api.TRUNK_PRIVATE, "two_way")
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
	# The sync mirrors device deletions into the cloud, so its result — including
	# how many cloud items it removed — must be visible, not just the label.
	if not Sync.backup_finished.is_connected(_on_backup_finished):
		Sync.backup_finished.connect(_on_backup_finished)
	Sync.run_sync.call_deferred()


func _on_backup_finished(_success: bool, message: String) -> void:
	progress.value = 0.0
	# A sync that mirrored deletions changes what the device trunk lists.
	if current_trunk == TRUNK_SYSTEM:
		_reload_context.call_deferred()
	status_label.text = message


func _on_progress(done: int, total: int) -> void:
	if total > 0:
		progress.value = float(done) / float(total)


func _open_settings() -> void:
	get_tree().change_scene_to_file("res://scenes/settings.tscn")
