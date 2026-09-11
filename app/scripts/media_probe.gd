extends RefCounted
## Reads technical metadata straight from a local file, with no decoder, no
## plugin and no network:
##   - sha256_file(): content hash, for assets the server has no hash for.
##   - probe(): video duration + pixel size, by walking the container structure:
##       MP4/MOV (ISO BMFF): moov > mvhd (duration / timescale)
##                           moov > trak > tkhd (width / height, 16.16 fixed)
##       Matroska/WebM (EBML): Segment > Info (TimecodeScale / Duration)
##                           Segment > Tracks > TrackEntry > Video > PixelWidth/Height
## Anything else (or a damaged file) returns zeros, which callers show as 未知.

const HASH_CHUNK := 1024 * 1024
# moov is read whole (it sits at the front or the end of an MP4); cap it so a
# damaged size field cannot pull a multi-GB read into memory.
const MOOV_READ_LIMIT := 32 * 1024 * 1024
# EBML is walked sequentially from the start of the file; the metadata we need
# (Info + Tracks) precedes the media Clusters, so a small budget always suffices.
const EBML_READ_BUDGET := 16 * 1024 * 1024
# Master elements nest, and a crafted file can nest them without end: the byte
# budget alone would allow millions of levels of recursion before it runs out.
const EBML_MAX_DEPTH := 16

# EBML element ids, marker bits included (the values _read_vint returns).
const EBML_SEGMENT := 0x18538067
const EBML_INFO := 0x1549A966
const EBML_TRACKS := 0x1654AE6B
const EBML_TRACK_ENTRY := 0xAE
const EBML_VIDEO := 0xE0
const EBML_TIMECODE_SCALE := 0x2AD7B1
const EBML_DURATION := 0x4489
const EBML_PIXEL_WIDTH := 0xB0
const EBML_PIXEL_HEIGHT := 0xBA
const EBML_CLUSTER := 0x1F43B675


## SHA-256 of a file, "" when it cannot be opened. Streamed in 1 MiB chunks.
static func sha256_file(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	while not f.eof_reached():
		ctx.update(f.get_buffer(HASH_CHUNK))
	var digest := ctx.finish()
	f.close()
	return digest.hex_encode()


## {"duration_ms": int, "width": int, "height": int}; 0 means unknown.
static func probe(path: String) -> Dictionary:
	var out := {"duration_ms": 0, "width": 0, "height": 0}
	match path.get_extension().to_lower():
		"mp4", "mov", "m4v", "3gp":
			_probe_mp4(path, out)
		"mkv", "webm":
			_probe_matroska(path, out)
	return out


# --- MP4 / MOV ---------------------------------------------------------------

static func _probe_mp4(path: String, out: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	var moov := _read_moov(f)
	f.close()
	if moov.is_empty():
		return
	var i := 0
	while i + 8 <= moov.size():
		var box := _box_at(moov, i, moov.size())
		if box.is_empty():
			return
		match box["kind"]:
			"mvhd":
				var ms := _mvhd_ms(moov, box["body"], box["end"])
				if ms > 0:
					out["duration_ms"] = ms
			"trak":
				if int(out["width"]) <= 0:
					var dim := _trak_dims(moov, box["body"], box["end"])
					if dim.x > 0:
						out["width"] = dim.x
						out["height"] = dim.y
		i = box["next"]


## Returns the moov box payload, or an empty buffer when the file has none.
## Top-level boxes are walked by seeking, so a trailing moov (the common
## non-faststart layout) costs a couple of seeks and one bounded read.
static func _read_moov(f: FileAccess) -> PackedByteArray:
	var fsize := f.get_length()
	var pos := 0
	while pos + 8 <= fsize:
		f.seek(pos)
		if f.get_position() != pos:
			return PackedByteArray()
		var hdr := f.get_buffer(8)
		if hdr.size() < 8:
			return PackedByteArray()
		var size := _be32(hdr, 0)
		var body := pos + 8
		if size == 1:
			var ext := f.get_buffer(8)
			if ext.size() < 8:
				return PackedByteArray()
			size = _be64(ext, 0)
			body = pos + 16
		elif size == 0:
			size = fsize - pos
		if size < body - pos or body > fsize:
			return PackedByteArray()
		if hdr.slice(4, 8).get_string_from_ascii() == "moov":
			f.seek(body)
			if f.get_position() != body:
				return PackedByteArray()
			return f.get_buffer(mini(size - (body - pos), MOOV_READ_LIMIT))
		pos += size
	return PackedByteArray()


## Reads the box header at `off`: {kind, body, end, next}, {} when invalid.
## `end` clamps the payload; `next` is where the following box starts.
static func _box_at(buf: PackedByteArray, off: int, end: int) -> Dictionary:
	if off + 8 > end:
		return {}
	var size := _be32(buf, off)
	var body := off + 8
	if size == 1:
		if off + 16 > end:
			return {}
		size = _be64(buf, off + 8)
		body = off + 16
	elif size == 0:
		size = end - off
	if size < body - off:
		return {}
	return {
		"kind": buf.slice(off + 4, off + 8).get_string_from_ascii(),
		"body": body,
		"end": mini(off + size, end),
		"next": off + size,
	}


## First video track's stored pixel size (audio tracks carry 0).
static func _trak_dims(buf: PackedByteArray, start: int, end: int) -> Vector2i:
	var i := start
	while i + 8 <= end:
		var box := _box_at(buf, i, end)
		if box.is_empty():
			return Vector2i.ZERO
		if box["kind"] == "tkhd":
			return _tkhd_dims(buf, box["body"], box["end"])
		i = box["next"]
	return Vector2i.ZERO


static func _mvhd_ms(buf: PackedByteArray, body: int, end: int) -> int:
	if body + 4 > end:
		return 0
	var timescale := 0
	var duration := 0
	if buf[body] == 1:
		if body + 32 > end:
			return 0
		timescale = _be32(buf, body + 20)
		duration = _be64(buf, body + 24)
	else:
		if body + 20 > end:
			return 0
		timescale = _be32(buf, body + 12)
		duration = _be32(buf, body + 16)
	if timescale <= 0:
		return 0
	return int(round(float(duration) * 1000.0 / float(timescale)))


static func _tkhd_dims(buf: PackedByteArray, body: int, end: int) -> Vector2i:
	if body + 4 > end:
		return Vector2i.ZERO
	# width/height are the last two 16.16 fixed-point fields of tkhd.
	var off := body + (88 if buf[body] == 1 else 76)
	if off + 8 > end:
		return Vector2i.ZERO
	return Vector2i(_be32(buf, off) >> 16, _be32(buf, off + 4) >> 16)


# --- Matroska / WebM ---------------------------------------------------------

static func _probe_matroska(path: String, out: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return
	# Duration is in TimecodeScale units (nanoseconds, default 1 ms).
	var state := {"scale": 1000000, "duration": 0.0, "width": 0, "height": 0}
	_walk_ebml(f, f.get_length(), state, [EBML_READ_BUDGET])
	f.close()
	var ms := int(round(state["duration"] * float(state["scale"]) / 1000000.0))
	if ms > 0:
		out["duration_ms"] = ms
	out["width"] = int(state["width"])
	out["height"] = int(state["height"])


## Walks EBML elements within [position, end], descending into the master
## elements that carry our targets and skipping everything else by size. `depth`
## bounds that descent: nesting is attacker-controlled, so it must not be able to
## recurse until the stack runs out.
static func _walk_ebml(f: FileAccess, end: int, state: Dictionary, budget: Array, depth: int = 0) -> void:
	if depth > EBML_MAX_DEPTH:
		return
	while budget[0] > 0 and f.get_position() < end and not f.eof_reached():
		var id_r := _read_vint(f)
		if id_r.is_empty():
			return
		var size_r := _read_vint(f)
		if size_r.is_empty():
			return
		budget[0] -= int(id_r[1]) + int(size_r[1])
		var id: int = id_r[0]
		var mask := (1 << (7 * int(size_r[1]))) - 1
		var size: int = size_r[0] & mask
		var body := f.get_position()
		var body_end := end if size == mask else mini(body + size, end)
		match id:
			EBML_SEGMENT, EBML_INFO, EBML_TRACKS, EBML_TRACK_ENTRY, EBML_VIDEO:
				_walk_ebml(f, body_end, state, budget, depth + 1)
				if size == mask:
					# Unknown-length master: it owns the rest of the parent.
					return
			EBML_TIMECODE_SCALE:
				state["scale"] = _read_uint(f, body_end - body)
			EBML_DURATION:
				var d := _read_float(f, body_end - body)
				if d > 0.0:
					state["duration"] = d
			EBML_PIXEL_WIDTH:
				state["width"] = _read_uint(f, body_end - body)
			EBML_PIXEL_HEIGHT:
				state["height"] = _read_uint(f, body_end - body)
			EBML_CLUSTER:
				# Media data starts here: Info and Tracks are already behind us.
				return
		if state["duration"] > 0.0 and int(state["width"]) > 0 and int(state["height"]) > 0:
			return
		if f.get_position() != body_end:
			f.seek(body_end)
			if f.get_position() != body_end:
				return


## Reads one EBML variable-length integer as [value, byte_length]; the value
## keeps its marker bit (element ids are compared that way). [] on EOF/invalid.
static func _read_vint(f: FileAccess) -> Array:
	if f.eof_reached():
		return []
	var first := f.get_8()
	var length := 1
	var mask := 0x80
	while length <= 8 and (first & mask) == 0:
		mask >>= 1
		length += 1
	if length > 8:
		return []
	var value := first
	for i in range(length - 1):
		if f.eof_reached():
			return []
		value = (value << 8) | f.get_8()
	return [value, length]


static func _read_uint(f: FileAccess, n: int) -> int:
	if n <= 0 or n > 8:
		return 0
	var buf := f.get_buffer(n)
	if buf.size() < n:
		return 0
	var v := 0
	for i in n:
		v = (v << 8) | buf[i]
	return v


static func _read_float(f: FileAccess, n: int) -> float:
	if n != 4 and n != 8:
		return 0.0
	var buf := f.get_buffer(n)
	if buf.size() < n:
		return 0.0
	buf.reverse()  # container floats are big-endian, decoders are little-endian
	return buf.decode_double(0) if n == 8 else buf.decode_float(0)


# --- big-endian primitives ---------------------------------------------------

static func _be32(b: PackedByteArray, o: int) -> int:
	return (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]


static func _be64(b: PackedByteArray, o: int) -> int:
	return (_be32(b, o) << 32) | _be32(b, o + 4)
