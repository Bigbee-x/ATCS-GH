extends Node3D
## Cinematic helicopter/drone flight mode for the ATCS-GH visualizer.
##
## Press H to toggle. A procedural helicopter (CSG fuselage, tail boom,
## translucent spinning rotor disc, tail rotor, skids, canopy, nav lights)
## spawns above the junction. The user flies it with FPS-style controls
## while a chase camera follows behind-and-above with a bit of lag for
## a cinematic feel.
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
##   while active. The chopper mesh is built once in _ready() and re-used
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
const CAM_PITCH_MIN: float   = -0.95         # ~-54° (looking up at chopper belly)
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
var _main_rotor: Node3D         # spins on Y
var _tail_rotor: Node3D         # spins on X
var _tail_light: MeshInstance3D # blinking nav light
var _tail_light_mat: StandardMaterial3D
var _rotor_mat: StandardMaterial3D   # translucent disc material

# ── Camera ──────────────────────────────────────────────────────────────────
var _camera: Camera3D           # chase cam — scene-root sibling, smooth follow
const CHASE_DIST: float    = 8.5
const CHASE_HEIGHT: float  = 3.2
const CAM_LERP: float      = 6.0

# ── Audio — procedural chopper loop (blade thump + turbine + air) ──────────
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

	# Start the chopper-sound loop with a short fade-in so the buffer
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
	# Keep the chopper above the ground
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

	# ── Rotors ─────────────────────────────────────────────────────────
	_rotor_spin += _rotor_speed * delta
	if _main_rotor:
		_main_rotor.rotation.y = _rotor_spin
	if _tail_rotor:
		_tail_rotor.rotation.x = _rotor_spin * 2.6

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
	## Camera sits at a fixed chase offset behind+above the chopper (in its
	## yaw frame) and smooth-follows it with a bit of lag. Mouse Y pitches
	## WHERE the camera looks, not where it sits — that's way less motion-sicky
	## than orbiting the camera around the chopper per pixel of mouse input.
	var heading: Basis = Basis(Vector3.UP, _yaw)
	var offset: Vector3 = heading * Vector3(0.0, CHASE_HEIGHT, CHASE_DIST)
	var target_pos: Vector3 = global_position + offset
	_camera.global_position = _camera.global_position.lerp(target_pos, CAM_LERP * delta)

	# Look-at point: slightly ahead of the chopper so it doesn't sit dead-center,
	# then shifted up/down by the current camera pitch so mouse-up shows sky.
	# cam_pitch > 0 (mouse dragged up) → look upward; < 0 → look downward.
	var forward: Vector3 = -heading.z
	var look_target: Vector3 = global_position + forward * 3.0
	look_target.y += _cam_pitch * 7.0
	_camera.look_at(look_target, Vector3.UP)


# ═════════════════════════════════════════════════════════════════════════════
# RIG CONSTRUCTION — procedural chopper mesh
# ═════════════════════════════════════════════════════════════════════════════

# Kenney-matched livery (flat matte, like the Car Kit colormap): white body,
# red accents, dark trim — reads as the same family as the ambulance/taxi.
const HELI_BODY   := Color(0.93, 0.93, 0.96)   # Kenney white
const HELI_ACCENT := Color(0.85, 0.22, 0.18)   # Kenney red
const HELI_TRIM   := Color(0.16, 0.16, 0.18)   # dark matte trim
const HELI_MATTE  := 0.9                       # roughness for painted parts


func _build_rig() -> void:
	# Hierarchy:
	#   self (this Node3D)
	#     _yaw_pivot (yaw heading)
	#       _tilt_pivot (bank + pitch, bob)
	#         Fuselage, tail boom, rotors, skids, canopy, nav lights
	#     _camera (chase — NOT a child of yaw/tilt so it can smooth-follow)

	_yaw_pivot = Node3D.new()
	_yaw_pivot.name = "YawPivot"
	add_child(_yaw_pivot)

	_tilt_pivot = Node3D.new()
	_tilt_pivot.name = "TiltPivot"
	_yaw_pivot.add_child(_tilt_pivot)

	_build_body()
	_build_tail()
	_build_rotors()
	_build_skids()
	_build_canopy()
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
	## Fuselage — main cabin + rounded nose, Kenney-style white with red livery.
	# Main cabin — slightly wider than tall, elongated
	var cabin: CSGBox3D = _csg_box(Vector3(1.45, 0.95, 2.4), HELI_BODY, 0.0, HELI_MATTE)
	cabin.position = Vector3(0.0, 0.1, 0.0)
	_tilt_pivot.add_child(cabin)

	# Livery stripes — red band along each cabin side (news/medic chopper read)
	for side in [-1.0, 1.0]:
		var stripe: CSGBox3D = _csg_box(Vector3(0.04, 0.22, 2.42), HELI_ACCENT, 0.0, HELI_MATTE)
		stripe.position = Vector3(side * 0.735, 0.0, 0.0)
		_tilt_pivot.add_child(stripe)

	# Belly plate — dark trim strip
	var belly: CSGBox3D = _csg_box(Vector3(1.50, 0.10, 2.30), HELI_TRIM, 0.0, HELI_MATTE)
	belly.position = Vector3(0.0, -0.45, 0.0)
	_tilt_pivot.add_child(belly)

	# Nose — forward-tapering block so the silhouette has a "beak"
	var nose: CSGBox3D = _csg_box(Vector3(1.10, 0.78, 0.8), HELI_BODY, 0.0, HELI_MATTE)
	nose.position = Vector3(0.0, 0.0, -1.45)
	_tilt_pivot.add_child(nose)

	# Nose tip — red accent, adds readable detail
	var tip: CSGBox3D = _csg_box(Vector3(0.8, 0.55, 0.35), HELI_ACCENT, 0.0, HELI_MATTE)
	tip.position = Vector3(0.0, -0.05, -1.9)
	_tilt_pivot.add_child(tip)


func _build_tail() -> void:
	## Tail boom + vertical fin + tail-rotor assembly.
	var metal := Color(0.28, 0.28, 0.32)

	# Tail boom — white like the body
	var boom: CSGBox3D = _csg_box(Vector3(0.28, 0.30, 2.6), HELI_BODY, 0.0, HELI_MATTE)
	boom.position = Vector3(0.0, 0.25, 2.4)
	_tilt_pivot.add_child(boom)

	# Vertical stabilizer / fin — red accent (livery tail flash)
	var fin: CSGBox3D = _csg_box(Vector3(0.08, 0.80, 0.55), HELI_ACCENT, 0.0, HELI_MATTE)
	fin.position = Vector3(0.0, 0.65, 3.55)
	_tilt_pivot.add_child(fin)

	# Horizontal stabilizer (small side wings) — red accent
	var stab: CSGBox3D = _csg_box(Vector3(1.0, 0.06, 0.35), HELI_ACCENT, 0.0, HELI_MATTE)
	stab.position = Vector3(0.0, 0.35, 3.4)
	_tilt_pivot.add_child(stab)

	# Tail rotor hub + disc (spins on X)
	_tail_rotor = Node3D.new()
	_tail_rotor.name = "TailRotor"
	_tail_rotor.position = Vector3(0.22, 0.65, 3.55)
	_tilt_pivot.add_child(_tail_rotor)

	var hub: CSGCylinder3D = _csg_cyl(0.07, 0.14, 8, metal, 0.6)
	hub.rotation.z = PI * 0.5
	_tail_rotor.add_child(hub)

	# Two thin blades crossing (so any angle shows something)
	var blade_col := Color(0.05, 0.05, 0.06)
	for i in range(2):
		var blade: CSGBox3D = _csg_box(Vector3(0.02, 0.9, 0.08), blade_col, 0.05, 0.7)
		blade.rotation.x = i * PI * 0.5
		_tail_rotor.add_child(blade)


func _build_rotors() -> void:
	## Main rotor mast + translucent spinning disc.
	var mast_col := Color(0.22, 0.22, 0.26)
	var mast: CSGCylinder3D = _csg_cyl(0.09, 0.45, 8, mast_col, 0.6)
	mast.position = Vector3(0.0, 0.9, -0.15)
	_tilt_pivot.add_child(mast)

	# Rotor hub
	var hub: CSGCylinder3D = _csg_cyl(0.22, 0.10, 10, mast_col, 0.7)
	hub.position = Vector3(0.0, 1.15, -0.15)
	_tilt_pivot.add_child(hub)

	# Spinning pivot — everything below rotates on Y at high speed
	_main_rotor = Node3D.new()
	_main_rotor.name = "MainRotor"
	_main_rotor.position = Vector3(0.0, 1.18, -0.15)
	_tilt_pivot.add_child(_main_rotor)

	# Thin visible blades (so stopped rotor is recognizable)
	var blade_col := Color(0.08, 0.08, 0.09)
	for i in range(2):
		var blade: CSGBox3D = _csg_box(Vector3(7.0, 0.06, 0.18), blade_col, 0.1, 0.6)
		blade.rotation.y = i * PI * 0.5
		_main_rotor.add_child(blade)

	# Translucent motion-blur disc — sits slightly above blades, spins with them
	_rotor_mat = StandardMaterial3D.new()
	_rotor_mat.albedo_color = Color(0.7, 0.7, 0.75, 0.18)
	_rotor_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_rotor_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_rotor_mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var disc := CSGCylinder3D.new()
	disc.radius = 3.6
	disc.height = 0.02
	disc.sides = 24
	disc.material = _rotor_mat
	disc.position = Vector3(0.0, 0.04, 0.0)
	_main_rotor.add_child(disc)


func _build_skids() -> void:
	## Landing skids — two parallel bars below the cabin with 4 struts.
	## Dark matte like the Kenney wheels/trim (no metallic sheen).
	var metal := Color(0.22, 0.22, 0.26)
	for side in [-1, 1]:
		var skid: CSGBox3D = _csg_box(Vector3(0.09, 0.09, 2.0), metal, 0.1, 0.8)
		skid.position = Vector3(side * 0.55, -0.75, 0.0)
		_tilt_pivot.add_child(skid)
		for z in [-0.7, 0.7]:
			var strut: CSGBox3D = _csg_box(Vector3(0.06, 0.35, 0.06), metal, 0.1, 0.8)
			strut.position = Vector3(side * 0.55, -0.55, z)
			_tilt_pivot.add_child(strut)


func _build_canopy() -> void:
	## Tinted cockpit glass — front half of the cabin, translucent dark blue.
	var glass_mat := StandardMaterial3D.new()
	# Same dark reflective glass as the building windows / car glazing
	glass_mat.albedo_color = Color(0.14, 0.17, 0.22, 0.80)
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_mat.metallic = 0.35
	glass_mat.roughness = 0.15

	var canopy := CSGBox3D.new()
	canopy.size = Vector3(1.30, 0.55, 1.2)
	canopy.material = glass_mat
	canopy.position = Vector3(0.0, 0.35, -0.85)
	_tilt_pivot.add_child(canopy)


func _build_nav_lights() -> void:
	## Red port, green starboard, blinking white tail — classic aviation lights.
	_tilt_pivot.add_child(_make_nav_light(Vector3(-0.78, -0.05, -1.3), Color(1.0, 0.08, 0.10)))   # port (red)
	_tilt_pivot.add_child(_make_nav_light(Vector3( 0.78, -0.05, -1.3), Color(0.08, 1.0, 0.20)))   # starboard (green)

	# Tail beacon — kept as a ref so it can blink. The material is the
	# MeshInstance3D's material_override (not a surface material).
	_tail_light = _make_nav_light(Vector3(0.0, 0.95, 3.75), Color(1.0, 1.0, 1.0))
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
# AUDIO — procedural chopper-loop generator
# ═════════════════════════════════════════════════════════════════════════════

func _build_audio() -> void:
	## Generate a short seamless loop on startup (blade thump + turbine
	## whine + broadband air noise), then hand it to an AudioStreamPlayer.
	## Non-positional so volume stays constant regardless of chase-cam distance.
	_sound_stream = _generate_chopper_loop(2.0, 22050)
	_sound_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	_sound_stream.loop_begin = 0
	_sound_stream.loop_end = _sound_stream.data.size() / 2  # 16-bit PCM

	_sound_player = AudioStreamPlayer.new()
	_sound_player.name = "ChopperSound"
	_sound_player.stream = _sound_stream
	_sound_player.volume_db = SOUND_QUIET_DB
	_sound_player.bus = "Master"
	add_child(_sound_player)


func _generate_chopper_loop(duration_sec: float, sample_rate: int) -> AudioStreamWAV:
	## Procedurally build a 2-second chopper loop:
	##   Blade thump   — sharp amplitude-modulated 80 Hz pulse at 18 Hz
	##                   (main-rotor blade-pass frequency — 2 blades × 9 rev/s)
	##   Turbine whine — two detuned sines (~420 / 380 Hz) producing a beat
	##                   frequency that sounds like turbine shimmer
	##   Bass rumble   — low 45 Hz sine for weight
	##   Air noise     — broadband white noise, low-pass filtered
	## 2-second length × 18 Hz thump = 36 cycles (integer) → seamless loop.
	var num_samples: int = int(sample_rate * duration_sec)
	var bytes := PackedByteArray()
	bytes.resize(num_samples * 2)

	var lp: float = 0.0   # one-pole low-pass state for the noise
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xC0FFEE

	for i in range(num_samples):
		var t: float = float(i) / sample_rate

		# Blade thump — a sharp "whomp" at the rotor blade-pass rate.
		# pow(cos, 8) gives a narrow spike that reads as a thump, not a tone.
		var thump_env: float = pow(cos(PI * 18.0 * t), 8.0)
		var thump: float = sin(TAU * 80.0 * t) * thump_env * 0.55

		# Turbine whine — two sines with close frequencies create a slow
		# beat that sounds mechanical and alive.
		var whine: float = sin(TAU * 420.0 * t) * 0.10
		whine += sin(TAU * 380.0 * t) * 0.07

		# Bass rumble — steady low sine for chest-thump weight.
		var rumble: float = sin(TAU * 45.0 * t) * 0.18

		# Air noise — low-passed white noise for the "wash" of the rotor
		var white: float = rng.randf() * 2.0 - 1.0
		lp = lp * 0.88 + white * 0.12
		var air: float = lp * 0.08

		var sample: float = thump + whine + rumble + air
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
