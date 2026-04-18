class_name ActionSelector
extends RefCounted

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const ActionDecisionScript := preload("res://scripts/agents/ai/action_decision.gd")

var config: Dictionary = {}


func _init(new_config: Dictionary = {}) -> void:
	config = new_config.duplicate(true)


func select(
	agent,
	policy,
	context,
	evaluators: Dictionary,
	current_tick: int,
	force_interrupt: bool = false
):
	var allowed_actions: Array = policy.get_allowed_actions()
	if allowed_actions.is_empty():
		var empty_decision = ActionDecisionScript.new()
		empty_decision.selected_action = AgentAction.NONE
		empty_decision.reason = "no allowed actions"
		return empty_decision

	var stickiness_bonus := float(config.get("stickiness_bonus", 0.10))
	var switch_threshold_delta := float(config.get("switch_threshold_delta", 0.15))
	var minimum_commitment_ticks := maxi(0, int(config.get("minimum_commitment_ticks", 6)))

	var raw_scores := {}
	var final_scores := {}
	var reasons_by_action := {}
	var current_action: StringName = StringName(agent.current_action)
	for action_name in allowed_actions:
		var evaluator = evaluators.get(action_name, null)
		var evaluation := {"score": 0.0, "reasons": []}
		if evaluator != null and evaluator.has_method("evaluate"):
			evaluation = evaluator.evaluate(agent, context)
		var raw_score := float(evaluation.get("score", 0.0))
		raw_scores[action_name] = raw_score
		reasons_by_action[action_name] = evaluation.get("reasons", [])
		var final_score := raw_score + float(policy.get_state_modifier(action_name, context))
		if action_name == current_action:
			final_score += stickiness_bonus
		final_scores[action_name] = final_score

	var best_action: StringName = allowed_actions[0]
	var best_score: float = float(final_scores.get(best_action, -INF))
	for action_name in allowed_actions:
		var action_score := float(final_scores.get(action_name, -INF))
		if action_score > best_score:
			best_action = action_name
			best_score = action_score

	var chosen_action: StringName = best_action
	var did_switch := current_action != StringName() and current_action != best_action
	var reason := _build_base_reason(best_action, best_score, reasons_by_action)
	if current_action != StringName() and policy.is_action_allowed(current_action):
		var current_score := float(final_scores.get(current_action, -INF))
		var ticks_in_current_action: int = agent.get_ticks_in_current_action(current_tick)
		if current_action != best_action and not force_interrupt:
			if ticks_in_current_action < minimum_commitment_ticks:
				chosen_action = current_action
				did_switch = false
				reason = "kept %s during minimum commitment (%d/%d ticks)" % [
					String(current_action),
					ticks_in_current_action,
					minimum_commitment_ticks,
				]
			elif best_score <= current_score + switch_threshold_delta:
				chosen_action = current_action
				did_switch = false
				reason = "kept %s because %.2f does not beat %.2f + %.2f" % [
					String(current_action),
					best_score,
					current_score,
					switch_threshold_delta,
				]
		elif current_action == best_action:
			did_switch = false
			reason = "kept %s as top action" % String(current_action)
	elif force_interrupt and chosen_action != current_action:
		reason = "forced interrupt to %s; %s" % [String(chosen_action), reason]

	var target_data: Dictionary = context.get_target(chosen_action)
	var decision = ActionDecisionScript.new()
	decision.selected_action = chosen_action
	decision.raw_scores = raw_scores.duplicate(true)
	decision.final_scores = final_scores.duplicate(true)
	decision.reason = reason
	decision.target_data = target_data.duplicate(true)
	decision.switched = did_switch
	return decision


func _build_base_reason(best_action: StringName, best_score: float, reasons_by_action: Dictionary) -> String:
	var fragments: Array = reasons_by_action.get(best_action, [])
	var filtered: Array = []
	for fragment in fragments:
		var text := str(fragment)
		if text == "":
			continue
		filtered.append(text)
		if filtered.size() >= 3:
			break
	var suffix := "" if filtered.is_empty() else " (%s)" % ", ".join(filtered)
	return "selected %s at %.2f%s" % [String(best_action), best_score, suffix]
