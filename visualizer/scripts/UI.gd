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

# ── UI element references ────────────────────────────────────────────────────
# Top bar
var _lbl_title: Label
var _lbl_sim_time: Label
var _lbl_completed: Label
var _lbl_avg_wait: Label
var _lbl_connection: Label

# Right panel — approach indicators
var _approach_panels: Dictionary = {}  # { "north": {bar, label}, ... }
var _lbl_phase: Label
var _lbl_ai_decision: Label
var _lbl_reward: Label

# Bottom bar
var _lbl_mode: Label
var _btn_force_north: Button
var _btn_force_south: Button
var _btn_force_east: Button
var _btn_force_west: Button

# Emergency banner
var _emergency_banner: PanelContainer
var _lbl_emergency: Label
var _banner_pulse_time: float = 0.0

# Metrics charts (MetricsChart.gd instances)
var _chart_queue: Control    ## Queue depth over time
var _chart_wait: Control     ## Wait time over time

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
	_build_bottom_bar()
	_build_emergency_banner()

	# Set initial state
	set_connection_status(false)


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
	for approach in ["North (N2J)", "South (S2J)", "East (E2J)", "West (W2J)"]:
		var key: String = approach.split(" ")[0].to_lower()
		var ap: Dictionary = _build_approach_indicator(approach)
		vbox.add_child(ap["container"])
		_approach_panels[key] = ap

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
	_chart_queue = MetricsChartScript.new()
	_chart_queue.chart_title = "Queue Depth"
	_chart_queue.max_value = 50.0
	_chart_queue.custom_minimum_size = Vector2(195, 100)
	vbox.add_child(_chart_queue)

	# Wait time chart
	_chart_wait = MetricsChartScript.new()
	_chart_wait.chart_title = "Wait Time (s)"
	_chart_wait.max_value = 300.0
	_chart_wait.custom_minimum_size = Vector2(195, 100)
	vbox.add_child(_chart_wait)


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
	panel.set_anchors_and_offsets_preset(PRESET_BOTTOM_WIDE)
	panel.custom_minimum_size = Vector2(0, 48)
	_style_panel(panel)
	add_child(panel)

	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 16)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	panel.add_child(hbox)

	# Mode indicator
	_lbl_mode = _make_label("AI CONTROL", 14)
	_lbl_mode.add_theme_color_override("font_color", ACCENT_GREEN)
	hbox.add_child(_lbl_mode)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(spacer)

	# Override buttons
	_btn_force_north = _make_override_button("Force North", "north")
	hbox.add_child(_btn_force_north)

	_btn_force_south = _make_override_button("Force South", "south")
	hbox.add_child(_btn_force_south)

	_btn_force_east = _make_override_button("Force East", "east")
	hbox.add_child(_btn_force_east)

	_btn_force_west = _make_override_button("Force West", "west")
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

	# Phase
	_lbl_phase.text = "Phase: %s" % data.get("phase_name", "—")

	# AI decision (5 actions: HOLD, NS_THROUGH, NS_LEFT, EW_THROUGH, EW_LEFT)
	var decision: String = data.get("ai_decision", "—")
	_lbl_ai_decision.text = "AI: %s" % decision
	if decision == "HOLD":
		_lbl_ai_decision.add_theme_color_override("font_color", ACCENT_GREEN)
	elif decision.ends_with("LEFT"):
		_lbl_ai_decision.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
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


func set_connection_status(connected: bool) -> void:
	## Update the connection status indicator.
	if connected:
		_lbl_connection.text = "CONNECTED"
		_lbl_connection.add_theme_color_override("font_color", ACCENT_GREEN)
	else:
		_lbl_connection.text = "RECONNECTING..."
		_lbl_connection.add_theme_color_override("font_color", ACCENT_RED)


func show_completion(data: Dictionary) -> void:
	## Show simulation completion info.
	_lbl_mode.text = "SIM COMPLETE"
	_lbl_mode.add_theme_color_override("font_color", TEXT_DIM)
	_lbl_completed.text = "Final: %d vehicles" % data.get("total_arrived", 0)


func reset_display() -> void:
	## Reset all HUD elements for a new simulation run.
	_lbl_sim_time.text = "00:00:00"
	_lbl_completed.text = "Completed: 0"
	_lbl_avg_wait.text = "Avg Wait: 0.0s"
	_lbl_phase.text = "Phase: —"
	_lbl_ai_decision.text = "AI: —"
	_lbl_reward.text = "R: 0.0 (Total: 0)"
	_emergency_banner.visible = false

	for approach in _approach_panels:
		var ap: Dictionary = _approach_panels[approach]
		ap["bar"].value = 0
		ap["stats"].text = "Q: 0  W: 0.0s"

	# Clear chart histories
	if _chart_queue:
		_chart_queue.clear_data()
	if _chart_wait:
		_chart_wait.clear_data()
