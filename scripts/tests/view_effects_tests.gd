extends RefCounted

## What the view is told about the simulation, and the effects it draws from it.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const AgentRendererScript := preload("res://scripts/ui/agent_renderer.gd")
const DyingSpritesScript := preload("res://scripts/ui/dying_sprites.gd")
const SaveSystemScript := preload("res://scripts/core/save_system.gd")
const EffectQueueScript := preload("res://scripts/ui/effect_queue.gd")
const EventEffectsScript := preload("res://scripts/ui/event_effects.gd")


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
	_test_effect_queue_keeps_order_cap_and_scatter(a)
	_test_kill_in_view_bursts_and_flashes(a)
	_test_birth_in_view_rings_and_grows_in(a)
	_test_dust_once_per_stride_and_never_in_flight(a)
	_test_view_leaves_the_world_alone(a)
	_test_sprites_take_the_night_tint(a)
	_test_carcass_sheets_start_where_the_fall_ends(a)
	_test_body_lies_as_the_animal_fell(a)


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
	a.equal(Array(state.frames), [0, 1, 2, 3, 4, 5], "a kill shows the blow")
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
	a.equal(int(state.frame), 3, "halfway through it is falling")
	a.equal(state.position, Vector2(120.0, 120.0), "having closed the gap to where it died")
	a.is_true(dying.advance(start + dying.play_seconds + dying.fade_seconds * 0.5), "the fade is a change of draw order")
	a.equal(int(state.frame), 5, "it fades on its last frame, still flushed")
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
	a.equal(Array(DyingSpritesScript.frames_for("predation", deer_row)), [0, 1, 2, 3, 4, 5], "a deer killed: through the blow")
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
## red in the middle and fades back, so a kill must run through the reddest frame and stop
## on the next, still a third of the way to it, and no frame of a death without a blow may
## be that red.
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
			var limit: float = float(redness[0]) + (float(redness[reddest]) - float(redness[0])) / 3.0
			a.is_true(Array(kill).has(reddest) and kill[kill.size() - 1] == reddest + 1,
				"%s facing %d: a kill runs through the reddest frame and stops on the next" % [species_id, direction])
			a.is_true(float(redness[kill[kill.size() - 1]]) >= limit,
				"%s facing %d: still flushed where it stops" % [species_id, direction])
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


## Marks leave in the order they came once their time is up, a full queue refuses new
## ones rather than cutting old ones short, and the scatter is a pure function of its
## inputs: no generator is advanced by drawing.
func _test_effect_queue_keeps_order_cap_and_scatter(a) -> void:
	var queue = EffectQueueScript.new()
	queue.capacity = 3
	a.is_true(queue.add(EffectQueueScript.Kind.DUST, Vector2(1.0, 0.0), 10.0, 0.5, 4.0), "a mark is taken")
	queue.add(EffectQueueScript.Kind.BURST, Vector2(2.0, 0.0), 10.0, 1.0, 4.0)
	queue.add(EffectQueueScript.Kind.DUST, Vector2(3.0, 0.0), 10.2, 0.5, 4.0)
	a.is_true(not queue.add(EffectQueueScript.Kind.DUST, Vector2(4.0, 0.0), 10.2, 0.5, 4.0), "past the cap a mark is refused")
	a.is_true(not EffectQueueScript.new().add(EffectQueueScript.Kind.DUST, Vector2.ZERO, 0.0, 0.0, 4.0),
		"and so is one that would last no time")
	a.near(EffectQueueScript.progress(queue.items()[0], 9.0), -1.0, 0.0001, "before its start a mark has not begun")
	a.near(EffectQueueScript.progress(queue.items()[0], 10.25), 0.5, 0.0001, "halfway through its life")
	a.is_true(queue.advance(10.6), "two are still alive")
	var left: Array = []
	for item in queue.items():
		left.append(item.position.x)
	a.equal(left, [2.0, 3.0], "the finished one left, the rest kept their order")
	a.is_true(queue.add(EffectQueueScript.Kind.FLASH, Vector2(5.0, 0.0), 10.6, 0.5, 4.0), "its place is free again")
	a.is_true(not queue.advance(20.0), "all gone in the end")
	a.equal(queue.added, 4, "four were taken in all")
	var scatter: Array = []
	for index in range(64):
		scatter.append(EffectQueueScript.jitter(17, index))
	var again: Array = []
	for index in range(64):
		again.append(EffectQueueScript.jitter(17, index))
	a.equal(scatter, again, "the scatter is the same every time")
	a.is_true(scatter.min() >= 0.0 and scatter.max() < 1.0, "within 0..1")
	a.is_true(scatter.max() - scatter.min() > 0.5, "and spread across it")


## A kill in view throws up a burst of puffs around the body and a flash at it; a death
## without a blow throws up nothing. The same kill always makes the same burst.
func _test_kill_in_view_bursts_and_flashes(a) -> void:
	var manager = Helpers.create_manager(621)
	var renderer = _make_renderer(manager)
	var world = manager.world_state
	var puffs := int(manager.config_bundle.visuals.effects.kill.puffs)
	var deer = Helpers.spawn_herbivore(world, Vector2(120.0, 120.0), 0)
	_show(renderer, deer, Vector2(120.0, 120.0), 0)
	world.kill_agent(deer, "predation")
	var marks: Array = renderer._effects.queue.items()
	a.equal(_kinds(marks), _repeat(EffectQueueScript.Kind.BURST, puffs) + [EffectQueueScript.Kind.FLASH],
		"a burst of puffs and a flash")
	var first: Array = _describe(marks)
	var starved = Helpers.spawn_herbivore(world, Vector2(140.0, 140.0), 0)
	_show(renderer, starved, Vector2(140.0, 140.0), 0)
	world.kill_agent(starved, "starvation")
	a.equal(renderer._effects.queue.items().size(), puffs + 1, "a death without a blow throws up nothing")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)

	manager = Helpers.create_manager(621)
	renderer = _make_renderer(manager)
	deer = Helpers.spawn_herbivore(manager.world_state, Vector2(120.0, 120.0), 0)
	_show(renderer, deer, Vector2(120.0, 120.0), 0)
	manager.world_state.kill_agent(deer, "predation")
	a.equal(_describe(renderer._effects.queue.items()), first, "the same kill makes the same burst")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)


## A young animal born in view opens a ring with sparkles and grows in from small, a
## little past full size and back; founders and animals born out of view just appear.
func _test_birth_in_view_rings_and_grows_in(a) -> void:
	var scale_at_start := EventEffectsScript.pop_scale(0.0, 0.3, 0.35)
	var largest := 0.0
	for step in range(31):
		largest = maxf(largest, EventEffectsScript.pop_scale(0.01 * float(step), 0.3, 0.35))
	a.near(scale_at_start, 0.35, 0.0001, "a newborn starts small")
	a.is_true(largest > 1.0 and largest < 1.06, "it overshoots a little (largest %.3f)" % largest)
	a.near(EventEffectsScript.pop_scale(0.3, 0.3, 0.35), 1.0, 0.0001, "and settles at full size")

	var manager = Helpers.create_manager(622)
	var renderer = _make_renderer(manager)
	var world = manager.world_state
	renderer.refresh()
	var sparkles := int(manager.config_bundle.visuals.effects.birth.sparkles)
	var calf = world.spawn_agent("herbivore", Vector2(100.0, 100.0), 0, "", {"reason": "reproduction"})
	a.equal(_kinds(renderer._effects.queue.items()), [EffectQueueScript.Kind.RING] + _repeat(EffectQueueScript.Kind.SPARKLE, sparkles),
		"a ring and sparkles where it was born")
	var start := float(renderer._born.get(calf.id, -1.0))
	renderer._now = start
	a.near(renderer._pop_of(calf.id), 0.35, 0.0001, "it is drawn small on its first frame")
	renderer._now = start + 0.15
	var growing: float = renderer._pop_of(calf.id)
	a.is_true(growing > 0.35 and growing < 1.06, "growing halfway in (%.3f)" % growing)
	renderer._now = start + 0.31
	a.near(renderer._pop_of(calf.id), 1.0, 0.0001, "full size once grown in")
	a.is_true(not renderer._born.has(calf.id), "and forgotten")
	var count: int = renderer._effects.queue.items().size()
	world.spawn_agent("herbivore", Vector2(110.0, 110.0), 0, "", {"reason": "initial"})
	a.equal(renderer._effects.queue.items().size(), count, "a founder just appears")
	renderer._visible_rect = Rect2(0.0, 0.0, 40.0, 40.0)
	world.spawn_agent("herbivore", Vector2(200.0, 200.0), 0, "", {"reason": "reproduction"})
	a.equal(renderer._effects.queue.items().size(), count, "a birth out of view is not drawn")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)


## An animal running in a chase kicks up one puff per stride of `dust.spacing_px`, behind
## it; one that is not in a chase raises none, and nor does a bird, whose run is flight.
func _test_dust_once_per_stride_and_never_in_flight(a) -> void:
	var manager = Helpers.create_manager(623)
	var renderer = _make_renderer(manager)
	var world = manager.world_state
	var spacing: float = renderer._effects.dust_spacing
	var deer = Helpers.spawn_herbivore(world, Vector2(100.0, 120.0), 0)
	deer.current_action = &"flee_to_safe_area"
	a.equal(_dust_after_strides(renderer, deer, spacing, [0.0, 0.4, 1.0, 1.5, 2.1, 3.3]), 3,
		"a fleeing deer: one puff per stride covered, counted from its first")
	var calm = Helpers.spawn_herbivore(world, Vector2(100.0, 160.0), 0)
	calm.current_action = &"explore"
	a.equal(_dust_after_strides(renderer, calm, spacing, [0.0, 1.0, 2.0, 3.0]), 0,
		"an animal running on its own business raises none")
	var crow = Helpers.spawn_species(world, "scavenger", Vector2(100.0, 200.0))
	crow.current_action = &"flee_to_safe_area"
	a.equal(_dust_after_strides(renderer, crow, spacing, [0.0, 1.0, 2.0, 3.0]), 0, "nor a bird, flying off")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)


## Runs `agent` through the frames of a run, its ground covered at `strides` x `spacing`,
## and counts the puffs of dust it raised.
static func _dust_after_strides(renderer, agent, spacing: float, strides: Array) -> int:
	var batch: Dictionary = renderer._batches[agent.species_type]
	batch["agents"] = [agent]
	renderer._history[agent.id] = PackedVector2Array([agent.position - Vector2(30.0, 0.0),
		agent.position - Vector2(20.0, 0.0), agent.position - Vector2(10.0, 0.0), agent.position])
	renderer._drawn_speed[agent.id] = 120.0
	var before: int = renderer._effects.queue.added
	for stride in strides:
		renderer._gait_distance[agent.id] = float(stride) * spacing
		renderer._render_positions.clear()
		renderer._animate_species(batch, 0.5, 1.0 / 60.0)
	batch["agents"] = []
	var raised: int = renderer._effects.queue.added - before
	for item in renderer._effects.queue.items():
		if int(item.kind) != EffectQueueScript.Kind.DUST:
			raised = -100
	renderer._effects.clear()
	return raised


## Drawing changes nothing it draws: a world run with the whole view attached - deaths,
## births, dust and all - ends the same as the same world run without it.
func _test_view_leaves_the_world_alone(a) -> void:
	var watched = _chase_fixture(624)
	var renderer = AgentRendererScript.new()
	Engine.get_main_loop().root.add_child(renderer)
	renderer.bind_manager(watched)
	var unwatched = _chase_fixture(624)
	for _tick in range(240):
		watched.step_once()
		renderer._process(1.0 / 60.0)
		unwatched.step_once()
	a.equal(Helpers.world_fingerprint(watched), Helpers.world_fingerprint(unwatched), "the same world either way")
	a.equal(watched.stats_system.counters, unwatched.stats_system.counters, "with the same tallies")
	a.is_true(renderer._effects.queue.added > 0, "and the view did draw something (%d marks)" % renderer._effects.queue.added)
	_free_renderer(renderer)
	Helpers.destroy_manager(watched)
	Helpers.destroy_manager(unwatched)


## A hungry predator beside a small herd, so a chase starts within seconds.
static func _chase_fixture(seed_value: int):
	var manager = Helpers.create_manager(seed_value)
	var world = manager.world_state
	Helpers.spawn_herd(world, Vector2(150.0, 130.0), 5, 0)
	var fox = Helpers.spawn_predator(world, Vector2(90.0, 120.0))
	fox.hunger = 85.0
	return manager


static func _kinds(items: Array) -> Array:
	var kinds: Array = []
	for item in items:
		kinds.append(int(item.kind))
	return kinds


static func _repeat(value, count: int) -> Array:
	var repeated: Array = []
	for _index in range(count):
		repeated.append(value)
	return repeated


static func _describe(items: Array) -> Array:
	var described: Array = []
	for item in items:
		described.append([int(item.kind), item.position, item.start, item.seconds, item.size, item.drift, item.lift])
	return described


## Animals, props and carcasses go dark at night with the ground: their shaders are lit, so
## `DayNightTint` reaches them. The flash and sparkles above them are added light and stay
## bright.
func _test_sprites_take_the_night_tint(a) -> void:
	for path in ["res://shaders/scene_atlas.gdshader", "res://shaders/agent_atlas.gdshader"]:
		var shader: Shader = load(path)
		a.is_true(shader != null and not shader.code.contains("render_mode unshaded"), "%s takes the night tint" % path)
	var manager = Helpers.create_manager(651)
	var renderer = _make_renderer(manager)
	a.equal(renderer._effects._air.material.light_mode, CanvasItemMaterial.LIGHT_MODE_UNSHADED,
		"the air's light does not")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)


## Each species' carcass sheet begins with the very frame its fall ends on, in every
## direction - the last of `fall_frames` without a blow, of `kill_frames` after one - so the
## body takes over from the fall without a change; then two stages drawn over it.
func _test_carcass_sheets_start_where_the_fall_ends(a) -> void:
	var visuals: Dictionary = Helpers.build_test_bundle(652).visuals
	for species_id in visuals.species.keys():
		var config: Dictionary = visuals.species[species_id]
		a.is_true(config.has("carcass_atlas"), "%s has a body of its own" % species_id)
		if not config.has("carcass_atlas"):
			continue
		var animal: Image = _image(str(config.atlas))
		var sheet: Image = _image(str(config.carcass_atlas))
		var pixels := int(config.get("frame_px", 32))
		var directions := int(config.get("directions", 1))
		var dead: Dictionary = config.animations.dead
		var stages := int(visuals.carcass.get("stages", 3))
		a.equal(sheet.get_size(), Vector2i(stages * pixels, 2 * directions * pixels),
			"%s: the stages across, the directions twice down" % species_id)
		for variant in range(2):
			var last: int = dead.kill_frames[dead.kill_frames.size() - 1] if variant == 1 \
				else dead.fall_frames[dead.fall_frames.size() - 1]
			for direction in range(directions):
				var fell := animal.get_region(Rect2i(last * pixels, (int(dead.row) + direction) * pixels, pixels, pixels))
				var row := (variant * directions + direction) * pixels
				var whole := sheet.get_region(Rect2i(0, row, pixels, pixels))
				a.is_true(_same_picture(whole, fell),
					"%s %s facing %d: the body is the frame the fall ends on" % [species_id, ["fall", "kill"][variant], direction])
				var bones := sheet.get_region(Rect2i((stages - 1) * pixels, row, pixels, pixels))
				a.is_true(not _same_picture(bones, whole), "%s facing %d: picked to the bones it is not whole" % [
					species_id, direction])


## The same visible pixels. Fully transparent ones are left out: the importer's alpha border
## fix gives them the colour of their neighbours, which differ between the two sheets.
static func _same_picture(first: Image, second: Image) -> bool:
	if first.get_size() != second.get_size():
		return false
	for y in range(first.get_height()):
		for x in range(first.get_width()):
			var one := first.get_pixel(x, y)
			var other := second.get_pixel(x, y)
			if (one.a > 0.0 or other.a > 0.0) and not one.is_equal_approx(other):
				return false
	return true


static func _image(path: String) -> Image:
	var image: Image = (load(path) as Texture2D).get_image()
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RGBA8)
	return image


## A body lies the way its animal was seen to fall and at its size, flushed only after a
## kill, and is opened and then picked to the bones as its meat goes. One nobody saw fall
## lies a way fixed by its id; a species without a sheet of its own gets the shared one.
func _test_body_lies_as_the_animal_fell(a) -> void:
	var manager = Helpers.create_manager(653)
	var renderer = _make_renderer(manager)
	var world = manager.world_state
	var visuals: Dictionary = manager.config_bundle.visuals
	var batch = renderer.scene_batch
	var deer = Helpers.spawn_herbivore(world, Vector2(100.0, 100.0), 0)
	_show(renderer, deer, Vector2(100.0, 100.0), 3)
	world.kill_agent(deer, "predation")
	var body := _body_of(world, deer.id)
	var entry: Dictionary = batch.carcass_entry(renderer, body, visuals)
	a.equal(entry.get("uv"), batch.uv_rect("carcass_herbivore", Vector2(0, 4 + 3), Vector2.ONE * 32.0),
		"a deer killed facing east: its own body, flushed, lying east")
	var fox = Helpers.spawn_predator(world, Vector2(140.0, 140.0))
	_show(renderer, fox, Vector2(140.0, 140.0), 1)
	world.kill_agent(fox, "starvation")
	a.equal(batch.carcass_entry(renderer, _body_of(world, fox.id), visuals).get("uv"),
		batch.uv_rect("carcass_predator", Vector2(0, 1), Vector2.ONE * 32.0),
		"a fox that starved facing north: a fox's body in its own colours, lying north")
	body["meat_remaining"] = float(body.meat_total) * 0.5
	a.equal(batch.carcass_entry(renderer, body, visuals).get("uv"),
		batch.uv_rect("carcass_herbivore", Vector2(1, 7), Vector2.ONE * 32.0), "half eaten: opened")
	body["meat_remaining"] = float(body.meat_total) * 0.1
	a.equal(batch.carcass_entry(renderer, body, visuals).get("uv"),
		batch.uv_rect("carcass_herbivore", Vector2(2, 7), Vector2.ONE * 32.0), "nearly gone: bones")
	var fawn = Helpers.spawn_herbivore(world, Vector2(60.0, 180.0), 0)
	fawn.age = 0.0
	_show(renderer, fawn, Vector2(60.0, 180.0), 0)
	world.kill_agent(fawn, "predation")
	var young: float = renderer._age_scale_of(fawn)
	var small: Dictionary = batch.carcass_entry(renderer, _body_of(world, fawn.id), visuals)
	a.is_true(young < 1.0, "fixture: a fawn is drawn smaller")
	a.near((small.transform as Transform2D).x.x,
		32.0 * float(visuals.species.herbivore.sprite_scale) * renderer._world_scale() * young, 0.001,
		"and leaves a body as small as it was")
	var unseen_id: int = Helpers.spawn_carcass(world, Vector2(200.0, 60.0))
	var unseen: Dictionary = world.carcasses[unseen_id]
	var lying: int = renderer.carcass_direction(unseen)
	a.equal(lying, posmod(unseen_id * 7 + 1, 4), "a body nobody saw fall lies a way fixed by its id")
	a.equal(batch.carcass_entry(renderer, unseen, visuals).get("uv"),
		batch.uv_rect("carcass_herbivore", Vector2(0, lying), Vector2.ONE * 32.0), "unflushed: it was no kill")
	unseen["source_species"] = "unknown"
	a.equal(batch.carcass_entry(renderer, unseen, visuals).get("uv"),
		batch.uv_rect("carcass", Vector2(0, 0), Vector2.ONE * float(visuals.carcass.get("frame_px", 32))),
		"a species without a sheet of its own gets the shared one")
	_free_renderer(renderer)
	Helpers.destroy_manager(manager)


static func _body_of(world, agent_id: int) -> Dictionary:
	for carcass in world.carcasses.values():
		if int(carcass.get("source_agent_id", -1)) == agent_id:
			return carcass
	return {}
