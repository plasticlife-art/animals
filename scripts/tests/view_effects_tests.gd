extends RefCounted

## What the view is told about the simulation, and the effects it draws from it.

const Helpers := preload("res://scripts/tests/test_helpers.gd")


func run(a) -> void:
	_test_view_hears_deaths_births_and_splits(a)
	_test_view_hears_the_worker_on_the_main_thread(a)
	_test_display_clock_runs_between_ticks(a)


## Deaths, births and herd splits reach `world_event`; grazing and the extra death notices
## do not. After a restart the new world's bus is heard as the old one was.
func _test_view_hears_deaths_births_and_splits(a) -> void:
	var manager = Helpers.create_manager(601)
	var heard: Array = []
	manager.world_event.connect(func(event): heard.append(str(event.get("type", ""))))
	var world = manager.world_state
	var deer = Helpers.spawn_herbivore(world, Vector2(40.0, 40.0), 0)
	a.equal(heard, ["AgentBorn"], "a birth is heard")
	heard.clear()
	world.emit_event("GrassConsumed", deer, -1, {})
	world.kill_agent(deer, "starvation")
	world.emit_population_event("HerdSplit", "herbivore", Vector2(40.0, 40.0), {"size": 4, "new_group_id": 3})
	a.equal(heard, ["AgentDied", "HerdSplit"], "a death once and a split; not grazing, not the starvation notice")
	heard.clear()
	manager.initialize(manager.config_bundle, 602)
	world = manager.world_state
	var fox = Helpers.spawn_predator(world, Vector2(60.0, 60.0))
	heard.clear()
	world.kill_agent(fox, "old_age")
	a.equal(heard, ["AgentDied"], "after a restart the new world is heard too")
	Helpers.destroy_manager(manager)


## With the worker running, its events are heard once, when the frame is applied on the
## main thread, and never from the bus the worker owns.
func _test_view_hears_the_worker_on_the_main_thread(a) -> void:
	var manager = Helpers.create_manager(603)
	var deer = Helpers.spawn_herbivore(manager.world_state, Vector2(96, 96), 0)
	manager.enable_interactive_worker()
	var worker = manager._worker
	a.is_true(not worker.events.event_emitted.is_connected(manager._forward_view_event),
		"the bus the worker owns is not watched")
	var heard: Array = []
	manager.world_event.connect(func(event): heard.append(event))
	worker.world.get_agent(deer.id).hunger = 100.0
	var frame: Dictionary = worker.step(manager.tick_duration, 0, 0.0, manager._build_lod_context(), -1, false)
	a.equal(heard.size(), 0, "nothing is heard before the frame is applied")
	manager._apply_worker_frame(frame)
	var deaths: Array = heard.filter(func(event): return str(event.get("type", "")) == "AgentDied")
	a.equal(deaths.size(), 1, "the death is heard once the frame is applied")
	if not deaths.is_empty():
		a.equal(int(deaths[0].get("data", {}).get("group_id", -2)), 0, "with the herd it died out of")
	Helpers.destroy_manager(manager)


## The view's clock is the last tick plus how far the next has come, so it holds still
## while the simulation's clock does.
func _test_display_clock_runs_between_ticks(a) -> void:
	var manager = Helpers.create_manager(604)
	manager.simulation_time = 10.0
	manager.accumulator = manager.tick_duration * 0.5
	a.near(manager.get_display_time(), 10.0 + manager.tick_duration * 0.5, 0.0001, "halfway to the next tick")
	manager.accumulator = 0.0
	a.near(manager.get_display_time(), 10.0, 0.0001, "and on the tick when the clock stands still")
	Helpers.destroy_manager(manager)
