class_name StartMenu
extends CenterContainer

## Setup screen shown before a simulation starts.
##
## The rows are built at runtime from `ConfigLoader.list_option_groups()` rather
## than laid out in the scene, because the groups live in `presets.json` and are
## meant to be edited there. Adding a "Season" group to that file should put a
## new row on this screen without touching a scene or this script.
##
## Widgets are limited to `Button`, `OptionButton` and `Label` on purpose: those
## are what `PixelUiTheme` styles. An `HSlider` here would render as raw grey.

signal start_requested(selection: Dictionary)
signal continue_requested()

const TITLE_TEXT := "Новая симуляция"

var _selection: Dictionary = {}
var _continue_button: Button = null
var _seed_option: OptionButton = null

# Offered as a choice rather than a text field: no themed line edit exists, and
# a fixed set keeps runs comparable between sessions.
const SEED_CHOICES := [3, 7, 11, 42, 101, 777, 2024]


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()


func _build() -> void:
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(420, 0)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	var title := Label.new()
	title.text = TITLE_TEXT
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

	_continue_button = Button.new()
	_continue_button.text = "Продолжить"
	_continue_button.pressed.connect(func(): continue_requested.emit())
	_continue_button.visible = false
	column.add_child(_continue_button)


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
