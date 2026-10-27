class_name StreamSettings
extends RefCounted

## The stream's chats as the admin set them up in «Трансляция» (`StreamWizard`): the Telegram
## bot's token and the groups it hears, the Twitch channel, the YouTube API key and live video. In
## `user://stream.json` - the game's own folder for its user (on a Mac under ~/Library/Application
## Support/Godot/app_userdata, on Windows under %APPDATA%\Godot\app_userdata), never in the
## project, so the keys stay on this computer. When the file is not there yet, a chat bridge's
## `tools/stream_bridge/bridge.json` beside the project is taken over once.

const PATH := "user://stream.json"
const BRIDGE_PATH := "res://tools/stream_bridge/bridge.json"
const DEFAULTS := {
	"telegram": {"enabled": false, "bot_token": "", "chats": [], "accept_slash": true, "rules": "",
		"rules_gap_seconds": 60.0, "poll_seconds": 25},
	"twitch": {"enabled": false, "channel": "", "oauth_token": "", "nick": ""},
	"youtube": {"enabled": false, "api_key": "", "video_id": "", "min_interval_seconds": 8.0},
	## The picture: upright 9:16 for viewers on phones, or lying down 16:9.
	"view": {"portrait": false},
}


## The settings at `path`, every key there (missing ones from `DEFAULTS`).
static func load_settings(path: String = PATH, bridge_path: String = BRIDGE_PATH) -> Dictionary:
	var saved := _read_json(path)
	if saved.is_empty() and bridge_path != "" and FileAccess.file_exists(bridge_path):
		saved = from_bridge(_read_json(bridge_path))
	return merged(saved)


static func save_settings(settings: Dictionary, path: String = PATH) -> bool:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(merged(settings), "  "))
	file.close()
	return true


## `settings` over `DEFAULTS`, a section at a time.
static func merged(settings: Dictionary) -> Dictionary:
	var out := {}
	for section in DEFAULTS.keys():
		var values: Dictionary = DEFAULTS[section].duplicate(true)
		var given = settings.get(section, {})
		if given is Dictionary:
			for key in given.keys():
				values[key] = given[key]
		out[section] = values
	return out


## A chat bridge's settings (`bridge.json`) as these: the same sections, the groups as `{id, title}`.
static func from_bridge(bridge: Dictionary) -> Dictionary:
	if bridge.is_empty():
		return {}
	var out := merged(bridge)
	var chats: Array = []
	for chat in out["telegram"].get("chats", []):
		chats.append(chat if chat is Dictionary else {"id": ChatProtocols._chat_key(chat), "title": ""})
	out["telegram"]["chats"] = chats
	var rules = out["telegram"].get("rules", "")
	out["telegram"]["rules"] = "\n".join(rules) if rules is Array else str(rules)
	return out


## Which chats are on and have what they need to run: `["telegram", "twitch"]`…
static func ready_chats(settings: Dictionary) -> Array:
	var ready: Array = []
	var telegram: Dictionary = settings.get("telegram", {})
	if bool(telegram.get("enabled", false)) and str(telegram.get("bot_token", "")).strip_edges() != "":
		ready.append("telegram")
	var twitch: Dictionary = settings.get("twitch", {})
	if bool(twitch.get("enabled", false)) and str(twitch.get("channel", "")).strip_edges() != "":
		ready.append("twitch")
	var youtube: Dictionary = settings.get("youtube", {})
	if bool(youtube.get("enabled", false)) and str(youtube.get("api_key", "")).strip_edges() != "" \
			and ChatProtocols.video_id_from(str(youtube.get("video_id", ""))) != "":
		ready.append("youtube")
	return ready


static func _read_json(path: String) -> Dictionary:
	if path == "" or not FileAccess.file_exists(path):
		return {}
	var json := JSON.new()
	if json.parse(FileAccess.get_file_as_string(path)) != OK or not json.data is Dictionary:
		return {}
	return json.data
