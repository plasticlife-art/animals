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
	"deaths_starvation_herbivore": 0,
	"deaths_starvation_predator": 0,
	"deaths_thirst_herbivore": 0,
	"deaths_thirst_predator": 0,
	"deaths_predation_herbivore": 0,
	"deaths_old_age_herbivore": 0,
	"deaths_old_age_predator": 0,
	"water_events": 0,
	"grass_events": 0,
	"hunt_success": 0,
	"hunt_fail": 0,
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


func initialize(config_bundle: Dictionary, new_event_bus) -> void:
	event_bus = new_event_bus
	var balance_config: Dictionary = config_bundle.get("balance", {})
	var stats_config: Dictionary = balance_config.get("stats", {})
	var debug_config: Dictionary = config_bundle.get("debug", {})
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

	var hunt_total: int = int(counters["hunt_success"]) + int(counters["hunt_fail"])
	var lod_counts: Dictionary = world.get_lod_counts()
	var grass_biomass_by_biome: Dictionary = world.resource_system.get_biomass_totals_by_biome()
	var snapshot: Dictionary = {
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
		"deaths_starvation_herbivore": counters["deaths_starvation_herbivore"],
		"deaths_starvation_predator": counters["deaths_starvation_predator"],
		"deaths_thirst_herbivore": counters["deaths_thirst_herbivore"],
		"deaths_thirst_predator": counters["deaths_thirst_predator"],
		"deaths_predation_herbivore": counters["deaths_predation_herbivore"],
		"deaths_old_age_herbivore": counters["deaths_old_age_herbivore"],
		"deaths_old_age_predator": counters["deaths_old_age_predator"],
		"average_hunger": 0.0 if living_count == 0 else hunger_sum / living_count,
		"average_energy": 0.0 if living_count == 0 else energy_sum / living_count,
		"active_herbivore_count": active_herbivore_count,
		"dormant_herbivore_count": dormant_herbivore_count,
		"active_herbivore_avg_hunger": 0.0 if active_herbivore_count == 0 else active_herbivore_hunger_sum / active_herbivore_count,
		"dormant_herbivore_avg_hunger": 0.0 if dormant_herbivore_count == 0 else dormant_herbivore_hunger_sum / dormant_herbivore_count,
		"starvation_risk_herbivore_count": int(population_metrics.get("starvation_risk_herbivore_count", 0)),
		"hunt_success_rate": 0.0 if hunt_total == 0 else float(counters["hunt_success"]) / hunt_total,
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
			var species_cause_key := "deaths_%s_%s" % [cause, species]
			if counters.has(species_cause_key):
				counters[species_cause_key] += 1
		"PredationSuccess":
			counters["hunt_success"] += 1
		"PredationFailed":
			counters["hunt_fail"] += 1
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
