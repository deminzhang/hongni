extends Node
## HTTP client for the hongni server API. Every method returns a Dictionary;
## a non-empty "error" key means failure. Methods are coroutines: callers must
## `await` them.

# Metadata/small requests use a short timeout so the UI falls back to local
# cache quickly when the cloud is weak/offline; file transfers keep the longer
# default so large uploads/downloads are not cut short.
const TIMEOUT_META := 4.0
const TIMEOUT_FILE := 15.0

# Transient UI state shared across scenes (navigation context).
var current_album_id: int = 0
var current_album_name: String = ""
var current_filter: String = "all"
var viewer_assets: Array = []
var viewer_index: int = 0
# Active trunk (相册/隐私) and its built-in buckets, filled by albums.gd on
# reload so album_view can resolve "全部" aggregation, favorite toggling,
# move/copy sources, and upload targets.
var current_trunk: String = "相册"
var current_trunk_id: int = 0
var favorite_album_id: int = 0
var scatter_album_id: int = 0


func _base_url() -> String:
	return Store.server_url() + "/api/v1"


func _headers() -> PackedStringArray:
	return PackedStringArray(["Authorization: Bearer " + Store.token()])


func _do_request(method: int, path: String, body: String = "", extra_headers: PackedStringArray = PackedStringArray(), body_raw: PackedByteArray = PackedByteArray(), timeout: float = TIMEOUT_META) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout
	add_child(http)
	var headers := _headers()
	for h in extra_headers:
		headers.append(h)

	var err: int
	if body_raw.size() > 0:
		err = http.request_raw(_base_url() + path, headers, method, body_raw)
	else:
		err = http.request(_base_url() + path, headers, method, body)

	if err != OK:
		http.queue_free()
		return {"error": "request_error_%d" % err}

	var result: Array = await http.request_completed
	http.queue_free()

	var http_result: int = result[0]
	var response_code: int = result[1]
	var resp_body: PackedByteArray = result[3]
	var resp_headers: PackedStringArray = result[2]

	if http_result != HTTPRequest.RESULT_SUCCESS:
		return {"error": "连接失败（网络错误 %d）" % http_result, "status": 0}
	var is_json := false
	for h in resp_headers:
		if h.begins_with("Content-Type:") and "application/json" in h:
			is_json = true
			break

	var parsed = null
	if is_json:
		var text := resp_body.get_string_from_utf8()
		if text != "":
			parsed = JSON.parse_string(text)

	if response_code >= 400:
		var msg := resp_body.get_string_from_utf8()
		if parsed is Dictionary and parsed.has("error"):
			msg = str(parsed["error"])
		return {"error": msg, "status": response_code}

	return {"status": response_code, "data": parsed, "body": resp_body}


func check_token() -> Dictionary:
	return await _do_request(HTTPClient.METHOD_GET, "/assets?limit=1")


func asset_by_hash(hash: String) -> Dictionary:
	var r := await _do_request(HTTPClient.METHOD_GET, "/assets/by-hash/" + hash)
	if r.has("error"):
		if r.get("status", 0) == 404:
			return {"found": false}
		return r
	return {"found": true, "asset": r["data"]}


func upload_asset(path: String, name: String, media_type: String, taken_at: int, album_id: int) -> Dictionary:
	var boundary := "----hongniBoundary%d" % randi()
	var fields := {"name": name, "media_type": media_type}
	if taken_at > 0:
		fields["taken_at"] = taken_at
	if album_id > 0:
		fields["album_id"] = album_id
	var mime := _mime_for(name, media_type)
	var body := _multipart(boundary, fields, "file", path, name, mime)
	var headers := PackedStringArray(["Content-Type: multipart/form-data; boundary=" + boundary])
	return await _do_request(HTTPClient.METHOD_POST, "/assets", "", headers, body, TIMEOUT_FILE)


func list_assets(filter: String = "all", album_id: int = 0, cursor: String = "") -> Dictionary:
	var path := "/assets?filter=" + filter
	if album_id > 0:
		path += "&album_id=%d" % album_id
	if cursor != "":
		path += "&cursor=" + cursor.uri_encode()
	return await _do_request(HTTPClient.METHOD_GET, path)


func delete_asset(id: int) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_DELETE, "/assets/%d" % id)


func update_asset(id: int, fields: Dictionary) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_PATCH, "/assets/%d" % id, JSON.stringify(fields), PackedStringArray(["Content-Type: application/json"]))


# --- Recycle bin (最近删除) ---

func list_trash(trunk_id: int = 0, cursor: String = "") -> Dictionary:
	var path := "/trash"
	var qs := ""
	if trunk_id > 0:
		qs = "trunk_id=%d" % trunk_id
	if cursor != "":
		qs += ("&" if qs != "" else "") + "cursor=" + cursor.uri_encode()
	if qs != "":
		path += "?" + qs
	return await _do_request(HTTPClient.METHOD_GET, path)


func restore_asset(id: int) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_POST, "/trash/%d/restore" % id)


func delete_trash(id: int) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_DELETE, "/trash/%d" % id)


func clear_trash(trunk_id: int = 0) -> Dictionary:
	var path := "/trash"
	if trunk_id > 0:
		path += "?trunk_id=%d" % trunk_id
	return await _do_request(HTTPClient.METHOD_DELETE, path)


func list_albums() -> Dictionary:
	return await _do_request(HTTPClient.METHOD_GET, "/albums")


func create_album(name: String, parent_id: int, is_hidden: bool, sync_mode: String) -> Dictionary:
	var body := {"name": name, "sync_mode": sync_mode}
	if parent_id > 0:
		body["parent_id"] = parent_id
	if is_hidden:
		body["is_hidden"] = true
	return await _do_request(HTTPClient.METHOD_POST, "/albums", JSON.stringify(body), PackedStringArray(["Content-Type: application/json"]))


func get_asset(id: int) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_GET, "/assets/%d" % id)


func update_album(id: int, fields: Dictionary) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_PATCH, "/albums/%d" % id, JSON.stringify(fields), PackedStringArray(["Content-Type: application/json"]))


func delete_album(id: int) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_DELETE, "/albums/%d" % id)


func add_asset_to_album(album_id: int, asset_id: int) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_POST, "/albums/%d/assets" % album_id, JSON.stringify({"asset_id": asset_id}), PackedStringArray(["Content-Type: application/json"]))


func remove_asset_from_album(album_id: int, asset_id: int) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_DELETE, "/albums/%d/assets/%d" % [album_id, asset_id])


func sync_changes(cursor: int) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_GET, "/sync/changes?cursor=%d" % cursor)


func fetch_thumb(id: int) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_GET, "/assets/%d/thumb" % id)


func fetch_original(id: int) -> Dictionary:
	return await _do_request(HTTPClient.METHOD_GET, "/assets/%d/original" % id, "", PackedStringArray(), PackedByteArray(), TIMEOUT_FILE)


func thumb_url(id: int) -> String:
	return "%s/api/v1/assets/%d/thumb" % [Store.server_url(), id]


func original_url(id: int) -> String:
	return "%s/api/v1/assets/%d/original" % [Store.server_url(), id]


func _mime_for(name: String, media_type: String) -> String:
	if media_type == "video":
		return "video/mp4"
	match name.get_extension().to_lower():
		"png":
			return "image/png"
		"gif":
			return "image/gif"
		"webp":
			return "image/webp"
		"heic":
			return "image/heic"
		"heif":
			return "image/heif"
		_:
			return "image/jpeg"


func _multipart(boundary: String, fields: Dictionary, file_field: String, file_path: String, file_name: String, file_mime: String) -> PackedByteArray:
	var body := PackedByteArray()
	for key in fields:
		body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
		body.append_array(("Content-Disposition: form-data; name=\"%s\"\r\n\r\n" % key).to_utf8_buffer())
		body.append_array(str(fields[key]).to_utf8_buffer())
		body.append_array("\r\n".to_utf8_buffer())
	body.append_array(("--" + boundary + "\r\n").to_utf8_buffer())
	body.append_array(("Content-Disposition: form-data; name=\"%s\"; filename=\"%s\"\r\n" % [file_field, file_name]).to_utf8_buffer())
	body.append_array(("Content-Type: %s\r\n\r\n" % file_mime).to_utf8_buffer())
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f:
		body.append_array(f.get_buffer(f.get_length()))
		f.close()
	body.append_array("\r\n".to_utf8_buffer())
	body.append_array(("--" + boundary + "--\r\n").to_utf8_buffer())
	return body
