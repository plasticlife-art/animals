class_name HareAI
extends "res://scripts/agents/ai/herbivore_ai.gd"

## A grass-eater that lives alone: the herd template's grazing, drinking, resting, exploring and
## panic, without seeking a herd to join, and tuned from its own `balance.json -> ai.hare` block.


func _config_key() -> String:
	return "hare"


func _alive_actions() -> Array:
	return [
		AgentAction.GRAZE,
		AgentAction.DRINK,
		AgentAction.REST,
		AgentAction.EXPLORE,
	]
