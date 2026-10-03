class_name SelectionCard
extends PanelContainer

## The fixed readout for the selected animal - the same three vitals the overhead
## tag carries, but with room for the raw numbers, the state, and the follow toggle.
##
## Separate from `DebugPanel` on purpose. That panel is a debugging instrument hidden
## behind Tab; this is the one thing that should be on screen whenever an animal is
## selected, which is why it is a sibling rather than a child - `set_hud_visible()`
## only touches the debug and charts panels, so this survives Tab untouched.
##
## It also owns the visible follow state. `focus_mode` is cleared behind the user's
## back by any camera pan (`GameCamera._clear_focus_if_active()`), so the button
## listens to `focus_mode_changed` rather than tracking its own idea of the state.

signal follow_toggled(enabled: bool)
## A parent's name was clicked in the family line.
signal family_clicked(agent_id: int)

@onready var title_label: Label = get_node_or_null("%TitleLabel")
@onready var bars_view: Control = get_node_or_null("%BarsView")
@onready var action_label: Label = get_node_or_null("%ActionLabel")
@onready var follow_button: Button = get_node_or_null("%FollowButton")
@onready var family_text: RichTextLabel = get_node_or_null("%FamilyText")
@onready var pin_button: Button = get_node_or_null("%PinButton")

const BAR_HEIGHT := 10.0
const BAR_SPACING := 8.0
## Space reserved at the right of the bar strip for "63 / 150".
const VALUE_COLUMN := 74.0

var simulation_manager: SimulationManager
## The world's names and family tree (`StoryBook`); without it the card shows numbers.
var story = null
var _vitals: Array = []


func _ready() -> void:
	if follow_button != null:
		follow_button.pressed.connect(_on_follow_button_pressed)
	if pin_button != null:
		pin_button.pressed.connect(_on_pin_button_pressed)
	if family_text != null:
		family_text.meta_clicked.connect(func(meta) -> void: family_clicked.emit(int(str(meta))))
	if bars_view != null:
		bars_view.draw.connect(_on_bars_view_draw)
		# The strip is drawn, so nothing about it reaches the container's own sizing.
		# Three rows of label-over-bar, measured off the theme font rather than
		# guessed, or the card clips its last bar at a different font size.
		var line_height := 16.0
		var font := bars_view.get_theme_default_font()
		if font != null:
			line_height = font.get_height(bars_view.get_theme_default_font_size())
		bars_view.custom_minimum_size.y = 3.0 * (line_height + 2.0 + BAR_HEIGHT + BAR_SPACING)
	visible = false


func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	simulation_manager.selection_changed.connect(_on_selection_changed)
	simulation_manager.tick_completed.connect(_on_tick_completed)
	simulation_manager.focus_mode_changed.connect(set_follow_state)
	set_follow_state(simulation_manager.focus_mode)
	refresh()


## Reflects the manager's focus mode, whatever changed it. A pan clears the focus
## without going through the button, and this is what makes that visible instead of
## leaving the camera silently detached.
## Pressed only while the camera follows this animal: following its herd is the herd
## card's toggle, and pressing this one then switches to the animal.
func set_follow_state(mode: String) -> void:
	if follow_button == null:
		return
	var following := mode == "agent"
	follow_button.text = "Слежу" if following else "Следить"
	follow_button.button_pressed = following


func _show_pin(agent) -> void:
	var pinned: bool = story != null and story.is_pinned(agent.id)
	var full: bool = story != null and story.pins.size() >= story.MAX_PINS
	pin_button.set_pressed_no_signal(pinned)
	pin_button.text = "Закреплено" if pinned else "Закрепить"
	pin_button.disabled = story == null or (full and not pinned)
	if pin_button.disabled and story != null:
		pin_button.tooltip_text = "Не больше %d закреплённых" % story.MAX_PINS
	else:
		pin_button.tooltip_text = "Держать в списке вверху слева, где бы оно ни было"


func _on_pin_button_pressed() -> void:
	if story != null and simulation_manager != null:
		story.toggle_pin(simulation_manager.get_selected_agent())
	refresh()


## «Мать: Ветка · Отец: Бурый» with the names as links, then «Детей: 3 (живы 2) · Потомков
## живых: 5 · Поколение 2». A parent who died is marked so.
static func family_line(story_book, agent) -> String:
	var entry: Dictionary = story_book.lineage.entry(agent.id)
	var parents: Array = []
	for role in [["mother", "Мать"], ["father", "Отец"]]:
		var parent_id := int(entry.get(role[0], -1))
		if parent_id >= 0:
			parents.append("%s: %s" % [role[1], _parent_link(story_book, parent_id)])
	if parents.is_empty():
		parents.append("Родители неизвестны")
	var children: Array = story_book.lineage.children(agent.id)
	var living := 0
	for child in children:
		if not story_book.lineage.is_dead(int(child)):
			living += 1
	return "%s\nДетей: %d (живы %d) · Потомков живых: %d · Поколение %d" % [" · ".join(parents),
		children.size(), living, story_book.lineage.descendants_alive(agent.id), int(entry.get("generation", 1))]


static func _parent_link(story_book, parent_id: int) -> String:
	var name: String = story_book.name_of_id(parent_id)
	if story_book.lineage.is_dead(parent_id):
		var sex := str(story_book.lineage.entry(parent_id).get("sex", ""))
		name += " (%s)" % HudText.verb(sex, "погиб", "погибла")
	return "[url=%d]%s[/url]" % [parent_id, name]


func _on_follow_button_pressed() -> void:
	follow_toggled.emit(simulation_manager == null or simulation_manager.focus_mode != "agent")


func _on_selection_changed(_agent_id: int) -> void:
	refresh()


## Follows the HUD's refresh cadence rather than the frame rate: the values only
## change on a tick, and redrawing them at 60 Hz makes the digits flicker.
func _on_tick_completed(tick: int, _snapshot: Dictionary) -> void:
	if simulation_manager != null and not simulation_manager.should_refresh_ui_on_tick(tick):
		return
	refresh()


func refresh() -> void:
	var agent = null
	if simulation_manager != null and simulation_manager.world_state != null:
		agent = simulation_manager.get_selected_agent()
	if agent == null or not agent.is_alive:
		_vitals = []
		visible = false
		return

	visible = true
	if title_label != null:
		title_label.text = AgentReadout.title(agent, "" if story == null else story.name_of(agent))
	if family_text != null:
		family_text.text = "" if story == null else family_line(story, agent)
	if pin_button != null:
		_show_pin(agent)
	if action_label != null:
		action_label.text = "%s  ·  %s" % [AgentReadout.action_label(agent), HudText.state_label(agent.state)]
	_vitals = AgentReadout.vitals(agent)
	if bars_view != null:
		bars_view.queue_redraw()


## Drawn rather than built from ProgressBars: the pixel theme styles panels and
## buttons only, so a stock ProgressBar would be the one grey control on the card.
func _on_bars_view_draw() -> void:
	if bars_view == null or _vitals.is_empty():
		return
	var font := bars_view.get_theme_default_font()
	var font_size := bars_view.get_theme_default_font_size()
	if font == null:
		return

	var bar_width: float = maxf(40.0, bars_view.size.x - VALUE_COLUMN)
	var y := 0.0
	for entry in _vitals:
		var label_size := font.get_string_size(entry["label"], HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
		bars_view.draw_string(font, Vector2(0.0, y + label_size.y * 0.8), entry["label"],
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, PixelUiTheme.INK)
		var value := AgentReadout.value_text(entry)
		bars_view.draw_string(font, Vector2(bar_width + 8.0, y + label_size.y * 0.8), value,
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, PixelUiTheme.INK_DIM)
		AgentReadout.draw_bars(bars_view, Vector2(0.0, y + label_size.y + 2.0), bar_width,
			BAR_HEIGHT, 0.0, [entry])
		y += label_size.y + 2.0 + BAR_HEIGHT + BAR_SPACING
