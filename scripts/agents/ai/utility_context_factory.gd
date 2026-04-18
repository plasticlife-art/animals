class_name UtilityContextFactory
extends RefCounted


static func need_ratio(current_value: float, max_value: float) -> float:
	return clampf(current_value / maxf(1.0, max_value), 0.0, 1.0)


static func energy_ratio(current_value: float, max_value: float) -> float:
	return clampf(current_value / maxf(1.0, max_value), 0.0, 1.0)


static func fatigue_ratio(current_energy: float, max_energy: float) -> float:
	return 1.0 - energy_ratio(current_energy, max_energy)


static func proximity_ratio(distance: float, max_distance: float) -> float:
	return 1.0 - clampf(distance / maxf(1.0, max_distance), 0.0, 1.0)


static func bool_ratio(value: bool) -> float:
	return 1.0 if value else 0.0


static func safe_biome_score(biome_id: String) -> float:
	match biome_id:
		"forest":
			return 0.95
		"swamp":
			return 0.65
		"meadow":
			return 0.4
		"drought":
			return 0.2
		_:
			return 0.5


static func is_open_area_biome(biome_id: String) -> bool:
	return biome_id in ["meadow", "drought"]


static func clamp_score(value: float) -> float:
	return clampf(value, 0.0, 1.5)
