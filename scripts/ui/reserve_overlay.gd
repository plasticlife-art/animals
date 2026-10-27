class_name ReserveOverlay
extends PanelContainer

## What the living reserve's stream shows its viewers, at the top left: where the rules are (one
## line, `reserve.json` `overlay.hint`) over the reserve's tables (`ReserveRecords`, by turns every
## `PAGE_SECONDS`) - the commands themselves only now and then and when a viewer asks
## (`help_shown()`) - the vote open (or when the next one opens), who cheers for which species, how
## many wards live, and the latest of what viewers did (`ReserveSession.told`). One line a row, the
## commands in their own colour; it never reaches down to the card of the animal on screen
## (`avoid`): the latest lines go first, then the counts, then the help or the table. Built in
## code, refreshed twice a second; it reads the session and draws nothing of the world.

const MAX_LINES := 2
const PAGE_SECONDS := 15.0
const WIDTH := 420.0
const GAP := 12.0
const HINT := "Правила и команды: напишите !помощь"
const INK := Color(0.20, 0.13, 0.08)
const DIM := Color(0.20, 0.13, 0.08, 0.62)
const COMMAND := Color(0.56, 0.22, 0.05)
const PROBLEM := Color(0.72, 0.18, 0.12)
## The chat's commands, as rows: what to write and what it does, the shorter ones command first.
const COMMANDS := [
	["!имя Ветка", "— взять зверя под опеку"],
	["!моё", "— показать своего"],
	["!1  !2  !3", "— голосовать"],
	["Стаду в кадре:", "!водопой  !повести  !отстрел"],
	["Болеть за вид:", "!олени  !лисы  !волки  !зайцы"],
]

var session = null
var story = null
## What the admin must see - a chat that is not being read («Telegram: неверный токен бота») - in
## red under the title.
var problems: Array = []
## The card the panel must stop above while it is shown (the selected animal's), or null.
var avoid: Control = null
var _box: VBoxContainer
var _next_vote: Label
var _problems: Label
var _vote: Label
var _hint: Label
var _help: VBoxContainer
var _table_title: Label
var _table: Label
var _wards: Label
var _funds: Label
var _lines: Array = []
var _told: Array = []
var _refresh_left := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(WIDTH, 0.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 4)
	margin.add_child(_box)
	var head := HBoxContainer.new()
	_box.add_child(head)
	var title := _label(head, "Живой заповедник", INK, 4)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_next_vote = _label(head, "", DIM, -2)
	_next_vote.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_problems = _label(_box, "", PROBLEM, -2)
	_vote = _label(_box, "", INK)
	_hint = _label(_box, HINT, INK)
	_help = VBoxContainer.new()
	_help.add_theme_constant_override("separation", 0)
	_box.add_child(_help)
	_label(_help, "Пишите в чат:", DIM, -2)
	for row in COMMANDS:
		var line := HBoxContainer.new()
		line.add_theme_constant_override("separation", 6)
		_help.add_child(line)
		var command_first := str(row[0]).begins_with("!")
		_label(line, str(row[0]), COMMAND if command_first else INK)
		_label(line, str(row[1]), INK if command_first else COMMAND)
	_table_title = _label(_box, "", DIM, -2)
	_table = _label(_box, "", INK)
	_wards = _label(_box, "", INK)
	_funds = _label(_box, "", INK)
	for _index in range(MAX_LINES):
		var told := _label(_box, "", DIM, -2)
		told.clip_text = true
		told.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		_lines.append(told)


func _label(parent: Control, text: String, color: Color, size_step := 0) -> Label:
	var label := Label.new()
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	if size_step != 0:
		label.add_theme_font_size_override("font_size", maxi(8, label.get_theme_font_size("font_size") + size_step))
	return label


func bind(new_session, new_story = null) -> void:
	session = new_session
	story = new_story
	if not session.told.is_connected(_on_told):
		session.told.connect(_on_told)
	refresh()


func _on_told(line: Dictionary) -> void:
	_told.append(str(line.get("text", "")))
	if _told.size() > MAX_LINES:
		_told = _told.slice(_told.size() - MAX_LINES)
	refresh()


func _process(delta: float) -> void:
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh_left = 0.5
		refresh()


func refresh() -> void:
	if session == null or session.manager == null or session.manager.world_state == null:
		return
	var world = session.manager.world_state
	_problems.text = "\n".join(problems)
	var open: bool = not session.vote.current.is_empty()
	_next_vote.text = "" if open else "голосование через %s" % clock(maxf(0.0, float(session.vote.next_at) - session.now()))
	_vote.text = vote_text(session) if open else ""
	var helping := help_shown(session)
	_hint.text = "" if helping else str(session.config.get("overlay", {}).get("hint", HINT))
	_help.visible = helping
	var page := int(Time.get_ticks_msec() / (PAGE_SECONDS * 1000.0))
	var table := "" if helping else ReserveRecords.page_text(page, world, story, session,
		story.calendar() if story != null else [120.0, 4])
	# Its first line is its title, set apart as the help's «Пишите в чат:» is.
	_table_title.text = table.get_slice("\n", 0)
	_table.text = table.substr(_table_title.text.length() + 1)
	var living := 0
	for ward in world.adoptions.values():
		if float(ward.get("died_at", -1.0)) < 0.0:
			living += 1
	_wards.text = "" if living == 0 else "Под опекой %d %s" % [living, HudText.plural(living, ["зверь", "зверя", "зверей"])]
	_funds.text = funds_text(session)
	for index in range(MAX_LINES):
		_lines[index].text = str(_told[index]) if index < _told.size() else ""
	_fit()


## Shows what has text and fits above `avoid`: the latest lines are dropped first, then the counts,
## then the help or the table. The title and an open vote always stay.
func _fit() -> void:
	_problems.visible = _problems.text != ""
	_vote.visible = _vote.text != ""
	_hint.visible = _hint.text != ""
	_table.visible = _table.text != ""
	_table_title.visible = _table.visible
	_wards.visible = _wards.text != ""
	_funds.visible = _funds.text != ""
	for told in _lines:
		told.visible = told.text != ""
	var room := _room()
	var droppable: Array = _lines.duplicate()
	droppable.reverse()
	droppable.append_array([_funds, _wards, _table if _table.visible else _help])
	for control in droppable:
		if _height() <= room:
			return
		control.visible = false
		if control == _table:
			_table_title.visible = false


## How tall the panel may be: down to `avoid`'s top while it is shown, else to the screen's foot.
func _room() -> float:
	var foot := get_viewport_rect().size.y if is_inside_tree() else INF
	if avoid != null and avoid.is_visible_in_tree() and avoid.size.y > 0.0:
		foot = avoid.get_global_rect().position.y
	return foot - GAP - (global_position.y if is_inside_tree() else 0.0)


## The panel's height for what is visible now, from its labels: a container's own size lags a frame.
func _height() -> float:
	var frame := 20.0
	var style := get_theme_stylebox("panel")
	if style != null:
		frame += style.get_minimum_size().y
	return frame + _stack_height(_box)


static func _stack_height(control: Control) -> float:
	if control is Label:
		return control.get_minimum_size().y
	var tallest := 0.0
	var total := 0.0
	var shown := 0
	for child in control.get_children():
		if not child is Control or not child.visible:
			continue
		var height := _stack_height(child)
		tallest = maxf(tallest, height)
		total += height
		shown += 1
	if control is HBoxContainer:
		return tallest
	if control is VBoxContainer and shown > 1:
		total += float(control.get_theme_constant("separation")) * float(shown - 1)
	return total


## Whether the commands show now: for `overlay.help_seconds` every `overlay.help_every_seconds` of
## the world's time (0: not by themselves), and that long after a viewer asked («!помощь»).
static func help_shown(reserve) -> bool:
	var settings: Dictionary = reserve.config.get("overlay", {})
	var now: float = reserve.now()
	var showing := float(settings.get("help_seconds", 20.0))
	var every := float(settings.get("help_every_seconds", 300.0))
	var asked := float(reserve.help_asked_at)
	if now >= asked and now - asked < showing:
		return true
	return every > 0.0 and fmod(now, every) < showing


## «Голосование, 0:42:\n1 Дождь — 3\n2 Стужа — 5\n3 Буйная трава — 0», or when the next opens.
static func vote_text(reserve) -> String:
	var vote = reserve.vote
	var now: float = reserve.now()
	if vote.current.is_empty():
		var left := maxf(0.0, float(vote.next_at) - now)
		return "Следующее голосование через %s" % clock(left)
	var parts: Array = []
	var counts: Array = vote.tallies()
	for index in range(vote.current["choices"].size()):
		parts.append("!%d %s — %d" % [index + 1, str(vote.current["choices"][index].get("label", "")), int(counts[index])])
	return "Голосование, ещё %s:\n%s" % [clock(maxf(0.0, float(vote.current["closes_at"]) - now)), "\n".join(parts)]


## «Болеют: за оленей 4 · за лис 2 — подмога через 3:10», counting members active since the last
## count; "" while nobody does.
static func funds_text(reserve) -> String:
	var settings: Dictionary = reserve.config.get("teams", {})
	var funds: Dictionary = settings.get("funds", {})
	var counts: Dictionary = reserve.book.active_teams(maxf(0.0, float(reserve._teams_counted_at)))
	var parts: Array = []
	for team in funds.keys():
		if int(counts.get(team, 0)) > 0:
			parts.append("за %s %d" % [str(funds[team].get("label", team)).trim_prefix("Фонд "), int(counts[team])])
	if parts.is_empty():
		return ""
	var text := "Болеют: %s" % " · ".join(parts)
	if float(reserve._teams_counted_at) >= 0.0:
		var left := float(reserve._teams_counted_at) + float(settings.get("every_seconds", 300.0)) - float(reserve.now())
		text += " — подмога через %s" % clock(maxf(0.0, left))
	return text


static func clock(seconds: float) -> String:
	var whole := int(ceil(seconds))
	@warning_ignore("integer_division")
	return "%d:%02d" % [whole / 60, whole % 60]
