extends Node3D
## Procedurally generates Accra-style buildings, shops, compound walls,
## and market stalls along all road arms of the single junction.
##
## All geometry is CSG-based — no imported models or textures.
## Built once in _ready() with seeded RNG for deterministic placement.
##
## Placement zone:
##   [Grass] [Buildings] [Sidewalk] [Road] [Sidewalk] [Buildings] [Grass]

# ── Road geometry (must match Intersection.gd) ──────────────────────────────
const ROAD_LENGTH     := 90.0
const NS_ROAD_WIDTH   := 6.4
const E_ROAD_WIDTH    := 6.4
const W_ROAD_WIDTH    := 6.4
const JUNCTION_SIZE   := 7.0
const JUNCTION_HALF   := 3.5
const SIDEWALK_WIDTH  := 1.5
const ROAD_THICKNESS  := 0.1

# ── Building generation parameters ──────────────────────────────────────────
const BUILDING_OFFSET := 0.5     # Gap between sidewalk edge and first building
const MIN_GAP         := 0.3     # Minimum gap between buildings
const MAX_GAP         := 1.5     # Maximum gap between buildings
const JUNCTION_MARGIN := 3.0     # Don't place buildings too close to junction
const ROAD_END_MARGIN := 5.0     # Don't place buildings at road edge

# ── Accra facade palette ────────────────────────────────────────────────────
const FACADE_COLORS: Array = [
	Color(0.85, 0.72, 0.45),   # Ochre
	Color(0.92, 0.88, 0.78),   # Cream
	Color(0.78, 0.52, 0.38),   # Terracotta
	Color(0.65, 0.78, 0.88),   # Pale blue
	Color(0.68, 0.82, 0.62),   # Light green
	Color(0.88, 0.72, 0.75),   # Pink
	Color(0.92, 0.92, 0.90),   # White
	Color(0.72, 0.70, 0.68),   # Warm gray
]

const AWNING_COLORS: Array = [
	Color(0.85, 0.15, 0.12),   # Red
	Color(0.15, 0.60, 0.25),   # Green
	Color(0.18, 0.35, 0.75),   # Blue
	Color(0.90, 0.78, 0.10),   # Yellow
	Color(0.90, 0.50, 0.12),   # Orange
]

const WALL_COLORS: Array = [
	Color(0.88, 0.85, 0.78),   # Cream wall
	Color(0.75, 0.72, 0.68),   # Gray wall
	Color(0.82, 0.78, 0.72),   # Sandy wall
]

const CANOPY_COLORS: Array = [
	Color(0.85, 0.20, 0.15),   # Red canopy
	Color(0.12, 0.55, 0.30),   # Green canopy
	Color(0.20, 0.40, 0.80),   # Blue canopy
	Color(0.90, 0.80, 0.15),   # Yellow canopy
	Color(0.85, 0.45, 0.10),   # Orange canopy
	Color(0.70, 0.25, 0.60),   # Purple canopy
]

# ── Shared materials (created once) ─────────────────────────────────────────
var _materials: Dictionary = {}   # Color hash → StandardMaterial3D

# ── RNG ─────────────────────────────────────────────────────────────────────
var _rng: RandomNumberGenerator


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = 42  # Deterministic placement

	# Build along each of the 4 road arms
	# Direction vectors: which axis the road runs along, and the perpendicular offset axis
	# format: [arm_name, road_axis (0=X, 1=Z), sign (+1/-1), road_width]
	var arms: Array = [
		["north", 1,  1.0, NS_ROAD_WIDTH],
		["south", 1, -1.0, NS_ROAD_WIDTH],
		["east",  0, -1.0, E_ROAD_WIDTH],   # Negated because Godot X is mirrored
		["west",  0,  1.0, W_ROAD_WIDTH],
	]

	for arm in arms:
		var arm_name: String = arm[0]
		var axis: int = arm[1]
		var sign: float = arm[2]
		var road_w: float = arm[3]
		_build_arm_buildings(arm_name, axis, sign, road_w)

	# Build junction corner anchor buildings
	_build_junction_corners()

	print("[EnvironmentBuilder] Built Accra streetscape")


# ═════════════════════════════════════════════════════════════════════════════
# ARM BUILDING GENERATION
# ═════════════════════════════════════════════════════════════════════════════

func _build_arm_buildings(arm_name: String, axis: int, sign: float,
						  road_width: float) -> void:
	## Generate buildings along both sides of a road arm.
	var sidewalk_edge: float = road_width / 2.0 + SIDEWALK_WIDTH
	var build_start: float = JUNCTION_HALF + JUNCTION_MARGIN
	var build_end: float = JUNCTION_HALF + ROAD_LENGTH - ROAD_END_MARGIN

	# Both sides of the road: +perp and -perp
	for side_sign in [-1.0, 1.0]:
		var perp_offset: float = side_sign * (sidewalk_edge + BUILDING_OFFSET)
		var cursor: float = build_start

		while cursor < build_end:
			# Choose building type with weighted random
			var roll: float = _rng.randf()
			var building_length: float

			if roll < 0.45:
				building_length = _place_block_building(axis, sign, cursor, perp_offset, side_sign)
			elif roll < 0.75:
				building_length = _place_shop_front(axis, sign, cursor, perp_offset, side_sign)
			elif roll < 0.85:
				building_length = _place_compound_wall(axis, sign, cursor, perp_offset, side_sign)
			else:
				building_length = _place_market_stalls(axis, sign, cursor, perp_offset, side_sign)

			cursor += building_length + _rng.randf_range(MIN_GAP, MAX_GAP)


# ═════════════════════════════════════════════════════════════════════════════
# BUILDING TYPES
# ═════════════════════════════════════════════════════════════════════════════

func _place_block_building(axis: int, sign: float, along: float,
						   perp: float, side_sign: float) -> float:
	## Place a simple block building with roof parapet. Returns building length.
	var width: float = _rng.randf_range(2.5, 5.0)
	var depth: float = _rng.randf_range(2.5, 4.0)
	var height: float = _rng.randf_range(1.8, 5.0)
	var facade_color: Color = FACADE_COLORS[_rng.randi() % FACADE_COLORS.size()]

	var pos := _compute_position(axis, sign, along + width / 2.0, perp, side_sign, depth)

	# Body
	var body := CSGBox3D.new()
	body.size = _orient_size(axis, width, height, depth)
	body.position = pos + Vector3(0, height / 2.0, 0)
	body.material = _get_material(facade_color)
	body.name = "BlockBody"
	add_child(body)

	# Roof parapet (slightly wider, darker)
	var parapet := CSGBox3D.new()
	parapet.size = _orient_size(axis, width + 0.1, 0.15, depth + 0.1)
	parapet.position = pos + Vector3(0, height + 0.075, 0)
	parapet.material = _get_material(facade_color * 0.7)
	parapet.name = "BlockParapet"
	add_child(parapet)

	return width


func _place_shop_front(axis: int, sign: float, along: float,
					   perp: float, side_sign: float) -> float:
	## Place a shop with awning. Returns building length.
	var width: float = _rng.randf_range(2.0, 4.0)
	var depth: float = _rng.randf_range(2.0, 3.5)
	var height: float = _rng.randf_range(1.5, 3.0)
	var facade_color: Color = FACADE_COLORS[_rng.randi() % FACADE_COLORS.size()]
	var awning_color: Color = AWNING_COLORS[_rng.randi() % AWNING_COLORS.size()]

	var pos := _compute_position(axis, sign, along + width / 2.0, perp, side_sign, depth)

	# Building body
	var body := CSGBox3D.new()
	body.size = _orient_size(axis, width, height, depth)
	body.position = pos + Vector3(0, height / 2.0, 0)
	body.material = _get_material(facade_color)
	body.name = "ShopBody"
	add_child(body)

	# Awning — extends toward the road
	var awning := CSGBox3D.new()
	var awning_depth: float = 1.2
	awning.size = _orient_size(axis, width - 0.2, 0.06, awning_depth)
	# Position awning toward the road side (negative side_sign direction)
	var awning_offset: Vector3
	if axis == 0:  # E/W road: perpendicular is Z
		awning_offset = Vector3(0, height * 0.6, -side_sign * (depth / 2.0 + awning_depth / 2.0 - 0.2))
	else:  # N/S road: perpendicular is X
		awning_offset = Vector3(-side_sign * (depth / 2.0 + awning_depth / 2.0 - 0.2), height * 0.6, 0)
	awning.position = pos + awning_offset
	awning.material = _get_material(awning_color)
	awning.name = "ShopAwning"
	add_child(awning)

	# Awning support pillar
	var pillar := CSGCylinder3D.new()
	pillar.radius = 0.04
	pillar.height = height * 0.6
	var pillar_offset: Vector3
	if axis == 0:
		pillar_offset = Vector3(0, height * 0.3, -side_sign * (depth / 2.0 + awning_depth - 0.4))
	else:
		pillar_offset = Vector3(-side_sign * (depth / 2.0 + awning_depth - 0.4), height * 0.3, 0)
	pillar.position = pos + pillar_offset
	pillar.material = _get_material(Color(0.3, 0.3, 0.32))
	pillar.name = "ShopPillar"
	add_child(pillar)

	return width


func _place_compound_wall(axis: int, sign: float, along: float,
						  perp: float, side_sign: float) -> float:
	## Place a low compound wall. Returns wall length.
	var width: float = _rng.randf_range(4.0, 8.0)
	var height: float = _rng.randf_range(0.6, 0.9)
	var depth: float = 0.2
	var wall_color: Color = WALL_COLORS[_rng.randi() % WALL_COLORS.size()]

	var pos := _compute_position(axis, sign, along + width / 2.0, perp, side_sign, depth)

	var wall := CSGBox3D.new()
	wall.size = _orient_size(axis, width, height, depth)
	wall.position = pos + Vector3(0, height / 2.0, 0)
	wall.material = _get_material(wall_color)
	wall.name = "CompoundWall"
	add_child(wall)

	return width


func _place_market_stalls(axis: int, sign: float, along: float,
						  perp: float, side_sign: float) -> float:
	## Place a cluster of 3-5 small market stalls. Returns cluster length.
	var stall_count: int = _rng.randi_range(3, 5)
	var total_width: float = 0.0

	for i in range(stall_count):
		var sw: float = _rng.randf_range(0.8, 1.4)
		var sd: float = _rng.randf_range(0.8, 1.2)
		var sh: float = _rng.randf_range(1.0, 1.6)
		var canopy_color: Color = CANOPY_COLORS[_rng.randi() % CANOPY_COLORS.size()]

		var pos := _compute_position(axis, sign, along + total_width + sw / 2.0, perp, side_sign, sd)

		# Canopy top
		var canopy := CSGBox3D.new()
		canopy.size = _orient_size(axis, sw, 0.04, sd)
		canopy.position = pos + Vector3(0, sh, 0)
		canopy.material = _get_material(canopy_color)
		canopy.name = "StallCanopy"
		add_child(canopy)

		# Support poles (2 corners)
		for j in range(2):
			var pole := CSGCylinder3D.new()
			pole.radius = 0.025
			pole.height = sh
			var pole_along_offset: float = (sw / 2.0 - 0.1) * (1.0 if j == 0 else -1.0)
			var pole_pos: Vector3
			if axis == 1:  # N/S
				pole_pos = pos + Vector3(0, sh / 2.0, sign * pole_along_offset)
			else:  # E/W
				pole_pos = pos + Vector3(sign * pole_along_offset, sh / 2.0, 0)
			pole.position = pole_pos
			pole.material = _get_material(Color(0.3, 0.28, 0.25))
			pole.name = "StallPole"
			add_child(pole)

		total_width += sw + 0.2  # Tiny gap between stalls

	return total_width


# ═════════════════════════════════════════════════════════════════════════════
# JUNCTION CORNER BUILDINGS
# ═════════════════════════════════════════════════════════════════════════════

func _build_junction_corners() -> void:
	## Place distinctive anchor buildings at the 4 corners of the junction.
	var corner_offset: float = JUNCTION_HALF + SIDEWALK_WIDTH + BUILDING_OFFSET + 0.5
	var corners: Array = [
		Vector3(-corner_offset, 0, corner_offset),   # NW
		Vector3(corner_offset, 0, corner_offset),     # NE
		Vector3(-corner_offset, 0, -corner_offset),   # SW
		Vector3(corner_offset, 0, -corner_offset),    # SE
	]

	for i in range(corners.size()):
		var pos: Vector3 = corners[i]
		var height: float = _rng.randf_range(3.0, 5.5)
		var width: float = _rng.randf_range(3.5, 5.0)
		var depth: float = _rng.randf_range(3.0, 4.5)
		var facade_color: Color = FACADE_COLORS[_rng.randi() % FACADE_COLORS.size()]
		var awning_color: Color = AWNING_COLORS[_rng.randi() % AWNING_COLORS.size()]

		# Main building body
		var body := CSGBox3D.new()
		body.size = Vector3(width, height, depth)
		body.position = pos + Vector3(0, height / 2.0, 0)
		body.material = _get_material(facade_color)
		body.name = "CornerBody_%d" % i
		add_child(body)

		# Roof parapet
		var parapet := CSGBox3D.new()
		parapet.size = Vector3(width + 0.15, 0.2, depth + 0.15)
		parapet.position = pos + Vector3(0, height + 0.1, 0)
		parapet.material = _get_material(facade_color * 0.65)
		parapet.name = "CornerParapet_%d" % i
		add_child(parapet)

		# Awning on the road-facing side (toward junction center)
		var awning := CSGBox3D.new()
		var awning_w: float = width - 0.3
		var awning_d: float = 1.4
		awning.size = Vector3(awning_w, 0.06, awning_d)
		# Position awning toward junction center
		var dir_to_center: Vector3 = -pos.normalized()
		awning.position = pos + Vector3(0, height * 0.45, 0) + dir_to_center * (depth / 2.0 + awning_d / 2.0 - 0.3)
		awning.material = _get_material(awning_color)
		awning.name = "CornerAwning_%d" % i
		add_child(awning)


# ═════════════════════════════════════════════════════════════════════════════
# HELPERS
# ═════════════════════════════════════════════════════════════════════════════

func _compute_position(axis: int, sign: float, along: float,
					   perp: float, side_sign: float, depth: float) -> Vector3:
	## Compute world position for a building.
	## axis=0: road runs along X, perp is Z
	## axis=1: road runs along Z, perp is X
	var perp_total: float = perp + side_sign * depth / 2.0
	if axis == 1:  # N/S road
		return Vector3(perp_total, 0, sign * along)
	else:  # E/W road
		return Vector3(sign * along, 0, perp_total)


func _orient_size(axis: int, width: float, height: float, depth: float) -> Vector3:
	## Orient a box size so 'width' runs along the road and 'depth' runs perpendicular.
	if axis == 1:  # N/S road: width along Z, depth along X
		return Vector3(depth, height, width)
	else:  # E/W road: width along X, depth along Z
		return Vector3(width, height, depth)


func _get_material(color: Color) -> StandardMaterial3D:
	## Get or create a material for the given color (shared to reduce draw calls).
	var key: int = color.to_rgba32()
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.8
	_materials[key] = mat
	return mat
