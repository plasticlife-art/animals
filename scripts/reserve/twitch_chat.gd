class_name TwitchChat
extends Node

## A Twitch channel's chat, read over its IRC with TLS (irc.chat.twitch.tv:6697). Reading needs
## no account: an anonymous `justinfanNNNNN` login, unless an `oauth_token` and `nick` are given
## for a chat closed to guests. Commands come out as `heard` lines; the server's PING is answered,
## RECONNECT and seven minutes of silence start it over. `check()` connects and says whether the
## channel's chat was joined (`checked`).

signal heard(line: Dictionary)
signal checked(ok: bool, text: String)
signal status_changed

const STATE_OFF := "off"
const STATE_STARTING := "starting"
const STATE_OK := "ok"
const STATE_FAILED := "error"
const SILENCE_SECONDS := 420.0
const CHECK_SECONDS := 15.0

var settings: Dictionary = {}
var status := {"state": STATE_OFF, "text": ""}

var _tcp: StreamPeerTCP = null
var _tls: StreamPeerTLS = null
var _buffer := PackedByteArray()
var _running := false
var _greeted := false
var _heard_at := 0.0
var _retry_at := -1.0
var _failures := 0
## While a check is under way, when it gives up.
var _checking_until := -1.0


func configure(new_settings: Dictionary) -> void:
	settings = new_settings.duplicate(true)


func channel() -> String:
	return str(settings.get("channel", "")).strip_edges().to_lower().trim_prefix("#")


func start() -> void:
	if channel() == "":
		_set_status(STATE_FAILED, "Не указан канал")
		return
	_running = true
	_failures = 0
	_connect()


func stop() -> void:
	_running = false
	_checking_until = -1.0
	_retry_at = -1.0
	_close()
	_set_status(STATE_OFF, "")


## Connects, joins and says so through `checked`; leaves it running only if it was.
func check() -> void:
	if channel() == "":
		checked.emit(false, "Впишите имя канала")
		return
	_checking_until = _now() + CHECK_SECONDS
	if not _running:
		_connect()


func _connect() -> void:
	_close()
	_greeted = false
	_buffer = PackedByteArray()
	_heard_at = _now()
	_tcp = StreamPeerTCP.new()
	var host := str(settings.get("host", "irc.chat.twitch.tv"))
	if _tcp.connect_to_host(host, int(settings.get("port", 6697))) != OK:
		_fail("Нет связи с Twitch")
		return
	_tls = null
	_set_status(STATE_STARTING, "Подключаемся к Twitch…")


func _close() -> void:
	if _tls != null:
		_tls.disconnect_from_stream()
	if _tcp != null:
		_tcp.disconnect_from_host()
	_tls = null
	_tcp = null


func _process(_delta: float) -> void:
	if _checking_until >= 0.0 and _now() > _checking_until:
		_checking_until = -1.0
		checked.emit(false, str(status["text"]) if str(status["state"]) == STATE_FAILED else "Twitch не ответил")
		if not _running:
			_close()
	if _tcp == null:
		if _running and _retry_at >= 0.0 and _now() >= _retry_at:
			_retry_at = -1.0
			_connect()
		return
	_tcp.poll()
	var tcp_state := _tcp.get_status()
	if tcp_state == StreamPeerTCP.STATUS_CONNECTING:
		return
	if tcp_state != StreamPeerTCP.STATUS_CONNECTED:
		_fail("Нет связи с Twitch")
		return
	if _tls == null:
		_tls = StreamPeerTLS.new()
		if _tls.connect_to_stream(_tcp, str(settings.get("host", "irc.chat.twitch.tv"))) != OK:
			_fail("Не удалось установить защищённое соединение")
			return
	_tls.poll()
	var tls_state := _tls.get_status()
	if tls_state == StreamPeerTLS.STATUS_HANDSHAKING:
		return
	if tls_state != StreamPeerTLS.STATUS_CONNECTED:
		_fail("Соединение с Twitch прервалось")
		return
	if not _greeted:
		_greeted = true
		_write(greeting())
	var available := _tls.get_available_bytes()
	if available > 0:
		var got: Array = _tls.get_data(available)
		if int(got[0]) == OK:
			_buffer.append_array(got[1])
			_heard_at = _now()
	while true:
		var end := _buffer.find(10)
		if end < 0:
			break
		var line := _buffer.slice(0, end).get_string_from_utf8().strip_edges()
		_buffer = _buffer.slice(end + 1)
		if line != "":
			_take(handle_line(line))
			if _tcp == null:
				return
	if _now() - _heard_at > SILENCE_SECONDS:
		_fail("Twitch молчит семь минут, подключаемся заново")


## The lines that open a session: tags and commands asked for, the login, the channel joined.
func greeting() -> Array:
	var lines: Array = ["CAP REQ :twitch.tv/tags twitch.tv/commands"]
	var oauth := str(settings.get("oauth_token", "")).strip_edges()
	if oauth != "":
		lines.append("PASS oauth:" + oauth.trim_prefix("oauth:"))
		lines.append("NICK " + str(settings.get("nick", "")).to_lower())
	else:
		# Its own generator: the shared one is not the game's to draw from.
		var rng := RandomNumberGenerator.new()
		rng.randomize()
		lines.append("NICK justinfan%d" % rng.randi_range(10000, 99999))
	lines.append("JOIN #" + channel())
	return lines


## What one line from the server comes to: `{send, line, joined, reconnect, error}` - lines to
## answer with, the viewer's command heard ({} if none), whether the channel was joined, whether to
## start over, and why the login failed ("" if it did not).
func handle_line(raw: String) -> Dictionary:
	var parsed := ChatProtocols.parse_irc_line(raw)
	var out := {"send": [], "line": {}, "joined": false, "reconnect": false, "error": ""}
	match str(parsed["command"]):
		"PING":
			out["send"].append("PONG :%s" % (parsed["trailing"] if parsed["trailing"] != null else "tmi.twitch.tv"))
		"RECONNECT":
			out["reconnect"] = true
		"NOTICE":
			if str(parsed["trailing"] if parsed["trailing"] != null else "").to_lower().contains("authentication failed"):
				out["error"] = "Twitch не принял вход: проверьте токен и ник"
		"JOIN":
			out["joined"] = true
		_:
			out["line"] = ChatProtocols.twitch_message(parsed)
	return out


func _take(result: Dictionary) -> void:
	if not result["send"].is_empty():
		_write(result["send"])
	if str(result["error"]) != "":
		_running = false
		_fail(str(result["error"]))
		return
	if bool(result["joined"]):
		_failures = 0
		_set_status(STATE_OK, "Читаю #%s" % channel())
		if _checking_until >= 0.0:
			_checking_until = -1.0
			checked.emit(true, "Чат #%s на связи" % channel())
			if not _running:
				_close()
				_set_status(STATE_OFF, "")
				return
	if bool(result["reconnect"]):
		_fail("Twitch просит подключиться заново")
		return
	if not result["line"].is_empty():
		heard.emit(result["line"])


func _write(lines: Array) -> void:
	if _tls != null:
		_tls.put_data(("\r\n".join(lines) + "\r\n").to_utf8_buffer())


func _fail(why: String) -> void:
	_close()
	_failures += 1
	_set_status(STATE_FAILED, why)
	if _running:
		_retry_at = _now() + minf(60.0, pow(2.0, float(mini(_failures, 6))))


func _set_status(state: String, text: String) -> void:
	if str(status["state"]) == state and str(status["text"]) == text:
		return
	status = {"state": state, "text": text}
	status_changed.emit()


func _now() -> float:
	return float(Time.get_ticks_msec()) / 1000.0
