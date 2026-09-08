extends Control
## Album browser: the active trunk (相册/隐私) shown as a grid of large album
## cards — 收藏 / 全部 / user sub-albums — laid out top-to-bottom in a
## multi-column grid. Selecting a card opens album_view.tscn (the album's pure
## photo-grid screen); long-press a card for the album menu (rename/delete).
## The 散照 bucket is retained in the data layer only: it is folded into the
## 全部 card (a trunk aggregation) and never shown as a standalone card.
## The trunk is switched via the top-bar 相册 button and the ⋮ menu's 隐私相册
## entry (PIN-gated); switching back is done by tapping 相册.

const LONG_PRESS := 0.5
const TRUNK_ALBUM := "相册"
const TRUNK_PRIVATE := "隐私"
const FAVORITE := "收藏"
const SCRATCH_BUCKETS := ["散照", "未分类散照"]
const TRUNK_COLUMNS := 2
# Card is just the preview icon (mostly) plus a single-line name label.
const CARD_SIZE := Vector2(336, 322)

enum MenuId { RENAME, DELETE_ALBUM }
enum MoreId { PRIVATE, TRASH, SYNC, SETTINGS }

var card_grid: GridContainer
var progress: ProgressBar
var btn_trunk_album: Button
var status_label: Label
var ctx_menu: PopupMenu
var more_menu: PopupMenu

var current_trunk: String = TRUNK_ALBUM
# True when the album list failed to load (offline / weak cloud). Card previews
# then read only from the cache and never wait on the network.
var _offline := false

# Long-press state. _lp_suppress swallows the 'pressed' signal that fires on
# release after a long-press, so the short-click action doesn't also run.
var _lp_suppress := false
var _lp_held := false
var _lp_token := 0

# Context target for the active album menu.
var _ctx_album_id := 0
var _ctx_album_name := ""


func _ready() -> void:
	_build_ui()
	Cache.enforce_cache()
	_reload_context.call_deferred()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# --- Top bar ---
	var top := HBoxContainer.new()
	root.add_child(top)

	var title := Label.new()
	title.text = "红泥"
	title.add_theme_font_size_override("font_size", 22)
	top.add_child(title)

	# Trunk switch button (相册) in the top bar; 隐私 lives in the ⋮ menu.
	btn_trunk_album = Button.new()
	btn_trunk_album.text = TRUNK_ALBUM
	btn_trunk_album.toggle_mode = true
	btn_trunk_album.button_pressed = true
	btn_trunk_album.pressed.connect(_on_trunk.bind(TRUNK_ALBUM))
	top.add_child(btn_trunk_album)

	var btn_system := Button.new()
	btn_system.text = "系统相册"
	btn_system.pressed.connect(_open_system_album)
	top.add_child(btn_system)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(spacer)

	# "新建相册" rendered as a compact "+" square, just left of the ⋮ menu.
	var btn_new := Button.new()
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

	# --- "更多" dropdown: 最近删除 / 立即同步 / 设置 ---
	more_menu = PopupMenu.new()
	add_child(more_menu)
	more_menu.id_pressed.connect(_on_more_menu)
	more_menu.add_item("隐私相册", MoreId.PRIVATE)
	more_menu.add_item("最近删除", MoreId.TRASH)
	more_menu.add_item("立即同步", MoreId.SYNC)
	more_menu.add_item("设置", MoreId.SETTINGS)


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
		_open_album(int(btn.get_meta("album_id")), str(btn.get_meta("album_name", "")))


func _on_long_press(btn: BaseButton) -> void:
	if btn.has_meta("album_id"):
		_show_album_menu(int(btn.get_meta("album_id")), str(btn.get_meta("album_name", "")))


# --- Navigation --------------------------------------------------------------

func _open_album(album_id: int, name: String) -> void:
	Api.current_album_id = album_id
	Api.current_album_name = name
	get_tree().change_scene_to_file("res://scenes/album_view.tscn")


# --- Context (trunk + buckets + sub-albums) ----------------------------------

func _on_trunk(name: String) -> void:
	if name == current_trunk:
		# Re-tapping the active trunk just re-syncs the toggle state.
		btn_trunk_album.button_pressed = true
		return
	if name == TRUNK_PRIVATE and not await Lock.require_unlock():
		btn_trunk_album.button_pressed = true
		return
	current_trunk = name
	_sync_trunk_state()
	_reload_context.call_deferred()


## Reflects the active trunk on the top-bar 相册 toggle: pressed only while the
## 相册 trunk is active. 隐私 is entered from the ⋮ menu, so the toggle reads as
## released there but stays the way back to 相册.
func _sync_trunk_state() -> void:
	btn_trunk_album.button_pressed = current_trunk == TRUNK_ALBUM


func _reload_context() -> void:
	for c in card_grid.get_children():
		c.queue_free()
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

	# Cards: 收藏 (only when non-empty), 全部 (= trunk aggregation), then the
	# custom sub-albums.
	if not favorite.is_empty() and await _album_has_items(int(favorite["id"])):
		_add_card(FAVORITE, int(favorite["id"]))
	_add_card("全部", trunk_id)
	for a in subs:
		_add_card(str(a["name"]), int(a["id"]))


## Whether an album has any members. Offline uses the cache snapshot (empty when
## not cached); online asks the server for the first page.
func _album_has_items(album_id: int) -> bool:
	if album_id <= 0:
		return false
	if _offline:
		return not Cache.offline_assets(album_id).is_empty()
	var r: Dictionary = await Api.list_assets("all", album_id)
	if r.has("error"):
		return false
	var arr = r.get("data", {}).get("assets", [])
	return arr is Array and not arr.is_empty()


func _find_trunk(albums: Array, name: String) -> Dictionary:
	for a in albums:
		if a.get("parent_id") == null and str(a.get("name", "")) == name:
			return a
	return {}


func _add_card(label: String, album_id: int) -> void:
	var btn := Button.new()
	btn.custom_minimum_size = CARD_SIZE
	btn.text = label
	btn.set_meta("album_id", album_id)
	btn.set_meta("album_name", label)
	_bind_long_press(btn)
	card_grid.add_child(btn)
	_load_card_preview.call_deferred(album_id, btn)


func _load_card_preview(album_id: int, btn: Button) -> void:
	if album_id <= 0:
		return
	var list: Array
	if _offline:
		list = Cache.offline_assets(album_id)
		if list.is_empty():
			return
	else:
		var r: Dictionary = await Api.list_assets("all", album_id)
		if not is_instance_valid(btn):
			return
		if r.has("error"):
			return
		Cache.snapshot_album_assets(album_id, r["data"]["assets"])
		list = r["data"]["assets"]
	if list.is_empty():
		return
	var preview_id := int(list[0]["id"])
	var body := Cache.read_thumb(preview_id)
	if body.is_empty() and not _offline:
		var t: Dictionary = await Api.fetch_thumb(preview_id)
		if t.has("error"):
			return
		body = t["body"]
		Cache.save_thumb(preview_id, body)
	if not is_instance_valid(btn) or body.is_empty():
		return
	var img := Image.new()
	if img.load_jpg_from_buffer(body) == OK:
		img.resize(int(CARD_SIZE.x), int(CARD_SIZE.y * 0.88), Image.INTERPOLATE_BILINEAR)
		btn.icon = ImageTexture.create_from_image(img)
		btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		btn.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP


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
	edit.text_submitted.connect(_do_rename_album.bind(album_id, popup))
	add_child(popup)
	popup.popup_centered()


func _do_rename_album(name: String, album_id: int, popup: AcceptDialog) -> void:
	if name.strip_edges() == "":
		return
	await Api.update_album(album_id, {"name": name.strip_edges()})
	popup.queue_free()
	_reload_context.call_deferred()


func _delete_album(album_id: int) -> void:
	if album_id <= 0:
		return
	if not await Lock.require_unlock():
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
	edit.text_submitted.connect(_do_create_album.bind(popup))
	add_child(popup)
	popup.popup_centered()


func _do_create_album(name: String, popup: AcceptDialog) -> void:
	if name.strip_edges() == "":
		return
	var r: Dictionary = await Api.list_albums()
	if r.has("error"):
		return
	var trunk := _find_trunk(r["data"]["albums"], current_trunk)
	if trunk.is_empty():
		return
	var private := current_trunk == TRUNK_PRIVATE
	# Unified two-way sync: every album now syncs the same way.
	await Api.create_album(name.strip_edges(), int(trunk["id"]), private, "two_way")
	popup.queue_free()
	_reload_context.call_deferred()


func _open_system_album() -> void:
	get_tree().change_scene_to_file("res://scenes/system_album.tscn")


func _open_trash() -> void:
	get_tree().change_scene_to_file("res://scenes/trash.tscn")


func _show_more_menu() -> void:
	more_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _on_more_menu(id: int) -> void:
	match id:
		MoreId.PRIVATE:
			await _on_trunk(TRUNK_PRIVATE)
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
	if await Lock.require_unlock():
		get_tree().change_scene_to_file("res://scenes/settings.tscn")
