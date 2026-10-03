class_name HerdReadout
extends RefCounted

## What the herd card says about the herd of the selected animal, worked out apart from
## the drawing so it can be tested: how many there are, near and far, how many are
## young, how fed, watered and rested they are on average, and how many hunters are after
## them right now. Read-only, from the world the view is shown - the worker's copy too.
##
## A herd is a `group_id` within a species whose `role.social` is `herd` (the grazers'
## herds, the scavengers' flocks); predators keep to pairs and have none. Its awake
## members are among the living agents; its sleeping ones only exist as the aggregates
## of their sleeping sectors, each a count with means, and are counted from those.

const HUNTING_STATES := ["seek_prey", "chase", "search_last_seen", "attack"]
const HudTextScript := preload("res://scripts/ui/hud_text.gd")


static func has_herd(world, agent) -> bool:
	if world == null or agent == null or int(agent.group_id) < 0:
		return false
	return world.species_registry.social(agent.species_type) == "herd"


## `{awake, sleeping, total, young, hunger, thirst, energy, hunters}` for `group_id` of
## `species`: the needs are means over every member, awake or asleep.
static func summarize(world, species: String, group_id: int) -> Dictionary:
	var summary := {"awake": 0, "sleeping": 0, "total": 0, "young": 0,
		"hunger": 0.0, "thirst": 0.0, "energy": 0.0, "hunters": 0}
	if world == null or group_id < 0:
		return summary
	var hunger := 0.0
	var thirst := 0.0
	var energy := 0.0
	var members := {}
	for agent in world.get_living_agents():
		if agent == null or not agent.is_alive or agent.species_type != species or int(agent.group_id) != group_id:
			continue
		members[agent.id] = true
		summary["awake"] += 1
		if agent.get_age_stage() == "young":
			summary["young"] += 1
		hunger += agent.hunger
		thirst += agent.thirst
		energy += agent.energy
	for sector in world._sector_states.values():
		if not bool(sector.get("dormant", false)):
			continue
		for aggregate in sector.get("dormant_aggregates", []):
			if str(aggregate.get("species_type", "")) != species or int(aggregate.get("group_id", -1)) != group_id:
				continue
			var count := int(aggregate.get("count", 0))
			summary["sleeping"] += count
			summary["young"] += maxi(0, count - int(aggregate.get("mature_males", 0)) - int(aggregate.get("mature_females", 0)))
			hunger += float(aggregate.get("avg_hunger", 0.0)) * count
			thirst += float(aggregate.get("avg_thirst", 0.0)) * count
			energy += float(aggregate.get("avg_energy", 0.0)) * count
	summary["total"] = int(summary["awake"]) + int(summary["sleeping"])
	var whole := float(maxi(1, int(summary["total"])))
	summary["hunger"] = hunger / whole
	summary["thirst"] = thirst / whole
	summary["energy"] = energy / whole
	summary["hunters"] = count_hunters(world, species, members)
	return summary


## Awake animals of a species that eats `species`, hunting one of `members` (ids) right now.
static func count_hunters(world, species: String, members: Dictionary) -> int:
	if members.is_empty():
		return 0
	var eaters: Dictionary = world.species_registry.predator_set(species)
	var hunters := 0
	for agent in world.get_living_agents():
		if agent == null or not agent.is_alive or not eaters.has(agent.species_type):
			continue
		if agent.state in HUNTING_STATES and members.has(int(agent.target_agent_id)):
			hunters += 1
	return hunters


## «Травоядные · Стадо №5».
static func title(species: String, group_id: int) -> String:
	return "%s · %s №%d" % [HudTextScript.species_label(species), HudTextScript.group_noun(species), HudTextScript.herd_number(group_id)]


## «Голов: 34 (вдали: 12) · Молодых: 6», the far ones only when there are any.
static func counts_text(summary: Dictionary) -> String:
	var heads := "Голов: %d" % int(summary.get("total", 0))
	if int(summary.get("sleeping", 0)) > 0:
		heads += " (вдали: %d)" % int(summary["sleeping"])
	return "%s · Молодых: %d" % [heads, int(summary.get("young", 0))]


static func hunters_text(hunters: int) -> String:
	return "Охоты нет" if hunters <= 0 else "Охотятся на них: %d" % hunters


## «Последняя потеря: хищник, 40 с назад», or «Потерь пока нет» with nothing recorded.
static func loss_text(loss: Dictionary, now: float) -> String:
	if loss.is_empty():
		return "Потерь пока нет"
	return "Последняя потеря: %s, %s" % [HudTextScript.cause_label(str(loss.get("cause", ""))),
		HudTextScript.ago_text(maxf(0.0, now - float(loss.get("time", now))))]


static func follow_text(species: String) -> String:
	return "Следить за %s" % str(HudTextScript.GROUPS_FOLLOWED.get(species, "группой"))
