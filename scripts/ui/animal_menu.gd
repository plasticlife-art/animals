class_name AnimalMenu
extends PopupMenu

## What can be done with one animal, at the pointer: a right click on it (a two-finger tap on a
## Mac's trackpad, Ctrl+click). The same things the card, the herd card and the chronicle offer,
## without looking for them: follow it or its herd, pin it, its family tree, its mother or father,
## its species' traits. `items()` says what is offered; `chosen` says what was picked, with the
## animal's id, and the main controller does it.

signal chosen(action: String, agent_id: int)

var _agent_id := -1
var _actions: Array = []


func _init() -> void:
	id_pressed.connect(_on_id_pressed)


## The rows for `agent`: `{action, text, disabled?, target?}`, or `{separator}`. `focus_mode` is
## the camera's, with `agent` the selected one; `herd` whether it lives in a herd one can follow.
static func items(agent, story, focus_mode: String, herd: bool) -> Array:
	var rows: Array = []
	rows.append({"action": "unfollow" if focus_mode == "agent" else "follow",
		"text": "Не следить" if focus_mode == "agent" else "Следить"})
	if herd and int(agent.group_id) >= 0:
		rows.append({"action": "unfollow" if focus_mode == "flock" else "follow_herd",
			"text": "Не следить за стадом" if focus_mode == "flock" else "Следить за стадом"})
	if story != null:
		var pinned: bool = story.is_pinned(agent.id)
		var full: bool = story.pins.size() >= story.MAX_PINS
		rows.append({"action": "pin", "text": "Открепить" if pinned else "Закрепить",
			"disabled": full and not pinned})
		rows.append({"separator": true})
		rows.append({"action": "tree", "text": "Родословная"})
		var entry: Dictionary = story.lineage.entry(agent.id)
		for role in [["mother", "Мать"], ["father", "Отец"]]:
			var parent_id := int(entry.get(role[0], -1))
			if parent_id >= 0:
				var name: String = story.name_of_id(parent_id)
				if story.lineage.is_dead(parent_id):
					name += " †"
				rows.append({"action": "parent", "text": "%s: %s" % [role[1], name], "target": parent_id})
	rows.append({"action": "traits", "text": "Черты вида"})
	return rows


## Opens at `at` (the canvas, as the mouse reports it) for `agent`.
func open_for(agent, story, focus_mode: String, herd: bool, at: Vector2) -> void:
	clear()
	_agent_id = agent.id
	_actions = []
	var title: String = story.name_of(agent) if story != null else HudText.animal_noun(agent.species_type, str(agent.sex))
	add_separator(title)
	_actions.append({})
	for row in items(agent, story, focus_mode, herd):
		if row.has("separator"):
			add_separator()
		else:
			add_item(str(row["text"]), _actions.size())
			set_item_disabled(item_count - 1, bool(row.get("disabled", false)))
		_actions.append(row)
	# A popup is a window of its own and does not take the theme's default size by itself.
	var font_size: int = theme.default_font_size if theme != null and theme.default_font_size > 0 else 16
	add_theme_font_size_override("font_size", font_size)
	add_theme_font_size_override("font_separator_size", font_size)
	popup(Rect2i(Vector2i(at.round()), Vector2i.ZERO))
	# Opening sets a scale of its own (0.8 on this canvas), smaller than the card's type; the
	# main window's - the interface's scale (`SettingsStore` `ui_scale`) - after it.
	content_scale_factor = get_tree().root.content_scale_factor
	reset_size()


func _on_id_pressed(id: int) -> void:
	if id < 0 or id >= _actions.size() or _actions[id].is_empty():
		return
	var row: Dictionary = _actions[id]
	chosen.emit(str(row["action"]), int(row.get("target", _agent_id)))
