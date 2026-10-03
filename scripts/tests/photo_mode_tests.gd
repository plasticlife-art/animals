extends RefCounted

## Photo mode: the GIF it writes, frame by frame, and what it hides and brings back.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const GifEncoderScript := preload("res://scripts/ui/gif_encoder.gd")
const AnimalNamesMix := preload("res://scripts/story/animal_names.gd")
const GifRecorderScript := preload("res://scripts/ui/gif_recorder.gd")
const PhotoModeScript := preload("res://scripts/ui/photo_mode.gd")


class RendererStub:
	extends RefCounted

	var show_selection_ring: bool = true

	func queue_redraw() -> void:
		pass


class WorldViewStub:
	extends RefCounted

	var input_enabled: bool = true

	func set_input_enabled(value: bool) -> void:
		input_enabled = value


func run(a) -> void:
	_test_gif_file_structure(a)
	_test_lzw_round_trip(a)
	_test_recorder_writes_a_gif(a)
	_test_photo_mode_hides_and_restores(a)


## A GIF a decoder can read: the header, the canvas, the loop, a delay per frame, and frames whose
## coded pixels come back as the palette indices they were.
func _test_gif_file_structure(a) -> void:
	var encoder = GifEncoderScript.new(8, 4)
	var frame := PackedByteArray()
	for y in range(4):
		for x in range(8):
			frame.append_array(PackedByteArray([255, 0, 0] if x < 4 else ([0, 0, 255] if y < 2 else [20, 200, 40])))
	encoder.add_frame(frame, 7)
	encoder.add_frame(frame, 9)
	var bytes: PackedByteArray = encoder.finish()
	a.equal(bytes.slice(0, 6).get_string_from_ascii(), "GIF89a", "the header")
	a.equal([bytes[6] | (bytes[7] << 8), bytes[8] | (bytes[9] << 8)], [8, 4], "the canvas")
	a.equal(bytes[bytes.size() - 1], 0x3B, "the trailer")
	a.is_true(bytes.hex_encode().contains("NETSCAPE2.0".to_ascii_buffer().hex_encode()), "it loops")
	var parsed := _parse_gif(bytes)
	a.equal(parsed["delays"], [7, 9], "a delay per frame")
	a.equal(parsed["frames"].size(), 2, "two frames")
	var first: PackedByteArray = _lzw_decode(parsed["frames"][0], 8)
	a.equal(first, encoder.indices(frame), "the coded pixels decode to their palette indices")
	var palette: PackedByteArray = encoder.palette()
	var red: int = first[0]
	a.is_true(absi(palette[red * 3] - 255) < 12 and palette[red * 3 + 1] < 12, "and the palette holds the colour")


## LZW codes come back the same through code-size growth and a full table's reset.
func _test_lzw_round_trip(a) -> void:
	var data := PackedByteArray()
	for index in range(30000):
		data.append(AnimalNamesMix.mix(index) % 37 if index % 7 else index % 256)
	var coded: PackedByteArray = GifEncoderScript.lzw(data, 8)
	a.equal(_lzw_decode(coded, 8), data, "a long varied stream round-trips")
	a.equal(_lzw_decode(GifEncoderScript.lzw(PackedByteArray([5]), 8), 8), PackedByteArray([5]), "a single pixel")


## Frames fed in as they were taken become a film whose delays are how long each really lasted,
## the last one a frame's length; the file is written off the main thread and reported by poll.
func _test_recorder_writes_a_gif(a) -> void:
	var path := ProjectSettings.globalize_path("user://test_recording.gif")
	DirAccess.remove_absolute(path)
	var recorder = GifRecorderScript.new()
	var reported: Array = []
	recorder.finished.connect(func(done_path: String, ok: bool) -> void: reported.append([done_path, ok]))
	recorder.start(path, Vector2i(110, 70))
	a.equal(recorder.frame_size.x, GifRecorderScript.WIDTH, "scaled to the film's width")
	var frame := PackedByteArray()
	frame.resize(recorder.frame_size.x * recorder.frame_size.y * 3)
	frame.fill(90)
	for at in [1000, 1070, 1130]:
		recorder.feed(frame, at)
	recorder.stop(1200)
	recorder.cancel()
	a.is_true(recorder.poll() and reported == [[path, true]], "written and reported once: %s" % str(reported))
	recorder.poll()
	a.equal(reported.size(), 1, "and only once")
	var bytes := FileAccess.get_file_as_bytes(path)
	a.equal(_parse_gif(bytes)["delays"], [7, 6, 7], "each frame as long as it lasted")
	DirAccess.remove_absolute(path)


## Photo mode hides what it was given and the selection ring, and gives back exactly what was
## shown before.
func _test_photo_mode_hides_and_restores(a) -> void:
	var photo = PhotoModeScript.new()
	var hud := Node2D.new()
	var overlay := Node2D.new()
	var labels := Node2D.new()
	labels.visible = false
	var renderer := RendererStub.new()
	var view := WorldViewStub.new()
	photo.bind(null, [hud, overlay, labels], renderer, view)
	photo.enter()
	a.is_true(photo.active and photo.visible, "on")
	a.is_true(not hud.visible and not overlay.visible and not labels.visible, "the interface hidden")
	a.is_true(not renderer.show_selection_ring and not view.input_enabled, "the ring off, clicks off")
	photo.leave()
	a.is_true(not photo.active and not photo.visible, "off")
	a.is_true(hud.visible and overlay.visible and not labels.visible, "what was shown comes back, and only that")
	a.is_true(renderer.show_selection_ring and view.input_enabled, "the ring and clicks back")
	var folder := ProjectSettings.globalize_path("user://photos_test")
	DirAccess.make_dir_recursive_absolute(folder)
	var named: String = PhotoModeScript.next_path("png", folder)
	a.is_true(named.begins_with(folder + "/eoe-") and named.ends_with(".png"), "a dated file name: %s" % named)
	for node in [hud, overlay, labels]:
		node.free()
	photo.free()


## `{delays: [...], frames: [lzw data, ...]}` walked off a GIF's blocks.
static func _parse_gif(bytes: PackedByteArray) -> Dictionary:
	var at := 13
	if bytes[10] & 0x80:
		at += 3 * (1 << ((bytes[10] & 7) + 1))
	var delays: Array = []
	var frames: Array = []
	while at < bytes.size():
		var tag: int = bytes[at]
		if tag == 0x3B:
			break
		if tag == 0x21:
			var label: int = bytes[at + 1]
			at += 2
			if label == 0xF9:
				delays.append(bytes[at + 2] | (bytes[at + 3] << 8))
			while bytes[at] != 0:
				at += bytes[at] + 1
			at += 1
		elif tag == 0x2C:
			var packed: int = bytes[at + 9]
			at += 10
			if packed & 0x80:
				at += 3 * (1 << ((packed & 7) + 1))
			at += 1
			var data := PackedByteArray()
			while bytes[at] != 0:
				data.append_array(bytes.slice(at + 1, at + 1 + bytes[at]))
				at += bytes[at] + 1
			at += 1
			frames.append(data)
		else:
			break
	return {"delays": delays, "frames": frames}


## A plain GIF LZW decoder, the way readers do it.
static func _lzw_decode(stream: PackedByteArray, min_code_size: int) -> PackedByteArray:
	var clear := 1 << min_code_size
	var end := clear + 1
	var code_size := min_code_size + 1
	var table: Array = []
	var out := PackedByteArray()
	var previous := PackedByteArray()
	var has_previous := false
	var bit := 0
	var total_bits := stream.size() * 8
	while bit + code_size <= total_bits:
		var code := 0
		for offset in range(code_size):
			var at := bit + offset
			if stream[at >> 3] & (1 << (at & 7)):
				code |= 1 << offset
		bit += code_size
		if code == clear:
			table.clear()
			for value in range(clear):
				table.append(PackedByteArray([value]))
			table.append(PackedByteArray())
			table.append(PackedByteArray())
			code_size = min_code_size + 1
			has_previous = false
			continue
		if code == end:
			break
		var entry: PackedByteArray
		if code < table.size():
			entry = table[code]
		elif code == table.size() and has_previous:
			entry = previous.duplicate()
			entry.append(previous[0])
		else:
			break
		out.append_array(entry)
		if has_previous:
			var grown := previous.duplicate()
			grown.append(entry[0])
			table.append(grown)
			if table.size() == (1 << code_size) and code_size < 12:
				code_size += 1
		previous = entry
		has_previous = true
	return out
