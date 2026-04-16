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
## Sizes tuned so cars look clear in the junction focal area and acceptably
## close (bumper-to-bumper) on the compressed roads.
const CAR_SIZE       := Vector3(0.6, 0.3, 1.0)
const TROTRO_SIZE    := Vector3(0.6, 0.4, 1.4)
const AMBULANCE_SIZE := Vector3(0.7, 0.45, 1.5)
const VEHICLE_Y      := 0.35

# ── SUMO → Godot coordinate transform ────────────────────────────────────────
## Junction J0 center in SUMO coordinates (from .net.xml)
const SUMO_ORIGIN_X: float = 1500.0
const SUMO_ORIGIN_Y: float = 1500.0
## Per-axis SUMO junction boundary distances from center (from intersection.net.xml)
## X axis (E/W): junction edges at x=1489.6 and x=1510.4
const SUMO_JUNC_HALF_X: float = 10.4
## Z axis (N/S — SUMO Y): junction edges at y=1492.8 and y=1507.2
const SUMO_JUNC_HALF_Z: float = 7.2
## Per-axis SUMO road lengths from junction edge to network endpoint
const SUMO_ROAD_LEN_X: float = 1489.6   ## E/W roads (3000 - 1510.4)
const SUMO_ROAD_LEN_Z: float = 1492.8   ## N/S roads (3000 - 1507.2)
## Godot junction half-width (JUNCTION_SIZE / 2 from Intersection.gd)
const GODOT_JUNC_HALF: float = 3.5
## Godot road length from junction edge (ROAD_LENGTH from Intersection.gd)
const GODOT_ROAD_LEN: float = 90.0

# ── Corridor mode ────────────────────────────────────────────────────────────
## When true, use piecewise mapping for corridor (3-junction layout).
## Expands junction areas and stretches road widths to match visual geometry.
var corridor_mode: bool = false

## SUMO net-offset: corridor.net.xml applies netOffset to all coords
## TraCI returns offset coords: J0=(1500,1500), J1=(1500,1800), J2=(1500,2100)
const CORRIDOR_OFFSET_X: float = 1500.0
const CORRIDOR_OFFSET_Y: float = 1500.0

## ── Corridor SUMO geometry (from corridor.net.xml junction shapes) ──────────
## Raw junction Y positions (offset-subtracted)
const C_J0_Y: float = 0.0
const C_J1_Y: float = 300.0
const C_J2_Y: float = 600.0
## Junction Y half-extents (from .net.xml shape bounding boxes)
const C_J0_HALF_Y: float = 10.4   # J0: y ∈ [-10.4, 10.4]
const C_J1_HALF_Y: float = 10.4   # J1: y ∈ [289.6, 310.4]
const C_J2_HALF_Y: float = 7.2    # J2: y ∈ [592.8, 607.2] (fewer E/W lanes)
## Junction X half-extent (same for all 3)
const C_JUNC_HALF_X: float = 10.4 # All junctions: x ∈ [-10.4, 10.4]

## SUMO road lengths between junction edges
const C_ROAD_J0J1: float = 279.2  # 289.6 - 10.4
const C_ROAD_J1J2: float = 282.4  # 592.8 - 310.4
const C_SOUTH_ROAD: float = 1489.6 # S boundary to J0 south edge
const C_NORTH_ROAD: float = 1492.8 # J2 north edge to N boundary
const C_CROSS_ROAD: float = 1489.6 # Junction edge to E/W boundary

## ── Corridor Godot geometry (must match CorridorBuilder.gd) ────────────────
const C_GD_J0_Z: float = 0.0
const C_GD_J1_Z: float = 18.0
const C_GD_J2_Z: float = 36.0
const C_GD_JUNC_HALF: float = 3.0   # JUNCTION_SIZE / 2
const C_GD_ROAD_J0J1: float = 12.0  # 15.0 - 3.0
const C_GD_ROAD_J1J2: float = 12.0  # 33.0 - 21.0
const C_GD_BOUNDARY: float = 30.0   # Boundary road length in Godot
const C_GD_CROSS_ARM: float = 30.0  # Cross-street arm length in Godot

# ── Animation ────────────────────────────────────────────────────────────────
const LERP_SPEED: float = 5.0     ## Position/rotation interpolation speed
const FADE_SPEED: float = 4.0     ## Fade-in/fade-out speed

# ── Boundary fade-out zones ──────────────────────────────────────────────────
## Vehicles approaching the edge of the visible Godot road gradually fade out
## instead of piling up.  Hides the extreme compression (49:1) on boundary
## roads and creates a natural "driving away" effect.
## Single-junction bounds: ±(GODOT_JUNC_HALF + GODOT_ROAD_LEN)
const SJ_BOUND: float = 93.5          # 3.5 + 90
const SJ_FADE_DIST: float = 15.0      # Start fading 15 units before edge
## Corridor bounds
const CR_Z_MIN: float = -33.0         # J0_Z - junc_half - boundary_road
const CR_Z_MAX: float = 69.0          # J2_Z + junc_half + boundary_road
const CR_X_BOUND: float = 33.0        # junc_half + cross_arm
const CR_FADE_DIST: float = 12.0      # Start fading 12 units before edge

# ── Pool limits ──────────────────────────────────────────────────────────────
var MAX_VEHICLES: int = 200

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

## Shared vehicle materials (created once, reused across all vehicles)
var _mat_windshield: StandardMaterial3D
var _mat_undercarriage: StandardMaterial3D
var _mat_roof_rack: StandardMaterial3D
var _mat_headlight: StandardMaterial3D   # Warm white, emissive at night
var _mat_taillight: StandardMaterial3D   # Red, emissive at night
var _is_night: bool = false


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	## Create shared vehicle materials.
	_mat_windshield = StandardMaterial3D.new()
	_mat_windshield.albedo_color = Color(0.1, 0.15, 0.25, 0.7)
	_mat_windshield.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_windshield.metallic = 0.6
	_mat_windshield.roughness = 0.2

	_mat_undercarriage = StandardMaterial3D.new()
	_mat_undercarriage.albedo_color = Color(0.08, 0.08, 0.08, 1.0)
	_mat_undercarriage.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_undercarriage.roughness = 0.9

	_mat_roof_rack = StandardMaterial3D.new()
	_mat_roof_rack.albedo_color = Color(0.35, 0.35, 0.38, 1.0)
	_mat_roof_rack.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_roof_rack.metallic = 0.5
	_mat_roof_rack.roughness = 0.4

	# Headlights — warm white, emission always on (nodes toggled via visibility)
	_mat_headlight = StandardMaterial3D.new()
	_mat_headlight.albedo_color = Color(1.0, 0.97, 0.85, 1.0)
	_mat_headlight.emission_enabled = true
	_mat_headlight.emission = Color(1.0, 0.95, 0.8)
	_mat_headlight.emission_energy_multiplier = 4.0
	_mat_headlight.roughness = 0.2

	# Taillights — red, emission always on (nodes toggled via visibility)
	_mat_taillight = StandardMaterial3D.new()
	_mat_taillight.albedo_color = Color(0.9, 0.1, 0.05, 1.0)
	_mat_taillight.emission_enabled = true
	_mat_taillight.emission = Color(1.0, 0.1, 0.05)
	_mat_taillight.emission_energy_multiplier = 3.0
	_mat_taillight.roughness = 0.2

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

		# --- Boundary fade: vehicles near road edges fade out smoothly ---
		var bfade: float = _get_boundary_fade(node.position)
		if bfade <= 0.0:
			# Beyond visible area — despawn immediately
			info["despawning"] = true
			continue

		# --- Fade in newly spawned vehicles (combine with boundary fade) ---
		if info["opacity"] < 1.0:
			info["opacity"] = minf(info["opacity"] + FADE_SPEED * delta, 1.0)

		# Apply effective opacity = spawn fade * boundary fade
		var effective_alpha: float = info["opacity"] * bfade
		_set_node_opacity(node, effective_alpha)

		# --- Ambulance light-bar pulse ---
		if info["is_ambulance"]:
			_pulse_light_bar(node)

	# Clean up fully faded-out vehicles
	for vid in to_remove:
		_release_vehicle(vid)


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

func set_night_mode(enabled: bool) -> void:
	## Toggle headlights, taillights, and windshield glow for night mode.
	## Uses VISIBILITY toggle (not material changes) so shared materials
	## aren't disrupted by the per-vehicle opacity system.
	_is_night = enabled

	# Windshield glow (shared material — safe since it's subtle)
	if _mat_windshield:
		_mat_windshield.emission_enabled = enabled
		if enabled:
			_mat_windshield.emission = Color(0.9, 0.85, 0.6)
			_mat_windshield.emission_energy_multiplier = 1.5

	# Toggle visibility of headlight/taillight nodes on ALL vehicles
	_toggle_all_vehicle_lights(enabled)


func _toggle_all_vehicle_lights(lights_on: bool) -> void:
	## Show/hide headlight and taillight CSG nodes on every vehicle.
	# Active vehicles
	for vid in _active:
		var veh_node: Node3D = _active[vid]["node"]
		_set_lights_visible(veh_node, lights_on)
	# Pooled cars (so they're correct when next acquired)
	for car in _car_pool:
		_set_lights_visible(car, lights_on)


func _set_lights_visible(veh_node: Node3D, lights_on: bool) -> void:
	## Toggle visibility of Headlight_* and Taillight_* children.
	for child in veh_node.get_children():
		var cname: String = child.name
		if cname.begins_with("Headlight") or cname.begins_with("Taillight"):
			child.visible = lights_on

func set_corridor_mode(enabled: bool) -> void:
	## Switch between single-junction and corridor coordinate mapping.
	corridor_mode = enabled
	if enabled:
		MAX_VEHICLES = 500  # 3 junctions need more vehicles
		print("[VehicleManager] Corridor mode enabled (linear mapping, max=%d)" % MAX_VEHICLES)


func update_vehicles(data: Dictionary) -> void:
	## Receive the full state packet and sync vehicles with SUMO data.
	# Auto-detect corridor mode from server data
	if data.get("mode", "") == "corridor" and not corridor_mode:
		set_corridor_mode(true)
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
			# If new target is beyond boundary, start despawning instead
			if _get_boundary_fade(pos) <= 0.0:
				if not _active[vid].get("despawning", false):
					_active[vid]["despawning"] = true
			else:
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
	## Map SUMO 2D coordinates → Godot 3D position.
	## NOTE: X axis is negated to flip left/right so the isometric camera
	## shows right-hand traffic (Ghana drives on the right).
	if corridor_mode:
		## Corridor: piecewise mapping that expands junction areas
		## and stretches road widths to match visual geometry.
		var dx: float = sx - CORRIDOR_OFFSET_X  # Offset-subtracted
		var dy: float = sy - CORRIDOR_OFFSET_Y
		var gx: float = -_map_corridor_x(dx)  # Negated for right-hand visual
		var gz: float = _map_corridor_z(dy)
		return Vector3(gx, VEHICLE_Y, gz)
	else:
		## Single junction: piecewise linear mapping
		## Uses per-axis junction boundaries (junction is NOT square in SUMO).
		## N/S edges at ±7.2 from center, E/W edges at ±10.4 from center.
		var dx: float = sx - SUMO_ORIGIN_X
		var dz: float = sy - SUMO_ORIGIN_Y
		var gx: float = -_map_axis(dx, SUMO_JUNC_HALF_X, SUMO_ROAD_LEN_X)  # Negated for right-hand visual
		var gz: float = _map_axis(dz, SUMO_JUNC_HALF_Z, SUMO_ROAD_LEN_Z)
		return Vector3(gx, VEHICLE_Y, gz)


func _map_axis(d: float, junc_half: float, road_len: float) -> float:
	## Map one axis: SUMO distance from center → Godot distance from center.
	var s: float = 1.0 if d >= 0.0 else -1.0
	var a: float = absf(d)
	if a <= junc_half:
		## Inside junction area: scale so junction edges align
		return s * a * (GODOT_JUNC_HALF / junc_half)
	else:
		## On road: junction edge → junction edge, then road scales separately
		var road_d: float = a - junc_half
		return s * (GODOT_JUNC_HALF + road_d * (GODOT_ROAD_LEN / road_len))


func _sumo_angle_to_godot(angle_deg: float) -> float:
	## SUMO angle (0=N clockwise) -> Godot rotation.y.
	## X axis is mirrored for right-hand traffic visual, so east/west swap.
	## Formula: 180 - angle (mirror of the original angle - 180).
	return deg_to_rad(180.0 - angle_deg)


# ═════════════════════════════════════════════════════════════════════════════
# CORRIDOR PIECEWISE MAPPING
# ═════════════════════════════════════════════════════════════════════════════

func _map_corridor_x(dx: float) -> float:
	## Map SUMO X (offset-subtracted) to Godot X.
	## Inside junction width → linear scale to Godot junction half.
	## Beyond junction edge → cross-street road scale.
	var s: float = 1.0 if dx >= 0.0 else -1.0
	var a: float = absf(dx)
	if a <= C_JUNC_HALF_X:
		return s * a * (C_GD_JUNC_HALF / C_JUNC_HALF_X)
	else:
		var road_d: float = a - C_JUNC_HALF_X
		return s * (C_GD_JUNC_HALF + road_d * (C_GD_CROSS_ARM / C_CROSS_ROAD))


func _map_corridor_z(dy: float) -> float:
	## Map SUMO Y (offset-subtracted) to Godot Z.
	## Piecewise linear through 3 junction zones and 4 road segments.
	## Each zone boundary is continuous with its neighbor.

	# ── Zone 1: South boundary road (dy < J0 south edge) ────────────
	var j0_south: float = C_J0_Y - C_J0_HALF_Y  # -10.4
	if dy < j0_south:
		var south_dist: float = j0_south - dy  # positive distance south
		return (C_GD_J0_Z - C_GD_JUNC_HALF) - south_dist * (C_GD_BOUNDARY / C_SOUTH_ROAD)

	# ── Zone 2: J0 junction ─────────────────────────────────────────
	var j0_north: float = C_J0_Y + C_J0_HALF_Y  # 10.4
	if dy <= j0_north:
		return C_GD_J0_Z + (dy - C_J0_Y) * (C_GD_JUNC_HALF / C_J0_HALF_Y)

	# ── Zone 3: Road J0 → J1 ────────────────────────────────────────
	var j1_south: float = C_J1_Y - C_J1_HALF_Y  # 289.6
	if dy < j1_south:
		var t: float = (dy - j0_north) / (j1_south - j0_north)
		return (C_GD_J0_Z + C_GD_JUNC_HALF) + t * C_GD_ROAD_J0J1

	# ── Zone 4: J1 junction ─────────────────────────────────────────
	var j1_north: float = C_J1_Y + C_J1_HALF_Y  # 310.4
	if dy <= j1_north:
		return C_GD_J1_Z + (dy - C_J1_Y) * (C_GD_JUNC_HALF / C_J1_HALF_Y)

	# ── Zone 5: Road J1 → J2 ────────────────────────────────────────
	var j2_south: float = C_J2_Y - C_J2_HALF_Y  # 592.8
	if dy < j2_south:
		var t: float = (dy - j1_north) / (j2_south - j1_north)
		return (C_GD_J1_Z + C_GD_JUNC_HALF) + t * C_GD_ROAD_J1J2

	# ── Zone 6: J2 junction ─────────────────────────────────────────
	var j2_north: float = C_J2_Y + C_J2_HALF_Y  # 607.2
	if dy <= j2_north:
		return C_GD_J2_Z + (dy - C_J2_Y) * (C_GD_JUNC_HALF / C_J2_HALF_Y)

	# ── Zone 7: North boundary road ─────────────────────────────────
	var north_dist: float = dy - j2_north  # positive distance north
	return (C_GD_J2_Z + C_GD_JUNC_HALF) + north_dist * (C_GD_BOUNDARY / C_NORTH_ROAD)


# ═════════════════════════════════════════════════════════════════════════════
# SPAWN / DESPAWN
# ═════════════════════════════════════════════════════════════════════════════

func _spawn_vehicle(vid: String, pos: Vector3, rot: float, vtype: String) -> void:
	## Create or recycle a vehicle node and add to _active tracking.
	# Skip vehicles that spawn beyond visible boundaries
	if _get_boundary_fade(pos) <= 0.0:
		return

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

func _acquire_car(vid: String) -> Node3D:
	## Get a car node from the pool, or create one.
	if _car_pool.size() > 0:
		var recycled: Node3D = _car_pool.pop_back()
		_color_car(recycled, vid)
		return recycled

	# Pool empty — create new
	var new_car := _make_car_mesh_for_vid(vid)
	add_child(new_car)
	return new_car


func _make_car_mesh_for_vid(vid: String) -> Node3D:
	## Create an enhanced car Node3D with body, cabin, windshield, undercarriage.
	var h: int = vid.hash()
	var is_trotro: bool = (abs(h) % 7 == 0)

	if is_trotro:
		var color := Color(0.95, 0.75, 0.05, 1.0)
		return _build_trotro_node("Car_%s" % vid.substr(0, 12), color)
	else:
		var color_idx: int = abs(h) % CAR_COLORS.size()
		var color: Color = CAR_COLORS[color_idx]
		return _build_car_node("Car_%s" % vid.substr(0, 12), color)


func _make_car_mesh(index: int) -> Node3D:
	## Pre-warm variant: create a car with index-based color.
	if index % 7 == 0:
		return _build_trotro_node("PoolCar_%d" % index, Color(0.95, 0.75, 0.05, 1.0))
	else:
		return _build_car_node("PoolCar_%d" % index, CAR_COLORS[index % CAR_COLORS.size()])


func _build_car_node(node_name: String, body_color: Color) -> Node3D:
	## Build a sedan: body + cabin + windshield + undercarriage.
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("is_trotro", false)

	# Body
	var body := CSGBox3D.new()
	body.size = CAR_SIZE
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = body_color
	body_mat.metallic = 0.3
	body_mat.roughness = 0.5
	body_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	body.material = body_mat
	body.name = "Body"
	root.add_child(body)

	# Cabin / roof step (darker shade, creates windshield silhouette)
	var cabin := CSGBox3D.new()
	cabin.size = Vector3(0.52, 0.12, 0.4)
	cabin.position = Vector3(0, 0.21, -0.1)
	var cabin_mat := StandardMaterial3D.new()
	cabin_mat.albedo_color = body_color * 0.8
	cabin_mat.albedo_color.a = 1.0
	cabin_mat.metallic = 0.3
	cabin_mat.roughness = 0.5
	cabin_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cabin.material = cabin_mat
	cabin.name = "Cabin"
	root.add_child(cabin)

	# Windshield (front-facing dark glass slab)
	var windshield := CSGBox3D.new()
	windshield.size = Vector3(0.50, 0.10, 0.02)
	windshield.position = Vector3(0, 0.20, -0.30)
	windshield.material = _mat_windshield
	windshield.name = "Windshield"
	root.add_child(windshield)

	# Undercarriage (dark strip reads as wheels from isometric angle)
	var undercarriage := CSGBox3D.new()
	undercarriage.size = Vector3(0.64, 0.05, 0.85)
	undercarriage.position = Vector3(0, -0.15, 0)
	undercarriage.material = _mat_undercarriage
	undercarriage.name = "Undercarriage"
	root.add_child(undercarriage)

	# Headlights (two small boxes at front — hidden during day, shown at night)
	for side in [-1.0, 1.0]:
		var hl := CSGBox3D.new()
		hl.size = Vector3(0.1, 0.06, 0.04)
		hl.position = Vector3(side * 0.2, 0.05, -0.52)
		hl.material = _mat_headlight
		hl.name = "Headlight_L" if side < 0 else "Headlight_R"
		hl.visible = _is_night
		root.add_child(hl)

	# Taillights (two small boxes at rear — hidden during day, shown at night)
	for side in [-1.0, 1.0]:
		var tl := CSGBox3D.new()
		tl.size = Vector3(0.1, 0.06, 0.04)
		tl.position = Vector3(side * 0.2, 0.05, 0.52)
		tl.material = _mat_taillight
		tl.name = "Taillight_L" if side < 0 else "Taillight_R"
		tl.visible = _is_night
		root.add_child(tl)

	return root


func _build_trotro_node(node_name: String, body_color: Color) -> Node3D:
	## Build a trotro/minibus: body + roof rack + windshield + undercarriage.
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("is_trotro", true)

	# Body
	var body := CSGBox3D.new()
	body.size = TROTRO_SIZE
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = body_color
	body_mat.metallic = 0.1
	body_mat.roughness = 0.7
	body_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	body.material = body_mat
	body.name = "Body"
	root.add_child(body)

	# Roof rack (key trotro visual differentiator)
	var rack := CSGBox3D.new()
	rack.size = Vector3(0.50, 0.03, 1.1)
	rack.position = Vector3(0, 0.22, 0)
	rack.material = _mat_roof_rack
	rack.name = "RoofRack"
	root.add_child(rack)

	# Windshield
	var windshield := CSGBox3D.new()
	windshield.size = Vector3(0.55, 0.14, 0.02)
	windshield.position = Vector3(0, 0.22, -0.68)
	windshield.material = _mat_windshield
	windshield.name = "Windshield"
	root.add_child(windshield)

	# Undercarriage
	var undercarriage := CSGBox3D.new()
	undercarriage.size = Vector3(0.64, 0.05, 1.3)
	undercarriage.position = Vector3(0, -0.18, 0)
	undercarriage.material = _mat_undercarriage
	undercarriage.name = "Undercarriage"
	root.add_child(undercarriage)

	# Headlights (hidden during day, shown at night)
	for side in [-1.0, 1.0]:
		var hl := CSGBox3D.new()
		hl.size = Vector3(0.12, 0.08, 0.04)
		hl.position = Vector3(side * 0.2, 0.05, -0.72)
		hl.material = _mat_headlight
		hl.name = "Headlight_L" if side < 0 else "Headlight_R"
		hl.visible = _is_night
		root.add_child(hl)

	# Taillights (hidden during day, shown at night)
	for side in [-1.0, 1.0]:
		var tl := CSGBox3D.new()
		tl.size = Vector3(0.12, 0.08, 0.04)
		tl.position = Vector3(side * 0.2, 0.05, 0.72)
		tl.material = _mat_taillight
		tl.name = "Taillight_L" if side < 0 else "Taillight_R"
		tl.visible = _is_night
		root.add_child(tl)

	return root


func _color_car(car_node: Node3D, vid: String) -> void:
	## Recolor an existing car node based on a new vehicle ID.
	var h: int = vid.hash()
	var is_trotro: bool = (abs(h) % 7 == 0)
	var was_trotro: bool = car_node.get_meta("is_trotro", false)

	# If vehicle type changed, rebuild the node in-place
	if is_trotro != was_trotro:
		# Remove old children
		for child in car_node.get_children():
			child.queue_free()
		# Rebuild as correct type
		var template: Node3D
		if is_trotro:
			template = _build_trotro_node("temp", Color(0.95, 0.75, 0.05, 1.0))
		else:
			var color_idx: int = abs(h) % CAR_COLORS.size()
			template = _build_car_node("temp", CAR_COLORS[color_idx])
		# Move children from template to existing node
		for child in template.get_children():
			template.remove_child(child)
			car_node.add_child(child)
		car_node.set_meta("is_trotro", is_trotro)
		template.queue_free()
		return

	# Same type — just recolor body and cabin
	var body_color: Color
	if is_trotro:
		body_color = Color(0.95, 0.75, 0.05, 1.0)
	else:
		var color_idx: int = abs(h) % CAR_COLORS.size()
		body_color = CAR_COLORS[color_idx]

	for child in car_node.get_children():
		if child.name == "Body" and child is CSGBox3D:
			var mat: StandardMaterial3D = child.material
			if mat:
				mat.albedo_color = body_color
				mat.albedo_color.a = 1.0
		elif child.name == "Cabin" and child is CSGBox3D:
			var mat: StandardMaterial3D = child.material
			if mat:
				mat.albedo_color = body_color * 0.8
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
	## Build ambulance: bright red body, white cross, pulsing light bar + glow.
	## Designed to be unmistakable among regular traffic.
	var root := Node3D.new()
	root.name = "Ambulance"

	# Body — bright red (highly visible against dark road)
	var body := CSGBox3D.new()
	body.size = AMBULANCE_SIZE
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.9, 0.05, 0.05)
	body_mat.emission_enabled = true
	body_mat.emission = Color(0.4, 0.0, 0.0)
	body_mat.emission_energy_multiplier = 1.5
	body_mat.metallic = 0.3
	body_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	body.material = body_mat
	body.name = "Body"
	root.add_child(body)

	# White cross stripe (horizontal)
	var stripe_h := CSGBox3D.new()
	stripe_h.size = Vector3(AMBULANCE_SIZE.x + 0.02, 0.1, 0.25)
	stripe_h.position = Vector3(0, 0.08, 0)
	var cross_mat := StandardMaterial3D.new()
	cross_mat.albedo_color = Color(1.0, 1.0, 1.0)
	cross_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	stripe_h.material = cross_mat
	stripe_h.name = "CrossH"
	root.add_child(stripe_h)

	# White cross stripe (vertical along length)
	var stripe_v := CSGBox3D.new()
	stripe_v.size = Vector3(0.18, 0.1, AMBULANCE_SIZE.z + 0.02)
	stripe_v.position = Vector3(0, 0.08, 0)
	var cross_mat_v := StandardMaterial3D.new()
	cross_mat_v.albedo_color = Color(1.0, 1.0, 1.0)
	cross_mat_v.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	stripe_v.material = cross_mat_v
	stripe_v.name = "CrossV"
	root.add_child(stripe_v)

	# Light bar — emissive, pulsing red/blue
	var light_bar := CSGBox3D.new()
	light_bar.size = Vector3(0.5, 0.1, 0.2)
	light_bar.position = Vector3(0, AMBULANCE_SIZE.y / 2.0 + 0.06, 0)
	var light_mat := StandardMaterial3D.new()
	light_mat.albedo_color = Color(1, 0, 0)
	light_mat.emission_enabled = true
	light_mat.emission = Color(1, 0, 0)
	light_mat.emission_energy_multiplier = 8.0
	light_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	light_bar.material = light_mat
	light_bar.name = "LightBar"
	root.add_child(light_bar)

	# OmniLight3D — visible glow that lights up surrounding road
	var glow := OmniLight3D.new()
	glow.position = Vector3(0, AMBULANCE_SIZE.y / 2.0 + 0.2, 0)
	glow.light_color = Color(1, 0, 0)
	glow.light_energy = 3.0
	glow.omni_range = 5.0
	glow.omni_attenuation = 1.5
	glow.shadow_enabled = false
	glow.name = "SirenGlow"
	root.add_child(glow)

	# Undercarriage (consistent with cars/trotros)
	var undercarriage := CSGBox3D.new()
	undercarriage.size = Vector3(0.74, 0.05, 1.4)
	undercarriage.position = Vector3(0, -0.20, 0)
	undercarriage.material = _mat_undercarriage
	undercarriage.name = "Undercarriage"
	root.add_child(undercarriage)

	return root


func _pulse_light_bar(amb_node: Node3D) -> void:
	## Animate the light bar and glow between red and blue.
	var light_bar: CSGBox3D = null
	var glow_light: OmniLight3D = null
	for child in amb_node.get_children():
		if child.name == "LightBar" and child is CSGBox3D:
			light_bar = child
		elif child.name == "SirenGlow" and child is OmniLight3D:
			glow_light = child
	if light_bar == null or light_bar.material == null:
		return
	var pulse: float = (sin(_pulse_time) + 1.0) / 2.0
	var color: Color = Color(1, 0, 0).lerp(Color(0, 0, 1), pulse)
	var mat: StandardMaterial3D = light_bar.material
	mat.emission = color
	mat.albedo_color = color
	if glow_light:
		glow_light.light_color = color
		glow_light.light_energy = 3.0 + 4.0 * pulse


# ═════════════════════════════════════════════════════════════════════════════
# OPACITY HELPERS
# ═════════════════════════════════════════════════════════════════════════════

func _set_node_opacity(node: Node3D, alpha: float) -> void:
	## Set the alpha on all materials of a vehicle node (car, trotro, ambulance).
	## Skips headlights/taillights — they use shared materials that must not be
	## touched by per-vehicle opacity (emission would flicker).
	for child in node.get_children():
		if child is CSGBox3D and child.material:
			var cname: String = child.name
			if cname.begins_with("Headlight") or cname.begins_with("Taillight"):
				continue
			var mat: StandardMaterial3D = child.material
			mat.albedo_color.a = alpha


# ═════════════════════════════════════════════════════════════════════════════
# BOUNDARY FADE
# ═════════════════════════════════════════════════════════════════════════════

func _get_boundary_fade(pos: Vector3) -> float:
	## Returns 1.0 if fully visible, 0.0 if beyond boundary, fractional in
	## the fade zone.  Works for both single-junction and corridor mode.
	if corridor_mode:
		# Z axis (north/south corridor length)
		var fz: float = _edge_fade(pos.z, CR_Z_MIN, CR_Z_MAX, CR_FADE_DIST)
		# X axis (east/west cross-streets)
		var fx: float = _edge_fade(pos.x, -CR_X_BOUND, CR_X_BOUND, CR_FADE_DIST)
		return minf(fz, fx)
	else:
		# Single junction — symmetric bounds on both axes
		var fx: float = _edge_fade(pos.x, -SJ_BOUND, SJ_BOUND, SJ_FADE_DIST)
		var fz: float = _edge_fade(pos.z, -SJ_BOUND, SJ_BOUND, SJ_FADE_DIST)
		return minf(fx, fz)


func _edge_fade(val: float, low: float, high: float, fade_dist: float) -> float:
	## Returns 1.0 when val is inside [low+fade, high-fade],
	## fades linearly to 0.0 at the boundaries [low, high],
	## and returns 0.0 outside [low, high].
	if val <= low or val >= high:
		return 0.0
	# Distance from the nearest edge
	var dist_from_edge: float = minf(val - low, high - val)
	if dist_from_edge >= fade_dist:
		return 1.0
	return clampf(dist_from_edge / fade_dist, 0.0, 1.0)
