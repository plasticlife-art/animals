class_name SimulationWorker
extends RefCounted

## Exclusive owner of mutable simulation state while an interactive tick runs.
## `step()` runs on the manager's one persistent worker thread. Only value
## snapshots cross back to the main thread; no live agents are shared.
var world: WorldState
var stats: StatsSystem
var events: EventBus
var random: RandomNumberGenerator
var pending_events: Array = []
var sequence: int = 0
var _last_carcasses: Dictionary = {}
var _known_agent_ids: Dictionary = {}
var _last_sectors: Dictionary = {}
var _last_groups: Dictionary = {}
var presentation_tick: int = 0
var presentation_time: float = 0.0
var _grass_was_included: bool = false

func configure(source_world: WorldState, source_stats: StatsSystem, source_events: EventBus, source_rng: RandomNumberGenerator) -> void:
	world = source_world
	stats = source_stats
	events = source_events
	random = source_rng
	sequence = 0
	presentation_tick = 0
	presentation_time = 0.0
	_last_carcasses = world.carcasses.duplicate(true)
	_known_agent_ids.clear()
	for agent in world.living_agents:
		_known_agent_ids[agent.id] = true
	_last_sectors = _export_presentation_sectors()
	_last_groups = world._group_state_cache.duplicate(true)
	_grass_was_included = false
	world.resource_system.track_dirty_cells = false
	world.resource_system.clear_dirty_cells()
	events.event_emitted.connect(_collect_event)

func _collect_event(event: Dictionary) -> void:
	pending_events.append(event)

func step(delta: float, tick: int, time: float, lod: Dictionary, inspected_id: int, include_grass: bool = false, include_fear: bool = false) -> Dictionary:
	pending_events.clear()
	world.inspected_agent_id = inspected_id
	var full_grass := include_grass and not _grass_was_included
	world.resource_system.track_dirty_cells = include_grass
	if not include_grass:
		world.resource_system.clear_dirty_cells()
	var start := Time.get_ticks_usec()
	world.step(delta, tick, time, lod)
	var elapsed := (Time.get_ticks_usec() - start) / 1000.0
	stats.record_step_duration(elapsed)
	var snapshot_started := Time.get_ticks_usec()
	stats.record_sample(world, tick + 1, time + delta)
	sequence += 1
	presentation_tick = tick + 1
	presentation_time = time + delta
	var result := _presentation_state(inspected_id, false, include_grass, full_grass)
	_grass_was_included = include_grass
	# The whole field while its overlay is on: a few hundred floats, against a
	# delta protocol that would cost more to maintain than to skip.
	if include_fear:
		result["fear_cells"] = world.fear_field.export_cells()
	result["kind"] = "presentation_delta"
	result["sequence"] = sequence
	result["tick"] = tick + 1
	result["time"] = time + delta
	result["tick_ms"] = elapsed
	result["snapshot_ms"] = float(Time.get_ticks_usec() - snapshot_started) / 1000.0
	return result


func full_presentation_snapshot(inspected_id: int) -> Dictionary:
	var started := Time.get_ticks_usec()
	var result := _presentation_state(inspected_id, true, true, true)
	result["kind"] = "full_snapshot"
	result["sequence"] = sequence
	result["tick"] = presentation_tick
	result["time"] = presentation_time
	result["tick_ms"] = 0.0
	result["snapshot_ms"] = float(Time.get_ticks_usec() - started) / 1000.0
	return result


func _presentation_state(inspected_id: int, full: bool, include_grass: bool, full_grass: bool = false) -> Dictionary:
	var records: Array = []
	var active_ids: Dictionary = {}
	for agent in world.living_agents:
		active_ids[agent.id] = true
		var needs_full_record := full or not _known_agent_ids.has(agent.id)
		var record: Dictionary = agent.export_runtime_state() if needs_full_record else agent.export_presentation_state()
		record["full_record"] = needs_full_record
		if agent.id == inspected_id:
			record["last_action_reason"] = agent.last_action_reason
			record["last_action_scores"] = agent.last_action_scores.duplicate()
			record["last_action_raw_scores"] = agent.last_action_raw_scores.duplicate()
			record["path_cells"] = agent.path_cells.duplicate()
		records.append(record)
	var agent_removals := PackedInt32Array()
	for known_id in _known_agent_ids:
		if not active_ids.has(known_id):
			agent_removals.append(int(known_id))
	_known_agent_ids = active_ids
	var sectors := _export_presentation_sectors()
	var sector_delta := _dictionary_delta(sectors, _last_sectors, full)
	_last_sectors = sectors.duplicate(true)
	var groups: Dictionary = world._group_state_cache
	var group_delta := _dictionary_delta(groups, _last_groups, full)
	_last_groups = groups.duplicate(true)
	var carcass_delta := _carcass_delta(full)
	var grass_delta: Dictionary
	if full or full_grass:
		grass_delta = {"full": world.resource_system.export_cells()}
		world.resource_system.clear_dirty_cells()
	elif include_grass:
		grass_delta = world.resource_system.take_dirty_cells()
	else:
		grass_delta = {"indices": PackedInt32Array(), "values": PackedFloat32Array()}
	# `metrics` is the frozen stats snapshot, handed over by reference: the stats
	# system replaces it on each sample rather than editing it.
	var result := {"full": full, "agents": records,
		"agent_removals": agent_removals,
		"carcass_upserts": carcass_delta.upserts,
		"carcass_removals": carcass_delta.removals,
		"grass_delta": grass_delta,
		"biomass": world.resource_system.total_biomass,
		"biomes": world.resource_system._biomass_totals_by_biome.duplicate(),
		"sector_upserts": sector_delta.upserts, "sector_removals": sector_delta.removals,
		"group_upserts": group_delta.upserts, "group_removals": group_delta.removals,
		"lod_counts": world.lod_counts.duplicate(), "performance": world.performance_counters.duplicate(),
		"metrics": stats.get_snapshot_view(), "counters": stats.counters.duplicate(),
		"events": pending_events.duplicate(true)}
	result["snapshot_counts"] = {"agents": records.size(),
		"agent_removals": agent_removals.size(),
		"carcasses": carcass_delta.upserts.size(),
		"grass_cells": world.resource_system.get_cell_count() if full or full_grass else grass_delta.indices.size(),
		"sectors": sector_delta.upserts.size(), "groups": group_delta.upserts.size(),
		"events": pending_events.size(),
		"mode": "full" if full else "delta"}
	return result


func _export_presentation_sectors() -> Dictionary:
	var sectors := {}
	for key in world._sector_states:
		var sector: Dictionary = world._sector_states[key]
		sectors[key] = {"dormant": sector.get("dormant", false),
			# The presentation world uses the same sector lookup for its carcass
			# overlay. IDs are compact and only change when a body appears or is
			# removed, so they belong in the sector delta rather than a full scan.
			"carcass_ids": sector.get("carcass_ids", []).duplicate(),
			"dormant_species": sector.get("dormant_species", {}).duplicate(true),
			"dormant_count": sector.get("dormant_count", 0),
			# Sleeping animals are still part of the presentation. The aggregate
			# carries stable record IDs and a center, enough for overview proxies
			# without copying every full runtime record back to the main thread.
			"dormant_aggregates": sector.get("dormant_aggregates", []).duplicate(true)}
	return sectors


func _dictionary_delta(current: Dictionary, previous: Dictionary, full: bool) -> Dictionary:
	var upserts := {}
	var removals: Array = []
	if full:
		upserts = current.duplicate(true)
	else:
		for key in current:
			if not previous.has(key) or previous[key] != current[key]:
				upserts[key] = current[key].duplicate(true) if current[key] is Dictionary else current[key]
		for key in previous:
			if not current.has(key):
				removals.append(key)
	return {"upserts": upserts, "removals": removals}


func _carcass_delta(full: bool) -> Dictionary:
	var upserts := {}
	var removals := PackedInt32Array()
	if full:
		upserts = world.carcasses.duplicate(true)
	else:
		for carcass_id in world.carcasses:
			var current: Dictionary = world.carcasses[carcass_id]
			if not _last_carcasses.has(carcass_id) or _last_carcasses[carcass_id] != current:
				upserts[carcass_id] = current.duplicate(true)
		for carcass_id in _last_carcasses:
			if not world.carcasses.has(carcass_id):
				removals.append(int(carcass_id))
	_last_carcasses = world.carcasses.duplicate(true)
	return {"upserts": upserts, "removals": removals}

func shutdown() -> void:
	if events.event_emitted.is_connected(_collect_event):
		events.event_emitted.disconnect(_collect_event)
	world.shutdown()
	stats.shutdown()
	events.shutdown()
	world = null
	stats = null
	events = null
