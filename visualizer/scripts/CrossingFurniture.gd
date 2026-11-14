extends RefCounted
const Layout = preload("res://scripts/TrafficLayout.gd")
const G = preload("res://scripts/PropGeometry.gd")

static func stop_lines(parent: Node3D, corridor: bool, junction: int, material: Material) -> void:
	var w := Layout.widths(corridor, junction)
	var c := Layout.center(corridor, junction)
	for arm in range(4):
		var d := Layout.stop_distance(corridor, junction, arm)
		var positions := [Vector3(w.x / 4, 0.053, d), Vector3(-d, 0.053, w.y / 4), Vector3(-w.x / 4, 0.053, -d), Vector3(d, 0.053, -w.z / 4)]
		var sizes := [Vector3(w.x / 2, 0.004, 0.12), Vector3(0.12, 0.004, w.y / 2), Vector3(w.x / 2, 0.004, 0.12), Vector3(0.12, 0.004, w.z / 2)]
		G.box(parent, c + positions[arm], sizes[arm], material, "StopLine_J%d_%d" % [junction, arm])

static func crossings(parent: Node3D, corridor: bool, junction: int, marking: Material, pavement: Material) -> void:
	var w := Layout.widths(corridor, junction)
	var center := Layout.center(corridor, junction)
	# Generous corner landings join all four crossings to the footways,
	# including the narrower west arm at J0.
	for side_x in [-1.0, 1.0]:
		var half_z: float = (w.y if side_x < 0 else w.z) * 0.5
		var depth: float = maxf(w.y, w.z) * 0.5 + 1.35 - half_z
		for side_z in [-1.0, 1.0]:
			G.box(parent, center + Vector3(side_x * (w.x * 0.5 + 0.675), 0.075, side_z * (half_z + depth * 0.5)), Vector3(1.35, 0.13, depth), pavement, "CrossingLanding")
	for arm in range(4):
		var path := Layout.crossing(corridor, junction, arm)
		var midpoint: Vector3 = (path.start + path.end) * 0.5
		midpoint.y = 0.053
		var along_x: bool = arm in [0, 2]
		var span: float = w.x if along_x else (w.y if arm == 1 else w.z)
		var count: int = int(span / 0.4)
		for i in range(count):
			var offset: float = (i - (count - 1) * 0.5) * 0.4
			var size := Vector3(0.22, 0.004, Layout.CROSSING_WIDTH) if along_x else Vector3(Layout.CROSSING_WIDTH, 0.004, 0.22)
			G.box(parent, midpoint + (Vector3(offset, 0, 0) if along_x else Vector3(0, 0, offset)), size, marking, "Crosswalk_J%d_%d_%d" % [junction, arm, i])
