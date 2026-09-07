extends Control
## Stage 4: browse the device system album (MediaStore via plugin) and import
## selected items into the cloud (upload + optional album membership).

const THUMB_SIZE := 140

var grid: GridContainer
var label_status: Label
var media: Array = []


func _ready() -> void:
	_build_ui()
	_refresh.call_deferred()


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


func _refresh() -> void:
	for c in grid.get_children():
		c.queue_free()
	media = Lock.list_media("all")
	label_status.text = "本机 %d 项" % media.size()
	for m in media:
		_add_cell(m)


func _add_cell(m: Dictionary) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = Vector2(THUMB_SIZE, THUMB_SIZE)
	btn.text = str(m.get("display_name", ""))
	btn.toggle_mode = true
	grid.add_child(btn)
	# Mark selected state text.
	btn.pressed.connect(_on_cell_toggled)


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


func _import_selected() -> void:
	var sel := _selected()
	if sel.is_empty():
		return
	var total := sel.size()
	var done := 0
	for m in sel:
		var uri: String = m["uri"]
		var name: String = m.get("display_name", "import")
		var media_type: String = "video" if str(m.get("mime_type", "")).begins_with("video") else "image"
		var dest := ProjectSettings.globalize_path("user://photos/" + name)
		if Lock.read_media_bytes(uri, dest):
			var taken_at := int(m.get("taken_at", 0))
			var r: Dictionary = await Api.upload_asset(dest, name, media_type, taken_at, Api.scatter_album_id)
			if r.has("error"):
				label_status.text = "导入失败：" + str(r.get("error", ""))
			# Remove the temp copy to avoid re-uploading on next backup.
			DirAccess.remove_absolute(dest)
		done += 1
		label_status.text = "导入 %d/%d" % [done, total]
	label_status.text = "导入完成"


func _go_back() -> void:
	get_tree().change_scene_to_file("res://scenes/albums.tscn")
