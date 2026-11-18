class_name AnimalNames
extends RefCounted

## A name for every animal, in Russian, from a list for its species and sex: «Ветка», and
## «Ветка II» while another Ветка is alive. Names belong to the view - nothing in the
## simulation reads them - and are kept with the save, so an animal keeps its name.
##
## A name is the world's, not a species': a fox Огонёк and a hare Огонёк are not alive at once,
## so the name over an animal is enough for a viewer to call it by in the chat (`find()`).
## Which name an animal gets is a hash of its id - the first of a few hashed picks that no
## living animal answers to - so the same world names the same animals the same way. Only
## when every pick is taken does the name get a number, the lowest one no living animal of
## that name holds: a death frees it, as a herd names a calf after one it lost.
## The order animals are named in - founders by id at the start, then each birth as it is
## heard - is the order of the world's events, so it repeats with them.

const LISTS := {
	"herbivore": {
		"female": ["Ветка", "Звёздочка", "Ласка", "Берёзка", "Росинка", "Тучка", "Зорька", "Лань", "Искра",
			"Капля", "Ромашка", "Былинка", "Дымка", "Пушинка", "Снежинка", "Рябинка", "Калинка",
			"Ягодка", "Тихоня", "Вербочка", "Метелица", "Зарянка", "Иволга", "Мята", "Липа", "Купава",
			"Заря", "Поляна", "Осока", "Ива", "Черника", "Брусника", "Синичка", "Белянка", "Пёстрая",
			"Кроха", "Пчёлка", "Ольха", "Незабудка", "Василиса", "Ракита", "Сирень", "Кувшинка",
			"Веснянка", "Голубка", "Ласточка", "Певунья", "Ночка", "Дубрава", "Ёлочка", "Малина",
			"Смородина", "Осинка", "Снежана", "Вьюжка", "Морошка", "Земляника", "Медуница", "Душица",
			"Фиалка", "Мальва", "Лебёдушка", "Синева", "Радуга", "Светлянка", "Луна", "Зимушка",
			"Хвоинка", "Полынь", "Вербена", "Арника", "Ежевика", "Голубика", "Клюква", "Черёмуха",
			"Яблонька", "Вишня", "Тропинка", "Капелька", "Росава",
			"Лилия", "Гвоздика", "Лаванда", "Мелисса", "Сосенка", "Травинка", "Отрада", "Услада",
			"Милава", "Любава", "Забава", "Весна", "Волна", "Заводь", "Прохлада", "Свирель", "Песенка",
			"Загадка", "Мечта", "Лоза", "Лещина", "Бузина", "Кашка", "Пижма", "Льдинка", "Позёмка",
			"Проталинка", "Лужайка", "Опушка", "Ложбинка", "Стёжка", "Горлица", "Малиновка", "Пеночка",
			"Стрекоза", "Ясна", "Добрава", "Дождинка", "Мурава", "Таволга", "Камышинка", "Тростинка",
			"Нива", "Жимолость", "Плясунья", "Резвушка", "Скромница", "Дрёма", "Нега", "Отава", "Серна",
			"Северянка", "Пташка", "Чайка", "Лапушка",
			"Снегурка", "Пурга", "Стужа", "Оттепель", "Листва", "Тайга", "Степь", "Даль", "Высь",
			"Ладушка", "Рябь", "Струна", "Скрипка", "Жалейка", "Потешка", "Прибаутка", "Частушка",
			"Смуглянка", "Чернобровка", "Белогрудка", "Пятнышко", "Облачко"],
		"male": ["Бурый", "Рогач", "Ветер", "Гром", "Дубок", "Боровик", "Стриж", "Сокол", "Яр", "Туман",
			"Буян", "Пепел", "Клён", "Тополь", "Лесник", "Странник", "Ясень", "Вихрь", "Кедр", "Мох",
			"Бор", "Каштан", "Орех", "Граф", "Князь", "Крепыш", "Смельчак", "Седой", "Ясный", "Тихон",
			"Ярило", "Овраг", "Камень", "Ручей", "Горец", "Удалец", "Север", "Беркут", "Явор",
			"Багульник", "Валун", "Утёс", "Перевал", "Гранит", "Дозор", "Рассвет", "Закат", "Полдень",
			"Зенит", "Бурелом", "Валежник", "Можжевельник", "Вереск", "Чертополох", "Лопух", "Репей",
			"Желудь", "Дуб", "Вяз", "Граб", "Осокорь", "Рокот", "Набат", "Звон", "Гул", "Шорох",
			"Шёпот", "Зарево", "Холм", "Курган", "Перекат", "Плёс", "Омут", "Брод", "Ветрогон",
			"Сугроб", "Иней", "Мороз", "Ливень", "Гордей",
			"Ветвистый", "Широкорог", "Златорог", "Богатырь", "Витязь", "Воевода", "Боярин", "Атаман",
			"Статный", "Великан", "Исполин", "Ураган", "Шквал", "Раскат", "Сосняк", "Ельник",
			"Березняк", "Орешник", "Тальник", "Камыш", "Хмель", "Шалфей", "Чабрец", "Зверобой",
			"Василёк", "Ковыль", "Заречный", "Степняк", "Таёжник", "Путник", "Пилигрим", "Отшельник",
			"Мудрец", "Молчун", "Упрямец", "Храбрец", "Силач", "Белохвост", "Рыжебок", "Серебряк",
			"Булат", "Алмаз", "Малахит", "Самоцвет", "Месяц", "Восход", "Вечер", "Листопад", "Снегопад",
			"Ледоход", "Родник", "Исток", "Порог", "Кряж", "Бугор",
			"Гонец", "Скороход", "Прыгун", "Скакун", "Зоркий", "Чуткий", "Часовой", "Ястреб", "Кречет",
			"Филин", "Ворон", "Лунь", "Сыч", "Тур", "Байкал", "Урал", "Алтай", "Енисей", "Амур", "Дон",
			"Иртыш", "Казбек"],
	},
	"predator": {
		"female": ["Огнёвка", "Рыжуха", "Лисичка", "Патрикеевна", "Алиса", "Хитрюга", "Искорка", "Рябина",
			"Медь", "Осень", "Ржавка", "Плутовка", "Злата", "Огневица", "Шустрая", "Краса", "Кумушка",
			"Лучина", "Заряна", "Жарка", "Рыжинка", "Вьюга", "Лиска", "Зоряна", "Багрянка", "Калина",
			"Ночка", "Тень", "Смута", "Веста", "Лукавка", "Огнея", "Пламенка", "Каштанка", "Бестия",
			"Проказа", "Затея", "Хитринка", "Рыжая", "Янтарка", "Охра", "Корица", "Умница", "Сказка",
			"Зарница", "Ворожея", "Мгла", "Полночь", "Заноза", "Огонька"],
		"male": ["Рыжик", "Огонёк", "Хитрец", "Лукавый", "Пламень", "Медяк", "Ржавый", "Шельмец", "Хват",
			"Плут", "Жар", "Багрец", "Сполох", "Вьюн", "Кузя", "Рыж", "Ловкач", "Шустрик", "Факел",
			"Костёр", "Огнедар", "Сумрак", "Мираж", "Патрик", "Уголь", "Колос", "Ухарь", "Рассвет",
			"Сорвиголова", "Вихрун", "Пройдоха", "Проныра", "Шалун", "Озорник", "Задор", "Жгучий",
			"Червонец", "Янтарь", "Медовик", "Ржавчик", "Хитрован", "Ловец", "Следопыт", "Бродяга",
			"Скиталец", "Полуночник", "Хвостатый", "Огнёвик", "Лучик", "Шмель"],
	},
	"wolf": {
		"female": ["Вьюга", "Метель", "Пурга", "Стужа", "Луна", "Мгла", "Зима", "Дымка", "Тень", "Ночь",
			"Буря", "Гроза", "Злата", "Лада", "Веда", "Ярка", "Седая", "Пороша", "Тундра", "Кама",
			"Ока", "Вега", "Тишь", "Льдинка", "Осень", "Ветла", "Северина", "Забава", "Смелая", "Резва",
			"Хмара", "Туча", "Зорянка", "Рысца", "Белава", "Ярина", "Роса", "Веста", "Мара", "Дана"],
		"male": ["Серый", "Буран", "Клык", "Вожак", "Гром", "Туман", "Ветер", "Сумрак", "Бурый", "Полкан",
			"Казбек", "Алтай", "Урал", "Север", "Байкал", "Ярый", "Лютый", "Матёрый", "Шторм", "Пепел",
			"Дым", "Валун", "Утёс", "Гранит", "Граф", "Вихрь", "Бор", "Седой", "Тихон", "Беркут",
			"Ворон", "Рык", "Хмурый", "Рокот", "Мрак", "Кряж", "Ратибор", "Храбр", "Святобор", "Дозор"],
	},
	"hare": {
		"female": ["Пуша", "Ушанка", "Прыгунья", "Морковка", "Капустка", "Былиночка", "Травинка", "Клеверка",
			"Пятка", "Белянка", "Беляночка", "Русачка", "Пушинка", "Скакалка", "Шустрая", "Трусишка",
			"Зайка", "Ушастик", "Луговка", "Полянка", "Тимошка", "Рыжинка", "Резвушка", "Норушка",
			"Овсянка", "Кашка", "Медуница", "Звёздочка", "Песчинка", "Сорока", "Летунья", "Прыткая",
			"Земляничка", "Хрустинка", "Снежка", "Ромашка", "Осинка", "Вишенка", "Дремушка", "Жужа"],
		"male": ["Косой", "Русак", "Беляк", "Прыгун", "Ушастый", "Скок", "Шустрик", "Трусишка", "Быстроног",
			"Пушок", "Серый", "Лопух", "Клевер", "Тимофей", "Степан", "Кузя", "Прошка", "Тишка", "Хруст",
			"Шмыг", "Порх", "Рыжик", "Зигзаг", "Скороход", "Петляй", "Кочка", "Полевик", "Луговик",
			"Огонёк", "Ветерок", "Стриж", "Юрок", "Бобка", "Пятнаш", "Сенька", "Овсяник", "Копуша",
			"Барсучок", "Мох", "Лёшик"],
	},
	"scavenger": {
		"female": ["Чернушка", "Рябушка", "Пеструшка", "Крапинка", "Хохлатка", "Серушка", "Курочка",
			"Малинка", "Брусничка", "Голубка", "Пятнашка", "Пёрышко", "Вертушка", "Чечётка",
			"Невеличка", "Хлопотунья", "Ряба", "Крошка", "Смородинка", "Вишенка", "Метла", "Полушка",
			"Копейка", "Зернинка", "Росянка", "Говорушка", "Тетёрочка", "Сойка", "Капелька", "Тишина",
			"Хлопушка", "Щебетунья", "Болтушка", "Квочка", "Наседка", "Серёжка", "Бусинка",
			"Горошинка", "Пшёнка", "Крупинка", "Гречка", "Клюковка", "Черничка", "Шишечка", "Веточка",
			"Пестрянка", "Чернавка", "Хохотушка", "Непоседа", "Тараторка",
			"Трещотка", "Свиристелка", "Пискуша", "Соринка", "Пылинка", "Мушка", "Букашка", "Пуговка",
			"Кнопка", "Пышка", "Плюшка", "Ватрушка", "Баранка", "Сушка", "Булочка", "Пампушка",
			"Петелька", "Ниточка", "Варежка", "Рукавичка", "Растрёпа", "Чистюля", "Модница", "Хозяйка",
			"Соседка", "Сплетница", "Трусишка", "Цокотуха", "Береста", "Костяничка", "Семечка",
			"Маковка", "Перчинка", "Изюминка"],
		"male": ["Уголёк", "Чернец", "Косач", "Бровастый", "Токарь", "Лирохвост", "Гребешок", "Буран",
			"Смоль", "Сажа", "Барин", "Задира", "Певун", "Бормотун", "Шумила", "Черныш", "Коготь",
			"Ветрогон", "Крикун", "Хохолок", "Щёголь", "Франт", "Бас", "Токун", "Петушок", "Перун",
			"Чернобров", "Гордец", "Забияка", "Трубач", "Дьячок", "Звонарь", "Глашатай", "Гусляр",
			"Балагур", "Хвастун", "Красавчик", "Кавалер", "Модник", "Вожак", "Сторож", "Дозорный",
			"Ворчун", "Бубнила", "Чумазый", "Смолян", "Кремень", "Пижон", "Гуляка", "Запевала",
			"Чубчик", "Мохноног", "Бородач", "Усач", "Краснобров", "Валенок", "Чернокрыл", "Белокрыл",
			"Драчун", "Хулиган", "Шалопай", "Лентяй", "Обжора", "Толстяк", "Пузан", "Колобок", "Бублик",
			"Пряник", "Кренделёк", "Пончик", "Орешек", "Горошек", "Свистун", "Скоморох", "Затейник",
			"Говорун", "Брюзга", "Задавака", "Купец", "Пономарь", "Ямщик", "Мельник", "Кузнец",
			"Бондарь"],
	},
}

## Hashes tried for a name no living animal holds before taking a number.
const PROBES := 8

var _names: Dictionary = {}
## The numbered names living animals hold, of every species: `"<name>"` -> {number: id}. A save
## from before names were the world's keyed them `"<species>:<name>"` (`import_state()`).
var _held: Dictionary = {}
## The key and number each named animal holds, by id, so a death frees the right one.
var _holding: Dictionary = {}


## The animal's name, given now if it has none yet. An unknown species gets «№<id>».
func name_of(agent_id: int, species: String, sex: String) -> String:
	if _names.has(agent_id):
		return _names[agent_id]
	var listed: Array = LISTS.get(species, {}).get(sex, LISTS.get(species, {}).get("female", []))
	if listed.is_empty():
		_names[agent_id] = "№%d" % agent_id
		return _names[agent_id]
	# The first of a few hashed picks no living animal answers to; only when all are taken
	# does the first pick get a number.
	var base: String = listed[mix(agent_id) % listed.size()]
	for probe in range(PROBES):
		var candidate: String = listed[mix(agent_id + probe * 7919) % listed.size()]
		if _held.get(candidate, {}).is_empty():
			base = candidate
			break
	var number := _hold(agent_id, base, 1)
	_names[agent_id] = base if number == 1 else "%s %s" % [base, roman(number)]
	return _names[agent_id]


## The living animals whose name is `text`, by id, lowest first: case, «ё» and spaces aside, and
## «Ветка 2» the same as «Ветка II». One unless a save from before names were the world's kept
## two of a name alive.
func find(text: String) -> Array:
	var wanted := spelled(text)
	var found: Array = []
	if wanted == "":
		return found
	for agent_id in _holding.keys():
		if spelled(str(_names.get(agent_id, ""))) == wanted:
			found.append(int(agent_id))
	found.sort()
	return found


## Whether the animal holds its name now: alive, as far as the names know.
func holds(agent_id: int) -> bool:
	return _holding.has(agent_id)


## `base` held by `agent_id` under the lowest number from `number` up that no living animal holds;
## the number it got.
func _hold(agent_id: int, base: String, number: int) -> int:
	var held: Dictionary = _held.get(base, {})
	while held.has(number):
		number += 1
	held[number] = agent_id
	_held[base] = held
	_holding[agent_id] = [base, number]
	return number


## The name already given, or empty.
func known(agent_id: int) -> String:
	return str(_names.get(agent_id, ""))


## The animal died: its number goes back for the next of its name. It keeps the name.
func release(agent_id: int) -> void:
	var holding: Array = _holding.get(agent_id, [])
	if holding.is_empty():
		return
	_holding.erase(agent_id)
	var held: Dictionary = _held.get(holding[0], {})
	if int(held.get(holding[1], -1)) == agent_id:
		held.erase(holding[1])


## Forgets animals the family tree no longer keeps.
func forget(agent_id: int) -> void:
	release(agent_id)
	_names.erase(agent_id)


func size() -> int:
	return _names.size()


func export_state() -> Dictionary:
	return {"names": _names.duplicate(), "held": _held.duplicate(true), "holding": _holding.duplicate(true)}


## A save from before names were the world's held them by species (`"<species>:<name>"`): they are
## held by name now, and of two of a name alive the later id takes the next number, keeping the
## name it shows, so no third is given it while either lives.
func import_state(data: Dictionary) -> void:
	_names = data.get("names", {}).duplicate()
	_held.clear()
	_holding.clear()
	var holding: Dictionary = data.get("holding", {})
	var ids: Array = holding.keys()
	ids.sort()
	for agent_id in ids:
		var entry: Array = holding[agent_id]
		var key := str(entry[0])
		_hold(int(agent_id), key.substr(key.find(":") + 1), int(entry[1]))


func clear() -> void:
	_names.clear()
	_held.clear()
	_holding.clear()


## Spreads neighbouring ids across the list.
static func mix(value: int) -> int:
	var h: int = value * 0x2c1b3c6d + 0x9e3779b9
	h = (h ^ (h >> 15)) * 0x297a2d39
	h = h ^ (h >> 13)
	return h & 0x7fffffff


## A name as the chat may spell it, for comparing: lower case, «ё» as «е», one space between
## words, a closing number in Roman letters, the first of a name none: «ветка 2» is «ветка ii»,
## «Ветка I» is «ветка».
static func spelled(text: String) -> String:
	var words := PackedStringArray()
	for word in text.to_lower().replace("ё", "е").replace("\t", " ").split(" ", false):
		words.append(word)
	if words.size() > 1 and words[-1].is_valid_int():
		words[-1] = roman(int(words[-1])).to_lower()
	if words.size() > 1 and words[-1] == "i":
		words.remove_at(words.size() - 1)
	return " ".join(words)


static func roman(number: int) -> String:
	var values := [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1]
	var letters := ["M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I"]
	var out := ""
	var left := maxi(1, number)
	for index in range(values.size()):
		while left >= values[index]:
			out += letters[index]
			left -= values[index]
	return out
