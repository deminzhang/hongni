extends Node
## Parent PIN / biometric gate. Delegates PIN hashing to the Android plugin when
## available; falls back to a pure-GDScript PBKDF2-HMAC-SHA256 (100000 iters) so
## the gate works on desktop/editor too. Also proxies the plugin's system-album,
## photo-picker, and mDNS discovery functionality with desktop-safe no-op stubs.

signal lan_result(addresses: Array)
signal photo_picker_result(uris: Array)
signal _pin_prompt_submitted(text: String)



const ITERATIONS := 100000
const KEY_LEN := 32

var unlocked := false


func _ready() -> void:
	if _has_plugin():
		var p = _plugin()
		if p.has_signal("biometric_result"):
			p.biometric_result.connect(_on_biometric_result)
		if p.has_signal("lan_scan_result"):
			p.lan_scan_result.connect(_on_lan_scan_result)
		if p.has_signal("photo_picker_result"):
			p.photo_picker_result.connect(_on_photo_picker_result)


func _has_plugin() -> bool:
	return Engine.has_singleton("HongniPlugin")


func _plugin():
	return Engine.get_singleton("HongniPlugin") if _has_plugin() else null


# --- PIN ---

func random_salt() -> String:
	if _has_plugin():
		var s: String = _plugin().random_salt()
		if s != "":
			return s
	var bytes := PackedByteArray()
	bytes.resize(16)
	for i in 16:
		bytes[i] = randi() % 256
	return bytes.hex_encode()


func hash_pin(pin: String, salt: String) -> String:
	if _has_plugin():
		var h: String = _plugin().hash_pin(pin, salt)
		if h != "":
			return h
	return _pbkdf2_hex(pin.to_utf8_buffer(), _hex_decode(salt), ITERATIONS, KEY_LEN)


func verify_pin(pin: String, salt: String, expected: String) -> bool:
	var actual := hash_pin(pin, salt)
	if actual.length() != expected.length():
		return false
	var diff := 0
	for i in actual.length():
		diff |= actual.unicode_at(i) ^ expected.unicode_at(i)
	return diff == 0


func has_pin_set() -> bool:
	return str(Store.settings.get("master_pin_hash", "")) != ""


func is_unlocked() -> bool:
	return unlocked


func lock() -> void:
	unlocked = false


func unlock_with_pin(pin: String) -> bool:
	if not has_pin_set():
		unlocked = true
		return true
	if verify_pin(pin, Store.settings["master_pin_salt"], Store.settings["master_pin_hash"]):
		unlocked = true
		return true
	return false


## Blocks on a PIN prompt until unlocked. Returns true when the session is
## unlocked (no PIN set, already unlocked, or correct PIN entered).
func require_unlock() -> bool:
	if unlocked:
		return true
	if not has_pin_set():
		unlocked = true
		return true
	return await _prompt_pin()


func _prompt_pin() -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var dialog := AcceptDialog.new()
	dialog.title = "家长 PIN"
	dialog.dialog_text = "输入 PIN 解锁"
	var edit := LineEdit.new()
	edit.secret = true
	edit.max_length = 6
	dialog.add_child(edit)
	scene.add_child(dialog)
	edit.text_submitted.connect(func(t: String) -> void: _pin_prompt_submitted.emit(t))
	dialog.confirmed.connect(func() -> void: _pin_prompt_submitted.emit(edit.text))
	dialog.popup_centered()
	var text: String = await _pin_prompt_submitted
	if is_instance_valid(dialog):
		dialog.queue_free()
	return unlock_with_pin(text)


# --- Biometric ---

func unlock_with_biometric() -> void:
	if _has_plugin() and _plugin().has_biometric():
		_plugin().authenticate_biometric("解锁隐私相册")


func has_biometric() -> bool:
	return _has_plugin() and _plugin().has_biometric()


func _on_biometric_result(status: String) -> void:
	if status == "success":
		unlocked = true


# --- System album / media (plugin proxy; desktop no-op) ---

func list_media(media: String, after_cursor: String = "") -> Array:
	if not _has_plugin():
		return []
	var raw: String = _plugin().list_media(after_cursor, media)
	var parsed = JSON.parse_string(raw)
	return parsed if parsed is Array else []


func read_media_bytes(uri: String, dest_abs_path: String) -> bool:
	if not _has_plugin():
		return false
	return _plugin().read_media_bytes(uri, dest_abs_path)


## Writes an image file (absolute path) into the device system album
## (Pictures/Hongni). Android-only; false on desktop/editor.
func save_to_gallery(src_abs_path: String, display_name: String, mime_type: String) -> bool:
	if not _has_plugin():
		return false
	return _plugin().save_to_gallery(src_abs_path, display_name, mime_type)


func play_video(path_or_uri: String) -> void:
	if _has_plugin():
		_plugin().play_video(path_or_uri)
	else:
		# Desktop/editor: no plugin, open the file with the OS default app.
		OS.shell_open(path_or_uri)


func open_photo_picker() -> void:
	if _has_plugin():
		_plugin().open_photo_picker()


func _on_photo_picker_result(json_str: String) -> void:
	var parsed = JSON.parse_string(json_str)
	photo_picker_result.emit(parsed if parsed is Array else [])


# --- mDNS LAN discovery ---

func scan_lan() -> void:
	if _has_plugin():
		_plugin().scan_lan()
	else:
		lan_result.emit([])


func _on_lan_scan_result(json_str: String) -> void:
	var parsed = JSON.parse_string(json_str)
	lan_result.emit(parsed if parsed is Array else [])


# --- WorkManager backup pending ---

func consume_backup_pending() -> bool:
	if _has_plugin():
		return _plugin().consume_backup_pending()
	return false


# --- PBKDF2-HMAC-SHA256 (GDScript fallback) ---

func _pbkdf2_hex(password: PackedByteArray, salt: PackedByteArray, iterations: int, dklen: int) -> String:
	var dk := PackedByteArray()
	var block_index := 1
	while dk.size() < dklen:
		var u := _hmac_sha256(password, salt + _int32_be(block_index))
		var t := u.duplicate()
		for i in range(1, iterations):
			u = _hmac_sha256(password, u)
			for j in t.size():
				t[j] = t[j] ^ u[j]
		dk.append_array(t)
		block_index += 1
	return dk.slice(0, dklen).hex_encode()


func _hmac_sha256(key: PackedByteArray, data: PackedByteArray) -> PackedByteArray:
	const BLOCK_SIZE := 64
	var k := key.duplicate()
	if k.size() > BLOCK_SIZE:
		k = _sha256(k)
	while k.size() < BLOCK_SIZE:
		k.append(0)
	var ipad := PackedByteArray()
	var opad := PackedByteArray()
	ipad.resize(BLOCK_SIZE)
	opad.resize(BLOCK_SIZE)
	for i in BLOCK_SIZE:
		ipad[i] = k[i] ^ 0x36
		opad[i] = k[i] ^ 0x5C
	return _sha256(opad + _sha256(ipad + data))


func _sha256(data: PackedByteArray) -> PackedByteArray:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish()


func _int32_be(v: int) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(4)
	b[0] = (v >> 24) & 0xFF
	b[1] = (v >> 16) & 0xFF
	b[2] = (v >> 8) & 0xFF
	b[3] = v & 0xFF
	return b


func _hex_decode(s: String) -> PackedByteArray:
	var b := PackedByteArray()
	var i := 0
	while i + 1 < s.length():
		b.append(("0x" + s.substr(i, 2)).hex_to_int())
		i += 2
	return b
