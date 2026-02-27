extends Node3D
## Builds and manages the 3D intersection geometry and traffic lights.
##
## All geometry is constructed from Godot primitives (CSGBox3D, CSGCylinder3D,
## CSGSphere3D, MeshInstance3D) — no external assets required.
##
## Coordinate mapping (SUMO → Godot):
##   SUMO North (Y+) → Godot +Z
##   SUMO South (Y-) → Godot -Z
##   SUMO East  (X+) → Godot +X
##   SUMO West  (X-) → Godot -X
##   Road surface sits at Y = 0
##
## Phase-to-light mapping (from SUMO tlLogic for junction J0):
##   Phase 0 (NS_GREEN):  N/S = GREEN,  E/W = RED
##   Phase 1 (NS_YELLOW): N/S = YELLOW, E/W = RED
##   Phase 2 (EW_GREEN):  N/S = RED,    E/W = GREEN
##   Phase 3 (EW_YELLOW): N/S = RED,    E/W = YELLOW

# ── Phase constants (must match Python traffic_env.py) ───────────────────────
const NS_GREEN  := 0
const NS_YELLOW := 1
const EW_GREEN  := 2
const EW_YELLOW := 3

# ── Road geometry constants ──────────────────────────────────────────────────
const ROAD_LENGTH     := 30.0   # Length of each road arm (Godot units)
const NS_ROAD_WIDTH   := 6.4    # 2 lanes per direction (~1.6 each)
const EW_ROAD_WIDTH   := 3.2    # 1 lane per direction
const ROAD_THICKNESS  := 0.1    # Road surface height
const JUNCTION_SIZE   := 8.0    # Central square junction size
const SIDEWALK_HEIGHT := 0.15   # Raised sidewalk height
const SIDEWALK_WIDTH  := 1.5    # Sidewalk width alongside road

# ── Traffic light references ─────────────────────────────────────────────────
# Structure: { "north": {"red": {mesh, glow}, "yellow": {...}, "green": {...}}, ... }
var _lights: Dictionary = {}

# ── Materials (created once, reused everywhere) ──────────────────────────────
var _mat_road: StandardMaterial3D
var _mat_sidewalk: StandardMaterial3D
var _mat_marking: StandardMaterial3D
var _mat_grass: StandardMaterial3D
var _mat_pole: StandardMaterial3D
var _mat_light_off: StandardMaterial3D
var _mat_red_on: StandardMaterial3D
var _mat_yellow_on: StandardMaterial3D
var _mat_green_on: StandardMaterial3D

# ── Emergency state ──────────────────────────────────────────────────────────
var _emergency_active: bool = false
var _emergency_pulse_time: float = 0.0
var _emergency_overlay: MeshInstance3D  # Semi-transparent red overlay


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_create_materials()
	_build_ground()
	_build_junction()
	_build_road_arm("north", Vector3(0, 0, 1), NS_ROAD_WIDTH)
	_build_road_arm("south", Vector3(0, 0, -1), NS_ROAD_WIDTH)
	_build_road_arm("east",  Vector3(1, 0, 0), EW_ROAD_WIDTH)
	_build_road_arm("west",  Vector3(-1, 0, 0), EW_ROAD_WIDTH)
	_build_traffic_lights()
	_build_watermark()
	_build_emergency_overlay()
	_build_stop_lines()


func _process(delta: float) -> void:
	# Emergency pulsing effect
	if _emergency_active:
		_emergency_pulse_time += delta * 4.0
		var pulse: float = (sin(_emergency_pulse_time) + 1.0) / 2.0
		if _emergency_overlay:
			var mat: StandardMaterial3D = _emergency_overlay.get_surface_override_material(0)
			if mat:
				mat.albedo_color = Color(1.0, 0.0, 0.0, 0.05 + 0.1 * pulse)
	else:
		_emergency_pulse_time = 0.0
		if _emergency_overlay:
			var mat: StandardMaterial3D = _emergency_overlay.get_surface_override_material(0)
			if mat:
				mat.albedo_color = Color(1.0, 0.0, 0.0, 0.0)


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API — called by Main.gd when state_update arrives
# ═════════════════════════════════════════════════════════════════════════════

func update_lights(data: Dictionary) -> void:
	## Update traffic light colors based on the current phase from the server.
	var phase: int = data.get("phase", 0)
	_emergency_active = data.get("emergency", {}).get("active", false)

	# Determine light state for each approach pair
	var ns_state: String  # "red", "yellow", or "green"
	var ew_state: String

	match phase:
		NS_GREEN:
			ns_state = "green"
			ew_state = "red"
		NS_YELLOW:
			ns_state = "yellow"
			ew_state = "red"
		EW_GREEN:
			ns_state = "red"
			ew_state = "green"
		EW_YELLOW:
			ns_state = "red"
			ew_state = "yellow"
		_:
			ns_state = "red"
			ew_state = "red"

	_set_light("north", ns_state)
	_set_light("south", ns_state)
	_set_light("east",  ew_state)
	_set_light("west",  ew_state)


# ═════════════════════════════════════════════════════════════════════════════
# MATERIAL CREATION
# ═════════════════════════════════════════════════════════════════════════════

func _create_materials() -> void:
	## Create all shared materials once.
	# Road surface — dark grey asphalt
	_mat_road = StandardMaterial3D.new()
	_mat_road.albedo_color = Color(0.18, 0.18, 0.20)

	# Sidewalk — lighter concrete
	_mat_sidewalk = StandardMaterial3D.new()
	_mat_sidewalk.albedo_color = Color(0.42, 0.40, 0.38)

	# Lane markings — white
	_mat_marking = StandardMaterial3D.new()
	_mat_marking.albedo_color = Color(0.92, 0.92, 0.92)

	# Grass / ground plane
	_mat_grass = StandardMaterial3D.new()
	_mat_grass.albedo_color = Color(0.22, 0.38, 0.18)

	# Traffic light pole — dark metal
	_mat_pole = StandardMaterial3D.new()
	_mat_pole.albedo_color = Color(0.25, 0.25, 0.28)
	_mat_pole.metallic = 0.6
	_mat_pole.roughness = 0.4

	# Light bulb OFF state
	_mat_light_off = StandardMaterial3D.new()
	_mat_light_off.albedo_color = Color(0.12, 0.12, 0.12)

	# Emissive materials for active lights
	_mat_red_on = StandardMaterial3D.new()
	_mat_red_on.albedo_color = Color(1.0, 0.1, 0.1)
	_mat_red_on.emission_enabled = true
	_mat_red_on.emission = Color(1.0, 0.0, 0.0)
	_mat_red_on.emission_energy_multiplier = 4.0

	_mat_yellow_on = StandardMaterial3D.new()
	_mat_yellow_on.albedo_color = Color(1.0, 0.85, 0.0)
	_mat_yellow_on.emission_enabled = true
	_mat_yellow_on.emission = Color(1.0, 0.85, 0.0)
	_mat_yellow_on.emission_energy_multiplier = 4.0

	_mat_green_on = StandardMaterial3D.new()
	_mat_green_on.albedo_color = Color(0.0, 1.0, 0.2)
	_mat_green_on.emission_enabled = true
	_mat_green_on.emission = Color(0.0, 1.0, 0.2)
	_mat_green_on.emission_energy_multiplier = 4.0


# ═════════════════════════════════════════════════════════════════════════════
# GEOMETRY BUILDING
# ═════════════════════════════════════════════════════════════════════════════

func _build_ground() -> void:
	## Build the ground plane (grass area surrounding the intersection).
	var ground := CSGBox3D.new()
	ground.size = Vector3(80.0, 0.02, 80.0)
	ground.position = Vector3(0, -0.06, 0)
	ground.material = _mat_grass
	ground.name = "Ground"
	add_child(ground)


func _build_junction() -> void:
	## Build the central junction square.
	var junction := CSGBox3D.new()
	junction.size = Vector3(JUNCTION_SIZE, ROAD_THICKNESS, JUNCTION_SIZE)
	junction.position = Vector3(0, 0, 0)
	junction.material = _mat_road
	junction.name = "Junction"
	add_child(junction)


func _build_road_arm(approach: String, direction: Vector3, road_width: float) -> void:
	## Build one road arm extending from the junction.
	## approach: "north", "south", "east", "west"
	## direction: Unit vector pointing away from junction center
	## road_width: Total road width (both directions combined)
	var half_junc: float = JUNCTION_SIZE / 2.0
	var center: Vector3 = direction * (half_junc + ROAD_LENGTH / 2.0)

	# Road surface
	var road := CSGBox3D.new()
	if abs(direction.x) > 0:
		road.size = Vector3(ROAD_LENGTH, ROAD_THICKNESS, road_width)
	else:
		road.size = Vector3(road_width, ROAD_THICKNESS, ROAD_LENGTH)
	road.position = center
	road.material = _mat_road
	road.name = "Road_%s" % approach
	add_child(road)

	# Center line (dashed marking)
	_build_center_line(center, direction, ROAD_LENGTH, road_width)

	# Sidewalks on both sides of the road
	_build_sidewalks(center, direction, ROAD_LENGTH, road_width)


func _build_center_line(center: Vector3, direction: Vector3, length: float, _road_width: float) -> void:
	## Build dashed center line along a road arm.
	var dash_length: float = 2.0
	var gap_length: float = 1.5
	var total_step: float = dash_length + gap_length
	var num_dashes: int = int(length / total_step)
	var half_length: float = length / 2.0
	for i in range(num_dashes):
		var offset: float = -half_length + i * total_step + dash_length / 2.0
		var pos: Vector3
		var dash := CSGBox3D.new()

		if abs(direction.z) > 0:
			# N/S road — dashes along Z axis
			dash.size = Vector3(0.08, 0.12, dash_length)
			pos = center + Vector3(0, 0, offset * sign(direction.z))
		else:
			# E/W road — dashes along X axis
			dash.size = Vector3(dash_length, 0.12, 0.08)
			pos = center + Vector3(offset * sign(direction.x), 0, 0)

		dash.position = pos
		dash.material = _mat_marking
		add_child(dash)


func _build_sidewalks(center: Vector3, direction: Vector3, length: float, road_width: float) -> void:
	## Build raised sidewalks on both sides of a road arm.
	var half_width: float = road_width / 2.0

	for side in [-1.0, 1.0]:
		var sw := CSGBox3D.new()
		var sw_pos: Vector3

		if abs(direction.z) > 0:
			# N/S road — sidewalks along X offset
			sw.size = Vector3(SIDEWALK_WIDTH, SIDEWALK_HEIGHT, length)
			sw_pos = center + Vector3(side * (half_width + SIDEWALK_WIDTH / 2.0), SIDEWALK_HEIGHT / 2.0, 0)
		else:
			# E/W road — sidewalks along Z offset
			sw.size = Vector3(length, SIDEWALK_HEIGHT, SIDEWALK_WIDTH)
			sw_pos = center + Vector3(0, SIDEWALK_HEIGHT / 2.0, side * (half_width + SIDEWALK_WIDTH / 2.0))

		sw.position = sw_pos
		sw.material = _mat_sidewalk
		add_child(sw)


func _build_stop_lines() -> void:
	## Build white stop lines at the junction edge for each approach.
	var half_junc: float = JUNCTION_SIZE / 2.0
	var configs: Array = [
		# approach, position, size
		["north", Vector3(0, 0.11, half_junc - 0.1), Vector3(NS_ROAD_WIDTH * 0.45, 0.02, 0.2)],
		["south", Vector3(0, 0.11, -(half_junc - 0.1)), Vector3(NS_ROAD_WIDTH * 0.45, 0.02, 0.2)],
		["east",  Vector3(half_junc - 0.1, 0.11, 0), Vector3(0.2, 0.02, EW_ROAD_WIDTH * 0.45)],
		["west",  Vector3(-(half_junc - 0.1), 0.11, 0), Vector3(0.2, 0.02, EW_ROAD_WIDTH * 0.45)],
	]

	for cfg in configs:
		var line := CSGBox3D.new()
		line.position = cfg[1]
		line.size = cfg[2]
		line.material = _mat_marking
		line.name = "StopLine_%s" % cfg[0]
		add_child(line)


# ═════════════════════════════════════════════════════════════════════════════
# TRAFFIC LIGHTS
# ═════════════════════════════════════════════════════════════════════════════

func _build_traffic_lights() -> void:
	## Build traffic light poles at each junction corner.
	# Each light faces inward toward approaching traffic.
	# Positions are at the left side of each approach (driver's perspective).
	var half_junc: float = JUNCTION_SIZE / 2.0 + 0.5

	var configs: Dictionary = {
		"north": {
			"pos": Vector3(-(NS_ROAD_WIDTH / 4.0 + 0.5), 0, half_junc),
			"rot_y": 0.0,  # Faces south (toward oncoming N traffic)
		},
		"south": {
			"pos": Vector3(NS_ROAD_WIDTH / 4.0 + 0.5, 0, -half_junc),
			"rot_y": PI,  # Faces north
		},
		"east": {
			"pos": Vector3(half_junc, 0, (EW_ROAD_WIDTH / 4.0 + 0.5)),
			"rot_y": -PI / 2.0,  # Faces west
		},
		"west": {
			"pos": Vector3(-half_junc, 0, -(EW_ROAD_WIDTH / 4.0 + 0.5)),
			"rot_y": PI / 2.0,  # Faces east
		},
	}

	for approach in configs:
		var cfg: Dictionary = configs[approach]
		var pole_root := Node3D.new()
		pole_root.position = cfg["pos"]
		pole_root.rotation.y = cfg["rot_y"]
		pole_root.name = "TrafficLight_%s" % approach
		add_child(pole_root)

		# Vertical pole
		var pole := CSGCylinder3D.new()
		pole.radius = 0.06
		pole.height = 3.5
		pole.position = Vector3(0, 1.75, 0)
		pole.material = _mat_pole
		pole.name = "Pole"
		pole_root.add_child(pole)

		# Housing (dark box behind the light bulbs)
		var housing := CSGBox3D.new()
		housing.size = Vector3(0.35, 1.1, 0.22)
		housing.position = Vector3(0, 3.2, 0.12)
		housing.material = _mat_pole
		housing.name = "Housing"
		pole_root.add_child(housing)

		# Three bulbs: red (top), yellow (middle), green (bottom)
		var bulb_data: Array = [
			{"name": "red",    "y": 3.55, "color": Color(1, 0, 0)},
			{"name": "yellow", "y": 3.20, "color": Color(1, 0.85, 0)},
			{"name": "green",  "y": 2.85, "color": Color(0, 1, 0.2)},
		]

		var approach_lights: Dictionary = {}

		for bd in bulb_data:
			# Bulb mesh (sphere)
			var bulb := CSGSphere3D.new()
			bulb.radius = 0.1
			bulb.radial_segments = 12
			bulb.rings = 6
			bulb.position = Vector3(0, bd["y"], 0.25)
			bulb.material = _mat_light_off
			bulb.name = "Bulb_%s" % bd["name"]
			pole_root.add_child(bulb)

			# Glow light (OmniLight3D for volumetric glow effect)
			var glow := OmniLight3D.new()
			glow.position = Vector3(0, bd["y"], 0.25)
			glow.light_energy = 0.0  # Off initially
			glow.light_color = bd["color"]
			glow.omni_range = 3.0
			glow.omni_attenuation = 2.0
			glow.shadow_enabled = false
			glow.name = "Glow_%s" % bd["name"]
			pole_root.add_child(glow)

			approach_lights[bd["name"]] = {
				"mesh": bulb,
				"glow": glow,
			}

		_lights[approach] = approach_lights


func _set_light(approach: String, active_color: String) -> void:
	## Set one traffic light: turn on the active bulb, turn off others.
	## approach: "north", "south", "east", "west"
	## active_color: "red", "yellow", or "green"
	if not _lights.has(approach):
		return

	var bulbs: Dictionary = _lights[approach]

	for color_name in ["red", "yellow", "green"]:
		var is_on: bool = (color_name == active_color)
		var mesh: CSGSphere3D = bulbs[color_name]["mesh"]
		var glow: OmniLight3D = bulbs[color_name]["glow"]

		if is_on:
			match color_name:
				"red":
					mesh.material = _mat_red_on
					glow.light_energy = 2.5
					glow.light_color = Color(1, 0, 0)
				"yellow":
					mesh.material = _mat_yellow_on
					glow.light_energy = 2.5
					glow.light_color = Color(1, 0.85, 0)
				"green":
					mesh.material = _mat_green_on
					glow.light_energy = 2.5
					glow.light_color = Color(0, 1, 0.2)
		else:
			mesh.material = _mat_light_off
			glow.light_energy = 0.0


# ═════════════════════════════════════════════════════════════════════════════
# WATERMARK & EMERGENCY OVERLAY
# ═════════════════════════════════════════════════════════════════════════════

func _build_watermark() -> void:
	## Place 'Valiborn Technologies' text at the intersection center.
	var label := Label3D.new()
	label.text = "VALIBORN TECHNOLOGIES"
	label.font_size = 48
	label.position = Vector3(0, 0.12, 0)
	label.rotation.x = -PI / 2.0  # Face upward (visible from above)
	label.modulate = Color(0.35, 0.35, 0.40, 0.35)  # Subtle watermark
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.pixel_size = 0.01
	label.name = "Watermark"
	add_child(label)


func _build_emergency_overlay() -> void:
	## Build a semi-transparent red overlay for emergency mode.
	var mesh := PlaneMesh.new()
	mesh.size = Vector2(JUNCTION_SIZE + 2.0, JUNCTION_SIZE + 2.0)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.0, 0.0, 0.0)  # Invisible initially
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true

	_emergency_overlay = MeshInstance3D.new()
	_emergency_overlay.mesh = mesh
	_emergency_overlay.set_surface_override_material(0, mat)
	_emergency_overlay.position = Vector3(0, 0.2, 0)
	_emergency_overlay.name = "EmergencyOverlay"
	add_child(_emergency_overlay)
