class_name TelegramChat
extends Node

## A Telegram bot of the admin's own, read by the Bot API's long polling (`getUpdates`): commands
## from the groups in `chats` come out as `heard` lines; «!помощь», «!правила», /help or /start get
## the rules back (in a group as a reply, once a `rules_gap_seconds`; in a private chat always).
## What was said before it started is passed over. With `discover`, as «Найти группу» in the
## wizard asks, it reads what is waiting too and lists the groups it hears from (`chats_found`),
## heard or not. `check()` asks the bot's name (`getMe`). `status` says how it goes, in words for
## the admin.

signal heard(line: Dictionary)
signal checked(ok: bool, text: String)
signal chats_found(chats: Array)
signal status_changed

const STATE_OFF := "off"
const STATE_STARTING := "starting"
const STATE_OK := "ok"
const STATE_FAILED := "error"

var settings: Dictionary = {}
var base_url := "https://api.telegram.org"
var discover := false
var status := {"state": STATE_OFF, "text": ""}
## Groups heard from since it started: `[{id, title, type}]`, the first heard first.
var found_chats: Array = []

var _poll: HTTPRequest
var _send: HTTPRequest
var _ask: HTTPRequest
var _running := false
## The next update to ask for; -2 until the first answer says where the waiting ones end.
var _offset := -2
var _retry_at := -1.0
var _failures := 0
var _rules_at := {}
var _outbox: Array = []


func _ready() -> void:
	_poll = _request_node(_on_polled)
	_send = _request_node(_on_sent)
	_ask = _request_node(_on_asked)


func _request_node(handler: Callable) -> HTTPRequest:
	var node := HTTPRequest.new()
	node.use_threads = true
	node.request_completed.connect(handler)
	add_child(node)
	return node


func configure(new_settings: Dictionary) -> void:
	settings = new_settings.duplicate(true)


func token() -> String:
	return str(settings.get("bot_token", "")).strip_edges()


func start() -> void:
	if token() == "":
		_set_status(STATE_FAILED, "Нет токена бота")
		return
	_running = true
	_offset = 0 if discover else -2
	_failures = 0
	_set_status(STATE_STARTING, "Подключаемся к Telegram…")
	_ask_updates()


func is_running() -> bool:
	return _running


func stop() -> void:
	_running = false
	_retry_at = -1.0
	if _poll != null:
		_poll.cancel_request()
	_set_status(STATE_OFF, "")


## The bot's name, answered by `checked`.
func check() -> void:
	if token() == "":
		checked.emit(false, "Впишите токен бота")
		return
	_ask.cancel_request()
	_ask.timeout = 15.0
	if _ask.request(url_for("getMe", {})) != OK:
		checked.emit(false, "Не удалось отправить запрос")


func url_for(method: String, params: Dictionary) -> String:
	var url := "%s/bot%s/%s" % [base_url.rstrip("/"), token(), method]
	return url if params.is_empty() else url + "?" + HTTPClient.new().query_string_from_dict(params)


func _process(_delta: float) -> void:
	if _running and _retry_at >= 0.0 and _now() >= _retry_at:
		_retry_at = -1.0
		_ask_updates()


func _ask_updates() -> void:
	if not _running:
		return
	var wait := 0 if _offset == -2 else int(settings.get("poll_seconds", 25))
	var params := {"timeout": wait, "allowed_updates": JSON.stringify(["message"])}
	params["offset"] = -1 if _offset == -2 else _offset
	_poll.timeout = float(wait) + 15.0
	if _poll.request(url_for("getUpdates", params)) != OK:
		_fail("Не удалось отправить запрос", 5.0)


func _on_polled(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not _running:
		return
	var answer := _answer(result, code, body)
	if not bool(answer["ok"]):
		_fail(str(answer["why"]), float(answer["wait"]))
		return
	var updates: Array = answer["result"] if answer["result"] is Array else []
	if _offset == -2:
		# The newest waiting update only: start past it.
		_offset = int(updates[-1].get("update_id", 0)) + 1 if not updates.is_empty() else 0
	else:
		var taken := handle_updates(updates, _now())
		_offset = maxi(_offset, int(taken["offset"]))
		for line in taken["lines"]:
			heard.emit(line)
		for reply in taken["replies"]:
			_outbox.append(reply)
		if not taken["found"].is_empty():
			chats_found.emit(found_chats.duplicate(true))
		_send_next()
	_failures = 0
	if str(status["state"]) != STATE_OK:
		_set_status(STATE_OK, listening_text())
	_ask_updates()


## What a batch of updates comes to: `{lines, replies, found, offset}` - the commands heard, the
## rules to send (`{chat_id, text, reply_to}`), the groups heard from for the first time (added to
## `found_chats`), and the offset past them all. `now` in seconds, for the rules' gap.
func handle_updates(updates: Array, now: float) -> Dictionary:
	var chats: Array = settings.get("chats", [])
	var accept_slash := bool(settings.get("accept_slash", true))
	var out := {"lines": [], "replies": [], "found": [], "offset": _offset}
	for update in updates:
		if not update is Dictionary:
			continue
		out["offset"] = maxi(int(out["offset"]), int(update.get("update_id", 0)) + 1)
		var chat := ChatProtocols.telegram_chat_of(update)
		if not chat.is_empty() and not _knows_chat(str(chat["id"])):
			found_chats.append(chat)
			out["found"].append(chat)
		if ChatProtocols.wants_rules(update, chats, accept_slash):
			var reply := _rules_reply(update, now)
			if not reply.is_empty():
				out["replies"].append(reply)
		var line := ChatProtocols.telegram_message(update, chats, accept_slash)
		if not line.is_empty():
			out["lines"].append(line)
	return out


func _knows_chat(chat_id: String) -> bool:
	for chat in found_chats:
		if str(chat["id"]) == chat_id:
			return true
	return false


func _rules_reply(update: Dictionary, now: float) -> Dictionary:
	var post: Dictionary = update["message"]
	var chat: Dictionary = post.get("chat", {})
	var chat_id := ChatProtocols._id_text(chat.get("id", ""))
	var private := str(chat.get("type", "")) == "private"
	var gap := float(settings.get("rules_gap_seconds", 60.0))
	if not private and _rules_at.has(chat_id) and now < float(_rules_at[chat_id]) + gap:
		return {}
	_rules_at[chat_id] = now
	var rules := str(settings.get("rules", "")).strip_edges()
	var reply := {"chat_id": chat_id, "text": rules if rules != "" else ChatProtocols.RULES}
	if not private and post.has("message_id"):
		reply["reply_to"] = int(post["message_id"])
	return reply


func _send_next() -> void:
	if _outbox.is_empty() or _send.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	var reply: Dictionary = _outbox.pop_front()
	var form := {"chat_id": reply["chat_id"], "text": reply["text"]}
	if reply.has("reply_to"):
		form["reply_parameters"] = JSON.stringify({"message_id": reply["reply_to"], "allow_sending_without_reply": true})
	_send.timeout = 15.0
	_send.request(url_for("sendMessage", {}), ["Content-Type: application/x-www-form-urlencoded"],
		HTTPClient.METHOD_POST, HTTPClient.new().query_string_from_dict(form))


func _on_sent(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var answer := _answer(result, code, body)
	if not bool(answer["ok"]):
		push_warning("Telegram: could not send the rules: %s" % answer["why"])
	_send_next()


func _on_asked(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	var answer := _answer(result, code, body)
	if not bool(answer["ok"]):
		checked.emit(false, str(answer["why"]))
		return
	var bot: Dictionary = answer["result"] if answer["result"] is Dictionary else {}
	checked.emit(true, "Бот @%s на связи" % str(bot.get("username", "?")))


## `{ok, result, why, wait}` of a Bot API answer: what it returned, or why not in words and how long
## to wait before asking again.
static func answer_of(result: int, code: int, body: PackedByteArray) -> Dictionary:
	if result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "result": null, "why": "Нет связи с Telegram", "wait": 5.0}
	var json := JSON.new()
	var data = json.data if json.parse(body.get_string_from_utf8()) == OK else null
	if code == 401 or code == 404:
		return {"ok": false, "result": null, "why": "Неверный токен бота", "wait": 60.0}
	if code == 409:
		return {"ok": false, "result": null, "why": "Этого бота уже читает другая программа (мост или webhook)", "wait": 60.0}
	if code == 429:
		var after := 5.0
		if data is Dictionary:
			after = float(data.get("parameters", {}).get("retry_after", 5.0))
		return {"ok": false, "result": null, "why": "Telegram просит подождать", "wait": after}
	if not data is Dictionary or not bool(data.get("ok", false)):
		var said := str(data.get("description", "")) if data is Dictionary else ""
		return {"ok": false, "result": null, "why": "Telegram ответил %d %s" % [code, said], "wait": 10.0}
	return {"ok": true, "result": data.get("result"), "why": "", "wait": 0.0}


func _answer(result: int, code: int, body: PackedByteArray) -> Dictionary:
	return answer_of(result, code, body)


func _fail(why: String, wait: float) -> void:
	_failures += 1
	_set_status(STATE_FAILED, why)
	# A lost connection is tried again soon, then less often; a refusal waits as long as it asks.
	_retry_at = _now() + maxf(wait, minf(60.0, pow(2.0, float(mini(_failures, 6)))))


## «Читаю: Заповедник» or what is missing.
func listening_text() -> String:
	var chats: Array = settings.get("chats", [])
	if chats.is_empty():
		return "На связи, но группа не выбрана"
	var names: Array = []
	for chat in chats:
		var title := str(chat.get("title", "")) if chat is Dictionary else ""
		names.append(title if title != "" else ChatProtocols._chat_key(chat))
	return "Читаю: %s" % ", ".join(names)


func _set_status(state: String, text: String) -> void:
	if str(status["state"]) == state and str(status["text"]) == text:
		return
	status = {"state": state, "text": text}
	status_changed.emit()


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
