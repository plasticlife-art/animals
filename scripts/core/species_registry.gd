class_name SpeciesRegistry
extends RefCounted

## The set of species the simulation knows about, derived from `species.json`.
##
## Everything that used to ask "is this a herbivore, or else a predator" asks
## this instead. The two-branch form was not merely inflexible: `else` meant
## "predator" in several places, so a third species would have inflated a
## sector's `threat_score`, shared the predators' group-cache slot, and had its
## births counted nowhere at all.
##
## Built once from the config bundle and never mutated afterwards. That is what
## makes it safe for the simulation worker thread and the presentation copy of
## `WorldState` to hold one each - including the loaded scripts, which are
## resolved eagerly here rather than memoised on first use.
##
## Iteration order is `role.slot`, never `Dictionary` key order. A saved world
## rebuilds several structures by index, so an order that depended on JSON
## insertion would be one more way for a loaded run to drift from an
## uninterrupted one.

const DIET_GRASS := "grass"
const DIET_PREY := "prey"
const DIET_CARRION := "carrion"

const SOCIAL_HERD := "herd"
const SOCIAL_PAIR := "pair"
const SOCIAL_SOLITARY := "solitary"

## Sentinel slot for a species whose `role` block omits one. Sorts last, and
## `_assign_slots()` replaces it with a real index.
const UNDECLARED_SLOT := 1 << 20

var _ids: Array = []
var _roles: Dictionary = {}
var _slots: Dictionary = {}
var _prey_sets: Dictionary = {}
var _predator_sets: Dictionary = {}
var _diet_ids: Dictionary = {}
var _threat_ids: Array = []
var _carcass_source_ids: Array = []
var _scripts: Dictionary = {}
var _ai_scripts: Dictionary = {}


static func from_config(species_config: Dictionary):
	var registry = new()
	registry.initialize(species_config)
	return registry


func initialize(species_config: Dictionary) -> void:
	_ids.clear()
	_roles.clear()
	_slots.clear()
	_prey_sets.clear()
	_predator_sets.clear()
	_diet_ids.clear()
	_threat_ids.clear()
	_carcass_source_ids.clear()
	_scripts.clear()
	_ai_scripts.clear()

	var ordered: Array = []
	for species_id in species_config.keys():
		var block: Dictionary = species_config[species_id]
		var role: Dictionary = block.get("role", {})
		if role.is_empty():
			push_error("Species '%s' has no `role` block in species.json" % species_id)
		ordered.append([int(role.get("slot", UNDECLARED_SLOT)), str(species_id), role])
	ordered.sort_custom(_compare_slot_entries)

	for entry in ordered:
		var species_id: String = str(entry[1])
		var role: Dictionary = entry[2]
		_ids.append(species_id)
		_roles[species_id] = role
		_scripts[species_id] = _load_role_script(species_id, role, "script")
		_ai_scripts[species_id] = _load_role_script(species_id, role, "ai")

	_assign_slots(ordered)
	_build_diet_indices()


## Declared slots win, because a save file and the group cache key both travel
## with them. They only have to be unique; a collision or an omission falls back
## to the species' position in the sorted order, which is still stable.
func _assign_slots(ordered: Array) -> void:
	var taken: Dictionary = {}
	var conflicted := false
	for entry in ordered:
		var declared: int = int(entry[0])
		if declared == UNDECLARED_SLOT or taken.has(declared):
			conflicted = true
			break
		taken[declared] = true
	for index in range(_ids.size()):
		var species_id: String = _ids[index]
		_slots[species_id] = index if conflicted else int(ordered[index][0])
	if conflicted:
		push_error("species.json has missing or duplicated `role.slot` values; falling back to declaration order")


func _build_diet_indices() -> void:
	for species_id in _ids:
		var role: Dictionary = _roles[species_id]
		var prey_set: Dictionary = {}
		for prey_id in role.get("eats_species", []):
			var prey_key := str(prey_id)
			if not _roles.has(prey_key):
				push_error("Species '%s' lists unknown prey '%s'" % [species_id, prey_key])
				continue
			prey_set[prey_key] = true
		_prey_sets[species_id] = prey_set

		var diet_key := str(role.get("diet", ""))
		if not _diet_ids.has(diet_key):
			_diet_ids[diet_key] = []
		_diet_ids[diet_key].append(species_id)

		if bool(role.get("is_threat", false)):
			_threat_ids.append(species_id)
		if bool(role.get("leaves_carcass", false)):
			_carcass_source_ids.append(species_id)

	# The reverse index, so "who hunts me" is a lookup rather than a scan over
	# every species' prey list on every perception build.
	for species_id in _ids:
		var predator_set: Dictionary = {}
		for other_id in _ids:
			if (_prey_sets[other_id] as Dictionary).has(species_id):
				predator_set[other_id] = true
		_predator_sets[species_id] = predator_set


func _load_role_script(species_id: String, role: Dictionary, key: String):
	var path := str(role.get(key, ""))
	if path == "":
		return null
	var loaded = load(path)
	if loaded == null:
		push_error("Species '%s' has an unloadable `role.%s`: %s" % [species_id, key, path])
	return loaded


static func _compare_slot_entries(a: Array, b: Array) -> bool:
	if int(a[0]) != int(b[0]):
		return int(a[0]) < int(b[0])
	return str(a[1]) < str(b[1])


## Every species, ordered by slot. Returned live rather than duplicated because
## callers iterate it inside the tick; treat it as read-only.
func ids() -> Array:
	return _ids


func size() -> int:
	return _ids.size()


func has(species_id: String) -> bool:
	return _roles.has(species_id)


func role(species_id: String) -> Dictionary:
	return _roles.get(species_id, {})


## Stable small integer per species. `WorldState._group_cache_key()` packs this
## into a `Vector2i` to stay allocation-free.
func slot(species_id: String) -> int:
	return int(_slots.get(species_id, -1))


func label(species_id: String) -> String:
	return str(role(species_id).get("label", species_id.capitalize()))


func diet(species_id: String) -> String:
	return str(role(species_id).get("diet", ""))


func social(species_id: String) -> String:
	return str(role(species_id).get("social", SOCIAL_SOLITARY))


## Whether this species frightens the ones it hunts, and counts toward a
## sector's `threat_score`. A scavenger eats the dead and is not a threat.
func is_threat(species_id: String) -> bool:
	return bool(role(species_id).get("is_threat", false))


func leaves_carcass(species_id: String) -> bool:
	return bool(role(species_id).get("leaves_carcass", false))


## How old a body may be before this species will not touch it, in seconds.
##
## A hunter takes fresh kills; a carrion feeder takes what is left. Absent means
## no limit, which is what a scavenger declares. Kept in seconds rather than as a
## share of `carcass.ttl_seconds` so that raising the TTL lengthens only the tail
## the scavenger has to itself - a share would widen the predator's window in
## step and hand it the same subsidy.
func carrion_max_age(species_id: String) -> float:
	var value = role(species_id).get("carrion_max_age_seconds", null)
	if value == null:
		return INF
	return maxf(0.0, float(value))


func carcass_meat_multiplier(species_id: String) -> float:
	return maxf(0.0, float(role(species_id).get("carcass_meat_multiplier", 1.0)))


## Species this one hunts, as a set for O(1) membership inside a query filter.
func prey_set(species_id: String) -> Dictionary:
	return _prey_sets.get(species_id, {})


## Species that hunt this one, as a set.
func predator_set(species_id: String) -> Dictionary:
	return _predator_sets.get(species_id, {})


func ids_with_diet(diet_key: String) -> Array:
	return _diet_ids.get(diet_key, [])


func threat_ids() -> Array:
	return _threat_ids


func carcass_source_ids() -> Array:
	return _carcass_source_ids


func make_agent(species_id: String):
	var species_script = _scripts.get(species_id, null)
	if species_script == null:
		push_error("Unknown species type: %s" % species_id)
		return null
	return species_script.new()


func make_ai(species_id: String, balance_config: Dictionary):
	var ai_script = _ai_scripts.get(species_id, null)
	if ai_script == null:
		push_error("Species '%s' has no AI script" % species_id)
		return null
	return ai_script.new(balance_config)
