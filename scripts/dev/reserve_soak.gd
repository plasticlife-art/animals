extends SceneTree

## The living reserve for hours, headless and as fast as it steps: its world from `reserve.json`
## with LOD on, a crowd of made-up viewers giving every command (`ReserveSession`), the story the
## view would keep (`StoryBook`), the autosave of `autosave_seconds`. The view looks where the
## director would, by turns at a ward and at the focus herd. A line every `sample` simulated
## seconds: each species, the rescues, the wards, what the save and the story weigh, memory, the
## tick's cost. At the end it saves, loads into a new world and compares the two at the load and
## after running on.
##
##   Godot --headless --path . --script res://scripts/dev/reserve_soak.gd -- [seed] [hours] [out.json]
##       [commands_per_minute]
##
## The viewers draw from a stream of their own, never the world's, so a seed gives the same run.

const SAMPLE_SECONDS := 600.0
const LOOK_SECONDS := 25.0
const NAMES := ["Ветка", "Луна", "Искра", "Буран", "Тучка", "Звёздочка", "Рыжик", "Снежок", "Гроза", "Ромашка", "Уголёк",
	"Метель", "Ольха", "Шиповник", "Берёза", "Ласка"]
const SOAK_SAVES := "user://soak_reserve_saves"

var manager = null
var session = null
var story = null
var viewers := RandomNumberGenerator.new()


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var run_seed := int(args[0]) if args.size() > 0 else 7
	var hours := float(args[1]) if args.size() > 1 else 3.0
	var output_path := str(args[2]) if args.size() > 2 else ""
	var per_minute := float(args[3]) if args.size() > 3 else 30.0
	var config := ConfigLoader.load_reserve_config()
	var bundle := ConfigLoader.load_reserve_bundle(config)
	var selection: Dictionary = bundle["reserve"]["selection"]
	manager = preload("res://scripts/core/simulation_manager.gd").new()
	manager.initialize(bundle, run_seed)
	manager.set_lod_enabled(true)
	session = ReserveSession.new()
	session.configure(manager, config)
	story = preload("res://scripts/story/story_book.gd").new()
	story.bind(manager)
	story.begin({})
	story.lineage.capacity = int(config.get("story_animals", story.lineage.capacity))
	viewers.seed = run_seed * 7919 + 13
	var told: Dictionary = {}
	session.told.connect(func(line: Dictionary) -> void:
		told[str(line["kind"])] = int(told.get(str(line["kind"]), 0)) + 1
		if str(line["kind"]) == "rescue":
			print("  %6.0f s  %s" % [session.now(), str(line["text"])]))
	SaveSystem.save_dir = SOAK_SAVES
	var autosave_ticks: int = maxi(1, int(float(config.get("autosave_seconds", 120.0)) * manager.tick_rate))
	var total_ticks: int = int(hours * 3600.0 * manager.tick_rate)
	var sample_ticks: int = int(SAMPLE_SECONDS * manager.tick_rate)
	var look_ticks: int = int(LOOK_SECONDS * manager.tick_rate)
	var command_chance: float = per_minute / 60.0 / manager.tick_rate
	var tick_ms: Array = []
	var save_ms: Array = []
	var samples: Array = []
	var started := Time.get_ticks_msec()
	var lowest := {}
	print("reserve soak: seed %d, %.1f h, %.0f commands a minute" % [run_seed, hours, per_minute])
	for tick in range(1, total_ticks + 1):
		if viewers.randf() < command_chance:
			session.hear(_viewer_line())
		var begun := Time.get_ticks_usec()
		manager.step_once()
		tick_ms.append(float(Time.get_ticks_usec() - begun) / 1000.0)
		session.tick()
		if tick % look_ticks == 0:
			_look(tick / look_ticks)
		if tick % autosave_ticks == 0:
			var saving := Time.get_ticks_usec()
			SaveSystem.save(manager, selection, "", story.export_state(), session.export_state())
			save_ms.append(float(Time.get_ticks_usec() - saving) / 1000.0)
		if tick % sample_ticks == 0:
			var sample := _sample(tick_ms, save_ms, told, started)
			for species in sample["counts"].keys():
				lowest[species] = mini(int(lowest.get(species, 1 << 30)), int(sample["counts"][species]))
			samples.append(sample)
			print(_line(sample))
			tick_ms.clear()
			save_ms.clear()
	var check := _check_load(selection)
	print("load: ", JSON.stringify(check))
	var report := {"seed": run_seed, "hours": hours, "commands_per_minute": per_minute, "samples": samples, "lowest": lowest,
		"told": told, "load": check, "wall_seconds": float(Time.get_ticks_msec() - started) / 1000.0}
	if output_path != "":
		var file := FileAccess.open(output_path, FileAccess.WRITE)
		file.store_string(JSON.stringify(report, "  "))
		file.close()
	for path in SaveSystem.slot_paths(SaveSystem.KIND_RESERVE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	quit()


## One viewer's chat line: a ward, «!моё», a vote, a fund, now and then a steward's power.
func _viewer_line() -> Dictionary:
	var id := viewers.randi_range(1, 400)
	var roll := viewers.randf()
	var text := "!моё"
	if roll < 0.25:
		text = "!имя " + str(NAMES[viewers.randi_range(0, NAMES.size() - 1)])
	elif roll < 0.55:
		text = "!%d" % viewers.randi_range(1, 3)
	elif roll < 0.75:
		text = ["!олени", "!лисы", "!волки"][viewers.randi_range(0, 2)]
	elif roll < 0.9:
		text = ["!водопой", "!повести", "!отстрел"][viewers.randi_range(0, 2)]
	return {"platform": "twitch", "user_id": str(id), "user": "Зритель%d" % id, "text": text}


## Where the view looks, as the director would: by turns a living ward and the focus herd. The
## LOD's awake window follows it, and the ward's herd becomes the focus.
func _look(turn: int) -> void:
	var world = manager.world_state
	var at = null
	if turn % 2 == 0:
		var wards: Array = []
		for id in world.adoptions.keys():
			if float(world.adoptions[id].get("died_at", -1.0)) < 0.0:
				wards.append(int(id))
		wards.sort()
		if not wards.is_empty():
			var ward_id: int = wards[viewers.randi_range(0, wards.size() - 1)]
			var agent = world.get_agent(ward_id)
			if agent != null and agent.is_alive:
				at = agent.position
				if int(agent.group_id) >= 0 and world.species_registry.social(agent.species_type) == "herd":
					session.focus = {"species": agent.species_type, "group_id": int(agent.group_id)}
			else:
				for sector in world._sector_states.values():
					for record in sector.get("dormant_records", []):
						if int(record.get("id", -1)) == ward_id:
							at = Vector2(record.get("position", Vector2.ZERO))
	if at == null:
		var herd: Dictionary = session.focus_herd()
		at = herd.get("center", world.bounds.get_center())
	var half := Vector2(800.0, 450.0)
	manager.set_lod_view(Rect2(at - half, half * 2.0), at, false)


func _sample(tick_ms: Array, save_ms: Array, told: Dictionary, started: int) -> Dictionary:
	var world = manager.world_state
	var sorted := tick_ms.duplicate()
	sorted.sort()
	var living := 0
	for ward in world.adoptions.values():
		if float(ward.get("died_at", -1.0)) < 0.0:
			living += 1
	var slot := SaveSystem.latest_slot(SaveSystem.KIND_RESERVE)
	var save_bytes := 0
	if slot != "":
		var file := FileAccess.open(slot, FileAccess.READ)
		save_bytes = file.get_length()
		file.close()
	return {
		"time": session.now(),
		"wall": float(Time.get_ticks_msec() - started) / 1000.0,
		"counts": session.census(),
		"wards_living": living,
		"wards_kept": world.adoptions.size(),
		"journal": world.player.journal.size(),
		"ponds": world.player.ponds.size(),
		"viewers": session.book.viewers.size(),
		"story_kb": var_to_bytes(story.export_state()).size() / 1024,
		"story_animals": story.lineage.size(),
		"session_kb": var_to_bytes(session.export_state()).size() / 1024,
		"save_kb": save_bytes / 1024,
		"save_ms": save_ms.max() if not save_ms.is_empty() else 0.0,
		"memory_mb": float(OS.get_static_memory_usage()) / 1048576.0,
		"tick_ms_mean": _mean(tick_ms),
		"tick_ms_p95": sorted[int(sorted.size() * 0.95)] if not sorted.is_empty() else 0.0,
		"told": told.duplicate(),
	}


func _line(sample: Dictionary) -> String:
	var counts: Array = []
	for species in ["herbivore", "predator", "scavenger", "wolf"]:
		counts.append("%s %d" % [species.left(4), int(sample["counts"].get(species, 0))])
	return "%6.0f s (%5.0f s wall)  %s | wards %d/%d journal %d ponds %d viewers %d | save %d KB (%.0f ms) story %d KB / %d | %.0f MB | tick %.2f / p95 %.2f ms" % [
		sample["time"], sample["wall"], " ".join(counts), sample["wards_living"], sample["wards_kept"], sample["journal"],
		sample["ponds"], sample["viewers"], sample["save_kb"], sample["save_ms"], sample["story_kb"], sample["story_animals"], sample["memory_mb"],
		sample["tick_ms_mean"], sample["tick_ms_p95"]]


## Saves, loads into a new world, and compares: at the load everything the reserve keeps must be
## the same; after both run on 600 ticks without viewers the counts are reported side by side
## (`check_save.gd` explains why only populations are promised after a load).
func _check_load(selection: Dictionary) -> Dictionary:
	# The orders queued since the last tick (a vote's, a fund's) are not saved: carried out first.
	while not manager.pending_commands().is_empty():
		manager.step_once()
	var path := SOAK_SAVES + "/reserve_check.dat"
	SaveSystem.save(manager, selection, path, story.export_state(), session.export_state())
	var data := SaveSystem.read(path)
	var loaded = preload("res://scripts/core/simulation_manager.gd").new()
	SaveSystem.restore(loaded, data)
	loaded.set_lod_enabled(true)
	loaded.set_lod_view(manager.lod_focus_rect, manager.lod_focus_center, false)
	var again = ReserveSession.new()
	again.configure(loaded, ConfigLoader.load_reserve_config())
	again.import_state(data.get("reserve", {}))
	var same_at_load: bool = again.census() == session.census() and loaded.world_state.adoptions == manager.world_state.adoptions \
		and loaded.world_state.player.used == manager.world_state.player.used and again.export_state() == session.export_state() \
		and loaded.world_state.world_events == manager.world_state.world_events
	for _tick in range(600):
		manager.step_once()
		loaded.step_once()
	var result := {"same_at_load": same_at_load, "after_600": {"saved": session.census(), "loaded": again.census()}}
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	loaded.free()
	return result


static func _mean(values: Array) -> float:
	var total := 0.0
	for value in values:
		total += float(value)
	return total / maxf(1.0, float(values.size()))
