extends CanvasLayer
## Lightweight flight instruments shared by both simulation scenes.
## No input is consumed: Tab can release the cursor for the existing controls.

const INK := Color("e8f3f0")
const MUTED := Color("a5b9b4")
const ACCENT := Color("7ee6b7")
const AMBER := Color("f0c27c")

var _mode: Label
var _status: Label
var _speed: Label
var _altitude: Label
var _view: Label
var _map_title: Label
var _compass: FlightCompass
var _map: FlightMap
var _ui_root: Control
var _flight_panels: Array[Control] = []
var _paused_banner: PanelContainer
var _latest: Dictionary = {}
var _last_update_ms: int = -1000

func _ready() -> void:
	layer = 15
	_ui_root = Control.new()
	_ui_root.name = "FlightOverlay"
	_ui_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_ui_root)
	_build_compass()
	_build_map()
	_build_instruments()
	_build_paused_banner()
	visible = false

func update_flight(data: Dictionary) -> void:
	_latest = data
	# Instruments need not rebuild text at the 3D render rate.
	var now: int = Time.get_ticks_msec()
	if now - _last_update_ms < 80:
		return
	_last_update_ms = now
	if not is_instance_valid(_mode):
		return
	_mode.text = "DRONE  /  " + str(data.get("mode", "CRUISE"))
	_speed.text = "SPEED  %04.1f u/s" % float(data.get("speed", 0.0))
	_altitude.text = "HEIGHT  %04.1f u" % float(data.get("altitude", 0.0))
	_view.text = "%s  ·  %d°" % [str(data.get("view", "CHASE")), roundi(float(data.get("zoom", 72.0)))]
	var paused: bool = bool(data.get("paused", false))
	var obstacle: bool = bool(data.get("obstacle", false))
	for panel in _flight_panels:
		panel.visible = not paused
	_paused_banner.visible = paused
	_status.text = "HOVERING · Tab to fly" if paused else ("OBSTACLE · steer clear" if obstacle else "FLIGHT READY")
	_status.add_theme_color_override("font_color", AMBER if paused or obstacle else ACCENT)
	_compass.heading = fposmod(float(data.get("heading", 0.0)), 360.0)
	_compass.queue_redraw()
	_map.flight_position = data.get("position", Vector3.ZERO)
	_map.home_position = data.get("home", Vector3.ZERO)
	_map.heading = _compass.heading
	_map.corridor = bool(data.get("corridor", false))
	_map.queue_redraw()
	_map_title.text = "CORRIDOR   /   N ↑" if _map.corridor else "JUNCTION   /   N ↑"

func _panel(parent: Control) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.067, 0.068, 0.91)
	style.border_color = Color(0.38, 0.61, 0.55, 0.48)
	style.set_border_width_all(1)
	style.set_corner_radius_all(10)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	panel.add_theme_stylebox_override("panel", style)
	parent.add_child(panel)
	return panel

func _label(text: String, font_size: int, color: Color = INK) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

func _build_compass() -> void:
	var panel := _panel(_ui_root)
	_flight_panels.append(panel)
	panel.name = "FlightHeading"
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.offset_left = -172
	panel.offset_right = 172
	panel.offset_top = 65
	panel.offset_bottom = 137
	_compass = FlightCompass.new()
	_compass.custom_minimum_size = Vector2(310, 50)
	_compass.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(_compass)

func _build_map() -> void:
	var panel := _panel(_ui_root)
	_flight_panels.append(panel)
	panel.name = "FlightMapPanel"
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -214
	panel.offset_right = -20
	panel.offset_top = 65
	panel.offset_bottom = 272
	var rows := VBoxContainer.new()
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_theme_constant_override("separation", 7)
	panel.add_child(rows)
	_map_title = _label("JUNCTION   /   N ↑", 11, MUTED)
	rows.add_child(_map_title)
	_map = FlightMap.new()
	_map.custom_minimum_size = Vector2(164, 150)
	_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(_map)
	var legend := _label("▲ YOU      ◇ HOME", 10, MUTED)
	rows.add_child(legend)

func _build_instruments() -> void:
	var panel := _panel(_ui_root)
	_flight_panels.append(panel)
	panel.name = "FlightInstruments"
	panel.anchor_left = 0.5
	panel.anchor_right = 0.5
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_left = -376
	panel.offset_right = 376
	panel.offset_top = -156
	panel.offset_bottom = -26
	var rows := VBoxContainer.new()
	rows.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_theme_constant_override("separation", 7)
	panel.add_child(rows)
	var title := HBoxContainer.new()
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(title)
	_mode = _label("DRONE  /  CRUISE", 12, ACCENT)
	_mode.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_child(_mode)
	_status = _label("FLIGHT READY", 11, ACCENT)
	title.add_child(_status)
	var stats := HBoxContainer.new()
	stats.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rows.add_child(stats)
	_speed = _label("SPEED  00.0 u/s", 17)
	_altitude = _label("HEIGHT  18.0 u", 17)
	_view = _label("CHASE  ·  72°", 17)
	for item: Label in [_speed, _altitude, _view]:
		item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		stats.add_child(item)
	var divider := HSeparator.new()
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	divider.modulate = Color(0.48, 0.68, 0.62, 0.5)
	rows.add_child(divider)
	var help := _label("WASD fly   ·   Space/Ctrl up/down   ·   Shift boost   ·   1/2/3 speed\nF camera   ·   Wheel zoom   ·   X brake   ·   R home   ·   Tab cursor   ·   H/Esc exit", 12, MUTED)
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	help.add_theme_constant_override("line_spacing", 5)
	rows.add_child(help)

func _build_paused_banner() -> void:
	_paused_banner = _panel(_ui_root)
	_paused_banner.name = "DroneHoverNotice"
	_paused_banner.anchor_left = 0.5
	_paused_banner.anchor_right = 0.5
	_paused_banner.offset_left = -188
	_paused_banner.offset_right = 188
	_paused_banner.offset_top = 55
	_paused_banner.offset_bottom = 92
	var label := _label("DRONE HOVERING  ·  Tab to resume flight", 12, AMBER)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_paused_banner.add_child(label)
	_paused_banner.visible = false

class FlightCompass extends Control:
	var heading: float = 0.0
	func _draw() -> void:
		var font: Font = ThemeDB.fallback_font
		var center: float = size.x * 0.5
		var pixels_per_degree: float = size.x / 130.0
		for tick in range(-12, 13):
			var degree: float = floorf(heading / 10.0) * 10.0 + tick * 10.0
			var x: float = center + (degree - heading) * pixels_per_degree
			if x < 4 or x > size.x - 4:
				continue
			var major: bool = posmod(roundi(degree), 30) == 0
			draw_line(Vector2(x, 37), Vector2(x, 42 if major else 40), Color("70958b"), 1.0)
			if major:
				var cardinal: String = ""
				match posmod(roundi(degree), 360):
					0: cardinal = "N"
					90: cardinal = "E"
					180: cardinal = "S"
					270: cardinal = "W"
				var caption: String = cardinal if not cardinal.is_empty() else str(posmod(roundi(degree), 360))
				var width: float = font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
				draw_string(font, Vector2(x - width * 0.5, 32), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("a5b9b4"))
		var reading := "%03d°" % posmod(roundi(heading), 360)
		var reading_width: float = font.get_string_size(reading, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		draw_style_box(_reading_plate(), Rect2(center - 27, -1, 54, 20))
		draw_string(font, Vector2(center - reading_width * 0.5, 14), reading, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("e8f3f0"))
		draw_colored_polygon(PackedVector2Array([Vector2(center - 4, 49), Vector2(center, 43), Vector2(center + 4, 49)]), Color("7ee6b7"))
	func _reading_plate() -> StyleBoxFlat:
		var plate := StyleBoxFlat.new()
		plate.bg_color = Color("132a28")
		plate.set_corner_radius_all(3)
		return plate

class FlightMap extends Control:
	var flight_position := Vector3.ZERO
	var home_position := Vector3.ZERO
	var heading: float = 0.0
	var corridor: bool = false
	func _point(at: Vector3) -> Vector2:
		# World X is mirrored by the simulation: east is negative X.
		var scale: float = minf(size.x, size.y) / (220.0 if not corridor else 196.0)
		var midpoint: float = 30.0 if corridor else 0.0
		return size * 0.5 + Vector2(-at.x, midpoint - at.z) * scale
	func _road(a: Vector3, b: Vector3, width: float) -> void:
		var scale: float = minf(size.x, size.y) / (220.0 if not corridor else 196.0)
		draw_line(_point(a), _point(b), Color("68827b"), maxf(width * scale, 2.0), true)
	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color("0a1719"))
		for n in range(1, 5):
			var line_x: float = size.x * n / 5.0
			var line_y: float = size.y * n / 5.0
			draw_line(Vector2(line_x, 0), Vector2(line_x, size.y), Color(0.24, 0.36, 0.33, 0.22))
			draw_line(Vector2(0, line_y), Vector2(size.x, line_y), Color(0.24, 0.36, 0.33, 0.22))
		if corridor:
			_road(Vector3(0, 0, -58), Vector3(0, 0, 118), 6.0)
			for z in [0.0, 30.0, 60.0]:
				_road(Vector3(-58, 0, z), Vector3(58, 0, z), 5.0)
		else:
			_road(Vector3(0, 0, -93.5), Vector3(0, 0, 93.5), 6.4)
			_road(Vector3(-93.5, 0, 0), Vector3(93.5, 0, 0), 6.4)
		var home: Vector2 = _point(home_position).clamp(Vector2(7, 7), size - Vector2(7, 7))
		var pilot: Vector2 = _point(flight_position).clamp(Vector2(7, 7), size - Vector2(7, 7))
		draw_line(home, pilot, Color(0.49, 0.9, 0.72, 0.3), 1.0, true)
		var diamond := PackedVector2Array([home + Vector2(0, -4), home + Vector2(4, 0), home + Vector2(0, 4), home + Vector2(-4, 0), home + Vector2(0, -4)])
		draw_polyline(diamond, Color("e4d3a9"), 1.4, true)
		var angle: float = deg_to_rad(heading)
		var triangle := PackedVector2Array()
		for point: Vector2 in [Vector2(0, -7), Vector2(5, 5), Vector2(0, 2), Vector2(-5, 5)]:
			triangle.append(pilot + point.rotated(angle))
		draw_colored_polygon(triangle, Color("7ee6b7"))
