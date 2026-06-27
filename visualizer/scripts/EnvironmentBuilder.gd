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
const BUILDING_OFFSET := 2.6     # Setback: sidewalk edge → building face
                                 # (was 0.5 — buildings loomed over the road;
                                 # now gutter 0.6 + verge ~2.0 sit between)
const MIN_GAP         := 0.3     # Minimum gap between buildings
const MAX_GAP         := 1.5     # Maximum gap between buildings
const JUNCTION_MARGIN := 5.5     # Don't place buildings too close to junction
                                 # (was 3.0 — crowded the TL poles/cabinets)
const ROAD_END_MARGIN := 5.0     # Don't place buildings at road edge

# ── Open roadside drainage (classic Accra concrete U-gutters) ───────────────
const GUTTER_WIDTH        := 0.6    # channel width, runs beside the sidewalk
const GUTTER_RIM_W        := 0.10   # concrete rim thickness each side
const GUTTER_RIM_H        := 0.15   # rim height (matches sidewalk curb)
const GUTTER_BRIDGE_EVERY := 7.0    # avg spacing of access slab bridges
const GUTTER_FLOOR_COLOR  := Color(0.10, 0.11, 0.12)   # dark channel interior
const GUTTER_CONCRETE     := Color(0.62, 0.60, 0.56)   # weathered concrete
const GUTTER_SLAB_COLOR   := Color(0.68, 0.66, 0.62)   # slightly lighter slabs

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

# ── District palettes (quadrant fill) ───────────────────────────────────────
const GLASS_COLORS: Array = [
	Color(0.35, 0.50, 0.65),   # Blue-tinted glass
	Color(0.40, 0.55, 0.60),   # Teal glass
	Color(0.50, 0.55, 0.60),   # Silver glass
	Color(0.30, 0.42, 0.55),   # Deep blue
]

const TOWER_BASE_COLORS: Array = [
	Color(0.85, 0.85, 0.88),   # White
	Color(0.55, 0.58, 0.62),   # Concrete gray
	Color(0.75, 0.72, 0.68),   # Warm concrete
	Color(0.92, 0.88, 0.78),   # Cream tower
]

const SCHOOL_COLORS: Array = [
	Color(0.92, 0.88, 0.75),   # Cream
	Color(0.88, 0.82, 0.68),   # Light tan
]

const CAR_COLORS: Array = [
	Color(0.85, 0.20, 0.15),   # Red
	Color(0.20, 0.35, 0.70),   # Blue
	Color(0.90, 0.90, 0.88),   # White
	Color(0.15, 0.15, 0.18),   # Black
	Color(0.82, 0.80, 0.30),   # Yellow-ish
	Color(0.60, 0.62, 0.65),   # Silver
]

const TREE_GREENS: Array = [
	Color(0.22, 0.42, 0.20),   # Dark green
	Color(0.32, 0.52, 0.26),   # Olive
	Color(0.28, 0.58, 0.28),   # Medium
	Color(0.40, 0.62, 0.32),   # Bright
]

const PITCH_GREEN       := Color(0.30, 0.55, 0.28)
const ASPHALT           := Color(0.16, 0.16, 0.17)
const ROOF_DARK         := Color(0.22, 0.20, 0.18)
const TRUNK_COLOR       := Color(0.35, 0.25, 0.18)
const CROSS_WHITE       := Color(0.95, 0.93, 0.90)

# ── Quadrant layout ─────────────────────────────────────────────────────────
# Usable quadrant interior (behind the along-road strip) roughly spans
# |x| ∈ [15, 85] and |z| ∈ [15, 85]. Sign pairs:
#   NE visually = (x_sign=-1, z_sign=+1)   (east extends in -X in this project)
#   NW visually = (x_sign=+1, z_sign=+1)
#   SE visually = (x_sign=-1, z_sign=-1)
#   SW visually = (x_sign=+1, z_sign=-1)
const TREES_PER_QUADRANT := 18

# ── Shared materials (created once) ─────────────────────────────────────────
var _materials: Dictionary = {}   # Color hash → StandardMaterial3D

# ── Emissive materials for night-time glow (toggled via TimeOfDayManager) ───
var _mat_window_warm: StandardMaterial3D   # House / residential windows (full-night)
var _mat_window_cool: StandardMaterial3D   # Office / tower windows (full-night)
## "_early" variants turn on at dusk (16:30) instead of waiting for full dark.
## A fraction of window assignments use these so some buildings light up before
## sundown — mirrors real-world behaviour where some residents flip lights on
## as darkness approaches and others wait.
var _mat_window_warm_early: StandardMaterial3D
var _mat_window_cool_early: StandardMaterial3D
var _mat_sign_glow: StandardMaterial3D     # Mall signage, bright commercial
var _mat_stadium_cap: StandardMaterial3D   # Stadium light heads
var _mat_canopy_glow: StandardMaterial3D   # Petrol under-canopy
var _mat_cross_white: StandardMaterial3D   # Church cross
var _mat_cross_red: StandardMaterial3D     # Clinic red cross
var _mat_sodium_glow: StandardMaterial3D   # Industrial yard floods (warm orange)

## Fraction of window assignments that use the "_early" dusk-lit variant.
## 0.0 = no buildings come on early, 1.0 = every building does. 0.40 gives
## a pleasant scatter of "some lights on" at dusk.
const DUSK_EARLY_WINDOW_FRAC: float = 0.40
## Dusk-time emission intensity (dimmer than full-night so the transition
## reads as evolving toward darkness rather than popping on full-blast).
const DUSK_WINDOW_EMISSION: float = 1.2
## Full-night emission intensity (same as the pre-dusk value for _mat_window_warm).
const NIGHT_WINDOW_EMISSION: float = 2.2

# ── Roadside facade detail (doors + windows with interior light) ────────────
## Door dimensions and open-vs-closed probabilities for roadside buildings.
## Open doors use a warm emissive material (_pick_window_warm) so they look
## like "light spilling out through the doorway"; closed doors use a dark
## wood panel.
const ROADSIDE_DOOR_HEIGHT: float = 1.7
const ROADSIDE_DOOR_WIDTH_HOUSE: float = 0.75
const ROADSIDE_DOOR_WIDTH_SHOP: float = 1.05
const ROADSIDE_DOOR_OPEN_PROB_HOUSE: float = 0.35
const ROADSIDE_DOOR_OPEN_PROB_SHOP: float = 0.60
const ROADSIDE_WINDOW_WIDTH: float = 0.55
const ROADSIDE_WINDOW_HEIGHT: float = 0.65
const ROADSIDE_UPPER_WINDOW_WIDTH: float = 0.55
const ROADSIDE_UPPER_WINDOW_HEIGHT: float = 0.55
const ROADSIDE_DETAIL_PROTRUDE: float = 0.035   # How far detail sits off facade (anti-z-fight)
const ROADSIDE_DOOR_DARK: Color = Color(0.18, 0.12, 0.08)  # Stained wood

var _is_dusk: bool = false
var _is_night: bool = false

# ── OmniLight3D instances toggled at night ──────────────────────────────────
var _stadium_lights: Array[OmniLight3D] = []
var _yard_lights: Array[OmniLight3D] = []   # Industrial yard floods
var _petrol_light: OmniLight3D = null

# ── Tree-exclusion zones (world-space rects: [x_min, z_min, x_max, z_max]) ──
# Populated by things like the football pitch so trees don't spawn on the field.
# Corridor mode: set true on the corridor scene's EnvironmentBuilder node so
# _ready() builds the 3-junction streetscape instead of the single-junction one.
@export var corridor_mode: bool = false
# Added to every _compute_position result so building rows can be offset to each
# corridor junction. Stays Vector3.ZERO for the single junction (no-op).
var _placement_origin: Vector3 = Vector3.ZERO

var _exclusion_zones: Array = []

# ── RNG ─────────────────────────────────────────────────────────────────────
var _rng: RandomNumberGenerator


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = 42  # Deterministic placement

	# Create shared emissive materials BEFORE any buildings reference them
	_create_glow_materials()

	if corridor_mode:
		_build_corridor()
	else:
		# Build along each of the 4 road arms of the single junction
		# format: [arm_name, road_axis (0=X, 1=Z), dir_sign (+1/-1), road_width]
		var arms: Array = [
			["north", 1,  1.0, NS_ROAD_WIDTH],
			["south", 1, -1.0, NS_ROAD_WIDTH],
			["east",  0, -1.0, E_ROAD_WIDTH],   # Negated because Godot X is mirrored
			["west",  0,  1.0, W_ROAD_WIDTH],
		]
		for arm in arms:
			var arm_name: String = arm[0]
			var axis: int = arm[1]
			var dir_sign: float = arm[2]
			var road_w: float = arm[3]
			_build_arm_buildings(arm_name, axis, dir_sign, road_w)
			_build_arm_gutters(axis, dir_sign, road_w)
		# Junction corner anchors + quadrant districts (single junction only)
		_build_junction_corners()
		_build_quadrants()

	# Hook into day/night cycle so emissive materials + OmniLights toggle correctly
	_wire_day_night()

	# Enable collision on all CSG geometry so the ground-level player can't walk
	# through buildings, tanks, goal posts, etc. Small decorative CSGs above
	# head-height are harmless — the player can't reach them anyway.
	_enable_collision_on_all_csg(self)

	print("[EnvironmentBuilder] Built Accra streetscape + 4 quadrant districts + lights")


func _enable_collision_on_all_csg(node: Node) -> void:
	## Recursively turn on use_collision for every CSG primitive under `node`.
	## Building bodies, walls, tanks, lamp posts, poles, and goal frames all
	## become solid — the player's CharacterBody3D capsule will stop against them.
	for child in node.get_children():
		if child is CSGBox3D:
			(child as CSGBox3D).use_collision = true
		elif child is CSGCylinder3D:
			(child as CSGCylinder3D).use_collision = true
		elif child is CSGSphere3D:
			(child as CSGSphere3D).use_collision = true
		if child.get_child_count() > 0:
			_enable_collision_on_all_csg(child)


# ═════════════════════════════════════════════════════════════════════════════
# LIGHTING SYSTEM (night-time glow)
# ═════════════════════════════════════════════════════════════════════════════

func _create_glow_materials() -> void:
	## Build all shared emissive materials. Emission energy starts at 0.0 so the
	## materials look normal during the day; _on_night_mode_changed() bumps them.

	# Warm window (residential houses) — yellow-orange domestic glow.
	# VISUAL FIX (2026-06-07): albedo is now DARK GLASS, not warm cream. The old
	# cream albedo looked like a flat beige panel pasted on the wall in daylight
	# (emission is off during the day). A dark, slightly-reflective glass tone
	# reads as a real window pane when unlit; the warm emission still drives the
	# night glow (emission is additive and dominates once the multiplier ramps).
	_mat_window_warm = StandardMaterial3D.new()
	_mat_window_warm.albedo_color = Color(0.14, 0.17, 0.22)   # dark glass (day look)
	_mat_window_warm.roughness = 0.15                          # low = reflective glass
	_mat_window_warm.metallic = 0.35
	_mat_window_warm.emission_enabled = true
	_mat_window_warm.emission = Color(1.00, 0.82, 0.45)        # warm glow (night look)
	_mat_window_warm.emission_energy_multiplier = 0.0

	# Cool window (offices / towers / schools) — blue-white fluorescent.
	# Same day/night split: dark blue glass when unlit, cool glow at night.
	_mat_window_cool = StandardMaterial3D.new()
	_mat_window_cool.albedo_color = Color(0.13, 0.18, 0.26)   # dark blue glass (day look)
	_mat_window_cool.roughness = 0.12
	_mat_window_cool.metallic = 0.40
	_mat_window_cool.emission_enabled = true
	_mat_window_cool.emission = Color(0.82, 0.92, 1.00)       # cool glow (night look)
	_mat_window_cool.emission_energy_multiplier = 0.0

	# "_early" dusk-lit variants — same look as the full-night materials, but
	# their emission ramps up at DUSK (4:30 PM) instead of waiting for 6 PM.
	# Buildings that get these materials appear to have their occupants turn
	# on the lights before sundown.
	_mat_window_warm_early = StandardMaterial3D.new()
	_mat_window_warm_early.albedo_color = _mat_window_warm.albedo_color
	_mat_window_warm_early.roughness = _mat_window_warm.roughness
	_mat_window_warm_early.metallic = _mat_window_warm.metallic
	_mat_window_warm_early.emission_enabled = true
	_mat_window_warm_early.emission = _mat_window_warm.emission
	_mat_window_warm_early.emission_energy_multiplier = 0.0

	_mat_window_cool_early = StandardMaterial3D.new()
	_mat_window_cool_early.albedo_color = _mat_window_cool.albedo_color
	_mat_window_cool_early.roughness = _mat_window_cool.roughness
	_mat_window_cool_early.metallic = _mat_window_cool.metallic
	_mat_window_cool_early.emission_enabled = true
	_mat_window_cool_early.emission = _mat_window_cool.emission
	_mat_window_cool_early.emission_energy_multiplier = 0.0

	# Mall / commercial signage — bright orange-red
	_mat_sign_glow = StandardMaterial3D.new()
	_mat_sign_glow.albedo_color = Color(0.95, 0.42, 0.20)
	_mat_sign_glow.roughness = 0.3
	_mat_sign_glow.emission_enabled = true
	_mat_sign_glow.emission = Color(1.00, 0.58, 0.30)
	_mat_sign_glow.emission_energy_multiplier = 0.0

	# Stadium lamp head — bright white
	_mat_stadium_cap = StandardMaterial3D.new()
	_mat_stadium_cap.albedo_color = Color(0.95, 0.95, 0.88)
	_mat_stadium_cap.roughness = 0.2
	_mat_stadium_cap.emission_enabled = true
	_mat_stadium_cap.emission = Color(1.00, 0.98, 0.90)
	_mat_stadium_cap.emission_energy_multiplier = 0.0

	# Petrol station under-canopy glow panel
	_mat_canopy_glow = StandardMaterial3D.new()
	_mat_canopy_glow.albedo_color = Color(0.96, 0.94, 0.85)
	_mat_canopy_glow.roughness = 0.5
	_mat_canopy_glow.emission_enabled = true
	_mat_canopy_glow.emission = Color(1.00, 0.96, 0.80)
	_mat_canopy_glow.emission_energy_multiplier = 0.0

	# Church cross — warm white
	_mat_cross_white = StandardMaterial3D.new()
	_mat_cross_white.albedo_color = CROSS_WHITE
	_mat_cross_white.roughness = 0.4
	_mat_cross_white.emission_enabled = true
	_mat_cross_white.emission = Color(1.00, 0.95, 0.88)
	_mat_cross_white.emission_energy_multiplier = 0.0

	# Clinic red cross — saturated red beacon
	_mat_cross_red = StandardMaterial3D.new()
	_mat_cross_red.albedo_color = Color(0.95, 0.18, 0.15)
	_mat_cross_red.roughness = 0.4
	_mat_cross_red.emission_enabled = true
	_mat_cross_red.emission = Color(1.00, 0.22, 0.15)
	_mat_cross_red.emission_energy_multiplier = 0.0

	# Industrial sodium flood-light lamp heads (warm orange)
	_mat_sodium_glow = StandardMaterial3D.new()
	_mat_sodium_glow.albedo_color = Color(1.00, 0.85, 0.55)
	_mat_sodium_glow.roughness = 0.3
	_mat_sodium_glow.emission_enabled = true
	_mat_sodium_glow.emission = Color(1.00, 0.78, 0.40)
	_mat_sodium_glow.emission_energy_multiplier = 0.0


func _wire_day_night() -> void:
	## Connect to the sibling TimeOfDayManager so we flip emissive energy
	## and OmniLight visibility whenever day/night mode changes.
	var tod: Node = get_parent().get_node_or_null("TimeOfDayManager")
	if tod == null:
		# Running without day/night manager — leave materials in day state
		return
	if tod.has_signal("night_mode_changed"):
		tod.night_mode_changed.connect(_on_night_mode_changed)
	if tod.has_signal("dusk_mode_changed"):
		tod.dusk_mode_changed.connect(_on_dusk_mode_changed)
	# Apply current state immediately so nothing is "stuck dim" on load.
	# Call night first, then dusk — dusk-lit materials are driven by
	# _apply_window_emission() which reads both flags.
	if tod.has_method("is_night"):
		_is_night = tod.is_night()
	if tod.has_method("is_dusk"):
		_is_dusk = tod.is_dusk()
	_apply_light_state()


func _on_night_mode_changed(is_night: bool) -> void:
	_is_night = is_night
	_apply_light_state()


func _on_dusk_mode_changed(is_dusk: bool) -> void:
	_is_dusk = is_dusk
	_apply_light_state()


func _apply_light_state() -> void:
	## Update emission multipliers from the current (dusk, night) pair,
	## and toggle scene-affecting OmniLights. Called whenever either state
	## changes.
	##
	## State matrix:
	##   neither     → everything dark (full daylight)
	##   dusk only   → _early window materials at partial intensity;
	##                 late-night materials stay dark; OmniLights off
	##   dusk + night → all window materials at full intensity;
	##                  OmniLights on, signage/stadium/canopy on
	##   night only  → shouldn't happen (dusk is a superset), but handle
	##                 defensively as "night" state
	var night: bool = _is_night
	var dusk_only: bool = _is_dusk and not _is_night

	# Window materials
	if _mat_window_warm:
		_mat_window_warm.emission_energy_multiplier = NIGHT_WINDOW_EMISSION if night else 0.0
	if _mat_window_cool:
		_mat_window_cool.emission_energy_multiplier = NIGHT_WINDOW_EMISSION if night else 0.0
	# Early-dusk variants: dimmer during dusk-only, full at night, off during day
	var early_e: float = 0.0
	if night:
		early_e = NIGHT_WINDOW_EMISSION
	elif dusk_only:
		early_e = DUSK_WINDOW_EMISSION
	if _mat_window_warm_early:
		_mat_window_warm_early.emission_energy_multiplier = early_e
	if _mat_window_cool_early:
		_mat_window_cool_early.emission_energy_multiplier = early_e

	# Signage, stadium, canopy, crosses, sodium — all still night-only
	# (sodium lights would actually come on at dusk via photocell in real
	# life, but that can be a follow-up tweak).
	var sign_e: float = 2.8 if night else 0.0
	var stadium_e: float = 3.5 if night else 0.0
	var canopy_e: float = 2.6 if night else 0.0
	var cross_e: float = 2.0 if night else 0.0
	var sodium_e: float = 3.0 if night else 0.0
	if _mat_sign_glow:
		_mat_sign_glow.emission_energy_multiplier = sign_e
	if _mat_stadium_cap:
		_mat_stadium_cap.emission_energy_multiplier = stadium_e
	if _mat_canopy_glow:
		_mat_canopy_glow.emission_energy_multiplier = canopy_e
	if _mat_cross_white:
		_mat_cross_white.emission_energy_multiplier = cross_e
	if _mat_cross_red:
		_mat_cross_red.emission_energy_multiplier = cross_e
	if _mat_sodium_glow:
		_mat_sodium_glow.emission_energy_multiplier = sodium_e

	# Scene-affecting OmniLights: only at full night
	for light in _stadium_lights:
		if light:
			light.visible = night
	for light in _yard_lights:
		if light:
			light.visible = night
	if _petrol_light:
		_petrol_light.visible = night


# ── Dusk window material pickers ────────────────────────────────────────────
## Use these in place of direct `_mat_window_warm` / `_mat_window_cool`
## references when creating windows. Each call rolls the RNG and returns
## the "_early" variant ~DUSK_EARLY_WINDOW_FRAC of the time so some windows
## light up before sundown.

func _pick_window_warm() -> StandardMaterial3D:
	if _rng.randf() < DUSK_EARLY_WINDOW_FRAC:
		return _mat_window_warm_early
	return _mat_window_warm


func _pick_window_cool() -> StandardMaterial3D:
	if _rng.randf() < DUSK_EARLY_WINDOW_FRAC:
		return _mat_window_cool_early
	return _mat_window_cool


# ═════════════════════════════════════════════════════════════════════════════
# ROADSIDE FACADE DECORATION (doors + windows with interior light)
# ═════════════════════════════════════════════════════════════════════════════

func _decorate_roadside_facade(body_center: Vector3, width: float,
								height: float, depth: float,
								road_dir: Vector3, lateral_dir: Vector3,
								is_shop: bool) -> void:
	## Place a door and one or two rows of windows on the road-facing face of a
	## roadside building. Doors have a chance to be "open" (warm-lit aperture);
	## closed doors get a dark wood panel. Windows use `_pick_window_warm()`
	## so some light up at golden hour and others hold out until full night —
	## this integrates with the existing dusk system in _apply_light_state().
	##
	## body_center: center of the building body (height/2 above ground)
	## width:       dimension along the road (lateral)
	## height:      building height from ground
	## depth:       dimension perpendicular to road (into building)
	## road_dir:    unit vector pointing outward from the facade toward the road
	## lateral_dir: unit vector along the facade (perpendicular to road_dir, horizontal)
	## is_shop:     true for shop fronts (wider door, higher open probability)
	##
	## Details sit ROADSIDE_DETAIL_PROTRUDE outside the facade plane to avoid
	## z-fighting with the body geometry.
	var lateral_is_x: bool = abs(lateral_dir.x) > 0.5

	# Facade plane sits at body_center.xz + road_dir * depth/2. We push
	# details a tiny bit beyond that so they render cleanly against the body.
	var facade_base: Vector3 = Vector3(body_center.x, 0.0, body_center.z) \
							   + road_dir * (depth / 2.0 + ROADSIDE_DETAIL_PROTRUDE)

	# ── Door ────────────────────────────────────────────────────────────────
	var door_width: float = ROADSIDE_DOOR_WIDTH_SHOP if is_shop else ROADSIDE_DOOR_WIDTH_HOUSE
	door_width = min(door_width, width * 0.55)
	var door_height: float = min(ROADSIDE_DOOR_HEIGHT, height * 0.75)
	var door_open_prob: float = ROADSIDE_DOOR_OPEN_PROB_SHOP if is_shop else ROADSIDE_DOOR_OPEN_PROB_HOUSE
	var door_is_open: bool = _rng.randf() < door_open_prob

	var door := CSGBox3D.new()
	if lateral_is_x:
		door.size = Vector3(door_width, door_height, 0.06)
	else:
		door.size = Vector3(0.06, door_height, door_width)
	door.position = facade_base + Vector3(0.0, door_height / 2.0, 0.0)
	if door_is_open:
		door.material = _pick_window_warm()   # Warm interior glow spilling out
	else:
		door.material = _get_material(ROADSIDE_DOOR_DARK)
	door.name = "RoadsideDoor"
	add_child(door)

	# ── Ground-floor flanking windows (skip if body is too narrow) ─────────
	var gw_half_span: float = door_width / 2.0 + 0.32 + ROADSIDE_WINDOW_WIDTH / 2.0
	var facade_margin: float = width / 2.0 - ROADSIDE_WINDOW_WIDTH / 2.0 - 0.12
	if gw_half_span <= facade_margin:
		var gw_y: float = min(door_height * 0.55 + 0.15,
							  height - ROADSIDE_WINDOW_HEIGHT / 2.0 - 0.2)
		for side in [-1.0, 1.0]:
			var gwin := CSGBox3D.new()
			if lateral_is_x:
				gwin.size = Vector3(ROADSIDE_WINDOW_WIDTH, ROADSIDE_WINDOW_HEIGHT, 0.05)
			else:
				gwin.size = Vector3(0.05, ROADSIDE_WINDOW_HEIGHT, ROADSIDE_WINDOW_WIDTH)
			gwin.position = facade_base + Vector3(0.0, gw_y, 0.0) \
							+ lateral_dir * (side * gw_half_span)
			gwin.material = _pick_window_warm()
			gwin.name = "RoadsideWindowGround"
			add_child(gwin)

	# ── Upper-floor window row (only if tall enough for a 2nd storey) ──────
	if height >= 2.8:
		var upper_y: float = height - 0.8
		var num_windows: int = max(2, int(width / 1.3))
		for i in range(num_windows):
			# Distribute windows across the facade, evenly spaced
			var t_norm: float = (float(i) + 1.0) / (float(num_windows) + 1.0) - 0.5
			var lateral_t: float = t_norm * (width - 0.5)
			var uwin := CSGBox3D.new()
			if lateral_is_x:
				uwin.size = Vector3(ROADSIDE_UPPER_WINDOW_WIDTH,
									ROADSIDE_UPPER_WINDOW_HEIGHT, 0.05)
			else:
				uwin.size = Vector3(0.05, ROADSIDE_UPPER_WINDOW_HEIGHT,
									ROADSIDE_UPPER_WINDOW_WIDTH)
			uwin.position = facade_base + Vector3(0.0, upper_y, 0.0) \
							+ lateral_dir * lateral_t
			uwin.material = _pick_window_warm()
			uwin.name = "RoadsideWindowUpper"
			add_child(uwin)


# ═════════════════════════════════════════════════════════════════════════════
# EXCLUSION ZONES (prevent trees spawning on top of special features)
# ═════════════════════════════════════════════════════════════════════════════

func _add_exclusion_zone(x_min: float, z_min: float, x_max: float, z_max: float) -> void:
	## Register a world-space AABB. _scatter_trees skips any position inside any zone.
	_exclusion_zones.append([x_min, z_min, x_max, z_max])


func _in_exclusion_zone(x: float, z: float) -> bool:
	for zone in _exclusion_zones:
		if x >= zone[0] and x <= zone[2] and z >= zone[1] and z <= zone[3]:
			return true
	return false


# ═════════════════════════════════════════════════════════════════════════════
# ARM BUILDING GENERATION
# ═════════════════════════════════════════════════════════════════════════════

func _build_arm_buildings(_arm_name: String, axis: int, dir_sign: float,
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
				building_length = _place_block_building(axis, dir_sign, cursor, perp_offset, side_sign)
			elif roll < 0.75:
				building_length = _place_shop_front(axis, dir_sign, cursor, perp_offset, side_sign)
			elif roll < 0.85:
				building_length = _place_compound_wall(axis, dir_sign, cursor, perp_offset, side_sign)
			else:
				building_length = _place_market_stalls(axis, dir_sign, cursor, perp_offset, side_sign)

			cursor += building_length + _rng.randf_range(MIN_GAP, MAX_GAP)


func _build_arm_gutters(axis: int, dir_sign: float, road_width: float) -> void:
	## Open concrete drainage gutters along both sides of a road arm, in the
	## strip between the sidewalk and the building setback, with periodic slab
	## bridges so frontages stay accessible — the classic Accra streetscape.
	var inner: float = road_width / 2.0 + SIDEWALK_WIDTH       # channel inner edge
	var outer: float = inner + GUTTER_WIDTH                     # channel outer edge
	var g_start: float = JUNCTION_HALF + 1.2                    # past the corner zone
	var g_end: float = JUNCTION_HALF + ROAD_LENGTH - 1.0
	var g_len: float = g_end - g_start
	var g_mid: float = (g_start + g_end) / 2.0

	for side_sign in [-1.0, 1.0]:
		# Dark channel interior (reads as the recessed open drain)
		var channel := CSGBox3D.new()
		channel.size = _orient_size(axis, g_len, 0.04, GUTTER_WIDTH)
		channel.position = _compute_position(axis, dir_sign, g_mid,
				side_sign * inner, side_sign, GUTTER_WIDTH) + Vector3(0, 0.02, 0)
		channel.material = _get_material(GUTTER_FLOOR_COLOR)
		channel.name = "GutterChannel"
		add_child(channel)

		# Concrete rims on both edges of the channel
		for rim_inner_edge in [inner - GUTTER_RIM_W, outer]:
			var rim := CSGBox3D.new()
			rim.size = _orient_size(axis, g_len, GUTTER_RIM_H, GUTTER_RIM_W)
			rim.position = _compute_position(axis, dir_sign, g_mid,
					side_sign * rim_inner_edge, side_sign, GUTTER_RIM_W) \
					+ Vector3(0, GUTTER_RIM_H / 2.0, 0)
			rim.material = _get_material(GUTTER_CONCRETE)
			rim.name = "GutterRim"
			add_child(rim)

		# Access slab bridges across the channel at irregular intervals
		var span: float = GUTTER_WIDTH + 2.0 * GUTTER_RIM_W
		var cursor: float = g_start + _rng.randf_range(1.0, 3.5)
		while cursor < g_end - 1.5:
			var slab := CSGBox3D.new()
			slab.size = _orient_size(axis, 1.1, 0.06, span)
			slab.position = _compute_position(axis, dir_sign, cursor,
					side_sign * (inner - GUTTER_RIM_W), side_sign, span) \
					+ Vector3(0, GUTTER_RIM_H + 0.01, 0)
			slab.material = _get_material(GUTTER_SLAB_COLOR)
			slab.name = "GutterBridge"
			add_child(slab)
			cursor += GUTTER_BRIDGE_EVERY + _rng.randf_range(-1.5, 2.5)


# ═════════════════════════════════════════════════════════════════════════════
# CORRIDOR STREETSCAPE (3-junction) — reuses the single-junction primitives
# ═════════════════════════════════════════════════════════════════════════════

func _build_corridor() -> void:
	## Accra streetscape along the 3-junction corridor: building rows down both
	## curbs of the N/S corridor + both curbs of every cross-street arm, plus a
	## few landmark structures in the open blocks. Mirrors CorridorBuilder.gd
	## geometry (junctions at Z 0/30/60, NS road half 3, cross/boundary arms 55).
	var junctions: Array = [0.0, 30.0, 60.0]
	var junc_half: float = 3.0
	var ns_half: float = 3.0
	var cross_arm: float = 55.0
	var boundary: float = 55.0
	var z_min: float = junctions[0] - junc_half - boundary    # -58
	var z_max: float = junctions[2] + junc_half + boundary    # 118
	var face_off: float = ns_half + SIDEWALK_WIDTH + BUILDING_OFFSET   # curb → building face

	# Keep the institutional block (around the football pitch, +X / J0–J1) clear
	# of generic frontage — registered BEFORE the frontage loops so they skip it.
	# _corridor_institutional() then fills it deliberately (car park + trees),
	# keeping only the big buildings (school + church).
	_add_exclusion_zone(12.0, 5.0, 46.0, 27.0)
	# Same for the hospital campus on the −X flank — it owns its block too.
	_add_exclusion_zone(-50.0, 4.0, -10.0, 28.0)

	# ── Building rows down both curbs of the N/S corridor ──────────────────
	_placement_origin = Vector3(0, 0, z_min)
	var span: float = z_max - z_min
	for side_sign in [-1.0, 1.0]:
		for row in range(2):                       # 2 frontage rows (districts fill behind)
			var perp: float = side_sign * (face_off + row * 9.0)
			var along: float = 4.0 + row * 3.0     # stagger so rows don't line up
			while along < span - 4.0:
				if _near_corridor_junction(z_min + along, junctions, junc_half + 6.0):
					along += 5.0
					continue
				along += _place_corridor_building(1, 1.0, along, perp, side_sign) \
						+ _rng.randf_range(MIN_GAP, MAX_GAP)
	_placement_origin = Vector3.ZERO

	# ── Building rows along each junction's E/W cross-street arms ───────────
	for cz in junctions:
		_placement_origin = Vector3(0, 0, cz)
		for dir_sign in [-1.0, 1.0]:   # east reaches -X, west reaches +X (mirrored)
			for side_sign in [-1.0, 1.0]:
				for row in range(1):
					var perp2: float = side_sign * (face_off + row * 9.0)
					var d: float = junc_half + JUNCTION_MARGIN + row * 3.0
					var d_end: float = junc_half + cross_arm - ROAD_END_MARGIN
					while d < d_end:
						d += _place_corridor_building(0, dir_sign, d, perp2, side_sign) \
								+ _rng.randf_range(MIN_GAP, MAX_GAP)
	_placement_origin = Vector3.ZERO

	# ── Zoned districts — one themed district per flanking block, placed beyond
	#    the frontage rows (mirrors the single-junction quadrants). Easy to
	#    rearrange: just swap which helper goes at which block centre. ─────────
	_placement_origin = Vector3.ZERO
	_place_airport(38.0, 96.0)                # north boundary +X — shifted north so the runway clears the J2 cross-street frontage
	_corridor_industrial(-38.0, 88.0)         # north boundary −X
	_corridor_offices(38.0, 45.0)             # J1–J2 +X — commercial / skyscrapers
	_corridor_residential(-38.0, 45.0, 3, 1)  # J1–J2 −X — homes
	_corridor_institutional(38.0, 16.0)       # J0–J1 +X — school + pitch + church
	_corridor_hospital(-38.0, 16.0)           # J0–J1 −X
	_corridor_residential(38.0, -32.0, 3, 3)  # south boundary +X — suburb
	_corridor_market(-38.0, -32.0)            # south boundary −X — market + trotro
	_place_petrol_station(Vector3(24.0, 0, -10.0))
	_place_petrol_station(Vector3(-24.0, 0, 70.0))


func _place_corridor_building(axis: int, dir_sign: float, along: float,
		perp: float, side_sign: float) -> float:
	## Weighted random street building (mirrors _build_arm_buildings' picker).
	# Skip spots inside a registered keep-clear zone (e.g. the institutional
	# block) so a district can own its land instead of generic frontage.
	var probe: Vector3 = _compute_position(axis, dir_sign, along + 1.5, perp, side_sign, 3.0)
	if _in_exclusion_zone(probe.x, probe.z):
		return 3.0   # advance the cursor past this spot without building
	var roll: float = _rng.randf()
	if roll < 0.45:
		return _place_block_building(axis, dir_sign, along, perp, side_sign)
	elif roll < 0.75:
		return _place_shop_front(axis, dir_sign, along, perp, side_sign)
	elif roll < 0.85:
		return _place_compound_wall(axis, dir_sign, along, perp, side_sign)
	else:
		return _place_market_stalls(axis, dir_sign, along, perp, side_sign)


func _near_corridor_junction(z: float, junctions: Array, margin: float) -> bool:
	for cz in junctions:
		if absf(z - cz) < margin:
			return true
	return false


## ── Corridor districts — compose existing primitives at offsets from a block
##    centre (cx, cz). Offsets use cx+offset so the same formula works on the +X
##    and −X flanks (cx already carries the side's sign). ──────────────────────

func _corridor_offices(cx: float, cz: float) -> void:
	## Commercial core: tall glassy towers + mid-rise + parking.
	_place_office_tower(Vector3(cx - 12, 0, cz - 4), 8, 6.5, 6.5)
	_place_office_tower(Vector3(cx + 2, 0, cz + 5), 6, 6.0, 6.0)
	_place_midrise_office(Vector3(cx + 14, 0, cz - 5), 4, 5.0, 5.0)
	_place_midrise_office(Vector3(cx - 4, 0, cz + 7), 3, 4.5, 4.5)
	_place_parking_lot(Vector3(cx + 13, 0, cz + 6), 9.0, 5.0, 6)
	_place_stadium_light(Vector3(cx + 6, 0, cz))
	_add_exclusion_zone(cx - 20, cz - 12, cx + 20, cz + 12)


func _corridor_residential(cx: float, cz: float, cols: int, rows: int) -> void:
	## Homes — compound houses on a grid threaded by internal streets. The 3×3
	## south suburb's street grid (x=cx±7, z=cz±7.5) is matched by
	## ResidentialTrafficManager (corridor mode) so ambient cars drive it.
	for i in range(cols):
		for j in range(rows):
			var x: float = cx + (float(i) - (cols - 1) / 2.0) * 14.0
			var z: float = cz + (float(j) - (rows - 1) / 2.0) * 15.0
			var st: int = 1 if _rng.randf() < 0.4 else 2
			_place_house_compound(Vector3(x, 0, z), 11.0, st)
	# Internal streets between the rows/columns of compounds.
	var ns_len: float = (float(rows) - 1.0) * 15.0 + 14.0
	if cols >= 2:
		for sx in [cx - 7.0, cx + 7.0]:
			_place_residential_street(Vector3(sx, 0, cz), ns_len, true)
	if rows >= 2:
		for sz in [cz - 7.5, cz + 7.5]:
			_place_residential_street(Vector3(cx, 0, sz), 40.0, false)
		for lx in [cx - 7.0, cx + 7.0]:
			for lz in [cz - 7.5, cz + 7.5]:
				_place_residential_lamp(Vector3(lx, 0, lz))
	else:
		_place_residential_lamp(Vector3(cx, 0, cz))


func _corridor_institutional(cx: float, cz: float) -> void:
	## A clean sports/school grounds: the football pitch + the two big buildings
	## (school + church), with the rest of the block deliberately left open as a
	## car park and trees. The keep-clear zone registered in _build_corridor stops
	## generic frontage from cluttering this block.
	_place_football_pitch(Vector3(cx - 8, 0, cz), 18.0, 11.0)
	_place_school_building(Vector3(cx + 14, 0, cz + 3), 3, 11.0, 6.0)   # big — kept
	_place_church(Vector3(cx + 15, 0, cz - 6))                          # big — kept

	# Car park west of the pitch (serves the school + stadium)
	_place_parking_lot(Vector3(cx - 22, 0, cz), 6.0, 14.0, 12)

	# Trees dotted around the grounds (south edge, north edge, and the gap
	# between the pitch and the school) — all clear of the pitch and buildings.
	for t in [Vector3(cx - 14, 0, cz - 9), Vector3(cx - 4, 0, cz - 9),
			Vector3(cx + 4, 0, cz - 9), Vector3(cx - 10, 0, cz + 9),
			Vector3(cx, 0, cz + 9), Vector3(cx + 6, 0, cz + 8),
			Vector3(cx + 9, 0, cz)]:
		_place_tree(t)

	_place_residential_lamp(Vector3(cx + 5, 0, cz))


func _corridor_hospital(cx: float, cz: float) -> void:
	## A planned hospital campus on the −X flank: one H-block hospital with a
	## taller ward tower set back behind it, a patient car park, a roadside GOIL
	## filling station (advertised by the relocated GOIL billboard), and trees.
	## The keep-clear zone in _build_corridor keeps generic frontage out.
	_place_clinic(Vector3(cx + 4, 0, cz + 2))                        # main hospital (H-block)
	_place_midrise_office(Vector3(cx - 6, 0, cz + 2), 5, 8.0, 8.0)   # ward tower, set back
	_place_parking_lot(Vector3(cx + 14, 0, cz + 4), 9.0, 10.0, 12)   # patient car park
	_place_petrol_station(Vector3(cx + 21, 0, cz - 8))               # roadside GOIL station

	for t in [Vector3(cx - 8, 0, cz - 7), Vector3(cx - 9, 0, cz + 9),
			Vector3(cx + 6, 0, cz + 9), Vector3(cx - 2, 0, cz - 8),
			Vector3(cx + 24, 0, cz + 8)]:
		_place_tree(t)
	_place_residential_lamp(Vector3(cx + 24, 0, cz + 2))
	_place_residential_lamp(Vector3(cx + 1, 0, cz - 8))


func _corridor_industrial(cx: float, cz: float) -> void:
	## Industrial yard — factories, warehouse, tanks, container yard, trucks.
	_place_factory(Vector3(cx, 0, cz - 14), 20.0, 6.0, 12.0)
	_place_factory(Vector3(cx - 12, 0, cz + 14), 12.0, 4.5, 8.0)
	_place_warehouse(Vector3(cx + 14, 0, cz + 14), 12.0, 5.0, 9.0)
	_place_storage_tank(Vector3(cx + 14, 0, cz - 6), 2.4, 5.5)
	_place_storage_tank(Vector3(cx + 18, 0, cz - 1), 2.0, 4.8)
	_place_storage_tank(Vector3(cx + 13, 0, cz + 2), 1.8, 4.2)
	_place_container_yard(Vector3(cx - 2, 0, cz + 2))
	_place_tanker_truck(Vector3(cx - 16, 0, cz - 8))
	_place_flatbed_truck(Vector3(cx - 8, 0, cz - 4))
	_place_yard_light(Vector3(cx - 10, 0, cz + 6))
	_place_yard_light(Vector3(cx + 12, 0, cz + 18))
	_add_exclusion_zone(cx - 24, cz - 24, cx + 24, cz + 24)


func _corridor_market(cx: float, cz: float) -> void:
	## Market + transport — dense stalls, trotro station, a mall, parking.
	_place_dense_market_stalls(Vector3(cx - 6, 0, cz + 8), 4, 5)
	_place_dense_market_stalls(Vector3(cx + 12, 0, cz - 8), 3, 5)
	_place_trotro_station(Vector3(cx - 10, 0, cz - 12))
	_place_shopping_mall(Vector3(cx + 12, 0, cz + 12), 14.0, 5.0, 8.0)
	_place_parking_lot(Vector3(cx + 2, 0, cz - 2), 9.0, 5.0, 6)
	_place_stadium_light(Vector3(cx, 0, cz))


func _place_airport(cx: float, cz: float) -> void:
	## Airport district — a clean runway (centreline + threshold "piano keys"),
	## a concrete apron set off on the +X side carrying a long glass terminal
	## with a KOTOKA sign, a tall control tower with a red beacon, an arched
	## hangar, and parked jets at the gates. ALL buildings sit on the apron, well
	## clear of the runway (x ≥ ~50; runway right edge ≈ cx+4.5).
	var asphalt: StandardMaterial3D = _get_material(Color(0.15, 0.15, 0.17))
	var concrete: StandardMaterial3D = _get_material(Color(0.33, 0.33, 0.36))
	var paint: StandardMaterial3D = _get_material(Color(0.92, 0.92, 0.92))

	# ── Runway (long in Z) + centreline + threshold bars ──
	var runway := CSGBox3D.new()
	runway.size = Vector3(9.0, 0.12, 44.0)
	runway.position = Vector3(cx, 0.06, cz)
	runway.material = asphalt
	runway.name = "Runway"
	add_child(runway)
	var z: float = cz - 18.0
	while z <= cz + 18.0:
		var dash := CSGBox3D.new()
		dash.size = Vector3(0.5, 0.04, 2.6)
		dash.position = Vector3(cx, 0.13, z)
		dash.material = paint
		add_child(dash)
		z += 5.6
	for end_z in [cz - 20.5, cz + 20.5]:
		for k in range(-2, 3):
			var bar := CSGBox3D.new()
			bar.size = Vector3(0.7, 0.04, 3.0)
			bar.position = Vector3(cx + k * 1.5, 0.13, end_z)
			bar.material = paint
			add_child(bar)

	# ── Concrete apron on the +X side + taxiway link to the runway ──
	var apron := CSGBox3D.new()
	apron.size = Vector3(22.0, 0.08, 38.0)
	apron.position = Vector3(cx + 17.0, 0.04, cz)
	apron.material = concrete
	apron.name = "Apron"
	add_child(apron)
	var taxi := CSGBox3D.new()
	taxi.size = Vector3(8.0, 0.08, 8.0)
	taxi.position = Vector3(cx + 7.0, 0.05, cz)
	taxi.material = concrete
	add_child(taxi)

	# ── Terminal — long, low, glass curtain wall facing the runway (-X) ──
	var tx: float = cx + 22.0    # 60
	var term := CSGBox3D.new()
	term.size = Vector3(8.0, 6.0, 24.0)
	term.position = Vector3(tx, 3.0, cz)
	term.material = _get_material(Color(0.82, 0.84, 0.88))
	term.name = "AirportTerminal"
	add_child(term)
	var glassfront := CSGBox3D.new()           # glass curtain wall on the runway face
	glassfront.size = Vector3(1.4, 5.0, 23.0)
	glassfront.position = Vector3(tx - 4.4, 2.8, cz)
	glassfront.material = _get_glass_material(GLASS_COLORS[0])
	add_child(glassfront)
	var fascia := CSGBox3D.new()               # roof overhang
	fascia.size = Vector3(9.2, 0.6, 24.8)
	fascia.position = Vector3(tx, 6.3, cz)
	fascia.material = _get_material(Color(0.5, 0.52, 0.56))
	add_child(fascia)
	# KOTOKA rooftop sign facing the runway (Accra's real airport)
	var sign := Label3D.new()
	sign.text = "KOTOKA"
	sign.font_size = 48
	sign.pixel_size = 0.030
	sign.modulate = Color(0.95, 0.22, 0.20)
	sign.outline_size = 8
	sign.outline_modulate = Color(0, 0, 0, 0.5)
	sign.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	sign.rotation.y = -PI / 2.0                # face -X (toward the runway/approach)
	sign.position = Vector3(tx - 4.7, 7.5, cz)
	sign.name = "AirportSign"
	add_child(sign)

	# ── Control tower — tall, glass cab, red beacon ──
	var ctx: float = cx + 13.0   # 51 — between runway and terminal, clear of both
	var ctz: float = cz - 16.0
	var tower := CSGCylinder3D.new()
	tower.radius = 1.0
	tower.height = 17.0
	tower.sides = 12
	tower.position = Vector3(ctx, 8.5, ctz)
	tower.material = _get_material(Color(0.86, 0.87, 0.90))
	tower.name = "ControlTower"
	add_child(tower)
	var cab := CSGBox3D.new()
	cab.size = Vector3(3.4, 2.4, 3.4)
	cab.position = Vector3(ctx, 17.6, ctz)
	cab.material = _get_glass_material(GLASS_COLORS[1])
	add_child(cab)
	var cabroof := CSGCylinder3D.new()
	cabroof.radius = 2.1
	cabroof.height = 0.4
	cabroof.sides = 12
	cabroof.position = Vector3(ctx, 18.9, ctz)
	cabroof.material = _get_material(Color(0.4, 0.42, 0.45))
	add_child(cabroof)
	var beacon := CSGSphere3D.new()
	beacon.radius = 0.35
	beacon.radial_segments = 8
	beacon.rings = 5
	beacon.position = Vector3(ctx, 19.5, ctz)
	var beacon_mat := StandardMaterial3D.new()
	beacon_mat.albedo_color = Color(1.0, 0.10, 0.10)
	beacon_mat.emission_enabled = true
	beacon_mat.emission = Color(1.0, 0.15, 0.12)
	beacon_mat.emission_energy_multiplier = 6.0
	beacon_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	beacon.material = beacon_mat
	beacon.name = "TowerBeacon"
	add_child(beacon)

	# ── Arched hangar past the north end of the terminal ──
	_place_hangar(Vector3(cx + 20.0, 0, cz + 17.0))

	# ── Parked jets at the gates (on the apron, wings clear of the runway) ──
	_place_plane(Vector3(cx + 11.0, 0, cz - 3.0))
	_place_plane(Vector3(cx + 11.0, 0, cz + 9.0))

	# ── Apron / perimeter floods (bright at night) ──
	for fl in [Vector3(cx + 6.0, 0, cz - 20.0), Vector3(cx + 6.0, 0, cz + 20.0),
			Vector3(cx + 20.0, 0, cz - 18.0), Vector3(cx + 20.0, 0, cz + 18.0),
			Vector3(cx + 14.0, 0, cz)]:
		_place_yard_light(fl)

	# ── Runway edge lights (emissive, always-on) + end OmniLights ──
	var rl_mat := StandardMaterial3D.new()
	rl_mat.albedo_color = Color(0.80, 0.90, 1.0)
	rl_mat.emission_enabled = true
	rl_mat.emission = Color(0.70, 0.85, 1.0)
	rl_mat.emission_energy_multiplier = 8.0
	var rz: float = cz - 20.0
	while rz <= cz + 20.0:
		for ex in [-1.0, 1.0]:
			var bulb := CSGSphere3D.new()
			bulb.radius = 0.22
			bulb.position = Vector3(cx + ex * 5.0, 0.4, rz)
			bulb.material = rl_mat
			bulb.name = "RunwayLight"
			add_child(bulb)
		rz += 4.0
	for endz in [cz - 22.0, cz + 22.0]:
		var rl := OmniLight3D.new()
		rl.position = Vector3(cx, 1.2, endz)
		rl.omni_range = 18.0
		rl.light_energy = 6.0
		rl.light_color = Color(0.80, 0.90, 1.0)
		rl.shadow_enabled = false
		add_child(rl)

	_add_exclusion_zone(cx - 8, cz - 28, cx + 32, cz + 28)


func _place_hangar(center: Vector3) -> void:
	## Arched-roof (Quonset) aircraft hangar with a big dark door facing the
	## runway (-X). Box body + half-cylinder roof reads clearly as a hangar.
	var w: float = 13.0
	var d: float = 10.0
	var hh: float = 5.0
	var body := CSGBox3D.new()
	body.size = Vector3(w, hh, d)
	body.position = center + Vector3(0, hh / 2.0, 0)
	body.material = _get_material(Color(0.58, 0.60, 0.64))
	body.name = "Hangar"
	add_child(body)
	var roof := CSGCylinder3D.new()             # arched roof, axis along Z
	roof.radius = w / 2.0
	roof.height = d
	roof.sides = 18
	roof.rotation = Vector3(deg_to_rad(90.0), 0, 0)
	roof.position = center + Vector3(0, hh, 0)
	roof.material = _get_material(Color(0.48, 0.50, 0.54))
	add_child(roof)
	var door := CSGBox3D.new()                  # big hangar door on the runway side
	door.size = Vector3(0.3, hh * 0.85, d * 0.8)
	door.position = center + Vector3(-w / 2.0, hh * 0.45, 0)
	door.material = _get_material(Color(0.20, 0.21, 0.24))
	add_child(door)


func _place_plane(center: Vector3) -> void:
	## A parked twin-engine jet — fuselage along Z, swept tail, engine nacelles
	## under the wings. Wings are 10 wide so they clear the runway from the apron.
	var white: StandardMaterial3D = _get_material(Color(0.93, 0.93, 0.95))
	var body := CSGCylinder3D.new()
	body.radius = 0.85
	body.height = 9.0
	body.rotation_degrees = Vector3(90, 0, 0)   # lie the fuselage along Z
	body.position = center + Vector3(0, 1.3, 0)
	body.material = white
	body.name = "Plane"
	add_child(body)
	var wing := CSGBox3D.new()
	wing.size = Vector3(10.0, 0.25, 2.2)
	wing.position = center + Vector3(0, 1.3, 0.5)
	wing.material = white
	add_child(wing)
	for ex in [-2.6, 2.6]:                       # under-wing engine nacelles
		var eng := CSGCylinder3D.new()
		eng.radius = 0.42
		eng.height = 1.8
		eng.sides = 12
		eng.rotation_degrees = Vector3(90, 0, 0)
		eng.position = center + Vector3(ex, 0.85, 0.9)
		eng.material = _get_material(Color(0.5, 0.52, 0.55))
		add_child(eng)
	var tailwing := CSGBox3D.new()
	tailwing.size = Vector3(4.0, 0.2, 1.2)
	tailwing.position = center + Vector3(0, 1.5, -3.8)
	tailwing.material = white
	add_child(tailwing)
	var tailfin := CSGBox3D.new()
	tailfin.size = Vector3(0.25, 2.2, 1.6)
	tailfin.position = center + Vector3(0, 2.4, -3.8)
	tailfin.material = _get_material(Color(0.85, 0.2, 0.2))
	add_child(tailfin)


# ═════════════════════════════════════════════════════════════════════════════
# BUILDING TYPES
# ═════════════════════════════════════════════════════════════════════════════

func _place_block_building(axis: int, dir_sign: float, along: float,
						   perp: float, side_sign: float) -> float:
	## Place a simple block building with roof parapet. Returns building length.
	var width: float = _rng.randf_range(2.5, 5.0)
	var depth: float = _rng.randf_range(2.5, 4.0)
	var height: float = _rng.randf_range(1.8, 5.0)
	var facade_color: Color = FACADE_COLORS[_rng.randi() % FACADE_COLORS.size()]

	var pos := _compute_position(axis, dir_sign, along + width / 2.0, perp, side_sign, depth)

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

	# Road-facing door + windows with their own interior glow, so the building
	# has presence at night instead of just catching street-light spill.
	var road_dir: Vector3 = Vector3(0.0, 0.0, -side_sign) if axis == 0 else Vector3(-side_sign, 0.0, 0.0)
	var lateral_dir: Vector3 = Vector3(1.0, 0.0, 0.0) if axis == 0 else Vector3(0.0, 0.0, 1.0)
	_decorate_roadside_facade(body.position, width, height, depth,
							  road_dir, lateral_dir, false)

	return width


func _place_shop_front(axis: int, dir_sign: float, along: float,
					   perp: float, side_sign: float) -> float:
	## Place a shop with awning. Returns building length.
	var width: float = _rng.randf_range(2.0, 4.0)
	var depth: float = _rng.randf_range(2.0, 3.5)
	var height: float = _rng.randf_range(1.5, 3.0)
	var facade_color: Color = FACADE_COLORS[_rng.randi() % FACADE_COLORS.size()]
	var awning_color: Color = AWNING_COLORS[_rng.randi() % AWNING_COLORS.size()]

	var pos := _compute_position(axis, dir_sign, along + width / 2.0, perp, side_sign, depth)

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

	# Storefront door + windows — shops get a wider, more-often-open door and
	# lit front-window so they read as "open for business" at dusk/night.
	var road_dir: Vector3 = Vector3(0.0, 0.0, -side_sign) if axis == 0 else Vector3(-side_sign, 0.0, 0.0)
	var lateral_dir: Vector3 = Vector3(1.0, 0.0, 0.0) if axis == 0 else Vector3(0.0, 0.0, 1.0)
	_decorate_roadside_facade(body.position, width, height, depth,
							  road_dir, lateral_dir, true)

	return width


func _place_compound_wall(axis: int, dir_sign: float, along: float,
						  perp: float, side_sign: float) -> float:
	## Place a low compound wall. Returns wall length.
	var width: float = _rng.randf_range(4.0, 8.0)
	var height: float = _rng.randf_range(0.6, 0.9)
	var depth: float = 0.2
	var wall_color: Color = WALL_COLORS[_rng.randi() % WALL_COLORS.size()]

	var pos := _compute_position(axis, dir_sign, along + width / 2.0, perp, side_sign, depth)

	var wall := CSGBox3D.new()
	wall.size = _orient_size(axis, width, height, depth)
	wall.position = pos + Vector3(0, height / 2.0, 0)
	wall.material = _get_material(wall_color)
	wall.name = "CompoundWall"
	add_child(wall)

	return width


func _place_market_stalls(axis: int, dir_sign: float, along: float,
						  perp: float, side_sign: float) -> float:
	## Place a cluster of 3-5 small market stalls. Returns cluster length.
	var stall_count: int = _rng.randi_range(3, 5)
	var total_width: float = 0.0

	for i in range(stall_count):
		var sw: float = _rng.randf_range(0.8, 1.4)
		var sd: float = _rng.randf_range(0.8, 1.2)
		var sh: float = _rng.randf_range(1.0, 1.6)
		var canopy_color: Color = CANOPY_COLORS[_rng.randi() % CANOPY_COLORS.size()]

		var pos := _compute_position(axis, dir_sign, along + total_width + sw / 2.0, perp, side_sign, sd)

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
				pole_pos = pos + Vector3(0, sh / 2.0, dir_sign * pole_along_offset)
			else:  # E/W
				pole_pos = pos + Vector3(dir_sign * pole_along_offset, sh / 2.0, 0)
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
	## Faces respect the same setback line as the arm buildings (sidewalk +
	## BUILDING_OFFSET), so corners no longer crowd the TL poles or the road.
	var face_line: float = JUNCTION_HALF + SIDEWALK_WIDTH + BUILDING_OFFSET
	var corner_signs: Array = [
		Vector2(-1,  1),   # NW
		Vector2( 1,  1),   # NE
		Vector2(-1, -1),   # SW
		Vector2( 1, -1),   # SE
	]

	for i in range(corner_signs.size()):
		var height: float = _rng.randf_range(3.0, 5.5)
		var width: float = _rng.randf_range(3.5, 5.0)
		var depth: float = _rng.randf_range(3.0, 4.5)
		var sgn: Vector2 = corner_signs[i]
		# Center sits half a footprint behind the setback line on BOTH axes
		var pos := Vector3(sgn.x * (face_line + width / 2.0), 0,
						   sgn.y * (face_line + depth / 2.0))
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

		# Door + windows on the road-facing facade. Alternate the facing axis
		# per-corner so 2 corners face the N/S arm and 2 face the E/W arm —
		# avoids all 4 corner doors looking in the same direction.
		# Corner body size is Vector3(width, height, depth) (X-along, Z-perp).
		var facing_x_road: bool = (i % 2 == 0)   # i=0,2 face E/W arm (road_dir along Z)
		var corner_road_dir: Vector3
		var corner_lateral: Vector3
		var corner_facade_w: float
		var corner_facade_d: float
		if facing_x_road:
			# Facade faces the E/W arm: road_dir along Z toward junction
			corner_road_dir = Vector3(0.0, 0.0, -sign(pos.z))
			corner_lateral = Vector3(1.0, 0.0, 0.0)
			corner_facade_w = width   # lateral is X (= width)
			corner_facade_d = depth   # into-building is Z (= depth)
		else:
			# Facade faces the N/S arm: road_dir along X toward junction
			corner_road_dir = Vector3(-sign(pos.x), 0.0, 0.0)
			corner_lateral = Vector3(0.0, 0.0, 1.0)
			corner_facade_w = depth   # lateral is Z (= depth)
			corner_facade_d = width   # into-building is X (= width)
		_decorate_roadside_facade(body.position, corner_facade_w, height,
								  corner_facade_d, corner_road_dir,
								  corner_lateral, true)  # corners act as shops (have awnings)


# ═════════════════════════════════════════════════════════════════════════════
# HELPERS
# ═════════════════════════════════════════════════════════════════════════════

func _compute_position(axis: int, dir_sign: float, along: float,
					   perp: float, side_sign: float, depth: float) -> Vector3:
	## Compute world position for a building.
	## axis=0: road runs along X, perp is Z
	## axis=1: road runs along Z, perp is X
	var perp_total: float = perp + side_sign * depth / 2.0
	if axis == 1:  # N/S road
		return Vector3(perp_total, 0, dir_sign * along) + _placement_origin
	else:  # E/W road
		return Vector3(dir_sign * along, 0, perp_total) + _placement_origin


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


func _get_glass_material(color: Color) -> StandardMaterial3D:
	## Like _get_material but with lower roughness + a touch of metallic for glass.
	var key: int = color.to_rgba32() ^ 0xDEADBEEF  # Different key than matte version
	if _materials.has(key):
		return _materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.25
	mat.metallic = 0.4
	_materials[key] = mat
	return mat


# ═════════════════════════════════════════════════════════════════════════════
# QUADRANT DISTRICTS
# ═════════════════════════════════════════════════════════════════════════════

func _build_quadrants() -> void:
	## Fill each of the 4 quadrants between the road arms with a themed district.
	## Sign convention: +Z=North, -Z=South, +X=West, -X=East (Godot X mirrored).
	# Commercial: NE  (towers, mall, parking)
	_build_commercial_quadrant(-1.0, 1.0)
	# Institutional: NW  (school, football pitch, church, clinic)
	_build_institutional_quadrant(1.0, 1.0)
	# Industrial: SW  (factory, storage tanks, container yard, trucks)
	_build_industrial_quadrant(1.0, -1.0)
	# Residential: SE  (compound houses)
	_build_residential_quadrant(-1.0, -1.0)

	# Scatter trees through all quadrants
	for xs in [-1.0, 1.0]:
		for zs in [-1.0, 1.0]:
			_scatter_trees(xs, zs, TREES_PER_QUADRANT)

	# One petrol station (SW inner corner — visible from junction)
	_place_petrol_station(Vector3(22, 0, -22))


# ─── NE: Commercial / Office district ───────────────────────────────────────

func _build_commercial_quadrant(xs: float, zs: float) -> void:
	## NE quadrant — offices, tall towers, shopping mall, parking.
	# Anchor tower (7 stories) — closest to junction, most visible
	_place_office_tower(Vector3(xs * 24, 0, zs * 26), 7, 6.5, 6.5)

	# Secondary tower (6 stories) — mid-depth
	_place_office_tower(Vector3(xs * 52, 0, zs * 36), 6, 6.0, 6.0)

	# Tertiary tower (5 stories) — back
	_place_office_tower(Vector3(xs * 26, 0, zs * 58), 5, 5.5, 5.5)

	# Shopping mall — long flat block at the far corner
	_place_shopping_mall(Vector3(xs * 65, 0, zs * 65), 18.0, 5.5, 9.0)

	# Parking lot in front of mall
	_place_parking_lot(Vector3(xs * 50, 0, zs * 68), 14.0, 7.0, 8)

	# Mid-rise office fillers
	_place_midrise_office(Vector3(xs * 45, 0, zs * 22), 4, 5.0, 5.0)
	_place_midrise_office(Vector3(xs * 70, 0, zs * 25), 3, 4.5, 4.5)
	_place_midrise_office(Vector3(xs * 42, 0, zs * 55), 4, 4.8, 4.8)
	_place_midrise_office(Vector3(xs * 72, 0, zs * 50), 3, 4.5, 5.0)

	# Extra area lights so the commercial quadrant reads at night.
	_place_stadium_light(Vector3(xs * 16, 0, zs * 18))   # corner by junction
	_place_stadium_light(Vector3(xs * 40, 0, zs * 48))   # between towers
	_place_stadium_light(Vector3(xs * 80, 0, zs * 58))   # behind mid-rise
	_place_stadium_light(Vector3(xs * 18, 0, zs * 72))   # near tower 3

	# Extra parking lots — office block + mid-rise strip.
	_place_parking_lot(Vector3(xs * 18, 0, zs * 40), 10.0, 6.0, 6)
	_place_parking_lot(Vector3(xs * 60, 0, zs * 15), 12.0, 5.5, 8)


# ─── NW: Institutional district ─────────────────────────────────────────────

func _build_institutional_quadrant(xs: float, zs: float) -> void:
	## NW quadrant — school, football pitch, church, clinic.
	# School main block (3 stories)
	_place_school_building(Vector3(xs * 48, 0, zs * 60), 3, 16.0, 7.0)

	# School wings (2 stories, flanking)
	_place_school_building(Vector3(xs * 30, 0, zs * 72), 2, 10.0, 5.5)
	_place_school_building(Vector3(xs * 66, 0, zs * 72), 2, 10.0, 5.5)

	# Football pitch (prominent green rectangle — has its own 4 stadium lights)
	_place_football_pitch(Vector3(xs * 48, 0, zs * 38), 22.0, 13.0)

	# Church — distinctive cross tower
	_place_church(Vector3(xs * 72, 0, zs * 28))

	# Clinic — smaller civic building
	_place_clinic(Vector3(xs * 25, 0, zs * 28))

	# Extra area lights for the school yard + church/clinic frontage.
	_place_stadium_light(Vector3(xs * 48, 0, zs * 22))   # frontage near junction
	_place_stadium_light(Vector3(xs * 20, 0, zs * 55))   # between clinic and school
	_place_stadium_light(Vector3(xs * 48, 0, zs * 80))   # behind school wings

	# School staff parking + church visitor parking.
	_place_parking_lot(Vector3(xs * 58, 0, zs * 53), 10.0, 5.5, 6)
	_place_parking_lot(Vector3(xs * 15, 0, zs * 62), 9.0, 5.5, 5)


# ─── SW: Industrial yard district ───────────────────────────────────────────

func _build_industrial_quadrant(xs: float, zs: float) -> void:
	## SW quadrant — factory, storage tanks, container yard, trucks.
	## Petrol station is placed separately (see _build_quadrants) near the junction.
	# Main factory shed (large box + chimney stacks + lit windows)
	_place_factory(Vector3(xs * 55, 0, zs * 52), 20.0, 6.0, 12.0)

	# Secondary assembly shed (smaller)
	_place_factory(Vector3(xs * 28, 0, zs * 72), 12.0, 4.5, 8.0)

	# Storage tank cluster (4 tanks)
	_place_storage_tank(Vector3(xs * 72, 0, zs * 38), 2.4, 5.5)
	_place_storage_tank(Vector3(xs * 78, 0, zs * 44), 2.0, 4.8)
	_place_storage_tank(Vector3(xs * 72, 0, zs * 48), 1.8, 4.2)
	_place_storage_tank(Vector3(xs * 68, 0, zs * 42), 1.5, 3.8)

	# Shipping container yard (loose grid, some stacked)
	_place_container_yard(Vector3(xs * 72, 0, zs * 68))

	# Parked tanker truck + flatbed truck
	_place_tanker_truck(Vector3(xs * 42, 0, zs * 30))
	_place_flatbed_truck(Vector3(xs * 32, 0, zs * 42))

	# 4 tall sodium yard floodlights — scatter across the quadrant
	_place_yard_light(Vector3(xs * 38, 0, zs * 38))
	_place_yard_light(Vector3(xs * 60, 0, zs * 28))
	_place_yard_light(Vector3(xs * 38, 0, zs * 68))
	_place_yard_light(Vector3(xs * 78, 0, zs * 60))

	# Exclude the main factory footprint so trees don't grow through it
	_add_exclusion_zone(xs * 55 - 11, zs * 52 - 7, xs * 55 + 11, zs * 52 + 7)
	_add_exclusion_zone(xs * 28 - 7, zs * 72 - 5, xs * 28 + 7, zs * 72 + 5)
	_add_exclusion_zone(xs * 72 - 8, zs * 68 - 6, xs * 72 + 8, zs * 68 + 6)


# ─── SE: Residential compound district ──────────────────────────────────────

func _build_residential_quadrant(xs: float, zs: float) -> void:
	## SE quadrant — compound houses in a loose 3x3 grid.
	var grid_positions: Array = [
		Vector3(xs * 24, 0, zs * 26),
		Vector3(xs * 46, 0, zs * 26),
		Vector3(xs * 68, 0, zs * 26),
		Vector3(xs * 24, 0, zs * 50),
		Vector3(xs * 46, 0, zs * 50),
		Vector3(xs * 68, 0, zs * 50),
		# Row 3 aligned with the other rows so compounds don't clip the N-S
		# streets at x=35 and x=57 (14-wide compounds extend ±7 from center).
		Vector3(xs * 24, 0, zs * 74),
		Vector3(xs * 46, 0, zs * 74),
		Vector3(xs * 68, 0, zs * 74),
	]
	for pos in grid_positions:
		var stories: int = 1 if _rng.randf() < 0.4 else 2
		_place_house_compound(pos, 14.0, stories)

	# ─── Internal residential street grid ─────────────────────────────
	# Two N-S + two E-W streets thread between the compound rows. They
	# extend from the quadrant interior out to ~5 units from the main-
	# road sidewalk so the neighborhood visually connects to the arterial.
	# Center at 45 with length 80 → spans [5, 85] in local coords.
	var street_len: float = 80.0
	var street_center: float = 45.0
	for street_x in [35.0, 57.0]:
		_place_residential_street(
			Vector3(xs * street_x, 0, zs * street_center),
			street_len, true
		)
	for street_z in [38.0, 62.0]:
		_place_residential_street(
			Vector3(xs * street_center, 0, zs * street_z),
			street_len, false
		)

	# Prevent trees from spawning on the new asphalt.
	var z_lo: float = min(zs * 5.0, zs * 85.0)
	var z_hi: float = max(zs * 5.0, zs * 85.0)
	for street_x in [35.0, 57.0]:
		_add_exclusion_zone(xs * street_x - 1.6, z_lo, xs * street_x + 1.6, z_hi)
	var x_lo: float = min(xs * 5.0, xs * 85.0)
	var x_hi: float = max(xs * 5.0, xs * 85.0)
	for street_z in [38.0, 62.0]:
		_add_exclusion_zone(x_lo, zs * street_z - 1.6, x_hi, zs * street_z + 1.6)

	# Street lamps at intersections + near the main-road approaches + far end.
	# N-S streets run at x=35 and x=57 (width 3 → edges at ±1.5 from center).
	# E-W streets run at z=38 and z=62. Lamps are offset +2 on both axes so
	# poles sit on the curb (~0.5 past the asphalt edge), not in the road.
	for lp in [
		Vector2(37, 40), Vector2(59, 40),    # SE corner of the two near intersections
		Vector2(37, 64), Vector2(59, 64),    # SE corner of the two far intersections
		Vector2(37, 15), Vector2(59, 15),    # east-side curbs near main-road approach
		Vector2(37, 82), Vector2(59, 82),    # east-side curbs at far dead-end
	]:
		_place_residential_lamp(Vector3(xs * lp.x, 0, zs * lp.y))

	# Three small residential parking lots tucked against the quadrant edges.
	_place_parking_lot(Vector3(xs * 15, 0, zs * 42), 5.0, 3.0, 3)
	_place_parking_lot(Vector3(xs * 82, 0, zs * 42), 5.0, 3.0, 3)
	_place_parking_lot(Vector3(xs * 40, 0, zs * 88), 6.0, 3.0, 4)


# ═════════════════════════════════════════════════════════════════════════════
# DISTRICT PRIMITIVES
# ═════════════════════════════════════════════════════════════════════════════

func _place_office_tower(center: Vector3, stories: int, base_w: float, base_d: float) -> void:
	## Stepped office tower: wider base + narrower top (modern Accra office style).
	## Each story = 2.0 units tall. Glass bands alternate with slab bands.
	var story_h: float = 2.0
	var base_stories: int = int(ceil(stories * 0.55))
	var top_stories: int = stories - base_stories
	var base_h: float = base_stories * story_h
	var top_h: float = top_stories * story_h

	var base_col: Color = TOWER_BASE_COLORS[_rng.randi() % TOWER_BASE_COLORS.size()]
	var glass_col: Color = GLASS_COLORS[_rng.randi() % GLASS_COLORS.size()]

	# Base body
	var base := CSGBox3D.new()
	base.size = Vector3(base_w, base_h, base_d)
	base.position = center + Vector3(0, base_h / 2.0, 0)
	base.material = _get_material(base_col)
	base.name = "TowerBase"
	add_child(base)

	# Horizontal glass bands on base (one per story, centred).
	# ~70% lit (emissive at night), rest dark glass — reads as "some offices occupied".
	for i in range(base_stories):
		var band := CSGBox3D.new()
		band.size = Vector3(base_w + 0.05, 0.7, base_d + 0.05)
		band.position = center + Vector3(0, i * story_h + story_h * 0.55, 0)
		if _rng.randf() < 0.7:
			band.material = _pick_window_cool()
		else:
			band.material = _get_glass_material(glass_col)
		band.name = "TowerGlassBand"
		add_child(band)

	# Upper tower (narrower, inset by ~15%)
	if top_stories > 0:
		var top_w: float = base_w * 0.82
		var top_d: float = base_d * 0.82
		var top := CSGBox3D.new()
		top.size = Vector3(top_w, top_h, top_d)
		top.position = center + Vector3(0, base_h + top_h / 2.0, 0)
		top.material = _get_material(base_col)
		top.name = "TowerTop"
		add_child(top)

		for i in range(top_stories):
			var band := CSGBox3D.new()
			band.size = Vector3(top_w + 0.05, 0.7, top_d + 0.05)
			band.position = center + Vector3(0, base_h + i * story_h + story_h * 0.55, 0)
			if _rng.randf() < 0.7:
				band.material = _pick_window_cool()
			else:
				band.material = _get_glass_material(glass_col)
			band.name = "TowerGlassBand"
			add_child(band)

	# Rooftop unit (antenna / AC housing)
	var rooftop := CSGBox3D.new()
	rooftop.size = Vector3(base_w * 0.35, 0.8, base_d * 0.35)
	var total_h: float = base_h + top_h
	rooftop.position = center + Vector3(0, total_h + 0.4, 0)
	rooftop.material = _get_material(base_col * 0.8)
	rooftop.name = "TowerRooftop"
	add_child(rooftop)


func _place_midrise_office(center: Vector3, stories: int, w: float, d: float) -> void:
	## Shorter 3-4 story office — flat roof, simple bands.
	var story_h: float = 1.8
	var h: float = stories * story_h
	var col: Color = TOWER_BASE_COLORS[_rng.randi() % TOWER_BASE_COLORS.size()]
	var glass: Color = GLASS_COLORS[_rng.randi() % GLASS_COLORS.size()]

	var body := CSGBox3D.new()
	body.size = Vector3(w, h, d)
	body.position = center + Vector3(0, h / 2.0, 0)
	body.material = _get_material(col)
	body.name = "MidriseBody"
	add_child(body)

	for i in range(stories):
		var band := CSGBox3D.new()
		band.size = Vector3(w + 0.05, 0.55, d + 0.05)
		band.position = center + Vector3(0, i * story_h + story_h * 0.55, 0)
		if _rng.randf() < 0.65:
			band.material = _pick_window_cool()
		else:
			band.material = _get_glass_material(glass)
		band.name = "MidriseGlassBand"
		add_child(band)

	# Parapet
	var parapet := CSGBox3D.new()
	parapet.size = Vector3(w + 0.2, 0.25, d + 0.2)
	parapet.position = center + Vector3(0, h + 0.125, 0)
	parapet.material = _get_material(col * 0.75)
	parapet.name = "MidriseParapet"
	add_child(parapet)


func _place_shopping_mall(center: Vector3, w: float, h: float, d: float) -> void:
	## Long flat block with signage band. 2-3 stories equivalent height.
	var base_col: Color = Color(0.78, 0.76, 0.74)

	var body := CSGBox3D.new()
	body.size = Vector3(w, h, d)
	body.position = center + Vector3(0, h / 2.0, 0)
	body.material = _get_material(base_col)
	body.name = "MallBody"
	add_child(body)

	# Signage stripe near top of facade — shared emissive so it glows at night
	var signage := CSGBox3D.new()
	signage.size = Vector3(w + 0.08, 1.0, d + 0.08)
	signage.position = center + Vector3(0, h - 0.8, 0)
	signage.material = _mat_sign_glow
	signage.name = "MallSign"
	add_child(signage)

	# Flat roof unit
	var roof := CSGBox3D.new()
	roof.size = Vector3(w * 0.4, 0.5, d * 0.6)
	roof.position = center + Vector3(0, h + 0.25, 0)
	roof.material = _get_material(ROOF_DARK)
	roof.name = "MallRoof"
	add_child(roof)


func _place_parking_lot(center: Vector3, w: float, d: float, num_cars: int) -> void:
	## Flat asphalt slab + a few tiny colored boxes as parked cars.
	var slab := CSGBox3D.new()
	slab.size = Vector3(w, 0.08, d)
	slab.position = center + Vector3(0, 0.04, 0)
	slab.material = _get_material(ASPHALT)
	slab.name = "ParkingSlab"
	add_child(slab)

	# Parked cars arranged in a rough grid
	var cols: int = 4
	var rows: int = max(1, int(ceil(float(num_cars) / cols)))
	var col_spacing: float = w / (cols + 1)
	var row_spacing: float = d / (rows + 1)
	var placed: int = 0
	for r in range(rows):
		for c in range(cols):
			if placed >= num_cars:
				break
			var car_col: Color = CAR_COLORS[_rng.randi() % CAR_COLORS.size()]
			var car := CSGBox3D.new()
			car.size = Vector3(0.55, 0.28, 1.0)
			var cx: float = -w / 2.0 + (c + 1) * col_spacing
			var cz: float = -d / 2.0 + (r + 1) * row_spacing
			car.position = center + Vector3(cx, 0.22, cz)
			car.material = _get_material(car_col)
			car.name = "ParkedCar"
			add_child(car)
			placed += 1


func _place_school_building(center: Vector3, stories: int, w: float, d: float) -> void:
	## Classroom block — cream colored, window bands, low parapet.
	var story_h: float = 1.9
	var h: float = stories * story_h
	var col: Color = SCHOOL_COLORS[_rng.randi() % SCHOOL_COLORS.size()]

	var body := CSGBox3D.new()
	body.size = Vector3(w, h, d)
	body.position = center + Vector3(0, h / 2.0, 0)
	body.material = _get_material(col)
	body.name = "SchoolBody"
	add_child(body)

	# Horizontal window bands (teal/green trim). ~40% lit at night — most
	# classrooms are empty but a few admin / security lights stay on.
	var window_col := Color(0.35, 0.55, 0.62)
	for i in range(stories):
		var band := CSGBox3D.new()
		band.size = Vector3(w + 0.05, 0.45, d + 0.05)
		band.position = center + Vector3(0, i * story_h + story_h * 0.6, 0)
		if _rng.randf() < 0.4:
			band.material = _pick_window_cool()
		else:
			band.material = _get_glass_material(window_col)
		band.name = "SchoolWindowBand"
		add_child(band)

	# Parapet (red-brown to match common school roofs)
	var parapet := CSGBox3D.new()
	parapet.size = Vector3(w + 0.2, 0.3, d + 0.2)
	parapet.position = center + Vector3(0, h + 0.15, 0)
	parapet.material = _get_material(Color(0.55, 0.30, 0.22))
	parapet.name = "SchoolParapet"
	add_child(parapet)


func _place_football_pitch(center: Vector3, w: float, d: float) -> void:
	## A proper football pitch: mown-stripe turf, full white markings (boundary,
	## halfway line + centre circle/spot, penalty boxes, goal areas, penalty
	## spots), goals, stadium floods and a bleacher. w = length (X), d = width (Z).
	var turf_dark: Color = Color(0.18, 0.42, 0.16)
	var turf_light: Color = Color(0.24, 0.50, 0.20)

	# Base slab (shows at the very edge) + alternating mown stripes on top so the
	# pitch clearly reads as managed turf, not the surrounding lawn.
	var base := CSGBox3D.new()
	base.size = Vector3(w, 0.04, d)
	base.position = center + Vector3(0, 0.02, 0)
	base.material = _get_material(turf_dark)
	base.name = "FootballPitch"
	add_child(base)
	var n_stripes: int = 7
	var stripe_w: float = d / float(n_stripes)
	for i in range(n_stripes):
		var stripe := CSGBox3D.new()
		stripe.size = Vector3(w, 0.03, stripe_w + 0.01)
		stripe.position = center + Vector3(0, 0.035, -d / 2.0 + (i + 0.5) * stripe_w)
		stripe.material = _get_material(turf_light if i % 2 == 0 else turf_dark)
		stripe.name = "PitchStripe"
		add_child(stripe)

	# ── White markings ───────────────────────────────────────────────────
	var lt: float = 0.18           # line thickness
	var lh: float = 0.01           # line height
	var ly: float = 0.06           # line top (sits above the stripes)
	var pb_d: float = w * 0.16     # penalty-box depth (into the pitch, X)
	var pb_w: float = d * 0.58     # penalty-box width (Z)
	var ga_d: float = w * 0.07     # goal-area depth
	var ga_w: float = d * 0.34     # goal-area width

	var lines: Array = [
		# Boundary
		[Vector3(0, ly, d / 2.0 - lt / 2.0), Vector3(w, lh, lt)],
		[Vector3(0, ly, -d / 2.0 + lt / 2.0), Vector3(w, lh, lt)],
		[Vector3(w / 2.0 - lt / 2.0, ly, 0), Vector3(lt, lh, d)],
		[Vector3(-w / 2.0 + lt / 2.0, ly, 0), Vector3(lt, lh, d)],
		# Halfway line
		[Vector3(0, ly, 0), Vector3(lt, lh, d)],
	]
	# Penalty box + goal area at each end (s = -1 / +1 along the length)
	for s in [-1.0, 1.0]:
		lines.append([Vector3(s * (w / 2.0 - pb_d), ly, 0), Vector3(lt, lh, pb_w)])
		lines.append([Vector3(s * (w / 2.0 - pb_d / 2.0), ly, pb_w / 2.0), Vector3(pb_d, lh, lt)])
		lines.append([Vector3(s * (w / 2.0 - pb_d / 2.0), ly, -pb_w / 2.0), Vector3(pb_d, lh, lt)])
		lines.append([Vector3(s * (w / 2.0 - ga_d), ly, 0), Vector3(lt, lh, ga_w)])
		lines.append([Vector3(s * (w / 2.0 - ga_d / 2.0), ly, ga_w / 2.0), Vector3(ga_d, lh, lt)])
		lines.append([Vector3(s * (w / 2.0 - ga_d / 2.0), ly, -ga_w / 2.0), Vector3(ga_d, lh, lt)])
	for p in lines:
		var line := CSGBox3D.new()
		line.size = p[1]
		line.position = center + p[0]
		line.material = _get_material(CROSS_WHITE)
		line.name = "PitchLine"
		add_child(line)

	# Centre circle (round, 32-sided) with a turf fill so it reads as a ring
	var cr: float = d * 0.17
	var ring := CSGCylinder3D.new()
	ring.radius = cr
	ring.height = 0.015
	ring.sides = 32
	ring.position = center + Vector3(0, ly + 0.005, 0)
	ring.material = _get_material(CROSS_WHITE)
	ring.name = "PitchCircle"
	add_child(ring)
	var inner := CSGCylinder3D.new()
	inner.radius = cr - lt
	inner.height = 0.02
	inner.sides = 32
	inner.position = center + Vector3(0, ly + 0.01, 0)
	inner.material = _get_material(turf_dark)   # centre sits on a dark stripe
	inner.name = "PitchCircleInner"
	add_child(inner)
	# Spots — centre + the two penalty spots
	for spot_x in [0.0, w / 2.0 - w * 0.11, -(w / 2.0 - w * 0.11)]:
		var spot := CSGCylinder3D.new()
		spot.radius = 0.13
		spot.height = 0.02
		spot.sides = 12
		spot.position = center + Vector3(spot_x, ly + 0.012, 0)
		spot.material = _get_material(CROSS_WHITE)
		spot.name = "PitchSpot"
		add_child(spot)

	# Stadium flood-lights at the 4 corners (real OmniLights, on at night)
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var corner := center + Vector3(sx * (w / 2.0 + 1.8), 0, sz * (d / 2.0 + 1.8))
			_place_stadium_light(corner)

	# Goal posts at each short end (pitch width runs along X)
	_place_goal_post(center + Vector3(-w / 2.0, 0, 0), 1.0)    # Net extends in -X
	_place_goal_post(center + Vector3(w / 2.0, 0, 0), -1.0)    # Net extends in +X

	# Bleacher on the far-from-junction side.
	# Pitch center.z is positive in the NW quadrant, so the outside side is +Z.
	var bleacher_face: float = -1.0 if center.z > 0 else 1.0   # Face toward pitch
	var bleacher_front_z: float = center.z + (d / 2.0 + 1.0) * sign(center.z)
	_place_bleacher(
		Vector3(center.x, 0, bleacher_front_z),
		w * 0.8,      # bleacher width (along X, parallel to touchline)
		4,            # rows
		bleacher_face
	)

	# Exclusion zone: pitch interior + bleacher + goals + stadium-light poles
	var zone_pad := 2.5
	_add_exclusion_zone(
		center.x - w / 2.0 - zone_pad,
		center.z - d / 2.0 - zone_pad,
		center.x + w / 2.0 + zone_pad,
		center.z + d / 2.0 + zone_pad + 3.0   # extra on +z side for bleacher
	)


func _place_stadium_light(base: Vector3) -> void:
	## Tall metal pole + emissive lamp head + OmniLight3D (visible at night only).
	var pole_h := 8.5
	var pole := CSGCylinder3D.new()
	pole.radius = 0.14
	pole.height = pole_h
	pole.position = base + Vector3(0, pole_h / 2.0, 0)
	pole.material = _get_material(Color(0.32, 0.32, 0.35))
	pole.name = "StadiumPole"
	add_child(pole)

	# Cross-brace just below the lamp head (bit of silhouette detail)
	var brace := CSGBox3D.new()
	brace.size = Vector3(0.9, 0.1, 0.1)
	brace.position = base + Vector3(0, pole_h - 0.4, 0)
	brace.material = _get_material(Color(0.30, 0.30, 0.32))
	brace.name = "StadiumBrace"
	add_child(brace)

	# Lamp head (emissive box)
	var head := CSGBox3D.new()
	head.size = Vector3(1.3, 0.55, 0.85)
	head.position = base + Vector3(0, pole_h + 0.35, 0)
	head.material = _mat_stadium_cap
	head.name = "StadiumHead"
	add_child(head)

	# Real scene light
	var light := OmniLight3D.new()
	light.position = base + Vector3(0, pole_h + 0.5, 0)
	light.omni_range = 32.0
	light.light_energy = 2.8
	light.light_color = Color(1.0, 0.98, 0.90)
	light.shadow_enabled = false  # Perf: 4 stadium lights with shadows is too much
	light.visible = false         # Off until night
	add_child(light)
	_stadium_lights.append(light)


func _place_church(center: Vector3) -> void:
	## Small chapel with a cross tower.
	var hall_w := 8.0
	var hall_h := 4.5
	var hall_d := 10.0
	var hall_col := Color(0.88, 0.85, 0.78)

	var hall := CSGBox3D.new()
	hall.size = Vector3(hall_w, hall_h, hall_d)
	hall.position = center + Vector3(0, hall_h / 2.0, 0)
	hall.material = _get_material(hall_col)
	hall.name = "ChurchHall"
	add_child(hall)

	# Pitched-roof approximation (wider parapet cap)
	var roof := CSGBox3D.new()
	roof.size = Vector3(hall_w + 0.3, 0.8, hall_d + 0.3)
	roof.position = center + Vector3(0, hall_h + 0.4, 0)
	roof.material = _get_material(Color(0.45, 0.22, 0.18))
	roof.name = "ChurchRoof"
	add_child(roof)

	# Cross tower (tall narrow shaft at front)
	var tower := CSGBox3D.new()
	var tower_h := 8.5
	tower.size = Vector3(2.2, tower_h, 2.2)
	tower.position = center + Vector3(0, tower_h / 2.0, -hall_d / 2.0 - 1.1)
	tower.material = _get_material(hall_col)
	tower.name = "ChurchTower"
	add_child(tower)

	# Cross at the top — emissive so it glows softly at night
	var cross_v := CSGBox3D.new()
	cross_v.size = Vector3(0.18, 1.4, 0.18)
	cross_v.position = center + Vector3(0, tower_h + 0.8, -hall_d / 2.0 - 1.1)
	cross_v.material = _mat_cross_white
	cross_v.name = "ChurchCrossV"
	add_child(cross_v)
	var cross_h := CSGBox3D.new()
	cross_h.size = Vector3(0.7, 0.18, 0.18)
	cross_h.position = center + Vector3(0, tower_h + 0.95, -hall_d / 2.0 - 1.1)
	cross_h.material = _mat_cross_white
	cross_h.name = "ChurchCrossH"
	add_child(cross_h)


func _place_clinic(center: Vector3) -> void:
	## Small H-shape clinic. Central block + 2 wings.
	var clinic_col := Color(0.92, 0.92, 0.90)
	var h := 4.0

	# Central block
	var core := CSGBox3D.new()
	core.size = Vector3(7.0, h, 3.5)
	core.position = center + Vector3(0, h / 2.0, 0)
	core.material = _get_material(clinic_col)
	core.name = "ClinicCore"
	add_child(core)

	# Left wing
	var wl := CSGBox3D.new()
	wl.size = Vector3(2.8, h, 6.0)
	wl.position = center + Vector3(-2.6, h / 2.0, 0)
	wl.material = _get_material(clinic_col)
	wl.name = "ClinicWingL"
	add_child(wl)

	# Right wing
	var wr := CSGBox3D.new()
	wr.size = Vector3(2.8, h, 6.0)
	wr.position = center + Vector3(2.6, h / 2.0, 0)
	wr.material = _get_material(clinic_col)
	wr.name = "ClinicWingR"
	add_child(wr)

	# Red cross on front (signals "clinic") — emissive so it reads as a night beacon
	var red_h := CSGBox3D.new()
	red_h.size = Vector3(1.0, 0.25, 0.08)
	red_h.position = center + Vector3(0, h - 0.8, -3.5 / 2.0 - 0.04)
	red_h.material = _mat_cross_red
	red_h.name = "ClinicCrossH"
	add_child(red_h)
	var red_v := CSGBox3D.new()
	red_v.size = Vector3(0.25, 1.0, 0.08)
	red_v.position = center + Vector3(0, h - 0.8, -3.5 / 2.0 - 0.04)
	red_v.material = _mat_cross_red
	red_v.name = "ClinicCrossV"
	add_child(red_v)


func _place_house_compound(center: Vector3, compound_size: float, stories: int) -> void:
	## Low perimeter wall with a 1-2 story house inside.
	var wall_h := 0.7
	var wall_t := 0.15
	var wall_col: Color = WALL_COLORS[_rng.randi() % WALL_COLORS.size()]
	var half := compound_size / 2.0

	# 4 walls
	var walls: Array = [
		[Vector3(0, wall_h / 2.0, half - wall_t / 2.0), Vector3(compound_size, wall_h, wall_t)],
		[Vector3(0, wall_h / 2.0, -half + wall_t / 2.0), Vector3(compound_size, wall_h, wall_t)],
		[Vector3(half - wall_t / 2.0, wall_h / 2.0, 0), Vector3(wall_t, wall_h, compound_size)],
		[Vector3(-half + wall_t / 2.0, wall_h / 2.0, 0), Vector3(wall_t, wall_h, compound_size)],
	]
	for w_data in walls:
		var wall := CSGBox3D.new()
		wall.size = w_data[1]
		wall.position = center + w_data[0]
		wall.material = _get_material(wall_col)
		wall.name = "CompoundWall"
		add_child(wall)

	# House inside
	var house_col: Color = FACADE_COLORS[_rng.randi() % FACADE_COLORS.size()]
	var house_w: float = _rng.randf_range(5.0, 7.0)
	var house_d: float = _rng.randf_range(5.0, 7.0)
	var story_h: float = 2.2
	var house_h: float = stories * story_h
	# Slight offset within compound
	var offset_x: float = _rng.randf_range(-1.5, 1.5)
	var offset_z: float = _rng.randf_range(-1.5, 1.5)

	var house := CSGBox3D.new()
	house.size = Vector3(house_w, house_h, house_d)
	house.position = center + Vector3(offset_x, house_h / 2.0, offset_z)
	house.material = _get_material(house_col)
	house.name = "HouseBody"
	add_child(house)

	# Pitched roof cap
	var roof := CSGBox3D.new()
	roof.size = Vector3(house_w + 0.4, 0.5, house_d + 0.4)
	roof.position = center + Vector3(offset_x, house_h + 0.25, offset_z)
	roof.material = _get_material(Color(0.55, 0.25, 0.18))
	roof.name = "HouseRoof"
	add_child(roof)

	# Warm-glow windows on all four facades (reads as "someone's home at night")
	var house_center := center + Vector3(offset_x, 0, offset_z)
	var window_w := 0.55
	var window_h := 0.55
	var win_depth := 0.05
	for s in range(stories):
		var row_y: float = s * story_h + story_h * 0.55
		# Front (+Z) and back (-Z) faces — windows across the width
		var num_x: int = int(max(2, round(house_w / 1.8)))
		for n in range(num_x):
			var wx: float = -house_w / 2.0 + house_w * (n + 1.0) / (num_x + 1.0)
			var front := CSGBox3D.new()
			front.size = Vector3(window_w, window_h, win_depth)
			front.position = house_center + Vector3(wx, row_y, house_d / 2.0 + win_depth / 2.0)
			front.material = _pick_window_warm()
			front.name = "HouseWindowFront"
			add_child(front)
			var back := CSGBox3D.new()
			back.size = Vector3(window_w, window_h, win_depth)
			back.position = house_center + Vector3(wx, row_y, -house_d / 2.0 - win_depth / 2.0)
			back.material = _pick_window_warm()
			back.name = "HouseWindowBack"
			add_child(back)
		# Left (-X) and right (+X) faces — windows across the depth
		var num_z: int = int(max(2, round(house_d / 1.8)))
		for n in range(num_z):
			var wz: float = -house_d / 2.0 + house_d * (n + 1.0) / (num_z + 1.0)
			var right := CSGBox3D.new()
			right.size = Vector3(win_depth, window_h, window_w)
			right.position = house_center + Vector3(house_w / 2.0 + win_depth / 2.0, row_y, wz)
			right.material = _pick_window_warm()
			right.name = "HouseWindowRight"
			add_child(right)
			var left := CSGBox3D.new()
			left.size = Vector3(win_depth, window_h, window_w)
			left.position = house_center + Vector3(-house_w / 2.0 - win_depth / 2.0, row_y, wz)
			left.material = _pick_window_warm()
			left.name = "HouseWindowLeft"
			add_child(left)


func _place_warehouse(center: Vector3, w: float, h: float, d: float) -> void:
	## Large plain industrial block with corrugated-look roof cap.
	var col := Color(0.65, 0.63, 0.60)
	var body := CSGBox3D.new()
	body.size = Vector3(w, h, d)
	body.position = center + Vector3(0, h / 2.0, 0)
	body.material = _get_material(col)
	body.name = "WarehouseBody"
	add_child(body)

	# Rollup door (darker panel on front face)
	var door := CSGBox3D.new()
	door.size = Vector3(w * 0.35, h * 0.7, 0.06)
	door.position = center + Vector3(0, h * 0.35, -d / 2.0 - 0.03)
	door.material = _get_material(Color(0.3, 0.3, 0.32))
	door.name = "WarehouseDoor"
	add_child(door)

	# Roof cap (slightly darker, wider)
	var roof := CSGBox3D.new()
	roof.size = Vector3(w + 0.2, 0.25, d + 0.2)
	roof.position = center + Vector3(0, h + 0.125, 0)
	roof.material = _get_material(col * 0.75)
	roof.name = "WarehouseRoof"
	add_child(roof)


func _place_trotro_station(center: Vector3) -> void:
	## Canopy + a few parked trotros + a tiny booth.
	var canopy_w := 10.0
	var canopy_d := 5.5
	var canopy_h := 3.0

	# Canopy top
	var top := CSGBox3D.new()
	top.size = Vector3(canopy_w, 0.15, canopy_d)
	top.position = center + Vector3(0, canopy_h, 0)
	top.material = _get_material(Color(0.85, 0.20, 0.15))  # Red canopy
	top.name = "StationCanopy"
	add_child(top)

	# 4 support posts
	var post_positions: Array = [
		Vector3(canopy_w / 2.0 - 0.2, canopy_h / 2.0, canopy_d / 2.0 - 0.2),
		Vector3(-canopy_w / 2.0 + 0.2, canopy_h / 2.0, canopy_d / 2.0 - 0.2),
		Vector3(canopy_w / 2.0 - 0.2, canopy_h / 2.0, -canopy_d / 2.0 + 0.2),
		Vector3(-canopy_w / 2.0 + 0.2, canopy_h / 2.0, -canopy_d / 2.0 + 0.2),
	]
	for p in post_positions:
		var post := CSGCylinder3D.new()
		post.radius = 0.1
		post.height = canopy_h
		post.position = center + p
		post.material = _get_material(Color(0.3, 0.3, 0.32))
		post.name = "StationPost"
		add_child(post)

	# Parked trotros (3 of them, golden yellow)
	for i in range(3):
		var trotro := CSGBox3D.new()
		trotro.size = Vector3(1.6, 1.1, 3.2)
		trotro.position = center + Vector3(-3.0 + i * 3.0, 0.55, 0)
		trotro.material = _get_material(Color(0.92, 0.78, 0.15))
		trotro.name = "ParkedTrotro"
		add_child(trotro)

	# Booth (small gray box beside canopy)
	var booth := CSGBox3D.new()
	booth.size = Vector3(2.0, 2.2, 2.0)
	booth.position = center + Vector3(canopy_w / 2.0 + 1.5, 1.1, 0)
	booth.material = _get_material(Color(0.55, 0.58, 0.60))
	booth.name = "StationBooth"
	add_child(booth)


func _place_dense_market_stalls(center: Vector3, rows: int, cols: int) -> void:
	## Dense grid of market stalls (much denser than the along-road clusters).
	var stall_w := 1.8
	var stall_d := 1.8
	var stall_h := 2.0
	var gap := 0.5
	var total_w: float = cols * stall_w + (cols - 1) * gap
	var total_d: float = rows * stall_d + (rows - 1) * gap

	for r in range(rows):
		for c in range(cols):
			var canopy_col: Color = CANOPY_COLORS[_rng.randi() % CANOPY_COLORS.size()]
			var cx: float = -total_w / 2.0 + stall_w / 2.0 + c * (stall_w + gap)
			var cz: float = -total_d / 2.0 + stall_d / 2.0 + r * (stall_d + gap)
			var stall_center: Vector3 = center + Vector3(cx, 0, cz)

			# Canopy top
			var canopy := CSGBox3D.new()
			canopy.size = Vector3(stall_w, 0.08, stall_d)
			canopy.position = stall_center + Vector3(0, stall_h, 0)
			canopy.material = _get_material(canopy_col)
			canopy.name = "DenseStallCanopy"
			add_child(canopy)

			# 2 support poles (corners)
			for sx in [-1.0, 1.0]:
				var pole := CSGCylinder3D.new()
				pole.radius = 0.04
				pole.height = stall_h
				pole.position = stall_center + Vector3(sx * (stall_w / 2.0 - 0.15), stall_h / 2.0, 0)
				pole.material = _get_material(Color(0.3, 0.28, 0.25))
				pole.name = "DenseStallPole"
				add_child(pole)


func _place_factory(center: Vector3, w: float, h: float, d: float) -> void:
	## Large industrial shed with corrugated roof, chimney stacks, lit windows,
	## and a rollup loading door on the front face.
	var wall_col := Color(0.60, 0.58, 0.55)
	var roof_col := Color(0.40, 0.38, 0.36)

	# Body
	var body := CSGBox3D.new()
	body.size = Vector3(w, h, d)
	body.position = center + Vector3(0, h / 2.0, 0)
	body.material = _get_material(wall_col)
	body.name = "FactoryBody"
	add_child(body)

	# Corrugated roof cap
	var roof := CSGBox3D.new()
	roof.size = Vector3(w + 0.3, 0.3, d + 0.3)
	roof.position = center + Vector3(0, h + 0.15, 0)
	roof.material = _get_material(roof_col)
	roof.name = "FactoryRoof"
	add_child(roof)

	# 2 chimney stacks
	for sx in [-1.0, 1.0]:
		var stack := CSGCylinder3D.new()
		stack.radius = 0.45
		stack.height = h * 0.7
		stack.position = center + Vector3(sx * w * 0.3, h + stack.height / 2.0, -d * 0.25)
		stack.material = _get_material(Color(0.50, 0.48, 0.46))
		stack.name = "FactoryStack"
		add_child(stack)
		# Red safety stripe near top
		var stripe := CSGCylinder3D.new()
		stripe.radius = 0.48
		stripe.height = 0.25
		stripe.position = stack.position + Vector3(0, stack.height / 2.0 - 0.4, 0)
		stripe.material = _get_material(Color(0.82, 0.18, 0.15))
		stripe.name = "FactoryStackStripe"
		add_child(stripe)

	# Window band on the long face (facing +z side here)
	var win_band := CSGBox3D.new()
	win_band.size = Vector3(w * 0.8, h * 0.22, 0.05)
	win_band.position = center + Vector3(0, h * 0.55, d / 2.0 + 0.03)
	win_band.material = _pick_window_warm()
	win_band.name = "FactoryWindows"
	add_child(win_band)

	# Rollup loading door (front-center, dark gray)
	var door := CSGBox3D.new()
	door.size = Vector3(w * 0.22, h * 0.55, 0.08)
	door.position = center + Vector3(0, h * 0.275, -d / 2.0 - 0.04)
	door.material = _get_material(Color(0.28, 0.28, 0.30))
	door.name = "FactoryDoor"
	add_child(door)


func _place_storage_tank(center: Vector3, radius: float, height: float) -> void:
	## Cylindrical industrial tank with slightly domed cap and vertical ladder.
	var body_col := Color(0.78, 0.78, 0.76)

	var body := CSGCylinder3D.new()
	body.radius = radius
	body.height = height
	body.position = center + Vector3(0, height / 2.0, 0)
	body.material = _get_material(body_col)
	body.name = "TankBody"
	add_child(body)

	# Dome cap (short wider cap)
	var cap := CSGCylinder3D.new()
	cap.radius = radius + 0.15
	cap.height = 0.25
	cap.position = center + Vector3(0, height + 0.125, 0)
	cap.material = _get_material(body_col * 0.85)
	cap.name = "TankCap"
	add_child(cap)

	# Vertical ladder (thin strip on one side)
	var ladder := CSGBox3D.new()
	ladder.size = Vector3(0.08, height * 0.95, 0.25)
	ladder.position = center + Vector3(radius + 0.04, height * 0.475, 0)
	ladder.material = _get_material(Color(0.35, 0.35, 0.38))
	ladder.name = "TankLadder"
	add_child(ladder)

	# Horizontal hoop ring (structural detail at 2/3 height)
	var hoop := CSGCylinder3D.new()
	hoop.radius = radius + 0.05
	hoop.height = 0.12
	hoop.position = center + Vector3(0, height * 0.66, 0)
	hoop.material = _get_material(body_col * 0.7)
	hoop.name = "TankHoop"
	add_child(hoop)


func _place_container_yard(center: Vector3) -> void:
	## Grid of shipping containers, some double-stacked. ISO 20ft = ~2.4 x 2.6 x 6.1.
	var container_colors: Array = [
		Color(0.80, 0.25, 0.20),   # Red
		Color(0.20, 0.40, 0.70),   # Blue
		Color(0.85, 0.55, 0.15),   # Orange
		Color(0.55, 0.35, 0.22),   # Rust
		Color(0.20, 0.55, 0.35),   # Green
		Color(0.55, 0.55, 0.58),   # Gray
	]
	var c_w := 2.4
	var c_h := 2.6
	var c_d := 6.1
	var gap := 0.4
	var rows := 3
	var cols := 3
	var total_w: float = cols * c_w + (cols - 1) * gap
	var total_d: float = rows * c_d + (rows - 1) * gap

	for r in range(rows):
		for c in range(cols):
			var cx: float = -total_w / 2.0 + c_w / 2.0 + c * (c_w + gap)
			var cz: float = -total_d / 2.0 + c_d / 2.0 + r * (c_d + gap)
			var col: Color = container_colors[_rng.randi() % container_colors.size()]

			var box := CSGBox3D.new()
			box.size = Vector3(c_w, c_h, c_d)
			box.position = center + Vector3(cx, c_h / 2.0, cz)
			box.material = _get_material(col)
			box.name = "Container"
			add_child(box)

			# ~35% chance of a stacked container
			if _rng.randf() < 0.35:
				var top_col: Color = container_colors[_rng.randi() % container_colors.size()]
				var stacked := CSGBox3D.new()
				stacked.size = Vector3(c_w, c_h, c_d)
				stacked.position = center + Vector3(cx, c_h * 1.5 + 0.05, cz)
				stacked.material = _get_material(top_col)
				stacked.name = "ContainerStacked"
				add_child(stacked)


func _place_residential_street(center: Vector3, length: float, is_ns: bool,
							   width: float = 3.0) -> void:
	## Flat asphalt slab for an internal neighborhood street. Sits just above
	## the ground plane; buildings and lamps placed on top render correctly.
	var slab := CSGBox3D.new()
	if is_ns:
		slab.size = Vector3(width, 0.08, length)
	else:
		slab.size = Vector3(length, 0.08, width)
	slab.position = center + Vector3(0, 0.04, 0)
	slab.material = _get_material(ASPHALT)
	slab.name = "ResidentialStreet"
	add_child(slab)


func _place_residential_lamp(base: Vector3) -> void:
	## Small residential street lamp — 4m pole with a warm sodium head.
	## OmniLight is appended to _yard_lights so it toggles with the night cycle.
	var pole_h := 4.0
	var pole := CSGCylinder3D.new()
	pole.radius = 0.07
	pole.height = pole_h
	pole.position = base + Vector3(0, pole_h / 2.0, 0)
	pole.material = _get_material(Color(0.30, 0.30, 0.32))
	pole.name = "ResLampPole"
	add_child(pole)

	# Small lamp head — shares the sodium glow material (emissive at night).
	var head := CSGBox3D.new()
	head.size = Vector3(0.28, 0.12, 0.28)
	head.position = base + Vector3(0, pole_h + 0.06, 0)
	head.material = _mat_sodium_glow
	head.name = "ResLampHead"
	add_child(head)

	# Real scene light — bright enough to actually illuminate nearby houses.
	var light := OmniLight3D.new()
	light.position = base + Vector3(0, pole_h + 0.15, 0)
	light.omni_range = 22.0
	light.light_energy = 3.5
	light.light_color = Color(1.0, 0.85, 0.55)
	light.shadow_enabled = false
	light.visible = false
	add_child(light)
	_yard_lights.append(light)


func _place_yard_light(base: Vector3) -> void:
	## Industrial floodlight — tall pole + sodium lamp head + OmniLight3D.
	var pole_h := 9.5
	var pole := CSGCylinder3D.new()
	pole.radius = 0.14
	pole.height = pole_h
	pole.position = base + Vector3(0, pole_h / 2.0, 0)
	pole.material = _get_material(Color(0.30, 0.30, 0.32))
	pole.name = "YardPole"
	add_child(pole)

	# Angled lamp head (emissive, sodium orange)
	var head := CSGBox3D.new()
	head.size = Vector3(0.65, 0.3, 0.85)
	head.position = base + Vector3(0, pole_h + 0.15, 0.25)
	head.material = _mat_sodium_glow
	head.name = "YardLampHead"
	add_child(head)

	# Scene light
	var light := OmniLight3D.new()
	light.position = base + Vector3(0, pole_h + 0.3, 0.1)
	light.omni_range = 28.0
	light.light_energy = 2.5
	light.light_color = Color(1.0, 0.82, 0.55)
	light.shadow_enabled = false
	light.visible = false
	add_child(light)
	_yard_lights.append(light)


func _place_tanker_truck(center: Vector3) -> void:
	## Cab + cylindrical tank trailer (parked). Simple silhouette.
	# Cab
	var cab := CSGBox3D.new()
	cab.size = Vector3(1.8, 1.6, 2.4)
	cab.position = center + Vector3(0, 0.95, -2.8)
	cab.material = _get_material(Color(0.25, 0.40, 0.70))
	cab.name = "TankerCab"
	add_child(cab)

	# Cab windshield
	var wind := CSGBox3D.new()
	wind.size = Vector3(1.7, 0.6, 0.06)
	wind.position = center + Vector3(0, 1.5, -2.8 - 1.24)
	wind.material = _get_material(Color(0.18, 0.22, 0.30))
	wind.name = "TankerWindshield"
	add_child(wind)

	# Tank trailer (cylinder lying on its side — rotate on X)
	var tank := CSGCylinder3D.new()
	tank.radius = 1.0
	tank.height = 5.5
	tank.rotation_degrees = Vector3(90, 0, 0)
	tank.position = center + Vector3(0, 1.25, 1.2)
	tank.material = _get_material(Color(0.85, 0.85, 0.88))
	tank.name = "TankerTank"
	add_child(tank)

	# Undercarriage chassis
	var chassis := CSGBox3D.new()
	chassis.size = Vector3(1.6, 0.2, 7.5)
	chassis.position = center + Vector3(0, 0.15, -0.5)
	chassis.material = _get_material(Color(0.15, 0.15, 0.17))
	chassis.name = "TankerChassis"
	add_child(chassis)


func _place_flatbed_truck(center: Vector3) -> void:
	## Cab + flat cargo bed — optionally with a crate on top.
	var cab := CSGBox3D.new()
	cab.size = Vector3(1.8, 1.6, 2.2)
	cab.position = center + Vector3(0, 0.95, -2.2)
	cab.material = _get_material(Color(0.70, 0.25, 0.20))
	cab.name = "FlatbedCab"
	add_child(cab)

	# Flat bed
	var bed := CSGBox3D.new()
	bed.size = Vector3(1.9, 0.35, 4.0)
	bed.position = center + Vector3(0, 0.85, 1.0)
	bed.material = _get_material(Color(0.30, 0.28, 0.25))
	bed.name = "FlatbedBed"
	add_child(bed)

	# Crate on bed
	var crate := CSGBox3D.new()
	crate.size = Vector3(1.7, 1.4, 2.6)
	crate.position = center + Vector3(0, 0.85 + 0.175 + 0.7, 0.8)
	crate.material = _get_material(Color(0.55, 0.38, 0.22))
	crate.name = "FlatbedCrate"
	add_child(crate)

	# Chassis
	var chassis := CSGBox3D.new()
	chassis.size = Vector3(1.6, 0.2, 6.5)
	chassis.position = center + Vector3(0, 0.15, -0.2)
	chassis.material = _get_material(Color(0.15, 0.15, 0.17))
	chassis.name = "FlatbedChassis"
	add_child(chassis)


func _place_bleacher(center: Vector3, width: float, rows: int, face_z: float) -> void:
	## Stepped concrete bleacher. face_z = +1 or -1 (direction seats face).
	## Row 0 is frontmost (near pitch); each later row steps UP and AWAY from pitch.
	var row_h := 0.32
	var row_d := 0.55
	for r in range(rows):
		var y: float = r * row_h + row_h / 2.0
		var z_shift: float = -face_z * r * row_d
		var seat := CSGBox3D.new()
		seat.size = Vector3(width, row_h, row_d)
		seat.position = center + Vector3(0, y, z_shift)
		seat.material = _get_material(Color(0.62, 0.60, 0.58))
		seat.name = "BleacherStep"
		add_child(seat)
	# Side walls (simple trapezoid-ish approximation using 2 boxes)
	var total_h: float = rows * row_h
	var total_d: float = rows * row_d
	for sx in [-1.0, 1.0]:
		var wall := CSGBox3D.new()
		wall.size = Vector3(0.2, total_h, total_d)
		wall.position = center + Vector3(
			sx * (width / 2.0 + 0.1),
			total_h / 2.0,
			-face_z * (rows - 1) * row_d / 2.0
		)
		wall.material = _get_material(Color(0.52, 0.52, 0.54))
		wall.name = "BleacherWall"
		add_child(wall)


func _place_goal_post(center: Vector3, facing_x: float) -> void:
	## Small goal post at a pitch end. facing_x = +1 if goal opens in +X direction
	## (i.e., the pitch lies in +X from center), -1 otherwise. The net extends AWAY
	## from the pitch behind the goal line.
	var goal_w := 4.5    # Distance between the 2 vertical posts (along Z)
	var goal_h := 1.3    # Height of crossbar
	var goal_d := 1.0    # How far the net extends back (away from pitch)
	var post_r := 0.06

	# 2 vertical posts at the goal line
	for sz in [-1.0, 1.0]:
		var post := CSGCylinder3D.new()
		post.radius = post_r
		post.height = goal_h
		post.position = center + Vector3(0, goal_h / 2.0, sz * goal_w / 2.0)
		post.material = _get_material(CROSS_WHITE)
		post.name = "GoalPost"
		add_child(post)

	# Crossbar (thin box along Z at the top)
	var bar := CSGBox3D.new()
	bar.size = Vector3(post_r * 2.0, post_r * 2.0, goal_w)
	bar.position = center + Vector3(0, goal_h, 0)
	bar.material = _get_material(CROSS_WHITE)
	bar.name = "GoalCrossbar"
	add_child(bar)

	# Back posts (shorter, leaning back into net)
	for sz in [-1.0, 1.0]:
		var back_post := CSGCylinder3D.new()
		back_post.radius = post_r * 0.8
		back_post.height = goal_h * 0.85
		back_post.position = center + Vector3(
			-facing_x * goal_d,
			goal_h * 0.425,
			sz * goal_w / 2.0
		)
		back_post.material = _get_material(Color(0.62, 0.62, 0.64))
		back_post.name = "GoalBackPost"
		add_child(back_post)

	# Net top (connects top of back posts, thin horizontal panel)
	var net_top := CSGBox3D.new()
	net_top.size = Vector3(goal_d, 0.03, goal_w)
	net_top.position = center + Vector3(
		-facing_x * goal_d * 0.5,
		goal_h * 0.9,
		0
	)
	net_top.material = _get_material(Color(0.58, 0.58, 0.60))
	net_top.name = "GoalNetTop"
	add_child(net_top)


func _place_tree(center: Vector3) -> void:
	## Simple tree: trunk cylinder + spherical canopy.
	var trunk_h: float = _rng.randf_range(1.8, 3.0)
	var canopy_r: float = _rng.randf_range(0.9, 1.6)
	var canopy_col: Color = TREE_GREENS[_rng.randi() % TREE_GREENS.size()]

	var trunk := CSGCylinder3D.new()
	trunk.radius = 0.16
	trunk.height = trunk_h
	trunk.position = center + Vector3(0, trunk_h / 2.0, 0)
	trunk.material = _get_material(TRUNK_COLOR)
	trunk.name = "TreeTrunk"
	add_child(trunk)

	var canopy := CSGSphere3D.new()
	canopy.radius = canopy_r
	canopy.position = center + Vector3(0, trunk_h + canopy_r * 0.7, 0)
	canopy.material = _get_material(canopy_col)
	canopy.name = "TreeCanopy"
	add_child(canopy)


func _scatter_trees(xs: float, zs: float, count: int) -> void:
	## Scatter trees randomly across a quadrant. Honours _exclusion_zones so
	## trees don't spawn on football pitch / factory footprints / etc. Minor
	## overlap with houses / small buildings is still acceptable (reads as
	## "tree in compound yard" visually).
	for _i in range(count):
		# Up to 6 retries per tree to find a non-excluded spot
		for _attempt in range(6):
			var ax: float = _rng.randf_range(16.0, 82.0)
			var az: float = _rng.randf_range(16.0, 82.0)
			var wx: float = xs * ax
			var wz: float = zs * az
			if not _in_exclusion_zone(wx, wz):
				_place_tree(Vector3(wx, 0, wz))
				break


func _place_petrol_station(center: Vector3) -> void:
	## Canopy on 4 pillars + 2 fuel pumps + small kiosk.
	var canopy_w := 7.0
	var canopy_d := 5.0
	var canopy_h := 3.8

	# Asphalt pad
	var pad := CSGBox3D.new()
	pad.size = Vector3(canopy_w + 2.0, 0.05, canopy_d + 2.0)
	pad.position = center + Vector3(0, 0.025, 0)
	pad.material = _get_material(ASPHALT)
	pad.name = "PetrolPad"
	add_child(pad)

	# Canopy top (yellow/orange — Shell-ish, or green for Goil)
	var top := CSGBox3D.new()
	top.size = Vector3(canopy_w, 0.3, canopy_d)
	top.position = center + Vector3(0, canopy_h, 0)
	top.material = _get_material(Color(0.90, 0.78, 0.10))
	top.name = "PetrolCanopy"
	add_child(top)

	# Red trim stripe
	var trim := CSGBox3D.new()
	trim.size = Vector3(canopy_w + 0.1, 0.12, canopy_d + 0.1)
	trim.position = center + Vector3(0, canopy_h - 0.2, 0)
	trim.material = _get_material(Color(0.85, 0.15, 0.12))
	trim.name = "PetrolTrim"
	add_child(trim)

	# Under-canopy glow panel (reads as recessed fluorescents at night)
	var under_glow := CSGBox3D.new()
	under_glow.size = Vector3(canopy_w - 0.6, 0.08, canopy_d - 0.6)
	under_glow.position = center + Vector3(0, canopy_h - 0.35, 0)
	under_glow.material = _mat_canopy_glow
	under_glow.name = "PetrolUnderGlow"
	add_child(under_glow)

	# Scene light under the canopy (illuminates pumps + any vehicles below)
	_petrol_light = OmniLight3D.new()
	_petrol_light.position = center + Vector3(0, canopy_h - 0.6, 0)
	_petrol_light.omni_range = 22.0
	_petrol_light.light_energy = 3.2
	_petrol_light.light_color = Color(1.0, 0.96, 0.80)
	_petrol_light.shadow_enabled = false
	_petrol_light.visible = false
	add_child(_petrol_light)

	# 4 pillars
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var pillar := CSGBox3D.new()
			pillar.size = Vector3(0.3, canopy_h, 0.3)
			pillar.position = center + Vector3(sx * (canopy_w / 2.0 - 0.2),
				canopy_h / 2.0, sz * (canopy_d / 2.0 - 0.2))
			pillar.material = _get_material(Color(0.82, 0.80, 0.78))
			pillar.name = "PetrolPillar"
			add_child(pillar)

	# 2 pump islands
	for dz in [-1.2, 1.2]:
		var pump := CSGBox3D.new()
		pump.size = Vector3(0.5, 1.4, 0.7)
		pump.position = center + Vector3(0, 0.7, dz)
		pump.material = _get_material(Color(0.85, 0.15, 0.12))
		pump.name = "PetrolPump"
		add_child(pump)

	# Kiosk beside canopy
	var kiosk := CSGBox3D.new()
	kiosk.size = Vector3(3.0, 2.5, 3.0)
	kiosk.position = center + Vector3(canopy_w / 2.0 + 2.5, 1.25, 0)
	kiosk.material = _get_material(Color(0.92, 0.88, 0.78))
	kiosk.name = "PetrolKiosk"
	add_child(kiosk)
