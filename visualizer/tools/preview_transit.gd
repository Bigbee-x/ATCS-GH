extends SceneTree
## Actual scene capture, optionally replaying recorded SUMO packets.
## -- station|fleet OUTPUT [replay-json] [frames-dir]
func _initialize() -> void:
	call_deferred("_capture")
func _capture() -> void:
	var args := OS.get_cmdline_user_args()
	var corridor: bool = args[0] == "corridor_station"
	var scene: Node3D = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
	scene.get_node("WebSocketClient").auto_connect = false
	root.add_child(scene)
	current_scene = scene
	# Capture windows must not react to keyboard shortcuts or change scenes.
	_disable_input(scene)
	scene.set_process(false) # Main's direct key polling also moves the camera.
	root.gui_disable_input = true
	root.size = Vector2i(1440,900)
	scene.get_node("UI").hide()
	scene.get_node("TimeOfDayManager").set_time(14.0)
	var vehicles: Node3D = scene.get_node("VehicleManager")
	var stations: Node3D = scene.get_node("TrotroStationManager")
	var camera: Camera3D = scene.get_node("IsometricCamera")
	camera.fov = 46
	if args[0] == "fleet":
		for i in range(3):
			vehicles.call("_spawn_vehicle","car_show_%d" % i,Vector3(-1.8+i*1.7,0.35,19),PI,"car")
		camera.position = Vector3(-1.5,1.65,22.8)
		camera.look_at(Vector3(0,0.45,19))
	else:
		camera.position = Vector3(1.5,3.6,30.5)
		camera.look_at(Vector3(-6.0,0.9,23.0))
		if args[0] == "pickup":
			camera.position = Vector3(-4.2,1.75,27.4)
			camera.look_at(Vector3(-3.1,0.65,23.2))
	if corridor:
		camera.position = Vector3(-2, 5.2, -13)
		camera.look_at(Vector3(6, 0.9, -23))
	var replay: Array = []
	if args.size() > 2:
		if not FileAccess.file_exists(args[2]):
			push_error("Replay file not found: " + args[2])
			quit(1)
			return
		replay = JSON.parse_string(FileAccess.get_file_as_string(args[2]))
	# Pre-roll the actual incoming bus up to the loading zone.
	for i in range(120):
		if not replay.is_empty() and i%10 == 0:
			var packet: Dictionary = replay[mini(i/10,replay.size()-1)]
			vehicles.update_vehicles(packet)
			stations.update_transit(packet["transit"])
		await process_frame
	if args.size() > 3:
		root.size = Vector2i(960,600)
		DirAccess.make_dir_recursive_absolute(args[3])
		for i in range(340):
			if i%10 == 0 and not replay.is_empty():
				var packet: Dictionary = replay[mini(12+i/10,replay.size()-1)]
				vehicles.update_vehicles(packet)
				stations.update_transit(packet["transit"])
			await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(args[3].path_join("frame_%03d.png" % i))
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(args[1])
	print("TRANSIT CAPTURE ",args[0])
	scene.queue_free()
	await process_frame
	quit()

func _disable_input(node: Node) -> void:
	node.set_process_input(false)
	node.set_process_unhandled_input(false)
	node.set_process_unhandled_key_input(false)
	for child in node.get_children():
		_disable_input(child)
