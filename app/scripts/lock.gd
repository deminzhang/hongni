extends Node
## 身份 PIN / biometric gate. The PIN is the node's own 身份 ID + PIN — the same
## one the server authenticates — so the door here is a local comparison against
## it and needs no second copy of the secret to keep in sync (and works offline).
## Also proxies the plugin's system-album, photo-picker, and mDNS discovery
## functionality with desktop-safe no-op stubs.

signal lan_result(addresses: Array)
signal photo_picker_result(uris: Array)
## MediaStore ids the platform actually removed, after a delete request. Android
## asks the user to confirm before another app's media can be deleted, so the
## outcome arrives here rather than in the return value of delete_media().
signal media_deleted(ids: Array)

## Every emission of `media_deleted`, counted. A caller that must not miss a
## report which raced ahead of its await reads this before the request and hands
## it to await_media_delete().
var _media_delete_seq := 0
var _media_delete_ids: Array = []
signal inapp_video_closed
signal inapp_video_prepared
signal _pin_prompt_submitted(text: String)



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
		if p.has_signal("media_delete_result"):
			p.media_delete_result.connect(_on_media_delete_result)
		if p.has_signal("inapp_video_closed"):
			p.inapp_video_closed.connect(func() -> void: inapp_video_closed.emit())
		if p.has_signal("inapp_video_prepared"):
			p.inapp_video_prepared.connect(func() -> void: inapp_video_prepared.emit())


func _has_plugin() -> bool:
	return Engine.has_singleton("HongniPlugin")


func _plugin():
	return Engine.get_singleton("HongniPlugin") if _has_plugin() else null


# --- PIN ---

## Whether the active node carries a PIN. The PIN belongs to the node's 身份 ID:
## one secret, typed once at setup, used both as the 隐私相册 door here and as the
## server login credential.
func has_pin_set() -> bool:
	return Store.active_pin() != ""


func is_unlocked() -> bool:
	return unlocked


func lock() -> void:
	unlocked = false


func unlock_with_pin(pin: String) -> bool:
	if not has_pin_set():
		unlocked = true
		return true
	if not _constant_time_equal(pin, Store.active_pin()):
		return false
	unlocked = true
	return true


## Compares two secrets without stopping at the first difference. Overkill
## against someone holding the unlocked device, but it costs nothing.
func _constant_time_equal(a: String, b: String) -> bool:
	if a.length() != b.length():
		return false
	var diff := 0
	for i in a.length():
		diff |= a.unicode_at(i) ^ b.unicode_at(i)
	return diff == 0


## Blocks on a PIN prompt until unlocked. Returns true when the session is
## unlocked (no PIN set, already unlocked, or correct PIN entered).
func require_unlock() -> bool:
	if unlocked:
		return true
	if not has_pin_set():
		unlocked = true
		return true
	return await _prompt_pin()


func _prompt_pin(prompt: String = "输入身份 PIN 解锁") -> bool:
	var scene := get_tree().current_scene
	if scene == null:
		return false
	var dialog := AcceptDialog.new()
	dialog.title = "身份 PIN"
	dialog.dialog_text = prompt
	var edit := LineEdit.new()
	edit.secret = true
	edit.max_length = 6
	dialog.add_child(edit)
	scene.add_child(dialog)
	# Closing the dialog (X) must resolve the await too, or the caller hangs
	# forever: an empty PIN never verifies, so it lands on the refusal path.
	edit.text_submitted.connect(func(t: String) -> void: _pin_prompt_submitted.emit(t))
	dialog.confirmed.connect(func() -> void: _pin_prompt_submitted.emit(edit.text))
	dialog.canceled.connect(func() -> void: _pin_prompt_submitted.emit(""))
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


## Generates a small center-cropped PNG thumbnail of a MediaStore item (image or
## video) into dest_abs_path. Android plugin only; false on desktop/editor.
func load_thumbnail(uri: String, dest_abs_path: String, size_px: int) -> bool:
	if not _has_plugin():
		return false
	return _plugin().load_thumbnail(uri, dest_abs_path, size_px)


## Decodes a MediaStore image at up to max_px on its longest edge (aspect kept,
## no crop) into dest_abs_path as JPEG, for the in-app viewer. Android only.
func load_media_preview(uri: String, dest_abs_path: String, max_px: int) -> bool:
	if not _has_plugin():
		return false
	return _plugin().load_media_preview(uri, dest_abs_path, max_px)


## Writes an image file (absolute path) into the device system album
## (Pictures/红泥). Android-only; false on desktop/editor.
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


# --- In-app video playback (Android plugin MediaPlayer -> Godot frames) ------

## Starts decoding a local path into the app; GDScript polls grab_inapp_frame()
## and renders it in an in-app TextureRect. The player is prepared **paused**;
## start it with resume_inapp_video() once inapp_video_prepared fires.
## Android-only; false on desktop.
func start_inapp_video(path: String, frame_w: int, frame_h: int) -> bool:
	if not _has_plugin():
		return false
	return _plugin().start_inapp_video(path, frame_w, frame_h)


## True once the player finished preparing (paused on its first frame).
func is_inapp_video_prepared() -> bool:
	if not _has_plugin():
		return false
	return _plugin().inapp_video_prepared()


## True once the clip played to its end (cleared by seek_inapp_video).
func inapp_video_completed() -> bool:
	if not _has_plugin():
		return false
	return _plugin().inapp_video_completed()


## Current position in ms; 0 when nothing is prepared.
func inapp_video_position_ms() -> int:
	if not _has_plugin():
		return 0
	return int(_plugin().inapp_video_position_ms())


## Clip duration in ms; -1 when unknown.
func inapp_video_duration_ms() -> int:
	if not _has_plugin():
		return -1
	return int(_plugin().inapp_video_duration_ms())


func seek_inapp_video(ms: int) -> bool:
	if not _has_plugin():
		return false
	return _plugin().seek_inapp_video(ms)


## Asks the plugin to build the preview-frame seek bar (count frames tiled into
## one RGBA image) off the main thread. Collect it with take_video_filmstrip().
func request_video_filmstrip(path: String, count: int, cell_w: int, cell_h: int, token: int) -> bool:
	if not _has_plugin():
		return false
	return _plugin().request_video_filmstrip(path, count, cell_w, cell_h, token)


## The filmstrip RGBA bytes for `token` (empty while it is still building, when
## it failed, or when a newer request replaced it).
func take_video_filmstrip(token: int) -> PackedByteArray:
	if not _has_plugin():
		return PackedByteArray()
	return _plugin().take_video_filmstrip(token)


func pause_inapp_video() -> bool:
	if not _has_plugin():
		return false
	return _plugin().pause_inapp_video()


func resume_inapp_video() -> bool:
	if not _has_plugin():
		return false
	return _plugin().resume_inapp_video()


func is_inapp_video_playing() -> bool:
	if not _has_plugin():
		return false
	return _plugin().is_inapp_video_playing()


func stop_inapp_video() -> bool:
	if not _has_plugin():
		return false
	return _plugin().stop_inapp_video()


## Latest decoded frame as packed RGBA bytes (empty when none/desktop).
func grab_inapp_frame() -> PackedByteArray:
	if not _has_plugin():
		return PackedByteArray()
	return _plugin().grab_inapp_frame()


## ms since the SurfaceTexture last produced a frame, -1 if none yet. Used to
## detect a stalled in-app decode (frozen picture) and fall back to the OS player.
func inapp_frame_age_ms() -> int:
	if not _has_plugin():
		return -1
	return int(_plugin().inapp_frame_age_ms())


## Requests a video thumbnail (frame from a URL with optional Bearer token, or a
## local path) into dest_abs_path, on a background thread. Returns immediately.
func extract_video_thumb(source: String, token: String, dest_abs_path: String, size_px: int, asset_id: int) -> bool:
	if not _has_plugin():
		return false
	return _plugin().extract_video_thumb(source, token, dest_abs_path, size_px, asset_id)


## Asset ids whose video thumbnails just finished (positive = ok, negative =
## failed). Drain this each frame while the grid is up.
func poll_video_thumb_finished() -> PackedInt32Array:
	if not _has_plugin():
		return PackedInt32Array()
	return _plugin().poll_video_thumb_finished()


func open_photo_picker() -> void:
	if _has_plugin():
		_plugin().open_photo_picker()


func _on_photo_picker_result(json_str: String) -> void:
	var parsed = JSON.parse_string(json_str)
	photo_picker_result.emit(parsed if parsed is Array else [])


## Whether the app can see the whole device gallery. Android 14 lets the user
## grant a hand-picked subset of photos instead, in which case a scan lists only
## those and says nothing about the rest. Desktop reads the Pictures folder
## directly, so it is always complete.
func has_full_media_access() -> bool:
	if _has_plugin():
		return _plugin().has_full_media_access()
	return true


## Asks the platform to delete the given device items (each needs `uri` and
## `key`). Returns the number removed outright, or -1 when Android raised its
## confirmation dialog — the ids that actually went away then arrive on
## `media_deleted`, and the caller should read the outcome back with
## await_media_delete(). Desktop never calls this: there is no MediaStore.
func delete_media(items: Array) -> int:
	if not _has_plugin():
		return -1
	var payload := []
	for it in items:
		payload.append({"uri": str(it.get("uri", "")), "id": str(it.get("key", ""))})
	return int(_plugin().delete_media(JSON.stringify(payload)))


## The delete-report counter as of now; read it just before delete_media().
func media_delete_seq() -> int:
	return _media_delete_seq


## Waits for a delete report newer than `since` and returns the new counter.
##
## Waiting on the signal directly would be wrong: Android 10 reports a partial
## success from inside delete_media() itself, before the caller can await, and
## the confirmation dialog's outcome is a second report. Racing ahead is
## therefore normal, not an error — so this polls the counter.
func await_media_delete(since: int, timeout: float = 30.0) -> int:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while _media_delete_seq <= since:
		if Time.get_ticks_msec() > deadline:
			return _media_delete_seq
		await get_tree().process_frame
	return _media_delete_seq


func _on_media_delete_result(json_str: String) -> void:
	var parsed = JSON.parse_string(json_str)
	_media_delete_ids = parsed if parsed is Array else []
	_media_delete_seq += 1
	media_deleted.emit(_media_delete_ids)


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
