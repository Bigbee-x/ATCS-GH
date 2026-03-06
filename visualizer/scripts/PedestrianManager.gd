extends Node3D
## Visual-only ambient pedestrian system.
##
## Spawns random pedestrians walking along sidewalks for scene realism.
## Entirely client-side — no SUMO data, no server interaction.
## Pedestrians walk back and forth along predefined sidewalk paths
## at varied speeds with randomised appearances.

# ── Configuration ──────────────────────────────────────────────────────────────
const NUM_PEDESTRIANS   := 28      # Total ambient pedestrians
const MIN_SPEED         := 0.4     # Slowest walk speed (Godot units/sec)
const MAX_SPEED         := 1.2     # Fastest walk speed
const BODY_WIDTH        := 0.3     # Torso width (X)
const BODY_DEPTH        := 0.25    # Torso depth (Z)
const BODY_HEIGHT       := 0.9     # Torso height (Y)
const HEAD_RADIUS       := 0.14    # Head sphere radius
const LEG_HEIGHT        := 0.7     # Legs (lower body)
const TOTAL_HEIGHT      := 1.75    # Approximate total (legs + body + head)
const SIDEWALK_Y        := 0.15    # Matches Intersection.gd SIDEWALK_HEIGHT

# ── Road geometry (must match Intersection.gd) ────────────────────────────────
const ROAD_LENGTH       := 30.0
const NS_ROAD_WIDTH     := 6.4
const E_ROAD_WIDTH      := 6.4
const W_ROAD_WIDTH      := 3.2
const JUNCTION_SIZE     := 10.0
const SIDEWALK_WIDTH    := 1.5

# ── Appearance palettes ───────────────────────────────────────────────────────
# Shirt/top colors (bright, visible from isometric camera)
const SHIRT_COLORS: Array = [
	Color(0.85, 0.15, 0.15),   # Red
	Color(0.15, 0.45, 0.85),   # Blue
	Color(0.95, 0.75, 0.05),   # Yellow
	Color(0.20, 0.70, 0.25),   # Green
	Color(0.90, 0.45, 0.10),   # Orange
	Color(0.60, 0.20, 0.70),   # Purple
	Color(0.95, 0.95, 0.95),   # White
	Color(0.15, 0.15, 0.15),   # Black
	Color(0.80, 0.40, 0.60),   # Pink
	Color(0.10, 0.65, 0.65),   # Teal
]

# Skin tones
const SKIN_COLORS: Array = [
	Color(0.36, 0.22, 0.14),   # Dark brown
	Color(0.45, 0.30, 0.18),   # Medium brown
	Color(0.55, 0.38, 0.24),   # Light brown
	Color(0.65, 0.48, 0.32),   # Tan
	Color(0.42, 0.26, 0.16),   # Rich brown
]

# Trouser/leg colors
const LEG_COLORS: Array = [
	Color(0.15, 0.15, 0.20),   # Dark navy
	Color(0.20, 0.18, 0.15),   # Dark brown
	Color(0.10, 0.10, 0.12),   # Black
	Color(0.30, 0.28, 0.25),   # Khaki dark
	Color(0.18, 0.22, 0.30),   # Denim
]

# ── Sidewalk path definitions ─────────────────────────────────────────────────
# Each path: {start: Vector3, end: Vector3, walk_axis: String}
# Pedestrians walk from start to end and back along the walk_axis.
# Positions placed at centre of each sidewalk strip.
var _sidewalk_paths: Array = []

# ── Active pedestrians ────────────────────────────────────────────────────────
# pid → {node, path_idx, progress, speed, forward}
var _pedestrians: Array = []


# ═══════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═══════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_define_sidewalk_paths()
	_spawn_all()


func _process(delta: float) -> void:
	for ped in _pedestrians:
		_move_pedestrian(ped, delta)


# ═══════════════════════════════════════════════════════════════════════════════
# PATH DEFINITIONS
# ═══════════════════════════════════════════════════════════════════════════════

func _define_sidewalk_paths() -> void:
	## Define all 8 sidewalk paths (2 per road arm).
	var half_junc: float = JUNCTION_SIZE / 2.0
	var ns_sw_offset: float = NS_ROAD_WIDTH / 2.0 + SIDEWALK_WIDTH / 2.0  # ~3.95
	var e_sw_offset: float = E_ROAD_WIDTH / 2.0 + SIDEWALK_WIDTH / 2.0
	var w_sw_offset: float = W_ROAD_WIDTH / 2.0 + SIDEWALK_WIDTH / 2.0    # ~2.35

	var road_start: float = half_junc + 1.0        # Start just past junction edge
	var road_end: float = half_junc + ROAD_LENGTH - 1.0  # End before road tip

	_sidewalk_paths = [
		# ── North road (Z+) — east sidewalk ──
		{"start": Vector3(ns_sw_offset, 0, road_start), "end": Vector3(ns_sw_offset, 0, road_end)},
		# ── North road (Z+) — west sidewalk ──
		{"start": Vector3(-ns_sw_offset, 0, road_start), "end": Vector3(-ns_sw_offset, 0, road_end)},

		# ── South road (Z-) — east sidewalk ──
		{"start": Vector3(ns_sw_offset, 0, -road_start), "end": Vector3(ns_sw_offset, 0, -road_end)},
		# ── South road (Z-) — west sidewalk ──
		{"start": Vector3(-ns_sw_offset, 0, -road_start), "end": Vector3(-ns_sw_offset, 0, -road_end)},

		# ── East road (X+) — north sidewalk ──
		{"start": Vector3(road_start, 0, e_sw_offset), "end": Vector3(road_end, 0, e_sw_offset)},
		# ── East road (X+) — south sidewalk ──
		{"start": Vector3(road_start, 0, -e_sw_offset), "end": Vector3(road_end, 0, -e_sw_offset)},

		# ── West road (X-) — north sidewalk ──
		{"start": Vector3(-road_start, 0, -w_sw_offset), "end": Vector3(-road_end, 0, -w_sw_offset)},
		# ── West road (X-) — south sidewalk ──
		{"start": Vector3(-road_start, 0, w_sw_offset), "end": Vector3(-road_end, 0, w_sw_offset)},
	]


# ═══════════════════════════════════════════════════════════════════════════════
# SPAWNING
# ═══════════════════════════════════════════════════════════════════════════════

func _spawn_all() -> void:
	## Spawn all ambient pedestrians distributed across sidewalks.
	for i in range(NUM_PEDESTRIANS):
		var path_idx: int = i % _sidewalk_paths.size()
		var ped_node: Node3D = _make_pedestrian_mesh()
		add_child(ped_node)

		var progress: float = randf()  # Random starting position along path
		var speed: float = MIN_SPEED + randf() * (MAX_SPEED - MIN_SPEED)
		var forward: bool = randf() > 0.5

		var ped_data: Dictionary = {
			"node": ped_node,
			"path_idx": path_idx,
			"progress": progress,
			"speed": speed,
			"forward": forward,
		}

		_update_position(ped_data)
		_pedestrians.append(ped_data)


func respawn() -> void:
	## Clear and respawn all pedestrians (called on sim restart).
	for ped in _pedestrians:
		ped["node"].queue_free()
	_pedestrians.clear()
	_spawn_all()


# ═══════════════════════════════════════════════════════════════════════════════
# MOVEMENT
# ═══════════════════════════════════════════════════════════════════════════════

func _move_pedestrian(ped: Dictionary, delta: float) -> void:
	## Advance a pedestrian along its sidewalk path.
	var path: Dictionary = _sidewalk_paths[ped["path_idx"]]
	var path_length: float = path["start"].distance_to(path["end"])
	var step: float = (ped["speed"] * delta) / path_length

	if ped["forward"]:
		ped["progress"] += step
		if ped["progress"] >= 1.0:
			ped["progress"] = 1.0
			ped["forward"] = false
	else:
		ped["progress"] -= step
		if ped["progress"] <= 0.0:
			ped["progress"] = 0.0
			ped["forward"] = true

	_update_position(ped)


func _update_position(ped: Dictionary) -> void:
	## Set pedestrian node position and rotation from progress.
	var path: Dictionary = _sidewalk_paths[ped["path_idx"]]
	var pos: Vector3 = path["start"].lerp(path["end"], ped["progress"])
	pos.y = SIDEWALK_Y + LEG_HEIGHT + BODY_HEIGHT / 2.0  # Stand on sidewalk

	var node: Node3D = ped["node"]
	node.position = pos

	# Face walking direction
	var dir: Vector3 = (path["end"] - path["start"]).normalized()
	if not ped["forward"]:
		dir = -dir
	if dir.length() > 0.01:
		node.rotation.y = atan2(dir.x, dir.z)


# ═══════════════════════════════════════════════════════════════════════════════
# MESH CREATION
# ═══════════════════════════════════════════════════════════════════════════════

func _make_pedestrian_mesh() -> Node3D:
	## Create a simple procedural pedestrian: legs + torso + head.
	var root := Node3D.new()

	# Random colours
	var shirt_color: Color = SHIRT_COLORS[randi() % SHIRT_COLORS.size()]
	var skin_color: Color = SKIN_COLORS[randi() % SKIN_COLORS.size()]
	var leg_color: Color = LEG_COLORS[randi() % LEG_COLORS.size()]

	# ── Legs (lower body box) ──
	var leg_mat := StandardMaterial3D.new()
	leg_mat.albedo_color = leg_color

	var legs := CSGBox3D.new()
	legs.size = Vector3(BODY_WIDTH, LEG_HEIGHT, BODY_DEPTH)
	legs.position = Vector3(0, -BODY_HEIGHT / 2.0 - LEG_HEIGHT / 2.0 + 0.05, 0)
	legs.material = leg_mat
	legs.name = "Legs"
	root.add_child(legs)

	# ── Torso (upper body box) ──
	var shirt_mat := StandardMaterial3D.new()
	shirt_mat.albedo_color = shirt_color

	var torso := CSGBox3D.new()
	torso.size = Vector3(BODY_WIDTH + 0.05, BODY_HEIGHT, BODY_DEPTH + 0.02)
	torso.position = Vector3(0, 0, 0)
	torso.material = shirt_mat
	torso.name = "Torso"
	root.add_child(torso)

	# ── Head (sphere) ──
	var skin_mat := StandardMaterial3D.new()
	skin_mat.albedo_color = skin_color

	var head := CSGSphere3D.new()
	head.radius = HEAD_RADIUS
	head.radial_segments = 8
	head.rings = 4
	head.position = Vector3(0, BODY_HEIGHT / 2.0 + HEAD_RADIUS, 0)
	head.material = skin_mat
	head.name = "Head"
	root.add_child(head)

	return root
