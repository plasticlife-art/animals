class_name AgentPerceptionSnapshot
extends RefCounted

var built_at_tick: int = -1
var built_at_time: float = 0.0
var species_neighbors: Array = []
var group_neighbors: Array = []
var predators: Array = []
var prey_candidates: Array = []
var carcasses: Array = []
var water_sources: Array = []
var water_target: Dictionary = {}
var grass_target: Dictionary = {}
var prey_target = null
var carcass_target: Dictionary = {}
var investigation_source: Dictionary = {}
var mate_target = null
var group_center = null
var kin_center = null
var values: Dictionary = {}
