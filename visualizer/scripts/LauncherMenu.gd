extends Control
## Launcher menu for ATCS-GH — lets the user choose between
## Single Junction and Corridor (3-junction) visualization modes.
##
## Integrated with ServerManager autoload: clicking a card automatically
## starts the matching Python server, shows live status, and provides a
## built-in log viewer so the user never needs a separate terminal.
##
## All UI elements are built programmatically in _ready().
## Press a card to load the corresponding scene; press Escape
## from inside either scene to return here.

# ── Style constants (same palette as UI.gd) ────────────────────────────────
const BG_COLOR       := Color(0.06, 0.06, 0.10, 1.0)
const BG_LIGHTER     := Color(0.10, 0.10, 0.16, 1.0)
const ACCENT_GREEN   := Color(0.2, 0.85, 0.3)
const ACCENT_BLUE    := Color(0.35, 0.55, 1.0)
const ACCENT_YELLOW  := Color(1.0, 0.9, 0.25)
const ACCENT_RED     := Color(0.9, 0.2, 0.2)
const TEXT_COLOR      := Color(0.9, 0.9, 0.95)
const TEXT_DIM        := Color(0.55, 0.55, 0.60)
const CARD_BG        := Color(0.10, 0.12, 0.18, 0.95)
const CARD_HOVER_BG  := Color(0.14, 0.17, 0.25, 0.98)
const CARD_BORDER    := Color(0.25, 0.30, 0.45, 0.6)

# ── Scene paths ─────────────────────────────────────────────────────────────
const SCENE_SINGLE   := "res://scenes/Main.tscn"
const SCENE_CORRIDOR := "res://scenes/CorridorMain.tscn"

# ── Server control UI references ────────────────────────────────────────────
var _status_dot: ColorRect
var _status_label: Label
var _log_panel: PanelContainer
var _log_text: RichTextLabel
var _log_toggle_btn: Button
var _stop_btn: Button
var _launching: bool = false


func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)

	# ── Full-screen dark background ─────────────────────────────────────
	var bg := ColorRect.new()
	bg.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	bg.color = BG_COLOR
	add_child(bg)

	# ── Center everything in a VBoxContainer ─────────────────────────────
	var root := VBoxContainer.new()
	root.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 0)
	add_child(root)

	# ── Top spacer (pushes content towards center) ───────────────────────
	var top_spacer := Control.new()
	top_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(top_spacer)

	# ── Title block ──────────────────────────────────────────────────────
	var title_box := VBoxContainer.new()
	title_box.add_theme_constant_override("separation", 4)
	title_box.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_child(title_box)

	var lbl_title := _make_label("ATCS-GH", 42)
	lbl_title.add_theme_color_override("font_color", ACCENT_GREEN)
	lbl_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_box.add_child(lbl_title)

	var lbl_subtitle := _make_label("Adaptive Traffic Control System — Ghana", 16)
	lbl_subtitle.add_theme_color_override("font_color", TEXT_COLOR)
	lbl_subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_box.add_child(lbl_subtitle)

	var lbl_company := _make_label("Valiborn Technologies", 12)
	lbl_company.add_theme_color_override("font_color", TEXT_DIM)
	lbl_company.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_box.add_child(lbl_company)

	# ── Spacer between title and status ──────────────────────────────────
	var mid_spacer := Control.new()
	mid_spacer.custom_minimum_size = Vector2(0, 28)
	root.add_child(mid_spacer)

	# ── Server status bar ────────────────────────────────────────────────
	var status_bar := _build_status_bar()
	root.add_child(status_bar)

	var status_spacer := Control.new()
	status_spacer.custom_minimum_size = Vector2(0, 20)
	root.add_child(status_spacer)

	# ── "Select Simulation Mode" header ──────────────────────────────────
	var lbl_select := _make_label("Select Simulation Mode", 14)
	lbl_select.add_theme_color_override("font_color", TEXT_DIM)
	lbl_select.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(lbl_select)

	var select_spacer := Control.new()
	select_spacer.custom_minimum_size = Vector2(0, 20)
	root.add_child(select_spacer)

	# ── Card row (HBoxContainer centered) ────────────────────────────────
	var card_row := HBoxContainer.new()
	card_row.alignment = BoxContainer.ALIGNMENT_CENTER
	card_row.add_theme_constant_override("separation", 32)
	card_row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	root.add_child(card_row)

	# ── Single Junction card ─────────────────────────────────────────────
	var card_single := _build_card(
		"Single Junction",
		"Achimota / Neoplan Junction",
		"1 intersection  •  4 approaches  •  7 phases",
		ACCENT_GREEN,
		SCENE_SINGLE
	)
	card_row.add_child(card_single)

	# ── Corridor card ────────────────────────────────────────────────────
	var card_corridor := _build_card(
		"N6 Corridor",
		"Nsawam Road — 3 Junctions",
		"Achimota → Asylum Down → Nima  •  Coordinated AI",
		ACCENT_BLUE,
		SCENE_CORRIDOR
	)
	card_row.add_child(card_corridor)

	# ── Log viewer panel (below cards, initially hidden) ─────────────────
	var log_spacer := Control.new()
	log_spacer.custom_minimum_size = Vector2(0, 16)
	root.add_child(log_spacer)

	_build_log_panel()
	root.add_child(_log_panel)

	# ── Spacer before footer ─────────────────────────────────────────────
	var footer_spacer := Control.new()
	footer_spacer.custom_minimum_size = Vector2(0, 20)
	root.add_child(footer_spacer)

	# ── Footer hint ──────────────────────────────────────────────────────
	var lbl_hint := _make_label("Server auto-starts when you select a mode  •  Press Escape to return here", 11)
	lbl_hint.add_theme_color_override("font_color", TEXT_DIM)
	lbl_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	root.add_child(lbl_hint)

	# ── Bottom spacer ───────────────────────────────────────────────────
	var bottom_spacer := Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(bottom_spacer)

	# ── Connect to ServerManager autoload ────────────────────────────────
	_connect_server_manager()


# ═════════════════════════════════════════════════════════════════════════════
# SERVER STATUS BAR
# ═════════════════════════════════════════════════════════════════════════════

func _build_status_bar() -> HBoxContainer:
	## Build the server status indicator row.
	var hbox := HBoxContainer.new()
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 8)

	# Status dot
	_status_dot = ColorRect.new()
	_status_dot.custom_minimum_size = Vector2(10, 10)
	_status_dot.color = ACCENT_RED
	_status_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	hbox.add_child(_status_dot)

	# Status label
	_status_label = _make_label("Server: Not Running", 12)
	_status_label.add_theme_color_override("font_color", TEXT_DIM)
	hbox.add_child(_status_label)

	# Spacer
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(24, 0)
	hbox.add_child(spacer)

	# Stop server button
	_stop_btn = Button.new()
	_stop_btn.text = "Stop Server"
	_stop_btn.custom_minimum_size = Vector2(95, 28)
	_stop_btn.add_theme_font_size_override("font_size", 11)
	_stop_btn.add_theme_color_override("font_color", ACCENT_RED)
	_stop_btn.add_theme_color_override("font_hover_color", Color(1.0, 0.4, 0.4))
	_stop_btn.flat = true
	_stop_btn.visible = false
	_stop_btn.pressed.connect(_on_stop_pressed)
	hbox.add_child(_stop_btn)

	# Show/Hide Log toggle
	_log_toggle_btn = Button.new()
	_log_toggle_btn.text = "Show Log"
	_log_toggle_btn.custom_minimum_size = Vector2(85, 28)
	_log_toggle_btn.add_theme_font_size_override("font_size", 11)
	_log_toggle_btn.add_theme_color_override("font_color", TEXT_DIM)
	_log_toggle_btn.add_theme_color_override("font_hover_color", TEXT_COLOR)
	_log_toggle_btn.flat = true
	_log_toggle_btn.pressed.connect(_on_log_toggle)
	hbox.add_child(_log_toggle_btn)

	return hbox


# ═════════════════════════════════════════════════════════════════════════════
# LOG VIEWER PANEL
# ═════════════════════════════════════════════════════════════════════════════

func _build_log_panel() -> void:
	## Build the collapsible server log viewer.
	_log_panel = PanelContainer.new()
	_log_panel.custom_minimum_size = Vector2(700, 180)
	_log_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_log_panel.visible = false

	# Dark terminal-style background
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.04, 0.07, 0.95)
	style.border_color = Color(0.2, 0.25, 0.35, 0.6)
	style.border_width_left = 1
	style.border_width_right = 1
	style.border_width_top = 1
	style.border_width_bottom = 1
	style.corner_radius_top_left = 8
	style.corner_radius_top_right = 8
	style.corner_radius_bottom_left = 8
	style.corner_radius_bottom_right = 8
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	_log_panel.add_theme_stylebox_override("panel", style)

	_log_text = RichTextLabel.new()
	_log_text.bbcode_enabled = false
	_log_text.scroll_following = true
	_log_text.selection_enabled = true
	_log_text.fit_content = false
	_log_text.custom_minimum_size = Vector2(680, 160)
	_log_text.add_theme_font_size_override("normal_font_size", 11)
	_log_text.add_theme_color_override("default_color", Color(0.65, 0.8, 0.65))
	_log_panel.add_child(_log_text)


# ═════════════════════════════════════════════════════════════════════════════
# CARD BUILDER
# ═════════════════════════════════════════════════════════════════════════════

func _build_card(title: String, location: String, details: String,
		accent: Color, scene_path: String) -> PanelContainer:
	## Build a clickable mode-selection card.
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(320, 180)

	# Normal style
	var style := StyleBoxFlat.new()
	style.bg_color = CARD_BG
	style.border_color = CARD_BORDER
	style.border_width_left = 2
	style.border_width_right = 2
	style.border_width_top = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left = 12
	style.corner_radius_top_right = 12
	style.corner_radius_bottom_left = 12
	style.corner_radius_bottom_right = 12
	style.content_margin_left = 24
	style.content_margin_right = 24
	style.content_margin_top = 20
	style.content_margin_bottom = 20
	panel.add_theme_stylebox_override("panel", style)

	# Card content
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	# Accent bar (thin colored line at top of card content)
	var accent_bar := ColorRect.new()
	accent_bar.custom_minimum_size = Vector2(0, 3)
	accent_bar.color = accent
	vbox.add_child(accent_bar)

	var spacer_top := Control.new()
	spacer_top.custom_minimum_size = Vector2(0, 4)
	vbox.add_child(spacer_top)

	# Title
	var lbl_title := _make_label(title, 22)
	lbl_title.add_theme_color_override("font_color", accent)
	vbox.add_child(lbl_title)

	# Location
	var lbl_location := _make_label(location, 14)
	lbl_location.add_theme_color_override("font_color", TEXT_COLOR)
	vbox.add_child(lbl_location)

	# Spacer
	var spacer_mid := Control.new()
	spacer_mid.custom_minimum_size = Vector2(0, 4)
	vbox.add_child(spacer_mid)

	# Details
	var lbl_details := _make_label(details, 11)
	lbl_details.add_theme_color_override("font_color", TEXT_DIM)
	lbl_details.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(lbl_details)

	# Bottom spacer (pushes content up, gives room)
	var spacer_bottom := Control.new()
	spacer_bottom.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer_bottom)

	# "Launch" label at bottom
	var lbl_launch := _make_label("Click to launch →", 12)
	lbl_launch.add_theme_color_override("font_color", Color(accent, 0.6))
	vbox.add_child(lbl_launch)

	# ── Make the whole card clickable via a transparent Button overlay ───
	var btn := Button.new()
	btn.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	btn.flat = true
	btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	# Hover style — highlight border
	var hover_style := style.duplicate()
	hover_style.bg_color = CARD_HOVER_BG
	hover_style.border_color = Color(accent, 0.7)
	hover_style.border_width_left = 2
	hover_style.border_width_right = 2
	hover_style.border_width_top = 2
	hover_style.border_width_bottom = 2
	btn.mouse_entered.connect(func():
		panel.add_theme_stylebox_override("panel", hover_style)
	)
	btn.mouse_exited.connect(func():
		panel.add_theme_stylebox_override("panel", style)
	)

	# Card click → launch mode with server auto-start
	btn.pressed.connect(func():
		_launch_mode(scene_path)
	)
	panel.add_child(btn)

	return panel


# ═════════════════════════════════════════════════════════════════════════════
# SERVER CONTROL LOGIC
# ═════════════════════════════════════════════════════════════════════════════

func _connect_server_manager() -> void:
	## Connect to the ServerManager autoload signals and refresh UI.
	var sm = get_node_or_null("/root/ServerManager")
	if not sm:
		push_warning("[Launcher] ServerManager autoload not found — server control disabled")
		return

	sm.server_started.connect(_on_server_started)
	sm.server_stopped.connect(_on_server_stopped)
	sm.server_log_updated.connect(_on_server_log_updated)
	sm.server_error.connect(_on_server_error)

	# Refresh status (server may still be running from a previous scene)
	_refresh_status()


func _launch_mode(scene_path: String) -> void:
	## Start the matching server (if needed) and load the visualization scene.
	if _launching:
		return
	_launching = true

	var sm = get_node_or_null("/root/ServerManager")
	if not sm:
		# Fallback: no ServerManager, just load scene
		get_tree().change_scene_to_file(scene_path)
		return

	# Determine which server type to start
	# ServerManager.ServerType: NONE=0, SINGLE_JUNCTION=1, CORRIDOR=2
	var server_type: int
	if scene_path == SCENE_SINGLE:
		server_type = 1  # SINGLE_JUNCTION
	elif scene_path == SCENE_CORRIDOR:
		server_type = 2  # CORRIDOR
	else:
		get_tree().change_scene_to_file(scene_path)
		return

	# If the correct server is already running, just load the scene
	if sm.is_running() and sm.get_server_type() == server_type:
		print("[Launcher] Server already running — loading scene")
		get_tree().change_scene_to_file(scene_path)
		return

	# Start (or switch) the server
	print("[Launcher] Starting server for %s..." % scene_path)
	_update_status_starting()

	sm.start_server(server_type)

	# Give server time to initialize, then load scene
	# WebSocketClient will handle reconnecting if the server needs more time
	await get_tree().create_timer(2.0).timeout

	_launching = false
	get_tree().change_scene_to_file(scene_path)


func _refresh_status() -> void:
	## Update the status bar to reflect the current ServerManager state.
	var sm = get_node_or_null("/root/ServerManager")
	if not sm:
		return

	if sm.is_running():
		_status_dot.color = ACCENT_GREEN
		_status_label.text = "Server: %s (PID %d)" % [sm.get_server_type_name(), sm.server_pid]
		_status_label.add_theme_color_override("font_color", ACCENT_GREEN)
		_stop_btn.visible = true
	else:
		_status_dot.color = ACCENT_RED
		_status_label.text = "Server: Not Running"
		_status_label.add_theme_color_override("font_color", TEXT_DIM)
		_stop_btn.visible = false


func _update_status_starting() -> void:
	_status_dot.color = ACCENT_YELLOW
	_status_label.text = "Server: Starting..."
	_status_label.add_theme_color_override("font_color", ACCENT_YELLOW)
	_stop_btn.visible = false


# ═════════════════════════════════════════════════════════════════════════════
# SIGNAL HANDLERS
# ═════════════════════════════════════════════════════════════════════════════

func _on_server_started(server_type_name: String) -> void:
	var sm = get_node_or_null("/root/ServerManager")
	_status_dot.color = ACCENT_GREEN
	if sm:
		_status_label.text = "Server: %s (PID %d)" % [server_type_name, sm.server_pid]
	else:
		_status_label.text = "Server: %s" % server_type_name
	_status_label.add_theme_color_override("font_color", ACCENT_GREEN)
	_stop_btn.visible = true


func _on_server_stopped() -> void:
	if not _launching:
		_status_dot.color = ACCENT_RED
		_status_label.text = "Server: Not Running"
		_status_label.add_theme_color_override("font_color", TEXT_DIM)
		_stop_btn.visible = false


func _on_server_log_updated(new_text: String) -> void:
	if _log_text and _log_panel.visible:
		_log_text.append_text(new_text)


func _on_server_error(message: String) -> void:
	_status_dot.color = ACCENT_RED
	_status_label.text = "Server Error: %s" % message
	_status_label.add_theme_color_override("font_color", ACCENT_RED)
	_stop_btn.visible = false
	# Auto-show log panel so user can see what went wrong
	if not _log_panel.visible:
		_on_log_toggle()


func _on_log_toggle() -> void:
	_log_panel.visible = not _log_panel.visible
	_log_toggle_btn.text = "Hide Log" if _log_panel.visible else "Show Log"
	# When showing, load full log contents
	if _log_panel.visible:
		var sm = get_node_or_null("/root/ServerManager")
		if sm:
			_log_text.clear()
			_log_text.append_text(sm.get_log_contents())


func _on_stop_pressed() -> void:
	var sm = get_node_or_null("/root/ServerManager")
	if sm:
		sm.stop_server()


# ═════════════════════════════════════════════════════════════════════════════
# HELPERS
# ═════════════════════════════════════════════════════════════════════════════

func _make_label(text: String, font_size: int) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", TEXT_COLOR)
	return lbl
