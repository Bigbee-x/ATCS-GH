extends Node3D
## Main controller for the ATCS-GH 3D Corridor Visualizer.
##
## Three-junction corridor along N6 Nsawam Road (J0, J1, J2).
## Identical to Main.gd but with corridor-specific camera and mode setup.
##
## Scene tree (expected child nodes):
##   WebSocketClient (Node)         — networking
##   IsometricCamera (Camera3D)     — viewpoint (wider for corridor)
##   Intersection (Node3D)          — CorridorBuilder: 3-junction geometry
##   VehicleManager (Node3D)        — vehicle pool rendering
##   PedestrianManager (Node3D)     — ambient walking pedestrians
##   UI (CanvasLayer → Control)     — HUD overlay

# ── Child node references ────────────────────────────────────────────────────
@onready var ws_client: WebSocketClient = $WebSocketClient
@onready var intersection: Node3D = $Intersection
@onready var vehicle_manager: Node3D = $VehicleManager
@onready var pedestrian_manager: Node3D = $PedestrianManager
@onready var audio_manager: Node = $AudioManager
@onready var ui: Control = $UI/UIRoot
@onready var camera: Camera3D = $IsometricCamera

# ── Camera state ─────────────────────────────────────────────────────────────
var _camera_default_position: Vector3
var _camera_default_rotation: Vector3
var _camera_default_size: float = 50.0  # Orthographic camera size
var _zoom_level: float = 1.0

const ZOOM_MIN: float = 0.3
const ZOOM_MAX: float = 4.0
const ZOOM_STEP: float = 0.08
const PAN_SPEED: float = 0.3

var _is_panning: bool = false
var _is_rotating: bool = false
var _pan_start: Vector2 = Vector2.ZERO
var _rotate_start: Vector2 = Vector2.ZERO

# Orbit rotation around the corridor center
var _orbit_yaw: float = 0.0      # Horizontal rotation (radians)
var _orbit_pitch: float = 0.0    # Vertical tilt offset (radians)
const ORBIT_SENSITIVITY: float = 0.005
const PITCH_MIN: float = -0.4    # Don't go below ground
const PITCH_MAX: float = 0.8     # Don't go too overhead

# Camera pivot — center of the corridor
var _camera_pivot: Vector3 = Vector3(0, 0, 18.0)  # Center on J1

# ── Packet counter ────────────────────────────────────────────────────────────
var _packets_received: int = 0
var _last_update_time: float = 0.0

# (removed unused _corridor_mode_set flag)


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	print("[CorridorMain] ATCS-GH Corridor Visualizer starting...")

	# Store default camera transform
	_camera_default_position = camera.position
	_camera_default_rotation = camera.rotation
	_camera_default_size = camera.size

	# ── Connect WebSocket signals ────────────────────────────────────────
	ws_client.state_updated.connect(_on_state_updated)
	ws_client.vehicle_updated.connect(_on_vehicle_updated)
	ws_client.sim_completed.connect(_on_sim_completed)
	ws_client.sim_restarted.connect(_on_sim_restarted)
	ws_client.connection_changed.connect(_on_connection_changed)

	# ── Connect UI signals ──────────────────────────────────────────────
	ui.override_requested.connect(_on_override_requested)
	ui.mode_switch_requested.connect(_on_mode_switch_requested)
	ui.emergency_spawn_requested.connect(_on_emergency_spawn_requested)
	ui.pedestrian_toggled.connect(_on_pedestrian_toggled)

	# ── Connect server mode-change signal ───────────────────────────────
	ws_client.mode_changed.connect(_on_mode_changed)

	# Enable corridor mode on subsystems
	vehicle_manager.set_corridor_mode(true)
	pedestrian_manager.set_corridor_mode(true)
	ui.set_corridor_mode(true)

	print("[CorridorMain] All signals connected. Corridor mode active.")
	print("[CorridorMain] Waiting for corridor_visualizer_server.py data...")


func _process(delta: float) -> void:
	_process_camera_keys(delta)


# ═════════════════════════════════════════════════════════════════════════════
# SIGNAL HANDLERS
# ═════════════════════════════════════════════════════════════════════════════

func _on_state_updated(data: Dictionary) -> void:
	_packets_received += 1
	_last_update_time = Time.get_ticks_msec() / 1000.0

	# Update each subsystem
	intersection.update_lights(data)
	intersection.update_lane_overlays(data)
	vehicle_manager.update_vehicles(data)
	audio_manager.update_audio(data)
	ui.update_display(data)

	# Update SUMO-driven crossing pedestrians
	var ped_list: Array = data.get("pedestrians", [])
	if ped_list.size() > 0:
		pedestrian_manager.update_crossing_pedestrians(ped_list)


func _on_vehicle_updated(data: Dictionary) -> void:
	vehicle_manager.update_vehicles(data)

	var ped_list: Array = data.get("pedestrians", [])
	if ped_list.size() > 0:
		pedestrian_manager.update_crossing_pedestrians(ped_list)


func _on_sim_completed(data: Dictionary) -> void:
	var avg_wait: float = data.get("corridor_avg_wait", data.get("avg_wait", 0.0))
	print("[CorridorMain] Simulation complete — %d vehicles, avg wait %.1fs" % [
		data.get("total_arrived", 0), avg_wait])
	ui.show_completion(data)


func _on_sim_restarted(data: Dictionary) -> void:
	var run: int = data.get("run", 0)
	print("[CorridorMain] Simulation restarting (run #%d)..." % run)
	vehicle_manager.clear_all()
	pedestrian_manager.respawn()
	audio_manager.reset_audio()
	ui.reset_display()
	_packets_received = 0


func _on_connection_changed(connected: bool) -> void:
	ui.set_connection_status(connected)
	if connected:
		print("[CorridorMain] Server connected — receiving corridor data")
	else:
		print("[CorridorMain] Server disconnected — waiting for reconnect...")


func _on_override_requested(approach: String) -> void:
	print("[CorridorMain] Manual override: force green for %s" % approach)
	ws_client.send_override(approach)


func _on_emergency_spawn_requested(approach: String) -> void:
	## Forward emergency vehicle deploy from UI to WebSocket server.
	print("[CorridorMain] Deploy ambulance from %s" % approach)
	ws_client.send_spawn_emergency(approach)


func _on_pedestrian_toggled(enabled: bool) -> void:
	## Toggle pedestrians on/off from UI button.
	pedestrian_manager.set_pedestrians_enabled(enabled)
	print("[CorridorMain] Pedestrians %s" % ("enabled" if enabled else "disabled"))


func _on_mode_switch_requested(target_mode: String) -> void:
	print("[CorridorMain] Mode switch requested: %s" % target_mode)
	ws_client.send_mode_switch(target_mode)


func _on_mode_changed(data: Dictionary) -> void:
	var new_mode: String = data.get("control_mode", "ai")
	print("[CorridorMain] Server confirmed mode: %s" % new_mode.to_upper())
	ui.update_control_mode(new_mode)


# ═════════════════════════════════════════════════════════════════════════════
# CAMERA CONTROLS
# ═════════════════════════════════════════════════════════════════════════════
#
# Mac trackpad + mouse compatible:
#   Pinch / Scroll       — Zoom in/out  (trackpad gesture or mouse wheel)
#   Click + drag         — Pan (move camera laterally)
#   Cmd + click + drag   — Orbit (rotate camera around corridor)
#   Right-click + drag   — Orbit (mouse alternative)
#   Middle-click + drag  — Pan (mouse alternative)
#   +/- keys             — Zoom in/out via keyboard
#   WASD / Arrow keys    — Pan via keyboard
#   Q / E               — Rotate left / right
#   R key or Home        — Reset camera to default

func _unhandled_input(event: InputEvent) -> void:
	# ── Escape: return to launcher menu ──────────────────────────────────
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().change_scene_to_file("res://scenes/LauncherMenu.tscn")
		return

	# ── Trackpad pinch-to-zoom ─────────────────────────────────────────
	if event is InputEventMagnifyGesture:
		# factor > 1.0 = pinch out (zoom in), < 1.0 = pinch in (zoom out)
		var zoom_delta: float = (1.0 - event.factor) * 0.5
		_zoom_level = clampf(_zoom_level + zoom_delta, ZOOM_MIN, ZOOM_MAX)
		_apply_camera()
		get_viewport().set_input_as_handled()
		return

	# ── Trackpad two-finger scroll → zoom ──────────────────────────────
	if event is InputEventPanGesture:
		_zoom_level = clampf(_zoom_level + event.delta.y * 0.02, ZOOM_MIN, ZOOM_MAX)
		_apply_camera()
		get_viewport().set_input_as_handled()
		return

	# ── Mouse wheel zoom ────────────────────────────────────────────────
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_level = clampf(_zoom_level - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			_apply_camera()
			get_viewport().set_input_as_handled()

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_level = clampf(_zoom_level + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			_apply_camera()
			get_viewport().set_input_as_handled()

		# Left-click: pan (trackpad-friendly) or orbit with Cmd held
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and event.meta_pressed:
				# Cmd + click = orbit
				_is_rotating = true
				_is_panning = false
				_rotate_start = event.position
			elif event.pressed:
				# Plain click = pan
				_is_panning = true
				_is_rotating = false
				_pan_start = event.position
			else:
				# Released
				_is_panning = false
				_is_rotating = false
			get_viewport().set_input_as_handled()

		# Middle-click: pan (mouse users)
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_is_panning = event.pressed
			_pan_start = event.position
			get_viewport().set_input_as_handled()

		# Right-click: orbit (mouse users)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_is_rotating = event.pressed
			_rotate_start = event.position
			get_viewport().set_input_as_handled()

	# ── Mouse motion: pan or orbit ─────────────────────────────────────
	elif event is InputEventMouseMotion:
		if _is_panning:
			var delta: Vector2 = event.position - _pan_start
			_pan_start = event.position
			# Pan in camera-local XZ plane
			var right: Vector3 = camera.global_transform.basis.x.normalized()
			var forward: Vector3 = Vector3(-right.z, 0, right.x).normalized()
			_camera_pivot += (-right * delta.x + forward * delta.y) * PAN_SPEED * _zoom_level * 0.005
			_apply_camera()
			get_viewport().set_input_as_handled()

		elif _is_rotating:
			var delta: Vector2 = event.position - _rotate_start
			_rotate_start = event.position
			_orbit_yaw -= delta.x * ORBIT_SENSITIVITY
			_orbit_pitch = clampf(_orbit_pitch + delta.y * ORBIT_SENSITIVITY, PITCH_MIN, PITCH_MAX)
			_apply_camera()
			get_viewport().set_input_as_handled()

	# ── Reset camera ───────────────────────────────────────────────────
	if event.is_action_pressed("reset_camera"):
		_reset_camera()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_HOME:
		_reset_camera()
		get_viewport().set_input_as_handled()


func _process_camera_keys(delta: float) -> void:
	## Handle WASD/arrow key camera movement each frame.
	var move := Vector3.ZERO
	var rotate_dir: float = 0.0
	var zoom_dir: float = 0.0

	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		move.z -= 1.0
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		move.z += 1.0
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		move.x += 1.0
	if Input.is_key_pressed(KEY_Q):
		rotate_dir -= 1.0
	if Input.is_key_pressed(KEY_E):
		rotate_dir += 1.0
	# +/= key = zoom in, -/_ key = zoom out (trackpad-friendly)
	if Input.is_key_pressed(KEY_EQUAL) or Input.is_key_pressed(KEY_KP_ADD):
		zoom_dir -= 1.0  # Decrease zoom_level = zoom in
	if Input.is_key_pressed(KEY_MINUS) or Input.is_key_pressed(KEY_KP_SUBTRACT):
		zoom_dir += 1.0  # Increase zoom_level = zoom out

	if move.length() > 0.01:
		var right: Vector3 = camera.global_transform.basis.x.normalized()
		var forward: Vector3 = Vector3(-right.z, 0, right.x).normalized()
		_camera_pivot += (right * move.x + forward * move.z) * 15.0 * _zoom_level * delta
		_apply_camera()

	if absf(rotate_dir) > 0.01:
		_orbit_yaw += rotate_dir * 1.5 * delta
		_apply_camera()

	if absf(zoom_dir) > 0.01:
		_zoom_level = clampf(_zoom_level + zoom_dir * 1.0 * delta, ZOOM_MIN, ZOOM_MAX)
		_apply_camera()


func _apply_camera() -> void:
	## Recalculate camera position from orbit parameters.
	## Uses orthographic projection — zoom is via camera.size, not distance.
	var base_dist: float = _camera_default_position.length()

	# Default orbit angles from the initial camera position
	var base_dir: Vector3 = _camera_default_position.normalized()
	var base_yaw: float = atan2(base_dir.x, base_dir.z)
	var base_pitch: float = asin(base_dir.y)

	var yaw: float = base_yaw + _orbit_yaw
	var pitch: float = clampf(base_pitch + _orbit_pitch, 0.15, 1.4)

	# Keep camera at constant distance (orthographic size handles zoom)
	var offset := Vector3(
		base_dist * cos(pitch) * sin(yaw),
		base_dist * sin(pitch),
		base_dist * cos(pitch) * cos(yaw)
	)

	camera.position = _camera_pivot + offset
	camera.look_at(_camera_pivot, Vector3.UP)

	# Orthographic zoom — larger size = more scene visible (zoomed out)
	camera.size = _camera_default_size * _zoom_level


func _reset_camera() -> void:
	_camera_pivot = Vector3(0, 0, 18.0)  # Center on J1
	_orbit_yaw = 0.0
	_orbit_pitch = 0.0
	_zoom_level = 1.0
	camera.size = _camera_default_size
	_apply_camera()
	print("[Camera] Reset to default position")
