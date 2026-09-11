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
# Device-gallery album (系统相册 trunk) being viewed; "" outside that trunk.
var current_device_bucket: String = ""
# Server media filter for the grid being opened: "all" normally, "videos" for the
# 视频 virtual album (the trunk aggregation restricted to videos).
var current_filter: String = "all"
var viewer_assets: Array = []
var viewer_index: int = 0
# Active trunk and its built-in buckets, filled by albums.gd on reload so
# album_view can resolve "全部" aggregation, favorite toggling, move/copy
# sources, and upload targets. Starts on 系统相册 (matching albums.gd's
# TRUNK_SYSTEM): the device gallery is what the user browses, with the cloud
# showing up as each item's ☁ 已备份 state.
var current_trunk: String = "系统相册"
var current_trunk_id: int = 0
var favorite_album_id: int = 0
var scatter_album_id: int = 0
# The 散照 bucket of the 相册 (cloud) trunk: where device-gallery uploads land,
# regardless of which trunk is on screen (the private trunk has its own 散照).
var import_album_id: int = 0


const API_PATH := "/api/v1"

# Cap on requests in flight at once. A grid renders a chunk of cells at a time
# and every uncached thumbnail is its own request, so without a cap opening an
# album fires 150+ sockets simultaneously — on a weak or absent server that is a
# burst of parallel timeouts rather than one clean failure, and it starves the
# requests that matter (a sync upload, the viewer's original). Surplus requests
# wait a frame at a time for a slot; heavy transfers share the same cap, which is
# free because their callers issue them one at a time.
const MAX_CONCURRENT_REQUESTS := 6
var _inflight := 0


## Takes a concurrency slot, waiting while the cap is reached. Every call must be
## paired with _release_slot() on the way out.
func _acquire_slot() -> void:
	while _inflight >= MAX_CONCURRENT_REQUESTS:
		await get_tree().process_frame
	_inflight += 1


func _release_slot() -> void:
	_inflight = maxi(0, _inflight - 1)

## The 相册 trunk's buckets that hold un-filed photos.
const SCRATCH_BUCKETS := ["散照", "未分类散照"]
## Names that already mean something inside a trunk: a device album called 收藏
## must not be mirrored onto the favourites bucket, nor a device album called
## 散照 collide with the scratch bucket.
const RESERVED_ALBUM_NAMES := ["相册", "隐私", "收藏", "散照", "未分类散照"]
## The two cloud trunks, by their server-side top-level album name. These are
## wire values: the client's tab identifiers and the server's rows must agree,
## so they are defined once, here.
const TRUNK_CLOUD := "相册"
const TRUNK_PRIVATE := "隐私"
## Device album name -> cloud album id, so an upload from a device album resolves
## its target once instead of re-listing the albums for every photo.
var _device_albums: Dictionary = {}
## Trunk name -> its 散照 bucket id, resolved once per run.
var _trunk_scatter: Dictionary = {}


## Sends a request to the server, walking the node list on transport failure:
## the node that answered last is tried first, then the rest in priority order.
## The first node that answers (even with an HTTP error status) becomes active.
func _do_request(method: int, path: String, body: String = "", extra_headers: PackedStringArray = PackedStringArray(), body_raw: PackedByteArray = PackedByteArray(), timeout: float = TIMEOUT_META) -> Dictionary:
	await _acquire_slot()
	var out: Dictionary = await _do_request_slot_held(method, path, body, extra_headers, body_raw, timeout)
	_release_slot()
	return out


## `_do_request` body, with a concurrency slot already held by the caller. Kept
## separate so every return path above releases its slot exactly once.
func _do_request_slot_held(method: int, path: String, body: String, extra_headers: PackedStringArray, body_raw: PackedByteArray, timeout: float) -> Dictionary:
	var nodes := Store.servers()
	if nodes.is_empty():
		return {"error": "未配置服务器", "status": 0}
	var failure: Dictionary = {"error": "所有服务器结点均不可达", "status": 0}
	for idx in _node_order(nodes.size()):
		var r: Dictionary = await _request_node(nodes[idx], method, path, body, extra_headers, body_raw, timeout)
		if not r.get("transport", false):
			Store.set_active_server(idx)
			return r
		failure = r
	return failure


## Active node first, then every other node in priority order.
func _node_order(count: int) -> Array:
	var active := clampi(Store.active_server, 0, count - 1)
	var order: Array = [active]
	for i in count:
		if i != active:
			order.append(i)
	return order


## One request against one node; `transport: true` in the result marks a node
## that never answered (bad address, DNS, timeout) — the caller tries the next.
func _request_node(node: Dictionary, method: int, path: String, body: String, extra_headers: PackedStringArray, body_raw: PackedByteArray, timeout: float) -> Dictionary:
	var http := HTTPRequest.new()
	http.timeout = timeout
	add_child(http)
	var headers := PackedStringArray(["Authorization: Bearer " + str(node.get("token", ""))])
	for h in extra_headers:
		headers.append(h)

	var url := str(node.get("url", "")) + API_PATH + path
	var err: int
	if body_raw.size() > 0:
		err = http.request_raw(url, headers, method, body_raw)
	else:
		err = http.request(url, headers, method, body)

	if err != OK:
		http.queue_free()
		return {"error": "服务器地址无效（%d）" % err, "status": 0, "transport": true}

	var result: Array = await http.request_completed
	http.queue_free()

	var http_result: int = result[0]
	var response_code: int = result[1]
	var resp_body: PackedByteArray = result[3]
	var resp_headers: PackedStringArray = result[2]

	if http_result != HTTPRequest.RESULT_SUCCESS:
		return {"error": "连接失败（网络错误 %d）" % http_result, "status": 0, "transport": true}
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


## Probes every configured node in parallel; returns one bool per node, in list
## order. Results are collected by per-request callbacks, never by awaiting each
## `request_completed` in turn: `request_completed` fires once, so a fast node
## that finishes while a slow one is still being awaited would never be seen.
func probe_all() -> Array:
	var nodes := Store.servers()
	var results: Array = []
	results.resize(nodes.size())
	var pending: Array = [0]
	for i in nodes.size():
		var http := HTTPRequest.new()
		http.timeout = TIMEOUT_META
		add_child(http)
		var idx := i
		http.request_completed.connect(func(result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
			results[idx] = result == HTTPRequest.RESULT_SUCCESS and code < 400
			http.queue_free()
			pending[0] -= 1
		)
		if http.request(str(nodes[i].get("url", "")) + "/health") == OK:
			pending[0] += 1
		else:
			results[idx] = false
			http.queue_free()
	while pending[0] > 0:
		await get_tree().process_frame
	return results


## Connectivity test for a node definition that may not be saved yet: fetches
## the asset list so the token is validated too, not just reachability.
func test_node(url: String, token: String) -> Dictionary:
	url = url.strip_edges().trim_suffix("/")
	if url == "":
		return {"error": "地址为空"}
	return await _request_node({"url": url, "token": token}, HTTPClient.METHOD_GET, "/assets?limit=1", "", PackedStringArray(), PackedByteArray(), TIMEOUT_META)


## Runs `work` on a background thread and yields each frame until it completes.
## The main loop stays live (no blocking), so heavy file/CPU work (building a
## multipart body, copying a large file, etc.) never stalls the UI. `work` must
## not touch the scene tree/rendering — pure data + file I/O only.
func _bg(work: Callable) -> void:
	var done := [false]
	var t := Thread.new()
	t.start(func() -> void:
		work.call()
		done[0] = true
	)
	while not done[0]:
		await get_tree().process_frame
	t.wait_to_finish()


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
	# Reading the whole file into the multipart body is the heavy part of an
	# upload (videos are large); build it on a background thread so the main
	# loop is never blocked.
	var holder := [PackedByteArray()]
	await _bg(func() -> void:
		holder[0] = _multipart(boundary, fields, "file", path, name, mime)
	)
	var body: PackedByteArray = holder[0]
	var headers := PackedStringArray(["Content-Type: multipart/form-data; boundary=" + boundary])
	return await _do_request(HTTPClient.METHOD_POST, "/assets", "", headers, body, TIMEOUT_FILE)


func list_assets(filter: String = "all", album_id: int = 0, cursor: String = "") -> Dictionary:
	var path := "/assets?filter=" + filter
	if album_id > 0:
		path += "&album_id=%d" % album_id
	if cursor != "":
		path += "&cursor=" + cursor.uri_encode()
	return await _do_request(HTTPClient.METHOD_GET, path)


## Deletes a cloud asset. `album_id` is the album the delete came from: a real
## album drops just that album's reference, and the photo goes to the recycle bin
## only when nothing else holds it (the response's `trashed` says which happened).
func delete_asset(id: int, album_id: int = 0) -> Dictionary:
	var path := "/assets/%d" % id
	if album_id > 0:
		path += "?album_id=%d" % album_id
	return await _do_request(HTTPClient.METHOD_DELETE, path)


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


## The 散照 bucket of a cloud trunk (`相册` / `隐私`) — where a single file lands
## when it is moved or copied onto that trunk. Resolved from the album list on
## first use and cached per trunk; 0 when unavailable (offline, or the trunk
## holds no such bucket).
func resolve_scatter_album(trunk_name: String = TRUNK_CLOUD) -> int:
	if trunk_name == TRUNK_CLOUD and import_album_id > 0:
		return import_album_id
	if _trunk_scatter.has(trunk_name):
		return int(_trunk_scatter[trunk_name])
	var r: Dictionary = await list_albums()
	if r.has("error"):
		return 0
	var albums: Array = r["data"]["albums"]
	var trunk_id := _trunk_id_named(albums, trunk_name)
	if trunk_id <= 0:
		return 0
	var id := _scatter_of(albums, trunk_id)
	if id > 0:
		_trunk_scatter[trunk_name] = id
	return id


## The cloud album mirroring the device album `bucket_name`, under the 相册
## trunk: looked up by name and created on the first upload from that album, so
## the cloud side stays organised the way the system gallery is instead of
## piling every device photo into 散照. Resolved ids are cached for the run.
## Names the trunk reserves, a nameless bucket, and an unreachable cloud all
## fall back to 散照 (0 when even that is unknown, which fails the upload).
func resolve_device_album(bucket_name: String) -> int:
	var name := bucket_name.strip_edges()
	if name == "" or RESERVED_ALBUM_NAMES.has(name):
		return await resolve_scatter_album(TRUNK_CLOUD)
	if _device_albums.has(name):
		return int(_device_albums[name])
	var r: Dictionary = await list_albums()
	if r.has("error"):
		return 0
	var albums: Array = r["data"]["albums"]
	var trunk_id := _trunk_id_named(albums, TRUNK_CLOUD)
	if trunk_id <= 0:
		return 0
	for a in albums:
		if _is_child_of(a, trunk_id) and str(a.get("name", "")) == name:
			_device_albums[name] = int(a["id"])
			return int(a["id"])
	var created: Dictionary = await create_album(name, trunk_id, false, "two_way")
	if created.has("error"):
		return _scatter_of(albums, trunk_id)
	var id := int(created["data"]["id"])
	_device_albums[name] = id
	return id


## Whether album `a` is a direct child of `parent_id`. The server sends
## `"parent_id": null` for a top-level trunk, and `int(null)` is an error —
## `Dictionary.get()` hands back the stored null, not its default.
func _is_child_of(a: Dictionary, parent_id: int) -> bool:
	var pid = a.get("parent_id")
	return pid != null and int(pid) == parent_id


## The id of the top-level trunk album named `name` in `albums`, 0 when absent.
func _trunk_id_named(albums: Array, name: String) -> int:
	for a in albums:
		if a.get("parent_id") == null and str(a.get("name", "")) == name:
			return int(a["id"])
	return 0


## The trunk's 散照 bucket in `albums`, remembered for later uploads; 0 when the
## trunk has none.
func _scatter_of(albums: Array, trunk_id: int) -> int:
	for a in albums:
		if _is_child_of(a, trunk_id) and str(a.get("name", "")) in SCRATCH_BUCKETS:
			import_album_id = int(a["id"])
			return import_album_id
	return 0



func create_album(name: String, parent_id: int, is_hidden: bool, sync_mode: String) -> Dictionary:
	var body := {"name": name, "sync_mode": sync_mode}
	if parent_id > 0:
		body["parent_id"] = parent_id
	if is_hidden:
		body["is_hidden"] = true
	return await _do_request(HTTPClient.METHOD_POST, "/albums", JSON.stringify(body), PackedStringArray(["Content-Type: application/json"]))


## Moves album `id` under `parent_id` (0 = up to the trunk level). One call, not
## a list-and-reparent loop: the server does it in a transaction and merges the
## album into a same-named sibling when the target already has one, which the
## client could not do safely with a sequence of smaller requests.
## Returns {"album": {...}, "merged_into": <int|null>, "moved": <int>}.
func move_album(id: int, parent_id: int) -> Dictionary:
	var body := {"parent_id": parent_id if parent_id > 0 else null}
	return await _do_request(HTTPClient.METHOD_POST, "/albums/%d/move" % id, JSON.stringify(body), PackedStringArray(["Content-Type: application/json"]))


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
