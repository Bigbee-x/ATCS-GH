extends CharacterBody3D
## Ground-level "GTA-style" pedestrian avatar.
##
## The player lives in the same scene as the top-down sim. Pressing V hands
## control from the isometric camera to this controller. F toggles between
## first-person (camera inside the head) and third-person (camera behind a
## visible avatar). Esc, or V again, returns to the top-down view.
##
## The avatar is self-contained: it builds its own capsule collision, avatar
## mesh (torso / head / legs matching the ambient pedestrian style), and two
## Camera3Ds (FP + TP) in _ready(). No Main.tscn edits needed.
##
## World scale: 1 Godot unit ≈ 4.5m (cars are 1 unit long). Player capsule is
## 0.5 tall, 0.16 radius — matches the ambient pedestrian visual scale.
##
## Godot rotation convention used here:
##   rotation.y = 0    → node's -Z basis points down world -Z (cam looks north)
##   rotation.y = +π   → -Z basis points down world +Z (cam looks south)
##   forward from yaw  = Vector3(-sin(yaw), 0, -cos(yaw))
##   right   from yaw  = Vector3( cos(yaw), 0, -sin(yaw))

# ── Physics tuning (scaled for this world) ─────────────────────────────────
const WALK_SPEED      : float = 1.6
const SPRINT_SPEED    : float = 4.0
const JUMP_VELOCITY   : float = 2.2
const GRAVITY         : float = 8.0
const ACCEL           : float = 18.0
const FRICTION        : float = 20.0
const MOUSE_SENSITIVITY : float = 0.0025
const PITCH_MIN : float = -1.35
const PITCH_MAX : float = 1.20

# ── Body geometry ──────────────────────────────────────────────────────────
const CAPSULE_RADIUS : float = 0.16
const CAPSULE_HEIGHT : float = 0.50   # total capsule height (incl. hemisphere caps)
const EYE_HEIGHT     : float = 0.45

# ── Avatar palette ─────────────────────────────────────────────────────────
const SHIRT_COLORS: Array = [
	Color(0.20, 0.35, 0.70),   # Blue
	Color(0.85, 0.15, 0.15),   # Red
	Color(0.15, 0.15, 0.15),   # Black
]
const SKIN_COLOR: Color = Color(0.55, 0.38, 0.24)
const LEG_COLOR:  Color = Color(0.15, 0.15, 0.20)

# ── State ──────────────────────────────────────────────────────────────────
var _active: bool = false
var _first_person: bool = true
var _yaw: float   = 0.0
var _pitch: float = -0.05

# ── Node refs (built in _ready) ────────────────────────────────────────────
var _collision_shape: CollisionShape3D
var _avatar_root: Node3D
var _yaw_pivot: Node3D          # child, rotates with view yaw
var _pitch_pivot: Node3D        # child of yaw pivot, pitches up/down
var _fp_camera: Camera3D
var _tp_camera: Camera3D

signal entered
signal exited


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	_build_collision()
	_build_avatar()
	_build_cameras()
	# Start dormant — Main.gd calls set_active(true) when V is pressed.
	set_active(false)


func _unhandled_input(event: InputEvent) -> void:
	if not _active:
		return

	if event is InputEventMouseMotion:
		_yaw   -= event.relative.x * MOUSE_SENSITIVITY
		_pitch  = clampf(_pitch - event.relative.y * MOUSE_SENSITIVITY, PITCH_MIN, PITCH_MAX)
		_apply_look()


func _physics_process(delta: float) -> void:
	if not _active:
		return

	# ── Gravity ──────────────────────────────────────────────────────────
	if not is_on_floor():
		velocity.y -= GRAVITY * delta

	# ── Movement input (camera-relative) ─────────────────────────────────
	# W = forward (-Z), S = back (+Z), A = left (-X of view), D = right (+X)
	var in_forward: float = 0.0
	var in_strafe : float = 0.0
	if Input.is_key_pressed(KEY_W) or Input.is_action_pressed("ui_up"):
		in_forward += 1.0
	if Input.is_key_pressed(KEY_S) or Input.is_action_pressed("ui_down"):
		in_forward -= 1.0
	if Input.is_key_pressed(KEY_D) or Input.is_action_pressed("ui_right"):
		in_strafe += 1.0
	if Input.is_key_pressed(KEY_A) or Input.is_action_pressed("ui_left"):
		in_strafe -= 1.0

	var target_speed: float = SPRINT_SPEED if Input.is_key_pressed(KEY_SHIFT) else WALK_SPEED
	var target_vel := Vector3.ZERO

	if absf(in_forward) + absf(in_strafe) > 0.001:
		# Convert camera-local intent → world direction
		var forward := Vector3(-sin(_yaw), 0, -cos(_yaw))
		var right   := Vector3( cos(_yaw), 0, -sin(_yaw))
		var dir     := (forward * in_forward + right * in_strafe).normalized()
		target_vel = dir * target_speed
		# Rotate avatar to face movement direction (TP view).
		# Want avatar's -Z basis to point along `dir`:
		#   (-sin(r), 0, -cos(r)) = dir → r = atan2(-dir.x, -dir.z)
		if _avatar_root:
			var face_yaw: float = atan2(-dir.x, -dir.z)
			_avatar_root.rotation.y = lerp_angle(_avatar_root.rotation.y, face_yaw, 12.0 * delta)

	# ── Smooth accel / friction ──────────────────────────────────────────
	var rate: float = ACCEL if target_vel.length_squared() > 0.001 else FRICTION
	velocity.x = move_toward(velocity.x, target_vel.x, rate * delta)
	velocity.z = move_toward(velocity.z, target_vel.z, rate * delta)

	# ── Jump ─────────────────────────────────────────────────────────────
	if Input.is_key_pressed(KEY_SPACE) and is_on_floor():
		velocity.y = JUMP_VELOCITY

	move_and_slide()


# ═════════════════════════════════════════════════════════════════════════════
# PUBLIC API
# ═════════════════════════════════════════════════════════════════════════════

func set_active(active: bool) -> void:
	_active = active
	if active:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_apply_view_mode()
		_apply_look()
		emit_signal("entered")
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if _fp_camera:
			_fp_camera.current = false
		if _tp_camera:
			_tp_camera.current = false
		if _avatar_root:
			_avatar_root.visible = false   # hide avatar while in top-down view
		velocity = Vector3.ZERO
		emit_signal("exited")


func is_active() -> bool:
	return _active


func toggle_view_mode() -> void:
	_first_person = not _first_person
	_apply_view_mode()


func is_first_person() -> bool:
	return _first_person


func spawn_at(pos: Vector3, facing_yaw: float = 0.0) -> void:
	global_position = pos
	_yaw = facing_yaw
	_pitch = -0.05
	velocity = Vector3.ZERO
	_apply_look()
	# Avatar's -Z basis should point the same way the camera is looking
	# (so TP view shows the back of the head, not the face).
	if _avatar_root:
		_avatar_root.rotation.y = facing_yaw


# ═════════════════════════════════════════════════════════════════════════════
# INTERNALS — SCENE CONSTRUCTION
# ═════════════════════════════════════════════════════════════════════════════

func _build_collision() -> void:
	var shape := CapsuleShape3D.new()
	shape.radius = CAPSULE_RADIUS
	shape.height = CAPSULE_HEIGHT
	_collision_shape = CollisionShape3D.new()
	_collision_shape.shape = shape
	# Capsule center at half-height so the feet rest at root-local y=0
	_collision_shape.position = Vector3(0, CAPSULE_HEIGHT / 2.0, 0)
	add_child(_collision_shape)


func _build_avatar() -> void:
	_avatar_root = Node3D.new()
	_avatar_root.name = "Avatar"
	add_child(_avatar_root)

	var shirt_color: Color = SHIRT_COLORS[randi() % SHIRT_COLORS.size()]

	# Legs
	var leg_mat := StandardMaterial3D.new()
	leg_mat.albedo_color = LEG_COLOR
	var legs := CSGBox3D.new()
	legs.size = Vector3(0.14, 0.20, 0.10)
	legs.position = Vector3(0, 0.10, 0)
	legs.material = leg_mat
	legs.name = "Legs"
	_avatar_root.add_child(legs)

	# Torso
	var shirt_mat := StandardMaterial3D.new()
	shirt_mat.albedo_color = shirt_color
	var torso := CSGBox3D.new()
	torso.size = Vector3(0.16, 0.18, 0.11)
	torso.position = Vector3(0, 0.30, 0)
	torso.material = shirt_mat
	torso.name = "Torso"
	_avatar_root.add_child(torso)

	# Head
	var skin_mat := StandardMaterial3D.new()
	skin_mat.albedo_color = SKIN_COLOR
	var head := CSGSphere3D.new()
	head.radius = 0.055
	head.radial_segments = 10
	head.rings = 5
	head.position = Vector3(0, 0.44, 0)
	head.material = skin_mat
	head.name = "Head"
	_avatar_root.add_child(head)

	_avatar_root.visible = false


func _build_cameras() -> void:
	# Yaw pivot at eye height; children inherit the yaw rotation.
	_yaw_pivot = Node3D.new()
	_yaw_pivot.name = "YawPivot"
	_yaw_pivot.position = Vector3(0, EYE_HEIGHT, 0)
	add_child(_yaw_pivot)

	# Pitch pivot — inherits yaw from parent, adds pitch.
	_pitch_pivot = Node3D.new()
	_pitch_pivot.name = "PitchPivot"
	_yaw_pivot.add_child(_pitch_pivot)

	# First-person camera — exactly at the pitch pivot, looks down local -Z.
	_fp_camera = Camera3D.new()
	_fp_camera.name = "FPCamera"
	_fp_camera.near = 0.02
	_fp_camera.far  = 400.0
	_fp_camera.fov  = 75.0
	_fp_camera.current = false
	_pitch_pivot.add_child(_fp_camera)

	# Third-person camera — sits behind (+Z local) and slightly above the pivot.
	# Child of pitch pivot so it orbits with look pitch.
	_tp_camera = Camera3D.new()
	_tp_camera.name = "TPCamera"
	_tp_camera.position = Vector3(0, 0.15, 1.2)   # behind and a touch up
	_tp_camera.near = 0.02
	_tp_camera.far  = 400.0
	_tp_camera.fov  = 70.0
	_tp_camera.current = false
	_pitch_pivot.add_child(_tp_camera)


# ═════════════════════════════════════════════════════════════════════════════
# VIEW / LOOK APPLICATION
# ═════════════════════════════════════════════════════════════════════════════

func _apply_view_mode() -> void:
	if _first_person:
		_fp_camera.current = true
		if _avatar_root:
			_avatar_root.visible = false
	else:
		_tp_camera.current = true
		if _avatar_root:
			_avatar_root.visible = true


func _apply_look() -> void:
	if _yaw_pivot:
		_yaw_pivot.rotation.y = _yaw
	if _pitch_pivot:
		_pitch_pivot.rotation.x = _pitch
