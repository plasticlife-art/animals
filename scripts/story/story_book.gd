class_name StoryBook
extends RefCounted

## The world told as a story about its animals: a name for each (`AnimalNames`), who is
## whose (`Lineage`), and the few the player has pinned to keep an eye on, wherever they
## are. Fed from `SimulationManager.world_event` on the main thread; read by the animal's
## card, its tag, the pinned list and the event feed. Nothing here reaches the simulation:
## a pin keeps an animal on a list, not its sector awake, so a world plays the same with
## pins or without. Kept with the save (`export_state()`).

signal pins_changed

const AnimalNamesScript := preload("res://scripts/story/animal_names.gd")
const LineageScript := preload("res://scripts/story/lineage.gd")
const StoryLogScript := preload("res://scripts/story/story_log.gd")
const PlaceNamesScript := preload("res://scripts/story/place_names.gd")
const MAX_PINS := 8
const STATE_VERSION := 1

var names = AnimalNamesScript.new()
var lineage = LineageScript.new()
## The event feed's lines (`StoryLog`). Not saved: a loaded world starts a fresh feed.
var feed = StoryLogScript.new()
## The names of the world's ponds and districts (`PlaceNames`).
var places = PlaceNamesScript.new()
var pins: Array = []
var manager = null


func _init() -> void:
	lineage.forgotten.connect(names.forget)
	feed.book = self


func bind(simulation_manager) -> void:
	manager = simulation_manager
	if not manager.world_event.is_connected(hear):
		manager.world_event.connect(hear)


## A new world, or one loaded: the old one's names, family tree and pins go; `saved` - what
## a save kept - comes back instead. The world's places are named before anything is heard,
## and then the awake animals are met in id order, so the founders are named the same way
## each time.
func begin(saved: Dictionary = {}) -> void:
	names.clear()
	lineage.clear()
	pins.clear()
	feed.clear()
	places.build(null if manager == null else manager.world_state, 0 if manager == null else int(manager.seed))
	if int(saved.get("version", 0)) == STATE_VERSION:
		import_state(saved)
	meet_living()
	pins_changed.emit()


## Called on the interface's refresh: animals that woke since are named while they can still
## be asked their sex, and the feed closes its minute when it is over.
func tick(now: float) -> void:
	meet_living()
	feed.tick(now)


## Names every awake animal not yet named, lowest id first.
func meet_living() -> void:
	if manager == null or manager.world_state == null:
		return
	var ids: Array = []
	for agent in manager.world_state.get_living_agents():
		if agent != null and names.known(agent.id) == "":
			ids.append(agent.id)
	ids.sort()
	for agent_id in ids:
		name_of(manager.world_state.get_agent(agent_id))


func hear(event: Dictionary) -> void:
	var data: Dictionary = event.get("data", {})
	var agent_id := int(event.get("agent_id", -1))
	var species := str(event.get("species", ""))
	var time := float(event.get("time_seconds", 0.0))
	match str(event.get("type", "")):
		"AgentBorn":
			# Asleep, the newborn has no agent and its id travels in the data.
			var born := agent_id if agent_id >= 0 else int(data.get("record_id", -1))
			if born < 0:
				return
			var sex := str(data.get("sex", ""))
			var parents: Array = [int(data["mother_id"])] if data.has("mother_id") else []
			lineage.note_birth(born, species, sex, time, int(data.get("group_id", -1)), parents)
			names.name_of(born, species, sex)
		"AgentReproduced":
			var child: Dictionary = lineage.entry(agent_id)
			if child.is_empty():
				return
			var parents: Array = [int(data.get("parent_a_id", -1)), int(data.get("parent_b_id", -1))]
			# A parent the view never met is awake now - it just mated - and its sex says
			# which parent it is.
			for parent_id in parents:
				if parent_id >= 0 and not lineage.knows(parent_id) and manager != null and manager.world_state != null:
					name_of(manager.world_state.get_agent(parent_id))
			lineage.note_birth(agent_id, str(child["species"]), str(child["sex"]), float(child["born"]),
				int(child["group"]), parents)
		"AgentDied":
			var died := agent_id if agent_id >= 0 else int(data.get("record_id", -1))
			if died < 0:
				return
			if not lineage.knows(died):
				lineage.note_animal(died, species, "", int(data.get("group_id", -1)))
			var at: Dictionary = event.get("position", {})
			lineage.note_death(died, time, str(data.get("cause", "")), int(event.get("other_agent_id", -1)),
				Vector2(float(at.get("x", 0.0)), float(at.get("y", 0.0))))
			names.release(died)
			if pins.has(died):
				pins_changed.emit()
	# After the names and the family tree, which the line is written from.
	feed.hear(event)


## The animal's name, given now if it had none, and the animal noted in the family tree.
func name_of(agent) -> String:
	if agent == null:
		return ""
	lineage.note_animal(agent.id, agent.species_type, agent.sex, agent.group_id)
	return names.name_of(agent.id, agent.species_type, agent.sex)


## The name of an animal known only by its id - a parent, a killer, a pinned one asleep.
func name_of_id(agent_id: int) -> String:
	var known: String = names.known(agent_id)
	if known != "":
		return known
	var entry: Dictionary = lineage.entry(agent_id)
	if not entry.is_empty() and str(entry["sex"]) != "":
		return names.name_of(agent_id, str(entry["species"]), str(entry["sex"]))
	var agent = null if manager == null or manager.world_state == null else manager.world_state.get_agent(agent_id)
	return name_of(agent) if agent != null else "№%d" % agent_id


func is_pinned(agent_id: int) -> bool:
	return pins.has(agent_id)


## Pins the animal or unpins it; true if it ends up pinned. Past `MAX_PINS` it stays as it was.
func toggle_pin(agent) -> bool:
	if agent == null:
		return false
	if pins.has(agent.id):
		pins.erase(agent.id)
		pins_changed.emit()
		return false
	if pins.size() >= MAX_PINS:
		return false
	name_of(agent)
	pins.append(agent.id)
	pins_changed.emit()
	return true


func unpin(agent_id: int) -> void:
	if pins.has(agent_id):
		pins.erase(agent_id)
		pins_changed.emit()


## Where a pinned animal is and how it is: `{id, name, species, sex, dead, cause, awake,
## position}`.
## Awake it is where it is drawn; asleep, where its sleeping sector keeps it; dead, where it
## died. `position` is `Vector2.INF` when it is nowhere to be found.
func pin_status(agent_id: int) -> Dictionary:
	var entry: Dictionary = lineage.entry(agent_id)
	var status := {"id": agent_id, "name": name_of_id(agent_id), "species": str(entry.get("species", "")),
		"sex": str(entry.get("sex", "")), "dead": lineage.is_dead(agent_id), "cause": str(entry.get("cause", "")),
		"awake": false, "position": Vector2.INF}
	if status["dead"]:
		status["position"] = entry.get("position", Vector2.INF)
		return status
	var world = null if manager == null else manager.world_state
	if world == null:
		return status
	var agent = world.get_agent(agent_id)
	if agent != null and agent.is_alive:
		status["awake"] = true
		status["position"] = agent.position
		return status
	for sector in world._sector_states.values():
		if not bool(sector.get("dormant", false)):
			continue
		for aggregate in sector.get("dormant_aggregates", []):
			var index: int = aggregate.get("record_ids", []).find(agent_id)
			if index >= 0:
				var at: PackedVector2Array = aggregate.get("record_positions", PackedVector2Array())
				status["position"] = at[index] if index < at.size() else aggregate.get("center", Vector2.INF)
				return status
	return status


func export_state() -> Dictionary:
	return {"version": STATE_VERSION, "names": names.export_state(), "lineage": lineage.export_state(),
		"pins": pins.duplicate(), "places": places.export_state()}


func import_state(data: Dictionary) -> void:
	names.import_state(data.get("names", {}))
	lineage.import_state(data.get("lineage", {}))
	pins = data.get("pins", []).duplicate()
	places.import_state(data.get("places", {}))
