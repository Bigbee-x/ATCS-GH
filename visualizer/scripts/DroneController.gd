extends Node3D
## Cinematic camera-drone flight mode for the ATCS-GH visualizer.
##
## Press H to toggle. A procedural DJI-style quadcopter (flat CSG shell, four
## arms with counter-rotating two-blade props + translucent motion-blur discs,
## landing legs, an under-slung gimbal camera, GPS puck + nav LEDs) spawns above
## the junction. The user flies it with FPS-style controls while a chase camera
## follows behind-and-above with a bit of lag for a cinematic feel.
##
## Controls
##   Mouse X         Yaw (turn left/right)
##   Mouse Y         Camera pitch (look up/down)
##   W / S           Forward / back
##   A / D           Strafe left / right
##   Space / Ctrl    Ascend / descend
##   Shift           Boost (1.7× speed)
##   H / Esc         Exit drone mode
##
## Audio
##   A procedural rotor loop (blade-pass thump + turbine whine + bass rumble
##   + low-passed white noise) is generated on startup and fades in on
##   activate / cuts on deactivate. No audio asset files needed.
##
## Architecture
##   Main.gd owns the toggle and restores the isometric camera on exit.
##   This controller owns the chase camera; it becomes `current = true`
##   while active. The drone mesh is built once in _ready() and re-used
##   across toggles.

signal mode_changed(active: bool)

# ═════════════════════════════════════════════════════════════════════════════
# STATE
# ═════════════════════════════════════════════════════════════════════════════

var active: bool = false

# ── Physics tuning ──────────────────────────────────────────────────────────
const MAX_SPEED: float       = 26.0
const BOOST_MULT: float      = 1.7
const THRUST: float          = 34.0
const DRAG: float            = 1.6           # velocity decay when no input
const VERT_THRUST: float     = 22.0
const MOUSE_YAW_SENS: float  = 0.0038
const MOUSE_PITCH_SENS: float = 0.0030
const CAM_PITCH_MIN: float   = -0.95         # ~-54° (looking up at the drone belly)
const CAM_PITCH_MAX: float   =  0.55         # ~ 31° (looking down past it)

# ── Motion state ────────────────────────────────────────────────────────────
var _velocity: Vector3 = Vector3.ZERO
var _yaw: float        = PI                  # spawn facing -Z (toward origin)
var _cam_pitch: float  = -0.18

# ── Body animation state (visual-only) ──────────────────────────────────────
var _bank: float           = 0.0             # roll, driven by strafe input
var _body_pitch: float     = 0.0             # fwd-lean, driven by fwd input
var _rotor_spin: float     = 0.0             # accumulator for rotor rotation
var _rotor_speed: float    = 0.0             # ramps up on activate, down on deactivate
var _hover_t: float        = 0.0             # time accumulator for idle bob
var _light_blink_t: float  = 0.0             # time accumulator for tail light

# ── Nodes ───────────────────────────────────────────────────────────────────
var _yaw_pivot: Node3D          # rotates on Y with heading
var _tilt_pivot: Node3D         # rolls/pitches for bank/pitch (camera does NOT inherit)
var _props: Array[Node3D] = []  # 4 prop pivots; adjacent ones counter-rotate
var _tail_light: MeshInstance3D # blinking rear status beacon
var _tail_light_mat: StandardMaterial3D
var _rotor_mat: StandardMaterial3D   # shared translucent prop-disc material

# ── Camera ──────────────────────────────────────────────────────────────────
var _camera: Camera3D           # chase cam — scene-root sibling, smooth follow
const CHASE_DIST: float    = 3.4
const CHASE_HEIGHT: float  = 1.5
const CAM_LERP: float      = 6.0

# ── Audio — procedural quad-buzz loop (prop buzz + motor whine + air) ──────
var _sound_player: AudioStreamPlayer
var _sound_stream: AudioStreamWAV
const SOUND_BASE_VOLUME_DB: float = -6.0
const SOUND_FADE_IN_SEC: float    = 0.45   # avoids a click on start
const SOUND_QUIET_DB: float       = -40.0  # ~silent starting point

# ── Spawn ───────────────────────────────────────────────────────────────────
const SPAWN_POS: Vector3 = Vector3(0.0, 18.0, 35.0)


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_build_rig()
	visible = false
	set_process(false)
	set_physics_process(false)
	set_process_input(false)


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API — called by Main.gd
# ═════════════════════════════════════════════════════════════════════════════

func activate() -> void:
	if active:
		return
	active = true
	visible = true
	global_position = SPAWN_POS
	_velocity = Vector3.ZERO
	_yaw = PI
	_cam_pitch = -0.18
	_bank = 0.0
	_body_pitch = 0.0
	_rotor_speed = 58.0
	_yaw_pivot.rotation.y = _yaw

	# Seat the chase camera behind+above so it doesn't snap-pan on first frame
	var heading: Basis = Basis(Vector3.UP, _yaw)
	_camera.global_position = SPAWN_POS + heading * Vector3(0, CHASE_HEIGHT, CHASE_DIST)
	_camera.look_at(SPAWN_POS, Vector3.UP)
	_camera.current = true

	# Start the drone-sound loop with a short fade-in so the buffer
	# doesn't click on the first sample. Tweens run independent of this
	# node's process flag, so they keep going even if we're stopped.
	if _sound_player:
		_sound_player.volume_db = SOUND_QUIET_DB
		if not _sound_player.playing:
			_sound_player.play()
		var tw := create_tween()
		tw.tween_property(_sound_player, "volume_db", SOUND_BASE_VOLUME_DB, SOUND_FADE_IN_SEC)

	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	set_process(true)
	set_physics_process(true)
	set_process_input(true)
	mode_changed.emit(true)


func deactivate() -> void:
	if not active:
		return
	active = false
	visible = false
	_rotor_speed = 0.0
	if _sound_player and _sound_player.playing:
		_sound_player.stop()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Release the chase camera so Main.gd can bring the isometric camera
	# back without fighting our `current` flag.
	if _camera:
		_camera.current = false

	set_process(false)
	set_physics_process(false)
	set_process_input(false)
	mode_changed.emit(false)


# ═════════════════════════════════════════════════════════════════════════════
# INPUT — mouse look
# ═════════════════════════════════════════════════════════════════════════════

func _input(event: InputEvent) -> void:
	if not active:
		return

	if event is InputEventMouseMotion:
		_yaw -= event.relative.x * MOUSE_YAW_SENS
		_cam_pitch -= event.relative.y * MOUSE_PITCH_SENS
		_cam_pitch = clampf(_cam_pitch, CAM_PITCH_MIN, CAM_PITCH_MAX)


# ═════════════════════════════════════════════════════════════════════════════
# PHYSICS — movement + body anim + camera
# ═════════════════════════════════════════════════════════════════════════════

func _physics_process(delta: float) -> void:
	# ── Gather keyboard input (local-space intent) ─────────────────────
	var fwd: float = 0.0      # +forward, -back
	var strafe: float = 0.0   # +right, -left
	var vert: float = 0.0     # +up, -down
	if Input.is_key_pressed(KEY_W): fwd    += 1.0
	if Input.is_key_pressed(KEY_S): fwd    -= 1.0
	if Input.is_key_pressed(KEY_A): strafe -= 1.0
	if Input.is_key_pressed(KEY_D): strafe += 1.0
	if Input.is_key_pressed(KEY_SPACE): vert += 1.0
	if Input.is_key_pressed(KEY_CTRL) or Input.is_key_pressed(KEY_C): vert -= 1.0

	var boosting: bool = Input.is_key_pressed(KEY_SHIFT)
	var speed_cap: float = MAX_SPEED * (BOOST_MULT if boosting else 1.0)
	var thrust_mag: float = THRUST * (BOOST_MULT if boosting else 1.0)

	# ── Apply yaw (heading comes straight from mouse/keyboard) ─────────
	_yaw_pivot.rotation.y = _yaw
	var heading: Basis = Basis(Vector3.UP, _yaw)

	# ── Build desired thrust in world space ────────────────────────────
	# Horizontal thrust comes from fwd/strafe rotated into heading.
	# Vertical thrust has its own magnitude so up/down feels responsive.
	# Godot forward is -Z, so "forward" input pushes along -heading.z.
	var h_thrust: Vector3 = (-heading.z * fwd + heading.x * strafe) * thrust_mag
	var v_thrust: float = vert * VERT_THRUST

	# ── Integrate velocity with drag ───────────────────────────────────
	# Drag applies to axes with no active input; axes with input accelerate.
	_velocity.x = _apply_axis(_velocity.x, h_thrust.x, delta)
	_velocity.z = _apply_axis(_velocity.z, h_thrust.z, delta)
	_velocity.y = _apply_axis(_velocity.y, v_thrust,   delta)

	# Clamp horizontal speed, keep vertical uncapped-ish (capped to speed_cap)
	var h: Vector2 = Vector2(_velocity.x, _velocity.z)
	if h.length() > speed_cap:
		h = h.normalized() * speed_cap
		_velocity.x = h.x
		_velocity.z = h.y
	_velocity.y = clampf(_velocity.y, -VERT_THRUST, VERT_THRUST)

	# ── Move ───────────────────────────────────────────────────────────
	global_position += _velocity * delta
	# Keep the drone above the ground
	if global_position.y < 2.0:
		global_position.y = 2.0
		_velocity.y = maxf(_velocity.y, 0.0)

	# ── Body lean (visual) ─────────────────────────────────────────────
	var target_bank: float  = -strafe * deg_to_rad(22.0)
	var target_pitch: float = -fwd    * deg_to_rad(14.0)
	_bank       = lerpf(_bank,       target_bank,  6.0 * delta)
	_body_pitch = lerpf(_body_pitch, target_pitch, 6.0 * delta)
	_tilt_pivot.rotation.z = _bank
	_tilt_pivot.rotation.x = _body_pitch

	# Gentle hover bob when barely moving (purely visual, applied to tilt pivot
	# as a tiny Y offset so the whole airframe bobs but the chase cam smooths
	# most of it out).
	_hover_t += delta
	var stillness: float = 1.0 - clampf(_velocity.length() / 4.0, 0.0, 1.0)
	var bob: float = sin(_hover_t * 1.8) * 0.06 * stillness
	_tilt_pivot.position.y = bob

	# ── Props ──────────────────────────────────────────────────────────
	# Four rotors spin fast; adjacent ones counter-rotate like a real quad.
	_rotor_spin += _rotor_speed * delta
	for i in range(_props.size()):
		var spin_dir: float = 1.0 if (i % 2 == 0) else -1.0
		_props[i].rotation.y = _rotor_spin * spin_dir

	# ── Blinking tail nav light ────────────────────────────────────────
	_light_blink_t += delta
	if _tail_light_mat:
		var on: bool = fmod(_light_blink_t, 1.2) < 0.12
		_tail_light_mat.emission_energy_multiplier = 4.0 if on else 0.3

	# ── Chase camera smooth-follow ─────────────────────────────────────
	_update_chase_camera(delta)


func _apply_axis(vel: float, thrust_axis: float, delta: float) -> float:
	## Integrate one axis: if input is pushing, accelerate; otherwise apply drag.
	if absf(thrust_axis) > 0.01:
		return vel + thrust_axis * delta
	# Exponential drag toward 0
	return vel * exp(-DRAG * delta)


func _update_chase_camera(delta: float) -> void:
	## Camera sits at a fixed chase offset behind+above the drone (in its
	## yaw frame) and smooth-follows it with a bit of lag. Mouse Y pitches
	## WHERE the camera looks, not where it sits — that's way less motion-sicky
	## than orbiting the camera around the drone per pixel of mouse input.
	var heading: Basis = Basis(Vector3.UP, _yaw)
	var offset: Vector3 = heading * Vector3(0.0, CHASE_HEIGHT, CHASE_DIST)
	var target_pos: Vector3 = global_position + offset
	_camera.global_position = _camera.global_position.lerp(target_pos, CAM_LERP * delta)

	# Look-at point: slightly ahead of the drone so it doesn't sit dead-center,
	# then shifted up/down by the current camera pitch so mouse-up shows sky.
	# cam_pitch > 0 (mouse dragged up) → look upward; < 0 → look downward.
	var forward: Vector3 = -heading.z
	var look_target: Vector3 = global_position + forward * 1.4
	look_target.y += _cam_pitch * 3.5
	_camera.look_at(look_target, Vector3.UP)


# ═════════════════════════════════════════════════════════════════════════════
# RIG CONSTRUCTION — procedural DJI-style quadcopter mesh
# ═════════════════════════════════════════════════════════════════════════════

# DJI-style camera-drone livery (flat matte, same toy-matte family as the Car
# Kit): light-grey shell, dark arms/gimbal, a small amber accent.
const DRONE_BODY   := Color(0.86, 0.87, 0.90)   # light grey shell
const DRONE_DARK   := Color(0.13, 0.13, 0.15)   # dark arms / motors / gimbal
const DRONE_ACCENT := Color(0.92, 0.58, 0.10)   # amber accent stripe
const DRONE_MATTE  := 0.85                       # roughness for shell parts
const ARM_REACH    := 1.75                       # motor offset along each diagonal
const PROP_RADIUS  := 1.25                       # spinning prop / blur-disc radius
const DRONE_SCALE  := 0.16                       # shrink the whole rig to a small consumer-drone footprint (~1.2 m span)


func _build_rig() -> void:
	# Hierarchy:
	#   self (this Node3D)
	#     _yaw_pivot (yaw heading)
	#       _tilt_pivot (bank + pitch, bob)
	#         Body shell, arms + props, legs, gimbal, top details, nav lights
	#     _camera (chase — NOT a child of yaw/tilt so it can smooth-follow)

	_yaw_pivot = Node3D.new()
	_yaw_pivot.name = "YawPivot"
	add_child(_yaw_pivot)

	_tilt_pivot = Node3D.new()
	_tilt_pivot.name = "TiltPivot"
	_yaw_pivot.add_child(_tilt_pivot)

	# The mesh is modeled at a big (helicopter-era) scale; shrink the whole
	# airframe down to a small consumer-drone footprint. Per-frame code only
	# sets this pivot's rotation/position (never its scale), so this sticks.
	_tilt_pivot.scale = Vector3.ONE * DRONE_SCALE

	_build_body()
	_build_arms_and_props()
	_build_legs()
	_build_gimbal()
	_build_top_details()
	_build_nav_lights()

	_camera = Camera3D.new()
	_camera.name = "ChaseCamera"
	_camera.fov = 72.0
	_camera.near = 0.1
	_camera.far = 500.0
	add_child(_camera)

	_build_audio()


func _csg_box(size: Vector3, color: Color, metallic: float = 0.1, roughness: float = 0.55) -> CSGBox3D:
	var b := CSGBox3D.new()
	b.size = size
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	b.material = m
	return b


func _csg_cyl(radius: float, height: float, sides: int, color: Color, metallic: float = 0.1) -> CSGCylinder3D:
	var c := CSGCylinder3D.new()
	c.radius = radius
	c.height = height
	c.sides = sides
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = 0.5
	c.material = m
	return c


func _build_body() -> void:
	## Flat camera-drone shell — low, wide, two-tier, light grey with an amber
	## nose stripe. Front faces -Z (the spawn heading), like the old nose did.
	# Lower hull (wider) + upper shell (narrower) → a soft two-tier body.
	var lower: CSGBox3D = _csg_box(Vector3(1.55, 0.26, 2.0), DRONE_BODY, 0.0, DRONE_MATTE)
	lower.position = Vector3(0.0, 0.0, 0.0)
	_tilt_pivot.add_child(lower)

	var upper: CSGBox3D = _csg_box(Vector3(1.15, 0.30, 1.5), DRONE_BODY, 0.0, DRONE_MATTE)
	upper.position = Vector3(0.0, 0.26, -0.05)
	_tilt_pivot.add_child(upper)

	# Dark belly plate (battery / downward sensors)
	var belly: CSGBox3D = _csg_box(Vector3(1.30, 0.10, 1.7), DRONE_DARK, 0.0, DRONE_MATTE)
	belly.position = Vector3(0.0, -0.16, 0.0)
	_tilt_pivot.add_child(belly)

	# Amber accent stripe across the nose (front = -Z) so heading is readable
	var stripe: CSGBox3D = _csg_box(Vector3(1.16, 0.12, 0.18), DRONE_ACCENT, 0.0, DRONE_MATTE)
	stripe.position = Vector3(0.0, 0.26, -0.78)
	_tilt_pivot.add_child(stripe)

	# Forward sensor nub — small dark block at the nose
	var beak: CSGBox3D = _csg_box(Vector3(0.5, 0.16, 0.30), DRONE_DARK, 0.0, DRONE_MATTE)
	beak.position = Vector3(0.0, 0.10, -1.04)
	_tilt_pivot.add_child(beak)


func _build_arms_and_props() -> void:
	## Four arms in an X, each ending in a motor pod + a spinning two-blade prop
	## with a translucent motion-blur disc. Adjacent props counter-rotate.
	_props.clear()

	# Shared translucent blur-disc material (reused across all four props)
	_rotor_mat = StandardMaterial3D.new()
	_rotor_mat.albedo_color = Color(0.72, 0.74, 0.80, 0.16)
	_rotor_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_rotor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rotor_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	# Diagonal motor positions: front-left, front-right, back-left, back-right.
	var corners := [
		Vector3(-1, 0, -1),  # front-left
		Vector3( 1, 0, -1),  # front-right
		Vector3(-1, 0,  1),  # back-left
		Vector3( 1, 0,  1),  # back-right
	]
	var blade_col := Color(0.07, 0.07, 0.08)
	for c in corners:
		var mx: float = c.x * ARM_REACH
		var mz: float = c.z * ARM_REACH

		# Arm — slim box from the body out to the motor, rotated so its long
		# (local Z) axis points down the diagonal toward (mx, mz).
		var reach: float = Vector2(mx, mz).length()
		var arm: CSGBox3D = _csg_box(Vector3(0.16, 0.12, reach), DRONE_DARK, 0.1, 0.7)
		arm.position = Vector3(mx * 0.5, 0.02, mz * 0.5)
		arm.rotation.y = atan2(mx, mz)
		_tilt_pivot.add_child(arm)

		# Motor pod — short cylinder standing at the arm tip
		var motor: CSGCylinder3D = _csg_cyl(0.16, 0.22, 12, DRONE_DARK, 0.4)
		motor.position = Vector3(mx, 0.14, mz)
		_tilt_pivot.add_child(motor)

		# Spinning prop pivot
		var prop := Node3D.new()
		prop.name = "Prop"
		prop.position = Vector3(mx, 0.28, mz)
		_tilt_pivot.add_child(prop)
		_props.append(prop)

		# Two thin blades (a stopped prop is still recognizable)
		for b in range(2):
			var blade: CSGBox3D = _csg_box(Vector3(PROP_RADIUS * 2.0, 0.03, 0.12), blade_col, 0.1, 0.6)
			blade.rotation.y = b * PI * 0.5
			prop.add_child(blade)

		# Translucent blur disc — sits just above the blades, spins with them
		var disc := CSGCylinder3D.new()
		disc.radius = PROP_RADIUS
		disc.height = 0.02
		disc.sides = 20
		disc.material = _rotor_mat
		disc.position = Vector3(0.0, 0.03, 0.0)
		prop.add_child(disc)


func _build_legs() -> void:
	## Four short landing legs with little foot pads under the body corners.
	for c in [Vector3(-1, 0, -1), Vector3(1, 0, -1), Vector3(-1, 0, 1), Vector3(1, 0, 1)]:
		var lx: float = c.x * 0.6
		var lz: float = c.z * 0.7
		var leg: CSGBox3D = _csg_box(Vector3(0.07, 0.42, 0.07), DRONE_DARK, 0.1, 0.8)
		leg.position = Vector3(lx, -0.38, lz)
		_tilt_pivot.add_child(leg)
		# Foot pad
		var foot: CSGBox3D = _csg_box(Vector3(0.14, 0.05, 0.22), DRONE_DARK, 0.1, 0.8)
		foot.position = Vector3(lx, -0.58, lz)
		_tilt_pivot.add_child(foot)


func _build_gimbal() -> void:
	## Under-slung 3-axis gimbal camera at the nose — the DJI signature.
	# Gimbal yoke (small dark bracket)
	var yoke: CSGBox3D = _csg_box(Vector3(0.34, 0.18, 0.22), DRONE_DARK, 0.2, 0.5)
	yoke.position = Vector3(0.0, -0.22, -0.85)
	_tilt_pivot.add_child(yoke)

	# Camera body — small dark cube
	var cam_body: CSGBox3D = _csg_box(Vector3(0.26, 0.26, 0.30), DRONE_DARK, 0.2, 0.45)
	cam_body.position = Vector3(0.0, -0.34, -0.88)
	_tilt_pivot.add_child(cam_body)

	# Lens — glossy black cylinder facing forward (-Z)
	var lens: CSGCylinder3D = _csg_cyl(0.10, 0.14, 14, Color(0.02, 0.02, 0.03), 0.6)
	lens.rotation.x = PI * 0.5
	lens.position = Vector3(0.0, -0.34, -1.02)
	_tilt_pivot.add_child(lens)

	# Lens glass — tiny blue-tinted emissive front so the camera "looks" alive
	var glint_mat := StandardMaterial3D.new()
	glint_mat.albedo_color = Color(0.20, 0.45, 0.75, 0.85)
	glint_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glint_mat.metallic = 0.6
	glint_mat.roughness = 0.1
	glint_mat.emission_enabled = true
	glint_mat.emission = Color(0.15, 0.35, 0.6)
	glint_mat.emission_energy_multiplier = 0.6
	var glint := CSGCylinder3D.new()
	glint.radius = 0.07
	glint.height = 0.03
	glint.sides = 14
	glint.material = glint_mat
	glint.rotation.x = PI * 0.5
	glint.position = Vector3(0.0, -0.34, -1.10)
	_tilt_pivot.add_child(glint)


func _build_top_details() -> void:
	## Small top-deck details — a GPS/compass puck and two stub antennas.
	var puck: CSGCylinder3D = _csg_cyl(0.22, 0.06, 16, Color(0.10, 0.10, 0.12), 0.3)
	puck.position = Vector3(0.0, 0.43, 0.10)
	_tilt_pivot.add_child(puck)

	for sx in [-1.0, 1.0]:
		var ant: CSGCylinder3D = _csg_cyl(0.02, 0.34, 6, DRONE_DARK, 0.3)
		ant.position = Vector3(sx * 0.45, 0.46, 0.55)
		ant.rotation.x = -0.5
		_tilt_pivot.add_child(ant)


func _build_nav_lights() -> void:
	## Front arm LEDs (red port / green starboard) + a blinking rear status
	## beacon — how a camera drone shows its orientation in low light.
	_tilt_pivot.add_child(_make_nav_light(Vector3(-ARM_REACH, 0.30, -ARM_REACH), Color(1.0, 0.08, 0.10)))   # front-left (red)
	_tilt_pivot.add_child(_make_nav_light(Vector3( ARM_REACH, 0.30, -ARM_REACH), Color(0.08, 1.0, 0.20)))   # front-right (green)

	# Rear status beacon — kept as a ref so it can blink. The material is the
	# MeshInstance3D's material_override (not a surface material).
	_tail_light = _make_nav_light(Vector3(0.0, 0.34, 1.0), Color(1.0, 1.0, 1.0))
	_tail_light_mat = _tail_light.material_override as StandardMaterial3D
	_tilt_pivot.add_child(_tail_light)


func _make_nav_light(pos: Vector3, color: Color) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.10
	sphere.height = 0.20
	sphere.radial_segments = 8
	sphere.rings = 4
	node.mesh = sphere
	node.position = pos
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	# material_override wins over any surface material on the mesh — we read
	# it back later via node.material_override (NOT mesh.surface_get_material).
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 3.0
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	node.material_override = mat
	return node


# ═════════════════════════════════════════════════════════════════════════════
# AUDIO — procedural quad-buzz loop generator
# ═════════════════════════════════════════════════════════════════════════════

func _build_audio() -> void:
	## Generate a short seamless loop on startup (high-pitched prop buzz +
	## electric-motor whine + prop-wash hiss), then hand it to an
	## AudioStreamPlayer. Non-positional so volume stays constant regardless of
	## chase-cam distance.
	_sound_stream = _generate_quad_loop(2.0, 22050)
	_sound_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	_sound_stream.loop_begin = 0
	_sound_stream.loop_end = _sound_stream.data.size() / 2  # 16-bit PCM

	_sound_player = AudioStreamPlayer.new()
	_sound_player.name = "DroneSound"
	_sound_player.stream = _sound_stream
	_sound_player.volume_db = SOUND_QUIET_DB
	_sound_player.bus = "Master"
	add_child(_sound_player)


func _generate_quad_loop(duration_sec: float, sample_rate: int) -> AudioStreamWAV:
	## Procedurally build a 2-second quadcopter loop:
	##   Prop buzz     — dense ~190 Hz blade-pass tone (four 2-blade props at
	##                   high RPM), slightly detuned for a beating shimmer +
	##                   two harmonics for the buzzy edge
	##   Motor whine   — high ~1.2 kHz electric-motor sizzle
	##   Body          — light 95 Hz low-end (no chopper chest-thump)
	##   Air wash      — low-passed white noise for the prop-wash hiss
	## All partials are integer multiples of 0.5 Hz → seamless 2-second loop.
	var num_samples: int = int(sample_rate * duration_sec)
	var bytes := PackedByteArray()
	bytes.resize(num_samples * 2)

	var lp: float = 0.0   # one-pole low-pass state for the noise
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC0FFEE

	for i in range(num_samples):
		var t: float = float(i) / sample_rate

		# Prop buzz — dense high blade-pass tone (four 2-blade props). A pair of
		# slightly detuned partials beat into a shimmer; two harmonics add edge.
		var buzz: float = sin(TAU * 190.0 * t) * 0.22
		buzz += sin(TAU * 192.5 * t) * 0.16   # detune → beating shimmer
		buzz += sin(TAU * 380.0 * t) * 0.10   # 2nd harmonic
		buzz += sin(TAU * 570.0 * t) * 0.05   # 3rd harmonic (buzzy edge)

		# Motor whine — high electric-motor sizzle on top.
		var whine: float = sin(TAU * 1180.0 * t) * 0.04
		whine += sin(TAU * 1240.0 * t) * 0.03

		# Body — light low-end weight (no chopper chest-thump).
		var rumble: float = sin(TAU * 95.0 * t) * 0.06

		# Air wash — low-passed white noise for the prop-wash hiss.
		var white: float = rng.randf() * 2.0 - 1.0
		lp = lp * 0.80 + white * 0.20
		var air: float = lp * 0.06

		var sample: float = buzz + whine + rumble + air
		sample = clampf(sample, -1.0, 1.0)
		var s16: int = int(sample * 32000.0)
		bytes[i * 2]     = s16 & 0xFF
		bytes[i * 2 + 1] = (s16 >> 8) & 0xFF

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = sample_rate
	wav.stereo = false
	wav.data = bytes
	return wav
