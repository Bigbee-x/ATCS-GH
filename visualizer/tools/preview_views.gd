extends SceneTree
## Several camera views of an assembled scene in one launch; no SUMO is started.
## -- corridor|single /absolute/out_dir hour weather name=px,py,pz>lx,ly,lz[@fov] ...
## A recorded crossing replay, when present, supplies parked-up traffic.

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 5 or DisplayServer.get_name() == "headless":
		push_error("Use a rendering display: corridor|single /abs/out_dir hour weather name=px,py,pz>lx,ly,lz[@fov] ...")
		quit(1)
		return
	var corridor: bool = args[0] == "corridor"
	var scene: Node3D = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
	scene.get_node("WebSocketClient").auto_connect = false
	root.add_child(scene)
	current_scene = scene
	_disable_input(scene)
	scene.set_process(false)
	root.gui_disable_input = true
	root.size = Vector2i(1440, 900)
	scene.get_node("UI").hide()
	scene.get_node("WebSocketClient").set_process(false)
	await process_frame
	var replay_path := "/private/tmp/crossing-replay-%s.json" % ("corridor" if corridor else "single")
	if FileAccess.file_exists(replay_path):
		var replay: Array = JSON.parse_string(FileAccess.get_file_as_string(replay_path))
		var packet: Dictionary = replay[-1]
		scene.get_node("VehicleManager").update_vehicles(packet)
		if scene.get("signal_playback") != null:
			scene.signal_playback.feed(packet)
	scene.get_node("TimeOfDayManager").set_time(float(args[2]))
	var weather: Node = scene.get_node("WeatherManager")
	weather.set_weather(int(args[3]))
	for i in range(180):
		weather._lerp_mods_toward_target(0.2)
		weather._update_surface_water(0.2)
	var camera: Camera3D = scene.get_node("IsometricCamera")
	camera.projection = Camera3D.PROJECTION_PERSPECTIVE
	camera.far = 2600.0
	var result: int = OK
	for i in range(4, args.size()):
		var spec: String = args[i]
		var view_name: String = spec.get_slice("=", 0)
		var body: String = spec.get_slice("=", 1)
		var fov: float = 58.0
		if body.contains("@"):
			fov = float(body.get_slice("@", 1))
			body = body.get_slice("@", 0)
		var from := _vec(body.get_slice(">", 0))
		var to := _vec(body.get_slice(">", 1))
		camera.fov = fov
		camera.position = from
		var up := Vector3.RIGHT if absf(from.x - to.x) + absf(from.z - to.z) < 0.01 else Vector3.UP
		camera.look_at(to, up)
		for frame in range(70 if i == 4 else 24):
			await process_frame
		await RenderingServer.frame_post_draw
		var path := args[1].path_join(view_name + ".png")
		result = maxi(result, root.get_texture().get_image().save_png(path))
		print("CAPTURE ", path, " draw_calls=", Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			" primitives=", Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			" fps=", Performance.get_monitor(Performance.TIME_FPS))
	scene.queue_free()
	await process_frame
	quit(result)

func _vec(text: String) -> Vector3:
	var parts := text.split(",")
	return Vector3(float(parts[0]), float(parts[1]), float(parts[2]))

func _disable_input(node: Node) -> void:
	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	node.set_process_unhandled_key_input(false)
	for child in node.get_children():
		_disable_input(child)
