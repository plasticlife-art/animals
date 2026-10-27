class_name StreamWizard
extends CenterContainer

## «Трансляция», from the start menu: the living reserve set up and started without a terminal or
## a file to edit, in three steps.
## 1. «Чаты» - the chats viewers command the world from. Telegram: the bot's token, checked
##    (`getMe`), and its groups found by reading what the bot hears («Найти группу») and picked
##    with a click. Twitch: the channel, checked by joining its chat. YouTube: the API key and the
##    live stream's link, checked by finding its chat.
## 2. «OBS» - what to click in OBS, for a Mac or for Windows, the window's name to copy.
## 3. «Запуск» - what is ready, then «Продолжить мир» or «Новый мир» (`start_requested`).
## Every change is written at once (`StreamSettings`); the keys stay in the game's folder for its
## user. The game reads the chats itself while the reserve runs (`StreamChats`).

signal start_requested(fresh: bool)
signal closed

const PAGE_WIDTH := 760.0
const TEXT_SIZE := 18
const SMALL_SIZE := 16
const GOOD := Color(0.16, 0.48, 0.2)
const BAD := Color(0.72, 0.18, 0.12)
const DIM := Color(0.20, 0.13, 0.08, 0.62)
const STEPS := ["1. Чаты", "2. OBS", "3. Запуск"]
const BOTFATHER_URL := "https://t.me/BotFather"
const CLOUD_URL := "https://console.cloud.google.com/apis/library/youtube.googleapis.com"
const OBS_URL := "https://obsproject.com/download"

var settings: Dictionary = StreamSettings.merged({})
var settings_path := StreamSettings.PATH
## Whether the reserve has a save to go on from; «Продолжить мир» shows only then.
var can_continue := false
var obs_system := "Windows" if OS.get_name() == "Windows" else "macOS"

var _panel: PanelContainer
var _scroll: ScrollContainer
var _step_buttons: Array = []
var _pages: Array = []
var _step := 0
var _toggles := {}
var _fields := {}
var _results := {}
var _chosen_box: VBoxContainer
var _found_box: VBoxContainer
var _find_button: Button
var _obs_text: Label
var _obs_switch: Button
var _summary: Label
var _continue: Button
var _telegram: TelegramChat
var _twitch: TwitchChat
var _youtube: YouTubeChat


func _init() -> void:
	visible = false
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_telegram = TelegramChat.new()
	_telegram.discover = true
	_telegram.checked.connect(_on_checked.bind("telegram"))
	_telegram.chats_found.connect(func(_chats: Array) -> void: _show_found())
	_telegram.status_changed.connect(_show_finding)
	add_child(_telegram)
	_twitch = TwitchChat.new()
	_twitch.checked.connect(_on_checked.bind("twitch"))
	add_child(_twitch)
	_youtube = YouTubeChat.new()
	_youtube.checked.connect(_on_checked.bind("youtube"))
	add_child(_youtube)
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(PAGE_WIDTH, 0.0)
	add_child(_panel)
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	_panel.add_child(margin)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)
	var title := Label.new()
	title.text = "Трансляция"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)
	var steps := HBoxContainer.new()
	steps.add_theme_constant_override("separation", 8)
	steps.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(steps)
	for index in range(STEPS.size()):
		var button := Button.new()
		button.text = STEPS[index]
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.pressed.connect(show_step.bind(index))
		steps.add_child(button)
		_step_buttons.append(button)
	_scroll = ScrollContainer.new()
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.custom_minimum_size = Vector2(PAGE_WIDTH - 44.0, 520.0)
	column.add_child(_scroll)
	# Clear of the scroll bar on the right.
	var inset := MarginContainer.new()
	inset.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_theme_constant_override("margin_right", 16)
	_scroll.add_child(inset)
	var pages := VBoxContainer.new()
	pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inset.add_child(pages)
	_pages = [_build_chats(), _build_obs(), _build_start()]
	for page in _pages:
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		pages.add_child(page)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 10)
	column.add_child(foot)
	var back := _button(foot, "В меню", func() -> void: close())
	back.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var next := _button(foot, "Далее", func() -> void: show_step(mini(_step + 1, STEPS.size() - 1)))
	next.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	next.name = "Next"
	show_step(0)


## Opens on the settings at `settings_path`: on «Запуск» when a chat is ready, else on «Чаты».
func open(saved_world: bool) -> void:
	can_continue = saved_world
	settings = StreamSettings.load_settings(settings_path)
	_fill()
	visible = true
	show_step(2 if not StreamSettings.ready_chats(settings).is_empty() else 0)


func close() -> void:
	_stop_checks()
	visible = false
	closed.emit()


func show_step(index: int) -> void:
	_step = index
	for page_index in range(_pages.size()):
		_pages[page_index].visible = page_index == index
		_step_buttons[page_index].set_pressed_no_signal(page_index == index)
		# The step one is on stands out; the others step back.
		_step_buttons[page_index].modulate = Color(1, 1, 1, 1.0 if page_index == index else 0.6)
	var next: Button = find_child("Next", true, false)
	if next != null:
		next.visible = index < STEPS.size() - 1
	if index == 2:
		_refresh_summary()
	if _scroll != null:
		_scroll.scroll_vertical = 0
	_refit()


## Fits the scroll to its page on the next frame, once the page has its new size.
func _refit() -> void:
	if is_inside_tree() and not get_tree().process_frame.is_connected(_fit):
		get_tree().process_frame.connect(_fit, CONNECT_ONE_SHOT)


## The scroll as tall as its page, up to what the window allows; a page that fits does not
## scroll, and a short one leaves no empty parchment below it.
func _fit() -> void:
	if not is_inside_tree() or _step >= _pages.size():
		return
	var room := clampf(get_viewport_rect().size.y - 260.0, 200.0, 640.0)
	_scroll.custom_minimum_size.y = minf(_pages[_step].get_combined_minimum_size().y + 4.0, room)


# --- Step 1: chats ----------------------------------------------------------------------------

func _build_chats() -> VBoxContainer:
	var page := _page()
	_text(page, "Зрители управляют миром командами в чате. Включите чаты, где пойдёт трансляция: игра будет читать их сама.")
	# Telegram
	var telegram := _section(page, "telegram", "Telegram")
	_text(telegram, "1. В Telegram откройте @BotFather → /newbot, придумайте имя — BotFather пришлёт токен.\n"
		+ "2. Там же /setprivacy → ваш бот → Disable, чтобы бот видел команды с «!».\n"
		+ "3. Добавьте бота в группу (или в обсуждение канала), где будет трансляция.", SMALL_SIZE)
	var links := _flow(telegram)
	_button(links, "Открыть BotFather", func() -> void: OS.shell_open(BOTFATHER_URL))
	var token_row := _row(telegram)
	_label(token_row, "Токен бота")
	_field(token_row, "telegram", "bot_token", "123456:ABC…", true)
	_button(token_row, "Проверить", func() -> void: _check("telegram"))
	_result(telegram, "telegram")
	_label(telegram, "Группы, которые бот слушает:")
	_chosen_box = VBoxContainer.new()
	telegram.add_child(_chosen_box)
	var find_row := _row(telegram)
	_find_button = _button(find_row, "Найти группу", _toggle_finding)
	_result(telegram, "finding")
	_found_box = VBoxContainer.new()
	telegram.add_child(_found_box)
	# Twitch
	var twitch := _section(page, "twitch", "Twitch")
	_text(twitch, "Чат читается без входа: достаточно имени канала, как в ссылке twitch.tv/имя.", SMALL_SIZE)
	var channel_row := _row(twitch)
	_label(channel_row, "Канал")
	_field(channel_row, "twitch", "channel", "имя канала", false)
	_button(channel_row, "Проверить", func() -> void: _check("twitch"))
	_result(twitch, "twitch")
	# YouTube
	var youtube := _section(page, "youtube", "YouTube")
	_text(youtube, "Нужен API-ключ своего проекта Google Cloud: включите YouTube Data API v3 и создайте ключ "
		+ "(Credentials → Create credentials → API key). Ссылка на эфир — у каждого эфира своя; "
		+ "проверка находит чат, только пока эфир идёт.", SMALL_SIZE)
	var cloud := _row(youtube)
	_button(cloud, "Открыть Google Cloud", func() -> void: OS.shell_open(CLOUD_URL))
	var key_row := _row(youtube)
	_label(key_row, "API-ключ")
	_field(key_row, "youtube", "api_key", "AIza…", true)
	var video_row := _row(youtube)
	_label(video_row, "Ссылка на эфир")
	_field(video_row, "youtube", "video_id", "https://youtube.com/live/…", false)
	_button(video_row, "Проверить", func() -> void: _check("youtube"))
	_result(youtube, "youtube")
	return page


## A chat's block: its switch, then what it needs, shown only while it is on.
func _section(page: VBoxContainer, platform: String, title: String) -> VBoxContainer:
	var toggle := Button.new()
	toggle.toggle_mode = true
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.toggled.connect(func(pressed: bool) -> void:
		settings[platform]["enabled"] = pressed
		_show_toggle(platform)
		_save())
	page.add_child(toggle)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 6)
	page.add_child(body)
	_toggles[platform] = {"button": toggle, "body": body, "title": title}
	return body


func _show_toggle(platform: String) -> void:
	var toggle: Dictionary = _toggles[platform]
	var on := bool(settings[platform].get("enabled", false))
	toggle["button"].set_pressed_no_signal(on)
	toggle["button"].text = "%s: %s" % [toggle["title"], "вкл" if on else "выкл"]
	toggle["body"].visible = on
	_refit()


func _field(row: HBoxContainer, platform: String, key: String, placeholder: String, secret: bool) -> LineEdit:
	var field := LineEdit.new()
	field.placeholder_text = placeholder
	field.secret = secret
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.custom_minimum_size.x = 240.0
	field.add_theme_font_size_override("font_size", TEXT_SIZE)
	field.text_changed.connect(func(text: String) -> void:
		settings[platform][key] = text.strip_edges()
		_save())
	row.add_child(field)
	_fields["%s.%s" % [platform, key]] = field
	if secret:
		var eye := Button.new()
		eye.text = "Показать"
		eye.toggle_mode = true
		eye.focus_mode = Control.FOCUS_NONE
		eye.add_theme_font_size_override("font_size", SMALL_SIZE)
		eye.toggled.connect(func(pressed: bool) -> void:
			field.secret = not pressed
			eye.text = "Скрыть" if pressed else "Показать")
		row.add_child(eye)
	return field


func _check(platform: String) -> void:
	_say(platform, "Проверяю…", DIM)
	match platform:
		"telegram":
			_telegram.configure(settings["telegram"])
			_telegram.check()
		"twitch":
			_twitch.configure(settings["twitch"])
			_twitch.check()
		"youtube":
			_youtube.configure(settings["youtube"])
			_youtube.check()


func _on_checked(ok: bool, text: String, platform: String) -> void:
	_say(platform, ("✓ " if ok else "✗ ") + text, GOOD if ok else BAD)


func _toggle_finding() -> void:
	if _telegram.is_running():
		_telegram.stop()
		_find_button.text = "Найти группу"
		_say("finding", "", DIM)
		return
	_telegram.configure(settings["telegram"])
	_telegram.found_chats.clear()
	_telegram.start()
	_find_button.text = "Остановить поиск"
	_show_found()


func _show_finding() -> void:
	var state := str(_telegram.status["state"])
	if state == TelegramChat.STATE_FAILED:
		_say("finding", "✗ " + str(_telegram.status["text"]), BAD)
	elif state != TelegramChat.STATE_OFF:
		_say("finding", "Напишите любое сообщение в группе с ботом — она появится ниже.", DIM)


## The groups found, each with «Добавить» unless it is heard already.
func _show_found() -> void:
	for child in _found_box.get_children():
		child.queue_free()
	for chat in _telegram.found_chats:
		var row := _row(_found_box)
		_label(row, "%s (%s)" % [str(chat.get("title", "")) if str(chat.get("title", "")) != "" else "без названия", chat["id"]])
		if _has_chat(str(chat["id"])):
			_label(row, "уже слушает", DIM)
		else:
			var picked: Dictionary = {"id": str(chat["id"]), "title": str(chat.get("title", ""))}
			_button(row, "Добавить", func() -> void:
				settings["telegram"]["chats"].append(picked)
				_save()
				_show_chosen()
				_show_found())
	_refit()


func _has_chat(chat_id: String) -> bool:
	for chat in settings["telegram"].get("chats", []):
		if ChatProtocols._chat_key(chat) == chat_id:
			return true
	return false


func _show_chosen() -> void:
	for child in _chosen_box.get_children():
		child.queue_free()
	var chats: Array = settings["telegram"].get("chats", [])
	if chats.is_empty():
		_label(_chosen_box, "пока ни одной — нажмите «Найти группу»", DIM)
	for index in range(chats.size()):
		var chat = chats[index]
		var title := str(chat.get("title", "")) if chat is Dictionary else ""
		var row := _row(_chosen_box)
		_label(row, "%s (%s)" % [title if title != "" else "группа", ChatProtocols._chat_key(chat)])
		var gone = chat
		_button(row, "Убрать", func() -> void:
			settings["telegram"]["chats"].erase(gone)
			_save()
			_show_chosen()
			_show_found())


# --- Step 2: OBS ------------------------------------------------------------------------------

func _build_obs() -> VBoxContainer:
	var page := _page()
	_text(page, "OBS Studio показывает окно игры зрителям. Настраивается один раз, дальше только «Начать трансляцию».")
	var row := _flow(page)
	_obs_switch = _button(row, "", func() -> void:
		obs_system = "Windows" if obs_system == "macOS" else "macOS"
		_show_obs())
	_button(row, "Открыть сайт OBS", func() -> void: OS.shell_open(OBS_URL))
	_button(row, "Скопировать название окна", func() -> void: DisplayServer.clipboard_set(window_title()))
	_obs_text = _text(page, "")
	return page


func _show_obs() -> void:
	_obs_switch.text = "Подсказки для: %s (сменить)" % ("Mac" if obs_system == "macOS" else "Windows")
	_obs_text.text = obs_steps(obs_system, window_title(), StreamSettings.ready_chats(settings))


static func window_title() -> String:
	return str(ProjectSettings.get_setting("application/config/name", "Engine of Ecosystem"))


## What to click in OBS, step by step, for `system` ("macOS" or "Windows"), the stream going to
## the platforms of `chats` (Telegram, Twitch, YouTube; all three when none is set up yet).
static func obs_steps(system: String, title: String, chats: Array) -> String:
	var steps: Array = ["Установите OBS Studio с obsproject.com и запустите."]
	if system == "macOS":
		steps.append("При первом запуске разрешите OBS запись экрана: Системные настройки → Конфиденциальность и безопасность → Запись экрана → включите OBS и перезапустите его.")
		steps.append("Внизу в «Источниках» нажмите «+» → «Захват экрана macOS» → «Способ: Захват окна» → выберите окно «%s»." % title)
	else:
		steps.append("Внизу в «Источниках» нажмите «+» → «Захват окна» → в списке «Окно» выберите то, где написано «%s». Если картинка чёрная — в свойствах источника поставьте «Метод захвата: Windows 10 (1903 и новее)»." % title)
	steps.append("Настройки → Видео: базовое и выходное разрешение 1920×1080, 30 кадров в секунду. Источник растяните на весь холст (правая кнопка → Преобразовать → Растянуть по экрану).")
	var where: Array = chats if not chats.is_empty() else ["telegram", "twitch", "youtube"]
	if where.has("telegram"):
		steps.append("Telegram: в группе нажмите «Трансляция» (значок видеочата) → «Начать с помощью…». Telegram покажет «URL сервера» и «Ключ трансляции». В OBS: Настройки → Трансляция → Сервис «Настраиваемый…», вставьте оба.")
	if where.has("twitch"):
		steps.append("Twitch: Настройки → Трансляция → Сервис «Twitch» → «Подключить аккаунт» (или ключ из Панели автора → Настройки → Трансляция).")
	if where.has("youtube"):
		steps.append("YouTube: Настройки → Трансляция → Сервис «YouTube» → «Подключить аккаунт» (или ключ из YouTube Studio → «Начать трансляцию»).")
	steps.append("Окно игры не сворачивайте — свёрнутое окно не рисуется. Удобно держать его на втором мониторе; другие окна поверх не мешают%s." % (" только в «Захвате окна»" if system == "macOS" else ""))
	steps.append("Запустите заповедник (шаг 3), затем в OBS «Начать трансляцию»%s." % (", потом в Telegram «Начать трансляцию»" if where.has("telegram") else ""))
	var lines: Array = []
	for index in range(steps.size()):
		lines.append("%d. %s" % [index + 1, steps[index]])
	return "\n".join(lines)


# --- Step 3: start ----------------------------------------------------------------------------

func _build_start() -> VBoxContainer:
	var page := _page()
	_summary = _text(page, "")
	_text(page, "Окно игры можно развернуть во весь экран клавишей F11. Пауза, скорость и Esc работают как обычно; "
		+ "мир сохраняется каждые две минуты в свои слоты.", SMALL_SIZE)
	var row := _row(page)
	_continue = _button(row, "Продолжить мир", func() -> void: _start(false))
	_continue.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var fresh := _button(row, "Новый мир", func() -> void: _start(true))
	fresh.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return page


func _refresh_summary() -> void:
	if _summary == null:
		return
	_summary.text = summary_text(settings)
	_continue.visible = can_continue


## What is ready, a line a chat: «Telegram: группы «Заповедник»», «Twitch: выключен»…
static func summary_text(values: Dictionary) -> String:
	var ready := StreamSettings.ready_chats(values)
	var lines: Array = ["Готово к запуску:" if not ready.is_empty() else "Ни один чат не настроен: зрители не смогут управлять миром. Вернитесь к шагу 1 — или запустите мир просто так."]
	var telegram: Dictionary = values.get("telegram", {})
	if ready.has("telegram"):
		var names: Array = []
		for chat in telegram.get("chats", []):
			var title := str(chat.get("title", "")) if chat is Dictionary else ""
			names.append("«%s»" % title if title != "" else ChatProtocols._chat_key(chat))
		lines.append("• Telegram: %s" % ("группы " + ", ".join(names) if not names.is_empty() else "бот на месте, но группа не выбрана — бот ответит только в личке"))
	elif bool(telegram.get("enabled", false)):
		lines.append("• Telegram: нет токена бота")
	var twitch: Dictionary = values.get("twitch", {})
	if ready.has("twitch"):
		lines.append("• Twitch: канал #%s" % str(twitch.get("channel", "")).to_lower().trim_prefix("#"))
	elif bool(twitch.get("enabled", false)):
		lines.append("• Twitch: не указан канал")
	var youtube: Dictionary = values.get("youtube", {})
	if ready.has("youtube"):
		lines.append("• YouTube: эфир %s" % ChatProtocols.video_id_from(str(youtube.get("video_id", ""))))
	elif bool(youtube.get("enabled", false)):
		lines.append("• YouTube: нужны API-ключ и ссылка на эфир")
	return "\n".join(lines)


func _start(fresh: bool) -> void:
	_stop_checks()
	_save()
	visible = false
	start_requested.emit(fresh)


func _stop_checks() -> void:
	_telegram.stop()
	_twitch.stop()
	_youtube.stop()
	if _find_button != null:
		_find_button.text = "Найти группу"


# --- Helpers ----------------------------------------------------------------------------------

func _fill() -> void:
	for key in _fields.keys():
		var parts: PackedStringArray = str(key).split(".")
		_fields[key].text = str(settings[parts[0]].get(parts[1], ""))
	for platform in _toggles.keys():
		_show_toggle(platform)
	for platform in _results.keys():
		_say(platform, "", DIM)
	_show_chosen()
	_show_found()
	_show_obs()


func _save() -> void:
	StreamSettings.save_settings(settings, settings_path)


func _page() -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 10)
	return page


func _row(parent: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)
	return row


## A row of buttons that wraps rather than widening the page.
func _flow(parent: Control) -> HFlowContainer:
	var row := HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 8)
	parent.add_child(row)
	return row


func _label(parent: Control, text: String, color := Color(0, 0, 0, 0)) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", TEXT_SIZE)
	if color.a > 0.0:
		label.add_theme_color_override("font_color", color)
	label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(label)
	return label


func _text(parent: Control, text: String, size := TEXT_SIZE) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.custom_minimum_size.x = PAGE_WIDTH - 80.0
	label.add_theme_font_size_override("font_size", size)
	parent.add_child(label)
	return label


func _button(parent: Control, text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", TEXT_SIZE)
	button.pressed.connect(action)
	parent.add_child(button)
	return button


func _result(parent: Control, key: String) -> Label:
	var label := _text(parent, "", SMALL_SIZE)
	label.visible = false
	_results[key] = label
	return label


func _say(key: String, text: String, color: Color) -> void:
	var label: Label = _results.get(key)
	if label == null:
		return
	label.text = text
	label.visible = text != ""
	label.add_theme_color_override("font_color", color)
	_refit()
