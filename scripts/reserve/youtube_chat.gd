class_name YouTubeChat
extends Node

## A YouTube live stream's chat, polled through the Data API with the admin's own API key: the
## video's live chat is found first (`videos`, `activeLiveChatId`), then its messages are asked for
## no oftener than `min_interval_seconds` (each poll costs 5 of the project's 10 000 units a day).
## The first page is what was said before it started and is passed over. A spent quota waits ten
## minutes. `check()` says whether the video has a live chat now (`checked`).

signal heard(line: Dictionary)
signal checked(ok: bool, text: String)
signal status_changed

const STATE_OFF := "off"
const STATE_STARTING := "starting"
const STATE_OK := "ok"
const STATE_FAILED := "error"
const QUOTA_REASONS := ["quotaExceeded", "rateLimitExceeded", "dailyLimitExceeded"]

var settings: Dictionary = {}
var base_url := "https://www.googleapis.com/youtube/v3"
var status := {"state": STATE_OFF, "text": ""}

var _http: HTTPRequest
var _ask: HTTPRequest
var _running := false
var _chat_id := ""
var _page_token := ""
var _first := true
var _next_at := -1.0
var _failures := 0


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.use_threads = true
	_http.timeout = 20.0
	_http.request_completed.connect(_on_answer)
	add_child(_http)
	_ask = HTTPRequest.new()
	_ask.use_threads = true
	_ask.timeout = 20.0
	_ask.request_completed.connect(_on_checked)
	add_child(_ask)


func configure(new_settings: Dictionary) -> void:
	settings = new_settings.duplicate(true)


func video_id() -> String:
	return ChatProtocols.video_id_from(str(settings.get("video_id", "")))


func start() -> void:
	var missing := _missing()
	if missing != "":
		_set_status(STATE_FAILED, missing)
		return
	_running = true
	_chat_id = ""
	_page_token = ""
	_first = true
	_failures = 0
	_set_status(STATE_STARTING, "Ищем чат эфира…")
	_request(_http, "videos", {"part": "liveStreamingDetails", "id": video_id()})


func stop() -> void:
	_running = false
	_next_at = -1.0
	if _http != null:
		_http.cancel_request()
	_set_status(STATE_OFF, "")


func check() -> void:
	var missing := _missing()
	if missing != "":
		checked.emit(false, missing)
		return
	_ask.cancel_request()
	_request(_ask, "videos", {"part": "liveStreamingDetails", "id": video_id()})


func _missing() -> String:
	if str(settings.get("api_key", "")).strip_edges() == "":
		return "Впишите API-ключ"
	if video_id() == "":
		return "Вставьте ссылку на эфир"
	return ""


func url_for(path: String, params: Dictionary) -> String:
	var query := params.duplicate()
	query["key"] = str(settings.get("api_key", "")).strip_edges()
	return "%s/%s?%s" % [base_url.rstrip("/"), path, HTTPClient.new().query_string_from_dict(query)]


func _request(node: HTTPRequest, path: String, params: Dictionary) -> void:
	if node.request(url_for(path, params), ["Accept: application/json"]) != OK:
		if node == _http:
			_fail("Не удалось отправить запрос", 10.0)
		else:
			checked.emit(false, "Не удалось отправить запрос")


func _process(_delta: float) -> void:
	if not _running or _next_at < 0.0 or _now() < _next_at:
		return
	_next_at = -1.0
	if _chat_id == "":
		_request(_http, "videos", {"part": "liveStreamingDetails", "id": video_id()})
		return
	var params := {"liveChatId": _chat_id, "part": "snippet,authorDetails", "maxResults": 200}
	if _page_token != "":
		params["pageToken"] = _page_token
	_request(_http, "liveChat/messages", params)


func _on_answer(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not _running:
		return
	var answer := answer_of(result, code, body)
	if not bool(answer["ok"]):
		_fail(str(answer["why"]), float(answer["wait"]))
		return
	var data: Dictionary = answer["data"]
	if _chat_id == "":
		var found := live_chat_of(data)
		if not bool(found["ok"]):
			_fail(str(found["why"]), 30.0)
			return
		_chat_id = str(found["chat_id"])
		_failures = 0
		_set_status(STATE_OK, "Читаю чат эфира")
		_next_at = _now()
		return
	var page := handle_page(data, _first)
	_first = false
	_page_token = str(page["token"]) if str(page["token"]) != "" else _page_token
	for line in page["lines"]:
		heard.emit(line)
	if bool(page["over"]):
		_chat_id = ""
		_fail("Эфир закончился", 60.0)
		return
	_failures = 0
	_next_at = _now() + maxf(float(settings.get("min_interval_seconds", 8.0)), float(page["wait"]))


func _on_checked(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var answer := answer_of(result, code, body)
	if not bool(answer["ok"]):
		checked.emit(false, str(answer["why"]))
		return
	var found := live_chat_of(answer["data"])
	checked.emit(bool(found["ok"]), "Эфир идёт, чат открыт" if bool(found["ok"]) else str(found["why"]))


## `{ok, chat_id, why}` from a `videos` answer.
static func live_chat_of(data: Dictionary) -> Dictionary:
	var items: Array = data.get("items", [])
	if items.is_empty():
		return {"ok": false, "chat_id": "", "why": "Такого видео нет: проверьте ссылку"}
	var chat := str(items[0].get("liveStreamingDetails", {}).get("activeLiveChatId", ""))
	if chat == "":
		return {"ok": false, "chat_id": "", "why": "Эфир сейчас не идёт (ещё не начат или уже окончен)"}
	return {"ok": true, "chat_id": chat, "why": ""}


## What a page of the live chat comes to: `{lines, token, wait, over}` - the commands (none from
## the first page, said before), the next page's token, how long the API asks to wait, and whether
## the stream is over.
static func handle_page(page: Dictionary, first: bool) -> Dictionary:
	var lines: Array = []
	if not first:
		for item in page.get("items", []):
			if item is Dictionary:
				var line := ChatProtocols.youtube_message(item)
				if not line.is_empty():
					lines.append(line)
	return {"lines": lines, "token": str(page.get("nextPageToken", "")),
		"wait": float(page.get("pollingIntervalMillis", 0)) / 1000.0, "over": str(page.get("offlineAt", "")) != ""}


## `{ok, data, why, wait}` of an API answer.
static func answer_of(result: int, code: int, body: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "data": {}, "why": "Нет связи с YouTube", "wait": 10.0}
	var text := body.get_string_from_utf8()
	if code < 200 or code >= 300:
		var reason := ChatProtocols.youtube_reason(text)
		if QUOTA_REASONS.has(reason):
			return {"ok": false, "data": {}, "why": "Квота YouTube на сегодня кончилась, ждём 10 минут", "wait": 600.0}
		if code == 400 or code == 403:
			return {"ok": false, "data": {}, "why": "YouTube не принял ключ (%s)" % (reason if reason != "" else str(code)), "wait": 120.0}
		return {"ok": false, "data": {}, "why": "YouTube ответил %d %s" % [code, reason], "wait": 30.0}
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {"ok": false, "data": {}, "why": "Непонятный ответ YouTube", "wait": 30.0}
	return {"ok": true, "data": json.data, "why": "", "wait": 0.0}


func _fail(why: String, wait: float) -> void:
	_failures += 1
	_set_status(STATE_FAILED, why)
	_next_at = _now() + maxf(wait, minf(120.0, pow(2.0, float(mini(_failures, 7)))))


func _set_status(state: String, text: String) -> void:
	if str(status["state"]) == state and str(status["text"]) == text:
		return
	status = {"state": state, "text": text}
	status_changed.emit()


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
