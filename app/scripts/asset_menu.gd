extends Control
## Shared per-asset action menu, used by both the album photo grid and the
## full-screen viewer. Owns:
##   - the rightmost ⋮ PopupMenu. For cloud assets: 收藏 / 移动到 / 复制到 /
##     设为相册封面 / 重命名 / 删除 / 详细, operating on one asset (viewer) or on
##     the current multi-selection (grid). For device (系统相册) media: 上传到红泥 /
##     详细 — the device owns the file, so the only thing to do with it here is
##     bring it into the cloud.
##   - the album picker and rename dialogs those entries need,
##   - the bottom 详细 sheet (details_sheet.gd).
##
## Call `setup(host, source_album)` once, then `popup(assets)` with the target
## assets. Mutations are reported through `changed(ids, op)` so the owner can
## refresh itself, and through `notice(text)` for user-facing one-liners.

signal changed(ids: Array, op: String)
signal notice(text: String)

enum MenuId { FAV_TOGGLE, MOVE, COPY, SET_COVER, RENAME, DELETE, DETAILS, UPLOAD }

const DETAILS := preload("res://scripts/details_sheet.gd")
const FAVORITE := "收藏"
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
	if DeviceMedia.is_device(targets[0]):
		# Device media has no cloud record yet: the one meaningful action is
		# bringing it over, plus the 详细 sheet.
		_menu.clear()
		_menu.add_item("导入到红泥", MenuId.UPLOAD)
		_menu.add_item("详细", MenuId.DETAILS)
		_menu.set_item_disabled(1, not single)
		_menu.popup(Rect2i(Vector2i(at if at != Vector2.INF else get_global_mouse_position()), Vector2i.ZERO))
		return
	_load_favorites()
	var cloud := _as_int(targets[0].get("id")) > 0
	var image := str(targets[0].get("media_type", "image")) == "image"
	_menu.clear()
	_menu.add_item(_fav_label(), MenuId.FAV_TOGGLE)
	_menu.add_item("移动到相册", MenuId.MOVE)
	_menu.add_item("复制到相册", MenuId.COPY)
	_menu.add_item("设为相册封面", MenuId.SET_COVER)
	_menu.add_item("重命名", MenuId.RENAME)
	_menu.add_item("删除", MenuId.DELETE)
	_menu.add_item("详细", MenuId.DETAILS)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.FAV_TOGGLE), not cloud)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.MOVE), not cloud)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.COPY), not cloud)
	# A cover is one specific cloud photo: videos have no server thumbnail and a
	# multi-selection has no single cover to point at.
	_menu.set_item_disabled(_menu.get_item_index(MenuId.SET_COVER), not single or not cloud or not image)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.RENAME), not single or not cloud)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.DELETE), not cloud)
	_menu.set_item_disabled(_menu.get_item_index(MenuId.DETAILS), not single)
	_menu.popup(Rect2i(Vector2i(at if at != Vector2.INF else get_global_mouse_position()), Vector2i.ZERO))


## Hides the 详细 sheet (the viewer calls this when the shown asset changes).
func close_details() -> void:
	if is_instance_valid(_sheet):
		_sheet.close()


## Deletes cloud assets (soft delete + recycle bin), queueing the cloud delete as
## a tombstone when the server is unreachable. Also used by the viewer's 删除
## button, so both entry points share one delete path. Deleting is not gated by
## the parent PIN: the PIN guards the 隐私相册 entrance only.
func delete_assets(assets: Array) -> void:
	var list: Array = []
	for a in assets:
		if a is Dictionary and _as_int(a.get("id")) > 0:
			list.append(a)
	if list.is_empty():
		return
	var ids: Array = []
	var offline := false
	for a in list:
		var id := _as_int(a["id"])
		var r: Dictionary = await Api.delete_asset(id)
		if r.has("error"):
			# Offline: drop local artifacts now, retry the cloud delete on sync.
			Sync.tombstone_delete(id)
			offline = true
		else:
			Sync.remove_local(id)
		ids.append(id)
	if offline:
		notice.emit("已标记删除 %d 项，联网后同步删除" % ids.size())
	changed.emit(ids, "delete")


## Local copy of an asset's original file: the not-yet-uploaded source, the
## cached full-res download, or the uploaded source under user://photos.
## "" when the asset only exists in the cloud.
func local_source_path(a: Dictionary) -> String:
	var local := str(a.get("local_path", ""))
	if local != "" and FileAccess.file_exists(local):
		return local
	var id := _as_int(a.get("id"))
	if id <= 0:
		return ""
	var name := str(a.get("original_name", ""))
	if Cache.original_cached(id, name, str(a.get("ext", ""))):
		return Cache.original_path(id, name, str(a.get("ext", "")))
	for e in Store.sync_index:
		if _as_int(e.get("cloud_asset_id")) == id:
			var p := "user://photos/" + str(e.get("local_id", "")).trim_prefix("photos/")
			if FileAccess.file_exists(p):
				return p
	return ""


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
		MenuId.UPLOAD:
			await _upload_to_cloud()


# --- 上传到红泥 (device media) ------------------------------------------------

## Copies the selected device items into the cloud: each one is staged into a
## hidden temp file, uploaded into the cloud trunk's 散照 bucket (which is what
## the 全部 card aggregates), then the temp copy is dropped. The device's own
## file is never modified.
func _upload_to_cloud() -> void:
	if _targets.is_empty():
		return
	var album_id := await Api.resolve_scatter_album()
	if album_id <= 0:
		notice.emit("无法上传：云端相册信息不可用")
		return
	var total := _targets.size()
	var done := 0
	var uploaded := 0
	for a in _targets:
		var local := await DeviceMedia.materialize(a)
		if local != "":
			var name := str(a.get("display_name", local.get_file()))
			var media_type := "video" if a.get("is_video", false) else "image"
			var r: Dictionary = await Api.upload_asset(local, name, media_type, _as_int(a.get("taken_at")), album_id)
			DeviceMedia.remove_temp(local)
			if not r.has("error"):
				uploaded += 1
		done += 1
		notice.emit("上传 %d/%d" % [done, total])
	if uploaded < total:
		notice.emit("已上传 %d/%d 项" % [uploaded, total])
	else:
		notice.emit("已上传 %d 项到红泥相册" % uploaded)
	changed.emit([], "upload")


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


## Adds the targets that are not favorites yet, removes those that are.
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
	for a in _targets:
		var id := _as_int(a.get("id"))
		if id <= 0 or _favorite_ids.has(str(id)) == add:
			continue
		if add:
			await Api.add_asset_to_album(fav_id, id)
			_favorite_ids[str(id)] = true
		else:
			await Api.remove_asset_from_album(fav_id, id)
			_favorite_ids.erase(str(id))
		ids.append(id)
	if not ids.is_empty():
		changed.emit(ids, "favorite")


# --- 移动到 / 复制到 / 设为相册封面 -------------------------------------------

## 移动到 / 复制到: pick a sub-album of the active trunk, excluding the album the
## photos are being moved out of. The picker calls the confirmation as
## `on_confirm.call(target_id)`, and `Callable.bind()` appends its arguments
## *after* the call-time ones — so the bound flag is the callback's LAST
## parameter, not its first (reversed, it made 移动 add to album 1 and 复制到
## remove the photo from its source without adding it anywhere).
func _prompt_target(move: bool) -> void:
	await _prompt_album("移动到相册" if move else "复制到相册", true, _apply_move_copy.bind(move))


## 设为相册封面: any cloud image can be the cover of any album of the active
## trunk — including the album it is already in.
func _prompt_cover() -> void:
	await _prompt_album("设为相册封面", false, _apply_cover)


## Album chooser shared by 移动到 / 复制到 / 设为相册封面. Offers the sub-albums of
## the active trunk (the trunk itself is the 全部 aggregation and 收藏 is
## auto-managed, so neither is a target) and calls `on_confirm` with the chosen
## album id.
func _prompt_album(title: String, exclude_current: bool, on_confirm: Callable) -> void:
	var r: Dictionary = await Api.list_albums()
	if r.has("error"):
		notice.emit("无法获取相册列表")
		return
	var options: Array = []
	for a in r["data"]["albums"]:
		var pid = a.get("parent_id")
		if pid == null or _as_int(pid) != Api.current_trunk_id:
			continue
		if str(a.get("name", "")) == FAVORITE:
			continue
		if exclude_current and _as_int(a["id"]) == Api.current_album_id:
			continue
		options.append(a)
	if options.is_empty():
		notice.emit("没有可选的相册")
		return

	var popup := AcceptDialog.new()
	popup.title = title
	var opt := OptionButton.new()
	for a in options:
		opt.add_item(str(a["name"]))
		opt.set_item_metadata(opt.item_count - 1, _as_int(a["id"]))
	popup.add_child(opt)
	_host.add_child(popup)
	# The dialog takes its width from the dropdown, so this is what keeps long
	# album names from being clipped.
	opt.custom_minimum_size.x = _picker_width(opt, options)
	popup.confirmed.connect(_on_album_picked.bind(opt, popup, on_confirm))
	popup.canceled.connect(popup.queue_free)
	popup.popup_centered()


## Width the picker needs: the longest album name in the dropdown's own font,
## and never less than PICKER_MIN_NAME_SAMPLE measures (7 CJK characters). A
## single glyph measured with get_char_size misses the font's CJK fallback, so
## the floor comes from measuring the sample string instead.
func _picker_width(opt: OptionButton, options: Array) -> float:
	var font := opt.get_theme_font("font")
	if font == null:
		return 0.0
	var size := opt.get_theme_font_size("font_size")
	var w := font.get_string_size(PICKER_MIN_NAME_SAMPLE, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	for a in options:
		w = maxf(w, font.get_string_size(str(a.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, size).x)
	return w + PICKER_CHROME_PX


func _on_album_picked(opt: OptionButton, popup: AcceptDialog, on_confirm: Callable) -> void:
	var target_id := _as_int(opt.get_item_metadata(opt.selected))
	if is_instance_valid(popup):
		popup.queue_free()
	if target_id > 0:
		on_confirm.call(target_id)


## `move` is the bound flag (last parameter — see _prompt_target); `target_id`
## is what the picker passed.
func _apply_move_copy(target_id: int, move: bool) -> void:
	var source := _as_int(_source_album.call()) if _source_album.is_valid() else 0
	var ids: Array = []
	for a in _targets:
		var id := _as_int(a.get("id"))
		if id <= 0:
			continue
		await Api.add_asset_to_album(target_id, id)
		if move and source > 0:
			await Api.remove_asset_from_album(source, id)
		ids.append(id)
	if not ids.is_empty():
		changed.emit(ids, "move" if move else "copy")


## 设为相册封面: recorded on this device only (settings.json `album_covers`) — the
## server keeps no cover, so the choice does not travel to other devices and the
## album's membership is untouched. Nothing on screen changes here (album cards
## live in the album list, which reads the choice when it opens), so no `changed`.
func _apply_cover(target_id: int) -> void:
	if _targets.size() != 1:
		return
	var id := _as_int(_targets[0].get("id"))
	if id <= 0:
		return
	Store.set_album_cover(target_id, id)
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
