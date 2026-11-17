extends RefCounted
## The metric display contract. Coordinates, lane IDs and shapes come from SUMO.
static var _data: Dictionary = {}
static var _edges: Dictionary = {}

## The simulated approaches run 1.5 km beyond the outer junctions, to where
## SUMO inserts traffic. Drawn in full they are long empty roads into nothing,
## so the corridor scene draws only this window of them (scene metres: min x,
## min z, size). It reaches past both trotro stations. Vehicles fade in as they
## enter it and out as they leave; SUMO, the HUD counts and the controller
## still see every vehicle on the full network.
const VIEW := Rect2(-380, -430, 760, 1460)
const VIEW_FADE := 35.0

static func clip_shape(shape: Array, corridor: bool = true) -> Array:
	## A lane polyline [[x, z], ...] cut to VIEW. Network roads are straight
	## runs, so each segment is kept, shortened or dropped.
	if not corridor:
		return shape
	var out: Array = []
	for i in range(1, shape.size()):
		var segment := _clip_segment(Vector2(shape[i-1][0], shape[i-1][1]), Vector2(shape[i][0], shape[i][1]))
		if segment.is_empty():
			continue
		if out.is_empty() or not Vector2(out[-1][0], out[-1][1]).is_equal_approx(segment[0]):
			out.append([segment[0].x, segment[0].y])
		out.append([segment[1].x, segment[1].y])
	return out

static func _clip_segment(a: Vector2, b: Vector2) -> Array:
	var t0: float = 0.0
	var t1: float = 1.0
	var d := b - a
	for edge in [[-d.x, a.x - VIEW.position.x], [d.x, VIEW.end.x - a.x], [-d.y, a.y - VIEW.position.y], [d.y, VIEW.end.y - a.y]]:
		var p: float = edge[0]
		var q: float = edge[1]
		if is_zero_approx(p):
			if q < 0.0:
				return []
		elif p < 0.0:
			t0 = maxf(t0, q / p)
		else:
			t1 = minf(t1, q / p)
	if t0 >= t1:
		return []
	return [a + d * t0, a + d * t1]

static func view_fade(at: Vector3, corridor: bool = true) -> float:
	## 1 well inside the drawn window, falling to 0 at its edge.
	if not corridor:
		return 1.0
	var inside: float = minf(minf(at.x - VIEW.position.x, VIEW.end.x - at.x), minf(at.z - VIEW.position.y, VIEW.end.y - at.z))
	return clampf(inside / VIEW_FADE, 0.0, 1.0)

static func data(corridor: bool = true) -> Dictionary:
	var key: String = "corridor" if corridor else "single"
	if not _data.has(key):
		_data[key] = JSON.parse_string(FileAccess.get_file_as_string("res://assets/network/%s.json" % key))
		_edges[key] = {}
		for e in _data[key].edges: _edges[key][e.id] = e
	return _data[key]

static func edge(id: String, corridor: bool = true) -> Dictionary:
	data(corridor)
	return _edges["corridor" if corridor else "single"].get(id, {})

static func point(p: Array, height: float = 0.05) -> Vector3:
	return Vector3(p[0], height, p[1])

static func position(x: float, y: float, height: float = 0.35, corridor: bool = true) -> Vector3:
	var origin: Array = data(corridor).origin
	return Vector3(float(origin[0]) - x, height, y - float(origin[1]))

static func center(j: int, corridor: bool = true) -> Vector3:
	return point(data(corridor).junctions["J%d" % j].center, 0)

static func crossing(j: int, arm: int, corridor: bool = true) -> Dictionary:
	var lane: Dictionary = edge(":J%d_c%d" % [j, arm], corridor).lanes[0]
	return {"start": point(lane.shape[0]), "end": point(lane.shape[-1]), "width": lane.width, "arm": arm}

static func widths(j: int, corridor: bool = true) -> Vector3:
	return Vector3(crossing(j, 0, corridor).start.distance_to(crossing(j, 0, corridor).end), crossing(j, 1, corridor).start.distance_to(crossing(j, 1, corridor).end), crossing(j, 3, corridor).start.distance_to(crossing(j, 3, corridor).end))

static func vehicle_size(kind: String, corridor: bool = true) -> Vector3:
	var spec: Dictionary = data(corridor).vehicle_types.get(kind, data(corridor).vehicle_types.car)
	# Preserve the simulated footprint. SUMO's omitted height defaults to a
	# passenger car even for our minibus type; give its visible body headroom.
	var height: float = maxf(spec.height, 2.4) if kind == "trotro" else float(spec.height)
	return Vector3(spec.width, height, spec.length)

static func sidewalks(corridor: bool = true) -> Array:
	var result: Array = []
	for e in data(corridor).edges:
		if e.kind != "road": continue
		for lane in e.lanes:
			if lane.pedestrian:
				var shape: Array = clip_shape(lane.shape, corridor)
				if shape.size() >= 2:
					result.append({"start": point(shape[0], 0), "end": point(shape[-1], 0)})
	return result
