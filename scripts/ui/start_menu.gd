class_name StartMenu
extends CenterContainer

## The screen shown before a simulation runs, in two pages.
##
## The first page is the main menu - scenarios, new run, continue, help, exit. The setup
## options only appear once "Новая симуляция" is pressed, because a wall of six
## dropdowns is the wrong thing to greet someone with: most sessions want the
## defaults or the last autosave, and neither needs the options at all. «Сценарии» lists the
## worlds with a goal (`ConfigLoader.list_scenarios()`), a card each with its brief and «Играть»,
## up to three abreast where the window is wide enough, and scrolling where it is too short; the
## first game's card says «Начните отсюда», a won one «Пройден» (`ScenarioProgress`). «Новая
## симуляция» is the sandbox.
##
## The setup rows are built at runtime from `ConfigLoader.list_option_groups()`
## rather than laid out in the scene, because the groups live in `presets.json`
## and are meant to be edited there. Adding a "Season" group to that file should
## put a new row on this screen without touching a scene or this script.
##
## Widgets are limited to `Button`, `OptionButton` and `Label` on purpose: those
## are what `PixelUiTheme` styles. An `HSlider` here would render as raw grey.

signal start_requested(selection: Dictionary)
## A scenario to play, in the style the setup page has chosen (the scenario decides the rest).
signal scenario_requested(scenario_id: String, style: String)
signal continue_requested()
signal help_requested()
signal settings_requested()
signal exit_requested()

const TITLE_TEXT := "Engine of Ecosystem"
const SETUP_TITLE_TEXT := "Новая симуляция"
const SCENARIOS_TITLE_TEXT := "Сценарии"
const PAGE_WIDTH := 420.0
## A scenario's card on the scenarios page, the gap between cards, and its brief's type: smaller
## than the menu's, which set a brief of a few sentences one word a line.
const SCENARIO_CARD_WIDTH := 380.0
const SCENARIO_GAP := 18.0
const BRIEF_FONT_SIZE := 18
## Kept clear above and below a page that would otherwise run off the window.
const SCREEN_MARGIN := 24.0
const MARK_TUTORIAL := Color(0.62, 0.38, 0.06)
const MARK_WON := Color(0.16, 0.48, 0.2)
const ScenarioProgress := preload("res://scripts/core/scenario_progress.gd")

var _selection: Dictionary = {}
var _continue_button: Button = null
var _seed_option: OptionButton = null
var _root_page: PanelContainer = null
var _setup_page: PanelContainer = null
var _scenarios_page: PanelContainer = null
var _scenario_scroll: ScrollContainer = null
var _scenario_grid: GridContainer = null

# Offered as a choice rather than a text field: no themed line edit exists, and
# a fixed set keeps runs comparable between sessions.
const SEED_CHOICES := [3, 7, 11, 42, 101, 777, 2024]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_root_page = _build_root_page()
	_setup_page = _build_setup_page()
	_scenarios_page = _build_scenarios_page()
	show_root()
	if is_inside_tree():
		get_viewport().size_changed.connect(func() -> void:
			if _scenarios_page.visible:
				_fit_scenarios())


## Both pages live under the same CenterContainer and take turns being visible,
## so each is centred on its own size rather than padded out to match the other.
func show_root() -> void:
	if _root_page == null:
		return
	_root_page.visible = true
	_setup_page.visible = false
	_scenarios_page.visible = false


func _show_setup() -> void:
	_root_page.visible = false
	_setup_page.visible = true


func show_scenarios() -> void:
	_root_page.visible = false
	_scenarios_page.visible = true
	_fill_scenarios()
	_fit_scenarios()


## A card a scenario, built again each time the page opens: a scenario won since is marked.
func _fill_scenarios() -> void:
	for card in _scenario_grid.get_children():
		_scenario_grid.remove_child(card)
		card.queue_free()
	for scenario in ConfigLoader.list_scenarios():
		_scenario_grid.add_child(_scenario_card(scenario))


## Two cards abreast where the window has the width, one where not; the cards scroll where the
## window is shorter than they are. Measured a frame after laying them out: a wrapped brief
## knows its height only once it has its width.
func _fit_scenarios() -> void:
	if _scenario_grid == null or not is_inside_tree():
		return
	var view: Vector2 = get_viewport_rect().size
	var fit := int((view.x - 44.0 - SCREEN_MARGIN * 2.0 + SCENARIO_GAP) / (SCENARIO_CARD_WIDTH + SCENARIO_GAP))
	_scenario_grid.columns = clampi(mini(fit, 3), 1, maxi(1, _scenario_grid.get_child_count()))
	await get_tree().process_frame
	if not is_inside_tree() or not _scenarios_page.visible:
		return
	var content: Vector2 = _scenario_grid.get_combined_minimum_size()
	var rest: float = _scenarios_page.get_combined_minimum_size().y - _scenario_scroll.custom_minimum_size.y
	var room := maxf(120.0, view.y - SCREEN_MARGIN * 2.0 - rest)
	_scenario_scroll.custom_minimum_size = Vector2(content.x, minf(content.y, room))


func _build_root_page() -> PanelContainer:
	var page := _new_page()
	var column := _page_body(page)

	var title := Label.new()
	title.text = TITLE_TEXT
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	var scenarios_button := Button.new()
	scenarios_button.text = SCENARIOS_TITLE_TEXT
	scenarios_button.tooltip_text = "Мир с целью: сохранить стадо, пока вокруг беда"
	scenarios_button.pressed.connect(show_scenarios)
	column.add_child(scenarios_button)

	var new_button := Button.new()
	new_button.text = SETUP_TITLE_TEXT
	new_button.tooltip_text = "Песочница: свой мир без целей, силы только с перезарядкой"
	new_button.pressed.connect(_show_setup)
	column.add_child(new_button)

	_continue_button = Button.new()
	_continue_button.text = "Продолжить"
	_continue_button.pressed.connect(func(): continue_requested.emit())
	_continue_button.visible = false
	column.add_child(_continue_button)

	var help_button := Button.new()
	help_button.text = "Помощь"
	help_button.pressed.connect(func(): help_requested.emit())
	column.add_child(help_button)

	var settings_button := Button.new()
	settings_button.text = "Настройки"
	settings_button.pressed.connect(func(): settings_requested.emit())
	column.add_child(settings_button)

	var exit_button := Button.new()
	exit_button.text = "Выход"
	exit_button.pressed.connect(func(): exit_requested.emit())
	column.add_child(exit_button)

	return page


func _build_setup_page() -> PanelContainer:
	var page := _new_page()
	var column := _page_body(page)

	var title := Label.new()
	title.text = SETUP_TITLE_TEXT
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	column.add_child(grid)

	for group in ConfigLoader.list_option_groups():
		_add_group_row(grid, group)
	_add_seed_row(grid)

	var start_button := Button.new()
	start_button.text = "Начать"
	start_button.pressed.connect(_on_start_pressed)
	column.add_child(start_button)

	var back_button := Button.new()
	back_button.text = "Назад"
	back_button.pressed.connect(show_root)
	column.add_child(back_button)

	return page


func _build_scenarios_page() -> PanelContainer:
	var page := _new_page()
	var column := _page_body(page)

	var title := Label.new()
	title.text = SCENARIOS_TITLE_TEXT
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	_scenario_scroll = ScrollContainer.new()
	_scenario_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(_scenario_scroll)
	_scenario_grid = GridContainer.new()
	_scenario_grid.columns = 2
	_scenario_grid.add_theme_constant_override("h_separation", int(SCENARIO_GAP))
	_scenario_grid.add_theme_constant_override("v_separation", int(SCENARIO_GAP))
	_scenario_scroll.add_child(_scenario_grid)
	_fill_scenarios()

	var back_button := Button.new()
	back_button.text = "Назад"
	back_button.pressed.connect(show_root)
	column.add_child(back_button)

	return page


## A scenario's card: its name, its brief and «Играть», the button at the foot so cards abreast
## line theirs up.
func _scenario_card(scenario: Dictionary) -> VBoxContainer:
	var card := VBoxContainer.new()
	card.custom_minimum_size.x = SCENARIO_CARD_WIDTH
	card.add_theme_constant_override("separation", 8)
	var heading := HBoxContainer.new()
	heading.add_theme_constant_override("separation", 10)
	card.add_child(heading)
	var name_label := Label.new()
	name_label.text = str(scenario["label"])
	heading.add_child(name_label)
	var mark := scenario_mark(scenario)
	if mark != "":
		var mark_label := Label.new()
		mark_label.text = mark
		mark_label.add_theme_font_size_override("font_size", BRIEF_FONT_SIZE)
		mark_label.add_theme_color_override("font_color", MARK_WON if mark == "Пройден" else MARK_TUTORIAL)
		mark_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		heading.add_child(mark_label)
	var brief := Label.new()
	brief.text = str(scenario["brief"])
	brief.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	brief.custom_minimum_size.x = SCENARIO_CARD_WIDTH
	brief.size_flags_vertical = Control.SIZE_EXPAND_FILL
	brief.add_theme_font_size_override("font_size", BRIEF_FONT_SIZE)
	card.add_child(brief)
	var play := Button.new()
	play.text = "Играть"
	var scenario_id := str(scenario["id"])
	play.pressed.connect(func(): scenario_requested.emit(scenario_id, chosen_style()))
	card.add_child(play)
	return card


## «Пройден» on a won scenario, «Начните отсюда» on the first game not yet won, "" otherwise.
static func scenario_mark(scenario: Dictionary) -> String:
	if ScenarioProgress.has_won(str(scenario.get("id", ""))):
		return "Пройден"
	return "Начните отсюда" if bool(scenario.get("tutorial", false)) else ""


## The style the setup page has chosen, the default until it is changed.
func chosen_style() -> String:
	return str(_selection.get("style", ConfigLoader.default_selection().get("style", "")))


func _new_page() -> PanelContainer:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PAGE_WIDTH, 0)
	add_child(panel)
	return panel


## Pads a page and returns the column its rows go into.
func _page_body(page: PanelContainer) -> VBoxContainer:
	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	page.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)
	return column


func _add_group_row(grid: GridContainer, group: Dictionary) -> void:
	var group_id := str(group["id"])
	var label := Label.new()
	label.text = str(group["label"])
	grid.add_child(label)

	var chooser := OptionButton.new()
	chooser.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var options: Array = group["options"]
	var selected_index := 0
	for index in range(options.size()):
		var option: Dictionary = options[index]
		chooser.add_item(str(option["label"]), index)
		chooser.set_item_metadata(index, str(option["id"]))
		if str(option["id"]) == str(group["default"]):
			selected_index = index
	chooser.select(selected_index)
	_selection[group_id] = str(options[selected_index]["id"])
	chooser.item_selected.connect(func(index: int):
		_selection[group_id] = str(chooser.get_item_metadata(index)))
	grid.add_child(chooser)


func _add_seed_row(grid: GridContainer) -> void:
	var label := Label.new()
	label.text = "Зерно"
	grid.add_child(label)

	_seed_option = OptionButton.new()
	_seed_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for index in range(SEED_CHOICES.size()):
		_seed_option.add_item(str(SEED_CHOICES[index]), index)
	_seed_option.select(0)
	grid.add_child(_seed_option)


## Reveals the Continue button. Called by the controller once it knows a save
## exists, so the menu itself never has to touch the filesystem.
func set_continue_available(available: bool) -> void:
	if _continue_button != null:
		_continue_button.visible = available


func selected_seed() -> int:
	if _seed_option == null:
		return int(SEED_CHOICES[0])
	return int(SEED_CHOICES[clampi(_seed_option.selected, 0, SEED_CHOICES.size() - 1)])


func _on_start_pressed() -> void:
	start_requested.emit(_selection.duplicate())
