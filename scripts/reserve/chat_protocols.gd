class_name ChatProtocols
extends RefCounted

## How the stream's chats are read, as plain functions over what their servers send: Telegram's
## Bot API updates, Twitch's IRC lines, YouTube's live chat items. Each gives the line a viewer's
## command makes - `{platform, user_id, user, text}`, the shape `ReserveSession.hear()` takes -
## or {} for anything else, only messages that begin with «!» counting. The game's own readers
## (`TelegramChat`, `TwitchChat`, `YouTubeChat`) and the chat bridge (`tools/stream_bridge`,
## where these were first written) read the same way.

const PREFIX := "!"
const MAX_TEXT := 300
## The words that ask the Telegram bot for the rules, after «!» (or «/»).
const RULES_WORDS := ["помощь", "правила", "help", "start"]
## What the bot answers them with, unless the settings say otherwise.
const RULES := "Живой заповедник — мир зверей, которым правит чат. Пишите команды в чат трансляции:\n\n" \
	+ "!имя Ветка — взять под опеку зверя у стада в кадре и дать ему имя (один живой подопечный, раз в 30 с)\n" \
	+ "!моё — камера покажет вашего подопечного\n" \
	+ "!1 !2 !3 — голос за событие: дождь, сушь, стужа, буйная трава, пришлые звери. Голосование открывается каждые 4 минуты на минуту\n" \
	+ "!водопой !повести !отстрел — силы смотрителя для стада в кадре (раз в 3 минуты)\n" \
	+ "!олени !лисы !волки !зайцы — болеть за вид: раз в 5 минут вид, за который болеет больше всех, получает подмогу\n\n" \
	+ "Если вид почти вымер, с края карты сами приходят новые звери."
const TAG_ESCAPES := {"s": " ", ":": ";", "\\": "\\", "r": "\r", "n": "\n"}


## The game's line, or {} for a message that is no command.
static func message(platform: String, user_id, user, text) -> Dictionary:
	var said := str(text if text != null else "").strip_edges()
	if not said.begins_with(PREFIX):
		return {}
	var who := str(user if user != null else "")
	return {"platform": platform, "user_id": str(user_id), "user": who if who != "" else str(user_id),
		"text": said.left(MAX_TEXT)}


## «/моё@ReserveBot Ветка» as «!моё Ветка»; anything else as it was.
static func slash_to_bang(text: String) -> String:
	if not text.begins_with("/"):
		return text
	var body := text.substr(1)
	var space := body.find(" ")
	var command := body if space < 0 else body.left(space)
	var rest := "" if space < 0 else body.substr(space + 1)
	# In a group a command names the bot it is for.
	var at := command.find("@")
	if at >= 0:
		command = command.left(at)
	return PREFIX + command + (" " + rest if rest != "" else "")


# --- Telegram ---------------------------------------------------------------------------------

## Whether a chat is one of `chats` - ids (numbers or strings) or «@username»s.
static func chat_heard(chat: Dictionary, chats: Array) -> bool:
	var wanted := {}
	for entry in chats:
		wanted[_chat_key(entry)] = true
	if wanted.has(_chat_key(chat.get("id", ""))):
		return true
	var username := str(chat.get("username", ""))
	return username != "" and wanted.has("@" + username.to_lower())


static func _chat_key(value) -> String:
	if value is Dictionary:
		value = value.get("id", "")
	if value is float:
		return str(int(value))
	return str(value).to_lower()


## The game's line for a Bot API update from one of `chats`, or {}.
static func telegram_message(update: Dictionary, chats: Array, accept_slash := true) -> Dictionary:
	var post: Dictionary = _post_of(update)
	var chat: Dictionary = post.get("chat", {})
	if not chat_heard(chat, chats):
		return {}
	var text := str(post.get("text", "")).strip_edges()
	if accept_slash:
		text = slash_to_bang(text)
	var sender: Dictionary = post.get("from", {})
	var shown := str(sender.get("username", ""))
	if shown == "":
		shown = " ".join([str(sender.get("first_name", "")), str(sender.get("last_name", ""))]).strip_edges()
	return message("telegram", _id_text(sender.get("id", "")), shown, text)


## Whether an update asks for the rules: «!помощь», «!правила», /help or /start, in one of `chats`
## or in a private chat with the bot (where «/» is always taken).
static func wants_rules(update: Dictionary, chats: Array, accept_slash := true) -> bool:
	var post: Dictionary = _post_of(update)
	var chat: Dictionary = post.get("chat", {})
	var private := str(chat.get("type", "")) == "private"
	if not private and not chat_heard(chat, chats):
		return false
	var text := str(post.get("text", "")).strip_edges()
	if accept_slash or private:
		text = slash_to_bang(text)
	if not text.begins_with(PREFIX):
		return false
	var word := text.substr(1).get_slice(" ", 0).to_lower()
	return RULES_WORDS.has(word)


## A group or channel an update came from, for «Найти группу»: `{id, title, type}`, or {} for a
## private chat or none.
static func telegram_chat_of(update: Dictionary) -> Dictionary:
	var chat: Dictionary = _post_of(update).get("chat", {})
	if chat.is_empty() or str(chat.get("type", "")) == "private":
		return {}
	var title := str(chat.get("title", ""))
	if title == "" and str(chat.get("username", "")) != "":
		title = "@" + str(chat["username"])
	return {"id": _id_text(chat.get("id", "")), "title": title, "type": str(chat.get("type", ""))}


static func _post_of(update: Dictionary) -> Dictionary:
	var post = update.get("message", null)
	return post if post is Dictionary else {}


## An id as the API means it: JSON numbers come back as floats, «-1001234567890.0» is no id.
static func _id_text(value) -> String:
	if value is float:
		return str(int(value))
	return str(value)


# --- Twitch -----------------------------------------------------------------------------------

static func unescape_tag(value: String) -> String:
	var out := ""
	var index := 0
	while index < value.length():
		if value[index] == "\\" and index + 1 < value.length():
			out += str(TAG_ESCAPES.get(value[index + 1], value[index + 1]))
			index += 2
		else:
			out += value[index]
			index += 1
	return out


## `{tags, prefix, command, params, trailing}` of one IRC line (IRCv3 tags included); `trailing`
## is null when the line has none.
static func parse_irc_line(line: String) -> Dictionary:
	var tags := {}
	var rest := line
	if rest.begins_with("@"):
		var space := rest.find(" ")
		var raw := rest.substr(1, space - 1) if space >= 0 else rest.substr(1)
		rest = rest.substr(space + 1) if space >= 0 else ""
		for pair in raw.split(";"):
			var equals := pair.find("=")
			if equals < 0:
				tags[pair] = ""
			else:
				tags[pair.left(equals)] = unescape_tag(pair.substr(equals + 1))
	var prefix := ""
	if rest.begins_with(":"):
		var space := rest.find(" ")
		prefix = rest.substr(1, space - 1) if space >= 0 else rest.substr(1)
		rest = rest.substr(space + 1) if space >= 0 else ""
	var trailing = null
	var colon := rest.find(" :")
	if colon >= 0:
		trailing = rest.substr(colon + 2)
		rest = rest.left(colon)
	elif rest.begins_with(":"):
		trailing = rest.substr(1)
		rest = ""
	var parts: Array = []
	for part in rest.split(" ", false):
		parts.append(part)
	return {"tags": tags, "prefix": prefix, "command": str(parts[0]).to_upper() if not parts.is_empty() else "",
		"params": parts.slice(1), "trailing": trailing}


## The game's line for a PRIVMSG, or {}.
static func twitch_message(parsed: Dictionary) -> Dictionary:
	if str(parsed.get("command", "")) != "PRIVMSG" or parsed.get("trailing") == null:
		return {}
	var nick := str(parsed.get("prefix", "")).get_slice("!", 0)
	var tags: Dictionary = parsed.get("tags", {})
	var user_id := str(tags.get("user-id", ""))
	var shown := str(tags.get("display-name", ""))
	return message("twitch", user_id if user_id != "" else nick, shown if shown != "" else nick, parsed["trailing"])


# --- YouTube ----------------------------------------------------------------------------------

## The game's line for a live chat item, or {}.
static func youtube_message(item: Dictionary) -> Dictionary:
	var snippet: Dictionary = item.get("snippet", {})
	if str(snippet.get("type", "textMessageEvent")) != "textMessageEvent":
		return {}
	var author: Dictionary = item.get("authorDetails", {})
	var text := str(snippet.get("displayMessage", ""))
	if text == "":
		text = str(snippet.get("textMessageDetails", {}).get("messageText", ""))
	var channel := str(author.get("channelId", ""))
	if channel == "":
		channel = str(snippet.get("authorChannelId", ""))
	return message("youtube", channel, author.get("displayName", ""), text)


## Why the API refused, from an error body: «quotaExceeded», «keyInvalid»… "" when it does not say.
static func youtube_reason(body: String) -> String:
	var json := JSON.new()
	if json.parse(body) != OK or not json.data is Dictionary:
		return ""
	var errors = json.data.get("error", {}).get("errors", [])
	if errors is Array and not errors.is_empty() and errors[0] is Dictionary:
		return str(errors[0].get("reason", ""))
	return ""


## The video's id from what the admin pasted: the id itself, or a link - «watch?v=», «youtu.be/»,
## «/live/», «/shorts/». "" when none is in it.
static func video_id_from(text: String) -> String:
	var value := text.strip_edges()
	for marker in ["v=", "youtu.be/", "/live/", "/shorts/", "/embed/"]:
		var at := value.find(marker)
		if at >= 0:
			value = value.substr(at + marker.length())
			break
	for stop in ["&", "?", "/", "#"]:
		var cut := value.find(stop)
		if cut >= 0:
			value = value.left(cut)
	var regex := RegEx.create_from_string("^[A-Za-z0-9_-]{6,20}$")
	return value if regex.search(value) != null else ""
