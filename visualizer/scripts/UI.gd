extends Control
## HUD overlay for the ATCS-GH 3D Visualizer.
##
## Displays real-time simulation metrics, connection status, manual override
## controls, and emergency alerts. All UI elements are built programmatically
## in _ready() — no external theme or font resources needed.
##
## Layout:
##   ┌─────────────────────────────────────────────────────────┐
##   │ TOP BAR: Logo | Sim Time | Completed | Avg Wait | Conn │
##   ├──────────────────────────────────┬──────────────────────┤
##   │                                  │  APPROACH PANELS     │
##   │          3D VIEWPORT             │  N: ████░░ Q:12 W:45 │
##   │                                  │  S: ██████ Q:8  W:30 │
##   │                                  │  E: ██░░░░ Q:5  W:22 │
##   │                                  │  W: █░░░░░ Q:3  W:15 │
##   │                                  │  AI: HOLD  R: +5.3   │
##   ├──────────────────────────────────┴──────────────────────┤
##   │ BOTTOM: Mode [AI CONTROL] | [Force N/S] [Force E/W]    │
##   └─────────────────────────────────────────────────────────┘
##   │ EMERGENCY BANNER (hidden unless active)                 │

# ── Signals ──────────────────────────────────────────────────────────────────
## Emitted when the user clicks a manual override button
signal override_requested(approach: String)
## Emitted when the user toggles between ATCS and Fixed Timer modes
signal mode_switch_requested(mode: String)
## Emitted when the user clicks the Deploy Ambulance button
signal emergency_spawn_requested(approach: String)
## Emitted when the user toggles pedestrians on/off
signal pedestrian_toggled(enabled: bool)

# ── Corridor mode ──────────────────────────────────────────────────────────
var corridor_mode: bool = false

# ── UI element references ────────────────────────────────────────────────────
# Top bar
var _lbl_title: Label
var _lbl_sim_time: Label
var _lbl_completed: Label
var _lbl_avg_wait: Label
var _lbl_connection: Label

# Right panel — approach indicators (single-junction mode)
var _approach_panels: Dictionary = {}  # { "north": {bar, label}, ... }
var _lbl_phase: Label
var _lbl_ai_decision: Label
var _lbl_reward: Label

# Right panel — corridor mode: per-junction panels
var _corridor_panel: PanelContainer         # The scrollable right panel for corridor
var _junction_panels: Dictionary = {}       # { "J0": { lbl_phase, lbl_wait, lbl_queue, lbl_ai, bar }, ... }
var _lbl_corridor_avg_wait: Label           # Corridor aggregate avg wait
var _lbl_corridor_reward: Label             # Corridor aggregate reward
var _right_panel_single: PanelContainer     # Reference to single-junction right panel

# Bottom bar
var _lbl_mode: Label
var _btn_mode_toggle: Button                # ATCS ↔ Fixed Timer toggle
var _current_control_mode: String = "ai"    # Tracks active control mode
var _btn_force_north: Button
var _btn_force_south: Button
var _btn_force_east: Button
var _btn_force_west: Button
var _btn_deploy_ambulance: Button            # Deploy Ambulance button
var _btn_toggle_pedestrians: Button          # Pedestrian on/off toggle
var _pedestrians_on: bool = true             # Current pedestrian toggle state
var _ambulance_counter: int = 0              # Unique ID counter for spawned ambulances
var _bottom_panel: PanelContainer           # Reference to bottom bar panel

# Emergency banner
var _emergency_banner: PanelContainer
var _lbl_emergency: Label
var _banner_pulse_time: float = 0.0

# Metrics charts (MetricsChart.gd instances)
var _chart_queue: Control    ## Queue depth over time (single-junction or corridor)
var _chart_wait: Control     ## Wait time over time (single-junction or corridor)
# Corridor-specific charts (kept separate so single-junction charts aren't lost)
var _corridor_chart_queue: Control
var _corridor_chart_wait: Control
# Single-junction charts
var _single_chart_queue: Control
var _single_chart_wait: Control

# ── Style constants ──────────────────────────────────────────────────────────
const BG_COLOR       := Color(0.08, 0.08, 0.12, 0.85)
const ACCENT_GREEN   := Color(0.2, 0.85, 0.3)
const ACCENT_ORANGE  := Color(0.95, 0.6, 0.1)
const ACCENT_RED     := Color(0.95, 0.15, 0.15)
const TEXT_COLOR      := Color(0.9, 0.9, 0.95)
const TEXT_DIM        := Color(0.6, 0.6, 0.65)
const PANEL_MARGIN   := 8


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	# Ensure this control fills the entire screen
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # Don't block 3D input

	_build_top_bar()
	_build_right_panel()
	_build_corridor_right_panel()
	_build_bottom_bar()
	_build_emergency_banner()

	# Set initial state
	set_connection_status(false)


func set_corridor_mode(enabled: bool) -> void:
	## Switch between single-junction and corridor UI layouts.
	corridor_mode = enabled
	if _right_panel_single:
		_right_panel_single.visible = not enabled
	if _corridor_panel:
		_corridor_panel.visible = enabled

	# Swap active chart references
	if enabled:
		_chart_queue = _corridor_chart_queue
		_chart_wait = _corridor_chart_wait
		_lbl_title.text = "ATCS-GH  |  N6 Nsawam Corridor  |  Valiborn Technologies"
		_lbl_mode.text = "CORRIDOR AI"
		_lbl_mode.add_theme_color_override("font_color", ACCENT_GREEN)
	else:
		_chart_queue = _single_chart_queue
		_chart_wait = _single_chart_wait
		_lbl_title.text = "ATCS-GH  |  Powered by Valiborn Technologies"


func _process(delta: float) -> void:
	# Pulse the emergency banner if visible
	if _emergency_banner and _emergency_banner.visible:
		_banner_pulse_time += delta * 3.5
		var alpha: float = 0.7 + 0.3 * sin(_banner_pulse_time)
		_emergency_banner.modulate = Color(1, 1, 1, alpha)


# ═════════════════════════════════════════════════════════════════════════════
# UI CONSTRUCTION
# ═════════════════════════════════════════════════════════════════════════════

func _build_top_bar() -> void:
	## Build the top information bar.
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(PRESET_TOP_WIDE)
	panel.custom_minimum_size = Vector2(0, 48)
	_style_panel(panel)
	add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 24)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(hbox)

	# Title
	_lbl_title = _make_label("ATCS-GH  |  Powered by Valiborn Technologies", 14)
	_lbl_title.add_theme_color_override("font_color", ACCENT_GREEN)
	hbox.add_child(_lbl_title)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	# Simulation time
	_lbl_sim_time = _make_label("00:00:00", 16)
	hbox.add_child(_lbl_sim_time)

	# Vehicles completed
	_lbl_completed = _make_label("Completed: 0", 13)
	hbox.add_child(_lbl_completed)

	# Average wait
	_lbl_avg_wait = _make_label("Avg Wait: 0.0s", 13)
	hbox.add_child(_lbl_avg_wait)

	# Connection status
	_lbl_connection = _make_label("DISCONNECTED", 12)
	_lbl_connection.add_theme_color_override("font_color", ACCENT_RED)
	hbox.add_child(_lbl_connection)


func _build_right_panel() -> void:
	## Build the right-side panel with approach indicators and AI info.
	var panel := PanelContainer.new()
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.anchor_top = 0.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -220
	panel.offset_top = 56
	panel.offset_bottom = -56
	panel.custom_minimum_size = Vector2(210, 0)
	_style_panel(panel)
	add_child(panel)
	_right_panel_single = panel

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# Section header
	var header := _make_label("APPROACHES", 11)
	header.add_theme_color_override("font_color", TEXT_DIM)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(header)

	# Add separator
	vbox.add_child(HSeparator.new())

	# Approach panels
	var approach_labels: Dictionary = {"north": "Nsawam (N)", "south": "CBD (S)", "east": "Aggrey St (E)", "west": "Guggisberg (W)"}
	for dir_key in ["north", "south", "east", "west"]:
		var label: String = approach_labels[dir_key]
		var ap: Dictionary = _build_approach_indicator(label)
		vbox.add_child(ap["container"])
		_approach_panels[dir_key] = ap

	# Separator before AI info
	vbox.add_child(HSeparator.new())

	# Phase info
	_lbl_phase = _make_label("Phase: —", 12)
	vbox.add_child(_lbl_phase)

	# AI decision
	_lbl_ai_decision = _make_label("AI: —", 14)
	_lbl_ai_decision.add_theme_color_override("font_color", ACCENT_GREEN)
	vbox.add_child(_lbl_ai_decision)

	# Reward
	_lbl_reward = _make_label("Reward: 0.0", 12)
	vbox.add_child(_lbl_reward)

	# ── Metrics Charts ────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())

	var charts_header := _make_label("LIVE CHARTS", 11)
	charts_header.add_theme_color_override("font_color", TEXT_DIM)
	charts_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(charts_header)

	# Queue depth chart
	var MetricsChartScript = load("res://scripts/MetricsChart.gd")
	_single_chart_queue = MetricsChartScript.new()
	_single_chart_queue.chart_title = "Queue Depth"
	_single_chart_queue.max_value = 50.0
	_single_chart_queue.custom_minimum_size = Vector2(195, 100)
	vbox.add_child(_single_chart_queue)

	# Wait time chart
	_single_chart_wait = MetricsChartScript.new()
	_single_chart_wait.chart_title = "Wait Time (s)"
	_single_chart_wait.max_value = 300.0
	_single_chart_wait.custom_minimum_size = Vector2(195, 100)
	vbox.add_child(_single_chart_wait)

	# Default: single-junction charts are active
	_chart_queue = _single_chart_queue
	_chart_wait = _single_chart_wait


func _build_corridor_right_panel() -> void:
	## Build the corridor-specific right panel showing all 3 junctions.
	_corridor_panel = PanelContainer.new()
	_corridor_panel.anchor_left = 1.0
	_corridor_panel.anchor_right = 1.0
	_corridor_panel.anchor_top = 0.0
	_corridor_panel.anchor_bottom = 1.0
	_corridor_panel.offset_left = -240
	_corridor_panel.offset_top = 56
	_corridor_panel.offset_bottom = -56
	_corridor_panel.custom_minimum_size = Vector2(230, 0)
	_style_panel(_corridor_panel)
	_corridor_panel.visible = false  # Hidden until corridor mode enabled
	add_child(_corridor_panel)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_corridor_panel.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(vbox)

	# ── Header ────────────────────────────────────────────────────────────
	var header := _make_label("CORRIDOR OVERVIEW", 11)
	header.add_theme_color_override("font_color", TEXT_DIM)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(header)
	vbox.add_child(HSeparator.new())

	# ── Corridor aggregate stats ──────────────────────────────────────────
	_lbl_corridor_avg_wait = _make_label("Corridor Wait: 0.0s", 13)
	_lbl_corridor_avg_wait.add_theme_color_override("font_color", ACCENT_GREEN)
	vbox.add_child(_lbl_corridor_avg_wait)

	_lbl_corridor_reward = _make_label("Total Reward: 0", 11)
	_lbl_corridor_reward.add_theme_color_override("font_color", TEXT_DIM)
	vbox.add_child(_lbl_corridor_reward)

	vbox.add_child(HSeparator.new())

	# ── Per-junction panels ──────────────────────────────────────────────
	var junction_names: Dictionary = {
		"J0": "J0 — Achimota",
		"J1": "J1 — Asylum Down",
		"J2": "J2 — Nima/Tesano",
	}

	var junction_colors: Dictionary = {
		"J0": Color(0.35, 0.55, 1.0),     # Blue
		"J1": Color(0.35, 1.0, 0.45),     # Green
		"J2": Color(1.0, 0.9, 0.25),      # Yellow
	}

	for jid in ["J0", "J1", "J2"]:
		var jp: Dictionary = _build_junction_panel(jid, junction_names[jid], junction_colors[jid])
		vbox.add_child(jp["container"])
		_junction_panels[jid] = jp

	# ── Corridor Charts ──────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())

	var charts_header := _make_label("JUNCTION WAIT TIMES", 11)
	charts_header.add_theme_color_override("font_color", TEXT_DIM)
	charts_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(charts_header)

	# Wait time chart for corridor (series = J0, J1, J2 mapped to north, south, east keys)
	var MetricsChartScript = load("res://scripts/MetricsChart.gd")
	_corridor_chart_wait = MetricsChartScript.new()
	_corridor_chart_wait.chart_title = "Avg Wait (s)"
	_corridor_chart_wait.max_value = 100.0
	_corridor_chart_wait.custom_minimum_size = Vector2(215, 110)
	# Override series colors with junction colors
	_corridor_chart_wait.SERIES_COLORS = {
		"north": Color(0.35, 0.55, 1.0),   # J0 = Blue
		"south": Color(0.35, 1.0, 0.45),   # J1 = Green
		"east":  Color(1.0, 0.9, 0.25),    # J2 = Yellow
	}
	_corridor_chart_wait.series_labels = {"north": "J0", "south": "J1", "east": "J2"}
	vbox.add_child(_corridor_chart_wait)

	# Queue chart (series = J0, J1, J2)
	_corridor_chart_queue = MetricsChartScript.new()
	_corridor_chart_queue.chart_title = "Total Queue"
	_corridor_chart_queue.max_value = 80.0
	_corridor_chart_queue.custom_minimum_size = Vector2(215, 110)
	_corridor_chart_queue.SERIES_COLORS = {
		"north": Color(0.35, 0.55, 1.0),
		"south": Color(0.35, 1.0, 0.45),
		"east":  Color(1.0, 0.9, 0.25),
	}
	_corridor_chart_queue.series_labels = {"north": "J0", "south": "J1", "east": "J2"}
	vbox.add_child(_corridor_chart_queue)


func _build_junction_panel(jid: String, name_text: String, color: Color) -> Dictionary:
	## Build a compact per-junction status panel for corridor mode.
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)

	# Junction name with colored indicator
	var header_hbox := HBoxContainer.new()
	header_hbox.add_theme_constant_override("separation", 6)
	container.add_child(header_hbox)

	# Color dot indicator
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(8, 8)
	dot.color = color
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header_hbox.add_child(dot)

	# Junction name
	var lbl_name := _make_label(name_text, 12)
	lbl_name.add_theme_color_override("font_color", color)
	header_hbox.add_child(lbl_name)

	# Phase row
	var lbl_phase := _make_label("NS_THROUGH", 11)
	lbl_phase.add_theme_color_override("font_color", ACCENT_GREEN)
	container.add_child(lbl_phase)

	# AI decision
	var lbl_ai := _make_label("AI: HOLD", 11)
	lbl_ai.add_theme_color_override("font_color", TEXT_DIM)
	container.add_child(lbl_ai)

	# Queue bar (total queue across all approaches)
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 80
	bar.value = 0
	bar.custom_minimum_size = Vector2(210, 10)
	bar.show_percentage = false
	bar.modulate = color
	container.add_child(bar)

	# Stats line: Wait | Queue | Reward
	var lbl_stats := _make_label("W: 0.0s  Q: 0  R: 0", 10)
	lbl_stats.add_theme_color_override("font_color", TEXT_DIM)
	container.add_child(lbl_stats)

	# Thin separator
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 2)
	container.add_child(sep)

	return {
		"container": container,
		"lbl_phase": lbl_phase,
		"lbl_ai": lbl_ai,
		"lbl_stats": lbl_stats,
		"bar": bar,
		"color": color,
	}


func _build_approach_indicator(label_text: String) -> Dictionary:
	## Build a single approach indicator with name, progress bar, and stats.
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 2)

	# Name label
	var name_lbl := _make_label(label_text, 11)
	name_lbl.add_theme_color_override("font_color", TEXT_DIM)
	container.add_child(name_lbl)

	# Queue bar (ProgressBar)
	var bar := ProgressBar.new()
	bar.min_value = 0
	bar.max_value = 50  # MAX_QUEUE from Python
	bar.value = 0
	bar.custom_minimum_size = Vector2(190, 14)
	bar.show_percentage = false
	container.add_child(bar)

	# Stats label (queue + wait)
	var stats := _make_label("Q: 0  W: 0.0s", 11)
	container.add_child(stats)

	return {
		"container": container,
		"bar": bar,
		"stats": stats,
	}


func _build_bottom_bar() -> void:
	## Build the bottom bar with mode indicator and override buttons.
	var panel := PanelContainer.new()
	# Set minimum size BEFORE the preset so PRESET_MODE_MINSIZE computes
	# correct offsets (offset_top = -48).  Without this the panel gets zero
	# height and grows off-screen below the viewport.
	panel.custom_minimum_size = Vector2(0, 48)
	panel.set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE)
	# Belt-and-suspenders: explicitly pin the top edge 48 px above bottom
	panel.offset_top = -48
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_style_panel(panel)
	add_child(panel)
	_bottom_panel = panel

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(hbox)

	# Mode indicator
	_lbl_mode = _make_label("AI CONTROL", 14)
	_lbl_mode.add_theme_color_override("font_color", ACCENT_GREEN)
	hbox.add_child(_lbl_mode)

	# ── ATCS / Fixed Timer toggle button ──────────────────────────────
	_btn_mode_toggle = Button.new()
	_btn_mode_toggle.text = "⚡ Switch to Fixed Timer"
	_btn_mode_toggle.custom_minimum_size = Vector2(190, 34)
	_btn_mode_toggle.add_theme_font_size_override("font_size", 12)
	# White text on colored background
	_btn_mode_toggle.add_theme_color_override("font_color", Color.WHITE)
	_btn_mode_toggle.add_theme_color_override("font_hover_color", Color.WHITE)
	_btn_mode_toggle.add_theme_color_override("font_pressed_color", Color(0.85, 0.85, 0.9))
	_btn_mode_toggle.add_theme_color_override("font_focus_color", Color.WHITE)
	# Blue background with border
	var toggle_style := StyleBoxFlat.new()
	toggle_style.bg_color = Color(0.12, 0.35, 0.7, 0.95)
	toggle_style.border_color = Color(0.4, 0.65, 1.0, 0.8)
	toggle_style.border_width_left = 2
	toggle_style.border_width_right = 2
	toggle_style.border_width_top = 2
	toggle_style.border_width_bottom = 2
	toggle_style.corner_radius_top_left = 6
	toggle_style.corner_radius_top_right = 6
	toggle_style.corner_radius_bottom_left = 6
	toggle_style.corner_radius_bottom_right = 6
	toggle_style.content_margin_left = 12
	toggle_style.content_margin_right = 12
	toggle_style.content_margin_top = 6
	toggle_style.content_margin_bottom = 6
	_btn_mode_toggle.add_theme_stylebox_override("normal", toggle_style)
	var toggle_hover := toggle_style.duplicate()
	toggle_hover.bg_color = Color(0.18, 0.45, 0.85, 0.98)
	toggle_hover.border_color = Color(0.5, 0.75, 1.0, 1.0)
	_btn_mode_toggle.add_theme_stylebox_override("hover", toggle_hover)
	var toggle_pressed := toggle_style.duplicate()
	toggle_pressed.bg_color = Color(0.08, 0.25, 0.55, 0.95)
	_btn_mode_toggle.add_theme_stylebox_override("pressed", toggle_pressed)
	var toggle_focus := toggle_style.duplicate()
	toggle_focus.border_color = Color(0.5, 0.75, 1.0, 1.0)
	_btn_mode_toggle.add_theme_stylebox_override("focus", toggle_focus)
	_btn_mode_toggle.pressed.connect(_on_mode_toggle_pressed)
	hbox.add_child(_btn_mode_toggle)

	# ── Deploy Ambulance button ──────────────────────────────────────────
	_btn_deploy_ambulance = Button.new()
	_btn_deploy_ambulance.text = "🚑 Deploy Ambulance"
	_btn_deploy_ambulance.custom_minimum_size = Vector2(180, 34)
	_btn_deploy_ambulance.add_theme_font_size_override("font_size", 12)
	_btn_deploy_ambulance.add_theme_color_override("font_color", Color.WHITE)
	_btn_deploy_ambulance.add_theme_color_override("font_hover_color", Color.WHITE)
	_btn_deploy_ambulance.add_theme_color_override("font_pressed_color", Color(0.9, 0.85, 0.85))
	_btn_deploy_ambulance.add_theme_color_override("font_focus_color", Color.WHITE)
	# Red background
	var amb_style := StyleBoxFlat.new()
	amb_style.bg_color = Color(0.7, 0.08, 0.08, 0.95)
	amb_style.border_color = Color(1.0, 0.3, 0.3, 0.8)
	amb_style.border_width_left = 2
	amb_style.border_width_right = 2
	amb_style.border_width_top = 2
	amb_style.border_width_bottom = 2
	amb_style.corner_radius_top_left = 6
	amb_style.corner_radius_top_right = 6
	amb_style.corner_radius_bottom_left = 6
	amb_style.corner_radius_bottom_right = 6
	amb_style.content_margin_left = 12
	amb_style.content_margin_right = 12
	amb_style.content_margin_top = 6
	amb_style.content_margin_bottom = 6
	_btn_deploy_ambulance.add_theme_stylebox_override("normal", amb_style)
	var amb_hover := amb_style.duplicate()
	amb_hover.bg_color = Color(0.85, 0.12, 0.12, 0.98)
	amb_hover.border_color = Color(1.0, 0.4, 0.4, 1.0)
	_btn_deploy_ambulance.add_theme_stylebox_override("hover", amb_hover)
	var amb_pressed := amb_style.duplicate()
	amb_pressed.bg_color = Color(0.5, 0.04, 0.04, 0.95)
	_btn_deploy_ambulance.add_theme_stylebox_override("pressed", amb_pressed)
	var amb_focus := amb_style.duplicate()
	amb_focus.border_color = Color(1.0, 0.4, 0.4, 1.0)
	_btn_deploy_ambulance.add_theme_stylebox_override("focus", amb_focus)
	_btn_deploy_ambulance.pressed.connect(_on_deploy_ambulance_pressed)
	hbox.add_child(_btn_deploy_ambulance)

	# ── Pedestrian toggle button ────────────────────────────────────────
	_btn_toggle_pedestrians = Button.new()
	_btn_toggle_pedestrians.text = "🚶 Pedestrians: ON"
	_btn_toggle_pedestrians.custom_minimum_size = Vector2(170, 34)
	_btn_toggle_pedestrians.add_theme_font_size_override("font_size", 12)
	_btn_toggle_pedestrians.add_theme_color_override("font_color", Color.WHITE)
	_btn_toggle_pedestrians.add_theme_color_override("font_hover_color", Color.WHITE)
	_btn_toggle_pedestrians.add_theme_color_override("font_pressed_color", Color(0.85, 0.9, 0.85))
	_btn_toggle_pedestrians.add_theme_color_override("font_focus_color", Color.WHITE)
	# Green background (active)
	var ped_style := StyleBoxFlat.new()
	ped_style.bg_color = Color(0.12, 0.55, 0.25, 0.95)
	ped_style.border_color = Color(0.3, 0.8, 0.4, 0.8)
	ped_style.border_width_left = 2
	ped_style.border_width_right = 2
	ped_style.border_width_top = 2
	ped_style.border_width_bottom = 2
	ped_style.corner_radius_top_left = 6
	ped_style.corner_radius_top_right = 6
	ped_style.corner_radius_bottom_left = 6
	ped_style.corner_radius_bottom_right = 6
	ped_style.content_margin_left = 12
	ped_style.content_margin_right = 12
	ped_style.content_margin_top = 6
	ped_style.content_margin_bottom = 6
	_btn_toggle_pedestrians.add_theme_stylebox_override("normal", ped_style)
	var ped_hover := ped_style.duplicate()
	ped_hover.bg_color = Color(0.15, 0.65, 0.30, 0.98)
	ped_hover.border_color = Color(0.4, 0.9, 0.5, 1.0)
	_btn_toggle_pedestrians.add_theme_stylebox_override("hover", ped_hover)
	var ped_pressed := ped_style.duplicate()
	ped_pressed.bg_color = Color(0.08, 0.40, 0.18, 0.95)
	_btn_toggle_pedestrians.add_theme_stylebox_override("pressed", ped_pressed)
	var ped_focus := ped_style.duplicate()
	ped_focus.border_color = Color(0.4, 0.9, 0.5, 1.0)
	_btn_toggle_pedestrians.add_theme_stylebox_override("focus", ped_focus)
	_btn_toggle_pedestrians.pressed.connect(_on_toggle_pedestrians_pressed)
	hbox.add_child(_btn_toggle_pedestrians)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	# Override buttons
	_btn_force_north = _make_override_button("Nsawam", "north")
	hbox.add_child(_btn_force_north)

	_btn_force_south = _make_override_button("CBD", "south")
	hbox.add_child(_btn_force_south)

	_btn_force_east = _make_override_button("Aggrey", "east")
	hbox.add_child(_btn_force_east)

	_btn_force_west = _make_override_button("Guggisberg", "west")
	hbox.add_child(_btn_force_west)


func _build_emergency_banner() -> void:
	## Build the emergency alert banner (hidden by default).
	_emergency_banner = PanelContainer.new()
	_emergency_banner.set_anchors_and_offsets_preset(PRESET_CENTER_TOP)
	_emergency_banner.anchor_left = 0.1
	_emergency_banner.anchor_right = 0.9
	_emergency_banner.offset_top = 56
	_emergency_banner.custom_minimum_size = Vector2(0, 40)
	_emergency_banner.visible = false

	# Red background
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.8, 0.05, 0.05, 0.9)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	_emergency_banner.add_theme_stylebox_override("panel", style)
	add_child(_emergency_banner)

	_lbl_emergency = _make_label("EMERGENCY VEHICLE — CORRIDOR CLEARING", 16)
	_lbl_emergency.add_theme_color_override("font_color", Color.WHITE)
	_lbl_emergency.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_emergency_banner.add_child(_lbl_emergency)


# ═════════════════════════════════════════════════════════════════════════════
# HELPER: UI element creation
# ═════════════════════════════════════════════════════════════════════════════

func _make_label(text: String, font_size: int) -> Label:
	## Create a styled label.
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", TEXT_COLOR)
	return lbl


func _make_override_button(text: String, approach: String) -> Button:
	## Create a manual override button that sends WebSocket commands.
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = Vector2(100, 32)
	btn.add_theme_font_size_override("font_size", 11)
	# Connect button press to emit override signal
	btn.pressed.connect(func(): override_requested.emit(approach))
	return btn


func _style_panel(panel: PanelContainer) -> void:
	## Apply dark semi-transparent background to a panel.
	var style := StyleBoxFlat.new()
	style.bg_color = BG_COLOR
	style.content_margin_left = PANEL_MARGIN
	style.content_margin_right = PANEL_MARGIN
	style.content_margin_top = PANEL_MARGIN
	style.content_margin_bottom = PANEL_MARGIN
	panel.add_theme_stylebox_override("panel", style)


func _on_mode_toggle_pressed() -> void:
	## Handle the ATCS / Fixed Timer toggle button press.
	if _current_control_mode == "ai":
		mode_switch_requested.emit("baseline")
	else:
		mode_switch_requested.emit("ai")


func _on_deploy_ambulance_pressed() -> void:
	## Deploy an ambulance from a random approach (or user can specify).
	_ambulance_counter += 1
	# Pick a random approach for variety
	var approaches := ["north", "south", "east", "west"]
	var approach: String = approaches[_ambulance_counter % approaches.size()]
	emergency_spawn_requested.emit(approach)
	# Brief visual feedback: disable button temporarily
	_btn_deploy_ambulance.disabled = true
	_btn_deploy_ambulance.text = "🚑 Deploying..."
	get_tree().create_timer(2.0).timeout.connect(func():
		_btn_deploy_ambulance.disabled = false
		_btn_deploy_ambulance.text = "🚑 Deploy Ambulance"
	)


func _on_toggle_pedestrians_pressed() -> void:
	## Toggle pedestrians on/off.
	_pedestrians_on = not _pedestrians_on
	pedestrian_toggled.emit(_pedestrians_on)
	if _pedestrians_on:
		_btn_toggle_pedestrians.text = "🚶 Pedestrians: ON"
		# Green style
		var style: StyleBoxFlat = _btn_toggle_pedestrians.get_theme_stylebox("normal") as StyleBoxFlat
		if style:
			style.bg_color = Color(0.12, 0.55, 0.25, 0.95)
			style.border_color = Color(0.3, 0.8, 0.4, 0.8)
	else:
		_btn_toggle_pedestrians.text = "🚶 Pedestrians: OFF"
		# Gray style
		var style: StyleBoxFlat = _btn_toggle_pedestrians.get_theme_stylebox("normal") as StyleBoxFlat
		if style:
			style.bg_color = Color(0.35, 0.35, 0.40, 0.95)
			style.border_color = Color(0.5, 0.5, 0.55, 0.8)


func update_control_mode(new_mode: String) -> void:
	## Update the UI to reflect the current control mode (called from server data).
	_current_control_mode = new_mode
	if new_mode == "baseline":
		_lbl_mode.text = "FIXED TIMER"
		_lbl_mode.add_theme_color_override("font_color", ACCENT_ORANGE)
		_btn_mode_toggle.text = "⚡ Switch to ATCS"
		# Restyle button to green (switch TO ai)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.1, 0.5, 0.2, 0.95)
		style.border_color = Color(0.3, 0.85, 0.4, 0.8)
		style.border_width_left = 2
		style.border_width_right = 2
		style.border_width_top = 2
		style.border_width_bottom = 2
		style.corner_radius_top_left = 6
		style.corner_radius_top_right = 6
		style.corner_radius_bottom_left = 6
		style.corner_radius_bottom_right = 6
		style.content_margin_left = 12
		style.content_margin_right = 12
		style.content_margin_top = 6
		style.content_margin_bottom = 6
		_btn_mode_toggle.add_theme_stylebox_override("normal", style)
		var hover := style.duplicate()
		hover.bg_color = Color(0.15, 0.6, 0.3, 0.98)
		hover.border_color = Color(0.4, 0.95, 0.5, 1.0)
		_btn_mode_toggle.add_theme_stylebox_override("hover", hover)
	else:
		if corridor_mode:
			_lbl_mode.text = "CORRIDOR AI"
		else:
			_lbl_mode.text = "AI CONTROL"
		_lbl_mode.add_theme_color_override("font_color", ACCENT_GREEN)
		_btn_mode_toggle.text = "⚡ Switch to Fixed Timer"
		# Restyle button to blue (switch TO baseline)
		var style := StyleBoxFlat.new()
		style.bg_color = Color(0.12, 0.35, 0.7, 0.95)
		style.border_color = Color(0.4, 0.65, 1.0, 0.8)
		style.border_width_left = 2
		style.border_width_right = 2
		style.border_width_top = 2
		style.border_width_bottom = 2
		style.corner_radius_top_left = 6
		style.corner_radius_top_right = 6
		style.corner_radius_bottom_left = 6
		style.corner_radius_bottom_right = 6
		style.content_margin_left = 12
		style.content_margin_right = 12
		style.content_margin_top = 6
		style.content_margin_bottom = 6
		_btn_mode_toggle.add_theme_stylebox_override("normal", style)
		var hover := style.duplicate()
		hover.bg_color = Color(0.18, 0.45, 0.85, 0.98)
		hover.border_color = Color(0.5, 0.75, 1.0, 1.0)
		_btn_mode_toggle.add_theme_stylebox_override("hover", hover)


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API — called by Main.gd
# ═════════════════════════════════════════════════════════════════════════════

func update_display(data: Dictionary) -> void:
	## Update all HUD elements from a state_update packet.
	# Simulation time (convert seconds to HH:MM:SS)
	var sim_time: int = data.get("sim_time", 0)
	var hours: int = int(float(sim_time) / 3600.0)
	var minutes: int = int(float(sim_time % 3600) / 60.0)
	var secs: int = sim_time % 60
	_lbl_sim_time.text = "%02d:%02d:%02d" % [hours, minutes, secs]

	# Top bar stats
	_lbl_completed.text = "Completed: %d" % data.get("vehicles_completed", 0)
	_lbl_avg_wait.text = "Avg Wait: %.1fs" % data.get("avg_wait", 0.0)

	# ── Corridor mode: per-junction update ────────────────────────────────
	if corridor_mode:
		_update_corridor_display(data)
		return

	# ── Single-junction mode (original behavior) ─────────────────────────
	# Phase
	_lbl_phase.text = "Phase: %s" % data.get("phase_name", "—")

	# AI decision (7 actions: HOLD, NS_THROUGH, NS_LEFT, EW_THROUGH, EW_LEFT, NS_ALL, EW_ALL)
	var decision: String = data.get("ai_decision", "—")
	_lbl_ai_decision.text = "AI: %s" % decision
	if decision == "HOLD":
		_lbl_ai_decision.add_theme_color_override("font_color", ACCENT_GREEN)
	elif decision.ends_with("LEFT"):
		_lbl_ai_decision.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
	elif decision.ends_with("ALL"):
		_lbl_ai_decision.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	else:
		_lbl_ai_decision.add_theme_color_override("font_color", ACCENT_ORANGE)

	# Reward
	var reward: float = data.get("reward", 0.0)
	var total_reward: float = data.get("total_reward", 0.0)
	_lbl_reward.text = "R: %.1f (Total: %.0f)" % [reward, total_reward]

	# Mode indicator
	var mode: String = data.get("mode", "ai")
	match mode:
		"ai":
			_lbl_mode.text = "AI CONTROL"
			_lbl_mode.add_theme_color_override("font_color", ACCENT_GREEN)
		"manual":
			_lbl_mode.text = "MANUAL OVERRIDE"
			_lbl_mode.add_theme_color_override("font_color", ACCENT_ORANGE)
		"demo":
			_lbl_mode.text = "DEMO MODE"
			_lbl_mode.add_theme_color_override("font_color", ACCENT_ORANGE)

	# Approach panels
	var queues: Dictionary = data.get("queues", {})
	var waits: Dictionary = data.get("wait_times", {})
	for approach in ["north", "south", "east", "west"]:
		if _approach_panels.has(approach):
			var ap: Dictionary = _approach_panels[approach]
			var q: float = queues.get(approach, 0)
			var w: float = waits.get(approach, 0)

			# Update progress bar
			var bar: ProgressBar = ap["bar"]
			bar.value = q
			# Color-code: green < 10, yellow < 25, red >= 25
			if q < 10:
				bar.modulate = ACCENT_GREEN
			elif q < 25:
				bar.modulate = ACCENT_ORANGE
			else:
				bar.modulate = ACCENT_RED

			# Update stats label
			var stats_lbl: Label = ap["stats"]
			stats_lbl.text = "Q: %d  W: %.0fs" % [int(q), w]

	# Emergency banner
	var emergency: Dictionary = data.get("emergency", {})
	var emerg_active: bool = emergency.get("active", false)
	_emergency_banner.visible = emerg_active

	if emerg_active:
		var emerg_approach: String = str(emergency.get("approach", "—")).to_upper()
		var emerg_vid: String = str(emergency.get("vehicle_id", ""))
		_lbl_emergency.text = "EMERGENCY VEHICLE — %s — %s" % [emerg_approach, emerg_vid]

	# Preempted indicator
	if data.get("preempted", false):
		_lbl_ai_decision.text = "AI: PREEMPTED"
		_lbl_ai_decision.add_theme_color_override("font_color", ACCENT_RED)

	# ── Feed charts with new data points ──────────────────────────────────
	if _chart_queue:
		for approach in ["north", "south", "east", "west"]:
			_chart_queue.add_point(approach, float(queues.get(approach, 0)))
	if _chart_wait:
		for approach in ["north", "south", "east", "west"]:
			_chart_wait.add_point(approach, float(waits.get(approach, 0)))


func _update_corridor_display(data: Dictionary) -> void:
	## Update corridor-specific UI elements from per-junction data.
	var junctions_data: Dictionary = data.get("junctions", {})

	# Corridor aggregate stats
	var corridor_avg_wait: float = data.get("corridor_avg_wait", data.get("avg_wait", 0.0))
	var corridor_total_reward: float = data.get("total_reward", 0.0)

	if _lbl_corridor_avg_wait:
		_lbl_corridor_avg_wait.text = "Corridor Wait: %.1fs" % corridor_avg_wait
		# Color-code: green < 20, orange < 50, red >= 50
		if corridor_avg_wait < 20.0:
			_lbl_corridor_avg_wait.add_theme_color_override("font_color", ACCENT_GREEN)
		elif corridor_avg_wait < 50.0:
			_lbl_corridor_avg_wait.add_theme_color_override("font_color", ACCENT_ORANGE)
		else:
			_lbl_corridor_avg_wait.add_theme_color_override("font_color", ACCENT_RED)

	if _lbl_corridor_reward:
		_lbl_corridor_reward.text = "Total Reward: %.0f" % corridor_total_reward

	# Mode indicator — update from control_mode in packet
	var control_mode: String = data.get("control_mode", _current_control_mode)
	if control_mode != _current_control_mode:
		update_control_mode(control_mode)
	elif _current_control_mode == "baseline":
		_lbl_mode.text = "FIXED TIMER"
		_lbl_mode.add_theme_color_override("font_color", ACCENT_ORANGE)
	else:
		_lbl_mode.text = "CORRIDOR AI"
		_lbl_mode.add_theme_color_override("font_color", ACCENT_GREEN)

	# ── Update per-junction panels ────────────────────────────────────────
	# Map chart series: north=J0, south=J1, east=J2
	var chart_keys: Array = ["north", "south", "east"]

	for i in range(3):
		var jid: String = ["J0", "J1", "J2"][i]
		if not junctions_data.has(jid) or not _junction_panels.has(jid):
			continue

		var jdata: Dictionary = junctions_data[jid]
		var jp: Dictionary = _junction_panels[jid]

		# Phase
		var phase_name: String = jdata.get("phase_name", "UNKNOWN")
		var lbl_phase: Label = jp["lbl_phase"]
		lbl_phase.text = phase_name
		# Color-code phase
		if phase_name.begins_with("NS"):
			lbl_phase.add_theme_color_override("font_color", ACCENT_GREEN)
		elif phase_name.begins_with("EW"):
			lbl_phase.add_theme_color_override("font_color", ACCENT_ORANGE)
		else:
			lbl_phase.add_theme_color_override("font_color", TEXT_DIM)

		# AI / Fixed Timer decision
		var ai_decision: String = jdata.get("ai_decision", "HOLD")
		var lbl_ai: Label = jp["lbl_ai"]
		if _current_control_mode == "baseline":
			lbl_ai.text = "Fixed: %s" % ai_decision
			lbl_ai.add_theme_color_override("font_color", ACCENT_ORANGE)
		else:
			lbl_ai.text = "AI: %s" % ai_decision
			if ai_decision == "HOLD":
				lbl_ai.add_theme_color_override("font_color", TEXT_DIM)
			else:
				lbl_ai.add_theme_color_override("font_color", ACCENT_GREEN)

		# Preempted override
		if jdata.get("preempted", false):
			lbl_ai.text = "AI: PREEMPTED"
			lbl_ai.add_theme_color_override("font_color", ACCENT_RED)

		# Queues and waits
		var queues: Dictionary = jdata.get("queues", {})
		var wait_times: Dictionary = jdata.get("wait_times", {})
		var total_q: float = 0.0
		var total_w: float = 0.0
		var n_approaches: int = 0
		for approach in queues:
			total_q += float(queues[approach])
			total_w += float(wait_times.get(approach, 0))
			n_approaches += 1
		var avg_w: float = total_w / maxf(n_approaches, 1.0)

		# Queue bar
		var bar: ProgressBar = jp["bar"]
		bar.value = total_q
		if total_q < 15:
			bar.modulate = jp["color"]
		elif total_q < 40:
			bar.modulate = ACCENT_ORANGE
		else:
			bar.modulate = ACCENT_RED

		# Stats line
		var reward: float = jdata.get("reward", 0.0)
		var lbl_stats: Label = jp["lbl_stats"]
		lbl_stats.text = "W: %.0fs  Q: %d  R: %.0f" % [avg_w, int(total_q), reward]

		# Feed charts (use approach keys as series: north=J0, south=J1, east=J2)
		if _chart_wait:
			_chart_wait.add_point(chart_keys[i], avg_w)
		if _chart_queue:
			_chart_queue.add_point(chart_keys[i], total_q)

	# ── Emergency banner (check any junction) ─────────────────────────────
	var any_emergency: bool = false
	var emerg_jid: String = ""
	var emerg_approach: String = ""
	var emerg_vid: String = ""

	for jid in ["J0", "J1", "J2"]:
		if junctions_data.has(jid):
			var emerg: Dictionary = junctions_data[jid].get("emergency", {})
			if emerg.get("active", false):
				any_emergency = true
				emerg_jid = jid
				emerg_approach = str(emerg.get("approach", "")).to_upper()
				emerg_vid = str(emerg.get("vehicle_id", ""))
				break

	_emergency_banner.visible = any_emergency
	if any_emergency:
		_lbl_emergency.text = "EMERGENCY — %s %s — %s" % [emerg_jid, emerg_approach, emerg_vid]


func reset_charts() -> void:
	## Clear all chart data (call on simulation restart).
	if _single_chart_queue: _single_chart_queue.clear_data()
	if _single_chart_wait: _single_chart_wait.clear_data()
	if _corridor_chart_queue: _corridor_chart_queue.clear_data()
	if _corridor_chart_wait: _corridor_chart_wait.clear_data()


func set_connection_status(connected: bool) -> void:
	## Update the connection status indicator.
	if connected:
		_lbl_connection.text = "CONNECTED"
		_lbl_connection.add_theme_color_override("font_color", ACCENT_GREEN)
	else:
		_lbl_connection.text = "RECONNECTING..."
		_lbl_connection.add_theme_color_override("font_color", ACCENT_RED)


func show_server_mismatch(server_type: String) -> void:
	## Show a prominent banner when connected to the wrong Python server.
	## server_type is "corridor" or "single" — describes what the server IS.
	_emergency_banner.visible = true
	_banner_pulse_time = 0.0
	if server_type == "corridor":
		_lbl_emergency.text = "WRONG SERVER — You are connected to the Corridor server. Press Escape → select N6 Corridor"
	else:
		_lbl_emergency.text = "WRONG SERVER — You are connected to the Single Junction server. Press Escape → select Single Junction"
	# Override the banner color to orange (not red, since it's not an emergency)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.75, 0.45, 0.0, 0.92)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 8
	style.content_margin_bottom = 8
	_emergency_banner.add_theme_stylebox_override("panel", style)
	# Update connection label
	_lbl_connection.text = "WRONG SERVER"
	_lbl_connection.add_theme_color_override("font_color", ACCENT_ORANGE)


func show_completion(data: Dictionary) -> void:
	## Show simulation completion info.
	_lbl_mode.text = "SIM COMPLETE"
	_lbl_mode.add_theme_color_override("font_color", TEXT_DIM)

	if corridor_mode:
		var avg_wait: float = data.get("corridor_avg_wait", data.get("avg_wait", 0.0))
		_lbl_completed.text = "Final: %d vehicles | Corridor Wait: %.1fs" % [
			data.get("total_arrived", 0), avg_wait]
	else:
		_lbl_completed.text = "Final: %d vehicles" % data.get("total_arrived", 0)


func reset_display() -> void:
	## Reset all HUD elements for a new simulation run.
	_lbl_sim_time.text = "00:00:00"
	_lbl_completed.text = "Completed: 0"
	_lbl_avg_wait.text = "Avg Wait: 0.0s"
	_emergency_banner.visible = false

	if corridor_mode:
		# Reset corridor panels
		if _lbl_corridor_avg_wait:
			_lbl_corridor_avg_wait.text = "Corridor Wait: 0.0s"
			_lbl_corridor_avg_wait.add_theme_color_override("font_color", ACCENT_GREEN)
		if _lbl_corridor_reward:
			_lbl_corridor_reward.text = "Total Reward: 0"
		for jid in _junction_panels:
			var jp: Dictionary = _junction_panels[jid]
			jp["lbl_phase"].text = "NS_THROUGH"
			jp["lbl_ai"].text = "AI: HOLD"
			jp["lbl_stats"].text = "W: 0.0s  Q: 0  R: 0"
			jp["bar"].value = 0
		_lbl_mode.text = "CORRIDOR AI"
		_lbl_mode.add_theme_color_override("font_color", ACCENT_GREEN)
	else:
		_lbl_phase.text = "Phase: —"
		_lbl_ai_decision.text = "AI: —"
		_lbl_reward.text = "R: 0.0 (Total: 0)"
		for approach in _approach_panels:
			var ap: Dictionary = _approach_panels[approach]
			ap["bar"].value = 0
			ap["stats"].text = "Q: 0  W: 0.0s"

	# Clear chart histories
	if _chart_queue:
		_chart_queue.clear_data()
	if _chart_wait:
		_chart_wait.clear_data()
