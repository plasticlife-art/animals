extends RefCounted

## Herd flight (`species.herbivore.herd.flight`, `WorldState.raise_herd_alarm()`): a fox seen by one
## deer alarms its herd, the near first; the herd runs together for one point; no `rng` is drawn;
## the alarm is saved; the worker steps it as an inline tick does; and without the block every
## deer flees for itself, as before.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const AT := Vector2(1500.0, 1500.0)
## West of the herd: the western column sees it, the rest of the herd does not.
const FOX_AT := Vector2(1350.0, 1500.0)
const FLIGHT := {
	"alarm_radius_cells": 4.0,
	"alarm_speed_cells": 6.0,
	"hold_seconds": 2.5,
	"escape_distance_cells": 3.5,
}


func run(a) -> void:
	_test_one_sighting_alarms_the_herd(a)
	_test_the_herd_runs_together(a)
	_test_no_rng_and_the_alarm_is_saved(a)
	_test_the_worker_runs_it_alike(a)


static func _bundle(seed: int, flight: bool) -> Dictionary:
	var bundle := Helpers.build_large_sector_bundle(seed)
	if flight:
		bundle["species"]["herbivore"]["herd"]["flight"] = FLIGHT.duplicate(true)
	return bundle


static func _world(seed: int, flight: bool):
	var manager = Helpers.create_manager_with(_bundle(seed, flight), seed)
	manager.set_lod_enabled(false)
	var herd: Array = Helpers.spawn_herd(manager.world_state, AT, 9, 0)
	var fox = Helpers.spawn_predator(manager.world_state, FOX_AT)
	fox.hunger = 0.0
	return [manager, herd, fox]


static func _fleeing(herd: Array) -> int:
	var count := 0
	for deer in herd:
		if deer.is_alive and deer.state == "flee":
			count += 1
	return count


## How much the moving deer run one way: the length of the mean of their headings, 1 for all
## alike, about 0 for headings every way.
static func _agreement(herd: Array) -> float:
	var sum := Vector2.ZERO
	var count := 0
	for deer in herd:
		if deer.is_alive and deer.velocity.length() > 5.0:
			sum += deer.velocity.normalized()
			count += 1
	return sum.length() / float(count) if count > 0 else 0.0


func _test_one_sighting_alarms_the_herd(a) -> void:
	var off: Array = _world(9971, false)
	var on: Array = _world(9971, true)
	var heard_at := {}
	for tick in range(6):
		off[0].step_once()
		on[0].step_once()
		for deer in on[1]:
			if deer.state == "flee" and not heard_at.has(deer.id):
				heard_at[deer.id] = tick
	a.is_true(_fleeing(off[1]) <= 4, "each for itself: only the deer that see the fox run (%d of 9)" % _fleeing(off[1]))
	a.is_true(_fleeing(on[1]) >= 8, "one sighting: the whole herd runs (%d of 9)" % _fleeing(on[1]))
	a.equal(on[0].world_state.herd_alarms.size(), 1, "one alarm for the herd")
	var near_first := true
	for deer in on[1]:
		for other in on[1]:
			if heard_at.has(deer.id) and heard_at.has(other.id) \
					and deer.position.distance_to(FOX_AT) + 60.0 < other.position.distance_to(FOX_AT) \
					and int(heard_at[deer.id]) > int(heard_at[other.id]):
				near_first = false
	a.is_true(near_first, "the near ones first (%s)" % str(heard_at))
	a.equal(int(on[0].stats_system.counters.get("herd_alarms", 0)), 1, "and counted once")
	a.is_true(off[0].world_state.herd_alarms.is_empty(), "without the block, no alarm at all")
	Helpers.destroy_manager(off[0])
	Helpers.destroy_manager(on[0])


func _test_the_herd_runs_together(a) -> void:
	var off: Array = _world(9972, false)
	var on: Array = _world(9972, true)
	for _tick in range(12):
		off[0].step_once()
		on[0].step_once()
	var together := _agreement(on[1])
	a.is_true(together > 0.8, "the herd runs one way (%.2f)" % together)
	var away := 0
	for deer in on[1]:
		if deer.velocity.dot(deer.position - FOX_AT) > 0.0:
			away += 1
	a.is_true(away >= 8, "away from the fox (%d of 9)" % away)
	var alarm: Dictionary = on[0].world_state.herd_alarms.values()[0]
	a.is_true(Vector2(alarm["goal"]).distance_to(FOX_AT) > AT.distance_to(FOX_AT), "for one point beyond the herd")
	Helpers.destroy_manager(off[0])
	Helpers.destroy_manager(on[0])


func _test_no_rng_and_the_alarm_is_saved(a) -> void:
	var made: Array = _world(9973, true)
	var manager = made[0]
	var world = manager.world_state
	for _tick in range(4):
		manager.step_once()
	var far = null
	for deer in made[1]:
		if deer.position.distance_to(FOX_AT) > 150.0 and not world.herd_alarm_for(deer).is_empty():
			far = deer
			break
	a.is_true(far != null, "a deer that has only heard the alarm")
	if far != null:
		var state_before: int = world.rng.state
		far._flee(world, manager.tick_duration, [], made[1])
		a.equal(world.rng.state, state_before, "runs with the herd drawing nothing from the shared stream")
		a.equal(far.target_position, Vector2(world.herd_alarm_for(far)["goal"]), "for the herd's point")
	var saved: Dictionary = world.export_state()
	var other = Helpers.create_manager_with(_bundle(9973, true), 9973)
	other.world_state.import_state(saved)
	a.equal(other.world_state.herd_alarms, world.herd_alarms, "the alarm comes back with a save")
	Helpers.destroy_manager(other)
	Helpers.destroy_manager(manager)


func _test_the_worker_runs_it_alike(a) -> void:
	var inline: Array = _world(9974, true)
	var threaded: Array = _world(9974, true)
	threaded[0].enable_interactive_worker()
	threaded[0].begin_interactive_stepping()
	for _tick in range(16):
		inline[0].step_once()
		threaded[0]._post_worker_job()
		threaded[0].synchronize_worker()
	a.is_true(not inline[0].world_state.herd_alarms.is_empty(), "the herd took fright")
	a.equal("\n".join(Helpers.agent_state_lines(threaded[0].world_state)), "\n".join(Helpers.agent_state_lines(inline[0].world_state)),
		"and the worker's world is where the inline one is")
	a.equal(threaded[0].rng.state, inline[0].rng.state, "with the shared stream drawn alike")
	Helpers.destroy_manager(threaded[0])
	Helpers.destroy_manager(inline[0])
