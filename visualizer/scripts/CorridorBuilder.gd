extends Node3D
const CrossingFurniture = preload("res://scripts/CrossingFurniture.gd")
const StreetLamp = preload("res://scripts/StreetLamp.gd")

const Signals = preload("res://scripts/SignalHardware.gd")
const PedSignals = preload("res://scripts/PedestrianSignals.gd")

const SurfaceMaterials = preload("res://scripts/StreetscapeMaterials.gd")
## Builds and manages the 3-junction corridor geometry and traffic lights.
##
## Three junctions (J0, J1, J2) along the N6 Nsawam Road corridor.
## All geometry is constructed from Godot primitives — no external assets.
##
## Layout (Godot coordinates):
##   J0 center: Z = 0     (Achimota/Neoplan)
##   J1 center: Z = 30    (Asylum Down / Ring Rd)
##   J2 center: Z = 60    (Nima / Tesano)
##   NS corridor runs along Z axis
##   Cross-streets run along X axis at each junction
##
## SUMO → Godot mapping:
##   Piecewise linear (see VehicleManager._map_corridor_z/x)
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
const SIDEWALK_WIDTH    := 0.7

# NS corridor road (2 lanes each direction = 4 lanes total)
const NS_ROAD_WIDTH     := 6.0

# Cross-street profiles per junction
# J0: E=Aggrey(2lane), W=Guggisberg(1lane)
# J1: E=Asylum Down(2lane), W=Ring Rd(2lane)
# J2: E=Nima(1lane), W=Tesano(1lane)

# Junction centers (Godot Z)
const J0_Z := 0.0
const J1_Z := 30.0
const J2_Z := 60.0
const JUNCTION_CENTERS: Array = [0.0, 30.0, 60.0]

# Road arm lengths
const BOUNDARY_ARM      := 55.0   # Boundary road arms (lengthened for breathing room)
const CROSS_ARM         := 55.0   # Cross-street arms (lengthened for breathing room)

# Junction names
const JUNCTION_IDS: Array = ["J0", "J1", "J2"]

# Cross-street widths per junction: {jid: {east: w, west: w}}
var _cross_widths: Dictionary = {
	"J0": {"east": 5.0, "west": 3.0},
	"J1": {"east": 5.0, "west": 5.0},
	"J2": {"east": 3.0, "west": 3.0},
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

	# Build 3 junctions
	for i in range(3):
		var jid: String = JUNCTION_IDS[i]
		var center_z: float = JUNCTION_CENTERS[i]
		_build_junction(jid, center_z)

	# Build corridor road segments between junctions
	_build_corridor_roads()

	# Build boundary roads (south of J0, north of J2)
	_build_boundary_roads()

	# Build cross-street arms
	for i in range(3):
		var jid: String = JUNCTION_IDS[i]
		var center_z: float = JUNCTION_CENTERS[i]
		_build_cross_streets(jid, center_z)

	# Build traffic lights at each junction
	for i in range(3):
		var jid: String = JUNCTION_IDS[i]
		var center_z: float = JUNCTION_CENTERS[i]
		_build_traffic_lights(jid, center_z)

	# Street furniture: lamps along every road + utility poles down the corridor
	_build_street_lights()
	_build_utility_poles()

	# Build lane congestion overlays
	_build_lane_overlays()

	# Build junction name labels

	# Build watermark


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

	_mat_grass = SurfaceMaterials.surface(3, Color("796d4b"))

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
	ground.size = Vector3(2000.0, 0.02, 2000.0)
	ground.position = Vector3(0, -0.06, J1_Z)  # Center on corridor midpoint
	ground.material = _mat_grass
	ground.name = "Ground"
	add_child(ground)


func _build_junction(jid: String, center_z: float) -> void:
	## Build one junction square at the given Z position.
	var junction := CSGBox3D.new()
	junction.size = Vector3(JUNCTION_SIZE, ROAD_THICKNESS, JUNCTION_SIZE)
	junction.position = Vector3(0, 0, center_z)
	junction.material = _mat_road
	junction.name = "Junction_%s" % jid
	add_child(junction)

	# Crosswalk markings at each junction edge
	_build_crosswalks(jid, center_z)

	# Stop lines
	_build_stop_lines(jid, center_z)


func _build_corridor_roads() -> void:
	## Build the NS corridor road segments between junctions.
	# J0→J1 segment
	var seg1_z_start: float = J0_Z + JUNCTION_HALF
	var seg1_z_end: float = J1_Z - JUNCTION_HALF
	var seg1_length: float = seg1_z_end - seg1_z_start
	var seg1_center: float = (seg1_z_start + seg1_z_end) / 2.0

	var road1 := CSGBox3D.new()
	road1.size = Vector3(NS_ROAD_WIDTH, ROAD_THICKNESS, seg1_length)
	road1.position = Vector3(0, 0, seg1_center)
	road1.material = _mat_road
	road1.name = "CorridorRoad_J0_J1"
	add_child(road1)

	# Sidewalks along J0→J1
	_build_corridor_sidewalks(seg1_center, seg1_length, NS_ROAD_WIDTH)

	# J1→J2 segment
	var seg2_z_start: float = J1_Z + JUNCTION_HALF
	var seg2_z_end: float = J2_Z - JUNCTION_HALF
	var seg2_length: float = seg2_z_end - seg2_z_start
	var seg2_center: float = (seg2_z_start + seg2_z_end) / 2.0

	var road2 := CSGBox3D.new()
	road2.size = Vector3(NS_ROAD_WIDTH, ROAD_THICKNESS, seg2_length)
	road2.position = Vector3(0, 0, seg2_center)
	road2.material = _mat_road
	road2.name = "CorridorRoad_J1_J2"
	add_child(road2)

	_build_corridor_sidewalks(seg2_center, seg2_length, NS_ROAD_WIDTH)

	# Center line dashes on corridor roads
	_build_center_dashes(Vector3(0, 0, seg1_center), Vector3(0, 0, 1), seg1_length)
	_build_center_dashes(Vector3(0, 0, seg2_center), Vector3(0, 0, 1), seg2_length)


func _build_corridor_sidewalks(center_z: float, length: float, road_width: float) -> void:
	## Build sidewalks + an open concrete U-gutter along a corridor road segment.
	var half_w: float = road_width / 2.0
	for side in [-1.0, 1.0]:
		var sw := CSGBox3D.new()
		sw.size = Vector3(SIDEWALK_WIDTH, SIDEWALK_HEIGHT, length)
		sw.position = Vector3(
			side * (half_w + SIDEWALK_WIDTH / 2.0),
			SIDEWALK_HEIGHT / 2.0,
			center_z
		)
		sw.material = _mat_sidewalk
		add_child(sw)
		# Open gutter just outside the sidewalk (classic Accra roadside drain)
		_build_gutter(Vector3(side * (half_w + SIDEWALK_WIDTH + 0.45), 0, center_z), length, true)


func _build_gutter(center: Vector3, length: float, is_ns: bool) -> void:
	## Open concrete U-gutter: a dark recessed channel flanked by two raised
	## concrete rims. Oriented along Z (is_ns) or X.
	var gw: float = 0.55     # channel width
	var rw: float = 0.12     # rim width
	var rh: float = 0.16     # rim height
	var channel := CSGBox3D.new()
	channel.size = Vector3(gw, 0.05, length) if is_ns else Vector3(length, 0.05, gw)
	channel.position = center + Vector3(0, 0.025, 0)
	channel.material = _mat_gutter_floor
	channel.name = "Gutter"
	add_child(channel)
	for s in [-1.0, 1.0]:
		var rim := CSGBox3D.new()
		rim.size = Vector3(rw, rh, length) if is_ns else Vector3(length, rh, rw)
		var off: float = s * (gw / 2.0 + rw / 2.0)
		rim.position = center + (Vector3(off, rh / 2.0, 0) if is_ns else Vector3(0, rh / 2.0, off))
		rim.material = _mat_gutter_concrete
		rim.name = "GutterRim"
		add_child(rim)


func _build_boundary_roads() -> void:
	## Build boundary roads: south of J0 and north of J2.
	# South boundary
	var s_center_z: float = J0_Z - JUNCTION_HALF - BOUNDARY_ARM / 2.0
	var s_road := CSGBox3D.new()
	s_road.size = Vector3(NS_ROAD_WIDTH, ROAD_THICKNESS, BOUNDARY_ARM)
	s_road.position = Vector3(0, 0, s_center_z)
	s_road.material = _mat_road
	s_road.name = "BoundaryRoad_South"
	add_child(s_road)
	_build_corridor_sidewalks(s_center_z, BOUNDARY_ARM, NS_ROAD_WIDTH)
	_build_center_dashes(Vector3(0, 0, s_center_z), Vector3(0, 0, -1), BOUNDARY_ARM)

	# North boundary
	var n_center_z: float = J2_Z + JUNCTION_HALF + BOUNDARY_ARM / 2.0
	var n_road := CSGBox3D.new()
	n_road.size = Vector3(NS_ROAD_WIDTH, ROAD_THICKNESS, BOUNDARY_ARM)
	n_road.position = Vector3(0, 0, n_center_z)
	n_road.material = _mat_road
	n_road.name = "BoundaryRoad_North"
	add_child(n_road)
	_build_corridor_sidewalks(n_center_z, BOUNDARY_ARM, NS_ROAD_WIDTH)
	_build_center_dashes(Vector3(0, 0, n_center_z), Vector3(0, 0, 1), BOUNDARY_ARM)


func _build_cross_streets(jid: String, center_z: float) -> void:
	## Build E/W cross-street arms at one junction.
	var widths: Dictionary = _cross_widths[jid]

	# East arm
	var e_width: float = widths["east"]
	var e_center_x: float = -(JUNCTION_HALF + CROSS_ARM / 2.0)
	var e_road := CSGBox3D.new()
	e_road.size = Vector3(CROSS_ARM, ROAD_THICKNESS, e_width)
	e_road.position = Vector3(e_center_x, 0, center_z)
	e_road.material = _mat_road
	e_road.name = "CrossRoad_%s_East" % jid
	add_child(e_road)
	# East sidewalks
	for side in [-1.0, 1.0]:
		var sw := CSGBox3D.new()
		sw.size = Vector3(CROSS_ARM, SIDEWALK_HEIGHT, SIDEWALK_WIDTH)
		sw.position = Vector3(e_center_x, SIDEWALK_HEIGHT / 2.0,
			center_z + side * (e_width / 2.0 + SIDEWALK_WIDTH / 2.0))
		sw.material = _mat_sidewalk
		add_child(sw)
	# Center dashes
	_build_center_dashes(Vector3(e_center_x, 0, center_z), Vector3(-1, 0, 0), CROSS_ARM)

	# West arm
	var w_width: float = widths["west"]
	var w_center_x: float = JUNCTION_HALF + CROSS_ARM / 2.0
	var w_road := CSGBox3D.new()
	w_road.size = Vector3(CROSS_ARM, ROAD_THICKNESS, w_width)
	w_road.position = Vector3(w_center_x, 0, center_z)
	w_road.material = _mat_road
	w_road.name = "CrossRoad_%s_West" % jid
	add_child(w_road)
	# West sidewalks
	for side in [-1.0, 1.0]:
		var sw := CSGBox3D.new()
		sw.size = Vector3(CROSS_ARM, SIDEWALK_HEIGHT, SIDEWALK_WIDTH)
		sw.position = Vector3(w_center_x, SIDEWALK_HEIGHT / 2.0,
			center_z + side * (w_width / 2.0 + SIDEWALK_WIDTH / 2.0))
		sw.material = _mat_sidewalk
		add_child(sw)
	_build_center_dashes(Vector3(w_center_x, 0, center_z), Vector3(1, 0, 0), CROSS_ARM)


func _build_center_dashes(center: Vector3, direction: Vector3, length: float) -> void:
	## Build dashed center line along a road.
	var dash_length: float = 0.8
	var gap_length: float = 0.6
	var total_step: float = dash_length + gap_length
	var num_dashes: int = int(length / total_step)
	var half_length: float = length / 2.0

	for i in range(num_dashes):
		var offset: float = -half_length + i * total_step + dash_length / 2.0
		var dash := CSGBox3D.new()

		if abs(direction.z) > 0:
			dash.size = Vector3(0.04, 0.12, dash_length)
			dash.position = center + Vector3(0, 0, offset * sign(direction.z))
		else:
			dash.size = Vector3(dash_length, 0.12, 0.04)
			dash.position = center + Vector3(offset * sign(direction.x), 0, 0)

		dash.material = _mat_marking
		add_child(dash)


func _build_stop_lines(jid: String, _center_z: float) -> void:
	CrossingFurniture.stop_lines(self, true, int(jid.substr(1)), _mat_marking)

func _build_crosswalks(jid: String, _center_z: float) -> void:
	CrossingFurniture.crossings(self, true, int(jid.substr(1)), _mat_marking, _mat_sidewalk)

func _build_lane_overlays() -> void:
	## Build semi-transparent overlay strips on each incoming lane of all 3 junctions.
	## Color shifts green→yellow→red based on queue density from server data.
	for i in range(3):
		var jid: String = JUNCTION_IDS[i]
		var center_z: float = JUNCTION_CENTERS[i]
		_build_junction_lane_overlays(jid, center_z)


func _build_junction_lane_overlays(jid: String, center_z: float) -> void:
	## Build lane overlays for one junction's incoming lanes.
	var half_j: float = JUNCTION_HALF
	var ns_lane_w: float = NS_ROAD_WIDTH / 4.0  # Half-lane width for 2-lane NS road
	var widths: Dictionary = _cross_widths[jid]
	var e_lane_w: float = widths["east"] / 4.0   # Half-lane width for east cross-street
	var w_width: float = widths["west"]

	# Build lane configs: lane_id → {pos: Vector3, size: Vector3}
	# N approach: incoming from north (positive Z direction)
	# Overlay sits north of junction: Z from junction edge outward
	var n_center_z: float = center_z + half_j + OVERLAY_LENGTH / 2.0
	# S approach: incoming from south (negative Z direction)
	var s_center_z: float = center_z - half_j - OVERLAY_LENGTH / 2.0
	# E approach: incoming from east (now negative X after mirror)
	var e_center_x: float = -(half_j + OVERLAY_LENGTH / 2.0)
	# W approach: incoming from west (now positive X after mirror)
	var w_center_x: float = half_j + OVERLAY_LENGTH / 2.0

	var lane_configs: Dictionary = {}

	match jid:
		"J0":
			# N: ACH_J1toJ0_1, ACH_J1toJ0_2 (2 lanes from J1)
			lane_configs["ACH_J1toJ0_1"] = {"pos": Vector3(ns_lane_w, 0.12, n_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			lane_configs["ACH_J1toJ0_2"] = {"pos": Vector3(-ns_lane_w, 0.12, n_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			# E: AGG_E2J0_1, AGG_E2J0_2 (2 lanes, Aggrey St)
			lane_configs["AGG_E2J0_1"] = {"pos": Vector3(e_center_x, 0.12, center_z + e_lane_w), "size": Vector3(OVERLAY_LENGTH, 0.02, e_lane_w * 1.8)}
			lane_configs["AGG_E2J0_2"] = {"pos": Vector3(e_center_x, 0.12, center_z - e_lane_w), "size": Vector3(OVERLAY_LENGTH, 0.02, e_lane_w * 1.8)}
			# S: ACH_S2J0_1, ACH_S2J0_2 (2 lanes from boundary)
			lane_configs["ACH_S2J0_1"] = {"pos": Vector3(-ns_lane_w, 0.12, s_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			lane_configs["ACH_S2J0_2"] = {"pos": Vector3(ns_lane_w, 0.12, s_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			# W: GUG_W2J0_1 (1 lane, Guggisberg)
			lane_configs["GUG_W2J0_1"] = {"pos": Vector3(w_center_x, 0.12, center_z), "size": Vector3(OVERLAY_LENGTH, 0.02, w_width * 0.8)}

		"J1":
			# N: ACH_J2toJ1_1, ACH_J2toJ1_2 (2 lanes from J2)
			lane_configs["ACH_J2toJ1_1"] = {"pos": Vector3(ns_lane_w, 0.12, n_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			lane_configs["ACH_J2toJ1_2"] = {"pos": Vector3(-ns_lane_w, 0.12, n_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			# E: ASD_E2J1_1, ASD_E2J1_2 (2 lanes, Asylum Down)
			lane_configs["ASD_E2J1_1"] = {"pos": Vector3(e_center_x, 0.12, center_z + e_lane_w), "size": Vector3(OVERLAY_LENGTH, 0.02, e_lane_w * 1.8)}
			lane_configs["ASD_E2J1_2"] = {"pos": Vector3(e_center_x, 0.12, center_z - e_lane_w), "size": Vector3(OVERLAY_LENGTH, 0.02, e_lane_w * 1.8)}
			# S: ACH_J0toJ1_1, ACH_J0toJ1_2 (2 lanes from J0)
			lane_configs["ACH_J0toJ1_1"] = {"pos": Vector3(-ns_lane_w, 0.12, s_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			lane_configs["ACH_J0toJ1_2"] = {"pos": Vector3(ns_lane_w, 0.12, s_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			# W: RNG_W2J1_1, RNG_W2J1_2 (2 lanes, Ring Rd)
			var w_lane_w: float = w_width / 4.0
			lane_configs["RNG_W2J1_1"] = {"pos": Vector3(w_center_x, 0.12, center_z - w_lane_w), "size": Vector3(OVERLAY_LENGTH, 0.02, w_lane_w * 1.8)}
			lane_configs["RNG_W2J1_2"] = {"pos": Vector3(w_center_x, 0.12, center_z + w_lane_w), "size": Vector3(OVERLAY_LENGTH, 0.02, w_lane_w * 1.8)}

		"J2":
			# N: ACH_N2J2_1, ACH_N2J2_2 (2 lanes from boundary)
			lane_configs["ACH_N2J2_1"] = {"pos": Vector3(ns_lane_w, 0.12, n_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			lane_configs["ACH_N2J2_2"] = {"pos": Vector3(-ns_lane_w, 0.12, n_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			# E: NMA_E2J2_1 (1 lane, Nima)
			lane_configs["NMA_E2J2_1"] = {"pos": Vector3(e_center_x, 0.12, center_z), "size": Vector3(OVERLAY_LENGTH, 0.02, widths["east"] * 0.8)}
			# S: ACH_J1toJ2_1, ACH_J1toJ2_2 (2 lanes from J1)
			lane_configs["ACH_J1toJ2_1"] = {"pos": Vector3(-ns_lane_w, 0.12, s_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			lane_configs["ACH_J1toJ2_2"] = {"pos": Vector3(ns_lane_w, 0.12, s_center_z), "size": Vector3(ns_lane_w * 1.8, 0.02, OVERLAY_LENGTH)}
			# W: TSN_W2J2_1 (1 lane, Tesano)
			lane_configs["TSN_W2J2_1"] = {"pos": Vector3(w_center_x, 0.12, center_z), "size": Vector3(OVERLAY_LENGTH, 0.02, w_width * 0.8)}

	# Create overlay meshes
	for lane_id in lane_configs:
		var cfg: Dictionary = lane_configs[lane_id]
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.0, 0.8, 0.0, 0.0)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true

		var overlay := CSGBox3D.new()
		overlay.size = cfg["size"]
		overlay.position = cfg["pos"]
		overlay.material = mat
		overlay.name = "LaneOverlay_%s" % lane_id
		add_child(overlay)

		_lane_overlays[lane_id] = {"mesh": overlay, "mat": mat}


# ═════════════════════════════════════════════════════════════════════════════
# TRAFFIC LIGHTS
# ═════════════════════════════════════════════════════════════════════════════

func _build_traffic_lights(jid: String, center_z: float) -> void:
	# Poles stand beyond the sidewalk and open drain, leaving the walking strip clear.
	var along: float = JUNCTION_HALF + 2.5
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
		var head := Signals.overhead(pole, -(cfg["length"] - 0.45), Signals.HEIGHT)
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
	## Sodium lamps along both curbs of the NS corridor (skipping the junction
	## boxes) and both curbs of every cross-street arm. Off by day; toggled on at
	## night by set_street_lights_night().
	var spacing: float = 14.0

	# NS corridor: both curbs, full length, skipping junction boxes.
	var ns_side: float = NS_ROAD_WIDTH / 2.0 + SIDEWALK_WIDTH - 0.12
	var z_start: float = J0_Z - JUNCTION_HALF - BOUNDARY_ARM + 4.0
	var z_end: float = J2_Z + JUNCTION_HALF + BOUNDARY_ARM - 4.0
	for side in [-1.0, 1.0]:
		var z: float = z_start
		while z <= z_end:
			if not _near_junction_z(z, JUNCTION_HALF + 1.5):
				_add_street_lamp(Vector3(side * ns_side, 0, z), Vector3(-side, 0, 0))
			z += spacing

	# Cross-street arms at each junction: both curbs along each E/W arm.
	for i in range(3):
		var center_z: float = JUNCTION_CENTERS[i]
		var widths: Dictionary = _cross_widths[JUNCTION_IDS[i]]
		# East arm reaches -X (mirrored); west arm reaches +X.
		for arm in [{"sign": -1.0, "w": widths["east"]}, {"sign": 1.0, "w": widths["west"]}]:
			var cross_side: float = arm["w"] / 2.0 + SIDEWALK_WIDTH - 0.12
			for side in [-1.0, 1.0]:
				var d: float = JUNCTION_HALF + 4.0
				while d <= JUNCTION_HALF + CROSS_ARM - 4.0:
					_add_street_lamp(Vector3(arm["sign"] * d, 0, center_z + side * cross_side),
						Vector3(0, 0, -side))
					d += spacing


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
	## Wooden utility poles down ONE curb of the NS corridor — each with a
	## cross-arm, brace, 3 ceramic insulators, and 3 power lines strung to the
	## previous pole (the wire run breaks across each junction box).
	var spacing: float = 20.0
	var h: float = 7.0
	var crossbar_len: float = 1.8
	var ins_spacing: float = crossbar_len * 0.38
	var z_start: float = J0_Z - JUNCTION_HALF - BOUNDARY_ARM + 6.0
	var z_end: float = J2_Z + JUNCTION_HALF + BOUNDARY_ARM - 6.0

	var side_x: float = -(NS_ROAD_WIDTH / 2.0 + 1.9)   # one curb only (−X side)
	var prev_ins: Array = []
	var z: float = z_start
	while z <= z_end:
		if _near_junction_z(z, JUNCTION_HALF + 1.5):
			prev_ins = []        # break the wire run across the junction box
			z += spacing
			continue
		var pos := Vector3(side_x, 0, z)

		var pole := CSGCylinder3D.new()
		pole.radius = 0.12
		pole.height = h
		pole.position = pos + Vector3(0, h / 2.0, 0)
		pole.material = _mat_util_pole
		pole.name = "UtilityPole"
		add_child(pole)

		var crossbar := CSGBox3D.new()
		crossbar.size = Vector3(crossbar_len, 0.14, 0.14)
		crossbar.position = pos + Vector3(0, h - 0.25, 0)
		crossbar.material = _mat_util_pole
		add_child(crossbar)

		var brace := CSGBox3D.new()
		brace.size = Vector3(0.55, 0.08, 0.08)
		brace.position = pos + Vector3(0, h - 0.55, 0)
		brace.rotation_degrees = Vector3(0, 0, 35)
		brace.material = _mat_util_pole
		add_child(brace)

		var ins_positions: Array = []
		for k in range(3):
			var slot: float = (k - 1) * ins_spacing
			var ins := CSGCylinder3D.new()
			ins.radius = 0.07
			ins.height = 0.20
			ins.position = pos + Vector3(slot, h - 0.05, 0)
			ins.material = _mat_insulator
			add_child(ins)
			ins_positions.append(ins.position + Vector3(0, 0.12, 0))

		if prev_ins.size() == 3:
			for k in range(3):
				var a: Vector3 = prev_ins[k]
				var b: Vector3 = ins_positions[k]
				var span: float = (b - a).length()
				var wire := CSGBox3D.new()
				wire.size = Vector3(0.035, 0.035, span)
				wire.position = (a + b) * 0.5 + Vector3(0, -0.15, 0)
				wire.material = _mat_wire
				wire.name = "PowerLine"
				add_child(wire)

		prev_ins = ins_positions
		z += spacing


func _near_junction_z(z: float, margin: float) -> bool:
	## True if z is within `margin` of any junction centre (used to keep street
	## furniture out of the intersection boxes).
	for cz in JUNCTION_CENTERS:
		if absf(z - cz) < margin:
			return true
	return false
