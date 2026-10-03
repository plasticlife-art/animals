class_name HerdCard
extends PanelContainer

## The herd of the selected animal, above its own card: how many there are, near and
## far, how many are young, how fed, watered and rested they are on average, whether
## anything is hunting them and what they lost last, with a toggle that puts the camera
## on the herd (`focus_mode` "flock"). In Russian, like the strip at the top; the card
## below stays the English one it was.
##
## Shown only while a herding animal is selected (`HerdReadout.has_herd()`): predators
## keep to pairs and get none, and the card goes when the selection dies or the start
## menu is up. The losses come from `world_event` into a `HerdLossLog`, started afresh
## with each world, since herd ids start again with it.

signal follow_toggled(enabled: bool)

const HerdReadoutScript := preload("res://scripts/ui/herd_readout.gd")
const HerdLossLogScript := preload("res://scripts/ui/herd_loss_log.gd")
const BAR_HEIGHT := 10.0
const BAR_SPACING := 8.0
## Space reserved at the right of the bar strip for "63 / 100".
const VALUE_COLUMN := 74.0
const BAR_LABELS := ["Силы", "Сытость", "Вода"]

var simulation_manager: SimulationManager
var losses = HerdLossLogScript.new()
## What the card shows now (`HerdReadout.summarize()`), empty while hidden.
var summary: Dictionary = {}
var _allowed: bool = true
var _bars: Array = []
var _title: Label
var _counts: Label
var _bars_view: Control
var _hunt: Label
var _loss: Label
var _follow: Button


func _init() -> void:
	var margin := MarginContainer.new()
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 10)
	add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)
	_title = Label.new()
	box.add_child(_title)
	_counts = Label.new()
	box.add_child(_counts)
	_bars_view = Control.new()
	_bars_view.custom_minimum_size = Vector2(300.0, 0.0)
	_bars_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bars_view.draw.connect(_on_bars_view_draw)
	box.add_child(_bars_view)
	_hunt = Label.new()
	box.add_child(_hunt)
	_loss = Label.new()
	box.add_child(_loss)
	_follow = Button.new()
	_follow.toggle_mode = true
	_follow.pressed.connect(_on_follow_pressed)
	box.add_child(_follow)
	visible = false


func _ready() -> void:
	# The bars are drawn, so their height reaches the container only through this, measured
	# off the theme font as the selection card does.
	var line_height := 16.0
	var font := _bars_view.get_theme_default_font()
	if font != null:
		line_height = font.get_height(_bars_view.get_theme_default_font_size())
	_bars_view.custom_minimum_size.y = 3.0 * (line_height + 2.0 + BAR_HEIGHT + BAR_SPACING)


## Binds to `manager` for a new world: the log starts empty, as the herd ids do.
func bind_manager(manager: SimulationManager) -> void:
	simulation_manager = manager
	losses.clear()
	if not manager.selection_changed.is_connected(_on_selection_changed):
		manager.selection_changed.connect(_on_selection_changed)
	if not manager.tick_completed.is_connected(_on_tick_completed):
		manager.tick_completed.connect(_on_tick_completed)
	if not manager.focus_mode_changed.is_connected(set_follow_state):
		manager.focus_mode_changed.connect(set_follow_state)
	if not manager.world_event.is_connected(losses.hear):
		manager.world_event.connect(losses.hear)
	set_follow_state(manager.focus_mode)
	refresh()


## False while the start menu is up: the card stays hidden whatever is selected.
func set_allowed(value: bool) -> void:
	_allowed = value
	refresh()


## Pressed while the camera follows the herd. Following the animal alone is the card
## below's button, so this one shows only the flock mode.
func set_follow_state(mode: String) -> void:
	_follow.button_pressed = mode == "flock"


func _on_follow_pressed() -> void:
	follow_toggled.emit(simulation_manager == null or simulation_manager.focus_mode != "flock")


func _on_selection_changed(_agent_id: int) -> void:
	refresh()


func _on_tick_completed(tick: int, _snapshot: Dictionary) -> void:
	if simulation_manager != null and not simulation_manager.should_refresh_ui_on_tick(tick):
		return
	refresh()


func refresh() -> void:
	var agent = null
	var world = null
	if simulation_manager != null and simulation_manager.world_state != null:
		world = simulation_manager.world_state
		agent = simulation_manager.get_selected_agent()
	if not _allowed or agent == null or not agent.is_alive or not HerdReadoutScript.has_herd(world, agent):
		summary = {}
		_bars = []
		visible = false
		return
	var species: String = agent.species_type
	var group_id := int(agent.group_id)
	summary = HerdReadoutScript.summarize(world, species, group_id)
	_title.text = HerdReadoutScript.title(species, group_id)
	_counts.text = HerdReadoutScript.counts_text(summary)
	_hunt.text = HerdReadoutScript.hunters_text(int(summary["hunters"]))
	_loss.text = HerdReadoutScript.loss_text(losses.last_loss(species, group_id), simulation_manager.simulation_time)
	_follow.text = HerdReadoutScript.follow_text(species)
	# The herd's means against the selected animal's own limits: one species, one set.
	_bars = AgentReadout.need_bars(float(summary["energy"]), float(summary["hunger"]), float(summary["thirst"]),
		maxf(1.0, agent.need_max), maxf(1.0, float(agent.metabolism.get("max_energy", 100.0))),
		agent.balance.get("state_thresholds", {}), BAR_LABELS)
	visible = true
	_bars_view.queue_redraw()


## Drawn like the selection card's, so the two read as one stack.
func _on_bars_view_draw() -> void:
	if _bars.is_empty():
		return
	var font := _bars_view.get_theme_default_font()
	var font_size := _bars_view.get_theme_default_font_size()
	if font == null:
		return
	var bar_width: float = maxf(40.0, _bars_view.size.x - VALUE_COLUMN)
	var y := 0.0
	for entry in _bars:
		var label_size := font.get_string_size(entry["label"], HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size)
		_bars_view.draw_string(font, Vector2(0.0, y + label_size.y * 0.8), entry["label"],
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, PixelUiTheme.INK)
		_bars_view.draw_string(font, Vector2(bar_width + 8.0, y + label_size.y * 0.8), AgentReadout.value_text(entry),
			HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, PixelUiTheme.INK_DIM)
		AgentReadout.draw_bars(_bars_view, Vector2(0.0, y + label_size.y + 2.0), bar_width, BAR_HEIGHT, 0.0, [entry])
		y += label_size.y + 2.0 + BAR_HEIGHT + BAR_SPACING
