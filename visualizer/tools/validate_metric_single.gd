extends SceneTree
const Net = preload("res://scripts/CorridorGeometry.gd")
const Layout = preload("res://scripts/TrafficLayout.gd")
var failures := 0
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	check(Net.data(false).source == "simulation/intersection.net.xml","Single scene loaded wrong network")
	check(Layout.widths(false).is_equal_approx(Vector3(12.8,12.8,12.8)),"Single-junction lane widths differ from SUMO")
	var scene: Node3D = load("res://scenes/Main.tscn").instantiate()
	check(scene.get_script() != null,"Main script failed to load")
	scene.get_node("WebSocketClient").auto_connect = false
	root.add_child(scene)
	current_scene = scene
	scene.set_process(false)
	await process_frame
	check(scene.get_node("Intersection/MetricRoads/RoadSurface") != null,"Missing network road surface")
	check(scene.get_node("Intersection/MetricRoads/WalkSurface").get_child_count() > 0,"Footways need collision for ground navigation")
	var fleet: Node = scene.get_node("VehicleManager")
	var cars: Array = []
	for i in range(40):
		cars.append({"id":"q%d" % i,"type":"car","x":1495.2,"y":1512.4+i*7.0,"angle":180.0,"speed":0.0})
	fleet.update_vehicles({"sim_time":1.0,"vehicles":cars})
	check(fleet._active.size() == 40,"Full queue must stay visible beyond the old scene boundary")
	var positions := Layout.vehicle_positions(cars,false)
	for i in range(1,40):
		check(is_equal_approx(positions[cars[i].id].z-positions[cars[i-1].id].z,7.0),"Queue spacing changed")
	var coach: Node3D = fleet._active.q0.node.get_node("Coach")
	check(is_equal_approx(coach._body.mesh.get_aabb().size.z*coach.scale.z,4.5),"Car length must be 4.5 m")
	var pm: Node = scene.get_node("PedestrianManager")
	check(pm.get_child_count() == 0,"Decorative walkers should not replace live sensor/simulation pedestrians")
	pm.update_crossing_pedestrians([{"id":"sidewalk","x":1492.85,"y":1650.0,"edge":"ACH_N2J","angle":180.0}],1.0)
	check(pm._crossing_peds.has("sidewalk"),"Real sidewalk walker missing")
	check(pm._crossing_peds.sidewalk.node.position.distance_to(Vector3(7.15,0.15,150)) < 0.01,"Sidewalk walker mapping changed")
	for arm in range(4):
		check(Layout.crossing(false,0,arm).width == 4,"Crossing must remain four metres wide")
	for spec in preload("res://scripts/TransitLayout.gd").stations(false):
		check(is_equal_approx(absf(spec.z),330.4),"Station must align with its original SUMO stop")
		check(absf(spec.bay_x) == 4.8,"Curbside stop must stay in its actual simulated lane")
	check(scene._player.get("EYE_HEIGHT") > 1.6,"Ground-level camera must be human height")
	scene._player.set_active(true)
	for i in range(90): await physics_frame
	check(absf(scene._player.position.y-0.15) < 0.04,"Player feet must rest on the sidewalk surface")
	scene._player.set_active(false)
	scene.get_node("IsometricCamera").current = true
	print("Metric single-junction validation: ",failures," failures; retained 40 queued cars")
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and DisplayServer.get_name() != "headless":
		root.size = Vector2i(1440,900)
		scene.get_node("UI").hide()
		var replay: Array = JSON.parse_string(FileAccess.get_file_as_string("/private/tmp/crossing-replay-single.json"))
		var packet: Dictionary = replay[-1]
		fleet.clear_all()
		fleet.update_vehicles(packet)
		scene.signal_playback.feed(packet)
		pm.update_crossing_pedestrians(packet.pedestrians,packet.sim_time)
		scene.get_node("TimeOfDayManager").set_time(13)
		var camera: Camera3D = scene.get_node("IsometricCamera")
		camera.position = Vector3(28,42,42)
		camera.look_at(Vector3.ZERO)
		for i in range(90): await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(args[0])
	scene.queue_free()
	await process_frame
	quit(0 if failures == 0 else 1)
