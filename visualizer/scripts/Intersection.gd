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
## Phase-to-light mapping (8 phases):
##   Phase 0 (NS_THROUGH): N/S straight = GREEN,  E/W = RED
##   Phase 1 (NS_LEFT):    N/S left arrow = GREEN, E/W = RED
##   Phase 2 (NS_YELLOW):  N/S = YELLOW, E/W = RED
##   Phase 3 (EW_THROUGH): E/W straight = GREEN,  N/S = RED
##   Phase 4 (EW_LEFT):    E/W left arrow = GREEN, N/S = RED
##   Phase 5 (EW_YELLOW):  E/W = YELLOW, N/S = RED
##   Phase 6 (NS_ALL):     N/S all green + arrow, E/W = RED
##   Phase 7 (EW_ALL):     E/W all green + arrow, N/S = RED

# ── Phase constants (must match Python traffic_env.py) ───────────────────────
const NS_THROUGH := 0
const NS_LEFT    := 1
const NS_YELLOW  := 2
const EW_THROUGH := 3
const EW_LEFT    := 4
const EW_YELLOW  := 5
const NS_ALL     := 6
const EW_ALL     := 7

# ── Road geometry constants (Achimota/Neoplan Junction calibration) ──────────
const ROAD_LENGTH     := 90.0   # Length of each road arm (Godot units)
const NS_ROAD_WIDTH   := 6.4    # Achimota Forest Rd: 2 lanes per direction
const E_ROAD_WIDTH    := 6.4    # Aggrey Street: 2 lanes per direction
const W_ROAD_WIDTH    := 6.4    # Guggisberg Street: 2 lanes per direction
const ROAD_THICKNESS  := 0.1    # Road surface height
const JUNCTION_SIZE   := 7.0    # Central junction (slight widening at intersection)
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

# ── Turn arrow materials ───────────────────────────────────────────────────
var _mat_arrow_on: StandardMaterial3D
var _mat_arrow_off: StandardMaterial3D

# ── Lane congestion overlays ──────────────────────────────────────────────
## Maps lane_id (e.g. "ACH_N2J_0") to {mesh: MeshInstance3D, mat: StandardMaterial3D}
var _lane_overlays: Dictionary = {}

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
	_build_road_arm("east",  Vector3(-1, 0, 0), E_ROAD_WIDTH)   # Mirrored X for right-hand visual
	_build_road_arm("west",  Vector3(1, 0, 0), W_ROAD_WIDTH)    # Mirrored X for right-hand visual
	_build_traffic_lights()
	_build_lane_overlays()
	_build_watermark()
	_build_emergency_overlay()
	_build_stop_lines()
	_build_crosswalks()


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
	## Update traffic light colors and turn arrows based on phase from server.
	var phase: int = data.get("phase", 0)
	_emergency_active = data.get("emergency", {}).get("active", false)

	# Determine light state and arrow state for each approach pair
	var ns_state: String = "red"
	var ew_state: String = "red"
	var ns_arrow: bool = false
	var ew_arrow: bool = false

	match phase:
		NS_THROUGH:
			ns_state = "green"
		NS_LEFT:
			ns_state = "red"
			ns_arrow = true
		NS_YELLOW:
			ns_state = "yellow"
		EW_THROUGH:
			ew_state = "green"
		EW_LEFT:
			ew_state = "red"
			ew_arrow = true
		EW_YELLOW:
			ew_state = "yellow"
		NS_ALL:
			ns_state = "green"
			ns_arrow = true
		EW_ALL:
			ew_state = "green"
			ew_arrow = true

	_set_light("north", ns_state)
	_set_light("south", ns_state)
	_set_light("east",  ew_state)
	_set_light("west",  ew_state)

	_set_arrow("north", ns_arrow)
	_set_arrow("south", ns_arrow)
	_set_arrow("east",  ew_arrow)
	_set_arrow("west",  ew_arrow)


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

	# Turn arrow ON (green arrow, emissive)
	_mat_arrow_on = StandardMaterial3D.new()
	_mat_arrow_on.albedo_color = Color(0.0, 1.0, 0.3)
	_mat_arrow_on.emission_enabled = true
	_mat_arrow_on.emission = Color(0.0, 1.0, 0.3)
	_mat_arrow_on.emission_energy_multiplier = 5.0

	# Turn arrow OFF (dim)
	_mat_arrow_off = StandardMaterial3D.new()
	_mat_arrow_off.albedo_color = Color(0.08, 0.08, 0.08)


# ═════════════════════════════════════════════════════════════════════════════
# GEOMETRY BUILDING
# ═════════════════════════════════════════════════════════════════════════════

func _build_ground() -> void:
	## Build the ground plane (grass area surrounding the intersection).
	var ground := CSGBox3D.new()
	ground.size = Vector3(200.0, 0.02, 200.0)
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
		["east",  Vector3(-(half_junc - 0.1), 0.11, 0), Vector3(0.2, 0.02, E_ROAD_WIDTH * 0.45)],
		["west",  Vector3(half_junc - 0.1, 0.11, 0), Vector3(0.2, 0.02, W_ROAD_WIDTH * 0.45)],
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
	## Build overhead mast-arm traffic lights for each approach.
	## Each pole stands on its own road's sidewalk, pushed 2 units past the
	## junction edge along the road arm so it's clearly on the correct road.
	## A horizontal mast arm extends from the pole top over the road lanes.

	# Curb offset: how far from road center the pole sits (on sidewalk)
	var curb: float = NS_ROAD_WIDTH / 2.0 + 0.5   # 3.7 — on sidewalk

	# Along-road offset: how far from junction center, along the road arm.
	# Pushed 2 units past the junction edge so the pole is clearly on its
	# own road — NOT at the corner where it could look like the other road.
	var along: float = JUNCTION_SIZE / 2.0 + 2.0   # 5.5 — well past junction edge

	# Overhead structure constants
	const POLE_HEIGHT: float = 5.5
	const ARM_LEN: float = 3.7                     # Reaches to road center

	# Pole positions — each pole is on its OWN road's sidewalk:
	#   north/south: X = ±curb (beside N/S road), Z = ±along (along N/S road)
	#   east/west:   X = ±along (along E/W road), Z = ±curb (beside E/W road)
	var configs: Dictionary = {
		"north": {
			"pos": Vector3(curb, 0, along),
			"rot_y": 0.0,
		},
		"south": {
			"pos": Vector3(-curb, 0, -along),
			"rot_y": PI,
		},
		"east": {
			"pos": Vector3(-along, 0, curb),
			"rot_y": -PI / 2.0,
		},
		"west": {
			"pos": Vector3(along, 0, -curb),
			"rot_y": PI / 2.0,
		},
	}

	for approach in configs:
		var cfg: Dictionary = configs[approach]
		var pole_root := Node3D.new()
		pole_root.position = cfg["pos"]
		pole_root.rotation.y = cfg["rot_y"]
		pole_root.name = "TrafficLight_%s" % approach
		add_child(pole_root)

		# ── Vertical pole ────────────────────────────────────────────────
		var pole := CSGCylinder3D.new()
		pole.radius = 0.1
		pole.height = POLE_HEIGHT
		pole.position = Vector3(0, POLE_HEIGHT / 2.0, 0)
		pole.material = _mat_pole
		pole.name = "Pole"
		pole_root.add_child(pole)

		# ── Horizontal mast arm (extends over road in local -X) ──────────
		var arm := CSGBox3D.new()
		arm.size = Vector3(ARM_LEN, 0.14, 0.14)
		arm.position = Vector3(-ARM_LEN / 2.0, POLE_HEIGHT, 0)
		arm.material = _mat_pole
		arm.name = "MastArm"
		pole_root.add_child(arm)

		# ── Diagonal brace ───────────────────────────────────────────────
		var brace_h: float = ARM_LEN * 0.55
		var brace_v: float = 1.6
		var brace_len: float = sqrt(brace_h * brace_h + brace_v * brace_v)
		var brace := CSGBox3D.new()
		brace.size = Vector3(brace_len, 0.06, 0.06)
		brace.rotation.z = -atan2(brace_v, brace_h)
		brace.position = Vector3(-brace_h / 2.0, POLE_HEIGHT - brace_v / 2.0, 0)
		brace.material = _mat_pole
		brace.name = "Brace"
		pole_root.add_child(brace)

		# ── Signal housing (hangs from arm tip, over road) ───────────────
		var housing := CSGBox3D.new()
		housing.size = Vector3(0.45, 1.3, 0.30)
		housing.position = Vector3(-ARM_LEN, POLE_HEIGHT - 0.75, 0)
		housing.material = _mat_pole
		housing.name = "Housing"
		pole_root.add_child(housing)

		# ── Visor / sun shade ────────────────────────────────────────────
		var visor := CSGBox3D.new()
		visor.size = Vector3(0.55, 0.06, 0.40)
		visor.position = Vector3(-ARM_LEN, POLE_HEIGHT - 0.05, 0.15)
		visor.material = _mat_pole
		visor.name = "Visor"
		pole_root.add_child(visor)

		# ── Three bulbs: red (top), yellow (mid), green (bottom) ─────────
		var bulb_data: Array = [
			{"name": "red",    "y": POLE_HEIGHT - 0.30, "color": Color(1, 0, 0)},
			{"name": "yellow", "y": POLE_HEIGHT - 0.65, "color": Color(1, 0.85, 0)},
			{"name": "green",  "y": POLE_HEIGHT - 1.00, "color": Color(0, 1, 0.2)},
		]

		var approach_lights: Dictionary = {}

		for bd in bulb_data:
			var bulb := CSGSphere3D.new()
			bulb.radius = 0.13
			bulb.radial_segments = 12
			bulb.rings = 6
			bulb.position = Vector3(-ARM_LEN, bd["y"], 0.18)
			bulb.material = _mat_light_off
			bulb.name = "Bulb_%s" % bd["name"]
			pole_root.add_child(bulb)

			var glow := OmniLight3D.new()
			glow.position = Vector3(-ARM_LEN, bd["y"], 0.18)
			glow.light_energy = 0.0
			glow.light_color = bd["color"]
			glow.omni_range = 5.0
			glow.omni_attenuation = 1.5
			glow.shadow_enabled = false
			glow.name = "Glow_%s" % bd["name"]
			pole_root.add_child(glow)

			approach_lights[bd["name"]] = {
				"mesh": bulb,
				"glow": glow,
			}

		# ── Turn arrow indicator (hangs below main signal) ───────────────
		var arrow_housing := CSGBox3D.new()
		arrow_housing.size = Vector3(0.45, 0.45, 0.30)
		arrow_housing.position = Vector3(-ARM_LEN, POLE_HEIGHT - 1.65, 0)
		arrow_housing.material = _mat_pole
		arrow_housing.name = "ArrowHousing"
		pole_root.add_child(arrow_housing)

		var arrow_mesh := CSGBox3D.new()
		arrow_mesh.size = Vector3(0.22, 0.22, 0.05)
		arrow_mesh.position = Vector3(-ARM_LEN, POLE_HEIGHT - 1.65, 0.18)
		arrow_mesh.material = _mat_arrow_off
		arrow_mesh.name = "Arrow"
		pole_root.add_child(arrow_mesh)

		var arrow_glow := OmniLight3D.new()
		arrow_glow.position = Vector3(-ARM_LEN, POLE_HEIGHT - 1.65, 0.18)
		arrow_glow.light_energy = 0.0
		arrow_glow.light_color = Color(0, 1, 0.3)
		arrow_glow.omni_range = 3.5
		arrow_glow.omni_attenuation = 1.5
		arrow_glow.shadow_enabled = false
		arrow_glow.name = "ArrowGlow"
		pole_root.add_child(arrow_glow)

		approach_lights["arrow"] = {"mesh": arrow_mesh, "glow": arrow_glow}

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
					glow.light_energy = 3.5
					glow.light_color = Color(1, 0, 0)
				"yellow":
					mesh.material = _mat_yellow_on
					glow.light_energy = 3.5
					glow.light_color = Color(1, 0.85, 0)
				"green":
					mesh.material = _mat_green_on
					glow.light_energy = 3.5
					glow.light_color = Color(0, 1, 0.2)
		else:
			mesh.material = _mat_light_off
			glow.light_energy = 0.0


func _set_arrow(approach: String, is_on: bool) -> void:
	## Set the turn arrow indicator on/off for an approach.
	if not _lights.has(approach):
		return
	var bulbs: Dictionary = _lights[approach]
	if not bulbs.has("arrow"):
		return
	var arrow_mesh: CSGBox3D = bulbs["arrow"]["mesh"]
	var arrow_glow: OmniLight3D = bulbs["arrow"]["glow"]
	if is_on:
		arrow_mesh.material = _mat_arrow_on
		arrow_glow.light_energy = 4.0
	else:
		arrow_mesh.material = _mat_arrow_off
		arrow_glow.light_energy = 0.0


# ═════════════════════════════════════════════════════════════════════════════
# LANE CONGESTION OVERLAYS
# ═════════════════════════════════════════════════════════════════════════════

func _build_lane_overlays() -> void:
	## Build semi-transparent overlay strips on each incoming lane.
	## Color shifts green→yellow→red based on queue density.
	var half_junc: float = JUNCTION_SIZE / 2.0
	var ns_lane_w: float = NS_ROAD_WIDTH / 4.0
	var e_lane_w: float = E_ROAD_WIDTH / 4.0
	var w_lane_w: float = W_ROAD_WIDTH / 4.0   # Now 2-lane like the others

	# Lane configs: lane_id -> {pos, size}
	# All approaches now 2-lane. X positions mirrored (negated) for right-hand traffic.
	var lane_configs: Dictionary = {
		"ACH_N2J_1": {"pos": Vector3(ns_lane_w, 0.12, half_junc + ROAD_LENGTH / 2.0), "size": Vector3(ns_lane_w * 1.8, 0.02, ROAD_LENGTH)},
		"ACH_N2J_2": {"pos": Vector3(-ns_lane_w, 0.12, half_junc + ROAD_LENGTH / 2.0), "size": Vector3(ns_lane_w * 1.8, 0.02, ROAD_LENGTH)},
		"ACH_S2J_1": {"pos": Vector3(-ns_lane_w, 0.12, -(half_junc + ROAD_LENGTH / 2.0)), "size": Vector3(ns_lane_w * 1.8, 0.02, ROAD_LENGTH)},
		"ACH_S2J_2": {"pos": Vector3(ns_lane_w, 0.12, -(half_junc + ROAD_LENGTH / 2.0)), "size": Vector3(ns_lane_w * 1.8, 0.02, ROAD_LENGTH)},
		"AGG_E2J_1": {"pos": Vector3(-(half_junc + ROAD_LENGTH / 2.0), 0.12, e_lane_w), "size": Vector3(ROAD_LENGTH, 0.02, e_lane_w * 1.8)},
		"AGG_E2J_2": {"pos": Vector3(-(half_junc + ROAD_LENGTH / 2.0), 0.12, -e_lane_w), "size": Vector3(ROAD_LENGTH, 0.02, e_lane_w * 1.8)},
		"GUG_W2J_1": {"pos": Vector3(half_junc + ROAD_LENGTH / 2.0, 0.12, -w_lane_w), "size": Vector3(ROAD_LENGTH, 0.02, w_lane_w * 1.8)},
		"GUG_W2J_2": {"pos": Vector3(half_junc + ROAD_LENGTH / 2.0, 0.12, w_lane_w), "size": Vector3(ROAD_LENGTH, 0.02, w_lane_w * 1.8)},
	}

	for lane_id in lane_configs:
		var cfg: Dictionary = lane_configs[lane_id]
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.0, 0.8, 0.0, 0.0)
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.no_depth_test = true

		var overlay := CSGBox3D.new()
		overlay.size = cfg["size"]
		overlay.position = cfg["pos"]
		overlay.material = mat
		overlay.name = "LaneOverlay_%s" % lane_id
		add_child(overlay)

		_lane_overlays[lane_id] = {"mesh": overlay, "mat": mat}


func update_lane_overlays(data: Dictionary) -> void:
	## Update lane overlay colors based on per-lane queue data.
	## data should contain "lane_data" key with per-lane metrics.
	var lane_data: Dictionary = data.get("lane_data", {})
	if lane_data.is_empty():
		return

	for lane_id in _lane_overlays:
		if not lane_data.has(lane_id):
			continue
		var ld: Dictionary = lane_data[lane_id]
		var queue: float = float(ld.get("queue", 0))
		var density: float = clampf(queue / 20.0, 0.0, 1.0)
		var mat: StandardMaterial3D = _lane_overlays[lane_id]["mat"]
		# Color: green → yellow → red as density increases
		var col: Color
		if density < 0.5:
			col = Color(0.0, 0.8, 0.0).lerp(Color(1.0, 0.85, 0.0), density * 2.0)
		else:
			col = Color(1.0, 0.85, 0.0).lerp(Color(1.0, 0.1, 0.0), (density - 0.5) * 2.0)
		col.a = density * 0.3
		mat.albedo_color = col


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


# ═════════════════════════════════════════════════════════════════════════════
# CROSSWALK MARKINGS
# ═════════════════════════════════════════════════════════════════════════════

func _build_crosswalks() -> void:
	## Build zebra crossing markings at the north and south junction edges only.
	## These cross the E/W road — the main pedestrian routes at Achimota junction.
	var half_junc: float = JUNCTION_SIZE / 2.0
	var stripe_w: float = 0.3
	var stripe_gap: float = 0.3
	var y_pos: float = 0.11

	# Only north and south crosswalks — positioned at the junction edge
	# where SUMO pedestrians actually cross
	var crosswalks: Array = [
		{"name": "north", "center": Vector3(0, y_pos, half_junc), "width": NS_ROAD_WIDTH, "along_x": true},
		{"name": "south", "center": Vector3(0, y_pos, -half_junc), "width": NS_ROAD_WIDTH, "along_x": true},
	]

	for cw in crosswalks:
		var n_stripes: int = int(cw["width"] / (stripe_w + stripe_gap))
		var total_span: float = n_stripes * (stripe_w + stripe_gap) - stripe_gap
		var start_offset: float = -total_span / 2.0

		for i in range(n_stripes):
			var stripe := CSGBox3D.new()
			var offset: float = start_offset + i * (stripe_w + stripe_gap)
			stripe.size = Vector3(stripe_w, 0.02, 1.6)
			stripe.position = cw["center"] + Vector3(offset + stripe_w / 2.0, 0, 0)
			stripe.material = _mat_marking
			stripe.name = "Crosswalk_%s_%d" % [cw["name"], i]
			add_child(stripe)
