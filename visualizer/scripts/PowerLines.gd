extends RefCounted
## Overhead distribution lines in the style of Accra's network: spun-concrete
## poles with a galvanised cross-arm on V-braces and brown pin insulators carrying
## three medium-voltage phases, an aerial bundled low-voltage cable lower down,
## catenary sag on every span, a pole-mounted transformer on every third pole and
## a stay wire at each end of a run. Shared by both scenes.
const G = preload("res://scripts/PropGeometry.gd")
const HEIGHT := 7.4
const ARM := 0.78      # outer phases sit this far either side of the pole

## `bases`: pole foot positions in order along one straight run. `across`: the
## cross-arm's horizontal direction. `field`: horizontal unit vector pointing away
## from the road, where transformers hang.
static func run(parent: Node3D, bases: Array[Vector3], across: Vector3, field: Vector3) -> void:
	if bases.is_empty():
		return
	var m := _materials()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var along: Vector3 = (bases[bases.size() - 1] - bases[0]).normalized() if bases.size() > 1 else field.cross(Vector3.UP)
	var previous: Array = []
	for i in range(bases.size()):
		var transformer: bool = i % 3 == 1 and i < bases.size() - 1
		var points: Array = _pole(parent, bases[i], across, field, m, transformer)
		if not previous.is_empty():
			for k in range(points.size()):
				var low_voltage: bool = k == points.size() - 1
				_catenary(st, previous[k], points[k], 0.46 if low_voltage else 0.32, 0.024 if low_voltage else 0.014)
		previous = points
	_stay(parent, bases[0], -along, m)
	if bases.size() > 1:
		_stay(parent, bases[bases.size() - 1], along, m)
	var lines := G.instance(parent, st.commit(), Vector3.ZERO, m["cable"], "PowerLines")
	lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

static func _materials() -> Dictionary:
	var cable := G.solid(Color("17191a"), 0.1, 0.55).duplicate() as StandardMaterial3D
	cable.cull_mode = BaseMaterial3D.CULL_DISABLED
	return {
		"concrete": G.solid(Color("a8a69b"), 0.0, 0.86),
		"collar": G.solid(Color("8d8b80"), 0.0, 0.92),
		"steel": G.solid(Color("8a908c"), 0.6, 0.36),
		"porcelain": G.solid(Color("6b4a33"), 0.05, 0.28),
		"glaze": G.solid(Color("d9d6cc"), 0.05, 0.3),
		"tank": G.solid(Color("8e9792"), 0.45, 0.42),
		"guard": G.solid(Color("e3b23c"), 0.1, 0.5),
		"plate": G.solid(Color("2f4a3c"), 0.2, 0.5),
		"cable": cable,
	}

static func _pole(parent: Node3D, b: Vector3, across: Vector3, field: Vector3, m: Dictionary, transformer: bool) -> Array:
	# Tapered spun-concrete pole on a collar, with an enamel number plate.
	var top := b + Vector3(0, HEIGHT, 0)
	G.segment(parent, b + Vector3(0, -0.03, 0), b + Vector3(0, 0.32, 0), 0.21, m["collar"], "PoleCollar")
	G.segment(parent, b, top, 0.15, m["concrete"], "PowerPole", 0.62)
	G.box(parent, b + field * 0.135 + Vector3(0, 2.4, 0), Vector3(0.16, 0.22, 0.16) * (Vector3.ONE - field.abs() * 0.9), m["plate"], "PoleNumber")
	# Galvanised cross-arm on two V-braces.
	var arm_y: float = HEIGHT - 0.32
	var arm_size: Vector3 = Vector3(2.0, 0.09, 0.1) if absf(across.x) > 0.5 else Vector3(0.1, 0.09, 2.0)
	G.box(parent, b + Vector3(0, arm_y, 0), arm_size, m["steel"], "CrossArm")
	for side in [-1.0, 1.0]:
		G.segment(parent, b + Vector3(0, arm_y - 0.62, 0), b + across * (side * 0.55) + Vector3(0, arm_y - 0.04, 0), 0.022, m["steel"], "ArmBrace")
	var points: Array = [
		_insulator(parent, b - across * ARM + Vector3(0, arm_y + 0.045, 0), m),
		_insulator(parent, top, m),
		_insulator(parent, b + across * ARM + Vector3(0, arm_y + 0.045, 0), m),
	]
	# Low-voltage aerial bundled cable on a short bracket, road side.
	var lv: Vector3 = b - field * 0.24 + Vector3(0, HEIGHT - 2.1, 0)
	G.segment(parent, b + Vector3(0, HEIGHT - 2.1, 0), lv, 0.02, m["steel"], "LVBracket")
	G.ellipsoid(parent, lv, Vector3(0.08, 0.08, 0.08), m["cable"], "LVClamp")
	points.append(lv)
	if transformer:
		_transformer(parent, b, across, field, points, m)
	return points

static func _insulator(parent: Node3D, base: Vector3, m: Dictionary) -> Vector3:
	G.segment(parent, base, base + Vector3(0, 0.07, 0), 0.012, m["steel"], "InsulatorPin")
	G.segment(parent, base + Vector3(0, 0.06, 0), base + Vector3(0, 0.2, 0), 0.04, m["porcelain"], "PinInsulator")
	for y in [0.09, 0.15]:
		G.ellipsoid(parent, base + Vector3(0, y, 0), Vector3(0.13, 0.035, 0.13), m["porcelain"], "InsulatorShed")
	return base + Vector3(0, 0.215, 0)

static func _transformer(parent: Node3D, b: Vector3, across: Vector3, field: Vector3, points: Array, m: Dictionary) -> void:
	# Pole-mounted transformer hung on the field side, fed from the three phases
	# through fuse cutouts, its earth lead running down the pole.
	var c: Vector3 = b + field * 0.45 + Vector3(0, 4.35, 0)
	for y in [4.68, 4.02]:
		G.segment(parent, b + Vector3(0, y, 0), c + Vector3(0, y - 4.35, 0) - field * 0.2, 0.03, m["steel"], "TransformerHanger")
	G.segment(parent, c + Vector3(0, -0.36, 0), c + Vector3(0, 0.36, 0), 0.25, m["tank"], "Transformer")
	G.segment(parent, c + Vector3(0, 0.36, 0), c + Vector3(0, 0.42, 0), 0.215, m["tank"], "TransformerLid")
	for fin in range(6):
		var angle: float = TAU * fin / 6.0
		var dir := Vector3(cos(angle), 0, sin(angle))
		G.box(parent, c + dir * 0.27, Vector3(0.05, 0.56, 0.05), m["tank"], "CoolingFin")
	for k in range(3):
		var bush: Vector3 = c + Vector3(0, 0.42, 0) + across * ((k - 1) * 0.12)
		G.segment(parent, bush, bush + Vector3(0, 0.16, 0), 0.025, m["glaze"], "Bushing")
		var cut: Vector3 = b + across * ((k - 1) * 0.42) + field * 0.16 + Vector3(0, HEIGHT - 1.15, 0)
		G.segment(parent, cut + Vector3(0, -0.13, 0), cut + Vector3(0, 0.13, 0), 0.022, m["glaze"], "FuseCutout")
		G.segment(parent, points[k], cut + Vector3(0, 0.13, 0), 0.008, m["cable"], "DropLead")
		G.segment(parent, cut + Vector3(0, -0.13, 0), bush + Vector3(0, 0.16, 0), 0.008, m["cable"], "DropLead")
	G.segment(parent, c + Vector3(0, -0.36, 0), b + field * 0.12 + Vector3(0, 0.3, 0), 0.01, m["cable"], "EarthLead")

static func _stay(parent: Node3D, b: Vector3, away: Vector3, m: Dictionary) -> void:
	# Stay wire from below the cross-arm to a ground anchor beyond the end pole,
	# with a yellow guard sleeve over its lower part.
	var anchor: Vector3 = b + away * 2.6
	var top: Vector3 = b + Vector3(0, HEIGHT - 0.7, 0)
	G.segment(parent, top, anchor + Vector3(0, 0.05, 0), 0.012, m["steel"], "StayWire")
	G.segment(parent, anchor.lerp(top, 0.03), anchor.lerp(top, 0.28), 0.034, m["guard"], "StayGuard")
	G.box(parent, anchor + Vector3(0, 0.02, 0), Vector3(0.32, 0.06, 0.32), m["collar"], "StayAnchor")

static func _catenary(st: SurfaceTool, a: Vector3, b: Vector3, sag: float, radius: float) -> void:
	var points: Array[Vector3] = []
	for i in range(13):
		var t: float = i / 12.0
		points.append(a.lerp(b, t) - Vector3(0, sag * 4.0 * t * (1.0 - t), 0))
	_tube(st, points, radius)

static func _tube(st: SurfaceTool, points: Array[Vector3], radius: float) -> void:
	var sides := 5
	var rings: Array = []
	for i in range(points.size()):
		var tangent: Vector3 = (points[mini(i + 1, points.size() - 1)] - points[maxi(i - 1, 0)]).normalized()
		var side: Vector3 = tangent.cross(Vector3.UP).normalized()
		var up: Vector3 = side.cross(tangent).normalized()
		var ring: Array[Vector3] = []
		for k in range(sides):
			var angle: float = TAU * k / sides
			ring.append(points[i] + (side * cos(angle) + up * sin(angle)) * radius)
		rings.append(ring)
	for i in range(rings.size() - 1):
		for k in range(sides):
			var a: Vector3 = rings[i][k]
			var b: Vector3 = rings[i][(k + 1) % sides]
			var c: Vector3 = rings[i + 1][k]
			var d: Vector3 = rings[i + 1][(k + 1) % sides]
			G.triangle(st, a, c, b)
			G.triangle(st, b, c, d)
