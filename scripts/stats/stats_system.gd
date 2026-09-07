class_name StatsSystem
extends RefCounted

var event_bus
var sample_interval_ticks: int = 5
var history_limit: int = 720
var counters := {
	"hunts_started": 0,
	"chases_failed": 0,
	"attack_attempts": 0,
	"hunt_fail_lost_sight": 0,
	"deaths_starvation": 0,
	"deaths_thirst": 0,
	"deaths_predation": 0,
	"deaths_old_age": 0,
	"water_events": 0,
	"grass_events": 0,
	"hunt_success": 0,
	"hunt_fail": 0,
	# Why chases end. `PredationFailed` already carries the reason; without the split, a low
	# hunt success rate says nothing about whether predators lose prey to range, the chase
	# clock, exhaustion, the mate leash, or simply missing.
	"hunt_fail_out_of_range": 0,
	"hunt_fail_timeout": 0,
	"hunt_fail_low_energy": 0,
	"hunt_fail_kin_gap": 0,
	"hunt_fail_miss": 0,
	"carcasses_spawned": 0,
	"carcasses_expired": 0,
	"carcass_consumption_events": 0,
}
var time_series: Array = []
var latest_snapshot: Dictionary = {}
var _step_duration_total_ms: float = 0.0
var _step_duration_max_ms: float = 0.0
var _step_duration_samples: int = 0
# Lifetime totals are kept alongside the windowed ones: the window is what makes a
# regression visible in the charts, the lifetime figures are what benchmark runs compare.
var _step_duration_lifetime_total_ms: float = 0.0
var _step_duration_lifetime_samples: int = 0
var _step_duration_peak_ms: float = 0.0
var _sample_accumulators: Dictionary = {}
## Species ids in registry order, so the snapshot keys come out in a stable order
## run after run. Seeded from the config, not from a hardcoded pair.
var _species_ids: Array = []


## Death and birth tallies are split by species, and by whether the death happened
## in the coarse dormant path. Without the split a predator die-off is
## indistinguishable from a herbivore one, and a dormant-ecology regression is
## invisible. Seeding the keys up front rather than creating them on first use is
## what keeps the snapshot schema - and therefore the CSV columns - fixed for a
## whole run even before anything of a given species has died.
func _seed_species_counters(species_config: Dictionary) -> void:
	_species_ids = species_config.keys()
	_species_ids.sort_custom(func(a, b):
		return int(species_config[a].get("role", {}).get("slot", 0)) < int(species_config[b].get("role", {}).get("slot", 0)))
	for species_id in _species_ids:
		counters["births_%s" % species_id] = 0
		counters["deaths_%s" % species_id] = 0
		for cause in ["starvation", "thirst", "predation", "old_age"]:
			counters["deaths_%s_%s" % [cause, species_id]] = 0
			counters["deaths_%s_%s_dormant" % [cause, species_id]] = 0


func _bump(key: String) -> void:
	counters[key] = int(counters.get(key, 0)) + 1


func initialize(config_bundle: Dictionary, new_event_bus) -> void:
	event_bus = new_event_bus
	var balance_config: Dictionary = config_bundle.get("balance", {})
	var stats_config: Dictionary = balance_config.get("stats", {})
	var debug_config: Dictionary = config_bundle.get("debug", {})
	_seed_species_counters(config_bundle.get("species", {}))
	sample_interval_ticks = int(stats_config.get("sample_interval_ticks", 5))
	history_limit = int(debug_config.get("chart_history_limit", stats_config.get("history_limit", 720)))
	event_bus.event_emitted.connect(_on_event_emitted)
	_reset_sample_accumulators()


func record_step_duration(step_duration_ms: float) -> void:
	_step_duration_total_ms += step_duration_ms
	_step_duration_max_ms = maxf(_step_duration_max_ms, step_duration_ms)
	_step_duration_samples += 1
	_step_duration_lifetime_total_ms += step_duration_ms
	_step_duration_lifetime_samples += 1
	_step_duration_peak_ms = maxf(_step_duration_peak_ms, step_duration_ms)


func record_sample(world, tick: int, time_seconds: float) -> void:
	var perf: Dictionary = world.get_performance_counters()
	_sample_accumulators["dormant_steps_total"] += int(perf.get("dormant_steps", 0))
	_sample_accumulators["dormant_migrations_total"] += int(perf.get("dormant_migrations", 0))
	_sample_accumulators["grass_consumed_total"] += float(perf.get("grass_consumed_total", 0.0))
	_sample_accumulators["herbivore_hunger_reduced_total"] += float(perf.get("herbivore_hunger_reduced_total", 0.0))
	if tick % max(1, sample_interval_ticks) != 0 and tick != 0:
		return
	_write_snapshot(world, tick, time_seconds, perf)


## Rebuilds the snapshot without touching the running totals or the interval.
##
## Loading a save needs exactly this: the interface must stop showing the world
## as it was generated, but the accumulators belong to ticks that have run, and
## feeding them the same counters twice would inflate every lifetime figure.
func refresh_snapshot(world, tick: int, time_seconds: float) -> void:
	_write_snapshot(world, tick, time_seconds, world.get_performance_counters())


func _write_snapshot(world, tick: int, time_seconds: float, perf: Dictionary) -> void:
	var population_metrics: Dictionary = world.get_population_metrics()
	var herbivore_count := int(population_metrics.get("herbivore_count", 0))
	var predator_count := int(population_metrics.get("predator_count", 0))
	var hunger_sum := float(population_metrics.get("hunger_sum", 0.0))
	var energy_sum := float(population_metrics.get("energy_sum", 0.0))
	var living_count := int(population_metrics.get("living_count", 0))
	var active_herbivore_count := int(population_metrics.get("active_herbivore_count", 0))
	var dormant_herbivore_count := int(population_metrics.get("dormant_herbivore_count", 0))
	var active_herbivore_hunger_sum := float(population_metrics.get("active_herbivore_hunger_sum", 0.0))
	var dormant_herbivore_hunger_sum := float(population_metrics.get("dormant_herbivore_hunger_sum", 0.0))
	var active_predator_count := int(population_metrics.get("active_predator_count", 0))
	var dormant_predator_count := int(population_metrics.get("dormant_predator_count", 0))
	var dormant_predator_hunger_sum := float(population_metrics.get("dormant_predator_hunger_sum", 0.0))
	var dormant_predator_thirst_sum := float(population_metrics.get("dormant_predator_thirst_sum", 0.0))
	var dormant_predator_energy_sum := float(population_metrics.get("dormant_predator_energy_sum", 0.0))

	var hunt_total: int = int(counters["hunt_success"]) + int(counters["hunt_fail"])
	var lod_counts: Dictionary = world.get_lod_counts()
	var grass_biomass_by_biome: Dictionary = world.resource_system.get_biomass_totals_by_biome()
	# Always present, even without a clock, so the charts and the HUD never have
	# to branch on whether the climate is running.
	var climate_values: Dictionary = {} if world.climate == null else world.climate.snapshot_values()
	var snapshot: Dictionary = {
		"tick": tick,
		"time_seconds": time_seconds,
		"season": str(climate_values.get("season", "spring")),
		"season_index": int(climate_values.get("season_index", 0)),
		"season_progress": float(climate_values.get("season_progress", 0.0)),
		"day_phase": float(climate_values.get("day_phase", 0.5)),
		"is_night": bool(climate_values.get("is_night", false)),
		"climate_regrowth_multiplier": float(climate_values.get("climate_regrowth_multiplier", 1.0)),
		"deaths_starvation": counters["deaths_starvation"],
		"deaths_thirst": counters["deaths_thirst"],
		"deaths_predation": counters["deaths_predation"],
		"deaths_old_age": counters["deaths_old_age"],
		"average_hunger": 0.0 if living_count == 0 else hunger_sum / living_count,
		"average_energy": 0.0 if living_count == 0 else energy_sum / living_count,
		"active_herbivore_count": active_herbivore_count,
		"dormant_herbivore_count": dormant_herbivore_count,
		"active_herbivore_avg_hunger": 0.0 if active_herbivore_count == 0 else active_herbivore_hunger_sum / active_herbivore_count,
		"dormant_herbivore_avg_hunger": 0.0 if dormant_herbivore_count == 0 else dormant_herbivore_hunger_sum / dormant_herbivore_count,
		"starvation_risk_herbivore_count": int(population_metrics.get("starvation_risk_herbivore_count", 0)),
		"active_predator_count": active_predator_count,
		"dormant_predator_count": dormant_predator_count,
		"dormant_predator_avg_hunger": 0.0 if dormant_predator_count == 0 else dormant_predator_hunger_sum / dormant_predator_count,
		"dormant_predator_avg_thirst": 0.0 if dormant_predator_count == 0 else dormant_predator_thirst_sum / dormant_predator_count,
		"dormant_predator_avg_energy": 0.0 if dormant_predator_count == 0 else dormant_predator_energy_sum / dormant_predator_count,
		"hunt_success_rate": 0.0 if hunt_total == 0 else float(counters["hunt_success"]) / hunt_total,
		"hunt_fail_out_of_range": counters["hunt_fail_out_of_range"],
		"hunt_fail_timeout": counters["hunt_fail_timeout"],
		"hunt_fail_low_energy": counters["hunt_fail_low_energy"],
		"hunt_fail_kin_gap": counters["hunt_fail_kin_gap"],
		"hunt_fail_miss": counters["hunt_fail_miss"],
		"grass_total_biomass": world.resource_system.get_total_biomass(),
		"grass_regrowing_cells": world.resource_system.get_regrowing_cell_count(),
		"grass_biomass_by_biome": grass_biomass_by_biome,
		"active_carcasses": world.get_active_carcass_count(),
		"carcass_meat_remaining_total": world.get_total_carcass_meat_remaining(),
		"carcasses_spawned": counters["carcasses_spawned"],
		"carcasses_expired": counters["carcasses_expired"],
		"carcass_consumption_events": counters["carcass_consumption_events"],
		"blocked_cell_ratio": 0.0 if world.terrain_system == null else world.terrain_system.get_blocked_cell_ratio(),
		"sim_step_ms_avg": 0.0 if _step_duration_samples == 0 else _step_duration_total_ms / _step_duration_samples,
		"sim_step_ms_max": _step_duration_max_ms,
		"sim_step_ms_lifetime_avg": 0.0 if _step_duration_lifetime_samples == 0 else _step_duration_lifetime_total_ms / _step_duration_lifetime_samples,
		"sim_step_ms_peak": _step_duration_peak_ms,
		"lod0_agents": int(lod_counts.get("lod0_agents", living_count)),
		"lod1_agents": int(lod_counts.get("lod1_agents", 0)),
		"lod2_agents": int(lod_counts.get("lod2_agents", 0)),
		"agents_full_tick": int(perf.get("agents_full_tick", 0)),
		"agents_maintenance_tick": int(perf.get("agents_maintenance_tick", 0)),
		"ai_context_build_ms": float(perf.get("ai_context_build_ms", 0.0)),
		"action_select_ms": float(perf.get("action_select_ms", 0.0)),
		"pathfind_calls": int(perf.get("pathfind_calls", 0)),
		"path_cache_hits": int(perf.get("path_cache_hits", 0)),
		"pathfind_ms": float(perf.get("pathfind_ms", 0.0)),
		"grass_query_calls": int(perf.get("grass_query_calls", 0)),
		"grass_search_ms": float(perf.get("grass_search_ms", 0.0)),
		"grass_search_calls": int(perf.get("grass_search_calls", 0)),
		"grass_cells_scanned": int(perf.get("grass_cells_scanned", 0)),
		"phase_resources_ms": float(perf.get("phase_resources_ms", 0.0)),
		"phase_agents_ms": float(perf.get("phase_agents_ms", 0.0)),
		"phase_dormant_ms": float(perf.get("phase_dormant_ms", 0.0)),
		"phase_sectors_ms": float(perf.get("phase_sectors_ms", 0.0)),
		"grass_target_budget_misses": int(perf.get("grass_target_budget_misses", 0)),
		"agent_query_calls": int(perf.get("agent_query_calls", 0)),
		"water_query_calls": int(perf.get("water_query_calls", 0)),
		"carcass_query_calls": int(perf.get("carcass_query_calls", 0)),
		"spatial_update_ms": float(perf.get("spatial_update_ms", 0.0)),
		"group_center_lookups": int(perf.get("group_center_lookups", 0)),
		"sector_wakeups": int(perf.get("sector_wakeups", 0)),
		"dormant_sectors": world.get_dormant_sector_count(),
		"dormant_agents": world.get_dormant_agent_count(),
		"dormant_steps": int(perf.get("dormant_steps", 0)),
		"dormant_migrations": int(perf.get("dormant_migrations", 0)),
		"dormant_forced_wakeups": int(perf.get("dormant_forced_wakeups", 0)),
		"dormant_goal_refreshes": int(perf.get("dormant_goal_refreshes", 0)),
		"dormant_stale_sectors": int(perf.get("dormant_stale_sectors", 0)),
		"grass_consumed": float(perf.get("grass_consumed_total", 0.0)),
		"herbivore_hunger_reduced": float(perf.get("herbivore_hunger_reduced_total", 0.0)),
		"dormant_steps_total": int(_sample_accumulators.get("dormant_steps_total", 0)),
		"dormant_migrations_total": int(_sample_accumulators.get("dormant_migrations_total", 0)),
		"grass_consumed_total": float(_sample_accumulators.get("grass_consumed_total", 0.0)),
		"herbivore_hunger_reduced_total": float(_sample_accumulators.get("herbivore_hunger_reduced_total", 0.0)),
	}
	# The per-species half of the snapshot, built from the same ids the counters
	# were seeded with. Names match what the two hand-written species produced, so
	# the charts, the HUD, the CSV and check_save.gd all keep reading what they read.
	for species_id in _species_ids:
		snapshot["%s_population" % species_id] = int(population_metrics.get("%s_count" % species_id, 0))
		snapshot["births_%s" % species_id] = counters.get("births_%s" % species_id, 0)
		snapshot["deaths_%s" % species_id] = counters.get("deaths_%s" % species_id, 0)
		for cause in ["starvation", "thirst", "predation", "old_age"]:
			var detail_key: String = "deaths_%s_%s" % [cause, species_id]
			snapshot[detail_key] = counters.get(detail_key, 0)
			snapshot["%s_dormant" % detail_key] = counters.get("%s_dormant" % detail_key, 0)
		for field in ["active_%s_count", "dormant_%s_count", "active_%s_hunger_sum",
				"dormant_%s_hunger_sum", "dormant_%s_thirst_sum", "dormant_%s_energy_sum",
				"starvation_risk_%s_count"]:
			var key: String = field % species_id
			snapshot[key] = population_metrics.get(key, 0)
		var active: int = int(population_metrics.get("active_%s_count" % species_id, 0))
		var dormant: int = int(population_metrics.get("dormant_%s_count" % species_id, 0))
		snapshot["active_%s_avg_hunger" % species_id] = 0.0 if active == 0 else float(population_metrics.get("active_%s_hunger_sum" % species_id, 0.0)) / active
		snapshot["dormant_%s_avg_hunger" % species_id] = 0.0 if dormant == 0 else float(population_metrics.get("dormant_%s_hunger_sum" % species_id, 0.0)) / dormant
		snapshot["dormant_%s_avg_thirst" % species_id] = 0.0 if dormant == 0 else float(population_metrics.get("dormant_%s_thirst_sum" % species_id, 0.0)) / dormant
		snapshot["dormant_%s_avg_energy" % species_id] = 0.0 if dormant == 0 else float(population_metrics.get("dormant_%s_energy_sum" % species_id, 0.0)) / dormant
	for key in ["hunts_started", "chases_failed", "attack_attempts", "hunt_fail_lost_sight"]:
		snapshot[key] = counters[key]
	snapshot["chase_success_rate"] = float(counters.hunt_success) / maxf(1.0, float(counters.hunt_success + counters.chases_failed))
	for key in ["visibility_checks", "local_path_searches", "stuck_agents"]:
		snapshot[key] = perf.get(key, 0)
	latest_snapshot = snapshot
	time_series.append(snapshot)
	while time_series.size() > history_limit:
		time_series.pop_front()
	_reset_sample_accumulators()


func get_snapshot() -> Dictionary:
	return latest_snapshot.duplicate(true)


func get_series() -> Array:
	return time_series.duplicate(false)


func shutdown() -> void:
	if event_bus != null and event_bus.event_emitted.is_connected(_on_event_emitted):
		event_bus.event_emitted.disconnect(_on_event_emitted)
	event_bus = null
	time_series.clear()
	latest_snapshot.clear()
	_reset_sample_accumulators()


func _reset_sample_accumulators() -> void:
	_step_duration_total_ms = 0.0
	_step_duration_max_ms = 0.0
	_step_duration_samples = 0
	_sample_accumulators = {
		"dormant_steps_total": 0,
		"dormant_migrations_total": 0,
		"grass_consumed_total": 0.0,
		"herbivore_hunger_reduced_total": 0.0,
	}


## Per-species (and, for predators, per-dormancy) death tallies live in the same flat
## `counters` dictionary as the aggregate ones, so the key is composed rather than
## matched. Unknown combinations are ignored instead of creating keys, which keeps the
## snapshot schema fixed and the CSV columns stable across runs.
func _count_death_detail(cause: String, species: String, is_dormant: bool) -> void:
	if cause == "" or species == "":
		return
	var species_key := "deaths_%s_%s" % [cause, species]
	if counters.has(species_key):
		counters[species_key] += 1
	if not is_dormant:
		return
	var dormant_key := "%s_dormant" % species_key
	if counters.has(dormant_key):
		counters[dormant_key] += 1


func _on_event_emitted(event: Dictionary) -> void:
	var event_type := str(event.get("type", ""))
	var species := str(event.get("species", ""))
	var data: Dictionary = event.get("data", {})

	match event_type:
		"AgentBorn":
			if str(data.get("reason", "")) == "initial":
				return
			# Keyed by species instead of matched against two names. The old
			# if/elif had no else, so a third species' births were counted
			# nowhere at all and nothing said so.
			_bump("births_%s" % species)
		"AgentDied":
			_bump("deaths_%s" % species)
			var cause := str(data.get("cause", ""))
			match cause:
				"starvation":
					counters["deaths_starvation"] += 1
				"thirst":
					counters["deaths_thirst"] += 1
				"predation":
					counters["deaths_predation"] += 1
				"old_age":
					counters["deaths_old_age"] += 1
			_count_death_detail(cause, species, bool(data.get("dormant", false)))
		"HuntStarted":
			counters["hunts_started"] += 1
		"AttackAttempt":
			counters["attack_attempts"] += 1
		"PredationSuccess":
			counters["hunt_success"] += 1
		"PredationFailed":
			counters["hunt_fail"] += 1
			if str(data.get("reason", "")) != "miss":
				counters["chases_failed"] += 1
			var fail_key := "hunt_fail_%s" % str(data.get("reason", ""))
			if counters.has(fail_key):
				counters[fail_key] += 1
		"WaterConsumed":
			counters["water_events"] += 1
		"GrassConsumed":
			counters["grass_events"] += 1
		"CarcassSpawned":
			counters["carcasses_spawned"] += 1
		"CarcassExpired":
			counters["carcasses_expired"] += 1
		"CarcassConsumed":
			counters["carcass_consumption_events"] += 1
