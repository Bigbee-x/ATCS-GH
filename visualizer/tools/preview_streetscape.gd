extends SceneTree
## Offline rendering of the real application scenes; no simulation is launched.
## -- single /absolute/output.png overview 12
## -- corridor /absolute/output.png street 17

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2 or DisplayServer.get_name() == "headless":
		push_error("Use a rendering display and pass: single|corridor /absolute/output.png [overview|street] [hour] [weather 0-3]")
		quit(1)
		return
	var corridor: bool = args[0] == "corridor"
	var scene_path := "res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn"
	var scene: Node3D = load(scene_path).instantiate()
	var live: bool = args.size() > 5 and args[5] == "live"
	scene.get_node("WebSocketClient").auto_connect = live
	if live:
		scene.get_node("WebSocketClient").server_url = "ws://127.0.0.1:8877"
	root.add_child(scene)
	current_scene = scene
	_disable_input(scene)
	scene.set_process(false)
	root.gui_disable_input = true
	root.size = Vector2i(1440, 900)
	scene.get_node("UI").hide()
	if not live:
		scene.get_node("WebSocketClient").set_process(false)
	var camera: Camera3D = scene.get_node("IsometricCamera")
	camera.far = 650.0
	if corridor:
		camera.position = Vector3(-40, 49, 83)
		camera.look_at(Vector3(0, 1, 28))
	if args.size() > 2 and args[2] == "street":
		camera.position = Vector3(-2.0, 2.1, 26)
		camera.look_at(Vector3(-12.0, 2.5, 7))
	if args.size() > 2 and args[2] == "district":
		camera.position = Vector3(60, 68, -90) if corridor else Vector3(60, 72, -105)
		camera.look_at(Vector3(-12, 3, 20) if corridor else Vector3(-5, 3, -3))
	if args.size() > 2 and args[2] in ["supermarket", "mechanic", "police", "mall", "apartment"]:
		var kit: Node3D = scene.get_node("EnvironmentBuilder/DetailedStreetscape")
		for use: Dictionary in kit.land_uses:
			if use.kind != args[2]:
				continue
			var front: Vector3 = use.facing
			var right := Vector3(front.z, 0, -front.x)
			var distance: float = maxf(use.width * 1.4, 12.0)
			var height: float = 9.0 if use.kind == "apartment" else 3.0
			camera.position = use.center + front * distance + right * (distance * 0.25) + Vector3.UP * (height + 2.0)
			camera.look_at(use.center + Vector3.UP * height)
			camera.fov = 52
			break
	if args.size() > 2 and args[2] == "airport":
		camera.position = Vector3(-12, 55, 55)
		camera.look_at(Vector3(64, 0, 134))
		camera.fov = 62
	if args.size() > 2 and args[2] == "terminal":
		camera.position = Vector3(49, 4.8, 89)
		camera.look_at(Vector3(72, 3.0, 111))
		camera.fov = 60
	if args.size() > 2 and args[2] == "weather":
		camera.position = Vector3(3, 1.75, 43)
		camera.look_at(Vector3(-3, 3.5, 0))
		camera.fov = 66
	if args.size() > 3:
		scene.get_node("TimeOfDayManager").set_time(float(args[3]))
	if args.size() > 4:
		scene.get_node("WeatherManager").set_weather(int(args[4]))
	# Settle weather deterministically without waiting minutes for wet pavement.
	if args.size() > 4:
		var weather_node: Node = scene.get_node("WeatherManager")
		for i in range(180):
			weather_node._lerp_mods_toward_target(0.2)
			weather_node._update_surface_water(0.2)
	for i in range(360 if live else 150):
		await process_frame
	await RenderingServer.frame_post_draw
	var result: int = root.get_texture().get_image().save_png(args[1])
	print("CAPTURE ", args[1], " result=", result,
		" draw_calls=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		" objects=", Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		" vehicles=", scene.get_node("VehicleManager").get("_active").size(),
		" fps=", Performance.get_monitor(Performance.TIME_FPS))
	scene.queue_free()
	await process_frame
	quit(result)

func _disable_input(node: Node) -> void:
	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	node.set_process_unhandled_key_input(false)
	for child in node.get_children():
		_disable_input(child)
