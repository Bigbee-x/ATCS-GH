extends Node3D
var playback_clock: RefCounted
## Pedestrian system with ambient sidewalk walkers + SUMO-driven crossing.
##
## Two modes of operation:
## 1. Ambient: Self-animated pedestrians walking back and forth on sidewalks
## 2. Crossing: SUMO simulation-driven pedestrians crossing at junction
##    (positions received from server via vehicle_update packets)
##
## SUMO coordinate mapping:
##   Piecewise mapping matches the vehicle renderer. SUMO owns crossing routes.
##   Ambient walkers stay inside the sidewalk strips; origin is at the feet.

const Layout = preload("res://scripts/TrafficLayout.gd")
const Actor = preload("res://scripts/PedestrianActor.gd")
const NUM_AMBIENT := 42
const MIN_SPEED := 0.30
const MAX_SPEED := 0.62
const SIDEWALK_Y := 0.15
var _rng := RandomNumberGenerator.new()

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
const C_NS_ROAD_WIDTH   := 6.0
const C_JUNCTION_SIZE   := 6.0
const C_JUNCTION_HALF   := 3.0
const C_SIDEWALK_WIDTH  := 0.7
const C_CROSS_ARM       := 55.0
const C_BOUNDARY_ARM    := 55.0
const C_J0_Z            := 0.0
const C_J1_Z            := 30.0
const C_J2_Z            := 60.0

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
const C_GD_ROAD_J0J1: float = 24.0
const C_GD_ROAD_J1J2: float = 24.0
const C_GD_BOUNDARY: float = 55.0

# ── Sidewalk path definitions ─────────────────────────────────────────────────
var _sidewalk_paths: Array = []

# ── Ambient pedestrians ───────────────────────────────────────────────────────
var _ambient_peds: Array = []

# ── SUMO-driven crossing pedestrians ──────────────────────────────────────────
# pid (String) → {node: Node3D, target_pos: Vector3, snaps: Array, phase: float}
var _crossing_peds: Dictionary = {}
# Pool of reusable pedestrian meshes
var _crossing_pool: Array = []

# Snapshot-interpolation playback clock (see SnapClock.gd) — same scheme as
# VehicleManager: render ~1.5 sim-secs behind the newest packet, interpolating
# between known sim-time-stamped positions instead of easing toward the latest.
const SnapClock := preload("res://scripts/SnapClock.gd")
var _snap_clock: RefCounted = SnapClock.new()
const MAX_SNAPS: int = 4

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
	_rng.seed = 5309
	_define_sidewalk_paths()
	_spawn_ambient()


func _process(delta: float) -> void:
	if not _pedestrians_enabled:
		return

	if playback_clock != null:
		_snap_clock.render_t = playback_clock.render_t
	else:
		_snap_clock.advance(delta)
	_retire_crossing_pedestrians()

	for ped in _ambient_peds:
		_move_ambient(ped, delta)

	# Move crossing pedestrians by snapshot interpolation (falling back to the
	# legacy lerp when packets carry no sim_time), animating their stride only
	# while they're actually moving.
	for pid in _crossing_peds:
		var data: Dictionary = _crossing_peds[pid]
		var node: Node3D = data["node"]
		var prev: Vector3 = node.position
		var snaps: Array = data.get("snaps", [])
		if _snap_clock.is_active() and not snaps.is_empty():
			node.position = _sample_ped_snaps(snaps, _snap_clock.render_t)
		else:
			node.position = node.position.lerp(data["target_pos"], minf(delta * 8.0, 1.0))
		var displacement: Vector3 = node.position - prev
		displacement.y = 0.0
		var distance: float = displacement.length()
		var target_yaw: float = data.get("target_yaw", node.rotation.y)
		if distance > 0.0001:
			target_yaw = atan2(displacement.x, displacement.z)
		node.rotation.y = lerp_angle(node.rotation.y, target_yaw, 1.0 - exp(-delta * 9.0))
		node.animate(distance, distance / maxf(delta, 0.0001), delta)



static func _push_ped_snap(snaps: Array, t: float, pos: Vector3) -> void:
	## Append a sim-time-stamped position, keeping the buffer monotonic
	## (equal t skipped; backwards t = sim restart → reset).
	if not snaps.is_empty():
		var last_t: float = snaps.back()["t"]
		if t == last_t:
			return
		if t < last_t:
			snaps.clear()
	snaps.append({"t": t, "pos": pos})
	while snaps.size() > MAX_SNAPS:
		snaps.pop_front()


static func _sample_ped_snaps(snaps: Array, rt: float) -> Vector3:
	## Position at playback time rt — clamps to the buffer ends (holds, never
	## extrapolates), interpolating linearly between straddling snapshots.
	var first: Dictionary = snaps[0]
	if rt <= first["t"]:
		return first["pos"]
	var last: Dictionary = snaps[snaps.size() - 1]
	if rt >= last["t"]:
		return last["pos"]
	for i in range(snaps.size() - 1, 0, -1):
		var a: Dictionary = snaps[i - 1]
		var b: Dictionary = snaps[i]
		if rt >= a["t"] and rt <= b["t"]:
			var f: float = (rt - a["t"]) / maxf(b["t"] - a["t"], 0.001)
			return (a["pos"] as Vector3).lerp(b["pos"], f)
	return last["pos"]


# ═══════════════════════════════════════════════════════════════════════════════
# PATH DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════

func _define_sidewalk_paths() -> void:
	_sidewalk_paths = Layout.Metric.sidewalks(corridor_mode)


# ═══════════════════════════════════════════════════════════════════════════════
# AMBIENT PEDESTRIAN SPAWNING & MOVEMENT
# ═══════════════════════════════════════════════════════════════════════════════

func _spawn_ambient() -> void:
	for i in range(0):  # Both metric scenes render authoritative SUMO pedestrians.
		var ped_node: Node3D = _make_pedestrian_mesh()
		add_child(ped_node)
		var ped: Dictionary = {
			"node": ped_node, "path_idx": i % _sidewalk_paths.size(),
			"progress": _rng.randf_range(0.025, 0.975),
			"speed": _rng.randf_range(MIN_SPEED, MAX_SPEED) * (2.5 if corridor_mode else 1.0), "velocity": 0.0,
			"forward": _rng.randf() > 0.5, "pause": 0.0,
			"next_pause": _rng.randf_range(7.0, 28.0), "lateral": 0.0,
			"interest": _rng.randf() * TAU,
		}
		# Avoid spawning overlapping bodies on the same strip.
		for attempt in range(12):
			var crowded: bool = false
			var path: Dictionary = _sidewalk_paths[ped["path_idx"]]
			var path_length: float = path["start"].distance_to(path["end"])
			for other in _ambient_peds:
				if other["path_idx"] == ped["path_idx"] and absf(other["progress"] - ped["progress"]) * path_length < 0.9:
					crowded = true
			if not crowded:
				break
			ped["progress"] = _rng.randf_range(0.025, 0.975)
		_update_ambient_position(ped, 1.0, true)
		_ambient_peds.append(ped)

func _move_ambient(ped: Dictionary, delta: float) -> void:
	var path: Dictionary = _sidewalk_paths[ped["path_idx"]]
	var length: float = path["start"].distance_to(path["end"])
	var forward: bool = ped["forward"]
	var remaining: float = (1.0 - ped["progress"] if forward else ped["progress"]) * length
	ped["next_pause"] -= delta
	if ped["pause"] <= 0.0:
		if remaining < 0.07:
			ped["pause"] = _rng.randf_range(1.0, 1.8)
			ped["forward"] = not forward
			ped["velocity"] = 0.0
		elif ped["next_pause"] <= 0.0:
			ped["pause"] = _rng.randf_range(1.1, 3.8)
			ped["next_pause"] = _rng.randf_range(13.0, 35.0)
	var desired: float = ped["speed"] * clampf(remaining / 0.55, 0.12, 1.0)
	if ped["pause"] > 0.0:
		ped["pause"] = maxf(0.0, ped["pause"] - delta)
		desired = 0.0
	# Keep a following distance. Opposing walkers use separate passing lanes.
	for other in _ambient_peds:
		if other["node"] == ped["node"] or other["path_idx"] != ped["path_idx"]:
			continue
		var gap: float = (other["progress"] - ped["progress"]) * length * (1.0 if ped["forward"] else -1.0)
		if gap > 0.0 and gap < 0.7 and other["forward"] == ped["forward"]:
			desired = minf(desired, other["velocity"] * clampf((gap - 0.24) / 0.46, 0.0, 1.0))
	ped["velocity"] = move_toward(ped["velocity"], desired, delta * 0.75)
	var node: Node3D = ped["node"]
	var previous: Vector3 = node.position
	ped["progress"] = clampf(ped["progress"] + ped["velocity"] * delta / length * (1.0 if ped["forward"] else -1.0), 0.0, 1.0)
	_update_ambient_position(ped, delta)
	var distance: float = node.position.distance_to(previous)
	node.animate(distance, distance / maxf(delta, 0.0001), delta)

func _update_ambient_position(ped: Dictionary, delta: float, snap: bool = false) -> void:
	var path: Dictionary = _sidewalk_paths[ped["path_idx"]]
	var direction: Vector3 = (path["end"] - path["start"]).normalized()
	var side := Vector3(direction.z, 0, -direction.x)
	var pos: Vector3 = path["start"].lerp(path["end"], ped["progress"])
	var lane_width: float = 0.17 if corridor_mode else 0.24
	var lane: float = lane_width * (1.0 if ped["forward"] else -1.0)
	# Slight individual drift, bounded well inside the sidewalk edge.
	lane += sin(ped["progress"] * 16.0 + ped["interest"]) * (0.008 if corridor_mode else 0.025)
	ped["lateral"] = lane if snap else move_toward(ped["lateral"], lane, delta * 0.25)
	pos += side * ped["lateral"]
	pos.y = SIDEWALK_Y
	var node: Node3D = ped["node"]
	node.position = pos
	if not ped["forward"]:
		direction = -direction
	var yaw: float = atan2(direction.x, direction.z)
	node.rotation.y = yaw if snap else lerp_angle(node.rotation.y, yaw, 1.0 - exp(-delta * 5.0))


# ═══════════════════════════════════════════════════════════════════════════════
# SUMO-DRIVEN CROSSING PEDESTRIANS
# ═══════════════════════════════════════════════════════════════════════════════

func update_crossing_pedestrians(ped_list: Array, sim_time: float = -1.0) -> void:
	## Called from Main.gd when server sends pedestrian data.
	## ped_list: Array of {id, x, y, speed, angle, edge}
	## sim_time: the packet's authoritative timestamp (−1 = unstamped → legacy lerp).
	##
	## Both scenes render actual SUMO pedestrians on sidewalks and crossings.
	if not _pedestrians_enabled:
		return

	if _snap_clock.restarted(sim_time):
		for pid in _crossing_peds:
			_crossing_peds[pid]["snaps"].clear()
	_snap_clock.feed(sim_time)

	var seen: Dictionary = {}

	for ped_data in ped_list:
		var pid: String = str(ped_data.get("id", ""))
		if pid.is_empty():
			continue


		seen[pid] = true
		if _crossing_peds.has(pid):
			_crossing_peds[pid].erase("retire_at")

		var target_pos := Layout.pedestrian(ped_data, corridor_mode)

		if _crossing_peds.has(pid):
			# Update existing crossing pedestrian
			_crossing_peds[pid]["target_pos"] = target_pos
		else:
			# Acquire or create a pedestrian mesh
			var new_mesh: Node3D = _acquire_crossing_mesh()
			new_mesh.position = target_pos
			new_mesh.rotation.y = deg_to_rad(-float(ped_data.get("angle", 0.0)))
			_crossing_peds[pid] = {
				"node": new_mesh,
				"target_pos": target_pos,
				"snaps": [],              # sim-time-stamped position history
				"target_yaw": 0.0,
			}
		if sim_time >= 0.0:
			_push_ped_snap(_crossing_peds[pid]["snaps"], sim_time, target_pos)

		# Update facing direction from SUMO angle
		var angle_deg: float = float(ped_data.get("angle", 0.0))
		_crossing_peds[pid]["target_yaw"] = deg_to_rad(-angle_deg)

	# Retire on the playback clock, after their last crossing/curb snapshot.
	for pid in _crossing_peds:
		if not seen.has(pid) and not _crossing_peds[pid].has("retire_at"):
			_crossing_peds[pid]["retire_at"] = sim_time
	if sim_time < 0:
		_retire_crossing_pedestrians()

func _retire_crossing_pedestrians() -> void:
	for pid in _crossing_peds.keys():
		var data: Dictionary = _crossing_peds[pid]
		if data.has("retire_at") and (float(data.retire_at) < 0 or _snap_clock.render_t >= float(data.retire_at)):
			_release_crossing_mesh(data.node)
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
	var actor := Actor.new()
	actor.configure(_rng.randi())
	actor.scale *= 2.0
	actor.character_scale *= 2.0
	actor.name = "Pedestrian"
	actor.visible = _pedestrians_enabled
	return actor
