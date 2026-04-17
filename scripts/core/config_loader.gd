class_name ConfigLoader
extends RefCounted

const CONFIG_FILES := {
	"world": "res://data/config/world.json",
	"species": "res://data/config/species.json",
	"balance": "res://data/config/balance.json",
	"debug": "res://data/config/debug.json",
}


static func load_config_bundle() -> Dictionary:
	var bundle := {}
	for key in CONFIG_FILES.keys():
		bundle[key] = _load_json(CONFIG_FILES[key])
	return bundle


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
