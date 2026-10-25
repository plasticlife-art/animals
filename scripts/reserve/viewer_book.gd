class_name ViewerBook
extends RefCounted

## The reserve's viewers (`ReserveSession`), by `platform:user_id`: the name they show, the fund
## they back, when each of their commands was last carried out (for the per-viewer cooldowns of
## `reserve.json`) and when they last spoke (a fund counts its members active since its last
## count). Simulated seconds throughout, so a saved reserve picks up where it stopped.

## `{name, platform, team, last: {kind: time}, seen}` by viewer key.
var viewers: Dictionary = {}


static func key_of(message: Dictionary) -> String:
	return "%s:%s" % [str(message.get("platform", "")), str(message.get("user_id", ""))]


## The viewer `message` comes from, noted as seen at `now`, with the name it shows.
func meet(message: Dictionary, now: float) -> Dictionary:
	var key := key_of(message)
	var viewer: Dictionary = viewers.get(key, {"name": "", "platform": str(message.get("platform", "")),
		"team": "", "last": {}, "seen": now})
	var shown := str(message.get("user", "")).strip_edges()
	if shown != "":
		viewer["name"] = shown
	viewer["seen"] = now
	viewers[key] = viewer
	return viewer


## Seconds until `key` may do `kind` again (0 when it may), with `cooldown` between.
func wait_for(key: String, kind: String, cooldown: float, now: float) -> float:
	var last := float(viewers.get(key, {}).get("last", {}).get(kind, -INF))
	return maxf(0.0, last + cooldown - now)


func note(key: String, kind: String, now: float) -> void:
	if viewers.has(key):
		viewers[key]["last"][kind] = now


func join(key: String, team: String) -> void:
	if viewers.has(key):
		viewers[key]["team"] = team


## Each fund's members active since `since`: `{team: count}`.
func active_teams(since: float) -> Dictionary:
	var counts := {}
	for viewer in viewers.values():
		var team := str(viewer.get("team", ""))
		if team != "" and float(viewer.get("seen", -INF)) >= since:
			counts[team] = int(counts.get(team, 0)) + 1
	return counts


func export_state() -> Dictionary:
	return {"viewers": viewers.duplicate(true)}


func import_state(data: Dictionary) -> void:
	viewers = data.get("viewers", {}).duplicate(true)
