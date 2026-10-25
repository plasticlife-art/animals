class_name Hare
extends Herbivore

## A hare: the herd template (`Herbivore`) living alone. It grazes, drinks, rests, explores, flees
## and breeds as a deer does, but never looks for a herd (`HareAI`), and finds a mate among the
## hares about it (`social` solitary, group -1). What makes it a hare is in species.json: small,
## fast on the dash and soon tired, quick to breed, short-lived.

const HareAIScript := preload("res://scripts/agents/ai/hare_ai.gd")


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
	_ai_controller = HareAIScript.new(balance_config)
	debug_color = Color(0.78, 0.62, 0.44)
