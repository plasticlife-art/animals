class_name ReserveOverlay
extends PanelContainer

## What the living reserve's stream shows its viewers, at the top right: how to act on the world
## with the chat, the vote open (or when the next one opens), how the funds stand, how many wards
## live, and the latest of what viewers did (`ReserveSession.told`). Built in code, refreshed twice
## a second; it reads the session and draws nothing of the world.

const MAX_LINES := 4
const HELP := "!имя Имя — взять зверя под опеку\n!моё — показать своего\n!1 !2 !3 — голосовать\n!водопой · !повести · !отстрел — стаду в кадре\n!олени · !лисы · !волки — болеть за вид"

var session = null
var _title: Label
var _help: Label
var _vote: Label
var _funds: Label
var _lines: Label
var _told: Array = []
var _refresh_left := 0.0


func _init() -> void:
	custom_minimum_size = Vector2(380.0, 0.0)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)
	_title = _label(box, "Живой заповедник")
	_help = _label(box, HELP)
	_vote = _label(box, "")
	_funds = _label(box, "")
	_lines = _label(box, "")


func _label(box: VBoxContainer, text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	return label


func bind(new_session) -> void:
	session = new_session
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
	_vote.text = vote_text(session)
	var living := 0
	for ward in session.manager.world_state.adoptions.values():
		if float(ward.get("died_at", -1.0)) < 0.0:
			living += 1
	_funds.text = "%s\nПод опекой: %d" % [funds_text(session), living]
	_lines.text = "\n".join(_told)
	_lines.visible = not _told.is_empty()


## «Голосование, 0:42: 1 Дождь — 3 · 2 Стужа — 5 · 3 Буйная трава — 0», or when the next opens.
static func vote_text(reserve) -> String:
	var vote = reserve.vote
	var now: float = reserve.now()
	if vote.current.is_empty():
		var left := maxf(0.0, float(vote.next_at) - now)
		return "Следующее голосование через %s" % clock(left)
	var parts: Array = []
	var counts: Array = vote.tallies()
	for index in range(vote.current["choices"].size()):
		parts.append("%d %s — %d" % [index + 1, str(vote.current["choices"][index].get("label", "")), int(counts[index])])
	return "Голосование, %s:\n%s" % [clock(maxf(0.0, float(vote.current["closes_at"]) - now)), "\n".join(parts)]


## «Фонды: олени 4 · лисы 2 · волки 0», counting members active since the last count.
static func funds_text(reserve) -> String:
	var funds: Dictionary = reserve.config.get("teams", {}).get("funds", {})
	var counts: Dictionary = reserve.book.active_teams(maxf(0.0, float(reserve._teams_counted_at)))
	var parts: Array = []
	for team in funds.keys():
		parts.append("%s %d" % [str(funds[team].get("label", team)).trim_prefix("Фонд "), int(counts.get(team, 0))])
	return "Фонды: %s" % " · ".join(parts)


static func clock(seconds: float) -> String:
	var whole := int(ceil(seconds))
	@warning_ignore("integer_division")
	return "%d:%02d" % [whole / 60, whole % 60]
