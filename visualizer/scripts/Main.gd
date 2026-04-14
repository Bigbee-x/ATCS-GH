extends Node3D
## Main controller for the ATCS-GH 3D Visualizer (Achimota/Neoplan Junction).
##
## Responsibilities:
##   1. Wire WebSocket client signals to Intersection, VehicleManager, and UI
##   2. Handle camera controls (zoom, pan, reset)
##   3. Forward manual override requests from UI → WebSocket → Python server
##
## Scene tree (expected child nodes):
##   WebSocketClient (Node)        — networking
##   IsometricCamera (Camera3D)    — viewpoint
##   Intersection (Node3D)         — 3D road geometry + traffic lights
##   VehicleManager (Node3D)       — vehicle pool rendering
##   PedestrianManager (Node3D)   — ambient walking pedestrians
##   UI (CanvasLayer → Control)    — HUD overlay

# ── Child node references ────────────────────────────────────────────────────
@onready var ws_client: WebSocketClient = $WebSocketClient
@onready var intersection: Node3D = $Intersection
@onready var vehicle_manager: Node3D = $VehicleManager
@onready var pedestrian_manager: Node3D = $PedestrianManager
@onready var audio_manager: Node = $AudioManager
@onready var ui: Control = $UI/UIRoot
@onready var camera: Camera3D = $IsometricCamera
@onready var tod_manager: Node = $TimeOfDayManager

# ── Camera state ─────────────────────────────────────────────────────────────
var _camera_default_position: Vector3
var _camera_default_rotation: Vector3
var _camera_default_size: float = 32.0
var _zoom_level: float = 1.0

const ZOOM_MIN: float = 0.3
const ZOOM_MAX: float = 3.0
const ZOOM_STEP: float = 0.1
const PAN_SPEED: float = 0.2

var _is_panning: bool = false
var _is_rotating: bool = false
var _pan_start: Vector2 = Vector2.ZERO
var _rotate_start: Vector2 = Vector2.ZERO

# Orbit camera system
var _orbit_yaw: float = 0.0
var _orbit_pitch: float = 0.0
const ORBIT_SENSITIVITY: float = 0.005
const PITCH_MIN: float = -0.4
const PITCH_MAX: float = 0.8
var _camera_pivot: Vector3 = Vector3.ZERO

# ── Packet counter (for debug/monitoring) ────────────────────────────────────
var _packets_received: int = 0
var _last_update_time: float = 0.0
var _corridor_switch_pending: bool = false


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	print("[Main] ATCS-GH 3D Visualizer starting...")

	# Store default camera transform for reset
	_camera_default_position = camera.position
	_camera_default_rotation = camera.rotation
	_camera_default_size = camera.size

	# ── Connect WebSocket signals to scene subsystems ────────────────────
	ws_client.state_updated.connect(_on_state_updated)
	ws_client.vehicle_updated.connect(_on_vehicle_updated)
	ws_client.sim_completed.connect(_on_sim_completed)
	ws_client.sim_restarted.connect(_on_sim_restarted)
	ws_client.connection_changed.connect(_on_connection_changed)

	# ── Connect UI manual override signal ────────────────────────────────
	ui.override_requested.connect(_on_override_requested)

	# ── Connect UI emergency deploy signal ───────────────────────────────
	ui.emergency_spawn_requested.connect(_on_emergency_spawn_requested)

	# ── Connect UI mode switch signal ────────────────────────────────────
	ui.mode_switch_requested.connect(_on_mode_switch_requested)
	ws_client.mode_changed.connect(_on_mode_changed)

	# ── Connect UI pedestrian toggle signal ──────────────────────────────
	ui.pedestrian_toggled.connect(_on_pedestrian_toggled)

	# ── Wire up TimeOfDayManager ─────────────────────────────────────────
	tod_manager.sun = $DirectionalLight3D
	tod_manager.world_env = $WorldEnvironment
	tod_manager.time_changed.connect(_on_time_changed)
	tod_manager.night_mode_changed.connect(_on_night_mode_changed)
	ui.time_of_day_changed.connect(_on_ui_time_changed)
	ui.tod_mode_changed.connect(_on_ui_tod_mode_changed)

	print("[Main] All signals connected. Waiting for server data...")


# ═════════════════════════════════════════════════════════════════════════════
# SIGNAL HANDLERS — WebSocket → Scene
# ═════════════════════════════════════════════════════════════════════════════

func _on_state_updated(data: Dictionary) -> void:
	## Route state update data to all subsystems.
	_packets_received += 1
	_last_update_time = Time.get_ticks_msec() / 1000.0

	# Detect wrong server: corridor data arriving in single-junction mode
	if data.has("junctions"):
		if not _corridor_switch_pending:
			_corridor_switch_pending = true
			push_warning("[Main] Receiving corridor data in single-junction mode.")
			ui.show_server_mismatch("corridor")
		return

	# Update each subsystem with the full data packet
	intersection.update_lights(data)
	intersection.update_lane_overlays(data)
	vehicle_manager.update_vehicles(data)
	audio_manager.update_audio(data)
	ui.update_display(data)

	# Feed sim time to day/night cycle if in sim-linked mode
	var sim_time: float = data.get("sim_time", -1.0)
	if sim_time >= 0.0:
		tod_manager.update_from_sim_time(sim_time)

	# Update SUMO-driven crossing pedestrians
	var ped_list: Array = data.get("pedestrians", [])
	if ped_list.size() > 0:
		pedestrian_manager.update_crossing_pedestrians(ped_list)


func _on_vehicle_updated(data: Dictionary) -> void:
	## Handle per-second vehicle position updates (smooth animation).
	# Block corridor data — wrong coordinate mapping would scatter vehicles
	if _corridor_switch_pending:
		return

	vehicle_manager.update_vehicles(data)

	# Update SUMO-driven crossing pedestrians (sent every sim-second)
	var ped_list: Array = data.get("pedestrians", [])
	if ped_list.size() > 0:
		pedestrian_manager.update_crossing_pedestrians(ped_list)


func _on_sim_completed(data: Dictionary) -> void:
	## Handle simulation run completion.
	print("[Main] Simulation complete — %d vehicles" % data.get("total_arrived", 0))
	ui.show_completion(data)


func _on_sim_restarted(data: Dictionary) -> void:
	## Handle simulation restart — clear all visual state.
	var run: int = data.get("run", 0)
	print("[Main] Simulation restarting (run #%d)..." % run)
	vehicle_manager.clear_all()
	pedestrian_manager.respawn()
	audio_manager.reset_audio()
	ui.reset_display()
	_packets_received = 0


func _on_connection_changed(connected: bool) -> void:
	## Handle WebSocket connection status changes.
	ui.set_connection_status(connected)
	if connected:
		print("[Main] Server connected — receiving live data")
	else:
		print("[Main] Server disconnected — waiting for reconnect...")


func _on_override_requested(approach: String) -> void:
	## Forward manual override from UI to WebSocket server.
	print("[Main] Manual override: force green for %s" % approach)
	ws_client.send_override(approach)


func _on_emergency_spawn_requested(approach: String) -> void:
	## Forward emergency vehicle deploy from UI to WebSocket server.
	print("[Main] Deploy ambulance from %s" % approach)
	ws_client.send_spawn_emergency(approach)


func _on_mode_switch_requested(target_mode: String) -> void:
	## Forward mode switch from UI to WebSocket server.
	print("[Main] Mode switch requested: %s" % target_mode)
	ws_client.send_mode_switch(target_mode)


func _on_mode_changed(data: Dictionary) -> void:
	## Handle server confirming mode change.
	var new_mode: String = data.get("control_mode", "ai")
	print("[Main] Server confirmed mode: %s" % new_mode.to_upper())
	ui.update_control_mode(new_mode)


func _on_pedestrian_toggled(enabled: bool) -> void:
	## Toggle pedestrians on/off from UI button.
	pedestrian_manager.set_pedestrians_enabled(enabled)
	print("[Main] Pedestrians %s" % ("enabled" if enabled else "disabled"))


func _on_time_changed(hour: float) -> void:
	## Update UI with current time-of-day.
	ui.update_time_display(hour)


func _on_night_mode_changed(is_night: bool) -> void:
	## Handle night mode transitions (headlights, glow intensity).
	var vm := vehicle_manager as Node3D
	if vm.has_method("set_night_mode"):
		vm.set_night_mode(is_night)
	print("[Main] Night mode: %s" % ("ON" if is_night else "OFF"))


func _on_ui_time_changed(hour: float) -> void:
	## User adjusted time via UI slider.
	tod_manager.set_time(hour)


func _on_ui_tod_mode_changed(mode_idx: int) -> void:
	## User changed time-of-day mode (0=Manual, 1=Auto, 2=SimLinked).
	tod_manager.set_mode(mode_idx)


# ═════════════════════════════════════════════════════════════════════════════
# CAMERA CONTROLS
# ═════════════════════════════════════════════════════════════════════════════
# Mac trackpad + mouse compatible:
#   Pinch / Scroll       — Zoom in/out
#   Click + drag         — Pan
#   Cmd + click + drag   — Orbit rotate
#   Right-click + drag   — Orbit rotate (mouse)
#   Middle-click + drag  — Pan (mouse)
#   WASD / Arrow keys    — Pan
#   Q / E                — Rotate left/right
#   +/- keys             — Zoom keyboard
#   R / Home             — Reset camera

func _process(delta: float) -> void:
	_process_camera_keys(delta)


func _unhandled_input(event: InputEvent) -> void:
	# ── Escape: return to launcher menu ──────────────────────────────────
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		get_tree().change_scene_to_file("res://scenes/LauncherMenu.tscn")
		return

	# ── R key: reset camera ─────────────────────────────────────────────
	if event.is_action_pressed("reset_camera"):
		_reset_camera()
		get_viewport().set_input_as_handled()
		return

	# ── Trackpad pinch-to-zoom ───────────────────────────────────────────
	if event is InputEventMagnifyGesture:
		var zoom_delta: float = (1.0 - event.factor) * 0.5
		_zoom_level = clampf(_zoom_level + zoom_delta, ZOOM_MIN, ZOOM_MAX)
		_apply_camera()
		get_viewport().set_input_as_handled()
		return

	# ── Trackpad pan gesture (two-finger scroll) ────────────────────────
	if event is InputEventPanGesture:
		_zoom_level = clampf(_zoom_level + event.delta.y * 0.02, ZOOM_MIN, ZOOM_MAX)
		_apply_camera()
		get_viewport().set_input_as_handled()
		return

	# ── Mouse buttons ────────────────────────────────────────────────────
	if event is InputEventMouseButton:
		# Scroll wheel zoom
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_level = clampf(_zoom_level - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			_apply_camera()
			get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_level = clampf(_zoom_level + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			_apply_camera()
			get_viewport().set_input_as_handled()

		# Left-click: Cmd+click = orbit, plain click = pan
		elif event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed and event.meta_pressed:
				_is_rotating = true
				_is_panning = false
				_rotate_start = event.position
			elif event.pressed:
				_is_panning = true
				_is_rotating = false
				_pan_start = event.position
			else:
				_is_panning = false
				_is_rotating = false
			get_viewport().set_input_as_handled()

		# Middle-click: pan
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_is_panning = event.pressed
			_pan_start = event.position
			get_viewport().set_input_as_handled()

		# Right-click: orbit rotate
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_is_rotating = event.pressed
			_rotate_start = event.position
			get_viewport().set_input_as_handled()

	# ── Mouse motion: pan or orbit ───────────────────────────────────────
	elif event is InputEventMouseMotion:
		if _is_panning:
			var delta: Vector2 = event.position - _pan_start
			_pan_start = event.position
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


func _process_camera_keys(delta: float) -> void:
	## Handle continuous keyboard camera controls each frame.
	var move := Vector3.ZERO
	var rotate_dir: float = 0.0
	var zoom_dir: float = 0.0

	# Pan: WASD / Arrow keys
	if Input.is_action_pressed("ui_up") or Input.is_key_pressed(KEY_W):
		move.z -= 1.0
	if Input.is_action_pressed("ui_down") or Input.is_key_pressed(KEY_S):
		move.z += 1.0
	if Input.is_action_pressed("ui_left") or Input.is_key_pressed(KEY_A):
		move.x -= 1.0
	if Input.is_action_pressed("ui_right") or Input.is_key_pressed(KEY_D):
		move.x += 1.0

	# Rotate: Q / E
	if Input.is_key_pressed(KEY_Q):
		rotate_dir -= 1.0
	if Input.is_key_pressed(KEY_E):
		rotate_dir += 1.0

	# Zoom: +/- keys
	if Input.is_key_pressed(KEY_EQUAL) or Input.is_key_pressed(KEY_KP_ADD):
		zoom_dir -= 1.0
	if Input.is_key_pressed(KEY_MINUS) or Input.is_key_pressed(KEY_KP_SUBTRACT):
		zoom_dir += 1.0

	# Apply pan
	if move.length() > 0.01:
		var right: Vector3 = camera.global_transform.basis.x.normalized()
		var forward: Vector3 = Vector3(-right.z, 0, right.x).normalized()
		_camera_pivot += (right * move.x + forward * move.z) * 15.0 * _zoom_level * delta
		_apply_camera()

	# Apply rotation
	if absf(rotate_dir) > 0.01:
		_orbit_yaw += rotate_dir * 1.5 * delta
		_apply_camera()

	# Apply zoom
	if absf(zoom_dir) > 0.01:
		_zoom_level = clampf(_zoom_level + zoom_dir * 1.0 * delta, ZOOM_MIN, ZOOM_MAX)
		_apply_camera()


func _apply_camera() -> void:
	## Recalculate camera position from orbit parameters.
	var base_dist: float = _camera_default_position.length()

	# Derive base angles from the initial camera position
	var base_dir: Vector3 = _camera_default_position.normalized()
	var base_yaw: float = atan2(base_dir.x, base_dir.z)
	var base_pitch: float = asin(base_dir.y)

	var yaw: float = base_yaw + _orbit_yaw
	var pitch: float = clampf(base_pitch + _orbit_pitch, 0.15, 1.4)

	# Keep camera at constant distance; orthographic size handles zoom
	var offset := Vector3(
		base_dist * cos(pitch) * sin(yaw),
		base_dist * sin(pitch),
		base_dist * cos(pitch) * cos(yaw)
	)

	camera.position = _camera_pivot + offset
	camera.look_at(_camera_pivot, Vector3.UP)

	# Orthographic zoom — larger size = more scene visible
	camera.size = _camera_default_size * _zoom_level


func _reset_camera() -> void:
	## Reset camera to default position, rotation, and zoom.
	_camera_pivot = Vector3.ZERO
	_orbit_yaw = 0.0
	_orbit_pitch = 0.0
	_zoom_level = 1.0
	camera.size = _camera_default_size
	_apply_camera()
	print("[Camera] Reset to default position")
