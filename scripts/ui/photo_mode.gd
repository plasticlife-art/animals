class_name PhotoMode
extends CanvasLayer

## Photo mode (P, or «Фото» on the player bar): the world without the interface, to take a
## picture of it. Every HUD panel goes - the whole HUD layer, never panel by panel, since the
## cards show themselves again on the next tick - and so do the world's own extras: the debug
## overlays, the world border, the place names and the selection ring. The camera still pans
## and zooms. A small bar at the bottom: «Снимок» saves the screen as a PNG, «GIF 10 с» films ten
## seconds (`GifRecorder`), «Пауза»/«Пуск», «Скрыть» (H) hides the bar itself, «Выйти» (Esc).
## Pictures go to the system's Pictures folder, under «Engine of Ecosystem», or to
## user://photos when there is none; the bar says where, with «Открыть папку».

signal pause_toggled(paused: bool)
signal exited

const GifRecorderScript := preload("res://scripts/ui/gif_recorder.gd")
const FOLDER := "Engine of Ecosystem"
const FRAME_COLOUR := Color(0.86, 0.16, 0.12, 0.9)
const FRAME_WIDTH := 3.0

var active: bool = false
var simulation_manager = null
## Where pictures go instead of the Pictures folder, when set (the check harness).
var folder_override: String = ""
## What photo mode hides: `{node: visible before}` while active.
var _hidden: Dictionary = {}
var _hide_targets: Array = []
var _agent_renderer = null
var _world_view = null
var _ring_before: bool = true
var _bar: PanelContainer
var _pause: Button
var _status: Label
var _open_folder: Button
var _frame: Control
var _recorder = null
var _last_path: String = ""
var _bar_hidden: bool = false


func _init() -> void:
	layer = 20
	visible = false
	_frame = Control.new()
	_frame.set_anchors_preset(Control.PRESET_FULL_RECT)
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.visible = false
	_frame.draw.connect(_draw_frame)
	add_child(_frame)
	_bar = PanelContainer.new()
	_bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_bar.offset_top = -16.0
	_bar.offset_bottom = -16.0
	add_child(_bar)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	_bar.add_child(column)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	column.add_child(row)
	row.add_child(_button("Снимок", "Сохранить кадр в PNG", take_photo))
	row.add_child(_button("GIF 10 с", "Записать десять секунд в GIF", start_gif))
	_pause = _button("Пауза", "Остановить и продолжить время", _on_pause_pressed)
	_pause.toggle_mode = true
	row.add_child(_pause)
	row.add_child(_button("Скрыть", "Спрятать эту панель (H)", toggle_bar))
	row.add_child(_button("Выйти", "Вернуться к игре (Esc, P)", leave))
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 8)
	column.add_child(status_row)
	_status = Label.new()
	_status.text = "Камера двигается как обычно"
	status_row.add_child(_status)
	_open_folder = _button("Открыть папку", "Показать снимок в папке", _on_open_folder)
	_open_folder.visible = false
	status_row.add_child(_open_folder)


## What to hide: `hide` are nodes hidden while active; the renderer's selection ring and the
## world view's clicks are switched off too.
func bind(manager, hide: Array, agent_renderer, world_view) -> void:
	simulation_manager = manager
	_hide_targets = hide
	_agent_renderer = agent_renderer
	_world_view = world_view


func set_theme_for_bar(bar_theme: Theme) -> void:
	_bar.theme = bar_theme


func toggle() -> void:
	if active:
		leave()
	else:
		enter()


func enter() -> void:
	if active:
		return
	active = true
	_hidden.clear()
	for node in _hide_targets:
		if node != null:
			_hidden[node] = node.visible
			node.visible = false
	if _agent_renderer != null:
		_ring_before = bool(_agent_renderer.show_selection_ring)
		_agent_renderer.show_selection_ring = false
		_agent_renderer.queue_redraw()
	if _world_view != null:
		_world_view.set_input_enabled(false)
	_pause.set_pressed_no_signal(simulation_manager != null and bool(simulation_manager.paused))
	_pause.text = "Пуск" if _pause.button_pressed else "Пауза"
	_bar_hidden = false
	_bar.visible = true
	_status.text = "Камера двигается как обычно"
	_open_folder.visible = false
	visible = true


func leave() -> void:
	if not active:
		return
	if _recorder != null and _recorder.is_recording():
		_recorder.stop(Time.get_ticks_msec())
	active = false
	for node in _hidden.keys():
		if is_instance_valid(node):
			node.visible = bool(_hidden[node])
	_hidden.clear()
	if _agent_renderer != null:
		_agent_renderer.show_selection_ring = _ring_before
		_agent_renderer.queue_redraw()
	if _world_view != null:
		_world_view.set_input_enabled(true)
	# A GIF still being written finishes on its own; the bar would only say where it went.
	visible = _recorder != null
	_frame.visible = false
	exited.emit()


## Quitting mid-film waits for the file rather than leaving its thread running.
func _exit_tree() -> void:
	if _recorder != null:
		_recorder.cancel()
		_recorder = null


func toggle_bar() -> void:
	_bar_hidden = not _bar_hidden
	_bar.visible = not _bar_hidden


## The screen as it is, without the bar, saved as a PNG.
func take_photo() -> void:
	if not active or _recording():
		return
	_bar.visible = false
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	_bar.visible = not _bar_hidden
	var path := next_path("png", folder_override)
	var saved := image != null and image.save_png(path) == OK
	_tell_saved(path, saved)


## Ten seconds of film; the bar steps aside and a red frame marks the recording.
func start_gif() -> void:
	if not active or _recording():
		return
	_recorder = GifRecorderScript.new()
	_recorder.finished.connect(_on_gif_finished)
	var size := get_viewport().get_texture().get_size()
	_recorder.start(next_path("gif", folder_override), Vector2i(size))
	_bar.visible = false
	_frame.visible = true
	_frame.queue_redraw()


func _process(_delta: float) -> void:
	if _recorder == null:
		return
	if _recorder.is_recording():
		_recorder.capture(get_viewport(), Time.get_ticks_msec())
		if not _recorder.is_recording():
			_frame.visible = false
			_bar.visible = active and not _bar_hidden
	if _recorder != null and not _recorder.is_recording():
		_status.text = "Сохраняю GIF… %d %%" % int(round(_recorder.progress() * 100.0))
		_recorder.poll()


func _recording() -> bool:
	return _recorder != null


func _on_gif_finished(path: String, ok: bool) -> void:
	_recorder = null
	_tell_saved(path, ok)
	if not active:
		visible = false


func _tell_saved(path: String, ok: bool) -> void:
	_last_path = path if ok else ""
	_status.text = "Сохранено: %s" % path.get_file() if ok else "Не удалось сохранить"
	_open_folder.visible = ok


func _on_open_folder() -> void:
	if _last_path != "":
		OS.shell_show_in_file_manager(ProjectSettings.globalize_path(_last_path))


func _on_pause_pressed() -> void:
	_pause.text = "Пуск" if _pause.button_pressed else "Пауза"
	pause_toggled.emit(_pause.button_pressed)


func _draw_frame() -> void:
	var rect := Rect2(Vector2.ZERO, _frame.size).grow(-FRAME_WIDTH * 0.5)
	_frame.draw_rect(rect, FRAME_COLOUR, false, FRAME_WIDTH)


## A new file under the pictures folder (or `folder`): «eoe-2026-10-03-14-55-12.png».
static func next_path(extension: String, folder: String = "") -> String:
	if folder == "":
		folder = pictures_folder()
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "-")
	var path := "%s/eoe-%s.%s" % [folder, stamp, extension]
	var index := 2
	while FileAccess.file_exists(path):
		path = "%s/eoe-%s-%d.%s" % [folder, stamp, index, extension]
		index += 1
	return path


## The system's Pictures folder under «Engine of Ecosystem», made if missing; user://photos
## when there is no Pictures folder or it cannot be written.
static func pictures_folder() -> String:
	var pictures := OS.get_system_dir(OS.SYSTEM_DIR_PICTURES)
	if pictures != "":
		var folder := pictures.path_join(FOLDER)
		if DirAccess.make_dir_recursive_absolute(folder) == OK:
			return folder
	var fallback := ProjectSettings.globalize_path("user://photos")
	DirAccess.make_dir_recursive_absolute(fallback)
	return fallback


static func _button(text: String, tip: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	return button
