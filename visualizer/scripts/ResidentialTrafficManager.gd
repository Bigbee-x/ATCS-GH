extends Node3D
## Ambient residential traffic for the SE quadrant's internal street grid.
##
## Purely client-side — these cars never touch SUMO, never report metrics,
## never queue at the main junction. They loop the residential network for
## visual life, same pattern as PedestrianManager's `_ambient_peds`.
##
## Street layout (single-junction SE quadrant, mirrored into world via
## QUAD_XS / QUAD_ZS = -1, matching EnvironmentBuilder.gd):
##
##                  (N, toward main road)
##           ne1 ──────────── ne2            z_local = 5
##            │                │
##    ww1 ── ix1 ── ── ── ── ix2 ── ee1      z_local = 38
##            │                │
##    ww2 ── ix3 ── ── ── ── ix4 ── ee2      z_local = 62
##            │                │
##           se1              se2            z_local = 85 (dead end)
##
## Cars pick a random outgoing edge at each intersection (never U-turn unless
## forced by a dead end). Right-hand traffic → cars drive on the right of the
## centerline.

# ── Tuning ──────────────────────────────────────────────────────────────────
const NUM_CARS        : int   = 8
const SPEED_MIN       : float = 1.0        # Godot u/sec (~16 km/h)
const SPEED_MAX       : float = 1.6        # (~26 km/h)
const LANE_OFFSET     : float = 0.6        # from centerline, right side
const TURN_LERP_SPEED : float = 7.0        # how fast cars rotate into new heading
const CAR_COLORS: Array = [
	Color(0.85, 0.15, 0.15),   # red
	Color(0.15, 0.35, 0.75),   # blue
	Color(0.95, 0.95, 0.95),   # white
	Color(0.20, 0.20, 0.22),   # black
	Color(0.55, 0.55, 0.55),   # silver
	Color(0.95, 0.70, 0.20),   # taxi yellow
	Color(0.20, 0.50, 0.30),   # green
]

# Quadrant mirror (must match EnvironmentBuilder.gd SE quadrant)
const QUAD_XS : float = -1.0
const QUAD_ZS : float = -1.0
const CAR_Y   : float = 0.13             # undercarriage bottom rests on the 0.08-high asphalt slab

# ── Waypoint graph (local coords, pre-mirror) ──────────────────────────────
# Interior intersections (4-way): ix1..ix4
# Street endpoints (dead ends): ne*, se*, ww*, ee*
var NODES: Dictionary = {
	"ne1": Vector2(35,  5),  "ne2": Vector2(57,  5),
	"se1": Vector2(35, 85),  "se2": Vector2(57, 85),
	"ww1": Vector2( 5, 38),  "ww2": Vector2( 5, 62),
	"ee1": Vector2(85, 38),  "ee2": Vector2(85, 62),
	"ix1": Vector2(35, 38),  "ix2": Vector2(57, 38),
	"ix3": Vector2(35, 62),  "ix4": Vector2(57, 62),
}

# Undirected adjacency
var ADJ: Dictionary = {
	"ne1": ["ix1"],
	"ne2": ["ix2"],
	"se1": ["ix3"],
	"se2": ["ix4"],
	"ww1": ["ix1"],
	"ww2": ["ix3"],
	"ee1": ["ix2"],
	"ee2": ["ix4"],
	"ix1": ["ne1", "ix3", "ww1", "ix2"],
	"ix2": ["ne2", "ix4", "ix1", "ee1"],
	"ix3": ["ix1", "se1", "ww2", "ix4"],
	"ix4": ["ix2", "se2", "ix3", "ee2"],
}

# ── State ───────────────────────────────────────────────────────────────────
var _cars: Array = []
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()

# Corridor mode: set true on the corridor scene's node to drive the corridor's
# south +X residential suburb (world coords, no quadrant mirror) instead of the
# single-junction SE quadrant.
@export var corridor_mode: bool = false
var _qx: float = QUAD_XS
var _qz: float = QUAD_ZS
var _num_cars: int = NUM_CARS


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_rng.seed = 7341   # deterministic palette / starting positions
	if corridor_mode:
		_configure_corridor()
	_spawn_all()


func _configure_corridor() -> void:
	## Point the ambient cars at the corridor's south +X residential suburb
	## (centre 38, −32). World coords, no quadrant mirror. Must match the street
	## grid laid by EnvironmentBuilder._corridor_residential for that block.
	_qx = 1.0
	_qz = 1.0
	_num_cars = 12
	NODES = {
		"ix1": Vector2(31, -39.5), "ix2": Vector2(45, -39.5),
		"ix3": Vector2(31, -24.5), "ix4": Vector2(45, -24.5),
		"n1": Vector2(31, -53), "n2": Vector2(45, -53),
		"s1": Vector2(31, -11), "s2": Vector2(45, -11),
		"w1": Vector2(18, -39.5), "w2": Vector2(18, -24.5),
		"e1": Vector2(58, -39.5), "e2": Vector2(58, -24.5),
	}
	ADJ = {
		"n1": ["ix1"], "n2": ["ix2"], "s1": ["ix3"], "s2": ["ix4"],
		"w1": ["ix1"], "w2": ["ix3"], "e1": ["ix2"], "e2": ["ix4"],
		"ix1": ["n1", "ix3", "w1", "ix2"],
		"ix2": ["n2", "ix4", "ix1", "e1"],
		"ix3": ["ix1", "s1", "w2", "ix4"],
		"ix4": ["ix2", "s2", "ix3", "e2"],
	}


func _process(delta: float) -> void:
	for car in _cars:
		_advance(car, delta)


# ═════════════════════════════════════════════════════════════════════════════
# SPAWN
# ═════════════════════════════════════════════════════════════════════════════

func _spawn_all() -> void:
	var edges: Array = _all_undirected_edges()
	for i in range(_num_cars):
		var e: Array = edges[_rng.randi() % edges.size()]
		# Randomize direction along the edge
		var from_key: String = e[0]
		var to_key: String = e[1]
		if _rng.randf() < 0.5:
			from_key = e[1]
			to_key = e[0]
		var car: Dictionary = {
			"node":     _build_car_mesh(),
			"prev":     from_key,
			"curr":     to_key,
			"progress": _rng.randf_range(0.05, 0.85),
			"speed":    _rng.randf_range(SPEED_MIN, SPEED_MAX),
			"yaw":      0.0,   # current render yaw (lerps toward heading)
		}
		add_child(car["node"])
		_cars.append(car)
		_update_car_transform(car, true)


func _all_undirected_edges() -> Array:
	var out: Array = []
	for key in ADJ.keys():
		for neighbor in ADJ[key]:
			if String(key) < String(neighbor):
				out.append([key, neighbor])
	return out


# ═════════════════════════════════════════════════════════════════════════════
# MOVEMENT
# ═════════════════════════════════════════════════════════════════════════════

func _advance(car: Dictionary, delta: float) -> void:
	var a: Vector2 = NODES[car["prev"]]
	var b: Vector2 = NODES[car["curr"]]
	var edge_len: float = a.distance_to(b)
	if edge_len < 0.01:
		return

	car["progress"] += (delta * float(car["speed"])) / edge_len

	if car["progress"] >= 1.0:
		# Arrived at `curr`. Pick next neighbor, avoiding immediate U-turn.
		var neighbors: Array = ADJ[car["curr"]]
		var choices: Array = []
		for n in neighbors:
			if n != car["prev"]:
				choices.append(n)
		if choices.is_empty():
			# Dead end — forced U-turn
			choices = neighbors
		var next_key: String = choices[_rng.randi() % choices.size()]
		car["prev"] = car["curr"]
		car["curr"] = next_key
		car["progress"] = 0.0

	_update_car_transform(car, false, delta)


func _update_car_transform(car: Dictionary, snap_yaw: bool, delta: float = 0.0) -> void:
	var a: Vector2 = NODES[car["prev"]]
	var b: Vector2 = NODES[car["curr"]]
	var local_pos: Vector2 = a.lerp(b, clampf(car["progress"], 0.0, 1.0))

	# World pos (apply quadrant mirror)
	var world_pos := Vector3(local_pos.x * _qx, CAR_Y, local_pos.y * _qz)

	# Edge direction in world space
	var dir_local: Vector2 = (b - a)
	if dir_local.length_squared() < 0.0001:
		return
	dir_local = dir_local.normalized()
	var dir_world := Vector3(dir_local.x * _qx, 0.0, dir_local.y * _qz)

	# Right-hand lane offset (perpendicular to direction, on the right)
	# right = forward × up  →  (dx, 0, dz) × (0, 1, 0) = (-dz, 0, dx)
	var right_vec := Vector3(-dir_world.z, 0.0, dir_world.x)
	world_pos += right_vec * LANE_OFFSET

	car["node"].position = world_pos

	# Heading — Godot convention: mesh front is -Z, so yaw = atan2(-dx, -dz).
	var target_yaw: float = atan2(-dir_world.x, -dir_world.z)
	if snap_yaw:
		car["yaw"] = target_yaw
	else:
		car["yaw"] = lerp_angle(float(car["yaw"]), target_yaw, clampf(delta * TURN_LERP_SPEED, 0.0, 1.0))
	car["node"].rotation.y = float(car["yaw"])


# ═════════════════════════════════════════════════════════════════════════════
# CAR MESH — body + cabin + undercarriage (matches main-sim car silhouette)
# ═════════════════════════════════════════════════════════════════════════════

func _build_car_mesh() -> Node3D:
	var root := Node3D.new()
	root.name = "ResCar"

	var body_color: Color = CAR_COLORS[_rng.randi() % CAR_COLORS.size()]

	# Body
	var body := CSGBox3D.new()
	body.size = Vector3(0.6, 0.28, 1.0)
	body.position = Vector3(0, 0.14, 0)
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = body_color
	body_mat.metallic = 0.3
	body_mat.roughness = 0.4
	body.material = body_mat
	body.name = "Body"
	root.add_child(body)

	# Cabin / roof step — darker shade of body color
	var cabin := CSGBox3D.new()
	cabin.size = Vector3(0.54, 0.14, 0.48)
	cabin.position = Vector3(0, 0.34, -0.08)
	var cabin_mat := StandardMaterial3D.new()
	cabin_mat.albedo_color = body_color * 0.72
	cabin_mat.metallic = 0.2
	cabin.material = cabin_mat
	cabin.name = "Cabin"
	root.add_child(cabin)

	# Undercarriage — reads as wheels from iso view
	var under := CSGBox3D.new()
	under.size = Vector3(0.64, 0.05, 0.92)
	under.position = Vector3(0, -0.02, 0)
	var under_mat := StandardMaterial3D.new()
	under_mat.albedo_color = Color(0.08, 0.08, 0.08)
	under.material = under_mat
	under.name = "Under"
	root.add_child(under)

	return root
