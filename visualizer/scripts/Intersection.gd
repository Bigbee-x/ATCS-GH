extends Node3D
const CrossingFurniture = preload("res://scripts/CrossingFurniture.gd")
const StreetLamp = preload("res://scripts/StreetLamp.gd")

const Signals = preload("res://scripts/SignalHardware.gd")
const PedSignals = preload("res://scripts/PedestrianSignals.gd")

const SurfaceMaterials = preload("res://scripts/StreetscapeMaterials.gd")
## Builds and manages the 3D intersection geometry and traffic lights.
##
## All geometry is constructed from Godot primitives (CSGBox3D, CSGCylinder3D,
## CSGSphere3D, MeshInstance3D) — no external assets required.
##
## Coordinate mapping (SUMO → Godot):
##   SUMO North (Y+) → Godot +Z
##   SUMO South (Y-) → Godot -Z
##   SUMO East  (X+) → Godot -X
##   SUMO West  (X-) → Godot +X
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
var _peds: Node   # PedestrianSignals: two heads per corner pole, live from the crossings

# ── Materials (created once, reused everywhere) ──────────────────────────────
var _mat_road: Material
var _mat_sidewalk: Material
var _mat_marking: Material
var _mat_grass: Material
var _mat_pole: StandardMaterial3D

# ── Lane congestion overlays ──────────────────────────────────────────────
## Maps lane_id (e.g. "ACH_N2J_0") to {mesh: MeshInstance3D, mat: StandardMaterial3D}
var _lane_overlays: Dictionary = {}

# ── Street light references (for night mode toggle) ─────────────────────────
var _street_lights: Array = []   # Array of OmniLight3D nodes
var _mat_lamp_housing: StandardMaterial3D

# ── Utility pole / overhead power line materials ────────────────────────────
var _mat_util_pole: StandardMaterial3D
var _mat_insulator: StandardMaterial3D
var _mat_wire: StandardMaterial3D

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
	#_build_lane_overlays()  # Disabled — visual clutter on dark roads
	_build_street_lights()
	_build_utility_poles()
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
	if _peds:
		_peds.update(data, data.get("pedestrians", []))

	if data.has("signals"):
		for arm in data.signals:
			_set_light(arm, data.signals[arm].main)
			_set_arrow(arm, data.signals[arm].arrow)
		return

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
	_mat_road = SurfaceMaterials.surface(1, Color("343834"))

	# Sidewalk — lighter concrete
	_mat_sidewalk = SurfaceMaterials.surface(2, Color("a59d88"))

	# Lane markings — white
	_mat_marking = SurfaceMaterials.surface(0, Color("c8c1a9"))

	# Grass / ground plane
	_mat_grass = SurfaceMaterials.surface(3, Color("796d4b"))

	# Street-lamp pole — dark metal
	_mat_pole = StandardMaterial3D.new()
	_mat_pole.albedo_color = Color(0.25, 0.25, 0.28)
	_mat_pole.metallic = 0.6
	_mat_pole.roughness = 0.4

	# Street lamp housing — dark metal with warm emissive face
	# (emission energy is 0 during day, bumped at night by set_street_lights_night)
	_mat_lamp_housing = StandardMaterial3D.new()
	_mat_lamp_housing.albedo_color = Color(0.95, 0.82, 0.50)
	_mat_lamp_housing.metallic = 0.2
	_mat_lamp_housing.roughness = 0.4
	_mat_lamp_housing.emission_enabled = true
	_mat_lamp_housing.emission = Color(1.00, 0.85, 0.45)
	_mat_lamp_housing.emission_energy_multiplier = 0.0

	# Utility / power pole — weathered wood
	_mat_util_pole = StandardMaterial3D.new()
	_mat_util_pole.albedo_color = Color(0.38, 0.28, 0.18)
	_mat_util_pole.roughness = 0.9

	# Cross-arm insulators — white ceramic
	_mat_insulator = StandardMaterial3D.new()
	_mat_insulator.albedo_color = Color(0.88, 0.86, 0.82)
	_mat_insulator.roughness = 0.4

	# Overhead power lines — dark, matte
	_mat_wire = StandardMaterial3D.new()
	_mat_wire.albedo_color = Color(0.08, 0.08, 0.08)
	_mat_wire.roughness = 0.9


# ═════════════════════════════════════════════════════════════════════════════
# GEOMETRY BUILDING
# ═════════════════════════════════════════════════════════════════════════════

func _build_ground() -> void:
	## Build the ground plane (grass area surrounding the intersection).
	var ground := CSGBox3D.new()
	# Extend beyond the camera clip distance so the horizon has no exposed edge.
	ground.size = Vector3(2000.0, 0.02, 2000.0)
	ground.position = Vector3(0, -0.06, 0)
	ground.material = _mat_grass
	ground.name = "Ground"
	ground.use_collision = true   # Walkable floor for ground-mode player
	add_child(ground)


func _build_junction() -> void:
	## Build the central junction square.
	var junction := CSGBox3D.new()
	junction.size = Vector3(JUNCTION_SIZE, ROAD_THICKNESS, JUNCTION_SIZE)
	junction.position = Vector3(0, 0, 0)
	junction.material = _mat_road
	junction.name = "Junction"
	junction.use_collision = true
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
	road.use_collision = true
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
		sw.use_collision = true   # Raised curbs the player can step up onto
		add_child(sw)


func _build_stop_lines() -> void:
	CrossingFurniture.stop_lines(self, false, 0, _mat_marking)

func _build_traffic_lights() -> void:
	## Build overhead mast-arm traffic lights for each approach.
	## Each pole stands beyond its own road's sidewalk and drain, pushed 2 units past the
	## junction edge along the road arm so it's clearly on the correct road.
	## A horizontal mast arm extends from the pole top over the road lanes.

	# Curb offset: how far from road center the pole sits (on the verge)
	var curb: float = NS_ROAD_WIDTH / 2.0 + SIDEWALK_WIDTH + 1.0   # clear of the gutter and walking strip

	# Along-road offset: how far from junction center, along the road arm.
	# Pushed 2 units past the junction edge so the pole is clearly on its
	# own road — NOT at the corner where it could look like the other road.
	var along: float = JUNCTION_SIZE / 2.0 + 2.0   # 5.5 — well past junction edge

	# Overhead structure constants
	const POLE_HEIGHT: float = 5.5
	var ARM_LEN: float = curb                     # Reaches to road center

	# Pole positions — each pole is on its own road's verge:
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

		Signals.structure(pole_root, -1.0, ARM_LEN)

		var head_over: Dictionary = _build_overhead_head(pole_root, -(ARM_LEN - 0.45), POLE_HEIGHT)
		var head_pole: Dictionary = _build_pole_head(pole_root, 3.5)

		_lights[approach] = {
			"red":    head_over["red"],
			"yellow": head_over["yellow"],
			"green":  head_over["green"],
			"arrow":  head_over["arrow"],
			"pole":   head_pole,           # Three-aspect roadside repeater
		}

	# Every approach also gets a far-side through head and left arrow, on the pole
	# standing at its far-left corner: the next approach's pole across the junction.
	# They share the approach's channel, so they show exactly what its main head shows.
	var served_by: Dictionary = {"north": "south", "south": "north", "east": "west", "west": "east"}
	for approach in configs:
		var host: Node3D = get_node("TrafficLight_%s" % approach)
		_lights[served_by[approach]]["far"] = Signals.far_side(host, 3.5)

	# Two pedestrian heads per corner pole, one at the end of each crossing beside
	# it, facing the walkers waiting at the far end: its own arm's crossing (pole
	# -X) and the neighbouring arm's (pole -Z).
	_peds = PedSignals.new()
	_peds.name = "PedestrianSignals"
	_peds.junction = "J0"
	add_child(_peds)
	var second_crossing: Dictionary = {"north": "west", "east": "north", "south": "east", "west": "south"}
	for approach in configs:
		var host: Node3D = get_node("TrafficLight_%s" % approach)
		_peds.add(approach, Signals.pedestrian_head(host, Vector3(-0.42, 2.42, 0), -PI / 2.0, Vector3(-0.07, 0, 0)))
		_peds.add(second_crossing[approach], Signals.pedestrian_head(host, Vector3(-0.42, 2.42, -0.40), PI, Vector3(-0.05, 0, -0.07)))


func _build_overhead_head(pole_root: Node3D, cx: float, arm_y: float) -> Dictionary:
	return Signals.overhead(pole_root, cx, arm_y)

func _build_pole_head(pole_root: Node3D, top_y: float) -> Dictionary:
	return Signals.repeater(pole_root, top_y)


func _set_light(approach: String, active_color: String) -> void:
	if not _lights.has(approach):
		return
	var bulbs: Dictionary = _lights[approach]
	for color_name in ["red", "yellow", "green"]:
		Signals.set_aspect(bulbs[color_name], color_name == active_color)
		Signals.set_aspect(bulbs["pole"][color_name], color_name == active_color)
		if bulbs.has("far"):
			Signals.set_aspect(bulbs["far"][color_name], color_name == active_color)

func _set_arrow(approach: String, is_on: bool) -> void:
	if _lights.has(approach):
		Signals.set_aspect(_lights[approach]["arrow"], is_on)
		if _lights[approach].has("far"):
			Signals.set_aspect(_lights[approach]["far"]["arrow"], is_on)


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
# EMERGENCY OVERLAY
# ═════════════════════════════════════════════════════════════════════════════

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
	CrossingFurniture.crossings(self, false, 0, _mat_marking, _mat_sidewalk)

func _build_street_lights() -> void:
	for arm in [{"dir": Vector3(0, 0, 1), "width": NS_ROAD_WIDTH}, {"dir": Vector3(0, 0, -1), "width": NS_ROAD_WIDTH}, {"dir": Vector3(-1, 0, 0), "width": E_ROAD_WIDTH}, {"dir": Vector3(1, 0, 0), "width": W_ROAD_WIDTH}]:
		for side in [-1.0, 1.0]:
			var lateral := Vector3(side, 0, 0) if absf(arm.dir.z) > 0 else Vector3(0, 0, side)
			var dist: float = JUNCTION_SIZE / 2.0 + 11.0
			while dist < ROAD_LENGTH - 5.0:
				var lamp := StreetLamp.new()
				lamp.position = arm.dir * dist + lateral * (arm.width / 2.0 + SIDEWALK_WIDTH - 0.12)
				lamp.rotation.y = atan2(-lateral.x, -lateral.z)
				add_child(lamp)
				_street_lights.append(lamp)
				dist += 15.0

func set_street_lights_night(enabled: bool) -> void:
	for lamp in _street_lights:
		lamp.set_night(enabled)

func _build_utility_poles() -> void:
	## Place wooden utility poles (taller than street lamps, further back) along
	## ONE side of each road arm, with a cross-arm + 3 ceramic insulators near
	## the top and 3 horizontal power lines strung between consecutive poles.
	var half_junc: float = JUNCTION_SIZE / 2.0
	var spacing: float = 22.0          # Longer span than street lights
	var pole_height: float = 7.0       # Taller than street lights (4m)
	var crossbar_len: float = 1.8
	var insulator_spacing: float = crossbar_len * 0.38  # insulator offsets: -x, 0, +x

	var arms: Array = [
		{"dir": Vector3(0, 0, 1),  "width": NS_ROAD_WIDTH, "side": 1.0},
		{"dir": Vector3(0, 0, -1), "width": NS_ROAD_WIDTH, "side": 1.0},
		{"dir": Vector3(-1, 0, 0), "width": E_ROAD_WIDTH,  "side": 1.0},
		{"dir": Vector3(1, 0, 0),  "width": W_ROAD_WIDTH,  "side": 1.0},
	]

	for arm_info in arms:
		var direction: Vector3 = arm_info["dir"]
		var road_w: float = arm_info["width"]
		var side: float = arm_info["side"]
		# Sit further back than street lights (0.6) to avoid clashing
		var side_offset: float = road_w / 2.0 + SIDEWALK_WIDTH + 1.25
		var is_ns: bool = abs(direction.z) > 0.0

		var lateral: Vector3
		if is_ns:
			lateral = Vector3(side * side_offset, 0, 0)
		else:
			lateral = Vector3(0, 0, side * side_offset)

		# Insulator positions from the previous pole on this arm (for wire spans)
		var prev_insulators: Array = []
		var dist: float = half_junc + 8.0
		while dist < ROAD_LENGTH - 3.0:
			var pos: Vector3 = direction * dist + lateral

			# Pole (wooden)
			var pole := CSGCylinder3D.new()
			pole.radius = 0.12
			pole.height = pole_height
			pole.position = pos + Vector3(0, pole_height / 2.0, 0)
			pole.material = _mat_util_pole
			pole.name = "UtilityPole"
			add_child(pole)

			# Cross-arm (horizontal bar perpendicular to road)
			var crossbar := CSGBox3D.new()
			if is_ns:
				crossbar.size = Vector3(crossbar_len, 0.14, 0.14)
			else:
				crossbar.size = Vector3(0.14, 0.14, crossbar_len)
			crossbar.position = pos + Vector3(0, pole_height - 0.25, 0)
			crossbar.material = _mat_util_pole
			crossbar.name = "UtilityCrossbar"
			add_child(crossbar)

			# Diagonal support brace (short 45° strut from pole to cross-arm)
			var brace := CSGBox3D.new()
			if is_ns:
				brace.size = Vector3(0.55, 0.08, 0.08)
			else:
				brace.size = Vector3(0.08, 0.08, 0.55)
			brace.position = pos + Vector3(0, pole_height - 0.55, 0)
			brace.rotation_degrees = Vector3(0, 0, 35) if is_ns else Vector3(35, 0, 0)
			brace.material = _mat_util_pole
			brace.name = "UtilityBrace"
			add_child(brace)

			# 3 ceramic insulators on the cross-arm (little white cylinders)
			var insulator_positions: Array = []
			for k in range(3):
				var slot: float = (k - 1) * insulator_spacing  # -1, 0, +1 slots
				var ins_offset: Vector3
				if is_ns:
					ins_offset = Vector3(slot, 0.0, 0.0)
				else:
					ins_offset = Vector3(0.0, 0.0, slot)
				var ins := CSGCylinder3D.new()
				ins.radius = 0.07
				ins.height = 0.20
				ins.position = pos + Vector3(0, pole_height - 0.05, 0) + ins_offset
				ins.material = _mat_insulator
				ins.name = "UtilityInsulator"
				add_child(ins)
				# Wire-attach point sits just above the insulator top
				insulator_positions.append(ins.position + Vector3(0, 0.12, 0))

			# String 3 wires between this pole and the previous one on this arm
			if prev_insulators.size() == 3:
				for k in range(3):
					var w_start: Vector3 = prev_insulators[k]
					var w_end: Vector3 = insulator_positions[k]
					var mid: Vector3 = (w_start + w_end) * 0.5
					var span: float = (w_end - w_start).length()
					var wire := CSGBox3D.new()
					if is_ns:
						wire.size = Vector3(0.035, 0.035, span)
					else:
						wire.size = Vector3(span, 0.035, 0.035)
					# Slight sag so wires don't look perfectly stiff
					wire.position = mid + Vector3(0, -0.15, 0)
					wire.material = _mat_wire
					wire.name = "PowerLine"
					add_child(wire)

			prev_insulators = insulator_positions
			dist += spacing
