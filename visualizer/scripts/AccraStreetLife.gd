extends RefCounted
## Roadside life for both scenes: traders under umbrellas, table-top sellers,
## hawkers with head pans, okada riders, hand carts, signboard clusters and the
## open drain that runs behind the footway. Everything here is batched scenery
## drawn through the streetscape kit. None of it is simulated traffic or a SUMO
## pedestrian, and nothing is placed on a carriageway or a footway.
const M = preload("res://scripts/StreetscapeMaterials.gd")
const G = preload("res://scripts/PropGeometry.gd")
const SKINS: Array[Color] = [Color("4a2f22"), Color("5d3b29"), Color("6f4731"), Color("3b261d"), Color("7d533a")]
const UMBRELLAS: Array[Color] = [Color("d43a2c"), Color("f2c318"), Color("1c63a8"), Color("2a9a55"),
	Color("f4f1e6"), Color("f08a1c")]
# Illustrative direction boards: churches, schools, clinics and guest houses.
const BOARDS: Array[String] = [
	"CHRIST THE KING\nInt. School", "GLORY CHAPEL\nInternational", "AKWAABA\nGuest House",
	"ADOM\nHerbal Centre", "ROYAL PALM\nHotel", "WINNERS\nPreparatory School",
	"LIVING WATERS\nMinistries", "PLOT FOR SALE\nSee Caretaker", "NANA YAW\nBorehole Drilling",
	"ABLE\nDriving School", "HOUSE OF PRAYER\nAssembly", "COMFORT\nMaternity Home",
	"GOOD SHEPHERD\nMontessori", "DABEN\nPhotocopy & Typing"]
# Distance behind the footway: lamp columns and poles stand first, then the drain.
const DRAIN_OFFSET := 2.35
const DRAIN_WIDTH := 0.8
var kit: Node3D
var rng := RandomNumberGenerator.new()
var counts: Dictionary = {}

func _init(streetscape: Node3D, seed_value: int = 5150) -> void:
	kit = streetscape
	rng.seed = seed_value

func _count(kind: String) -> void:
	counts[kind] = int(counts.get(kind, 0)) + 1

func _cloth() -> Color:
	return kit.CLOTH[rng.randi_range(0, kit.CLOTH.size() - 1)]

## Standing or seated figure in bright cloth. `load` 1 carries a head pan.
func person(at: Vector3, yaw: float, seated: bool = false, load: int = 0, stool: bool = true) -> void:
	_count("people")
	var f := Transform3D(Basis(Vector3.UP, yaw), at)
	var skin := M.solid(SKINS[rng.randi_range(0, SKINS.size() - 1)], 0.0, 0.7)
	var woman: bool = rng.randf() < 0.6
	var top := M.solid(_cloth(), 0.0, 0.85)
	var lower := M.solid(_cloth() if woman else [Color("23282d"), Color("3b3a36"), Color("2c3b52"), Color("5a5142")][rng.randi_range(0, 3)], 0.0, 0.9)
	var hip: float = 0.5 if seated else 0.88
	kit._detail = true
	if seated:
		if stool:
			kit._box(f, Vector3(0, 0.22, -0.06), Vector3(0.34, 0.44, 0.34), M.surface(6, Color("6a5638")))
		for side in [-1.0, 1.0]:
			kit._beam(f, Vector3(side * 0.1, hip, 0.42), Vector3(side * 0.1, hip, -0.05), 0.2, lower)
			kit._beam(f, Vector3(side * 0.1, 0.04, 0.44), Vector3(side * 0.1, hip + 0.04, 0.42), 0.15, skin if woman else lower)
	elif woman:
		kit._beam(f, Vector3(0, hip + 0.04, 0), Vector3(0, 0.1, 0), 0.38, lower)
	else:
		for side in [-1.0, 1.0]:
			kit._beam(f, Vector3(side * 0.1, 0.03, 0), Vector3(side * 0.09, hip + 0.05, 0), 0.19, lower)
	# Flattened trunk, broader at the shoulders, rounded off at each shoulder.
	kit._batch(kit._cylinder_mesh, top, f * Transform3D(Basis(Vector3.FORWARD, PI) * Basis.from_scale(Vector3(0.46, 0.56, 0.27)), Vector3(0, hip + 0.28, 0)))
	for side in [-1.0, 1.0]:
		kit._ball(f, Vector3(side * 0.19, hip + 0.51, 0), Vector3(0.16, 0.14, 0.2), top)
	for side in [-1.0, 1.0]:
		var hand := Vector3(side * 0.2, hip + 0.1, 0.3) if seated else Vector3(side * 0.26, hip - 0.04, 0.05)
		kit._beam(f, hand, Vector3(side * 0.21, hip + 0.52, 0), 0.1, skin if woman else top)
	kit._beam(f, Vector3(0, hip + 0.55, 0), Vector3(0, hip + 0.66, 0), 0.11, skin)
	kit._ball(f, Vector3(0, hip + 0.74, 0), Vector3(0.21, 0.25, 0.23), skin)
	if woman and rng.randf() < 0.6:
		kit._ball(f, Vector3(0, hip + 0.83, -0.02), Vector3(0.27, 0.2, 0.28), M.solid(_cloth(), 0.0, 0.9))
	else:
		kit._ball(f, Vector3(0, hip + 0.82, -0.02), Vector3(0.22, 0.14, 0.23), M.solid(Color("17130f"), 0.0, 0.9))
	if load == 1 and not seated:
		kit._drum(f, Vector3(0, hip + 0.89, 0), 0.56, 0.14, M.solid(Color("c3c5c0"), 0.6, 0.4))
		var goods := M.solid([Color("e88d1c"), Color("e9c62c"), Color("bcd9e6"), Color("5d8a2e"), Color("c8371f")][rng.randi_range(0, 4)], 0.0, 0.7)
		for i in range(5):
			kit._ball(f, Vector3(cos(i * 1.26) * 0.14, hip + 1.07, sin(i * 1.26) * 0.14), Vector3.ONE * 0.19, goods)
	kit._detail = false

## Trader's umbrella on a concrete-filled tyre, one bold colour under a white cap.
func umbrella(at: Vector3) -> void:
	_count("umbrellas")
	var f := Transform3D(Basis(Vector3(1, 0, 0.4).normalized(), rng.randf_range(-0.08, 0.08)), at)
	var color: Color = UMBRELLAS[rng.randi_range(0, UMBRELLAS.size() - 1)]
	var r: float = rng.randf_range(1.15, 1.5)
	kit._drum(f, Vector3.ZERO, 0.6, 0.2, M.solid(Color("161616"), 0.0, 0.9))
	kit._beam(f, Vector3.ZERO, Vector3(0, 2.3, 0), 0.055, M.solid(Color("b9bbb6"), 0.6, 0.4))
	kit._batch(kit._cone_mesh, M.solid(color, 0.0, 0.8), f * Transform3D(Basis.from_scale(Vector3(r * 2.0, 0.5, r * 2.0)), Vector3(0, 2.3, 0)))
	var cap: Color = Color("f4f1e6") if color.get_luminance() < 0.7 else Color("d43a2c")
	kit._batch(kit._cone_mesh, M.solid(cap, 0.0, 0.8), f * Transform3D(Basis.from_scale(Vector3(r * 0.9, 0.24, r * 0.9)), Vector3(0, 2.46, 0)))

## Trading table with one of the things sold at an Accra roadside.
func table(at: Vector3, yaw: float, kind: int = -1) -> void:
	_count("tables")
	var f := Transform3D(Basis(Vector3.UP, yaw), at)
	var wood := M.surface(6, Color("7c6746"))
	kit._box(f, Vector3(0, 0.76, 0), Vector3(1.5, 0.06, 0.75), wood)
	kit._detail = true
	for x in [-0.68, 0.68]:
		kit._box(f, Vector3(x, 0.37, 0), Vector3(0.07, 0.74, 0.66), M.surface(6, Color("6a5638")))
	if kind < 0:
		kind = rng.randi_range(0, 7)
	match kind:
		0:  # Oranges and tomatoes in pyramids.
			for i in range(8):
				var fruit := M.solid(Color("e88d1c") if i < 4 else Color("c8371f"), 0.0, 0.6)
				kit._ball(f, Vector3(-0.56 + i * 0.16, 0.88, rng.randf_range(-0.12, 0.12)), Vector3(0.24, 0.2, 0.24), fruit)
		1:  # Tea bread and butter bread in a glass-sided box.
			kit._box(f, Vector3(0, 1.02, 0), Vector3(1.2, 0.46, 0.55), M.solid(Color("cfe0e4"), 0.2, 0.2))
			for i in range(5):
				kit._box(f, Vector3(-0.44 + i * 0.22, 0.92, 0.02), Vector3(0.18, 0.2, 0.42), M.solid(Color("c98f4a"), 0.0, 0.8))
		2:  # Phone accessories and airtime.
			for i in range(10):
				kit._box(f, Vector3(-0.6 + (i % 5) * 0.3, 0.84, -0.16 + (i / 5) * 0.32), Vector3(0.24, 0.1, 0.24), M.solid(_cloth(), 0.0, 0.6))
		3:  # Plantain bunches.
			for i in range(7):
				kit._ball(f, Vector3(-0.54 + i * 0.18, 0.9, rng.randf_range(-0.15, 0.15)), Vector3(0.16, 0.2, 0.52),
					M.solid(Color("7a9a2e") if i % 3 else Color("e9c62c"), 0.0, 0.7))
		4:  # Second-hand clothes in a heap.
			for i in range(9):
				kit._box(f, Vector3(rng.randf_range(-0.55, 0.55), 0.84 + i * 0.03, rng.randf_range(-0.22, 0.22)),
					Vector3(0.5, 0.1, 0.36), M.solid(_cloth(), 0.0, 0.95))
		5:  # Kenkey and fried fish from big aluminium pots.
			for i in range(2):
				kit._drum(f, Vector3(-0.38 + i * 0.76, 0.79, 0), 0.52, 0.34, M.solid(Color("c3c5c0"), 0.7, 0.35))
			kit._drum(f, Vector3(0, 0.79, 0.12), 0.34, 0.1, M.solid(Color("1c63a8"), 0.0, 0.5))
		6:  # Shoes and sandals in rows.
			for i in range(12):
				kit._box(f, Vector3(-0.6 + (i % 6) * 0.24, 0.82, -0.15 + (i / 6) * 0.3), Vector3(0.11, 0.07, 0.26),
					M.solid([Color("16181a"), Color("6a4630"), Color("f4f1e6"), Color("c62f25")][i % 4], 0.0, 0.6))
		_:  # Sachet water, soft drinks and an ice chest.
			kit._box(f, Vector3(-0.35, 0.99, 0), Vector3(0.62, 0.4, 0.42), M.solid(Color("1c63a8"), 0.0, 0.5))
			for i in range(6):
				kit._drum(f, Vector3(0.12 + (i % 3) * 0.17, 0.79, -0.1 + (i / 3) * 0.2), 0.09, 0.24, M.solid(_cloth(), 0.1, 0.4))
	kit._detail = false

## Umbrella, table, the trader on a stool behind it and sometimes a customer.
func vendor(at: Vector3, yaw: float, kind: int = -1) -> void:
	_count("vendors")
	var f := Transform3D(Basis(Vector3.UP, yaw), at)
	umbrella(f * Vector3(rng.randf_range(-0.4, 0.4), 0, -0.55))
	table(at, yaw, kind)
	person(f * Vector3(rng.randf_range(-0.3, 0.3), 0, -0.85), yaw, true)
	# A rechargeable lamp hung under the umbrella: the trader's light after dark.
	kit._ball(f, Vector3(0.1, 1.9, -0.45), Vector3(0.16, 0.2, 0.16), kit._warm)
	if rng.randf() < 0.35:
		person(f * Vector3(rng.randf_range(-0.5, 0.5), 0, 0.85), yaw + PI + rng.randf_range(-0.4, 0.4))
	if rng.randf() < 0.4:
		kit._detail = true
		kit._drum(f, Vector3(1.05, 0, -0.2), 0.5, 0.3, M.solid([Color("1c63a8"), Color("d43a2c"), Color("2a9a55")][rng.randi_range(0, 2)], 0.0, 0.45))
		kit._detail = false

## Heap of produce on a mat on the ground with its seller: yam, watermelon,
## coconut or charcoal.
func ground_heap(at: Vector3, yaw: float) -> void:
	_count("heaps")
	var f := Transform3D(Basis(Vector3.UP, yaw), at)
	var kind: int = rng.randi_range(0, 3)
	kit._box(f, Vector3(0, 0.02, 0), Vector3(1.9, 0.03, 1.3), M.solid(Color("8e7a52") if kind != 3 else Color("3a3a38"), 0.0, 0.95))
	kit._detail = true
	for i in range(14):
		var spot := Vector3(rng.randf_range(-0.7, 0.7), 0.14 + (i % 3) * 0.12, rng.randf_range(-0.4, 0.4))
		match kind:
			0: kit._ball(f, spot, Vector3(0.2, 0.2, 0.55), M.solid(Color("6b4a2f"), 0.0, 0.9))
			1: kit._ball(f, spot + Vector3(0, 0.05, 0), Vector3(0.36, 0.3, 0.44), M.solid(Color("2f6b2a"), 0.0, 0.5))
			2: kit._ball(f, spot, Vector3.ONE * 0.26, M.solid(Color("7a8f35"), 0.0, 0.6))
			_: kit._box(f, Vector3(spot.x * 0.8, 0.2 + (i % 2) * 0.36, spot.z), Vector3(0.5, 0.34, 0.36), M.solid(Color("d8d2c0"), 0.0, 0.9))
	kit._detail = false
	person(f * Vector3(0, 0, -0.95), yaw, true)

func _wheel(f: Transform3D, at: Vector3, diameter: float, width: float) -> void:
	var basis := Basis(Vector3.FORWARD, PI * 0.5) * Basis.from_scale(Vector3(diameter, width, diameter))
	kit._batch(kit._tube_mesh, M.solid(Color("151515"), 0.0, 0.9), f * Transform3D(basis, at))

## Okada: the motorbike taxi, parked on its stand or with the rider waiting.
func okada(at: Vector3, yaw: float, rider: bool = false) -> void:
	_count("okadas")
	var f := Transform3D(Basis(Vector3.UP, yaw), at)
	var paint := M.solid([Color("c62f25"), Color("1c63a8"), Color("16181a"), Color("f08a1c")][rng.randi_range(0, 3)], 0.4, 0.4)
	_wheel(f, Vector3(0, 0.3, 0.68), 0.6, 0.1)
	_wheel(f, Vector3(0, 0.3, -0.62), 0.6, 0.12)
	kit._detail = true
	kit._box(f, Vector3(0, 0.5, 0), Vector3(0.22, 0.3, 0.9), M.solid(Color("3b3f41"), 0.7, 0.45))
	kit._ball(f, Vector3(0, 0.78, 0.22), Vector3(0.3, 0.26, 0.5), paint)
	kit._box(f, Vector3(0, 0.8, -0.3), Vector3(0.28, 0.1, 0.66), M.solid(Color("17130f"), 0.0, 0.8))
	kit._beam(f, Vector3(0, 0.34, 0.68), Vector3(0, 1.02, 0.42), 0.06, M.solid(Color("b9bbb6"), 0.7, 0.35))
	kit._box(f, Vector3(0, 1.04, 0.42), Vector3(0.66, 0.04, 0.05), M.solid(Color("2c3033"), 0.6, 0.4))
	kit._box(f, Vector3(0, 0.62, -0.72), Vector3(0.2, 0.05, 0.3), paint)
	kit._detail = false
	if rider:
		person(f * Vector3(0, 0.36, -0.2), yaw, true, 0, false)

## Four-wheeled hand truck piled with sacks, water or scrap, and its pusher.
func handcart(at: Vector3, yaw: float) -> void:
	_count("carts")
	var f := Transform3D(Basis(Vector3.UP, yaw), at)
	var wood := M.surface(6, Color("6a5638"))
	kit._box(f, Vector3(0, 0.5, 0), Vector3(1.1, 0.08, 1.9), wood)
	for x in [-0.5, 0.5]:
		for z in [-0.6, 0.6]:
			_wheel(f, Vector3(x, 0.26, z), 0.52, 0.14)
	kit._detail = true
	kit._beam(f, Vector3(-0.45, 0.54, -0.95), Vector3(-0.45, 1.0, -1.5), 0.05, wood)
	kit._beam(f, Vector3(0.45, 0.54, -0.95), Vector3(0.45, 1.0, -1.5), 0.05, wood)
	kit._beam(f, Vector3(-0.45, 1.0, -1.5), Vector3(0.45, 1.0, -1.5), 0.05, wood)
	var kind: int = rng.randi_range(0, 2)
	for i in range(8):
		var spot := Vector3((i % 2) * 0.5 - 0.25, 0.66 + (i / 4) * 0.22, -0.55 + ((i / 2) % 2) * 0.9)
		if kind == 0:
			kit._box(f, spot, Vector3(0.48, 0.2, 0.8), M.solid(Color("e9e2cf") if i % 3 else Color("d8c79c"), 0.0, 0.9))
		elif kind == 1:
			kit._box(f, spot, Vector3(0.46, 0.2, 0.7), M.solid(Color("bcd9e6"), 0.0, 0.35))
		else:
			kit._drum(f, spot - Vector3(0, 0.1, 0), 0.4, 0.34, M.solid([Color("f2c318"), Color("1c63a8")][i % 2], 0.0, 0.5))
	kit._detail = false
	if rng.randf() < 0.7:
		person(f * Vector3(0, 0, -1.9), yaw)

## One painted direction board on a pipe post, lettered on the side it faces.
func signpost(at: Vector3, yaw: float, text: String, color: Color, height: float = 2.6, w: float = 1.5) -> void:
	_count("signposts")
	var f := Transform3D(Basis(Vector3.UP, yaw), at)
	for x in [-w * 0.32, w * 0.32]:
		kit._beam(f, Vector3(x, 0, 0), Vector3(x, height + 0.3, 0), 0.06, M.solid(Color("4a4f50"), 0.5, 0.6))
	kit._box(f, Vector3(0, height, 0), Vector3(w, 0.7, 0.08), M.solid(color, 0.0, 0.65))
	var ink := Color("f6f2e6") if color.get_luminance() < 0.45 else Color("123a73")
	# Lettered on both faces: traffic passes it in both directions.
	for face in [0.0, PI]:
		var label := G.label(kit, text, Vector3.ZERO, w - 0.16, 0.56, ink, "DirectionBoard")
		label.transform = f * Transform3D(Basis(Vector3.UP, face), Vector3(0, height, 0.044 if face == 0.0 else -0.044))
		label.visibility_range_end = 55.0

## The thicket of boards at a street mouth: churches, schools, clinics, plots.
func sign_cluster(at: Vector3, yaw: float, count: int = 4) -> void:
	_count("sign_clusters")
	var f := Transform3D(Basis(Vector3.UP, yaw), at)
	var start: int = rng.randi_range(0, BOARDS.size() - 1)
	for i in range(count):
		var color: Color = [Color("f4f1e6"), Color("1c63a8"), Color("f2c318"), Color("1c7a45"), Color("c62f25")][(start + i) % 5]
		signpost(f * Vector3(i * 0.55 - count * 0.28, 0, (i % 2) * 0.7), yaw + rng.randf_range(-0.12, 0.12),
			BOARDS[(start + i) % BOARDS.size()], color, 2.0 + (i % 3) * 0.75 + rng.randf() * 0.2, rng.randf_range(1.25, 1.7))

## Open concrete drain from `a` to `b`, with a slab crossing at each distance in
## `bridges` (metres from `a`) and a few more at random.
func drain(a: Vector3, b: Vector3, bridges: Array = [], covered: bool = false) -> void:
	var length: float = a.distance_to(b)
	if length < 2.0:
		return
	_count("drains")
	var f := Transform3D(Basis(Vector3.UP, atan2(b.x - a.x, b.z - a.z)), (a + b) * 0.5)
	var concrete := M.surface(2, Color("9f9a8e"))
	if covered:
		# Paved districts: the same drain under a continuous run of cover slabs,
		# with an open inspection gap now and then.
		kit._box(f, Vector3(0, 0.05, 0), Vector3(DRAIN_WIDTH + 0.2, 0.1, length), M.surface(2, Color("aaa69a")))
		var gap: float = rng.randf_range(12.0, 20.0)
		while gap < length - 2.0:
			kit._box(f, Vector3(0, 0.102, gap - length * 0.5), Vector3(DRAIN_WIDTH - 0.25, 0.01, 0.5), M.solid(Color("1a1f19"), 0.0, 0.9))
			gap += rng.randf_range(16.0, 28.0)
		return
	kit._box(f, Vector3(0, 0.03, 0), Vector3(DRAIN_WIDTH - 0.2, 0.05, length), M.solid(Color("1a1f19"), 0.0, 0.9))
	for side in [-1.0, 1.0]:
		kit._box(f, Vector3(side * (DRAIN_WIDTH * 0.5 - 0.06), 0.09, 0), Vector3(0.14, 0.2, length), concrete)
	var spots: Array = bridges.duplicate()
	var cursor: float = rng.randf_range(4.0, 9.0)
	while cursor < length - 2.0:
		spots.append(cursor)
		cursor += rng.randf_range(9.0, 17.0)
	for spot in spots:
		var along: float = clampf(float(spot), 0.9, length - 0.9) - length * 0.5
		kit._box(f, Vector3(0, 0.2, along), Vector3(DRAIN_WIDTH + 0.5, 0.08, rng.randf_range(1.2, 2.4)), M.surface(2, Color("aaa69a")))

## Trading apron in front of one roadside premises. `front` is the middle of the
## shop front at ground level, `facing` points at the road, and `setback` is the
## distance from the shop front to the back of the footway. The last `service`
## metres before the footway belong to lamps, poles and the drain.
## Concrete planter with shrubs, as set out along the paved frontages.
func planter(at: Vector3, yaw: float) -> void:
	_count("planters")
	var f := Transform3D(Basis(Vector3.UP, yaw), at)
	kit._box(f, Vector3(0, 0.25, 0), Vector3(2.0, 0.5, 0.8), M.surface(2, Color("b3ada0")))
	kit._box(f, Vector3(0, 0.5, 0), Vector3(1.8, 0.04, 0.6), M.solid(Color("4a4034"), 0.0, 0.95))
	for i in range(3):
		kit.shrub(f * Vector3(i * 0.6 - 0.6, 0.35, 0), 0.55, i == 1 and rng.randf() < 0.5)

func frontage(front: Vector3, facing: Vector3, width: float, setback: float, kind: String, service: float = 3.5, tidy: bool = false) -> void:
	var f := Transform3D(Basis(Vector3.UP, atan2(facing.x, facing.z)), front)
	var yaw: float = atan2(facing.x, facing.z)
	var near: float = 1.75
	var far: float = setback - service
	if far - near < 0.3:
		# Tight frontage: only a hawker or a board fits between drain and shop.
		if rng.randf() < 0.3:
			person(f * Vector3(rng.randf_range(-0.4, 0.4) * width, 0, minf(near, setback - 0.7)), yaw + rng.randf_range(-0.6, 0.6), false, 1)
		return
	var slots: int = maxi(1, floori(width / 4.2))
	for slot in range(slots):
		var x: float = -width * 0.5 + (slot + 0.5) * width / slots + rng.randf_range(-0.6, 0.6)
		var z: float = rng.randf_range(near, far)
		var roll: float = rng.randf()
		if kind == "police":
			continue
		if kind == "mechanic" and roll < 0.5:
			okada(f * Vector3(x, 0, z), yaw + rng.randf_range(-0.5, 0.5))
			continue
		if tidy:
			# Kept districts: a few umbrella traders and people about, planters
			# along the frontage, and none of the heaps and hand carts.
			if roll < 0.2:
				vendor(f * Vector3(x, 0, z), yaw + rng.randf_range(-0.15, 0.15))
			elif roll < 0.5:
				planter(f * Vector3(x, 0, far), yaw)
			elif roll < 0.62:
				person(f * Vector3(x, 0, z), yaw + rng.randf_range(-1.2, 1.2))
				person(f * Vector3(x + 0.7, 0, z + 0.3), yaw + PI * 0.5 + rng.randf_range(-0.6, 0.6))
			continue
		if roll < 0.34:
			vendor(f * Vector3(x, 0, z), yaw + rng.randf_range(-0.25, 0.25))
		elif roll < 0.46:
			ground_heap(f * Vector3(x, 0, z), yaw + rng.randf_range(-0.3, 0.3))
		elif roll < 0.58:
			person(f * Vector3(x, 0, z), yaw + rng.randf_range(-1.2, 1.2), false, 1)
			if rng.randf() < 0.5:
				person(f * Vector3(x + 0.7, 0, z + 0.3), yaw + PI * 0.5 + rng.randf_range(-0.6, 0.6))
		elif roll < 0.66:
			okada(f * Vector3(x, 0, z), yaw + PI * 0.5 + rng.randf_range(-0.3, 0.3), rng.randf() < 0.6)
			if rng.randf() < 0.5:
				okada(f * Vector3(x + 0.9, 0, z + 0.2), yaw + PI * 0.5 + rng.randf_range(-0.3, 0.3), false)
		elif roll < 0.72:
			handcart(f * Vector3(x, 0, z), yaw + PI * 0.5)
		elif roll < 0.8:
			table(f * Vector3(x, 0, z), yaw)
			person(f * Vector3(x, 0, z - 0.8), yaw, true)
	# A direction board at the road edge of the apron, square to passing traffic.
	if width > 6.0 and rng.randf() < 0.3:
		var edge: float = setback - service - 0.15
		signpost(f * Vector3(width * 0.5 - 0.4, 0, edge), yaw + (PI * 0.5 if rng.randf() < 0.5 else -PI * 0.5),
			BOARDS[rng.randi_range(0, BOARDS.size() - 1)], [Color("f4f1e6"), Color("1c63a8"), Color("f2c318"), Color("1c7a45")][rng.randi_range(0, 3)],
			rng.randf_range(2.4, 3.2))
