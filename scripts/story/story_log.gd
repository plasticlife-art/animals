class_name StoryLog
extends RefCounted

## What happened to whom and where, as short lines in Russian for the event feed: «Ветка,
## олениха из Стада №3, погибла у Тихой заводи: задрал лис Рыжик», «Пополнение в Стаде №3 на
## Медовом лугу: оленёнок Звёздочка, мать — Ветка», «Стадо №3 разделилось у Лисьего брода: 12
## голов ушли в новое Стадо №8». Places come from the book's `PlaceNames`.
##
## A map holds hundreds of animals, and a line for every birth and death would be a wall of
## text, so only what the player is looking at gets a line of its own: an event in view, in
## the selected animal's herd, or of a pinned animal - its death, its young, its kill. The
## rest is counted, and once a minute a line sums the whole map up («За минуту: хищники —
## 4 оленя · голод — 2 лисы · родились — 6 оленят»). A run of the same thing in one herd
## within a few seconds - three fawns, two deaths from thirst - becomes one line with a
## number. Names come from the `StoryBook` that owns this log, which has heard the event
## first. Nothing here reaches the simulation.

signal changed

const HudTextScript := preload("res://scripts/ui/hud_text.gd")
## Lines kept; the feed shows the newest few.
const CAPACITY := 40
## Seconds within which a line of the same kind, in the same herd, is folded into the last.
const COALESCE_SECONDS := 12.0
## Simulated seconds each map-wide summary covers.
const SUMMARY_SECONDS := 60.0
## Accusative of a new herd: «в новое Стадо №8», «в новую Стаю №2».
const NEW_GROUP := {"herbivore": "новое Стадо", "scavenger": "новую Стаю"}
## Who leaves a group that divides: «5 голов» of a herd, «12 птиц» of a flock.
const MOVED_NOUNS := {"herbivore": ["голова", "головы", "голов"], "scavenger": ["птица", "птицы", "птиц"]}

## Newest first: `{time, text, position, focus_id, pinned, kind, key, count, species, ...}`.
## `position` is `Vector2.INF` for a summary; `focus_id` is the animal a click should select.
var lines: Array = []
## The `StoryBook` this log belongs to, held weakly: the book holds the log, and a strong
## reference back would keep both alive for ever.
var book:
	get:
		return null if _book_ref == null else _book_ref.get_ref()
	set(value):
		_book_ref = null if value == null else weakref(value)
var _book_ref: WeakRef = null
## `{"view": Rect2, "herd": [species, group_id]}` - what the player is looking at - from
## whoever shows the feed. Without it only pinned animals get lines of their own.
var context_provider: Callable = Callable()
var _tally: Dictionary = {}
var _window_start: float = -1.0


func hear(event: Dictionary) -> void:
	var context: Dictionary = context_provider.call() if context_provider.is_valid() else {}
	var data: Dictionary = event.get("data", {})
	var time := float(event.get("time_seconds", 0.0))
	if _window_start < 0.0:
		_window_start = time
	match str(event.get("type", "")):
		"AgentDied":
			_hear_death(event, data, time, context)
		"AgentReproduced":
			_hear_birth(int(event.get("agent_id", -1)), false, time, context, _position_of(event))
		"AgentBorn":
			# An awake birth is told when its parents are known (`AgentReproduced`).
			if str(data.get("reason", "")) == "dormant":
				_hear_birth(int(data.get("record_id", -1)), true, time, context, _position_of(event))
		"HerdSplit":
			_hear_split(event, data, time, context)
		"PondDried", "PondRefilled":
			_hear_pond(str(event.get("type", "")) == "PondDried", int(data.get("index", -1)), time, context,
				_position_of(event))
		"PlayerCommand":
			_hear_player_command(data, time, _position_of(event))


## Closes the minute when it is over: one line for everything that had no line of its own.
func tick(now: float) -> void:
	if _window_start < 0.0:
		_window_start = now
		return
	if now - _window_start < SUMMARY_SECONDS:
		return
	_window_start = now
	if _tally.is_empty():
		return
	var text := summary_text(_tally)
	_tally.clear()
	_add({"time": now, "text": text, "position": Vector2.INF, "focus_id": -1, "pinned": false,
		"kind": "summary", "key": "", "count": 1})


func clear() -> void:
	lines.clear()
	_tally.clear()
	_window_start = -1.0
	changed.emit()


func _hear_death(event: Dictionary, data: Dictionary, time: float, context: Dictionary) -> void:
	var asleep := int(event.get("agent_id", -1)) < 0
	var victim := int(event.get("agent_id", -1)) if not asleep else int(data.get("record_id", -1))
	var species := str(event.get("species", ""))
	var cause := str(data.get("cause", ""))
	var killer: int = book.killer_of(event) if book != null else -1
	var group := int(data.get("group_id", -1))
	var position := _position_of(event)
	var pinned: bool = book != null and (book.is_pinned(victim) or book.is_pinned(killer))
	var remembered: bool = book != null and book.epitaphs.has(victim)
	if victim < 0 or not (pinned or remembered or _in_herd(context, species, group) \
			or (not asleep and _in_view(context, position))):
		_count("deaths:%s:%s" % [cause, species])
		return
	var entry: Dictionary = book.lineage.entry(victim) if book != null else {}
	var sex := str(entry.get("sex", ""))
	var who := "%s, %s%s" % [_name(victim), HudTextScript.animal_noun(species, sex), _from_herd(species, group)]
	var place := _place_of(position)
	# Where it happened; out of view with no name for the place, just «вдали».
	var where := " " + place if place != "" else (" вдали" if asleep else "")
	var text := ""
	if cause == "predation" and killer >= 0:
		var killer_entry: Dictionary = book.lineage.entry(killer) if book != null else {}
		var killer_sex := str(killer_entry.get("sex", ""))
		var killer_species := str(killer_entry.get("species", "predator"))
		text = "%s, %s%s: %s %s %s" % [who, HudTextScript.verb(sex, "погиб", "погибла"), where,
			HudTextScript.verb(killer_sex, "задрал", "задрала"), HudTextScript.animal_noun(killer_species, killer_sex),
			_name(killer)]
	elif cause == "predation":
		text = "%s, %s от хищника%s" % [who, HudTextScript.verb(sex, "погиб", "погибла"), where]
	else:
		text = "%s, %s от %s%s" % [who, HudTextScript.verb(sex, "умер", "умерла"),
			str(HudTextScript.CAUSES_FROM.get(cause, cause)), where]
	# A living killer is the one to look at; otherwise where the body lies.
	var focus := killer if killer >= 0 and book != null and not book.lineage.is_dead(killer) else -1
	# A death worth remembering is told by its epitaph, in gold, and never folded into others.
	if book != null and book.epitaphs.has(victim):
		_add({"time": time, "text": str(book.epitaphs[victim]), "position": position, "focus_id": focus,
			"pinned": true, "kind": "epitaph", "key": "", "count": 1, "species": species, "group": group,
			"cause": cause, "at": place, "agent_id": victim})
		return
	_add({"time": time, "text": text, "position": position, "focus_id": focus, "pinned": pinned,
		"kind": "death", "key": "death:%s:%s:%d" % [cause, species, group], "count": 1, "species": species,
		"group": group, "cause": cause, "at": place})


func _hear_birth(child: int, asleep: bool, time: float, context: Dictionary, position: Vector2) -> void:
	if child < 0 or book == null:
		return
	var entry: Dictionary = book.lineage.entry(child)
	if entry.is_empty():
		return
	var species := str(entry["species"])
	var group := int(entry["group"])
	var mother := int(entry["mother"])
	var father := int(entry["father"])
	var pinned: bool = book.is_pinned(mother) or book.is_pinned(father)
	if not (pinned or _in_herd(context, species, group) or (not asleep and _in_view(context, position))):
		_count("births:%s" % species)
		return
	var young := "%s %s" % [HudTextScript.animal_noun(species, str(entry["sex"]), true), _name(child)]
	var parents := ""
	if mother >= 0 and father >= 0 and HudTextScript.GROUPS.get(species, "") == "":
		parents = ", родители — %s и %s" % [_name(mother), _name(father)]
	elif mother >= 0:
		parents = ", мать — %s" % _name(mother)
	var where := " в %s" % HudTextScript.herd_name(species, group, "prepositional") if group >= 0 else ""
	var place := _place_of(position)
	var text := "%s%s%s: %s%s" % ["Вдали пополнение" if asleep and place == "" else "Пополнение", where,
		" " + place if place != "" else "", young, parents]
	_add({"time": time, "text": text, "position": position, "focus_id": child, "pinned": pinned, "kind": "birth",
		"key": "birth:%s:%d" % [species, group], "count": 1, "species": species, "group": group, "at": place})


func _hear_split(event: Dictionary, data: Dictionary, time: float, context: Dictionary) -> void:
	var species := str(event.get("species", ""))
	var group := int(data.get("group_id", -1))
	var position := _position_of(event)
	if group < 0 or not (_in_herd(context, species, group) or _in_view(context, position)):
		return
	var moved := int(data.get("moved", 0))
	var place := _place_of(position)
	var text := "%s разделилось%s: %d %s %s в %s №%d" % [HudTextScript.herd_name(species, group),
		" " + place if place != "" else "", moved, HudTextScript.plural(moved, MOVED_NOUNS.get(species, MOVED_NOUNS["herbivore"])),
		HudTextScript.plural(moved, ["ушла", "ушли", "ушли"]), str(NEW_GROUP.get(species, "новую группу")),
		HudTextScript.herd_number(int(data.get("new_group_id", -1)))]
	if species == "scavenger":
		text = text.replace("разделилось", "разделилась")
	_add({"time": time, "text": text, "position": position, "focus_id": -1, "pinned": false, "kind": "split",
		"key": "", "count": 1})


## «Тихая заводь пересохла», «В Тихой заводи снова вода» for a pond in view (`WaterSystem`);
## a few drying within seconds fold into «Пересохли Тихая заводь и ещё 3 водоёма». A summer dries
## dozens, so the rest go into the minute's summary, like deaths out of view.
func _hear_pond(dried: bool, index: int, time: float, context: Dictionary, position: Vector2) -> void:
	if book == null or book.places == null or index < 0 or index >= book.places.ponds.size():
		return
	if not _in_view(context, position):
		_count("ponds:dried" if dried else "ponds:refilled")
		return
	var pond: Dictionary = book.places.ponds[index]
	var text := ""
	if dried:
		text = "%s %s" % [pond["name"], HudTextScript.verb3(str(pond.get("gender", "m")), "пересох", "пересохла",
			"пересохло")]
	else:
		text = "%s снова вода" % HudTextScript.capitalized(str(pond.get("in", pond["at"])))
	var kind := "pond_dried" if dried else "pond_refilled"
	_add({"time": time, "text": text, "position": position, "focus_id": -1, "pinned": false, "kind": kind,
		"key": kind, "count": 1, "first": pond["name"]})


## What the player's own orders did, wherever the camera is: «Выкопан водопой: Тихий пруд на
## Медовом лугу». A refused order is the power bar's to explain, not the feed's.
func _hear_player_command(data: Dictionary, time: float, position: Vector2) -> void:
	if not bool(data.get("ok", false)):
		return
	match str(data.get("power", "")):
		"dig_pond":
			var index := int(data.get("index", -1))
			if book == null or book.places == null or index < 0 or index >= book.places.ponds.size():
				return
			var district: int = book.places.district_at(position)
			var where := "" if district < 0 else " " + str(book.places.districts[district]["at"])
			_add({"time": time, "text": "Выкопан водопой: %s%s" % [book.places.ponds[index]["name"], where],
				"position": position, "focus_id": -1, "pinned": false, "kind": "player", "key": "", "count": 1})


## «За минуту: хищники — 4 оленя, 1 тетерев · голод — 2 лисы · родились — 6 оленят».
static func summary_text(tally: Dictionary) -> String:
	var parts: Array = []
	for cause in ["predation", "starvation", "thirst", "old_age"]:
		var counts: Array = []
		for species in ["herbivore", "scavenger", "predator"]:
			var count := int(tally.get("deaths:%s:%s" % [cause, species], 0))
			if count > 0:
				counts.append(HudTextScript.animal_count(species, count))
		if not counts.is_empty():
			var label := "хищники" if cause == "predation" else HudTextScript.cause_label(cause)
			parts.append("%s — %s" % [label, ", ".join(counts)])
	var born: Array = []
	for species in ["herbivore", "scavenger", "predator"]:
		var count := int(tally.get("births:%s" % species, 0))
		if count > 0:
			born.append(HudTextScript.animal_count(species, count, true))
	if not born.is_empty():
		parts.append("родились — %s" % ", ".join(born))
	var ponds := [["ponds:dried", "пересохли"], ["ponds:refilled", "снова с водой"]]
	for pair in ponds:
		var count := int(tally.get(pair[0], 0))
		if count > 0:
			parts.append("%s — %d %s" % [pair[1], count, HudTextScript.plural(count, ["водоём", "водоёма", "водоёмов"])])
	return "За минуту по всей карте: %s" % " · ".join(parts)


## Folds a line into the newest when it is the same kind of thing in the same herd a few
## seconds on, and neither concerns a pinned animal: «Пополнение в Стаде №3: 3 оленёнка».
func _add(line: Dictionary) -> void:
	if not lines.is_empty() and str(line["key"]) != "" and not bool(line["pinned"]):
		var last: Dictionary = lines[0]
		if str(last["key"]) == str(line["key"]) and not bool(last["pinned"]) \
				and float(line["time"]) - float(last["time"]) <= COALESCE_SECONDS:
			last["count"] = int(last["count"]) + 1
			last["time"] = line["time"]
			last["position"] = line["position"]
			last["at"] = line.get("at", "")
			last["text"] = _folded_text(last)
			changed.emit()
			return
	lines.push_front(line)
	while lines.size() > CAPACITY:
		lines.pop_back()
	changed.emit()


static func _folded_text(line: Dictionary) -> String:
	var species := str(line.get("species", ""))
	var group := int(line.get("group", -1))
	var count := int(line["count"])
	if str(line["kind"]) in ["pond_dried", "pond_refilled"]:
		var more := "%s и ещё %d %s" % [line.get("first", ""), count - 1,
			HudTextScript.plural(count - 1, ["водоём", "водоёма", "водоёмов"])]
		return ("Пересохли " if str(line["kind"]) == "pond_dried" else "Снова вода: ") + more
	var at := str(line.get("at", ""))
	var place := " " + at if at != "" else ""
	if str(line["kind"]) == "birth":
		var where := " в %s" % HudTextScript.herd_name(species, group, "prepositional") if group >= 0 else ""
		return "Пополнение%s%s: %s" % [where, place, HudTextScript.animal_count(species, count, true)]
	var herd := HudTextScript.herd_name(species, group) if group >= 0 else HudTextScript.species_label(species)
	var cause := str(line.get("cause", ""))
	var how := "от хищников погибли" if cause == "predation" else "от %s %s" % [
		str(HudTextScript.CAUSES_FROM.get(cause, cause)), "умерли"]
	return "%s%s: %s %s" % [herd, place, how, HudTextScript.animal_count(species, count)]


func _count(key: String) -> void:
	_tally[key] = int(_tally.get(key, 0)) + 1


## «у Тихой заводи», «на Медовом лугу», or "" where the place has no name.
func _place_of(position: Vector2) -> String:
	if book == null or book.places == null:
		return ""
	return book.places.at(position)


func _name(agent_id: int) -> String:
	return book.name_of_id(agent_id) if book != null else "№%d" % agent_id


static func _from_herd(species: String, group: int) -> String:
	if group < 0 or HudTextScript.GROUPS.get(species, "") == "":
		return ""
	return " из %s" % HudTextScript.herd_name(species, group, "genitive")


static func _in_herd(context: Dictionary, species: String, group: int) -> bool:
	var herd: Array = context.get("herd", [])
	return group >= 0 and herd.size() == 2 and str(herd[0]) == species and int(herd[1]) == group


static func _in_view(context: Dictionary, position: Vector2) -> bool:
	var view = context.get("view", null)
	return view is Rect2 and (view as Rect2).has_point(position)


static func _position_of(event: Dictionary) -> Vector2:
	var at: Dictionary = event.get("position", {})
	return Vector2(float(at.get("x", 0.0)), float(at.get("y", 0.0)))
