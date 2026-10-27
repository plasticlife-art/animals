extends RefCounted

## The stream's chats the game reads itself and «Трансляция», its wizard: how each chat's messages
## are read (`ChatProtocols`), what each reader does with what its server sends - without a
## network - the settings kept in the game's folder, and the wizard's pages.

const TEST_PATH := "user://test_stream.json"


func run(a) -> void:
	_test_telegram_lines(a)
	_test_rules_asked(a)
	_test_telegram_batch(a)
	_test_telegram_answers(a)
	_test_irc_lines(a)
	_test_twitch_session(a)
	_test_youtube(a)
	_test_video_links(a)
	_test_settings(a)
	_test_chats_started(a)
	_test_wizard(a)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))


static func _update(chat: Dictionary, text: String, user := 7.0, username := "masha") -> Dictionary:
	return {"update_id": 1.0, "message": {"message_id": 5.0, "chat": chat, "text": text,
		"from": {"id": user, "username": username}}}


func _test_telegram_lines(a) -> void:
	var group := {"id": -1001.0, "title": "Заповедник", "type": "supergroup"}
	var chats: Array = [-1001, "@reserve_open"]
	a.equal(ChatProtocols.telegram_message(_update(group, "!имя Ветка"), chats),
		{"platform": "telegram", "user_id": "7", "user": "masha", "text": "!имя Ветка"}, "a command from a group heard, ids as the API means them")
	a.equal(str(ChatProtocols.telegram_message(_update(group, "/имя@ReserveBot Ветка"), chats).get("text", "")), "!имя Ветка",
		"a slash command naming the bot")
	a.equal(str(ChatProtocols.telegram_message(_update({"id": -5.0, "username": "Reserve_Open"}, "!олени"), chats).get("text", "")), "!олени",
		"a group by its @username, whatever its case")
	a.is_true(ChatProtocols.telegram_message(_update({"id": -9.0}, "!олени"), chats).is_empty(), "a chat not listed is not heard")
	a.is_true(ChatProtocols.telegram_message(_update(group, "привет"), chats).is_empty(), "talk is not a command")
	a.is_true(ChatProtocols.telegram_message(_update(group, "/моё"), chats, false).is_empty(), "nor «/» unless asked for")
	var named := {"update_id": 2.0, "message": {"chat": group, "text": "!моё", "from": {"id": 8.0, "first_name": "Аня", "last_name": "К"}}}
	a.equal(str(ChatProtocols.telegram_message(named, chats).get("user", "")), "Аня К", "no username: the name")
	a.is_true(ChatProtocols.chat_heard({"id": -1001.0}, [{"id": "-1001", "title": "Заповедник"}]), "the wizard's groups, kept with their titles")
	a.equal(ChatProtocols.telegram_chat_of(_update(group, "привет")), {"id": "-1001", "title": "Заповедник", "type": "supergroup"},
		"a group found for the wizard")
	a.is_true(ChatProtocols.telegram_chat_of(_update({"id": 7.0, "type": "private"}, "/start")).is_empty(), "a private chat is no group")


func _test_rules_asked(a) -> void:
	var group := {"id": -1001.0, "type": "supergroup"}
	var alone := {"id": 7.0, "type": "private"}
	var chats: Array = [-1001]
	a.is_true(ChatProtocols.wants_rules(_update(group, "!помощь"), chats), "«!помощь» in the group")
	a.is_true(ChatProtocols.wants_rules(_update(group, "/help@ReserveBot"), chats), "/help naming the bot")
	a.is_true(ChatProtocols.wants_rules(_update(alone, "/start"), chats), "a private chat needs no listing")
	a.is_true(ChatProtocols.wants_rules(_update(alone, "/правила"), chats, false), "and always takes «/»")
	a.is_true(not ChatProtocols.wants_rules(_update({"id": -9.0, "type": "group"}, "!помощь"), chats), "a group not heard")
	a.is_true(not ChatProtocols.wants_rules(_update(group, "!олени"), chats), "another command")


func _test_telegram_batch(a) -> void:
	var reader := TelegramChat.new()
	reader.configure({"bot_token": "1:x", "chats": [{"id": "-1001", "title": "Заповедник"}], "rules": "Правила:\n!моё",
		"rules_gap_seconds": 60.0})
	var group := {"id": -1001.0, "title": "Заповедник", "type": "supergroup"}
	var updates: Array = [
		{"update_id": 11.0, "message": {"message_id": 1.0, "chat": group, "text": "!помощь", "from": {"id": 2.0, "username": "a"}}},
		{"update_id": 12.0, "message": {"message_id": 2.0, "chat": group, "text": "/help", "from": {"id": 3.0, "username": "b"}}},
		{"update_id": 13.0, "message": {"message_id": 3.0, "chat": {"id": 2.0, "type": "private"}, "text": "/start", "from": {"id": 2.0}}},
		{"update_id": 14.0, "message": {"message_id": 4.0, "chat": {"id": -42.0, "title": "Чужая", "type": "group"}, "text": "!олени", "from": {"id": 5.0}}},
		{"update_id": 15.0, "message": {"message_id": 5.0, "chat": group, "text": "!олени", "from": {"id": 4.0, "username": "c"}}},
	]
	var taken: Dictionary = reader.handle_updates(updates, 100.0)
	var texts: Array = []
	for line in taken["lines"]:
		texts.append(str(line["text"]))
	a.equal(texts, ["!помощь", "!help", "!олени"], "the group's commands go on, asks for the rules too; another group's do not")
	a.equal(taken["replies"].size(), 2, "one answer in the group for two asks, one in private")
	a.is_true(str(taken["replies"][0]["chat_id"]) == "-1001" and int(taken["replies"][0]["reply_to"]) == 1
		and str(taken["replies"][0]["text"]) == "Правила:\n!моё", "a reply to who asked, with the rules set")
	a.is_true(str(taken["replies"][1]["chat_id"]) == "2" and not taken["replies"][1].has("reply_to"), "privately, no reply")
	a.equal(int(taken["offset"]), 16, "and past them all")
	var found: Array = []
	for chat in reader.found_chats:
		found.append(str(chat["id"]))
	a.equal(found, ["-1001", "-42"], "the groups heard from, for «Найти группу»")
	var later: Dictionary = reader.handle_updates([updates[0]], 100.0 + 61.0)
	a.equal(later["replies"].size(), 1, "a minute on, the group is answered again")
	a.equal(reader.listening_text(), "Читаю: Заповедник", "what it says it reads")
	reader.free()


func _test_telegram_answers(a) -> void:
	var good := TelegramChat.answer_of(HTTPRequest.RESULT_SUCCESS, 200, '{"ok":true,"result":{"username":"ReserveBot"}}'.to_utf8_buffer())
	a.is_true(bool(good["ok"]) and str(good["result"]["username"]) == "ReserveBot", "an answer")
	a.equal(str(TelegramChat.answer_of(HTTPRequest.RESULT_SUCCESS, 401, '{"ok":false}'.to_utf8_buffer())["why"]), "Неверный токен бота",
		"a wrong token, in words")
	a.is_true(str(TelegramChat.answer_of(HTTPRequest.RESULT_SUCCESS, 409, PackedByteArray())["why"]).contains("другая программа"),
		"another reader of the bot")
	var offline := TelegramChat.answer_of(HTTPRequest.RESULT_CANT_CONNECT, 0, PackedByteArray())
	a.is_true(not bool(offline["ok"]) and str(offline["why"]) == "Нет связи с Telegram", "no network")


func _test_irc_lines(a) -> void:
	var parsed := ChatProtocols.parse_irc_line("@badge-info=;display-name=Маша\\sК;user-id=42 :masha!masha@masha.tmi.twitch.tv PRIVMSG #reserve :!олени")
	a.is_true(str(parsed["command"]) == "PRIVMSG" and parsed["params"] == ["#reserve"] and str(parsed["trailing"]) == "!олени"
		and str(parsed["tags"]["display-name"]) == "Маша К", "a tagged message: %s" % str(parsed))
	a.equal(ChatProtocols.twitch_message(parsed), {"platform": "twitch", "user_id": "42", "user": "Маша К", "text": "!олени"},
		"its line")
	var bare := ChatProtocols.twitch_message(ChatProtocols.parse_irc_line(":vasya!vasya@vasya.tmi.twitch.tv PRIVMSG #reserve :!моё"))
	a.is_true(str(bare["user_id"]) == "vasya" and str(bare["user"]) == "vasya", "without tags, the nick")
	var ping := ChatProtocols.parse_irc_line("PING :tmi.twitch.tv")
	a.is_true(str(ping["command"]) == "PING" and str(ping["trailing"]) == "tmi.twitch.tv", "a ping")
	a.is_true(ChatProtocols.parse_irc_line(":tmi.twitch.tv 001 justinfan1 :Welcome").get("trailing") == "Welcome", "a numeric reply")
	a.is_true(ChatProtocols.twitch_message(ChatProtocols.parse_irc_line(":x!x@x PRIVMSG #reserve :привет")).is_empty(), "talk")


func _test_twitch_session(a) -> void:
	var reader := TwitchChat.new()
	reader.configure({"channel": "#Reserve"})
	var hello: Array = reader.greeting()
	a.is_true(str(hello[1]).begins_with("NICK justinfan") and str(hello[-1]) == "JOIN #reserve" and hello.size() == 3,
		"a guest's greeting: %s" % str(hello))
	reader.configure({"channel": "reserve", "oauth_token": "oauth:abc", "nick": "Bot"})
	hello = reader.greeting()
	a.is_true(hello.has("PASS oauth:abc") and hello.has("NICK bot"), "a login for a closed chat")
	a.equal(reader.handle_line("PING :tmi.twitch.tv")["send"], ["PONG :tmi.twitch.tv"], "a ping answered")
	a.is_true(bool(reader.handle_line(":justinfan1!justinfan1@justinfan1.tmi.twitch.tv JOIN #reserve")["joined"]), "the channel joined")
	a.is_true(bool(reader.handle_line(":tmi.twitch.tv RECONNECT")["reconnect"]), "asked to reconnect")
	a.is_true(str(reader.handle_line(":tmi.twitch.tv NOTICE * :Login authentication failed")["error"]).contains("не принял"),
		"a refused login, in words")
	a.equal(str(reader.handle_line("@user-id=9;display-name=Оля :olya!olya@olya.tmi.twitch.tv PRIVMSG #reserve :!1")["line"].get("text", "")),
		"!1", "a vote heard")
	reader.free()


func _test_youtube(a) -> void:
	var item := {"snippet": {"type": "textMessageEvent", "displayMessage": "!лисы"},
		"authorDetails": {"channelId": "UC1", "displayName": "Петя"}}
	a.equal(ChatProtocols.youtube_message(item), {"platform": "youtube", "user_id": "UC1", "user": "Петя", "text": "!лисы"}, "a chat line")
	a.is_true(ChatProtocols.youtube_message({"snippet": {"type": "superChatEvent"}}).is_empty(), "not a text message")
	a.equal(ChatProtocols.youtube_reason('{"error":{"errors":[{"reason":"quotaExceeded"}]}}'), "quotaExceeded", "why it refused")
	a.equal(YouTubeChat.live_chat_of({"items": [{"liveStreamingDetails": {"activeLiveChatId": "chat1"}}]})["chat_id"], "chat1",
		"the live chat found")
	a.is_true(not bool(YouTubeChat.live_chat_of({"items": [{"liveStreamingDetails": {}}]})["ok"]), "no stream on")
	var page := {"items": [item], "nextPageToken": "t2", "pollingIntervalMillis": 5000}
	a.is_true(YouTubeChat.handle_page(page, true)["lines"].is_empty(), "the first page was said before")
	var next: Dictionary = YouTubeChat.handle_page(page, false)
	a.is_true(next["lines"].size() == 1 and str(next["token"]) == "t2" and is_equal_approx(float(next["wait"]), 5.0)
		and not bool(next["over"]), "then its lines, the next page and the wait")
	var quota := YouTubeChat.answer_of(HTTPRequest.RESULT_SUCCESS, 403, '{"error":{"errors":[{"reason":"quotaExceeded"}]}}'.to_utf8_buffer())
	a.is_true(not bool(quota["ok"]) and is_equal_approx(float(quota["wait"]), 600.0), "a spent quota waits ten minutes")


func _test_video_links(a) -> void:
	var cases := {"https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1": "dQw4w9WgXcQ", "https://youtu.be/dQw4w9WgXcQ": "dQw4w9WgXcQ",
		"https://youtube.com/live/abcDEF12345?feature=share": "abcDEF12345", "abcDEF12345": "abcDEF12345", "просто текст": ""}
	for link in cases.keys():
		a.equal(ChatProtocols.video_id_from(str(link)), cases[link], "the video in «%s»" % link)


func _test_settings(a) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	var fresh := StreamSettings.load_settings(TEST_PATH, "")
	a.is_true(not bool(fresh["telegram"]["enabled"]) and fresh["telegram"]["chats"].is_empty() and StreamSettings.ready_chats(fresh).is_empty(),
		"nothing set up at first")
	fresh["telegram"]["enabled"] = true
	fresh["telegram"]["bot_token"] = "1:x"
	fresh["telegram"]["chats"] = [{"id": "-1001", "title": "Заповедник"}]
	fresh["twitch"]["enabled"] = true
	a.is_true(StreamSettings.save_settings(fresh, TEST_PATH), "written")
	var again := StreamSettings.load_settings(TEST_PATH, "")
	a.equal(again["telegram"]["chats"], [{"id": "-1001", "title": "Заповедник"}], "read back")
	a.equal(StreamSettings.ready_chats(again), ["telegram"], "Telegram ready, Twitch on but without a channel")
	var bridge := StreamSettings.from_bridge({"telegram": {"enabled": true, "bot_token": "2:y", "chats": [-1001234567890.0, "@open"],
		"rules": ["a", "b"]}, "twitch": {"enabled": true, "channel": "reserve"}})
	a.is_true(bridge["telegram"]["chats"] == [{"id": "-1001234567890", "title": ""}, {"id": "@open", "title": ""}]
		and str(bridge["telegram"]["rules"]) == "a\nb" and StreamSettings.ready_chats(bridge) == ["telegram", "twitch"],
		"a chat bridge's settings taken over: %s" % str(bridge["telegram"]))


func _test_chats_started(a) -> void:
	var chats := StreamChats.new()
	chats.start(StreamSettings.merged({"telegram": {"enabled": false, "bot_token": "1:x"}, "twitch": {"enabled": true, "channel": ""}}))
	a.is_true(chats.readers.is_empty() and chats.problems().is_empty() and chats.poll().is_empty(), "no reader for a chat off or unready")
	chats.free()


func _test_wizard(a) -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_PATH))
	var wizard := StreamWizard.new()
	wizard.settings_path = TEST_PATH
	wizard.open(false)
	a.is_true(wizard.visible and wizard._pages[0].visible and not wizard._pages[2].visible, "opens on the chats when none is ready")
	wizard._toggles["telegram"]["button"].toggled.emit(true)
	wizard._fields["telegram.bot_token"].text_changed.emit(" 123:abc ")
	a.is_true(bool(wizard._toggles["telegram"]["body"].visible), "Telegram's fields shown once it is on")
	var saved := StreamSettings.load_settings(TEST_PATH, "")
	a.is_true(bool(saved["telegram"]["enabled"]) and str(saved["telegram"]["bot_token"]) == "123:abc", "each change written at once")
	wizard._telegram.found_chats.append({"id": "-1001", "title": "Заповедник", "type": "supergroup"})
	wizard._show_found()
	var add: Button = null
	for row in wizard._found_box.get_children():
		for child in row.get_children():
			if child is Button and child.text == "Добавить":
				add = child
	a.is_true(add != null, "a group found offers «Добавить»")
	if add != null:
		add.pressed.emit()
	a.equal(StreamSettings.load_settings(TEST_PATH, "")["telegram"]["chats"], [{"id": "-1001", "title": "Заповедник"}], "and is heard once added")
	wizard.close()
	var started: Array = []
	wizard.start_requested.connect(func(fresh: bool) -> void: started.append(fresh))
	wizard.open(true)
	a.is_true(wizard._pages[2].visible and wizard._continue.visible, "opens on «Запуск» when a chat is ready, «Продолжить мир» with a save")
	wizard._portrait.toggled.emit(true)
	a.is_true(bool(StreamSettings.load_settings(TEST_PATH, "")["view"]["portrait"]) and wizard._portrait.text.contains("вертикальная"),
		"the picture stood upright, kept")
	a.is_true(wizard._summary.text.contains("Telegram: группы «Заповедник»"), "what is ready: %s" % wizard._summary.text)
	wizard._continue.pressed.emit()
	a.equal(started, [false], "the world goes on")
	var mac := StreamWizard.obs_steps("macOS", "Engine of Ecosystem", ["telegram"])
	var windows := StreamWizard.obs_steps("Windows", "Engine of Ecosystem", [])
	a.is_true(mac.contains("Захват экрана macOS") and mac.contains("Запись экрана") and mac.contains("Настраиваемый")
		and not mac.contains("Сервис «Twitch»") and mac.begins_with("Проще всего — без OBS") and mac.contains("«Экран»"),
		"OBS on a Mac, to Telegram, after the way without it")
	a.is_true(StreamWizard.obs_steps("macOS", "Engine of Ecosystem", ["twitch"], true).contains("1080×1920")
		and not StreamWizard.obs_steps("macOS", "Engine of Ecosystem", ["twitch"]).contains("без OBS"),
		"an upright canvas for an upright picture; no Telegram, no video chat")
	a.is_true(windows.contains("Захват окна") and windows.contains("Windows 10") and windows.contains("Twitch") and windows.contains("YouTube"),
		"on Windows, every platform while none is set up")
	a.is_true(StreamWizard.summary_text(StreamSettings.merged({})).begins_with("Ни один чат не настроен"), "nothing ready, said")
	wizard.free()
