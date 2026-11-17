extends SceneTree
## Render actual scene details: people|signals|sensor|billboard OUTPUT [corridor] [frames-dir]
var _scene: Node3D
func _initialize() -> void:
	call_deferred("_capture")
func _capture() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		quit(1)
		return
	var corridor: bool = args.size() > 2 and args[2] == "corridor"
	_scene = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
	_scene.get_node("WebSocketClient").auto_connect = false
	root.add_child(_scene)
	current_scene = _scene
	root.size = Vector2i(1440, 900)
	_scene.get_node("UI").hide()
	_scene.get_node("TimeOfDayManager").set_time(14.5)
	var camera: Camera3D = _scene.get_node("IsometricCamera")
	camera.fov = 42
	var road: Node3D = _scene.get_node("Intersection")
	road.update_lights({"phase": 1})
	var pole: Node3D = road.get_node("TL_J0_north" if corridor else "TrafficLight_north")
	# Pedestrians come only from SUMO; place one on the north footway to frame.
	var walkers: Node3D = _scene.get_node("PedestrianManager")
	walkers.update_crossing_pedestrians([{"id": "preview", "x": 1492.8 if corridor else 1492.85,
		"y": 1540.0 if corridor else 1650.0, "edge": "ACH_J1toJ0" if corridor else "ACH_N2J", "angle": 180.0}])
	var ped: Node3D = walkers.get("_crossing_peds")["preview"]["node"]
	var target := Vector3.ZERO
	match args[0]:
		"signals":
			target = pole.global_position + Vector3(-2.5, 4.8, 0)
			camera.position = target + Vector3(1.4, 1.0, 8.3)
		"sensor":
			target = pole.get_node("Sensor_CCTV").global_position
			camera.position = target + Vector3(0.7, 0.4, 1.15)
		"billboard":
			var board: Node3D = _scene.get_node("BillboardBuilder").get_child(0)
			target = board.to_global(Vector3(0, 2.6, 0))
			camera.position = board.to_global(Vector3(2.7, 3.8, 10.5))
		"people":
			target = ped.position + Vector3(0, 0.45, 0)
			camera.position = ped.position + Vector3(1.4, 1.05, 2.2)
	camera.look_at(target)
	for i in range(90):
		await process_frame
	if args.size() > 3:
		root.size = Vector2i(800, 500)
		Engine.max_fps = 20
		DirAccess.make_dir_recursive_absolute(args[3])
		for i in range(100):
			await process_frame
			if args[0] == "people":
				camera.position = ped.position + Vector3(1.4, 1.05, 2.2)
				camera.look_at(ped.position + Vector3(0, 0.45, 0))
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(args[3].path_join("frame_%03d.png" % i))
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(args[1])
	print("DETAIL CAPTURE ", args[0], " fps=", Performance.get_monitor(Performance.TIME_FPS))
	_scene.queue_free()
	await process_frame
	quit()
