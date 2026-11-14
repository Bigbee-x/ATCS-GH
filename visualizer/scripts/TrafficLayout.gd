extends RefCounted
## Shared road-space contract for vehicles, crossings and stop markings.
## SUMO coordinates are front-bumper positions; visual actors are centred.
const CROSSING_WIDTH := 0.8
const STOP_GAP := 0.5
static var _axis_cache: Dictionary = {}

static func widths(corridor: bool, junction: int = 0) -> Vector3:
	# N/S, east arm (-X), west arm (+X).
	if not corridor:
		return Vector3(6.4, 6.4, 6.4)
	return [Vector3(6, 5, 3), Vector3(6, 5, 5), Vector3(6, 3, 3)][junction]

static func center(corridor: bool, junction: int) -> Vector3:
	return Vector3(0, 0, junction * 30.0 if corridor else 0.0)

static func crossing_distance(corridor: bool, junction: int, arm: int) -> float:
	var w := widths(corridor, junction)
	return (maxf(w.y, w.z) * 0.5 if arm in [0, 2] else w.x * 0.5) + 0.85

static func stop_distance(corridor: bool, junction: int, arm: int) -> float:
	return crossing_distance(corridor, junction, arm) + CROSSING_WIDTH * 0.5 + STOP_GAP

static func crossing(corridor: bool, junction: int, arm: int) -> Dictionary:
	var w := widths(corridor, junction)
	var c := center(corridor, junction)
	var d := crossing_distance(corridor, junction, arm)
	var margin: float = 0.24
	match arm:
		0: return {"start": c + Vector3(-w.x * 0.5 - margin, 0, d), "end": c + Vector3(w.x * 0.5 + margin, 0, d), "arm": arm}
		1: return {"start": c + Vector3(-d, 0, -w.y * 0.5 - margin), "end": c + Vector3(-d, 0, w.y * 0.5 + margin), "arm": arm}
		2: return {"start": c + Vector3(w.x * 0.5 + margin, 0, -d), "end": c + Vector3(-w.x * 0.5 - margin, 0, -d), "arm": arm}
		_: return {"start": c + Vector3(d, 0, w.z * 0.5 + margin), "end": c + Vector3(d, 0, -w.z * 0.5 - margin), "arm": arm}

static func half_length(kind: String) -> float:
	if "trotro" in kind.to_lower(): return 1.13
	if "ambulance" in kind.to_lower() or "emergency" in kind.to_lower(): return 1.0
	return 0.73

static func map_position(sx: float, sy: float, corridor: bool) -> Vector3:
	var x: float = sx - 1500.0
	var y: float = sy - 1500.0
	var junction: int = clampi(roundi(y / 300.0), 0, 2) if corridor else 0
	var w := widths(corridor, junction)
	var gx: float = -_sample(_x_anchors(corridor), x)
	var gz: float = _sample(_z_anchors(corridor), y)
	# Preserve lane offsets on asymmetric cross streets rather than squeezing
	# their traffic into the centre of the road.
	var local_y: float = y - (junction * 300.0 if corridor else 0.0)
	var road_half: float = (w.y if x >= 0 else w.z) * 0.5
	var sumo_half: float = 3.2 if corridor and road_half < 2.0 else 6.4
	if absf(x) > 4.5 and absf(local_y) <= sumo_half:
		var lateral: float = (junction * 30.0 if corridor else 0.0) + local_y * road_half / sumo_half
		gz = lerpf(gz, lateral, smoothstep(4.5, 6.4, absf(x)))
	return Vector3(gx, 0.35, gz)

static func _x_anchors(corridor: bool) -> Array:
	var key := "x" + str(corridor)
	if not _axis_cache.has(key):
		var half: float = widths(corridor).x * 0.5
		var cross_d: float = crossing_distance(corridor, 0, 1)
		var stop_d: float = stop_distance(corridor, 0, 1)
		var bound: float = 58.0 if corridor else 93.5
		_axis_cache[key] = [Vector2(-1500, -bound), Vector2(-32.4, -stop_d - 7.5), Vector2(-10.4, -stop_d), Vector2(-8.4, -cross_d), Vector2(-6.4, -half), Vector2(0, 0), Vector2(6.4, half), Vector2(8.4, cross_d), Vector2(10.4, stop_d), Vector2(32.4, stop_d + 7.5), Vector2(1500, bound)]
	return _axis_cache[key]

static func _z_anchors(corridor: bool) -> Array:
	var key := "z" + str(corridor)
	if not _axis_cache.has(key):
		var anchors: Array = [Vector2(-1500, -58.0 if corridor else -93.5)]
		for j in range(3 if corridor else 1):
			var raw: float = j * 300.0
			var visual: float = j * 30.0
			var extent: float = 7.2 if corridor and j == 2 else 10.4
			var w := widths(corridor, j)
			var half: float = maxf(w.y, w.z) * 0.5
			var cross_d: float = crossing_distance(corridor, j, 0)
			var stop_d: float = stop_distance(corridor, j, 0)
			anchors.append_array([Vector2(raw - extent - 22, visual - stop_d - 7.5), Vector2(raw - extent, visual - stop_d), Vector2(raw - extent + 2, visual - cross_d), Vector2(raw - extent + 4, visual - half), Vector2(raw, visual), Vector2(raw + extent - 4, visual + half), Vector2(raw + extent - 2, visual + cross_d), Vector2(raw + extent, visual + stop_d), Vector2(raw + extent + 22, visual + stop_d + 7.5)])
		anchors.append(Vector2(2100, 118) if corridor else Vector2(1500, 93.5))
		# Preserve the existing station platforms while distributing approach space.
		var stations: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/transit/stations.json"))
		for station in stations["corridor" if corridor else "single"]:
			var raw: float = 10.4 + station.pos if station.side < 0 else ((592.8 - station.pos) if corridor else -10.4 - station.pos)
			if station.has("sumo_y"):
				raw = float(station.sumo_y) - 1500.0
			anchors.append(Vector2(raw, station.z))
		anchors.sort_custom(func(a: Vector2, b: Vector2): return a.x < b.x)
		_axis_cache[key] = anchors
	return _axis_cache[key]

static func _sample(anchors: Array, value: float) -> float:
	for i in range(1, anchors.size()):
		var a: Vector2 = anchors[i - 1]
		var b: Vector2 = anchors[i]
		if value <= b.x:
			return lerpf(a.y, b.y, (value - a.x) / (b.x - a.x))
	return anchors.back().y

static func pedestrian(packet: Dictionary, corridor: bool) -> Vector3:
	var edge: String = packet.get("edge", "")
	var j: int = 0
	if corridor:
		j = clampi(int(edge.substr(2, 1)), 0, 2) if edge.begins_with(":J") else clampi(roundi((float(packet.y) - 1500.0) / 300.0), 0, 2)
	if "_c" in edge and not packet.has("crossing_progress"):
		packet = packet.duplicate()
		var arm: int = int(edge.get_slice("_c", 1))
		var raw_y: float = float(packet.y) - 1500.0 - j * 300.0
		var w := widths(corridor, j)
		var east_half: float = 3.2 if corridor and w.y < 4 else 6.4
		var west_half: float = 3.2 if corridor and w.z < 4 else 6.4
		packet["crossing_index"] = arm
		packet["crossing_progress"] = [(1506.4 - float(packet.x)) / 12.8, (raw_y + east_half) / (east_half * 2), (float(packet.x) - 1493.6) / 12.8, (west_half - raw_y) / (west_half * 2)][arm]
	if packet.has("crossing_progress"):
		var arm: int = int(packet.get("crossing_index", 0))
		var path := crossing(corridor, j, arm)
		var point: Vector3 = path.start.lerp(path.end, clampf(packet.crossing_progress, 0, 1))
		var tangent: Vector3 = (path.end - path.start).normalized()
		var lateral: float = clampf(float(packet.get("crossing_lateral", 0.0)), -1, 1)
		point -= Vector3(-tangent.z, 0, tangent.x) * lateral * CROSSING_WIDTH * 0.32
		point.y = 0.055
		var w := widths(corridor, j)
		var road_span: float = w.x if arm in [0, 2] else (w.y if arm == 1 else w.z)
		var cross_center: Vector3 = (path.start + path.end) * 0.5
		var across: float = absf((point - cross_center).dot(tangent))
		point.y = lerpf(0.055, 0.15, clampf((across - road_span * 0.5) / 0.24, 0, 1))
		return point
	# Junction waiting areas belong on the footway, never in the vehicle lanes.
	var at := map_position(float(packet.x), float(packet.y), corridor)
	var c := center(corridor, j)
	var w := widths(corridor, j)
	var side_x: float = signf(at.x)
	var side_z: float = signf(at.z - c.z)
	var sw: float = 1.35 if corridor else 1.5
	var half_z: float = (w.y if side_x < 0 else w.z) * 0.5
	at.x = side_x * clampf(absf(at.x), w.x * 0.5 + 0.2, w.x * 0.5 + sw - 0.16)
	at.z = c.z + side_z * clampf(absf(at.z - c.z), half_z + 0.2, crossing_distance(corridor, j, 0) + 0.18)
	at.y = 0.15
	return at

static func vehicle_positions(vehicles: Array, corridor: bool) -> Dictionary:
	# Fixed-size meshes need a minimum bumper gap on compressed approaches.
	# Preserve lane order and the leader's authoritative front position.
	var positions: Dictionary = {}
	var lanes: Dictionary = {}
	for v in vehicles:
		var heading: float = deg_to_rad(float(v.get("angle", 0)))
		var forward := Vector3(-sin(heading), 0, cos(heading))
		positions[v.id] = map_position(v.x, v.y, corridor) - forward * half_length(str(v.get("type", "car")))
		if v.has("lane") and not v.get("offroad", false) and not str(v.get("edge", ":")).begins_with(":"):
			if not lanes.has(v.lane): lanes[v.lane] = []
			lanes[v.lane].append(v)
	for lane in lanes.values():
		lane.sort_custom(func(a, b): return a.lane_position > b.lane_position)
		var previous: Dictionary = {}
		for v in lane:
			var half: float = half_length(v.type)
			var heading: float = deg_to_rad(v.angle)
			var forward := Vector3(-sin(heading), 0, cos(heading))
			var position: Vector3 = positions[v.id]
			var displaced: bool = false
			if not previous.is_empty():
				var gap: float = (previous.position - position).dot(forward)
				var minimum: float = half + float(previous.half) + 0.18
				if gap < minimum:
					position -= forward * (minimum - gap)
					displaced = true
			# Dense corridor queues have finite display capacity. Cull the tail
			# before it can spill visually into the preceding junction; SUMO
			# still simulates every vehicle and the leading queue stays intact.
			var origin: String = str(v.get("from_junction", ""))
			if displaced and origin.begins_with("J"):
				var j: int = int(origin.substr(1))
				var arm: int = (0 if forward.z > 0 else 2) if absf(forward.z) > 0.5 else (1 if forward.x < 0 else 3)
				if (position - center(corridor, j)).dot(forward) < crossing_distance(corridor, j, arm) + CROSSING_WIDTH * 0.5 + half:
					positions.erase(v.id)
					continue
			positions[v.id] = position
			previous = {"position": position, "half": half}
	return positions
