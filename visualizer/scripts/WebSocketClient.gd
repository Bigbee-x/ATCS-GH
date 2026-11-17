extends Node
class_name WebSocketClient
## WebSocket client for the TrafIQ visualizer server.
##
## Connects to the Python WebSocket server, receives JSON state packets,
## and emits signals that other nodes (Intersection, VehicleManager, UI)
## listen to for live updates.
##
## Handles:
##   - Automatic reconnection on dropped connections
##   - Graceful handling of server not yet running (startup order independence)
##   - JSON parsing with error recovery
##   - Sending manual override commands back to the server
##
## Godot 4.2+ WebSocket API:
##   Uses WebSocketPeer (not the old WebSocketClient class).
##   Must call poll() manually in _process(), detect state transitions,
##   and read packets with get_packet().

# ── Signals ──────────────────────────────────────────────────────────────────
## Emitted when a state_update packet arrives from the server
signal state_updated(data: Dictionary)
## Emitted for per-second vehicle position updates (smooth animation)
signal vehicle_updated(data: Dictionary)
## Emitted when the simulation run finishes (sim_complete)
signal sim_completed(data: Dictionary)
## Emitted when the server restarts a simulation run
signal sim_restarted(data: Dictionary)
## Emitted when simulation data is received on a connection (false = lost).
signal connection_changed(is_connected: bool)
## Emitted when the server confirms a control mode change (ai/baseline)
signal mode_changed(data: Dictionary)

# ── Configuration ────────────────────────────────────────────────────────────
## WebSocket server URL (Python visualizer_server.py)
@export var server_url: String = "ws://localhost:8765"
## Seconds to wait before retrying after a failed connection
@export var reconnect_delay: float = 3.0
## Maximum reconnect attempts before giving up (-1 = infinite)
@export var max_reconnect_attempts: int = -1
## Offline art previews can instantiate the real scene without opening sockets.
@export var auto_connect: bool = true
## Disable when an external traffic server owns the default endpoint.
@export var auto_start_server: bool = true

# Full corridor snapshots include every vehicle, pedestrian and live detector.
# The default 64 KiB receive buffer closes healthy connections with code 1009
# once traffic builds up. Leave room for large snapshots AND a short backlog
# while the renderer is busy. Keep the allocation bounded on every reconnect.
const RECEIVE_BUFFER_BYTES: int = 16 * 1024 * 1024
const MAX_QUEUED_PACKETS: int = 256

static func create_traffic_socket() -> WebSocketPeer:
	var peer := WebSocketPeer.new()
	peer.inbound_buffer_size = RECEIVE_BUFFER_BYTES
	peer.max_queued_packets = MAX_QUEUED_PACKETS
	return peer

# ── Internal state ───────────────────────────────────────────────────────────
var _socket: WebSocketPeer = create_traffic_socket()
var _is_connected: bool = false
var _suspended: bool = false
var _was_ever_connected: bool = false
var _reconnect_timer: float = 0.0
var _reconnect_attempts: int = 0
var _last_state: WebSocketPeer.State = WebSocketPeer.STATE_CLOSED
var _last_packet_time: float = 0.0  # Time of last received packet

# ── Lifecycle ────────────────────────────────────────────────────────────────

func _ready() -> void:
	print("[WS] WebSocket client initialising...")
	print("[WS] Target server: %s" % server_url)
	if auto_connect:
		var manager := get_node_or_null("/root/ServerManager")
		if auto_start_server and manager and server_url in ["ws://localhost:8765", "ws://127.0.0.1:8765", manager.get_websocket_url()]:
			# Parent scene wires the selected managed port after startup.
			_suspended = true
		else:
			_attempt_connection()


func _process(delta: float) -> void:
	if not auto_connect or _suspended:
		return
	# Poll the socket to process incoming data
	_socket.poll()
	var state: WebSocketPeer.State = _socket.get_ready_state()

	match state:
		WebSocketPeer.STATE_OPEN:
			_handle_open_state()

		WebSocketPeer.STATE_CONNECTING:
			pass  # Wait for handshake to complete

		WebSocketPeer.STATE_CLOSING:
			pass  # Wait for close to complete

		WebSocketPeer.STATE_CLOSED:
			_handle_closed_state(delta)

	_last_state = state


func _handle_open_state() -> void:
	## Process packets while connection is open.
	# Read all available packets (there may be multiple queued)
	while _socket.get_available_packet_count() > 0:
		var raw_data: PackedByteArray = _socket.get_packet()
		var text: String = raw_data.get_string_from_utf8()
		_last_packet_time = Time.get_ticks_msec() / 1000.0
		_parse_and_dispatch(text)


func _handle_closed_state(delta: float) -> void:
	## Handle disconnection and auto-reconnect.
	if _last_state != WebSocketPeer.STATE_CLOSED:
		print("[WS] Disconnected (code=%d, reason='%s')" % [
			_socket.get_close_code(), _socket.get_close_reason()])
	if _is_connected:
		# We just lost the connection
		_is_connected = false
		connection_changed.emit(false)
		_reconnect_timer = reconnect_delay

	# Auto-reconnect with delay
	_reconnect_timer -= delta
	if _reconnect_timer <= 0.0:
		if max_reconnect_attempts >= 0 and _reconnect_attempts >= max_reconnect_attempts:
			# Give up after max attempts
			if _reconnect_attempts == max_reconnect_attempts:
				print("[WS] Max reconnect attempts reached. Stopping.")
				_reconnect_attempts += 1  # Prevent repeated prints
			return

		_attempt_connection()


# ── Connection management ────────────────────────────────────────────────────

func _attempt_connection() -> void:
	## Try to connect to the WebSocket server.
	_reconnect_attempts += 1
	_reconnect_timer = reconnect_delay

	if _reconnect_attempts > 1:
		print("[WS] Reconnecting (attempt %d)..." % _reconnect_attempts)
	else:
		print("[WS] Connecting to %s..." % server_url)

	# Create a fresh socket for each connection attempt
	# (WebSocketPeer cannot be reused after close in Godot 4)
	_socket = create_traffic_socket()
	_last_packet_time = 0.0
	var err: int = _socket.connect_to_url(server_url)
	if err != OK:
		push_warning("[WS] connect_to_url() failed with error %d" % err)


# ── Packet parsing ───────────────────────────────────────────────────────────

func _parse_and_dispatch(text: String) -> void:
	## Parse a JSON packet and emit the appropriate signal.
	var json := JSON.new()
	var err: int = json.parse(text)
	if err != OK:
		push_warning("[WS] JSON parse error (line %d): %s" % [
			json.get_error_line(), json.get_error_message()])
		return

	if not json.data is Dictionary:
		push_warning("[WS] Received non-dict JSON, ignoring")
		return

	var data: Dictionary = json.data
	var packet_type: String = data.get("type", "")

	match packet_type:
		"state_update":
			_mark_traffic_connected()
			state_updated.emit(data)
		"vehicle_update":
			_mark_traffic_connected()
			vehicle_updated.emit(data)
		"sim_complete":
			sim_completed.emit(data)
		"sim_restart":
			sim_restarted.emit(data)
		"mode_changed":
			mode_changed.emit(data)
		_:
			push_warning("[WS] Unknown packet type: '%s'" % packet_type)


func _mark_traffic_connected() -> void:
	# A successful handshake (or a mode_changed acknowledgement) doesn't prove
	# the traffic stream fits in the receive buffer. Report live only once an
	# actual simulation snapshot has been decoded on this connection.
	if not _is_connected:
		_is_connected = true
		_was_ever_connected = true
		_reconnect_attempts = 0
		print("[WS] Connected — receiving live traffic")
		connection_changed.emit(true)


# ── Public API ───────────────────────────────────────────────────────────────

func send_override(approach: String, junction: String = "J0") -> void:
	## Send a manual override command to the Python server.
	## approach: One of "north", "south", "east", "west"
	if not _is_connected:
		push_warning("[WS] Cannot send override — not connected")
		return

	var msg: String = JSON.stringify({
		"action": "force_green",
		"approach": approach,
		"junction": junction,
	})
	_socket.send_text(msg)
	print("[WS] Sent override: force green for %s" % approach)


func send_mode_switch(target_mode: String) -> void:
	## Switch traffic control mode on the server.
	## target_mode: "ai" for TrafIQ (DQN adaptive), "baseline" for fixed timer
	if not _is_connected:
		push_warning("[WS] Cannot switch mode — not connected")
		return

	var msg: String = JSON.stringify({
		"action": "switch_mode",
		"mode": target_mode,
	})
	_socket.send_text(msg)
	print("[WS] Sent mode switch: %s" % target_mode)


func is_connected_to_server() -> bool:
	## Returns true if currently connected to the Python server.
	return _is_connected


func get_seconds_since_last_packet() -> float:
	## Returns seconds since the last packet was received. Useful for stale data detection.
	if _last_packet_time <= 0.0:
		return -1.0  # Never received a packet
	return (Time.get_ticks_msec() / 1000.0) - _last_packet_time


func suspend_connection() -> void:
	_suspended = true
	_socket.close()
	_is_connected = false

func connect_to_server(url: String) -> void:
	suspend_connection()
	server_url = url
	_reconnect_attempts = 0
	_suspended = false
	_attempt_connection()
