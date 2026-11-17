extends Node3D
var playback_clock: RefCounted
## Pedestrians as SUMO reports them, on footways and crossings.
##
## Positions arrive in vehicle_update packets and play back on the vehicles'
## snapshot clock. There are no decorative walkers: both metric scenes draw only
## SUMO's pedestrians, so what walks is what the simulation and controller see.

const Layout = preload("res://scripts/TrafficLayout.gd")
const Actor = preload("res://scripts/PedestrianActor.gd")
var _rng := RandomNumberGenerator.new()

var corridor_mode: bool = false

# ── SUMO pedestrians (footways and crossings) ─────────────────────────────────
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
		respawn()


func set_pedestrians_enabled(enabled: bool) -> void:
	## Toggle the SUMO pedestrians on/off.
	_pedestrians_enabled = enabled
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


func _process(delta: float) -> void:
	if not _pedestrians_enabled:
		return

	if playback_clock != null:
		_snap_clock.render_t = playback_clock.render_t
	else:
		_snap_clock.advance(delta)
	_retire_crossing_pedestrians()

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
# RESET
# ═══════════════════════════════════════════════════════════════════════════════

func respawn() -> void:
	## Clear all pedestrians (called on sim restart).
	for pid in _crossing_peds:
		_crossing_peds[pid]["node"].queue_free()
	_crossing_peds.clear()

	# Clear pool
	for node in _crossing_pool:
		node.queue_free()
	_crossing_pool.clear()


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
