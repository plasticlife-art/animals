extends RefCounted

## Hunting as a pair (`species.predator.hunt.pair`): a fox joins the prey its mate chases, seen
## through the mate's eyes; the farther cuts it off ("flank") for a point ahead of it on its own
## side, the nearer drives; a blow struck with the mate at the prey is surer; sleeping pairs
## count for more; and without the block every fox hunts alone, as before.

const Helpers := preload("res://scripts/tests/test_helpers.gd")
const AgentBaseScript := preload("res://scripts/agents/agent_base.gd")
const PAIR := {
	"join_vision_share": 1.5,
	"lateral_attack_radii": 2.0,
	"close_attack_radii": 2.5,
	"lead_max_seconds": 1.5,
	"attack_bonus": 0.12,
	"close_partner_attack_radii": 1.5,
	"dormant_kill_multiplier": 0.3,
}
const DEER_AT := Vector2(1500.0, 1500.0)


func run(a) -> void:
	_test_the_flank_point(a)
	_test_a_mate_joins_and_the_roles_hold(a)
	_test_the_blow_with_the_mate(a)
	_test_sleeping_pairs_count_more(a)
	_test_a_pair_hunts_a_herd(a)


static func _world(seed: int, pair: bool):
	var bundle := Helpers.build_large_sector_bundle(seed)
	if pair:
		bundle["species"]["predator"]["hunt"]["pair"] = PAIR.duplicate(true)
	var manager = Helpers.create_manager_with(bundle, seed)
	manager.set_lod_enabled(false)
	return manager


## A bonded pair: a dog fox at `male_at`, a vixen at `female_at`, both hungry.
static func _pair(world, male_at: Vector2, female_at: Vector2) -> Array:
	var male = Helpers.spawn_predator(world, male_at)
	var female = Helpers.spawn_species(world, "predator", female_at, -1, AgentBaseScript.SEX_FEMALE)
	male.set_preferred_mate_id(female.id)
	female.set_preferred_mate_id(male.id)
	for fox in [male, female]:
		fox.hunger = 60.0
	return [male, female]


func _test_the_flank_point(a) -> void:
	var prey := Vector2.ZERO
	var running := Vector2(100.0, 0.0)
	var driver := Vector2(-200.0, 0.0)
	var flanker := Vector2(0.0, 300.0)
	var point := Predator.flank_point(prey, running, driver, flanker, 128.0, 120.0, 1.5)
	a.is_true(point.x > 0.0, "ahead of the prey (%s)" % point)
	a.is_true(point.y > 0.0, "on the flanker's side")
	var close := Predator.flank_point(prey, running, driver, Vector2(10.0, 40.0), 128.0, 120.0, 1.5)
	a.is_true(absf(close.y) < absf(point.y), "the offset fading as it closes in (%s)" % close)
	var still := Predator.flank_point(prey, Vector2.ZERO, driver, flanker, 128.0, 120.0, 1.5)
	a.is_true(still.is_finite() and still.distance_to(prey) <= 130.0, "a standing prey: beside it (%s)" % still)


func _test_a_mate_joins_and_the_roles_hold(a) -> void:
	var manager = _world(9981, true)
	var world = manager.world_state
	var deer = Helpers.spawn_herbivore(world, DEER_AT, 0)
	# One sees the deer; the other is past its own sight of it but within the pair's.
	var foxes := _pair(world, DEER_AT + Vector2(-200.0, 0.0), DEER_AT + Vector2(0.0, 600.0))
	var driver = foxes[0]
	var flanker = foxes[1]
	driver.target_agent_id = deer.id
	driver.state = "chase"
	a.equal(flanker._choose_prey(world), deer, "the mate's prey, beyond its own sight")
	a.is_true(flanker._mate_sees(world, deer), "seen through the mate's eyes")
	flanker.target_agent_id = deer.id
	flanker.state = "chase"
	a.equal([flanker._pair_role_for(world, deer), driver._pair_role_for(world, deer)], ["flank", "drive"],
		"the farther cuts it off, the nearer drives")
	flanker.position = DEER_AT + Vector2(-50.0, 0.0)
	a.equal(flanker._pair_role_for(world, deer), "flank", "and keeps to it when the two cross")
	a.equal(int(manager.stats_system.counters.get("pair_hunts", 0)), 1, "one hunt as a pair, counted")
	flanker.clear_targets(world)
	a.equal(flanker._pair_role, "", "a hunt over, its part is let go")
	var alone = _world(9981, false)
	var solo := _pair(alone.world_state, DEER_AT + Vector2(-200.0, 0.0), DEER_AT + Vector2(0.0, 600.0))
	var other_deer = Helpers.spawn_herbivore(alone.world_state, DEER_AT, 0)
	solo[0].target_agent_id = other_deer.id
	solo[0].state = "chase"
	a.is_true(solo[1]._pair_mate(alone.world_state) == null and solo[1]._choose_prey(alone.world_state) == null,
		"without the block: each for itself, and nothing past its own sight")
	Helpers.destroy_manager(alone)
	Helpers.destroy_manager(manager)


func _test_the_blow_with_the_mate(a) -> void:
	var manager = _world(9982, true)
	var world = manager.world_state
	var deer = Helpers.spawn_herbivore(world, DEER_AT, 0)
	var foxes := _pair(world, DEER_AT + Vector2(-20.0, 0.0), DEER_AT + Vector2(0.0, 400.0))
	foxes[1].target_agent_id = deer.id
	foxes[1].state = "chase"
	a.is_true(not foxes[0]._mate_at_the_prey(world, deer), "the mate far off: alone")
	foxes[1].position = DEER_AT + Vector2(0.0, 40.0)
	a.is_true(foxes[0]._mate_at_the_prey(world, deer), "the mate at the prey: together")
	Helpers.destroy_manager(manager)


func _test_sleeping_pairs_count_more(a) -> void:
	var manager = _world(9983, true)
	var world = manager.world_state
	var members := [
		{"id": 1, "hunger": 50.0, "preferred_mate_id": 2},
		{"id": 2, "hunger": 50.0, "preferred_mate_id": 1},
		{"id": 3, "hunger": 50.0, "preferred_mate_id": 4},
		{"id": 4, "hunger": 10.0, "preferred_mate_id": 3},
	]
	a.equal(world._dormant_paired_hungry(members), 2, "the two hungry mates, not the one whose mate is fed")
	Helpers.destroy_manager(manager)


## A pair let loose by a small herd: hunts as a pair are struck up, and one of the two cuts off.
func _test_a_pair_hunts_a_herd(a) -> void:
	var manager = _world(9984, true)
	var world = manager.world_state
	Helpers.spawn_herd(world, DEER_AT, 6, 0)
	var foxes := _pair(world, DEER_AT + Vector2(-260.0, -40.0), DEER_AT + Vector2(-240.0, 120.0))
	var flanked := false
	for _tick in range(240):
		manager.step_once()
		for fox in foxes:
			if fox.is_alive and fox.state == "flank":
				flanked = true
	a.is_true(int(manager.stats_system.counters.get("pair_hunts", 0)) >= 1, "a hunt as a pair (%d)" % int(manager.stats_system.counters.get("pair_hunts", 0)))
	a.is_true(flanked, "one of them cutting the prey off")
	Helpers.destroy_manager(manager)
