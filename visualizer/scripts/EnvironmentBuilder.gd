extends Node3D

const TransitLayout = preload("res://scripts/TransitLayout.gd")

const SignLayout = preload("res://scripts/StreetSignLayout.gd")
## Procedurally generates Accra-style buildings, shops, compound walls,
## and market stalls along all road arms of the single junction.
##
## Detailed mesh architecture and vegetation are built by AccraStreetscape;
## legacy landmarks retain their geometry with shared weathered materials.
## Built once in _ready() with seeded RNG for deterministic placement.
##
## Placement zone:
##   [Grass] [Buildings] [Sidewalk] [Road] [Sidewalk] [Buildings] [Grass]

# ── Road geometry (must match Intersection.gd) ──────────────────────────────
const Streetscape = preload("res://scripts/AccraStreetscape.gd")
const SurfaceMaterials = preload("res://scripts/StreetscapeMaterials.gd")
var _streetscape: Node3D

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
const JUNCTION_MARGIN := 5.5     # Don't place buildings too close to junction
                                 # (was 3.0 — crowded the TL poles/cabinets)
const ROAD_END_MARGIN := 5.0     # Don't place buildings at road edge

# ── Open roadside drainage (classic Accra concrete U-gutters) ───────────────
const GUTTER_WIDTH        := 0.6    # channel width, runs beside the sidewalk
const GUTTER_RIM_W        := 0.10   # concrete rim thickness each side
const GUTTER_RIM_H        := 0.15   # rim height (matches sidewalk curb)
const GUTTER_FLOOR_COLOR  := Color(0.10, 0.11, 0.12)   # dark channel interior
const GUTTER_CONCRETE     := Color(0.62, 0.60, 0.56)   # weathered concrete
const GUTTER_SLAB_COLOR   := Color(0.68, 0.66, 0.62)   # slightly lighter slabs

# ── Accra facade palette ────────────────────────────────────────────────────
# ── District palettes (quadrant fill) ───────────────────────────────────────
const GLASS_COLORS: Array = [
	Color(0.35, 0.50, 0.65),   # Blue-tinted glass
	Color(0.40, 0.55, 0.60),   # Teal glass
	Color(0.50, 0.55, 0.60),   # Silver glass
	Color(0.30, 0.42, 0.55),   # Deep blue
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
var _materials: Dictionary = {}   # Glass material cache

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
# Reserved full plots, including shop aprons, keep frontage and districts separate.
var _occupied_plots: Array[Rect2] = []
var frontage_uses: Array[Dictionary] = []

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
	_streetscape = Streetscape.new()
	_streetscape.name = "DetailedStreetscape"
	add_child(_streetscape)
	_streetscape.configure(_mat_window_warm_early, _mat_window_cool_early)

	for stop in TransitLayout.stations(corridor_mode):
		var reserved: Rect2 = TransitLayout.plot(stop)
		_add_exclusion_zone(reserved.position.x, reserved.position.y, reserved.end.x, reserved.end.y)
	for spec in SignLayout.billboards(corridor_mode):
		var plot: Rect2 = SignLayout.plot(spec)
		_add_exclusion_zone(plot.position.x, plot.position.y, plot.end.x, plot.end.y)
	if corridor_mode:
		_build_corridor()
	else:
		# Lay out districts and their access streets before filling roadside plots.
		_build_quadrants()
		_build_junction_corners()
		_reserve_district_buildings()
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
		for xs in [-1.0, 1.0]:
			for zs in [-1.0, 1.0]:
				_scatter_trees(xs, zs, TREES_PER_QUADRANT)

	_streetscape.backdrop(corridor_mode)
	_streetscape.finish()

	# Hook into day/night cycle so emissive materials + OmniLights toggle correctly
	_wire_day_night()

	# Enable collision on all CSG geometry so the ground-level player can't walk
	# through buildings, tanks, goal posts, etc. Small decorative CSGs above
	# head-height are harmless — the player can't reach them anyway.
	_enable_collision_on_all_csg(self)

	print("[EnvironmentBuilder] Built detailed Accra streetscape and district lighting")


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

func _building_plot(center: Vector3, facing: Vector3, width: float, depth: float,
		apron: float = 1.3) -> Rect2:
	# Local +Z faces the road. Include roof edges and the usable front apron.
	var size := Vector2(width + 0.8, depth + 0.4 + apron)
	var at := center + facing * ((apron - 0.4) * 0.5)
	if absf(facing.x) > 0.5:
		size = Vector2(size.y, size.x)
	return Rect2(Vector2(at.x, at.z) - size * 0.5, size)


func _reserve_district_buildings() -> void:
	for use: Dictionary in _streetscape.land_uses:
		_occupied_plots.append(_building_plot(use.center, use.facing, use.width, use.depth))


func _plot_available(plot: Rect2) -> bool:
	for zone in _exclusion_zones:
		if plot.intersects(Rect2(zone[0], zone[1], zone[2] - zone[0], zone[3] - zone[1])):
			return false
	for occupied in _occupied_plots:
		if plot.intersects(occupied):
			return false
	return true


func _build_arm_buildings(arm_name: String, axis: int, dir_sign: float,
		road_width: float) -> void:
	var arm_id: int = ["north", "south", "east", "west"].find(arm_name)
	for side in range(2):
		var side_sign: float = -1.0 if side == 0 else 1.0
		var face: float = side_sign * (road_width * 0.5 + SIDEWALK_WIDTH + BUILDING_OFFSET)
		_build_frontage_strip(axis, dir_sign, JUNCTION_HALF + JUNCTION_MARGIN + 5.0,
			JUNCTION_HALF + ROAD_LENGTH - ROAD_END_MARGIN, face, side_sign, arm_id * 2 + side)


func _build_frontage_strip(axis: int, direction: float, start: float, end: float,
		face: float, side: float, district_id: int) -> void:
	# One anchor business per strip, followed by small independent shops/kiosks.
	# Homes are exclusively in the interior neighbourhoods.
	var anchors: Array[String] = ["supermarket", "mechanic", "mall", "police", "supermarket", "mechanic", "mall", "shop"]
	var local_uses: Array[String] = ["shop", "kiosk", "shop", "shop", "kiosk"]
	var cursor: float = start
	var index: int = 0
	while cursor < end:
		var kind: String = anchors[district_id % anchors.size()] if index == 0 else local_uses[(index + district_id) % local_uses.size()]
		var sizes: Dictionary = {"supermarket": Vector2(8.4, 5.2), "mall": Vector2(11.0, 5.5),
			"mechanic": Vector2(8.0, 5.8), "police": Vector2(7.0, 5.0),
			"shop": Vector2(4.6, 3.6), "kiosk": Vector2(2.6, 2.4)}
		var size: Vector2 = sizes[kind]
		if cursor + size.x > end:
			break
		var center := _compute_position(axis, direction, cursor + size.x * 0.5, face, side, size.y)
		var facing := Vector3(0, 0, -side) if axis == 0 else Vector3(-side, 0, 0)
		var plot := _building_plot(center, facing, size.x, size.y)
		if not _plot_available(plot):
			cursor += 1.0
			continue
		_streetscape.commercial(center, facing, size.x, size.y, kind)
		# Each entrance has its own paved connection over the drain to the sidewalk.
		var path := CSGBox3D.new()
		var access_width: float = size.x * 0.75 if kind == "mechanic" else 1.35
		path.size = _orient_size(axis, access_width, 0.08, BUILDING_OFFSET + 0.15)
		path.position = _compute_position(axis, direction, cursor + size.x * 0.5,
			face - side * (BUILDING_OFFSET + 0.075), side, BUILDING_OFFSET + 0.15) + Vector3(0, 0.16, 0)
		path.material = SurfaceMaterials.surface(2, Color("aaa89a"))
		path.name = "ShopAccessBridge"
		add_child(path)
		_occupied_plots.append(plot)
		frontage_uses.append({"kind": kind, "center": center, "plot": plot})
		cursor += size.x + 1.25
		index += 1


func _build_arm_gutters(axis: int, dir_sign: float, road_width: float) -> void:
	## Open concrete drainage gutters along both sides of a road arm, in the
	## strip between the sidewalk and the building setback. Slab bridges align
	## with shop entrances and the mouths of neighbourhood access streets.
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

		# Road entrances get wide culvert slabs; individual shops place their own
		# aligned access bridges, so none end at an arbitrary point on a wall.
		for child in get_children():
			if not child is CSGBox3D or not (String(child.name).begins_with("ResidentialStreet") or String(child.name).begins_with("CommercialAccess")):
				continue
			var runs_ns: bool = child.size.z > child.size.x
			if runs_ns == (axis == 1):
				continue
			var along: float = child.position.z if axis == 1 else child.position.x
			var across: float = child.position.x if axis == 1 else child.position.z
			if signf(along) != dir_sign or signf(across) != side_sign:
				continue
			var span: float = 1.3
			var entrance_width: float = child.size.z if axis == 1 else child.size.x
			var slab := CSGBox3D.new()
			slab.size = _orient_size(axis, entrance_width + 0.4, 0.08, span)
			slab.position = _compute_position(axis, dir_sign, absf(along),
					side_sign * (inner - GUTTER_RIM_W), side_sign, span) \
					+ Vector3(0, 0.16, 0)
			slab.material = _get_material(GUTTER_SLAB_COLOR)
			slab.name = "GutterBridge"
			add_child(slab)


# ═════════════════════════════════════════════════════════════════════════════
# CORRIDOR STREETSCAPE (3-junction) — reuses the single-junction primitives
# ═════════════════════════════════════════════════════════════════════════════

func _build_corridor() -> void:
	# Districts own their land first. A single commercial strip faces each road;
	# the former second row overlapped compounds and institutional grounds.
	_add_exclusion_zone(12.0, 5.0, 60.0, 27.0)
	_add_exclusion_zone(-50.0, 4.0, -10.0, 28.0)
	_place_airport(38.0, 96.0)
	_corridor_industrial(-38.0, 88.0)
	_corridor_offices(38.0, 45.0)
	for i in range(3):
		_place_apartment(Vector3(-24.0 - i * 14.0, 0, 45.0), [8, 11, 9][i], 8.0, 6.0)
	_corridor_institutional(38.0, 16.0)
	_corridor_hospital(-38.0, 16.0)
	_corridor_residential(38.0, -32.0, 3, 3)
	_corridor_market(-38.0, -32.0)
	_place_petrol_station(Vector3(24.0, 0, -10.0))
	_place_petrol_station(Vector3(-24.0, 0, 70.0))
	_reserve_district_buildings()

	# The corridor sidewalk is 0.7 wide; every frontage faces the actual curb.
	var junctions: Array[float] = [0.0, 30.0, 60.0]
	for side in range(2):
		var side_sign: float = -1.0 if side == 0 else 1.0
		var face: float = side_sign * (3.0 + 0.7 + BUILDING_OFFSET)
		# Separate stretches preserve junction sightlines and crossing space.
		for stretch in range(4):
			var starts: Array[float] = [-53.0, 10.0, 40.0, 70.0]
			var ends: Array[float] = [-10.0, 20.0, 50.0, 113.0]
			_build_frontage_strip(1, 1.0, starts[stretch], ends[stretch], face, side_sign, stretch * 2 + side)
	for j in range(3):
		_placement_origin = Vector3(0, 0, junctions[j])
		for direction in [-1.0, 1.0]:
			var road_width: float = [5.0, 5.0, 3.0][j] if direction < 0 else [3.0, 5.0, 3.0][j]
			for side in range(2):
				var side_sign: float = -1.0 if side == 0 else 1.0
				var face: float = side_sign * (road_width * 0.5 + 0.7 + BUILDING_OFFSET)
				_build_frontage_strip(0, direction, 10.0, 53.0, face, side_sign, j * 2 + side + (2 if direction > 0 else 0))
	_placement_origin = Vector3.ZERO


## ── Corridor districts — compose existing primitives at offsets from a block
##    centre (cx, cz). Offsets use cx+offset so the same formula works on the +X
##    and −X flanks (cx already carries the side's sign). ──────────────────────

func _corridor_offices(cx: float, cz: float) -> void:
	## Commercial core: tall glassy towers + mid-rise + parking.
	_place_residential_street(Vector3(cx - 20, 0, cz), 30.0, true, 2.5, "CommercialAccess")
	_place_residential_street(Vector3(cx, 0, cz - 10), 40.0, false, 2.5, "CommercialAccess")
	_place_office_tower(Vector3(cx - 12, 0, cz - 4), 12, 7.0, 7.0)
	_place_office_tower(Vector3(cx + 2, 0, cz + 4), 10, 7.0, 6.5)
	_place_midrise_office(Vector3(cx + 14, 0, cz - 4), 8, 6.0, 6.0)
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
			if j == rows - 1:
				# The row nearest the cross street is a service/commercial buffer.
				_streetscape.commercial(Vector3(x, 0, z), Vector3.BACK, 8.0, 5.0,
					["supermarket", "shop", "police"][i % 3])
			elif i == 1 and j == 1:
				_place_apartment(Vector3(x, 0, z), 9, 8.0, 8.0)
			else:
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


func _place_airport(_cx: float, _cz: float) -> void:
	var layout = preload("res://scripts/AirportLayout.gd")
	var plot: Rect2 = layout.SITE
	_add_exclusion_zone(plot.position.x, plot.position.y, plot.end.x, plot.end.y)
	var access: Rect2 = layout.ACCESS
	_add_exclusion_zone(access.position.x, access.position.y, access.end.x, access.end.y)
	var airport = preload("res://scripts/AirportBuilder.gd").new()
	airport.name = "Airport"
	add_child(airport)


# ═════════════════════════════════════════════════════════════════════════════
# BUILDING TYPES
# ═════════════════════════════════════════════════════════════════════════════

func _build_junction_corners() -> void:
	var face_line: float = JUNCTION_HALF + SIDEWALK_WIDTH + BUILDING_OFFSET
	var signs: Array[Vector2] = [Vector2(-1, 1), Vector2(1, 1), Vector2(-1, -1), Vector2(1, -1)]
	for i in range(signs.size()):
		var sgn: Vector2 = signs[i]
		var pos := Vector3(sgn.x * (face_line + 2.1), 0, sgn.y * (face_line + 2.1))
		var facing := Vector3(0, 0, -sgn.y) if i % 2 == 0 else Vector3(-sgn.x, 0, 0)
		_streetscape.commercial(pos, facing, 4.2, 4.2, "shop")


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


func _get_material(color: Color) -> Material:
	# Existing landmarks now share the same tactile surfaces as the new kit.
	var kind: int = 0
	if color.is_equal_approx(ASPHALT):
		kind = 1
	elif color.is_equal_approx(ROOF_DARK):
		kind = 4
	return SurfaceMaterials.surface(kind, color)


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

	# One petrol station (SW inner corner — visible from junction)
	_place_petrol_station(Vector3(22, 0, -22))


# ─── NE: Commercial / Office district ───────────────────────────────────────

func _build_commercial_quadrant(xs: float, zs: float) -> void:
	## NE quadrant — offices, tall towers, shopping mall, parking.
	# Interior access connects the offices and mall to two clear street mouths.
	_place_residential_street(Vector3(xs * 35, 0, zs * 45), 80.0, true, 3.0, "CommercialAccess")
	_place_residential_street(Vector3(xs * 45, 0, zs * 45), 80.0, false, 3.0, "CommercialAccess")
	# Taller offices step back behind the low commercial frontage.
	_place_office_tower(Vector3(xs * 24, 0, zs * 26), 11, 7.5, 7.5)

	# Secondary tower — mid-depth
	_place_office_tower(Vector3(xs * 52, 0, zs * 36), 9, 7.0, 7.0)

	# Tertiary tower — back
	_place_office_tower(Vector3(xs * 26, 0, zs * 58), 8, 6.5, 6.5)

	# Shopping mall — long flat block at the far corner
	_place_shopping_mall(Vector3(xs * 65, 0, zs * 65), 18.0, 5.5, 9.0)

	# Parking lot in front of mall
	_place_parking_lot(Vector3(xs * 50, 0, zs * 68), 14.0, 7.0, 8)

	# Mid-rise office fillers
	_place_midrise_office(Vector3(xs * 45, 0, zs * 22), 4, 5.0, 5.0)
	_place_midrise_office(Vector3(xs * 70, 0, zs * 25), 3, 4.5, 4.5)
	_place_midrise_office(Vector3(xs * 42, 0, zs * 55), 4, 4.8, 4.8)
	_place_midrise_office(Vector3(xs * 72, 0, zs * 50), 3, 4.5, 5.0)

	_place_office_tower(Vector3(xs * 68, 0, zs * 39), 10, 7.0, 7.0)

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
		if pos.is_equal_approx(Vector3(xs * 46, 0, zs * 74)):
			_place_apartment(pos, 11, 10.0, 9.0)
		elif pos.is_equal_approx(Vector3(xs * 68, 0, zs * 50)):
			_place_apartment(pos, 9, 10.0, 9.0)
		else:
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
	_streetscape.office(center, stories, base_w, base_d)


func _place_midrise_office(center: Vector3, stories: int, w: float, d: float) -> void:
	_streetscape.office(center, stories, w, d)


func _place_apartment(center: Vector3, stories: int, w: float, d: float) -> void:
	_streetscape.apartment(center, Vector3.BACK, stories, w, d)


func _place_shopping_mall(center: Vector3, w: float, _h: float, d: float) -> void:
	_streetscape.commercial(center, Vector3.BACK, w, d, "mall")


func _place_parking_lot(center: Vector3, w: float, d: float, num_cars: int) -> void:
	_add_exclusion_zone(center.x - w * 0.5, center.z - d * 0.5, center.x + w * 0.5, center.z + d * 0.5)
	_streetscape.parking_lot(center, w, d, num_cars)


func _place_school_building(center: Vector3, stories: int, w: float, d: float) -> void:
	_streetscape.building(center, Vector3.BACK, w, d, stories, false, true)


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
	_add_exclusion_zone(center.x - 4.4, center.z - 7.5, center.x + 4.4, center.z + 5.4)
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
	_streetscape.building(center, Vector3.BACK, 8.0, 5.5, 2, false, true, "COMMUNITY\nHEALTH CENTRE")


func _place_house_compound(center: Vector3, compound_size: float, stories: int) -> void:
	_streetscape.compound(center, compound_size, stories)


func _place_warehouse(center: Vector3, w: float, h: float, d: float) -> void:
	_streetscape.warehouse(center, w, h, d)


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
	for row in range(rows):
		for col in range(cols):
			var pos := center + Vector3((col - (cols - 1) * 0.5) * 2.3, 0, (row - (rows - 1) * 0.5) * 2.8)
			_streetscape.market_stall(pos, Vector3.BACK, 1.8, 1.7)


func _place_factory(center: Vector3, w: float, h: float, d: float) -> void:
	_streetscape.factory(center, w, h, d)


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
							   width: float = 3.0, street_name: String = "ResidentialStreet") -> void:
	## Flat asphalt slab for an internal neighborhood street. Sits just above
	## the ground plane; buildings and lamps placed on top render correctly.
	var slab := CSGBox3D.new()
	if is_ns:
		slab.size = Vector3(width, 0.08, length)
	else:
		slab.size = Vector3(length, 0.08, width)
	_add_exclusion_zone(center.x - slab.size.x * 0.5 - 0.25, center.z - slab.size.z * 0.5 - 0.25,
		center.x + slab.size.x * 0.5 + 0.25, center.z + slab.size.z * 0.5 + 0.25)
	slab.position = center + Vector3(0, 0.04, 0)
	slab.material = _get_material(ASPHALT)
	slab.name = street_name
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
	_streetscape.tree(center, _rng.randf() < 0.18)


func _scatter_trees(xs: float, zs: float, count: int) -> void:
	## Keep scattered trees outside buildings, forecourts and access streets.
	for _i in range(count):
		# Up to 6 retries per tree to find a non-excluded spot
		for _attempt in range(6):
			var ax: float = _rng.randf_range(16.0, 82.0)
			var az: float = _rng.randf_range(16.0, 82.0)
			var wx: float = xs * ax
			var wz: float = zs * az
			if _plot_available(Rect2(wx - 1.0, wz - 1.0, 2.0, 2.0)):
				_place_tree(Vector3(wx, 0, wz))
				break


func _place_petrol_station(center: Vector3) -> void:
	_add_exclusion_zone(center.x - 4.8, center.z - 3.8, center.x + 7.8, center.z + 3.8)
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
