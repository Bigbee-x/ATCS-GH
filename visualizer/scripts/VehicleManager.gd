extends Node3D

const Layout = preload("res://scripts/TrafficLayout.gd")
const FleetActor = preload("res://scripts/VehicleActor.gd")
## Per-vehicle tracking with smooth animation.
##
## Each SUMO ID has a correctly typed pooled vehicle, with snapshot playback.
## Cars and trotros use shared curved coachwork and animated wheels; ambulances
## retain the bundled GLB and flashing light bar. Forward is local -Z.
const VEHICLE_Y := 0.35
const MODEL_SCALE := 0.40
const MODEL_Y_OFFSET := -0.30
const MODEL_YAW_OFFSET := PI
const AMBULANCE_MODEL: PackedScene = preload("res://assets/vehicles/ambulance.glb")

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
const C_GD_J1_Z: float = 30.0
const C_GD_J2_Z: float = 60.0
const C_GD_JUNC_HALF: float = 3.0   # JUNCTION_SIZE / 2
const C_GD_ROAD_J0J1: float = 24.0  # 27.0 - 3.0
const C_GD_ROAD_J1J2: float = 24.0  # 57.0 - 33.0
const C_GD_BOUNDARY: float = 55.0   # Boundary road length in Godot
const C_GD_CROSS_ARM: float = 55.0  # Cross-street arm length in Godot

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
const CR_Z_MIN: float = -58.0         # J0_Z - junc_half - boundary_road
const CR_Z_MAX: float = 118.0         # J2_Z + junc_half + boundary_road
const CR_X_BOUND: float = 58.0        # junc_half + cross_arm
const CR_FADE_DIST: float = 12.0      # Start fading 12 units before edge

# ── Pool limits ──────────────────────────────────────────────────────────────
var MAX_VEHICLES: int = 200

# ── Internal state ───────────────────────────────────────────────────────────
## Active vehicles: vid -> { node: Node3D, target_pos: Vector3,
##   target_rot: float, snaps: Array, type: String, opacity: float,
##   is_ambulance: bool }
var _active: Dictionary = {}

## Snapshot-interpolation playback clock (see SnapClock.gd). Packets stamp
## sim_time; vehicles render ~1.5 sim-secs behind the newest packet, lerping
## between known snapshots — smooth 60 fps motion from 1 Hz data.
const SnapClock := preload("res://scripts/SnapClock.gd")
var _clock: RefCounted = SnapClock.new()
const MAX_SNAPS: int = 4     # per-vehicle history (4 s at 1 Hz packets)

## Recyclable car nodes (hidden, ready for reuse)
var _car_pool: Array = []
var _trotro_pool: Array = []

## Recyclable ambulance nodes
var _amb_pool: Array = []

## Ambulance light-bar pulse timer
var _pulse_time: float = 0.0

## Shared vehicle materials (created once, reused across all vehicles)
var _is_night: bool = false
## True from ~16:30 onwards. When set WITHOUT _is_night, roughly
## DUSK_LIGHTS_THRESHOLD % of vehicles run their lights — mimics real-world
## behaviour where some drivers flip headlights on before full dark.
var _is_dusk: bool = false


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	## Attach the traffic soundscape (engine emitters + horns + wash). A child
	## of this node so it ships in both scenes with zero .tscn wiring; it reads
	## vehicles via audio_snapshot().
	var traffic_audio := preload("res://scripts/TrafficAudio.gd").new()
	traffic_audio.name = "TrafficAudio"
	add_child(traffic_audio)

	## Pre-warm the car pool with a few nodes.
	for i in range(40):
		var car := _make_car_mesh(i)
		car.visible = false
		add_child(car)
		_car_pool.append(car)


func _process(delta: float) -> void:
	_pulse_time += delta * 6.0

	# Advance the snapshot playback clock (no-op until stamped packets arrive)
	_clock.advance(delta)

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

		# --- Position/rotation: snapshot interpolation between the two known
		#     packets straddling render_t (never extrapolates); falls back to
		#     the legacy exponential lerp when packets carry no sim_time. ---
		var previous_position: Vector3 = node.position
		var previous_yaw: float = node.rotation.y
		var snaps: Array = info.get("snaps", [])
		if _clock.is_active() and not snaps.is_empty():
			var s: Dictionary = _sample_snaps(snaps, _clock.render_t)
			node.position = s["pos"]
			node.rotation.y = s["rot"]
			info["display_boarding"] = s.get("boarding",false)
		else:
			node.position = node.position.lerp(info["target_pos"], LERP_SPEED * delta)
			node.rotation.y = lerp_angle(node.rotation.y, info["target_rot"], LERP_SPEED * delta)

		if node.has_node("Coach"):
			var distance: float = previous_position.distance_to(node.position)
			node.get_node("Coach").animate(distance, angle_difference(previous_yaw, node.rotation.y), delta, _lights_on_for(vid), float(info.get("speed", 0.0)) < 0.3, info.get("display_boarding", info.get("boarding", false)))

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


static func _push_snap(snaps: Array, t: float, pos: Vector3, rot: float, boarding: bool = false) -> void:
	## Append a sim-time-stamped snapshot, keeping the buffer monotonic:
	## equal t (state_update repeating the last vehicle_update) is skipped;
	## t going backwards (stale buffer across a sim restart) resets it.
	if not snaps.is_empty():
		var last_t: float = snaps.back()["t"]
		if t == last_t:
			return
		if t < last_t:
			snaps.clear()
	snaps.append({"t": t, "pos": pos, "rot": rot, "boarding": boarding})
	while snaps.size() > MAX_SNAPS:
		snaps.pop_front()


static func _sample_snaps(snaps: Array, rt: float) -> Dictionary:
	## Pose at playback time rt, interpolating between the two snapshots that
	## straddle it. Clamps to the ends — HOLDS rather than extrapolates, so
	## late packets can never cause overshoot-and-reverse artifacts.
	var first: Dictionary = snaps[0]
	if rt <= first["t"]:
		return first
	var last: Dictionary = snaps[snaps.size() - 1]
	if rt >= last["t"]:
		return last
	for i in range(snaps.size() - 1, 0, -1):
		var a: Dictionary = snaps[i - 1]
		var b: Dictionary = snaps[i]
		if rt >= a["t"] and rt <= b["t"]:
			var f: float = (rt - a["t"]) / maxf(b["t"] - a["t"], 0.001)
			return {
				"t": rt,
				"pos": (a["pos"] as Vector3).lerp(b["pos"], f),
				"rot": lerp_angle(a["rot"], b["rot"], f),
				"boarding": a.get("boarding",false) and b.get("boarding",false),
			}
	return last


func audio_snapshot(cam_pos: Vector3, max_dist: float) -> Array:
	## Vehicles within max_dist of cam_pos as [{vid, node, speed, type, dist}],
	## nearest first. Consumed by TrafficAudio a few times per second to assign
	## engine emitters and pick horn candidates — cheap (one pass, no physics).
	var out: Array = []
	for vid in _active:
		var info: Dictionary = _active[vid]
		if info.get("despawning", false):
			continue
		var node: Node3D = info["node"]
		var dist: float = node.global_position.distance_to(cam_pos)
		if dist > max_dist:
			continue
		out.append({
			"vid": vid,
			"node": node,
			"speed": float(info.get("speed", 0.0)),
			"type": str(info.get("type", "car")),
			"dist": dist,
		})
	out.sort_custom(func(a, b): return a["dist"] < b["dist"])
	return out


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

## Weather-driven headlight modes, stacked on top of night mode.
##   OFF     — no weather demand (night mode alone still applies)
##   PARTIAL — only ~40 % of vehicles run lights (used for overcast)
##   ALL     — every vehicle runs lights (used for rain)
enum WeatherLights { OFF, PARTIAL, ALL }

const PARTIAL_LIGHTS_THRESHOLD: int = 40   # % of vehicles that run lights in partial mode
const DUSK_LIGHTS_THRESHOLD: int   = 60   # % of vehicles that run lights at dusk (before full night)

var _weather_lights: WeatherLights = WeatherLights.OFF


func set_night_mode(enabled: bool) -> void:
	## Toggle headlights, taillights, and windshield glow for night mode.
	## Uses VISIBILITY toggle (not material changes) so shared materials
	## aren't disrupted by the per-vehicle opacity system.
	_is_night = enabled
	_refresh_all_vehicle_lights()


func set_dusk_mode(enabled: bool) -> void:
	## Turn on headlights for a deterministic ~60 % of vehicles from
	## ~16:30 onwards. Composes with night mode (night still forces ALL on)
	## and with weather lights.
	_is_dusk = enabled
	_refresh_all_vehicle_lights()


func set_weather_lights_mode(mode: int) -> void:
	## Drive headlights from weather (0=OFF, 1=PARTIAL overcast, 2=ALL rain).
	## Composes with night mode — whichever calls for lights wins.
	_weather_lights = mode as WeatherLights
	_refresh_all_vehicle_lights()


func _refresh_all_vehicle_lights() -> void:
	## Recompute the windshield glow material + every vehicle's headlight
	## visibility from the current (night, weather) state.
	# Per-vehicle: active cars (we know their vid) → exact decision
	for vid in _active:
		var veh_node: Node3D = _active[vid]["node"]
		_set_lights_visible(veh_node, _lights_on_for(vid))
	# Pool cars are dark until acquired — _spawn_vehicle handles that path.
	for car in _car_pool:
		_set_lights_visible(car, false)


func _lights_on_for(vid: String) -> bool:
	## Per-vehicle lights decision, stable across frames for a given vid.
	if _is_night or _weather_lights == WeatherLights.ALL:
		return true
	# Dusk: ~60 % of drivers are "early adopters" — hash bucket keeps each
	# vehicle's choice consistent across frames. Checked before weather
	# partial so dusk's larger share wins if both apply.
	if _is_dusk:
		return absi(vid.hash()) % 100 < DUSK_LIGHTS_THRESHOLD
	if _weather_lights == WeatherLights.PARTIAL:
		# Deterministic hash bucket so the same car keeps the same behaviour
		return absi(vid.hash()) % 100 < PARTIAL_LIGHTS_THRESHOLD
	return false


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
		print("[VehicleManager] Corridor mode enabled (shared road layout, max=%d)" % MAX_VEHICLES)


func update_vehicles(data: Dictionary) -> void:
	## Receive the full state packet and sync vehicles with SUMO data.
	# Auto-detect corridor mode from server data
	if data.get("mode", "") == "corridor" and not corridor_mode:
		set_corridor_mode(true)
	var vehicle_list: Array = data.get("vehicles", []).duplicate()
	# A busy overview may hit the rendering cap; keep station services visible.
	vehicle_list.sort_custom(func(a, b): return a.has("station_id") and not b.has("station_id"))
	var seen: Dictionary = {}

	# Snapshot clock: feed the packet's authoritative sim_time. On sim restart
	# (time jumps backwards) the per-vehicle buffers hold stale future-times —
	# clear them (SUMO flow ids repeat across runs, so ids alone can't tell).
	var t: float = float(data.get("sim_time", -1.0))
	if _clock.restarted(t):
		for vid in _active:
			_active[vid]["snaps"].clear()
	_clock.feed(t)

	var display_positions := Layout.vehicle_positions(vehicle_list, corridor_mode)
	for v in vehicle_list:
		var vid: String = str(v.get("id", ""))
		if vid.is_empty():
			continue
		seen[vid] = true

		if not display_positions.has(vid):
			seen.erase(vid)
			continue
		var pos: Vector3 = display_positions[vid]
		# Curbside stop alignment is visual only; longitudinal motion remains SUMO's.
		if v.has("station_id"):
			var remaining: float = float(v.get("stop_distance",10000.0))
			var approach: float = smoothstep(85.0,10.0,remaining) if remaining >= 0 else 1.0-smoothstep(0.0,32.0,-remaining)
			if absf(remaining) < 85:
				var curb: float = 2.42 if corridor_mode else 2.62
				var bay: float = float(v.get("bay_x", signf(pos.x) * curb))
				pos.x = lerpf(pos.x, bay, approach)
				if v.has("bay_x"):
					pos.y = lerpf(pos.y, 0.45, approach)
		var rot := _sumo_angle_to_godot(v.get("angle", 0.0))
		var vtype: String = str(v.get("type", "DEFAULT_VEHTYPE"))

		if _active.has(vid):
			# Update existing vehicle's target
			# If new target is beyond boundary, start despawning instead
			if _get_boundary_fade(pos) <= 0.0:
				if not _active[vid].get("despawning", false):
					_active[vid]["despawning"] = true
			else:
				_active[vid]["despawning"] = false
				_active[vid]["target_pos"] = pos
				_active[vid]["target_rot"] = rot
				_active[vid]["speed"] = float(v.get("speed", 0.0))
				if t >= 0.0:
					_push_snap(_active[vid]["snaps"], t, pos, rot, v.get("boarding",false))
		else:
			# Spawn new vehicle
			if _active.size() >= MAX_VEHICLES:
				if v.has("station_id"):
					_make_room_for_transit()
				if _active.size() >= MAX_VEHICLES:
					continue
			_spawn_vehicle(vid, pos, rot, vtype)
			if t >= 0.0 and _active.has(vid):
				_push_snap(_active[vid]["snaps"], t, pos, rot, v.get("boarding",false))

		if _active.has(vid):
			_active[vid]["speed"] = float(v.get("speed",0.0))
			_active[vid]["boarding"] = v.get("boarding",false)
			_active[vid]["station_id"] = v.get("station_id","")
			if _active[vid]["node"].has_node("Coach") and v.has("destination"):
				_active[vid]["node"].get_node("Coach").set_destination(v["destination"])

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


func _make_room_for_transit() -> void:
	var camera := get_viewport().get_camera_3d()
	var origin: Vector3 = camera.global_position if camera else Vector3.ZERO
	var candidate: String = ""
	var farthest: float = -1.0
	for vid in _active:
		var info: Dictionary = _active[vid]
		if info["type"] != "car" or not str(info.get("station_id", "")).is_empty():
			continue
		var distance: float = info["node"].global_position.distance_squared_to(origin)
		if distance > farthest:
			candidate = vid
			farthest = distance
	if not candidate.is_empty():
		_release_vehicle(candidate)


# ═════════════════════════════════════════════════════════════════════════════
# COORDINATE MAPPING
# ═════════════════════════════════════════════════════════════════════════════

func _sumo_to_godot(sx: float, sy: float) -> Vector3:
	return Layout.map_position(sx, sy, corridor_mode)


func _sumo_angle_to_godot(angle_deg: float) -> float:
	## SUMO angle (0=N clockwise) -> Godot rotation.y.
	## X axis is mirrored for right-hand traffic visual, so east/west swap.
	## Formula: 180 - angle (mirror of the original angle - 180).
	return deg_to_rad(180.0 - angle_deg)


# ═════════════════════════════════════════════════════════════════════════════
# CORRIDOR PIECEWISE MAPPING
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
		node = _acquire_car(vid, vtype)

	node.position = pos
	node.rotation.y = rot
	node.visible = true

	# Apply the current night/weather lights decision to this specific vehicle.
	# Pool nodes come back with lights hidden (see _refresh_all_vehicle_lights),
	# so without this step a car acquired during rain would spawn dark.
	_set_lights_visible(node, _lights_on_for(vid))

	_active[vid] = {
		"node": node,
		"target_pos": pos,
		"target_rot": rot,
		"snaps": [],          # sim-time-stamped {t, pos, rot} history
		"speed": 0.0,         # latest SUMO-reported speed (m/s) — audio pitch
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
	elif info["type"] == "trotro":
		_trotro_pool.append(node)
	else:
		_car_pool.append(node)

	_active.erase(vid)


# ═════════════════════════════════════════════════════════════════════════════
# NODE POOL — CARS
# ═════════════════════════════════════════════════════════════════════════════

func _acquire_car(vid: String, vtype: String = "car") -> Node3D:
	var pool: Array = _trotro_pool if vtype == "trotro" else _car_pool
	if not pool.is_empty():
		return pool.pop_back()
	var node := _build_fleet_node("TrafficVehicle", "trotro" if vtype == "trotro" else "car", vid.hash())
	add_child(node)
	return node

func _make_car_mesh(index: int) -> Node3D:
	return _build_fleet_node("PoolCar_%d" % index, "car", index)

func _build_car_node(node_name: String) -> Node3D:
	return _build_fleet_node(node_name, "car", node_name.hash())

func _build_trotro_node(node_name: String) -> Node3D:
	return _build_fleet_node(node_name, "trotro", node_name.hash())

func _build_fleet_node(node_name: String, kind: String, seed_value: int) -> Node3D:
	var root := Node3D.new()
	root.name = node_name
	root.set_meta("is_trotro", kind == "trotro")
	var coach := FleetActor.new()
	coach.name = "Coach"
	coach.configure(kind, seed_value)
	coach.position.y = -0.30
	root.add_child(coach)
	return root

func _prepare_model_for_fade(model_root: Node3D) -> void:
	for mi in _all_mesh_instances(model_root):
		var src: Material = mi.get_active_material(0)
		if src is BaseMaterial3D:
			var material := src.duplicate() as BaseMaterial3D
			material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_HASH
			mi.material_override = material

func _all_mesh_instances(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_all_mesh_instances(c))
	return out


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
	## Realistic ambulance — the Kenney model + a pulsing red/blue siren bar and
	## glow on top so it stays unmistakable in traffic (_pulse_light_bar animates
	## the LightBar + SirenGlow by name).
	var root := Node3D.new()
	root.name = "Ambulance"
	root.set_meta("is_model", true)

	var m: Node3D = AMBULANCE_MODEL.instantiate()
	m.name = "Model"
	m.scale = Vector3(MODEL_SCALE, MODEL_SCALE, MODEL_SCALE)
	m.position = Vector3(0.0, MODEL_Y_OFFSET, 0.0)
	m.rotation.y = MODEL_YAW_OFFSET
	_prepare_model_for_fade(m)
	root.add_child(m)

	# Pulsing light bar on the roof (ambulance body is ~0.64 tall after scale)
	var light_bar := CSGBox3D.new()
	light_bar.size = Vector3(0.42, 0.08, 0.18)
	light_bar.position = Vector3(0, 0.52, 0)
	var light_mat := StandardMaterial3D.new()
	light_mat.albedo_color = Color(1, 0, 0)
	light_mat.emission_enabled = true
	light_mat.emission = Color(1, 0, 0)
	light_mat.emission_energy_multiplier = 8.0
	light_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	light_bar.material = light_mat
	light_bar.name = "LightBar"
	root.add_child(light_bar)

	# OmniLight3D — visible glow that lights up the surrounding road
	var glow := OmniLight3D.new()
	glow.position = Vector3(0, 0.66, 0)
	glow.light_color = Color(1, 0, 0)
	glow.light_energy = 3.0
	glow.omni_range = 5.0
	glow.omni_attenuation = 1.5
	glow.shadow_enabled = false
	glow.name = "SirenGlow"
	root.add_child(glow)

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
	if node.has_node("Coach"):
		node.get_node("Coach").set_opacity(alpha)
		return
	## Fade a vehicle by setting alpha on its materials. Skips headlights/
	## taillights (shared emissive materials). The "Model" child is a GLB
	## instance whose meshes carry per-instance transparent material copies.
	for child in node.get_children():
		if child.name == "Model":
			for mi in _all_mesh_instances(child):
				var om := mi.material_override as BaseMaterial3D
				if om:
					om.albedo_color.a = alpha
		elif child is CSGBox3D and child.material:
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
