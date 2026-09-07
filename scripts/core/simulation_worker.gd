class_name SimulationWorker
extends RefCounted

## Exclusive owner of mutable simulation state while an interactive tick runs.
## Only value snapshots cross back to the main thread; no live agents are shared.
var world: WorldState
var stats: StatsSystem
var events: EventBus
var random: RandomNumberGenerator
var pending_events: Array = []

func configure(source_world: WorldState, source_stats: StatsSystem, source_events: EventBus, source_rng: RandomNumberGenerator) -> void:
	world = source_world
	stats = source_stats
	events = source_events
	random = source_rng
	events.event_emitted.connect(_collect_event)

func _collect_event(event: Dictionary) -> void:
	pending_events.append(event)

func step(delta: float, tick: int, time: float, lod: Dictionary, inspected_id: int) -> Dictionary:
	pending_events.clear()
	world.inspected_agent_id = inspected_id
	var start := Time.get_ticks_usec()
	world.step(delta, tick, time, lod)
	var elapsed := (Time.get_ticks_usec() - start) / 1000.0
	stats.record_step_duration(elapsed)
	stats.record_sample(world, tick + 1, time + delta)
	var records: Array = []
	for agent in world.living_agents:
		var record: Dictionary = agent.export_runtime_state()
		if agent.id == inspected_id:
			record["last_action_reason"] = agent.last_action_reason
			record["last_action_scores"] = agent.last_action_scores.duplicate()
			record["last_action_raw_scores"] = agent.last_action_raw_scores.duplicate()
		records.append(record)
	var sectors := {}
	for key in world._sector_states:
		var sector: Dictionary = world._sector_states[key]
		sectors[key] = {"dormant": sector.get("dormant", false),
			"dormant_species": sector.get("dormant_species", {}).duplicate(true),
			"dormant_count": sector.get("dormant_count", 0)}
	return {"tick": tick + 1, "time": time + delta, "tick_ms": elapsed,
		"agents": records, "carcasses": world.carcasses.duplicate(true),
		"grass": world.resource_system.export_cells(),
		"biomass": world.resource_system.total_biomass,
		"biomes": world.resource_system._biomass_totals_by_biome.duplicate(),
		"sectors": sectors, "groups": world._group_state_cache.duplicate(true),
		"lod_counts": world.lod_counts.duplicate(), "performance": world.performance_counters.duplicate(),
		"metrics": stats.get_snapshot(), "counters": stats.counters.duplicate(),
		"events": pending_events.duplicate(true)}

func shutdown() -> void:
	if events.event_emitted.is_connected(_collect_event):
		events.event_emitted.disconnect(_collect_event)
	world.shutdown()
	stats.shutdown()
	events.shutdown()
	world = null
	stats = null
	events = null
