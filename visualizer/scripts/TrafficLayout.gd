extends RefCounted
const Metric = preload("res://scripts/CorridorGeometry.gd")
## Shared metric road contract. SUMO reports the vehicle's front bumper.
const CROSSING_WIDTH := 4.0

static func widths(corridor: bool, junction: int = 0) -> Vector3:
	return Metric.widths(junction, corridor)

static func center(corridor: bool, junction: int) -> Vector3:
	return Metric.center(junction, corridor)

static func crossing_distance(corridor: bool, junction: int, arm: int) -> float:
	var path := Metric.crossing(junction, arm, corridor)
	return ((path.start+path.end)*0.5).distance_to(center(corridor,junction)+Vector3.UP*0.05)

static func stop_distance(corridor: bool, junction: int, arm: int) -> float:
	return crossing_distance(corridor,junction,arm)+Metric.crossing(junction,arm,corridor).width*0.5

static func crossing(corridor: bool, junction: int, arm: int) -> Dictionary:
	return Metric.crossing(junction,arm,corridor)

static func half_length(kind: String, corridor: bool = false) -> float:
	return Metric.vehicle_size(kind,corridor).z*0.5

static func map_position(sx: float, sy: float, corridor: bool) -> Vector3:
	return Metric.position(sx,sy,0.35,corridor)

static func pedestrian(packet: Dictionary, corridor: bool) -> Vector3:
	var height: float = 0.055 if "_c" in str(packet.get("edge", "")) else (0.065 if "_w" in str(packet.get("edge", "")) else 0.15)
	return Metric.position(float(packet.x),float(packet.y),height,corridor)

static func vehicle_positions(vehicles: Array, corridor: bool) -> Dictionary:
	var mapped: Dictionary = {}
	for v in vehicles:
		var angle: float = deg_to_rad(float(v.get("angle",0)))
		var length: float = float(v.get("length",Metric.vehicle_size(str(v.get("type","car")),corridor).z))
		mapped[v.id] = map_position(v.x,v.y,corridor)-Vector3(-sin(angle),0,cos(angle))*length*0.5
	return mapped
