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
const AgentActionScript := preload("res://scripts/agents/ai/agent_action.gd")
const PairCohesionUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/pair_cohesion_utility_evaluator.gd")
const ScavengeCarcassUtilityEvaluatorScript := preload("res://scripts/agents/ai/evaluators/scavenge_carcass_utility_evaluator.gd")


func run(asserts) -> void:
	_test_night_rest_bias(asserts)
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

	var sated_graze_context = TestHelpers.build_context({
		"hunger": 0.04,
		"food_proximity": 0.95,
		"food_biomass": 1.0,
		"threat": 0.0,
		"thirst": 0.1,
		"water_proximity": 0.1,
		"fatigue": 0.1,
		"graze_allowed": 0.0,
		"low_urgency": 0.9,
		"resource_scarcity": 0.0,
	})
	var sated_graze_score := float(GrazeUtilityEvaluatorScript.new().evaluate(null, sated_graze_context).get("score", 0.0))
	var sated_explore_score := float(ExploreUtilityEvaluatorScript.new().evaluate(null, sated_graze_context).get("score", 0.0))
	asserts.is_true(sated_graze_score < sated_explore_score, "graze should drop below explore when hunger is below the graze floor")

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

	# `no_targets_score` is derived as `1 - max(prey_quality, ...)` in
	# `PredatorAI.build_context()`, so it has to be consistent with `prey_quality` here.
	# It used to be hand-set to 0.0 alongside a prey_quality of 0.85 - a combination the
	# real context cannot produce - which is why this test passed while a predator next to
	# a herd patrolled until it starved.
	var hunt_values := {
		"hunger": 0.9,
		"prey_quality": 0.85,
		"prey_proximity": 0.8,
		"energy_ratio": 0.9,
		"feeding_allowed": 1.0,
		"low_urgency": 0.1,
		"no_targets_score": 0.15,
	}
	var hunt_context = TestHelpers.build_context(hunt_values)
	var hunt_score := float(HuntPreyUtilityEvaluatorScript.new().evaluate(null, hunt_context).get("score", 0.0))
	var patrol_score := float(PatrolUtilityEvaluatorScript.new().evaluate(null, hunt_context).get("score", 0.0))
	asserts.greater(hunt_score, patrol_score, "hunt should beat patrol when hunger is high and prey is available")

	# With an actual prey target in the context, patrol is not merely outscored - it is
	# removed from the candidate set, so the selector's stickiness and switch threshold
	# cannot keep an incumbent patrol alive.
	var modest_hunger_values := hunt_values.duplicate(true)
	modest_hunger_values["hunger"] = 0.2
	modest_hunger_values["low_urgency"] = 0.8
	var targeted_context = TestHelpers.build_context(
		modest_hunger_values,
		{AgentActionScript.HUNT_PREY: {"agent_id": 7, "position": Vector2.ZERO}}
	)
	var targeted_patrol: Dictionary = PatrolUtilityEvaluatorScript.new().evaluate(null, targeted_context)
	asserts.is_true(bool(targeted_patrol.get("vetoed", false)), "patrol should veto outright while a hungry predator has prey in reach")
	var targeted_cohesion: Dictionary = PairCohesionUtilityEvaluatorScript.new().evaluate(null, targeted_context)
	asserts.is_true(bool(targeted_cohesion.get("vetoed", false)), "pair cohesion should veto outright while a hungry predator has prey in reach")

	var sated_hunt_context = TestHelpers.build_context({
		"hunger": 0.02,
		"prey_quality": 0.95,
		"prey_proximity": 0.95,
		"energy_ratio": 0.95,
		"feeding_allowed": 0.0,
		"low_urgency": 0.9,
		"no_targets_score": 0.0,
	})
	var sated_hunt_score := float(HuntPreyUtilityEvaluatorScript.new().evaluate(null, sated_hunt_context).get("score", 0.0))
	var sated_patrol_score := float(PatrolUtilityEvaluatorScript.new().evaluate(null, sated_hunt_context).get("score", 0.0))
	asserts.is_true(sated_hunt_score < sated_patrol_score, "hunt should drop below patrol when hunger is below the feed floor")

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

	var sated_scavenge_context = TestHelpers.build_context({
		"hunger": 0.03,
		"carcass_proximity": 0.95,
		"carcass_meat": 1.0,
		"prey_scarcity": 0.9,
		"feeding_allowed": 0.0,
		"low_urgency": 0.9,
		"no_targets_score": 0.0,
	})
	var sated_scavenge_score := float(ScavengeCarcassUtilityEvaluatorScript.new().evaluate(null, sated_scavenge_context).get("score", 0.0))
	var sated_scavenge_patrol := float(PatrolUtilityEvaluatorScript.new().evaluate(null, sated_scavenge_context).get("score", 0.0))
	asserts.is_true(sated_scavenge_score < sated_scavenge_patrol, "scavenge should drop below patrol when hunger is below the feed floor")

	var graze_veto: Dictionary = GrazeUtilityEvaluatorScript.new().evaluate(null, sated_graze_context)
	var hunt_veto: Dictionary = HuntPreyUtilityEvaluatorScript.new().evaluate(null, sated_hunt_context)
	var scavenge_veto: Dictionary = ScavengeCarcassUtilityEvaluatorScript.new().evaluate(null, sated_scavenge_context)
	asserts.is_true(bool(graze_veto.get("vetoed", false)), "graze below the hunger floor should be vetoed, not merely scored low")
	asserts.is_true(bool(hunt_veto.get("vetoed", false)), "hunt below the feed floor should be vetoed, not merely scored low")
	asserts.is_true(bool(scavenge_veto.get("vetoed", false)), "scavenge below the feed floor should be vetoed, not merely scored low")
	asserts.is_true(graze_veto.get("score", 0.0) < 0.0, "a veto must survive result clamping as a negative score")


## The shipped weights, so these fail if balance.json drifts out from under the
## feature rather than quietly passing against defaults.
const HERBIVORE_NIGHT_REST_WEIGHT := 0.30
const HERBIVORE_NIGHT_EXPLORE_PENALTY := 0.30


func _calm_night_values(night: float) -> Dictionary:
	return {
		"hunger": 0.08, "thirst": 0.06, "fatigue": 0.4, "threat": 0.0,
		"safe_biome_score": 0.4, "low_urgency": 0.8, "resource_scarcity": 0.5,
		"food_proximity": 0.2, "food_biomass": 0.6, "water_proximity": 0.1,
		"night_ratio": night,
	}


func _test_night_rest_bias(asserts) -> void:
	var rest_config := {"night_weight": HERBIVORE_NIGHT_REST_WEIGHT}
	var explore_config := {"night_penalty": HERBIVORE_NIGHT_EXPLORE_PENALTY}
	var rest_evaluator = RestUtilityEvaluatorScript.new(rest_config)
	var explore_evaluator = ExploreUtilityEvaluatorScript.new(explore_config)

	var day_context = TestHelpers.build_context(_calm_night_values(0.0))
	var night_context = TestHelpers.build_context(_calm_night_values(1.0))

	var rest_day := float(rest_evaluator.evaluate(null, day_context).get("score", 0.0))
	var rest_night := float(rest_evaluator.evaluate(null, night_context).get("score", 0.0))
	var explore_day := float(explore_evaluator.evaluate(null, day_context).get("score", 0.0))
	var explore_night := float(explore_evaluator.evaluate(null, night_context).get("score", 0.0))

	asserts.near(rest_night - rest_day, HERBIVORE_NIGHT_REST_WEIGHT, 0.0001,
		"night should raise rest by exactly its weight")
	asserts.near(explore_day - explore_night, HERBIVORE_NIGHT_EXPLORE_PENALTY, 0.0001,
		"night should lower explore by exactly its penalty")

	# The actual requirement: a calm, fed herd beds down at night and moves by day.
	asserts.greater(explore_day, rest_day, "a calm herd should wander during the day")
	asserts.greater(rest_night, explore_night, "a calm herd should bed down at night")

	# And the guard against a weight tuned so high that herds starve in their
	# sleep - hunger has to keep winning in the dark.
	var hungry_values: Dictionary = _calm_night_values(1.0)
	hungry_values["hunger"] = 0.5
	hungry_values["food_proximity"] = 0.8
	hungry_values["food_biomass"] = 0.5
	hungry_values["low_urgency"] = 0.1
	var hungry_night = TestHelpers.build_context(hungry_values)
	var graze_score := float(GrazeUtilityEvaluatorScript.new().evaluate(null, hungry_night).get("score", 0.0))
	var rest_hungry := float(rest_evaluator.evaluate(null, hungry_night).get("score", 0.0))
	asserts.greater(graze_score, rest_hungry, "a hungry herbivore should still graze at night")

	# Predators get no night rest weight at all - the code default is zero, which
	# is what makes the shrunken herbivore vision worth anything.
	var default_rest = RestUtilityEvaluatorScript.new()
	asserts.near(
		float(default_rest.evaluate(null, night_context).get("score", 0.0)),
		float(default_rest.evaluate(null, day_context).get("score", 0.0)), 0.0001,
		"without a configured weight, night must not move rest at all")
