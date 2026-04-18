extends RefCounted

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const TestHelpers := preload("res://scripts/tests/test_helpers.gd")


func run(asserts) -> void:
	_test_thirsty_herbivore(asserts)
	_test_panic_herbivore(asserts)
	_test_resting_herbivore(asserts)
	_test_hunting_predator(asserts)
	_test_scavenging_predator(asserts)
	_test_determinism(asserts)


func _test_thirsty_herbivore(asserts) -> void:
	var manager = TestHelpers.create_manager(31)
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(72.0, 72.0), 0)
	herbivore.thirst = 92.0
	herbivore.hunger = 12.0
	herbivore.energy = 82.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(herbivore.current_action, AgentAction.DRINK, "thirsty herbivore near safe water should choose drink")
	manager.free()


func _test_panic_herbivore(asserts) -> void:
	var manager = TestHelpers.create_manager(32)
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(108.0, 96.0), 0)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(120.0, 96.0))
	herbivore.hunger = 90.0
	herbivore.thirst = 18.0
	herbivore.energy = 84.0
	predator.hunger = 20.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(herbivore.current_action, AgentAction.FLEE_TO_SAFE_AREA, "herbivore near predator should not keep grazing")
	manager.free()


func _test_resting_herbivore(asserts) -> void:
	var manager = TestHelpers.create_manager(33)
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(196.0, 196.0), 0)
	herbivore.hunger = 5.0
	herbivore.thirst = 5.0
	herbivore.energy = 6.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(herbivore.current_action, AgentAction.REST, "tired herbivore in safe terrain should choose rest")
	manager.free()


func _test_hunting_predator(asserts) -> void:
	var manager = TestHelpers.create_manager(34)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(100.0, 100.0))
	var herbivore = TestHelpers.spawn_herbivore(manager.world_state, Vector2(118.0, 100.0), 0)
	predator.hunger = 92.0
	predator.energy = 140.0
	herbivore.energy = 40.0
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(predator.current_action, AgentAction.HUNT_PREY, "hungry predator with reachable prey should enter hunt flow")
	manager.free()


func _test_scavenging_predator(asserts) -> void:
	var manager = TestHelpers.create_manager(35)
	var predator = TestHelpers.spawn_predator(manager.world_state, Vector2(112.0, 112.0))
	predator.hunger = 92.0
	predator.energy = 130.0
	TestHelpers.spawn_carcass(manager.world_state, Vector2(120.0, 112.0), 90.0)
	TestHelpers.run_ticks(manager, 1)
	asserts.equal(predator.current_action, AgentAction.SCAVENGE_CARCASS, "hungry predator near carcass should choose scavenging")
	manager.free()


func _test_determinism(asserts) -> void:
	var manager_a = TestHelpers.create_manager(36)
	var herbivore_a = TestHelpers.spawn_herbivore(manager_a.world_state, Vector2(104.0, 104.0), 0)
	var predator_a = TestHelpers.spawn_predator(manager_a.world_state, Vector2(132.0, 104.0))
	herbivore_a.hunger = 62.0
	herbivore_a.thirst = 24.0
	herbivore_a.energy = 78.0
	predator_a.hunger = 74.0
	predator_a.energy = 135.0
	var trace_a := TestHelpers.capture_trace(manager_a, [herbivore_a.id, predator_a.id], 18)

	var manager_b = TestHelpers.create_manager(36)
	var herbivore_b = TestHelpers.spawn_herbivore(manager_b.world_state, Vector2(104.0, 104.0), 0)
	var predator_b = TestHelpers.spawn_predator(manager_b.world_state, Vector2(132.0, 104.0))
	herbivore_b.hunger = 62.0
	herbivore_b.thirst = 24.0
	herbivore_b.energy = 78.0
	predator_b.hunger = 74.0
	predator_b.energy = 135.0
	var trace_b := TestHelpers.capture_trace(manager_b, [herbivore_b.id, predator_b.id], 18)

	asserts.equal(JSON.stringify(trace_a), JSON.stringify(trace_b), "same seed and setup should produce identical action/state traces")
	manager_a.free()
	manager_b.free()
