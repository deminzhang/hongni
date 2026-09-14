extends Control
## Settings scene: server node list (one row per node, priority = row order,
## per-node sub-UI for name/address/token/身份 ID/PIN/login test/delete), local
## storage policy.

enum NodeStatus { UNKNOWN, OK, FAIL }

# Touch height of the top-bar 返回: at the stretch scale (screen width / 600) this
# lands at ~48dp on a phone, the Android minimum for a finger target.
const BACK_BTN_H := 72

const DOT_COLOR := {
	NodeStatus.UNKNOWN: Color(0.62, 0.62, 0.64),
	NodeStatus.OK: Color(0.21, 0.78, 0.35),
	NodeStatus.FAIL: Color(1.0, 0.23, 0.19),
}

## Emitted once by the 修改 PIN dialog with (current, new); both empty when the
## dialog was dismissed.
signal _pin_change_submitted(current: String, fresh: String)

var chk_clean: CheckButton
var spin_free: SpinBox
var storage_status: Label

# One row per Store.servers() entry, rebuilt on every add/remove/reorder.
var _nodes_box: VBoxContainer
var _dot_labels: Array = []
var _node_status: Array = []
# Bumped per connectivity probe so a slow one cannot overwrite a newer result.
var _probe_gen: int = 0

# Node sub-UI: hidden overlay with the fields of one node (or a new one).
var _editor_layer: Control
var _editor_title: Label
var _edit_index: int = -1
var _f_name: LineEdit
var _f_url: LineEdit
var _f_token: LineEdit
var _f_identity: LineEdit
var _f_pin: LineEdit
var _edit_status: Label
var _btn_delete: Button
var _btn_pin: Button


func _ready() -> void:
	_build_ui()
	_refresh_storage_status()
	_refresh_connectivity()


func _build_ui() -> void:
	var root := ScrollContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(root)

	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(v)

	# --- Top bar: 返回 pinned to the top-left, title beside it ---
	var top := HBoxContainer.new()
	v.add_child(top)

	var btn_back := Button.new()
	btn_back.text = "< <"
	btn_back.custom_minimum_size = Vector2(0, BACK_BTN_H)
	btn_back.add_theme_font_size_override("font_size", 20)
	btn_back.focus_mode = Control.FOCUS_NONE
	btn_back.pressed.connect(_go_back)
	top.add_child(btn_back)

	var title := Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 28)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	top.add_child(title)

	# --- Server nodes ---
	var hdr_srv := Label.new()
	hdr_srv.text = "服务器"
	v.add_child(hdr_srv)

	var hint := Label.new()
	hint.text = "按由上到下的优先级尝试，第一个连得上的结点生效；上一个可用的结点会被优先复用。\n每台设备用「身份 ID + PIN」登录：共享相册全家可见可操作，隐私相册只有本人能看到。身份 ID 首次注册为准，PIN 在首次注册时设定。"
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(hint)

	_nodes_box = VBoxContainer.new()
	v.add_child(_nodes_box)
	_rebuild_nodes()

	var srv_row := HBoxContainer.new()
	v.add_child(srv_row)
	var btn_add := Button.new()
	btn_add.text = "添加结点"
	btn_add.pressed.connect(_open_node_editor.bind(-1))
	srv_row.add_child(btn_add)
	var btn_probe := Button.new()
	btn_probe.text = "检测连接"
	btn_probe.pressed.connect(_refresh_connectivity)
	srv_row.add_child(btn_probe)

	# --- Local storage section ---
	var hdr_storage := Label.new()
	hdr_storage.text = "本地存储"
	v.add_child(hdr_storage)

	var l3 := Label.new()
	l3.text = "剩余空间低于阈值时,自动删除“很久没看”的原图/原视频本地缓存(云端有备份),只保留缩略图。"
	l3.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(l3)

	chk_clean = CheckButton.new()
	chk_clean.text = "空间低时自动清理"
	chk_clean.button_pressed = bool(Store.settings.get("cache_clean_enabled", true))
	chk_clean.toggled.connect(_on_clean_toggled)
	v.add_child(chk_clean)

	var thr_row := HBoxContainer.new()
	v.add_child(thr_row)
	var thr_lbl := Label.new()
	thr_lbl.text = "剩余空间低于 (MB)"
	thr_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	thr_row.add_child(thr_lbl)
	spin_free = SpinBox.new()
	spin_free.min_value = 128.0
	spin_free.max_value = 65536.0
	spin_free.step = 128.0
	spin_free.suffix = " MB"
	spin_free.value_changed.connect(_on_threshold_changed)
	spin_free.set_value_no_signal(float(int(Store.settings.get("cache_min_free_mb", 1024))))
	thr_row.add_child(spin_free)

	var run_row := HBoxContainer.new()
	v.add_child(run_row)
	var btn_clean := Button.new()
	btn_clean.text = "立即清理"
	btn_clean.pressed.connect(_clean_now)
	run_row.add_child(btn_clean)
	var btn_storage_refresh := Button.new()
	btn_storage_refresh.text = "刷新"
	btn_storage_refresh.pressed.connect(_refresh_storage_status)
	run_row.add_child(btn_storage_refresh)

	storage_status = Label.new()
	storage_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(storage_status)

	_build_node_editor()
	if not Lock.lan_result.is_connected(_on_lan_result):
		Lock.lan_result.connect(_on_lan_result)


# --- Node list ---------------------------------------------------------------

func _rebuild_nodes() -> void:
	# remove_child before queue_free: a deferred free would leave the old rows
	# in the container for the rest of the frame, so reorder/add/delete would
	# show a stale row list until the next frame.
	for c in _nodes_box.get_children():
		_nodes_box.remove_child(c)
		c.queue_free()
	_dot_labels.clear()
	var list := Store.servers()
	if list.is_empty():
		var empty := Label.new()
		empty.text = "尚未添加服务器结点，点“添加结点”开始。"
		_nodes_box.add_child(empty)
		return
	for i in list.size():
		_nodes_box.add_child(_build_row(i, list[i], list.size()))


## 名称 · 连通性标志 · ▲/▼ (priority) · 设置
func _build_row(index: int, node: Dictionary, total: int) -> HBoxContainer:
	var row := HBoxContainer.new()

	var dot := Label.new()
	dot.text = "●"
	dot.add_theme_font_size_override("font_size", 20)
	dot.add_theme_color_override("font_color", DOT_COLOR[_status_at(index)])
	row.add_child(dot)
	_dot_labels.append(dot)

	var name_lbl := Label.new()
	name_lbl.text = str(node.get("name", ""))
	name_lbl.tooltip_text = str(node.get("url", ""))
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	row.add_child(name_lbl)

	var btn_up := Button.new()
	btn_up.text = "▲"
	btn_up.disabled = index == 0
	btn_up.pressed.connect(_move_node.bind(index, -1))
	row.add_child(btn_up)

	var btn_down := Button.new()
	btn_down.text = "▼"
	btn_down.disabled = index == total - 1
	btn_down.pressed.connect(_move_node.bind(index, 1))
	row.add_child(btn_down)

	var btn_cfg := Button.new()
	btn_cfg.text = "设置"
	btn_cfg.pressed.connect(_open_node_editor.bind(index))
	row.add_child(btn_cfg)

	return row


## Moves a node one slot up/down; the row order IS the priority order.
func _move_node(index: int, delta: int) -> void:
	var list := Store.servers()
	var j := index + delta
	if index < 0 or j < 0 or index >= list.size() or j >= list.size():
		return
	var swap = list[index]
	list[index] = list[j]
	list[j] = swap
	Store.set_servers(list)
	if _node_status.size() == list.size():
		var st = _node_status[index]
		_node_status[index] = _node_status[j]
		_node_status[j] = st
	_rebuild_nodes()


func _status_at(index: int) -> int:
	return _node_status[index] if index >= 0 and index < _node_status.size() else NodeStatus.UNKNOWN


func _set_row_status(index: int, status: int) -> void:
	if index < 0 or index >= _node_status.size():
		return
	_node_status[index] = status
	_repaint_dots()


func _repaint_dots() -> void:
	for i in _dot_labels.size():
		_dot_labels[i].add_theme_color_override("font_color", DOT_COLOR[_status_at(i)])


## Probes every node (dots go grey while in flight) and repaints the flags.
func _refresh_connectivity() -> void:
	_probe_gen += 1
	var gen := _probe_gen
	var count := Store.servers().size()
	_node_status.resize(count)
	_node_status.fill(NodeStatus.UNKNOWN)
	_repaint_dots()
	var results: Array = await Api.probe_all()
	# A newer probe (or a list edit) supersedes this one, and the row set may
	# have changed while the requests were in flight.
	if gen != _probe_gen or results.size() != Store.servers().size():
		return
	_node_status.clear()
	for ok in results:
		_node_status.append(NodeStatus.OK if ok else NodeStatus.FAIL)
	_repaint_dots()


# --- Node sub-UI -------------------------------------------------------------

func _build_node_editor() -> void:
	_editor_layer = Control.new()
	_editor_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_editor_layer.visible = false
	add_child(_editor_layer)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_editor_layer.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_editor_layer.add_child(center)

	var margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 16)
	center.add_child(margin)

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(340, 0)
	margin.add_child(panel)

	var col := VBoxContainer.new()
	panel.add_child(col)

	_editor_title = Label.new()
	_editor_title.add_theme_font_size_override("font_size", 20)
	col.add_child(_editor_title)

	var l_name := Label.new()
	l_name.text = "名称"
	col.add_child(l_name)
	_f_name = LineEdit.new()
	_f_name.placeholder_text = "如：家里 / 云主机"
	col.add_child(_f_name)

	var l_url := Label.new()
	l_url.text = "地址 (http://<ip>:<port>)"
	col.add_child(l_url)
	var url_row := HBoxContainer.new()
	col.add_child(url_row)
	_f_url = LineEdit.new()
	_f_url.placeholder_text = "http://192.168.1.5:8354"
	_f_url.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	url_row.add_child(_f_url)
	var btn_scan := Button.new()
	btn_scan.text = "扫描局域网"
	btn_scan.pressed.connect(_scan_lan)
	url_row.add_child(btn_scan)

	var l_token := Label.new()
	l_token.text = "令牌 (HONGNI_TOKEN)"
	col.add_child(l_token)
	_f_token = LineEdit.new()
	_f_token.secret = true
	col.add_child(_f_token)

	var l_identity := Label.new()
	l_identity.text = "身份 ID"
	col.add_child(l_identity)
	_f_identity = LineEdit.new()
	_f_identity.placeholder_text = "如：爸爸 / baba"
	col.add_child(_f_identity)

	var l_pin := Label.new()
	l_pin.text = "PIN (4–6 位数字)"
	col.add_child(l_pin)
	_f_pin = LineEdit.new()
	_f_pin.secret = true
	_f_pin.max_length = 6
	col.add_child(_f_pin)

	_edit_status = Label.new()
	_edit_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(_edit_status)

	var actions := HBoxContainer.new()
	col.add_child(actions)
	var btn_test := Button.new()
	btn_test.text = "登录测试"
	btn_test.pressed.connect(_test_node)
	actions.add_child(btn_test)
	_btn_pin = Button.new()
	_btn_pin.text = "修改 PIN"
	_btn_pin.pressed.connect(_change_pin)
	actions.add_child(_btn_pin)
	_btn_delete = Button.new()
	_btn_delete.text = "删除"
	_btn_delete.pressed.connect(_delete_node)
	actions.add_child(_btn_delete)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)
	var btn_cancel := Button.new()
	btn_cancel.text = "取消"
	btn_cancel.pressed.connect(_close_node_editor)
	actions.add_child(btn_cancel)
	var btn_ok := Button.new()
	btn_ok.text = "保存"
	btn_ok.pressed.connect(_save_node)
	actions.add_child(btn_ok)


func _open_node_editor(index: int) -> void:
	_edit_index = index
	var node: Dictionary = Store.server_at(index) if index >= 0 else {}
	_f_name.text = str(node.get("name", ""))
	_f_url.text = str(node.get("url", ""))
	_f_token.text = str(node.get("token", ""))
	_f_identity.text = str(node.get("identity", ""))
	_f_pin.text = str(node.get("pin", ""))
	_editor_title.text = "编辑结点" if index >= 0 else "添加结点"
	_btn_delete.visible = index >= 0
	# 换 PIN 是服务器上的动作：只对当前生效的那个结点有意义（请求带的会话就是它
	# 的），所以编辑别的结点时不出现。
	_btn_pin.visible = index >= 0 and index == Store.active_server and str(node.get("identity", "")) != ""
	_edit_status.text = ""
	_editor_layer.visible = true


func _close_node_editor() -> void:
	_editor_layer.visible = false
	_edit_index = -1


func _save_node() -> void:
	if _f_url.text.strip_edges() == "":
		_edit_status.text = "请填写地址"
		return
	var list := Store.servers()
	var identity := _f_identity.text.strip_edges()
	# identity_id 只在与旧条目同服务器、同身份时沿用。换了任何一个，记住的那个 id
	# 都属于别人的隐私相册；置 0 让下一次登录必定走一次身份切换清理。
	var same := _edit_index >= 0 and _edit_index < list.size() \
			and str(list[_edit_index].get("identity", "")) == identity \
			and str(list[_edit_index].get("url", "")) == _f_url.text.strip_edges().trim_suffix("/")
	var entry := {
		"name": _f_name.text,
		"url": _f_url.text,
		"token": _f_token.text,
		"identity": identity,
		"pin": _f_pin.text.strip_edges(),
		"identity_id": int(list[_edit_index].get("identity_id", 0)) if same else 0,
	}
	if _edit_index >= 0 and _edit_index < list.size():
		list[_edit_index] = entry
	else:
		list.append(entry)
	Store.set_servers(list)
	# 存的结点可能带着另一个身份或另一个 PIN，手里活着的会话不再代表它。
	Api.clear_sessions()
	_close_node_editor()
	_rebuild_nodes()
	await _refresh_connectivity()


func _delete_node() -> void:
	var list := Store.servers()
	if _edit_index < 0 or _edit_index >= list.size():
		return
	list.remove_at(_edit_index)
	Store.set_servers(list)
	_close_node_editor()
	_rebuild_nodes()
	await _refresh_connectivity()


## Logs in with the values as typed, before saving: this both validates the
## token/address and registers the 身份 ID on first use, so the user learns here
## whether they are setting a PIN or proving it. The row dot follows the outcome.
func _test_node() -> void:
	var url := _f_url.text.strip_edges()
	if url == "":
		_edit_status.text = "请填写地址"
		return
	_edit_status.text = "登录中…"
	_set_row_status(_edit_index, NodeStatus.UNKNOWN)
	var r: Dictionary = await Api.login_node(url, _f_token.text, _f_identity.text, _f_pin.text)
	if r.has("error"):
		_edit_status.text = str(r.get("error", "登录失败"))
		_set_row_status(_edit_index, NodeStatus.FAIL)
	else:
		var data: Dictionary = r.get("data", {}) if r.get("data") is Dictionary else {}
		var ident: Dictionary = data.get("identity", {}) if data.get("identity") is Dictionary else {}
		var who := str(ident.get("name", _f_identity.text.strip_edges()))
		if bool(data.get("registered", false)):
			_edit_status.text = "已注册并登录：%s（首次注册已设定 PIN）" % who
		else:
			_edit_status.text = "已登录：%s" % who
		_set_row_status(_edit_index, NodeStatus.OK)


## 换 PIN：服务器先认旧 PIN，认过之后该身份的所有旧会话作废。本地记录跟着更新，
## 否则下一次自动重登会用旧 PIN 把自己挡在门外。
func _change_pin() -> void:
	if _edit_index < 0:
		return
	var scene := get_tree().current_scene
	if scene == null:
		return
	var dialog := AcceptDialog.new()
	dialog.title = "修改 PIN"
	dialog.dialog_text = "服务器会先校验当前 PIN，改完本设备的记录一并更新。"
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var cur := LineEdit.new()
	cur.secret = true
	cur.max_length = 6
	cur.placeholder_text = "当前 PIN"
	box.add_child(cur)
	var fresh := LineEdit.new()
	fresh.secret = true
	fresh.max_length = 6
	fresh.placeholder_text = "新 PIN（4–6 位数字）"
	box.add_child(fresh)
	dialog.add_child(box)
	scene.add_child(dialog)
	dialog.confirmed.connect(func() -> void: _pin_change_submitted.emit(cur.text, fresh.text))
	dialog.canceled.connect(func() -> void: _pin_change_submitted.emit("", ""))
	dialog.popup_centered()
	var pair: Array = await _pin_change_submitted
	if is_instance_valid(dialog):
		dialog.queue_free()
	var new_pin := str(pair[1]) if pair.size() > 1 else ""
	if new_pin == "":
		return
	_edit_status.text = "修改中…"
	var r: Dictionary = await Api.set_identity_pin(str(pair[0]), new_pin)
	if r.has("error"):
		_edit_status.text = str(r.get("error", "修改失败"))
		return
	Store.set_server_pin(_edit_index, new_pin.strip_edges())
	_f_pin.text = new_pin.strip_edges()
	_edit_status.text = "PIN 已更新"
	_set_row_status(_edit_index, NodeStatus.OK)


func _scan_lan() -> void:
	_edit_status.text = "扫描中…"
	Lock.scan_lan()


func _on_lan_result(addresses: Array) -> void:
	if not _editor_layer.visible:
		return
	if addresses.is_empty():
		_edit_status.text = "未发现局域网服务"
	else:
		_f_url.text = addresses[0]
		_edit_status.text = "发现服务，已填入地址（仍需确认令牌）"


# --- Local storage / auto-clean ----------------------------------------------

func _on_clean_toggled(on: bool) -> void:
	Store.settings["cache_clean_enabled"] = on
	Store.save_settings()
	_refresh_storage_status()


func _on_threshold_changed(value: float) -> void:
	Store.settings["cache_min_free_mb"] = int(value)
	Store.save_settings()
	_refresh_storage_status()


func _clean_now() -> void:
	Cache.enforce_cache()
	_refresh_storage_status()


func _refresh_storage_status() -> void:
	var free_mb := int(Cache.free_space_bytes() / Cache.MB)
	var st := Cache.originals_stats()
	var used_mb := int(st["bytes"] / Cache.MB)
	var enabled := bool(Store.settings.get("cache_clean_enabled", true))
	var line := "原件缓存 %d 个 · %d MB    剩余空间 %d MB" % [st["count"], used_mb, free_mb]
	if not enabled:
		line += "\n自动清理已关闭"
	else:
		line += "\n低于 %d MB 时清理不常看的原件" % int(Store.settings.get("cache_min_free_mb", 1024))
	storage_status.text = line


func _go_back() -> void:
	get_tree().change_scene_to_file("res://scenes/albums.tscn")
