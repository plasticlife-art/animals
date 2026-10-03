extends RefCounted

## What the view is told about the simulation, and the effects it draws from it.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const AgentRendererScript := preload("res://scripts/ui/agent_renderer.gd")
const DyingSpritesScript := preload("res://scripts/ui/dying_sprites.gd")
const SaveSystemScript := preload("res://scripts/core/save_system.gd")


func run(a) -> void:
	_test_view_hears_deaths_births_and_splits(a)
	_test_view_hears_the_worker_on_the_main_thread(a)
	_test_display_clock_runs_between_ticks(a)
	_test_death_plays_then_hands_over_to_the_body(a)
	_test_death_frames_follow_the_cause(a)
	_test_death_frames_match_the_art(a)
	_test_no_death_drawn_unseen_asleep_or_in_overview(a)
	_test_fall_starts_on_the_frame_the_death_is_drawn(a)
	_test_old_save_is_drawn_as_today(a)


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


## A renderer with the shipped batches, in the tree so the scene batch can cull against
## the viewport (no camera: the whole world is in view). Shown animals are put into the
## batches by hand, as `refresh()` would have from the last tick.
static func _make_renderer(manager):
	var renderer = AgentRendererScript.new()
	renderer.simulation_manager = manager
	renderer._build_batches()
	Engine.get_main_loop().root.add_child(renderer)
	manager.world_event.connect(renderer._on_world_event)
	return renderer


static func _free_renderer(renderer) -> void:
	renderer.get_parent().remove_child(renderer)
	renderer.free()


static func _show(renderer, agent, drawn_at: Vector2, direction: int) -> void:
	renderer._batches[agent.species_type]["agents"] = [agent]
	renderer._render_positions[agent.id] = drawn_at
	renderer._direction[agent.id] = direction


## A kill in view plays the species' `dead` row where the animal was last drawn, facing the
## way it was facing, with the blow; its body is held back until the fall starts to fade,
## and the sprite is gone once the fade is over.
func _test_death_plays_then_hands_over_to_the_body(a) -> void:
	var manager = Helpers.create_manager(611)
	var renderer = _make_renderer(manager)
	var world = manager.world_state
	var deer = Helpers.spawn_herbivore(world, Vector2(120.0, 120.0), 0)
	_show(renderer, deer, Vector2(112.0, 120.0), 3)
	var dead_row := int(manager.config_bundle.visuals.species.herbivore.animations.dead.row)
	world.kill_agent(deer, "predation")
	var sprites: Array = renderer.transient_sprites()
	a.equal(sprites.size(), 1, "the kill starts a dying sprite")
	if sprites.size() != 1:
		_free_renderer(renderer)
		Helpers.destroy_manager(manager)
		return
	var state: Dictionary = sprites[0]
	a.equal(int(state.row), dead_row + 3, "the dead row, in the direction it was drawn facing")
	a.equal(Array(state.frames), [0, 1, 2, 3, 4], "a kill shows the blow")
	a.equal(state.position, Vector2(112.0, 120.0), "it starts where the animal was last drawn")
	a.equal(state.to, Vector2(120.0, 120.0), "and settles where it died")
	a.is_true(renderer.hides_carcass(deer.id), "its body waits while it falls")
	renderer.refresh()
	renderer.scene_batch.render(renderer, 0.0)
	a.equal(int(renderer.scene_batch.last_counts.get("visible_transient", -1)), 1, "the fall is drawn")
	a.equal(int(renderer.scene_batch.last_counts.get("visible_carcasses", -1)), 0, "the body is not drawn under it yet")

	var start := float(state.start)
	var dying = renderer._dying
	dying.advance(start + dying.play_seconds * 0.5)
	a.equal(int(state.frame), 2, "halfway through it is falling")
	a.equal(state.position, Vector2(120.0, 120.0), "having closed the gap to where it died")
	a.is_true(dying.advance(start + dying.play_seconds + dying.fade_seconds * 0.5), "the fade is a change of draw order")
	a.equal(int(state.frame), 4, "it fades on its last frame, the reddest")
	a.is_true(float(state.alpha) > 0.0 and float(state.alpha) < 1.0, "half faded")
	a.is_true(not renderer.hides_carcass(deer.id), "the body shows through the fade")
	renderer.refresh()
	renderer.scene_batch.render(renderer, 0.0)
	a.equal(int(renderer.scene_batch.last_counts.get("visible_carcasses", -1)), 1, "the body is drawn under the fading sprite")
	a.equal(int(renderer.scene_batch.last_counts.get("visible_transient", -1)), 1, "while the sprite still fades")
	a.is_true(dying.advance(start + dying.play_seconds + dying.fade_seconds + 0.01), "finishing changes the order too")
	a.is_true(renderer.transient_sprites().is_empty(), "the sprite is gone after the fade")
	a.is_true(renderer.transient_sprite(DyingSpritesScript.KEY_BASE + deer.id).is_empty(), "and so is its slot's state")
	renderer.refresh()
	renderer.scene_batch.render(renderer, 0.0)
	a.equal(int(renderer.scene_batch.last_counts.get("visible_transient", -1)), 0, "leaving the body alone")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)


## A kill ends on the reddest frame of the `dead` row, the blow; any other death skips the
## red and ends on the body in its own colours. The frames differ by species, so the row
## lists them; a row that lists none plays whole.
func _test_death_frames_follow_the_cause(a) -> void:
	var manager = Helpers.create_manager(612)
	var species: Dictionary = manager.config_bundle.visuals.species
	var deer_row: Dictionary = species.herbivore.animations.dead
	var fox_row: Dictionary = species.predator.animations.dead
	a.equal(Array(DyingSpritesScript.frames_for("predation", deer_row)), [0, 1, 2, 3, 4], "a deer killed: up to the blow")
	a.equal(Array(DyingSpritesScript.frames_for("starvation", deer_row)), [0, 1, 2, 6], "a deer starved: no red")
	a.equal(Array(DyingSpritesScript.frames_for("old_age", fox_row)), [0, 1, 5], "a fox of old age: no red")
	a.equal(Array(DyingSpritesScript.frames_for("predation", {"frames": 3})), [0, 1, 2], "a row listing nothing plays whole")
	a.equal(Array(DyingSpritesScript.frames_for("thirst", {"frames": 3, "fall_frames": [0, 9]})), [0, 2],
		"a listed frame past the row is its last")
	var renderer = _make_renderer(manager)
	var world = manager.world_state
	var fox = Helpers.spawn_predator(world, Vector2(80.0, 80.0))
	_show(renderer, fox, Vector2(80.0, 80.0), 0)
	world.kill_agent(fox, "starvation")
	var sprites: Array = renderer.transient_sprites()
	a.equal(sprites.size(), 1, "a starving predator in view falls too")
	if not sprites.is_empty():
		a.equal(Array(sprites[0].frames), [0, 1, 5], "without the red")
		a.equal(str(sprites[0].species), "predator", "in its own atlas")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)


## The lists hold for the art they describe, in every direction: each `dead` row flushes
## red in the middle and fades back, so a kill must end on the reddest frame and no frame
## of a death without a blow may be a third of the way to it.
func _test_death_frames_match_the_art(a) -> void:
	var visuals: Dictionary = Helpers.build_test_bundle(616).visuals
	for species_id in visuals.species.keys():
		var config: Dictionary = visuals.species[species_id]
		var row: Dictionary = config.get("animations", {}).get("dead", {})
		var texture: Texture2D = load(str(config.get("atlas", "")))
		if row.is_empty() or texture == null:
			a.is_true(false, "%s has a dead row and an atlas" % species_id)
			continue
		var image: Image = texture.get_image()
		if image.is_compressed():
			image.decompress()
		var pixels := int(config.get("frame_px", 32))
		var kill: PackedInt32Array = DyingSpritesScript.frames_for("predation", row)
		var fall: PackedInt32Array = DyingSpritesScript.frames_for("starvation", row)
		for direction in range(maxi(1, int(config.get("directions", 1)))):
			var redness: Array = []
			for frame in range(int(row.frames)):
				redness.append(_redness(image, Rect2i(frame * pixels, (int(row.row) + direction) * pixels, pixels, pixels)))
			var reddest := redness.find(redness.max())
			a.equal(kill[kill.size() - 1], reddest, "%s facing %d: a kill ends on the reddest frame" % [species_id, direction])
			var limit: float = float(redness[0]) + (float(redness[reddest]) - float(redness[0])) / 3.0
			for frame in fall:
				a.is_true(float(redness[frame]) < limit, "%s facing %d: frame %d of a death without a blow is not red" % [
					species_id, direction, frame])


## How much redder than grey a frame's drawn pixels are on average.
static func _redness(image: Image, frame: Rect2i) -> float:
	var total := 0.0
	var count := 0
	for y in range(frame.position.y, frame.end.y):
		for x in range(frame.position.x, frame.end.x):
			var colour := image.get_pixel(x, y)
			if colour.a <= 0.0:
				continue
			total += colour.r - (colour.g + colour.b) * 0.5
			count += 1
	return total / maxf(1.0, float(count))


## A death the player cannot see is not played: off screen, in a sleeping sector, or in
## overview, where animals are frozen dots. Past the cap a death just leaves its body.
func _test_no_death_drawn_unseen_asleep_or_in_overview(a) -> void:
	var manager = Helpers.create_manager(613)
	var renderer = _make_renderer(manager)
	var world = manager.world_state
	var unseen = Helpers.spawn_herbivore(world, Vector2(60.0, 60.0), 0)
	world.kill_agent(unseen, "starvation")
	a.equal(renderer.transient_sprites().size(), 0, "not in the drawn set: died off screen")
	world.emit_population_event("AgentDied", "herbivore", Vector2(60.0, 60.0), {"cause": "predation", "dormant": true})
	a.equal(renderer.transient_sprites().size(), 0, "a sleeping sector's death has no sprite")
	var seen = Helpers.spawn_herbivore(world, Vector2(90.0, 90.0), 0)
	_show(renderer, seen, Vector2(90.0, 90.0), 0)
	renderer.set_overview_mode(true)
	world.kill_agent(seen, "predation")
	a.equal(renderer.transient_sprites().size(), 0, "not in overview")
	renderer.set_overview_mode(false)
	var first = Helpers.spawn_herbivore(world, Vector2(100.0, 100.0), 0)
	_show(renderer, first, Vector2(100.0, 100.0), 0)
	world.kill_agent(first, "predation")
	a.equal(renderer.transient_sprites().size(), 1, "back at normal zoom it plays")
	renderer.set_overview_mode(true)
	a.equal(renderer.transient_sprites().size(), 0, "and switching to overview drops it")
	renderer.set_overview_mode(false)
	renderer._dying.max_active = 1
	var deer_a = Helpers.spawn_herbivore(world, Vector2(110.0, 110.0), 0)
	var deer_b = Helpers.spawn_herbivore(world, Vector2(130.0, 130.0), 0)
	renderer._batches["herbivore"]["agents"] = [deer_a, deer_b]
	world.kill_agent(deer_a, "predation")
	world.kill_agent(deer_b, "predation")
	a.equal(renderer.transient_sprites().size(), 1, "past the cap a death is not played")
	a.is_true(not renderer.hides_carcass(deer_b.id), "and its body is drawn at once")
	renderer._dying.clear()
	renderer._dying.configure({"enabled": false})
	var deer_c = Helpers.spawn_herbivore(world, Vector2(140.0, 140.0), 0)
	_show(renderer, deer_c, Vector2(140.0, 140.0), 0)
	world.kill_agent(deer_c, "predation")
	a.equal(renderer.transient_sprites().size(), 0, "switched off in visuals.effects.death")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)


## The fall is timed from the tick that killed the animal, so it starts on the frame that
## tick is first drawn: on the main thread and through the worker alike.
func _test_fall_starts_on_the_frame_the_death_is_drawn(a) -> void:
	var manager = Helpers.create_manager(614)
	var renderer = _make_renderer(manager)
	var deer = Helpers.spawn_herbivore(manager.world_state, Vector2(96.0, 96.0), 0)
	_show(renderer, deer, Vector2(96.0, 96.0), 0)
	deer.hunger = 100.0
	manager.accumulator = 0.0
	manager.step_once()
	var sprites: Array = renderer.transient_sprites()
	a.equal(sprites.size(), 1, "a death in a tick on the main thread")
	if not sprites.is_empty():
		a.near(manager.get_display_time(), float(sprites[0].start), 0.0001, "starts as the tick is drawn")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)

	manager = Helpers.create_manager(615)
	renderer = _make_renderer(manager)
	deer = Helpers.spawn_herbivore(manager.world_state, Vector2(96.0, 96.0), 0)
	manager.enable_interactive_worker()
	var shown = manager.world_state.get_agent(deer.id)
	_show(renderer, shown, Vector2(96.0, 96.0), 0)
	manager._worker.world.get_agent(deer.id).hunger = 100.0
	var frame: Dictionary = manager._worker.step(manager.tick_duration, manager.current_tick,
		manager.simulation_time, manager._build_lod_context(), -1, false)
	manager._apply_worker_frame(frame)
	manager._presentation_alpha = 0.0
	sprites = renderer.transient_sprites()
	a.equal(sprites.size(), 1, "a death the worker reports")
	if not sprites.is_empty():
		a.near(manager.get_display_time(), float(sprites[0].start), 0.0001, "starts as its frame is drawn")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)


## A save brings its world back as it was and draws it as the game draws today. A bundle
## from before the grass ramp, the water, the effects and the death frame lists, with the
## minimap's water off, comes back with the shipped look; what places the scenery and
## runs the world stays as saved.
func _test_old_save_is_drawn_as_today(a) -> void:
	var manager = Helpers.create_manager(617)
	Helpers.spawn_herbivore(manager.world_state, Vector2(100.0, 100.0), 0)
	var old: Dictionary = manager.config_bundle.duplicate(true)
	old.visuals.erase("water")
	old.visuals.erase("effects")
	old.visuals["ground"] = {"enabled": true, "update_interval_ticks": 18, "bare_color": [0.54, 0.43, 0.27, 0.6],
		"bare_range": [0.4, 0.08], "lush_color": [0.16, 0.42, 0.14, 0.3], "lush_range": [0.62, 0.95]}
	old.visuals.species.herbivore.animations.dead.erase("kill_frames")
	old.visuals.species.herbivore.animations.dead.erase("fall_frames")
	old.visuals.props["saved_only"] = true
	old.debug.overlays["show_minimap_water"] = false
	old.debug["ui_refresh_interval_ticks"] = 7
	var data := {"version": SaveSystemScript.SAVE_VERSION, "selection": {}, "config_bundle": old, "seed": 617,
		"tick": manager.current_tick, "simulation_time": manager.simulation_time, "accumulator": 0.0,
		"rng_seed": manager.rng.seed, "rng_state": manager.rng.state,
		"world": manager.export_simulation_state(), "stats": manager.stats_system.counters.duplicate()}
	var restored = Helpers.create_manager(618)
	a.is_true(SaveSystemScript.restore(restored, data), "the old save loads")
	var shipped: Dictionary = Helpers.ConfigLoaderScript.load_config_bundle({})
	var visuals: Dictionary = restored.config_bundle.visuals
	a.equal(visuals.get("water"), shipped.visuals.water, "with water on the ground")
	a.equal(visuals.get("ground"), shipped.visuals.ground, "with the grass ramp, not the old two ranges")
	a.equal(visuals.get("effects"), shipped.visuals.effects, "with the effects")
	a.equal(visuals.species.herbivore.animations.dead, shipped.visuals.species.herbivore.animations.dead,
		"with the death frames listed")
	a.is_true(bool(restored.debug_flags.get("show_minimap_water", false)), "and with water on the minimap")
	a.is_true(bool(visuals.props.get("saved_only", false)), "the scenery is placed from the saved props")
	a.equal(restored.ui_refresh_interval_ticks, 7, "the rest of the debug block is the save's")
	a.equal(restored.config_bundle.world, old.world, "and so is the world's own config")
	a.equal(restored.world_state.living_agents.size(), manager.world_state.living_agents.size(), "with its animals")
	var bare := {"world": {"seed": 1}}
	a.equal(Helpers.ConfigLoaderScript.with_shipped_presentation(bare, {}), bare,
		"nothing shipped to take: the save's own bundle")
	Helpers.destroy_manager(restored)
	Helpers.destroy_manager(manager)
