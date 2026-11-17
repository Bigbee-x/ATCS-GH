extends Node3D
## Architectural kit for both SUMO scenes. Front faces local +Z.
## Small repeated details are batched by material and 24-unit spatial cell.
## Only building envelopes and boundary walls get physics shapes.
##
## The look is roadside Accra: painted sandcrete over a darker dado, storey
## buildings with shops under a verandah, long-span aluminium roofs in oxide
## red, blue and green, flat slabs left with starter bars for the next floor,
## black polytanks, lock-up stores with steel doors and hand-painted signboards.

const Props = preload("res://scripts/PropGeometry.gd")
const Materials = preload("res://scripts/StreetscapeMaterials.gd")
# Emulsion colours seen on Accra walls; the first four also dress the backdrop.
const WALLS: Array[Color] = [
	Color("ead9ae"), Color("f0e6cf"), Color("e7b98c"), Color("e6cf7c"),
	Color("a9cbdc"), Color("b5d6b4"), Color("dfa58c"), Color("c9c3b4"),
	Color("e9c9a0"), Color("d8b25e"), Color("9cc2c0"), Color("efe3c0")]
# Oil-paint dado below the emulsion: it hides the laterite splash-back.
const DADOS: Array[Color] = [Color("7b3328"), Color("2f4f77"), Color("2f6b4a"),
	Color("6b4a33"), Color("8a6a2a"), Color("55585a")]
# Long-span aluminium sheets and weathered zinc.
const ROOFS: Array[Color] = [Color("8d3b2f"), Color("2f5f93"), Color("2e7352"), Color("a3a8a6"),
	Color("8a5b3e"), Color("b3b6b1"), Color("70392c"), Color("3d6d8a")]
const DOORS: Array[Color] = [Color("2f5f93"), Color("2e7352"), Color("6b3a2a"),
	Color("7d8384"), Color("1f3f66"), Color("8d3b2f")]
# Illustrative shop names in the style of Accra signboards: a name, then a trade.
const SHOP_NAMES: Array[String] = [
	"GOD IS GOOD\nEnterprise", "NYAME ADOM\nCold Store", "BLESSED HANDS\nBeauty Salon",
	"BY HIS GRACE\nPhones & Accessories", "AKWAABA\nProvisions", "SHALOM\nChemical Shop",
	"KOFI'S\nBarbering Shop", "ABENA\nFabrics & Lace", "NEOPLAN\nSpare Parts",
	"MAMA ESI\nChop Bar", "ONYAME NNAE\nElectricals", "GYE NYAME\nHardware",
	"STILL BELIEVE\nFashion Home", "AUNTIE AKOS\nWaakye & Kenkey", "NO WEAPON\nAluminium Works",
	"PSALM 23\nMobile Money", "EL-SHADDAI\nVentures", "CLAP FOR JESUS\nTailoring",
	"OBAATANPA\nDrinking Spot", "DE-LORD\nBlock Factory", "ANOINTED\nMotors",
	"PEACE & LOVE\nCosmetics", "ASEDA\nBoutique", "MERCY'S\nCheck-Check & Fried Rice",
	"THANK YOU JESUS\nPlumbing Materials", "ADOM WO WIM\nRice & Oil Depot",
	"SIKA MPE DEDE\nFurniture Works", "EBENEZER\nPrinting Press"]
const SHOP_COLORS: Array[Color] = [Color("c62f25"), Color("f2c318"), Color("1c63a8"), Color("1c7a45"),
	Color("f08a1c"), Color("f4f1e6"), Color("7a1f5c"), Color("16181a")]
const CLOTH: Array[Color] = [Color("d43a2c"), Color("f2c318"), Color("1c63a8"), Color("2a9a55"),
	Color("f08a1c"), Color("f4f1e6"), Color("8a2f7c"), Color("27b0c0"), Color("e85f8a")]
const STORY := 3.0
const DETAIL_RANGE := 140.0
# Filling stations carry the project's own fuel brand, "Sankofa", in the sim's teal and amber.
const FUEL_TEAL := Color("1f5a55")
const FUEL_AMBER := Color("e9a93a")
const FleetActor = preload("res://scripts/VehicleActor.gd")
# Pitchside advertisers are the sim's own businesses: [name, board colour, lettering].
const PITCH_ADVERTS: Array = [
	["SANKOFA FUEL", "1f5a55", "f4f1e6"], ["VALIBORN TECHNOLOGIES", "1d2b3a", "f4f1e6"],
	["AKWAABA PROVISIONS", "2c5853", "e9dfc5"], ["BUILD BEYOND", "e9a93a", "1d2b3a"],
	["ADOM PHARMACY", "345e41", "f4f1e6"], ["MAMA ESI CHOP BAR", "825a39", "f4e9d2"],
	["GRACE COLD STORE", "514233", "e9dfc5"]]

var _rng := RandomNumberGenerator.new()
var _batches: Dictionary = {}
var _box_mesh := BoxMesh.new()
var _cylinder_mesh := CylinderMesh.new()
var _tube_mesh := CylinderMesh.new()
var _cone_mesh := CylinderMesh.new()
var _sphere_mesh := SphereMesh.new()
var _leaf_mesh: ArrayMesh
var _roof_mesh: ArrayMesh
var _gable_mesh: ArrayMesh
var _palm_crowns: Array[Mesh] = []
var _warm: Material
var _cool: Material
var _building_count: int = 0
var _tree_count: int = 0
var _sign_count: int = 0
var _background_count: int = 0
var _building_backdrop: bool = false
# Fine trim goes in its own batches: no shadows, and hidden beyond DETAIL_RANGE.
var _detail: bool = false
# Well-kept, paved districts: surfaces batched inside these rectangles carry a
# low instance alpha, which the surface shader reads as less dirt and rust.
var clean_rects: Array[Rect2] = []
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
		"kiosk": ["MOMO & AIRTIME", "AMA'S PROVISIONS", "UNITY PHONE REPAIRS", "ABENA'S COLD DRINKS",
			"PURE WATER DEPOT", "LOTTO KIOSK"],
		"mechanic": ["GOD FIRST FITTING SHOP", "KOFI'S AUTO WORKS", "ABOSSEY SPARE PARTS & SPRAYING"],
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
	_tube_mesh.top_radius = 0.5
	_tube_mesh.bottom_radius = 0.5
	_tube_mesh.height = 1.0
	_tube_mesh.radial_segments = 14
	_tube_mesh.rings = 1
	_cone_mesh.top_radius = 0.0
	_cone_mesh.bottom_radius = 0.5
	_cone_mesh.height = 1.0
	_cone_mesh.radial_segments = 8
	_cone_mesh.rings = 1
	_sphere_mesh.radius = 0.5
	_sphere_mesh.height = 1.0
	_sphere_mesh.radial_segments = 10
	_sphere_mesh.rings = 6
	_leaf_mesh = _make_leaf_cluster()
	_roof_mesh = _make_hip_roof()
	_gable_mesh = _make_gable_roof()
	for variant in range(3):
		_palm_crowns.append(_make_palm_crown(variant))

func _frame(center: Vector3, facing: Vector3 = Vector3.BACK) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, atan2(facing.x, facing.z)), center)

func _batch(mesh: Mesh, material: Material, transform: Transform3D, shade: Color = Color.WHITE) -> void:
	if material.has_meta("shared"):
		# Paint rides on the instance so every colour of a finish shares a batch.
		shade = material.get_meta("paint")
		material = material.get_meta("shared")
		for zone in clean_rects:
			if zone.has_point(Vector2(transform.origin.x, transform.origin.z)):
				shade.a = 0.25
	var cell_size: float = 64.0 if _building_backdrop else 24.0
	var cell := Vector2i(floori(transform.origin.x / cell_size), floori(transform.origin.z / cell_size))
	var key := "%d:%d:%d:%d:%s:%s" % [mesh.get_instance_id(), material.get_instance_id(), cell.x, cell.y, _building_backdrop, _detail]
	if not _batches.has(key):
		_batches[key] = {"mesh": mesh, "material": material, "transforms": [], "colors": [],
			"background": _building_backdrop, "detail": _detail}
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

## Upright straight-sided drum: tanks, tyres, basins, oil drums and gas bottles.
func _drum(frame: Transform3D, at: Vector3, diameter: float, height: float, material: Material) -> void:
	_batch(_tube_mesh, material, frame * Transform3D(Basis.from_scale(Vector3(diameter, height, diameter)), at + Vector3(0, height * 0.5, 0)))

func _ball(frame: Transform3D, at: Vector3, size: Vector3, material: Material) -> void:
	_batch(_sphere_mesh, material, frame * Transform3D(Basis.from_scale(size), at))

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
		if batch["detail"]:
			instance.name = "StreetscapeDetail"
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			instance.visibility_range_end = DETAIL_RANGE
			instance.visibility_range_end_margin = 12.0
		add_child(instance)
	_batches.clear()
	print("[Streetscape] %d detailed buildings, %d background buildings, %d trees; spatially batched geometry" % [_building_count, _background_count, _tree_count])

## Shop-below, rooms-above storey building, a single-storey line of lock-up
## stores, or a plain house, depending on `floors` and `shop`. Institutional
## blocks take the yellow-and-brown of public schools and clinics.
func building(center: Vector3, facing: Vector3, width: float, depth: float,
		floors: int, shop: bool = false, institutional: bool = false,
		institution_name: String = "COMMUNITY\nLEARNING CENTRE") -> void:
	_building_count += 1
	_record_use("civic" if institutional else ("shop" if shop else "house"), center, facing, width, depth, floors)
	var frame := _frame(center, facing)
	var h: float = floors * STORY
	var paint: Color = WALLS[_rng.randi_range(0, WALLS.size() - 1)]
	var dado: Color = DADOS[_rng.randi_range(0, DADOS.size() - 1)]
	var two_tone: bool = _rng.randf() < 0.62
	if institutional:
		paint = Color("e3c067")
		dado = Color("6d4127")
		two_tone = true
	var plaster := Materials.surface(0, paint)
	var trim := Materials.surface(0, paint.lerp(Color("f6f1e4"), 0.62))
	var band := Materials.surface(0, dado)
	var concrete := Materials.surface(2, Color("8f8a7e"))
	var front: float = depth * 0.5
	var veranda: float = 1.25 if width >= 4.0 and (floors > 1 or shop or institutional) else 0.0
	var bays: int = maxi(1, roundi(width / 3.3))
	var bay_w: float = width / bays
	# Screeded apron, the painted block and its oil-paint dado.
	_box(frame, Vector3(0, 0.04, 0.3), Vector3(width + 0.65, 0.16, depth + 1.3), Materials.surface(2, Color("9c978b")))
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(width, h, depth), plaster, true)
	if two_tone:
		_box(frame, Vector3(0, 0.55, 0), Vector3(width + 0.05, 1.1, depth + 0.05), band)
	for floor_index in range(1, floors):
		_box(frame, Vector3(0, floor_index * STORY - 0.09, 0), Vector3(width + 0.12, 0.18, depth + 0.12), trim)
	for floor_index in range(floors):
		var y: float = floor_index * STORY
		for side in range(4):
			if side == 0 and floor_index == 0 and shop:
				continue
			var facade := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
			var span: float = width if side % 2 == 0 else depth
			var reach: float = depth if side % 2 == 0 else width
			var count: int = maxi(1, floori(span / (2.2 if side == 0 else 2.9)))
			for k in range(count):
				var x: float = -span * 0.5 + (k + 0.5) * span / count
				if side == 0 and k == count / 2 and (floor_index == 0 or veranda > 0.0):
					if floor_index > 0:
						_door(facade, Vector3(x, y + 1.05, reach * 0.5 + 0.03), 0.9, 2.05)
					continue
				_window(facade, Vector3(x, y + 1.62, reach * 0.5 + 0.025), minf(1.45, span / count * 0.6), 1.3,
					floor_index == 0 and side == 0, trim, side != 0)
	if shop:
		_shop_front(frame, width, depth, paint, veranda, floors)
	else:
		_door(frame, Vector3(0.0, 1.05, front + 0.04), 0.95, 2.05)
		_box(frame, Vector3(0.0, 0.13, front + 0.4), Vector3(1.6, 0.26, 0.8), concrete)
		if veranda <= 0.0 or floors == 1:
			_box(frame, Vector3(0.0, 2.45, front + 0.45), Vector3(1.9, 0.1, 0.95), trim)
	if veranda > 0.0 and floors > 1:
		_verandah(frame, width, front, veranda, floors, bays, band if two_tone else trim, trim, concrete, shop)
	# Long-span sheets over most single-storey rows; taller blocks are as often a
	# flat slab waiting for its next floor.
	var roll: float = _rng.randf()
	var cover: float = depth + veranda * (1.0 if floors > 1 else 0.0)
	var shift: float = veranda * (0.5 if floors > 1 else 0.0)
	if institutional or (floors == 1 and roll < 0.85) or (floors > 1 and roll < 0.6):
		_hip_roof(frame, width + 0.75, cover + 0.75, h + 0.02, clampf(minf(width, cover) * 0.2, 0.8, 2.4),
			roll < 0.32 and width > cover, shift)
	else:
		_slab_roof(frame, width, cover, h, shift, bays, plaster, concrete, floors > 1 and _rng.randf() < 0.5)
	# Split-unit condensers on a side wall and a downpipe at the front corner.
	_detail = true
	_beam(frame, Vector3(width * 0.5 + 0.06, 0.2, front - 0.15), Vector3(width * 0.5 + 0.06, h, front - 0.15), 0.09, Materials.solid(Color("3a3d3a"), 0.45))
	_detail = false
	if floors > 1:
		var flank := frame * Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3.ZERO)
		for unit in range(mini(floors - 1, 2)):
			_air_conditioner(flank, Vector3(depth * 0.22, STORY * (unit + 1) + 0.55, width * 0.5 + 0.2))
	if institutional:
		_sign(frame, institution_name, Vector3(0, STORY - 0.5 if floors > 1 else h - 0.45, front + (veranda if floors > 1 else 0.0) + 0.09),
			minf(width - 0.6, 7.0), 0.8, Color("f4f1e6"))

## Upper-floor access balconies on posts: the shaded arcade over the shops.
func _verandah(frame: Transform3D, width: float, front: float, reach: float, floors: int, bays: int,
		rail: Material, trim: Material, concrete: Material, shop: bool) -> void:
	var h: float = floors * STORY
	var edge: float = front + reach
	var solid_rail: bool = _rng.randf() < 0.55
	for floor_index in range(1, floors):
		var y: float = floor_index * STORY
		_box(frame, Vector3(0, y - 0.08, front + reach * 0.5), Vector3(width, 0.16, reach), concrete)
		if solid_rail:
			_box(frame, Vector3(0, y + 0.47, edge - 0.06), Vector3(width, 0.94, 0.12), rail)
			_box(frame, Vector3(0, y + 0.97, edge - 0.06), Vector3(width + 0.06, 0.06, 0.2), trim)
		else:
			_detail = true
			var steel := Materials.solid(Color("2c3033"), 0.6)
			for rail_y in [0.12, 0.52, 0.95]:
				_box(frame, Vector3(0, y + rail_y, edge - 0.05), Vector3(width, 0.045, 0.045), steel)
			var posts: int = maxi(4, ceili(width / 0.6))
			for i in range(posts + 1):
				_box(frame, Vector3(-width * 0.5 + width * i / posts, y + 0.52, edge - 0.05), Vector3(0.03, 0.88, 0.03), steel)
			_detail = false
	_box(frame, Vector3(0, h - 0.08, front + reach * 0.5), Vector3(width, 0.16, reach), concrete)
	var bay_w: float = width / bays
	for i in range(bays + 1):
		var x: float = clampf(-width * 0.5 + i * bay_w, -width * 0.5 + 0.11, width * 0.5 - 0.11)
		_box(frame, Vector3(x, h * 0.5, edge - 0.11), Vector3(0.22, h, 0.22), trim)
	if not shop and _rng.randf() < 0.45:
		# Washing on the top balcony.
		_detail = true
		var y: float = (floors - 1) * STORY
		var start: float = -width * 0.5 + 0.5
		var items: int = mini(8, floori((width - 1.0) / 0.55))
		for i in range(items):
			var cloth: Color = CLOTH[_rng.randi_range(0, CLOTH.size() - 1)]
			var drop: float = _rng.randf_range(0.45, 0.85)
			_box(frame, Vector3(start + i * 0.55, y + 1.95 - drop * 0.5, edge - 0.3), Vector3(0.42, drop, 0.02), Materials.solid(cloth, 0.0, 0.9))
		_detail = false
	elif shop and _rng.randf() < 0.5:
		_banner(frame, Vector3(_rng.randf_range(-0.2, 0.2) * width, STORY * (floors - 1) + 0.5, edge + 0.02), minf(width * 0.5, 3.6))

func _banner(frame: Transform3D, at: Vector3, w: float) -> void:
	var texts: Array[String] = ["ROOMS TO LET", "COMPUTER TRAINING", "SHOP FOR RENT", "REMEDIAL CLASSES",
		"HAIR BRAIDING HERE", "FORMS ON SALE", "DSTV & GOTV AGENT", "ADMISSION IN PROGRESS"]
	var color: Color = SHOP_COLORS[_rng.randi_range(0, 5)]
	_box(frame, at, Vector3(w, 0.62, 0.02), Materials.solid(color, 0.0, 0.85))
	var ink := Color("f6f2e6") if color.get_luminance() < 0.45 else Color("a31d16")
	var label := Props.label(self, texts[_sign_count % texts.size()], Vector3.ZERO, w - 0.25, 0.4, ink, "Banner")
	label.transform = frame * Transform3D(Basis.IDENTITY, at + Vector3(0, 0, 0.016))
	label.visibility_range_end = 60.0

## Flat concrete roof with a parapet, the polytank and, when `unfinished`, the
## column starter bars left standing for a floor that has not been built yet.
func _slab_roof(frame: Transform3D, w: float, d: float, h: float, shift: float, bays: int,
		plaster: Material, concrete: Material, unfinished: bool) -> void:
	_box(frame, Vector3(0, h + 0.06, shift), Vector3(w + 0.3, 0.14, d + 0.3), concrete)
	for z in [-d * 0.5, d * 0.5]:
		_box(frame, Vector3(0, h + 0.36, shift + z), Vector3(w + 0.16, 0.5, 0.15), plaster)
	for x in [-w * 0.5, w * 0.5]:
		_box(frame, Vector3(x, h + 0.36, shift), Vector3(0.15, 0.5, d), plaster)
	if unfinished:
		var rust := Materials.solid(Color("5e3524"), 0.3, 0.8)
		for i in range(bays + 1):
			var x: float = clampf(-w * 0.5 + i * w / bays, -w * 0.5 + 0.14, w * 0.5 - 0.14)
			for z in [-d * 0.5 + 0.14, d * 0.5 - 0.14]:
				_box(frame, Vector3(x, h + 0.5, shift + z), Vector3(0.25, 0.8, 0.25), concrete)
				_detail = true
				for corner in range(4):
					var bar := Vector3(x + (0.08 if corner % 2 == 0 else -0.08), 0, shift + z + (0.08 if corner < 2 else -0.08))
					_beam(frame, bar + Vector3(0, h + 0.9, 0), bar + Vector3(_rng.randf_range(-0.05, 0.05), h + _rng.randf_range(1.55, 1.9), 0), 0.03, rust)
				_detail = false
	_water_tank(frame, Vector3(-w * 0.24, h + 0.13, shift - d * 0.2))
	if _rng.randf() < 0.55:
		# Satellite dish on a short mast, facing a little west of south.
		var grey := Materials.solid(Color("b9bbb6"), 0.3, 0.5)
		var at := Vector3(w * 0.3, h + 0.13, shift + d * 0.18)
		_beam(frame, at, at + Vector3(0, 0.75, 0), 0.06, grey)
		_batch(_sphere_mesh, grey, frame * Transform3D(Basis.from_euler(Vector3(-0.75, 0.6, 0)) * Basis.from_scale(Vector3(0.85, 0.85, 0.12)), at + Vector3(0, 0.95, 0)))

## Aluminium sliding window: the frame and pane carry at any distance; the
## mullion, sill and burglar-proof bars are close-range trim.
func _window(frame: Transform3D, at: Vector3, w: float, h: float, bars: bool, trim: Material, plain: bool = false) -> void:
	var pane: Material = _warm if _rng.randf() < 0.3 else Materials.solid(Color("2c4753"), 0.35, 0.2)
	_box(frame, at, Vector3(w + 0.12, h + 0.12, 0.06), Materials.solid(Color("585f60"), 0.55, 0.4))
	_box(frame, at + Vector3(0, 0, 0.034), Vector3(w, h, 0.02), pane)
	if plain:
		return
	_detail = true
	_box(frame, at + Vector3(0, 0, 0.05), Vector3(0.05, h, 0.03), Materials.solid(Color("8a9090"), 0.6, 0.35))
	_box(frame, at + Vector3(0, -h * 0.5 - 0.08, 0.07), Vector3(w + 0.3, 0.08, 0.2), trim)
	if bars:
		var steel := Materials.solid(Color("23262a"), 0.5)
		for i in range(4):
			_box(frame, at + Vector3((i - 1.5) * w * 0.25, 0, 0.11), Vector3(0.022, h, 0.022), steel)
		for y in [-h * 0.25, h * 0.25]:
			_box(frame, at + Vector3(0, y, 0.11), Vector3(w, 0.022, 0.022), steel)
	_detail = false

func _door(frame: Transform3D, at: Vector3, w: float, h: float) -> void:
	_box(frame, at, Vector3(w + 0.14, h + 0.12, 0.08), Materials.solid(Color("363630")))
	var wood := Materials.surface(6, Color("6a4a30"))
	_box(frame, at + Vector3(0, 0, 0.05), Vector3(w, h, 0.035), wood)
	_detail = true
	for y in [-h * 0.24, h * 0.24]:
		_box(frame, at + Vector3(0, y, 0.075), Vector3(w * 0.74, h * 0.37, 0.025), Materials.surface(6, Color("7c5a3b")))
	_box(frame, at + Vector3(w * 0.33, 0, 0.12), Vector3(0.045, 0.18, 0.05), Materials.solid(Color("b0a080"), 0.8))
	_detail = false

## Lock-up stores: one steel double door per bay, most of them open on to a
## stocked interior, stock spilling on to the apron, and a signboard each.
func _shop_front(frame: Transform3D, w: float, d: float, paint: Color, veranda: float, floors: int) -> void:
	var z: float = d * 0.5
	var count: int = maxi(1, roundi(w / 3.3))
	var bay: float = w / count
	var open_h: float = 2.4
	var canopy_y: float = STORY - 0.2
	for i in range(count):
		var x: float = -w * 0.5 + (i + 0.5) * bay
		var door_w: float = minf(bay * 0.48, 1.9)
		var metal := Materials.surface(4, DOORS[_rng.randi_range(0, DOORS.size() - 1)])
		if _rng.randf() < 0.72:
			_box(frame, Vector3(x, open_h * 0.5, z + 0.02), Vector3(door_w, open_h, 0.06), Materials.solid(Color("15120f")))
			for leaf in [-1.0, 1.0]:
				_box(frame, Vector3(x + leaf * door_w * 0.76, open_h * 0.5, z + 0.05), Vector3(door_w * 0.5 - 0.04, open_h, 0.05), metal)
			_detail = true
			# Stocked shelves just inside the opening.
			for shelf in range(3):
				for item in range(4):
					var stock: Color = CLOTH[_rng.randi_range(0, CLOTH.size() - 1)]
					_box(frame, Vector3(x - door_w * 0.36 + item * door_w * 0.24, 0.7 + shelf * 0.55, z + 0.06),
						Vector3(door_w * 0.2, 0.36, 0.05), Materials.solid(stock, 0.0, 0.8))
			_detail = false
			_box(frame, Vector3(x, open_h + 0.12, z + 0.09), Vector3(door_w * 0.7, 0.07, 0.07), _cool)
			_shop_goods(frame, Vector3(x + _rng.randf_range(-0.3, 0.3), 0.12, z + 0.6), _rng.randi_range(0, 9))
		else:
			_box(frame, Vector3(x, open_h * 0.5, z + 0.04), Vector3(door_w, open_h, 0.07), metal)
			_detail = true
			_box(frame, Vector3(x, open_h * 0.5, z + 0.08), Vector3(0.03, open_h, 0.02), Materials.solid(Color("1b1c1c")))
			_box(frame, Vector3(x + 0.08, 1.05, z + 0.1), Vector3(0.09, 0.12, 0.04), Materials.solid(Color("b9a14a"), 0.8, 0.4))
			_detail = false
		var sign_id: int = _sign_count % SHOP_NAMES.size()
		var board: Color = SHOP_COLORS[(_sign_count * 3 + i) % SHOP_COLORS.size()]
		var sign_w: float = minf(bay - 0.3, 3.6)
		if floors > 1 and veranda > 0.0:
			_sign(frame, SHOP_NAMES[sign_id], Vector3(x, STORY + 0.44, z + veranda + 0.06), sign_w, 0.8, board)
		else:
			_sign(frame, SHOP_NAMES[sign_id], Vector3(x, canopy_y + 0.52, z + veranda + 0.02), sign_w, 0.85, board)
		_sign_count += 1
	if floors == 1 or veranda <= 0.0:
		# Flat concrete canopy over the shop doors, on slim pipe posts.
		var reach: float = maxf(veranda, 0.9)
		_box(frame, Vector3(0, canopy_y, z + reach * 0.5), Vector3(w + 0.2, 0.12, reach), Materials.surface(2, Color("a6a196")))
		_box(frame, Vector3(0, canopy_y - 0.12, z + reach - 0.04), Vector3(w + 0.2, 0.2, 0.08), Materials.surface(0, paint.darkened(0.25)))
		var steel := Materials.solid(Color("4a4f50"), 0.5)
		for k in range(count + 1):
			var x: float = clampf(-w * 0.5 + k * bay, -w * 0.5 + 0.08, w * 0.5 - 0.08)
			_beam(frame, Vector3(x, 0.1, z + reach - 0.1), Vector3(x, canopy_y, z + reach - 0.1), 0.075, steel)

## Stock set out on the apron in front of an open store.
func _shop_goods(frame: Transform3D, at: Vector3, kind: int) -> void:
	_detail = true
	match kind:
		0:  # Soft-drink crates.
			for i in range(4):
				_box(frame, at + Vector3((i % 2) * 0.46 - 0.23, 0.15 + (i / 2) * 0.31, 0), Vector3(0.42, 0.29, 0.32),
					Materials.solid([Color("c62f25"), Color("f2c318"), Color("1c63a8")][i % 3], 0.0, 0.6))
		1:  # Nested plastic basins and buckets.
			for i in range(3):
				_drum(frame, at + Vector3(i * 0.55 - 0.5, 0, 0), 0.5 - i * 0.03, 0.32 + i * 0.08,
					Materials.solid([Color("1c63a8"), Color("2a9a55"), Color("d43a2c")][i], 0.0, 0.45))
		2:  # Rice and maize sacks.
			for i in range(5):
				_box(frame, at + Vector3((i % 2) * 0.62 - 0.31, 0.11 + (i / 2) * 0.22, 0), Vector3(0.58, 0.2, 0.4),
					Materials.solid(Color("e9e2cf") if i % 3 else Color("d8c79c"), 0.0, 0.9))
		3:  # LPG cylinders.
			for i in range(4):
				var gas := Materials.solid([Color("2f5f93"), Color("b9bbb6"), Color("f2c318"), Color("c62f25")][i], 0.3, 0.5)
				_drum(frame, at + Vector3(i * 0.36 - 0.54, 0, 0), 0.3, 0.55, gas)
				_ball(frame, at + Vector3(i * 0.36 - 0.54, 0.55, 0), Vector3(0.3, 0.22, 0.3), gas)
		4:  # Foam mattresses leaning on the wall.
			for i in range(4):
				_box(frame, at + Vector3(0, 0.95, -0.42 + i * 0.16), Vector3(1.0, 1.9, 0.14),
					Materials.solid(CLOTH[(i * 2 + _sign_count) % CLOTH.size()], 0.0, 0.95))
		5:  # Stacked plastic chairs.
			for i in range(2):
				var chair := Materials.solid(Color("f4f1e6") if i == 0 else Color("1c63a8"), 0.0, 0.5)
				_box(frame, at + Vector3(i * 0.6 - 0.3, 0.3, 0), Vector3(0.46, 0.6, 0.46), chair)
				_box(frame, at + Vector3(i * 0.6 - 0.3, 0.8, -0.2), Vector3(0.46, 0.5, 0.06), chair)
		6:  # Provisions table: tins, tomato paste and milk.
			_box(frame, at + Vector3(0, 0.7, 0), Vector3(1.3, 0.06, 0.6), Materials.surface(6, Color("7c6746")))
			for leg in [-0.58, 0.58]:
				_box(frame, at + Vector3(leg, 0.35, 0), Vector3(0.06, 0.7, 0.5), Materials.surface(6, Color("6a5638")))
			for i in range(6):
				_drum(frame, at + Vector3(i * 0.2 - 0.5, 0.73, _rng.randf_range(-0.15, 0.15)), 0.14, 0.2,
					Materials.solid(CLOTH[i % CLOTH.size()], 0.2, 0.5))
		7:  # Used tyres.
			for i in range(5):
				_drum(frame, at + Vector3((i / 3) * 0.72 - 0.3, (i % 3) * 0.2, 0), 0.66, 0.19, Materials.solid(Color("161616"), 0.0, 0.9))
		8:  # Bags of sachet water.
			for i in range(6):
				_box(frame, at + Vector3((i % 2) * 0.5 - 0.25, 0.1 + (i / 2) * 0.19, 0), Vector3(0.46, 0.17, 0.36),
					Materials.solid(Color("bcd9e6"), 0.0, 0.35))
		_:  # Paint tins and buckets.
			for i in range(5):
				_drum(frame, at + Vector3((i % 3) * 0.34 - 0.34, (i / 3) * 0.33, 0), 0.3, 0.32,
					Materials.solid([Color("f4f1e6"), Color("2f5f93"), Color("e6cf7c")][i % 3], 0.1, 0.5))
	_detail = false

## Painted sheet-metal signboard: bold ground, contrasting letters, a rule below.
func _sign(frame: Transform3D, text: String, at: Vector3, w: float, h: float, color: Color) -> void:
	_box(frame, at, Vector3(w, h, 0.06), Materials.solid(Color("2b2b28"), 0.3, 0.6))
	_box(frame, at + Vector3(0, 0, 0.034), Vector3(w - 0.07, h - 0.07, 0.012), Materials.solid(color, 0.0, 0.65))
	var light: bool = color.get_luminance() > 0.45
	var ink: Color = [Color("a31d16"), Color("123a73"), Color("16181a")][_sign_count % 3] if light else \
		[Color("f6f2e6"), Color("f7d21e"), Color("f6f2e6")][_sign_count % 3]
	_detail = true
	_box(frame, at + Vector3(0, -h * 0.5 + 0.09, 0.042), Vector3(w - 0.2, 0.035, 0.008), Materials.solid(ink, 0.0, 0.7))
	_detail = false
	var label := Props.label(self, text, Vector3.ZERO, w - 0.28, h - 0.24, ink, "ShopName")
	label.transform = frame * Transform3D(Basis.IDENTITY, at + Vector3(0, 0.03, 0.044))
	label.visibility_range_end = 70.0

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

func _make_gable_roof() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var a := Vector3(-0.5, 0, -0.5)
	var b := Vector3(0.5, 0, -0.5)
	var c := Vector3(0.5, 0, 0.5)
	var e := Vector3(-0.5, 0, 0.5)
	var ridge_a := Vector3(-0.5, 1, 0)
	var ridge_b := Vector3(0.5, 1, 0)
	_triangle(st, a, ridge_a, ridge_b)
	_triangle(st, a, ridge_b, b)
	_triangle(st, b, ridge_b, c)
	_triangle(st, c, ridge_b, ridge_a)
	_triangle(st, c, ridge_a, e)
	_triangle(st, e, ridge_a, a)
	return st.commit()

## Long-span sheet roof with white fascia boards: hipped, or gabled when asked.
func _hip_roof(frame: Transform3D, w: float, d: float, y: float, rise: float, gable: bool = false, shift: float = 0.0) -> void:
	var material := Materials.surface(4, ROOFS[_rng.randi_range(0, ROOFS.size() - 1)])
	_batch(_gable_mesh if gable else _roof_mesh, material, frame * Transform3D(Basis.from_scale(Vector3(w, rise, d)), Vector3(0, y, shift)))
	var half: float = w * (0.5 if gable else 0.27)
	_beam(frame, Vector3(-half, y + rise, shift), Vector3(half, y + rise, shift), 0.14, material)
	var fascia := Materials.solid(Color("ece7da"), 0.0, 0.7)
	for z in [-d * 0.5, d * 0.5]:
		_box(frame, Vector3(0, y - 0.07, shift + z), Vector3(w, 0.18, 0.06), fascia)
	for x in [-w * 0.5, w * 0.5]:
		_box(frame, Vector3(x, y - 0.07, shift), Vector3(0.06, 0.18, d), fascia)

## Black ribbed polytank on a low block base.
func _water_tank(frame: Transform3D, at: Vector3, size: float = 1.0) -> void:
	var plastic := Materials.solid(Color("15181a"), 0.0, 0.42)
	_box(frame, at + Vector3(0, 0.1, 0), Vector3(1.5, 0.2, 1.5) * size, Materials.surface(2, Color("77756b")))
	_drum(frame, at + Vector3(0, 0.2 * size, 0), 1.35 * size, 1.45 * size, plastic)
	_ball(frame, at + Vector3(0, 1.65 * size, 0), Vector3(1.3, 0.5, 1.3) * size, plastic)
	_drum(frame, at + Vector3(0, 1.82 * size, 0), 0.42 * size, 0.12 * size, plastic)
	_detail = true
	for y in [0.55, 0.9, 1.25]:
		_drum(frame, at + Vector3(0, y * size, 0), 1.4 * size, 0.05 * size, plastic)
	_detail = false

## Polytank raised on an angle-iron stand, as in most compound yards.
func tank_stand(center: Vector3, height: float = 3.2) -> void:
	var frame := _frame(center)
	var steel := Materials.solid(Color("4a3a30"), 0.5, 0.7)
	for x in [-0.7, 0.7]:
		for z in [-0.7, 0.7]:
			_beam(frame, Vector3(x, 0, z), Vector3(x * 0.85, height, z * 0.85), 0.09, steel)
	_detail = true
	for y in [height * 0.35, height * 0.7]:
		for side in range(4):
			var turn := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
			_beam(turn, Vector3(-0.66, y, 0.66), Vector3(0.66, y + height * 0.3, 0.66), 0.05, steel)
	_detail = false
	_box(frame, Vector3(0, height, 0), Vector3(1.6, 0.1, 1.6), Materials.surface(6, Color("5a4632")))
	_water_tank(frame, Vector3(0, height - 0.12, 0))

func _air_conditioner(frame: Transform3D, at: Vector3) -> void:
	_box(frame, at, Vector3(0.8, 0.55, 0.3), Materials.solid(Color("d8d6cc"), 0.1, 0.6))
	_detail = true
	_drum(frame * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), at + Vector3(-0.12, 0, 0.14)), Vector3.ZERO, 0.4, 0.04, Materials.solid(Color("3c4040"), 0.3, 0.6))
	_detail = false

func compound(center: Vector3, size: float, floors: int, facing: Vector3 = Vector3.BACK) -> void:
	# The gate and the house front face `facing`. A swept laterite yard inside a
	# painted block wall, a steel gate, the polytank stand and something growing.
	var frame := _frame(center, facing)
	var paint: Color = WALLS[_rng.randi_range(0, WALLS.size() - 1)]
	var wall := Materials.surface(0, paint)
	var coping := Materials.surface(0, paint.lerp(Color("f6f1e4"), 0.6))
	var half: float = size * 0.5
	var tall: float = 1.9 if size > 12.0 else 1.5
	_box(frame, Vector3(0, -0.005, 0), Vector3(size, 0.05, size), Materials.surface(9, Color("9c6c4e")))
	for z in [-half, half]:
		if z < 0:
			_box(frame, Vector3(0, tall * 0.5, z), Vector3(size, tall, 0.18), wall, true)
			_box(frame, Vector3(0, tall + 0.04, z), Vector3(size + 0.06, 0.08, 0.26), coping)
		else:
			for sign_value in [-1.0, 1.0]:
				_box(frame, Vector3(sign_value * (size + 2.6) * 0.25, tall * 0.5, z), Vector3((size - 2.6) * 0.5, tall, 0.18), wall, true)
				_box(frame, Vector3(sign_value * (size + 2.6) * 0.25, tall + 0.04, z), Vector3((size - 2.6) * 0.5 + 0.06, 0.08, 0.26), coping)
	for x in [-half, half]:
		_box(frame, Vector3(x, tall * 0.5, 0), Vector3(0.18, tall, size), wall, true)
		_box(frame, Vector3(x, tall + 0.04, 0), Vector3(0.26, 0.08, size + 0.06), coping)
	for x in [-half, -1.34, 1.34, half]:
		_box(frame, Vector3(x, (tall + 0.3) * 0.5, half), Vector3(0.34, tall + 0.3, 0.34), wall, true)
		_box(frame, Vector3(x, tall + 0.36, half), Vector3(0.44, 0.12, 0.44), coping)
	var gate := Materials.surface(4, DOORS[_rng.randi_range(0, DOORS.size() - 1)])
	_box(frame, Vector3(0, tall * 0.5 + 0.03, half), Vector3(2.5, tall - 0.06, 0.07), gate)
	_detail = true
	for i in range(7):
		_ball(frame, Vector3(-1.05 + i * 0.35, tall + 0.1, half), Vector3(0.07, 0.2, 0.07), Materials.solid(Color("c9a437"), 0.7, 0.4))
	_detail = false
	building(center + frame.basis * Vector3(-0.5, 0, -0.7), facing, size * 0.57, size * 0.5, floors)
	# Validate the enclosing residential plot, not just the house inside its walls.
	land_uses[-1].merge({"center": center, "width": size, "depth": size, "compound": true}, true)
	var corner := center + frame.basis * Vector3(half - 1.5, 0, -half + 1.5)
	var pick: float = _rng.randf()
	if pick < 0.4:
		tree(corner, true)
	elif pick < 0.75:
		banana(corner)
	else:
		tree(corner, false, 6, 10)
	if size > 9.0:
		tank_stand(center + frame.basis * Vector3(half - 1.3, 0, half * 0.2), 2.8)
	if _rng.randf() < 0.4:
		for i in range(3):
			shrub(center + frame.basis * Vector3(-half + 1.2 + i * 1.1, tall - 0.5, half + 0.1), 0.9, true)

func boundary_wall(center: Vector3, facing: Vector3, width: float) -> void:
	var frame := _frame(center, facing)
	var material := Materials.surface(0, Color("d9c9a3"))
	_box(frame, Vector3(0, 0.75, 0), Vector3(width, 1.5, 0.2), material, true)
	_box(frame, Vector3(0, 1.54, 0), Vector3(width + 0.08, 0.1, 0.29), Materials.surface(0, Color("f0e9d8")))
	var piers: int = maxi(1, floori(width / 3.0))
	for i in range(piers + 1):
		_box(frame, Vector3(-width * 0.5 + width * i / piers, 0.85, 0), Vector3(0.3, 1.7, 0.32), material)

## Timber market stall under rusting roofing sheets, piled with produce.
func market_stall(center: Vector3, facing: Vector3, w: float, d: float) -> void:
	var frame := _frame(center, facing)
	var wood := Materials.surface(6, Color("756047"))
	var canopy := Materials.surface(4, [Color("a3a8a6"), Color("8a5b3e"), Color("2f5f93"), Color("b3b6b1")][_rng.randi_range(0, 3)])
	for x in [-w * 0.45, w * 0.45]:
		for z in [-d * 0.45, d * 0.45]:
			_beam(frame, Vector3(x, 0, z), Vector3(x, 2.1, z), 0.07, wood)
	var pitched := frame * Transform3D(Basis(Vector3.RIGHT, -0.13), Vector3(0, 2.12, 0))
	_box(pitched, Vector3.ZERO, Vector3(w + 0.3, 0.045, d + 0.4), canopy)
	_box(frame, Vector3(0, 0.75, 0.14), Vector3(w, 0.08, d * 0.8), wood)
	_ball(frame, Vector3(0, 1.85, 0.1), Vector3(0.15, 0.19, 0.15), _warm)
	for x in [-w * 0.42, w * 0.42]:
		_box(frame, Vector3(x, 0.37, 0.14), Vector3(0.08, 0.74, d * 0.7), wood)
	_detail = true
	var produce: Array[Color] = [Color("c8371f"), Color("e88d1c"), Color("5d8a2e"), Color("8a5a2f"), Color("e9c62c"), Color("b02a2a")]
	var heaps: int = maxi(3, floori(w / 0.5))
	for i in range(heaps):
		var fruit := Materials.solid(produce[_rng.randi_range(0, produce.size() - 1)], 0.0, 0.7)
		_ball(frame, Vector3(-w * 0.42 + (i + 0.5) * w * 0.84 / heaps, 0.88, 0.14 + _rng.randf_range(-0.2, 0.2) * d),
			Vector3(0.42, 0.26, 0.42), fruit)
	_detail = false

func commercial(center: Vector3, facing: Vector3, w: float, d: float, kind: String, title: String = "") -> void:
	## Purpose-built roadside premises; their front apron fits inside the setback.
	_building_count += 1
	var floors: int = 2 if kind in ["mall", "police"] else 1
	_record_use(kind, center, facing, w, d, floors)
	var frame := _frame(center, facing)
	var concrete := Materials.surface(2, Color("9c978b"))
	if kind != "kiosk":
		_box(frame, Vector3(0, 0.025, 0.45), Vector3(w + 0.5, 0.1, d + 1.5), concrete)
	match kind:
		"mechanic":
			_workshop(frame, w, d)
		"police":
			_police_station(frame, w, d)
		"kiosk":
			_kiosk(frame, w, d)
		_:
			_retail(frame, w, d, kind, title)

func _retail(frame: Transform3D, w: float, d: float, kind: String, title: String = "") -> void:
	var mall: bool = kind == "mall"
	var supermarket: bool = kind == "supermarket"
	if not mall and not supermarket:
		# Corner store: the same lock-up bays as any other line of shops.
		var paint: Color = WALLS[_rng.randi_range(0, WALLS.size() - 1)]
		_box(frame, Vector3(0, STORY * 0.5, 0), Vector3(w, STORY, d), Materials.surface(0, paint), true)
		_box(frame, Vector3(0, 0.55, 0), Vector3(w + 0.05, 1.1, d + 0.05), Materials.surface(0, DADOS[_rng.randi_range(0, DADOS.size() - 1)]))
		_shop_front(frame, w, d, paint, 0.9, 1)
		_hip_roof(frame, w + 0.6, d + 0.6, STORY + 0.02, clampf(minf(w, d) * 0.2, 0.7, 1.6))
		return
	var h: float = 7.2 if mall else 4.4
	var z: float = d * 0.5
	# Supermarkets are white with one loud colour; the mall is clad in panels.
	var accent: Color = [Color("c62f25"), Color("1c7a45"), Color("f08a1c"), Color("1c63a8")][_sign_count % 4]
	var plaster := Materials.surface(0, Color("dfe1dc") if mall else Color("f1ede0"))
	var trim := Materials.surface(2, Color("c9c9c0"))
	var colour := Materials.solid(accent, 0.0, 0.6)
	var metal := Materials.solid(Color("555f5d"), 0.65, 0.3)
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), plaster, true)
	_box(frame, Vector3(0, 0.16, 0), Vector3(w + 0.06, 0.32, d + 0.06), trim)
	_box(frame, Vector3(0, h - 0.5, 0), Vector3(w + 0.08, 0.7, d + 0.08), colour)
	var bays: int = maxi(2, floori(w / 3.0))
	for i in range(bays):
		var bay_w: float = w / bays
		var x: float = -w * 0.5 + (i + 0.5) * bay_w
		_glazed_shop_bay(frame, Vector3(x, 1.45, z + 0.055), bay_w - 0.3, 2.5, i == bays / 2)
		_box(frame, Vector3(x - bay_w * 0.5 + 0.1, 1.6, z + 0.07), Vector3(0.2, 3.2, 0.2), trim)
		if mall:
			_window(frame, Vector3(x, 5.0, z + 0.04), bay_w * 0.78, 1.9, false, trim, true)
			_box(frame, Vector3(x - bay_w * 0.45, 5.0, z + 0.2), Vector3(0.12, 2.4, 0.32), metal)
	if mall:
		for side in [-1.0, 1.0]:
			var flank := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
			var count: int = maxi(2, floori(d / 3.2))
			for i in range(count):
				_window(flank, Vector3(-d * 0.5 + (i + 0.5) * d / count, 5.0, w * 0.5 + 0.025), d / count * 0.6, 1.8, false, trim, true)
	var text: String
	if mall:
		text = (_premise_name("mall") if title.is_empty() else title) + "\nShops  •  Food Court  •  Cinema"
	else:
		text = (_premise_name("supermarket") if title.is_empty() else title) + "\nGroceries  •  Home Essentials"
	_sign(frame, text, Vector3(0, h - 0.5, z + 0.09), minf(w - 0.6, 12.0), 1.1 if mall else 0.95, Color("f4f1e6") if _sign_count % 2 == 0 else accent)
	_sign_count += 1
	_box(frame, Vector3(0, 3.1, z + 0.75), Vector3(w + 0.3, 0.14, 1.5), colour)
	for x in [-w * 0.46, w * 0.46]:
		_beam(frame, Vector3(x, 0.1, z + 1.35), Vector3(x, 3.05, z + 1.35), 0.09, metal)
	_flat_roof(frame, w, d, h, trim)
	_box(frame, Vector3(w * 0.24, h + 0.55, -d * 0.2), Vector3(1.6, 0.9, 2.0), metal)
	_water_tank(frame, Vector3(-w * 0.3, h + 0.13, -d * 0.25))
	if supermarket:
		# Nested trolley silhouettes alongside the entrance.
		_detail = true
		for i in range(3):
			var at := Vector3(w * 0.34, 0.0, z + 0.4 + i * 0.2)
			_box(frame, at + Vector3(0, 0.44, 0), Vector3(0.42, 0.26, 0.43), Materials.solid(Color("737f7d"), 0.8))
		_detail = false

func _glazed_shop_bay(frame: Transform3D, at: Vector3, w: float, h: float, entrance: bool) -> void:
	var aluminum := Materials.solid(Color("a6aca6"), 0.75, 0.28)
	var glass: Material = _cool if entrance else Materials.solid(Color("2f5f72"), 0.45, 0.16)
	_box(frame, at, Vector3(w, h, 0.06), glass)
	_detail = true
	for x in [-w * 0.5, 0.0, w * 0.5]:
		_box(frame, at + Vector3(x, 0, 0.045), Vector3(0.05, h + 0.04, 0.07), aluminum)
	for y in [-h * 0.5, h * 0.5]:
		_box(frame, at + Vector3(0, y, 0.045), Vector3(w + 0.04, 0.05, 0.07), aluminum)
	if not entrance:
		# Promotional poster behind the glass.
		_box(frame, at + Vector3(0, -h * 0.12, 0.04), Vector3(w * 0.6, h * 0.42, 0.02),
			Materials.solid(CLOTH[_rng.randi_range(0, CLOTH.size() - 1)], 0.0, 0.7))
	_detail = false

func _flat_roof(frame: Transform3D, w: float, d: float, h: float, trim: Material) -> void:
	_box(frame, Vector3(0, h + 0.04, 0), Vector3(w + 0.18, 0.12, d + 0.18), Materials.surface(2, Color("8a8b84")))
	for z in [-d * 0.5, d * 0.5]:
		_box(frame, Vector3(0, h + 0.25, z), Vector3(w + 0.18, 0.42, 0.17), trim)
	for x in [-w * 0.5, w * 0.5]:
		_box(frame, Vector3(x, h + 0.25, 0), Vector3(0.17, 0.42, d), trim)

## Fitting shop: bare block walls, a rusting zinc roof, a car under repair,
## an engine block on the floor and the vulcanizer's tyre stack by the road.
func _workshop(frame: Transform3D, w: float, d: float) -> void:
	var h: float = 3.6
	var wall := Materials.surface(11, Color("9c9a92"))
	var metal := Materials.surface(4, Color("8a5b3e"))
	var dark := Materials.solid(Color("1c1d1c"))
	var bay_count: int = maxi(2, floori(w / 4.2))
	var z: float = d * 0.5
	# Real open bays: collision follows rear and flank walls, not the openings.
	_box(frame, Vector3(0, h * 0.5, -z + 0.12), Vector3(w, h, 0.24), wall, true)
	for x in [-w * 0.5 + 0.1, w * 0.5 - 0.1]:
		_box(frame, Vector3(x, h * 0.5, 0), Vector3(0.2, h, d), wall, true)
	_box(frame, Vector3(0, 0.07, 0), Vector3(w, 0.14, d), Materials.surface(9, Color("5b5148")))
	_hip_roof(frame, w + 0.6, d + 0.9, h, 0.9, true)
	for i in range(bay_count + 1):
		var x: float = -w * 0.5 + i * w / bay_count
		_box(frame, Vector3(x, h * 0.5, z - 0.07), Vector3(0.22, h, 0.22), wall, true)
	for i in range(bay_count):
		var x: float = -w * 0.5 + (i + 0.5) * w / bay_count
		_box(frame, Vector3(x, 0.8, -z + 0.6), Vector3(w / bay_count * 0.7, 0.1, 0.7), Materials.surface(6, Color("5a4632")))
		_box(frame, Vector3(x, 1.5, -z + 0.26), Vector3(w / bay_count * 0.66, 0.9, 0.05), dark)
	_sign(frame, _premise_name("mechanic") + "\nFitting  •  Vulcanizing  •  Spraying", Vector3(0, h - 0.35, z + 0.2), minf(w - 0.4, 9.0), 0.85, Color("f2c318"))
	_sign_count += 1
	# Service car, engine block and tyre stack make the premises legible at street level.
	var car := FleetActor.new()
	car.configure("car", 4)
	car.transform = frame * Transform3D(Basis(Vector3.UP, 0.25), Vector3(-w * 0.2, 0.17, 0.3))
	car.set_metric_dimensions(Vector3(1.8, 1.5, 4.5))
	car.name = "WorkshopVehicle"
	add_child(car)
	var rubber := Materials.solid(Color("161616"), 0.0, 0.9)
	for i in range(6):
		_drum(frame, Vector3(w * 0.38 + (i / 4) * 0.4, 0.14 + (i % 4) * 0.2, z + 0.5), 0.66, 0.19, rubber)
	_drum(frame, Vector3(w * 0.22, 0.14, z - 1.2), 0.58, 0.88, Materials.solid(Color("2f5f93"), 0.4, 0.6))
	_box(frame, Vector3(w * 0.05, 0.4, -z + 1.6), Vector3(0.7, 0.55, 0.5), Materials.solid(Color("3b3f41"), 0.7, 0.5))

func _police_station(frame: Transform3D, w: float, d: float) -> void:
	# Ghana Police stations are white over a strong blue band.
	var h: float = STORY * 2.0
	var z: float = d * 0.5
	var wall := Materials.surface(0, Color("eef0ea"))
	var blue := Materials.surface(0, Color("1f4f9a"))
	var trim := Materials.surface(2, Color("c9c9c0"))
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), wall, true)
	_box(frame, Vector3(0, 0.6, 0), Vector3(w + 0.04, 1.2, d + 0.04), blue)
	for floor_index in range(2):
		for side in range(4):
			var face := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
			var span: float = w if side % 2 == 0 else d
			var dep: float = d if side % 2 == 0 else w
			for x in [-span * 0.32, span * 0.32]:
				_window(face, Vector3(x, 1.75 + floor_index * STORY, dep * 0.5 + 0.025), minf(span * 0.22, 1.5), 1.15, floor_index == 0, trim, side != 0)
	_door(frame, Vector3(0, 1.1, z + 0.05), 1.3, 2.2)
	_box(frame, Vector3(0, 2.75, z + 0.7), Vector3(w * 0.5, 0.16, 1.4), blue)
	for x in [-w * 0.22, w * 0.22]:
		_box(frame, Vector3(x, 1.38, z + 1.3), Vector3(0.22, 2.75, 0.22), wall)
	_sign(frame, _premise_name("police") + "\nGhana Police Service", Vector3(0, STORY + 0.55, z + 0.1), minf(w - 0.6, 8.0), 0.9, Color("1f4f9a"))
	_sign_count += 1
	_flat_roof(frame, w, d, h, trim)
	_water_tank(frame, Vector3(w * 0.25, h + 0.13, -d * 0.2))
	var mast_x: float = -w * 0.43
	_beam(frame, Vector3(mast_x, 0.1, z + 1.0), Vector3(mast_x, 6.0, z + 1.0), 0.07, Materials.solid(Color("d9dbd6"), 0.5))
	# Ghana's flag, mounted within the forecourt rather than over the pavement.
	for stripe in range(3):
		var color: Color = [Color("c8281e"), Color("f2c318"), Color("1c7a45")][stripe]
		_box(frame, Vector3(mast_x + 0.6, 5.75 - stripe * 0.25, z + 1.0), Vector3(1.1, 0.25, 0.022), Materials.solid(color, 0.0, 0.8))
	_ball(frame, Vector3(mast_x + 0.6, 5.5, z + 1.0), Vector3(0.2, 0.2, 0.04), Materials.solid(Color("16181a")))

## Container shop: a painted steel box with a serving hatch under a propped
## awning. Mobile-money yellow, airtime red and cold-drink blue are everywhere.
func _kiosk(frame: Transform3D, w: float, d: float) -> void:
	var h: float = 2.5
	var z: float = d * 0.5
	var accent: Color = [Color("f2c318"), Color("c62f25"), Color("1c63a8"), Color("1c7a45"), Color("f08a1c"), Color("f4f1e6")][_sign_count % 6]
	var steel := Materials.surface(4, accent)
	var dark := Materials.solid(Color("15120f"))
	_box(frame, Vector3(0, 0.1, 0), Vector3(w * 0.9, 0.2, d * 0.9), Materials.surface(11, Color("9c9a92")))
	_box(frame, Vector3(0, 0.2 + h * 0.5, 0), Vector3(w, h, d), steel, true)
	_box(frame, Vector3(0, h + 0.24, 0), Vector3(w + 0.1, 0.08, d + 0.1), Materials.surface(4, Color("a3a8a6")))
	_box(frame, Vector3(0, 1.55, z + 0.02), Vector3(w * 0.72, 1.05, 0.05), dark)
	_box(frame, Vector3(0, 1.0, z + 0.2), Vector3(w * 0.78, 0.06, 0.42), Materials.surface(6, Color("8a7350")))
	var awning := frame * Transform3D(Basis(Vector3.RIGHT, 0.32), Vector3(0, 2.3, z + 0.55))
	_box(awning, Vector3.ZERO, Vector3(w * 0.8, 0.04, 1.15), steel)
	_detail = true
	for x in [-w * 0.36, w * 0.36]:
		_beam(frame, Vector3(x, 1.05, z + 0.05), Vector3(x, 2.1, z + 1.05), 0.03, Materials.solid(Color("3a3d3a"), 0.5))
	for i in range(6):
		_box(frame, Vector3(-w * 0.28 + i * w * 0.11, 1.15, z + 0.2), Vector3(w * 0.08, 0.24, 0.16), Materials.solid(CLOTH[i % CLOTH.size()], 0.0, 0.7))
	for i in range(5):
		_drum(frame, Vector3(-w * 0.26 + i * w * 0.13, 1.72, z + 0.06), 0.09, 0.26, Materials.solid(CLOTH[(i + 3) % CLOTH.size()], 0.1, 0.5))
	_detail = false
	_ball(frame, Vector3(0, 2.2, z + 0.5), Vector3(0.16, 0.2, 0.16), _warm)
	_sign(frame, _premise_name("kiosk") + "\nTransfer  •  Credit  •  Provisions", Vector3(0, h + 0.62, z - 0.05), w, 0.62, accent)
	_sign_count += 1

func _entrance_apron(frame: Transform3D, w: float, d: float) -> void:
	# All paving and planting remain inside the plot's existing reserved envelope.
	var paving := Materials.surface(5, Color("b3ada0"))
	var trim := Materials.surface(2, Color("9a9a8e"))
	var z: float = d * 0.5
	_box(frame, Vector3(0, 0.025, 0.45), Vector3(w + 0.6, 0.1, d + 1.5), paving)
	_box(frame, Vector3(0, 0.13, 0), Vector3(w + 0.08, 0.26, d + 0.08), trim)
	var entry_w: float = minf(2.6, w * 0.46)
	_box(frame, Vector3(0, 0.085, z + 0.7), Vector3(entry_w + 0.3, 0.07, 0.88), trim)
	_box(frame, Vector3(0, 0.12, z + 0.35), Vector3(entry_w, 0.14, 0.52), paving)
	for side in [-1.0, 1.0]:
		var x: float = side * w * 0.36
		var planter_w: float = minf(1.25, w * 0.2)
		_box(frame, Vector3(x, 0.25, z + 0.65), Vector3(planter_w, 0.35, 0.66), trim)
		for cluster in range(3):
			var leaf_at := Vector3(x + (cluster - 1) * planter_w * 0.22, 0.6, z + 0.65)
			_batch(_leaf_mesh, Materials.foliage(), frame * Transform3D(Basis.from_scale(Vector3(0.75, 0.6, 0.7)), leaf_at),
				Color(0.5, 0.2 if cluster == 1 else 0.5, 0.0 if cluster == 1 else 0.5))

## Block of flats: painted render, a balcony to every flat, condensers, washing
## and the row of polytanks that every Accra roofline carries.
func apartment(center: Vector3, facing: Vector3, floors: int, w: float, d: float) -> void:
	_building_count += 1
	_record_use("apartment", center, facing, w, d, floors)
	var frame := _frame(center, facing)
	var story: float = 3.0
	var h: float = floors * story
	var scheme: int = _rng.randi_range(0, 3)
	var plaster := Materials.surface(0, [Color("f0e6cf"), Color("ead9ae"), Color("e9e4d8"), Color("efe3c0")][scheme])
	var accent := Materials.surface(0, [Color("b6553c"), Color("3d6d8a"), Color("7b3328"), Color("c08a3a")][scheme])
	var trim := Materials.surface(2, Color("d6d3c6"))
	var metal := Materials.solid(Color("3c4446"), 0.65, 0.3)
	_entrance_apron(frame, w, d)
	# Recessed central volume leaves genuine balcony depth within the plot.
	_box(frame, Vector3(0, h * 0.5, -0.35), Vector3(w, h, d - 0.7), plaster, true)
	_box(frame, Vector3(0, 1.5, 0), Vector3(w, 3.0, d), accent, true)
	for side in range(4):
		var face := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
		var span: float = w if side % 2 == 0 else d
		var dep: float = d if side % 2 == 0 else w
		var bays: int = maxi(2, floori(span / 3.0))
		for floor_index in range(1, floors):
			var y: float = floor_index * story
			for bay in range(bays):
				var x: float = -span * 0.5 + (bay + 0.5) * span / bays
				var inset: float = 0.67 if side == 0 else 0.0
				_window(face, Vector3(x, y + 1.45, dep * 0.5 - inset + 0.025), span / bays * 0.5, 1.5, false, trim, true)
				if side == 0:
					# Individual balconies with solid partitions and painted upstands.
					_box(face, Vector3(x, y + 0.06, dep * 0.5 - 0.23), Vector3(span / bays - 0.14, 0.15, 0.88), trim)
					_box(face, Vector3(x - span / bays * 0.5 + 0.08, y + 1.35, dep * 0.5 - 0.25), Vector3(0.14, 2.7, 0.84), accent)
					_box(face, Vector3(x, y + 0.55, dep * 0.5 + 0.16), Vector3(span / bays - 0.2, 0.9, 0.08), accent if (bay + floor_index) % 2 == 0 else plaster)
					if (bay * 3 + floor_index) % 4 == 0:
						_air_conditioner(face, Vector3(x + span / bays * 0.25, y + 2.2, dep * 0.5 - 0.5))
					if (bay + floor_index * 2) % 5 == 0:
						_detail = true
						for item in range(4):
							_box(face, Vector3(x - 0.6 + item * 0.4, y + 1.55, dep * 0.5 + 0.1), Vector3(0.32, 0.6, 0.02),
								Materials.solid(CLOTH[(item + bay + floor_index) % CLOTH.size()], 0.0, 0.9))
						_detail = false
			_box(face, Vector3(0, y, dep * 0.5 + 0.015), Vector3(span + 0.1, 0.16, 0.16), trim)
	_glazed_shop_bay(frame, Vector3(0, 1.3, d * 0.5 + 0.06), minf(w * 0.4, 2.3), 2.25, true)
	_box(frame, Vector3(0, 2.75, d * 0.5 + 0.4), Vector3(w * 0.6, 0.16, 0.95), metal)
	_sign(frame, _premise_name("apartment") + "\nApartments", Vector3(0, 3.4, d * 0.5 + 0.13), minf(w * 0.62, 5.5), 0.7, Color("f4f1e6"))
	_sign_count += 1
	_flat_roof(frame, w, d, h, trim)
	_box(frame, Vector3(0, h + 1.1, -d * 0.17), Vector3(w * 0.33, 2.2, d * 0.4), accent)
	for tank in range(maxi(2, floori(w / 4.0))):
		_water_tank(frame, Vector3(-w * 0.38 + tank * 1.7, h + 0.1, d * 0.22))

## Office block in the Airport City manner: blue reflective glass between
## white composite fins, a plant room and a mast on the roof.
func office(center: Vector3, floors: int, w: float, d: float) -> void:
	_building_count += 1
	_record_use("office", center, Vector3.BACK, w, d, floors)
	var frame := _frame(center)
	var story: float = 3.2 if w >= 11.0 else 2.2
	var h: float = floors * story
	var scheme: int = _rng.randi_range(0, 2)
	var skin := Materials.surface(0, [Color("eceae2"), Color("d9d5c8"), Color("e6dcc4")][scheme])
	var fin := Materials.solid([Color("f1f1ec"), Color("c9ccc9"), Color("e9e2cf")][scheme], 0.3, 0.45)
	var glass_color: Color = [Color("2f6f9f"), Color("2c7f86"), Color("3a5f8a")][scheme]
	_entrance_apron(frame, w, d)
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), skin, true)
	for side in range(4):
		var face := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
		var span: float = w if side % 2 == 0 else d
		var dep: float = d if side % 2 == 0 else w
		var bays: int = maxi(2, floori(span / (2.4 if w >= 11.0 else 1.6)))
		for floor_index in range(floors):
			for bay in range(bays):
				var x: float = -span * 0.5 + (bay + 0.5) * span / bays
				var pane: Material = _cool if _rng.randf() < 0.16 else Materials.solid(glass_color.darkened(_rng.randf() * 0.18), 0.55, 0.12)
				_box(face, Vector3(x, floor_index * story + story * 0.55, dep * 0.5 + 0.025), Vector3(span / bays - 0.14, story * 0.72, 0.035), pane)
			_box(face, Vector3(0, (floor_index + 1) * story, dep * 0.5 + 0.12), Vector3(span + 0.15, 0.16, 0.34), fin)
		for bay in range(bays + 1):
			_box(face, Vector3(-span * 0.5 + bay * span / bays, h * 0.5, dep * 0.5 + 0.12), Vector3(0.1, h, 0.3), fin)
	_box(frame, Vector3(0, h + 0.3, 0), Vector3(w + 0.2, 0.6, d + 0.2), skin)
	_box(frame, Vector3(0, h + 1.0, -d * 0.12), Vector3(w * 0.45, 1.2, d * 0.5), Materials.surface(4, Color("a3a8a6")))
	if floors >= 6:
		# Lattice telecom mast and warning light on the tallest blocks.
		var steel := Materials.solid(Color("c8281e"), 0.4, 0.5)
		_beam(frame, Vector3(w * 0.3, h + 0.6, d * 0.25), Vector3(w * 0.3, h + 7.0, d * 0.25), 0.18, steel)
		_beam(frame, Vector3(w * 0.3, h + 3.2, d * 0.25), Vector3(w * 0.3, h + 4.6, d * 0.25), 0.2, Materials.solid(Color("f1f1ec"), 0.4, 0.5))
	_water_tank(frame, Vector3(-w * 0.3, h + 0.6, d * 0.25))
	_door(frame, Vector3(0, 1.1, d * 0.5 + 0.08), 1.3, 2.05)
	_box(frame, Vector3(0, 2.6, d * 0.5 + 0.7), Vector3(w * 0.6, 0.16, 1.5), fin)

func warehouse(center: Vector3, w: float, h: float, d: float) -> void:
	_building_count += 1
	_record_use("warehouse", center, Vector3.BACK, w, d, maxi(1, ceili(h / 2.55)))
	var frame := _frame(center)
	var render := Materials.surface(0, [Color("e9e2cf"), Color("c9c3b4"), Color("d9cfae")][_rng.randi_range(0, 2)])
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), render, true)
	_box(frame, Vector3(0, 0.6, 0), Vector3(w + 0.05, 1.2, d + 0.05), Materials.surface(0, DADOS[_rng.randi_range(0, DADOS.size() - 1)]))
	_hip_roof(frame, w + 0.5, d + 0.6, h, minf(w, d) * 0.18, true)
	var shutter := Materials.surface(4, DOORS[_rng.randi_range(0, DOORS.size() - 1)])
	_box(frame, Vector3(0, h * 0.34, d * 0.5 + 0.05), Vector3(w * 0.42, h * 0.68, 0.08), shutter)
	for x in [-w * 0.4, w * 0.4]:
		_window(frame, Vector3(x, h * 0.65, d * 0.5 + 0.04), w * 0.13, h * 0.2, true, render)
	_box(frame, Vector3(0, 0.09, d * 0.5 + 0.8), Vector3(w + 1.0, 0.18, 1.8), Materials.surface(2, Color("9a958a")))

## Uncompleted storey building: bare blockwork between concrete frames, empty
## openings, columns standing above the last slab with their starter bars, and
## the owner's sand and blocks waiting outside.
func uncompleted(center: Vector3, facing: Vector3, w: float, d: float, floors: int) -> void:
	_building_count += 1
	_record_use("uncompleted", center, facing, w, d, floors)
	var frame := _frame(center, facing)
	var h: float = floors * STORY
	var block := Materials.surface(11, Color("a09d94"))
	var concrete := Materials.surface(2, Color("7f7b72"))
	var hollow := Materials.solid(Color("1a1917"))
	var bays: int = maxi(1, roundi(w / 3.4))
	_box(frame, Vector3(0, h * 0.5, 0), Vector3(w, h, d), block, true)
	for floor_index in range(floors + 1):
		_box(frame, Vector3(0, floor_index * STORY - 0.1, 0), Vector3(w + 0.2, 0.22, d + 0.2), concrete)
	var rust := Materials.solid(Color("5e3524"), 0.3, 0.8)
	for i in range(bays + 1):
		var x: float = clampf(-w * 0.5 + i * w / bays, -w * 0.5 + 0.13, w * 0.5 - 0.13)
		for z in [-d * 0.5 + 0.13, d * 0.5 - 0.13]:
			_box(frame, Vector3(x, (h + 1.0) * 0.5, z), Vector3(0.3, h + 1.0, 0.3), concrete)
			_detail = true
			for corner in range(4):
				var bar := Vector3(x + (0.09 if corner % 2 == 0 else -0.09), 0, z + (0.09 if corner < 2 else -0.09))
				_beam(frame, bar + Vector3(0, h + 1.0, 0), bar + Vector3(_rng.randf_range(-0.06, 0.06), h + _rng.randf_range(1.7, 2.1), 0), 0.03, rust)
			_detail = false
	for floor_index in range(floors):
		for side in range(4):
			var face := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
			var span: float = w if side % 2 == 0 else d
			var dep: float = d if side % 2 == 0 else w
			var count: int = maxi(1, floori(span / 3.0))
			for k in range(count):
				var x: float = -span * 0.5 + (k + 0.5) * span / count
				if side == 0 and floor_index == 0 and k == count / 2:
					_box(face, Vector3(x, 1.1, dep * 0.5 + 0.01), Vector3(1.1, 2.2, 0.05), hollow)
				else:
					_box(face, Vector3(x, floor_index * STORY + 1.6, dep * 0.5 + 0.01), Vector3(1.3, 1.2, 0.05), hollow)
	# Sharp sand, a stack of blocks and bamboo props by the front.
	var z_front: float = d * 0.5
	_ball(frame, Vector3(-w * 0.28, 0.2, z_front + 0.75), Vector3(2.2, 1.1, 1.3), Materials.surface(9, Color("cdb68a")))
	for i in range(12):
		_box(frame, Vector3(w * 0.2 + (i % 4) * 0.47, 0.12 + (i / 4) * 0.24, z_front + 0.6), Vector3(0.45, 0.22, 0.22), Materials.surface(2, Color("9a978e")))
	_detail = true
	for i in range(3):
		_beam(frame, Vector3(-w * 0.1 + i * 0.5, 0, z_front + 0.3), Vector3(-w * 0.1 + i * 0.5, STORY - 0.2, z_front + 0.12), 0.07, Materials.surface(6, Color("b09a62")))
	_detail = false
	if _rng.randf() < 0.6:
		var notice := Props.label(self, "STOP WORK\nPRODUCE PERMIT", Vector3.ZERO, minf(w * 0.45, 3.4), 1.0, Color("b3221a"), "PermitNotice")
		notice.transform = frame * Transform3D(Basis.IDENTITY, Vector3(w * 0.22, 1.5, z_front + 0.015))
		notice.visibility_range_end = 60.0

## Red-and-white lattice telecom mast in a small walled compound with its
## equipment cabin and generator: the tallest thing on most Accra skylines.
func telecom_mast(center: Vector3, height: float = 44.0) -> void:
	var frame := _frame(center)
	var red := Materials.solid(Color("c8281e"), 0.3, 0.5)
	var white := Materials.solid(Color("f1f1ec"), 0.3, 0.5)
	var spread: float = height * 0.075
	var sections: int = 8
	for i in range(sections):
		var y0: float = height * i / sections
		var y1: float = height * (i + 1) / sections
		var r0: float = lerpf(spread, 0.55, float(i) / sections)
		var r1: float = lerpf(spread, 0.55, float(i + 1) / sections)
		var paint: Material = red if i % 2 == 0 else white
		for face in range(4):
			var a: float = face * PI * 0.5 + PI * 0.25
			var b: float = a + PI * 0.5
			var low_a := Vector3(cos(a) * r0 * 1.414, y0, sin(a) * r0 * 1.414)
			var low_b := Vector3(cos(b) * r0 * 1.414, y0, sin(b) * r0 * 1.414)
			var high_a := Vector3(cos(a) * r1 * 1.414, y1, sin(a) * r1 * 1.414)
			var high_b := Vector3(cos(b) * r1 * 1.414, y1, sin(b) * r1 * 1.414)
			_beam(frame, low_a, high_a, 0.2, paint)
			_beam(frame, low_a, low_b, 0.09, paint)
			_beam(frame, low_a, high_b, 0.08, paint)
			_beam(frame, low_b, high_a, 0.08, paint)
	var grey := Materials.solid(Color("d9dbd6"), 0.3, 0.5)
	for k in range(3):
		var turn := frame * Transform3D(Basis(Vector3.UP, k * TAU / 3.0), Vector3.ZERO)
		_box(turn, Vector3(0, height - 2.6, 1.0), Vector3(0.36, 2.2, 0.16), grey)
		_box(turn, Vector3(0, height - 6.4, 1.15), Vector3(0.36, 2.2, 0.16), grey)
	for k in range(2):
		var dish := frame * Transform3D(Basis(Vector3.UP, 0.8 + k * 2.3), Vector3(0, height * (0.72 - k * 0.1), 0))
		_batch(_sphere_mesh, grey, dish * Transform3D(Basis.from_scale(Vector3(1.3, 1.3, 0.4)), Vector3(0, 0, 1.25)))
	_ball(frame, Vector3(0, height + 0.25, 0), Vector3.ONE * 0.36, _warm)
	_beam(frame, Vector3(0, height, 0), Vector3(0, height + 2.4, 0), 0.06, grey)
	# Compound: block wall, steel gate, equipment cabin and a diesel generator.
	var half: float = spread + 2.6
	var block := Materials.surface(11, Color("a09d94"))
	_box(frame, Vector3(0, 0.02, 0), Vector3(half * 2.0, 0.04, half * 2.0), Materials.surface(2, Color("9c978b")))
	for side in range(4):
		var turn := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
		if side == 0:
			_box(turn, Vector3(-half * 0.5 - 0.7, 1.1, half), Vector3(half - 1.4, 2.2, 0.2), block, true)
			_box(turn, Vector3(half * 0.5 + 0.7, 1.1, half), Vector3(half - 1.4, 2.2, 0.2), block, true)
			_box(turn, Vector3(0, 1.05, half), Vector3(2.8, 2.0, 0.07), Materials.surface(4, Color("2f5f93")))
		else:
			_box(turn, Vector3(0, 1.1, half), Vector3(half * 2.0, 2.2, 0.2), block, true)
	_box(frame, Vector3(half - 2.0, 1.3, -half + 1.6), Vector3(2.6, 2.6, 2.2), Materials.surface(4, Color("d9dbd6")))
	_box(frame, Vector3(-half + 1.6, 0.75, -half + 1.4), Vector3(2.0, 1.3, 1.1), Materials.solid(Color("2e7352"), 0.4, 0.5))

## Steel pedestrian footbridge over a road that runs along Z: a deck on two
## concrete piers, parapet trusses, and a dog-leg stair down to each apron.
## `stairs` is +1 or -1: which way along the road the stairs descend. Only the
## piers are solid; the deck has no collider because it crosses the carriageway.
func footbridge(center: Vector3, span: float, stairs: float = 1.0, advert: String = "") -> void:
	var frame := _frame(center)
	var steel := Materials.solid(Color("1c63a8"), 0.35, 0.5)
	var brace := Materials.solid(Color("f2c318"), 0.35, 0.5)
	var concrete := Materials.surface(2, Color("9c978b"))
	var deck: float = 5.7
	var w: float = 2.8
	_box(frame, Vector3(0, deck - 0.15, 0), Vector3(span + 1.2, 0.3, w), concrete)
	var panels: int = maxi(4, int(span / 2.6))
	for side in [-1.0, 1.0]:
		var z: float = side * (w * 0.5 - 0.07)
		_box(frame, Vector3(0, deck + 1.5, z), Vector3(span + 1.2, 0.14, 0.14), steel)
		_box(frame, Vector3(0, deck + 0.12, z), Vector3(span + 1.2, 0.14, 0.14), steel)
		for i in range(panels + 1):
			var x: float = -span * 0.5 + i * span / panels
			_box(frame, Vector3(x, deck + 0.8, z), Vector3(0.1, 1.4, 0.1), steel)
			if i < panels:
				var rise: float = 1.5 if i % 2 == 0 else 0.12
				_beam(frame, Vector3(x, deck + (0.12 if i % 2 == 0 else 1.5), z), Vector3(x + span / panels, deck + rise, z), 0.07, brace)
	for end in [-1.0, 1.0]:
		var x: float = end * span * 0.5
		_box(frame, Vector3(x, (deck - 0.3) * 0.5, 0), Vector3(0.8, deck - 0.3, 1.8), concrete, true)
		_box(frame, Vector3(x, deck - 0.55, 0), Vector3(1.1, 0.5, w + 0.3), concrete)
		# Two flights of sixteen risers with a half landing, running along the road.
		var dir: float = stairs
		var tread: float = 0.3
		var riser: float = (deck - 0.15) / 32.0
		for flight in range(2):
			var top: float = deck - 0.15 - flight * riser * 16.0
			var start: float = w * 0.5 + flight * (16 * tread + 1.6)
			for i in range(16):
				_box(frame, Vector3(x, top - (i + 0.5) * riser - 0.1, dir * (start + (i + 0.5) * tread)), Vector3(1.9, riser + 0.2, tread), concrete)
			var foot: float = start + 16 * tread
			for rail in [-0.9, 0.9]:
				_beam(frame, Vector3(x + rail, top + 1.0, dir * start), Vector3(x + rail, top - 16 * riser + 1.0, dir * foot), 0.07, steel)
				_detail = true
				for post in range(5):
					var t: float = post / 4.0
					_beam(frame, Vector3(x + rail, top - t * 16 * riser, dir * lerpf(start, foot, t)),
						Vector3(x + rail, top - t * 16 * riser + 1.0, dir * lerpf(start, foot, t)), 0.05, steel)
				_detail = false
			if flight == 0:
				_box(frame, Vector3(x, top - 16 * riser - 0.12, dir * (foot + 0.8)), Vector3(1.9, 0.24, 1.6), concrete)
				_box(frame, Vector3(x, (top - 16 * riser) * 0.5, dir * (foot + 0.8)), Vector3(0.5, top - 16 * riser, 0.5), concrete, true)
	if not advert.is_empty():
		for face in [0.0, PI]:
			var turn := frame * Transform3D(Basis(Vector3.UP, face), Vector3.ZERO)
			_sign(turn, advert, Vector3(0, deck + 0.82, w * 0.5 + 0.03), minf(span * 0.5, 9.0), 1.25, Color("1c7a45") if face == 0.0 else Color("c62f25"))
			_sign_count += 1

## Vacant plot behind a block wall with the owner's warning painted on it, a
## foundation trench, a pile of blocks and weeds taking over.
func walled_plot(center: Vector3, facing: Vector3, w: float, d: float) -> void:
	var frame := _frame(center, facing)
	var block := Materials.surface(11, Color("a6a39a"))
	var texts: Array[String] = ["THIS LAND IS\nNOT FOR SALE", "POST NO BILL", "KEEP OFF\nBY ORDER", "PLOT 14\nNOT FOR SALE", "BEWARE OF\n419"]
	for side in range(4):
		var turn := frame * Transform3D(Basis(Vector3.UP, side * PI * 0.5), Vector3.ZERO)
		var span: float = w if side % 2 == 0 else d
		var reach: float = d if side % 2 == 0 else w
		if side == 0:
			for part in [-1.0, 1.0]:
				_box(turn, Vector3(part * (span * 0.25 + 0.8), 1.0, reach * 0.5), Vector3(span * 0.5 - 1.6, 2.0, 0.2), block, true)
			_box(turn, Vector3(0, 0.95, reach * 0.5), Vector3(3.2, 1.9, 0.07), Materials.surface(4, DOORS[_rng.randi_range(0, DOORS.size() - 1)]))
			var notice := Props.label(self, texts[_sign_count % texts.size()], Vector3.ZERO, minf(span * 0.2, 3.0), 0.9, Color("b3221a"), "WallNotice")
			notice.transform = turn * Transform3D(Basis.IDENTITY, Vector3(span * 0.25 + 0.8, 1.25, reach * 0.5 + 0.11))
			notice.visibility_range_end = 60.0
			_sign_count += 1
		else:
			_box(turn, Vector3(0, 1.0, reach * 0.5), Vector3(span, 2.0, 0.2), block, true)
	for i in range(18):
		_box(frame, Vector3(-w * 0.3 + (i % 6) * 0.47, 0.12 + (i / 6) * 0.24, -d * 0.2), Vector3(0.45, 0.22, 0.22), Materials.surface(2, Color("9a978e")))
	_box(frame, Vector3(w * 0.12, 0.12, d * 0.05), Vector3(w * 0.45, 0.24, d * 0.4), Materials.surface(11, Color("8f8c84")))
	_box(frame, Vector3(w * 0.12, 0.13, d * 0.05), Vector3(w * 0.45 - 0.5, 0.25, d * 0.4 - 0.5), Materials.surface(9, Color("8f6046")))
	for i in range(6):
		shrub(frame * Vector3(_rng.randf_range(-0.42, 0.42) * w, 0, _rng.randf_range(-0.42, 0.42) * d), _rng.randf_range(0.8, 1.5))
	if _rng.randf() < 0.5:
		banana(frame * Vector3(-w * 0.36, 0, d * 0.3))

## Compacted earth yard with `count` metre-scale cars nosed in along its edges.
func yard_parking(center: Vector3, w: float, d: float, count: int) -> void:
	var frame := _frame(center)
	if d > w:
		frame = _frame(center, Vector3.RIGHT)
		var swap: float = w
		w = d
		d = swap
	_box(frame, Vector3(0, 0.02, 0), Vector3(w, 0.04, d), Materials.surface(9, Color("8f6046")))
	var per_row: int = maxi(1, floori((w - 1.0) / 2.9))
	for i in range(count):
		var row: int = i / per_row
		if row > 1:
			break
		var car := FleetActor.new()
		car.configure("car", i * 7 + int(absf(center.x + center.z)))
		var x: float = -w * 0.5 + 1.9 + (i % per_row) * 2.9
		var z: float = (-d * 0.5 + 2.8) if row == 0 else (d * 0.5 - 2.8)
		# Place first: assigning a transform would discard the metre-scale sizing.
		car.transform = frame * Transform3D(Basis(Vector3.UP, (0.0 if row == 0 else PI) + sin(float(i) * 2.9) * 0.12), Vector3(x, 0.05, z))
		car.set_metric_dimensions(Vector3(1.8, 1.5, 4.5))
		car.name = "ParkedVehicle"
		add_child(car)

func tree(center: Vector3, palm: bool = false, branches: int = 9, clusters: int = 14, scale_factor: float = 1.0) -> void:
	# Infill passes ask for fewer branches and leaf clusters to keep groves cheap.
	# Without a palm the species is drawn at random: a dark domed mango, an open
	# neem, a tiered tropical almond or, now and then, a flamboyant in flower.
	_tree_count += 1
	var frame := _frame(center, Vector3(sin(_tree_count * 2.4), 0, cos(_tree_count * 2.4)))
	frame.basis = frame.basis.scaled(Vector3.ONE*scale_factor)
	if palm:
		_palm(frame, _rng.randf_range(6.2, 9.0), Materials.surface(6, Color("8d8068")))
		return
	var pick: float = _rng.randf()
	var mango: bool = pick < 0.42
	var flamboyant: bool = pick > 0.9
	var bark := Materials.surface(6, Color("5b4a36") if mango else Color("6e6048"))
	var h: float = _rng.randf_range(3.6, 5.0) if mango else _rng.randf_range(4.4, 6.4)
	var spread: float = 1.25 if mango else (1.5 if flamboyant else 1.0)
	var lean := Vector3(_rng.randf_range(-0.35, 0.35), 0, _rng.randf_range(-0.3, 0.3))
	_beam(frame, Vector3.ZERO, lean + Vector3(0, h * 0.62, 0), 0.38 if mango else 0.3, bark)
	for branch in range(branches):
		var angle: float = branch * TAU / branches + _rng.randf_range(-0.25, 0.25)
		var radius: float = _rng.randf_range(0.5, 2.3) * spread
		var top: float = _rng.randf_range(0.82, 1.0) if flamboyant else _rng.randf_range(0.7, 1.18)
		var tip := Vector3(cos(angle) * radius, h * top, sin(angle) * radius) + lean
		var joint := lean + Vector3(0, h * _rng.randf_range(0.42, 0.62), 0)
		_beam(frame, joint, tip, 0.13, bark)
		for cluster in range(clusters):
			var offset := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-0.6, 0.75), _rng.randf_range(-1.0, 1.0))
			var basis := Basis.from_euler(Vector3(_rng.randf_range(-0.5, 0.5), _rng.randf_range(0, TAU), _rng.randf_range(-0.5, 0.5)))
			basis = basis.scaled(Vector3.ONE * _rng.randf_range(1.5, 2.2))
			var light: float = _rng.randf_range(0.06, 0.6) if mango else _rng.randf_range(0.25, 0.95)
			var shade := Color(light, light, maxf(light, 0.1))
			if flamboyant and _rng.randf() < 0.5:
				shade = Color(_rng.randf_range(0.35, 0.9), 1.0, 0.0)
			_batch(_leaf_mesh, Materials.foliage(), frame * Transform3D(basis, tip + offset), shade)

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
## `bloom` turns it into bougainvillea spilling over a wall.
func shrub(center: Vector3, size: float, bloom: bool = false) -> void:
	for i in range(3 + int(size * 3.0)):
		var angle: float = i * 2.39996 + _rng.randf() * 0.6
		var r: float = _rng.randf_range(0.0, 0.45) * size
		var at := center + Vector3(cos(angle) * r, _rng.randf_range(0.22, 0.5) * size, sin(angle) * r)
		var basis := Basis.from_euler(Vector3(_rng.randf_range(-0.4, 0.4), _rng.randf_range(0, TAU), _rng.randf_range(-0.4, 0.4)))
		basis = basis.scaled(Vector3(1.4, 1.0, 1.4) * size * _rng.randf_range(0.9, 1.3))
		var light: float = _rng.randf_range(0.1, 0.75)
		var shade := Color(light, light, maxf(light, 0.1))
		if bloom and i % 3 != 0:
			shade = Color(_rng.randf_range(0.3, 0.8), 0.0, 0.0)
		_batch(_leaf_mesh, Materials.foliage(), Transform3D(basis, at), shade)

## Plantain or banana clump: a few stout pseudo-stems under huge paddle leaves.
func banana(center: Vector3) -> void:
	var stem := Materials.solid(Color("7b8443"), 0.0, 0.8)
	for i in range(_rng.randi_range(3, 5)):
		var angle: float = i * 2.1 + _rng.randf()
		var base := center + Vector3(cos(angle), 0, sin(angle)) * _rng.randf_range(0.15, 0.6)
		var h: float = _rng.randf_range(1.6, 2.8)
		_beam(Transform3D.IDENTITY, base, base + Vector3(0, h, 0), 0.2, stem)
		var basis := Basis.from_euler(Vector3(0, _rng.randf_range(0, TAU), 0)).scaled(Vector3(2.6, 3.4, 2.6))
		var light: float = _rng.randf_range(0.55, 1.0)
		_batch(_leaf_mesh, Materials.foliage(), Transform3D(basis, base + Vector3(0, h + 0.3, 0)), Color(light, light, light))

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
			_batch(_leaf_mesh, Materials.foliage(), frame * Transform3D(basis, Vector3(x, 0.12 + tall * 0.42, z)), Color(light, light, maxf(light, 0.1)))
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
		if batch["mesh"] == _leaf_mesh or batch["mesh"] in _palm_crowns or batch["background"]:
			continue
		var bounds: AABB = (batch["mesh"] as Mesh).get_aabb()
		for transform: Transform3D in batch["transforms"]:
			var box: AABB = transform * bounds
			if box.size.x < 0.12 and box.size.z < 0.12:
				continue
			rects.append(Rect2(box.position.x, box.position.z, box.size.x, box.size.z))
	return rects

## Crown of arching coconut fronds: a rachis with leaflets hanging to both sides.
func _make_palm_crown(variant: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 9100 + variant
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var fronds: int = 15 + variant
	for frond in range(fronds):
		var angle: float = frond * TAU / fronds + rng.randf_range(-0.2, 0.2)
		var radial := Vector3(cos(angle), 0, sin(angle))
		var lateral := Vector3(-sin(angle), 0, cos(angle))
		var length: float = rng.randf_range(2.7, 3.7)
		var lift: float = rng.randf_range(-0.25, 0.95)
		var points: Array[Vector3] = []
		var widths: Array[float] = []
		for i in range(13):
			var t: float = i / 12.0
			points.append(radial * (0.25 + length * t) + Vector3.UP * length * (lift * t - 0.95 * t * t))
			widths.append((sin(t * PI) * 0.8 + 0.1) * 0.62)
		for i in range(12):
			var shade := Color(0.45 + (i % 2) * 0.25 + rng.randf() * 0.2, 1, 1)
			for side in [-1.0, 1.0]:
				var hang0: Vector3 = lateral * side * widths[i] - Vector3.UP * widths[i] * 0.55
				var hang1: Vector3 = lateral * side * widths[i + 1] - Vector3.UP * widths[i + 1] * 0.55
				_triangle(st, points[i], points[i] + hang0, points[i + 1], shade)
				_triangle(st, points[i + 1], points[i] + hang0, points[i + 1] + hang1, shade)
	return st.commit()

func _palm(frame: Transform3D, h: float, bark: Material) -> void:
	var previous := Vector3.ZERO
	var bend: float = _rng.randf_range(0.5, 1.6)
	for segment in range(8):
		var t: float = (segment + 1) / 8.0
		var next := Vector3(bend * t * t, h * t, 0.2 * sin(t * PI))
		_beam(frame, previous, next, 0.4 - t * 0.14, bark)
		previous = next
	var light: float = _rng.randf_range(0.5, 0.9)
	var crown: Mesh = _palm_crowns[_tree_count % _palm_crowns.size()]
	_batch(crown, Materials.foliage(), frame * Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), previous), Color(light, light, light))
	_detail = true
	var husk := Materials.solid(Color("6f7f2e"), 0.0, 0.7)
	for nut in range(4):
		_ball(frame, previous + Vector3(cos(nut * 1.7) * 0.3, -0.3, sin(nut * 1.7) * 0.3), Vector3.ONE * 0.3, husk)
	_detail = false

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
	_water_tank(shop, Vector3(-0.55 * s, sh + 0.1, -1.5), 0.7)
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
			if absf(x) < 32.0 or absf(z) < 32.0 or maxf(absf(x),absf(z)) < 100.0 or Vector2(x,z).length() > 270.0:
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
