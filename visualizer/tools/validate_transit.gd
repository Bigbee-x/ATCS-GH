extends SceneTree
const Layout = preload("res://scripts/TransitLayout.gd")
const Fleet = preload("res://scripts/VehicleActor.gd")
var failures: int = 0
func _initialize() -> void:
	call_deferred("_run")
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _run() -> void:
	for corridor in [false,true]:
		var scene: Node3D = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
		scene.get_node("WebSocketClient").auto_connect = false
		root.add_child(scene)
		current_scene = scene
		await process_frame
		var manager: Node3D = scene.get_node("VehicleManager")
		manager.set_process(false)
		var stations: Node3D = scene.get_node("TrotroStationManager")
		check(stations.get("_stations").size() == 2,"Missing trotro stations")
		# Seed a trotro and car, recycle both, then acquire the opposite order.
		for iteration in range(2):
			manager.update_vehicles({"vehicles":[{"id":"typed_bus","type":"trotro","x":1504.8,"y":1520.0,"speed":4},{"id":"typed_car","type":"car","x":1495.2,"y":1520.0,"speed":3}]})
			check(manager.get("_active")["typed_bus"]["node"].get_node("Coach").kind == "trotro","SUMO trotro rendered as a passenger car")
			check(manager.get("_active")["typed_car"]["node"].get_node("Coach").kind == "car","Car pool acquired a trotro")
			manager.clear_all()
		manager.MAX_VEHICLES = 2
		manager.update_vehicles({"vehicles":[{"id":"cap_a","type":"car","x":1495.2,"y":1520.0},{"id":"cap_b","type":"car","x":1495.2,"y":1540.0}]})
		manager.update_vehicles({"vehicles":[{"id":"cap_a","type":"car","x":1495.2,"y":1520.0},{"id":"cap_b","type":"car","x":1495.2,"y":1540.0},{"id":"service_bus","type":"trotro","x":1504.8,"y":1520.0,"station_id":"priority_test"}]})
		check(manager.get("_active").has("service_bus") and manager.get("_active").size() == 2,"Rendering cap hides a station service or exceeds its limit")
		manager.clear_all()
		var kit: Node3D = scene.get_node("EnvironmentBuilder/DetailedStreetscape")
		for spec in Layout.stations(corridor):
			var plot: Rect2 = Layout.plot(spec)
			for child in kit.get_children():
				if not child is StaticBody3D:
					continue
				var collision: CollisionShape3D = child.get_child(0)
				var size: Vector3 = collision.shape.size
				var tx: Transform3D = collision.global_transform
				var half: Vector3 = (tx.basis.x.abs()*size.x+tx.basis.z.abs()*size.z)*0.5
				check(not plot.intersects(Rect2(tx.origin.x-half.x,tx.origin.z-half.z,half.x*2,half.z*2)),"Building occupies a station plot")
			var sumo_y: float
			if corridor:
				sumo_y = 1510.4+spec["pos"] if spec["side"] < 0 else 2092.8-spec["pos"]
			else:
				sumo_y = 1510.4+spec["pos"] if spec["side"] < 0 else 1489.6-spec["pos"]
			if spec.has("sumo_y"):
				sumo_y = float(spec.sumo_y)
			var mapped: Vector3 = manager.call("_sumo_to_godot",1500.0,sumo_y)
			check(absf(mapped.z-float(spec["z"])) < 0.01,"Station is not aligned with its SUMO stop")
		scene.get_node("TimeOfDayManager").set_time(20)
		for light in stations.get("_lights"):
			check(light.light_energy > 0,"Station night lighting missing")
		stations.set_passengers_enabled(false)
		for station in stations.get("_stations").values():
			check(not station["mate"].visible,"Pedestrian toggle leaves station mate visible")
		print("TRANSIT SCENE PASS: ","corridor" if corridor else "single")
		scene.queue_free()
		await process_frame
	var actor := Fleet.new()
	actor.configure("trotro",3)
	root.add_child(actor)
	actor.animate(0.3,0.1,0.1,false,false,false)
	var spin: float = actor.get("_spin")
	check(absf(spin) > 0.01,"Wheels do not rotate with travel")
	actor.animate(0,0,1,true,true,true)
	check(is_equal_approx(actor.get("_spin"),spin),"Stopped wheels keep spinning")
	check(actor.get("_door_blend") == 1,"Boarding door does not open")
	check(actor.get("_lamps")[0].visible and actor.get("_brakes")[0].visible,"Headlights or brake lights missing")
	actor.animate(0,0,1,false,false,false)
	check(actor.get("_door_blend") == 0,"Boarding door does not close")
	actor.free()
	print("Transit validation: ",failures," failures")
	quit(0 if failures == 0 else 1)
