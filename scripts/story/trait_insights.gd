extends RefCounted

## What the chronicle concludes from the traits' history (`TraitHistory`), for «Выводы» and the
## card beside a trait in «Черты»: a few rules, each a sentence the player can check against the
## charts, said as carefully as the numbers allow.
##
## - selection: a trait moved, and the parents of the young were ahead of the living in that
##   direction, or the hunted behind;
## - cost: a trait fell, and those who died of hunger or thirst had more of it;
## - drift: a trait moved no further than the marker, which nothing selects, or the species was
##   too few to tell chance from choice;
## - trend: a trait moved and none of that explains it;
## - jump: a mean moved a long way between two points, and who died then had it;
## - bottleneck: a species fell to a handful, and its traits are less spread since;
## - race: a hunter and its prey grew faster, or sharper-eyed, together.
##
## Every number is read off the history: the living's means and spread at each point and the
## tallies of who left young and who died of what between them. Nothing here reaches the world.

const TraitsScript := preload("res://scripts/agents/traits.gd")
const HudTextScript := preload("res://scripts/ui/hud_text.gd")

const KINDS := ["selection", "cost", "race", "jump", "bottleneck", "trend", "drift"]
const KIND_LABELS := {"selection": "ОТБОР", "cost": "ЦЕНА", "race": "ГОНКА", "jump": "СКАЧОК",
	"bottleneck": "ГОРЛЫШКО", "trend": "СДВИГ", "drift": "ДРЕЙФ"}
## How far a mean must move from the founders, as a multiplier, to be spoken of.
const MOVED := 0.03
## Fewer than this at the leanest time and chance alone can carry a trait far.
const FEW := 30
## A tally's lean counts once it is this share of the trait's spread, and no less than `MIN_LEAN`.
const LEAN_SHARE := 0.1
const MIN_LEAN := 0.003
## Heard at least so many before a group's lean is told.
const MIN_PARENTS := 20
const MIN_DEAD := 10
## A jump: the mean moves this much between two points, or this share of the spread if more.
const JUMP := 0.025
const JUMP_SHARE := 0.6
## A bottleneck: the count falls to a third of what it was and below `NARROW`, and the spread
## after is at most `NARROWED` of the spread before.
const NARROW := 40
const NARROWED := 0.7
## The causes a death's lean is told for, and how («У съеденных хищниками скорость ниже…»).
const GROUP_WHO := {"parents": "У родителей детёнышей", "predation": "У съеденных хищниками",
	"need": "У умерших от голода и жажды", "old_age": "У умерших от старости", "culled": "У отстрелянных",
	"emigrated": "У ушедших"}
## By `Traits` index; the marker's are never said.
const TRAIT_UP := ["стали быстрее", "стали зорче", "стали прожорливее", "стали жить дольше", "", "стали осторожнее",
	"стали легче переносить жажду", "стали крупнее"]
const TRAIT_DOWN := ["стали медленнее", "стали хуже видеть", "стали экономнее", "стали жить меньше", "", "стали смелее",
	"стали чаще хотеть пить", "стали мельче"]
const ROSE := ["выросла", "выросло", "вырос", "выросло", "выросла", "выросла", "выросла", "вырос"]
const FELL := ["упала", "упало", "упал", "упало", "упала", "упала", "упала", "упал"]


## Every conclusion the history allows, the surest and latest first: `[{kind, species, trait,
## title, detail, confidence (1-3), time, from, to}]`, `trait` a `Traits` index or -1 for the
## species as a whole, `from`/`to` the stretch of time it is about. `species_ids` are the species
## with heredity, `eats` each hunter's prey (`role.eats_species`), `calendar` the world's
## (`[season seconds, seasons a year]`), `name_of` an id's name for the dead a jump tells of.
static func conclude(history, species_ids: Array, eats: Dictionary = {}, calendar: Array = [120.0, 4],
		name_of: Callable = Callable(), lineage = null) -> Array:
	var found: Array = []
	if history == null or history.points.size() < 3:
		return found
	for species_id in species_ids:
		var series := _series(history, str(species_id))
		if series.size() < 3:
			continue
		for index in _told(series):
			var said := _trait_finding(history, str(species_id), index, series, calendar)
			if not said.is_empty():
				found.append(said)
		var jump := _jump(history, str(species_id), series, calendar, name_of, lineage)
		if not jump.is_empty():
			found.append(jump)
		var neck := _bottleneck(history, str(species_id), series)
		if not neck.is_empty():
			found.append(neck)
	found.append_array(_races(history, species_ids, eats, calendar))
	found.sort_custom(func(a, b):
		if int(a["confidence"]) != int(b["confidence"]):
			return int(a["confidence"]) > int(b["confidence"])
		if KINDS.find(a["kind"]) != KINDS.find(b["kind"]):
			return KINDS.find(a["kind"]) < KINDS.find(b["kind"])
		return float(a["time"]) > float(b["time"]))
	return found


## The conclusions about `species_id`'s trait `index`, from `found` (`conclude()`): those that
## name it, then the species' own (a bottleneck).
static func about(found: Array, species_id: String, index: int) -> Array:
	var out: Array = []
	for finding in found:
		if str(finding["species"]) != species_id and not str(finding.get("partner", "")) == species_id:
			continue
		if int(finding["trait"]) == index or int(finding["trait"]) < 0:
			out.append(finding)
	return out


## «4,5 %» for a lean of 0.045, «6 %» for 0.06, «12 %» from ten up.
static func percent(value: float) -> String:
	var tenths := roundi(absf(value) * 1000.0)
	# A space that does not break, so a wrapped line never leaves «%» alone.
	if tenths >= 100 or tenths % 10 == 0:
		return "%d\u00a0%%" % roundi(float(tenths) / 10.0)
	return "%d,%d\u00a0%%" % [tenths / 10, tenths % 10]


## A species' points: `[{time, means, spread, count}]`, oldest first, only those it was in.
static func _series(history, species_id: String) -> Array:
	var out: Array = []
	for point in history.points:
		var means: Array = point["values"].get(species_id, [])
		if means.size() < HudTextScript.CORE_TRAITS:
			continue
		out.append({"time": float(point["time"]), "means": means,
			"spread": point.get("spread", {}).get(species_id, []),
			"count": int(point.get("counts", {}).get(species_id, -1))})
	return out


static func _trait_finding(history, species_id: String, index: int, series: Array, calendar: Array) -> Dictionary:
	var first: Dictionary = series[0]
	var last: Dictionary = series[-1]
	var moved := float(last["means"][index]) - float(first["means"][index])
	var spread: float = history.mean_spread(species_id, index)
	var lean := maxf(MIN_LEAN, spread * LEAN_SHARE)
	var fewest := _fewest(series)
	var marker := _marker_moved(series)
	var span := HudTextScript.age_text(float(last["time"]) - float(first["time"]), calendar)
	var who := _who(species_id)
	var base := {"species": species_id, "trait": index, "time": float(last["time"]),
		"from": float(first["time"]), "to": float(last["time"])}
	if absf(moved) < MOVED:
		# Still near the founders, but swinging wide in a species of a few: chance, not choice.
		var low := INF
		var high := -INF
		for entry in series:
			low = minf(low, float(entry["means"][index]))
			high = maxf(high, float(entry["means"][index]))
		if high - low < 0.08 or fewest < 0 or fewest >= FEW:
			return {}
		return _with(base, "drift", 1 if fewest >= 15 else 2,
			"%s, %s: скорее случайность" % [who, _trait_lower(index)],
			"Среднее качалось от %s до %s, а вид в худшие времена сокращался до %d. Так далеко черта уходит и сама, когда зверей мало." % [
				HudTextScript.percent_change(low), HudTextScript.percent_change(high), fewest])
	var parents: Dictionary = history.differential(species_id, "parents", index)
	var hunted: Dictionary = history.differential(species_id, "predation", index)
	var need := _merged(history.differential(species_id, "starvation", index), history.differential(species_id, "thirst", index))
	var sign := signf(moved)
	var bred := int(parents["count"]) >= MIN_PARENTS and signf(float(parents["diff"])) == sign \
		and absf(float(parents["diff"])) >= lean
	var caught := int(hunted["count"]) >= MIN_DEAD and signf(float(hunted["diff"])) == -sign \
		and absf(float(hunted["diff"])) >= lean
	var starved := moved < 0.0 and int(need["count"]) >= MIN_DEAD and float(need["diff"]) >= lean
	var chance := (fewest >= 0 and fewest < FEW) or (marker >= 0.0 and absf(moved) <= marker * 1.5)
	var title := "%s %s на %s" % [who, TRAIT_UP[index] if moved > 0.0 else TRAIT_DOWN[index], percent(moved)]
	var lines: Array = []
	for told in [["parents", parents, bred], ["predation", hunted, caught], ["need", need, starved]]:
		if bool(told[2]):
			lines.append(_lean_line(str(told[0]), told[1], index))
	var marker_line := "" if marker < 0.0 else "Метка за %s ушла на %s." % [span, percent(marker)]
	if chance and not (bred and caught):
		var why := "Вид сокращался до %d." % fewest if fewest >= 0 and fewest < FEW \
			else "Метка, которую никто не отбирает, ушла почти так же: на %s." % percent(marker)
		return _with(base, "drift", 2 if fewest >= 0 and fewest < 15 else 1,
			"%s, %s: скорее случайность" % [who, _trait_lower(index)],
			"%s за %s. %s Выводы о причине делать рано." % [_moved_words(index, moved), span, why])
	var strength := 0.0
	var heard := 0
	for told in [[parents, bred], [hunted, caught], [need, starved]]:
		if bool(told[1]):
			strength = maxf(strength, absf(float(told[0]["diff"])) / maxf(spread, 0.001))
			heard += int(told[0]["count"])
	var confidence := 1
	if heard >= 150 and strength >= 0.3:
		confidence = 3
	elif heard >= 50:
		confidence = 2
	if starved:
		return _with(base, "cost", confidence, title,
			" ".join(lines + ["Похоже, цена этой черты перевесила пользу.", marker_line]).strip_edges())
	if bred or caught:
		return _with(base, "selection", confidence, title,
			" ".join(lines + [marker_line]).strip_edges())
	return _with(base, "trend", 1, title,
		" ".join(["За %s. Ни родители, ни погибшие заметно не отличались от живых." % span, marker_line]).strip_edges())


## The biggest move of one of `species_id`'s traits between two points, and who died then.
static func _jump(history, species_id: String, series: Array, calendar: Array, name_of: Callable, lineage) -> Dictionary:
	var best := {}
	var best_size := 0.0
	var points: Array = history.points
	for position in range(1, series.size()):
		var before: Dictionary = series[position - 1]
		var after: Dictionary = series[position]
		for index in _told([before, after]):
			var step := float(after["means"][index]) - float(before["means"][index])
			var spread: Array = after["spread"]
			var floor_size := maxf(JUMP, (float(spread[index]) * JUMP_SHARE) if index < spread.size() else 0.0)
			if absf(step) < floor_size or absf(step) < best_size:
				continue
			best_size = absf(step)
			best = {"index": index, "step": step, "from": float(before["time"]), "to": float(after["time"])}
	if best.is_empty():
		return {}
	var index := int(best["index"])
	var step := float(best["step"])
	# The tally the later point heard: who died between the two, and how they leaned.
	var tallies: Dictionary = {}
	for point in points:
		if absf(float(point["time"]) - float(best["to"])) < 0.001:
			tallies = point.get("tallies", {}).get(species_id, {})
			break
	var means: Array = []
	for entry in series:
		if absf(float(entry["time"]) - float(best["from"])) < 0.001:
			means = entry["means"]
	var cause := ""
	var cause_lean := 0.0
	var cause_count := 0
	for group in tallies.keys():
		if group == "parents":
			continue
		var tally: Array = tallies[group]
		var count := int(tally[-1])
		if count <= 0 or index >= means.size():
			continue
		var lean := float(tally[index]) / float(count) - float(means[index])
		# Who took the trait away leaned against the move.
		if signf(lean) == -signf(step) and absf(lean) * count > absf(cause_lean) * cause_count:
			cause = str(group)
			cause_lean = lean
			cause_count = count
	var span := HudTextScript.age_text(float(best["to"]) - float(best["from"]), calendar)
	var title := "%s: %s %s на %s за %s" % [_who(species_id), _trait_lower(index), ROSE[index] if step > 0.0 else FELL[index],
		percent(step), span]
	var detail := "Среднее сдвинулось сильнее, чем обычно за такое время."
	if cause != "":
		var named := _dead_names(lineage, name_of, species_id, cause, float(best["from"]), float(best["to"]))
		detail = "%s %s %s, у них %s %s среднего на %s. Это не отбор, а уход нескольких зверей." % [
			_dead_words(cause, cause_count), _animals_count(species_id, cause_count), "" if named == "" else "(%s)" % named,
			_trait_lower(index), "выше" if cause_lean > 0.0 else "ниже", percent(cause_lean)]
		detail = detail.replace("  ", " ").replace(" ,", ",")
	return {"kind": "jump", "species": species_id, "trait": index, "title": title, "detail": detail,
		"confidence": 2 if cause != "" and cause_count >= 2 else 1, "time": float(best["to"]),
		"from": float(best["from"]), "to": float(best["to"])}


static func _bottleneck(history, species_id: String, series: Array) -> Dictionary:
	var lowest := -1
	var peak_before := 0
	var peak := 0
	for position in range(series.size()):
		var count := int(series[position]["count"])
		if count < 0:
			continue
		peak = maxi(peak, count)
		if lowest < 0 or count < int(series[lowest]["count"]):
			lowest = position
			peak_before = peak
	if lowest <= 0 or lowest >= series.size() - 2:
		return {}
	var fewest := int(series[lowest]["count"])
	if fewest >= NARROW or peak_before < fewest * 3:
		return {}
	var before := _spread_over(series.slice(maxi(0, lowest - 10), lowest))
	var after := _spread_over(series.slice(lowest + 1, mini(series.size(), lowest + 11)))
	if before <= 0.0 or after <= 0.0 or after > before * NARROWED:
		return {}
	var narrowed := 1.0 - after / before
	return {"kind": "bottleneck", "species": species_id, "trait": -1,
		"title": "%s прошли через горлышко: %d из %d" % [_who(species_id), fewest, peak_before],
		"detail": "Разброс черт после этого сжался на %s. Выжившие похожи друг на друга, и их потомки тоже." % percent(narrowed),
		"confidence": 3 if narrowed >= 0.5 else 2, "time": float(series[lowest]["time"]),
		"from": float(series[maxi(0, lowest - 10)]["time"]), "to": float(series[mini(series.size() - 1, lowest + 10)]["time"])}


## A hunter and its prey both faster - or sharper-eyed - over the latter half of the history.
static func _races(history, species_ids: Array, eats: Dictionary, calendar: Array) -> Array:
	var out: Array = []
	for hunter in species_ids:
		for prey in eats.get(hunter, []):
			if not species_ids.has(prey):
				continue
			var hunter_series := _series(history, str(hunter))
			var prey_series := _series(history, str(prey))
			if hunter_series.size() < 6 or prey_series.size() < 6:
				continue
			for index in [TraitsScript.SPEED, TraitsScript.VISION]:
				var hunter_moved := _late_move(hunter_series, index)
				var prey_moved := _late_move(prey_series, index)
				if hunter_moved < 0.02 or prey_moved < 0.02:
					continue
				var since := float(hunter_series[hunter_series.size() / 2]["time"])
				var span := HudTextScript.age_text(float(hunter_series[-1]["time"]) - since, calendar)
				out.append({"kind": "race", "species": str(prey), "partner": str(hunter), "trait": index,
					"title": "%s и %s %s вместе" % [_who(str(prey)), _animals(str(hunter)),
						"ускоряются" if index == TraitsScript.SPEED else "становятся зорче"],
					"detail": "За последние %s: %s %s, %s %s. Кто отстанет, тому достанется меньше." % [span,
						_animals(str(prey)), HudTextScript.percent_change(1.0 + prey_moved),
						_animals(str(hunter)), HudTextScript.percent_change(1.0 + hunter_moved)],
					"confidence": 2, "time": float(hunter_series[-1]["time"]), "from": since,
					"to": float(hunter_series[-1]["time"])})
	return out


## The traits worth a word in `series`: every one its points have, but the marker.
static func _told(series: Array) -> Array:
	var out: Array = []
	var known: int = series[0]["means"].size()
	for entry in series:
		known = mini(known, entry["means"].size())
	for index in range(mini(known, HudTextScript.TRAIT_LABELS.size())):
		if index != TraitsScript.MARKER:
			out.append(index)
	return out


static func _late_move(series: Array, index: int) -> float:
	var middle: Dictionary = series[series.size() / 2]
	return float(series[-1]["means"][index]) - float(middle["means"][index])


static func _spread_over(series: Array) -> float:
	var total := 0.0
	var known := 0
	for entry in series:
		var spread: Array = entry["spread"]
		for index in range(spread.size()):
			if index == TraitsScript.MARKER or float(spread[index]) <= 0.0:
				continue
			total += float(spread[index])
			known += 1
	return 0.0 if known == 0 else total / float(known)


## The fewest the species was at any point, -1 when no point counted it.
static func _fewest(series: Array) -> int:
	var fewest := -1
	for entry in series:
		var count := int(entry["count"])
		if count >= 0 and (fewest < 0 or count < fewest):
			fewest = count
	return fewest


## How far the marker has moved from the founders, -1 when the history has none.
static func _marker_moved(series: Array) -> float:
	var first: Array = series[0]["means"]
	var last: Array = series[-1]["means"]
	if first.size() <= TraitsScript.MARKER or last.size() <= TraitsScript.MARKER:
		return -1.0
	return absf(float(last[TraitsScript.MARKER]) - float(first[TraitsScript.MARKER]))


static func _merged(a: Dictionary, b: Dictionary) -> Dictionary:
	var count := int(a["count"]) + int(b["count"])
	if count == 0:
		return {"diff": 0.0, "count": 0}
	return {"diff": (float(a["diff"]) * int(a["count"]) + float(b["diff"]) * int(b["count"])) / float(count), "count": count}


static func _lean_line(group: String, told: Dictionary, index: int) -> String:
	var count := int(told["count"])
	var who := HudTextScript.plural(count, ["родитель", "родителя", "родителей"] if group == "parents" \
		else ["зверь", "зверя", "зверей"])
	return "%s %s %s, чем у живых, на %s (%d %s)." % [GROUP_WHO[group], _trait_lower(index),
		"выше" if float(told["diff"]) > 0.0 else "ниже", percent(float(told["diff"])), count, who]


static func _moved_words(index: int, moved: float) -> String:
	return "%s %s на %s" % [str(HudTextScript.TRAIT_LABELS[index]), ROSE[index] if moved > 0.0 else FELL[index], percent(moved)]


static func _dead_words(cause: String, count: int) -> String:
	match cause:
		"predation":
			return HudTextScript.plural(count, ["Съеден", "Съедены", "Съедены"])
		"starvation":
			return HudTextScript.plural(count, ["Умер от голода", "Умерли от голода", "Умерли от голода"])
		"thirst":
			return HudTextScript.plural(count, ["Умер от жажды", "Умерли от жажды", "Умерли от жажды"])
		"old_age":
			return HudTextScript.plural(count, ["Умер от старости", "Умерли от старости", "Умерли от старости"])
		"culled":
			return HudTextScript.plural(count, ["Отстрелян", "Отстреляны", "Отстреляны"])
		"emigrated":
			return HudTextScript.plural(count, ["Ушёл", "Ушли", "Ушли"])
	return "Погибли"


## Up to three names of `species_id` that died of `cause` between `from` and `to`, joined.
static func _dead_names(lineage, name_of: Callable, species_id: String, cause: String, from: float, to: float) -> String:
	if lineage == null or not name_of.is_valid():
		return ""
	var ids: Array = []
	var animals: Dictionary = lineage.animals()
	for agent_id in animals:
		var entry: Dictionary = animals[agent_id]
		var died := float(entry["died"])
		if str(entry["species"]) == species_id and str(entry["cause"]) == cause and died > from and died <= to:
			ids.append(int(agent_id))
	if ids.is_empty() or ids.size() > 5:
		return ""
	ids.sort()
	var named: Array = []
	for agent_id in ids.slice(0, 3):
		named.append(str(name_of.call(agent_id)))
	return ", ".join(named) + (" и другие" if ids.size() > 3 else "")


static func _with(base: Dictionary, kind: String, confidence: int, title: String, detail: String) -> Dictionary:
	var out := base.duplicate()
	out["kind"] = kind
	out["confidence"] = confidence
	out["title"] = title
	out["detail"] = detail
	return out


## «Олени», «Лисы»: a species as its animals, capitalised, the subject of a title.
static func _who(species_id: String) -> String:
	var words := HudTextScript.animals_label(species_id)
	return words.substr(0, 1).to_upper() + words.substr(1)


static func _animals(species_id: String) -> String:
	return HudTextScript.animals_label(species_id)


static func _animals_count(species_id: String, count: int) -> String:
	return "%d %s" % [count, HudTextScript.plural(count, ["зверь", "зверя", "зверей"])] if count > 0 else _animals(species_id)


static func _trait_lower(index: int) -> String:
	return str(HudTextScript.TRAIT_LABELS[index]).to_lower()
