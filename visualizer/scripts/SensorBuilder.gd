extends Node3D
## TSH-1 sensor heads (77 GHz radar, wide and tele cameras, thermal core) on each
## mast arm, a pull box at each pole base, and ONE signal cabinet per junction on
## its south-east corner, as on the canvas junction plan. Visual only: SUMO remains
## the source of data. Local +Z faces approaching traffic; mounting comes from each mast.
## Head geometry follows the TSH-1 design: 220 x 120 x 160 mm die-cast body, white
## sun shield, finned rear cover, on a stainless band-clamp saddle with pan/tilt yoke.
const G = preload("res://scripts/PropGeometry.gd")
const Signals = preload("res://scripts/SignalHardware.gd")
# South-pole-local spot for the junction cabinet: outward of the pole and back from
# the junction, door facing away from it so a technician at the door sees the signals.
const CABINET_OFFSET := Vector3(0.71, 0, 0.70)
# Cable runs in the K view: magenta, so they read apart from the four coverage colours.
const ROUTE_COLOR := Color("ff4fd8")
const CAM_PITCH := deg_to_rad(10.0)                # head tilt down the approach
const LENS_REACH := 0.254                          # Sensor_CCTV origin to the wide lens
const WIDE_LENS := Vector3(0.030, 0.020, 0.0825)   # head-local, centre of the wide lens
const RADOME := Vector3(-0.055, 0.0, 0.0805)       # head-local, centre of the radome
const ROAD_TOP := 0.05                             # asphalt top (0.1 m slabs centred on y = 0)
# Coverage shown by the K sightline view, one entry per TSH-1 sensor: its window
# on the head (head-local), true horizontal x vertical field of view in degrees,
# and a range shortened to fit the scene. The single junction's arms are 90 m;
# the corridor packs ~280 m links into 30 m, so there the radar stops short of
# the next junction, as the real one does. The wide camera is drawn only over
# the junction area it serves: its 108° fan would otherwise paint the cross streets.
# "tag" places each name label that far along its footprint, so labels don't stack.
const COVERAGE := [
	{"name": "Wide camera", "at": Vector3(0.030, 0.020, 0.0825), "h": 108.0, "v": 75.0, "color": Color(0.28, 0.85, 1.0), "alpha": 0.14, "range": 12.0, "corridor": 9.0, "tag": 0.35},
	{"name": "Tele camera", "at": Vector3(0.072, 0.020, 0.0825), "h": 35.0, "v": 20.0, "color": Color(0.93, 0.94, 0.96), "alpha": 0.16, "range": 36.0, "corridor": 22.0, "tag": 0.75},
	{"name": "Thermal", "at": Vector3(0.030, -0.024, 0.0815), "h": 57.0, "v": 44.0, "color": Color(0.96, 0.65, 0.14), "alpha": 0.24, "range": 14.0, "corridor": 11.0, "tag": 0.85},
	{"name": "Radar", "at": Vector3(-0.055, 0.0, 0.0805), "h": 40.0, "v": 14.0, "color": Color(0.43, 0.66, 1.0), "alpha": 0.14, "range": 48.0, "corridor": 26.0, "tag": 0.85},
]
var _sightline_pivots: Array[Node3D] = []
var _cones_visible: bool = false
var _coverage_cache: Dictionary = {}
var _route_mat: StandardMaterial3D

func attach_to_intersection(intersection: Node3D) -> void:
	var junctions: Dictionary = {}
	for pole in intersection.get_children():
		var pole_name := String(pole.name)
		if pole is Node3D and (pole_name.begins_with("TrafficLight_") or pole_name.begins_with("TL_")):
			# Single junction: TrafficLight_<approach>; corridor: TL_<junction>_<approach>.
			var corridor: bool = pole_name.begins_with("TL_")
			var jid: String = pole_name.get_slice("_", 1) if corridor else "J0"
			if not junctions.has(jid):
				junctions[jid] = {}
			junctions[jid][pole_name.get_slice("_", 2 if corridor else 1)] = pole
			if pole.has_node("Sensor_CCTV"):
				continue
			_attach(pole)
	for jid in junctions:
		if not intersection.has_node("SignalCabinet_" + jid):
			_junction_cabinet(intersection, jid, junctions[jid])

func toggle_sightlines() -> void:
	_cones_visible = not _cones_visible
	for pivot in _sightline_pivots:
		pivot.visible = _cones_visible

func sightlines_visible() -> bool:
	return _cones_visible

func _attach(pole: Node3D) -> void:
	var s: float = pole.get_meta("arm_sign", -1.0)
	var length: float = pole.get_meta("arm_length", 3.7)
	var m := _materials()
	var x: float = s * (length - 0.85)
	# The saddle clamps where the tapered mast arm (SignalHardware: 0.062 m
	# radius at the elbow, 72 % of that at the tip) passes x.
	var along: float = clampf((absf(x) - 0.24) / maxf(length - 0.24, 0.01), 0.0, 1.0)
	var arm_r: float = 0.062 * lerpf(1.0, 0.72, along)
	var arm_y: float = 5.5
	var center := Vector3(x, arm_y + arm_r + 0.218, 0)  # the head's tilt axis
	_mount(pole, center, arm_y, arm_r, m)
	var head := Node3D.new()
	head.name = "Sensor_TSH1"
	head.position = center
	head.rotation.x = CAM_PITCH
	pole.add_child(head)
	_head(head, m)
	# Anchors that ride on the tilted head, kept for tools and validators: the
	# wide camera's optical axis (lens at LENS_REACH along +Z) and the radome.
	var camera := Node3D.new()
	camera.name = "Sensor_CCTV"
	camera.transform = head.transform * Transform3D(Basis(), WIDE_LENS - Vector3(0, 0, LENS_REACH))
	pole.add_child(camera)
	var radar := Node3D.new()
	radar.name = "Sensor_Radar"
	radar.transform = head.transform * Transform3D(Basis(), RADOME)
	pole.add_child(radar)
	# One Cat6A cable for power and data leaves the downward M12 connector, runs
	# behind the arm and down the pole into the ground, through the pull box at the
	# pole base and under the pavement to the junction's signal cabinet.
	var plug: Vector3 = head.transform * Vector3(0.060, -0.074, -0.040)
	var cable_points: Array[Vector3] = [plug, Vector3(plug.x, arm_y + arm_r + 0.04, -0.06), Vector3(plug.x, arm_y, -0.075), Vector3(0, arm_y, -0.08), Vector3(0, 0.03, -0.1)]
	for i in range(cable_points.size() - 1):
		G.segment(pole, cable_points[i], cable_points[i + 1], 0.008, m["dark"], "CableConduit")
	_pull_box(pole)
	# Corridor poles are named TL_<junction>_<approach>; its roads are compressed.
	_sightline(pole, head, String(pole.name).begins_with("TL_"))

func _materials() -> Dictionary:
	var led := G.solid(Color("f5a524"), 0.0, 0.4).duplicate() as StandardMaterial3D
	led.emission_enabled = true
	led.emission = Color("f5a524")
	led.emission_energy_multiplier = 2.0
	return {
		"housing": G.solid(Color("c6c8c4"), 0.35, 0.45),   # RAL 7035 die-cast aluminium
		"bezel": G.solid(Color("b9bbb7"), 0.3, 0.5),
		"shield": G.solid(Color("eeede6"), 0.05, 0.55),    # RAL 9016 ASA sun shield
		"radome": G.solid(Color("34373c"), 0.0, 0.6),
		"glass": G.solid(Color("0b0f16"), 0.6, 0.06),
		"optic": G.solid(Color("05080f"), 0.4, 0.05),
		"germanium": G.solid(Color("3b3442"), 0.8, 0.12),
		"stainless": G.solid(Color("a2a8ad"), 0.85, 0.3),
		"knob": G.solid(Color("2a2d31"), 0.2, 0.55),
		"nickel": G.solid(Color("b9bdc2"), 0.9, 0.25),
		"led": led,
		"white": G.solid(Color("d4d3c7"), 0.2, 0.5),
		"steel": G.solid(Color("68746f"), 0.7, 0.35),
		"dark": G.solid(Color("252e2b"), 0.35, 0.48),
	}

func _head(head: Node3D, m: Dictionary) -> void:
	# Sealed body with a finned rear cover (the compute heat sink) and the front
	# bezel. Viewed from the road: radar radome on the left, camera window upper
	# right with the wide and tele lenses, germanium thermal window and status LED below.
	G.rounded_box(head, Vector3(0, 0, -0.003), Vector3(0.22, 0.12, 0.154), 0.012, m["housing"], "Housing")
	for i in range(7):
		G.box(head, Vector3(-0.09 + i * 0.03, 0, -0.088), Vector3(0.004, 0.10, 0.016), m["housing"], "CoolingFin")
	G.rounded_box(head, Vector3(0, 0, 0.077), Vector3(0.22, 0.12, 0.006), 0.012, m["bezel"], "FrontBezel")
	G.rounded_box(head, RADOME, Vector3(0.092, 0.092, 0.002), 0.006, m["radome"], "RadarRadome")
	G.rounded_box(head, Vector3(0.051, 0.020, 0.0805), Vector3(0.096, 0.044, 0.002), 0.006, m["glass"], "CameraWindow")
	G.segment(head, Vector3(0.030, 0.020, 0.0812), WIDE_LENS, 0.007, m["optic"], "WideLens")
	G.segment(head, Vector3(0.072, 0.020, 0.0812), Vector3(0.072, 0.020, 0.0825), 0.0085, m["optic"], "TeleLens")
	G.segment(head, Vector3(0.030, -0.024, 0.0800), Vector3(0.030, -0.024, 0.0815), 0.010, m["germanium"], "ThermalWindow")
	G.ellipsoid(head, Vector3(0.072, -0.024, 0.0812), Vector3.ONE * 0.006, m["led"], "StatusLED")
	var tag := G.label(head, "TSH-1", Vector3(0.072, -0.044, 0.0812), 0.044, 0.010, Color("5d6166"))
	tag.visibility_range_end = 6.0
	# White sun shield on four standoffs, 8 mm above the housing.
	G.box(head, Vector3(0, 0.0695, 0.020), Vector3(0.25, 0.003, 0.20), m["shield"], "SunShield")
	for side in [-1.0, 1.0]:
		G.box(head, Vector3(side * 0.1155, 0.045, 0.020), Vector3(0.003, 0.050, 0.20), m["shield"], "SunShieldSide")
		for z in [-0.05, 0.06]:
			G.segment(head, Vector3(side * 0.08, 0.060, z), Vector3(side * 0.08, 0.068, z), 0.004, m["stainless"], "ShieldStandoff")
	# Downward-facing M12 X-coded connector and membrane vent under the rear.
	G.segment(head, Vector3(0.060, -0.060, -0.040), Vector3(0.060, -0.074, -0.040), 0.009, m["nickel"], "M12Connector")
	G.segment(head, Vector3(-0.060, -0.060, -0.040), Vector3(-0.060, -0.066, -0.040), 0.006, m["knob"], "MembraneVent")

func _mount(pole: Node3D, c: Vector3, arm_y: float, arm_r: float, m: Dictionary) -> void:
	# Band-clamp saddle on the mast arm, short riser, 360° pan base and the
	# tilt yoke whose bosses carry the head. None of it tilts with the head.
	var saddle_y: float = arm_y + arm_r + 0.015
	G.rounded_box(pole, Vector3(c.x, saddle_y, 0), Vector3(0.10, 0.03, 0.12), 0.008, m["stainless"], "ArmSaddle")
	for dx in [-0.035, 0.035]:
		G.segment(pole, Vector3(c.x + dx - 0.0095, arm_y, 0), Vector3(c.x + dx + 0.0095, arm_y, 0), arm_r + 0.004, m["stainless"], "BandClamp")
	G.segment(pole, Vector3(c.x, saddle_y + 0.015, 0), Vector3(c.x, c.y - 0.128, 0), 0.024, m["stainless"], "AdapterRiser")
	G.segment(pole, Vector3(c.x, c.y - 0.128, 0), Vector3(c.x, c.y - 0.108, 0), 0.040, m["stainless"], "PanBase")
	G.box(pole, c + Vector3(0, -0.104, 0), Vector3(0.256, 0.008, 0.040), m["stainless"], "YokeBar")
	for side in [-1.0, 1.0]:
		G.box(pole, c + Vector3(side * 0.124, -0.050, 0), Vector3(0.008, 0.116, 0.040), m["stainless"], "YokeArm")
		G.segment(pole, c + Vector3(side * 0.110, 0, 0), c + Vector3(side * 0.120, 0, 0), 0.014, m["stainless"], "TiltBoss")
		G.segment(pole, c + Vector3(side * 0.128, 0, 0), c + Vector3(side * 0.140, 0, 0), 0.011, m["knob"], "TiltLock")

func _pull_box_offset(pole: Node3D) -> Vector3:
	# Beside the pole base on its outward side, clear of the footway and drain.
	return Vector3(-float(pole.get_meta("arm_sign", -1.0)) * 0.42, 0, -0.2)

func _pull_box(pole: Node3D) -> void:
	# Polymer-concrete handhole where the pole's cables drop underground.
	var box := Node3D.new()
	box.name = "PullBox"
	box.position = _pull_box_offset(pole)
	pole.add_child(box)
	G.box(box, Vector3.ZERO, Vector3(0.38, 0.06, 0.52), G.solid(Color("8e8d7f"), 0.0, 0.9), "PullBoxCollar")
	G.box(box, Vector3(0, 0.034, 0), Vector3(0.32, 0.012, 0.46), G.solid(Color("4f524d"), 0.15, 0.75), "PullBoxLid")
	var bolt := G.solid(Color("a2a8ad"), 0.8, 0.3)
	for z in [-0.17, 0.17]:
		G.segment(box, Vector3(0, 0.04, z), Vector3(0, 0.045, z), 0.012, bolt, "LidBolt")

func _junction_cabinet(intersection: Node3D, jid: String, poles: Dictionary) -> void:
	# The junction's computer hub sits on its south-east corner, beside the south
	# approach's pole: one cabinet per junction, every head and TSH-1 wired back to it.
	if not poles.has("south"):
		return
	var south: Node3D = poles["south"]
	var outward: float = -float(south.get_meta("arm_sign", -1.0))
	var cabinet := Node3D.new()
	cabinet.name = "SignalCabinet_" + jid
	intersection.add_child(cabinet)
	cabinet.transform = south.transform * Transform3D(Basis(), Vector3(outward * CABINET_OFFSET.x, 0, CABINET_OFFSET.z))
	Signals.junction_cabinet(cabinet, jid)
	_cable_routes(intersection, jid, poles, cabinet)

func _cable_routes(intersection: Node3D, jid: String, poles: Dictionary, cabinet: Node3D) -> void:
	# Shown with K: the ducts under the pavement, from the cabinet to the south pole's
	# pull box, across the east and south arms, then across the west arm. Each duct
	# carries the heads' signal cable and the TSH-1's Cat6A.
	for key in ["north", "east", "south", "west"]:
		if not poles.has(key):
			return
	var routes := Node3D.new()
	routes.name = "CableRoutes_" + jid
	routes.visible = _cones_visible
	intersection.add_child(routes)
	var y: float = 0.03
	var box: Dictionary = {}
	for key in poles:
		var p: Vector3 = poles[key].transform * _pull_box_offset(poles[key])
		box[key] = Vector3(p.x, y, p.z)
	var se := Vector3(box["east"].x, y, box["south"].z)
	var sw := Vector3(box["west"].x, y, box["south"].z)
	var nw := Vector3(box["west"].x, y, box["north"].z)
	var entry: Vector3 = cabinet.transform * Vector3(-0.35, y, -0.25)
	var runs: Array = [[entry, box["south"]], [box["south"], se, box["east"]], [se, sw, box["west"]], [sw, nw, box["north"]]]
	for run in runs:
		for i in range(run.size() - 1):
			if run[i].distance_to(run[i + 1]) > 0.01:
				G.segment(routes, run[i], run[i + 1], 0.035, _route_material(), "CableRun")
	var tag := Label3D.new()
	tag.name = "CabinetLabel"
	tag.text = "Signal cabinet %s\nevery head + 4 TSH-1" % jid
	tag.position = cabinet.transform * Vector3(0.2, 2.3, 0)
	tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	tag.font_size = 48
	tag.pixel_size = 0.011
	tag.outline_size = 10
	tag.modulate = ROUTE_COLOR
	tag.outline_modulate = Color(0.05, 0.06, 0.08, 0.85)
	tag.shaded = false
	tag.no_depth_test = true
	tag.visibility_range_end = 120.0
	routes.add_child(tag)
	_sightline_pivots.append(routes)

func _route_material() -> StandardMaterial3D:
	# Drawn through the pavement, like an X-ray of the ducts.
	if _route_mat == null:
		_route_mat = StandardMaterial3D.new()
		_route_mat.albedo_color = Color(ROUTE_COLOR, 0.95)
		_route_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		_route_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_route_mat.no_depth_test = true
		_route_mat.render_priority = 2
	return _route_mat

func _sightline(pole: Node3D, head: Node3D, corridor: bool) -> void:
	# One pivot per head, at the wide-camera lens and tilted with the head. Each
	# sensor's coverage is painted on the road as its footprint, with beam lines
	# back to its own window on the bezel; raised sidewalks and buildings hide
	# the parts that aren't road.
	var pivot := Node3D.new()
	pivot.name = "SightlinePivot"
	pivot.transform = head.transform * Transform3D(Basis(), WIDE_LENS)
	pivot.visible = _cones_visible
	pole.add_child(pivot)
	var to_pivot: Transform3D = pivot.transform.affine_inverse()
	for layer in range(COVERAGE.size()):
		var sensor: Dictionary = COVERAGE[layer]
		var reach: float = sensor["corridor"] if corridor else sensor["range"]
		var aperture: Vector3 = head.transform * sensor["at"]
		var ground: Array[Vector3] = _footprint(aperture, sensor["h"], sensor["v"], reach, ROAD_TOP + 0.01 + 0.008 * layer)
		if ground.is_empty():
			continue
		var c: Array[Vector3] = []
		for p in ground:
			c.append(to_pivot * p)
		var apex: Vector3 = to_pivot * aperture
		var fill_st := SurfaceTool.new()
		fill_st.begin(Mesh.PRIMITIVE_TRIANGLES)
		G.triangle(fill_st, c[0], c[1], c[2])
		G.triangle(fill_st, c[0], c[2], c[3])
		var line_st := SurfaceTool.new()
		line_st.begin(Mesh.PRIMITIVE_LINES)
		for i in range(4):
			for p in [c[i], c[(i + 1) % 4], apex, c[i]]:
				line_st.add_vertex(p)
		var key := String(sensor["name"]).replace(" ", "")
		var mats: Array = _coverage_materials(sensor)
		var fill := G.instance(pivot, fill_st.commit(), Vector3.ZERO, mats[0], "Coverage_" + key)
		fill.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var edges := G.instance(pivot, line_st.commit(), Vector3.ZERO, mats[1], "CoverageEdges_" + key)
		edges.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Name tag above its footprint, part-way out, larger further away.
		var near: float = ground[0].z - aperture.z
		var far: float = ground[3].z - aperture.z
		var along: float = near + (far - near) * float(sensor["tag"])
		var spot := Vector3(aperture.x, 0.8, aperture.z + along)
		var tag := Label3D.new()
		tag.name = "CoverageLabel_" + key
		tag.text = sensor["name"]
		tag.position = to_pivot * spot
		tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		tag.font_size = 48
		tag.pixel_size = 0.009 + along * 0.0004
		tag.outline_size = 10
		tag.modulate = sensor["color"]
		tag.outline_modulate = Color(0.05, 0.06, 0.08, 0.85)
		tag.shaded = false
		tag.visibility_range_end = 90.0
		pivot.add_child(tag)
	_sightline_pivots.append(pivot)

func _footprint(aperture: Vector3, h_deg: float, v_deg: float, reach: float, ground_y: float) -> Array[Vector3]:
	# Where a sensor's view meets the road, as a trapezoid in pole-local space:
	# near edge where its lower field edge lands, far edge at the range limit
	# (or where its upper edge lands, if that comes first), widening with the
	# horizontal field of view. Corners: near-left, near-right, far-right, far-left.
	var height: float = aperture.y - ground_y
	var down: float = CAM_PITCH + deg_to_rad(v_deg) * 0.5
	var near: float = height / tan(minf(down, deg_to_rad(89.0)))
	var far: float = reach
	var up: float = CAM_PITCH - deg_to_rad(v_deg) * 0.5
	if up > 0.0:
		far = minf(far, height / tan(up))
	if near >= far:
		return []
	var spread: float = tan(deg_to_rad(h_deg) * 0.5)
	var w_near: float = sqrt(near * near + height * height) * spread
	var w_far: float = sqrt(far * far + height * height) * spread
	return [Vector3(aperture.x - w_near, ground_y, aperture.z + near), Vector3(aperture.x + w_near, ground_y, aperture.z + near),
		Vector3(aperture.x + w_far, ground_y, aperture.z + far), Vector3(aperture.x - w_far, ground_y, aperture.z + far)]

func _coverage_materials(sensor: Dictionary) -> Array:
	var name_key: String = sensor["name"]
	if not _coverage_cache.has(name_key):
		_coverage_cache[name_key] = [_coverage_material(sensor["color"], sensor["alpha"]),
			_coverage_material(sensor["color"], 0.55)]
	return _coverage_cache[name_key]

func _coverage_material(color: Color, alpha: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(color, alpha)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material
