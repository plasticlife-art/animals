class_name ChatCommands
extends RefCounted

## A viewer's chat line read as a reserve command (`reserve.json` `commands`): «!имя Ветка» is
## `{kind: "adopt", arg: "Ветка"}`, «!2» a vote for the second choice, «!водопой» a steward's
## power; anything else - talk - is `{}`. Case and «ё»/«е» do not matter in the command's word.
## A ward's name is cleaned by `clean_name()`: letters, spaces and hyphens only, at most
## `max_length`, no word from `blocked`, the first letter capital; "" when nothing fit is left.


static func parse(text: String, config: Dictionary) -> Dictionary:
	var line := text.strip_edges()
	if not line.begins_with("!") or line.length() < 2:
		return {}
	var body := line.substr(1).strip_edges()
	var space := body.find(" ")
	var word := (body if space < 0 else body.left(space)).to_lower().replace("ё", "е")
	var arg := "" if space < 0 else body.substr(space + 1).strip_edges()
	if word.is_valid_int():
		return {"kind": "vote", "arg": word}
	var commands: Dictionary = config.get("commands", {})
	for key in commands.keys():
		if str(key).to_lower().replace("ё", "е") == word:
			var kind := str(commands[key])
			if kind.begins_with("team:"):
				return {"kind": "team", "arg": kind.trim_prefix("team:")}
			return {"kind": kind, "arg": arg}
	return {}


static func clean_name(raw: String, config: Dictionary) -> String:
	var names: Dictionary = config.get("names", {})
	var kept := ""
	for index in range(raw.length()):
		var character := raw[index]
		var code := character.unicode_at(0)
		var letter := (code >= 0x41 and code <= 0x5A) or (code >= 0x61 and code <= 0x7A) \
			or (code >= 0x410 and code <= 0x44F) or code == 0x401 or code == 0x451
		if letter or character == "-" or (character == " " and not kept.ends_with(" ")):
			kept += character
	kept = kept.strip_edges().left(int(names.get("max_length", 16))).strip_edges()
	if kept.replace("-", "").replace(" ", "").is_empty():
		return ""
	var lowered := kept.to_lower().replace("ё", "е")
	for blocked in names.get("blocked", []):
		if lowered.contains(str(blocked).to_lower().replace("ё", "е")):
			return ""
	return kept.left(1).to_upper() + kept.substr(1)
