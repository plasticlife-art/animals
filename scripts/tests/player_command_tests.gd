extends RefCounted

## The player's orders (`PlayerCommands`, `PlayerState`): carried out on the tick they were
## handed to, the same inline and on the worker thread; paid for in charges and cooldowns kept by
## the simulation; refused with a reason; kept in the journal and the save; waiting while the
## game is paused; forgotten by a new world; and the view following the player's state even
## across a lost frame.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const SimulationTests := preload("res://scripts/tests/simulation_tests.gd")
const PlayerCommandsScript := preload("res://scripts/core/player_commands.gd")

## A test power: `charges` and `cooldown_seconds` as given, carried out by `_mark()`.
const MARK := "mark"


func run(a) -> void:
	_test_order_is_carried_out_on_its_tick(a)
	_test_worker_and_inline_carry_out_orders_alike(a)
	_test_charges_and_cooldowns(a)
	_test_refused_orders_change_nothing(a)
	_test_paused_orders_wait_and_a_new_world_forgets_them(a)
	_test_view_follows_the_budget_across_a_lost_frame(a)


## Gives `world` the test power: it sets the hunger of the animal the order names, so a carried
## out order shows in the world's fingerprint.
static func _arm(world, charges: int = -1, cooldown: float = 0.0) -> void:
	world.player.configure({"powers": {MARK: {"charges": charges, "cooldown_seconds": cooldown}}})
	# Weakly: the world keeps its handlers, and a handler holding the world would keep both.
	var world_ref: WeakRef = weakref(world)
	world.player_command_handlers[MARK] = func(command: Dictionary) -> Dictionary:
		var acting = world_ref.get_ref()
		var params: Dictionary = command.get("params", {})
		var animal = acting.get_agent(int(params.get("agent_id", -1)))
		if animal == null:
			return {"ok": false, "reason": PlayerCommandsScript.REFUSED_BAD_TARGET}
		animal.hunger = float(params.get("hunger", 0.0))
		return {"ok": true, "tick_seen": acting.current_tick}


func _test_order_is_carried_out_on_its_tick(a) -> void:
	var manager = Helpers.create_manager(9701)
	var world = manager.world_state
	_arm(world)
	var deer = Helpers.spawn_herbivore(world, Vector2(90.0, 90.0), 0)
	Helpers.run_ticks(manager, 5)
	var heard: Array = []
	manager.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "PlayerCommand":
			heard.append(event))
	var tick := int(manager.current_tick)
	var seq: int = manager.enqueue_command(MARK, {"agent_id": deer.id, "hunger": 33.0})
	a.equal(manager.pending_commands().size(), 1, "an order waits for the next tick")
	manager.step_once()
	a.equal(manager.pending_commands().size(), 0, "and goes with it")
	var entry: Dictionary = world.player.journal.back()
	a.equal([int(entry.seq), int(entry.tick), str(entry.type)], [seq, tick, MARK], "the journal keeps it on its tick")
	a.equal(int(entry.result.get("tick_seen", -1)), tick, "carried out on that tick")
	a.equal(heard.size(), 1, "one event says so")
	a.equal(int(heard[0].tick), tick, "on that tick")
	a.is_true(bool(heard[0].data.ok) and int(heard[0].data.seq) == seq and str(heard[0].data.power) == MARK,
		"with what came of which order")
	a.near(deer.hunger, 33.0, 2.0, "and the world changed by it")
	Helpers.destroy_manager(manager)


## The same order on the same tick leaves a worker-stepped world exactly where an inline one is,
## and its event comes back in that tick's frame.
func _test_worker_and_inline_carry_out_orders_alike(a) -> void:
	var inline = SimulationTests._build_worker_fixture(9702)
	var threaded = SimulationTests._build_worker_fixture(9702)
	_arm(inline.world_state)
	threaded.enable_interactive_worker()
	threaded.begin_interactive_stepping()
	_arm(threaded._worker.world)
	var target: int = inline.world_state.get_living_agents()[0].id
	var heard: Array = []
	threaded.world_event.connect(func(event: Dictionary) -> void:
		if str(event.get("type", "")) == "PlayerCommand":
			heard.append(int(event.tick)))
	var ordered_at := -1
	for tick in range(24):
		if tick == 10:
			ordered_at = int(inline.current_tick)
			inline.enqueue_command(MARK, {"agent_id": target, "hunger": 61.0})
			threaded.enqueue_command(MARK, {"agent_id": target, "hunger": 61.0})
		inline.step_once()
		threaded._post_worker_job()
		threaded.synchronize_worker()
	a.equal(threaded.rng.state, inline.rng.state, "an order draws on the shared stream alike on both paths")
	a.equal("\n".join(Helpers.agent_state_lines(threaded.world_state)), "\n".join(Helpers.agent_state_lines(inline.world_state)),
		"and leaves the worker's world where the inline one is")
	a.equal(heard, [ordered_at], "its event comes back in the frame of the tick it was carried out on")
	a.equal(threaded._worker.world.player.journal.size(), 1, "the worker keeps the journal")
	Helpers.destroy_manager(threaded)
	Helpers.destroy_manager(inline)


func _test_charges_and_cooldowns(a) -> void:
	var manager = Helpers.create_manager(9703)
	var world = manager.world_state
	_arm(world, 2, 5.0)
	var deer = Helpers.spawn_herbivore(world, Vector2(90.0, 90.0), 0)
	manager.enqueue_command(MARK, {"agent_id": deer.id})
	manager.enqueue_command(MARK, {"agent_id": deer.id})
	manager.step_once()
	var results: Array = []
	for entry in world.player.journal:
		results.append(str(entry.result.get("reason", "ok")))
	a.equal(results, ["ok", PlayerCommandsScript.REFUSED_COOLING], "two orders on one tick: the second waits out the first's cooldown")
	a.equal(int(world.player.budget[MARK].charges), 1, "one charge spent, by the order carried out")
	Helpers.run_ticks(manager, int(ceil(5.0 / manager.tick_duration)))
	manager.enqueue_command(MARK, {"agent_id": deer.id})
	manager.step_once()
	a.equal(str(world.player.journal.back().result.get("reason", "ok")), "ok", "after its cooldown, in simulated time, it is used again")
	a.equal(int(world.player.budget[MARK].charges), 0, "and the last charge is gone")
	Helpers.run_ticks(manager, int(ceil(5.0 / manager.tick_duration)))
	manager.enqueue_command(MARK, {"agent_id": deer.id})
	manager.step_once()
	a.equal(str(world.player.journal.back().result.get("reason", "")), PlayerCommandsScript.REFUSED_NO_CHARGES,
		"with no charges left it is refused")
	var saved: Dictionary = world.export_state()
	var other = Helpers.create_manager(9703)
	_arm(other.world_state, 2, 5.0)
	other.world_state.import_state(saved)
	a.equal(other.world_state.player.budget, world.player.budget, "charges and cooldowns come back with a save")
	a.equal(other.world_state.player.journal.size(), 4, "and so does the journal")
	var old_save: Dictionary = saved.duplicate(true)
	old_save.erase("player")
	var fresh = Helpers.create_manager(9703)
	_arm(fresh.world_state, 2, 5.0)
	fresh.world_state.import_state(old_save)
	a.equal(int(fresh.world_state.player.budget[MARK].charges), 2, "a save from before the powers keeps them as configured")
	a.is_true(fresh.world_state.player.journal.is_empty(), "with an empty journal")
	Helpers.destroy_manager(fresh)
	Helpers.destroy_manager(other)
	Helpers.destroy_manager(manager)


## A refused order is in the journal and changes nothing else: the world plays on as one that
## was never given it.
func _test_refused_orders_change_nothing(a) -> void:
	var plain = Helpers.create_manager(9704)
	var ordered = Helpers.create_manager(9704)
	for manager in [plain, ordered]:
		Helpers.spawn_herbivore(manager.world_state, Vector2(90.0, 90.0), 0)
		Helpers.spawn_predator(manager.world_state, Vector2(200.0, 160.0))
	_arm(ordered.world_state)
	for tick in range(30):
		if tick == 4:
			ordered.enqueue_command("no_such_power", {})
			ordered.enqueue_command(MARK, {"agent_id": 99999})
		plain.step_once()
		ordered.step_once()
	var reasons: Array = []
	for entry in ordered.world_state.player.journal:
		reasons.append(str(entry.result.get("reason", "")))
	a.equal(reasons, [PlayerCommandsScript.REFUSED_UNKNOWN, PlayerCommandsScript.REFUSED_BAD_TARGET],
		"an unknown power and a bad target are refused, each with its reason")
	a.equal(Helpers.world_fingerprint(ordered), Helpers.world_fingerprint(plain), "and the world is as if they never were")
	a.equal(int(ordered.world_state.player.budget[MARK].get("cooldown_until", 0.0)), 0, "nothing is paid for a refusal")
	Helpers.destroy_manager(ordered)
	Helpers.destroy_manager(plain)


func _test_paused_orders_wait_and_a_new_world_forgets_them(a) -> void:
	var manager = Helpers.create_manager(9705)
	var world = manager.world_state
	_arm(world)
	var deer = Helpers.spawn_herbivore(world, Vector2(90.0, 90.0), 0)
	manager.set_paused(true)
	manager.enqueue_command(MARK, {"agent_id": deer.id, "hunger": 12.0})
	manager._process(0.5)
	a.equal(manager.pending_commands().size(), 1, "a paused game holds the order")
	a.is_true(world.player.journal.is_empty(), "and carries out nothing")
	manager.set_paused(false)
	manager.step_once()
	a.equal(world.player.journal.size(), 1, "the first tick after it carries it out")
	manager.enqueue_command(MARK, {"agent_id": deer.id})
	manager.initialize(Helpers.build_test_bundle(9705), 9705)
	a.is_true(manager.pending_commands().is_empty(), "a new world forgets the orders given to the last one")
	Helpers.destroy_manager(manager)


## The worker sends the player's state when it moves and with every full snapshot, so a frame
## lost to a sequence gap does not leave the view's charges behind.
func _test_view_follows_the_budget_across_a_lost_frame(a) -> void:
	var manager = SimulationTests._build_worker_fixture(9706)
	var target: int = manager.world_state.get_living_agents()[0].id
	_arm(manager.world_state, 3, 0.0)
	manager.enable_interactive_worker()
	var worker = manager._worker
	_arm(worker.world, 3, 0.0)
	_arm(manager.world_state, 3, 0.0)
	var announced := [0]
	manager.player_state_changed.connect(func() -> void: announced[0] += 1)
	var lod: Dictionary = manager._build_lod_context()
	var first: Dictionary = worker.step(manager.tick_duration, 0, 0.0, lod, -1, false, false, 0,
		[PlayerCommandsScript.make(1, MARK, {"agent_id": target})])
	a.is_true(first.has("player"), "a frame carries the player's state when it moved")
	manager._apply_worker_frame(first)
	a.equal(int(manager.world_state.player.budget[MARK].charges), 2, "and the view takes the spent charge")
	a.equal(announced[0], 1, "announced once")
	var second: Dictionary = worker.step(manager.tick_duration, 1, manager.tick_duration, lod, -1)
	a.is_true(not second.has("player"), "a frame where nothing moved leaves it out")
	manager._apply_worker_frame(second)
	# This frame is lost: the view never applies it.
	worker.step(manager.tick_duration, 2, manager.tick_duration * 2.0, lod, -1, false, false, 0,
		[PlayerCommandsScript.make(2, MARK, {"agent_id": target})])
	var fourth: Dictionary = worker.step(manager.tick_duration, 3, manager.tick_duration * 3.0, lod, -1)
	manager._apply_worker_frame(fourth)
	a.equal(int(manager.world_state.player.budget[MARK].charges), 1, "the full snapshot after a lost frame brings the charge spent in it")
	a.equal(announced[0], 2, "and announces it")
	manager._apply_worker_frame(fourth)
	a.equal(int(manager.world_state.player.budget[MARK].charges), 1, "a frame applied twice leaves the view as once")
	Helpers.destroy_manager(manager)
