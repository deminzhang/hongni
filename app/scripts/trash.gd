extends Control
## 最近删除 (recycle bin) for the active trunk. Photos soft-deleted from the
## active set land here for the 30-day restore window (server-side retention in
## api.go). Tapping an item offers 恢复 or 永久删除; the header 清空 empties the
## trunk bin. 主相册 and 隐私 have independent bins (per-trunk provenance
## recorded at delete time).

const THUMB_SIZE := 140
# Touch height of the top-bar 返回 (~48dp once the 600px base is scaled up).
const BACK_BTN_H := 72
const RENDER_CHUNK := 150

enum MenuId { RESTORE, DELETE_FOREVER }

var grid: GridContainer
var scroll: ScrollContainer
var status_label: Label
var ctx_menu: PopupMenu

var _trunk_id: int = 0
var _trunk_name: String = ""
var _assets_full: Array = []
var _rendered := 0
var _grid_gen := 0
var _rendering := false
var _ctx_asset_id := 0


func _ready() -> void:
	_trunk_id = Api.current_trunk_id
	_trunk_name = Api.current_trunk
	if _trunk_name == Api.TRUNK_PRIVATE and not await Lock.require_unlock():
		_go_back()
		return
	_build_ui()
	_refresh_grid.call_deferred()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	var top := HBoxContainer.new()
	root.add_child(top)

	var btn_back := Button.new()
	btn_back.text = "← 返回"
	btn_back.custom_minimum_size = Vector2(0, BACK_BTN_H)
	btn_back.add_theme_font_size_override("font_size", 20)
	btn_back.pressed.connect(_go_back)
	top.add_child(btn_back)

	var title := Label.new()
	title.text = "最近删除（" + _trunk_name + "）"
	title.add_theme_font_size_override("font_size", 20)
	top.add_child(title)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	var btn_clear := Button.new()
	btn_clear.text = "清空"
	btn_clear.pressed.connect(_clear_all)
	top.add_child(btn_clear)

	status_label = Label.new()
	root.add_child(status_label)

	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.get_v_scroll_bar().value_changed.connect(_on_scroll)
	root.add_child(scroll)

	grid = GridContainer.new()
	grid.columns = 4
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)

	ctx_menu = PopupMenu.new()
	add_child(ctx_menu)
	ctx_menu.id_pressed.connect(_on_ctx_menu)


# --- Loading ----------------------------------------------------------------

func _refresh_grid() -> void:
	_clear_grid()
	if _trunk_id <= 0:
		status_label.text = "无效"
		return
	var out: Array = []
	var cursor := ""
	while true:
		var r: Dictionary = await Api.list_trash(_trunk_id, cursor)
		if r.has("error"):
			status_label.text = "无法加载最近删除"
			return
		var data: Dictionary = r["data"]
		out.append_array(data["assets"])
		cursor = str(data.get("next_cursor", ""))
		if cursor == "":
			break
	_assets_full = out
	if out.is_empty():
		status_label.text = "最近删除为空"
	_render_cells(0)


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
	var asset_id := int(a["id"])
	var btn := TextureButton.new()
	btn.custom_minimum_size = Vector2(THUMB_SIZE, THUMB_SIZE)
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_KEEP_ASPECT_CENTERED
	btn.pressed.connect(_show_item_menu.bind(asset_id))
	grid.add_child(btn)
	_load_thumb(btn, asset_id, gen)


## Fills a recycle-bin thumbnail without blocking the render loop.
func _load_thumb(btn: TextureButton, asset_id: int, gen: int) -> void:
	var body := Cache.read_thumb(asset_id)
	if body.is_empty():
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


# --- Context menu / actions --------------------------------------------------

func _show_item_menu(asset_id: int) -> void:
	_ctx_asset_id = asset_id
	ctx_menu.clear()
	ctx_menu.add_item("恢复", MenuId.RESTORE)
	ctx_menu.add_item("永久删除", MenuId.DELETE_FOREVER)
	ctx_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _on_ctx_menu(id: int) -> void:
	match id:
		MenuId.RESTORE:
			await _restore(_ctx_asset_id)
		MenuId.DELETE_FOREVER:
			await _delete_forever(_ctx_asset_id)


func _restore(asset_id: int) -> void:
	await Api.restore_asset(asset_id)
	_refresh_grid.call_deferred()


## 永久删除 is the one irreversible action in the app — there is no bin behind it
## and the blob goes with the row — so it asks first, the same way deleting a
## non-empty album does. Everything else (grid 删除, 从本机删除) is recoverable
## enough to fire on the tap.
func _delete_forever(asset_id: int) -> void:
	var popup := ConfirmationDialog.new()
	popup.title = "永久删除"
	popup.ok_button_text = "永久删除"
	popup.dialog_text = "永久删除这一项？云端文件立即删除，无法恢复。"
	popup.confirmed.connect(_do_delete_forever.bind(popup, asset_id))
	popup.canceled.connect(popup.queue_free)
	add_child(popup)
	popup.popup_centered()


func _do_delete_forever(popup: ConfirmationDialog, asset_id: int) -> void:
	if is_instance_valid(popup):
		popup.queue_free()
	var r: Dictionary = await Api.delete_trash(asset_id)
	if r.has("error"):
		status_label.text = "永久删除失败：" + str(r["error"])
		return
	Cache.remove_original_by_id(asset_id)
	Cache.remove_thumb_by_id(asset_id)
	_refresh_grid.call_deferred()


func _clear_all() -> void:
	if _assets_full.is_empty():
		return
	var popup := ConfirmationDialog.new()
	popup.title = "清空最近删除"
	popup.ok_button_text = "清空"
	popup.dialog_text = "清空「%s」的最近删除？其中 %d 项将被永久删除，无法恢复。" % [
		_trunk_name, _assets_full.size(),
	]
	popup.confirmed.connect(_do_clear_all.bind(popup))
	popup.canceled.connect(popup.queue_free)
	add_child(popup)
	popup.popup_centered()


func _do_clear_all(popup: ConfirmationDialog) -> void:
	if is_instance_valid(popup):
		popup.queue_free()
	var r: Dictionary = await Api.clear_trash(_trunk_id)
	if r.has("error"):
		status_label.text = "清空失败：" + str(r["error"])
		return
	# Gone for good, so what the cache kept for recycle-bin browsing is dead
	# weight now: drop this trunk's cached originals and thumbnails with them.
	for a in _assets_full:
		var id := int(a.get("id", 0))
		Cache.remove_original_by_id(id)
		Cache.remove_thumb_by_id(id)
	_refresh_grid.call_deferred()


func _go_back() -> void:
	get_tree().change_scene_to_file("res://scenes/albums.tscn")
