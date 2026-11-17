extends RefCounted
## One shared layout consumed by Python stop scheduling and Godot scenery.
static func stations(corridor: bool) -> Array:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/transit/stations.json"))
	var result: Array = data["corridor" if corridor else "single"]
	for spec in result:
		var raw_y: float = float(spec.get("sumo_y",1510.4+spec.pos if spec.side < 0 else 1489.6-spec.pos))
		spec.z = raw_y-1500.0
		spec.sumo_y = raw_y
		spec.road_half = 6.4
		spec.sidewalk = 1.5
		spec.bay_x = float(spec.side)*(10.4 if spec.get("parking",false) else 4.8)
		spec.metric = true
	return result

static func plot(spec: Dictionary) -> Rect2:
	var outer: float = spec["road_half"] + spec["sidewalk"]
	if spec.get("metric", false):
		# Include loading space, entry/exit driveways and the rear parking apron.
		return Rect2(outer if spec.side > 0 else -outer-10.0, spec.z-25.0, 10.0, 50.0)
	var x: float = outer if spec["side"] > 0 else -outer - 8.0
	return Rect2(x, spec["z"] - 7.0, 8.0, 14.0)

static func conflicts(center: Vector3, corridor: bool) -> bool:
	var building := Rect2(center.x-3.6,center.z-3.6,7.2,7.2)
	for spec in stations(corridor):
		if plot(spec).intersects(building):
			return true
	return false
