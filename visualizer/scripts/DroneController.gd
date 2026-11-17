extends CharacterBody3D
## Shared navigation drone: assisted flight, swept collisions, stabilised camera,
## resumable position and an instrument HUD. Main owns H/Esc and camera restore.
signal mode_changed(active: bool)

const FlightHUD = preload("res://scripts/DroneHUD.gd")
const Airframe = preload("res://scripts/DroneAirframe.gd")
@export var corridor_mode: bool = false
const SPEEDS: Array[float] = [4.0, 12.0, 26.0]
const SPEED_NAMES: Array[String] = ["INSPECT", "CRUISE", "FAST"]
const BOOST_MULT: float = 1.7
const MIN_HEIGHT: float = 1.3
const MAX_HEIGHT: float = 120.0
const BODY_RADIUS: float = 0.65
const CHASE_DIST: float = 4.0
const MOUSE_SENS: float = 0.0025
const SOUND_BASE_VOLUME_DB: float = -22.0
const SOUND_QUIET_DB: float = -40.0

var active: bool = false
var _velocity := Vector3.ZERO
var _yaw: float = 0.0
var _pitch: float = -0.32
var _camera_yaw: float = 0.0
var _camera_pitch: float = -0.32
var _speed_mode: int = 1
var _gimbal_view: bool = false
var _cursor_released: bool = false
var _focus_lost: bool = false
var _has_flown: bool = false
var _zoom_target: float = 64.0
var _obstacle: bool = false
var _home := Vector3.ZERO
var _intent := Vector3.ZERO
var _boosting: bool = false
var _bank: float = 0.0
var _body_pitch: float = 0.0
var _rotor_spin: float = 0.0
var _rotor_speed: float = 58.0
var _hover_t: float = 0.0
var _light_blink_t: float = 0.0
var _yaw_pivot: Node3D
var _tilt_pivot: Node3D
var _airframe: Node3D
var _camera: Camera3D
var _camera_rig: Node3D
var _spring_arm: SpringArm3D
var _hull: SphereShape3D
var _hud: CanvasLayer
var _dashboard: CanvasLayer
var _dashboard_was_visible: bool = true
var _previous_camera: Camera3D
var _sound_player: AudioStreamPlayer
var _sound_stream: AudioStreamWAV

func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = 0 # The navigation tool never blocks simulation actors.
	collision_mask = 1
	safe_margin = 0.03
	_hull = SphereShape3D.new()
	_hull.radius = BODY_RADIUS
	var shape := CollisionShape3D.new()
	shape.shape = _hull
	add_child(shape)
	_home = Vector3(0, 35, 340) if corridor_mode else Vector3(0,35,40)
	_build_rig()
	_hud = FlightHUD.new()
	add_child(_hud)
	visible = false
	set_process(false)
	set_physics_process(false)
	set_process_input(false)

func activate(source_camera: Camera3D = null) -> void:
	if active:
		return
	_previous_camera = source_camera if source_camera != null else get_viewport().get_camera_3d()
	_dashboard = get_parent().get_node_or_null("UI") as CanvasLayer
	if _dashboard:
		_dashboard_was_visible = _dashboard.visible
	active = true
	visible = true
	if not _has_flown:
		global_position = _home
		_yaw = 0.0
		_pitch = -0.32
		# Enter from the view being inspected when there is room for the drone.
		if source_camera != null and _position_clear(source_camera.global_position):
			global_position = source_camera.global_position
			_yaw = source_camera.global_rotation.y
			_pitch = clampf(source_camera.global_rotation.x, -1.48, 0.65)
		_has_flown = true
	brake()
	set_cursor_released(false)
	_yaw_pivot.rotation.y = _yaw
	_snap_camera()
	_camera.current = true
	_hud.visible = true
	if _sound_player:
		_sound_player.volume_db = SOUND_QUIET_DB
		_sound_player.play()
	set_process(true)
	set_physics_process(true)
	set_process_input(true)
	_hud.update_flight(telemetry())
	mode_changed.emit(true)

func deactivate() -> void:
	if not active:
		return
	active = false
	brake()
	visible = false
	_hud.visible = false
	if _sound_player:
		_sound_player.stop()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_camera.current = false
	if is_instance_valid(_previous_camera):
		_previous_camera.current = true
	if is_instance_valid(_dashboard):
		_dashboard.visible = _dashboard_was_visible
	set_process(false)
	set_physics_process(false)
	set_process_input(false)
	mode_changed.emit(false)

func flight_camera() -> Camera3D:
	return _camera

func set_speed_mode(index: int) -> void:
	_speed_mode = clampi(index, 0, SPEEDS.size() - 1)

func toggle_view() -> void:
	_gimbal_view = not _gimbal_view
	_tilt_pivot.visible = not _gimbal_view
	_spring_arm.spring_length = 0.0 if _gimbal_view else CHASE_DIST
	_snap_camera()

func adjust_zoom(steps: float) -> void:
	_zoom_target = clampf(_zoom_target - steps * 4.0, 28.0, 86.0)

func brake() -> void:
	_velocity = Vector3.ZERO
	velocity = Vector3.ZERO
	_intent = Vector3.ZERO
	_boosting = false

func return_home() -> void:
	global_position = _home
	_yaw = 0.0
	_pitch = -0.32
	brake()
	_obstacle = false
	_snap_camera()

func set_cursor_released(released: bool) -> void:
	_cursor_released = released
	brake()
	if not released:
		_focus_lost = false
		get_viewport().gui_release_focus()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if released else Input.MOUSE_MODE_CAPTURED
	if active and is_instance_valid(_dashboard):
		_dashboard.visible = _dashboard_was_visible if released else false

func _notification(what: int) -> void:
	if what in [NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT] and active:
		_focus_lost = true
		set_cursor_released(true)

func _exit_tree() -> void:
	if active:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_TAB:
		set_cursor_released(not _cursor_released)
		get_viewport().set_input_as_handled()
		return
	if _cursor_released or _focus_lost:
		return
	if event is InputEventMouseMotion:
		_yaw = wrapf(_yaw - event.relative.x * MOUSE_SENS, -PI, PI)
		_pitch = clampf(_pitch - event.relative.y * MOUSE_SENS, -1.48, 0.65)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			adjust_zoom(1.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			adjust_zoom(-1.0)
		get_viewport().set_input_as_handled()
	elif event is InputEventMagnifyGesture:
		adjust_zoom((event.factor - 1.0) * 12.0)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		if event.pressed and not event.echo:
			match event.keycode:
				KEY_1: set_speed_mode(0)
				KEY_2: set_speed_mode(1)
				KEY_3: set_speed_mode(2)
				KEY_F: toggle_view()
				KEY_X: brake()
				KEY_R: return_home()
		# Keep mode switches and sensor overlay available to the scene controller.
		if event.keycode in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_SPACE, KEY_CTRL, KEY_C,
			KEY_SHIFT, KEY_1, KEY_2, KEY_3, KEY_F, KEY_X, KEY_R, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT]:
			get_viewport().set_input_as_handled()

func _physics_process(delta: float) -> void:
	var intent := Vector3.ZERO
	if not _cursor_released and not _focus_lost:
		intent.x = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		intent.z = float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
		intent.y = float(Input.is_physical_key_pressed(KEY_SPACE)) - float(Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_C))
		_yaw = wrapf(_yaw + (float(Input.is_key_pressed(KEY_LEFT)) - float(Input.is_key_pressed(KEY_RIGHT))) * delta * 1.4, -PI, PI)
		_pitch = clampf(_pitch + (float(Input.is_key_pressed(KEY_UP)) - float(Input.is_key_pressed(KEY_DOWN))) * delta, -1.48, 0.65)
	_step_flight(delta, intent, Input.is_physical_key_pressed(KEY_SHIFT), Input.is_physical_key_pressed(KEY_X))

func _integrate_velocity(delta: float, intent: Vector3, boosting: bool, braking: bool) -> void:
	if braking:
		brake()
		return
	var limited := intent.limit_length(1.0)
	var cap: float = SPEEDS[_speed_mode] * (2.5 if _speed_mode > 0 else 1.0) * (BOOST_MULT if boosting else 1.0)
	var local_velocity := limited * cap
	local_velocity.y = limited.y * minf(cap, 12.0)
	var target := Basis(Vector3.UP, _yaw) * local_velocity
	# Exponential response avoids frame-rate-dependent acceleration and stopping.
	var response: float = 5.0 if not limited.is_zero_approx() else 8.0
	_velocity = _velocity.lerp(target, 1.0 - exp(-response * delta))
	if _velocity.length_squared() < 0.0001:
		_velocity = Vector3.ZERO

func _step_flight(delta: float, intent: Vector3, boosting: bool = false, braking: bool = false) -> void:
	if not active or _cursor_released or _focus_lost:
		brake()
		return
	_intent = intent.limit_length(1.0)
	_boosting = boosting
	_integrate_velocity(delta, intent, boosting, braking)
	velocity = _velocity
	move_and_slide()
	_velocity = velocity
	_obstacle = get_slide_collision_count() > 0
	# Ground clearance and a finite flying area prevent losing the simulation.
	var before: Vector3 = global_position
	var mid_z: float = 300.0 if corridor_mode else 0.0
	global_position = Vector3(clampf(before.x, -1800.0, 1800.0), clampf(before.y, MIN_HEIGHT, MAX_HEIGHT), clampf(before.z, mid_z - (1900.0 if corridor_mode else 1800.0), mid_z + (1900.0 if corridor_mode else 1800.0)))
	for axis in range(3):
		if not is_equal_approx(before[axis], global_position[axis]):
			_velocity[axis] = 0.0
			velocity[axis] = 0.0
			_obstacle = true

func _position_clear(at: Vector3) -> bool:
	var mid_z: float = 300.0 if corridor_mode else 0.0
	if at.y < MIN_HEIGHT or at.y > MAX_HEIGHT or absf(at.x) > (1800.0) or absf(at.z - mid_z) > (1900.0 if corridor_mode else 1800.0):
		return false
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = _hull
	query.transform = Transform3D(Basis.IDENTITY, at)
	query.collision_mask = collision_mask
	query.exclude = [get_rid()]
	return get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()

func _snap_camera() -> void:
	_camera_yaw = _yaw
	_camera_pitch = _pitch
	_camera_rig.global_transform = Transform3D(Basis.from_euler(Vector3(_pitch, _yaw, 0)), global_position + Vector3.UP * 0.25)
	_camera.position = Vector3(0, 0, 0.0 if _gimbal_view else CHASE_DIST)
	_camera.fov = _zoom_target

func _process(delta: float) -> void:
	if not active:
		return
	var blend: float = 1.0 - exp(-10.0 * delta)
	_yaw_pivot.rotation.y = lerp_angle(_yaw_pivot.rotation.y, _yaw, blend)
	_bank = lerpf(_bank, -_intent.x * 0.28, blend)
	_body_pitch = lerpf(_body_pitch, _intent.z * 0.20, blend)
	_tilt_pivot.rotation = Vector3(_body_pitch, 0, _bank)
	_hover_t += delta
	_tilt_pivot.position.y = sin(_hover_t * 1.8) * 0.025 * (1.0 - clampf(_velocity.length() / 4.0, 0.0, 1.0))
	_rotor_speed = lerpf(_rotor_speed, 58.0 + _velocity.length() * 1.1, blend)
	_rotor_spin = fmod(_rotor_spin + _rotor_speed * delta, TAU)
	_light_blink_t += delta
	_airframe.animate_flight(_rotor_spin, _camera_pitch, _body_pitch, _bank,
		wrapf(_camera_yaw - _yaw_pivot.rotation.y, -PI, PI), _light_blink_t)
	_camera_yaw = lerp_angle(_camera_yaw, _yaw, blend)
	_camera_pitch = lerpf(_camera_pitch, _pitch, blend)
	# The stabilised gimbal follows position directly; neither view inherits body bank.
	_camera_rig.global_position = global_position + Vector3.UP * 0.25
	_camera_rig.global_basis = Basis.from_euler(Vector3(_camera_pitch, _camera_yaw, 0))
	_camera.fov = lerpf(_camera.fov, _zoom_target, blend)
	_hud.update_flight(telemetry())
	if _sound_player:
		var volume: float = -30.0 if _cursor_released else SOUND_BASE_VOLUME_DB
		_sound_player.volume_db = lerpf(_sound_player.volume_db, volume, blend)
		_sound_player.pitch_scale = lerpf(_sound_player.pitch_scale, 0.94 + _velocity.length() * 0.006, blend)

func telemetry() -> Dictionary:
	# Mirrored simulation coordinates: north +Z, east -X.
	var forward := -Basis(Vector3.UP, _yaw).z
	return {"speed": _velocity.length(), "altitude": global_position.y,
		"heading": fposmod(rad_to_deg(atan2(-forward.x, forward.z)), 360.0),
		"mode": SPEED_NAMES[_speed_mode], "view": "GIMBAL" if _gimbal_view else "CHASE",
		"zoom": _camera.fov, "position": global_position, "home": _home,
		"paused": _cursor_released or _focus_lost, "obstacle": _obstacle, "corridor": corridor_mode}


func _build_rig() -> void:
	_yaw_pivot = Node3D.new()
	_yaw_pivot.name = "YawPivot"
	add_child(_yaw_pivot)
	_tilt_pivot = Node3D.new()
	_tilt_pivot.name = "TiltPivot"
	_yaw_pivot.add_child(_tilt_pivot)
	_airframe = Airframe.new()
	_airframe.name = "SurveyAirframe"
	_tilt_pivot.add_child(_airframe)

	_camera_rig = Node3D.new()
	_camera_rig.name = "StabilisedRig"
	add_child(_camera_rig)
	_camera_rig.top_level = true
	_spring_arm = SpringArm3D.new()
	_spring_arm.name = "CameraClearance"
	_spring_arm.spring_length = CHASE_DIST
	_spring_arm.margin = 0.15
	_spring_arm.collision_mask = 1
	var camera_shape := SphereShape3D.new()
	camera_shape.radius = 0.2
	_spring_arm.shape = camera_shape
	_camera_rig.add_child(_spring_arm)
	_spring_arm.add_excluded_object(get_rid())
	_camera = Camera3D.new()
	_camera.name = "FlightCamera"
	_camera.fov = 64.0
	_camera.near = 0.06
	_camera.far = 4500.0
	_camera.doppler_tracking = Camera3D.DOPPLER_TRACKING_PHYSICS_STEP
	_spring_arm.add_child(_camera)

	_build_audio()


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
