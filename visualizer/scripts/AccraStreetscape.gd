extends Node3D
## Architectural kit for both SUMO scenes. Front faces local +Z.
## Small repeated details are batched by material and 24-unit spatial cell.
## Only building envelopes and boundary walls get physics shapes.

const Props = preload("res://scripts/PropGeometry.gd")
const Materials = preload("res://scripts/StreetscapeMaterials.gd")
const WALLS: Array[Color] = [
	Color("b7a583"), Color("c2b7a0"), Color("a9977b"), Color("9d8e78"),
	Color("b58c6a"), Color("8e9e92"), Color("b9b6aa"), Color("a6a493")]
const ROOFS: Array[Color] = [Color("735044"), Color("666d6a"), Color("8b5945"), Color("526365")]
const SHOP_NAMES: Array[String] = [
	"AKWAABA\nPROVISIONS", "ADOM\nPHARMACY", "KOFI'S\nBARBER SHOP", "ABENA\nFABRICS",
	"NEOPLAN\nSPARE PARTS", "MAMA ESI\nCHOP BAR", "ACCRA\nELECTRICALS", "GRACE\nCOLD STORE"]
const SHOP_COLORS: Array[Color] = [Color("2c5853"), Color("345e41"), Color("514233"), Color("825a39")]
# Filling stations carry the project's own fuel brand, "Sankofa", in the sim's teal and amber.
const FUEL_TEAL := Color("1f5a55")
const FUEL_AMBER := Color("e9a93a")
const FleetActor = preload("res://scripts/VehicleActor.gd")
# Pitchside advertisers are the sim's own businesses: [name, board colour, lettering].
const PITCH_ADVERTS: Array = [
	["SANKOFA FUEL", "1f5a55", "f4f1e6"], ["VALIBORN TECHNOLOGIES", "1d2b3a", "f4f1e6"],
	["AKWAABA PROVISIONS", "2c5853", "e9dfc5"], ["RELAX, IT WORKS", "e9a93a", "1d2b3a"],
	["ADOM PHARMACY", "345e41", "f4f1e6"], ["MAMA ESI CHOP BAR", "825a39", "f4e9d2"],
	["GRACE COLD STORE", "514233", "e9dfc5"]]

var _rng := RandomNumberGenerator.new()
var _batches: Dictionary = {}
var _box_mesh := BoxMesh.new()
var _cylinder_mesh := CylinderMesh.new()
var _leaf_mesh: ArrayMesh
var _roof_mesh: ArrayMesh
var _warm: Material
var _cool: Material
var _building_count: int = 0
var _tree_count: int = 0
var _sign_count: int = 0
var _background_count: int = 0
var _building_backdrop: bool = false
# Plot metadata stays separate from the render batches for zoning validation.
var land_uses: Array[Dictionary] = []
var _premise_counts: Dictionary = {}
var _special_materials: Dictionary = {}

func _record_use(kind: String, center: Vector3, facing: Vector3, w: float, d: float, floors: int) -> void:
	land_uses.append({"kind": kind, "center": center, "facing": facing,
		"width": w, "depth": d, "floors": floors})

func _premise_name(kind: String) -> String:
	var names: Dictionary = {
		"mall": ["RINGWAY MALL", "PALM PLAZA MALL", "JUNCTION MALL"],
		"supermarket": ["AKWAABA SUPERMARKET", "ADOM SUPERMARKET", "FRESHWAY SUPERMARKET", "CITY MART SUPERMARKET"],
		"police": ["DISTRICT POLICE", "COMMUNITY POLICE", "NORTH DISTRICT POLICE"],
		"kiosk": ["ADOM KIOSK", "AMA'S KIOSK", "UNITY KIOSK", "ABENA'S KIOSK"],
		"apartment": ["PALM COURT", "GARDEN HEIGHTS", "ACACIA COURT", "RIDGE VIEW"]}
	var index: int = int(_premise_counts.get(kind, 0))
	_premise_counts[kind] = index + 1
	return names[kind][index % names[kind].size()]

func configure(warm: Material, cool: Material) -> void:
	_rng.seed = 42107
	_warm = warm
	_cool = cool
	_box_mesh.size = Vector3.ONE
	_cylinder_mesh.top_radius = 0.42
	_cylinder_mesh.bottom_radius = 0.5
	_cylinder_mesh.height = 1.0
	_cylinder_mesh.radial_segments = 12
	_cylinder_mesh.rings = 1
	_leaf_mesh = _make_leaf_cluster()
	_roof_mesh = _make_hip_roof()

func _frame(center: Vector3, facing: Vector3 = Vector3.BACK) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, atan2(facing.x, facing.z)), center)

func _batch(mesh: Mesh, material: Material, transform: Transform3D, shade: Color = Color.WHITE) -> void:
	var cell_size: float = 64.0 if _building_backdrop else 24.0
	var cell := Vector2i(floori(transform.origin.x / cell_size), floori(transform.origin.z / cell_size))
	var key := "%d:%d:%d:%d:%s" % [mesh.get_instance_id(), material.get_instance_id(), cell.x, cell.y, _building_backdrop]
	if not _batches.has(key):
		_batches[key] = {"mesh": mesh, "material": material, "transforms": [], "colors": [], "background": _building_backdrop}
	_batches[key]["transforms"].append(transform)
	_batches[key]["colors"].append(shade)

func _box(frame: Transform3D, at: Vector3, size: Vector3, material: Material, solid: bool = false) -> void:
	_batch(_box_mesh, material, frame * Transform3D(Basis.from_scale(size), at))
	if solid:
		var body := StaticBody3D.new()
		body.transform = frame
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = size
		shape.shape = box
		shape.position = at
		body.add_child(shape)
		add_child(body)

func _beam(frame: Transform3D, a: Vector3, b: Vector3, diameter: float, material: Material) -> void:
	var direction := b - a
	var basis := Basis(Quaternion(Vector3.UP, direction.normalized()))
	# Scale the cylinder along its own Y axis before orienting it between endpoints.
	basis = basis * Basis.from_scale(Vector3(diameter, direction.length(), diameter))
	_batch(_cylinder_mesh, material, frame * Transform3D(basis, (a + b) * 0.5))

func finish() -> void:
	for batch: Dictionary in _batches.values():
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		multimesh.mesh = batch["mesh"]
		multimesh.instance_count = batch["transforms"].size()
		for i in range(multimesh.instance_count):
			multimesh.set_instance_transform(i, batch["transforms"][i])
			multimesh.set_instance_color(i, batch["colors"][i])
		var instance := MultiMeshInstance3D.new()
		instance.multimesh = multimesh
		instance.material_override = batch["material"]
		instance.name = "StreetscapeBatch"
		if batch["background"]:
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)
	_batches.clear()
	print("[Streetscape] %d detailed buildings, %d background buildings, %d trees; spatially batched geometry" % [_building_count, _background_count, _tree_count])

func building(center: Vector3, facing: Vector3, width: float, depth: float,
		floors: int, shop: bool = false, institutional: bool = false,
		institution_name: String = "COMMUNITY\nLEARNING CENTRE") -> void:
	_building_count += 1
	_record_use("civic" if institutional else ("shop" if shop else "house"), center, facing, width, depth, floors)
	var frame := _frame(center, facing)
	var h: float = floors * 2.55
	var color: Color = WALLS[_rng.randi_range(0, WALLS.size() - 1)]
	var plaster := Materials.surface(0, color)
	var trim := Materials.surface(0, color.lightened(0.12))
	var concrete := Materials.surface(2, Color("807c70"))
	var dark := Materials.solid(Color("383b37"), 0.45)
	var front: float = depth * 0.5
	_box(frame, Vector3(0, 0.025, 0.3), Vector3(width + 0.65, 0.12, depth + 1.3), Materials.surface(5, Color("998c77")))
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(width, h, depth), plaster, true)
	_box(frame, Vector3(0, 0.22, 0), Vector3(width + 0.04, 0.44, depth + 0.04), concrete)
	# Recessed bays, projecting floor slabs and small structural pilasters.
	for floor_index in range(floors):
		var y: float = floor_index * 2.55
		if floor_index > 0:
			_box(frame, Vector3(0, y, 0), Vector3(width + 0.16, 0.13, depth + 0.16), trim)
		for side in range(4):
			var angle: float = side * PI * 0.5
			var facade_frame := frame * Transform3D(Basis(Vector3.UP, angle), Vector3.ZERO)
			var span: float = width if side % 2 == 0 else depth
			var face_depth: float = depth if side % 2 == 0 else width
			var bays: int = maxi(2, floori(span / 1.6))
			for bay in range(bays):
				var x: float = -span * 0.5 + (bay + 0.5) * span / bays
				if side == 0 and floor_index == 0:
					if shop or bay == bays / 2:
						continue
				_window(facade_frame, Vector3(x, y + 1.48, face_depth * 0.5 + 0.025),
					minf(0.86, span / bays * 0.63), 1.05, floor_index == 0, trim)
		for x in [-width * 0.5 + 0.07, width * 0.5 - 0.07]:
			_box(frame, Vector3(x, y + 1.27, front + 0.035), Vector3(0.14, 2.55, 0.13), trim)
	if shop:
		_shop_front(frame, width, depth, color)
	else:
		_door(frame, Vector3(0.1, 1.03, front + 0.04), 0.86, 1.95)
		_box(frame, Vector3(0.1, 0.13, front + 0.32), Vector3(1.25, 0.26, 0.65), concrete)
		_box(frame, Vector3(0.1, 2.18, front + 0.37), Vector3(1.45, 0.1, 0.85), trim)
	if floors > 1 and not institutional:
		_balcony(frame, width * 0.75, front, 2.58, trim)
	# A mixture of hip roofs and inhabited flat rooftops changes the silhouette.
	if floors == 1 or _rng.randf() < 0.58 or institutional:
		_hip_roof(frame, width + 0.55, depth + 0.55, h + 0.12, minf(width, depth) * 0.25)
	else:
		_box(frame, Vector3(0, h + 0.04, 0), Vector3(width + 0.2, 0.12, depth + 0.2), concrete)
		for z in [-front, front]:
			_box(frame, Vector3(0, h + 0.28, z), Vector3(width + 0.1, 0.48, 0.14), trim)
		for x in [-width * 0.5, width * 0.5]:
			_box(frame, Vector3(x, h + 0.28, 0), Vector3(0.14, 0.48, depth), trim)
		_water_tank(frame, Vector3(-width * 0.22, h + 0.1, -depth * 0.18))
	# Rainwater downpipe and exterior AC units are actual geometry, not decals.
	_beam(frame, Vector3(width * 0.5 + 0.05, 0.2, front - 0.1),
		Vector3(width * 0.5 + 0.05, h, front - 0.1), 0.075, dark)
	if floors > 1:
		_air_conditioner(frame, Vector3(width * 0.25, 3.85, front + 0.21))
	if institutional:
		_sign(frame, institution_name, Vector3(0, 2.25, front + 0.1), minf(width - 0.3, 5.0), 0.52, SHOP_COLORS[0])

func _window(frame: Transform3D, at: Vector3, w: float, h: float, bars: bool, trim: Material) -> void:
	var reveal := Materials.solid(Color("252c29"))
	var aluminum := Materials.solid(Color("767d79"), 0.65, 0.34)
	_box(frame, at, Vector3(w + 0.14, h + 0.16, 0.07), reveal)
	var pane: Material = _warm if _rng.randf() < 0.36 else Materials.solid(Color("34464b"), 0.28, 0.19)
	_box(frame, at + Vector3(0, 0, 0.046), Vector3(w - 0.06, h - 0.08, 0.02), pane)
	for x in [-w * 0.5, 0.0, w * 0.5]:
		_box(frame, at + Vector3(x, 0, 0.07), Vector3(0.035, h, 0.045), aluminum)
	for y in [-h * 0.5, h * 0.5]:
		_box(frame, at + Vector3(0, y, 0.07), Vector3(w + 0.08, 0.045, 0.045), aluminum)
	_box(frame, at + Vector3(0, -h * 0.5 - 0.06, 0.08), Vector3(w + 0.24, 0.09, 0.23), trim)
	_box(frame, at + Vector3(0, h * 0.5 + 0.11, 0.16), Vector3(w + 0.3, 0.08, 0.42), trim)
	if bars:
		var steel := Materials.solid(Color("44473e"), 0.5)
		for i in range(5):
			_box(frame, at + Vector3((i - 2) * w * 0.18, 0, 0.16), Vector3(0.018, h, 0.025), steel)
		_box(frame, at + Vector3(0, 0, 0.16), Vector3(w, 0.025, 0.025), steel)

func _door(frame: Transform3D, at: Vector3, w: float, h: float) -> void:
	_box(frame, at, Vector3(w + 0.14, h + 0.12, 0.08), Materials.solid(Color("363630")))
	var wood := Materials.surface(6, Color("574332"))
	_box(frame, at + Vector3(0, 0, 0.05), Vector3(w, h, 0.035), wood)
	for y in [-h * 0.24, h * 0.24]:
		_box(frame, at + Vector3(0, y, 0.075), Vector3(w * 0.74, h * 0.37, 0.025), Materials.surface(6, Color("68513a")))
	_box(frame, at + Vector3(w * 0.33, 0, 0.12), Vector3(0.045, 0.18, 0.05), Materials.solid(Color("b0a080"), 0.8))

func _balcony(frame: Transform3D, w: float, front: float, y: float, trim: Material) -> void:
	var steel := Materials.solid(Color("414640"), 0.65)
	_box(frame, Vector3(0, y, front + 0.37), Vector3(w, 0.14, 0.85), trim)
	for rail_y in [y + 0.25, y + 0.92]:
		_box(frame, Vector3(0, rail_y, front + 0.77), Vector3(w, 0.045, 0.045), steel)
	var rails: int = maxi(4, ceili(w / 0.24))
	for i in range(rails + 1):
		_box(frame, Vector3(-w * 0.5 + w * i / rails, y + 0.52, front + 0.77), Vector3(0.023, 0.78, 0.023), steel)
	for x in [-w * 0.5, w * 0.5]:
		_box(frame, Vector3(x, y + 0.92, front + 0.38), Vector3(0.045, 0.045, 0.8), steel)

func _shop_front(frame: Transform3D, w: float, d: float, color: Color) -> void:
	var z: float = d * 0.5
	var steel := Materials.solid(Color("53584f"), 0.35)
	var count: int = maxi(1, floori(w / 1.7))
	for bay in range(count):
		var bay_w: float = w / count * 0.8
		var x: float = -w * 0.5 + (bay + 0.5) * w / count
		_box(frame, Vector3(x, 1.0, z + 0.03), Vector3(bay_w, 1.85, 0.08), Materials.solid(Color("222c28")))
		# Partially lifted roller shutter, with visible slats and dark shop interior.
		for slat in range(6):
			_box(frame, Vector3(x, 1.48 + slat * 0.07, z + 0.09), Vector3(bay_w + 0.02, 0.058, 0.06), steel)
		_box(frame, Vector3(x, 0.64, z + 0.12), Vector3(bay_w * 0.85, 0.72, 0.26), Materials.surface(6, Color("7c6746")))
		for item in range(5):
			var item_color: Color = [Color("ab793e"), Color("6b813e"), Color("9f583c")][item % 3]
			_box(frame, Vector3(x - bay_w * 0.35 + item * bay_w * 0.17, 1.07, z + 0.18), Vector3(0.17, 0.16, 0.2), Materials.solid(item_color))
	var sign_id: int = _sign_count % SHOP_NAMES.size()
	_sign(frame, SHOP_NAMES[sign_id], Vector3(0, 2.17, z + 0.12), w - 0.12, 0.55, SHOP_COLORS[sign_id % SHOP_COLORS.size()])
	_sign_count += 1
	# Sloping sheet-metal canopy with fascia, braces and two slim posts.
	var canopy_mat := Materials.surface(4, color.darkened(0.35))
	var canopy := frame * Transform3D(Basis(Vector3.RIGHT, 0.12), Vector3(0, 1.99, z + 0.58))
	_box(canopy, Vector3.ZERO, Vector3(w + 0.22, 0.055, 1.3), canopy_mat)
	_box(frame, Vector3(0, 1.87, z + 1.2), Vector3(w + 0.22, 0.13, 0.04), canopy_mat)
	for x in [-w * 0.45, w * 0.45]:
		_beam(frame, Vector3(x, 0.1, z + 1.1), Vector3(x, 1.92, z + 1.1), 0.055, steel)
		_beam(frame, Vector3(x, 1.9, z + 0.05), Vector3(x, 1.6, z + 1.1), 0.035, steel)
	# Water barrels and a small timber bench live on the apron, outside the walkway.
	_beam(frame, Vector3(w * 0.42, 0.1, z + 0.42), Vector3(w * 0.42, 0.68, z + 0.42), 0.38, Materials.solid(Color("385e69")))
	_box(frame, Vector3(-w * 0.22, 0.4, z + 0.65), Vector3(w * 0.32, 0.09, 0.3), Materials.surface(6, Color("65513b")))

func _sign(frame: Transform3D, text: String, at: Vector3, w: float, h: float, color: Color) -> void:
	var root := Node3D.new()
	root.name = "LocalShopSign"
	root.transform = frame * Transform3D(Basis.IDENTITY, at)
	add_child(root)
	Props.rounded_box(root, Vector3.ZERO, Vector3(w, h, 0.075), 0.025, Materials.solid(Color("363e36"), 0.4), "SignFrame")
	Props.box(root, Vector3(0, 0, 0.041), Vector3(w - 0.055, h - 0.055, 0.012), Materials.solid(color), "PaintedFace")
	var cream := Color("e9dfc5")
	Props.box(root, Vector3(0, -h * 0.37, 0.05), Vector3(w - 0.17, 0.012, 0.01), Materials.solid(cream))
	var lines := text.split("\n")
	var text_x: float = h * 0.30
	var badge_x: float = -w * 0.5 + h * 0.45
	Props.ellipsoid(root, Vector3(badge_x, 0.02, 0.06), Vector3(h * 0.53, h * 0.53, 0.016), Materials.solid(cream), "ShopBadge")
	Props.label(root, lines[0].substr(0, 1), Vector3(badge_x, 0.02, 0.074), h * 0.32, h * 0.34, color).visibility_range_end = 65.0
	Props.label(root, lines[0], Vector3(text_x, h * 0.13, 0.055), w - h * 1.3, h * 0.33, cream, "ShopName").visibility_range_end = 65.0
	if lines.size() > 1:
		Props.label(root, lines[1], Vector3(text_x, -h * 0.19, 0.055), w - h * 1.3, h * 0.16, cream, "ShopType").visibility_range_end = 65.0

func _triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, shade: Color = Color.WHITE) -> void:
	var normal := (b - a).cross(c - a).normalized()
	for point: Vector3 in [a, c, b]:
		st.set_normal(normal)
		st.set_color(shade)
		st.set_uv(Vector2(point.x, point.z))
		st.add_vertex(point)

func _make_hip_roof() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(-0.5, 0, -0.5)
	var b := Vector3(0.5, 0, -0.5)
	var c := Vector3(0.5, 0, 0.5)
	var e := Vector3(-0.5, 0, 0.5)
	var ridge_a := Vector3(-0.27, 1, 0)
	var ridge_b := Vector3(0.27, 1, 0)
	_triangle(st, a, ridge_a, ridge_b)
	_triangle(st, a, ridge_b, b)
	_triangle(st, b, ridge_b, c)
	_triangle(st, c, ridge_b, ridge_a)
	_triangle(st, c, ridge_a, e)
	_triangle(st, e, ridge_a, a)
	return st.commit()

func _hip_roof(frame: Transform3D, w: float, d: float, y: float, rise: float) -> void:
	var material := Materials.surface(4, ROOFS[_rng.randi_range(0, ROOFS.size() - 1)])
	_batch(_roof_mesh, material, frame * Transform3D(Basis.from_scale(Vector3(w, rise, d)), Vector3(0, y, 0)))
	var ridge_a := Vector3(-w * 0.27, y + rise, 0)
	var ridge_b := Vector3(w * 0.27, y + rise, 0)
	_beam(frame, ridge_a, ridge_b, 0.12, material)
	for z in [-d * 0.5, d * 0.5]:
		_box(frame, Vector3(0, y - 0.05, z), Vector3(w, 0.14, 0.1), Materials.surface(0, Color("c0b7a2")))
	for x in [-w * 0.5, w * 0.5]:
		_box(frame, Vector3(x, y - 0.05, 0), Vector3(0.1, 0.14, d), Materials.surface(0, Color("c0b7a2")))

func _water_tank(frame: Transform3D, at: Vector3) -> void:
	var plastic := Materials.solid(Color("303b36"), 0.0, 0.55)
	_box(frame, at + Vector3(0, 0.12, 0), Vector3(0.9, 0.24, 0.9), Materials.surface(2, Color("77756b")))
	_beam(frame, at + Vector3(0, 0.24, 0), at + Vector3(0, 1.23, 0), 0.78, plastic)
	for y in [0.35, 0.53, 0.72, 0.91, 1.12]:
		_beam(frame, at + Vector3(0, y, 0), at + Vector3(0, y + 0.025, 0), 0.81, plastic)
	_beam(frame, at + Vector3(0, 1.23, 0), at + Vector3(0, 1.29, 0), 0.45, plastic)

func _air_conditioner(frame: Transform3D, at: Vector3) -> void:
	_box(frame, at, Vector3(0.66, 0.38, 0.3), Materials.solid(Color("afa998")))
	for i in range(6):
		_box(frame, at + Vector3(0, -0.13 + i * 0.05, 0.16), Vector3(0.54, 0.017, 0.02), Materials.solid(Color("62685f")))

func compound(center: Vector3, size: float, floors: int, facing: Vector3 = Vector3.BACK) -> void:
	# The gate and the house front face `facing`.
	var frame := _frame(center, facing)
	var wall := Materials.surface(0, WALLS[_rng.randi_range(0, WALLS.size() - 1)])
	var half: float = size * 0.5
	_box(frame, Vector3(0, -0.005, 0), Vector3(size, 0.05, size), Materials.surface(5, Color("a6967b")))
	for z in [-half, half]:
		if z < 0:
			_box(frame, Vector3(0, 0.64, z), Vector3(size, 1.28, 0.18), wall, true)
		else:
			for sign_value in [-1.0, 1.0]:
				_box(frame, Vector3(sign_value * (size + 1.9) * 0.25, 0.64, z), Vector3((size - 1.9) * 0.5, 1.28, 0.18), wall, true)
	for x in [-half, half]:
		_box(frame, Vector3(x, 0.64, 0), Vector3(0.18, 1.28, size), wall, true)
	for x in [-half, -0.99, 0.99, half]:
		_box(frame, Vector3(x, 0.75, half), Vector3(0.3, 1.5, 0.3), wall, true)
		_box(frame, Vector3(x, 1.53, half), Vector3(0.38, 0.12, 0.38), Materials.surface(2, Color("7f7c70")))
	var gate := Materials.solid(Color("484c43"), 0.6)
	for i in range(13):
		_box(frame, Vector3(-0.88 + i * 0.147, 0.67, half), Vector3(0.105, 1.25, 0.06), gate)
	_box(frame, Vector3(0, 1.25, half), Vector3(1.9, 0.05, 0.08), gate)
	building(center + frame.basis * Vector3(-0.5, 0, -0.7), facing, size * 0.57, size * 0.5, floors)
	# Validate the enclosing residential plot, not just the house inside its walls.
	land_uses[-1].merge({"center": center, "width": size, "depth": size, "compound": true}, true)
	tree(center + frame.basis * Vector3(half - 1.2, 0, -half + 1.2), true)

func boundary_wall(center: Vector3, facing: Vector3, width: float) -> void:
	var frame := _frame(center, facing)
	var material := Materials.surface(0, Color("a99f86"))
	_box(frame, Vector3(0, 0.57, 0), Vector3(width, 1.14, 0.2), material, true)
	_box(frame, Vector3(0, 1.17, 0), Vector3(width + 0.08, 0.12, 0.29), Materials.surface(2, Color("7e7c6e")))
	var piers: int = maxi(1, floori(width / 1.8))
	for i in range(piers + 1):
		_box(frame, Vector3(-width * 0.5 + width * i / piers, 0.69, 0), Vector3(0.28, 1.38, 0.3), material)

func market_stall(center: Vector3, facing: Vector3, w: float, d: float) -> void:
	var frame := _frame(center, facing)
	var wood := Materials.surface(6, Color("756047"))
	var canopy := Materials.surface(4, SHOP_COLORS[_rng.randi_range(0, 3)].lightened(0.1))
	for x in [-w * 0.45, w * 0.45]:
		for z in [-d * 0.45, d * 0.45]:
			_beam(frame, Vector3(x, 0, z), Vector3(x, 1.8, z), 0.045, wood)
	var pitched := frame * Transform3D(Basis(Vector3.RIGHT, -0.13), Vector3(0, 1.82, 0))
	_box(pitched, Vector3.ZERO, Vector3(w + 0.25, 0.045, d + 0.3), canopy)
	_box(frame, Vector3(0, 0.75, 0.14), Vector3(w, 0.13, d * 0.8), wood)
	_box(frame, Vector3(0, 0.4, 0.14), Vector3(w * 0.9, 0.6, d * 0.6), Materials.surface(6, Color("8f724d")))
	for i in range(4):
		var fruit: Color = [Color("b79838"), Color("718843"), Color("ae593e"), Color("9a8242")][i]
		_box(frame, Vector3(-w * 0.37 + i * w * 0.24, 0.9, 0.15), Vector3(w * 0.2, 0.17, d * 0.45), Materials.solid(fruit))

func commercial(center: Vector3, facing: Vector3, w: float, d: float, kind: String) -> void:
	## Purpose-built roadside premises; their front apron fits inside the setback.
	_building_count += 1
	var floors: int = 2 if kind in ["mall", "police"] else 1
	_record_use(kind, center, facing, w, d, floors)
	var frame := _frame(center, facing)
	var concrete := Materials.surface(2, Color("928e80"))
	_box(frame, Vector3(0, 0.025, 0.45), Vector3(w + 0.5, 0.1, d + 1.5), concrete)
	match kind:
		"mechanic":
			_workshop(frame, w, d)
		"police":
			_police_station(frame, w, d)
		"kiosk":
			_kiosk(frame, w, d)
		_:
			_retail(frame, w, d, kind)

func _retail(frame: Transform3D, w: float, d: float, kind: String) -> void:
	var mall: bool = kind == "mall"
	var supermarket: bool = kind == "supermarket"
	var h: float = 6.2 if mall else (3.6 if supermarket else 3.0)
	var z: float = d * 0.5
	var plaster := Materials.surface(0, Color("c5bca6") if mall else Color("b4af9a"))
	var trim := Materials.surface(2, Color("b7b7a9"))
	var accent: Color = Color("365b50") if supermarket else (Color("5c5147") if mall else SHOP_COLORS[_sign_count % SHOP_COLORS.size()])
	var metal := Materials.solid(Color("555f5d"), 0.65, 0.3)
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), plaster, true)
	_box(frame, Vector3(0, 0.16, 0), Vector3(w + 0.06, 0.32, d + 0.06), trim)
	var bays: int = maxi(2, floori(w / 2.1))
	for i in range(bays):
		var bay_w: float = w / bays
		var x: float = -w * 0.5 + (i + 0.5) * bay_w
		_glazed_shop_bay(frame, Vector3(x, 1.35, z + 0.055), bay_w - 0.25, 2.3, i == bays / 2)
		_box(frame, Vector3(x - bay_w * 0.5 + 0.08, 1.5, z + 0.07), Vector3(0.16, 3.0, 0.2), trim)
		if mall:
			_window(frame, Vector3(x, 4.65, z + 0.04), bay_w * 0.78, 1.75, false, trim)
			_box(frame, Vector3(x - bay_w * 0.45, 4.65, z + 0.2), Vector3(0.1, 2.2, 0.32), metal)
	if mall:
		# The upper storey steps back visually behind a continuous retail canopy.
		_box(frame, Vector3(0, 3.15, z + 0.38), Vector3(w + 0.35, 0.21, 0.9), trim)
		for side in [-1.0, 1.0]:
			var flank := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
			for i in range(maxi(2, floori(d / 2.4))):
				var count: int = maxi(2, floori(d / 2.4))
				_window(flank, Vector3(-d * 0.5 + (i + 0.5) * d / count, 4.6, w * 0.5 + 0.025), d / count * 0.65, 1.6, false, trim)
	var text: String = SHOP_NAMES[_sign_count % SHOP_NAMES.size()]
	if mall:
		text = _premise_name("mall") + "\nSHOPS  •  FOOD COURT"
	elif supermarket:
		text = _premise_name("supermarket") + "\nGROCERIES  •  HOME ESSENTIALS"
	_sign(frame, text, Vector3(0, 2.88 if mall else h - 0.42, z + 0.22), w - 0.3, 0.67, accent)
	_sign_count += 1
	_box(frame, Vector3(0, 2.52, z + 0.58), Vector3(w + 0.3, 0.11, 1.18), metal)
	for x in [-w * 0.46, w * 0.46]:
		_beam(frame, Vector3(x, 0.1, z + 1.04), Vector3(x, 2.51, z + 1.04), 0.055, metal)
	# Roof parapet hides service equipment; no domestic pitched roof or balcony.
	_flat_roof(frame, w, d, h, trim)
	_box(frame, Vector3(w * 0.24, h + 0.45, -d * 0.2), Vector3(1.0, 0.6, 1.3), metal)
	if supermarket:
		# Nested trolley silhouettes alongside the entrance.
		for i in range(3):
			var at := Vector3(w * 0.34, 0.0, z + 0.4 + i * 0.2)
			_box(frame, at + Vector3(0, 0.44, 0), Vector3(0.42, 0.26, 0.43), Materials.solid(Color("737f7d"), 0.8))
			for x in [-0.17, 0.17]:
				_beam(frame, at + Vector3(x, 0.14, -0.16), at + Vector3(x, 0.6, 0.17), 0.025, metal)

func _glazed_shop_bay(frame: Transform3D, at: Vector3, w: float, h: float, entrance: bool) -> void:
	var aluminum := Materials.solid(Color("a6aca6"), 0.75, 0.28)
	var glass: Material = _cool if entrance else Materials.solid(Color("3a5354"), 0.35, 0.2)
	_box(frame, at, Vector3(w, h, 0.06), glass)
	for x in [-w * 0.5, 0.0, w * 0.5]:
		_box(frame, at + Vector3(x, 0, 0.045), Vector3(0.045, h + 0.04, 0.07), aluminum)
	for y in [-h * 0.5, h * 0.5]:
		_box(frame, at + Vector3(0, y, 0.045), Vector3(w + 0.04, 0.045, 0.07), aluminum)
	if entrance:
		for x in [-0.09, 0.09]:
			_box(frame, at + Vector3(x, -0.06, 0.105), Vector3(0.025, 0.48, 0.035), aluminum)
	else:
		_box(frame, at + Vector3(0, -h * 0.26, 0.04), Vector3(w * 0.88, 0.18, 0.025), Materials.solid(Color("8f9b86")))

func _flat_roof(frame: Transform3D, w: float, d: float, h: float, trim: Material) -> void:
	_box(frame, Vector3(0, h + 0.04, 0), Vector3(w + 0.18, 0.12, d + 0.18), Materials.surface(2, Color("777e74")))
	for z in [-d * 0.5, d * 0.5]:
		_box(frame, Vector3(0, h + 0.25, z), Vector3(w + 0.18, 0.42, 0.17), trim)
	for x in [-w * 0.5, w * 0.5]:
		_box(frame, Vector3(x, h + 0.25, 0), Vector3(0.17, 0.42, d), trim)

func _workshop(frame: Transform3D, w: float, d: float) -> void:
	var h: float = 3.35
	var wall := Materials.surface(0, Color("918e7b"))
	var metal := Materials.surface(4, Color("5c6a66"))
	var dark := Materials.solid(Color("292f2c"))
	var bay_count: int = maxi(2, floori(w / 2.8))
	var z: float = d * 0.5
	# Real open bays: collision follows rear and flank walls, not the openings.
	_box(frame, Vector3(0, h * 0.5, -z + 0.12), Vector3(w, h, 0.24), wall, true)
	for x in [-w * 0.5 + 0.1, w * 0.5 - 0.1]:
		_box(frame, Vector3(x, h * 0.5, 0), Vector3(0.2, h, d), wall, true)
	_box(frame, Vector3(0, 0.07, 0), Vector3(w, 0.14, d), Materials.surface(1, Color("4e5148")))
	_hip_roof(frame, w + 0.4, d + 0.45, h, 0.5)
	for i in range(bay_count + 1):
		var x: float = -w * 0.5 + i * w / bay_count
		_box(frame, Vector3(x, h * 0.5, z - 0.07), Vector3(0.15, h, 0.2), wall, true)
	for i in range(bay_count):
		var x: float = -w * 0.5 + (i + 0.5) * w / bay_count
		for slat in range(5):
			_box(frame, Vector3(x, 2.55 + slat * 0.09, z + 0.05), Vector3(w / bay_count - 0.2, 0.07, 0.07), metal)
		_box(frame, Vector3(x, 0.78, -z + 0.55), Vector3(w / bay_count * 0.75, 0.12, 0.64), metal)
		_box(frame, Vector3(x, 1.38, -z + 0.24), Vector3(w / bay_count * 0.68, 0.7, 0.055), dark)
		for tool in range(5):
			_beam(frame, Vector3(x - 0.4 + tool * 0.2, 1.13, -z + 0.29), Vector3(x - 0.38 + tool * 0.2, 1.56, -z + 0.29), 0.028, Materials.solid(Color("adb2aa"), 0.7))
	_sign(frame, "KOFI'S AUTO WORKS\nSERVICING  •  TYRES  •  SPARE PARTS", Vector3(0, 3.11, z + 0.13), w - 0.25, 0.53, Color("4f665c"))
	# Service car, axle stands and tyre stack make the premises legible at street level.
	var car := FleetActor.new()
	car.configure("car", 4)
	car.transform = frame * Transform3D(Basis.from_scale(Vector3.ONE * 1.1), Vector3(-w * 0.22, 0.17, 0.1))
	car.name = "WorkshopVehicle"
	add_child(car)
	var tyre := TorusMesh.new()
	tyre.inner_radius = 0.13
	tyre.outer_radius = 0.26
	tyre.rings = 12
	tyre.ring_segments = 8
	for i in range(4):
		_batch(tyre, dark, frame * Transform3D(Basis.IDENTITY, Vector3(w * 0.36, 0.16 + i * 0.14, z - 0.48)))
	_box(frame, Vector3(w * 0.34, 0.43, -z + 0.8), Vector3(0.6, 0.72, 0.65), Materials.solid(Color("8f493b")))

func _police_station(frame: Transform3D, w: float, d: float) -> void:
	var h: float = 5.25
	var z: float = d * 0.5
	var wall := Materials.surface(0, Color("bfc0af"))
	var blue := Materials.solid(Color("29455e"))
	var trim := Materials.surface(2, Color("b9b8a5"))
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), wall, true)
	_box(frame, Vector3(0, 0.46, 0), Vector3(w + 0.035, 0.92, d + 0.035), blue)
	for floor_index in range(2):
		for side in range(4):
			var face := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
			var span: float = w if side % 2 == 0 else d
			var dep: float = d if side % 2 == 0 else w
			for x in [-span * 0.32, span * 0.32]:
				_window(face, Vector3(x, 1.55 + floor_index * 2.5, dep * 0.5 + 0.025), minf(span * 0.22, 1.35), 1.1, floor_index == 0, trim)
	_glazed_shop_bay(frame, Vector3(0, 1.15, z + 0.06), minf(1.5, w * 0.23), 2.1, true)
	_box(frame, Vector3(0, 2.55, z + 0.58), Vector3(w * 0.48, 0.17, 1.2), blue)
	_sign(frame, _premise_name("police") + "\nPOLICE STATION", Vector3(0, 2.95, z + 0.13), w - 0.35, 0.63, Color("29455e"))
	_flat_roof(frame, w, d, h, trim)
	var mast_x: float = -w * 0.43
	_beam(frame, Vector3(mast_x, 0.1, z + 0.8), Vector3(mast_x, 4.3, z + 0.8), 0.045, Materials.solid(Color("a9ada4"), 0.75))
	# Ghana's flag, mounted within the forecourt rather than over the pavement.
	for stripe in range(3):
		var color: Color = [Color("a84335"), Color("c6aa4b"), Color("49714c")][stripe]
		_box(frame, Vector3(mast_x + 0.34, 4.15 - stripe * 0.14, z + 0.8), Vector3(0.65, 0.14, 0.022), Materials.solid(color))
	var flag := Node3D.new()
	flag.transform = frame
	add_child(flag)
	Props.label(flag, "★", Vector3(mast_x + 0.34, 4.01, z + 0.82), 0.14, 0.14, Color("202b27"), "FlagStar")

func _kiosk(frame: Transform3D, w: float, d: float) -> void:
	var h: float = 2.55
	var z: float = d * 0.5
	var accent: Color = SHOP_COLORS[_sign_count % SHOP_COLORS.size()]
	var steel := Materials.surface(4, accent)
	var frame_mat := Materials.solid(Color("636c5d"), 0.6)
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), steel, true)
	for side in [-1.0, 1.0]:
		for i in range(ceili(d / 0.22)):
			_box(frame, Vector3(side * (w * 0.5 + 0.015), h * 0.5, -z + (i + 0.5) * d / ceili(d / 0.22)), Vector3(0.035, h - 0.15, 0.035), frame_mat)
	_box(frame, Vector3(0, 1.34, z + 0.04), Vector3(w * 0.77, 1.1, 0.05), Materials.solid(Color("27392f")))
	_box(frame, Vector3(0, 0.83, z + 0.2), Vector3(w * 0.85, 0.13, 0.55), Materials.surface(6, Color("927755")))
	for i in range(6):
		_box(frame, Vector3(-w * 0.31 + i * w * 0.12, 1.04, z + 0.1), Vector3(w * 0.08, 0.29, 0.18), Materials.solid([Color("b29a52"), Color("7f975f"), Color("a66d4c")][i % 3]))
	var canopy := frame * Transform3D(Basis(Vector3.RIGHT, 0.13), Vector3(0, 2.36, z + 0.36))
	_box(canopy, Vector3.ZERO, Vector3(w + 0.35, 0.07, 1.35), steel)
	_box(frame, Vector3(0, h + 0.03, 0), Vector3(w + 0.3, 0.1, d + 0.3), steel)
	_sign(frame, _premise_name("kiosk") + "\nMOBILE MONEY  •  PROVISIONS", Vector3(0, 2.05, z + 0.11), w - 0.16, 0.45, accent)
	_sign_count += 1

func _entrance_apron(frame: Transform3D, w: float, d: float) -> void:
	# All paving and planting remain inside the plot's existing reserved envelope.
	var paving := Materials.surface(5, Color("a3a292"))
	var trim := Materials.surface(2, Color("8b8f81"))
	var z: float = d * 0.5
	_box(frame, Vector3(0, 0.025, 0.45), Vector3(w + 0.6, 0.1, d + 1.5), paving)
	_box(frame, Vector3(0, 0.13, 0), Vector3(w + 0.08, 0.26, d + 0.08), trim)
	var entry_w: float = minf(2.6, w * 0.46)
	_box(frame, Vector3(0, 0.085, z + 0.7), Vector3(entry_w + 0.3, 0.07, 0.88), trim)
	_box(frame, Vector3(0, 0.12, z + 0.35), Vector3(entry_w, 0.14, 0.52), paving)
	# Paving joints make the narrow entrance terrace read as a designed surface.
	for i in range(ceili(w / 1.2)):
		var x: float = -w * 0.5 + i * 1.2
		_box(frame, Vector3(x, 0.079, z + 0.66), Vector3(0.015, 0.006, 1.05), trim)
	for side in [-1.0, 1.0]:
		var x: float = side * w * 0.36
		var planter_w: float = minf(1.25, w * 0.2)
		_box(frame, Vector3(x, 0.25, z + 0.65), Vector3(planter_w, 0.35, 0.66), trim)
		_box(frame, Vector3(x, 0.43, z + 0.65), Vector3(planter_w - 0.08, 0.035, 0.56), Materials.solid(Color("534d3b")))
		for cluster in range(3):
			var leaf_at := Vector3(x + (cluster - 1) * planter_w * 0.22, 0.6, z + 0.65)
			_batch(_leaf_mesh, Materials.foliage(), frame * Transform3D(Basis.from_scale(Vector3(0.75, 0.6, 0.7)), leaf_at))

func apartment(center: Vector3, facing: Vector3, floors: int, w: float, d: float) -> void:
	_building_count += 1
	_record_use("apartment", center, facing, w, d, floors)
	var frame := _frame(center, facing)
	var story: float = 2.65
	var h: float = floors * story
	var plaster := Materials.surface(0, Color("c4bdac"))
	var accent := Materials.surface(0, Color("8c9c97"))
	var trim := Materials.surface(2, Color("b0b1a2"))
	var metal := Materials.solid(Color("485e5c"), 0.65, 0.3)
	_entrance_apron(frame, w, d)
	# Recessed central volume leaves genuine balcony depth within the plot.
	_box(frame, Vector3(0, h * 0.5, -0.35), Vector3(w, h, d - 0.7), plaster, true)
	_box(frame, Vector3(0, 1.35, 0), Vector3(w, 2.7, d), accent, true)
	for side in range(4):
		var face := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
		var span: float = w if side % 2 == 0 else d
		var dep: float = d if side % 2 == 0 else w
		var bays: int = maxi(2, floori(span / 2.25))
		for floor_index in range(1, floors):
			var y: float = floor_index * story
			for bay in range(bays):
				var x: float = -span * 0.5 + (bay + 0.5) * span / bays
				var inset: float = 0.67 if side == 0 else 0.0
				_window(face, Vector3(x, y + 1.28, dep * 0.5 - inset + 0.025), span / bays * 0.56, 1.55, false, trim)
				if side == 0:
					# Individual loggias with solid partitions and metal railings.
					_box(face, Vector3(x, y + 0.06, dep * 0.5 - 0.23), Vector3(span / bays - 0.14, 0.15, 0.88), trim)
					_box(face, Vector3(x - span / bays * 0.5 + 0.08, y + 1.2, dep * 0.5 - 0.25), Vector3(0.12, 2.4, 0.84), accent)
					for rail_y in [0.3, 1.0]:
						_box(face, Vector3(x, y + rail_y, dep * 0.5 + 0.16), Vector3(span / bays - 0.2, 0.045, 0.045), metal)
					for baluster in range(5):
						_box(face, Vector3(x + (baluster - 2) * span / bays * 0.17, y + 0.63, dep * 0.5 + 0.16), Vector3(0.025, 0.76, 0.025), metal)
			_box(face, Vector3(0, y, dep * 0.5 + 0.015), Vector3(span + 0.1, 0.16, 0.16), trim)
	_glazed_shop_bay(frame, Vector3(0, 1.3, d * 0.5 + 0.06), minf(w * 0.4, 2.3), 2.25, true)
	_box(frame, Vector3(0, 2.55, d * 0.5 + 0.4), Vector3(w * 0.6, 0.16, 0.95), metal)
	_sign(frame, _premise_name("apartment") + "\nAPARTMENTS", Vector3(0, 2.98, d * 0.5 + 0.13), minf(w * 0.62, 4.5), 0.43, Color("526a60"))
	_flat_roof(frame, w, d, h, trim)
	_box(frame, Vector3(0, h + 0.9, -d * 0.17), Vector3(w * 0.33, 1.8, d * 0.4), accent)
	_water_tank(frame, Vector3(w * 0.3, h + 0.1, -d * 0.22))
	# Roof pergola gives the silhouette a lighter finish than another solid box.
	for x in [-w * 0.35, w * 0.35]:
		_beam(frame, Vector3(x, h + 0.1, d * 0.27), Vector3(x, h + 1.35, d * 0.27), 0.065, metal)
	for i in range(6):
		_box(frame, Vector3(0, h + 1.35, d * 0.1 + i * 0.22), Vector3(w * 0.75, 0.08, 0.055), metal)

func office(center: Vector3, floors: int, w: float, d: float) -> void:
	_building_count += 1
	_record_use("office", center, Vector3.BACK, w, d, floors)
	var frame := _frame(center)
	var story: float = 2.2
	var h: float = floors * story
	var stone := Materials.surface(0, Color("a4a18e"))
	var metal := Materials.solid(Color("556361"), 0.65, 0.32)
	_entrance_apron(frame, w, d)
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), stone, true)
	for side in range(4):
		var face := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
		var span: float = w if side % 2 == 0 else d
		var dep: float = d if side % 2 == 0 else w
		var bays: int = maxi(2, floori(span / 1.2))
		for floor_index in range(floors):
			for bay in range(bays):
				var x: float = -span * 0.5 + (bay + 0.5) * span / bays
				var pane: Material = _cool if _rng.randf() < 0.16 else Materials.solid(Color("354c50"), 0.48, 0.15)
				_box(face, Vector3(x, floor_index * story + 1.2, dep * 0.5 + 0.025), Vector3(span / bays - 0.12, 1.65, 0.035), pane)
				_box(face, Vector3(x - span / bays * 0.5, floor_index * story + 1.2, dep * 0.5 + 0.12), Vector3(0.075, story, 0.28), metal)
			_box(face, Vector3(0, (floor_index + 1) * story, dep * 0.5 + 0.15), Vector3(span + 0.15, 0.14, 0.42), stone)
	_box(frame, Vector3(0, h + 0.22, 0), Vector3(w + 0.2, 0.44, d + 0.2), stone)
	_box(frame, Vector3(0, h + 0.62, -d * 0.12), Vector3(w * 0.45, 0.8, d * 0.5), Materials.surface(4, Color("6e7570")))
	if floors >= 6:
		# Corner fins and an open crown vary the high-rise outline without enlarging its plot.
		for x in [-w * 0.44, w * 0.44]:
			_box(frame, Vector3(x, h * 0.5 + 0.45, d * 0.5 + 0.12), Vector3(0.19, h + 0.9, 0.3), metal)
		for i in range(6):
			_box(frame, Vector3(-w * 0.35 + i * w * 0.14, h + 1.15, 0), Vector3(0.08, 0.65, d * 0.68), metal)
	_door(frame, Vector3(0, 1.1, d * 0.5 + 0.08), 1.3, 2.05)
	_box(frame, Vector3(0, 2.4, d * 0.5 + 0.55), Vector3(w * 0.75, 0.16, 1.25), metal)

func warehouse(center: Vector3, w: float, h: float, d: float) -> void:
	_building_count += 1
	_record_use("warehouse", center, Vector3.BACK, w, d, maxi(1, ceili(h / 2.55)))
	var frame := _frame(center)
	var render := Materials.surface(0, Color("a49c87"))
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), render, true)
	_hip_roof(frame, w + 0.5, d + 0.6, h, minf(w, d) * 0.18)
	var shutter := Materials.surface(4, Color("626e67"))
	for i in range(ceili(h * 0.65 / 0.1)):
		_box(frame, Vector3(0, 0.1 + i * 0.1, d * 0.5 + 0.06), Vector3(w * 0.45, 0.085, 0.09), shutter)
	for x in [-w * 0.4, w * 0.4]:
		_window(frame, Vector3(x, h * 0.65, d * 0.5 + 0.04), w * 0.13, h * 0.2, true, render)
	_box(frame, Vector3(0, 0.09, d * 0.5 + 0.8), Vector3(w + 1.0, 0.18, 1.8), Materials.surface(2, Color("898675")))

func tree(center: Vector3, palm: bool = false, branches: int = 9, clusters: int = 14) -> void:
	# Infill passes ask for fewer branches and leaf clusters to keep groves cheap.
	_tree_count += 1
	var frame := _frame(center, Vector3(sin(_tree_count * 2.4), 0, cos(_tree_count * 2.4)))
	var bark := Materials.surface(6, Color("62523a"))
	var h: float = _rng.randf_range(3.3, 5.6)
	if palm:
		_palm(frame, h + 0.8, bark)
		return
	var lean := Vector3(_rng.randf_range(-0.35, 0.35), 0, _rng.randf_range(-0.3, 0.3))
	_beam(frame, Vector3.ZERO, lean + Vector3(0, h * 0.7, 0), 0.26, bark)
	for branch in range(branches):
		var angle: float = branch * TAU / branches + _rng.randf_range(-0.2, 0.2)
		var radius: float = _rng.randf_range(1.0, 1.85)
		var tip := Vector3(cos(angle) * radius, h * _rng.randf_range(0.72, 1.12), sin(angle) * radius) + lean
		var joint := lean + Vector3(0, h * _rng.randf_range(0.44, 0.67), 0)
		_beam(frame, joint, tip, 0.10, bark)
		for cluster in range(clusters):
			var offset := Vector3(_rng.randf_range(-0.7, 0.7), _rng.randf_range(-0.48, 0.62), _rng.randf_range(-0.7, 0.7))
			var basis := Basis.from_euler(Vector3(_rng.randf_range(-0.5, 0.5), _rng.randf_range(0, TAU), _rng.randf_range(-0.5, 0.5)))
			basis = basis.scaled(Vector3.ONE * _rng.randf_range(1.05, 1.55))
			var light: float = _rng.randf_range(0.15, 0.9)
			_batch(_leaf_mesh, Materials.foliage(), frame * Transform3D(basis, tip + offset), Color(light, light, light))

func _make_leaf_cluster() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for leaf in range(11):
		var angle: float = leaf * 2.39996
		var length: float = _rng.randf_range(0.22, 0.44)
		var at := Vector3(cos(angle), _rng.randf_range(-0.12, 0.12), sin(angle)) * 0.3
		var dir := Vector3(cos(angle), _rng.randf_range(-0.35, 0.55), sin(angle))
		var side := Vector3(-sin(angle), 0, cos(angle)) * length * 0.3
		var tip := at + dir * length
		var mid := at + dir * length * 0.5 + Vector3(0, 0.035, 0)
		var shade := Color(_rng.randf_range(0.4, 1.0), 1, 1)
		_triangle(st, at, mid + side, mid, shade)
		_triangle(st, at, mid, mid - side, shade)
		_triangle(st, mid + side, tip, mid, shade)
		_triangle(st, mid, tip, mid - side, shade)
	return st.commit()

## Low bush of leaf clusters hugging the ground: hedges, yards and verges.
func shrub(center: Vector3, size: float) -> void:
	for i in range(3 + int(size * 3.0)):
		var angle: float = i * 2.39996 + _rng.randf() * 0.6
		var r: float = _rng.randf_range(0.0, 0.45) * size
		var at := center + Vector3(cos(angle) * r, _rng.randf_range(0.22, 0.5) * size, sin(angle) * r)
		var basis := Basis.from_euler(Vector3(_rng.randf_range(-0.4, 0.4), _rng.randf_range(0, TAU), _rng.randf_range(-0.4, 0.4)))
		basis = basis.scaled(Vector3(1.4, 1.0, 1.4) * size * _rng.randf_range(0.9, 1.3))
		var light: float = _rng.randf_range(0.1, 0.75)
		_batch(_leaf_mesh, Materials.foliage(), Transform3D(basis, at), Color(light, light, light))

## Smallholding on bare laterite: ridged rows of cassava or maize along local X,
## a stick fence on two sides and a mango tree in one corner.
func farm_plot(center: Vector3, w: float, d: float, along_x: bool) -> void:
	var frame := _frame(center, Vector3.BACK if along_x else Vector3.RIGHT)
	var plot_w: float = w if along_x else d
	var plot_d: float = d if along_x else w
	var earth := Materials.surface(8, Color.WHITE)
	var ridge := Materials.surface(8, Color(0.82, 0.8, 0.78))
	var wood := Materials.surface(6, Color("756047"))
	_box(frame, Vector3(0, 0.012, 0), Vector3(plot_w, 0.03, plot_d), earth)
	var rows: int = maxi(3, floori(plot_d / 0.9))
	var maize: bool = _rng.randf() < 0.5
	for r in range(rows):
		var z: float = -plot_d * 0.5 + (r + 0.5) * plot_d / rows
		_box(frame, Vector3(0, 0.06, z), Vector3(plot_w - 0.5, 0.1, 0.36), ridge)
		var plants: int = floori((plot_w - 0.6) / 0.75)
		for k in range(plants):
			var x: float = -plot_w * 0.5 + 0.55 + k * 0.75 + _rng.randf_range(-0.1, 0.1)
			var tall: float = _rng.randf_range(0.75, 1.0) * (1.25 if maize else 0.8)
			var basis := Basis.from_euler(Vector3(0, _rng.randf_range(0, TAU), 0)).scaled(Vector3(0.55, tall, 0.55))
			var light: float = _rng.randf_range(0.35, 0.95) if maize else _rng.randf_range(0.1, 0.6)
			_batch(_leaf_mesh, Materials.foliage(), frame * Transform3D(basis, Vector3(x, 0.12 + tall * 0.42, z)), Color(light, light, light))
	for i in range(floori(plot_w / 1.4) + 1):
		var x: float = -plot_w * 0.5 + i * plot_w / floori(plot_w / 1.4)
		_beam(frame, Vector3(x, 0, -plot_d * 0.5 - 0.2), Vector3(x, 0.85, -plot_d * 0.5 - 0.2), 0.05, wood)
	for y in [0.35, 0.7]:
		_beam(frame, Vector3(-plot_w * 0.5, y, -plot_d * 0.5 - 0.2), Vector3(plot_w * 0.5, y, -plot_d * 0.5 - 0.2), 0.03, wood)
	tree(center + frame.basis * Vector3(plot_w * 0.5 - 0.6, 0, plot_d * 0.5 + 0.4), false, 6, 9)

## Laterite footpath or yard track from `a` to `b`, just proud of the ground.
func track(a: Vector3, b: Vector3, width: float) -> void:
	var frame := Transform3D(Basis(Vector3.UP, atan2(b.x - a.x, b.z - a.z)), (a + b) * 0.5)
	_box(frame, Vector3(0, 0.012, 0), Vector3(width, 0.03, a.distance_to(b)), Materials.surface(8, Color.WHITE))

## Asphalt neighbourhood lane, as in the surrounding street grid.
func lane(center: Vector3, size: Vector2) -> void:
	_box(_frame(center), Vector3(0, 0.015, 0), Vector3(size.x, 0.06, size.y), Materials.surface(1, Color("55574e")))

## Ground footprints (XZ) of everything batched so far, for the infill planner.
## Leaf clusters are left out: a tree's branches already outline its canopy.
func pending_footprints() -> Array[Rect2]:
	var rects: Array[Rect2] = []
	for batch: Dictionary in _batches.values():
		if batch["mesh"] == _leaf_mesh or batch["background"]:
			continue
		var bounds: AABB = (batch["mesh"] as Mesh).get_aabb()
		for transform: Transform3D in batch["transforms"]:
			var box: AABB = transform * bounds
			if box.size.x < 0.12 and box.size.z < 0.12:
				continue
			rects.append(Rect2(box.position.x, box.position.z, box.size.x, box.size.z))
	return rects

func _palm(frame: Transform3D, h: float, bark: Material) -> void:
	var previous := Vector3.ZERO
	for segment in range(8):
		var t: float = (segment + 1) / 8.0
		var next := Vector3(0.35 * t * t, h * t, 0.13 * sin(t * PI))
		_beam(frame, previous, next, 0.23 - t * 0.08, bark)
		previous = next
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for frond in range(11):
		var angle: float = frond * TAU / 11.0
		var radial := Vector3(cos(angle), 0, sin(angle))
		var lateral := Vector3(-sin(angle), 0, cos(angle))
		var length: float = _rng.randf_range(2.0, 2.9)
		for i in range(16):
			var t: float = i / 16.0
			var spine := previous + radial * length * t + Vector3(0, sin(t * PI) * 0.65 - t * t * 0.9, 0)
			var spread: float = sin(t * PI) * 0.53 + 0.04
			for sign_value in [-1.0, 1.0]:
				var tip: Vector3 = spine + lateral * spread * sign_value - radial * 0.23 - Vector3(0, 0.1, 0)
				_triangle(st, spine, tip, spine + radial * 0.15, Color(0.55 + t * 0.25, 1, 1))
	var leaves := MeshInstance3D.new()
	leaves.mesh = st.commit()
	leaves.material_override = Materials.foliage()
	leaves.transform = frame
	leaves.name = "PalmFronds"
	add_child(leaves)

func parking_lot(center: Vector3, w: float, d: float, count: int) -> void:
	var frame := _frame(center)
	_box(frame, Vector3(0, 0.01, 0), Vector3(w, 0.09, d), Materials.surface(1, Color("454a43")))
	var paint := Materials.solid(Color("bfb49b"))
	var cols: int = mini(5, maxi(2, floori(w / 1.65)))
	var rows: int = ceili(float(count) / cols)
	for i in range(count):
		var x: float = -w * 0.5 + (i % cols + 0.5) * w / cols
		var z: float = -d * 0.5 + (floori(float(i) / cols) + 0.5) * d / rows
		var car := FleetActor.new()
		car.configure("car",i+int(abs(center.x+center.z)))
		car.position = center + Vector3(x, 0.06, z)
		car.rotation.y = PI if i % 2 == 0 else 0.0
		car.name = "ParkedVehicle"
		add_child(car)
		_box(frame, Vector3(x - w / cols * 0.48, 0.062, z), Vector3(0.035, 0.005, 1.6), paint)
	for z in [-d * 0.5, d * 0.5]:
		_box(frame, Vector3(0, 0.12, z), Vector3(w, 0.24, 0.16), Materials.surface(2, Color("9a9685")))

## Roadside filling station for the project's own fuel brand (no real retailer):
## a concrete forecourt with a deep-fascia canopy on two clad columns over one
## pump island with two dispensers, a small shop with the kit's framed sign, and a
## price pylon on a planted island between the driveways. Local +Z is the road;
## `shop_side` puts the shop at local +X (1) or -X (-1); `apron` extends the
## forecourt to the footway, `footway` is that footway's width (driveway
## crossovers); `two_way` opens the second driveway. `glow` (soffit and logo
## lightboxes), `fascia` and `stripe` are the caller's night-lit materials.
## Returns light positions.
func filling_station(center: Vector3, facing: Vector3, shop_side: float, apron: float, footway: float, two_way: bool, glow: Material, fascia: Material, stripe: Material) -> Array[Vector3]:
	var frame := _frame(center, facing)
	var s: float = -1.0 if shop_side < 0.0 else 1.0
	var front: float = 4.2 + apron
	var concrete := Materials.surface(2, Color("aaa99c"))
	var kerb := Materials.surface(2, Color("8b8f81"))
	# Corporate panels are clean aluminium composite, not the kit's weathered sheet metal.
	var teal := Materials.solid(FUEL_TEAL, 0.25, 0.42)
	var white := Materials.solid(Color("e9e7df"), 0.15, 0.45)
	var amber := Materials.solid(FUEL_AMBER, 0.1, 0.5)
	var steel := Materials.solid(Color("53584f"), 0.35)
	var aluminum := Materials.solid(Color("a6aca6"), 0.75, 0.28)
	var glass := Materials.solid(Color("17201f"), 0.4, 0.12)
	var hose := Materials.solid(Color("15181a"), 0.0, 0.6)
	var paint := Materials.solid(Color("e8e4d6"))
	var soil := Materials.solid(Color("534d3b"))
	# Forecourt slab, kerbed at the back and sides; the front meets the footway.
	_box(frame, Vector3(0, 0.06, apron * 0.5), Vector3(12.4, 0.12, 8.4 + apron), concrete)
	_box(frame, Vector3(0, 0.1, -4.26), Vector3(12.52, 0.2, 0.12), kerb)
	for x in [-6.26, 6.26]:
		_box(frame, Vector3(x, 0.1, apron * 0.5), Vector3(0.12, 0.2, 8.52 + apron), kerb)
	# Driveways at the canopy end and beside the shop, with painted flow arrows; a
	# planted island between them carries the price pylon.
	var drives: Array = [[-4.7, 3.0]]
	if two_way:
		drives.append([0.8, 3.2])
	else:
		_box(frame, Vector3(0.8 * s, 0.2, front - 0.45), Vector3(3.2, 0.16, 0.5), kerb)
	_box(frame, Vector3(3.6 * s, 0.2, front - 0.45), Vector3(2.0, 0.16, 0.5), kerb)
	for i in range(drives.size()):
		var dx: float = drives[i][0] * s
		var flow: float = -1.0 if i == 0 else 1.0
		var at := Vector3(dx, 0.125, front - 1.7)
		_box(frame, at, Vector3(0.12, 0.006, 0.9), paint)
		_box(frame * Transform3D(Basis(Vector3.UP, PI * 0.25), at + Vector3(0, 0, flow * 0.5)), Vector3.ZERO, Vector3(0.32, 0.006, 0.32), paint)
		if footway > 0.0:
			_box(frame, Vector3(dx, 0.155, front + footway * 0.5), Vector3(drives[i][1], 0.02, footway), Materials.surface(2, Color("9d9c90")))
	var px: float = -2.0 * s
	_box(frame, Vector3(px, 0.2, front - 0.65), Vector3(2.0, 0.16, 0.9), kerb)
	_box(frame, Vector3(px, 0.285, front - 0.65), Vector3(1.84, 0.02, 0.74), soil)
	for k in [-0.62, 0.0, 0.62]:
		_batch(_leaf_mesh, Materials.foliage(), frame * Transform3D(Basis.from_scale(Vector3(0.85, 0.75, 0.75)), Vector3(px + k, 0.55, front - 0.65)))
	# The pylon stands at the shop-side corner, clear of the canopy's lettering.
	_price_pylon(frame, Vector3(5.5 * s, 0.12, front - 0.75), teal, glow, stripe, glass, kerb)
	# Canopy: white deck and soffit with LED panels, teal fascia with an amber reveal.
	var cx: float = -2.0 * s
	var ch: float = 3.6
	_box(frame, Vector3(cx, ch + 0.33, 0.1), Vector3(7.6, 0.1, 5.6), white)
	_box(frame, Vector3(cx, ch + 0.03, 0.1), Vector3(7.5, 0.06, 5.5), white)
	for lx in [-2.6, -0.9, 0.9, 2.6]:
		for lz in [-1.8, 0.0, 1.8]:
			_box(frame, Vector3(cx + lx, ch - 0.005, 0.1 + lz), Vector3(1.1, 0.02, 0.5), glow)
	for side in [-1.0, 1.0]:
		_box(frame, Vector3(cx, ch + 0.33, 0.1 + side * 2.8), Vector3(7.7, 0.65, 0.1), fascia)
		_box(frame, Vector3(cx + side * 3.8, ch + 0.33, 0.1), Vector3(0.1, 0.65, 5.7), fascia)
		_box(frame, Vector3(cx, ch + 0.04, 0.1 + side * 2.86), Vector3(7.72, 0.09, 0.03), stripe)
		_box(frame, Vector3(cx + side * 3.86, ch + 0.04, 0.1), Vector3(0.03, 0.09, 5.72), stripe)
		_box(frame, Vector3(cx, ch + 0.66, 0.1 + side * 2.86), Vector3(7.72, 0.04, 0.03), white)
		_box(frame, Vector3(cx + side * 3.86, ch + 0.66, 0.1), Vector3(0.03, 0.04, 5.72), white)
		_fuel_brand(frame, Vector3(cx, ch + 0.33, 0.1 + side * 2.86), 0.0 if side > 0.0 else PI, 3.6, 0.5, stripe)
		_fuel_brand(frame, Vector3(cx + side * 3.86, ch + 0.33, 0.1), side * PI * 0.5, 3.0, 0.45, stripe)
	# Two columns on the island: teal-clad base, amber band, aluminium shaft, downpipe.
	for col_x in [-4.4, 0.4]:
		var x: float = col_x * s
		_box(frame, Vector3(x, 0.87, 0.1), Vector3(0.34, 1.2, 0.34), teal)
		_box(frame, Vector3(x, 1.51, 0.1), Vector3(0.35, 0.08, 0.35), stripe)
		_box(frame, Vector3(x, (1.55 + ch) * 0.5, 0.1), Vector3(0.3, ch - 1.55, 0.3), aluminum)
		_beam(frame, Vector3(x + 0.19, 0.3, 0.1), Vector3(x + 0.19, ch, 0.1), 0.06, steel)
	# Pump island with striped noses, crash bollards, bins and a fire point.
	_box(frame, Vector3(cx, 0.195, 0.1), Vector3(5.8, 0.15, 0.84), Materials.surface(2, Color("c6c3b4")))
	for end in [-1.0, 1.0]:
		var ex: float = cx + end * 2.9
		for k in range(3):
			_box(frame, Vector3(ex - end * (0.06 + k * 0.12), 0.2, 0.1), Vector3(0.11, 0.162, 0.86), Materials.solid(Color("e3b23c") if k % 2 == 0 else Color("23251f")))
		_beam(frame, Vector3(ex + end * 0.35, 0.12, 0.1), Vector3(ex + end * 0.35, 0.95, 0.1), 0.12, Materials.solid(Color("e3b23c"), 0.2, 0.5))
		_beam(frame, Vector3(ex - end * 0.55, 0.27, 0.42), Vector3(ex - end * 0.55, 0.92, 0.42), 0.3, Materials.solid(Color("2f4a3c"), 0.1, 0.6))
	_beam(frame, Vector3(cx, 0.27, 0.42), Vector3(cx, 0.72, 0.42), 0.13, Materials.solid(Color("b7302a"), 0.2, 0.45))
	_beam(frame, Vector3(cx + 0.24, 0.27, 0.42), Vector3(cx + 0.24, 0.47, 0.42), 0.22, Materials.solid(Color("b7302a"), 0.1, 0.6))
	for dx in [-3.1, -0.9]:
		_dispenser(frame, Vector3(dx * s, 0.27, 0.1), fascia, white, stripe, glass, steel, hose)
	# Shop: plastered box, glazed front with the kit's sign, side window to the
	# forecourt, flat roof with a teal parapet, water tank and air conditioner.
	var sw: float = 3.1
	var sd: float = 5.4
	var sh: float = 3.0
	var shop := frame * Transform3D(Basis.IDENTITY, Vector3(4.35 * s, 0.12, -1.2))
	_box(shop, Vector3(0, sh * 0.5, 0), Vector3(sw, sh, sd), Materials.surface(0, Color("d8d2c2")), true)
	_box(shop, Vector3(0, 0.15, 0), Vector3(sw + 0.06, 0.3, sd + 0.06), kerb)
	_flat_roof(shop, sw, sd, sh, teal)
	_glazed_shop_bay(shop, Vector3(-0.72, 1.25, sd * 0.5 + 0.02), 1.2, 1.9, true)
	_glazed_shop_bay(shop, Vector3(0.72, 1.25, sd * 0.5 + 0.02), 1.2, 1.9, false)
	_sign(shop, "SANKOFA SHOP\nSNACKS • COLD DRINKS • MOMO", Vector3(0, 2.55, sd * 0.5 + 0.07), sw - 0.1, 0.5, FUEL_TEAL)
	var side_face := shop * Transform3D(Basis(Vector3.UP, -PI * 0.5 * s), Vector3(-sw * 0.5 * s, 0, 0))
	_glazed_shop_bay(side_face, Vector3(0.9, 1.35, 0.02), 2.4, 1.3, false)
	_water_tank(shop, Vector3(-0.55 * s, sh + 0.1, -1.5))
	_air_conditioner(shop * Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO), Vector3(0.6, 2.2, sd * 0.5 + 0.17))
	# Chest cooler at the shop door and the air & water point on the forecourt.
	_box(shop, Vector3(1.0 * s, 0.45, sd * 0.5 + 0.5), Vector3(0.8, 0.6, 0.45), Materials.solid(Color("e9ebe6"), 0.2, 0.4))
	_box(shop, Vector3(1.0 * s, 0.78, sd * 0.5 + 0.5), Vector3(0.82, 0.06, 0.47), teal)
	var air := Vector3(2.55 * s, 0.12, -2.9)
	_box(frame, air + Vector3(0, 0.55, 0), Vector3(0.24, 1.1, 0.2), teal)
	_box(frame, air + Vector3(0, 1.13, 0), Vector3(0.28, 0.06, 0.24), amber)
	_beam(frame, air + Vector3(-0.13 * s, 0.85, 0), air + Vector3(-0.22 * s, 0.25, 0.1), 0.025, hose)
	# A customer at the pump, parked alongside the island.
	var car := FleetActor.new()
	car.configure("car", 7 + int(absf(center.x * 3.0 + center.z)))
	car.position = frame * Vector3(cx - 0.6 * s, 0.12, -0.85)
	car.rotation.y = atan2(facing.x, facing.z) + PI * 0.5
	car.name = "ParkedVehicle"
	add_child(car)
	var lights: Array[Vector3] = [frame * Vector3(cx, ch - 0.35, 0.1)]
	return lights

func _dispenser(frame: Transform3D, base: Vector3, teal: Material, white: Material, amber: Material, glass: Material, steel: Material, hose: Material) -> void:
	# Double-sided multi-product dispenser: plinth, white cabinet, teal header,
	# a lit display and three nozzles (diesel, super, premium) on each face.
	_box(frame, base + Vector3(0, 0.04, 0), Vector3(0.9, 0.08, 0.5), steel)
	_box(frame, base + Vector3(0, 0.58, 0), Vector3(0.8, 1.0, 0.42), white)
	_box(frame, base + Vector3(0, 1.17, 0), Vector3(0.86, 0.18, 0.46), teal)
	_box(frame, base + Vector3(0, 1.085, 0), Vector3(0.87, 0.03, 0.47), amber)
	var nozzles: Array[Color] = [Color("1d2422"), Color("2f7d4f"), Color("d1a12f")]
	for face in [-1.0, 1.0]:
		var fz: float = face * 0.215
		_box(frame, base + Vector3(0, 0.82, fz), Vector3(0.56, 0.3, 0.012), glass)
		_box(frame, base + Vector3(0, 0.46, fz + face * 0.03), Vector3(0.62, 0.05, 0.06), steel)
		for k in range(3):
			_box(frame, base + Vector3(-0.2 + k * 0.2, 0.55, fz + face * 0.06), Vector3(0.08, 0.14, 0.06), Materials.solid(nozzles[k]))
		_beam(frame, base + Vector3(0.34, 1.07, fz), base + Vector3(0.4, 0.38, fz + face * 0.11), 0.03, hose)
		_beam(frame, base + Vector3(0.4, 0.38, fz + face * 0.11), base + Vector3(0.2, 0.5, fz + face * 0.08), 0.03, hose)
		var screen := Node3D.new()
		screen.name = "PumpDisplay"
		screen.transform = frame * Transform3D(Basis(Vector3.UP, 0.0 if face > 0.0 else PI), base + Vector3(0, 0.82, fz + face * 0.008))
		add_child(screen)
		var digits := Props.label(screen, "125.40\n8.83 L", Vector3.ZERO, 0.45, 0.24, Color("8dffb0"), "PumpDigits")
		digits.shaded = false
		digits.visibility_range_end = 35.0

func _price_pylon(frame: Transform3D, base: Vector3, teal: Material, white: Material, amber: Material, glass: Material, kerb: Material) -> void:
	# Double-sided pylon across the frontage, so traffic from either side reads it:
	# brand panel, amber stripe and three LED price rows (GHS per litre).
	_box(frame, base + Vector3(0, 0.25, 0), Vector3(0.5, 0.5, 1.3), kerb)
	_box(frame, base + Vector3(0, 2.4, 0), Vector3(0.3, 3.8, 1.1), teal)
	_box(frame, base + Vector3(0, 4.32, 0), Vector3(0.34, 0.06, 1.14), white)
	var rows: Array = [["SUPER", "14.20"], ["DIESEL", "15.10"], ["LPG", "13.40"]]
	for face in [-1.0, 1.0]:
		var fx: float = face * 0.155
		_box(frame, base + Vector3(fx, 3.75, 0), Vector3(0.012, 0.85, 1.0), white)
		_box(frame, base + Vector3(fx, 3.26, 0), Vector3(0.014, 0.07, 1.0), amber)
		for row in range(rows.size()):
			_box(frame, base + Vector3(fx, 2.85 - row * 0.5, 0), Vector3(0.012, 0.4, 1.0), glass)
		var panel := Node3D.new()
		panel.name = "PricePylon"
		panel.transform = frame * Transform3D(Basis(Vector3.UP, face * PI * 0.5), base + Vector3(fx + face * 0.008, 0, 0))
		add_child(panel)
		Props.ellipsoid(panel, Vector3(-0.31, 3.75, 0.004), Vector3(0.3, 0.3, 0.01), Materials.solid(FUEL_TEAL), "FuelBadge")
		Props.label(panel, "S", Vector3(-0.31, 3.75, 0.012), 0.16, 0.2, Color("f4f1e6"), "FuelBadgeLetter").visibility_range_end = 70.0
		Props.label(panel, "SANKOFA", Vector3(0.12, 3.78, 0.008), 0.62, 0.2, FUEL_TEAL, "FuelName").visibility_range_end = 70.0
		Props.label(panel, "GHS PER LITRE", Vector3(0.12, 3.55, 0.008), 0.5, 0.07, FUEL_TEAL.darkened(0.2), "FuelUnit").visibility_range_end = 30.0
		for row in range(rows.size()):
			var y: float = 2.85 - row * 0.5
			var product := Props.label(panel, rows[row][0], Vector3(-0.27, y, 0.008), 0.36, 0.13, Color("e9e6da"), "FuelProduct")
			var price := Props.label(panel, rows[row][1], Vector3(0.2, y, 0.008), 0.48, 0.27, Color("ffb23a"), "FuelPrice")
			for l in [product, price]:
				l.shaded = false
				l.visibility_range_end = 70.0

func _fuel_brand(frame: Transform3D, at: Vector3, yaw: float, w: float, h: float, roundel: Material) -> void:
	# Backlit fascia lettering with an amber roundel, drawn unshaded so it reads
	# as illuminated by day and by night.
	var root := Node3D.new()
	root.name = "FuelBrand"
	root.transform = frame * Transform3D(Basis(Vector3.UP, yaw), at)
	add_child(root)
	var bx: float = -w * 0.5 + h * 0.45
	Props.ellipsoid(root, Vector3(bx, 0, 0.012), Vector3(h * 0.82, h * 0.82, 0.02), roundel, "FuelBadge")
	Props.label(root, "S", Vector3(bx, 0, 0.026), h * 0.45, h * 0.55, FUEL_TEAL.darkened(0.25), "FuelBadgeLetter").visibility_range_end = 90.0
	var name_tag := Props.label(root, "SANKOFA", Vector3(h * 0.4, 0, 0.02), w - h * 1.2, h * 0.62, Color("f4f1e6"), "FuelName")
	name_tag.shaded = false
	name_tag.visibility_range_end = 90.0

## Driveway lane from a road edge `a` to a forecourt `b`: a crossover over the
## 1.5 m footway, a culvert slab over the open drain, then kerbed asphalt.
func access_lane(a: Vector3, b: Vector3, width: float) -> void:
	var length: float = a.distance_to(b)
	var frame := Transform3D(Basis(Vector3.UP, atan2(b.x - a.x, b.z - a.z)), a)
	_box(frame, Vector3(0, 0.155, 0.75), Vector3(width, 0.02, 1.5), Materials.surface(2, Color("9d9c90")))
	_box(frame, Vector3(0, 0.13, 1.8), Vector3(width, 0.06, 0.8), Materials.surface(2, Color("8f8e83")))
	_box(frame, Vector3(0, 0.06, (2.2 + length) * 0.5), Vector3(width, 0.12, length - 2.2), Materials.surface(1, Color("4a4f48")))
	for side in [-1.0, 1.0]:
		_box(frame, Vector3(side * (width * 0.5 + 0.06), 0.12, (2.2 + length) * 0.5), Vector3(0.12, 0.2, length - 2.2), Materials.surface(2, Color("8b8f81")))

## Community football ground: a striped pitch with full markings (arcs included)
## and worn goalmouths, goals with nets, corner flags, pitchside boards for the
## sim's own businesses, two dugouts on the near touchline, a roofed stand seated
## in red, gold and green on the far touchline, four floodlight masts and a
## chain-link fence with a gate. The pitch is `w` (along X) by `d` around
## `center`; the stand is on `stand_side` (+1 = +Z) with `rows` of seats. `lamp`
## is the caller's night-lit floodlight material. Returns the floodlight positions.
func football_ground(center: Vector3, w: float, d: float, stand_side: float, rows: int,
		ground_name: String, lamp: Material) -> Array[Vector3]:
	var frame := _frame(center, Vector3(0, 0, -1.0 if stand_side < 0.0 else 1.0))
	var hw: float = w * 0.5
	var hd: float = d * 0.5
	var white := Materials.solid(Color("eceee6"), 0.0, 0.55)
	var steel := Materials.solid(Color("9aa0a2"), 0.6, 0.38)
	var concrete := Materials.surface(2, Color("a8a596"))
	# Turf in mower bands across the pitch, running 1.4 m past the lines.
	var run: float = 1.4
	var bands: int = 2 * maxi(3, roundi((w + run * 2.0) / 3.6))
	var band: float = (w + run * 2.0) / bands
	var turf: Array[Material] = [Materials.surface(7, Color("2b6226")), Materials.surface(7, Color("377531"))]
	for i in range(bands):
		_box(frame, Vector3(-hw - run + (i + 0.5) * band, 0.03, 0), Vector3(band, 0.05, d + run * 2.0), turf[i % 2])
	# Worn goalmouths and centre: soft-edged decals, a few overlapping per area.
	var wear := SurfaceTool.new()
	wear.begin(Mesh.PRIMITIVE_TRIANGLES)
	for s in [-1.0, 1.0]:
		for patch: Vector4 in [Vector4(1.1, 0.0, 3.0, 2.4), Vector4(0.6, 0.5, 1.7, 1.4), Vector4(1.9, -0.4, 1.8, 1.3)]:
			_decal_quad(wear, Vector2(s * (hw - patch.x), s * patch.y), Vector2(patch.z, patch.w), 0.058)
	_decal_quad(wear, Vector2.ZERO, Vector2(2.2, 1.5), 0.058)
	_decal_quad(wear, Vector2(0.4, -0.2), Vector2(1.2, 0.9), 0.058)
	var worn := MeshInstance3D.new()
	worn.mesh = wear.commit()
	worn.material_override = _wear_material()
	worn.transform = frame
	worn.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	worn.name = "PitchWear"
	add_child(worn)
	_pitch_markings(frame, hw, hd, white)
	var net := _lattice_material(false, Color(0.97, 0.97, 0.95))
	for s in [-1.0, 1.0]:
		_goal(frame, Vector3(s * (hw - 0.06), 0, 0), s, d * 0.24, 1.15, white, net)
	var flag_pole := Materials.solid(Color("e3b23c"), 0.1, 0.5)
	var flag := Materials.solid(Color("c8352b"), 0.0, 0.7)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var corner := Vector3(sx * hw, 0, sz * hd)
			_beam(frame, corner, corner + Vector3(0, 0.82, 0), 0.03, flag_pole)
			_box(frame, corner + Vector3(-sx * 0.11, 0.74, 0), Vector3(0.2, 0.14, 0.01), flag)
	# Boards along the far touchline, either side of the dugouts and behind both goals.
	var adverts := Node3D.new()
	adverts.name = "PitchsideAdverts"
	adverts.transform = frame
	add_child(adverts)
	var dugout_x: float = w * 0.15
	var gap: float = dugout_x + 1.6
	var brand: int = 0
	brand = _board_run(frame, adverts, Vector3(-hw, 0, hd + 0.8), Vector3(hw, 0, hd + 0.8), brand)
	brand = _board_run(frame, adverts, Vector3(-hw, 0, -hd - 0.8), Vector3(-gap, 0, -hd - 0.8), brand)
	brand = _board_run(frame, adverts, Vector3(gap, 0, -hd - 0.8), Vector3(hw, 0, -hd - 0.8), brand)
	for s in [-1.0, 1.0]:
		brand = _board_run(frame, adverts, Vector3(s * (hw + 1.35), 0, -hd + 0.4), Vector3(s * (hw + 1.35), 0, hd - 0.4), brand)
	for s in [-1.0, 1.0]:
		_dugout(frame, Vector3(s * dugout_x, 0, -hd - 1.35), Color("b8322a") if s < 0.0 else Color("2a55a8"))
	var stand_w: float = minf(w * 0.72, 16.0)
	_box(frame, Vector3(0, 0.03, hd + 1.17), Vector3(stand_w + 1.2, 0.06, 0.66), concrete)
	var back: float = _stand(frame, hd + 1.5, stand_w, rows, ground_name, steel)
	var lights: Array[Vector3] = []
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			lights.append(frame * _floodlight(frame, Vector3(sx * (hw + 1.9), 0, sz * (hd + 1.9)), steel, lamp))
	_ground_fence(frame, hw + 2.4, -hd - 2.3, back - 0.35, stand_w * 0.5 + 0.2, steel)
	return lights

## Yard and car-park floodlight to match the football grounds' masts: a
## galvanised tapered pole on a plinth with two LED heads on a T-bracket. `lamp`
## is the caller's night-lit material. Returns the light position.
func area_light(base: Vector3, lamp: Material) -> Vector3:
	var yaw: float = base.x * 0.37 + base.z * 0.11
	var frame := _frame(base, Vector3(sin(yaw), 0, cos(yaw)))
	var steel := Materials.solid(Color("9aa0a2"), 0.6, 0.38)
	var housing := Materials.solid(Color("3a3f42"), 0.5, 0.4)
	var h: float = 8.5
	_box(frame, Vector3(0, 0.15, 0), Vector3(0.55, 0.3, 0.55), Materials.surface(2, Color("8f8c80")))
	_beam(frame, Vector3(0, 0.3, 0), Vector3(0, h, 0), 0.22, steel)
	_box(frame, Vector3(0, h - 0.05, 0), Vector3(1.5, 0.08, 0.1), steel)
	for x in [-0.62, 0.62]:
		var head := frame * Transform3D(Basis(Vector3.RIGHT, 0.6), Vector3(x, h + 0.08, 0.12))
		_box(head, Vector3.ZERO, Vector3(0.5, 0.36, 0.13), housing)
		_box(head, Vector3(0, 0, 0.07), Vector3(0.43, 0.29, 0.012), lamp)
	return base + Vector3(0, h, 0)

func _pitch_markings(frame: Transform3D, hw: float, hd: float, white: Material) -> void:
	# All lines as one flat mesh: touchlines, goal lines and halfway line, centre
	# circle and spot, both areas with their penalty spots and arcs, corner arcs.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lt: float = 0.12
	var y: float = 0.062
	var w: float = hw * 2.0
	var d: float = hd * 2.0
	for z in [-hd, hd - lt]:
		_flat_rect(st, -hw, z, hw, z + lt, y)
	for x in [-hw, hw - lt]:
		_flat_rect(st, x, -hd, x + lt, hd, y)
	_flat_rect(st, -lt * 0.5, -hd, lt * 0.5, hd, y)
	var circle: float = d * 0.15
	_flat_ring(st, Vector2.ZERO, circle - lt, circle, 0.0, TAU, 40, y)
	_flat_ring(st, Vector2.ZERO, 0.0, 0.11, 0.0, TAU, 12, y)
	var spot: float = w * 0.115
	for s in [-1.0, 1.0]:
		for area: Vector2 in [Vector2(w * 0.17, d * 0.66), Vector2(w * 0.075, d * 0.4)]:
			var edge: float = s * (hw - area.x)
			_flat_rect(st, edge - lt * 0.5, -area.y * 0.5, edge + lt * 0.5, area.y * 0.5, y)
			for z in [-area.y * 0.5, area.y * 0.5 - lt]:
				_flat_rect(st, edge, z, s * hw, z + lt, y)
		var spot_at := Vector2(s * (hw - spot), 0)
		_flat_ring(st, spot_at, 0.0, 0.09, 0.0, TAU, 10, y)
		var half_arc: float = acos(clampf((w * 0.17 - spot) / circle, -1.0, 1.0))
		var toward_centre: float = PI if s > 0.0 else 0.0
		_flat_ring(st, spot_at, circle - lt, circle, toward_centre - half_arc, toward_centre + half_arc, 14, y)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var inward: float = atan2(-sz, -sx)
			_flat_ring(st, Vector2(sx * hw, sz * hd), 0.45 - lt, 0.45, inward - PI * 0.25, inward + PI * 0.25, 6, y)
	var markings := MeshInstance3D.new()
	markings.mesh = st.commit()
	markings.material_override = white
	markings.transform = frame
	markings.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	markings.name = "PitchMarkings"
	add_child(markings)

func _decal_quad(st: SurfaceTool, center: Vector2, size: Vector2, y: float) -> void:
	var corners: Array[Vector2] = [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)]
	for k in [0, 1, 2, 0, 2, 3]:
		var c: Vector2 = corners[k]
		st.set_normal(Vector3.UP)
		st.set_uv(c + Vector2(0.5, 0.5))
		st.add_vertex(Vector3(center.x + c.x * size.x, y, center.y + c.y * size.y))

func _wear_material() -> StandardMaterial3D:
	# Trodden turf: a radial fade with a ragged edge, tinted dry olive.
	if not _special_materials.has("wear"):
		var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		for y in range(64):
			for x in range(64):
				var r: float = Vector2(x - 31.5, y - 31.5).length() / 31.5
				var fade: float = smoothstep(1.0, 0.25, r)
				var grain: float = fposmod(sin(x * 12.9898 + y * 78.233) * 43758.5453, 1.0)
				image.set_pixel(x, y, Color(1, 1, 1, clampf(fade * (0.62 + (grain - 0.5) * 0.35), 0.0, 1.0)))
		image.generate_mipmaps()
		var material := StandardMaterial3D.new()
		material.albedo_texture = ImageTexture.create_from_image(image)
		material.albedo_color = Color("6e6a3c")
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.roughness = 0.95
		_special_materials["wear"] = material
	return _special_materials["wear"]

func _flat(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	if (b - a).cross(c - a).y < 0.0:
		_triangle(st, a, c, b)
	else:
		_triangle(st, a, b, c)

func _flat_rect(st: SurfaceTool, x0: float, z0: float, x1: float, z1: float, y: float) -> void:
	var a := Vector3(minf(x0, x1), y, minf(z0, z1))
	var b := Vector3(maxf(x0, x1), y, maxf(z0, z1))
	_flat(st, a, Vector3(a.x, y, b.z), Vector3(b.x, y, a.z))
	_flat(st, Vector3(b.x, y, a.z), Vector3(a.x, y, b.z), b)

func _flat_ring(st: SurfaceTool, c: Vector2, r0: float, r1: float, a0: float, a1: float, steps: int, y: float) -> void:
	for i in range(steps):
		var t0: float = lerpf(a0, a1, float(i) / steps)
		var t1: float = lerpf(a0, a1, float(i + 1) / steps)
		var outer0 := Vector3(c.x + cos(t0) * r1, y, c.y + sin(t0) * r1)
		var outer1 := Vector3(c.x + cos(t1) * r1, y, c.y + sin(t1) * r1)
		var inner0 := Vector3(c.x + cos(t0) * r0, y, c.y + sin(t0) * r0)
		var inner1 := Vector3(c.x + cos(t1) * r0, y, c.y + sin(t1) * r0)
		_flat(st, inner0, outer0, outer1)
		if r0 > 0.0:
			_flat(st, inner0, outer1, inner1)

func _goal(frame: Transform3D, at: Vector3, out: float, gw: float, gh: float, white: Material, net: Material) -> void:
	# Posts and crossbar on the goal line; stanchions hold the net up and back.
	var roof := Vector3(out * 0.5, gh * 0.94, 0)
	var base := Vector3(out * 0.95, 0.02, 0)
	for z in [-gw * 0.5, gw * 0.5]:
		var side: Vector3 = at + Vector3(0, 0, z)
		_beam(frame, side, side + Vector3(0, gh, 0), 0.075, white)
		_beam(frame, side + Vector3(0, gh, 0), side + roof, 0.03, white)
		_beam(frame, side + roof, side + base, 0.03, white)
		_beam(frame, side + Vector3(0, 0.02, 0), side + base, 0.03, white)
	_beam(frame, at + Vector3(0, gh, -gw * 0.5 - 0.035), at + Vector3(0, gh, gw * 0.5 + 0.035), 0.075, white)
	_beam(frame, at + base + Vector3(0, 0, -gw * 0.5), at + base + Vector3(0, 0, gw * 0.5), 0.03, white)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lo := Vector3(0, 0, -gw * 0.5)
	var hi := Vector3(0, 0, gw * 0.5)
	var bar := Vector3(0, gh, 0)
	_net_quad(st, at + bar + lo, at + bar + hi, at + roof + hi, at + roof + lo, 0.11)
	_net_quad(st, at + roof + lo, at + roof + hi, at + base + hi, at + base + lo, 0.11)
	for z: Vector3 in [lo, hi]:
		_net_quad(st, at + z + Vector3(0, 0.02, 0), at + z + bar, at + z + roof, at + z + base, 0.11)
	var mesh := MeshInstance3D.new()
	mesh.mesh = st.commit()
	mesh.material_override = net
	mesh.transform = frame
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.name = "GoalNet"
	add_child(mesh)

func _net_quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, cell: float) -> void:
	# A planar net or mesh panel whose texture cells are `cell` metres wide.
	var u: Vector3 = (p1 - p0).normalized()
	var v: Vector3 = (p3 - p0).normalized()
	var normal: Vector3 = u.cross(v).normalized()
	for p: Vector3 in [p0, p1, p2, p0, p2, p3]:
		st.set_normal(normal)
		st.set_uv(Vector2((p - p0).dot(v), (p - p0).dot(u)) / cell)
		st.add_vertex(p)

func _lattice_material(diamond: bool, color: Color) -> StandardMaterial3D:
	# Goal net (square) or chain-link (diamond): opaque cords over clear cells,
	# mipmapped so distant panels fade to a faint veil rather than shimmer.
	var key := "lattice:%s:%s" % [diamond, color.to_html()]
	if _special_materials.has(key):
		return _special_materials[key]
	var image := Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 0))
	for i in range(32):
		for t in range(2):
			if diamond:
				image.set_pixel((i + t) % 32, i, Color.WHITE)
				image.set_pixel(posmod(31 - i + t, 32), i, Color.WHITE)
			else:
				image.set_pixel(i, t, Color.WHITE)
				image.set_pixel(t, i, Color.WHITE)
	image.generate_mipmaps()
	var material := StandardMaterial3D.new()
	material.albedo_texture = ImageTexture.create_from_image(image)
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.metallic = 0.45 if diamond else 0.0
	material.roughness = 0.55 if diamond else 0.9
	_special_materials[key] = material
	return material

func _glazing(color: Color) -> StandardMaterial3D:
	var key := "glazing:" + color.to_html()
	if not _special_materials.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.cull_mode = BaseMaterial3D.CULL_DISABLED
		material.metallic = 0.1
		material.roughness = 0.12
		_special_materials[key] = material
	return _special_materials[key]

func _board_run(frame: Transform3D, root: Node3D, a: Vector3, b: Vector3, brand: int) -> int:
	# A straight run of ~2.6 m pitchside boards, lettered on both faces. Returns the
	# next brand index so neighbouring runs keep rotating through the advertisers.
	var length: float = a.distance_to(b)
	var count: int = maxi(1, roundi(length / 2.6))
	var along: Vector3 = (b - a) / length
	var inward := Vector3(-along.z, 0, along.x)
	if inward.dot(-(a + b) * 0.5) < 0.0:
		inward = -inward
	var panel: float = length / count
	for i in range(count):
		var spec: Array = PITCH_ADVERTS[(brand + i) % PITCH_ADVERTS.size()]
		var at: Vector3 = a + along * ((i + 0.5) * panel) + Vector3(0, 0.27, 0)
		var size := Vector3(panel - 0.06, 0.42, 0.06) if absf(along.x) > 0.5 else Vector3(0.06, 0.42, panel - 0.06)
		_box(frame, at, size, Materials.solid(Color(spec[1]), 0.1, 0.5))
		for face: Vector3 in [inward, -inward]:
			var text := Props.label(root, spec[0], at + face * 0.032, panel - 0.4, 0.24, Color(spec[2]), "AdvertBoard")
			text.rotation.y = atan2(face.x, face.z)
			text.visibility_range_end = 75.0
	return brand + count

func _dugout(frame: Transform3D, at: Vector3, seat_color: Color) -> void:
	# Team shelter facing the pitch: a dark back panel, smoked side screens and a
	# roof curving down at the front on an aluminium frame, over five seats.
	var shell := Materials.solid(Color("2f3b45"), 0.3, 0.45)
	var aluminium := Materials.solid(Color("b4b9b6"), 0.7, 0.3)
	var smoked := _glazing(Color(0.55, 0.66, 0.72, 0.5))
	var seat := Materials.solid(seat_color, 0.0, 0.45)
	_box(frame, at + Vector3(0, 0.03, 0), Vector3(2.6, 0.06, 1.0), Materials.surface(2, Color("9c998c")))
	_box(frame, at + Vector3(0, 0.6, -0.46), Vector3(2.5, 1.1, 0.05), shell)
	for x in [-1.25, 1.25]:
		_box(frame, at + Vector3(x, 0.58, -0.04), Vector3(0.03, 1.04, 0.86), smoked)
		_beam(frame, at + Vector3(x, 0.0, 0.4), at + Vector3(x, 1.0, 0.4), 0.04, aluminium)
	_box(frame, at + Vector3(0, 1.17, -0.2), Vector3(2.56, 0.035, 0.6), smoked)
	_box(frame * Transform3D(Basis(Vector3.RIGHT, 0.5), at + Vector3(0, 1.08, 0.24)), Vector3.ZERO, Vector3(2.56, 0.035, 0.36), smoked)
	_box(frame, at + Vector3(0, 0.29, -0.2), Vector3(2.3, 0.06, 0.08), aluminium)
	for i in range(5):
		var x: float = -1.0 + i * 0.5
		_box(frame, at + Vector3(x, 0.35, -0.2), Vector3(0.36, 0.06, 0.32), seat)
		_box(frame, at + Vector3(x, 0.53, -0.36), Vector3(0.36, 0.3, 0.05), seat)

func _stand(frame: Transform3D, front: float, width: float, rows: int, ground_name: String, steel: Material) -> float:
	# Stepped concrete terraces with bucket seats in red, gold and green blocks and
	# stepped aisles between them, behind a low parapet. A cantilevered roof on
	# back columns, held by stays from short masts, carries the ground's name on
	# its fascia and a scoreboard; the name is painted on the back wall for the
	# street too. Returns the back of the roof.
	var concrete := Materials.surface(2, Color("a8a596"))
	var wall := Materials.surface(0, Color("cbc4b0"))
	var sheet := Materials.surface(4, Color("8e9aa0"))
	var green := Materials.solid(Color("1f6b45"), 0.15, 0.5)
	var tread: float = 0.55
	var riser: float = 0.32
	var base: float = 0.36
	var aisle: float = 0.7
	var block: float = (width - aisle * 2.0) / 3.0
	var seat_colors: Array[Color] = [Color("c0392b"), Color("e1ad2b"), Color("1f7a45")]
	var seats: int = maxi(3, floori(block / 0.46))
	var spacing: float = block / seats
	for r in range(rows):
		var top: float = base + r * riser
		var z: float = front + (r + 0.5) * tread
		_box(frame, Vector3(0, top * 0.5, z), Vector3(width, top, tread), concrete)
		for k in range(3):
			var x0: float = -width * 0.5 + k * (block + aisle)
			var seat := Materials.solid(seat_colors[k], 0.0, 0.5)
			for i in range(seats):
				var x: float = x0 + (i + 0.5) * spacing
				_box(frame, Vector3(x, top + 0.17, z - 0.04), Vector3(spacing * 0.78, 0.05, 0.3), seat)
				_box(frame, Vector3(x, top + 0.31, z + 0.12), Vector3(spacing * 0.78, 0.26, 0.05), seat)
		for k in range(2):
			var ax: float = -width * 0.5 + (k + 1) * block + (k + 0.5) * aisle
			_box(frame, Vector3(ax, top + riser * 0.25, z + tread * 0.25), Vector3(aisle - 0.06, riser * 0.5, tread * 0.5), concrete)
		for s in [-1.0, 1.0]:
			_box(frame, Vector3(s * (width * 0.5 + 0.1), (top + 0.5) * 0.5, z), Vector3(0.2, top + 0.5, tread), wall)
	var back: float = front + rows * tread
	var top_row: float = base + (rows - 1) * riser
	_box(frame, Vector3(0, 0.42, front - 0.07), Vector3(width + 0.4, 0.84, 0.14), wall)
	_box(frame, Vector3(0, 0.62, front - 0.145), Vector3(width + 0.4, 0.16, 0.012), green)
	var wall_h: float = top_row + 1.05
	_box(frame, Vector3(0, wall_h * 0.5, back + 0.1), Vector3(width + 0.4, wall_h, 0.2), wall, true)
	var roof_y: float = top_row + 1.75
	var roof_front: float = front - 0.75
	var roof_back: float = back + 0.45
	_box(frame, Vector3(0, roof_y, (roof_front + roof_back) * 0.5), Vector3(width + 0.8, 0.07, roof_back - roof_front), sheet)
	_box(frame, Vector3(0, roof_y - 0.13, roof_front - 0.03), Vector3(width + 0.8, 0.34, 0.06), green)
	for i in range(4):
		var x: float = lerpf(-width * 0.5 + 0.35, width * 0.5 - 0.35, i / 3.0)
		_beam(frame, Vector3(x, 0, back + 0.32), Vector3(x, roof_y + 0.7, back + 0.32), 0.16, steel)
		_box(frame, Vector3(x, roof_y - 0.12, (roof_front + roof_back) * 0.5), Vector3(0.1, 0.18, roof_back - roof_front), steel)
		_beam(frame, Vector3(x, roof_y + 0.68, back + 0.32), Vector3(x, roof_y + 0.05, roof_front + 0.2), 0.025, steel)
	var board_z: float = back - 0.25
	for x in [-1.0, 1.0]:
		_beam(frame, Vector3(x, roof_y, board_z), Vector3(x, roof_y + 0.6, board_z), 0.06, steel)
	_box(frame, Vector3(0, roof_y + 1.0, board_z), Vector3(2.8, 0.9, 0.14), Materials.solid(Color("15191b"), 0.3, 0.4))
	_box(frame, Vector3(0, wall_h * 0.55, back + 0.205), Vector3(width * 0.78, 0.95, 0.012), green)
	var letters := Node3D.new()
	letters.name = "StandLettering"
	letters.transform = frame
	add_child(letters)
	var fascia := Props.label(letters, ground_name, Vector3(0, roof_y - 0.13, roof_front - 0.065), width * 0.6, 0.24, Color("f4f1e6"), "StandName")
	fascia.rotation.y = PI
	var title := Props.label(letters, ground_name, Vector3(0, roof_y + 1.27, board_z - 0.075), 2.2, 0.17, Color("f4f1e6"), "ScoreboardTitle")
	var score := Props.label(letters, "HOME  2 - 1  AWAY", Vector3(0, roof_y + 0.93, board_z - 0.075), 2.4, 0.34, Color("ffb23a"), "Scoreboard")
	for lit in [title, score]:
		lit.rotation.y = PI
		lit.shaded = false
	Props.label(letters, ground_name, Vector3(0, wall_h * 0.55, back + 0.215), width * 0.7, 0.62, Color("f4f1e6"), "StandMural")
	return roof_back

func _floodlight(frame: Transform3D, base: Vector3, steel: Material, lamp: Material) -> Vector3:
	# Tapered mast on a plinth with a railed service platform and a bank of six
	# lamps turned to the centre spot and tilted down onto the pitch. Returns the
	# lamp bank's position in the ground's frame.
	var h: float = 8.6
	var toward := Vector3(-base.x, 0, -base.z).normalized()
	_box(frame, base + Vector3(0, 0.17, 0), Vector3(0.75, 0.34, 0.75), Materials.surface(2, Color("8f8c80")))
	_beam(frame, base + Vector3(0, 0.34, 0), base + Vector3(0, h, 0), 0.28, steel)
	var mount := frame * Transform3D(Basis(Vector3.UP, atan2(toward.x, toward.z)), base)
	_box(mount, Vector3(0, h - 0.45, 0.25), Vector3(1.5, 0.05, 0.9), steel)
	for x in [-0.73, 0.73]:
		_box(mount, Vector3(x, h - 0.2, 0.25), Vector3(0.03, 0.5, 0.9), steel)
	_beam(mount, Vector3(0, h - 0.4, 0), Vector3(0, h + 0.45, 0.35), 0.1, steel)
	var head := mount * Transform3D(Basis(Vector3.RIGHT, 0.45), Vector3(0, h + 0.45, 0.35))
	_box(head, Vector3(0, 0, -0.08), Vector3(1.75, 1.05, 0.08), steel)
	var housing := Materials.solid(Color("3a3f42"), 0.5, 0.4)
	for row in range(2):
		for col in range(3):
			var at := Vector3(-0.57 + col * 0.57, -0.25 + row * 0.5, 0.03)
			_box(head, at, Vector3(0.5, 0.42, 0.16), housing)
			_box(head, at + Vector3(0, 0, 0.085), Vector3(0.43, 0.35, 0.012), lamp)
	return base + Vector3(0, h + 0.3, 0) + toward * 0.9

func _ground_fence(frame: Transform3D, x_edge: float, z_near: float, z_far: float, stand_half: float, steel: Material) -> void:
	# Chain-link on galvanised posts round three sides, closing on the stand's
	# ends, with a double gate in the middle of the near side.
	var runs: Array = [
		[Vector3(-x_edge, 0, z_near), Vector3(-0.95, 0, z_near)],
		[Vector3(0.95, 0, z_near), Vector3(x_edge, 0, z_near)],
		[Vector3(-x_edge, 0, z_near), Vector3(-x_edge, 0, z_far)],
		[Vector3(x_edge, 0, z_near), Vector3(x_edge, 0, z_far)],
		[Vector3(-x_edge, 0, z_far), Vector3(-stand_half, 0, z_far)],
		[Vector3(stand_half, 0, z_far), Vector3(x_edge, 0, z_far)]]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var h: float = 1.45
	for pair: Array in runs:
		var a: Vector3 = pair[0]
		var b: Vector3 = pair[1]
		_net_quad(st, a + Vector3(0, 0.04, 0), a + Vector3(0, h, 0), b + Vector3(0, h, 0), b + Vector3(0, 0.04, 0), 0.07)
		_beam(frame, a + Vector3(0, h, 0), b + Vector3(0, h, 0), 0.042, steel)
		var posts: int = maxi(1, ceili(a.distance_to(b) / 2.6))
		for i in range(posts + 1):
			var p: Vector3 = a.lerp(b, float(i) / posts)
			_beam(frame, p, p + Vector3(0, h + 0.05, 0), 0.055, steel)
	for s in [-1.0, 1.0]:
		var hinge := Vector3(s * 0.95, 0, z_near)
		var tip := Vector3(s * 0.04, 0, z_near)
		_beam(frame, hinge, hinge + Vector3(0, h + 0.15, 0), 0.08, steel)
		_net_quad(st, hinge + Vector3(-s * 0.04, 0.08, 0), hinge + Vector3(-s * 0.04, h - 0.05, 0), tip + Vector3(0, h - 0.05, 0), tip + Vector3(0, 0.08, 0), 0.07)
		for y in [0.08, h - 0.05]:
			_beam(frame, hinge + Vector3(-s * 0.04, y, 0), tip + Vector3(0, y, 0), 0.035, steel)
		_beam(frame, tip + Vector3(0, 0.08, 0), tip + Vector3(0, h - 0.05, 0), 0.035, steel)
	var fence := MeshInstance3D.new()
	fence.mesh = st.commit()
	fence.material_override = _lattice_material(true, Color("a3aaad"))
	fence.transform = frame
	fence.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fence.name = "ChainLinkFence"
	add_child(fence)

func factory(center: Vector3, w: float, h: float, d: float) -> void:
	warehouse(center, w, h, d)
	land_uses[-1]["kind"] = "factory"
	var frame := _frame(center)
	var steel := Materials.surface(4, Color("74766d"))
	for x in [-w * 0.28, w * 0.28]:
		_beam(frame, Vector3(x, h, -d * 0.25), Vector3(x, h + 4.5, -d * 0.25), 0.42, steel)
		_beam(frame, Vector3(x, h + 3.9, -d * 0.25), Vector3(x, h + 4.25, -d * 0.25), 0.44, Materials.solid(Color("9a5842")))

func backdrop(corridor: bool) -> void:
	# A street grid and irregular plots replace the isolated ring of buildings.
	# Keep the entire simulation/district rectangle clear; distant detail is visual only.
	var midpoint: float = 30.0 if corridor else 0.0
	_building_backdrop = true
	var asphalt := Materials.surface(1, Color("55574e"))
	var soil := Materials.surface(3, Color.WHITE)
	for row in range(-7, 7):
		for col in range(-7, 7):
			var x: float = (col + 0.5) * 32.0
			var z: float = (row + 0.5) * 32.0
			if maxf(absf(x), absf(z)) < 100.0 or Vector2(x, z).length() > 270.0:
				continue
			if corridor:
				var airport_layout = preload("res://scripts/AirportLayout.gd")
				var block := Rect2(x - 17.5, z + midpoint - 17.5, 35, 35)
				if block.intersects(airport_layout.SITE) or block.intersects(airport_layout.ACCESS):
					continue
			var frame := _frame(Vector3(x, 0, z + midpoint))
			_box(frame, Vector3(0, -0.01, 0), Vector3(30.5, 0.04, 30.5), soil)
			_box(frame, Vector3(-16, 0.015, 0), Vector3(3, 0.06, 32), asphalt)
			_box(frame, Vector3(0, 0.015, -16), Vector3(32, 0.06, 3), asphalt)
			var plots: Array[Vector2] = [Vector2(-7, -7), Vector2(7, 7)]
			if _rng.randf() < 0.65:
				plots.append(Vector2(7, -7))
			if _rng.randf() < 0.45:
				plots.append(Vector2(-7, 7))
			for plot in plots:
				var at := Vector3(x + plot.x + _rng.randf_range(-0.7, 0.7), 0, z + midpoint + plot.y)
				_background_building(at, _rng.randi_range(0, 3) * PI * 0.5)
			# Plots without a building are gardens: a tree, so the grid reads as lived in.
			for spare in [Vector2(7, -7), Vector2(-7, 7)]:
				if spare not in plots:
					tree(Vector3(x + spare.x, 0, z + midpoint + spare.y), _rng.randf() < 0.3, 6, 9)
			if (row + col) % 4 == 0:
				tree(Vector3(x, 0, z + midpoint), (row + col) % 8 == 0)
	_building_backdrop = false

func _background_building(center: Vector3, rotation_y: float) -> void:
	_background_count += 1
	var frame := Transform3D(Basis(Vector3.UP, rotation_y), center)
	var w: float = _rng.randf_range(7.0, 11.5)
	var d: float = _rng.randf_range(6.0, 10.5)
	var floors: int = _rng.randi_range(1, 3)
	var h: float = floors * 2.5
	var plaster := Materials.surface(0, WALLS[_rng.randi_range(0, 3)])
	var trim := Materials.surface(0, Color("b9b09b"))
	var roof := Materials.surface(4, ROOFS[_rng.randi_range(0, ROOFS.size() - 1)])
	var glass := Materials.solid(Color("3e4b47"))
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), plaster)
	_box(frame, Vector3(0, 0.12, 0), Vector3(w + 0.2, 0.24, d + 0.2), trim)
	if _rng.randf() < 0.72:
		_batch(_roof_mesh, roof, frame * Transform3D(Basis.from_scale(Vector3(w + 0.5, 1.3, d + 0.5)), Vector3(0, h, 0)))
	else:
		_box(frame, Vector3(0, h + 0.14, 0), Vector3(w + 0.2, 0.28, d + 0.2), trim)
		_box(frame, Vector3(w * 0.2, h + 0.6, -d * 0.2), Vector3(1.1, 1, 1.1), roof)
	for side in range(4):
		var face := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
		var span: float = w if side % 2 == 0 else d
		var dep: float = d if side % 2 == 0 else w
		for floor_index in range(floors):
			for bay in range(3):
				_box(face, Vector3((bay - 1) * span * 0.28, 1.5 + floor_index * 2.5, dep * 0.5 + 0.02), Vector3(0.95, 1.1, 0.04), _warm if _rng.randf() < 0.12 else glass)
	# Short compound walls define plots without expensive distant collision bodies.
	_box(frame, Vector3(0, 0.48, -d * 0.5 - 0.7), Vector3(w + 1.4, 0.96, 0.14), plaster)
	_box(frame, Vector3(-w * 0.5 - 0.7, 0.48, 0), Vector3(0.14, 0.96, d + 1.4), plaster)
