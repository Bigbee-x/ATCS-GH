extends Control
## Corridor entry point. Presentation never supplies traffic observations or actions.
const SCENE_CORRIDOR := "res://scenes/CorridorMain.tscn"
const CORRIDOR_SERVER: int = 2  # Stable ServerManager enum; legacy files remain readable.
const BG := Color("111111")
const PANEL := Color("191919")
const BORDER := Color("373737")
const INK := Color("eeeeee")
const MUTED := Color("a4a4a4")
const ACCENT := Color("f59a50")
const AMBER := Color("f59a50")
const RED := Color("f59a50")

var _columns: GridContainer
var _shortcuts: GridContainer
var _hero: Label
var _status_label: Label
var _status_detail: Label
var _status_dot: ColorRect
var _launch_btn: Button
var _dashboard: CheckBox
var _stop_btn: Button
var _log_toggle_btn: Button
var _log_panel: PanelContainer
var _log_text: RichTextLabel
var _launching := false
var _error := ""

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	get_window().title = "TrafIQ | Corridor Intelligence"
	var ui_theme := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Avenir Next", "Inter", "DejaVu Sans"])
	font.font_weight = 500
	ui_theme.default_font = font
	ui_theme.default_font_size = 14
	theme = ui_theme
	var bg := ColorRect.new()
	bg.color = BG
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	add_child(bg)
	var scroll := ScrollContainer.new()
	scroll.name = "PageScroll"
	scroll.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	scroll.add_child(margin)
	var page := _stack(24)
	page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(page)
	_build_header(page)
	_columns = GridContainer.new()
	_columns.columns = 2
	_columns.add_theme_constant_override("h_separation", 40)
	_columns.add_theme_constant_override("v_separation", 24)
	page.add_child(_columns)
	_build_launch_panel()
	_build_map()
	_build_status(page)
	_build_shortcuts(page)
	_build_logs(page)
	var footer := _row(8)
	page.add_child(footer)
	footer.add_child(_label("VALIBORN TECHNOLOGIES", 11, MUTED))
	_space(footer)
	footer.add_child(_label("Traffic intelligence, in motion.", 12, MUTED))
	resized.connect(_responsive)
	_responsive()
	_connect_server_manager()
	_launch_btn.grab_focus()

func _build_header(parent: Control) -> void:
	var row := _row(16)
	parent.add_child(row)
	row.add_child(_label("TrafIQ", 30, ACCENT))
	_space(row)
	var badge := PanelContainer.new()
	badge.add_theme_stylebox_override("panel", _surface(BG, BORDER, 8, 10))
	badge.add_child(_label("N6  /  ACCRA", 12, MUTED))
	row.add_child(badge)

func _build_launch_panel() -> void:
	var left := _stack(14)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.size_flags_stretch_ratio = 0.86
	_columns.add_child(left)
	left.add_child(_label("CORRIDOR SIMULATION", 12, ACCENT))
	_hero = _label("Three junctions.\nOne corridor.", 46)
	left.add_child(_hero)
	var intro := _label("Explore Nsawam Road with adaptive signals, live traffic and pedestrian crossings.", 16, MUTED)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(intro)
	var scope := _label("J0  Achimota   /   J1  Asylum Down   /   J2  Nima", 12, INK)
	scope.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	left.add_child(scope)
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 6
	left.add_child(spacer)
	_launch_btn = _button("Launch corridor  →", true)
	_launch_btn.name = "LaunchCorridor"
	_launch_btn.custom_minimum_size.y = 52
	_launch_btn.pressed.connect(_launch_corridor)
	left.add_child(_launch_btn)
	_dashboard = CheckBox.new()
	_dashboard.name = "OpenDashboard"
	_dashboard.text = "Open live dashboard in browser"
	_dashboard.button_pressed = true
	_dashboard.add_theme_color_override("font_color", MUTED)
	_dashboard.add_theme_color_override("font_hover_color", INK)
	_dashboard.add_theme_stylebox_override("focus", _surface(Color.TRANSPARENT, ACCENT, 5, 3))
	left.add_child(_dashboard)

func _build_map() -> void:
	var panel := PanelContainer.new()
	panel.name = "CorridorMap"
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", _surface(PANEL, BORDER, 18, 22))
	_columns.add_child(panel)
	var box := _stack(8)
	panel.add_child(box)
	var top := _row(8)
	box.add_child(top)
	top.add_child(_label("NSAWAM ROAD", 12, INK))
	_space(top)
	top.add_child(_label("ROUTE SCHEMATIC", 10, MUTED))
	var diagram := preload("res://scripts/CorridorOverview.gd").new()
	diagram.name = "RouteDiagram"
	diagram.custom_minimum_size.y = 255
	diagram.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(diagram)
	var bottom := _row(12)
	box.add_child(bottom)
	bottom.add_child(_label("03  JUNCTIONS", 11, ACCENT))
	_space(bottom)
	bottom.add_child(_label("300 m between junctions", 11, MUTED))

func _build_status(parent: Control) -> void:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _surface(PANEL, BORDER, 12, 16))
	parent.add_child(panel)
	var row := _row(14)
	panel.add_child(row)
	_status_dot = ColorRect.new()
	_status_dot.custom_minimum_size = Vector2(7, 7)
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(_status_dot)
	var copy := _stack(2)
	copy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(copy)
	_status_label = _label("Ready to launch", 14)
	copy.add_child(_status_label)
	_status_detail = _label("Live traffic starts when you launch the corridor.", 12, MUTED)
	_status_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	copy.add_child(_status_detail)
	_stop_btn = _button("Stop session")
	_stop_btn.pressed.connect(_on_stop_pressed)
	row.add_child(_stop_btn)
	_log_toggle_btn = _button("View log")
	_log_toggle_btn.pressed.connect(_on_log_toggle)
	row.add_child(_log_toggle_btn)

func _build_shortcuts(parent: Control) -> void:
	_shortcuts = GridContainer.new()
	_shortcuts.columns = 3
	_shortcuts.add_theme_constant_override("h_separation", 24)
	_shortcuts.add_theme_constant_override("v_separation", 16)
	parent.add_child(_shortcuts)
	for item in [["01 / NAVIGATE", "1 · 2 · 3  Junctions    /    0  Overview"],
		["02 / EXPLORE", "H  Drone    /    K  Sensor coverage"],
		["03 / RETURN", "Esc  Exit drone, then return here"]]:
		var box := _stack(6)
		box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_shortcuts.add_child(box)
		box.add_child(_label(item[0], 10, MUTED))
		var info := _label(item[1], 12, INK)
		info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(info)

func _build_logs(parent: Control) -> void:
	_log_panel = PanelContainer.new()
	_log_panel.visible = false
	_log_panel.add_theme_stylebox_override("panel", _surface(Color("101010"), BORDER, 12, 14))
	parent.add_child(_log_panel)
	var box := _stack(8)
	_log_panel.add_child(box)
	box.add_child(_label("SESSION LOG", 11, MUTED))
	_log_text = RichTextLabel.new()
	_log_text.bbcode_enabled = false
	_log_text.scroll_following = true
	_log_text.selection_enabled = true
	_log_text.custom_minimum_size.y = 140
	_log_text.add_theme_font_size_override("normal_font_size", 12)
	_log_text.add_theme_color_override("default_color", MUTED)
	box.add_child(_log_text)

func _responsive() -> void:
	if not is_instance_valid(_columns): return
	_columns.columns = 1 if size.x < 920 else 2
	_shortcuts.columns = 1 if size.x < 760 else 3
	_hero.add_theme_font_size_override("font_size", 38 if size.x < 1100 else 46)

func _connect_server_manager() -> void:
	var sm := get_node_or_null("/root/ServerManager")
	if sm:
		sm.server_started.connect(_on_server_started)
		sm.server_stopped.connect(_on_server_stopped)
		sm.server_log_updated.connect(_on_server_log_updated)
		sm.server_error.connect(_on_server_error)
	_refresh_status()

func _launch_corridor() -> void:
	if _launching: return
	var sm := get_node_or_null("/root/ServerManager")
	if not sm:
		_on_server_error("Traffic service unavailable. Reopen the project and try again.")
		return
	_error = ""
	_launching = true
	_refresh_status()
	var ready: bool = sm.is_running() and sm.get_server_type() == CORRIDOR_SERVER
	if ready and _dashboard.button_pressed:
		sm.open_dashboard()
	if not ready:
		ready = await sm.start_server(CORRIDOR_SERVER, {"dashboard": _dashboard.button_pressed})
	if not is_inside_tree(): return
	_launching = false
	if not ready:
		if _error.is_empty():
			_on_server_error("Live traffic did not start. Check the session log, then retry.")
		_refresh_status()
		return
	_enter_corridor()

func _enter_corridor() -> void:
	var result := get_tree().change_scene_to_file(SCENE_CORRIDOR)
	if result != OK:
		_on_server_error("The corridor scene could not open. Check the session log.")

func _refresh_status() -> void:
	if not is_inside_tree(): return
	var sm := get_node_or_null("/root/ServerManager")
	var running: bool = sm != null and sm.is_running()
	var corridor: bool = running and sm.get_server_type() == CORRIDOR_SERVER
	_launch_btn.disabled = _launching or sm == null
	_dashboard.disabled = _launching
	_stop_btn.visible = running and not _launching
	_launch_btn.text = "Resume corridor  →" if corridor else "Launch corridor  →"
	if _launching:
		_launch_btn.text = "Starting live traffic…"
		_set_status("Starting corridor", "Waiting for the first traffic data. The scene opens when it is ready.", AMBER)
	elif not _error.is_empty():
		_launch_btn.text = "Retry launch  →"
		_set_status("Unable to launch", _error, RED)
	elif sm == null:
		_set_status("Traffic service unavailable", "Reopen the project to restore the traffic service.", RED)
	elif corridor:
		_set_status("Corridor session running", "Resume the current session, or stop it to begin a new run.", ACCENT)
	elif running:
		_set_status("Previous session running", "Launching will switch this session to the N6 corridor.", AMBER)
	else:
		_set_status("Ready to launch", "Live traffic starts when you launch the corridor.", MUTED)

func _set_status(title: String, detail: String, color: Color) -> void:
	_status_dot.color = color
	_status_label.text = title
	_status_label.add_theme_color_override("font_color", color)
	_status_detail.text = detail

func _on_server_started(_server_type_name: String) -> void:
	_error = ""
	_refresh_status()

func _on_server_stopped() -> void:
	_refresh_status()

func _on_server_error(message: String) -> void:
	_error = message
	_refresh_status()
	if not _log_panel.visible: _on_log_toggle()

func _on_server_log_updated(new_text: String) -> void:
	if _log_panel.visible:
		_log_text.append_text(new_text)

func _on_log_toggle() -> void:
	_log_panel.visible = not _log_panel.visible
	_log_toggle_btn.text = "Hide log" if _log_panel.visible else "View log"
	if _log_panel.visible:
		var sm := get_node_or_null("/root/ServerManager")
		var contents: String = sm.get_log_contents() if sm else ""
		_log_text.text = contents if not contents.is_empty() else "No session log yet. Launch the corridor to begin."

func _on_stop_pressed() -> void:
	_error = ""
	var sm := get_node_or_null("/root/ServerManager")
	if sm: sm.stop_server()
	_refresh_status()

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and _log_panel.visible:
		_on_log_toggle()
		get_viewport().set_input_as_handled()

func _label(copy: String, font_size: int, color: Color = INK) -> Label:
	var label := Label.new()
	label.text = copy
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label

func _stack(gap: int) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", gap)
	return box

func _row(gap: int) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", gap)
	return box

func _space(parent: Control) -> void:
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(spacer)

func _surface(fill: Color, border: Color, radius: int, padding: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style

func _button(copy: String, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = copy
	button.custom_minimum_size.y = 36
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_size_override("font_size", 16 if primary else 12)
	button.add_theme_stylebox_override("normal", _surface(ACCENT if primary else PANEL, ACCENT if primary else BORDER, 8, 12))
	button.add_theme_stylebox_override("hover", _surface(Color("ffb578") if primary else Color("303030"), ACCENT, 8, 12))
	button.add_theme_stylebox_override("pressed", _surface(Color("dc873e") if primary else BORDER, ACCENT, 8, 12))
	button.add_theme_stylebox_override("disabled", _surface(Color("36312b"), BORDER, 8, 12))
	var focus := _surface(Color.TRANSPARENT, ACCENT, 10, 12)
	focus.set_border_width_all(2)
	focus.expand_margin_left = 3
	focus.expand_margin_right = 3
	focus.expand_margin_top = 3
	focus.expand_margin_bottom = 3
	button.add_theme_stylebox_override("focus", focus)
	for state in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, BG if primary else INK)
	button.add_theme_color_override("font_disabled_color", MUTED)
	return button
