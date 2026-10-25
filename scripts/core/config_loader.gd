class_name ConfigLoader
extends RefCounted

const CONFIG_FILES := {
	"world": "res://data/config/world.json",
	"species": "res://data/config/species.json",
	"balance": "res://data/config/balance.json",
	"debug": "res://data/config/debug.json",
	"visuals": "res://data/config/visuals.json",
	"powers": "res://data/config/powers.json",
}

const OPTIONS_FILE := "res://data/config/presets.json"
const HELP_FILE := "res://data/config/help.json"
const SCENARIOS_FILE := "res://data/config/scenarios.json"


const RESERVE_FILE := "res://data/config/reserve.json"


## The living reserve's own settings (`reserve.json`): its viewers' commands, votes and funds.
static func load_reserve_config() -> Dictionary:
	return _load_json(RESERVE_FILE)


## The reserve's world: the setup options `reserve.json` `selection` names over the defaults, its
## powers `offered` with the settings `powers` changes, and a `reserve` key, which is what puts its
## saves in the reserve's slots.
static func load_reserve_bundle(reserve: Dictionary) -> Dictionary:
	var selection := default_selection()
	selection.merge(reserve.get("selection", {}), true)
	var bundle := load_config_bundle(selection)
	bundle["powers"]["offered"] = reserve.get("offered", []).duplicate()
	var changed: Dictionary = reserve.get("powers", {})
	for power in changed.keys():
		if bundle["powers"]["powers"].has(power):
			bundle["powers"]["powers"][power].merge(changed[power], true)
	# A species held to a number by births too (`birth_ceilings`): its capacity, the land's (a
	# territory's) or the regulation's, set to that number over its start.
	var ceilings: Dictionary = reserve.get("birth_ceilings", {})
	for species in ceilings.keys():
		var start := float(bundle["world"].get("spawns", {}).get("%s_count" % species, 0))
		if start <= 0.0 or not bundle["species"].has(species):
			continue
		var multiplier := float(ceilings[species]) / start
		bundle["balance"]["population_regulation"]["capacity_multipliers"][species] = multiplier
		if bundle["species"][species].has("territory"):
			bundle["species"][species]["territory"]["capacity_multiplier"] = multiplier
	bundle["reserve"] = {"selection": selection}
	return bundle


## Loads every config file and overlays the chosen setup options.
##
## `selection` maps a group id to an option id; any group it omits falls back to
## that group's declared default, so `load_config_bundle()` with no argument is
## still the plain default world that the headless runners and tests expect.
static func load_config_bundle(selection: Dictionary = {}) -> Dictionary:
	var bundle := {}
	for key in CONFIG_FILES.keys():
		bundle[key] = _load_json(CONFIG_FILES[key])
	_apply_options(bundle, selection)
	return bundle


## `saved`, a bundle a save was made with, drawn as the game draws today: `visuals`, the
## debug overlay switches and developer mode are taken from `shipped`, the bundle the
## save's selection loads now. A save keeps its whole bundle so the world it holds plays
## on the same, but the look is the game's, not the world's: an old save came back with
## the grass tint, the water and the effects of the version that wrote it, or none, and
## animation rows that no longer have to match the atlases. Only `visuals.props` stays as
## saved: the scenery is placed from it. Neither the overlays nor the rest of `visuals`
## reach the simulation; the overlays only choose what the worker ships for them.
static func with_shipped_presentation(saved: Dictionary, shipped: Dictionary) -> Dictionary:
	var bundle: Dictionary = saved.duplicate(true)
	var visuals = shipped.get("visuals")
	if visuals is Dictionary and not visuals.is_empty():
		var drawn: Dictionary = visuals.duplicate(true)
		var saved_visuals = saved.get("visuals")
		if saved_visuals is Dictionary and saved_visuals.has("props"):
			drawn["props"] = saved_visuals["props"].duplicate(true)
		bundle["visuals"] = drawn
	var shipped_debug = shipped.get("debug")
	if shipped_debug is Dictionary and bundle.get("debug") is Dictionary:
		if shipped_debug.get("overlays") is Dictionary:
			bundle["debug"]["overlays"] = shipped_debug["overlays"].duplicate(true)
		# Whether the developer panel is on offer is the installation's choice, not the save's.
		if shipped_debug.has("developer_mode"):
			bundle["debug"]["developer_mode"] = shipped_debug["developer_mode"]
		else:
			bundle["debug"].erase("developer_mode")
	# A save from before the player had powers takes them as shipped: it never had any.
	if not bundle.has("powers") and shipped.get("powers") is Dictionary:
		bundle["powers"] = shipped["powers"].duplicate(true)
	return bundle


## The bundle scenario `scenario_id` is played with (`scenarios.json`): the setup options the
## scenario names over `selection` - so only what it leaves out, the style above all, stays the
## player's - then its `patch` merged over the bundle, new keys and all, and its `challenge`
## under that key, with its id, label, brief and seed. A save keeps the bundle, so the goals and
## powers it was begun with go on whatever the file says later. {} for an unknown id.
static func load_scenario_bundle(scenario_id: String, selection: Dictionary = {}) -> Dictionary:
	var scenario: Dictionary = _load_json(SCENARIOS_FILE).get("scenarios", {}).get(scenario_id, {})
	if scenario.is_empty():
		push_error("Unknown scenario '%s'" % scenario_id)
		return {}
	var chosen := default_selection()
	chosen.merge(selection, true)
	chosen.merge(scenario.get("selection", {}), true)
	var bundle := load_config_bundle(chosen)
	var patch: Dictionary = scenario.get("patch", {})
	for key in patch.keys():
		if bundle.get(key) is Dictionary and patch[key] is Dictionary:
			_merge_into(bundle[key], patch[key].duplicate(true))
		else:
			bundle[key] = patch[key].duplicate(true) if patch[key] is Dictionary else patch[key]
	var challenge: Dictionary = scenario.get("challenge", {}).duplicate(true)
	challenge["id"] = scenario_id
	challenge["label"] = str(scenario.get("label", scenario_id))
	challenge["brief"] = str(scenario.get("brief", ""))
	challenge["seed"] = int(scenario.get("seed", bundle.get("world", {}).get("seed", 1337)))
	challenge["selection"] = chosen
	bundle["challenge"] = challenge
	return bundle


## The scenarios a start page can offer, in the file's declared order: `[{id, label, brief}]`.
static func list_scenarios() -> Array:
	var parsed: Dictionary = _load_json(SCENARIOS_FILE)
	var scenarios: Dictionary = parsed.get("scenarios", {})
	var order: Array = parsed.get("order", [])
	if order.is_empty():
		order = scenarios.keys()
	var listed: Array = []
	for scenario_id in order:
		if not scenarios.has(scenario_id):
			continue
		var scenario: Dictionary = scenarios[scenario_id]
		listed.append({"id": str(scenario_id), "label": str(scenario.get("label", scenario_id)),
			"brief": str(scenario.get("brief", "")), "tutorial": bool(scenario.get("tutorial", false))})
	return listed


## The scenario after `scenario_id` in the page's order, "" after the last or for one not listed:
## what the result window offers next.
static func next_scenario(scenario_id: String) -> String:
	var listed: Array = list_scenarios()
	for index in range(listed.size() - 1):
		if str(listed[index]["id"]) == scenario_id:
			return str(listed[index + 1]["id"])
	return ""


## The option groups a setup screen can offer, in application order.
##
## Returns `[{id, label, default, options: [{id, label}]}]`. Exposing this rather
## than the raw file keeps the UI from having to know the patch format.
static func list_option_groups() -> Array:
	var parsed: Dictionary = _load_options_file()
	var groups: Dictionary = parsed.get("groups", {})
	var listed: Array = []
	for group_id in _group_order(parsed):
		if not groups.has(group_id):
			continue
		var group: Dictionary = groups[group_id]
		var options: Array = []
		for option_id in group.get("options", {}).keys():
			var option: Dictionary = group["options"][option_id]
			options.append({"id": str(option_id), "label": str(option.get("label", option_id))})
		if options.is_empty():
			continue
		listed.append({
			"id": str(group_id),
			"label": str(group.get("label", group_id)),
			"default": str(group.get("default", options[0]["id"])),
			"options": options,
		})
	return listed


## The help screen's sections, in the file's declared order.
##
## Returns `[{id, label, body}]` with `body` as BBCode. Kept out of
## `CONFIG_FILES` on purpose: help text is prose for the reader, not a knob the
## simulation reads, and a headless run has no business loading it.
static func list_help_sections() -> Array:
	var parsed: Dictionary = _load_json(HELP_FILE)
	var sections: Dictionary = parsed.get("sections", {})
	var order: Array = parsed.get("order", [])
	if order.is_empty():
		order = sections.keys()
	var listed: Array = []
	for section_id in order:
		if not sections.has(section_id):
			continue
		var section: Dictionary = sections[section_id]
		listed.append({
			"id": str(section_id),
			"label": str(section.get("label", section_id)),
			"body": str(section.get("body", "")),
		})
	return listed


static func default_selection() -> Dictionary:
	var selection := {}
	for group in list_option_groups():
		selection[group["id"]] = group["default"]
	return selection


## Applies one option from each group, in the file's declared order.
##
## Order is load-bearing: later groups overwrite earlier ones where they touch
## the same key, which is how "no predators" can override whatever the chosen
## species mix said. A patch may reach into `world` or `species`, and doing so
## changes the simulation rather than only its looks.
static func _apply_options(bundle: Dictionary, selection: Dictionary) -> void:
	var parsed: Dictionary = _load_options_file()
	var groups: Dictionary = parsed.get("groups", {})
	for group_id in _group_order(parsed):
		if not groups.has(group_id):
			continue
		var group: Dictionary = groups[group_id]
		var options: Dictionary = group.get("options", {})
		var chosen := str(selection.get(group_id, group.get("default", "")))
		if chosen == "" or not options.has(chosen):
			if chosen != "":
				push_error("Unknown option '%s' for group '%s'; using default" % [chosen, group_id])
			chosen = str(group.get("default", ""))
			if not options.has(chosen):
				continue
		var patch: Dictionary = options[chosen].get("patch", {})
		for key in patch.keys():
			if bundle.has(key) and typeof(patch[key]) == TYPE_DICTIONARY:
				_merge_into(bundle[key], patch[key])


static func _group_order(parsed: Dictionary) -> Array:
	var order: Array = parsed.get("order", [])
	if not order.is_empty():
		return order
	return parsed.get("groups", {}).keys()


static func _load_options_file() -> Dictionary:
	var file := FileAccess.open(OPTIONS_FILE, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Setup options file is not a dictionary: %s" % OPTIONS_FILE)
		return {}
	return parsed


## Deep-merges `patch` into `target`. Dictionaries merge key by key; anything
## else replaces outright, so an array in a patch is the whole new array rather
## than an element-wise blend - which is what a list of atlas slots needs.
static func _merge_into(target: Dictionary, patch: Dictionary) -> void:
	for key in patch.keys():
		if typeof(patch[key]) == TYPE_DICTIONARY and typeof(target.get(key)) == TYPE_DICTIONARY:
			_merge_into(target[key], patch[key])
		else:
			target[key] = patch[key]


static func _load_json(path: String) -> Dictionary:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("Failed to open config: %s" % path)
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("Config is not a dictionary: %s" % path)
		return {}
	return parsed
