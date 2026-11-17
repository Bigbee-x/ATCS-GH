extends Control
## Corridor-only HUD. Reads authoritative packets; scene preferences never change demand.
signal override_requested(junction: String, approach: String)
signal mode_switch_requested(mode: String)
signal pedestrian_toggled(enabled: bool)
signal time_of_day_changed(hour: float)
signal tod_mode_changed(mode_idx: int)
signal weather_changed(weather_idx: int)
signal focus_requested(junction: String)
const T = preload("res://scripts/TrafIQTheme.gd")
const JIDS := ["J0","J1","J2"]
const NAMES := ["Achimota","Asylum Down","Nima / Tesano"]
const ARMS := ["north","east","south","west"]
const REASONS := {"dqn":"Policy decision", "balance_queue_pressure":"Balancing competing queues", "maintain_green_flow":"Keeping traffic flowing", "minimum_green":"Completing minimum green", "serve_waiting_approach":"Serving waiting traffic", "maximum_green":"Sharing green time", "empty_or_blocked_movement":"Serving an available exit", "no_serviceable_demand":"Waiting for demand or exit space", "manual_override":"Manual request applied"}
var corridor_mode := true
var selected_junction := "J0"
var _data: Dictionary = {}
var _history := {"J0":[],"J1":[],"J2":[]}
var _last_sim_time := -1.0
var _last_packet_ms := -1
var _connected := false
var _complete := false
var _current_control_mode := ""
var _pending_mode := ""
var _pending_ms := 0
var _page := ""
var _cards: Dictionary = {}
var _nav: Dictionary = {}
var _pages: Dictionary = {}
var _approaches: Dictionary = {}
var _top: PanelContainer
var _dock: PanelContainer
var _drawer: PanelContainer
var _alert: PanelContainer
var _alert_text: Label
var _drawer_title: Label
var _lbl_sim_time: Label
var _lbl_completed: Label
var _lbl_avg_wait: Label
var _lbl_connection: Label
var _lbl_mode: Label
var _detail_name: Label
var _detail_phase: Label
var _detail_decision: Label
var _detail_reason: Label
var _detail_sample: Label
var _detail_crossing: Label
var _detail_signal: Label
var _wait_chart: Control
var _queue_chart: Control
var _btn_mode_toggle: Button
var _mode_value: Label
var _request_note: Label
var _override_buttons: Array[Button] = []
var _selectors: Array[OptionButton] = []
var _ped_toggle: CheckBox
var _slider_tod: HSlider
var _lbl_tod_time: Label
var _tod_choice: OptionButton
var _weather_choice: OptionButton
var _tod_mode_idx := 0
var _weather_idx := 0
var _pulse_elapsed := 0.0

func _ready() -> void:
	set_anchors_and_offsets_preset(PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = T.make_theme()
	_build_top()
	_build_dock()
	_build_drawer()
	_build_alert()
	resized.connect(_layout)
	_layout()
	_refresh_cards()
	_refresh_detail()
	_refresh_connection()

func set_corridor_mode(_enabled: bool) -> void:
	corridor_mode = true

func _build_top() -> void:
	_top = _panel(self)
	_top.name = "StatusBar"
	var row := _row(16)
	_top.add_child(row)
	var brand := T.label("TrafIQ",20)
	brand.tooltip_text = "Valiborn Technologies · N6 Nsawam corridor"
	row.add_child(brand)
	_space(row)
	_lbl_sim_time = _metric(row,"ELAPSED","Simulation time; independent of the scene clock.")
	_lbl_completed = _metric(row,"COMPLETED","Trips completed in this run, as reported by SUMO.")
	_lbl_avg_wait = _metric(row,"MEAN WAIT","Current wait per vehicle on the incoming corridor roads. Not a completed-trip delay.")
	_space(row)
	_lbl_connection = T.label("Waiting",12,T.MUTED)
	row.add_child(_lbl_connection)
	for page in ["Traffic","Scene","Controls"]:
		var button := T.button(page)
		button.pressed.connect(func(): toggle_page(page))
		row.add_child(button)
		_nav[page] = button

func _metric(parent: Control, title: String, hint: String) -> Label:
	var column := _stack(0)
	column.custom_minimum_size.x = 70
	column.tooltip_text = hint
	parent.add_child(column)
	column.add_child(T.label(title,9,T.MUTED))
	var value := T.label("—",14)
	column.add_child(value)
	return value

func _build_dock() -> void:
	_dock = _panel(self)
	_dock.name = "JunctionDock"
	var row := _row(8)
	_dock.add_child(row)
	var info := _stack(3)
	info.custom_minimum_size.x = 88
	row.add_child(info)
	info.add_child(T.label("N6 CORRIDOR",9,T.MUTED))
	_lbl_mode = T.label("Waiting",11)
	info.add_child(_lbl_mode)
	for i in range(3):
		var jid: String = JIDS[i]
		var button := T.button("")
		button.custom_minimum_size = Vector2(138,48)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.tooltip_text = "Focus %s · %s" % [jid,NAMES[i]]
		row.add_child(button)
		var box := _stack(2)
		box.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.set_anchors_and_offsets_preset(PRESET_FULL_RECT)
		box.offset_left = 10
		box.offset_top = 6
		box.offset_right = -8
		box.add_child(T.label(jid+"  "+NAMES[i],11))
		var details := T.label("Waiting for data",10,T.MUTED)
		box.add_child(details)
		button.add_child(box)
		button.pressed.connect(func(): select_junction(jid); focus_requested.emit(jid))
		_cards[jid] = {"button":button,"details":details}

func _build_drawer() -> void:
	_drawer = _panel(self)
	_drawer.name = "Inspector"
	_drawer.visible = false
	var content := _stack(14)
	_drawer.add_child(content)
	var heading := _row(8)
	content.add_child(heading)
	_drawer_title = T.label("Traffic",17)
	heading.add_child(_drawer_title)
	_space(heading)
	var close := T.button("×")
	close.tooltip_text = "Close panel"
	close.pressed.connect(func(): toggle_page(_page))
	heading.add_child(close)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
	var pages := _stack(0)
	pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(pages)
	for name_text in ["Traffic","Scene","Controls"]:
		var page := _stack(14)
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.visible = false
		pages.add_child(page)
		_pages[name_text] = page
	_build_traffic(_pages.Traffic)
	_build_scene(_pages.Scene)
	_build_controls(_pages.Controls)

func _selector(parent: Control) -> OptionButton:
	var choice := _option(parent)
	for i in range(3): choice.add_item(JIDS[i]+" · "+NAMES[i])
	choice.item_selected.connect(func(index: int): select_junction(JIDS[index]))
	_selectors.append(choice)
	return choice

func _build_traffic(page: Control) -> void:
	_selector(page)
	_detail_name = T.label("Achimota",16)
	page.add_child(_detail_name)
	_detail_phase = _wrapped("Waiting for phase data",14)
	page.add_child(_detail_phase)
	_detail_decision = _wrapped("Decision —",12)
	page.add_child(_detail_decision)
	_detail_reason = _wrapped("",12,T.MUTED)
	page.add_child(_detail_reason)
	_detail_signal = _wrapped("",11,T.MUTED)
	page.add_child(_detail_signal)
	page.add_child(HSeparator.new())
	var grid := GridContainer.new()
	grid.columns = 3
	grid.add_theme_constant_override("h_separation",20)
	grid.add_theme_constant_override("v_separation",8)
	page.add_child(grid)
	for caption in ["APPROACH","QUEUED","MEAN WAIT"]: grid.add_child(T.label(caption,10,T.MUTED))
	for arm in ARMS:
		grid.add_child(T.label(arm.capitalize(),12))
		var queue := T.label("—",12)
		var wait := T.label("—",12)
		grid.add_child(queue)
		grid.add_child(wait)
		_approaches[arm] = {"queue":queue,"wait":wait}
	_detail_crossing = _wrapped("",11,T.MUTED)
	page.add_child(_detail_crossing)
	_detail_sample = _wrapped("No traffic sample yet",10,T.MUTED)
	page.add_child(_detail_sample)
	_wait_chart = preload("res://scripts/TrafficHistory.gd").new()
	_wait_chart.custom_minimum_size.y = 140
	page.add_child(_wait_chart)
	_queue_chart = preload("res://scripts/TrafficHistory.gd").new()
	_queue_chart.field = "queue"
	_queue_chart.caption = "Queued vehicles"
	_queue_chart.line_color = T.ORANGE
	_queue_chart.custom_minimum_size.y = 140
	page.add_child(_queue_chart)
	page.add_child(_wrapped("Up to 10 minutes of measured history · simulation time",10,T.MUTED))

func _build_scene(page: Control) -> void:
	page.add_child(_wrapped("Set the view",16))
	page.add_child(_wrapped("Lighting, weather and visibility for the 3D scene.",12,T.MUTED))
	_lbl_tod_time = T.label("12:00",24)
	page.add_child(_lbl_tod_time)
	_slider_tod = HSlider.new()
	_slider_tod.min_value = 0
	_slider_tod.max_value = 23.99
	_slider_tod.step = 0.05
	_slider_tod.value = 12
	_slider_tod.custom_minimum_size.y = 30
	_slider_tod.value_changed.connect(func(hour: float):
		if _tod_mode_idx == 0: time_of_day_changed.emit(hour))
	page.add_child(_slider_tod)
	page.add_child(T.label("SCENE CLOCK",10,T.MUTED))
	_tod_choice = _option(page)
	for label in ["Manual","Automatic day cycle","Follow simulation"]: _tod_choice.add_item(label)
	_tod_choice.item_selected.connect(func(index: int):
		_tod_mode_idx = index
		_slider_tod.editable = index == 0
		tod_mode_changed.emit(index))
	page.add_child(T.label("WEATHER",10,T.MUTED))
	_weather_choice = _option(page)
	for label in ["Clear","Overcast","Rain"]: _weather_choice.add_item(label)
	_weather_choice.item_selected.connect(func(index: int):
		_weather_idx = index
		weather_changed.emit(index))
	page.add_child(HSeparator.new())
	_ped_toggle = CheckBox.new()
	_ped_toggle.text = "Show pedestrians"
	_ped_toggle.button_pressed = true
	_ped_toggle.add_theme_color_override("font_color",T.TEXT)
	_ped_toggle.toggled.connect(func(enabled: bool): pedestrian_toggled.emit(enabled))
	page.add_child(_ped_toggle)
	page.add_child(_wrapped("Visibility only. Pedestrian demand and crossing protection remain active.",11,T.MUTED))
	page.add_child(HSeparator.new())
	page.add_child(_wrapped("H  Drone flight\nK  Sensor coverage\n0  Corridor overview\n1 / 2 / 3  Focus junction\n4  Airport · 5–8  Districts\nEsc  Exit drone, then return to lobby",12,T.MUTED))

func _build_controls(page: Control) -> void:
	page.add_child(T.label("SIGNAL CONTROL",10,T.MUTED))
	_mode_value = T.label("Waiting for server",16)
	page.add_child(_mode_value)
	_btn_mode_toggle = T.button("Waiting for live traffic")
	_btn_mode_toggle.pressed.connect(_request_mode)
	page.add_child(_btn_mode_toggle)
	page.add_child(_wrapped("The active mode changes only after the server confirms it.",11,T.MUTED))
	page.add_child(HSeparator.new())
	page.add_child(T.label("MANUAL REQUEST",10,T.MUTED))
	_selector(page)
	for item in [["Request N–S through","north"],["Request E–W through","east"]]:
		var approach: String = item[1]
		var button := T.button(item[0])
		button.pressed.connect(func(): _request_override(approach))
		page.add_child(button)
		_override_buttons.append(button)
	page.add_child(_wrapped("Requests use the normal signal transitions and crossing protection. The current phase appears under Traffic.",11,T.MUTED))
	_request_note = _wrapped("",12,T.ORANGE)
	page.add_child(_request_note)

func _build_alert() -> void:
	_alert = _panel(self)
	_alert.name = "TrafficNotice"
	_alert.visible = false
	_alert_text = _wrapped("",12,T.ORANGE)
	_alert.add_child(_alert_text)

func _layout() -> void:
	if not is_instance_valid(_top): return
	_top.position = Vector2(16,16)
	_top.size = Vector2(maxf(size.x-32,0),56)
	var dock_width := minf(size.x-32,710)
	_dock.position = Vector2((size.x-dock_width)*0.5,size.y-88)
	_dock.size = Vector2(dock_width,72)
	_drawer.position = Vector2(maxf(size.x-360,16),84)
	_drawer.size = Vector2(minf(344,size.x-32),maxf(140,size.y-188))
	_alert.position = Vector2(16,84)
	_alert.size = Vector2(minf(480,size.x-32-(_drawer.size.x+16 if _drawer.visible else 0)),0)
	var row: HBoxContainer = _top.get_child(0)
	row.add_theme_constant_override("separation",8 if size.x < 1000 else 16)

func toggle_page(page: String) -> void:
	_page = "" if _page == page else page
	_drawer.visible = not _page.is_empty()
	for key in _pages:
		_pages[key].visible = key == _page
		_nav[key].add_theme_color_override("font_color",T.ORANGE if key == _page else T.TEXT)
	_drawer_title.text = _page
	_layout()

func select_junction(jid: String) -> void:
	if jid not in JIDS: return
	selected_junction = jid
	for selector in _selectors: selector.select(JIDS.find(jid))
	_refresh_cards()
	_refresh_detail()

func update_display(data: Dictionary) -> void:
	var time = _number(data.get("sim_time"))
	if time != null and float(time) < _last_sim_time: reset_display()
	_data = data
	_complete = false
	_alert.hide()
	_last_packet_ms = _now_ms()
	if time != null:
		_last_sim_time = float(time)
		_lbl_sim_time.text = _clock(float(time))
	else: _lbl_sim_time.text = "—"
	_lbl_completed.text = _format(data.get("vehicles_completed"),false)
	_lbl_avg_wait.text = _format(data.get("corridor_avg_wait",data.get("avg_wait")),true)
	if data.has("control_mode"): update_control_mode(str(data.control_mode))
	for jid in JIDS:
		var junction: Dictionary = data.get("junctions",{}).get(jid,{})
		if time != null:
			var samples: Array = _history[jid]
			var sample := {"time":float(time),"wait":_number(junction.get("avg_wait")),"queue":_queue_total(junction.get("queues",{}))}
			if not samples.is_empty() and samples[-1].time == time: samples[-1] = sample
			else: samples.append(sample)
			while not samples.is_empty() and (samples[0].time < float(time)-600 or samples.size() > 600): samples.pop_front()
	_refresh_cards()
	_refresh_detail()
	_refresh_connection()

func _refresh_cards() -> void:
	for jid in JIDS:
		var card: Dictionary = _cards[jid]
		var junction: Dictionary = _data.get("junctions",{}).get(jid,{})
		var phase := _phase(str(junction.get("phase_name","")))
		card.details.text = phase+"  ·  "+_format(_queue_total(junction.get("queues",{})),false)+" queued"
		card.button.add_theme_stylebox_override("normal",T.surface(Color("27231f") if jid == selected_junction else Color("202020"),T.ORANGE if jid == selected_junction else T.BORDER,8))

func _refresh_detail() -> void:
	var junction: Dictionary = _data.get("junctions",{}).get(selected_junction,{})
	_detail_name.text = NAMES[JIDS.find(selected_junction)]
	var phase_name := str(junction.get("phase_name",""))
	_detail_phase.text = _phase(phase_name)+"  ·  "+_format(junction.get("phase_timer"),true)+" elapsed"
	_detail_decision.text = "Decision  ·  "+_phase(str(junction.get("ai_decision","")))
	var control: Dictionary = junction.get("control",{})
	var reason := str(control.get("reason",""))
	_detail_reason.text = REASONS.get(reason,"Fixed signal schedule" if _current_control_mode == "baseline" else "Decision reason unavailable")
	var blocked: Array = control.get("blocked_exits",[])
	if not blocked.is_empty(): _detail_reason.text += "\n%d blocked exits" % blocked.size()
	_detail_reason.tooltip_text = "Policy proposal: %s\nApplied action: %s" % [str(control.get("proposed_action","—")),str(junction.get("ai_decision","—"))]
	var aspects: Array[String] = []
	for arm in ARMS:
		var signal_value: String = str(junction.get("signals",{}).get(arm,{}).get("main","—"))
		aspects.append(arm.left(1).to_upper()+" "+signal_value)
	_detail_signal.text = "Actual signals  ·  "+" / ".join(aspects)
	for arm in ARMS:
		_approaches[arm].queue.text = _format(junction.get("queues",{}).get(arm),false)
		_approaches[arm].wait.text = _format(junction.get("wait_times",{}).get(arm),true)
	var walks: Dictionary = junction.get("crossing_green",{})
	var walk_arms: Array[String] = []
	for arm in ARMS:
		if walks.get(arm,false): walk_arms.append(arm.left(1).to_upper())
	_detail_crossing.text = "Crossing WALK  ·  "+(" / ".join(walk_arms) if not walk_arms.is_empty() else ("None" if walks.size() == 4 else "—"))
	_detail_sample.text = "Sample "+(_clock(_last_sim_time) if _last_sim_time >= 0 else "—")+" · "+("Live snapshot" if _is_fresh() else "Last received snapshot")
	_wait_chart.set_samples(_history[selected_junction])
	_queue_chart.set_samples(_history[selected_junction])

func _request_mode() -> void:
	if not _is_fresh() or not _pending_mode.is_empty(): return
	_pending_mode = "baseline" if _current_control_mode == "ai" else "ai"
	_pending_ms = _now_ms()
	mode_switch_requested.emit(_pending_mode)
	_refresh_controls()

func _request_override(approach: String) -> void:
	if not _is_fresh(): return
	override_requested.emit(selected_junction,approach)
	_request_note.text = "Request sent to %s. Check Traffic for the applied phase." % selected_junction

func update_control_mode(mode: String) -> void:
	_current_control_mode = mode
	if mode == _pending_mode: _pending_mode = ""
	var copy: String = {"ai":"Adaptive AI","baseline":"Fixed timer","manual":"Manual","demo":"Demo"}.get(mode,"Waiting")
	_lbl_mode.text = copy
	_mode_value.text = copy
	_refresh_controls()

func _refresh_controls() -> void:
	_btn_mode_toggle.disabled = not _is_fresh() or not _pending_mode.is_empty()
	_btn_mode_toggle.text = "Awaiting confirmation…" if not _pending_mode.is_empty() else ("Switch to fixed timer" if _current_control_mode == "ai" else "Switch to adaptive AI")
	for button in _override_buttons: button.disabled = not _is_fresh()

func _process(delta: float) -> void:
	_pulse_elapsed += delta
	if _pulse_elapsed < 0.5: return
	_pulse_elapsed = 0
	if not _pending_mode.is_empty() and _now_ms()-_pending_ms > 10000:
		_pending_mode = ""
		_request_note.text = "Mode change was not confirmed. Check the connection and retry."
	_refresh_connection()

func _is_fresh() -> bool:
	return _connected and not _complete and _last_packet_ms >= 0 and _now_ms()-_last_packet_ms < 15000

func _refresh_connection() -> void:
	if _complete: _lbl_connection.text = "Complete"
	elif not _connected: _lbl_connection.text = "Reconnecting"
	elif _last_packet_ms < 0: _lbl_connection.text = "Waiting for data"
	elif not _is_fresh(): _lbl_connection.text = "Data delayed"
	else: _lbl_connection.text = "Live"
	_lbl_connection.add_theme_color_override("font_color",T.TEXT if _is_fresh() or _complete else T.ORANGE)
	_top.tooltip_text = "Live traffic sample" if _is_fresh() else "Values show the last received traffic sample; commands wait for fresh data."
	_refresh_controls()
	_detail_sample.text = "Sample "+(_clock(_last_sim_time) if _last_sim_time >= 0 else "—")+" · "+("Live snapshot" if _is_fresh() else "Last received snapshot")

func set_connection_status(connected: bool) -> void:
	_connected = connected
	_refresh_connection()

func update_time_display(hour: float) -> void:
	_slider_tod.set_value_no_signal(hour)
	_lbl_tod_time.text = "%02d:%02d" % [int(hour)%24,int(fmod(hour,1)*60)]

func set_traffic_status(message: String) -> void:
	_lbl_connection.text = "Starting"
	_notice(message)

func show_simulation_error(message: String) -> void:
	_connected = false
	_notice("Traffic unavailable. Return to the lobby with Esc to view the server log.")
	_alert_text.tooltip_text = message
	_refresh_connection()

func show_server_mismatch(server_type: String) -> void:
	_connected = false
	_notice("Expected the corridor server; received "+server_type+". Return to the lobby with Esc.")
	_refresh_connection()

func show_completion(data: Dictionary) -> void:
	_complete = true
	_lbl_completed.text = _format(data.get("total_arrived",data.get("vehicles_completed")),false)
	_notice("Run complete · "+_lbl_completed.text+" trips completed")
	_refresh_connection()

func reset_charts() -> void:
	for jid in JIDS: _history[jid] = []
	_wait_chart.set_samples([])
	_queue_chart.set_samples([])

func reset_display() -> void:
	_data = {}
	_last_sim_time = -1
	_last_packet_ms = -1
	_complete = false
	_pending_mode = ""
	_current_control_mode = ""
	_request_note.text = ""
	_alert.hide()
	for label in [_lbl_sim_time,_lbl_completed,_lbl_avg_wait]: label.text = "—"
	reset_charts()
	update_control_mode("")
	_refresh_cards()
	_refresh_detail()
	_refresh_connection()

func _notice(copy: String) -> void:
	_alert_text.text = copy
	_alert.show()
	_layout()

func dismiss_panel() -> bool:
	if _page.is_empty(): return false
	toggle_page(_page)
	return true

func _number(value: Variant) -> Variant:
	if value is int or value is float:
		if is_finite(float(value)) and float(value) >= 0: return float(value)
	return null

func _format(value: Variant, seconds: bool) -> String:
	var number = _number(value)
	if number == null: return "—"
	return "%.1fs" % float(number) if seconds else "%d" % int(number)

func _queue_total(queues: Dictionary) -> Variant:
	var total := 0.0
	for arm in ARMS:
		var number = _number(queues.get(arm))
		if number == null: return null
		total += float(number)
	return total

func _phase(value: String) -> String:
	return {"NS_THROUGH":"N–S through","EW_THROUGH":"E–W through","NS_LEFT":"N–S left","EW_LEFT":"E–W left","NS_YELLOW":"N–S clearing","EW_YELLOW":"E–W clearing","HOLD":"Hold","ALL_RED":"All red"}.get(value,value.replace("_"," ").capitalize() if not value.is_empty() else "—")

func _clock(seconds: float) -> String:
	return "%02d:%02d:%02d" % [int(seconds)/3600,(int(seconds)%3600)/60,int(seconds)%60]

func _panel(parent: Node) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel",T.surface())
	parent.add_child(panel)
	return panel
func _stack(gap: int) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation",gap)
	return box
func _row(gap: int) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation",gap)
	return box
func _space(parent: Control) -> void:
	var item := Control.new()
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(item)
func _wrapped(copy: String, font_size: int, color: Color = T.TEXT) -> Label:
	var label := T.label(copy,font_size,color)
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label
func _option(parent: Control) -> OptionButton:
	var choice := OptionButton.new()
	choice.custom_minimum_size.y = 34
	choice.add_theme_stylebox_override("normal",T.surface(Color("252525"),T.BORDER,8))
	choice.add_theme_stylebox_override("hover",T.surface(Color("303030"),T.ORANGE,8))
	choice.add_theme_color_override("font_color",T.TEXT)
	parent.add_child(choice)
	return choice

func _now_ms() -> int:
	return Time.get_ticks_msec()
