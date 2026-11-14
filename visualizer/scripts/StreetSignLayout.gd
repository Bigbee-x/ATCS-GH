extends RefCounted
## Shared by the street builder and sign builder so advertising has reserved land.
static func billboards(corridor: bool) -> Array[Dictionary]:
	if corridor:
		return [
			{"position": Vector3(10, 0, -22), "yaw": -PI / 4.0, "design": 0},
			{"position": Vector3(-10, 0, 44), "yaw": PI / 4.0, "design": 1},
			{"position": Vector3(10, 0, 88), "yaw": -PI / 4.0, "design": 2}]
	return [
		{"position": Vector3(10, 0, 36), "yaw": -PI / 4.0, "design": 0},
		{"position": Vector3(-10, 0, -40), "yaw": PI * 3.0 / 4.0, "design": 1}]

static func plot(spec: Dictionary) -> Rect2:
	var at: Vector3 = spec["position"]
	return Rect2(at.x - 4.2, at.z - 4.5, 8.4, 9.0)

static func frontage_conflict(center: Vector3, corridor: bool) -> bool:
	# Conservative footprint includes the largest shop's canopy and roof overhang.
	var footprint := Rect2(center.x - 3.6, center.z - 3.6, 7.2, 7.2)
	for spec in billboards(corridor):
		if footprint.intersects(plot(spec)):
			return true
	return false
