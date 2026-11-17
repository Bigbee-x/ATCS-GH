extends Node3D
const Net = preload("res://scripts/CorridorGeometry.gd")
const Transit = preload("res://scripts/TransitLayout.gd")
const StreetLamp = preload("res://scripts/StreetLamp.gd")

const Signals = preload("res://scripts/SignalHardware.gd")
const PowerLines = preload("res://scripts/PowerLines.gd")
const PedSignals = preload("res://scripts/PedestrianSignals.gd")

const SurfaceMaterials = preload("res://scripts/StreetscapeMaterials.gd")
## Builds and manages the 3-junction corridor geometry and traffic lights.
##
## Three junctions (J0, J1, J2) along the N6 Nsawam Road corridor.
## All geometry is constructed from Godot primitives — no external assets.
##
## Layout (Godot coordinates):
##   J0 center: Z = 0     (Achimota/Neoplan)
##   J1 center: Z = 300    (Asylum Down / Ring Rd)
##   J2 center: Z = 600    (Nima / Tesano)
##   NS corridor runs along Z axis
##   Cross-streets run along X axis at each junction
##
## SUMO → Godot mapping:
##   Metric translation and X reflection (see CorridorGeometry.gd)
##   SUMO Y → Godot Z,  SUMO X → Godot -X

# ── Phase constants (must match corridor_env.py) ──────────────────────────────
const NS_THROUGH := 0
const NS_LEFT    := 1
const NS_YELLOW  := 2
const EW_THROUGH := 3
const EW_LEFT    := 4
const EW_YELLOW  := 5
const NS_ALL     := 6
const EW_ALL     := 7

# ── Corridor geometry constants ──────────────────────────────────────────────
const JUNCTION_SIZE     := 6.0    # Each junction square (Godot units)
const JUNCTION_HALF     := 3.0
const ROAD_THICKNESS    := 0.1
const SIDEWALK_HEIGHT   := 0.15
const SIDEWALK_WIDTH    := 1.5

# NS corridor road (2 lanes each direction = 4 lanes total)
const NS_ROAD_WIDTH     := 12.8

# Cross-street profiles per junction
# J0: E=Aggrey(2lane), W=Guggisberg(1lane)
# J1: E=Asylum Down(2lane), W=Ring Rd(2lane)
# J2: E=Nima(1lane), W=Tesano(1lane)

# Junction centers (Godot Z)
const J0_Z := 0.0
const J1_Z := 300.0
const J2_Z := 600.0
const JUNCTION_CENTERS: Array = [0.0, 300.0, 600.0]

# Road arm lengths
const BOUNDARY_ARM      := 1489.6   # Boundary road arms (lengthened for breathing room)
const CROSS_ARM         := 880.0   # Cross-street arms (lengthened for breathing room)

# Junction names
const JUNCTION_IDS: Array = ["J0", "J1", "J2"]

# Cross-street widths per junction: {jid: {east: w, west: w}}
var _cross_widths: Dictionary = {
	"J0": {"east": 12.8, "west": 6.4},
	"J1": {"east": 12.8, "west": 12.8},
	"J2": {"east": 6.4, "west": 6.4},
}

# ── Traffic light references ─────────────────────────────────────────────────
# Structure: { "J0": { "north": {"red": {mesh, glow}, ...}, ... }, ... }
var _lights: Dictionary = {}
var _peds: Dictionary = {}   # junction id -> PedestrianSignals

# ── Lane overlay references ──────────────────────────────────────────────────
# Structure: { "ACH_J1toJ0_1": {"mesh": CSGBox3D, "mat": StandardMaterial3D}, ... }
var _lane_overlays: Dictionary = {}

# ── Lane overlay geometry ────────────────────────────────────────────────────
const OVERLAY_LENGTH := 4.0   # Length of each lane overlay strip (Godot units)

# ── Materials ────────────────────────────────────────────────────────────────
var _mat_road: Material
var _mat_sidewalk: Material
var _mat_marking: Material
var _mat_grass: Material
var _mat_pole: StandardMaterial3D
var _mat_lamp_housing: StandardMaterial3D
var _mat_util_pole: StandardMaterial3D
var _mat_insulator: StandardMaterial3D
var _mat_wire: StandardMaterial3D
var _mat_gutter_floor: StandardMaterial3D
var _mat_gutter_concrete: StandardMaterial3D

# Street-light OmniLights — off by day, toggled on at night
var _street_lights: Array = []

# ── Emergency state ──────────────────────────────────────────────────────────
var _emergency_active: Dictionary = {"J0": false, "J1": false, "J2": false}


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_create_materials()
	_build_ground()
	var roads := preload("res://scripts/MetricRoadBuilder.gd").new()
	roads.name = "MetricRoads"
	add_child(roads)
	roads.build()
	_build_lane_overlays()
	for i in range(3):
		_build_traffic_lights(JUNCTION_IDS[i], JUNCTION_CENTERS[i])
	_build_street_lights()
	var pools := preload("res://scripts/LampPools.gd").new()
	pools.setup(_street_lights, get_parent())
	add_child(pools)
	_build_utility_poles()

func _build_lane_overlays() -> void:
	# Existing live queue heatmap follows the same incoming lanes as the roads.
	for edge in Net.data().edges:
		if edge.kind != "road" or not edge.target.begins_with("J"):
			continue
		for lane in edge.lanes:
			if lane.pedestrian:
				continue
			var end := Net.point(lane.shape[-1], 0.075)
			var direction := (end-Net.point(lane.shape[-2], 0.075)).normalized()
			var length: float = minf(30.0, lane.length)
			var mat := StandardMaterial3D.new()
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = Color(0, 0.8, 0, 0)
			var overlay := MeshInstance3D.new()
			overlay.name = "Queue_"+lane.id
			var box := BoxMesh.new()
			box.size = Vector3(lane.width*0.85, 0.005, length)
			overlay.mesh = box
			overlay.material_override = mat
			overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			overlay.position = end-direction*length*0.5
			overlay.rotation.y = atan2(direction.x, direction.z)
			add_child(overlay)
			_lane_overlays[lane.id] = {"mesh":overlay, "mat":mat}


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API — called by Main.gd when state_update arrives
# ═════════════════════════════════════════════════════════════════════════════

func update_lights(data: Dictionary) -> void:
	## Update traffic light colors for all junctions.
	## Corridor mode: phases come from data.junctions.{J0,J1,J2}
	## Fallback: single-junction mode uses data.phase
	var junctions_data: Dictionary = data.get("junctions", {})

	if junctions_data.size() > 0:
		# Corridor mode: per-junction phases
		for jid in JUNCTION_IDS:
			if junctions_data.has(jid):
				var jdata: Dictionary = junctions_data[jid]
				var phase: int = jdata.get("phase", 0)
				_emergency_active[jid] = jdata.get("emergency", {}).get("active", false)
				if _peds.has(jid):
					_peds[jid].update(jdata, data.get("pedestrians", []))
				if jdata.has("signals"):
					for arm in jdata.signals:
						_set_light(jid, arm, jdata.signals[arm].main)
						_set_arrow(jid, arm, jdata.signals[arm].arrow)
				else:
					_update_junction_lights(jid, phase)
	else:
		# Fallback: single-junction mode (use J0)
		var phase: int = data.get("phase", 0)
		_emergency_active["J0"] = data.get("emergency", {}).get("active", false)
		_update_junction_lights("J0", phase)
		if _peds.has("J0"):
			_peds["J0"].update(data, data.get("pedestrians", []))


func update_lane_overlays(data: Dictionary) -> void:
	## Update lane overlay colors based on per-lane queue data.
	## In corridor mode, lane_data comes from data.junctions.{J0,J1,J2}.lane_data
	var junctions_data: Dictionary = data.get("junctions", {})

	# Merge all junction lane_data into one flat dict
	var all_lane_data: Dictionary = {}
	if junctions_data.size() > 0:
		for jid in JUNCTION_IDS:
			if junctions_data.has(jid):
				var jld: Dictionary = junctions_data[jid].get("lane_data", {})
				all_lane_data.merge(jld)
	else:
		# Fallback: single-junction format
		all_lane_data = data.get("lane_data", {})

	if all_lane_data.is_empty():
		return

	for lane_id in _lane_overlays:
		if not all_lane_data.has(lane_id):
			continue
		var ld: Dictionary = all_lane_data[lane_id]
		var queue: float = float(ld.get("queue", 0))
		var density: float = clampf(queue / 20.0, 0.0, 1.0)
		var mat: StandardMaterial3D = _lane_overlays[lane_id]["mat"]
		# Color: green → yellow → red as density increases
		var col: Color
		if density < 0.5:
			col = Color(0.0, 0.8, 0.0).lerp(Color(1.0, 0.85, 0.0), density * 2.0)
		else:
			col = Color(1.0, 0.85, 0.0).lerp(Color(1.0, 0.1, 0.0), (density - 0.5) * 2.0)
		col.a = density * 0.3
		mat.albedo_color = col


# ═════════════════════════════════════════════════════════════════════════════
# MATERIAL CREATION
# ═════════════════════════════════════════════════════════════════════════════

func _create_materials() -> void:
	_mat_road = SurfaceMaterials.surface(1, Color("343834"))

	_mat_sidewalk = SurfaceMaterials.surface(2, Color("a59d88"))

	_mat_marking = SurfaceMaterials.surface(0, Color("c8c1a9"))

	# Green grass (the user's choice, 17 Nov), worn to laterite in patches under the
	# town; see streetscape_surface kind 10.
	_mat_grass = SurfaceMaterials.surface(10, Color("4f6a33"))
	var town: Rect2 = preload("res://scripts/CityDistrictBuilder.gd").TOWN
	_mat_grass.set_shader_parameter("town_rect", Vector4(town.position.x, town.position.y, town.end.x, town.end.y))
	var paved: Array[Rect2] = preload("res://scripts/CityDistrictBuilder.gd").PAVED
	_mat_grass.set_shader_parameter("paved_a", Vector4(paved[0].position.x, paved[0].position.y, paved[0].end.x, paved[0].end.y))
	_mat_grass.set_shader_parameter("paved_b", Vector4(paved[1].position.x, paved[1].position.y, paved[1].end.x, paved[1].end.y))

	_mat_pole = StandardMaterial3D.new()
	_mat_pole.albedo_color = Color(0.25, 0.25, 0.28)
	_mat_pole.metallic = 0.6
	_mat_pole.roughness = 0.4

	_mat_lamp_housing = StandardMaterial3D.new()
	_mat_lamp_housing.albedo_color = Color(0.95, 0.82, 0.50)
	_mat_lamp_housing.metallic = 0.2
	_mat_lamp_housing.roughness = 0.4
	_mat_lamp_housing.emission_enabled = true
	_mat_lamp_housing.emission = Color(1.00, 0.85, 0.45)
	_mat_lamp_housing.emission_energy_multiplier = 0.0

	_mat_util_pole = StandardMaterial3D.new()
	_mat_util_pole.albedo_color = Color(0.38, 0.28, 0.18)
	_mat_util_pole.roughness = 0.9

	_mat_insulator = StandardMaterial3D.new()
	_mat_insulator.albedo_color = Color(0.88, 0.86, 0.82)
	_mat_insulator.roughness = 0.4

	_mat_wire = StandardMaterial3D.new()
	_mat_wire.albedo_color = Color(0.05, 0.05, 0.05)
	_mat_wire.roughness = 0.8

	_mat_gutter_floor = StandardMaterial3D.new()
	_mat_gutter_floor.albedo_color = Color(0.10, 0.11, 0.12)    # dark recessed drain
	_mat_gutter_concrete = StandardMaterial3D.new()
	_mat_gutter_concrete.albedo_color = Color(0.62, 0.60, 0.56)  # weathered concrete rim


# ═════════════════════════════════════════════════════════════════════════════
# GEOMETRY BUILDING
# ═════════════════════════════════════════════════════════════════════════════

func _build_ground() -> void:
	var ground := CSGBox3D.new()
	ground.size = Vector3(4000.0, 0.1, 4400.0)
	ground.position = Vector3(0, -0.06, J1_Z)  # Center on corridor midpoint
	ground.material = _mat_grass
	ground.name = "Ground"
	ground.use_collision = true
	# Nothing lies beneath the ground plane; as a shadow caster it only darkened
	# thin earth plates laid a centimetre above it.
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)


func _build_traffic_lights(jid: String, center_z: float) -> void:
	# Poles stand beyond the sidewalk and open drain, leaving the walking strip clear.
	var along: float = 12.5
	var widths: Dictionary = _cross_widths[jid]
	var ns_offset: float = NS_ROAD_WIDTH * 0.5 + SIDEWALK_WIDTH + 1.1
	var e_offset: float = widths["east"] * 0.5 + SIDEWALK_WIDTH + 1.1
	var w_offset: float = widths["west"] * 0.5 + SIDEWALK_WIDTH + 1.1
	var configs: Dictionary = {
		"north": {"pos": Vector3(ns_offset, 0, center_z + along), "yaw": 0.0, "length": ns_offset},
		"south": {"pos": Vector3(-ns_offset, 0, center_z - along), "yaw": PI, "length": ns_offset},
		"east": {"pos": Vector3(-along, 0, center_z + e_offset), "yaw": -PI / 2.0, "length": e_offset},
		"west": {"pos": Vector3(along, 0, center_z - w_offset), "yaw": PI / 2.0, "length": w_offset},
	}
	_lights[jid] = {}
	for approach in configs:
		var cfg: Dictionary = configs[approach]
		var pole := Node3D.new()
		pole.name = "TL_%s_%s" % [jid, approach]
		pole.position = cfg["pos"]
		pole.rotation.y = cfg["yaw"]
		add_child(pole)
		Signals.structure(pole, -1.0, cfg["length"])
		var head := Signals.overhead(pole, -(cfg["length"] - (NS_ROAD_WIDTH*0.25 if approach in ["north","south"] else widths[approach]*0.25)), Signals.HEIGHT)
		head["pole"] = Signals.repeater(pole, 3.35)
		_lights[jid][approach] = head
	# Far-side through head + left arrow for each approach, on the pole at its
	# far-left corner (see Intersection.gd); same channel as the approach's heads.
	var served_by: Dictionary = {"north": "south", "south": "north", "east": "west", "west": "east"}
	for approach in configs:
		var host: Node3D = get_node("TL_%s_%s" % [jid, approach])
		_lights[jid][served_by[approach]]["far"] = Signals.far_side(host, 3.35)
	# Two pedestrian heads per corner pole, live from this junction's crossings
	# (see Intersection.gd for the layout).
	var peds := PedSignals.new()
	peds.name = "PedestrianSignals_%s" % jid
	peds.junction = jid
	add_child(peds)
	_peds[jid] = peds
	var second_crossing: Dictionary = {"north": "west", "east": "north", "south": "east", "west": "south"}
	for approach in configs:
		var host: Node3D = get_node("TL_%s_%s" % [jid, approach])
		peds.add(approach, Signals.pedestrian_head(host, Vector3(-0.42, 2.42, 0), -PI / 2.0, Vector3(-0.07, 0, 0)))
		peds.add(second_crossing[approach], Signals.pedestrian_head(host, Vector3(-0.42, 2.42, -0.40), PI, Vector3(-0.05, 0, -0.07)))


func _build_overhead_head(pole_root: Node3D, cx: float, arm_y: float) -> Dictionary:
	return Signals.overhead(pole_root, cx, arm_y)

func _build_pole_head(pole_root: Node3D, top_y: float) -> Dictionary:
	return Signals.repeater(pole_root, top_y)


func _update_junction_lights(jid: String, phase: int) -> void:
	## Update lights for one junction based on its phase.
	if not _lights.has(jid):
		return

	var ns_state: String = "red"
	var ew_state: String = "red"
	var ns_arrow: bool = false
	var ew_arrow: bool = false

	match phase:
		NS_THROUGH:
			ns_state = "green"
		NS_LEFT:
			ns_state = "red"
			ns_arrow = true
		NS_YELLOW:
			ns_state = "yellow"
		EW_THROUGH:
			ew_state = "green"
		EW_LEFT:
			ew_state = "red"
			ew_arrow = true
		EW_YELLOW:
			ew_state = "yellow"
		NS_ALL:
			ns_state = "green"
			ns_arrow = true
		EW_ALL:
			ew_state = "green"
			ew_arrow = true

	_set_light(jid, "north", ns_state)
	_set_light(jid, "south", ns_state)
	_set_light(jid, "east", ew_state)
	_set_light(jid, "west", ew_state)

	_set_arrow(jid, "north", ns_arrow)
	_set_arrow(jid, "south", ns_arrow)
	_set_arrow(jid, "east", ew_arrow)
	_set_arrow(jid, "west", ew_arrow)


func _set_light(jid: String, approach: String, active_color: String) -> void:
	if not _lights.has(jid) or not _lights[jid].has(approach):
		return
	var bulbs: Dictionary = _lights[jid][approach]
	for color_name in ["red", "yellow", "green"]:
		Signals.set_aspect(bulbs[color_name], color_name == active_color)
		Signals.set_aspect(bulbs["pole"][color_name], color_name == active_color)
		if bulbs.has("far"):
			Signals.set_aspect(bulbs["far"][color_name], color_name == active_color)

func _set_arrow(jid: String, approach: String, is_on: bool) -> void:
	if _lights.has(jid) and _lights[jid].has(approach):
		Signals.set_aspect(_lights[jid][approach]["arrow"], is_on)
		if _lights[jid][approach].has("far"):
			Signals.set_aspect(_lights[jid][approach]["far"]["arrow"], is_on)


# ═════════════════════════════════════════════════════════════════════════════
# STREET FURNITURE — sodium lamps + utility poles (ported from Intersection.gd)
# ═════════════════════════════════════════════════════════════════════════════

func _build_street_lights() -> void:
	# One series along each SUMO sidewalk; poles sit in the outer verge.
	for path in Net.sidewalks():
		var start: Vector3 = path.start
		var end: Vector3 = path.end
		var tangent := (end-start).normalized()
		var outward := Vector3(-tangent.z, 0, tangent.x)
		var length: float = start.distance_to(end)
		for i in range(int((length-32)/32.0)):
			var at := start+tangent*(24+i*32.0)+outward*1.1
			if not _in_station_plot(at):
				_add_street_lamp(at,-outward)

func _in_station_plot(at: Vector3) -> bool:
	for spec in Transit.stations(true):
		if Transit.plot(spec).grow(1.0).has_point(Vector2(at.x, at.z)):
			return true
	return false

func _add_street_lamp(base: Vector3, toward: Vector3) -> void:
	var lamp := StreetLamp.new()
	lamp.position = base
	lamp.rotation.y = atan2(toward.x, toward.z)
	add_child(lamp)
	_street_lights.append(lamp)

func set_street_lights_night(enabled: bool) -> void:
	for lamp in _street_lights:
		lamp.set_night(enabled)

func _build_utility_poles() -> void:
	## Overhead lines down ONE curb of the NS corridor (PowerLines.gd), a pole every
	## 40 m; each run ends with a stay at the junction boxes, where the line breaks.
	var spacing: float = 40.0
	# Poles follow the drawn window of the road, not the full simulated approach.
	var z_start: float = maxf(J0_Z - JUNCTION_HALF - BOUNDARY_ARM + 6.0, Net.VIEW.position.y + 12.0)
	var z_end: float = minf(J2_Z + JUNCTION_HALF + BOUNDARY_ARM - 6.0, Net.VIEW.end.y - 12.0)
	var side_x: float = -(NS_ROAD_WIDTH / 2.0 + 1.9)   # one curb only (−X side)
	var runs: Array = []
	var current: Array[Vector3] = []
	var z: float = z_start
	while z <= z_end:
		if _near_junction_z(z, 20.0):
			if not current.is_empty():
				runs.append(current)
			current = []
		elif not _in_station_plot(Vector3(side_x, 0, z)):
			current.append(Vector3(side_x, 0, z))
		z += spacing
	if not current.is_empty():
		runs.append(current)
	for bases in runs:
		PowerLines.run(self, bases, Vector3.LEFT, Vector3.LEFT)

func _near_junction_z(z: float, margin: float) -> bool:
	## True if z is within `margin` of any junction centre (used to keep street
	## furniture out of the intersection boxes).
	for cz in JUNCTION_CENTERS:
		if absf(z - cz) < margin:
			return true
	return false
