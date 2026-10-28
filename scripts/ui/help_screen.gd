class_name HelpScreen
extends CenterContainer

## Reference screen for controls, interface and mechanics, shown over the
## blurred world from the setup screen, the pause menu or F1.
##
## The sections come from `ConfigLoader.list_help_sections()` rather than living
## in this script, for the same reason the setup screen reads `presets.json`:
## the copy is content, and adding a section to that file should put a new
## button on this screen without touching code or a scene.
##
## The section switcher is a row of `Button`s rather than a `TabContainer`
## because `PixelUiTheme` only styles Button, OptionButton, Label, PanelContainer
## and PopupMenu - a tab bar here would render as raw Godot grey.

signal closed

const TITLE_TEXT := "Помощь"
const BACK_TEXT := "Назад"
const EMPTY_TEXT := "Файл справки не найден: data/config/help.json"

## Sized against the 1600x900 design canvas: wide enough that the prose does not
## wrap mid-clause at the menu type scale, and short enough that the panel plus
## its title, tab row and back button still clear the bottom of the screen.
const PANEL_WIDTH := 1040.0
const BODY_HEIGHT := 560.0
## A screen narrower than the panel (the reserve upright): the panel takes the screen's width less
## this each side, its section buttons in `NARROW_COLUMNS` columns.
const NARROW_MARGIN := 8.0
const NARROW_COLUMNS := 2

var _sections: Array = []
var _panel: PanelContainer = null
var _tab_row: HBoxContainer = null
var _tab_grid: GridContainer = null
var _buttons: Array[Button] = []
var _scroll: ScrollContainer = null
var _body: RichTextLabel = null
var _back_button: Button = null
var _active_index: int = -1


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	show_section(0)
	get_viewport().size_changed.connect(_fit_to_view)
	_fit_to_view()


## The panel to the screen's width when the screen is narrower than it, the section buttons
## then in a grid rather than one row; as designed otherwise.
func _fit_to_view() -> void:
	if _panel == null:
		return
	var view_width := get_viewport_rect().size.x
	var narrow := view_width < PANEL_WIDTH + 2.0 * NARROW_MARGIN
	_panel.custom_minimum_size.x = view_width - 2.0 * NARROW_MARGIN if narrow else PANEL_WIDTH
	var holder: Container = _tab_grid if narrow else _tab_row
	for button in _buttons:
		if button.get_parent() != holder:
			button.reparent(holder, false)
	_tab_grid.visible = narrow
	_tab_row.visible = not narrow


func _build() -> void:
	_sections = ConfigLoader.list_help_sections()

	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	add_child(panel)
	_panel = panel

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 20)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 12)
	margin.add_child(column)

	var title := Label.new()
	title.text = TITLE_TEXT
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	column.add_child(title)

	_tab_row = HBoxContainer.new()
	_tab_row.add_theme_constant_override("separation", 8)
	column.add_child(_tab_row)
	_tab_grid = GridContainer.new()
	_tab_grid.columns = NARROW_COLUMNS
	_tab_grid.add_theme_constant_override("h_separation", 8)
	_tab_grid.add_theme_constant_override("v_separation", 8)
	_tab_grid.visible = false
	column.add_child(_tab_grid)
	for index in range(_sections.size()):
		var button := Button.new()
		button.text = str(_sections[index]["label"])
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(show_section.bind(index))
		_tab_row.add_child(button)
		_buttons.append(button)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0, BODY_HEIGHT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(_scroll)

	_body = RichTextLabel.new()
	_body.bbcode_enabled = true
	# The outer ScrollContainer is the only scrolling region: a live inner
	# scrollbar would swallow the wheel and leave the section half-readable.
	_body.fit_content = true
	_body.scroll_active = false
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_body)

	_back_button = Button.new()
	_back_button.text = BACK_TEXT
	_back_button.pressed.connect(func(): closed.emit())
	column.add_child(_back_button)


## The active section's button is disabled rather than highlighted: the art pack
## has no "selected" button state, and the theme already gives disabled its own
## ink, so the current section reads as current without inventing a style.
func show_section(index: int) -> void:
	if _body == null:
		return
	if _sections.is_empty():
		_body.text = EMPTY_TEXT
		return
	_active_index = clampi(index, 0, _sections.size() - 1)
	_body.text = str(_sections[_active_index]["body"])
	if _scroll != null:
		_scroll.scroll_vertical = 0
	for button_index in range(_buttons.size()):
		_buttons[button_index].disabled = button_index == _active_index


## Called by the controller each time the screen is opened, so it always comes
## up on the first section rather than wherever it was left.
func reset() -> void:
	show_section(0)
	if _back_button != null:
		_back_button.grab_focus()
