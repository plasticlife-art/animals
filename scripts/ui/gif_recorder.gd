class_name GifRecorder
extends RefCounted

## Ten seconds of the screen as a GIF, for photo mode: the window is grabbed fifteen times a
## second on the main thread - the only one that may read the screen back - cropped of the
## recording frame drawn at its edge, scaled to 640 wide, and handed to `GifEncoder` on a
## thread of its own, which codes the frames in order while the recording goes on. Each frame
## is shown for as long as it really lasted until the next. The owner calls `poll()` each frame
## once the recording is over; `finished` comes from there, on the main thread, when the file
## is written - no call crosses back from the coding thread.

signal finished(path: String, ok: bool)

const FPS := 15
const SECONDS := 10.0
const WIDTH := 640
## Pixels cut off each edge: the red frame that marks the recording is drawn there.
const CROP := 6

var path: String = ""
var frame_size := Vector2i.ZERO
var captured: int = 0
var _encoder = null
var _thread: Thread = null
var _mutex := Mutex.new()
var _semaphore := Semaphore.new()
var _queue: Array = []
var _closing := false
var _encoded: int = 0
var _started_msec: int = -1
var _last_msec: int = -1
var _pending := PackedByteArray()
var _pending_msec: int = -1
var _recording := false
var _done := false
var _ok := false
var _reported := false


## Starts a film of a screen `screen_size` big, to be written to `target`.
func start(target: String, screen_size: Vector2i) -> void:
	path = target
	var cut := Vector2i(maxi(1, screen_size.x - CROP * 2), maxi(1, screen_size.y - CROP * 2))
	var height := maxi(2, int(round(float(WIDTH) * float(cut.y) / float(cut.x))))
	frame_size = Vector2i(WIDTH, height)
	_encoder = preload("res://scripts/ui/gif_encoder.gd").new(frame_size.x, frame_size.y)
	_recording = true
	_closing = false
	_done = false
	_ok = false
	_reported = false
	captured = 0
	_encoded = 0
	_started_msec = -1
	_pending = PackedByteArray()
	_pending_msec = -1
	_thread = Thread.new()
	_thread.start(_work)


func is_recording() -> bool:
	return _recording


## Seconds of film so far.
func elapsed(now_msec: int) -> float:
	return 0.0 if _started_msec < 0 else float(now_msec - _started_msec) / 1000.0


## Called every frame while recording: grabs the screen when the next frame is due. Ends the
## recording itself once its time is up.
func capture(viewport: Viewport, now_msec: int) -> void:
	if not _recording:
		return
	if _started_msec < 0:
		_started_msec = now_msec
	elif float(now_msec - _started_msec) / 1000.0 >= SECONDS:
		stop(now_msec)
		return
	if _last_msec >= 0 and now_msec - _last_msec < int(1000.0 / FPS):
		return
	_last_msec = now_msec
	var image := viewport.get_texture().get_image()
	if image == null or image.is_empty():
		return
	image.convert(Image.FORMAT_RGB8)
	var cut := Rect2i(CROP, CROP, maxi(1, image.get_width() - CROP * 2), maxi(1, image.get_height() - CROP * 2))
	image = image.get_region(cut)
	image.resize(frame_size.x, frame_size.y, Image.INTERPOLATE_BILINEAR)
	feed(image.get_data(), now_msec)


## A frame of `frame_size` RGB8 pixels taken at `now_msec`; the one before it now knows how long
## it lasted and goes to the coding thread.
func feed(rgb: PackedByteArray, now_msec: int) -> void:
	_push_pending(now_msec)
	_pending = rgb
	_pending_msec = now_msec
	captured += 1


## Ends the recording: the last frame goes with a frame's length, and the thread finishes the
## file.
func stop(now_msec: int) -> void:
	if not _recording:
		return
	_recording = false
	if _pending_msec >= 0:
		_enqueue(_pending, int(round(100.0 / FPS)))
		_pending = PackedByteArray()
		_pending_msec = -1
	_mutex.lock()
	_closing = true
	_mutex.unlock()
	_semaphore.post()


## How much of the film is coded, 0 to 1.
func progress() -> float:
	_mutex.lock()
	var done := _encoded
	_mutex.unlock()
	return 1.0 if captured <= 0 else clampf(float(done) / float(captured), 0.0, 1.0)


## True once the file is written; `finished` is emitted then, once.
func poll() -> bool:
	_mutex.lock()
	var done := _done
	_mutex.unlock()
	if not done:
		return false
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null
	if not _reported:
		_reported = true
		finished.emit(path, _ok)
	return true


## Ends a recording and waits for its file: quitting in the middle, or a test.
func cancel() -> void:
	if _recording:
		stop(Time.get_ticks_msec())
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
	_thread = null


func _push_pending(now_msec: int) -> void:
	if _pending_msec < 0:
		return
	_enqueue(_pending, clampi(int(round(float(now_msec - _pending_msec) / 10.0)), 2, 100))


func _enqueue(rgb: PackedByteArray, delay_cs: int) -> void:
	_mutex.lock()
	_queue.append([rgb, delay_cs])
	_mutex.unlock()
	_semaphore.post()


func _work() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		var item = _queue.pop_front() if not _queue.is_empty() else null
		var closing := _closing
		_mutex.unlock()
		if item != null:
			_encoder.add_frame(item[0], int(item[1]))
			_mutex.lock()
			_encoded += 1
			_mutex.unlock()
		elif closing:
			break
	var ok := false
	if _encoder.frames > 0:
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file != null:
			file.store_buffer(_encoder.finish())
			file.close()
			ok = true
	_mutex.lock()
	_ok = ok
	_done = true
	_mutex.unlock()
