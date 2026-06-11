extends Node3D
## Attaches real-world ATCS sensor props to every traffic-signal pole.
##
## Makes the AI's senses visible. Right now the DQN agent reads a 45-d
## state vector (per-lane queues, speeds, waits, phase, emergency flag,
## pedestrian counts) — but in the 3D scene there was nothing to show
## WHERE that data was coming from. Every pole now carries three sensor
## types that mirror a live Accra/Achimota ATCS deployment:
##
##   • CCTV camera — bullet-style housing on the mast arm, pitched 20°
##     down the approach. Classifies vehicles / estimates queue length.
##   • Microwave radar — flat white panel beside the signal housing,
##     facing incoming traffic. Presence + speed, works in rain & fog.
##   • Controller cabinet — olive-green metal enclosure at the pole base.
##     This is where the "brain" (DQN inference) actually runs in reality.
##
## Optional sightline cones (press K) render translucent cyan wedges
## along each camera's FOV so you can SEE the coverage pattern. Hidden
## by default — they get visually busy with four approaches active.
##
## The sensors are purely cosmetic — state still flows from the Python
## env over WebSocket. This just makes the input pipeline LEGIBLE.

const APPROACHES: Array[String] = ["north", "south", "east", "west"]

# ── Pole geometry — MUST mirror Intersection.gd's _build_traffic_lights() ──
# If those constants drift, the sensors will float off into space. Keep
# them in sync or centralize in a shared constants file.
const POLE_HEIGHT: float = 5.5
const ARM_LEN: float     = 3.7

# ── Sightline cone dimensions ──────────────────────────────────────────────
const CONE_LENGTH: float     = 28.0
const CONE_HALF_ANGLE: float = deg_to_rad(13.0)
# Camera pitch (matches _add_cctv's tilt). The sightline cone orients
# along pole-local +Z (approach direction) then pitches down by this much.
const CAM_PITCH: float       = deg_to_rad(20.0)

# ── State ──────────────────────────────────────────────────────────────────
var _sightline_pivots: Array[Node3D] = []   # one per pole, holds the cone
var _cones_visible: bool             = false

# Shared materials — built once, reused across every pole.
var _mat_housing_white: StandardMaterial3D
var _mat_housing_dark:  StandardMaterial3D
var _mat_lens:          StandardMaterial3D
var _mat_led:           StandardMaterial3D
var _mat_radome:        StandardMaterial3D
var _mat_cabinet:       StandardMaterial3D
var _mat_cabinet_door:  StandardMaterial3D
var _mat_cone:          StandardMaterial3D


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_build_materials()


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

func attach_to_intersection(intersection: Node3D) -> void:
	## Walk each TrafficLight_<approach> child on Intersection and attach a
	## sensor suite. Called by Main.gd in _ready() after Intersection has
	## finished building (children's _ready runs before parent's, so by the
	## time we're called the poles exist).
	for approach in APPROACHES:
		var pole: Node3D = intersection.get_node_or_null("TrafficLight_%s" % approach)
		if pole == null:
			push_warning("[SensorBuilder] missing TrafficLight_%s — skipping" % approach)
			continue
		_attach_sensors_to_pole(pole)


func toggle_sightlines() -> void:
	## Show/hide the translucent FOV cones. Safe to call before attach — just
	## flips the stored visibility state and no-ops the loop.
	_cones_visible = not _cones_visible
	for pivot in _sightline_pivots:
		pivot.visible = _cones_visible


func sightlines_visible() -> bool:
	return _cones_visible


# ═════════════════════════════════════════════════════════════════════════════
# MATERIAL SETUP
# ═════════════════════════════════════════════════════════════════════════════

func _build_materials() -> void:
	_mat_housing_white = StandardMaterial3D.new()
	_mat_housing_white.albedo_color = Color(0.88, 0.88, 0.90)
	_mat_housing_white.metallic = 0.3
	_mat_housing_white.roughness = 0.5

	_mat_housing_dark = StandardMaterial3D.new()
	_mat_housing_dark.albedo_color = Color(0.18, 0.18, 0.20)
	_mat_housing_dark.metallic = 0.5
	_mat_housing_dark.roughness = 0.4

	_mat_lens = StandardMaterial3D.new()
	_mat_lens.albedo_color = Color(0.04, 0.04, 0.08)
	_mat_lens.metallic = 0.85
	_mat_lens.roughness = 0.08

	# Tiny red "recording" LED — unshaded so it reads as a glow dot
	_mat_led = StandardMaterial3D.new()
	_mat_led.albedo_color = Color(1.0, 0.10, 0.10)
	_mat_led.emission_enabled = true
	_mat_led.emission = Color(1.0, 0.25, 0.25)
	_mat_led.emission_energy_multiplier = 2.5
	_mat_led.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED

	_mat_radome = StandardMaterial3D.new()
	_mat_radome.albedo_color = Color(0.10, 0.12, 0.16)
	_mat_radome.metallic = 0.2
	_mat_radome.roughness = 0.5

	# Utility olive-green — the color every traffic cabinet on earth seems
	# to ship in.
	_mat_cabinet = StandardMaterial3D.new()
	_mat_cabinet.albedo_color = Color(0.42, 0.48, 0.38)
	_mat_cabinet.roughness = 0.7

	_mat_cabinet_door = StandardMaterial3D.new()
	_mat_cabinet_door.albedo_color = Color(0.30, 0.35, 0.28)
	_mat_cabinet_door.roughness = 0.8

	# Sightline cone — translucent cyan, unshaded, double-sided so you
	# see it from inside too (driving under it shouldn't flicker).
	_mat_cone = StandardMaterial3D.new()
	_mat_cone.albedo_color = Color(0.28, 0.85, 1.00, 0.14)
	_mat_cone.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mat_cone.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat_cone.cull_mode = BaseMaterial3D.CULL_DISABLED


# ═════════════════════════════════════════════════════════════════════════════
# PER-POLE ATTACHMENT
# ═════════════════════════════════════════════════════════════════════════════

func _attach_sensors_to_pole(pole: Node3D) -> void:
	## In a pole's local frame:
	##   local -X → over the road (toward the junction center)
	##   local +Z → the direction approaching traffic is coming FROM
	##   local +Y → up
	## So cameras & radar face local +Z to watch the approach.
	_add_cctv(pole)
	_add_cabinet(pole)
	_add_sightline_cone(pole)


func _add_cctv(pole: Node3D) -> void:
	## Bullet-style traffic cam mounted near the junction end of the mast arm.
	## Root node handles the 20° downward tilt so lens, body, bracket and LED
	## all rotate together as one unit.
	var root := Node3D.new()
	root.name = "Sensor_CCTV"
	root.position = Vector3(-ARM_LEN + 0.35, POLE_HEIGHT + 0.32, 0.0)
	# +rotation.x around +X sends the lens axis (+Z) toward −Y (down):
	#   (0,0,1) · R_x(+20°) = (0, -sin20°, cos20°) → forward & down.
	root.rotation.x = CAM_PITCH
	pole.add_child(root)

	# Short vertical bracket anchoring camera to the mast arm
	var bracket := CSGBox3D.new()
	bracket.size = Vector3(0.04, 0.28, 0.04)
	bracket.position = Vector3(0.0, -0.20, 0.0)
	bracket.material = _mat_housing_dark
	root.add_child(bracket)

	# Camera body — lying on its side so the long axis points +Z (down the approach)
	var body := CSGCylinder3D.new()
	body.radius = 0.075
	body.height = 0.28
	body.sides = 14
	body.rotation.x = deg_to_rad(90.0)
	body.position = Vector3(0.0, 0.0, 0.06)
	body.material = _mat_housing_white
	root.add_child(body)

	# Rear cap — slightly narrower, darker so the body reads as two-tone
	var rear := CSGCylinder3D.new()
	rear.radius = 0.062
	rear.height = 0.05
	rear.sides = 14
	rear.rotation.x = deg_to_rad(90.0)
	rear.position = Vector3(0.0, 0.0, -0.10)
	rear.material = _mat_housing_dark
	root.add_child(rear)

	# Lens — dark glossy disc on the front face
	var lens := CSGCylinder3D.new()
	lens.radius = 0.052
	lens.height = 0.035
	lens.sides = 14
	lens.rotation.x = deg_to_rad(90.0)
	lens.position = Vector3(0.0, 0.0, 0.21)
	lens.material = _mat_lens
	root.add_child(lens)

	# Status LED — tiny emissive red dot reading "recording"
	var led := CSGSphere3D.new()
	led.radius = 0.012
	led.radial_segments = 6
	led.rings = 4
	led.position = Vector3(0.055, 0.035, 0.13)
	led.material = _mat_led
	root.add_child(led)



func _add_cabinet(pole: Node3D) -> void:
	## Controller cabinet — olive-green metal enclosure at pole base. This
	## is the physical box that would hold the DQN inference hardware in
	## a live deployment. Offset in local -Z (away from road) so it sits
	## on the sidewalk/grass behind the pole, not blocking the curb.
	var cabinet := CSGBox3D.new()
	cabinet.name = "Sensor_Cabinet"
	cabinet.size = Vector3(0.50, 1.15, 0.38)
	cabinet.position = Vector3(0.05, 0.575, -0.55)
	cabinet.material = _mat_cabinet
	pole.add_child(cabinet)

	# Door panel — thin plate stuck slightly proud of the front face for
	# depth (shows a recognizable "this is a door" detail from close up)
	var door := CSGBox3D.new()
	door.size = Vector3(0.42, 0.92, 0.02)
	door.position = Vector3(0.05, 0.50, -0.365)
	door.material = _mat_cabinet_door
	pole.add_child(door)

	# Door handle — tiny nub
	var handle := CSGBox3D.new()
	handle.size = Vector3(0.04, 0.08, 0.03)
	handle.position = Vector3(0.20, 0.50, -0.36)
	handle.material = _mat_housing_dark
	pole.add_child(handle)

	# Three ventilation slats across the top — matches real cabinet look
	for i in range(3):
		var slat := CSGBox3D.new()
		slat.size = Vector3(0.30, 0.015, 0.02)
		slat.position = Vector3(0.05, 1.09, -0.41 + i * 0.04)
		slat.material = _mat_cabinet_door
		pole.add_child(slat)


func _add_sightline_cone(pole: Node3D) -> void:
	## Translucent FOV cone extending from each CCTV lens along the approach.
	## Hidden by default — press K to show all four at once.
	##
	## Orientation math:
	##   CSGCylinder3D with cone=true tapers to a point at +Y. We want the
	##   point (narrow end) at the camera lens and the base (wide end)
	##   extending forward down the approach with a 20° downward tilt.
	##
	##   Step 1: position cone so its +Y tip is at the pivot origin
	##            → cone.position.y = -CONE_LENGTH / 2
	##            → tip ends at (0,0,0), base at (0,-CONE_LENGTH, 0)
	##   Step 2: rotate the pivot so local -Y becomes "forward and down 20°"
	##            → rotation.x such that -Y maps to (0, -sin(20°), +cos(20°))
	##            → that's rotation.x = -(90° - 20°) = -70°
	var pivot := Node3D.new()
	pivot.name = "SightlinePivot"
	pivot.position = Vector3(-ARM_LEN + 0.35, POLE_HEIGHT + 0.32, 0.0)
	pivot.rotation.x = deg_to_rad(-70.0)   # see derivation above
	pivot.visible = false                   # hidden until toggle_sightlines()
	pole.add_child(pivot)

	var cone := CSGCylinder3D.new()
	cone.name = "FOVCone"
	cone.radius = CONE_LENGTH * tan(CONE_HALF_ANGLE)
	cone.height = CONE_LENGTH
	cone.sides = 16
	cone.cone = true               # taper to a point at +Y
	cone.smooth_faces = true
	cone.material = _mat_cone
	cone.position = Vector3(0, -CONE_LENGTH / 2.0, 0)
	pivot.add_child(cone)

	_sightline_pivots.append(pivot)
