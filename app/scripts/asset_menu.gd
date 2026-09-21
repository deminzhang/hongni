extends Control
## Shared per-asset action menu, used by both the album photo grid and the
## full-screen viewer. Owns:
##   - the rightmost ⋮ PopupMenu. Cloud assets get 收藏 / 移动到 / 复制到 /
##     设为相册封面 / 重命名 / 删除 / 删本地保云端 / 详细. Device (系统相册) media gets
##     移动到 / 复制到 / 删本地保云端 / 从本机删除 / 详细 — there the device owns
##     the file, so every action either pushes a copy into the cloud or asks the
##     platform to remove the device's own file.
##   - the target picker those 移动/复制 entries need: either of the two cloud
##     trunks, a real sub-album of the current trunk, or the device gallery,
##   - the rename dialog and the bottom 详细 sheet.
##
## Call `setup(host, source_album)` once, then `popup(assets)` with the target
## assets. Mutations are reported through `changed(ids, op)` so the owner can
## refresh itself, and through `notice(text)` for user-facing one-liners —
## except 删本地保云端, which reports a notice only and leaves the screen as it is
## (see `_delete_local_keep_cloud`).

signal changed(ids: Array, op: String)
signal notice(text: String)

enum MenuId { FAV_TOGGLE, MOVE, COPY, SET_COVER, RENAME, DELETE, DETAILS, KEEP, DELETE_DEVICE }

## Where a 移动到/复制到 can send one asset:
##   ALBUM   a real sub-album under one of the trunks,
##   TRUNK   a cloud trunk as a whole — a single file lands in its 散照 (a device
##           item going to 共享相册 lands in the album mirroring its device album,
##           so the grouping the system gallery shows is the one the cloud keeps),
##   DEVICE  the device gallery itself, written as an export into Pictures/红泥.
enum TargetKind { ALBUM, TRUNK, DEVICE }

## What the picker offers: 移动/复制 lists the trunks as well as the current
## trunk's sub-albums; 设为相册封面 only lists sub-albums (a cover belongs to one
## specific cloud album).
const PICK_TARGET := 0
const PICK_COVER := 1

const DETAILS := preload("res://scripts/details_sheet.gd")
const FAVORITE := "收藏"
# Where an exported cloud photo lands on the device: the app may only add media
# it owns without a prompt, so it cannot write into the device's own albums.
const EXPORT_DIR_NAME := "红泥"
# Album picker sizing: a name must fit even when it is this many CJK
# characters long, measured on a sample of exactly that length (CJK glyphs are
# the widest case), plus the room the dropdown arrow and the button's inner
# padding need.
const PICKER_MIN_NAME_SAMPLE := "相册名称七个字"
const PICKER_CHROME_PX := 64.0

# Scene root: parent for the dialogs and the coordinate space of the sheet.
var _host: Control
# -> int: the album a 移动到 detaches from (0 = the asset has no source album,
# e.g. moving out of the 全部 aggregation with no 散照 bucket).
var _source_album: Callable = Callable()
var _menu: PopupMenu
var _sheet: PanelContainer

# Targets of the menu currently open (asset dictionaries, shared with the
# caller, so an in-place rename is visible to both).
var _targets: Array = []

# asset_id as String -> true. Seeded from the cached 收藏 snapshot (instant,
# works offline) and refreshed from the server in the background.
var _favorite_ids: Dictionary = {}


## Wires the menu into `host`. `source_album` is called when a move needs the
## album to detach the asset from.
func setup(host: Control, source_album: Callable) -> void:
	_host = host
	_source_album = source_album
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchor_left = 0.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 1.0
	offset_left = 0
	offset_right = 0
	offset_top = 0
	offset_bottom = 0
	_menu = PopupMenu.new()
	add_child(_menu)
	_menu.id_pressed.connect(_on_menu)
	_sheet = DETAILS.new()
	add_child(_sheet)
	host.add_child(self)


## Opens the menu for `assets`. `at` is the global position to pop it at; the
## mouse position is used when omitted.
func popup(assets: Array, at := Vector2.INF) -> void:
	var targets: Array = []
	for a in assets:
		if a is Dictionary:
			targets.append(a)
	if targets.is_empty():
		notice.emit("请先选择照片或视频")
		return
	_targets = targets
	var single := targets.size() == 1
	var pos := Rect2i(Vector2i(at if at != Vector2.INF else get_global_mouse_position()), Vector2i.ZERO)
	_menu.clear()
	if DeviceMedia.is_device(targets[0]):
		_device_menu(single)
	else:
		_cloud_menu(single)
	_menu.popup(pos)


## Menu for device (系统相册) media: nothing here is a cloud operation, since the
## device owns these files — the entries either push a copy up or hand the file
## back to the platform.
func _device_menu(single: bool) -> void:
	_menu.add_item("移动到", MenuId.MOVE)
	_menu.add_item("复制到", MenuId.COPY)
	_menu.add_item("删本地保云端", MenuId.KEEP)
	_menu.add_item("从本机删除", MenuId.DELETE_DEVICE)
	_menu.add_item("详细", MenuId.DETAILS)
	# 删本地保云端 needs the cloud copy that already exists (there is nothing to
	# pin otherwise), so it needs a single, already-backed-up item; 详细
	# describes one item.
	_menu.set_item_disabled(_menu.get_item_index(MenuId.KEEP), not single or _keep_target_id(_targets[0]) <= 0)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.DETAILS), not single)


## Menu for cloud assets. 收藏 is a view (the server keeps it as a real album row,
## but nothing is filed there — a photo "in" 收藏 is starred, not stored), so its
## menu carries no 删除/移动/复制: those are container actions, and doing them from
## a view is how a photo ends up filed nowhere. 取消收藏 is the way out of it.
func _cloud_menu(single: bool) -> void:
	_load_favorites()
	var cloud := _as_int(_targets[0].get("id")) > 0
	var image := str(_targets[0].get("media_type", "image")) == "image"
	var fav_view := in_favorites_view()
	_menu.add_item(_fav_label(), MenuId.FAV_TOGGLE)
	if not fav_view:
		_menu.add_item("移动到", MenuId.MOVE)
		_menu.add_item("复制到", MenuId.COPY)
	_menu.add_item("设为相册封面", MenuId.SET_COVER)
	_menu.add_item("重命名", MenuId.RENAME)
	if not fav_view:
		_menu.add_item("删除", MenuId.DELETE)
	_menu.add_item("删本地保云端", MenuId.KEEP)
	_menu.add_item("详细", MenuId.DETAILS)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.FAV_TOGGLE), not cloud)
	_set_item_disabled(MenuId.MOVE, not cloud)
	_set_item_disabled(MenuId.COPY, not cloud)
	# A cover is one specific cloud photo: videos have no server thumbnail and a
	# multi-selection has no single cover to point at.
	_menu.set_item_disabled(_menu.get_item_index(MenuId.SET_COVER), not single or not cloud or not image)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.RENAME), not single or not cloud)
	_set_item_disabled(MenuId.DELETE, not cloud)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.KEEP), not single or not cloud)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.DETAILS), not single)


## True when the album being browsed is 收藏 itself. Its id is only known once
## the album list has been read, so an unknown id means "not 收藏". The grid's ⋮
## menu and the viewer's own 删除 button both ask this: 收藏 is a starred view, and
## a photo deleted or moved out of a view is a photo on its way to being filed
## nowhere.
func in_favorites_view() -> bool:
	return Api.favorite_album_id > 0 and Api.current_album_id == Api.favorite_album_id


## Disables an entry by id, tolerating its absence (收藏 hides 移动/复制/删除, and
## index -1 would be a range error rather than a no-op).
func _set_item_disabled(id: int, disabled: bool) -> void:
	var idx := _menu.get_item_index(id)
	if idx >= 0:
		_menu.set_item_disabled(idx, disabled)


## Hides the 详细 sheet (the viewer calls this when the shown asset changes).
func close_details() -> void:
	if is_instance_valid(_sheet):
		_sheet.close()


func _on_menu(id: int) -> void:
	match id:
		MenuId.FAV_TOGGLE:
			await _toggle_favorite()
		MenuId.MOVE:
			await _prompt_target(true)
		MenuId.COPY:
			await _prompt_target(false)
		MenuId.SET_COVER:
			await _prompt_cover()
		MenuId.RENAME:
			await _prompt_rename()
		MenuId.DELETE:
			await delete_assets(_targets)
		MenuId.DETAILS:
			_show_details()
		MenuId.KEEP:
			await _delete_local_keep_cloud()
		MenuId.DELETE_DEVICE:
			await _delete_device_items()


# --- 删除 (cloud) -------------------------------------------------------------

## Deletes cloud assets. Inside a real album that means "drop this album's copy":
## the photo itself is only trashed when no other album holds it (the server
## decides, and says which happened), so the same photo can be filed in several
## albums and leave one without leaving them all. 全部 / 视频 / 收藏 are views of
## the whole library, so deleting there means deleting the photo. Queueing the
## cloud delete as a tombstone when the server is unreachable, scope included.
## Also used by the viewer's 删除 button, so both entry points share one delete
## path. Deleting is not gated by the parent PIN: the PIN guards the 隐私相册
## entrance only.
func delete_assets(assets: Array) -> void:
	var list: Array = []
	for a in assets:
		if a is Dictionary and _as_int(a.get("id")) > 0:
			list.append(a)
	if list.is_empty():
		return
	var scope := Api.current_album_id
	var ids: Array = []
	var offline := false
	# Offline deletes queue one tombstone each; batch so the index/settings file
	# is written once for the whole selection.
	Store.begin_batch()
	for a in list:
		var id := _as_int(a["id"])
		var r: Dictionary = await Api.delete_asset(id, scope)
		if r.has("error"):
			# Offline: drop local artifacts now, retry the cloud delete on sync.
			Sync.tombstone_delete(id, scope)
			offline = true
		elif bool(r.get("data", {}).get("trashed", true)):
			# 整个资产进了回收站，本机留着的原件与索引才真的没用了。
			Sync.remove_local(id)
		ids.append(id)
	Store.end_batch()
	if offline:
		notice.emit("已标记删除 %d 项，联网后同步删除" % ids.size())
	changed.emit(ids, "delete")


## Local file backing a cloud asset: the cached full-res download. "" when the
## asset exists only in the cloud — which is what the grid's ↓ badge reports.
func local_source_path(a: Dictionary) -> String:
	var id := _as_int(a.get("id"))
	if id <= 0:
		return ""
	var name := str(a.get("original_name", ""))
	if Cache.original_cached(id, name, str(a.get("ext", ""))):
		return Cache.original_path(id, name, str(a.get("ext", "")))
	return ""


# --- 删本地保云端 -------------------------------------------------------------

## The cloud asset the pin applies to: a device item's backed-up copy, or the
## cloud asset itself. 0 when there is nothing in the cloud to pin.
func _keep_target_id(a: Dictionary) -> int:
	if DeviceMedia.is_device(a):
		return Sync.backed_up_asset_id(a)
	return _as_int(a.get("id"))


## ⋮ → 删本地保云端: free the phone's copy now, keep the cloud's — no toggle, no
## way back (the local original comes again by itself: cloud assets re-fetch it
## on demand the next time one is opened). The pin (`Store.is_kept`) is what
## makes the cloud survive — without it the next sync mirrors the missing file
## into the recycle bin (restorable for 30 days); with it the sync only drops the
## index entry. The original goes immediately: a cloud asset loses its cached
## full-res download, a device item its own file (the system confirmation still
## governs, as always). Thumbnails and album membership are not originals and
## stay either way. Nothing here re-renders the screen: the cell keeps its place
## and its thumbnail until the grid is rebuilt, so 下次重新查看 is when the new
## state appears.
func _delete_local_keep_cloud() -> void:
	if _targets.size() != 1:
		return
	var a: Dictionary = _targets[0]
	var cloud_id := _keep_target_id(a)
	if cloud_id <= 0:
		notice.emit("该项还没有云端副本可保留")
		return
	if DeviceMedia.is_device(a):
		await _delete_device_keeping_cloud([a])
		return
	Store.set_kept(cloud_id, true)
	if local_source_path(a) == "":
		notice.emit("本机没有原图可删除；云端已标记保留")
		return
	Cache.remove_original_by_id(cloud_id)
	notice.emit("已删除本机原图，云端保留；下次查看时重新下载")


## 删本地保云端 on 系统相册 media: hand the device's own files to the platform and
## pin the cloud copies of the ones that really went away — the system dialog
## decides, and a declined one leaves everything, pin included, in place. No
## `changed` for the same reason as the cloud path: the cell stays until the
## grid is rebuilt.
func _delete_device_keeping_cloud(items: Array) -> void:
	var pins: Dictionary = {}
	var list: Array = []
	for a in items:
		if DeviceMedia.is_device(a):
			list.append(a)
			pins[DeviceMedia.key_of(a)] = _keep_target_id(a)
	if list.is_empty():
		return
	var gone := await DeviceMedia.delete_items(list)
	var pinned := 0
	for k in gone:
		var cloud_id := int(pins.get(str(k), 0))
		if cloud_id > 0:
			Store.set_kept(cloud_id, true)
			pinned += 1
	if pinned == 0:
		notice.emit("未从本机删除任何项（已取消或失败）")
	else:
		notice.emit("已删除本机 %d 项，云端保留；下次查看时刷新" % pinned)


# --- 从本机删除 (device media) -----------------------------------------------

## Removes the device's own files. Android raises a system confirmation (an app
## may not silently delete another app's media), so the outcome is read back
## from a fresh scan: whatever is gone is gone, and a declined dialog simply
## leaves everything in place.
func _delete_device_items() -> void:
	var items: Array = []
	for a in _targets:
		if DeviceMedia.is_device(a):
			items.append(a)
	if items.is_empty():
		return
	var gone := await DeviceMedia.delete_items(items)
	if gone.is_empty():
		notice.emit("未从本机删除任何项（已取消或失败）")
	elif gone.size() < items.size():
		notice.emit("已从本机删除 %d/%d 项；未标记保留的云端副本会在下次同步一并删除"
			% [gone.size(), items.size()])
	else:
		notice.emit("已从本机删除 %d 项；未标记保留的云端副本会在下次同步一并删除" % gone.size())
	changed.emit([], "device")


# --- 移动 / 复制 --------------------------------------------------------------

## 移动到 / 复制到: pick a destination. `Callable.bind()` appends its arguments
## *after* the call-time ones, so the bound flag is the callback's LAST
## parameter, not its first.
func _prompt_target(move: bool) -> void:
	await _prompt_album("移动到" if move else "复制到", PICK_TARGET, _apply_move_copy.bind(move))


## 设为相册封面: any cloud image can be the cover of any album of the active
## trunk — including the album it is already in.
func _prompt_cover() -> void:
	await _prompt_album("设为相册封面", PICK_COVER, _apply_cover)


## Target chooser shared by 移动/复制 and 设为相册封面. Every option carries a
## descriptor ({kind, trunk, id, label}) rather than a bare album id, because a
## destination can now be a whole trunk or the device gallery as well.
func _prompt_album(title: String, pick: int, on_confirm: Callable) -> void:
	var r: Dictionary = await Api.list_albums()
	if r.has("error"):
		notice.emit("无法获取相册列表")
		return
	var albums: Array = r["data"]["albums"]
	var options: Array = _sub_album_options(albums, pick == PICK_TARGET)
	if pick == PICK_TARGET:
		var device_source := DeviceMedia.is_device(_targets[0])
		options = _trunk_options(device_source) + options
	if options.is_empty():
		notice.emit("没有可选的相册")
		return

	var popup := AcceptDialog.new()
	popup.title = title
	var opt := OptionButton.new()
	for o in options:
		opt.add_item(str(o["label"]))
		opt.set_item_metadata(opt.item_count - 1, o)
	popup.add_child(opt)
	_host.add_child(popup)
	# The dialog takes its width from the dropdown, so this is what keeps long
	# album names from being clipped.
	opt.custom_minimum_size.x = _picker_width(opt, options)
	popup.confirmed.connect(_on_album_picked.bind(opt, popup, on_confirm))
	popup.canceled.connect(popup.queue_free)
	popup.popup_centered()


## The two cloud trunks as destinations. A single file dropped on a trunk lands
## in that trunk's 散照; a device item going to 共享相册 keeps its device album
## grouping instead (a separate album per device album).
func _trunk_options(device_source: bool) -> Array:
	var out: Array = [{
		"kind": TargetKind.TRUNK,
		"trunk": Api.TRUNK_CLOUD,
		"label": "共享相册" + ("（按本机相册归位）" if device_source else "（散照）"),
	}, {
		"kind": TargetKind.TRUNK,
		"trunk": Api.TRUNK_PRIVATE,
		"label": "隐私相册（散照）",
	}]
	if not device_source:
		out.append({
			"kind": TargetKind.DEVICE,
			"trunk": "",
			"label": "系统相册（存到 Pictures/%s）" % EXPORT_DIR_NAME,
		})
	return out


## Real sub-albums of the trunk on screen (the trunk itself is the 全部
## aggregation and 收藏 is auto-managed, so neither is a destination).
func _sub_album_options(albums: Array, exclude_current: bool) -> Array:
	var out: Array = []
	for a in albums:
		var pid = a.get("parent_id")
		if pid == null or _as_int(pid) != Api.current_trunk_id:
			continue
		if str(a.get("name", "")) == FAVORITE:
			continue
		if exclude_current and _as_int(a["id"]) == Api.current_album_id:
			continue
		out.append({
			"kind": TargetKind.ALBUM,
			"trunk": "",
			"id": _as_int(a["id"]),
			"label": str(a.get("name", "")),
		})
	return out


## Width a single-choice dropdown needs so long names are not clipped: the
## longest label measured in the dropdown's own font, and never less than
## PICKER_MIN_NAME_SAMPLE measures (7 CJK characters). Measuring one glyph would
## miss the font's CJK fallback, so the floor comes from measuring the sample
## string instead. Shared with the album browser's move picker.
static func picker_width(opt: OptionButton, labels: Array) -> float:
	var font := opt.get_theme_font("font")
	if font == null:
		return 0.0
	var size := opt.get_theme_font_size("font_size")
	var w := font.get_string_size(PICKER_MIN_NAME_SAMPLE, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	for l in labels:
		w = maxf(w, font.get_string_size(str(l), HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	return w + PICKER_CHROME_PX


func _picker_width(opt: OptionButton, options: Array) -> float:
	var labels: Array = []
	for o in options:
		labels.append(str(o["label"]))
	return picker_width(opt, labels)


func _on_album_picked(opt: OptionButton, popup: AcceptDialog, on_confirm: Callable) -> void:
	var target = opt.get_item_metadata(opt.selected)
	if is_instance_valid(popup):
		popup.queue_free()
	if target is Dictionary and not target.is_empty():
		on_confirm.call(target)


## Applies 移动/复制 to `target` (see TargetKind). The three source/destination
## pairings mean different things:
##   device -> cloud   upload (and, for 移动, remove the device's own file),
##   cloud  -> cloud   album membership: add to the destination, and for 移动
##                     detach from the album being viewed,
##   cloud  -> device  export a copy into Pictures/红泥 (and, for 移动, soft-delete
##                     the cloud asset).
func _apply_move_copy(target: Dictionary, move: bool) -> void:
	var kind := int(target.get("kind", TargetKind.ALBUM))
	var trunk := str(target.get("trunk", Api.TRUNK_CLOUD))
	# Writing into 隐私相册 without unlocking would put content behind a gate the
	# user never passed; everything else stays ungated, as before.
	if kind == TargetKind.TRUNK and trunk == Api.TRUNK_PRIVATE and not await Lock.require_unlock():
		return
	var device_source := DeviceMedia.is_device(_targets[0])
	var ids: Array = []
	var pushed: Array = []
	var failed := 0
	var detached := 0

	# Uploads write a sync-index entry each; one write for the whole selection.
	Store.begin_batch()
	for a in _targets:
		if DeviceMedia.is_device(a):
			if kind == TargetKind.DEVICE:
				continue  # already on the device
			var album_id := await Api.resolve_scatter_album(trunk)
			if trunk == Api.TRUNK_CLOUD:
				# 按设备相册名归位；解析不出来（离线/主干缺失）时保留上面刚拿到的
				# 散照，别把一个已经可用的落点清零。
				var by_name := await Api.resolve_device_album(str(a.get("bucket_name", "")))
				if by_name > 0:
					album_id = by_name
			# Backs the item up into `album_id` and links it in the sync index, so
			# the grid marks it ☁ 已备份 and the next sync leaves it alone. Bytes
			# the cloud already holds are linked rather than sent again; the
			# device's own file is never touched here.
			var up: Dictionary = await Sync.upload_device_item(a, album_id)
			if int(up.get("asset_id", 0)) > 0:
				pushed.append(a)
				ids.append(DeviceMedia.key_of(a))
			else:
				failed += 1
			continue
		var asset_id := _as_int(a.get("id"))
		if asset_id <= 0:
			continue
		if kind == TargetKind.DEVICE:
			if await export_to_device([a], move) > 0:
				ids.append(asset_id)
			else:
				failed += 1
			continue
		# 移动到隐私相册 = 只自己可见：服务端连这张照片在共享相册里的引用一起摘掉，
		# 所以来源相册那一步（_attach 里的摘除）由服务端代劳。复制则原样保留共享引用
		# ——要移开的话由用户自己删。
		var only_here := move and kind == TargetKind.TRUNK and trunk == Api.TRUNK_PRIVATE
		var album_id := _as_int(target.get("id")) if kind == TargetKind.ALBUM \
			else await Api.resolve_scatter_album(trunk)
		var res: Dictionary = {}
		if album_id > 0:
			res = await _attach(asset_id, album_id, move, only_here)
		if res.is_empty():
			failed += 1
		else:
			ids.append(asset_id)
			var data = res.get("data")
			if only_here and data is Dictionary and _as_int(data.get("detached_shared")) > 0:
				detached += 1
	Store.end_batch()

	# 移动 out of the device gallery only deletes the device's own file once the
	# cloud copy actually exists.
	var moved_out := 0
	if device_source and move and not pushed.is_empty():
		moved_out = (await DeviceMedia.delete_items(pushed)).size()

	var done := ids.size() - (pushed.size() - moved_out)
	var verb := "移动" if move else "复制"
	var where := str(target.get("label", ""))
	var text := "已%s %d 项到 %s" % [verb, done, where]
	if failed > 0:
		text += "（%d 项失败）" % failed
	if device_source and move and pushed.size() > moved_out:
		text += "；本机文件未删除 %d 项" % (pushed.size() - moved_out)
	if detached > 0:
		text += "；已移除其它相册的引用"
	notice.emit(text)
	changed.emit(ids, "device" if device_source else ("move" if move else "copy"))


## Adds `asset_id` to `album_id`, and detaches it from the album being viewed
## when this is a 移动. With `only_here` the server has already taken the photo
## out of every shared album — 转到隐私相册 means the family stops seeing it — so
## that detach is skipped rather than repeated. Returns the server response
## ({} when the destination could not be set).
func _attach(asset_id: int, album_id: int, move: bool, only_here: bool) -> Dictionary:
	var r: Dictionary = await Api.add_asset_to_album(album_id, asset_id, only_here)
	if r.has("error"):
		return {}
	if move and not only_here:
		var src := _as_int(_source_album.call()) if _source_album.is_valid() else 0
		if src > 0 and src != album_id:
			await Api.remove_asset_from_album(src, asset_id)
	return r


# --- cloud -> device ---------------------------------------------------------

## Copies cloud assets into the device gallery under Pictures/红泥 (Sync owns the
## transfer; this only reports it). With `move` the cloud copy is soft-deleted
## into the recycle bin. Returns how many files were written.
func export_to_device(assets: Array, move: bool) -> int:
	var r: Dictionary = await Sync.export_assets_to_device(assets, move)
	var written := int(r.get("written", 0))
	if written > 0:
		notice.emit("已存到系统相册 %d 项" % written)
	elif int(r.get("skipped_video", 0)) > 0:
		notice.emit("视频暂不支持存到相册")
	return written


# --- Detail sheet ------------------------------------------------------------

func _show_details() -> void:
	if _targets.size() != 1:
		return
	var a: Dictionary = _targets[0]
	if DeviceMedia.is_device(a):
		# On Android a device item has no local path (content:// only): the sheet
		# then shows what MediaStore reported and the URI as the path.
		var path := str(a.get("path", ""))
		var uri := str(a.get("uri", ""))
		_sheet.open(_device_details(a), path, uri if uri != "" else path)
		return
	var local := local_source_path(a)
	var id := _as_int(a.get("id"))
	var cloud := ""
	if local == "" and id > 0:
		cloud = "%s/api/v1/assets/%d/original" % [Store.server_url(), id]
	_sheet.open(a, local, cloud)


## The 详细 sheet reads the cloud asset shape; map a device item onto it.
static func _device_details(a: Dictionary) -> Dictionary:
	return {
		"original_name": str(a.get("display_name", "")),
		"media_type": "video" if a.get("is_video", false) else "image",
		"size": _as_int(a.get("size")),
		"width": _as_int(a.get("width")),
		"height": _as_int(a.get("height")),
		"taken_at": _as_int(a.get("taken_at")),
		"duration_ms": _as_int(a.get("duration_ms")),
	}


# --- 收藏 ---------------------------------------------------------------------

func _fav_label() -> String:
	for a in _targets:
		if not _favorite_ids.has(str(_as_int(a.get("id")))):
			return "收藏"
	return "取消收藏"


## Seeds membership from the cached 收藏 snapshot so the menu label is right
## immediately, then refreshes it from the server (next popup sees the truth).
func _load_favorites() -> void:
	var fav_id := Api.favorite_album_id
	if fav_id <= 0:
		return
	_favorite_ids.clear()
	for a in Cache.offline_assets(fav_id):
		_favorite_ids[str(_as_int(a.get("id")))] = true
	var r: Dictionary = await Api.list_assets("all", fav_id)
	if r.has("error"):
		return
	var list: Array = r["data"]["assets"]
	_favorite_ids.clear()
	for a in list:
		_favorite_ids[str(_as_int(a.get("id")))] = true
	Cache.snapshot_album_assets(fav_id, list)


## Adds the targets that are not favorites yet, removes those that are. A failed
## call (usually offline) is reported and leaves the menu's own state alone —
## otherwise the label would claim a change that never happened. Un-starring a
## photo that no album holds any more parks it in that trunk's 散照, which is
## worth saying out loud: nothing was deleted, it just stopped being filed.
func _toggle_favorite() -> void:
	var fav_id := Api.favorite_album_id
	if fav_id <= 0:
		notice.emit("未找到收藏相册")
		return
	var add := false
	for a in _targets:
		if not _favorite_ids.has(str(_as_int(a.get("id")))):
			add = true
			break
	var ids: Array = []
	var parked := 0
	var failed := 0
	for a in _targets:
		var id := _as_int(a.get("id"))
		if id <= 0 or _favorite_ids.has(str(id)) == add:
			continue
		var r: Dictionary
		if add:
			r = await Api.add_asset_to_album(fav_id, id)
		else:
			r = await Api.remove_asset_from_album(fav_id, id)
		if r.has("error"):
			failed += 1
			continue
		if add:
			_favorite_ids[str(id)] = true
		else:
			_favorite_ids.erase(str(id))
			if bool(r.get("data", {}).get("parked", false)):
				parked += 1
		ids.append(id)
	if failed > 0:
		notice.emit("收藏操作失败 %d 项（离线？稍后再试）" % failed)
	if parked > 0:
		notice.emit("已取消收藏；%d 项已不属于任何相册，移到 散照 里" % parked)
	if not ids.is_empty():
		changed.emit(ids, "favorite")


# --- 设为相册封面 -------------------------------------------------------------

## 设为相册封面: recorded on this device only (settings.json `album_covers`) — the
## server keeps no cover, so the choice does not travel to other devices and the
## album's membership is untouched. Nothing on screen changes here (album cards
## live in the album list, which reads the choice when it opens), so no `changed`.
func _apply_cover(target: Dictionary) -> void:
	if _targets.size() != 1:
		return
	var id := _as_int(_targets[0].get("id"))
	var album_id := _as_int(target.get("id"))
	if id <= 0 or album_id <= 0:
		return
	Store.set_album_cover(album_id, id)
	notice.emit("已设为相册封面")


# --- 重命名 -------------------------------------------------------------------

func _prompt_rename() -> void:
	if _targets.size() != 1:
		return
	var asset: Dictionary = _targets[0]
	if _as_int(asset.get("id")) <= 0:
		return
	var current := str(asset.get("original_name", ""))
	# Renaming never drops the file type: the index keeps the original extension.
	var ext := str(asset.get("ext", ""))
	if ext == "":
		ext = current.get_extension().to_lower()
	var popup := AcceptDialog.new()
	popup.title = "重命名照片"
	var edit := LineEdit.new()
	edit.text = current
	popup.add_child(edit)
	_host.add_child(popup)
	edit.text_submitted.connect(_do_rename.bind(popup, edit, asset, ext))
	popup.confirmed.connect(_do_rename.bind("", popup, edit, asset, ext))
	popup.popup_centered()


func _do_rename(text: String, popup: AcceptDialog, edit: LineEdit, asset: Dictionary, ext: String) -> void:
	if not is_instance_valid(popup):
		return
	var new_name := text.strip_edges() if text.strip_edges() != "" else edit.text.strip_edges()
	var id := _as_int(asset.get("id"))
	if new_name == "" or id <= 0:
		popup.queue_free()
		return
	if ext != "":
		var base := new_name.get_basename()
		new_name = (base if base != "" else new_name) + "." + ext
	await Api.update_asset(id, {"original_name": new_name})
	asset["original_name"] = new_name
	popup.queue_free()
	changed.emit([id], "rename")


static func _as_int(v) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	return 0
