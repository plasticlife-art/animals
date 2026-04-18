extends RefCounted

const AgentAIState := preload("res://scripts/agents/ai/agent_ai_state.gd")
const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const ActionSelectorScript := preload("res://scripts/agents/ai/action_selector.gd")
const TestHelpers := preload("res://scripts/tests/test_helpers.gd")


class FixedEvaluator:
	extends RefCounted

	var fixed_score: float = 0.0

	func _init(score: float) -> void:
		fixed_score = score

	func evaluate(_agent, _context) -> Dictionary:
		return {"score": fixed_score, "reasons": []}


class AgentStub:
	extends RefCounted

	var current_action: StringName = AgentAction.NONE
	var action_ticks: int = 0

	func get_ticks_in_current_action(_current_tick: int) -> int:
		return action_ticks


func run(asserts) -> void:
	var selector = ActionSelectorScript.new({
		"stickiness_bonus": 0.10,
		"switch_threshold_delta": 0.15,
		"minimum_commitment_ticks": 6,
	})
	var policy = TestHelpers.build_policy(AgentAIState.ALIVE, [AgentAction.GRAZE, AgentAction.DRINK])
	var context = TestHelpers.build_context({})

	var fresh_agent := AgentStub.new()
	var direct_pick = selector.select(fresh_agent, policy, context, {
		AgentAction.GRAZE: FixedEvaluator.new(0.55),
		AgentAction.DRINK: FixedEvaluator.new(0.82),
	}, 12, false)
	asserts.equal(direct_pick.selected_action, AgentAction.DRINK, "selector should pick the highest utility action")

	var sticky_agent := AgentStub.new()
	sticky_agent.current_action = AgentAction.GRAZE
	sticky_agent.action_ticks = 9
	var sticky_pick = selector.select(sticky_agent, policy, context, {
		AgentAction.GRAZE: FixedEvaluator.new(0.62),
		AgentAction.DRINK: FixedEvaluator.new(0.68),
	}, 20, false)
	asserts.equal(sticky_pick.selected_action, AgentAction.GRAZE, "selector should keep current action when stickiness closes the score gap")

	var commitment_agent := AgentStub.new()
	commitment_agent.current_action = AgentAction.GRAZE
	commitment_agent.action_ticks = 2
	var commitment_pick = selector.select(commitment_agent, policy, context, {
		AgentAction.GRAZE: FixedEvaluator.new(0.15),
		AgentAction.DRINK: FixedEvaluator.new(0.95),
	}, 20, false)
	asserts.equal(commitment_pick.selected_action, AgentAction.GRAZE, "selector should honor minimum commitment time")

	var threshold_agent := AgentStub.new()
	threshold_agent.current_action = AgentAction.GRAZE
	threshold_agent.action_ticks = 10
	var threshold_pick = selector.select(threshold_agent, policy, context, {
		AgentAction.GRAZE: FixedEvaluator.new(0.50),
		AgentAction.DRINK: FixedEvaluator.new(0.62),
	}, 20, false)
	asserts.equal(threshold_pick.selected_action, AgentAction.GRAZE, "selector should not switch without beating the current action by delta")

	var interrupt_agent := AgentStub.new()
	interrupt_agent.current_action = AgentAction.GRAZE
	interrupt_agent.action_ticks = 1
	var interrupt_pick = selector.select(interrupt_agent, policy, context, {
		AgentAction.GRAZE: FixedEvaluator.new(0.15),
		AgentAction.DRINK: FixedEvaluator.new(0.95),
	}, 20, true)
	asserts.equal(interrupt_pick.selected_action, AgentAction.DRINK, "selector should bypass commitment rules on forced interrupt")
