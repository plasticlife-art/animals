extends RefCounted

const AgentAIState := preload("res://scripts/agents/ai/agent_ai_state.gd")
const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const HerbivoreAIScript := preload("res://scripts/agents/ai/herbivore_ai.gd")
const PredatorAIScript := preload("res://scripts/agents/ai/predator_ai.gd")
const TestHelpers := preload("res://scripts/tests/test_helpers.gd")


class HerbivoreStub:
	extends RefCounted

	var is_alive: bool = true
	var ai_state: StringName = AgentAIState.ALIVE
	var current_action: StringName = AgentAction.NONE
	var action_target_failure_ticks: int = 0


class PredatorStub:
	extends RefCounted

	var is_alive: bool = true
	var state: String = "idle"
	var target_agent_id: int = -1
	var target_carcass_id: int = -1
	var ai_state: StringName = AgentAIState.ALIVE
	var current_action: StringName = AgentAction.NONE
	var action_target_failure_ticks: int = 0


func run(asserts) -> void:
	var herbivore_ai = HerbivoreAIScript.new({})
	var predator_ai = PredatorAIScript.new({})

	var alive_policy = herbivore_ai.get_policy(AgentAIState.ALIVE)
	asserts.is_true(alive_policy.is_action_allowed(AgentAction.GRAZE), "alive herbivore policy should allow graze")
	asserts.is_true(alive_policy.is_action_allowed(AgentAction.DRINK), "alive herbivore policy should allow drink")
	asserts.is_true(alive_policy.is_action_allowed(AgentAction.EXPLORE), "alive herbivore policy should allow explore")

	var panic_policy = herbivore_ai.get_policy(AgentAIState.PANIC)
	asserts.equal(panic_policy.get_allowed_actions().size(), 2, "panic herbivore policy should expose exactly two actions")
	asserts.is_true(panic_policy.is_action_allowed(AgentAction.FLEE_TO_SAFE_AREA), "panic herbivore policy should allow flee")
	asserts.is_true(not panic_policy.is_action_allowed(AgentAction.REST), "panic herbivore policy should block rest")

	var dead_policy = herbivore_ai.get_policy(AgentAIState.DEAD)
	asserts.equal(dead_policy.get_allowed_actions().size(), 0, "dead herbivore policy should not allow actions")

	var herbivore_stub := HerbivoreStub.new()
	var panic_context = TestHelpers.build_context({
		"predator_visible_ratio": 1.0,
		"threat": 0.9,
	})
	asserts.equal(herbivore_ai.resolve_state(herbivore_stub, panic_context), AgentAIState.PANIC, "herbivore should resolve to panic under visible predator threat")
	herbivore_stub.is_alive = false
	asserts.equal(herbivore_ai.resolve_state(herbivore_stub, panic_context), AgentAIState.DEAD, "dead herbivore should resolve to dead state")

	var predator_stub := PredatorStub.new()
	predator_stub.state = "chase"
	asserts.equal(predator_ai.resolve_state(predator_stub, TestHelpers.build_context({})), AgentAIState.ENGAGED, "predator chase flow should resolve to engaged state")
	var engaged_policy = predator_ai.get_policy(AgentAIState.ENGAGED)
	asserts.is_true(engaged_policy.is_locked, "engaged predator policy should be locked")
	asserts.equal(engaged_policy.get_allowed_actions().size(), 0, "engaged predator policy should bypass free utility actions")
