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
const BODY_WIDTH        := 0.3     # Torso width (X)
const BODY_DEPTH        := 0.25    # Torso depth (Z)
const BODY_HEIGHT       := 0.9     # Torso height (Y)
const HEAD_RADIUS       := 0.14    # Head sphere radius
const LEG_HEIGHT        := 0.7     # Legs (lower body)
const TOTAL_HEIGHT      := 1.75    # Approximate total (legs + body + head)
const SIDEWALK_Y        := 0.15    # Matches Intersection.gd SIDEWALK_HEIGHT

# ── SUMO coordinate transform ──────────────────────────────────────────────────
const SUMO_CENTER       := 500.0   # SUMO junction center
const SUMO_SCALE        := 0.04    # SUMO units to Godot units (500m / ~12.5)

# ── Road geometry (must match Intersection.gd) ────────────────────────────────
const ROAD_LENGTH       := 30.0
const NS_ROAD_WIDTH     := 6.4
const E_ROAD_WIDTH      := 6.4
const W_ROAD_WIDTH      := 3.2
const JUNCTION_SIZE     := 10.0
const SIDEWALK_WIDTH    := 1.5

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


# ═══════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_define_sidewalk_paths()
	_spawn_ambient()


func _process(delta: float) -> void:
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
		{"start": Vector3(road_start, 0, e_sw_offset), "end": Vector3(road_end, 0, e_sw_offset)},
		{"start": Vector3(road_start, 0, -e_sw_offset), "end": Vector3(road_end, 0, -e_sw_offset)},
		{"start": Vector3(-road_start, 0, -w_sw_offset), "end": Vector3(-road_end, 0, -w_sw_offset)},
		{"start": Vector3(-road_start, 0, w_sw_offset), "end": Vector3(-road_end, 0, w_sw_offset)},
	]


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
	var seen: Dictionary = {}

	for ped_data in ped_list:
		var pid: String = str(ped_data.get("id", ""))
		if pid.is_empty():
			continue
		seen[pid] = true

		# Convert SUMO coords to Godot coords
		var sumo_x: float = float(ped_data.get("x", 500.0))
		var sumo_y: float = float(ped_data.get("y", 500.0))
		var godot_x: float = (sumo_x - SUMO_CENTER) * SUMO_SCALE
		var godot_z: float = (sumo_y - SUMO_CENTER) * SUMO_SCALE
		var target_y: float = SIDEWALK_Y + LEG_HEIGHT + BODY_HEIGHT / 2.0

		# Check if this pedestrian is on a crossing (on the road surface)
		var edge: String = str(ped_data.get("edge", ""))
		if edge.begins_with(":J0_c"):
			target_y = LEG_HEIGHT + BODY_HEIGHT / 2.0  # Road level (no sidewalk)

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

	# Remove pedestrians no longer in the update
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
	legs.position = Vector3(0, -BODY_HEIGHT / 2.0 - LEG_HEIGHT / 2.0 + 0.05, 0)
	legs.material = leg_mat
	legs.name = "Legs"
	root.add_child(legs)

	# Torso
	var shirt_mat := StandardMaterial3D.new()
	shirt_mat.albedo_color = shirt_color
	var torso := CSGBox3D.new()
	torso.size = Vector3(BODY_WIDTH + 0.05, BODY_HEIGHT, BODY_DEPTH + 0.02)
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
