extends SceneTree
## Real SUMO + full corridor scene through the former 64 KiB failure point.
var failures: int = 0
var latest: Dictionary = {}
var connections: int = 0
var disconnects: int = 0
var updates: int = 0
var max_payload_bytes: int = 0
var max_vehicles: int = 0
var first_sim_time: float = -1.0
var first_arrived: int = -1
var initial_positions: Dictionary = {}
var moved: Dictionary = {}
var phases: Dictionary = {}

func _initialize() -> void:
	call_deferred("_run")

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures += 1
		push_error(message)

func _run() -> void:
	var manager: Node = root.get_node("ServerManager")
	var ready: bool = await manager.start_server(2, {"port": 8890, "speed": 30.0, "dashboard": false})
	_check(ready, "Dense corridor backend failed: " + manager.last_error)
	if not ready:
		print(manager.get_log_contents())
		quit(1)
		return
	var scene: Node3D = load("res://scenes/CorridorMain.tscn").instantiate()
	var client: Node = scene.get_node("WebSocketClient")
	client.auto_start_server = false
	client.server_url = manager.get_websocket_url()
	client.connection_changed.connect(_connection)
	client.state_updated.connect(_state)
	client.vehicle_updated.connect(_traffic)
	root.add_child(scene)
	current_scene = scene
	scene.set_process(false)
	var deadline: int = Time.get_ticks_msec() + 180000
	while Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
		var fleet: Dictionary = scene.get_node("VehicleManager")._active
		for id in fleet:
			var node: Node3D = fleet[id].node
			if not initial_positions.has(id):
				initial_positions[id] = node.global_position
			elif node.visible and node.global_position.distance_to(initial_positions[id]) > 0.5:
				moved[id] = true
		if float(latest.get("sim_time", 0)) >= maxf(1200.0, first_sim_time + 900.0):
			break
	_check(float(latest.get("sim_time", 0)) >= maxf(1200.0, first_sim_time + 900.0), "Live clock did not advance through dense traffic")
	_check(max_payload_bytes > 65536, "Run never exceeded the old receive limit")
	_check(connections == 1 and disconnects == 0, "Dense stream disconnected: %d opens / %d drops" % [connections, disconnects])
	_check(updates >= 900, "Traffic updates were lost")
	_check(max_vehicles >= 200 and moved.size() >= 20, "Dense traffic was not rendered and moving")
	_check(int(latest.get("vehicles_completed", 0)) - first_arrived > 10, "Vehicles stopped completing trips")
	_check(phases.size() >= 2, "AI signals stopped changing")
	var control: Dictionary = latest.get("junctions", {}).get("J0", {}).get("control", {})
	_check(control.get("kind") == "dqn_supervised", "Live AI controller missing")
	_check(absf(float(control.get("sample_time", -10)) - float(latest.get("sim_time", 0))) < 1.1, "AI observations are stale")
	print("DENSE TRAFFIC: sim_time=", latest.get("sim_time"), " max_payload_bytes=", max_payload_bytes,
		" max_vehicles=", max_vehicles, " updates=", updates, " moving=", moved.size(),
		" connections=", connections, " disconnects=", disconnects, " failures=", failures)
	scene.queue_free()
	await process_frame
	manager.stop_server()
	quit(0 if failures == 0 else 1)

func _connection(connected: bool) -> void:
	if connected:
		connections += 1
	else:
		disconnects += 1

func _traffic(data: Dictionary) -> void:
	updates += 1
	if first_sim_time < 0:
		first_sim_time = float(data.sim_time)
	max_vehicles = maxi(max_vehicles, data.get("vehicles", []).size())

func _state(data: Dictionary) -> void:
	latest = data
	if first_arrived < 0:
		first_arrived = int(data.get("vehicles_completed", 0))
	max_payload_bytes = maxi(max_payload_bytes, JSON.stringify(data).to_utf8_buffer().size())
	phases[int(data.junctions.J0.phase)] = true
