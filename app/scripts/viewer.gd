extends Control
## Full-screen viewer: shows the original image for the current asset, with
## left/right navigation and delete / add-to-album / save-to-device-gallery
## actions.

var texture_rect: TextureRect
var label_name: Label
var label_status: Label
var btn_save: Button


func _ready() -> void:
	_build_ui()
	_show_current()


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

	var btn_prev := Button.new()
	btn_prev.text = "‹"
	btn_prev.pressed.connect(_prev)
	top.add_child(btn_prev)

	var btn_next := Button.new()
	btn_next.text = "›"
	btn_next.pressed.connect(_next)
	top.add_child(btn_next)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	var btn_delete := Button.new()
	btn_delete.text = "删除"
	btn_delete.pressed.connect(_delete_current)
	top.add_child(btn_delete)

	var btn_album := Button.new()
	btn_album.text = "加入相册"
	btn_album.pressed.connect(_add_to_album)
	top.add_child(btn_album)

	btn_save = Button.new()
	btn_save.text = "存到相册"
	btn_save.pressed.connect(_save_to_album)
	top.add_child(btn_save)

	label_name = Label.new()
	root.add_child(label_name)

	texture_rect = TextureRect.new()
	texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	texture_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(texture_rect)

	label_status = Label.new()
	label_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(label_status)


func _show_current() -> void:
	if Api.viewer_assets.is_empty() or Api.viewer_index < 0 or Api.viewer_index >= Api.viewer_assets.size():
		texture_rect.texture = null
		label_name.text = "（无）"
		label_status.text = ""
		return
	var a: Dictionary = Api.viewer_assets[Api.viewer_index]
	var asset_id := int(a.get("id", 0))
	if asset_id <= 0:
		# Local-only (not yet uploaded) photo: show a hint, nothing to fetch.
		texture_rect.texture = null
		label_name.text = str(a.get("original_name", ""))
		label_status.text = "本地待上传 · 尚未同步到云端"
		return
	var name := str(a.get("original_name", ""))
	var ext := str(a.get("ext", ""))
	var mime: String = a.get("mime_type", "image/jpeg")
	var media_type := str(a.get("media_type", "image"))
	label_name.text = "%d  %s" % [asset_id, name]
	texture_rect.texture = null
	Cache.mark_viewed(asset_id)
	btn_save.visible = OS.get_name() == "Android" and media_type != "video"
	label_status.text = "加载中…"

	if media_type == "video":
		label_status.text = "视频暂不支持内嵌预览"
		return

	# Prefer the cached full-res copy (works offline); otherwise fetch from the
	# server and write it through to the cache (which re-checks free space).
	var body := Cache.read_original(asset_id, name, ext)
	var is_thumb_fallback := false
	if body.is_empty():
		var r: Dictionary = await Api.fetch_original(asset_id)
		if r.has("error"):
			# Offline / unreachable: fall back to the cached thumbnail.
			body = Cache.read_thumb(asset_id)
			if body.is_empty():
				label_status.text = "无法加载原图"
				return
			is_thumb_fallback = true
		else:
			body = r["body"]
			Cache.save_original(asset_id, name, body, ext)
	if body.is_empty():
		label_status.text = "无法加载原图"
		return
	var img := Image.new()
	var err := img.load_jpg_from_buffer(body)
	if mime == "image/png":
		err = img.load_png_from_buffer(body)
	elif mime == "image/webp":
		err = img.load_webp_from_buffer(body)
	if err == OK:
		texture_rect.texture = ImageTexture.create_from_image(img)
		if is_thumb_fallback:
			label_status.text = "离线缩略图 · 原图未缓存"
		else:
			label_status.text = ""
	elif is_thumb_fallback:
		label_status.text = "缓存无法解码"
	else:
		label_status.text = "格式不支持预览"


func _prev() -> void:
	if Api.viewer_index > 0:
		Api.viewer_index -= 1
		_show_current()


func _next() -> void:
	if Api.viewer_index < Api.viewer_assets.size() - 1:
		Api.viewer_index += 1
		_show_current()

func _delete_current() -> void:
	if not await Lock.require_unlock():
		return
	var a: Dictionary = Api.viewer_assets[Api.viewer_index]
	var r: Dictionary = await Api.delete_asset(a["id"])
	if r.has("error"):
		# Offline: drop local artifacts now, queue the cloud delete for later.
		Sync.tombstone_delete(int(a["id"]))
	else:
		Sync.remove_local(int(a["id"]))
	Api.viewer_assets.remove_at(Api.viewer_index)
	if Api.viewer_assets.is_empty():
		_go_back()
		return
	if Api.viewer_index >= Api.viewer_assets.size():
		Api.viewer_index = Api.viewer_assets.size() - 1
	_show_current()


func _add_to_album() -> void:
	var a: Dictionary = Api.viewer_assets[Api.viewer_index]
	var dialog := AcceptDialog.new()
	dialog.title = "加入相册（输入相册 ID）"
	var edit := LineEdit.new()
	edit.placeholder_text = "相册 ID"
	edit.name = "AlbumIdEdit"
	dialog.add_child(edit)
	edit.text_submitted.connect(_do_add_to_album.bind(a["id"], dialog))
	add_child(dialog)
	dialog.popup_centered()


func _do_add_to_album(text: String, asset_id: int, dialog: AcceptDialog) -> void:
	if text.strip_edges() == "" or not text.strip_edges().is_valid_int():
		return
	var album_id := text.strip_edges().to_int()
	await Api.add_asset_to_album(album_id, asset_id)
	dialog.queue_free()


func _ext_for_mime(mime: String) -> String:
	match mime:
		"image/png": return "png"
		"image/webp": return "webp"
		"image/gif": return "gif"
		"image/bmp": return "bmp"
		_: return "jpg"


## Saves the current image's full-res bytes into the device system album
## (Pictures/Hongni) via the Android plugin. Uses the cached original when
## present, otherwise downloads it first.
func _save_to_album() -> void:
	var a: Dictionary = Api.viewer_assets[Api.viewer_index]
	if str(a.get("media_type", "image")) == "video":
		label_status.text = "视频暂不支持存到相册"
		return
	if OS.get_name() != "Android":
		return
	btn_save.disabled = true
	var asset_id := int(a.get("id", 0))
	var name := str(a.get("original_name", ""))
	# The server records the original extension at upload, so it survives a
	# later rename that strips the extension from the display name.
	var ext := str(a.get("ext", ""))
	var mime := str(a.get("mime_type", ""))
	if mime == "":
		mime = "image/jpeg"
	var body := Cache.read_original(asset_id, name, ext)
	if body.is_empty():
		var r: Dictionary = await Api.fetch_original(asset_id)
		if r.has("error"):
			label_status.text = "保存失败：无法获取原图"
			btn_save.disabled = false
			return
		body = r["body"]
		Cache.save_original(asset_id, name, body, ext)
	if body.is_empty():
		label_status.text = "保存失败：无数据"
		btn_save.disabled = false
		return
	# Give the gallery copy a real extension: prefer the recorded one, else the
	# display name's, else one derived from the MIME type. Only rewrite the
	# display name when it is extension-less, so a well-formed name is kept.
	if ext == "":
		ext = name.get_extension().to_lower()
	if ext == "":
		ext = _ext_for_mime(mime)
	if name.get_extension().to_lower() == "":
		name = (name.get_basename() + "." + ext) if name.get_basename() != "" else "hongni_%d.%s" % [asset_id, ext]
	label_status.text = "保存中…"
	var tmp := "user://hongni_save_tmp_%d.%s" % [asset_id, ext]
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		label_status.text = "保存失败：无法写入临时文件"
		btn_save.disabled = false
		return
	f.store_buffer(body)
	f.close()
	var ok := Lock.save_to_gallery(ProjectSettings.globalize_path(tmp), name, mime)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))
	btn_save.disabled = false
	label_status.text = "已保存到系统相册" if ok else "保存失败"


func _go_back() -> void:
	get_tree().change_scene_to_file("res://scenes/album_view.tscn")
