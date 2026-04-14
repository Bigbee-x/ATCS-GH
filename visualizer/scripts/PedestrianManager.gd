extends Node3D
## Pedestrian system with ambient sidewalk walkers + SUMO-driven crossing.
##
## Two modes of operation:
## 1. Ambient: Self-animated pedestrians walking back and forth on sidewalks
## 2. Crossing: SUMO simulation-driven pedestrians crossing at junction
##    (positions received from server via vehicle_update packets)
##
## SUMO coordinate mapping:
##   SUMO (x,y) center = (500, 500) → Godot (0, 0)
##   Scale: 1 SUMO unit = 0.04 Godot units (500m → 20 Godot units)

# ── Configuration ──────────────────────────────────────────────────────────────
const NUM_AMBIENT       := 28      # Ambient sidewalk pedestrians
const MIN_SPEED         := 0.4     # Slowest walk speed (Godot units/sec)
const MAX_SPEED         := 1.2     # Fastest walk speed
const BODY_WIDTH        := 0.10    # Torso width (X)
const BODY_DEPTH        := 0.08    # Torso depth (Z)
const BODY_HEIGHT       := 0.25    # Torso height (Y)
const HEAD_RADIUS       := 0.045   # Head sphere radius
const LEG_HEIGHT        := 0.18    # Legs (lower body)
const TOTAL_HEIGHT      := 0.52    # Approximate total (legs + body + head)
const SIDEWALK_Y        := 0.15    # Matches Intersection.gd SIDEWALK_HEIGHT

# ── SUMO coordinate transform ──────────────────────────────────────────────────
const SUMO_CENTER       := 1500.0  # SUMO junction center (single-junction mode)
## Piecewise mapping constants (must match VehicleManager.gd)
const SUMO_JUNC_HALF_X  := 10.4   # Junction half-extent in SUMO X
const SUMO_JUNC_HALF_Z  := 7.2    # Junction half-extent in SUMO Y (Z in Godot)
const SUMO_ROAD_LEN_X   := 1489.6 # E/W road length in SUMO
const SUMO_ROAD_LEN_Z   := 1492.8 # N/S road length in SUMO
const GODOT_JUNC_HALF   := 3.5    # JUNCTION_SIZE / 2 in Godot
const GODOT_ROAD_LEN    := 90.0   # Road arm length in Godot

# ── Road geometry (must match Intersection.gd for single junction) ────────────
const ROAD_LENGTH       := 90.0
const NS_ROAD_WIDTH     := 6.4
const E_ROAD_WIDTH      := 6.4
const W_ROAD_WIDTH      := 6.4
const JUNCTION_SIZE     := 7.0
const SIDEWALK_WIDTH    := 1.5

# ── Corridor mode ────────────────────────────────────────────────────────────
var corridor_mode: bool = false
# Corridor geometry constants (must match CorridorBuilder.gd)
const C_NS_ROAD_WIDTH   := 5.0
const C_JUNCTION_SIZE   := 6.0
const C_JUNCTION_HALF   := 3.0
const C_SIDEWALK_WIDTH  := 0.5
const C_CROSS_ARM       := 30.0
const C_BOUNDARY_ARM    := 30.0
const C_J0_Z            := 0.0
const C_J1_Z            := 18.0
const C_J2_Z            := 36.0

# ── Corridor SUMO piecewise mapping (from corridor.net.xml) ─────────────────
# Raw junction Y positions (offset-subtracted)
const C_SUMO_J0_Y: float = 0.0
const C_SUMO_J1_Y: float = 300.0
const C_SUMO_J2_Y: float = 600.0
# Junction half-extents
const C_SUMO_J0_HALF_Y: float = 10.4
const C_SUMO_J1_HALF_Y: float = 10.4
const C_SUMO_J2_HALF_Y: float = 7.2
const C_SUMO_JUNC_HALF_X: float = 10.4
# SUMO road lengths between junction edges
const C_SUMO_ROAD_J0J1: float = 279.2
const C_SUMO_ROAD_J1J2: float = 282.4
const C_SUMO_SOUTH_ROAD: float = 1489.6
const C_SUMO_NORTH_ROAD: float = 1492.8
const C_SUMO_CROSS_ROAD: float = 1489.6
# Godot corridor targets
const C_GD_JUNC_HALF: float = 3.0
const C_GD_ROAD_J0J1: float = 12.0
const C_GD_ROAD_J1J2: float = 12.0
const C_GD_BOUNDARY: float = 30.0

# ── Appearance palettes ───────────────────────────────────────────────────────
const SHIRT_COLORS: Array = [
	Color(0.85, 0.15, 0.15),   # Red
	Color(0.15, 0.45, 0.85),   # Blue
	Color(0.95, 0.75, 0.05),   # Yellow
	Color(0.20, 0.70, 0.25),   # Green
	Color(0.90, 0.45, 0.10),   # Orange
	Color(0.60, 0.20, 0.70),   # Purple
	Color(0.95, 0.95, 0.95),   # White
	Color(0.15, 0.15, 0.15),   # Black
	Color(0.80, 0.40, 0.60),   # Pink
	Color(0.10, 0.65, 0.65),   # Teal
]

const SKIN_COLORS: Array = [
	Color(0.36, 0.22, 0.14),
	Color(0.45, 0.30, 0.18),
	Color(0.55, 0.38, 0.24),
	Color(0.65, 0.48, 0.32),
	Color(0.42, 0.26, 0.16),
]

const LEG_COLORS: Array = [
	Color(0.15, 0.15, 0.20),
	Color(0.20, 0.18, 0.15),
	Color(0.10, 0.10, 0.12),
	Color(0.30, 0.28, 0.25),
	Color(0.18, 0.22, 0.30),
]

# ── Sidewalk path definitions ─────────────────────────────────────────────────
var _sidewalk_paths: Array = []

# ── Ambient pedestrians ───────────────────────────────────────────────────────
var _ambient_peds: Array = []

# ── SUMO-driven crossing pedestrians ──────────────────────────────────────────
# pid (String) → {node: Node3D, last_pos: Vector3}
var _crossing_peds: Dictionary = {}
# Pool of reusable pedestrian meshes
var _crossing_pool: Array = []

# ── Pedestrian toggle ────────────────────────────────────────────────────────
var _pedestrians_enabled: bool = true


# ═══════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═══════════════════════════════════════════════════════════════════════════════

func set_corridor_mode(enabled: bool) -> void:
	corridor_mode = enabled
	if enabled:
		print("[PedestrianManager] Corridor mode enabled")
		# Re-define paths for corridor layout, then respawn
		_define_sidewalk_paths()
		respawn()


func set_pedestrians_enabled(enabled: bool) -> void:
	## Toggle all pedestrians on/off (ambient + SUMO-driven).
	_pedestrians_enabled = enabled
	# Show/hide ambient pedestrians
	for ped in _ambient_peds:
		ped["node"].visible = enabled
	# Show/hide or release crossing pedestrians
	if not enabled:
		for pid in _crossing_peds:
			_crossing_peds[pid]["node"].visible = false
	else:
		for pid in _crossing_peds:
			_crossing_peds[pid]["node"].visible = true
	print("[PedestrianManager] Pedestrians %s" % ("enabled" if enabled else "disabled"))


func is_pedestrians_enabled() -> bool:
	return _pedestrians_enabled


func _ready() -> void:
	_define_sidewalk_paths()
	_spawn_ambient()


func _process(delta: float) -> void:
	if not _pedestrians_enabled:
		return

	for ped in _ambient_peds:
		_move_ambient(ped, delta)

	# Smoothly interpolate crossing pedestrians toward target positions
	for pid in _crossing_peds:
		var data: Dictionary = _crossing_peds[pid]
		var node: Node3D = data["node"]
		node.position = node.position.lerp(data["target_pos"], minf(delta * 8.0, 1.0))


# ═══════════════════════════════════════════════════════════════════════════════
# PATH DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════

func _define_sidewalk_paths() -> void:
	if corridor_mode:
		_define_corridor_sidewalk_paths()
		return

	var half_junc: float = JUNCTION_SIZE / 2.0
	var ns_sw_offset: float = NS_ROAD_WIDTH / 2.0 + SIDEWALK_WIDTH / 2.0
	var e_sw_offset: float = E_ROAD_WIDTH / 2.0 + SIDEWALK_WIDTH / 2.0
	var w_sw_offset: float = W_ROAD_WIDTH / 2.0 + SIDEWALK_WIDTH / 2.0

	var road_start: float = half_junc + 1.0
	var road_end: float = half_junc + ROAD_LENGTH - 1.0

	_sidewalk_paths = [
		{"start": Vector3(ns_sw_offset, 0, road_start), "end": Vector3(ns_sw_offset, 0, road_end)},
		{"start": Vector3(-ns_sw_offset, 0, road_start), "end": Vector3(-ns_sw_offset, 0, road_end)},
		{"start": Vector3(ns_sw_offset, 0, -road_start), "end": Vector3(ns_sw_offset, 0, -road_end)},
		{"start": Vector3(-ns_sw_offset, 0, -road_start), "end": Vector3(-ns_sw_offset, 0, -road_end)},
		{"start": Vector3(-road_start, 0, e_sw_offset), "end": Vector3(-road_end, 0, e_sw_offset)},
		{"start": Vector3(-road_start, 0, -e_sw_offset), "end": Vector3(-road_end, 0, -e_sw_offset)},
		{"start": Vector3(road_start, 0, -w_sw_offset), "end": Vector3(road_end, 0, -w_sw_offset)},
		{"start": Vector3(road_start, 0, w_sw_offset), "end": Vector3(road_end, 0, w_sw_offset)},
	]


func _define_corridor_sidewalk_paths() -> void:
	## Define sidewalk paths for the 3-junction corridor layout.
	_sidewalk_paths = []
	var sw_offset: float = C_NS_ROAD_WIDTH / 2.0 + C_SIDEWALK_WIDTH / 2.0

	# Corridor sidewalks along NS road (both sides, between junctions) — X negated for right-hand mirror
	# South boundary to J0
	_sidewalk_paths.append({"start": Vector3(-sw_offset, 0, C_J0_Z - C_JUNCTION_HALF - C_BOUNDARY_ARM + 1.0), "end": Vector3(-sw_offset, 0, C_J0_Z - C_JUNCTION_HALF - 0.5)})
	_sidewalk_paths.append({"start": Vector3(sw_offset, 0, C_J0_Z - C_JUNCTION_HALF - C_BOUNDARY_ARM + 1.0), "end": Vector3(sw_offset, 0, C_J0_Z - C_JUNCTION_HALF - 0.5)})
	# J0 to J1
	_sidewalk_paths.append({"start": Vector3(-sw_offset, 0, C_J0_Z + C_JUNCTION_HALF + 0.5), "end": Vector3(-sw_offset, 0, C_J1_Z - C_JUNCTION_HALF - 0.5)})
	_sidewalk_paths.append({"start": Vector3(sw_offset, 0, C_J0_Z + C_JUNCTION_HALF + 0.5), "end": Vector3(sw_offset, 0, C_J1_Z - C_JUNCTION_HALF - 0.5)})
	# J1 to J2
	_sidewalk_paths.append({"start": Vector3(-sw_offset, 0, C_J1_Z + C_JUNCTION_HALF + 0.5), "end": Vector3(-sw_offset, 0, C_J2_Z - C_JUNCTION_HALF - 0.5)})
	_sidewalk_paths.append({"start": Vector3(sw_offset, 0, C_J1_Z + C_JUNCTION_HALF + 0.5), "end": Vector3(sw_offset, 0, C_J2_Z - C_JUNCTION_HALF - 0.5)})
	# J2 to north boundary
	_sidewalk_paths.append({"start": Vector3(-sw_offset, 0, C_J2_Z + C_JUNCTION_HALF + 0.5), "end": Vector3(-sw_offset, 0, C_J2_Z + C_JUNCTION_HALF + C_BOUNDARY_ARM - 1.0)})
	_sidewalk_paths.append({"start": Vector3(sw_offset, 0, C_J2_Z + C_JUNCTION_HALF + 0.5), "end": Vector3(sw_offset, 0, C_J2_Z + C_JUNCTION_HALF + C_BOUNDARY_ARM - 1.0)})

	# Cross-street sidewalks at each junction (offset = road_half + sidewalk_half)
	# Cross-street widths per junction: {east, west}
	var cross_widths: Array = [
		{"east": 5.0, "west": 3.0},  # J0: Aggrey(2lane), Guggisberg(1lane)
		{"east": 5.0, "west": 5.0},  # J1: Asylum Down(2lane), Ring Rd(2lane)
		{"east": 3.0, "west": 3.0},  # J2: Nima(1lane), Tesano(1lane)
	]
	var junc_centers: Array = [C_J0_Z, C_J1_Z, C_J2_Z]
	for i_j in range(3):
		var center_z: float = junc_centers[i_j]
		var e_sw: float = cross_widths[i_j]["east"] / 2.0 + C_SIDEWALK_WIDTH / 2.0
		var w_sw: float = cross_widths[i_j]["west"] / 2.0 + C_SIDEWALK_WIDTH / 2.0
		# East arms (mirrored to negative X)
		_sidewalk_paths.append({"start": Vector3(-(C_JUNCTION_HALF + 0.5), 0, center_z + e_sw), "end": Vector3(-(C_JUNCTION_HALF + C_CROSS_ARM - 1.0), 0, center_z + e_sw)})
		_sidewalk_paths.append({"start": Vector3(-(C_JUNCTION_HALF + 0.5), 0, center_z - e_sw), "end": Vector3(-(C_JUNCTION_HALF + C_CROSS_ARM - 1.0), 0, center_z - e_sw)})
		# West arms (mirrored to positive X)
		_sidewalk_paths.append({"start": Vector3(C_JUNCTION_HALF + 0.5, 0, center_z - w_sw), "end": Vector3(C_JUNCTION_HALF + C_CROSS_ARM - 1.0, 0, center_z - w_sw)})
		_sidewalk_paths.append({"start": Vector3(C_JUNCTION_HALF + 0.5, 0, center_z + w_sw), "end": Vector3(C_JUNCTION_HALF + C_CROSS_ARM - 1.0, 0, center_z + w_sw)})


# ═══════════════════════════════════════════════════════════════════════════════
# AMBIENT PEDESTRIAN SPAWNING & MOVEMENT
# ═══════════════════════════════════════════════════════════════════════════════

func _spawn_ambient() -> void:
	for i in range(NUM_AMBIENT):
		var path_idx: int = i % _sidewalk_paths.size()
		var ped_node: Node3D = _make_pedestrian_mesh()
		add_child(ped_node)

		var ped_data: Dictionary = {
			"node": ped_node,
			"path_idx": path_idx,
			"progress": randf(),
			"speed": MIN_SPEED + randf() * (MAX_SPEED - MIN_SPEED),
			"forward": randf() > 0.5,
		}
		_update_ambient_position(ped_data)
		_ambient_peds.append(ped_data)


func _move_ambient(ped: Dictionary, delta: float) -> void:
	var path: Dictionary = _sidewalk_paths[ped["path_idx"]]
	var path_length: float = path["start"].distance_to(path["end"])
	var step: float = (ped["speed"] * delta) / path_length

	if ped["forward"]:
		ped["progress"] += step
		if ped["progress"] >= 1.0:
			ped["progress"] = 1.0
			ped["forward"] = false
	else:
		ped["progress"] -= step
		if ped["progress"] <= 0.0:
			ped["progress"] = 0.0
			ped["forward"] = true

	_update_ambient_position(ped)


func _update_ambient_position(ped: Dictionary) -> void:
	var path: Dictionary = _sidewalk_paths[ped["path_idx"]]
	var pos: Vector3 = path["start"].lerp(path["end"], ped["progress"])
	pos.y = SIDEWALK_Y + LEG_HEIGHT + BODY_HEIGHT / 2.0
	var node: Node3D = ped["node"]
	node.position = pos
	var dir: Vector3 = (path["end"] - path["start"]).normalized()
	if not ped["forward"]:
		dir = -dir
	if dir.length() > 0.01:
		node.rotation.y = atan2(dir.x, dir.z)


# ═══════════════════════════════════════════════════════════════════════════════
# SUMO-DRIVEN CROSSING PEDESTRIANS
# ═══════════════════════════════════════════════════════════════════════════════

func update_crossing_pedestrians(ped_list: Array) -> void:
	## Called from Main.gd when server sends pedestrian data.
	## ped_list: Array of {id, x, y, speed, angle, edge}
	##
	## Only renders pedestrians on crossing edges (:Jx_c*) or walking areas (:Jx_w*).
	## Pedestrians on regular road edges are skipped — the ambient system handles
	## sidewalk visuals, and SUMO sidewalk coords don't map to Godot sidewalk offsets.
	if not _pedestrians_enabled:
		return

	var seen: Dictionary = {}

	for ped_data in ped_list:
		var pid: String = str(ped_data.get("id", ""))
		if pid.is_empty():
			continue

		# Only render pedestrians on junction crossing or walking area edges.
		# Pedestrians on regular road edges (ACH_N2J, etc.) would appear on the
		# vehicle lanes because SUMO sidewalk coords don't map to Godot sidewalk
		# positions — the piecewise mapping doesn't preserve lateral offsets.
		var edge: String = str(ped_data.get("edge", ""))
		var on_crossing: bool = edge.begins_with(":J0_c") or edge.begins_with(":J1_c") or edge.begins_with(":J2_c")
		var on_walking_area: bool = edge.begins_with(":J0_w") or edge.begins_with(":J1_w") or edge.begins_with(":J2_w")
		if not on_crossing and not on_walking_area:
			# Skip — pedestrian is on a regular road edge (sidewalk in SUMO)
			# If they were previously visible, release them
			if _crossing_peds.has(pid):
				_release_crossing_mesh(_crossing_peds[pid]["node"])
				_crossing_peds.erase(pid)
			continue

		seen[pid] = true

		# Convert SUMO coords to Godot coords (piecewise mapping matching VehicleManager)
		var sumo_x: float = float(ped_data.get("x", 1500.0))
		var sumo_y: float = float(ped_data.get("y", 1500.0))
		var godot_x: float
		var godot_z: float
		if corridor_mode:
			var dx: float = sumo_x - SUMO_CENTER
			var dy: float = sumo_y - SUMO_CENTER
			godot_x = -_map_corridor_x(dx)  # Negated for right-hand visual
			godot_z = _map_corridor_z(dy)
		else:
			var dx: float = sumo_x - SUMO_CENTER
			var dz: float = sumo_y - SUMO_CENTER
			godot_x = -_map_sj_axis(dx, SUMO_JUNC_HALF_X, SUMO_ROAD_LEN_X)  # Negated for right-hand visual
			godot_z = _map_sj_axis(dz, SUMO_JUNC_HALF_Z, SUMO_ROAD_LEN_Z)

		# Crossings are at road level; walking areas are at sidewalk level
		var target_y: float
		if on_crossing:
			target_y = LEG_HEIGHT + BODY_HEIGHT / 2.0  # Road level
		else:
			target_y = SIDEWALK_Y + LEG_HEIGHT + BODY_HEIGHT / 2.0  # Sidewalk level

		var target_pos := Vector3(godot_x, target_y, godot_z)

		if _crossing_peds.has(pid):
			# Update existing crossing pedestrian
			_crossing_peds[pid]["target_pos"] = target_pos
		else:
			# Acquire or create a pedestrian mesh
			var node: Node3D = _acquire_crossing_mesh()
			node.position = target_pos
			_crossing_peds[pid] = {
				"node": node,
				"target_pos": target_pos,
			}

		# Update facing direction from SUMO angle
		var angle_deg: float = float(ped_data.get("angle", 0.0))
		var node: Node3D = _crossing_peds[pid]["node"]
		node.rotation.y = deg_to_rad(-(angle_deg - 90.0))

	# Remove pedestrians no longer in the update (left the area or no longer on crossing)
	var to_remove: Array = []
	for pid in _crossing_peds:
		if not seen.has(pid):
			to_remove.append(pid)

	for pid in to_remove:
		var node: Node3D = _crossing_peds[pid]["node"]
		_release_crossing_mesh(node)
		_crossing_peds.erase(pid)


func _acquire_crossing_mesh() -> Node3D:
	## Get a pedestrian mesh from pool or create new one.
	if _crossing_pool.size() > 0:
		var node: Node3D = _crossing_pool.pop_back()
		node.visible = true
		return node
	else:
		var node: Node3D = _make_pedestrian_mesh()
		add_child(node)
		return node


func _release_crossing_mesh(node: Node3D) -> void:
	## Return a pedestrian mesh to the pool.
	node.visible = false
	_crossing_pool.append(node)


# ═══════════════════════════════════════════════════════════════════════════════
# CORRIDOR PIECEWISE MAPPING
# ═══════════════════════════════════════════════════════════════════════════════

func _map_corridor_x(dx: float) -> float:
	## Map SUMO X (offset-subtracted) to Godot X (same logic as VehicleManager).
	var s: float = 1.0 if dx >= 0.0 else -1.0
	var a: float = absf(dx)
	if a <= C_SUMO_JUNC_HALF_X:
		return s * a * (C_GD_JUNC_HALF / C_SUMO_JUNC_HALF_X)
	else:
		var road_d: float = a - C_SUMO_JUNC_HALF_X
		return s * (C_GD_JUNC_HALF + road_d * (C_CROSS_ARM / C_SUMO_CROSS_ROAD))


func _map_corridor_z(dy: float) -> float:
	## Map SUMO Y (offset-subtracted) to Godot Z (same logic as VehicleManager).
	var j0_south: float = C_SUMO_J0_Y - C_SUMO_J0_HALF_Y
	if dy < j0_south:
		var dist: float = j0_south - dy
		return (C_J0_Z - C_GD_JUNC_HALF) - dist * (C_GD_BOUNDARY / C_SUMO_SOUTH_ROAD)

	var j0_north: float = C_SUMO_J0_Y + C_SUMO_J0_HALF_Y
	if dy <= j0_north:
		return C_J0_Z + (dy - C_SUMO_J0_Y) * (C_GD_JUNC_HALF / C_SUMO_J0_HALF_Y)

	var j1_south: float = C_SUMO_J1_Y - C_SUMO_J1_HALF_Y
	if dy < j1_south:
		var t: float = (dy - j0_north) / (j1_south - j0_north)
		return (C_J0_Z + C_GD_JUNC_HALF) + t * C_GD_ROAD_J0J1

	var j1_north: float = C_SUMO_J1_Y + C_SUMO_J1_HALF_Y
	if dy <= j1_north:
		return C_J1_Z + (dy - C_SUMO_J1_Y) * (C_GD_JUNC_HALF / C_SUMO_J1_HALF_Y)

	var j2_south: float = C_SUMO_J2_Y - C_SUMO_J2_HALF_Y
	if dy < j2_south:
		var t: float = (dy - j1_north) / (j2_south - j1_north)
		return (C_J1_Z + C_GD_JUNC_HALF) + t * C_GD_ROAD_J1J2

	var j2_north: float = C_SUMO_J2_Y + C_SUMO_J2_HALF_Y
	if dy <= j2_north:
		return C_J2_Z + (dy - C_SUMO_J2_Y) * (C_GD_JUNC_HALF / C_SUMO_J2_HALF_Y)

	var dist: float = dy - j2_north
	return (C_J2_Z + C_GD_JUNC_HALF) + dist * (C_GD_BOUNDARY / C_SUMO_NORTH_ROAD)


# ═══════════════════════════════════════════════════════════════════════════════
# SINGLE-JUNCTION PIECEWISE MAPPING
# ═══════════════════════════════════════════════════════════════════════════════

func _map_sj_axis(d: float, junc_half: float, road_len: float) -> float:
	## Map one axis from SUMO to Godot (same logic as VehicleManager._map_axis).
	var s: float = 1.0 if d >= 0.0 else -1.0
	var a: float = absf(d)
	if a <= junc_half:
		return s * a * (GODOT_JUNC_HALF / junc_half)
	else:
		var road_d: float = a - junc_half
		return s * (GODOT_JUNC_HALF + road_d * (GODOT_ROAD_LEN / road_len))


# ═══════════════════════════════════════════════════════════════════════════════
# RESET
# ═══════════════════════════════════════════════════════════════════════════════

func respawn() -> void:
	## Clear and respawn all pedestrians (called on sim restart).
	# Clear ambient
	for ped in _ambient_peds:
		ped["node"].queue_free()
	_ambient_peds.clear()

	# Clear crossing
	for pid in _crossing_peds:
		_crossing_peds[pid]["node"].queue_free()
	_crossing_peds.clear()

	# Clear pool
	for node in _crossing_pool:
		node.queue_free()
	_crossing_pool.clear()

	_spawn_ambient()


# ═══════════════════════════════════════════════════════════════════════════════
# MESH CREATION
# ═══════════════════════════════════════════════════════════════════════════════

func _make_pedestrian_mesh() -> Node3D:
	var root := Node3D.new()

	var shirt_color: Color = SHIRT_COLORS[randi() % SHIRT_COLORS.size()]
	var skin_color: Color = SKIN_COLORS[randi() % SKIN_COLORS.size()]
	var leg_color: Color = LEG_COLORS[randi() % LEG_COLORS.size()]

	# Legs
	var leg_mat := StandardMaterial3D.new()
	leg_mat.albedo_color = leg_color
	var legs := CSGBox3D.new()
	legs.size = Vector3(BODY_WIDTH, LEG_HEIGHT, BODY_DEPTH)
	legs.position = Vector3(0, -BODY_HEIGHT / 2.0 - LEG_HEIGHT / 2.0 + 0.02, 0)
	legs.material = leg_mat
	legs.name = "Legs"
	root.add_child(legs)

	# Torso
	var shirt_mat := StandardMaterial3D.new()
	shirt_mat.albedo_color = shirt_color
	var torso := CSGBox3D.new()
	torso.size = Vector3(BODY_WIDTH + 0.02, BODY_HEIGHT, BODY_DEPTH + 0.01)
	torso.position = Vector3(0, 0, 0)
	torso.material = shirt_mat
	torso.name = "Torso"
	root.add_child(torso)

	# Head
	var skin_mat := StandardMaterial3D.new()
	skin_mat.albedo_color = skin_color
	var head := CSGSphere3D.new()
	head.radius = HEAD_RADIUS
	head.radial_segments = 8
	head.rings = 4
	head.position = Vector3(0, BODY_HEIGHT / 2.0 + HEAD_RADIUS, 0)
	head.material = skin_mat
	head.name = "Head"
	root.add_child(head)

	return root
