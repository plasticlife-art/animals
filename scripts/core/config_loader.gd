class_name ConfigLoader
extends RefCounted

const CONFIG_FILES := {
	"world": "res://data/config/world.json",
	"species": "res://data/config/species.json",
	"balance": "res://data/config/balance.json",
	"debug": "res://data/config/debug.json",
	"visuals": "res://data/config/visuals.json",
}

const OPTIONS_FILE := "res://data/config/presets.json"


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
