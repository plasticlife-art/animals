extends RefCounted

## The always-on readouts: what the ecology strip says about the land, worked out from
## the stats snapshots, and the Russian words both readouts use.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const EcologyReadoutScript := preload("res://scripts/ui/ecology_readout.gd")
const EcologyStripScript := preload("res://scripts/ui/ecology_strip.gd")
const HudTextScript := preload("res://scripts/ui/hud_text.gd")


func run(a) -> void:
	_test_reference_is_a_minute_back(a)
	_test_trend_holds_inside_the_band(a)
	_test_species_rows_count_risk_and_kills(a)
	_test_grass_is_read_against_what_each_biome_holds(a)
	_test_strip_reads_the_running_world(a)
	_test_words(a)


static func _sample(tick: int, seconds: float, extra: Dictionary = {}) -> Dictionary:
	var sample := {"tick": tick, "time_seconds": seconds}
	sample.merge(extra, true)
	return sample


## "Lately" is the last minute: the newest snapshot a minute or more old. Early on, when
## there is less than a minute behind, it is the oldest there is; alone, nothing.
func _test_reference_is_a_minute_back(a) -> void:
	var series: Array = []
	for second in range(0, 121):
		series.append(_sample(second * 18, float(second)))
	var latest: Dictionary = series[series.size() - 1]
	a.near(float(EcologyReadoutScript.reference_sample(series, latest).time_seconds), 60.0, 0.001,
		"a minute before the newest")
	var young: Array = series.slice(0, 31)
	a.near(float(EcologyReadoutScript.reference_sample(young, young[young.size() - 1]).time_seconds), 0.0, 0.001,
		"half a minute in: the oldest there is")
	a.is_true(EcologyReadoutScript.reference_sample([series[0]], series[0]).is_empty(), "alone: nothing to compare")
	a.is_true(EcologyReadoutScript.reference_sample([], {}).is_empty(), "no series: nothing")


## A population holds steady inside a band of 3% or two animals, whichever is wider.
func _test_trend_holds_inside_the_band(a) -> void:
	a.equal(EcologyReadoutScript.trend(100.0, 100.0), 0, "the same: holding")
	a.equal(EcologyReadoutScript.trend(102.0, 100.0), 0, "two up out of a hundred: holding")
	a.equal(EcologyReadoutScript.trend(103.0, 100.0), 1, "three up: rising")
	a.equal(EcologyReadoutScript.trend(97.0, 100.0), -1, "three down: falling")
	a.equal(EcologyReadoutScript.trend(3.0, 2.0), 0, "one up out of two: holding")
	a.equal(EcologyReadoutScript.trend(0.0, 2.0), -1, "the last two gone: falling")


## Per species: the count and its trend, the hungry and the thirsty as a share of the
## species, and the kills since the reference as a rate per minute.
func _test_species_rows_count_risk_and_kills(a) -> void:
	var reference := _sample(0, 0.0, {"herbivore_population": 190, "deaths_predation_herbivore": 10,
		"predator_population": 20, "deaths_predation_predator": 0})
	var latest := _sample(1080, 60.0, {"herbivore_population": 200, "starvation_risk_herbivore_count": 30,
		"thirst_risk_herbivore_count": 60, "deaths_predation_herbivore": 16,
		"predator_population": 20, "starvation_risk_predator_count": 1, "thirst_risk_predator_count": 0,
		"deaths_predation_predator": 0})
	var rows: Array = EcologyReadoutScript.species_rows(latest, reference, ["herbivore", "predator"])
	a.equal(rows.size(), 2, "a row per species")
	var deer: Dictionary = rows[0]
	a.equal([deer.population, deer.trend, deer.hungry, deer.thirsty, deer.kills], [200, 1, 30, 60, 6],
		"herbivores: count, rising, hungry, thirsty, killed")
	a.equal([deer.hungry_level, deer.thirsty_level, deer.kills_level],
		[EcologyReadoutScript.Level.WARN, EcologyReadoutScript.Level.BAD, EcologyReadoutScript.Level.WARN],
		"15% hungry is worth a look, 30% thirsty is bad, 3% killed a minute is worth a look")
	var foxes: Dictionary = rows[1]
	a.equal([foxes.trend, foxes.hungry_level, foxes.kills_level],
		[0, EcologyReadoutScript.Level.GOOD, EcologyReadoutScript.Level.GOOD], "predators: holding and fine")
	var first: Dictionary = EcologyReadoutScript.species_rows(latest, {}, ["herbivore"])[0]
	a.equal([first.trend, first.kills], [0, 0], "nothing to compare yet: no trend, no kills")


## A biome's grass is its biomass over the most its cells can hold; the strip reports the
## four that grow grass, in a fixed order, and leaves out one that holds none.
func _test_grass_is_read_against_what_each_biome_holds(a) -> void:
	var manager = Helpers.create_manager(631)
	var world = manager.world_state
	var capacity: Dictionary = EcologyReadoutScript.capacity_by_biome(world.resource_system, world.terrain_system)
	var total := 0.0
	for value in capacity.values():
		total += float(value)
	var caps: PackedFloat32Array = world.resource_system.export_caps()
	var expected := 0.0
	for cap in caps:
		expected += cap
	a.near(total, expected, 0.01, "every cap is counted once, under its biome")
	var rows: Array = EcologyReadoutScript.grass_rows({"grass_biomass_by_biome": {"meadow": 25.0, "forest": 80.0}},
		{"meadow": 100.0, "forest": 100.0, "drought": 0.0}, HudTextScript.BIOME_ORDER)
	a.equal(rows.size(), 2, "a biome that holds no grass is left out")
	a.equal([rows[0].id, rows[0].share, rows[0].level], ["meadow", 0.25, EcologyReadoutScript.Level.WARN],
		"a quarter left is worth a look")
	a.equal([rows[1].id, rows[1].level], ["forest", EcologyReadoutScript.Level.GOOD], "most of it left is fine")
	a.equal(EcologyReadoutScript.grass_level(0.15), EcologyReadoutScript.Level.BAD, "a seventh left is bad")
	a.equal(EcologyReadoutScript.grass_level(0.47), EcologyReadoutScript.Level.GOOD, "where a world starts is fine")
	Helpers.destroy_manager(manager)


## The strip reads the world it is shown, before and after the worker takes the world
## over and hands the view a copy.
func _test_strip_reads_the_running_world(a) -> void:
	var manager = Helpers.create_manager(632)
	Helpers.spawn_herd(manager.world_state, Vector2(120.0, 120.0), 4, 0)
	manager.stats_system.refresh_snapshot(manager.world_state, manager.current_tick, manager.simulation_time)
	var strip = EcologyStripScript.new()
	strip.bind_manager(manager)
	var shown: Dictionary = strip.readout()
	var deer := _row(shown, "herbivore")
	a.equal(int(deer.get("population", -1)), manager.world_state.get_population_metrics().get("herbivore_count", -2),
		"the herd is counted")
	a.is_true(not shown.get("grass", []).is_empty(), "and the grass is read")
	a.equal([strip._hunted.get("herbivore"), strip._hunted.get("predator")], [true, false],
		"nothing hunts predators, so their kills column says so")
	manager.enable_interactive_worker()
	var frame: Dictionary = manager._worker.step(manager.tick_duration, manager.current_tick, manager.simulation_time,
		manager._build_lod_context(), -1, false)
	manager._apply_worker_frame(frame)
	shown = strip.readout()
	a.equal(int(_row(shown, "herbivore").get("population", -1)), int(deer.get("population", -2)),
		"through the worker too")
	a.is_true(strip._capacity_world == manager.world_state, "with the grass caps of the copy it is shown")
	strip.free()
	Helpers.destroy_manager(manager)
	var idle = EcologyStripScript.new()
	a.is_true(idle.readout().is_empty(), "with no world it says nothing")
	idle.free()


static func _row(shown: Dictionary, species_id: String) -> Dictionary:
	for row in shown.get("rows", []):
		if row.id == species_id:
			return row
	return {}


func _test_words(a) -> void:
	a.equal(HudTextScript.species_label("predator"), "Хищники", "species")
	a.equal(HudTextScript.group_noun("herbivore"), "Стадо", "a herd")
	a.equal(HudTextScript.group_noun("scavenger"), "Стая", "a flock")
	a.equal(HudTextScript.biome_label("drought"), "Засуха", "biomes")
	a.equal(HudTextScript.cause_label("old_age"), "старость", "causes")
	a.equal(HudTextScript.herd_number(0), 1, "herds are numbered from one")
	a.equal(HudTextScript.ago_text(0.5), "только что", "just now")
	a.equal(HudTextScript.ago_text(40.2), "40 с назад", "seconds")
	a.equal(HudTextScript.ago_text(185.0), "3 мин назад", "minutes")
	a.equal(HudTextScript.ago_text(7300.0), "2 ч назад", "hours")
