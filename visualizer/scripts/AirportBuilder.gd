extends Node3D
## Accra-inspired airport precinct, compressed for the traffic visualizer.
const G = preload("res://scripts/PropGeometry.gd")
const M = preload("res://scripts/StreetscapeMaterials.gd")
const Layout = preload("res://scripts/AirportLayout.gd")
const Aircraft = preload("res://scripts/AircraftModel.gd")
const Fleet = preload("res://scripts/VehicleActor.gd")
var obstacles: Array[Rect2] = []
var aircraft: Array[Node3D] = []
var _parts: Node3D
var _lamps: Array[OmniLight3D] = []
var _night_materials: Array[StandardMaterial3D] = []
var _windsock: Node3D
var _beacon: StandardMaterial3D
var _elapsed: float = 0.0
var _clock: Node
var _weather: Node
var _lit: bool = false
var _stone := M.surface(0, Color("b6b7a8"))
var _roof := M.solid(Color("afb6b1"), 0.45, 0.38)
var _glass := M.solid(Color("345760"), 0.60, 0.18)
var _frame := M.solid(Color("6e7e80"), 0.65, 0.3)
var _asphalt := M.surface(1, Color("3c4140"))
var _concrete := M.surface(2, Color("9f9d8f"))
var _white := M.solid(Color("deded1"), 0.0, 0.85)
var _yellow := M.solid(Color("c9a642"), 0.0, 0.85)

func _ready() -> void:
	position = Layout.ORIGIN
	_parts = Node3D.new()
	add_child(_parts)
	_build_airfield()
	_build_terminal()
	_build_tower()
	_build_hangar()
	_build_landside()
	_build_windsock()
	for i in range(2):
		var z: float = 32.0 + i * 22.0
		var jet := Aircraft.new()
		jet.name = "ParkedAirliner%d" % (i + 1)
		jet.position = Vector3(43.5, 0.10, z)
		jet.rotation.y = -PI * 0.5
		add_child(jet)
		aircraft.append(jet)
		_build_jetbridge(z + 2.25)
		_line(Vector3(32, 0.15, z), Vector3(49.0, 0.15, z), 0.07, _yellow)
		_line(Vector3(48.8, 0.15, z - 1.4), Vector3(48.8, 0.15, z + 1.4), 0.10, _yellow)
		_ground_label("A%d" % (i + 1), Vector3(32.0, 0.16, z), 1.2, 0.6, Color("d9b74f"), -PI * 0.5)
		_service_vehicle(Vector3(38.0, 0.12, z + 7.0), false)
		for cart in range(3):
			_baggage_cart(Vector3(40.0 + cart * 1.45, 0.12, z + 7.0))
	_service_vehicle(Vector3(49.0, 0.12, 72.0), true)
	_bake()
	_clock = get_parent().get_parent().get_node_or_null("TimeOfDayManager")
	_weather = get_parent().get_parent().get_node_or_null("WeatherManager")
	print("[Airport] Runway, taxiway, two serviced stands, terminal, tower and landside precinct")

func _box(at: Vector3, size: Vector3, material: Material, solid: bool = false) -> void:
	G.box(_parts, at, size, material)
	if solid:
		var body := StaticBody3D.new()
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = size
		collision.shape = shape
		body.position = at
		body.add_child(collision)
		add_child(body)
		obstacles.append(Rect2(at.x - size.x * 0.5, at.z - size.z * 0.5, size.x, size.z))

func _line(a: Vector3, b: Vector3, width: float, material: Material) -> void:
	var offset := b - a
	var strip := G.box(_parts, (a + b) * 0.5, Vector3(width, 0.012, offset.length()), material, "PavementMarking")
	strip.rotation.y = atan2(offset.x, offset.z)

func _ground_label(text: String, at: Vector3, width: float, height: float, color: Color, yaw: float = 0.0) -> void:
	var sign := G.label(self, text, at, width, height, color, "GroundMarking")
	sign.rotation = Vector3(-PI * 0.5, yaw, 0)
	sign.shaded = false

func _build_airfield() -> void:
	_box(Vector3(48, -0.02, 71), Vector3(96, 0.08, 142), M.surface(7, Color("7c856c")))
	# Graded shoulders and a long, slender runway replace the short slab.
	_box(Vector3(14, 0.018, 64), Vector3(13.5, 0.055, 124), M.surface(10, Color("8f9179")))
	_box(Vector3(14, 0.065, 64), Vector3(8, 0.10, 116), _asphalt)
	for x in [10.15, 17.85]:
		_line(Vector3(x, 0.124, 7), Vector3(x, 0.124, 121), 0.10, _white)
	for z in range(22, 110, 7):
		_line(Vector3(14, 0.126, z), Vector3(14, 0.126, z + 3.2), 0.16, _white)
	for end in [0, 1]:
		var near: float = 8.0 if end == 0 else 120.0
		var direction: float = 1.0 if end == 0 else -1.0
		for x in [11.0, 11.7, 12.4, 15.6, 16.3, 17.0]:
			_box(Vector3(x, 0.129, near + direction * 2), Vector3(0.42, 0.014, 4), _white)
		_ground_label("36" if end == 0 else "18", Vector3(14, 0.15, near + direction * 8), 2.0, 2.8, Color("e4e5dc"), 0.0 if end == 0 else PI)
		for x in [11.5, 16.5]:
			_box(Vector3(x, 0.13, near + direction * 18), Vector3(0.8, 0.014, 4.8), _white)
		# Rubber deposits are concentrated around the touchdown zone.
		for track in range(9):
			var x: float = 12.6 + track * 0.34
			_line(Vector3(x, 0.139, near + direction * 22), Vector3(x, 0.139, near + direction * (31 + track % 3)), 0.10, M.solid(Color("303637")))
	_box(Vector3(26, 0.065, 65), Vector3(3.6, 0.10, 104), _asphalt)
	_line(Vector3(26, 0.13, 13), Vector3(26, 0.13, 117), 0.08, _yellow)
	for z in [20.0, 110.0]:
		_box(Vector3(20, 0.06, z), Vector3(12, 0.1, 4.0), _asphalt)
		_line(Vector3(14, 0.132, z), Vector3(26, 0.132, z), 0.08, _yellow)
		for offset in [-0.22, 0.22]:
			_line(Vector3(20.5 + offset, 0.14, z - 1.5), Vector3(20.5 + offset, 0.14, z + 1.5), 0.07, _yellow)
		_airfield_sign(Vector3(23, 0, z - 3), "A  |  18–36")
	_box(Vector3(42, 0.065, 48), Vector3(26, 0.1, 68), _concrete)
	for z in [25.0, 73.0]:
		_box(Vector3(28.5, 0.064, z), Vector3(7, 0.1, 3.6), _asphalt)
		_line(Vector3(26, 0.13, z), Vector3(33, 0.13, z), 0.08, _yellow)
	# Stand safety borders and a service lane behind the parked aircraft.
	for z in [22.0, 42.0, 44.0, 64.0]:
		_line(Vector3(34, 0.135, z), Vector3(51, 0.135, z), 0.055, M.solid(Color("b36a52")))
	for z in range(17, 80, 4):
		_line(Vector3(52.7, 0.136, z), Vector3(52.7, 0.136, z + 2), 0.08, _white)
	var edge := _light_material(Color("dbe9df"))
	var blue := _light_material(Color("456dcc"))
	var green := _light_material(Color("46b68b"))
	var red := _light_material(Color("ce4e3e"))
	for z in range(7, 123, 6):
		for x in [9.65, 18.35]:
			_fixture(Vector3(x, 0, z), edge)
		for x in [23.9, 28.1]:
			_fixture(Vector3(x, 0, z), blue)
	for x in range(11, 18):
		_fixture(Vector3(x, 0, 6), green)
		_fixture(Vector3(x, 0, 122), red)
	for z in [-2.0, 1.0, 4.0, 125.0, 128.0, 131.0]:
		_fixture(Vector3(14, 0, z), edge)
	# Perimeter stays outside the runway strip and beyond the terminal access.
	for x in [3.0, 93.0]:
		for z in range(2, 139, 5):
			G.segment(_parts, Vector3(x, 0, z), Vector3(x, 1.5, z), 0.045, _frame, "FencePost")
		for y in [0.45, 1.05, 1.5]:
			G.segment(_parts, Vector3(x, y, 2), Vector3(x, y, 138), 0.015, _frame, "PerimeterWire")

func _build_terminal() -> void:
	_box(Vector3(59, 3.0, 43), Vector3(8, 6, 40), _stone, true)
	for side in [-1.0, 1.0]:
		var x: float = 59 + side * 4.03
		for z in range(24, 63, 2):
			_box(Vector3(x, 3.0, z), Vector3(0.05, 4.85, 1.82), _glass)
			_box(Vector3(x + side * 0.09, 3, z - 0.95), Vector3(0.13, 5.7, 0.11), _frame)
		for y in [0.5, 2.8, 5.45]:
			_box(Vector3(x + side * 0.08, y, 43), Vector3(0.13, 0.11, 40), _frame)
	# Broad curved roof with projecting eaves and exposed ribs.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(16):
		var x0: float = 52.5 + i * 0.8
		var x1: float = x0 + 0.8
		var y0: float = 6.0 + sin(i * PI / 16.0) * 1.2
		var y1: float = 6.0 + sin((i + 1) * PI / 16.0) * 1.2
		G.triangle(st, Vector3(x0, y0, 21.5), Vector3(x0, y0, 64.5), Vector3(x1, y1, 21.5))
		G.triangle(st, Vector3(x1, y1, 21.5), Vector3(x0, y0, 64.5), Vector3(x1, y1, 64.5))
		G.triangle(st, Vector3(x1, y1 - 0.18, 21.5), Vector3(x0, y0 - 0.18, 64.5), Vector3(x0, y0 - 0.18, 21.5))
		G.triangle(st, Vector3(x1, y1 - 0.18, 64.5), Vector3(x0, y0 - 0.18, 64.5), Vector3(x1, y1 - 0.18, 21.5))
		for edge_z in [21.5, 64.5]:
			G.segment(_parts, Vector3(x0, y0 - 0.08, edge_z), Vector3(x1, y1 - 0.08, edge_z), 0.10, _roof, "RoofFascia")
		G.segment(_parts, Vector3(x0, y0 + 0.04, 21.5), Vector3(x0, y0 + 0.04, 64.5), 0.025, _frame, "RoofSeam")
	st.index() # Batching with indexed primitives must retain the custom roof faces.
	G.instance(_parts, st.commit(), Vector3.ZERO, _roof, "CurvedTerminalRoof")
	var sign := G.label(self, "ACCRA INTERNATIONAL", Vector3(54.8, 5.65, 43), 20.0, 0.68, Color("d7b565"), "AirportName")
	sign.rotation.y = -PI * 0.5
	sign.shaded = false
	var terminal := G.label(self, "TERMINAL 3", Vector3(63.15, 5.0, 43), 7, 0.65, Color("eee5cf"), "TerminalIdentity")
	terminal.rotation.y = PI * 0.5
	terminal.shaded = false
	for z in range(25, 64, 6):
		_box(Vector3(65.5, 3.0, z), Vector3(5.2, 0.14, 5.7), _roof)
		G.segment(_parts, Vector3(67.5, 0, z), Vector3(67.5, 3.0, z), 0.065, _frame, "CanopyColumn")
	# Narrow sunshade fins add depth to the glazing and cast real afternoon shadows.
	for z in range(24, 63, 2):
		_box(Vector3(54.7, 4.0, z - 0.95), Vector3(0.75, 2.7, 0.08), _roof)
	for z in [32.0, 54.0]:
		var door_light := _light_material(Color("d2dfd7"))
		_box(Vector3(63.12, 1.4, z), Vector3(0.08, 2.3, 2.4), door_light)
	for at in [Vector3(31, 0, 17), Vector3(53, 0, 79), Vector3(69, 0, 64), Vector3(31, 0, 45), Vector3(53, 0, 21), Vector3(53, 0, 66)]:
		_floodlight(at)

func _build_jetbridge(z: float) -> void:
	# The bridge runs beside the nose; its short elbow meets the port entry door.
	_box(Vector3(51.6, 1.7, z), Vector3(6.8, 1.3, 1.2), _stone, true)
	for side in [-1.0, 1.0]:
		_box(Vector3(51.6, 1.8, z + side * 0.61), Vector3(6.4, 0.72, 0.03), _glass)
		for x in range(49, 55):
			_box(Vector3(x, 1.8, z + side * 0.64), Vector3(0.05, 0.85, 0.06), _frame)
	_box(Vector3(47.9, 1.7, z - 0.55), Vector3(1.4, 1.3, 2.0), _stone, true)
	_box(Vector3(47.9, 1.65, z - 1.52), Vector3(1.25, 1.25, 0.42), M.solid(Color("354444")))
	for offset in [1.36, 1.48, 1.60]:
		_box(Vector3(47.9, 1.65, z - offset), Vector3(1.35, 1.33, 0.045), _frame)
	G.segment(_parts, Vector3(49, 0.2, z), Vector3(49, 1.05, z), 0.15, _frame, "BridgeColumn")
	for side in [-1.0, 1.0]:
		G.segment(_parts, Vector3(48.8, 0.28, z + side * 0.45), Vector3(49.2, 0.28, z + side * 0.45), 0.27, M.solid(Color("263333")), "BridgeWheel")

func _build_tower() -> void:
	var center := Vector3(73, 0, 14)
	_box(center + Vector3(0, 1.4, 0), Vector3(7, 2.8, 7), _stone, true)
	_box(center + Vector3(0, 7, 0), Vector3(2.9, 14, 3.2), _stone, true)
	for y in range(4, 13, 3):
		_box(center + Vector3(-1.46, y, 0), Vector3(0.04, 1.5, 1.7), _glass)
	G.segment(_parts, center + Vector3(0, 13.5, 0), center + Vector3(0, 16.2, 0), 2.4, _glass, "TowerCab", 1.15)
	for i in range(12):
		var a: float = i * TAU / 12.0
		G.segment(_parts, center + Vector3(cos(a) * 2.4, 13.5, sin(a) * 2.4), center + Vector3(cos(a) * 2.76, 16.2, sin(a) * 2.76), 0.045, _frame, "CabMullion")
	G.segment(_parts, center + Vector3(0, 13.3, 0), center + Vector3(0, 13.5, 0), 2.8, _roof, "TowerGallery")
	G.segment(_parts, center + Vector3(0, 16.2, 0), center + Vector3(0, 16.5, 0), 3.0, _roof, "TowerRoof")
	G.segment(_parts, center + Vector3(0, 16.5, 0), center + Vector3(0, 19, 0), 0.035, _frame, "Antenna")
	_beacon = _light_material(Color("d25b4e"))
	G.ellipsoid(_parts, center + Vector3(0, 17, 0), Vector3(0.22, 0.26, 0.22), _beacon, "ObstructionBeacon")

func _build_hangar() -> void:
	_box(Vector3(67, 3.3, 104), Vector3(13, 6.6, 19), _stone, true)
	_box(Vector3(67, 6.72, 104), Vector3(14, 0.24, 20), _roof)
	for z in range(96, 113, 2):
		_box(Vector3(60.45, 3, z), Vector3(0.12, 5.5, 1.87), M.surface(4, Color("6a7e7f")))
		_box(Vector3(60.3, 3, z - 0.95), Vector3(0.18, 6, 0.05), _frame)
	var sign := G.label(self, "AIRCRAFT SERVICES", Vector3(60.2, 6.0, 104), 12, 0.55, Color("dce4db"))
	sign.rotation.y = -PI * 0.5
	_box(Vector3(53.5, 0.06, 104), Vector3(13, 0.1, 22), _concrete)
	_box(Vector3(39, 0.065, 104), Vector3(24, 0.1, 4), _asphalt)
	_line(Vector3(26, 0.13, 104), Vector3(53, 0.13, 104), 0.08, _yellow)

func _build_landside() -> void:
	_box(Vector3(75, 0.04, 44), Vector3(9.0, 0.08, 65), _asphalt)
	_box(Vector3(80.0, 0.06, 44), Vector3(1.0, 0.1, 65), _concrete)
	_box(Vector3(68.5, 0.06, 43), Vector3(3.0, 0.1, 44), _concrete)
	# Extend the east end of the cross street into the terminal access road.
	_box(Vector3(56.5, 0.04, -10), Vector3(40, 0.08, 7), _asphalt)
	for x in range(39, 75, 5):
		_line(Vector3(x, 0.095, -10), Vector3(x + 2.5, 0.095, -10), 0.09, _white)
	_box(Vector3(75, 0.04, 1), Vector3(7.0, 0.08, 22), _asphalt)
	for z in range(-8, 74, 5):
		_line(Vector3(75, 0.095, z), Vector3(75, 0.095, z + 2.5), 0.09, _white)
	_box(Vector3(86, 0.045, 43), Vector3(11, 0.08, 43), _asphalt)
	for row in range(12):
		var z: float = 23 + row * 3.2
		for x in [83.0, 88.0]:
			_line(Vector3(x - 1.4, 0.10, z), Vector3(x + 1.4, 0.10, z), 0.06, _white)
			if row % 3 != 0:
				var car := Fleet.new()
				car.configure("car", row)
				car.position = Vector3(x, 0.10, z + 1.4)
				car.rotation.y = PI * 0.5
				add_child(car)
	for z in [26.0, 46.0, 61.0]:
		_floodlight(Vector3(80, 0, z))
		for i in range(6):
			_box(Vector3(69.7 + i * 1.35, 0.12, z), Vector3(0.75, 0.015, 2), _white)
	_airfield_sign(Vector3(80, 0, 10), "P  /  ARRIVALS")

func _service_vehicle(at: Vector3, tanker: bool) -> void:
	var parent := Node3D.new()
	parent.position = at
	add_child(parent)
	G.rounded_box(parent, Vector3(-0.55, 0.55, 0), Vector3(0.9, 0.9, 0.8), 0.12, _white, "ServiceCab")
	G.box(parent, Vector3(-0.55, 0.74, -0.42), Vector3(0.70, 0.34, 0.025), _glass, "CabGlass")
	G.box(parent, Vector3(0.25, 0.28, 0), Vector3(2.7, 0.23, 0.9), _frame, "VehicleChassis")
	if tanker:
		G.segment(parent, Vector3(0, 0.95, 0), Vector3(1.5, 0.95, 0), 0.50, _metal_material(), "FuelTank")
	else:
		G.rounded_box(parent, Vector3(0.3, 0.48, 0), Vector3(1.5, 0.35, 0.9), 0.08, _yellow, "ElectricTug")
	for x in [-0.65, 1.1]:
		for z in [-0.5, 0.5]:
			G.segment(parent, Vector3(x, 0.2, z - 0.09), Vector3(x, 0.2, z + 0.09), 0.20, M.solid(Color("263033")), "ServiceTyre")

func _baggage_cart(at: Vector3) -> void:
	_box(at + Vector3(0, 0.35, 0), Vector3(1.15, 0.12, 0.85), _frame)
	_box(at + Vector3(0, 0.65, 0), Vector3(0.96, 0.5, 0.66), M.solid(Color("557079")))
	for x in [-0.4, 0.4]:
		for z in [-0.42, 0.42]:
			G.segment(_parts, at + Vector3(x, 0.18, z - 0.06), at + Vector3(x, 0.18, z + 0.06), 0.14, M.solid(Color("253033")), "CartWheel")
	G.segment(_parts, at + Vector3(-0.55, 0.28, 0), at + Vector3(-0.9, 0.28, 0), 0.035, _frame, "TowBar")

func _metal_material() -> Material:
	return M.solid(Color("a5afac"), 0.75, 0.3)

func _airfield_sign(at: Vector3, text: String) -> void:
	_box(at + Vector3(0, 0.45, 0), Vector3(2.4, 0.65, 0.12), M.solid(Color("252e29")))
	G.label(self, text, at + Vector3(0, 0.45, 0.075), 2.15, 0.30, Color("e3c45e"), "TaxiwaySign")

func _light_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.0
	_night_materials.append(material)
	return material

func _fixture(at: Vector3, material: Material) -> void:
	_box(at + Vector3(0, 0.07, 0), Vector3(0.20, 0.14, 0.20), _frame)
	G.ellipsoid(_parts, at + Vector3(0, 0.18, 0), Vector3(0.13, 0.14, 0.13), material, "AirfieldLight")

func _floodlight(at: Vector3) -> void:
	G.segment(_parts, at, at + Vector3(0, 7.8, 0), 0.075, _frame, "ApronMast")
	_box(at + Vector3(0, 7.9, 0), Vector3(1.5, 0.15, 0.5), _frame)
	_box(at + Vector3(0, 7.80, 0), Vector3(1.3, 0.04, 0.4), _light_material(Color("e1e4ca")))
	var light := OmniLight3D.new()
	light.position = at + Vector3(0, 7.5, 0)
	light.omni_range = 21.0
	light.light_color = Color("e5e1c9")
	light.light_energy = 0
	add_child(light)
	_lamps.append(light)

func _build_windsock() -> void:
	G.segment(_parts, Vector3(21, 0, 94), Vector3(21, 4.0, 94), 0.05, _frame, "WindsockMast")
	_windsock = Node3D.new()
	_windsock.position = Vector3(21, 3.7, 94)
	add_child(_windsock)
	for stripe in range(5):
		var material: Material = M.solid(Color("c9764d") if stripe % 2 == 0 else Color("e0dfca"))
		var r: float = 0.30 - stripe * 0.04
		G.segment(_windsock, Vector3(0, 0, stripe * 0.36), Vector3(0, 0, (stripe + 1) * 0.36), r, material, "WindsockFabric", (r - 0.04) / r)

func _process(delta: float) -> void:
	_elapsed += delta
	var wind := Vector3(1.2, 0, 0.4)
	var rain: float = 0.0
	if _weather and _weather.has_method("get_wind"):
		wind = _weather.get_wind()
		rain = _weather.get("_current_mods").rain_intensity
	_windsock.rotation.y = lerp_angle(_windsock.rotation.y, atan2(wind.x, wind.z), 1.0 - exp(-delta * 2))
	_windsock.rotation.x = lerpf(0.8, 0.05, clampf(wind.length() / 8.0, 0, 1)) + sin(_elapsed * 4) * 0.04
	var lit: bool = (_clock != null and _clock.is_dusk()) or rain > 0.6
	if lit != _lit:
		_lit = lit
		for material in _night_materials:
			material.emission_energy_multiplier = 3.0 if lit else 0.0
		_glass.emission_enabled = true
		_glass.emission = Color("a1b2ae")
		_glass.emission_energy_multiplier = 0.32 if lit else 0.0
		for light in _lamps:
			light.light_energy = 5.0 if lit else 0.0
	_beacon.emission_energy_multiplier = 4.0 if fmod(_elapsed, 1.5) < 0.18 else 0.2

func _bake() -> void:
	var groups: Dictionary = {}
	for node in _parts.get_children():
		if not node is MeshInstance3D:
			continue
		var material: Material = node.material_override
		if not groups.has(material):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			groups[material] = st
		groups[material].append_from(node.mesh, 0, node.transform)
	var mesh := ArrayMesh.new()
	for material in groups:
		groups[material].set_material(material)
		groups[material].commit(mesh)
	G.instance(self, mesh, Vector3.ZERO, null, "AirportGeometry")
	_parts.free()
