extends RefCounted
## Valiborn interface palette. Physical road signals keep their real aspect colours.
const BG := Color("111111")
const PANEL := Color(0.075,0.075,0.075,0.96)
const BORDER := Color("373737")
const TEXT := Color("eeeeee")
const MUTED := Color("a4a4a4")
const ORANGE := Color("f59a50")

static func make_theme() -> Theme:
	var result := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Avenir Next", "Inter", "DejaVu Sans"])
	font.font_weight = 500
	result.default_font = font
	result.default_font_size = 13
	return result

static func surface(fill: Color = PANEL, border: Color = BORDER, padding: int = 12) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style

static func label(copy: String, font_size: int = 13, color: Color = TEXT) -> Label:
	var item := Label.new()
	item.text = copy
	item.add_theme_font_size_override("font_size", font_size)
	item.add_theme_color_override("font_color", color)
	return item

static func button(copy: String) -> Button:
	var item := Button.new()
	item.text = copy
	item.custom_minimum_size.y = 32
	item.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	item.add_theme_font_size_override("font_size", 12)
	item.add_theme_stylebox_override("normal", surface(Color("202020"), BORDER, 8))
	item.add_theme_stylebox_override("hover", surface(Color("303030"), ORANGE, 8))
	item.add_theme_stylebox_override("pressed", surface(Color("34302b"), ORANGE, 8))
	item.add_theme_stylebox_override("disabled", surface(Color("1a1a1a"), BORDER, 8))
	var focus := surface(Color.TRANSPARENT, ORANGE, 8)
	focus.set_border_width_all(2)
	item.add_theme_stylebox_override("focus", focus)
	for key in ["font_color","font_hover_color","font_pressed_color","font_focus_color"]:
		item.add_theme_color_override(key, TEXT)
	item.add_theme_color_override("font_disabled_color", MUTED)
	return item
