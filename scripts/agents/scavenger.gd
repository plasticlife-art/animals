class_name Scavenger
extends Herbivore

## A flocking animal that eats the dead.
##
## Extends `Herbivore` for its behaviour, not its diet: that file is the herd
## template - flock, flee, drink, rest, explore, breed - and the food source is
## the one thing a subclass replaces. `species_type` carries the actual identity,
## and `role.script` in species.json is what picks this class. (The base class
## deserves a name that says "herd animal" rather than "herbivore"; renaming it
## touches every preload and is left for a quiet tree.)
##
## Feeding itself is `AgentBase.scavenge_or_feed()`, shared with the predator,
## including the reservation ledger that stops two animals eating the same meat.

const ScavengerAIScript := preload("res://scripts/agents/ai/scavenger_ai.gd")


func configure(
	agent_id: int,
	new_species_type: String,
	spawn_position: Vector2,
	new_sex: String,
	species_config: Dictionary,
	balance_config: Dictionary,
	rng: RandomNumberGenerator,
	new_group_id: int = -1
) -> void:
	super.configure(agent_id, new_species_type, spawn_position, new_sex, species_config, balance_config, rng, new_group_id)
	_ai_controller = ScavengerAIScript.new(balance_config)
	debug_color = Color(0.86, 0.74, 0.38)


func _build_snapshot(world, known_predators = null):
	return world.build_scavenger_snapshot(self, known_predators)


## Carrion, where the herd template would graze. Every other arm of the parent's
## dispatch - drink, rest, flock, explore, flee - is inherited unchanged.
func _execute_selected_action(world, delta: float, neighbors: Array, predators: Array, action_name: StringName, snapshot = null) -> void:
	if action_name != AgentAction.SCAVENGE_CARCASS:
		super._execute_selected_action(world, delta, neighbors, predators, action_name, snapshot)
		return
	var carcass_target: Dictionary = {} if snapshot == null else snapshot.carcass_target
	if not scavenge_or_feed(world, delta, carcass_target):
		_explore(world, delta, neighbors)


## Mid-meal, for the gorging rule in `AgentBase.is_hungry_enough_to_feed()`.
func can_continue_feeding() -> bool:
	return current_action == AgentAction.SCAVENGE_CARCASS or state in ["seek_carcass", "feed_carcass"]


func clear_targets(world = null) -> void:
	if world != null:
		release_carcass_target(world)
	else:
		target_carcass_id = -1
	super.clear_targets()


func _get_debug_target_text() -> String:
	if target_carcass_id != -1:
		return "carcass:%d" % target_carcass_id
	return super._get_debug_target_text()
