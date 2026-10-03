class_name PlaceNames
extends RefCounted

## Names for the land, in Russian, so the feed and the epitaphs can say where something
## happened - «у Тихой заводи», «на Медовом лугу» - and the map can label it. Every watering
## hole gets a name; the rest of the map is split into districts of roughly equal size,
## each named after the biome it has most of compared with the map as a whole: a district
## heavy with woods is a «бор» or a «роща», one with swamp an «болото», the rest meadows.
## Biomes alone do not make places: the meadow is one patch over half the map and the
## woods and dry ground hundreds of small ones.
##
## Names are picked by hashing the world's seed and the place's index, so a world names its
## places the same way each time; the story keeps them with the save. Nothing here reaches
## the simulation.

const AnimalNamesScript := preload("res://scripts/story/animal_names.gd")

## Adjectives as «word:type», the type saying how they decline: `h` hard «-ый», `o` stressed
## «-ой», `v` «-кий/-гий/-хий», `z` «-жий/-ший/-чий/-щий», `s` soft «-ний», `p` possessive
## «-ий» with «ь» («Лисий» - «Лисья», «Лисьего»).
const POND_ADJECTIVES := [
	"Тихий:v", "Кривой:o", "Лисий:p", "Олений:p", "Волчий:p", "Медвежий:p", "Заячий:p", "Глухой:o",
	"Светлый:h", "Студёный:h", "Мшистый:h", "Ивовый:h", "Тёмный:h", "Песчаный:h", "Утиный:h",
	"Камышовый:h", "Синий:s", "Чистый:h", "Холодный:h", "Круглый:h", "Длинный:h", "Мелкий:v",
	"Глубокий:v", "Зеркальный:h", "Каменный:h", "Ольховый:h", "Берёзовый:h", "Журавлиный:h",
	"Лебединый:h", "Гусиный:h", "Сонный:h", "Ясный:h", "Звонкий:v", "Рыбный:h", "Илистый:h",
	"Туманный:h", "Ракитовый:h", "Дальний:s", "Верхний:s", "Нижний:s", "Тайный:h", "Старый:h",
	"Чёрный:h", "Белый:h", "Серебряный:h", "Золотой:o", "Росистый:h", "Лунный:h", "Звёздный:h",
	"Совиный:h", "Тетеревиный:h", "Барсучий:p",
]
## Pond nouns: `[word, gender, genitive]`.
const POND_NOUNS := [
	["брод", "m", "брода"], ["плёс", "m", "плёса"], ["омут", "m", "омута"], ["затон", "m", "затона"],
	["бочаг", "m", "бочага"], ["ключ", "m", "ключа"], ["родник", "m", "родника"], ["пруд", "m", "пруда"],
	["водопой", "m", "водопоя"], ["заводь", "f", "заводи"], ["старица", "f", "старицы"],
	["купель", "f", "купели"], ["озерцо", "n", "озерца"], ["озеро", "n", "озера"],
]
## District nouns by biome: `[word, gender, locative, preposition]`.
const DISTRICT_NOUNS := {
	"meadow": [["луг", "m", "лугу", "на"], ["поляна", "f", "поляне", "на"], ["долина", "f", "долине", "в"],
		["луговина", "f", "луговине", "на"]],
	"forest": [["лес", "m", "лесу", "в"], ["бор", "m", "бору", "в"], ["роща", "f", "роще", "в"],
		["чаща", "f", "чаще", "в"], ["дубрава", "f", "дубраве", "в"], ["перелесок", "m", "перелеске", "в"]],
	"drought": [["степь", "f", "степи", "в"], ["пустошь", "f", "пустоши", "на"],
		["солончак", "m", "солончаке", "на"], ["плато", "n", "плато", "на"]],
	"swamp": [["болото", "n", "болоте", "на"], ["топь", "f", "топи", "в"], ["трясина", "f", "трясине", "в"],
		["мшара", "f", "мшаре", "на"], ["низина", "f", "низине", "в"]],
}
const DISTRICT_ADJECTIVES := {
	"meadow": ["Медовый:h", "Цветочный:h", "Ромашковый:h", "Клеверный:h", "Росистый:h", "Зелёный:h",
		"Широкий:v", "Шмелиный:h", "Земляничный:h", "Васильковый:h"],
	"forest": ["Ольховый:h", "Берёзовый:h", "Сосновый:h", "Еловый:h", "Дубовый:h", "Осиновый:h",
		"Тёмный:h", "Сумрачный:h", "Липовый:h", "Рябиновый:h"],
	"drought": ["Сухой:o", "Пыльный:h", "Ржавый:h", "Жёлтый:h", "Рыжий:z", "Горький:v", "Каменистый:h",
		"Песчаный:h", "Ковыльный:h", "Полынный:h"],
	"swamp": ["Гиблый:h", "Топкий:v", "Мшистый:h", "Клюквенный:h", "Комариный:h", "Чёрный:h",
		"Морошковый:h", "Камышовый:h", "Сырой:o", "Багульный:h"],
}
## Adjectives any district can take.
const SHARED_ADJECTIVES := [
	"Тихий:v", "Дальний:s", "Старый:h", "Ветреный:h", "Солнечный:h", "Туманный:h", "Сонный:h",
	"Кривой:o", "Лисий:p", "Волчий:p", "Олений:p", "Медвежий:p", "Заячий:p", "Совиный:h",
	"Журавлиный:h", "Глухой:o",
]
## Endings by type: m, f, n nominative; genitive m/n and f; prepositional m/n and f.
const ENDINGS := {
	"h": ["ый", "ая", "ое", "ого", "ой", "ом", "ой"],
	"o": ["ой", "ая", "ое", "ого", "ой", "ом", "ой"],
	"v": ["ий", "ая", "ое", "ого", "ой", "ом", "ой"],
	"z": ["ий", "ая", "ее", "его", "ей", "ем", "ей"],
	"s": ["ий", "яя", "ее", "его", "ей", "ем", "ей"],
	"p": ["ий", "ья", "ье", "ьего", "ьей", "ьем", "ьей"],
}
## A district covers about this much ground (world units squared), so a large map has
## about two dozen and a small one a few.
const DISTRICT_AREA := 4.84e6
const MIN_DISTRICTS := 3
const MAX_DISTRICTS := 64
## A biome names a district only if it covers at least this share of it.
const MIN_BIOME_SHARE := 0.2
## How near a pond, in its radii, still counts as «у» it.
const POND_REACH := 1.6
const PROBES := 24

## `{position, radius, level, name, at}`, by `water_sources` index.
var ponds: Array = []
## `{center, level, biome, name, at}`; `center` is where its label goes.
var districts: Array = []
var _cell_district := PackedInt32Array()
var _cols: int = 0
var _rows: int = 0
var _cell_size: float = 1.0


func clear() -> void:
	ponds.clear()
	districts.clear()
	_cell_district = PackedInt32Array()
	_cols = 0
	_rows = 0


## Names the ponds and districts of `world` (`WorldState`), from `seed_value`.
func build(world, seed_value: int) -> void:
	clear()
	if world == null or world.terrain_system == null:
		return
	var terrain = world.terrain_system
	_cols = terrain.cols
	_rows = terrain.rows
	_cell_size = terrain.cell_size
	_name_ponds(world.water_sources, terrain, seed_value)
	_split_districts(world.bounds, terrain, seed_value)


## The place at a world position: `{name, at, kind}` - «у Тихой заводи» near a pond, else the
## district's «на Медовом лугу» - or empty off the map.
func place_at(position: Vector2) -> Dictionary:
	var pond := pond_near(position)
	if pond >= 0:
		return {"name": ponds[pond]["name"], "at": ponds[pond]["at"], "kind": "pond"}
	var district := district_at(position)
	if district >= 0:
		return {"name": districts[district]["name"], "at": districts[district]["at"], "kind": "district"}
	return {}


## The phrase for a position, or "" - for text that reads on without it.
func at(position: Vector2) -> String:
	return str(place_at(position).get("at", ""))


## The nearest pond whose bank is within reach, or -1.
func pond_near(position: Vector2) -> int:
	var best := -1
	var best_gap := INF
	for index in range(ponds.size()):
		var pond: Dictionary = ponds[index]
		var gap: float = position.distance_to(pond["position"]) - float(pond["radius"]) * POND_REACH
		if gap <= 0.0 and gap < best_gap:
			best_gap = gap
			best = index
	return best


func district_at(position: Vector2) -> int:
	if _cols <= 0 or not is_finite(position.x) or not is_finite(position.y):
		return -1
	var cx := int(floor(position.x / _cell_size))
	var cy := int(floor(position.y / _cell_size))
	if cx < 0 or cy < 0 or cx >= _cols or cy >= _rows:
		return -1
	return _cell_district[cy * _cols + cx]


func export_state() -> Dictionary:
	var pond_names: Array = []
	for pond in ponds:
		pond_names.append([pond["name"], pond["at"]])
	var district_names: Array = []
	for district in districts:
		district_names.append([district["name"], district["at"]])
	return {"ponds": pond_names, "districts": district_names}


## Names a save kept, over the ones just built, as long as the world still has the same number
## of each - so a later change to the word lists leaves an old world's places as they were.
func import_state(data: Dictionary) -> void:
	var pond_names: Array = data.get("ponds", [])
	if pond_names.size() == ponds.size():
		for index in range(ponds.size()):
			ponds[index]["name"] = str(pond_names[index][0])
			ponds[index]["at"] = str(pond_names[index][1])
	var district_names: Array = data.get("districts", [])
	if district_names.size() == districts.size():
		for index in range(districts.size()):
			districts[index]["name"] = str(district_names[index][0])
			districts[index]["at"] = str(district_names[index][1])


## `{name, genitive, prepositional}` of an adjective-noun name; see `ENDINGS`.
static func compose(adjective: String, noun: Array, district := false) -> Dictionary:
	var parts := adjective.split(":")
	var word: String = parts[0]
	var endings: Array = ENDINGS.get(parts[1] if parts.size() > 1 else "h", ENDINGS["h"])
	var stem := word.substr(0, word.length() - 2)
	var gender := str(noun[1])
	var nominative: String = stem + str(endings[{"m": 0, "f": 1, "n": 2}.get(gender, 0)])
	var genitive: String = stem + str(endings[4 if gender == "f" else 3])
	var prepositional: String = stem + str(endings[6 if gender == "f" else 5])
	var name := "%s %s" % [nominative, noun[0]]
	if district:
		return {"name": name, "at": "%s %s %s" % [noun[3], prepositional, noun[2]]}
	return {"name": name, "at": "у %s %s" % [genitive, noun[2]]}


func _name_ponds(sources: Array, terrain, seed_value: int) -> void:
	var taken := {}
	var uses := {}
	var share := ceili(float(sources.size()) / float(POND_ADJECTIVES.size()))
	for index in range(sources.size()):
		var source: Dictionary = sources[index]
		var named := _pick(POND_ADJECTIVES, POND_NOUNS, seed_value, 0x504F, index, taken, false, uses, share)
		var position: Vector2 = source.get("position", Vector2.ZERO)
		ponds.append({"position": position, "radius": float(source.get("radius", 0.0)),
			"level": _level_at(terrain, position), "name": named["name"], "at": named["at"]})


## Districts: a jittered grid of centres over the map, each cell going to the nearest; each
## named after the biome it is richest in compared with the whole map.
func _split_districts(bounds: Rect2, terrain, seed_value: int) -> void:
	var cell_count: int = _cols * _rows
	_cell_district.resize(cell_count)
	_cell_district.fill(-1)
	if cell_count == 0 or bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	var wanted := clampi(int(round(bounds.size.x * bounds.size.y / DISTRICT_AREA)), MIN_DISTRICTS, MAX_DISTRICTS)
	var aspect := bounds.size.x / bounds.size.y
	var grid_cols := maxi(1, int(round(sqrt(float(wanted) * aspect))))
	var grid_rows := maxi(1, int(ceil(float(wanted) / float(grid_cols))))
	var step := Vector2(bounds.size.x / grid_cols, bounds.size.y / grid_rows)
	var centres: Array = []
	for gy in range(grid_rows):
		for gx in range(grid_cols):
			var slot := centres.size()
			var jitter := Vector2(_unit(seed_value, 0x4A58, slot) - 0.5, _unit(seed_value, 0x4A59, slot) - 0.5) * 0.6
			centres.append(bounds.position + Vector2((gx + 0.5 + jitter.x) * step.x, (gy + 0.5 + jitter.y) * step.y))
	var counts: Array = []
	for _centre in centres:
		counts.append({})
	var map_counts := {}
	for index in range(cell_count):
		var centre_point := _cell_point(index)
		var best := 0
		var best_distance := INF
		for slot in range(centres.size()):
			var distance: float = centre_point.distance_squared_to(centres[slot])
			if distance < best_distance:
				best_distance = distance
				best = slot
		_cell_district[index] = best
		var biome: String = terrain.get_biome_at_index(index)
		counts[best][biome] = int(counts[best].get(biome, 0)) + 1
		map_counts[biome] = int(map_counts.get(biome, 0)) + 1
	var taken := {}
	var uses := {}
	for slot in range(centres.size()):
		var biome := _district_biome(counts[slot], map_counts)
		var adjectives: Array = DISTRICT_ADJECTIVES.get(biome, []) + SHARED_ADJECTIVES
		var named := _pick(adjectives, DISTRICT_NOUNS.get(biome, DISTRICT_NOUNS["meadow"]), seed_value, 0x4449,
			slot, taken, true, uses, 1)
		var centre: Vector2 = _label_point(slot, centres[slot])
		districts.append({"center": centre, "level": _level_at(terrain, centre), "biome": biome,
			"name": named["name"], "at": named["at"]})


## The biome most over-represented in a district against the map, if it covers enough of it.
static func _district_biome(counts: Dictionary, map_counts: Dictionary) -> String:
	var total := 0
	var map_total := 0
	for biome in counts.keys():
		total += int(counts[biome])
	for biome in map_counts.keys():
		map_total += int(map_counts[biome])
	var best := "meadow"
	var best_ratio := 0.0
	for biome in ["meadow", "forest", "drought", "swamp"]:
		var share := float(counts.get(biome, 0)) / maxf(1.0, float(total))
		var map_share := float(map_counts.get(biome, 0)) / maxf(1.0, float(map_total))
		if share < MIN_BIOME_SHARE or map_share <= 0.0:
			continue
		var ratio := share / map_share
		if ratio > best_ratio:
			best_ratio = ratio
			best = biome
	return best


## The cell of the district nearest its centre, so a label lands inside its own district.
func _label_point(slot: int, centre: Vector2) -> Vector2:
	var best := centre
	var best_distance := INF
	for index in range(_cell_district.size()):
		if _cell_district[index] != slot:
			continue
		var point := _cell_point(index)
		var distance := point.distance_squared_to(centre)
		if distance < best_distance:
			best_distance = distance
			best = point
	return best


## The first of a few hashed adjective-noun pairs not yet taken whose adjective has not been
## used more than its `share` yet - so «Звонкий» does not name four ponds while other words
## name none; then any pair not taken; when all are, the first.
static func _pick(adjectives: Array, nouns: Array, seed_value: int, salt: int, index: int, taken: Dictionary,
		district: bool, uses: Dictionary, share: int) -> Dictionary:
	var candidates: Array = []
	for probe in range(PROBES):
		var h: int = AnimalNamesScript.mix(seed_value * 7919 + salt * 31 + index * 104729 + probe * 15485863)
		var adjective := str(adjectives[h % adjectives.size()])
		candidates.append([adjective, compose(adjective, nouns[AnimalNamesScript.mix(h + 1) % nouns.size()], district)])
	for fair in [true, false]:
		for candidate in candidates:
			var named: Dictionary = candidate[1]
			if taken.has(named["name"]) or (fair and int(uses.get(candidate[0], 0)) >= share):
				continue
			taken[named["name"]] = true
			uses[candidate[0]] = int(uses.get(candidate[0], 0)) + 1
			return named
	return candidates[0][1]


func _cell_point(index: int) -> Vector2:
	var cx: int = index % _cols
	return Vector2((cx + 0.5) * _cell_size, (float(index - cx) / float(_cols) + 0.5) * _cell_size)


static func _unit(seed_value: int, salt: int, index: int) -> float:
	return float(AnimalNamesScript.mix(seed_value * 7919 + salt * 31 + index * 104729) % 100000) / 100000.0


static func _level_at(terrain, position: Vector2) -> int:
	var index: int = terrain.get_index_from_position(position)
	return terrain.get_height_at_index(index) if index >= 0 else 0
