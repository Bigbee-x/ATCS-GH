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
const FleetActor = preload("res://scripts/VehicleActor.gd")

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

func compound(center: Vector3, size: float, floors: int) -> void:
	var frame := _frame(center)
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
	building(center + Vector3(-0.5, 0, -0.7), Vector3.BACK, size * 0.57, size * 0.5, floors)
	# Validate the enclosing residential plot, not just the house inside its walls.
	land_uses[-1].merge({"center": center, "width": size, "depth": size, "compound": true}, true)
	tree(center + Vector3(half - 1.2, 0, -half + 1.2), true)

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

func tree(center: Vector3, palm: bool = false) -> void:
	_tree_count += 1
	var frame := _frame(center, Vector3(sin(_tree_count * 2.4), 0, cos(_tree_count * 2.4)))
	var bark := Materials.surface(6, Color("62523a"))
	var h: float = _rng.randf_range(3.3, 5.6)
	if palm:
		_palm(frame, h + 0.8, bark)
		return
	var lean := Vector3(_rng.randf_range(-0.35, 0.35), 0, _rng.randf_range(-0.3, 0.3))
	_beam(frame, Vector3.ZERO, lean + Vector3(0, h * 0.7, 0), 0.26, bark)
	for branch in range(9):
		var angle: float = branch * TAU / 9.0 + _rng.randf_range(-0.2, 0.2)
		var radius: float = _rng.randf_range(1.0, 1.85)
		var tip := Vector3(cos(angle) * radius, h * _rng.randf_range(0.72, 1.12), sin(angle) * radius) + lean
		var joint := lean + Vector3(0, h * _rng.randf_range(0.44, 0.67), 0)
		_beam(frame, joint, tip, 0.10, bark)
		for cluster in range(14):
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
