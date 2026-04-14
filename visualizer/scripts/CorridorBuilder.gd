extends Node3D
## Builds and manages the 3-junction corridor geometry and traffic lights.
##
## Three junctions (J0, J1, J2) along the N6 Nsawam Road corridor.
## All geometry is constructed from Godot primitives — no external assets.
##
## Layout (Godot coordinates):
##   J0 center: Z = 0     (Achimota/Neoplan)
##   J1 center: Z = 18    (Asylum Down / Ring Rd)
##   J2 center: Z = 36    (Nima / Tesano)
##   NS corridor runs along Z axis
##   Cross-streets run along X axis at each junction
##
## SUMO → Godot mapping:
##   Piecewise linear (see VehicleManager._map_corridor_z/x)
##   SUMO Y → Godot Z,  SUMO X → Godot X

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
const SIDEWALK_WIDTH    := 0.5

# NS corridor road (2 lanes each direction = 4 lanes total)
const NS_ROAD_WIDTH     := 5.0

# Cross-street profiles per junction
# J0: E=Aggrey(2lane), W=Guggisberg(1lane)
# J1: E=Asylum Down(2lane), W=Ring Rd(2lane)
# J2: E=Nima(1lane), W=Tesano(1lane)

# Junction centers (Godot Z)
const J0_Z := 0.0
const J1_Z := 18.0
const J2_Z := 36.0
const JUNCTION_CENTERS: Array = [0.0, 18.0, 36.0]

# Road arm lengths
const BOUNDARY_ARM      := 30.0   # Boundary road arms
const CROSS_ARM         := 30.0   # Cross-street arms

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

# ── Lane overlay references ──────────────────────────────────────────────────
# Structure: { "ACH_J1toJ0_1": {"mesh": CSGBox3D, "mat": StandardMaterial3D}, ... }
var _lane_overlays: Dictionary = {}

# ── Lane overlay geometry ────────────────────────────────────────────────────
const OVERLAY_LENGTH := 4.0   # Length of each lane overlay strip (Godot units)

# ── Junction labels ──────────────────────────────────────────────────────────
var _junction_labels: Dictionary = {}

# ── Materials ────────────────────────────────────────────────────────────────
var _mat_road: StandardMaterial3D
var _mat_sidewalk: StandardMaterial3D
var _mat_marking: StandardMaterial3D
var _mat_grass: StandardMaterial3D
var _mat_pole: StandardMaterial3D
var _mat_light_off: StandardMaterial3D
var _mat_red_on: StandardMaterial3D
var _mat_yellow_on: StandardMaterial3D
var _mat_green_on: StandardMaterial3D
var _mat_arrow_on: StandardMaterial3D
var _mat_arrow_off: StandardMaterial3D

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

	# Build lane congestion overlays
	_build_lane_overlays()

	# Build junction name labels
	_build_junction_labels()

	# Build watermark
	_build_watermark()


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
				_update_junction_lights(jid, phase)
	else:
		# Fallback: single-junction mode (use J0)
		var phase: int = data.get("phase", 0)
		_emergency_active["J0"] = data.get("emergency", {}).get("active", false)
		_update_junction_lights("J0", phase)


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
	_mat_road = StandardMaterial3D.new()
	_mat_road.albedo_color = Color(0.18, 0.18, 0.20)

	_mat_sidewalk = StandardMaterial3D.new()
	_mat_sidewalk.albedo_color = Color(0.42, 0.40, 0.38)

	_mat_marking = StandardMaterial3D.new()
	_mat_marking.albedo_color = Color(0.92, 0.92, 0.92)

	_mat_grass = StandardMaterial3D.new()
	_mat_grass.albedo_color = Color(0.22, 0.38, 0.18)

	_mat_pole = StandardMaterial3D.new()
	_mat_pole.albedo_color = Color(0.25, 0.25, 0.28)
	_mat_pole.metallic = 0.6
	_mat_pole.roughness = 0.4

	_mat_light_off = StandardMaterial3D.new()
	_mat_light_off.albedo_color = Color(0.12, 0.12, 0.12)

	_mat_red_on = StandardMaterial3D.new()
	_mat_red_on.albedo_color = Color(1.0, 0.1, 0.1)
	_mat_red_on.emission_enabled = true
	_mat_red_on.emission = Color(1.0, 0.0, 0.0)
	_mat_red_on.emission_energy_multiplier = 4.0

	_mat_yellow_on = StandardMaterial3D.new()
	_mat_yellow_on.albedo_color = Color(1.0, 0.85, 0.0)
	_mat_yellow_on.emission_enabled = true
	_mat_yellow_on.emission = Color(1.0, 0.85, 0.0)
	_mat_yellow_on.emission_energy_multiplier = 4.0

	_mat_green_on = StandardMaterial3D.new()
	_mat_green_on.albedo_color = Color(0.0, 1.0, 0.2)
	_mat_green_on.emission_enabled = true
	_mat_green_on.emission = Color(0.0, 1.0, 0.2)
	_mat_green_on.emission_energy_multiplier = 4.0

	_mat_arrow_on = StandardMaterial3D.new()
	_mat_arrow_on.albedo_color = Color(0.0, 1.0, 0.3)
	_mat_arrow_on.emission_enabled = true
	_mat_arrow_on.emission = Color(0.0, 1.0, 0.3)
	_mat_arrow_on.emission_energy_multiplier = 5.0

	_mat_arrow_off = StandardMaterial3D.new()
	_mat_arrow_off.albedo_color = Color(0.08, 0.08, 0.08)


# ═════════════════════════════════════════════════════════════════════════════
# GEOMETRY BUILDING
# ═════════════════════════════════════════════════════════════════════════════

func _build_ground() -> void:
	var ground := CSGBox3D.new()
	ground.size = Vector3(80.0, 0.02, 110.0)
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
	## Build sidewalks along a corridor road segment.
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


func _build_stop_lines(jid: String, center_z: float) -> void:
	## Build stop lines at junction edges.
	var widths: Dictionary = _cross_widths[jid]
	var e_half: float = widths["east"] / 2.0 * 0.45
	var w_half: float = widths["west"] / 2.0 * 0.45
	var ns_half: float = NS_ROAD_WIDTH / 2.0 * 0.45

	var configs: Array = [
		Vector3(0, 0.11, center_z + JUNCTION_HALF - 0.05),
		Vector3(0, 0.11, center_z - JUNCTION_HALF + 0.05),
		Vector3(-(JUNCTION_HALF - 0.05), 0.11, center_z),
		Vector3(JUNCTION_HALF - 0.05, 0.11, center_z),
	]
	var sizes: Array = [
		Vector3(ns_half * 2, 0.02, 0.1),
		Vector3(ns_half * 2, 0.02, 0.1),
		Vector3(0.1, 0.02, e_half * 2),
		Vector3(0.1, 0.02, w_half * 2),
	]

	for idx in range(4):
		var line := CSGBox3D.new()
		line.position = configs[idx]
		line.size = sizes[idx]
		line.material = _mat_marking
		line.name = "StopLine_%s_%d" % [jid, idx]
		add_child(line)


func _build_crosswalks(_jid: String, center_z: float) -> void:
	## Build zebra crossing markings at north and south junction edges only.
	var stripe_w: float = 0.12
	var stripe_gap: float = 0.12
	var y_pos: float = 0.11

	# Only north/south crosswalks (crossing the N/S corridor road)
	for z_offset in [JUNCTION_HALF - 0.4, -(JUNCTION_HALF - 0.4)]:
		var n_stripes: int = int(NS_ROAD_WIDTH / (stripe_w + stripe_gap))
		var total_span: float = n_stripes * (stripe_w + stripe_gap) - stripe_gap
		var start: float = -total_span / 2.0
		for i in range(n_stripes):
			var stripe := CSGBox3D.new()
			stripe.size = Vector3(stripe_w, 0.02, 0.5)
			stripe.position = Vector3(start + i * (stripe_w + stripe_gap), y_pos,
				center_z + z_offset)
			stripe.material = _mat_marking
			add_child(stripe)


# ═════════════════════════════════════════════════════════════════════════════
# LANE CONGESTION OVERLAYS
# ═════════════════════════════════════════════════════════════════════════════

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
	## Build 4 traffic light poles at one junction.
	## Poles sit just outside the road edge (on sidewalk) at each junction corner.
	var half_j: float = JUNCTION_HALF + 0.3
	var widths: Dictionary = _cross_widths[jid]
	var ns_offset: float = NS_ROAD_WIDTH / 2.0 + 0.3
	var e_offset: float = widths["east"] / 2.0 + 0.3
	var w_offset: float = widths["west"] / 2.0 + 0.3

	# X positions mirrored (negated) for right-hand traffic visual mapping.
	var configs: Dictionary = {
		"north": {"pos": Vector3(ns_offset, 0, center_z + half_j), "rot_y": 0.0},
		"south": {"pos": Vector3(-ns_offset, 0, center_z - half_j), "rot_y": PI},
		"east":  {"pos": Vector3(-half_j, 0, center_z + e_offset), "rot_y": PI / 2.0},
		"west":  {"pos": Vector3(half_j, 0, center_z - w_offset), "rot_y": -PI / 2.0},
	}

	if not _lights.has(jid):
		_lights[jid] = {}

	for approach in configs:
		var cfg: Dictionary = configs[approach]
		var pole_root := Node3D.new()
		pole_root.position = cfg["pos"]
		pole_root.rotation.y = cfg["rot_y"]
		pole_root.name = "TL_%s_%s" % [jid, approach]
		add_child(pole_root)

		# Pole
		var pole := CSGCylinder3D.new()
		pole.radius = 0.04
		pole.height = 2.5
		pole.position = Vector3(0, 1.25, 0)
		pole.material = _mat_pole
		pole_root.add_child(pole)

		# Housing
		var housing := CSGBox3D.new()
		housing.size = Vector3(0.25, 0.8, 0.16)
		housing.position = Vector3(0, 2.3, 0.09)
		housing.material = _mat_pole
		pole_root.add_child(housing)

		# Bulbs
		var bulb_data: Array = [
			{"name": "red",    "y": 2.55},
			{"name": "yellow", "y": 2.30},
			{"name": "green",  "y": 2.05},
		]

		var approach_lights: Dictionary = {}
		for bd in bulb_data:
			var bulb := CSGSphere3D.new()
			bulb.radius = 0.07
			bulb.radial_segments = 10
			bulb.rings = 5
			bulb.position = Vector3(0, bd["y"], 0.18)
			bulb.material = _mat_light_off
			bulb.name = "Bulb_%s" % bd["name"]
			pole_root.add_child(bulb)

			var glow := OmniLight3D.new()
			glow.position = Vector3(0, bd["y"], 0.18)
			glow.light_energy = 0.0
			glow.light_color = Color(1, 1, 1)
			glow.omni_range = 2.0
			glow.omni_attenuation = 2.0
			glow.shadow_enabled = false
			glow.name = "Glow_%s" % bd["name"]
			pole_root.add_child(glow)

			approach_lights[bd["name"]] = {"mesh": bulb, "glow": glow}

		# Arrow
		var arrow_housing := CSGBox3D.new()
		arrow_housing.size = Vector3(0.25, 0.3, 0.16)
		arrow_housing.position = Vector3(0, 1.7, 0.09)
		arrow_housing.material = _mat_pole
		pole_root.add_child(arrow_housing)

		var arrow_mesh := CSGBox3D.new()
		arrow_mesh.size = Vector3(0.13, 0.13, 0.03)
		arrow_mesh.position = Vector3(0, 1.7, 0.19)
		arrow_mesh.material = _mat_arrow_off
		arrow_mesh.name = "Arrow"
		pole_root.add_child(arrow_mesh)

		var arrow_glow := OmniLight3D.new()
		arrow_glow.position = Vector3(0, 1.7, 0.19)
		arrow_glow.light_energy = 0.0
		arrow_glow.light_color = Color(0, 1, 0.3)
		arrow_glow.omni_range = 1.5
		arrow_glow.shadow_enabled = false
		pole_root.add_child(arrow_glow)

		approach_lights["arrow"] = {"mesh": arrow_mesh, "glow": arrow_glow}
		_lights[jid][approach] = approach_lights


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
		var is_on: bool = (color_name == active_color)
		var mesh = bulbs[color_name]["mesh"]
		var glow: OmniLight3D = bulbs[color_name]["glow"]
		if is_on:
			match color_name:
				"red":
					mesh.material = _mat_red_on
					glow.light_energy = 2.0
					glow.light_color = Color(1, 0, 0)
				"yellow":
					mesh.material = _mat_yellow_on
					glow.light_energy = 2.0
					glow.light_color = Color(1, 0.85, 0)
				"green":
					mesh.material = _mat_green_on
					glow.light_energy = 2.0
					glow.light_color = Color(0, 1, 0.2)
		else:
			mesh.material = _mat_light_off
			glow.light_energy = 0.0


func _set_arrow(jid: String, approach: String, is_on: bool) -> void:
	if not _lights.has(jid) or not _lights[jid].has(approach):
		return
	var bulbs: Dictionary = _lights[jid][approach]
	if not bulbs.has("arrow"):
		return
	var arrow_mesh = bulbs["arrow"]["mesh"]
	var arrow_glow: OmniLight3D = bulbs["arrow"]["glow"]
	if is_on:
		arrow_mesh.material = _mat_arrow_on
		arrow_glow.light_energy = 2.5
	else:
		arrow_mesh.material = _mat_arrow_off
		arrow_glow.light_energy = 0.0


# ═════════════════════════════════════════════════════════════════════════════
# JUNCTION LABELS & WATERMARK
# ═════════════════════════════════════════════════════════════════════════════

func _build_junction_labels() -> void:
	## Place floating labels above each junction.
	var names: Dictionary = {
		"J0": "J0 — Achimota/Neoplan",
		"J1": "J1 — Asylum Down",
		"J2": "J2 — Nima/Tesano",
	}

	for i in range(3):
		var jid: String = JUNCTION_IDS[i]
		var center_z: float = JUNCTION_CENTERS[i]
		var label := Label3D.new()
		label.text = names[jid]
		label.font_size = 32
		label.position = Vector3(0, 3.5, center_z)
		label.rotation.x = -PI / 6.0
		label.modulate = Color(1.0, 1.0, 1.0, 0.8)
		label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		label.pixel_size = 0.008
		label.name = "Label_%s" % jid
		add_child(label)
		_junction_labels[jid] = label


func _build_watermark() -> void:
	var label := Label3D.new()
	label.text = "VALIBORN TECHNOLOGIES — N6 NSAWAM CORRIDOR"
	label.font_size = 36
	label.position = Vector3(0, 0.12, J1_Z)
	label.rotation.x = -PI / 2.0
	label.modulate = Color(0.35, 0.35, 0.40, 0.25)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.pixel_size = 0.008
	label.name = "Watermark"
	add_child(label)
