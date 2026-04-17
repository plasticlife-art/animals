class_name StatsSystem
extends RefCounted

var event_bus
var sample_interval_ticks: int = 5
var history_limit: int = 720
var counters := {
	"births_herbivore": 0,
	"births_predator": 0,
	"deaths_herbivore": 0,
	"deaths_predator": 0,
	"deaths_starvation": 0,
	"deaths_thirst": 0,
	"deaths_predation": 0,
	"deaths_old_age": 0,
	"water_events": 0,
	"grass_events": 0,
	"hunt_success": 0,
	"hunt_fail": 0,
}
var time_series: Array = []
var latest_snapshot: Dictionary = {}
var _step_duration_total_ms: float = 0.0
var _step_duration_max_ms: float = 0.0
var _step_duration_samples: int = 0


func initialize(config_bundle: Dictionary, new_event_bus) -> void:
	event_bus = new_event_bus
	var balance_config: Dictionary = config_bundle.get("balance", {})
	var stats_config: Dictionary = balance_config.get("stats", {})
	var debug_config: Dictionary = config_bundle.get("debug", {})
	sample_interval_ticks = int(stats_config.get("sample_interval_ticks", 5))
	history_limit = int(debug_config.get("chart_history_limit", stats_config.get("history_limit", 720)))
	event_bus.event_emitted.connect(_on_event_emitted)


func record_step_duration(step_duration_ms: float) -> void:
	_step_duration_total_ms += step_duration_ms
	_step_duration_max_ms = maxf(_step_duration_max_ms, step_duration_ms)
	_step_duration_samples += 1


func record_sample(world, tick: int, time_seconds: float) -> void:
	if tick % max(1, sample_interval_ticks) != 0 and tick != 0:
		return

	var herbivore_count := 0
	var predator_count := 0
	var hunger_sum := 0.0
	var energy_sum := 0.0
	var living_count := 0

	for agent in world.get_living_agents():
		if agent == null or not agent.is_alive:
			continue
		living_count += 1
		hunger_sum += agent.hunger
		energy_sum += agent.energy
		if agent.species_type == "herbivore":
			herbivore_count += 1
		elif agent.species_type == "predator":
			predator_count += 1

	var hunt_total: int = int(counters["hunt_success"]) + int(counters["hunt_fail"])
	var lod_counts: Dictionary = world.get_lod_counts()
	var grass_biomass_by_biome := world.resource_system.get_biomass_totals_by_biome()
	var snapshot := {
		"tick": tick,
		"time_seconds": time_seconds,
		"herbivore_population": herbivore_count,
		"predator_population": predator_count,
		"births_herbivore": counters["births_herbivore"],
		"births_predator": counters["births_predator"],
		"deaths_herbivore": counters["deaths_herbivore"],
		"deaths_predator": counters["deaths_predator"],
		"deaths_starvation": counters["deaths_starvation"],
		"deaths_thirst": counters["deaths_thirst"],
		"deaths_predation": counters["deaths_predation"],
		"deaths_old_age": counters["deaths_old_age"],
		"average_hunger": 0.0 if living_count == 0 else hunger_sum / living_count,
		"average_energy": 0.0 if living_count == 0 else energy_sum / living_count,
		"hunt_success_rate": 0.0 if hunt_total == 0 else float(counters["hunt_success"]) / hunt_total,
		"grass_total_biomass": world.resource_system.get_total_biomass(),
		"grass_biomass_by_biome": grass_biomass_by_biome,
		"blocked_cell_ratio": 0.0 if world.terrain_system == null else world.terrain_system.get_blocked_cell_ratio(),
		"sim_step_ms_avg": 0.0 if _step_duration_samples == 0 else _step_duration_total_ms / _step_duration_samples,
		"sim_step_ms_max": _step_duration_max_ms,
		"lod0_agents": int(lod_counts.get("lod0_agents", living_count)),
		"lod1_agents": int(lod_counts.get("lod1_agents", 0)),
		"lod2_agents": int(lod_counts.get("lod2_agents", 0)),
	}
	latest_snapshot = snapshot
	time_series.append(snapshot)
	while time_series.size() > history_limit:
		time_series.pop_front()


func get_snapshot() -> Dictionary:
	return latest_snapshot.duplicate(true)


func get_series() -> Array:
	return time_series.duplicate(false)


func _on_event_emitted(event: Dictionary) -> void:
	var event_type := str(event.get("type", ""))
	var species := str(event.get("species", ""))
	var data: Dictionary = event.get("data", {})

	match event_type:
		"AgentBorn":
			if str(data.get("reason", "")) == "initial":
				return
			if species == "herbivore":
				counters["births_herbivore"] += 1
			elif species == "predator":
				counters["births_predator"] += 1
		"AgentDied":
			if species == "herbivore":
				counters["deaths_herbivore"] += 1
			elif species == "predator":
				counters["deaths_predator"] += 1
			match str(data.get("cause", "")):
				"starvation":
					counters["deaths_starvation"] += 1
				"thirst":
					counters["deaths_thirst"] += 1
				"predation":
					counters["deaths_predation"] += 1
				"old_age":
					counters["deaths_old_age"] += 1
		"PredationSuccess":
			counters["hunt_success"] += 1
		"PredationFailed":
			counters["hunt_fail"] += 1
		"WaterConsumed":
			counters["water_events"] += 1
		"GrassConsumed":
			counters["grass_events"] += 1
