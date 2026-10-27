class_name StreamChats
extends Node

## The stream's chats the game reads itself, as set up in «Трансляция» (`StreamSettings`): a
## reader a chat that is on and has what it needs (`TelegramChat`, `TwitchChat`, `YouTubeChat`).
## `poll()` takes what viewers wrote since the last call, the same lines the chat bridge sends
## (`ViewerLink`); `problems()` is what the admin should see on screen.

const NAMES := {"telegram": "Telegram", "twitch": "Twitch", "youtube": "YouTube"}

var readers: Dictionary = {}
var _heard: Array = []


## Starts a reader for each chat ready in `settings`, stopping any from before.
func start(settings: Dictionary) -> void:
	stop()
	for platform in StreamSettings.ready_chats(settings):
		var reader: Node = _reader_for(str(platform))
		reader.name = NAMES[platform]
		add_child(reader)
		reader.configure(settings[platform])
		reader.heard.connect(func(line: Dictionary) -> void: _heard.append(line))
		readers[platform] = reader
		reader.start()


func stop() -> void:
	for reader in readers.values():
		reader.stop()
		remove_child(reader)
		reader.queue_free()
	readers.clear()


func _reader_for(platform: String) -> Node:
	match platform:
		"telegram":
			return TelegramChat.new()
		"twitch":
			return TwitchChat.new()
	return YouTubeChat.new()


func poll() -> Array:
	var taken := _heard
	_heard = []
	return taken


## `{platform: {state, text}}` of every reader.
func statuses() -> Dictionary:
	var out := {}
	for platform in readers.keys():
		out[platform] = readers[platform].status.duplicate()
	return out


## «Telegram: неверный токен бота»… for the readers that are failing.
func problems() -> Array:
	var out: Array = []
	for platform in readers.keys():
		var status: Dictionary = readers[platform].status
		if str(status.get("state", "")) == "error":
			out.append("%s: %s" % [NAMES[platform], str(status.get("text", ""))])
	return out
