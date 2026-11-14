extends RefCounted
## One shared layout consumed by Python stop scheduling and Godot scenery.
static func stations(corridor: bool) -> Array:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/transit/stations.json"))
	return data["corridor" if corridor else "single"]

static func plot(spec: Dictionary) -> Rect2:
	var outer: float = spec["road_half"] + spec["sidewalk"]
	var x: float = outer if spec["side"] > 0 else -outer - 8.0
	return Rect2(x, spec["z"] - 7.0, 8.0, 14.0)

static func conflicts(center: Vector3, corridor: bool) -> bool:
	var building := Rect2(center.x-3.6,center.z-3.6,7.2,7.2)
	for spec in stations(corridor):
		if plot(spec).intersects(building):
			return true
	return false
