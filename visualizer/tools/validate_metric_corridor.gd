extends SceneTree
const Net = preload("res://scripts/CorridorGeometry.gd")
const Layout = preload("res://scripts/TrafficLayout.gd")
var failures: int = 0
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	check(Net.center(0).distance_to(Net.center(1)) == 300, "Junction spacing must retain 300 metres")
	check(Net.widths(0).is_equal_approx(Vector3(12.8,12.8,6.4)), "Lane widths must match SUMO")
	var cars: Array = []
	for i in range(40):
		cars.append({"id":str(i),"type":"car","x":1504.8,"y":1787.1-i*7.0,"angle":0.0,"lane":"ACH_J0toJ1_1","lane_position":277.1-i*7.0,"from_junction":"J0","edge":"ACH_J0toJ1"})
	var mapped := Layout.vehicle_positions(cars,true)
	check(mapped.size() == 40, "Full 40-vehicle queue must remain visible")
	for i in range(1,40): check(is_equal_approx(mapped[str(i-1)].z-mapped[str(i)].z,7.0), "Queue gaps must remain 7 metres")
	for j in range(3):
		for arm in range(4):
			var c := Net.crossing(j,arm)
			check(c.width == 4, "Four-metre crossing width")
			check(is_equal_approx(Layout.stop_distance(true,j,arm)-Layout.crossing_distance(true,j,arm),2), "Stop bar must be outside crossing")
	var scene: Node3D = load("res://scenes/CorridorMain.tscn").instantiate()
	scene.get_node("WebSocketClient").auto_connect = false
	check(scene.get_node("UI/UIRoot").get_script() != null, "UI script failed to load")
	root.add_child(scene)
	current_scene = scene
	scene.set_process(false)
	await process_frame
	check(scene.get_node("PedestrianManager").corridor_mode, "Scene startup must configure metric pedestrians")
	var fleet: Node = scene.get_node("VehicleManager")
	fleet.update_vehicles({"mode":"corridor","sim_time":1.0,"vehicles":cars})
	await process_frame
	check(fleet._active.size() == 40,"Scene must render complete queue")
	check(scene.get_node("Intersection/TL_J1_north").position.z > 300, "J1 signals must move with the junction")
	check(scene.get_node("Intersection/TL_J2_north").position.z > 600, "J2 signals must move with the junction")
	check(scene.get_node("Intersection/MetricRoads/RoadSurface") != null,"Generated road surface exists")
	check(not scene.get_node("Intersection")._lane_overlays.is_empty(),"Live queue heatmap must retain lane overlays")
	for key in [KEY_1, KEY_2, KEY_3, KEY_0]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = true
		scene._unhandled_input(event)
		var expected: float = 300.0 if key == KEY_0 else (key-KEY_1)*300.0
		check(is_equal_approx(scene._camera_pivot.z,expected),"Camera shortcut must focus the actual junction")
	check(scene._zoom_level > 6.0,"Overview must span all three junctions")
	for key in [KEY_5,KEY_6,KEY_7,KEY_8]:
		var event := InputEventKey.new()
		event.keycode = key
		event.pressed = true
		scene._unhandled_input(event)
		var section: Dictionary = preload("res://scripts/CityDistrictBuilder.gd").sections()[key-KEY_5]
		check(is_equal_approx(scene._camera_pivot.z,section.z),"District shortcut must match its planned section")
	var size: Vector3 = fleet._active["0"].node.get_node("Coach").scale
	var bounds: AABB = fleet._active["0"].node.get_node("Coach")._body.mesh.get_aabb()
	check(is_equal_approx(size.z*bounds.size.z,4.5),"Car body must match 4.5 m length")
	for spec in preload("res://scripts/TransitLayout.gd").stations(true):
		check(is_equal_approx(float(spec.z),float(spec.sumo_y)-1500),"Station must keep physical SUMO location")
		check(absf(spec.bay_x)-Net.vehicle_size("trotro").x*0.5 > 7.9,"Boarding bus must clear road and footway")
	for lamp in scene.get_node("Intersection")._street_lights:
		check(not scene.get_node("Intersection")._in_station_plot(lamp.position),"Lamp pole must not block a station driveway")
	print("Metric corridor validation: ", failures," failures; retained ",mapped.size()," queued vehicles")
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and DisplayServer.get_name() != "headless":
		root.size = Vector2i(1440,900)
		scene.get_node("UI").hide()
		var replay_path := "/private/tmp/crossing-replay-corridor.json"
		if FileAccess.file_exists(replay_path):
			var replay: Array = JSON.parse_string(FileAccess.get_file_as_string(replay_path))
			fleet.clear_all()
			var packet: Dictionary = replay[-1]
			fleet.update_vehicles(packet)
			scene.signal_playback.feed(packet)
			scene.get_node("PedestrianManager").update_crossing_pedestrians(packet.pedestrians, packet.sim_time)
		scene.get_node("TimeOfDayManager").set_time(13)
		var camera: Camera3D = scene.get_node("IsometricCamera")
		camera.position = Vector3(-32,40,345)
		camera.look_at(Vector3(0,0,302))
		if args.size() > 1 and args[1] == "city":
			camera.position = Vector3(-285,340,700)
			camera.look_at(Vector3(0,0,300))
		if args.size() > 1 and args[1] == "airport":
			camera.position = Vector3(340,145,320)
			camera.look_at(Vector3(207,0,155))
		if args.size() > 1 and args[1] == "j0":
			camera.position = Vector3(-24,28,38)
			camera.look_at(Vector3(0,0,0))
		if args.size() > 1 and args[1] == "station":
			camera.position = Vector3(35,20,-307)
			camera.look_at(Vector3(9,0,-330))
		if args.size() > 1 and args[1].begins_with("section"):
			var section: int = args[1].trim_prefix("section").to_int()
			var middle: float = preload("res://scripts/CityDistrictBuilder.gd").sections()[clampi(section-1,0,3)].z
			camera.position = Vector3(-190,215,middle+170)
			camera.look_at(Vector3(-20,0,middle))
		if args.size() > 1 and args[1] in ["plan","review"]:
			camera.projection = Camera3D.PROJECTION_ORTHOGONAL
			camera.size = 700
			camera.position = Vector3(0,600,340)
			camera.look_at(Vector3(0,0,340),Vector3.RIGHT)
		for i in range(90): await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(args[0])
		if args.size() > 1 and args[1] == "review":
			camera.projection = Camera3D.PROJECTION_PERSPECTIVE
			camera.position = Vector3(-4.5,2.0,315)
			camera.look_at(Vector3(-22,4.5,283))
			for i in range(60): await process_frame
			await RenderingServer.frame_post_draw
			root.get_texture().get_image().save_png(args[0].get_basename()+"-street.png")
	scene.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
