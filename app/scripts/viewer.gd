extends Control
## Full-screen viewer: shows the original image for the current asset, with
## left/right swipe navigation. The bottom bar carries the actions (删除 /
## 存到相册) and the rightmost ⋮ menu — the shared per-asset menu (收藏 / 移动到 /
## 复制到 / 重命名 / 删除 / 详细) that used to be the grid's long-press menu,
## acting on the photo currently on screen.
##
## Videos never autoplay: the poster (or the first decoded frame) waits for ▶ /
## a tap on the picture. A tap on an image toggles the surrounding UI so the
## photo can be viewed full-bleed; a tap on a *playing* video does the same for
## the picture, and tapping again brings the controls back. While a video is
## prepared, the transport under the picture shows 播放至时间|总时间 (分:秒) over a
## seek bar built from preview frames — drag it to seek, or use the ▶/❚❚ button
## centred on the bar itself.
##
## Device (系统相册) items are shown from the device's own copy: an aspect-
## preserving preview (plugin decoder on Android, direct decode on desktop),
## videos via the same in-app/OS players, and only the ⋮ menu's 移动到/复制到/
## 删本地保云端/从本机删除/详细 (删除/存到相册 belong to the cloud and stay hidden).

const SWIPE_THRESHOLD := 80.0
# Touch height of the top-bar 返回 (~48dp once the 600px base is scaled up).
const BACK_BTN_H := 72
# In-app MediaPlayer frames are captured at this size and scaled to fit. Lower
# resolution keeps the per-frame getBitmap() readback light so playback stays
# smooth; it scales up to the video area on screen.
const VIDEO_FRAME_W := 480
const VIDEO_FRAME_H := 270
const FRAME_POLL_MS := 0.042
# Device video poster: the device thumbnail is only generated at grid size, so
# ask for a card-sized one to avoid a visibly blurred still.
const DEVICE_POSTER_SIZE := 336
# In-app playback is abandoned for the OS player when no new frame arrives for
# this long while playing (a stalled decoder). Frames normally arrive at video
# fps, so a >1.5 s gap means the picture has frozen — hand over quickly rather
# than leaving the user stuck on a still. The same delay is granted after a
# start/seek, whose first frame legitimately takes a moment (SEEK_CLOSEST
# decodes from the previous keyframe).
const STALL_TIMEOUT_MS := 1500

# Seek bar (进度条): the plugin bakes STRIP_CELLS preview frames, evenly spaced
# over the clip, into ONE image; the viewer shows it full-width as a filmstrip
# and maps a drag position to a time. A cell is requested at CELL_W x CELL_H
# pixels and stretched to the screen, so the payload stays small.
const STRIP_CELL_W := 128
const STRIP_CELL_H := 72
const STRIP_CELL_PX := 120.0
const STRIP_MIN_CELLS := 4
const STRIP_MAX_CELLS := 10
const STRIP_HEIGHT := 64.0
# After starting/pausing/seeking, decoded frames keep replacing the picture for
# this long — enough for the frame at the new position to land — then polling
# stops until playback resumes.
const FRAME_SETTLE_MS := 700
# A session that dies this soon after it started is a failed decode (unsupported
# codec), not a legitimately short clip: hand the file to the OS player.
const EARLY_DEATH_MS := 2500

const ASSET_MENU := preload("res://scripts/asset_menu.gd")
const SAFE_AREA := preload("res://scripts/safe_area.gd")

var top_bar: HBoxContainer
var bottom_row: HBoxContainer
var label_status: Label
var texture_rect: TextureRect
# Empty band above the top bar on a phone: the notch / rounded screen corners
# must not cut the 返回 / ‹ / › buttons. Hidden with the rest of the chrome, so a
# tap-to-hide still gives the picture the whole screen.
var top_pad: Control
var btn_delete: Button
var btn_save: Button
var btn_center_play: Button
var btn_menu: Button
# Video transport: time readout + preview-frame seek bar + its ▶/❚❚ button.
var video_bar: VBoxContainer
var label_time: Label
var seek_wrap: Control
var filmstrip: TextureRect
var dim_right: ColorRect
var playhead: ColorRect
var btn_playpause: Button
# Shared per-asset action menu (⋮), acting on the asset on screen.
var asset_menu: Control

# Horizontal drag/swipe state for prev/next photo navigation.
var _touch_active := false
var _touch_start := Vector2.ZERO
var _touch_time := 0
# Bumped by _show_current; async work (video download + prepare) checks it so a
# slow fetch cannot hijack the asset the user has since swiped to.
var _show_gen := 0
# Whether the current video has a cached poster (no need to paint frame 1).
var _has_poster := false

# In-app video playback state (Android plugin renders frames into texture_rect).
var _video_session := false      # a plugin player exists for the current asset
var _video_preparing := false    # local copy being fetched/staged
var _video_playing := false
var _video_broken := false       # no in-app decoder, or it errored out
var _video_played_once := false  # ▶ over the picture is for the first play only
var _video_pos_ms := 0
var _video_duration_ms := -1     # -1 = unknown
var _video_started_ms := 0       # session start, for the early-death handoff
var _stall_check_after := 0      # ignore the stall watchdog until then
var _play_when_ready := false
var _seeking := false
var _strip_token := 0            # identifies the filmstrip request in flight
var _strip_cells := STRIP_MIN_CELLS
var _strip_waiting := false
var _frame_accum := 0.0
var _frame_until := 0            # poll frames until then (poster/seek frame)
# Surrounding UI (top bar, action row, transport) — hidden for full-bleed view.
var _chrome_visible := true


func _ready() -> void:
	_build_ui()
	if not Lock.inapp_video_closed.is_connected(_on_inapp_closed):
		Lock.inapp_video_closed.connect(_on_inapp_closed)
	if not Lock.inapp_video_prepared.is_connected(_on_inapp_prepared):
		Lock.inapp_video_prepared.connect(_on_inapp_prepared)
	_show_current()


func _build_ui() -> void:
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Swipes starting anywhere except buttons must reach _gui_input below.
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# 刘海 / 屏幕圆角：垫在顶栏之上的空条，让 返回/‹/› 落到圆角以下；隐藏周边
	# UI 时它跟着一起收起来，画面照旧铺满整屏。
	top_pad = Control.new()
	top_pad.custom_minimum_size = Vector2(0, SAFE_AREA.top_inset())
	top_pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top_pad)

	top_bar = HBoxContainer.new()
	top_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(top_bar)

	var btn_back := Button.new()
	btn_back.text = "← 返回"
	btn_back.custom_minimum_size = Vector2(0, BACK_BTN_H)
	btn_back.add_theme_font_size_override("font_size", 20)
	btn_back.pressed.connect(_go_back)
	top_bar.add_child(btn_back)

	var btn_prev := Button.new()
	btn_prev.text = "‹"
	btn_prev.pressed.connect(_prev)
	top_bar.add_child(btn_prev)

	var btn_next := Button.new()
	btn_next.text = "›"
	btn_next.pressed.connect(_next)
	top_bar.add_child(btn_next)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top_bar.add_child(spacer)

	texture_rect = TextureRect.new()
	texture_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	texture_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	texture_rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	texture_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(texture_rect)

	# Big center ▶ exactly over the video frame; visible until the video has
	# played for the first time, then the transport's own button takes over.
	btn_center_play = Button.new()
	btn_center_play.text = "▶"
	btn_center_play.add_theme_font_size_override("font_size", 64)
	btn_center_play.custom_minimum_size = Vector2(96, 96)
	btn_center_play.visible = false
	btn_center_play.pressed.connect(_on_video_tap)
	texture_rect.add_child(btn_center_play)
	btn_center_play.anchor_left = 0.5
	btn_center_play.anchor_top = 0.5
	btn_center_play.anchor_right = 0.5
	btn_center_play.anchor_bottom = 0.5
	btn_center_play.grow_horizontal = Control.GROW_DIRECTION_BOTH
	btn_center_play.grow_vertical = Control.GROW_DIRECTION_BOTH
	btn_center_play.offset_left = -48
	btn_center_play.offset_top = -48
	btn_center_play.offset_right = 48
	btn_center_play.offset_bottom = 48

	# --- Video transport: 播放至时间|总时间 over the preview-frame seek bar ---
	video_bar = VBoxContainer.new()
	video_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	video_bar.visible = false
	root.add_child(video_bar)

	label_time = Label.new()
	label_time.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_time.mouse_filter = Control.MOUSE_FILTER_IGNORE
	video_bar.add_child(label_time)

	seek_wrap = Control.new()
	seek_wrap.custom_minimum_size = Vector2(0, STRIP_HEIGHT)
	seek_wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	seek_wrap.mouse_filter = Control.MOUSE_FILTER_STOP
	seek_wrap.gui_input.connect(_on_seek_input)
	video_bar.add_child(seek_wrap)

	# Dark track behind the frames — also the look before the strip arrives.
	var track := ColorRect.new()
	track.color = Color(0, 0, 0, 0.65)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	seek_wrap.add_child(track)
	track.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	filmstrip = TextureRect.new()
	filmstrip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	filmstrip.stretch_mode = TextureRect.STRETCH_SCALE
	filmstrip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	seek_wrap.add_child(filmstrip)
	filmstrip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# Everything right of the playhead is dimmed; the playhead itself is a thin
	# white line — together they read as progress over the frames.
	dim_right = ColorRect.new()
	dim_right.color = Color(0, 0, 0, 0.55)
	dim_right.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dim_right.anchor_left = 0.0
	dim_right.anchor_right = 1.0
	dim_right.anchor_top = 0.0
	dim_right.anchor_bottom = 1.0
	seek_wrap.add_child(dim_right)

	playhead = ColorRect.new()
	playhead.color = Color(1, 1, 1, 0.95)
	playhead.mouse_filter = Control.MOUSE_FILTER_IGNORE
	playhead.anchor_left = 0.0
	playhead.anchor_right = 0.0
	playhead.anchor_top = 0.0
	playhead.anchor_bottom = 1.0
	seek_wrap.add_child(playhead)

	btn_playpause = Button.new()
	btn_playpause.text = "▶"
	btn_playpause.add_theme_font_size_override("font_size", 22)
	btn_playpause.custom_minimum_size = Vector2(64, 44)
	btn_playpause.focus_mode = Control.FOCUS_NONE
	btn_playpause.visible = false
	btn_playpause.pressed.connect(_play_pause)
	seek_wrap.add_child(btn_playpause)
	btn_playpause.anchor_left = 0.5
	btn_playpause.anchor_top = 0.5
	btn_playpause.anchor_right = 0.5
	btn_playpause.anchor_bottom = 0.5
	btn_playpause.grow_horizontal = Control.GROW_DIRECTION_BOTH
	btn_playpause.grow_vertical = Control.GROW_DIRECTION_BOTH
	btn_playpause.offset_left = -32
	btn_playpause.offset_top = -22
	btn_playpause.offset_right = 32
	btn_playpause.offset_bottom = 22
	seek_wrap.resized.connect(_place_playhead)

	label_status = Label.new()
	label_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label_status.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(label_status)

	# --- Bottom action row: 删除 / 存到相册 + the ⋮ menu (rightmost) ---
	bottom_row = HBoxContainer.new()
	root.add_child(bottom_row)

	btn_delete = Button.new()
	btn_delete.text = "删除"
	btn_delete.pressed.connect(_delete_current)
	bottom_row.add_child(btn_delete)

	btn_save = Button.new()
	btn_save.text = "存到相册"
	btn_save.pressed.connect(_save_to_album)
	bottom_row.add_child(btn_save)

	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bottom_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bottom_row.add_child(bottom_spacer)

	btn_menu = Button.new()
	btn_menu.text = "⋮"
	btn_menu.focus_mode = Control.FOCUS_NONE
	btn_menu.custom_minimum_size = Vector2(44, 44)
	btn_menu.pressed.connect(_show_asset_menu)
	bottom_row.add_child(btn_menu)

	# --- Shared asset menu (详细 / 收藏 / 移动到 / 复制到 / 重命名 / 删除) ---
	asset_menu = ASSET_MENU.new()
	asset_menu.changed.connect(_on_menu_changed)
	asset_menu.notice.connect(_on_menu_notice)
	asset_menu.setup(self, _move_source_album)


func _show_current() -> void:
	_show_gen += 1
	_stop_video()
	_set_chrome_visible(true)
	# The 详细 sheet describes one asset: drop it when another one comes up.
	asset_menu.close_details()
	if Api.viewer_assets.is_empty() or Api.viewer_index < 0 or Api.viewer_index >= Api.viewer_assets.size():
		texture_rect.texture = null
		label_status.text = ""
		return
	var a: Dictionary = Api.viewer_assets[Api.viewer_index]
	if DeviceMedia.is_device(a):
		_show_device_current(a)
		return
	var asset_id := int(a.get("id", 0))
	if asset_id <= 0:
		# Local-only (not yet uploaded) photo: show a hint, nothing to fetch.
		texture_rect.texture = null
		label_status.text = "本地待上传 · 尚未同步到云端"
		return
	# 收藏 里不提供 删除/移动到/复制（见 asset_menu.in_favorites_view）：viewer 的
	# 删除按钮是另一条入口，必须和 ⋮ 菜单一致，否则从收藏点进来看大图就绕过去了。
	btn_delete.visible = not asset_menu.in_favorites_view()
	var name := str(a.get("original_name", ""))
	var ext := str(a.get("ext", ""))
	var mime: String = a.get("mime_type", "image/jpeg")
	var media_type := str(a.get("media_type", "image"))
	texture_rect.texture = null
	Cache.mark_viewed(asset_id)
	btn_save.visible = OS.get_name() == "Android" and media_type != "video"
	label_status.text = "加载中…"

	if media_type == "video":
		# No autoplay and no download yet: the poster (when the server or
		# Android MediaStore produced one) waits for ▶ / a tap on the picture.
		label_status.text = "视频"
		var poster := Cache.read_thumb(asset_id)
		if poster.size() > 0:
			var pimg := Image.new()
			if pimg.load_jpg_from_buffer(poster) == OK:
				texture_rect.texture = ImageTexture.create_from_image(pimg)
				_has_poster = true
		btn_center_play.visible = true
		return

	# Prefer the cached full-res copy (works offline); otherwise fetch from the
	# server and write it through to the cache (which re-checks free space).
	var body := Cache.read_original(asset_id, name, ext)
	var is_thumb_fallback := false
	if body.is_empty():
		var r: Dictionary = await Api.fetch_original(asset_id)
		if r.has("error"):
			# Offline / unreachable: fall back to the cached thumbnail.
			body = Cache.read_thumb(asset_id)
			if body.is_empty():
				label_status.text = "无法加载原图"
				return
			is_thumb_fallback = true
		else:
			body = r["body"]
			await Cache.save_original_bg(asset_id, name, body, ext)
	if body.is_empty():
		label_status.text = "无法加载原图"
		return
	var img := Image.new()
	var err := img.load_jpg_from_buffer(body)
	if mime == "image/png":
		err = img.load_png_from_buffer(body)
	elif mime == "image/webp":
		err = img.load_webp_from_buffer(body)
	if err == OK:
		texture_rect.texture = ImageTexture.create_from_image(img)
		if is_thumb_fallback:
			label_status.text = "离线缩略图 · 原图未缓存"
		else:
			label_status.text = ""
	elif is_thumb_fallback:
		label_status.text = "缓存无法解码"
	else:
		label_status.text = "格式不支持预览"


## A device (系统相册) item: the file belongs to the device, so there is nothing
## cloud-side to delete or save here — show it (the ⋮ menu can upload it).
func _show_device_current(a: Dictionary) -> void:
	btn_delete.visible = false
	btn_save.visible = false
	texture_rect.texture = null
	if a.get("is_video", false):
		label_status.text = "视频"
		var poster := DeviceMedia.cached_thumb(a, DEVICE_POSTER_SIZE)
		if poster.get_width() > 0:
			texture_rect.texture = ImageTexture.create_from_image(poster)
			_has_poster = true
		btn_center_play.visible = true
		return
	label_status.text = "加载中…"
	var img := DeviceMedia.get_preview(a)
	if img.get_width() > 0:
		texture_rect.texture = ImageTexture.create_from_image(img)
		label_status.text = ""
	else:
		label_status.text = "无法预览该文件"


# --- Video playback ----------------------------------------------------------

## A tap on ▶ / the picture: play (first tap), pause, resume, or — while playing
## — hide/show the surrounding UI so the video plays full-bleed.
func _on_video_tap() -> void:
	if _video_playing:
		_set_chrome_visible(not _chrome_visible)
		return
	if _video_session:
		_play_pause()
		return
	if _video_preparing:
		_play_when_ready = true
		return
	if _video_broken:
		# The in-app decoder already failed for this asset (or does not exist):
		# go straight to the OS player instead of failing again.
		_play_current_external()
		return
	_start_video_playback()


## Fetches the local copy (cloud video: cache/originals; device video: staged
## under cache/device) and prepares the in-app player for it. The player is left
## paused — _on_inapp_prepared() then starts it, since a tap asked for playback.
func _start_video_playback() -> void:
	var a := _current_asset()
	if a.is_empty():
		return
	var gen := _show_gen
	_play_when_ready = true
	_video_preparing = true
	var path := ""
	if DeviceMedia.is_device(a):
		path = DeviceMedia.local_video_path(a)
	else:
		path = await _ensure_local_video()
	if gen != _show_gen:
		# Swiped away while fetching: the new asset owns the screen now.
		return
	_video_preparing = false
	if path == "":
		_play_when_ready = false
		return
	var abs := ProjectSettings.globalize_path(path)
	if not Lock.start_inapp_video(abs, VIDEO_FRAME_W, VIDEO_FRAME_H):
		# No in-app decoder (desktop/editor): hand the file to the OS player.
		_play_when_ready = false
		_video_broken = true
		label_status.text = ""
		Lock.play_video(abs)
		return
	_video_session = true
	_video_playing = false
	_video_broken = false
	_video_played_once = false
	_video_pos_ms = 0
	_video_duration_ms = -1
	_video_started_ms = Time.get_ticks_msec()
	_strip_waiting = true
	_strip_token += 1
	_strip_cells = _strip_cell_count()
	Lock.request_video_filmstrip(abs, _strip_cells, STRIP_CELL_W, STRIP_CELL_H, _strip_token)
	if not _has_poster:
		_frame_until = Time.get_ticks_msec() + FRAME_SETTLE_MS
	label_status.text = ""
	_refresh_transport()


## The player finished preparing (paused on frame 1): publish the duration and
## start playback when the tap that got us here asked for it.
func _on_inapp_prepared() -> void:
	if not _video_session:
		return
	var dur := Lock.inapp_video_duration_ms()
	if dur > 0:
		_video_duration_ms = dur
	_refresh_transport()
	if _play_when_ready:
		_play_when_ready = false
		_play_pause()


func _play_pause() -> void:
	if not _video_session:
		_on_video_tap()
		return
	if _video_playing:
		if Lock.pause_inapp_video():
			_video_playing = false
			_frame_until = Time.get_ticks_msec() + FRAME_SETTLE_MS
		_refresh_transport()
		return
	if not Lock.is_inapp_video_prepared():
		# Still preparing: play as soon as it is ready.
		_play_when_ready = true
		return
	if Lock.resume_inapp_video():
		_video_playing = true
		_video_played_once = true
		_video_started_ms = Time.get_ticks_msec()
		_stall_check_after = Time.get_ticks_msec() + STALL_TIMEOUT_MS
		var dur := Lock.inapp_video_duration_ms()
		if dur > 0:
			_video_duration_ms = dur
	_refresh_transport()


## Played to the end: back to the idle ▶ affordance, playhead at 0:00.
func _on_video_ended() -> void:
	_video_playing = false
	_video_played_once = false
	_video_pos_ms = 0
	Lock.seek_inapp_video(0)
	_frame_until = Time.get_ticks_msec() + FRAME_SETTLE_MS
	_set_chrome_visible(true)


## Drops the in-app player and continues in the OS player (frozen or failed
## decode, or a file the plugin cannot play).
func _handoff_to_external(text: String) -> void:
	_stop_video()
	_set_chrome_visible(true)
	_video_broken = true
	label_status.text = text
	_refresh_transport()
	_play_current_external()


func _play_current_external() -> void:
	var a := _current_asset()
	if a.is_empty():
		return
	if DeviceMedia.is_device(a):
		_play_device_video_external(a)
	else:
		_start_video_external()


## Desktop/editor fallback for a device video: hand the file to the OS player.
func _play_device_video_external(a: Dictionary) -> void:
	var path := DeviceMedia.local_video_path(a)
	if path == "":
		label_status.text = "无法读取该视频"
		return
	label_status.text = ""
	Lock.play_video(ProjectSettings.globalize_path(path))


## Swipe left/right (touch or mouse drag) to go to the next/previous photo.
## Swipes over buttons are consumed by the buttons themselves and never reach
## here; the image/label fillers are MOUSE_FILTER_IGNORE so gestures starting
## on the photo area land on this control instead.
func _gui_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		if event.pressed:
			_touch_active = true
			_touch_start = event.position
			_touch_time = Time.get_ticks_msec()
		else:
			if _touch_active:
				if _on_tap(event.position):
					pass
				else:
					_handle_swipe_end(event.position)
			_touch_active = false
		accept_event()
	elif event is InputEventScreenDrag:
		if _touch_active:
			accept_event()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_touch_active = true
			_touch_start = event.position
			_touch_time = Time.get_ticks_msec()
		else:
			if _touch_active:
				if not _on_tap(event.position):
					_handle_swipe_end(event.position)
			_touch_active = false
		accept_event()
	elif event is InputEventMouseMotion and _touch_active and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		accept_event()


## A short press that doesn't move becomes a tap: a video plays/pauses (and
## toggles the surrounding UI while playing), an image hides/shows it. Returns
## true when the tap was consumed here, false when it should fall through to a
## swipe-based navigation.
func _on_tap(pos: Vector2) -> bool:
	var dx := pos.x - _touch_start.x
	var dy := pos.y - _touch_start.y
	if abs(dx) >= 24.0 or abs(dy) >= 24.0 or (Time.get_ticks_msec() - _touch_time) >= 400:
		return false
	if _current_asset().is_empty():
		return false
	if _current_is_video():
		_on_video_tap()
	else:
		_set_chrome_visible(not _chrome_visible)
	return true


## Maps a just-released drag to prev/next, ignoring short or vertical swipes.
func _handle_swipe_end(pos: Vector2) -> void:
	var dx := pos.x - _touch_start.x
	var dy := pos.y - _touch_start.y
	if abs(dx) < SWIPE_THRESHOLD or abs(dy) > abs(dx):
		return
	if dx < 0:
		_next()
	else:
		_prev()


func _prev() -> void:
	if Api.viewer_index > 0:
		Api.viewer_index -= 1
		_show_current()


func _next() -> void:
	if Api.viewer_index < Api.viewer_assets.size() - 1:
		Api.viewer_index += 1
		_show_current()

func _delete_current() -> void:
	var a := _current_asset()
	if a.is_empty():
		return
	await asset_menu.delete_assets([a])


# --- Surrounding UI ----------------------------------------------------------

## Hides/shows everything around the picture: top bar, status line, the video
## transport and the action row. Used for full-bleed viewing of an image, and
## for a playing video ("再点一下隐藏/显示周边操作 UI").
func _set_chrome_visible(show: bool) -> void:
	_chrome_visible = show
	top_bar.visible = show
	top_pad.visible = show
	bottom_row.visible = show
	label_status.visible = show
	_refresh_transport()


# --- Seek bar (preview frames) ----------------------------------------------

## Preview-frame cells to request: one per ~120 px of screen, so the strip
## covers the width without an oversized payload.
func _strip_cell_count() -> int:
	return clampi(int(round(get_viewport_rect().size.x / STRIP_CELL_PX)), STRIP_MIN_CELLS, STRIP_MAX_CELLS)


## Drag (or click) anywhere on the strip to seek: the picture/readout follow the
## finger, the player is seeked once on release.
func _on_seek_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch or (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT):
		if event.pressed:
			_seeking = true
			_seek_preview(event.position.x)
		else:
			_seeking = false
			_commit_seek()
		seek_wrap.accept_event()
	elif (event is InputEventScreenDrag) or (event is InputEventMouseMotion and _seeking):
		if _seeking:
			_seek_preview(event.position.x)
		seek_wrap.accept_event()


func _seek_preview(x: float) -> void:
	if _video_duration_ms <= 0:
		return
	var w := maxf(seek_wrap.size.x, 1.0)
	_video_pos_ms = int(round(clampf(x / w, 0.0, 1.0) * float(_video_duration_ms)))
	_refresh_transport()


func _commit_seek() -> void:
	if not _video_session:
		return
	Lock.seek_inapp_video(_video_pos_ms)
	_stall_check_after = Time.get_ticks_msec() + STALL_TIMEOUT_MS
	if not _video_playing:
		# Paused: paint the frame at the new position.
		_frame_until = Time.get_ticks_msec() + FRAME_SETTLE_MS
	_refresh_transport()


## The transport under the picture: 播放至时间|总时间 (分:秒) and the strip. Hidden
## for images, while nothing is known about the video, and in full-bleed mode.
func _refresh_transport() -> void:
	if not _current_is_video():
		video_bar.visible = false
		btn_center_play.visible = false
		btn_playpause.visible = false
		return
	var has_time := _video_duration_ms > 0
	video_bar.visible = has_time and _chrome_visible
	btn_center_play.visible = not _video_playing and not _video_played_once
	if not has_time:
		return
	var readout := "%s|%s" % [_clock(_video_pos_ms), _clock(_video_duration_ms)]
	if label_time.text != readout:
		label_time.text = readout
	btn_playpause.visible = _video_session
	btn_playpause.text = "❚❚" if _video_playing else "▶"
	_place_playhead()


func _place_playhead() -> void:
	var x := seek_wrap.size.x * _play_ratio()
	playhead.offset_left = x - 1.0
	playhead.offset_right = x + 1.0
	dim_right.offset_left = x
	dim_right.offset_right = 0.0


func _play_ratio() -> float:
	if _video_duration_ms <= 0:
		return 0.0
	return clampf(float(_video_pos_ms) / float(_video_duration_ms), 0.0, 1.0)


## 分:秒 — total minutes, so an hour-long clip reads 62:30. "--:--" when the
## duration is unknown.
func _clock(ms: int) -> String:
	if ms < 0:
		return "--:--"
	var total := ms / 1000
	return "%d:%02d" % [total / 60, total % 60]


## The asset on screen; {} when the viewer holds no (navigable) entry.
func _current_asset() -> Dictionary:
	if Api.viewer_assets.is_empty() or Api.viewer_index < 0 or Api.viewer_index >= Api.viewer_assets.size():
		return {}
	return Api.viewer_assets[Api.viewer_index]


func _current_is_video() -> bool:
	var a := _current_asset()
	if a.is_empty():
		return false
	if DeviceMedia.is_device(a):
		return bool(a.get("is_video", false))
	return str(a.get("media_type", "image")) == "video"


# --- Asset menu (⋮) ----------------------------------------------------------

func _show_asset_menu() -> void:
	var a := _current_asset()
	if a.is_empty():
		return
	asset_menu.popup([a])


## Album a 移动到 detaches the photo from: the album the viewer was opened from.
## In the 全部 (aggregate trunk) view there is no single source, so the move
## de-orphans the photo from the 散照 bucket (0 when there is none).
func _move_source_album() -> int:
	if Api.current_album_id == Api.current_trunk_id:
		return Api.scatter_album_id
	return Api.current_album_id


## 收藏/复制/改名 leave the photo where it is; 删除 and 移动到 (outside the 全部
## aggregation) drop it from the album being viewed, so the viewer moves on.
func _on_menu_changed(ids: Array, op: String) -> void:
	if op == "device":
		# 导入/删除/移动 都可能把当前这张从本机带走；别的云端操作不动画面。
		_drop_missing_device_items()
		return
	if op != "delete" and op != "move":
		_show_current()
		return
	if op == "move" and Api.current_album_id == Api.current_trunk_id:
		_show_current()
		return
	var keep: Array = []
	for a in Api.viewer_assets:
		if not ids.has(int(a.get("id", 0))):
			keep.append(a)
	Api.viewer_assets = keep
	if Api.viewer_assets.is_empty():
		_go_back()
		return
	Api.viewer_index = clampi(Api.viewer_index, 0, Api.viewer_assets.size() - 1)
	_show_current()


## Drops device items the device no longer lists (a 删除/移动 from the menu can
## take the photo being viewed with it) and moves the viewer on.
func _drop_missing_device_items() -> void:
	var live: Dictionary = {}
	for it in DeviceMedia.items():
		live[DeviceMedia.key_of(it)] = true
	var keep: Array = []
	for a in Api.viewer_assets:
		if DeviceMedia.is_device(a) and not live.has(DeviceMedia.key_of(a)):
			continue
		keep.append(a)
	if keep.size() == Api.viewer_assets.size():
		_show_current()
		return
	Api.viewer_assets = keep
	if Api.viewer_assets.is_empty():
		_go_back()
		return
	Api.viewer_index = clampi(Api.viewer_index, 0, Api.viewer_assets.size() - 1)
	_show_current()


func _on_menu_notice(text: String) -> void:
	label_status.text = text


## The mp4 is served by the cloud behind a Bearer token, so it is downloaded to
## the local original cache first (reusing a cached copy when present) and then
## handed to playback: the Android in-app MediaPlayer via the plugin (or the OS
## player on desktop/editor). Returns the absolute local path, "" on failure.
func _ensure_local_video() -> String:
	var a: Dictionary = Api.viewer_assets[Api.viewer_index]
	var asset_id := int(a.get("id", 0))
	if asset_id <= 0:
		label_status.text = "本地视频尚未上传云端，无法播放"
		return ""
	var name := str(a.get("original_name", ""))
	var ext := str(a.get("ext", ""))
	if ext == "":
		ext = name.get_extension().to_lower()
	if ext == "":
		ext = "mp4"
	var body := Cache.read_original(asset_id, name, ext)
	if body.is_empty():
		label_status.text = "正在获取视频…"
		var r: Dictionary = await Api.fetch_original(asset_id)
		if r.has("error"):
			label_status.text = "离线且视频未缓存，无法播放"
			return ""
		body = r["body"]
		await Cache.save_original_bg(asset_id, name, body, ext)
	if body.is_empty():
		label_status.text = "播放失败：无数据"
		return ""
	var path := Cache.original_path(asset_id, name, ext)
	if not FileAccess.file_exists(path):
		label_status.text = "播放失败：本地文件缺失"
		return ""
	return path


func _start_video_external() -> void:
	var path := await _ensure_local_video()
	if path == "":
		return
	label_status.text = ""
	Lock.play_video(ProjectSettings.globalize_path(path))


## The plugin reported an error (a finished clip sets inapp_video_completed
## instead): drop the session and, when it died right after starting — a failed
## decode rather than a short clip — let the OS player take over.
func _on_inapp_closed() -> void:
	if not _video_session:
		return
	var died_early := _video_started_ms > 0 and Time.get_ticks_msec() - _video_started_ms < EARLY_DEATH_MS
	_stop_video()
	_set_chrome_visible(true)
	_video_broken = true
	if died_early:
		label_status.text = "内置播放失败，改用系统播放器"
		_play_current_external()
	else:
		label_status.text = "视频"
	_refresh_transport()


## Tears the in-app session down and resets every per-asset playback field.
func _stop_video() -> void:
	if _video_session:
		Lock.stop_inapp_video()
	_video_session = false
	_video_playing = false
	_video_preparing = false
	_video_broken = false
	_video_played_once = false
	_video_pos_ms = 0
	_video_duration_ms = -1
	_video_started_ms = 0
	_stall_check_after = 0
	_play_when_ready = false
	_seeking = false
	_strip_waiting = false
	# Invalidate a filmstrip still building: it must not land on the next asset.
	_strip_token += 1
	_frame_accum = 0.0
	_frame_until = 0
	_has_poster = false
	if filmstrip != null:
		filmstrip.texture = null
	_refresh_transport()


## Collects the preview-frame strip once the plugin finished building it; the
## token keeps a build for a previously viewed video from being shown.
func _take_strip() -> void:
	var bytes := Lock.take_video_filmstrip(_strip_token)
	if bytes.is_empty():
		return
	_strip_waiting = false
	var img := Image.create_from_data(_strip_cells * STRIP_CELL_W, STRIP_CELL_H, false, Image.FORMAT_RGBA8, bytes)
	if img != null:
		filmstrip.texture = ImageTexture.create_from_image(img)


## Polls the plugin's latest decoded frame and paints it into texture_rect while
## playing (or briefly after a start/pause/seek, to refresh the still). Also
## watches the plugin's surface-update age: if no new frame has arrived for
## STALL_TIMEOUT_MS while playing, the decode/readback has frozen (seen without
## any MediaPlayer error) — hand over to the OS player instead of a dead still.
func _process(delta: float) -> void:
	var poll_frames := false
	if _video_session:
		if _strip_waiting:
			_take_strip()
		if _video_playing:
			if Lock.inapp_video_completed():
				_on_video_ended()
				return
			if Time.get_ticks_msec() > _stall_check_after and Lock.inapp_frame_age_ms() > STALL_TIMEOUT_MS:
				_handoff_to_external("内置播放无画面，改用系统播放器")
				return
			if not _seeking:
				_video_pos_ms = Lock.inapp_video_position_ms()
			_refresh_transport()
			poll_frames = true
		elif Time.get_ticks_msec() < _frame_until:
			poll_frames = true
	if not poll_frames:
		return
	_frame_accum += delta
	if _frame_accum < FRAME_POLL_MS:
		return
	_frame_accum = 0.0
	var body := Lock.grab_inapp_frame()
	if body.is_empty():
		return
	var img := Image.create_from_data(VIDEO_FRAME_W, VIDEO_FRAME_H, false, Image.FORMAT_RGBA8, body)
	if img != null:
		texture_rect.texture = ImageTexture.create_from_image(img)


## Saves the current asset's full-res bytes into the device gallery. The export
## itself lives in the asset menu, which the grid's 复制到/移动到 reuse — one
## implementation, one set of notices, and it works on desktop too.
func _save_to_album() -> void:
	var a := _current_asset()
	if a.is_empty() or int(a.get("id", 0)) <= 0:
		return
	btn_save.disabled = true
	await asset_menu.export_to_device([a], false)
	btn_save.disabled = false


func _go_back() -> void:
	_stop_video()
	get_tree().change_scene_to_file("res://scenes/album_view.tscn")


func _exit_tree() -> void:
	_stop_video()
