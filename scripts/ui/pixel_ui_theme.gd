class_name PixelUiTheme
extends RefCounted

## Builds the HUD theme from the pixel-art UI pack.
##
## The textures are exported at 3x by tools/build_ui_theme.py and used here at
## 1:1. That is deliberate: a StyleBoxTexture draws its 9-patch corners at the
## texture's own resolution, so scaling the Control tree would leave the corners
## at a third the size of everything else, and scaling the CanvasLayer would
## fight the anchored HUD layout. Pre-scaling the source keeps every pixel square
## and the existing layout untouched.
##
## `SOURCE_SCALE` has to match the tool: the 9-patch margins below are given in
## source pixels and multiplied up here, so a mismatch stretches the corners.
##
## The pack's panel is parchment-light while Godot's default text is light grey,
## so the theme has to set the text colours too - otherwise every label in the
## HUD becomes unreadable the moment the panel is applied.

const PANEL_TEXTURE := "res://assets/ui/panel.png"
const BUTTON_TEXTURES := {
	"normal": "res://assets/ui/button_normal.png",
	"hover": "res://assets/ui/button_hover.png",
	"pressed": "res://assets/ui/button_pressed.png",
	"disabled": "res://assets/ui/button_disabled.png",
}

## Must match SCALE in tools/build_ui_theme.py.
const SOURCE_SCALE := 3
## Godot's default is 16, which reads small against art this chunky. The HUD
## asks for something smaller: it is a dense readout of two dozen fields and a
## grid of thirteen toggles, and at menu size that panel runs off the screen.
const MENU_FONT_SIZE := 22
const HUD_FONT_SIZE := 15

const INK := Color(0.20, 0.13, 0.08)
const INK_DIM := Color(0.20, 0.13, 0.08, 0.55)
const BUTTON_INK := Color(0.10, 0.20, 0.13)

## Vital bars. Kept here with the rest of the palette rather than in
## `AgentReadout`, because the same three colours are drawn onto the parchment
## panel and onto the world behind the overhead tag, and they only stay legible
## on both if they are picked together with the ink above.
const BAR_GOOD := Color(0.42, 0.62, 0.28)
const BAR_LOW := Color(0.76, 0.33, 0.18)
const BAR_TRACK := Color(0.20, 0.13, 0.08, 0.24)
## The tag has no panel behind it, so it carries its own backdrop - dark, because
## it sits over grass and water rather than over the parchment.
const TAG_BACKDROP := Color(0.10, 0.09, 0.07, 0.84)
const TAG_INK := Color(0.94, 0.91, 0.84)
const TAG_INK_DIM := Color(0.94, 0.91, 0.84, 0.66)
## Dark enough to read as a grip against the parchment without competing with
## the ink of the text it sits beside.
const SCROLL_GRABBER := Color(0.20, 0.13, 0.08, 0.62)


## `compact` trades the menu's generous padding for the density the HUD needs.
## Both share the same art, so only the type scale and the paddings differ - two
## sets of textures would have to be kept in step by hand.
static func build(compact: bool = false) -> Theme:
	var theme := Theme.new()

	theme.default_font_size = HUD_FONT_SIZE if compact else MENU_FONT_SIZE
	var pad: float = 0.6 if compact else 1.0

	var panel := _stretched(PANEL_TEXTURE, 4, 4, 4, 4)
	if panel == null:
		return theme
	panel.content_margin_left = 18.0 * pad
	panel.content_margin_right = 18.0 * pad
	panel.content_margin_top = 16.0 * pad
	panel.content_margin_bottom = 16.0 * pad
	theme.set_stylebox("panel", "PanelContainer", panel)
	theme.set_stylebox("panel", "Panel", panel)

	for state in BUTTON_TEXTURES.keys():
		var box := _stretched(BUTTON_TEXTURES[state], 5, 5, 4, 4)
		if box == null:
			continue
		box.content_margin_left = 16.0 * pad
		box.content_margin_right = 16.0 * pad
		box.content_margin_top = 7.0 * pad
		box.content_margin_bottom = 7.0 * pad
		theme.set_stylebox(state, "Button", box)
	# OptionButton is a Button subclass but does not inherit its styles, so the
	# speed and follow dropdowns would stay default grey without this.
	for state in BUTTON_TEXTURES.keys():
		var drop := _stretched(BUTTON_TEXTURES[state], 5, 5, 4, 4)
		if drop == null:
			continue
		drop.content_margin_left = 16.0 * pad
		drop.content_margin_right = 16.0 * pad
		drop.content_margin_top = 7.0 * pad
		drop.content_margin_bottom = 7.0 * pad
		theme.set_stylebox(state, "OptionButton", drop)
	theme.set_stylebox("focus", "OptionButton", StyleBoxEmpty.new())
	var popup := _stretched(PANEL_TEXTURE, 4, 4, 4, 4)
	if popup != null:
		popup.content_margin_left = 12.0 * pad
		popup.content_margin_right = 12.0 * pad
		popup.content_margin_top = 9.0 * pad
		popup.content_margin_bottom = 9.0 * pad
		theme.set_stylebox("panel", "PopupMenu", popup)
	theme.set_color("font_color", "PopupMenu", INK)
	theme.set_color("font_hover_color", "PopupMenu", BUTTON_INK)

	# Focus is left flat: the pack has no focus art, and Godot's default focus
	# box is a bright rectangle that clashes with everything here.
	theme.set_stylebox("focus", "Button", StyleBoxEmpty.new())

	for state in ["font_color", "font_hover_color", "font_focus_color"]:
		theme.set_color(state, "Button", BUTTON_INK)
	theme.set_color("font_pressed_color", "Button", BUTTON_INK)
	theme.set_color("font_disabled_color", "Button", Color(0.10, 0.20, 0.13, 0.5))

	theme.set_color("font_color", "Label", INK)
	theme.set_color("font_color", "CheckBox", INK)
	theme.set_color("font_hover_color", "CheckBox", INK)
	theme.set_color("font_pressed_color", "CheckBox", INK)
	theme.set_color("font_disabled_color", "CheckBox", INK_DIM)
	theme.set_color("font_color", "OptionButton", BUTTON_INK)
	theme.set_color("default_color", "RichTextLabel", INK)

	# The pack has no scrollbar art, and both the HUD panel and the help screen
	# scroll. Flat boxes in the palette above read as part of the parchment;
	# Godot's untouched default is a slab of grey that does not.
	# The grabber sets the bar's width, so it is the thicker of the two: at the
	# track's width the whole thing reads as a hairline rather than a control.
	for bar in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", bar, _bar_box(BAR_TRACK, 3.0))
		theme.set_stylebox("scroll_focus", bar, _bar_box(BAR_TRACK, 3.0))
		theme.set_stylebox("grabber", bar, _bar_box(SCROLL_GRABBER, 6.0))
		theme.set_stylebox("grabber_highlight", bar, _bar_box(INK, 6.0))
		theme.set_stylebox("grabber_pressed", bar, _bar_box(INK, 6.0))
	return theme


## `thickness` is a margin on every side, so it sets both the bar's width and
## the grabber's inset from the track.
static func _bar_box(color: Color, thickness: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = color
	box.set_corner_radius_all(3)
	box.content_margin_left = thickness
	box.content_margin_right = thickness
	box.content_margin_top = thickness
	box.content_margin_bottom = thickness
	return box


static func _stretched(path: String, left: int, right: int, top: int, bottom: int) -> StyleBoxTexture:
	var texture: Texture2D = load(path)
	if texture == null:
		push_error("UI theme texture missing: %s" % path)
		return null
	var box := StyleBoxTexture.new()
	box.texture = texture
	# Margins are given in source pixels and scaled to match the exported art.
	box.texture_margin_left = float(left * SOURCE_SCALE)
	box.texture_margin_right = float(right * SOURCE_SCALE)
	box.texture_margin_top = float(top * SOURCE_SCALE)
	box.texture_margin_bottom = float(bottom * SOURCE_SCALE)
	return box
