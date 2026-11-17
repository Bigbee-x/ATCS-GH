extends SceneTree
## Real SUMO -> WebSocket -> rendered vehicle/signal integration, no canned data.
var failures: int = 0
var latest: Dictionary = {}
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
	manager.log_file_path = "/private/tmp/trafiq-live-validation-%d.log" % OS.get_process_id()
	# Occupy a port with an unrelated listener: startup must leave it intact.
	var occupied := TCPServer.new()
	var test_port: int = manager._available_port(8878)
	_check(occupied.listen(test_port, "127.0.0.1") == OK, "Could not reserve test port")
	var modes := [false, true] if "--legacy" in OS.get_cmdline_user_args() else [true]
	for corridor in modes:
		latest.clear()
		initial_positions.clear()
		moved.clear()
		phases.clear()
		var ready: bool = await manager.start_server(2 if corridor else 1, {"port": test_port, "speed": 6.0, "dashboard": false})
		_check(ready, "Real traffic backend did not start: " + manager.last_error)
		_check(manager.active_port != test_port and occupied.is_listening(), "Occupied port was not preserved")
		if not ready:
			print(manager.get_log_contents())
			break
		var scene: Node3D = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
		var client: Node = scene.get_node("WebSocketClient")
		client.server_url = manager.get_websocket_url()
		client.state_updated.connect(_state)
		root.add_child(scene)
		current_scene = scene
		scene.set_process(false)
		var deadline: int = Time.get_ticks_msec() + 60000
		var max_vehicles: int = 0
		while Time.get_ticks_msec() < deadline:
			await create_timer(0.1).timeout
			var fleet: Dictionary = scene.get_node("VehicleManager")._active
			max_vehicles = maxi(max_vehicles, fleet.size())
			for id in fleet:
				var node: Node3D = fleet[id].node
				if not initial_positions.has(id):
					initial_positions[id] = node.global_position
				elif node.global_position.distance_to(initial_positions[id]) > 0.5 and node.visible:
					moved[id] = true
			if max_vehicles >= 12 and moved.size() >= 8 and phases.size() >= 2 and (DisplayServer.get_name() == "headless" or float(latest.get("sim_time", 0.0)) >= 160.0):
				break
		_check(max_vehicles >= 12, "Traffic packets did not create a populated fleet")
		_check(moved.size() >= 8, "Rendered cars are not moving")
		_check(phases.size() >= 2, "Live traffic signals never change phase")
		_check(scene._packets_received > 1, "Scene is not consuming state packets")
		if corridor:
			var control: Dictionary = latest.get("junctions", {}).get("J0", {}).get("control", {})
			_check(control.get("kind") == "dqn_supervised", "Live corridor bypasses the DQN supervisor")
			_check(control.has("movement_demand") and control.has("lane_detectors"), "Live controller lacks movement detectors")
			_check(absf(float(control.get("sample_time", -10)) - float(latest.get("sim_time", 0))) < 1.1, "Detector observations are stale")
		# Signal bulbs must reflect the SUMO state at the shared playback time.
		var lights: Dictionary = scene.get_node("Intersection")._lights
		var heads: Dictionary = lights["J0"] if corridor else lights
		var displayed: Dictionary = scene.signal_playback.displayed
		var actual: Dictionary = displayed.get("junctions", {}).get("J0", {}) if corridor else displayed
		var expected: String = actual.get("signals", {}).get("north", {}).get("main", "")
		_check(not expected.is_empty() and heads.north[expected].on, "Rendered signal bulbs disagree with SUMO playback")
		print("LIVE TRAFFIC ", "corridor" if corridor else "single", ": port=", manager.active_port,
			" vehicles=", max_vehicles, " moving=", moved.size(), " phases=", phases.keys())
		var args := OS.get_cmdline_user_args()
		if not args.is_empty() and not args[0].begins_with("--") and DisplayServer.get_name() != "headless":
			root.size = Vector2i(1440, 900)
			scene.get_node("TimeOfDayManager").set_time(14.0)
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(args[0].path_join("live-traffic-%s.png" % ("corridor" if corridor else "single")))
			if corridor and "--hud" in args:
				var hud: Control = scene.get_node("UI/UIRoot")
				var camera: Camera3D = scene.get_node("IsometricCamera")
				camera.projection = Camera3D.PROJECTION_PERSPECTIVE
				camera.position = Vector3(-100,100,135)
				camera.look_at(Vector3(0,0,310))
				scene.get_node("TimeOfDayManager").set_time(17.5)
				for page in ["", "Traffic", "Scene", "Controls"]:
					if not hud._page.is_empty(): hud.toggle_page(hud._page)
					if not page.is_empty(): hud.toggle_page(page)
					for frame in range(16): await process_frame
					await RenderingServer.frame_post_draw
					root.get_texture().get_image().save_png(args[0].path_join("hud-%s.png" % ("overview" if page.is_empty() else page.to_lower())))
				var sample := FileAccess.open(args[0].path_join("live-packet.json"), FileAccess.WRITE)
				sample.store_string(JSON.stringify(latest))
		scene.queue_free()
		await process_frame
		manager.stop_server()
	occupied.stop()
	print("Live traffic validation: ", failures, " failures")
	quit(0 if failures == 0 else 1)

func _state(data: Dictionary) -> void:
	latest = data
	var phase: int = data.junctions.J0.phase if data.has("junctions") else data.phase
	phases[phase] = true
