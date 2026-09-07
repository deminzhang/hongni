extends Control
## Settings scene: server URL/token, local storage policy, parent PIN, LAN scan.
## Sync mode is unified two-way and no longer configured per album.

var url_edit: LineEdit
var token_edit: LineEdit
var status: Label
var pin_edit: LineEdit
var pin_status: Label
var chk_clean: CheckButton
var spin_free: SpinBox
var storage_status: Label


func _ready() -> void:
	_build_ui()
	_refresh_storage_status()


func _build_ui() -> void:
	var root := ScrollContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(root)

	var v := VBoxContainer.new()
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_child(v)

	var title := Label.new()
	title.text = "红泥 · 设置"
	title.add_theme_font_size_override("font_size", 28)
	v.add_child(title)

	# --- Server section ---
	var hdr_srv := Label.new()
	hdr_srv.text = "服务器"
	v.add_child(hdr_srv)

	var l1 := Label.new()
	l1.text = "服务器地址 (http://<ip>:<port>)"
	v.add_child(l1)
	url_edit = LineEdit.new()
	url_edit.text = Store.server_url()
	url_edit.placeholder_text = "http://192.168.1.5:8354"
	v.add_child(url_edit)

	var l2 := Label.new()
	l2.text = "令牌 (HONGNI_TOKEN)"
	v.add_child(l2)
	token_edit = LineEdit.new()
	token_edit.text = Store.token()
	token_edit.secret = true
	v.add_child(token_edit)

	var hbox := HBoxContainer.new()
	v.add_child(hbox)
	var btn_save := Button.new()
	btn_save.text = "保存并测试"
	btn_save.pressed.connect(_save)
	hbox.add_child(btn_save)
	var btn_scan := Button.new()
	btn_scan.text = "扫描局域网"
	btn_scan.pressed.connect(_scan_lan)
	hbox.add_child(btn_scan)

	status = Label.new()
	v.add_child(status)

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

	# --- Parent PIN section ---
	var hdr_pin := Label.new()
	hdr_pin.text = "家长 PIN"
	v.add_child(hdr_pin)

	var pin_row := HBoxContainer.new()
	v.add_child(pin_row)
	pin_edit = LineEdit.new()
	pin_edit.placeholder_text = "4–6 位数字 PIN"
	pin_edit.secret = true
	pin_edit.max_length = 6
	pin_row.add_child(pin_edit)
	var btn_pin := Button.new()
	btn_pin.text = "设置 PIN"
	btn_pin.pressed.connect(_set_pin)
	pin_row.add_child(btn_pin)
	pin_status = Label.new()
	v.add_child(pin_status)

	var btn_back := Button.new()
	btn_back.text = "← 返回"
	btn_back.pressed.connect(_go_back)
	v.add_child(btn_back)


func _save() -> void:
	Store.set_server_url(url_edit.text)
	Store.set_token(token_edit.text)
	var r: Dictionary = await Api.check_token()
	if r.has("error"):
		status.text = "连接失败：" + str(r.get("error", ""))
	else:
		status.text = "已连接 ✓"


func _set_pin() -> void:
	var pin := pin_edit.text.strip_edges()
	if not pin.is_valid_int() or pin.length() < 4 or pin.length() > 6:
		pin_status.text = "PIN 需为 4–6 位数字"
		return
	var salt := Lock.random_salt()
	var hash := Lock.hash_pin(pin, salt)
	Store.settings["master_pin_hash"] = hash
	Store.settings["master_pin_salt"] = salt
	Store.save_settings()
	pin_edit.text = ""
	pin_status.text = "家长 PIN 已设置"


func _scan_lan() -> void:
	status.text = "扫描中…"
	if not Lock.lan_result.is_connected(_on_lan_result):
		Lock.lan_result.connect(_on_lan_result)
	Lock.scan_lan()


func _on_lan_result(addresses: Array) -> void:
	if addresses.is_empty():
		status.text = "未发现局域网服务"
	else:
		url_edit.text = addresses[0]
		status.text = "发现服务，已填入地址（仍需确认令牌）"


# --- Local storage / auto-clean ---

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
