extends RefCounted

const AgentAction := preload("res://scripts/agents/ai/agent_action.gd")
const TestHelpers := preload("res://scripts/tests/test_helpers.gd")
const GrazeUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/graze_utility_evaluator.gd")
const ExploreUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/explore_utility_evaluator.gd")
const DrinkUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/drink_utility_evaluator.gd")
const RestUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/rest_utility_evaluator.gd")
const FleeUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/flee_utility_evaluator.gd")
const HuntPreyUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/hunt_prey_utility_evaluator.gd")
const PatrolUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/patrol_utility_evaluator.gd")
const ScavengeCarcassUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/scavenge_carcass_utility_evaluator.gd")


func run(asserts) -> void:
	var graze_context = TestHelpers.build_context({
		"hunger": 0.92,
		"food_proximity": 0.9,
		"food_biomass": 1.0,
		"threat": 0.08,
		"thirst": 0.2,
		"water_proximity": 0.1,
		"fatigue": 0.18,
		"low_urgency": 0.1,
		"resource_scarcity": 0.0,
	})
	var graze_score := float(GrazeUtilityEvaluatorScript.new().evaluate(null, graze_context).get("score", 0.0))
	var explore_score := float(ExploreUtilityEvaluatorScript.new().evaluate(null, graze_context).get("score", 0.0))
	asserts.greater(graze_score, explore_score, "graze should beat explore when hunger is high and food is nearby")

	var drink_context = TestHelpers.build_context({
		"hunger": 0.25,
		"food_proximity": 0.55,
		"thirst": 0.95,
		"water_proximity": 0.95,
		"water_threat": 0.05,
		"threat": 0.05,
	})
	var drink_score := float(DrinkUtilityEvaluatorScript.new().evaluate(null, drink_context).get("score", 0.0))
	var graze_vs_drink := float(GrazeUtilityEvaluatorScript.new().evaluate(null, drink_context).get("score", 0.0))
	asserts.greater(drink_score, graze_vs_drink, "drink should beat graze when thirst and water proximity are high")

	var flee_context = TestHelpers.build_context({
		"threat": 0.95,
		"predator_visible_ratio": 1.0,
		"open_area_ratio": 1.0,
		"energy_ratio": 0.3,
		"safe_zone_proximity": 0.8,
		"fatigue": 0.25,
		"hunger": 0.2,
		"thirst": 0.2,
		"safe_biome_score": 0.2,
	})
	var flee_score := float(FleeUtilityEvaluatorScript.new().evaluate(null, flee_context).get("score", 0.0))
	var rest_score := float(RestUtilityEvaluatorScript.new().evaluate(null, flee_context).get("score", 0.0))
	asserts.greater(flee_score, rest_score, "flee should beat rest when a predator is visible and threat is high")

	var rest_context = TestHelpers.build_context({
		"fatigue": 0.92,
		"safe_biome_score": 0.95,
		"threat": 0.05,
		"hunger": 0.08,
		"thirst": 0.08,
	})
	var calm_rest_score := float(RestUtilityEvaluatorScript.new().evaluate(null, rest_context).get("score", 0.0))
	var calm_explore_score := float(ExploreUtilityEvaluatorScript.new().evaluate(null, rest_context).get("score", 0.0))
	asserts.greater(calm_rest_score, calm_explore_score, "rest should beat explore when fatigue is high and threat is low")

	var hunt_context = TestHelpers.build_context({
		"hunger": 0.9,
		"prey_quality": 0.85,
		"prey_proximity": 0.8,
		"energy_ratio": 0.9,
		"low_urgency": 0.1,
		"no_targets_score": 0.0,
	})
	var hunt_score := float(HuntPreyUtilityEvaluatorScript.new().evaluate(null, hunt_context).get("score", 0.0))
	var patrol_score := float(PatrolUtilityEvaluatorScript.new().evaluate(null, hunt_context).get("score", 0.0))
	asserts.greater(hunt_score, patrol_score, "hunt should beat patrol when hunger is high and prey is available")

	var scavenge_context = TestHelpers.build_context({
		"hunger": 0.82,
		"carcass_proximity": 0.92,
		"carcass_meat": 0.88,
		"prey_scarcity": 0.9,
		"low_urgency": 0.1,
		"no_targets_score": 0.0,
	})
	var scavenge_score := float(ScavengeCarcassUtilityEvaluatorScript.new().evaluate(null, scavenge_context).get("score", 0.0))
	var fallback_patrol := float(PatrolUtilityEvaluatorScript.new().evaluate(null, scavenge_context).get("score", 0.0))
	asserts.greater(scavenge_score, fallback_patrol, "scavenge should beat patrol when carcass opportunity is strong")
