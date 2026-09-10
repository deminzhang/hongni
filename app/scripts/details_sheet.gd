extends PanelContainer
## Bottom 详细 sheet: a text area, popped up over the lower part of the screen,
## listing one asset's 名称 / 哈希 / 时间 / 大小 / 宽高 / 时长 (videos) / 路径.
##
## Values come from the server's asset record where it has them (hash, size,
## width/height of images, taken/created time); what it cannot know — video
## duration, video pixel size, the local path — is read from the local copy by
## media_probe.gd. An asset with no server record yet (a local-only photo) gets
## its SHA-256 computed from the file on a background thread.

const Probe = preload("res://scripts/media_probe.gd")

# The sheet covers this fraction of the viewport height (min 240 px so the text
# area stays usable on short screens).
const HEIGHT_RATIO := 0.42
const MIN_HEIGHT := 240.0
# 哈希 is the second line; the background hash computation rewrites it in place.
const HASH_LINE := 1
const HASH_PENDING := "计算中…"

var _text: Label

# Bumped on every open()/close() so a slow hash from a previous asset cannot
# paint into the sheet after the user has moved on.
var _open_gen := 0


func _ready() -> void:
	visible = false
	anchor_left = 0.0
	anchor_right = 1.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = 0
	offset_right = 0
	offset_bottom = 0
	offset_top = -MIN_HEIGHT

	var col := VBoxContainer.new()
	add_child(col)

	var head := HBoxContainer.new()
	col.add_child(head)
	var title := Label.new()
	title.text = "详细"
	title.add_theme_font_size_override("font_size", 20)
	head.add_child(title)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(spacer)
	var btn_close := Button.new()
	btn_close.text = "关闭"
	btn_close.pressed.connect(close)
	head.add_child(btn_close)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(scroll)

	_text = Label.new()
	_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Paths are long and unbreakable: wrap them instead of scrolling sideways.
	_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	scroll.add_child(_text)


func close() -> void:
	_open_gen += 1
	visible = false


## Shows the sheet for one asset. `local_path` is a user:// path of any local
## copy ("" when the asset only lives in the cloud); `cloud_url` is what to show
## as the path in that case.
func open(asset: Dictionary, local_path: String, cloud_url: String) -> void:
	_open_gen += 1
	var gen := _open_gen
	_resize()
	visible = true

	var media_type := str(asset.get("media_type", "image"))
	var is_video := media_type == "video"
	var name := str(asset.get("original_name", ""))
	var size := _as_int(asset.get("size"))
	var mtime := 0
	if local_path != "":
		mtime = int(FileAccess.get_modified_time(local_path))
		if size <= 0:
			var f := FileAccess.open(local_path, FileAccess.READ)
			if f != null:
				size = f.get_length()
				f.close()

	var probe: Dictionary = Probe.probe(local_path) if (is_video and local_path != "") else {}
	var width := _as_int(asset.get("width"))
	var height := _as_int(asset.get("height"))
	if width <= 0 or height <= 0:
		width = _as_int(probe.get("width"))
		height = _as_int(probe.get("height"))
	if (width <= 0 or height <= 0) and local_path != "" and not is_video:
		var dim := _image_size(local_path)
		width = dim.x
		height = dim.y

	var hash := str(asset.get("hash", ""))
	var partial := hash == "" and local_path != ""
	var lines := PackedStringArray()
	lines.append("名称: " + (name if name != "" else "（无）"))
	lines.append("哈希: " + (hash if hash != "" else (HASH_PENDING if partial else "未知")))
	lines.append("时间: " + _format_time(_timestamp(asset, mtime)))
	lines.append("大小: " + _format_size(size))
	lines.append("宽高: " + ("%d × %d" % [width, height] if width > 0 and height > 0 else "未知"))
	if is_video:
		var ms := _as_int(probe.get("duration_ms"))
		if ms <= 0:
			# Device (系统相册) videos: MediaStore already reported the duration.
			ms = _as_int(asset.get("duration_ms"))
		if ms > 0:
			lines.append("时长: " + _format_duration(ms))
		else:
			lines.append("时长: " + ("未知" if local_path == "" else "未缓存原文件，无法读取"))
	var path := ProjectSettings.globalize_path(local_path) if local_path != "" else cloud_url
	lines.append("路径: " + (path if path != "" else "未知"))
	_text.text = "\n".join(lines)

	if partial:
		var computed := await _sha256_bg(local_path)
		if gen != _open_gen:
			return
		lines[HASH_LINE] = "哈希: " + (computed if computed != "" else "读取失败")
		_text.text = "\n".join(lines)


func _resize() -> void:
	var vp := get_viewport_rect().size
	offset_top = -maxf(MIN_HEIGHT, vp.y * HEIGHT_RATIO)


## 时间: the timestamp the file carried at upload, else when it landed in the
## cloud, else the local file's mtime.
func _timestamp(asset: Dictionary, mtime: int) -> int:
	var taken := _as_int(asset.get("taken_at"))
	if taken > 0:
		return taken
	var created := _as_int(asset.get("created_at"))
	return created if created > 0 else mtime


func _format_time(unix: int) -> String:
	if unix <= 0:
		return "未知"
	var bias := int(Time.get_time_zone_from_system().get("bias", 0)) * 60
	return Time.get_datetime_string_from_unix_time(unix + bias, true)


func _format_size(bytes: int) -> String:
	if bytes <= 0:
		return "未知"
	if bytes < 1024:
		return "%d B" % bytes
	var value := float(bytes)
	var unit := "B"
	for u in ["KB", "MB", "GB", "TB"]:
		if value < 1024.0:
			break
		value /= 1024.0
		unit = u
	return "%.1f %s（%d 字节）" % [value, unit, bytes]


func _format_duration(ms: int) -> String:
	var total := int(round(ms / 1000.0))
	var h := total / 3600
	var m := (total % 3600) / 60
	var s := total % 60
	var clock := ("%d:%02d:%02d" % [h, m, s]) if h > 0 else ("%02d:%02d" % [m, s])
	return "%s（%.1f 秒）" % [clock, ms / 1000.0]


## Pixel size of a local image, (0, 0) when it cannot be decoded.
func _image_size(path: String) -> Vector2i:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return Vector2i.ZERO
	var body := f.get_buffer(f.get_length())
	f.close()
	if body.is_empty():
		return Vector2i.ZERO
	var img := Image.new()
	var err := img.load_jpg_from_buffer(body)
	if err != OK:
		err = img.load_png_from_buffer(body)
	if err != OK:
		err = img.load_webp_from_buffer(body)
	if err != OK:
		err = img.load_bmp_from_buffer(body)
	if err != OK and img.has_method("load_gif_from_buffer"):
		err = img.load_gif_from_buffer(body)
	if err != OK:
		return Vector2i.ZERO
	return img.get_size()


## Hashing a large file (a video, typically) must not stall the render loop.
func _sha256_bg(path: String) -> String:
	var out := [""]
	var done := [false]
	var t := Thread.new()
	t.start(func() -> void:
		out[0] = Probe.sha256_file(path)
		done[0] = true
	)
	while not done[0]:
		await get_tree().process_frame
	t.wait_to_finish()
	return out[0]


static func _as_int(v) -> int:
	if v is int:
		return v
	if v is float:
		return int(v)
	return 0
