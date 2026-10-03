class_name DyingSprites
extends RefCounted

## Animals that died where they could be seen, played through their species' `dead` row
## before the carcass left where they fell takes over.
##
## A dead animal leaves the simulation in the tick it dies, so the renderer has nothing
## to draw it from: the atlas has always had a death row, and nothing ever reached it.
## Each entry here holds what the sprite needs - where it was last drawn, the row, its
## scale - and runs on the view's clock (`SimulationManager.get_display_time()`), so it
## stops when the game is paused. While an entry plays, the carcass with the animal's id
## as `source_agent_id` is not drawn; once it starts fading the carcass shows through.
## Nothing here touches the simulation.

## Scene batch key of a dying sprite, `KEY_BASE + agent_id`: above agent ids and the
## carcass keys (`100000000 + carcass id`), apart from props (negative).
const KEY_BASE := 200000000
## `visuals.effects.death` when a key is missing, as in a save made before it existed.
const DEFAULTS := {
	"enabled": true,
	"play_seconds": 0.8,
	"fade_seconds": 0.2,
	"max_active": 24,
}

enum Phase { PLAYING, FADING, DONE }

var enabled: bool = true
var play_seconds: float = 0.8
var fade_seconds: float = 0.2
var max_active: int = 24
var _entries: Dictionary = {}
var _states: Array = []


func configure(death: Dictionary) -> void:
	enabled = bool(death.get("enabled", DEFAULTS["enabled"]))
	play_seconds = maxf(0.01, float(death.get("play_seconds", DEFAULTS["play_seconds"])))
	fade_seconds = maxf(0.0, float(death.get("fade_seconds", DEFAULTS["fade_seconds"])))
	max_active = maxi(0, int(death.get("max_active", DEFAULTS["max_active"])))


## The frames of a species' `dead` row (`spec`, its animation entry in visuals.json) that
## a death by `cause` plays. Every row in the pack falls, flushes red at the blow and fades
## back to the body's own colours, at frames that differ by species, so the row itself
## lists them: `kill_frames` for a kill, which runs through the reddest frame and stops on
## the next, still flushed, and `fall_frames` for any other death, which skips the red. Each
## list ends on the frame the species' carcass sheet starts from, so the body takes over
## from the fall unchanged. A row that lists nothing plays whole.
static func frames_for(cause: String, spec: Dictionary) -> PackedInt32Array:
	var count := maxi(1, int(spec.get("frames", 1)))
	var listed = spec.get("kill_frames" if cause == "predation" else "fall_frames", [])
	var frames := PackedInt32Array()
	if listed is Array:
		for value in listed:
			frames.append(clampi(int(value), 0, count - 1))
	if frames.is_empty():
		for index in range(count):
			frames.append(index)
	return frames


## Starts a dying sprite. `from` is where the animal was last drawn and `to` where it
## died, which the renderer drew about a tick behind; the sprite closes that gap over
## `glide` seconds instead of jumping. Refused when one is already playing for this
## animal, when the list is full, or when switched off.
func begin(agent_id: int, species: String, from: Vector2, to: Vector2, row: int, frames: PackedInt32Array,
		scale: float, facing: float, ground_offset: float, start: float, glide: float) -> bool:
	if not enabled or frames.is_empty() or _entries.has(agent_id) or _entries.size() >= max_active:
		return false
	var state := {
		"key": KEY_BASE + agent_id, "agent_id": agent_id, "species": species,
		"from": from, "to": to, "row": row, "frames": frames, "scale": scale, "facing": facing,
		"ground_offset": ground_offset, "start": start, "glide": maxf(0.0001, glide),
		"position": from, "frame": frames[0], "alpha": 1.0, "phase": Phase.PLAYING,
	}
	_entries[agent_id] = state
	_states.append(state)
	return true


## Moves every dying sprite to `now`. Returns true when any of them started fading or
## finished, the moments the draw order changes: a carcass appears under it, or it goes.
func advance(now: float) -> bool:
	var changed := false
	var finished: Array = []
	for state in _states:
		var elapsed: float = now - float(state["start"])
		var frames: PackedInt32Array = state["frames"]
		var index := clampi(int(maxf(elapsed, 0.0) / play_seconds * frames.size()), 0, frames.size() - 1)
		state["frame"] = frames[index]
		state["position"] = (state["from"] as Vector2).lerp(state["to"], smoothstep(0.0, float(state["glide"]), elapsed))
		state["alpha"] = 1.0 - clampf((elapsed - play_seconds) / maxf(fade_seconds, 0.0001), 0.0, 1.0)
		var phase := Phase.PLAYING
		if elapsed >= play_seconds + fade_seconds:
			phase = Phase.DONE
		elif elapsed >= play_seconds:
			phase = Phase.FADING
		if phase != int(state["phase"]):
			state["phase"] = phase
			changed = true
		if phase == Phase.DONE:
			finished.append(state)
	for state in finished:
		_entries.erase(int(state["agent_id"]))
		_states.erase(state)
	return changed


func states() -> Array:
	return _states


## The entry drawn under scene batch key `key`, or empty once it has finished.
func state(key: int) -> Dictionary:
	return _entries.get(key - KEY_BASE, {})


## True while the animal that left this carcass is still being shown dying.
func hides_carcass(source_agent_id: int) -> bool:
	var entry: Dictionary = _entries.get(source_agent_id, {})
	return not entry.is_empty() and int(entry["phase"]) == Phase.PLAYING


func is_empty() -> bool:
	return _states.is_empty()


func clear() -> void:
	_entries.clear()
	_states.clear()
