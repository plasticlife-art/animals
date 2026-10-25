class_name VoteRound
extends RefCounted

## The reserve's votes (`reserve.json` `vote`): every `every_seconds` a vote opens on `choices`
## events taken in turn from `events` - which ones by the round's number, never by chance - for
## `open_seconds`; each viewer has one vote and may change it; at the close the most votes win,
## the earlier choice on a tie, and no votes at all means nothing happens.

var round_number: int = 0
## While a vote is open: `{choices: [event...], closes_at, ballots: {viewer: index}}`; else empty.
var current: Dictionary = {}
var next_at: float = -1.0


## A vote opens or closes at `now` as its times come: the winning event when one closes, else {}.
func tick(now: float, config: Dictionary) -> Dictionary:
	var settings: Dictionary = config.get("vote", {})
	if next_at < 0.0:
		next_at = now + float(settings.get("every_seconds", 240.0))
	if current.is_empty():
		if now >= next_at:
			_open(now, settings)
		return {}
	if now < float(current["closes_at"]):
		return {}
	var winner := winning_choice()
	var won: Dictionary = current["choices"][winner] if winner >= 0 else {}
	current = {}
	next_at = now + float(settings.get("every_seconds", 240.0))
	return won


func _open(now: float, settings: Dictionary) -> void:
	var events: Array = settings.get("events", [])
	if events.is_empty():
		next_at = now + float(settings.get("every_seconds", 240.0))
		return
	var choices: Array = []
	var count := mini(int(settings.get("choices", 3)), events.size())
	for index in range(count):
		choices.append(events[(round_number * count + index) % events.size()])
	round_number += 1
	current = {"choices": choices, "closes_at": now + float(settings.get("open_seconds", 60.0)), "ballots": {}}


## `viewer`'s vote for the `number`-th choice (from 1); false when no vote is open or no such choice.
func cast(viewer: String, number: int) -> bool:
	if current.is_empty() or number < 1 or number > current["choices"].size():
		return false
	current["ballots"][viewer] = number - 1
	return true


## Votes per choice, in choice order.
func tallies() -> Array:
	var counts: Array = []
	if current.is_empty():
		return counts
	for _index in current["choices"]:
		counts.append(0)
	for index in current["ballots"].values():
		counts[int(index)] += 1
	return counts


## The choice with most votes (the earlier on a tie), or -1 with none cast.
func winning_choice() -> int:
	var counts := tallies()
	var best := -1
	for index in range(counts.size()):
		if int(counts[index]) > 0 and (best < 0 or int(counts[index]) > int(counts[best])):
			best = index
	return best


func export_state() -> Dictionary:
	return {"round_number": round_number, "current": current.duplicate(true), "next_at": next_at}


func import_state(data: Dictionary) -> void:
	round_number = int(data.get("round_number", 0))
	current = data.get("current", {}).duplicate(true)
	next_at = float(data.get("next_at", -1.0))
