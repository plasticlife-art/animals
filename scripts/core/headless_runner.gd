class_name HeadlessRunner
extends Node

@export var total_ticks: int = 3600
@export var seed_override: int = -1
@export var export_on_finish: bool = true

const SimulationManagerScript = preload("res://scripts/core/simulation_manager.gd")


func _ready() -> void:
	var simulation_manager = SimulationManagerScript.new()
	add_child(simulation_manager)
	simulation_manager.initialize({}, seed_override)
	var result := simulation_manager.run_headless(total_ticks, export_on_finish)
	print("Headless run completed: ", result)
	get_tree().quit()
