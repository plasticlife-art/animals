extends RefCounted

## Hares (`species.hare`, `Hare`, `HareAI`): living alone, foxes' prey and not wolves'; starting in
## clusters; grown hares side by side breed; a hare comes back from a save as a hare; and the
## view has words and names for them.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const ConfigLoaderScript := preload("res://scripts/core/config_loader.gd")
const AnimalNamesScript := preload("res://scripts/story/animal_names.gd")


func run(a) -> void:
	_test_the_species(a)
	_test_clusters(a)
	_test_breeding(a)
	_test_saved(a)


static func _bundle(seed: int, count: int, clusters: int) -> Dictionary:
	var bundle: Dictionary = Helpers.build_large_sector_bundle(seed)
	bundle["world"]["spawns"]["hare_count"] = count
	bundle["world"]["spawns"]["hare_group_count"] = clusters
	return bundle


func _test_the_species(a) -> void:
	var shipped: Dictionary = ConfigLoaderScript.load_config_bundle()
	a.is_true(shipped["species"]["hare"]["role"]["social"] == "solitary" and int(shipped["world"]["spawns"]["hare_count"]) > 0,
		"hares ship, living alone")
	var manager = Helpers.create_manager_with(_bundle(9961, 6, 2), 9961)
	var registry = manager.world_state.species_registry
	a.is_true(registry.prey_set("predator").has("hare") and not registry.prey_set("wolf").has("hare"),
		"foxes hunt hares, wolves do not")
	var hares: Array = manager.world_state.get_living_agents().filter(func(agent) -> bool: return agent.species_type == "hare")
	a.is_true(hares.size() == 6 and hares.all(func(hare) -> bool: return hare is Hare and int(hare.group_id) == -1),
		"each a Hare, alone")
	a.is_true(not hares[0]._ai_controller._alive_actions().has(AgentAction.JOIN_HERD), "and never looking for a herd")
	a.equal([HudText.animal_count("hare", 5), HudText.animal_noun("hare", "female"), HudText.species_label("hare")],
		["5 зайцев", "зайчиха", "Зайцы"], "named in Russian")
	a.is_true(AnimalNamesScript.LISTS["hare"]["female"].size() >= 40 and AnimalNamesScript.LISTS["hare"]["male"].size() >= 40,
		"with names of their own")
	Helpers.destroy_manager(manager)


func _test_clusters(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9962, 12, 3), 9962)
	var hares: Array = manager.world_state.get_living_agents().filter(func(agent) -> bool: return agent.species_type == "hare")
	var total := 0.0
	for hare in hares:
		var nearest := INF
		for other in hares:
			if other != hare:
				nearest = minf(nearest, hare.position.distance_to(other.position))
		total += nearest
	var mean := total / float(hares.size())
	a.is_true(mean < 300.0, "they start in clusters: the nearest hare %.0f px off on average" % mean)
	Helpers.destroy_manager(manager)


func _test_breeding(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9963, 2, 1), 9963)
	manager.set_lod_enabled(false)
	var world = manager.world_state
	var hares: Array = world.get_living_agents().filter(func(agent) -> bool: return agent.species_type == "hare")
	hares[0].sex = "female"
	hares[1].sex = "male"
	hares[1].position = hares[0].position + Vector2(24.0, 0.0)
	for hare in hares:
		hare.age = 100.0
		hare.reproduction_cooldown = 0.0
		hare.hunger = 0.0
		hare.thirst = 0.0
		hare.energy = 80.0
	var born := 0
	for _tick in range(int(manager.tick_rate * 90.0)):
		manager.step_once()
		born = world.get_living_agents().filter(func(agent) -> bool: return agent.species_type == "hare").size() - 2
		if born > 0:
			break
	a.is_true(born > 0, "grown hares side by side breed (%d young)" % born)
	Helpers.destroy_manager(manager)


func _test_saved(a) -> void:
	var manager = Helpers.create_manager_with(_bundle(9964, 3, 1), 9964)
	var saved: Dictionary = manager.world_state.export_state()
	var loaded = Helpers.create_manager_with(_bundle(9964, 3, 1), 9964)
	loaded.world_state.import_state(saved)
	var hares: Array = loaded.world_state.get_living_agents().filter(func(agent) -> bool: return agent.species_type == "hare")
	a.is_true(hares.size() == 3 and hares.all(func(hare) -> bool: return hare is Hare), "a hare comes back from a save as a hare")
	Helpers.destroy_manager(manager)
	Helpers.destroy_manager(loaded)
