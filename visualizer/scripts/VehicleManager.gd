extends Node3D
## Per-vehicle tracking with smooth animation.
##
## Each SUMO vehicle is represented 1:1 as a Godot CSGBox3D (or ambulance
## Node3D). Positions stream from the Python server every decision step
## and vehicles smoothly lerp toward their targets in _process().
##
## Vehicle lifecycle:
##   Spawn  — new ID in server data, acquire node from pool, snap to position
##   Update — existing ID, update target position/rotation (lerp animates)
##   Despawn — ID gone from server data, release node back to pool
##
## Coordinate mapping:
##   SUMO (x, y)  ->  Godot Vector3(x, 0.35, y)
##   SUMO angle   ->  Godot rotation.y = deg_to_rad(angle - 180)

# ── Vehicle geometry ─────────────────────────────────────────────────────────
const CAR_SIZE       := Vector3(1.2, 0.5, 2.2)
const TROTRO_SIZE    := Vector3(1.2, 0.65, 3.2)
const AMBULANCE_SIZE := Vector3(1.3, 0.6, 2.6)
const VEHICLE_Y      := 0.35

# ── SUMO → Godot coordinate transform ────────────────────────────────────────
## Junction J0 center in SUMO coordinates (from .net.xml)
const SUMO_ORIGIN_X: float = 500.0
const SUMO_ORIGIN_Y: float = 500.0
## Per-axis SUMO junction boundary distances from center (from intersection.net.xml)
## X axis (E/W): junction edges at x=489.6 and x=510.4
const SUMO_JUNC_HALF_X: float = 10.4
## Z axis (N/S — SUMO Y): junction edges at y=492.8 and y=507.2
const SUMO_JUNC_HALF_Z: float = 7.2
## Per-axis SUMO road lengths from junction edge to network endpoint
const SUMO_ROAD_LEN_X: float = 489.6   ## E/W roads (1000 - 510.4)
const SUMO_ROAD_LEN_Z: float = 492.8   ## N/S roads (1000 - 507.2)
## Godot junction half-width (JUNCTION_SIZE / 2 from Intersection.gd)
const GODOT_JUNC_HALF: float = 4.0
## Godot road length from junction edge (ROAD_LENGTH from Intersection.gd)
const GODOT_ROAD_LEN: float = 30.0

# ── Animation ────────────────────────────────────────────────────────────────
const LERP_SPEED: float = 5.0     ## Position/rotation interpolation speed
const FADE_SPEED: float = 4.0     ## Fade-in/fade-out speed

# ── Pool limits ──────────────────────────────────────────────────────────────
const MAX_VEHICLES: int = 200

# ── Accra street palette ─────────────────────────────────────────────────────
const CAR_COLORS: Array = [
	Color(0.15, 0.25, 0.65),   # Blue
	Color(0.65, 0.10, 0.10),   # Red
	Color(0.90, 0.90, 0.90),   # White
	Color(0.12, 0.12, 0.14),   # Black
	Color(0.55, 0.55, 0.55),   # Silver
	Color(0.05, 0.45, 0.20),   # Green
	Color(0.50, 0.30, 0.15),   # Brown
	Color(0.75, 0.20, 0.55),   # Maroon
]

# ── Internal state ───────────────────────────────────────────────────────────
## Active vehicles: vid -> { node: Node3D, target_pos: Vector3,
##   target_rot: float, type: String, opacity: float, is_ambulance: bool }
var _active: Dictionary = {}

## Recyclable car nodes (hidden, ready for reuse)
var _car_pool: Array = []

## Recyclable ambulance nodes
var _amb_pool: Array = []

## Ambulance light-bar pulse timer
var _pulse_time: float = 0.0


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	## Pre-warm the car pool with a few nodes.
	for i in range(40):
		var car := _make_car_mesh(i)
		car.visible = false
		add_child(car)
		_car_pool.append(car)


func _process(delta: float) -> void:
	_pulse_time += delta * 6.0

	## Smoothly move every active vehicle toward its target.
	var to_remove: Array = []

	for vid in _active:
		var info: Dictionary = _active[vid]
		var node: Node3D = info["node"]

		# --- Fade in newly spawned vehicles ---
		if info["opacity"] < 1.0:
			info["opacity"] = minf(info["opacity"] + FADE_SPEED * delta, 1.0)
			_set_node_opacity(node, info["opacity"])

		# --- Fade out despawning vehicles ---
		if info.get("despawning", false):
			info["opacity"] = maxf(info["opacity"] - FADE_SPEED * delta, 0.0)
			_set_node_opacity(node, info["opacity"])
			if info["opacity"] <= 0.0:
				to_remove.append(vid)
			continue

		# --- Lerp position ---
		node.position = node.position.lerp(info["target_pos"], LERP_SPEED * delta)

		# --- Lerp rotation ---
		node.rotation.y = lerp_angle(node.rotation.y, info["target_rot"], LERP_SPEED * delta)

		# --- Ambulance light-bar pulse ---
		if info["is_ambulance"]:
			_pulse_light_bar(node)

	# Clean up fully faded-out vehicles
	for vid in to_remove:
		_release_vehicle(vid)


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

func update_vehicles(data: Dictionary) -> void:
	## Receive the full state packet and sync vehicles with SUMO data.
	var vehicle_list: Array = data.get("vehicles", [])
	var seen: Dictionary = {}

	for v in vehicle_list:
		var vid: String = str(v.get("id", ""))
		if vid.is_empty():
			continue
		seen[vid] = true

		var pos := _sumo_to_godot(v.get("x", 0.0), v.get("y", 0.0))
		var rot := _sumo_angle_to_godot(v.get("angle", 0.0))
		var vtype: String = str(v.get("type", "DEFAULT_VEHTYPE"))

		if _active.has(vid):
			# Update existing vehicle's target
			_active[vid]["target_pos"] = pos
			_active[vid]["target_rot"] = rot
		else:
			# Spawn new vehicle
			if _active.size() >= MAX_VEHICLES:
				continue
			_spawn_vehicle(vid, pos, rot, vtype)

	# Mark vehicles for despawn that are no longer in the server data
	for vid in _active:
		if not seen.has(vid) and not _active[vid].get("despawning", false):
			_active[vid]["despawning"] = true


func clear_all() -> void:
	## Release all vehicles back to pool (called on sim restart).
	var all_vids: Array = _active.keys()
	for vid in all_vids:
		_release_vehicle(vid)
	_active.clear()


# ═════════════════════════════════════════════════════════════════════════════
# COORDINATE MAPPING
# ═════════════════════════════════════════════════════════════════════════════

func _sumo_to_godot(sx: float, sy: float) -> Vector3:
	## Piecewise linear mapping from SUMO 2D → Godot 3D.
	## Junction area uses junction scale, road area uses road scale.
	## This ensures cars on the road appear on the road, not in the junction.
	var dx: float = sx - SUMO_ORIGIN_X
	var dz: float = sy - SUMO_ORIGIN_Y
	return Vector3(_map_axis(dx), VEHICLE_Y, _map_axis(dz))


func _map_axis(d: float) -> float:
	## Map one axis: SUMO distance from center → Godot distance from center.
	var s: float = 1.0 if d >= 0.0 else -1.0
	var a: float = absf(d)
	if a <= SUMO_JUNC_HALF:
		## Inside junction area: scale so junction edges align
		return s * a * (GODOT_JUNC_HALF / SUMO_JUNC_HALF)
	else:
		## On road: junction edge maps to junction edge, then road scales separately
		var road_d: float = a - SUMO_JUNC_HALF
		return s * (GODOT_JUNC_HALF + road_d * (GODOT_ROAD_LEN / SUMO_ROAD_LEN))


func _sumo_angle_to_godot(angle_deg: float) -> float:
	## SUMO angle (0=N clockwise) -> Godot rotation.y.
	## SUMO 0=N(+Z), 90=E(+X), 180=S(-Z), 270=W(-X)
	## Godot rot 0=face -Z, PI=face +Z, -PI/2=face +X, PI/2=face -X
	return deg_to_rad(angle_deg - 180.0)


# ═════════════════════════════════════════════════════════════════════════════
# SPAWN / DESPAWN
# ═════════════════════════════════════════════════════════════════════════════

func _spawn_vehicle(vid: String, pos: Vector3, rot: float, vtype: String) -> void:
	## Create or recycle a vehicle node and add to _active tracking.
	var is_ambulance: bool = (vtype == "emergency")
	var node: Node3D

	if is_ambulance:
		node = _acquire_ambulance()
	else:
		node = _acquire_car(vid)

	node.position = pos
	node.rotation.y = rot
	node.visible = true

	_active[vid] = {
		"node": node,
		"target_pos": pos,
		"target_rot": rot,
		"type": vtype,
		"is_ambulance": is_ambulance,
		"opacity": 0.0,       # Fade in from 0
		"despawning": false,
	}


func _release_vehicle(vid: String) -> void:
	## Return a vehicle node to the pool.
	if not _active.has(vid):
		return
	var info: Dictionary = _active[vid]
	var node: Node3D = info["node"]
	node.visible = false
	_set_node_opacity(node, 1.0)  # Reset opacity for reuse

	if info["is_ambulance"]:
		_amb_pool.append(node)
	else:
		_car_pool.append(node)

	_active.erase(vid)


# ═════════════════════════════════════════════════════════════════════════════
# NODE POOL — CARS
# ═════════════════════════════════════════════════════════════════════════════

func _acquire_car(vid: String) -> CSGBox3D:
	## Get a car node from the pool, or create one.
	if _car_pool.size() > 0:
		var recycled: CSGBox3D = _car_pool.pop_back()
		# Re-color based on new vehicle ID
		_color_car(recycled, vid)
		return recycled

	# Pool empty — create new
	var new_car := _make_car_mesh_for_vid(vid)
	add_child(new_car)
	return new_car


func _make_car_mesh_for_vid(vid: String) -> CSGBox3D:
	## Create a car CSGBox3D with color determined by vehicle ID hash.
	var car := CSGBox3D.new()
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	# Hash the vehicle ID to get a consistent color & size
	var h: int = vid.hash()
	var is_trotro: bool = (abs(h) % 7 == 0)  # ~14% chance of trotro

	if is_trotro:
		car.size = TROTRO_SIZE
		mat.albedo_color = Color(0.95, 0.75, 0.05, 1.0)
		mat.metallic = 0.1
		mat.roughness = 0.7
	else:
		car.size = CAR_SIZE
		var color_idx: int = abs(h) % CAR_COLORS.size()
		mat.albedo_color = CAR_COLORS[color_idx]
		mat.metallic = 0.3
		mat.roughness = 0.5

	car.material = mat
	car.name = "Car_%s" % vid.substr(0, 12)
	return car


func _make_car_mesh(index: int) -> CSGBox3D:
	## Pre-warm variant: create a car with index-based color.
	var car := CSGBox3D.new()
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA

	if index % 7 == 0:
		car.size = TROTRO_SIZE
		mat.albedo_color = Color(0.95, 0.75, 0.05, 1.0)
		mat.metallic = 0.1
		mat.roughness = 0.7
	else:
		car.size = CAR_SIZE
		mat.albedo_color = CAR_COLORS[index % CAR_COLORS.size()]
		mat.metallic = 0.3
		mat.roughness = 0.5

	car.material = mat
	car.name = "PoolCar_%d" % index
	return car


func _color_car(car: CSGBox3D, vid: String) -> void:
	## Recolor an existing car node based on a new vehicle ID.
	var mat: StandardMaterial3D = car.material
	if mat == null:
		return
	var h: int = vid.hash()
	var is_trotro: bool = (abs(h) % 7 == 0)

	if is_trotro:
		car.size = TROTRO_SIZE
		mat.albedo_color = Color(0.95, 0.75, 0.05, 1.0)
	else:
		car.size = CAR_SIZE
		var color_idx: int = abs(h) % CAR_COLORS.size()
		mat.albedo_color = CAR_COLORS[color_idx]

	mat.albedo_color.a = 1.0


# ═════════════════════════════════════════════════════════════════════════════
# NODE POOL — AMBULANCES
# ═════════════════════════════════════════════════════════════════════════════

func _acquire_ambulance() -> Node3D:
	## Get an ambulance from pool, or create one.
	if _amb_pool.size() > 0:
		return _amb_pool.pop_back()

	var amb := _make_ambulance_node()
	add_child(amb)
	return amb


func _make_ambulance_node() -> Node3D:
	## Build ambulance: white body, red stripe, pulsing emissive light bar.
	var root := Node3D.new()
	root.name = "Ambulance"

	# Body — white
	var body := CSGBox3D.new()
	body.size = AMBULANCE_SIZE
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.95, 0.95, 0.95)
	body_mat.metallic = 0.2
	body_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	body.material = body_mat
	body.name = "Body"
	root.add_child(body)

	# Red stripe
	var stripe := CSGBox3D.new()
	stripe.size = Vector3(AMBULANCE_SIZE.x + 0.02, 0.12, AMBULANCE_SIZE.z + 0.02)
	stripe.position = Vector3(0, 0.08, 0)
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = Color(0.9, 0.05, 0.05)
	stripe_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	stripe.material = stripe_mat
	stripe.name = "Stripe"
	root.add_child(stripe)

	# Light bar — emissive, pulsing red/blue
	var light_bar := CSGBox3D.new()
	light_bar.size = Vector3(0.7, 0.12, 0.3)
	light_bar.position = Vector3(0, AMBULANCE_SIZE.y / 2.0 + 0.06, 0)
	var light_mat := StandardMaterial3D.new()
	light_mat.albedo_color = Color(1, 0, 0)
	light_mat.emission_enabled = true
	light_mat.emission = Color(1, 0, 0)
	light_mat.emission_energy_multiplier = 6.0
	light_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	light_bar.material = light_mat
	light_bar.name = "LightBar"
	root.add_child(light_bar)

	return root


func _pulse_light_bar(amb_node: Node3D) -> void:
	## Animate the light bar between red and blue.
	if amb_node.get_child_count() < 3:
		return
	var light_bar := amb_node.get_child(2) as CSGBox3D
	if light_bar == null or light_bar.material == null:
		return
	var mat: StandardMaterial3D = light_bar.material
	var pulse: float = (sin(_pulse_time) + 1.0) / 2.0
	var color: Color = Color(1, 0, 0).lerp(Color(0, 0, 1), pulse)
	mat.emission = color
	mat.albedo_color = color


# ═════════════════════════════════════════════════════════════════════════════
# OPACITY HELPERS
# ═════════════════════════════════════════════════════════════════════════════

func _set_node_opacity(node: Node3D, alpha: float) -> void:
	## Set the alpha on all materials of a vehicle node.
	if node is CSGBox3D:
		var mat: StandardMaterial3D = node.material
		if mat:
			mat.albedo_color.a = alpha
	else:
		# Ambulance — iterate children
		for child in node.get_children():
			if child is CSGBox3D and child.material:
				var mat: StandardMaterial3D = child.material
				mat.albedo_color.a = alpha
