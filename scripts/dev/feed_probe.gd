extends SceneTree

## The event feed (`StoryLog`) over a run, as the game hears it: the world steps through the
## manager, events reach the `StoryBook` only by `world_event`, and the view the feed tells apart
## from the rest of the map is set as the game sets it. Counts what the bus raised, what reached
## the view and what the feed made of it: new lines by kind, folds, lines per simulated minute.
##
##   Godot --headless --path . --script res://scripts/dev/feed_probe.gd -- [seed] [minutes]
##       [game|reserve] [herd|overview] [out.json] [inline|worker]
##
## `herd`: the view, 1600 x 900, follows the biggest deer herd, and that herd is the selected
## one's (`_story_context()` in the game). `overview`: the whole map in view, LOD in overview,
## nothing selected - the zoomed-out map, where most sectors sleep. `worker` steps the world on the
## manager's own thread, as the game does, its events coming back with each frame.

## The events the feed's territory and pasture lines are told from.
const WATCHED := ["TerritoryClaimed", "TerritoryVacated", "DispersalStarted", "PackLeft", "HerdMigrates"]
const LOOK_SECONDS := 10.0
const HALF_VIEW := Vector2(800.0, 450.0)

var manager = null
var story = null
var view := Rect2()
var herd: Array = []


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0]) if args.size() > 0 else 11
	var minutes := float(args[1]) if args.size() > 1 else 20.0
	var world_kind := str(args[2]) if args.size() > 2 else "game"
	var look := str(args[3]) if args.size() > 3 else "herd"
	var output_path := str(args[4]) if args.size() > 4 else ""
	var threaded := args.size() > 5 and str(args[5]) == "worker"
	var bundle: Dictionary = ConfigLoader.load_config_bundle(ConfigLoader.default_selection())
	if world_kind == "reserve":
		bundle = ConfigLoader.load_reserve_bundle(ConfigLoader.load_reserve_config())
	manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, run_seed)
	manager.set_lod_enabled(true)
	if threaded:
		# The bus the world raised its events on goes to the worker; the view's own re-raises them.
		manager.enable_interactive_worker()
		manager.begin_interactive_stepping()
	story = preload("res://scripts/story/story_book.gd").new()
	story.bind(manager)
	story.begin({})
	story.feed.context_provider = func() -> Dictionary:
		var context := {"view": view}
		if not herd.is_empty():
			context["herd"] = herd
		return context
	var on_bus: Dictionary = {}
	var on_view: Dictionary = {}
	manager.event_bus.event_emitted.connect(func(event: Dictionary) -> void:
		var type := str(event.get("type", ""))
		if WATCHED.has(type):
			var dormant: bool = int(event.get("agent_id", -1)) < 0
			var key := "%s%s" % [type, " asleep" if dormant else ""]
			on_bus[key] = int(on_bus.get(key, 0)) + 1)
	manager.world_event.connect(func(event: Dictionary) -> void:
		var type := str(event.get("type", ""))
		on_view[type] = int(on_view.get(type, 0)) + 1)
	var told: Array = []
	var folds := {"count": 0}
	var newest := [null]
	story.feed.changed.connect(func() -> void:
		if story.feed.lines.is_empty():
			return
		var line: Dictionary = story.feed.lines[0]
		if newest[0] != null and is_same(line, newest[0]):
			folds["count"] += 1
			return
		newest[0] = line
		told.append({"time": float(line["time"]), "kind": str(line["kind"]), "text": str(line["text"])}))
	var total_ticks := int(minutes * 60.0 * manager.tick_rate)
	var look_ticks := int(LOOK_SECONDS * manager.tick_rate)
	var started := Time.get_ticks_msec()
	print("feed probe: seed %d, %.0f min, %s world, view %s, %s" % [run_seed, minutes, world_kind, look,
		"worker" if threaded else "inline"])
	for tick in range(1, total_ticks + 1):
		if tick == 1 or tick % look_ticks == 0:
			_look(look)
		if threaded:
			manager._post_worker_job()
			manager.synchronize_worker()
		else:
			manager.step_once()
		if manager.should_refresh_ui_on_tick(manager.current_tick):
			story.tick(manager.simulation_time)
	var by_kind: Dictionary = {}
	var per_minute: Dictionary = {}
	for line in told:
		by_kind[line["kind"]] = int(by_kind.get(line["kind"], 0)) + 1
		var minute := int(float(line["time"]) / 60.0)
		per_minute[minute] = int(per_minute.get(minute, 0)) + 1
	var busiest := 0
	for start in range(told.size()):
		var within := 0
		for other in range(start, told.size()):
			if float(told[other]["time"]) - float(told[start]["time"]) < 60.0:
				within += 1
		busiest = maxi(busiest, within)
	var report := {"seed": run_seed, "minutes": minutes, "world": world_kind, "look": look, "worker": threaded, "on_bus": on_bus,
		"on_view": on_view, "lines": told.size(), "folds": folds["count"], "by_kind": by_kind,
		"per_minute": per_minute, "busiest_minute": busiest,
		"wall_seconds": float(Time.get_ticks_msec() - started) / 1000.0}
	print("bus (watched types): ", JSON.stringify(on_bus))
	print("world_event: ", JSON.stringify(on_view))
	print("feed lines %d, folds %d, by kind %s, busiest 60 s %d" % [told.size(), folds["count"], JSON.stringify(by_kind), busiest])
	for line in told:
		if not str(line["kind"]) in ["death", "birth", "summary", "epitaph"]:
			print("  %6.0f s  [%s] %s" % [float(line["time"]), str(line["kind"]), str(line["text"])])
	report["lines_told"] = told
	if output_path != "":
		var file := FileAccess.open(output_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	manager.shutdown()
	quit()


## The view as the game would have it now.
func _look(look: String) -> void:
	var world = manager.world_state
	if look == "overview":
		view = world.bounds
		herd = []
		manager.set_lod_view(world.bounds, world.bounds.get_center(), true)
		return
	var best := -1
	var census := {}
	for agent in world.get_living_agents():
		if agent != null and agent.is_alive and agent.species_type == "herbivore" and int(agent.group_id) >= 0:
			census[int(agent.group_id)] = int(census.get(int(agent.group_id), 0)) + 1
	for group in census.keys():
		if best < 0 or int(census[group]) > int(census[best]):
			best = int(group)
	var at: Vector2 = world.bounds.get_center()
	herd = []
	if best >= 0:
		var where: Dictionary = HerdReadout.locate(world, "herbivore", best)
		if int(where["count"]) > 0:
			at = where["center"]
			herd = ["herbivore", best]
	view = Rect2(at - HALF_VIEW, HALF_VIEW * 2.0)
	manager.set_lod_view(view, at, false)
