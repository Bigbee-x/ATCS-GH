extends Node3D
## Main controller for the ATCS-GH 3D Visualizer.
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
##   UI (CanvasLayer → Control)    — HUD overlay

# ── Child node references ────────────────────────────────────────────────────
@onready var ws_client: WebSocketClient = $WebSocketClient
@onready var intersection: Node3D = $Intersection
@onready var vehicle_manager: Node3D = $VehicleManager
@onready var audio_manager: Node = $AudioManager
@onready var ui: Control = $UI/UIRoot
@onready var camera: Camera3D = $IsometricCamera

# ── Camera state ─────────────────────────────────────────────────────────────
var _camera_default_position: Vector3
var _camera_default_rotation: Vector3
var _zoom_level: float = 1.0

const ZOOM_MIN: float = 0.4
const ZOOM_MAX: float = 3.0
const ZOOM_STEP: float = 0.1
const PAN_SPEED: float = 0.15

var _is_panning: bool = false
var _pan_start: Vector2 = Vector2.ZERO

# ── Packet counter (for debug/monitoring) ────────────────────────────────────
var _packets_received: int = 0
var _last_update_time: float = 0.0


# ═════════════════════════════════════════════════════════════════════════════
# LIFECYCLE
# ═════════════════════════════════════════════════════════════════════════════

func _ready() -> void:
	print("[Main] ATCS-GH 3D Visualizer starting...")

	# Store default camera transform for reset
	_camera_default_position = camera.position
	_camera_default_rotation = camera.rotation

	# ── Connect WebSocket signals to scene subsystems ────────────────────
	ws_client.state_updated.connect(_on_state_updated)
	ws_client.vehicle_updated.connect(_on_vehicle_updated)
	ws_client.sim_completed.connect(_on_sim_completed)
	ws_client.sim_restarted.connect(_on_sim_restarted)
	ws_client.connection_changed.connect(_on_connection_changed)

	# ── Connect UI manual override signal ────────────────────────────────
	ui.override_requested.connect(_on_override_requested)

	print("[Main] All signals connected. Waiting for server data...")


# ═════════════════════════════════════════════════════════════════════════════
# SIGNAL HANDLERS — WebSocket → Scene
# ═════════════════════════════════════════════════════════════════════════════

func _on_state_updated(data: Dictionary) -> void:
	## Route state update data to all subsystems.
	_packets_received += 1
	_last_update_time = Time.get_ticks_msec() / 1000.0

	# Update each subsystem with the full data packet
	intersection.update_lights(data)
	intersection.update_lane_overlays(data)
	vehicle_manager.update_vehicles(data)
	audio_manager.update_audio(data)
	ui.update_display(data)


func _on_vehicle_updated(data: Dictionary) -> void:
	## Handle per-second vehicle position updates (smooth animation).
	vehicle_manager.update_vehicles(data)


func _on_sim_completed(data: Dictionary) -> void:
	## Handle simulation run completion.
	print("[Main] Simulation complete — %d vehicles" % data.get("total_arrived", 0))
	ui.show_completion(data)


func _on_sim_restarted(data: Dictionary) -> void:
	## Handle simulation restart — clear all visual state.
	var run: int = data.get("run", 0)
	print("[Main] Simulation restarting (run #%d)..." % run)
	vehicle_manager.clear_all()
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


# ═════════════════════════════════════════════════════════════════════════════
# CAMERA CONTROLS
# ═════════════════════════════════════════════════════════════════════════════

func _unhandled_input(event: InputEvent) -> void:
	# ── Mouse wheel: zoom ────────────────────────────────────────────────
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_level = clampf(_zoom_level - ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			_apply_zoom()
			get_viewport().set_input_as_handled()

		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_level = clampf(_zoom_level + ZOOM_STEP, ZOOM_MIN, ZOOM_MAX)
			_apply_zoom()
			get_viewport().set_input_as_handled()

		# ── Middle mouse button: start/stop panning ──────────────────────
		elif event.button_index == MOUSE_BUTTON_MIDDLE:
			_is_panning = event.pressed
			_pan_start = event.position
			get_viewport().set_input_as_handled()

	# ── Mouse motion: pan while middle button held ───────────────────────
	elif event is InputEventMouseMotion and _is_panning:
		var delta: Vector2 = event.position - _pan_start
		_pan_start = event.position
		# Pan in world XZ plane (camera-relative)
		camera.position += Vector3(-delta.x, 0, -delta.y) * PAN_SPEED * _zoom_level * 0.01
		get_viewport().set_input_as_handled()

	# ── R key: reset camera to default position ─────────────────────────
	if event.is_action_pressed("reset_camera"):
		_reset_camera()
		get_viewport().set_input_as_handled()


func _apply_zoom() -> void:
	## Smoothly adjust camera position based on zoom level.
	# Scale the camera's distance from origin proportionally
	camera.position = _camera_default_position * _zoom_level


func _reset_camera() -> void:
	## Reset camera to default position, rotation, and zoom.
	camera.position = _camera_default_position
	camera.rotation = _camera_default_rotation
	_zoom_level = 1.0
	print("[Camera] Reset to default position")
