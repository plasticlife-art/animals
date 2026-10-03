class_name GifEncoder
extends RefCounted

## An animated GIF built frame by frame in plain GDScript, for photo mode: Godot writes PNG and
## WebP but no GIF, and a GIF is what a forum, a chat or a store page takes.
##
## One palette for the whole film, from its first frame: a median cut of its 15-bit colour
## histogram - the box of colours with the most spread split at its weighted median, again and
## again - plus a coarse lattice of the colour cube, so a colour the first frame lacked (a burst
## of dust, a sparkle) still lands near itself. Each pixel's colour is looked up once
## per 15-bit value and remembered. Frames are LZW-coded as they come (variable code size, a
## clear code when the table fills), and the film loops for ever (NETSCAPE block). Delays are
## in hundredths of a second, as GIF counts them.

const MAX_CODE := 4095
## Palette entries kept for the lattice; the rest go to the first frame's median cut.
const LATTICE := [[0, 128, 255], [0, 128, 255], [0, 128, 255]]

var width: int = 0
var height: int = 0
var frames: int = 0
var _bytes := PackedByteArray()
var _palette := PackedByteArray()
var _lut := PackedInt32Array()


func _init(frame_width: int, frame_height: int) -> void:
	width = frame_width
	height = frame_height
	_bytes.append_array("GIF89a".to_ascii_buffer())
	_append_u16(width)
	_append_u16(height)
	# A global colour table of 256 entries follows (flag, 8 bits of colour, size 2^8).
	_bytes.append_array(PackedByteArray([0xF7, 0, 0]))


## A frame of `width` x `height` RGB8 pixels (`Image.get_data()` of an RGB8 image), shown for
## `delay_cs` hundredths of a second.
func add_frame(rgb: PackedByteArray, delay_cs: int) -> void:
	if rgb.size() < width * height * 3:
		push_error("GifEncoder: a frame of %d bytes, %d wanted" % [rgb.size(), width * height * 3])
		return
	if frames == 0:
		_build_palette(rgb)
		_bytes.append_array(_palette)
		_bytes.append_array(PackedByteArray([0x21, 0xFF, 0x0B]))
		_bytes.append_array("NETSCAPE2.0".to_ascii_buffer())
		_bytes.append_array(PackedByteArray([0x03, 0x01, 0x00, 0x00, 0x00]))
	# Graphic control: no disposal, the delay, no transparency.
	_bytes.append_array(PackedByteArray([0x21, 0xF9, 0x04, 0x00]))
	_append_u16(clampi(delay_cs, 2, 65535))
	_bytes.append_array(PackedByteArray([0x00, 0x00]))
	# The image: whole canvas, no local table, not interlaced.
	_bytes.append(0x2C)
	_append_u16(0)
	_append_u16(0)
	_append_u16(width)
	_append_u16(height)
	_bytes.append(0x00)
	_bytes.append(8)
	_append_blocks(lzw(indices(rgb), 8))
	frames += 1


## The whole file, trailer and all.
func finish() -> PackedByteArray:
	var done := _bytes.duplicate()
	done.append(0x3B)
	return done


## Palette indices for each pixel, from the remembered nearest colours.
func indices(rgb: PackedByteArray) -> PackedByteArray:
	var count := width * height
	var out := PackedByteArray()
	out.resize(count)
	var lut := _lut
	var source := 0
	for index in range(count):
		var key: int = ((rgb[source] >> 3) << 10) | ((rgb[source + 1] >> 3) << 5) | (rgb[source + 2] >> 3)
		var found: int = lut[key]
		if found < 0:
			found = _nearest(key)
			lut[key] = found
		out[index] = found
		source += 3
	return out


## The palette as 768 bytes of RGB.
func palette() -> PackedByteArray:
	return _palette


## GIF's LZW: codes of growing width, least significant bit first, a clear code first and
## whenever the table fills, an end code last.
static func lzw(data: PackedByteArray, min_code_size: int) -> PackedByteArray:
	var clear := 1 << min_code_size
	var end := clear + 1
	var out := PackedByteArray()
	var bit_buffer := 0
	var bit_count := 0
	var code_size := min_code_size + 1
	var next_code := end + 1
	var table := {}
	# Emit the clear code.
	bit_buffer |= clear << bit_count
	bit_count += code_size
	if data.is_empty():
		bit_buffer |= end << bit_count
		bit_count += code_size
		while bit_count > 0:
			out.append(bit_buffer & 0xFF)
			bit_buffer >>= 8
			bit_count -= 8
		return out
	var prefix: int = data[0]
	for position in range(1, data.size()):
		var symbol: int = data[position]
		var key := (prefix << 8) | symbol
		var known = table.get(key)
		if known != null:
			prefix = known
			continue
		bit_buffer |= prefix << bit_count
		bit_count += code_size
		while bit_count >= 8:
			out.append(bit_buffer & 0xFF)
			bit_buffer >>= 8
			bit_count -= 8
		if next_code <= MAX_CODE:
			table[key] = next_code
			next_code += 1
			if next_code > (1 << code_size) and code_size < 12:
				code_size += 1
		else:
			bit_buffer |= clear << bit_count
			bit_count += code_size
			while bit_count >= 8:
				out.append(bit_buffer & 0xFF)
				bit_buffer >>= 8
				bit_count -= 8
			table.clear()
			code_size = min_code_size + 1
			next_code = end + 1
		prefix = symbol
	bit_buffer |= prefix << bit_count
	bit_count += code_size
	while bit_count >= 8:
		out.append(bit_buffer & 0xFF)
		bit_buffer >>= 8
		bit_count -= 8
	# The decoder adds an entry for the last code too, and may widen before the end code.
	if next_code >= (1 << code_size) and code_size < 12:
		code_size += 1
	bit_buffer |= end << bit_count
	bit_count += code_size
	while bit_count > 0:
		out.append(bit_buffer & 0xFF)
		bit_buffer >>= 8
		bit_count -= 8
	return out


## The frame's colours cut into boxes, each box's weighted mean an entry, and the lattice.
func _build_palette(rgb: PackedByteArray) -> void:
	var counts := PackedInt32Array()
	counts.resize(32768)
	for source in range(0, width * height * 3, 3):
		counts[((rgb[source] >> 3) << 10) | ((rgb[source + 1] >> 3) << 5) | (rgb[source + 2] >> 3)] += 1
	var present: Array = []
	for key in range(32768):
		if counts[key] > 0:
			present.append(key)
	var lattice: Array = []
	for r in LATTICE[0]:
		for g in LATTICE[1]:
			for b in LATTICE[2]:
				lattice.append([r, g, b])
	var boxes: Array = [present]
	var wanted := 256 - lattice.size()
	while boxes.size() < wanted:
		# Split the box whose colours spread furthest, weighted by how many pixels it holds.
		var widest := -1
		var widest_score := 0.0
		var widest_axis := 0
		for index in range(boxes.size()):
			var box: Array = boxes[index]
			if box.size() < 2:
				continue
			var spread := _spread(box)
			var weight := 0
			for key in box:
				weight += counts[key]
			var score := float(spread[0]) * sqrt(float(weight))
			if score > widest_score:
				widest_score = score
				widest = index
				widest_axis = int(spread[1])
		if widest < 0:
			break
		var shift: int = [10, 5, 0][widest_axis]
		var box: Array = boxes[widest]
		box.sort_custom(func(a, b): return ((a >> shift) & 31) < ((b >> shift) & 31) or (((a >> shift) & 31) == ((b >> shift) & 31) and a < b))
		var total := 0
		for key in box:
			total += counts[key]
		var running := 0
		var cut := 1
		for index in range(box.size() - 1):
			running += counts[box[index]]
			if running * 2 >= total:
				cut = index + 1
				break
			cut = index + 1
		boxes[widest] = box.slice(0, cut)
		boxes.append(box.slice(cut))
	_palette = PackedByteArray()
	for box in boxes:
		var sums := [0, 0, 0]
		var weight := 0
		for key in box:
			var n: int = counts[key]
			sums[0] += (((key >> 10) & 31) * 8 + 4) * n
			sums[1] += (((key >> 5) & 31) * 8 + 4) * n
			sums[2] += ((key & 31) * 8 + 4) * n
			weight += n
		for channel in range(3):
			_palette.append(clampi(int(round(float(sums[channel]) / float(maxi(1, weight)))), 0, 255))
	for colour in lattice:
		_palette.append_array(PackedByteArray(colour))
	while _palette.size() < 768:
		_palette.append(0)
	_lut = PackedInt32Array()
	_lut.resize(32768)
	_lut.fill(-1)


## How far a box of 15-bit colours spreads along its widest channel: `[range, axis]`.
static func _spread(box: Array) -> Array:
	var low := [31, 31, 31]
	var high := [0, 0, 0]
	for key in box:
		var channels := [(key >> 10) & 31, (key >> 5) & 31, key & 31]
		for axis in range(3):
			low[axis] = mini(low[axis], channels[axis])
			high[axis] = maxi(high[axis], channels[axis])
	var best := 0
	for axis in range(1, 3):
		if high[axis] - low[axis] > high[best] - low[best]:
			best = axis
	return [high[best] - low[best], best]


func _nearest(key: int) -> int:
	var r := ((key >> 10) & 31) * 8 + 4
	var g := ((key >> 5) & 31) * 8 + 4
	var b := (key & 31) * 8 + 4
	var best := 0
	var best_distance := 1 << 30
	for entry in range(256):
		var dr: int = int(_palette[entry * 3]) - r
		var dg: int = int(_palette[entry * 3 + 1]) - g
		var db: int = int(_palette[entry * 3 + 2]) - b
		var distance := dr * dr * 3 + dg * dg * 4 + db * db * 2
		if distance < best_distance:
			best_distance = distance
			best = entry
	return best


func _append_u16(value: int) -> void:
	_bytes.append(value & 0xFF)
	_bytes.append((value >> 8) & 0xFF)


## Data sub-blocks of at most 255 bytes, then the zero block.
func _append_blocks(data: PackedByteArray) -> void:
	var start := 0
	while start < data.size():
		var length := mini(255, data.size() - start)
		_bytes.append(length)
		_bytes.append_array(data.slice(start, start + length))
		start += length
	_bytes.append(0)
