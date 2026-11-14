extends SceneTree
## Network regression: exercise the production client, with a default-peer control.
var client: Node
var peer: WebSocketPeer
var received: Array[int] = []
var connections: int = 0
var disconnections: int = 0
var failures: int = 0
var deadline: int
var negative_control: bool = false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() != 2:
		push_error("Expected temporary websocket URL and test mode")
		quit(1)
		return
	deadline = Time.get_ticks_msec() + 30000
	negative_control = args[1] == "default-peer"
	if negative_control:
		peer = WebSocketPeer.new()
		print("Default peer inbound bytes: ", peer.inbound_buffer_size)
		_check(peer.connect_to_url(args[0]) == OK, "Default peer failed to connect")
	else:
		client = load("res://scripts/WebSocketClient.gd").new()
		client.server_url = args[0]
		client.auto_start_server = false
		client.reconnect_delay = 0.15
		client.vehicle_updated.connect(_packet)
		client.state_updated.connect(_packet)
		client.connection_changed.connect(_connection)
		client.mode_changed.connect(_mode_only)
		client.sim_completed.connect(_complete)
		root.add_child(client)

func _process(_delta: float) -> bool:
	if deadline > 0 and Time.get_ticks_msec() > deadline:
		push_error("Stream regression timed out")
		quit(1)
	if negative_control and peer:
		peer.poll()
		if peer.get_ready_state() == WebSocketPeer.STATE_OPEN:
			while peer.get_available_packet_count() > 0:
				peer.get_packet()
		if peer.get_ready_state() == WebSocketPeer.STATE_CLOSED and peer.get_close_code() >= 0:
			_check(peer.get_close_code() == 1009, "Default peer did not reproduce Message too big")
			print("STREAM PASS default peer reproduced close code ", peer.get_close_code())
			quit(0 if failures == 0 else 1)
	return false

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _connection(connected: bool) -> void:
	if connected:
		connections += 1
	else:
		disconnections += 1

func _mode_only(_data: Dictionary) -> void:
	_check(not client.is_connected_to_server(), "Handshake alone was shown as live traffic")
	client._socket.send_text(JSON.stringify({"validation_mode_ack": true}))

func _packet(data: Dictionary) -> void:
	var sequence: int = int(data.validation_sequence)
	var count: int = int(data.validation_count)
	_check(sequence == received.size() + 1, "Traffic packets were lost or reordered")
	_check(data.vehicles.size() == count, "Vehicle array was truncated")
	_check(data.vehicles[-1].id == "corridor_vehicle_%d" % (count - 1), "Last vehicle missing")
	_check(is_equal_approx(float(data.vehicles[-1].y), 1000.0 + (count - 1) * 0.25 + sequence), "Vehicle position changed in transit")
	_check(int(data.junctions.J2.control.sample_time) == sequence, "Signal observations stopped advancing")
	received.append(sequence)
	client._socket.send_text(JSON.stringify({"validation_ack": sequence}))
	if data.get("validation_stall", false):
		# Emulate a slow rendered frame while several traffic snapshots arrive.
		OS.delay_msec(300)

func _complete(data: Dictionary) -> void:
	_check(received.size() == data.validation_expected.size(), "Not all test packets arrived")
	_check(connections == 2, "Expected only initial connection and deliberate reconnect")
	_check(disconnections == 1, "Unexpected live traffic disconnects")
	print("STREAM PASS production client: packets=", received.size(), " connections=", connections,
		" disconnects=", disconnections, " failures=", failures)
	client.suspend_connection()
	quit(0 if failures == 0 else 1)
