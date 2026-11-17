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
const StreetLife = preload("res://scripts/AccraStreetLife.gd")
var _streetscape: Node3D
# Traders, hawkers, okadas and signboards on the aprons in front of the shops.
var _street_life: RefCounted
# Shop front to back of footway: the dusty trading apron every Accra road has.
var _frontage_setback: float = 6.0
# Width behind the footway kept for lamp columns, poles and the open drain.
var _frontage_service: float = 2.0

const ROAD_LENGTH     := 90.0
const NS_ROAD_WIDTH   := 12.8
const E_ROAD_WIDTH    := 12.8
const W_ROAD_WIDTH    := 12.8
const JUNCTION_SIZE   := 7.0
const JUNCTION_HALF   := 10.4
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
var _mat_fuel_fascia: StandardMaterial3D   # Filling-station fascia, backlit at night
var _mat_fuel_stripe: StandardMaterial3D   # Amber reveals, roundels and stripes, lit at night
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
var _petrol_lights: Array[OmniLight3D] = []   # One under each filling-station canopy

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
	_street_life = StreetLife.new(_streetscape)
	if corridor_mode:
		_streetscape.clean_rects = preload("res://scripts/CityDistrictBuilder.gd").PAVED
		_frontage_setback = 7.0
		_frontage_service = StreetLife.DRAIN_OFFSET + StreetLife.DRAIN_WIDTH + 0.35

	for stop in TransitLayout.stations(corridor_mode):
		var reserved: Rect2 = TransitLayout.plot(stop)
		_add_exclusion_zone(reserved.position.x, reserved.position.y, reserved.end.x, reserved.end.y)
	for spec in SignLayout.billboards(corridor_mode):
		var plot: Rect2 = SignLayout.plot(spec)
		_add_exclusion_zone(plot.position.x, plot.position.y, plot.end.x, plot.end.y)
	if corridor_mode:
		preload("res://scripts/CityDistrictBuilder.gd").reserve_streets(self)
		_build_metric_corridor()
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

	_station_traders()

	# Open land between the districts and the surrounding street grid gets homes,
	# smallholdings and greenery before the grid itself is laid.
	if not corridor_mode:
		_infill_lots()
		_streetscape.backdrop(false)
	if corridor_mode:
		var city := preload("res://scripts/CityDistrictBuilder.gd").new()
		city.build(self)
		set_meta("city_parcels",city.parcels)
		set_meta("city_mix",city.counts)
		set_meta("city_footways",city.footway_surfaces)
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
	_mat_fuel_fascia = StandardMaterial3D.new()
	_mat_fuel_fascia.albedo_color = Color("1f5a55")
	_mat_fuel_fascia.metallic = 0.25
	_mat_fuel_fascia.roughness = 0.42
	_mat_fuel_fascia.emission_enabled = true
	_mat_fuel_fascia.emission = Color("2f8f84")
	_mat_fuel_fascia.emission_energy_multiplier = 0.0
	_mat_fuel_stripe = StandardMaterial3D.new()
	_mat_fuel_stripe.albedo_color = Color("e9a93a")
	_mat_fuel_stripe.metallic = 0.1
	_mat_fuel_stripe.roughness = 0.5
	_mat_fuel_stripe.emission_enabled = true
	_mat_fuel_stripe.emission = Color("ffb84a")
	_mat_fuel_stripe.emission_energy_multiplier = 0.0
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
	if _mat_fuel_fascia:
		_mat_fuel_fascia.emission_energy_multiplier = 0.55 if night else 0.0
	if _mat_fuel_stripe:
		_mat_fuel_stripe.emission_energy_multiplier = 1.6 if night else 0.0
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
	for light in _petrol_lights:
		if light:
			light.visible = night


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
		var face: float = side_sign * (road_width * 0.5 + SIDEWALK_WIDTH + _frontage_setback)
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
		if corridor_mode:
			# Metre-scale premises: an anchor store has a usable trading floor,
			# while smaller tenancies form a continuous, varied high street.
			var metric_sizes := {"supermarket":Vector2(20,12),"mall":Vector2(27,15),
				"mechanic":Vector2(18,15),"police":Vector2(18,12),
				"shop":Vector2(7.5+(index%3)*1.5,8),"kiosk":Vector2(3.2,3)}
			size = metric_sizes[kind]
		if cursor + size.x > end:
			break
		var center := _compute_position(axis, direction, cursor + size.x * 0.5, face, side, size.y)
		var facing := Vector3(0, 0, -side) if axis == 0 else Vector3(-side, 0, 0)
		var plot := _building_plot(center, facing, size.x, size.y)
		if not _plot_available(plot):
			cursor += 1.0
			continue
		if corridor_mode and kind == "shop" and index%3 != 0:
			_streetscape.building(center,facing,size.x,size.y,2+index%2,true)
		else:
			_streetscape.commercial(center, facing, size.x, size.y, kind)
		# Each entrance has its own slab over the drain, from the footway to the
		# trading apron; the apron itself is swept, compacted laterite.
		var access_width: float = size.x * 0.75 if kind == "mechanic" else 1.6
		var kerb: float = face - side * _frontage_setback
		var across := _compute_position(axis, direction, cursor + size.x * 0.5, kerb, side, _frontage_service)
		_streetscape._box(Transform3D(Basis.IDENTITY, across), Vector3(0, 0.16, 0),
			_orient_size(axis, access_width, 0.08, _frontage_service), SurfaceMaterials.surface(2, Color("aaa69a")))
		if not corridor_mode:
			var apron := _compute_position(axis, direction, cursor + size.x * 0.5, kerb, side, _frontage_setback)
			_streetscape._box(Transform3D(Basis.IDENTITY, apron), Vector3(0, 0.02, 0),
				_orient_size(axis, size.x + 1.3, 0.02, _frontage_setback), SurfaceMaterials.surface(9, Color("9c6c4e")))
		var kept: bool = corridor_mode and preload("res://scripts/CityDistrictBuilder.gd").paved_at(center.x, center.z)
		_street_life.frontage(center + facing * (size.y * 0.5), facing, size.x, _frontage_setback, kind, _frontage_service, kept)
		_occupied_plots.append(plot)
		frontage_uses.append({"kind": kind, "center": center, "plot": plot})
		cursor += size.x + 1.25
		index += 1


func _open_drain(axis: int, direction: float, start: float, end: float, kerb: float) -> void:
	## Drain behind the footway from `start` to `end` along a road, broken
	## wherever a station, billboard plot or side-street mouth needs the ground.
	## Open in most of town; under cover slabs through the paved districts.
	var town = preload("res://scripts/CityDistrictBuilder.gd")
	var side: float = signf(kerb)
	var across: float = kerb + side * (StreetLife.DRAIN_OFFSET + StreetLife.DRAIN_WIDTH * 0.5)
	var run_start: float = start
	var open: bool = false
	var run_covered: bool = false
	var along: float = start
	while along <= end + 0.01:
		var at := _compute_position(axis, direction, along, across, side, 0.0)
		var clear: bool = not _in_exclusion_zone(at.x, at.z) and along < end
		var covered: bool = town.paved_at(at.x, at.z)
		if open and (not clear or covered != run_covered):
			open = false
			_street_life.drain(_compute_position(axis, direction, run_start, across, side, 0.0),
				_compute_position(axis, direction, along - 2.0, across, side, 0.0), [], run_covered)
		if clear and not open:
			run_start = along
			run_covered = covered
			open = true
		along += 2.0


func _station_traders() -> void:
	## A trotro stop draws its own market: traders, produce heaps and a container
	## kiosk in a row behind the bays. Scenery only; SUMO still owns the stop,
	## the queue and boarding, and nothing here stands inside the station plot.
	for stop in TransitLayout.stations(corridor_mode):
		var plot: Rect2 = TransitLayout.plot(stop)
		var side: float = float(stop.side)
		var back: float = (plot.end.x if side > 0 else plot.position.x) + side * 2.4
		var yaw: float = atan2(-side, 0.0)
		for i in range(7):
			var at := Vector3(back, 0, plot.position.y + 4.0 + i * 7.0)
			var spot := Rect2(at.x - 1.9, at.z - 1.9, 3.8, 3.8)
			if not _plot_available(spot):
				continue
			_occupied_plots.append(spot)
			if i % 4 == 3:
				_streetscape.commercial(at, Vector3(-side, 0, 0), 3.2, 3.0, "kiosk")
			elif i % 4 == 1:
				_street_life.ground_heap(at, yaw)
			else:
				_street_life.vendor(at, yaw)


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
	# Filling stations front their cross streets, forecourts meeting the 0.7 m footway.
	# Each is set so the cross street's lamp lands on the shop's kerb strip, not a driveway.
	_place_petrol_station(Vector3(17.4, 0, -6.8), Vector3.BACK, 1.0, 0.4, 0.7, true)
	_place_petrol_station(Vector3(-17.4, 0, 66.8), Vector3.FORWARD, 1.0, 0.4, 0.7, true)
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
	## Business quarter: three towers with real floor plates around an earth
	## parking yard, the nearest thing the corridor has to Airport City.
	_place_office_tower(Vector3(cx - 19, 0, cz - 2), 12, 15.0, 14.0)
	_place_office_tower(Vector3(cx + 1, 0, cz + 1), 10, 14.0, 13.0)
	_place_midrise_office(Vector3(cx + 20, 0, cz - 4), 8, 12.0, 12.0)
	_place_parking_lot(Vector3(cx + 1, 0, cz - 15.5), 30.0, 9.0, 9)
	_place_stadium_light(Vector3(cx + 11, 0, cz + 11))
	_add_exclusion_zone(cx - 28, cz - 21, cx + 28, cz + 14)


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
	_place_football_pitch(Vector3(cx - 8, 0, cz), 28.0, 18.0, "ADINKRA PARK", 4)
	_place_school_building(Vector3(cx + 26, 0, cz + 6), 3, 15.0, 9.0)
	_place_church(Vector3(cx + 24, 0, cz - 17))

	# Car park west of the pitch (serves the school + stadium), clear of its fence.
	_place_parking_lot(Vector3(cx - 29, 0, cz), 8.0, 18.0, 6)

	# Trees dotted around the grounds (south edge and the gap between the pitch
	# and the school), clear of the fence, the stand and the buildings.
	for t in [Vector3(cx - 14, 0, cz - 17), Vector3(cx - 4, 0, cz - 17),
			Vector3(cx + 5, 0, cz - 17), Vector3(cx + 12, 0, cz + 15),
			Vector3(cx + 12, 0, cz)]:
		_place_tree(t)

	_place_residential_lamp(Vector3(cx + 13, 0, cz))


func _corridor_hospital(cx: float, cz: float) -> void:
	## A planned hospital campus on the −X flank: one H-block hospital with a
	## taller ward tower set back behind it, a patient car park, a roadside
	## filling station on the J0 cross street, and trees.
	## The keep-clear zone in _build_corridor keeps generic frontage out.
	_place_clinic(Vector3(cx + 4, 0, cz + 2))                        # main hospital (H-block)
	_place_midrise_office(Vector3(cx - 6, 0, cz + 2), 5, 8.0, 8.0)   # ward tower, set back
	_place_parking_lot(Vector3(cx + 14, 0, cz + 4), 9.0, 10.0, 12)   # patient car park
	_place_petrol_station(Vector3(cx + 21, 0, cz - 8.2), Vector3.FORWARD, 1.0, 0.4, 0.7, true)  # roadside filling station

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
	## Market + transport: dense stalls, the lorry park, a small plaza.
	_place_dense_market_stalls(Vector3(cx - 6, 0, cz + 8), 4, 5)
	_place_dense_market_stalls(Vector3(cx + 12, 0, cz - 8), 3, 5)
	_lorry_park(Vector3(cx - 11, 0, cz - 11))
	_place_shopping_mall(Vector3(cx + 12, 0, cz + 12), 14.0, 5.0, 8.0)
	_place_stadium_light(Vector3(cx, 0, cz))


func _junction_corner_life() -> void:
	## Each junction corner is a trading spot: an umbrella seller, hawkers who
	## work the queues from the kerb, and riders or direction boards behind them.
	## Everything stands on the corner apron, clear of the footway, the crossing
	## landings and the signal hardware.
	for j in range(3):
		var widths := preload("res://scripts/CorridorGeometry.gd").widths(j)
		for sx in [-1.0, 1.0]:
			for sz in [-1.0, 1.0]:
				var cross: float = widths.y if sx < 0 else widths.z
				var corner := Vector3(sx * 13.2, 0, j * 300.0 + sz * (cross * 0.5 + 6.8))
				if _in_exclusion_zone(corner.x, corner.z):
					continue
				var yaw: float = atan2(-sx, -sz)
				_street_life.vendor(corner, yaw)
				_street_life.person(corner + Vector3(-sx * 2.6, 0, sz * 1.4), yaw + 0.5, false, 1)
				_street_life.person(corner + Vector3(sx * 1.6, 0, -sz * 2.8), yaw - 0.6, false, 1)
				if posmod(j + int(sx) + int(sz), 2) == 0:
					for i in range(2):
						_street_life.okada(corner + Vector3(sx * (3.2 + i), 0, sz * 3.4), yaw + PI * 0.5, i == 0)
				else:
					_street_life.sign_cluster(corner + Vector3(sx * 3.6, 0, sz * 3.6), yaw, 3)


func _corridor_footbridge(z: float) -> void:
	## Pedestrian footbridge across the main road. The piers and stairs stand on
	## the aprons behind the drain; the ground at each foot is kept open.
	var span: float = 24.6
	for side in [-1.0, 1.0]:
		_add_exclusion_zone(minf(side * 9.6, side * 17.0), z - 2.4, maxf(side * 9.6, side * 17.0), z + 14.2)
		_street_life.vendor(Vector3(side * 14.6, 0, z + 5.0), -side * PI * 0.5)
		_street_life.person(Vector3(side * 14.2, 0, z + 9.0), side * 0.6, false, 1)
	_streetscape.footbridge(Vector3(0, 0, z), span, 1.0, "VALIBORN TECH\nBuild Beyond.")
	for i in range(3):
		_street_life.person(Vector3(-6.0 + i * 5.0, 5.7, z + 0.5 - i * 0.4), PI * 0.5 if i != 1 else -PI * 0.5)


func _lorry_park(center: Vector3) -> void:
	## Trotro and taxi yard beside the market: minibuses loading in ranks, the
	## bookman's shed, traders and waiting passengers. Parked scenery only; the
	## simulated trotro stops are the SUMO stations on the main road.
	var w: float = 32.0
	var d: float = 24.0
	_add_exclusion_zone(center.x - w * 0.5 - 1.0, center.z - d * 0.5 - 1.0, center.x + w * 0.5 + 1.0, center.z + d * 0.5 + 1.0)
	var frame := Transform3D(Basis.IDENTITY, center)
	_streetscape._box(frame, Vector3(0, 0.02, 0), Vector3(w, 0.04, d), SurfaceMaterials.surface(9, Color("8a5c44")))
	var bus_size: Vector3 = preload("res://scripts/CorridorGeometry.gd").vehicle_size("trotro")
	for i in range(8):
		var bus: Node3D = _streetscape.FleetActor.new()
		bus.configure("trotro", 11 + i * 5)
		# Place first: assigning a transform would discard the metre-scale sizing.
		bus.transform = frame * Transform3D(Basis(Vector3.UP, (PI if i < 4 else 0.0) + sin(float(i) * 1.7) * 0.07),
			Vector3(-w * 0.5 + 5.0 + (i % 4) * 4.4, 0.05, -d * 0.5 + 5.5 + (i / 4) * 9.5))
		bus.set_metric_dimensions(bus_size)
		bus.name = "ParkedTrotro"
		_streetscape.add_child(bus)
		if i % 2 == 0:
			_street_life.person(frame * Vector3(-w * 0.5 + 7.2 + (i % 4) * 4.4, 0, -d * 0.5 + 6.0 + (i / 4) * 9.5), PI * 0.5, false, 1 if i % 4 == 0 else 0)
	for i in range(4):
		var taxi: Node3D = _streetscape.FleetActor.new()
		taxi.configure("car", 2 + i * 3)
		taxi.transform = frame * Transform3D(Basis(Vector3.UP, PI * 0.5 + sin(float(i) * 2.1) * 0.1), Vector3(w * 0.5 - 4.0, 0.05, -d * 0.5 + 4.0 + i * 3.2))
		taxi.set_metric_dimensions(Vector3(1.8, 1.5, 4.5))
		taxi.name = "ParkedTaxi"
		_streetscape.add_child(taxi)
	# Bookman's shed: zinc on timber posts, benches under it, the park's board above.
	var shed := frame * Transform3D(Basis.IDENTITY, Vector3(w * 0.5 - 7.0, 0, d * 0.5 - 3.6))
	_streetscape._hip_roof(shed, 11.0, 5.0, 3.0, 1.0, true)
	for x in [-5.0, 0.0, 5.0]:
		for z in [-2.1, 2.1]:
			_streetscape._beam(shed, Vector3(x, 0, z), Vector3(x, 3.0, z), 0.14, SurfaceMaterials.surface(6, Color("6a5638")))
	for x in [-3.0, 2.0]:
		_streetscape._box(shed, Vector3(x, 0.45, 0.8), Vector3(3.6, 0.08, 0.4), SurfaceMaterials.surface(6, Color("7c6746")))
		_street_life.person(shed * Vector3(x - 0.8, 0, 0.75), PI, true, 0, false)
		_street_life.person(shed * Vector3(x + 0.6, 0, 0.75), PI, true, 0, false)
	_streetscape._sign(shed, "ACHIMOTA LORRY PARK\nKumasi  •  Nsawam  •  Circle  •  Madina", Vector3(0, 4.6, -2.3), 9.0, 1.2, Color("f2c318"))
	for x in [-4.0, 4.0]:
		_streetscape._beam(shed, Vector3(x, 3.0, -2.3), Vector3(x, 4.2, -2.3), 0.1, SurfaceMaterials.solid(Color("4a4f50"), 0.5, 0.6))
	for i in range(5):
		_street_life.vendor(frame * Vector3(-w * 0.5 + 3.5 + i * 5.2, 0, d * 0.5 - 1.6), 0.0)
	_street_life.handcart(frame * Vector3(-w * 0.5 + 3.0, 0, 1.0), 0.3)
	_street_life.ground_heap(frame * Vector3(2.0, 0, -d * 0.5 + 1.6), PI)


func _place_airport(_cx: float, _cz: float) -> void:
	var layout = preload("res://scripts/AirportLayout.gd")
	var plot: Rect2 = layout.SITE
	_add_exclusion_zone(plot.position.x, plot.position.y, plot.end.x, plot.end.y)
	var access: Rect2 = layout.ACCESS
	_add_exclusion_zone(access.position.x, access.position.y, access.end.x, access.end.y)
	var airport = preload("res://scripts/AirportBuilder.gd").new()
	airport.name = "Airport"
	airport.scale = Vector3.ONE*layout.SCALE
	add_child(airport)
	_place_residential_street(Vector3(247.5,0,19.1),31.8,true,10.5,"AirportAccess")


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

	# One filling station in the SW block, facing Achimota Forest Rd. Its access lane
	# leaves the road between the trotro station and the corner shops, crossing the
	# footway and bridging the open drain; the station's other driveway stays closed.
	# The lane runs just south of the footway's street lamp at z -14.5.
	_place_petrol_station(Vector3(17.2, 0, -20.6), Vector3.LEFT, -1.0, 0.0, 0.0, false)
	_streetscape.access_lane(Vector3(6.4, 0, -15.8), Vector3(13.0, 0, -15.8), 2.1)
	_add_exclusion_zone(6.4, -17.0, 13.0, -14.6)


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
	_place_football_pitch(Vector3(xs * 48, 0, zs * 38), 22.0, 13.0, "UNITY PARK")

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
	var offset := Vector3(xs*4.0,0,zs*4.0)
	## SE quadrant — compound houses in a loose 3x3 grid.
	var grid_positions: Array = [
		Vector3(xs * 24, 0, zs * 26) + offset,
		Vector3(xs * 46, 0, zs * 26) + offset,
		Vector3(xs * 68, 0, zs * 26) + offset,
		Vector3(xs * 24, 0, zs * 50) + offset,
		Vector3(xs * 46, 0, zs * 50) + offset,
		Vector3(xs * 68, 0, zs * 50) + offset,
		# Row 3 aligned with the other rows so compounds don't clip the N-S
		# streets at x=35 and x=57 (14-wide compounds extend ±7 from center).
		Vector3(xs * 24, 0, zs * 74) + offset,
		Vector3(xs * 46, 0, zs * 74) + offset,
		Vector3(xs * 68, 0, zs * 74) + offset,
	]
	for pos in grid_positions:
		var stories: int = 1 if _rng.randf() < 0.4 else 2
		if pos.is_equal_approx(Vector3(xs * 46, 0, zs * 74) + offset):
			_place_apartment(pos, 11, 10.0, 9.0)
		elif pos.is_equal_approx(Vector3(xs * 68, 0, zs * 50) + offset):
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
			Vector3(xs * street_x, 0, zs * street_center) + offset,
			street_len, true
		)
	for street_z in [38.0, 62.0]:
		_place_residential_street(
			Vector3(xs * street_center, 0, zs * street_z) + offset,
			street_len, false
		)

	# Prevent trees from spawning on the new asphalt.
	var z_lo: float = min(zs * 9.0, zs * 89.0)
	var z_hi: float = max(zs * 9.0, zs * 89.0)
	for street_x in [35.0, 57.0]:
		_add_exclusion_zone(xs * (street_x+4.0) - 1.6, z_lo, xs * (street_x+4.0) + 1.6, z_hi)
	var x_lo: float = min(xs * 9.0, xs * 89.0)
	var x_hi: float = max(xs * 9.0, xs * 89.0)
	for street_z in [38.0, 62.0]:
		_add_exclusion_zone(x_lo, zs * (street_z+4.0) - 1.6, x_hi, zs * (street_z+4.0) + 1.6)

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
		_place_residential_lamp(Vector3(xs * lp.x, 0, zs * lp.y) + offset)

	# Three small residential parking lots tucked against the quadrant edges.
	_place_parking_lot(Vector3(xs * 15, 0, zs * 42) + offset, 5.0, 3.0, 3)
	_place_parking_lot(Vector3(xs * 82, 0, zs * 42) + offset, 5.0, 3.0, 3)
	_place_parking_lot(Vector3(xs * 40, 0, zs * 88) + offset, 6.0, 3.0, 4)


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
	if corridor_mode:
		# Metre-scale cars on a compacted yard; the kit's marked lot is drawn for
		# the single junction's smaller district layouts.
		_streetscape.yard_parking(center, w, d, num_cars)
		return
	_streetscape.parking_lot(center, w, d, num_cars)


func _place_school_building(center: Vector3, stories: int, w: float, d: float) -> void:
	_streetscape.building(center, Vector3.BACK, w, d, stories, false, true)


func _place_football_pitch(center: Vector3, w: float, d: float, ground_name: String, rows: int = 5) -> void:
	## A community football ground from the streetscape kit (see
	## AccraStreetscape.football_ground): w = length (X), d = width (Z). The stand
	## takes the touchline away from the junction; each floodlight mast gets a
	## night light, and the fence line plus the stand are kept clear.
	var stand_side: float = 1.0 if center.z >= 0.0 else -1.0
	for spot in _streetscape.football_ground(center, w, d, stand_side, rows, ground_name, _mat_stadium_cap):
		var light := OmniLight3D.new()
		light.name = "FloodLight"
		light.position = spot
		light.omni_range = 32.0
		light.light_energy = 2.8
		light.light_color = Color(1.0, 0.98, 0.90)
		light.shadow_enabled = false   # Perf: four floods per ground
		light.visible = false          # Off until night
		add_child(light)
		_stadium_lights.append(light)
	var near: float = d / 2.0 + 2.6
	var far: float = d / 2.0 + 1.5 + rows * 0.55 + 0.7
	_add_exclusion_zone(center.x - w / 2.0 - 2.7, center.z - (near if stand_side > 0.0 else far),
		center.x + w / 2.0 + 2.7, center.z + (far if stand_side > 0.0 else near))


func _place_stadium_light(base: Vector3) -> void:
	## Yard / car-park floodlight from the kit (AccraStreetscape.area_light), with a
	## real light that comes on at night.
	var light := OmniLight3D.new()
	light.name = "AreaLight"
	light.position = _streetscape.area_light(base, _mat_stadium_cap)
	light.omni_range = 32.0
	light.light_energy = 2.8
	light.light_color = Color(1.0, 0.98, 0.90)
	light.shadow_enabled = false  # Perf: several area lights per district
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


func _place_petrol_station(center: Vector3, facing: Vector3 = Vector3.BACK, shop_side: float = 1.0,
		apron: float = 0.0, footway: float = 0.0, two_way: bool = true) -> void:
	## A branded filling station from the streetscape kit (see
	## AccraStreetscape.filling_station), fronting its road along `facing`. The
	## footprint, out to the kerb, is reserved so trees and frontage keep clear,
	## and a light under each canopy comes on at night.
	var frame := Transform3D(Basis(Vector3.UP, atan2(facing.x, facing.z)), center)
	var lo := Vector3(INF, 0, INF)
	var hi := Vector3(-INF, 0, -INF)
	for corner in [Vector3(-6.4, 0, -4.5), Vector3(6.4, 0, -4.5), Vector3(-6.4, 0, 4.2 + apron + footway), Vector3(6.4, 0, 4.2 + apron + footway)]:
		var p: Vector3 = frame * corner
		lo = lo.min(p)
		hi = hi.max(p)
	_add_exclusion_zone(lo.x, lo.z, hi.x, hi.z)
	for spot in _streetscape.filling_station(center, facing, shop_side, apron, footway, two_way, _mat_canopy_glow, _mat_fuel_fascia, _mat_fuel_stripe):
		var light := OmniLight3D.new()
		light.name = "CanopyLight"
		light.position = spot
		light.omni_range = 16.0
		light.light_energy = 2.6
		light.light_color = Color(1.0, 0.96, 0.86)
		light.shadow_enabled = false
		light.visible = false
		add_child(light)
		_petrol_lights.append(light)


# ═════════════════════════════════════════════════════════════════════════════
# INFILL — neighbourhoods, smallholdings and greenery on the land left open
# ═════════════════════════════════════════════════════════════════════════════

const OCC_SIZE := 200          # 1 m cells across the 200 m square the districts sit in
var _occ := PackedByteArray()  # 1 = taken
var _occ_sum := PackedInt32Array()
var _occ_origin := Vector2.ZERO
var _arterials: Array[Rect2] = []
var _road_rects: Array[Rect2] = []


func _infill_lots() -> void:
	## The districts leave broad open ground between them and the street grid
	## around the scene. Rasterise everything built so far (1 m cells), then:
	## continue the grid with whole neighbourhood blocks where a 32 m block is still
	## free, pack walled compounds (sheds in industrial areas) into the remaining
	## land with laterite paths to their road, and finish with smallholdings, groves
	## of trees and shrubs. Deterministic: the planner has its own seed.
	var started: int = Time.get_ticks_msec()
	var rng := RandomNumberGenerator.new()
	rng.seed = 90210 if corridor_mode else 70707
	var mid: float = 30.0 if corridor_mode else 0.0
	_occ_origin = Vector2(-100.0, mid - 100.0)
	_occ.resize(OCC_SIZE * OCC_SIZE)
	_occ.fill(0)
	_rasterise_existing(mid)
	var blocks: int = _infill_blocks(mid, rng)
	_build_occ_sum()
	var buildings: int = _infill_buildings(mid, rng, 13.2)
	var farms: int = _infill_farms(mid, rng)
	# A second, tighter pass puts single houses (or small sheds) in the gaps.
	_build_occ_sum()
	buildings += _infill_buildings(mid, rng, 9.4)
	var greenery: Vector2i = _infill_greenery(rng)
	print("[Infill] %d neighbourhood blocks, %d buildings, %d smallholdings, %d trees, %d shrubs (%d ms)" % [
		blocks, buildings, farms, greenery.x, greenery.y, Time.get_ticks_msec() - started])


func _rasterise_existing(mid: float) -> void:
	# Kit geometry still waiting to be batched, every visible mesh in the scene
	# (the junctions' roads, poles and street furniture too), reserved plots and
	# keep-clear zones, the arterials with a margin, the airport, and the frame
	# where the surrounding street grid begins (its lanes at +96 m; the first lane
	# on the far sides, at -96 m, is left for infill blocks to draw).
	for rect in _streetscape.pending_footprints():
		_occ_mark(rect.grow(0.3))
	_road_rects.clear()
	_rasterise_node(get_parent())
	for zone in _exclusion_zones:
		_occ_mark(Rect2(zone[0], zone[1], zone[2] - zone[0], zone[3] - zone[1]))
	for plot in _occupied_plots:
		_occ_mark(plot)
	for use: Dictionary in _streetscape.land_uses:
		_occ_mark(_building_plot(use.center, use.facing, use.width, use.depth))
	_arterials = _arterial_rects()
	for road in _arterials:
		_occ_mark(road.grow(2.5))
		_road_rects.append(road)
	if corridor_mode:
		var airport = preload("res://scripts/AirportLayout.gd")
		_occ_mark(airport.SITE.grow(3.0))
		_occ_mark(airport.ACCESS.grow(3.0))
	_occ_mark(Rect2(95.0, mid - 100.0, 5.0, 200.0))
	_occ_mark(Rect2(-100.0, mid + 95.0, 200.0, 5.0))
	_occ_mark(Rect2(-100.0, mid - 100.0, 2.0, 200.0))
	_occ_mark(Rect2(-100.0, mid - 100.0, 200.0, 2.0))
	_road_rects.append(Rect2(94.5, mid - 100.0, 3.0, 200.0))
	_road_rects.append(Rect2(-100.0, mid + 94.5, 200.0, 3.0))


func _rasterise_node(node: Node) -> void:
	for child in node.get_children():
		if child is CanvasItem or child is CanvasLayer or child is GPUParticles3D or child is CPUParticles3D:
			continue
		if child is Node3D and not (child as Node3D).visible:
			continue
		if child is GeometryInstance3D and not child is Label3D:
			var box: AABB = _world_aabb(child)
			# Ground planes and sky are not obstacles; roads (long but narrow) are.
			if box.size != Vector3.ZERO and box.position.y < 15.0 and (box.size.x < 60.0 or box.size.z < 60.0):
				var rect := Rect2(box.position.x, box.position.z, box.size.x, box.size.z)
				_occ_mark(rect.grow(0.3))
				var label: String = String(child.name)
				if label.begins_with("ResidentialStreet") or label.begins_with("CommercialAccess"):
					_road_rects.append(rect)
		_rasterise_node(child)


func _world_aabb(node: GeometryInstance3D) -> AABB:
	# CSG meshes are built a frame late, so size primitives from their parameters.
	var local := AABB()
	if node is CSGBox3D:
		var size: Vector3 = (node as CSGBox3D).size
		local = AABB(-size * 0.5, size)
	elif node is CSGCylinder3D:
		var cylinder := node as CSGCylinder3D
		local = AABB(Vector3(-cylinder.radius, -cylinder.height * 0.5, -cylinder.radius),
			Vector3(cylinder.radius * 2.0, cylinder.height, cylinder.radius * 2.0))
	elif node is CSGSphere3D:
		var r: float = (node as CSGSphere3D).radius
		local = AABB(-Vector3.ONE * r, Vector3.ONE * r * 2.0)
	else:
		local = node.get_aabb()
	if local.size == Vector3.ZERO:
		return AABB()
	return node.global_transform * local


func _arterial_rects() -> Array[Rect2]:
	## The simulated roads as tools/validate_zoning.gd sees them.
	var roads: Array[Rect2] = []
	if not corridor_mode:
		roads.append(Rect2(-6.4,-1500.0,12.8,3000.0))
		roads.append(Rect2(-1500.0,-6.4,3000.0,12.8))
		return roads
	roads.append(Rect2(-3.0, -58.0, 6.0, 176.0))
	for i in range(3):
		var east_width: float = [5.0, 5.0, 3.0][i]
		var west_width: float = [3.0, 5.0, 3.0][i]
		roads.append(Rect2(-58.0, i * 30.0 - east_width * 0.5, 58.0, east_width))
		roads.append(Rect2(0.0, i * 30.0 - west_width * 0.5, 58.0, west_width))
	return roads


func _occ_cells(rect: Rect2) -> Rect2i:
	var x0: int = clampi(floori(rect.position.x - _occ_origin.x), 0, OCC_SIZE)
	var z0: int = clampi(floori(rect.position.y - _occ_origin.y), 0, OCC_SIZE)
	var x1: int = clampi(ceili(rect.end.x - _occ_origin.x), 0, OCC_SIZE)
	var z1: int = clampi(ceili(rect.end.y - _occ_origin.y), 0, OCC_SIZE)
	return Rect2i(x0, z0, maxi(0, x1 - x0), maxi(0, z1 - z0))


func _occ_mark(rect: Rect2) -> void:
	var cells := _occ_cells(rect)
	for z in range(cells.position.y, cells.end.y):
		var row: int = z * OCC_SIZE
		for x in range(cells.position.x, cells.end.x):
			_occ[row + x] = 1


func _occ_inside(rect: Rect2) -> bool:
	return rect.position.x >= _occ_origin.x and rect.position.y >= _occ_origin.y \
		and rect.end.x <= _occ_origin.x + OCC_SIZE and rect.end.y <= _occ_origin.y + OCC_SIZE


func _occ_clear(rect: Rect2) -> bool:
	## Exact test against the live raster; anything off the raster counts as taken.
	if not _occ_inside(rect):
		return false
	var cells := _occ_cells(rect)
	for z in range(cells.position.y, cells.end.y):
		var row: int = z * OCC_SIZE
		for x in range(cells.position.x, cells.end.x):
			if _occ[row + x] != 0:
				return false
	return true


func _build_occ_sum() -> void:
	var n: int = OCC_SIZE + 1
	_occ_sum.resize(n * n)
	_occ_sum.fill(0)
	for z in range(OCC_SIZE):
		var running: int = 0
		for x in range(OCC_SIZE):
			running += _occ[z * OCC_SIZE + x]
			_occ_sum[(z + 1) * n + x + 1] = _occ_sum[z * n + x + 1] + running


func _occ_sum_clear(rect: Rect2) -> bool:
	## Constant-time test against the raster as of the last _build_occ_sum.
	if not _occ_inside(rect):
		return false
	var c := _occ_cells(rect)
	var n: int = OCC_SIZE + 1
	return _occ_sum[c.end.y * n + c.end.x] - _occ_sum[c.position.y * n + c.end.x] \
		- _occ_sum[c.end.y * n + c.position.x] + _occ_sum[c.position.y * n + c.position.x] == 0


func _rect_gap(a: Rect2, b: Rect2) -> float:
	return Vector2(maxf(0.0, maxf(a.position.x - b.end.x, b.position.x - a.end.x)),
		maxf(0.0, maxf(a.position.y - b.end.y, b.position.y - a.end.y))).length()


func _clear_of_arterials(rect: Rect2, gap: float) -> bool:
	for road in _arterials:
		if _rect_gap(rect, road) < gap:
			return false
	return true


func _backdrop_block(center: Vector2, mid: float) -> bool:
	# Mirrors AccraStreetscape.backdrop's choice of blocks.
	var local := Vector2(center.x, center.y - mid)
	if maxf(absf(local.x), absf(local.y)) < 100.0 or local.length() > 270.0:
		return false
	if corridor_mode:
		var airport = preload("res://scripts/AirportLayout.gd")
		var block := Rect2(center.x - 17.5, center.y - 17.5, 35, 35)
		if block.intersects(airport.SITE) or block.intersects(airport.ACCESS):
			return false
	return true


func _infill_blocks(mid: float, rng: RandomNumberGenerator) -> int:
	# Whole free 32 m blocks on the surrounding grid's lattice get its lanes (west
	# and south edges, plus east/north where no neighbouring block draws one) and
	# four compounds, so the street grid carries on up to the districts.
	var full: Array[Vector2] = []
	for row in range(-3, 3):
		for col in range(-3, 3):
			var c := Vector2((col + 0.5) * 32.0, mid + (row + 0.5) * 32.0)
			if _occ_clear(Rect2(c.x - 17.5, c.y - 17.5, 32.0, 32.0)) and _clear_of_arterials(Rect2(c.x - 14.5, c.y - 14.5, 29.0, 29.0), 13.0):
				full.append(c)
	for c in full:
		var lanes: Array[Rect2] = [Rect2(c.x - 17.5, c.y - 16.0, 3.0, 32.0), Rect2(c.x - 16.0, c.y - 17.5, 32.0, 3.0)]
		var east := Vector2(c.x + 32.0, c.y)
		if east not in full and not _backdrop_block(east, mid) and _occ_clear(Rect2(c.x + 14.5, c.y - 16.0, 3.0, 32.0)):
			lanes.append(Rect2(c.x + 14.5, c.y - 16.0, 3.0, 32.0))
		var north := Vector2(c.x, c.y + 32.0)
		if north not in full and not _backdrop_block(north, mid) and _occ_clear(Rect2(c.x - 16.0, c.y + 14.5, 32.0, 3.0)):
			lanes.append(Rect2(c.x - 16.0, c.y + 14.5, 32.0, 3.0))
		for lane in lanes:
			_streetscape.lane(Vector3(lane.get_center().x, 0, lane.get_center().y), lane.size)
			_road_rects.append(lane)
			_occ_mark(lane)
		_occ_mark(Rect2(c.x - 17.5, c.y - 17.5, 32.0, 32.0))
	for c in full:
		for offset: Vector2 in [Vector2(-7, -7), Vector2(7, -7), Vector2(-7, 7), Vector2(7, 7)]:
			var at: Vector2 = c + offset + Vector2(rng.randf_range(-0.5, 0.5), rng.randf_range(-0.5, 0.5))
			_place_infill_home(at, rng.randf_range(10.6, 11.4), rng, false)
	return full.size()


func _infill_buildings(mid: float, rng: RandomNumberGenerator, room: float) -> int:
	# Pack the remaining open land: candidate `room`-metre plots on a 2 m lattice,
	# tested against the summed raster (plus what this pass has added). Homes stay
	# 12.5 m clear of the arterials; industrial areas get sheds with yards instead.
	# Compound-sized rooms get walled compounds, smaller ones a single house.
	var added: Array[Rect2] = []
	var count: int = 0
	var z: float = mid - 98.0
	while z + room < mid + 95.0:
		var x: float = -98.0
		while x + room < 95.0:
			var plot := Rect2(x, z, room, room)
			var placed: bool = false
			if _occ_sum_clear(plot) and not _hits_any(plot, added) and _occ_clear(plot):
				var at: Vector2 = plot.get_center()
				if _industrial_at(at):
					placed = _place_infill_shed(at, room, rng)
				elif room >= 12.0:
					placed = _place_infill_home(at, rng.randf_range(10.4, 11.4), rng, true)
				else:
					placed = _place_infill_house(at, room, rng)
				if placed:
					added.append(plot)
					count += 1
			if placed:
				x += room
			else:
				x += 2.0
		z += 2.0
	return count


func _hits_any(rect: Rect2, rects: Array[Rect2]) -> bool:
	for other in rects:
		if rect.intersects(other):
			return true
	return false


func _industrial_at(p: Vector2) -> bool:
	if corridor_mode:
		return p.x < -8.0 and p.y > 66.0
	return p.x > 8.0 and p.y < -8.0


func _place_infill_home(at: Vector2, size: float, rng: RandomNumberGenerator, with_path: bool) -> bool:
	## A walled compound (now and then a small walk-up block) with its gate to the
	## nearest road, and a laterite path out to it when it sits back.
	var plot := Rect2(at - Vector2(size, size) * 0.5, Vector2(size, size))
	if not _clear_of_arterials(plot, 12.5):
		return false
	var access: Array = _face_road(plot)
	var facing: Vector3 = access[0]
	var center := Vector3(at.x, 0, at.y)
	if rng.randf() < 0.12:
		_streetscape.apartment(center, facing, rng.randi_range(3, 4), 8.0, 6.4)
	else:
		_streetscape.compound(center, size, 1 if rng.randf() < 0.6 else 2, facing)
	_occ_mark(plot.grow(0.6))
	if with_path:
		_gate_path(at, size, facing, access[1])
	return true


func _place_infill_shed(at: Vector2, room: float, rng: RandomNumberGenerator) -> bool:
	## A workshop shed on a concrete yard, roller door to the north.
	var plot := Rect2(at - Vector2(room, room) * 0.5, Vector2(room, room))
	if not _clear_of_arterials(plot, 4.0):
		return false
	var scale: float = room / 13.2
	_streetscape.warehouse(Vector3(at.x, 0, at.y - 1.0 * scale), rng.randf_range(8.5, 11.0) * scale,
		rng.randf_range(3.8, 5.0) * maxf(scale, 0.8), rng.randf_range(5.5, 7.0) * scale)
	_occ_mark(plot)
	return true


func _place_infill_house(at: Vector2, room: float, rng: RandomNumberGenerator) -> bool:
	## A detached house on its paved apron, front door to the nearest road.
	var plot := Rect2(at - Vector2(room, room) * 0.5, Vector2(room, room))
	if not _clear_of_arterials(plot, 12.5):
		return false
	var access: Array = _face_road(plot)
	var facing: Vector3 = access[0]
	var w: float = rng.randf_range(6.0, 7.2)
	var d: float = rng.randf_range(5.0, 6.0)
	_streetscape.building(Vector3(at.x, 0, at.y), facing, w, d, 1 if rng.randf() < 0.55 else 2)
	_occ_mark(plot.grow(-0.2))
	_gate_path(at, maxf(w, d), facing, access[1] + (room - maxf(w, d)) * 0.5)
	return true


func _face_road(plot: Rect2) -> Array:
	## [direction to the nearest road beside the plot, gap to it]; with no road
	## within reach the gate faces south and the gap is 0.
	var best := Vector3(0, 0, -1)
	var best_gap: float = 40.0
	for road in _road_rects:
		var gap: float = INF
		var direction := Vector3.ZERO
		if road.position.x < plot.end.x - 2.0 and road.end.x > plot.position.x + 2.0:
			if road.position.y >= plot.end.y:
				gap = road.position.y - plot.end.y
				direction = Vector3(0, 0, 1)
			elif road.end.y <= plot.position.y:
				gap = plot.position.y - road.end.y
				direction = Vector3(0, 0, -1)
		elif road.position.y < plot.end.y - 2.0 and road.end.y > plot.position.y + 2.0:
			if road.position.x >= plot.end.x:
				gap = road.position.x - plot.end.x
				direction = Vector3(1, 0, 0)
			elif road.end.x <= plot.position.x:
				gap = plot.position.x - road.end.x
				direction = Vector3(-1, 0, 0)
		if gap < best_gap:
			best_gap = gap
			best = direction
	return [best, best_gap if best_gap < 40.0 else 0.0]


func _gate_path(at: Vector2, size: float, facing: Vector3, gap: float) -> void:
	# Laterite path from the gate straight toward the road, stopping short of
	# anything in its way.
	if gap < 0.8:
		return
	var dir := Vector2(facing.x, facing.z)
	var start: Vector2 = at + dir * (size * 0.5 + 0.6)
	var length: float = 0.0
	while length < gap - 0.6:
		var probe_center: Vector2 = start + dir * (length + 0.5)
		var half := Vector2(0.8, 0.5) if absf(dir.y) > 0.5 else Vector2(0.5, 0.8)
		if not _occ_clear(Rect2(probe_center - half, half * 2.0)):
			break
		length += 1.0
	if length < 1.0:
		return
	var end: Vector2 = start + dir * length
	_streetscape.track(Vector3(at.x + dir.x * size * 0.5, 0, at.y + dir.y * size * 0.5), Vector3(end.x, 0, end.y), 1.5)
	var lo := Vector2(minf(start.x, end.x), minf(start.y, end.y))
	var hi := Vector2(maxf(start.x, end.x), maxf(start.y, end.y))
	_occ_mark(Rect2(lo, hi - lo).grow(0.75))


func _infill_farms(mid: float, rng: RandomNumberGenerator) -> int:
	# Smallholdings of cassava and maize on open land away from the arterials.
	var count: int = 0
	for attempt in range(400):
		if count >= 7:
			break
		var along_x: bool = rng.randf() < 0.5
		var size := Vector2(rng.randf_range(8.0, 12.0), rng.randf_range(6.0, 8.5))
		if not along_x:
			size = Vector2(size.y, size.x)
		var at := Vector2(rng.randf_range(-90.0, 90.0), mid + rng.randf_range(-90.0, 90.0))
		var room := Rect2(at - size * 0.5, size).grow(1.4)
		# Peri-urban: only out towards the edge of the scene.
		if maxf(absf(at.x), absf(at.y - mid)) < 55.0:
			continue
		if _occ_clear(room) and _clear_of_arterials(room, 10.0):
			_streetscape.farm_plot(Vector3(at.x, 0, at.y), size.x, size.y, along_x)
			_occ_mark(room)
			count += 1
	return count


func _infill_greenery(rng: RandomNumberGenerator) -> Vector2i:
	# Trees, then shrubs, on whatever is still open. A coarse noise field groups
	# them into groves with meadow between, rather than an even sprinkle.
	var noise := FastNoiseLite.new()
	noise.seed = rng.seed
	noise.frequency = 0.03
	var trees: int = 0
	var shrubs: int = 0
	for gz in range(0, OCC_SIZE, 6):
		for gx in range(0, OCC_SIZE, 6):
			var p: Vector2 = _occ_origin + Vector2(gx + rng.randf_range(1.0, 5.0), gz + rng.randf_range(1.0, 5.0))
			var grove: float = noise.get_noise_2d(p.x, p.y) * 0.5 + 0.5
			if rng.randf() > 0.2 + grove * 0.72:
				continue
			var spot := Rect2(p - Vector2(1.7, 1.7), Vector2(3.4, 3.4))
			if not _occ_clear(spot):
				continue
			_streetscape.tree(Vector3(p.x, 0, p.y), rng.randf() < 0.22, 7, 10)
			_occ_mark(spot.grow(0.4))
			trees += 1
	for gz in range(0, OCC_SIZE, 3):
		for gx in range(0, OCC_SIZE, 3):
			var p: Vector2 = _occ_origin + Vector2(gx + rng.randf_range(0.5, 2.5), gz + rng.randf_range(0.5, 2.5))
			var grove: float = noise.get_noise_2d(p.x + 40.0, p.y) * 0.5 + 0.5
			if rng.randf() > 0.08 + grove * 0.45:
				continue
			var spot := Rect2(p - Vector2(0.75, 0.75), Vector2(1.5, 1.5))
			if not _occ_clear(spot):
				continue
			_streetscape.shrub(Vector3(p.x, 0, p.y), rng.randf_range(0.7, 1.25))
			_occ_mark(spot)
			shrubs += 1
	return Vector2i(trees, shrubs)


func _build_metric_corridor() -> void:
	# Use existing detailed premises at metre-scale road setbacks. Reserve the
	# airport/stations before placing frontage; keep corners open for sightlines.
	_place_airport(38, 96)
	_corridor_residential(58, -95, 3, 3)
	_corridor_offices(-65, 145)
	_corridor_institutional(65, 445)
	_corridor_hospital(-65, 445)
	_corridor_industrial(-70, 720)
	_corridor_market(-55, -95)
	# Roadside landmarks claim their ground before the shop rows are laid: two
	# Sankofa filling stations, the footbridge between the school and the clinic,
	# and three telecom masts.
	_place_petrol_station(Vector3(15.3, 0, 236), Vector3.LEFT, 1.0, 3.2, 1.5, true)
	_place_petrol_station(Vector3(-15.3, 0, 672), Vector3.RIGHT, -1.0, 3.2, 1.5, true)
	_corridor_footbridge(462.0)
	for mast in [Vector3(128, 0, 346), Vector3(-100, 0, 622), Vector3(96, 0, -52)]:
		_add_exclusion_zone(mast.x - 6.4, mast.z - 6.4, mast.x + 6.4, mast.z + 6.4)
		_streetscape.telecom_mast(mast, 44.0 if mast.x > 0 else 38.0)
	for j in range(3):
		for side in [-1.0, 1.0]:
			# J0's eastern apartment stays clear of the airport access street.
			_place_apartment(Vector3(side*52, 0, j*300.0+(40 if j == 0 and side > 0 else 65)), 8+j*2, 16, 12)
			for end in [-1.0,1.0]:
				# Modest corner blocks define the junction without filling its
				# sightlines or turning it into a cluster of identical towers.
				_streetscape.building(Vector3(side*25,0,j*300.0+end*25),
					Vector3(0,0,-end),14,12,3+posmod(j+int(side),2),true)
	_reserve_district_buildings()
	for j in range(3):
		_placement_origin = Vector3(0, 0, j*300.0)
		var widths := preload("res://scripts/CorridorGeometry.gd").widths(j)
		for direction in [-1.0, 1.0]:
			var road_width: float = widths.y if direction < 0 else widths.z
			for side in [-1.0, 1.0]:
				var face: float = side*(road_width*0.5+1.5+_frontage_setback)
				_build_frontage_strip(0,direction,30,145,face,side,j*2+int(side>0))
				_open_drain(0,direction,22,150,side*(road_width*0.5+1.5))
	_placement_origin = Vector3.ZERO
	_junction_corner_life()
	for side in [-1.0, 1.0]:
		var face: float = side*(6.4+1.5+_frontage_setback)
		for stretch in [Vector2(-140,-30),Vector2(30,270),Vector2(330,570),Vector2(630,820)]:
			_build_frontage_strip(1,1,stretch.x,stretch.y,face,side,int(absf(stretch.x)/100)+int(side>0))
			_open_drain(1,1,stretch.x-8,stretch.y+8,side*(6.4+1.5))
		# Shade trees stand on the trading apron behind the drain, never in the
		# footway: neem and mango every thirty-odd metres, traders beneath them.
		var along: float = -134.0
		while along < 816.0:
			var z: float = along + sin(along * 0.37 + side) * 5.0
			var near_junction: bool = false
			for j in range(3):
				if absf(z - j * 300.0) < 36.0: near_junction = true
			if not near_junction and not _in_exclusion_zone(side * 11.8, z):
				_streetscape.tree(Vector3(side * 11.8, 0, z), false, 8, 12, 1.45)
			along += 34.0
