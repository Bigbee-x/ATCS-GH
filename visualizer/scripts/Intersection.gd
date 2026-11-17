extends Node3D
const Net = preload("res://scripts/CorridorGeometry.gd")
const Transit = preload("res://scripts/TransitLayout.gd")
const StreetLamp = preload("res://scripts/StreetLamp.gd")

const Signals = preload("res://scripts/SignalHardware.gd")
const PowerLines = preload("res://scripts/PowerLines.gd")
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
const ROAD_LENGTH     := 1500.0   # Length of each road arm (Godot units)
const NS_ROAD_WIDTH   := 12.8    # Achimota Forest Rd: 2 lanes per direction
const E_ROAD_WIDTH    := 12.8    # Aggrey Street: 2 lanes per direction
const W_ROAD_WIDTH    := 12.8    # Guggisberg Street: 2 lanes per direction
const ROAD_THICKNESS  := 0.1    # Road surface height
const JUNCTION_SIZE   := 16.8    # Central junction (slight widening at intersection)
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
	var roads := preload("res://scripts/MetricRoadBuilder.gd").new()
	roads.name = "MetricRoads"
	roads.corridor_mode = false
	add_child(roads)
	roads.build()
	_build_traffic_lights()
	#_build_lane_overlays()  # Disabled — visual clutter on dark roads
	_build_street_lights()
	_build_utility_poles()
	_build_emergency_overlay()


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
	ground.size = Vector3(4000.0, 0.02, 4000.0)
	ground.position = Vector3(0, -0.06, 0)
	ground.material = _mat_grass
	ground.name = "Ground"
	ground.use_collision = true   # Walkable floor for ground-mode player
	add_child(ground)


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
	var along: float = 12.5   # 5.5 — well past junction edge

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

		var head_over: Dictionary = _build_overhead_head(pole_root, -(ARM_LEN - NS_ROAD_WIDTH*0.25), POLE_HEIGHT)
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

func _build_street_lights() -> void:
	for path in Net.sidewalks(false):
		var start: Vector3 = path.start
		var end: Vector3 = path.end
		var tangent := (end-start).normalized()
		var outward := Vector3(-tangent.z,0,tangent.x)
		for i in range(int((start.distance_to(end)-32)/32.0)):
			var at := start+tangent*(24+i*32.0)+outward*1.1
			if _in_station_plot(at): continue
			var lamp := StreetLamp.new()
			lamp.position = at
			lamp.rotation.y = atan2(-outward.x,-outward.z)
			add_child(lamp)
			_street_lights.append(lamp)

func _in_station_plot(at: Vector3) -> bool:
	for spec in Transit.stations(false):
		if Transit.plot(spec).grow(1.0).has_point(Vector2(at.x,at.z)): return true
	return false

func set_street_lights_night(enabled: bool) -> void:
	for lamp in _street_lights:
		lamp.set_night(enabled)

func _build_utility_poles() -> void:
	## Overhead lines down ONE side of each road arm (PowerLines.gd): a pole every
	## 22 m from just beyond the junction to the end of the arm, cross-arms across
	## the road, transformers hanging on the field side.
	var half_junc: float = JUNCTION_SIZE / 2.0
	var arms: Array = [
		{"dir": Vector3(0, 0, 1),  "width": NS_ROAD_WIDTH},
		{"dir": Vector3(0, 0, -1), "width": NS_ROAD_WIDTH},
		{"dir": Vector3(-1, 0, 0), "width": E_ROAD_WIDTH},
		{"dir": Vector3(1, 0, 0),  "width": W_ROAD_WIDTH},
	]
	for arm_info in arms:
		var direction: Vector3 = arm_info["dir"]
		var side_offset: float = float(arm_info["width"]) / 2.0 + SIDEWALK_WIDTH + 1.25
		var lateral: Vector3 = Vector3(side_offset, 0, 0) if absf(direction.z) > 0.0 else Vector3(0, 0, side_offset)
		var bases: Array[Vector3] = []
		var dist: float = half_junc + 8.0
		while dist < ROAD_LENGTH - 3.0:
			var at := direction*dist+lateral
			if not _in_station_plot(at): bases.append(at)
			dist += 40.0
		PowerLines.run(self, bases, lateral.normalized(), lateral.normalized())
