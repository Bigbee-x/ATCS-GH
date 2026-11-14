extends SceneTree
const Layout = preload("res://scripts/TrafficLayout.gd")
const Lamp = preload("res://scripts/StreetLamp.gd")
var failures := 0
func _initialize() -> void:
	call_deferred("_run")
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		if failures < 12: push_error(message)
func _run() -> void:
	check(Lamp.demand(12, 0, 0.3) == 0, "Day lamps stay on")
	check(Lamp.demand(21, 0, 0.3) == 1, "Night lamps off")
	check(Lamp.demand(12, 1, 1) > 0.5, "Rain does not activate lighting")
	for corridor in [false, true]:
		var path := "/private/tmp/crossing-replay-%s.json" % ("corridor" if corridor else "single")
		var packets: Array = JSON.parse_string(FileAccess.get_file_as_string(path))
		var stop_checks := 0
		var crossing_checks := 0
		var overlaps := 0
		for packet in packets:
			var lanes: Dictionary = {}
			var positions := Layout.vehicle_positions(packet.vehicles, corridor)
			for v in packet.vehicles:
				if v.edge.begins_with(":") or not positions.has(v.id): continue
				var front := Layout.map_position(v.x, v.y, corridor)
				var j: int = clampi(roundi((v.y - 1500) / 300.0), 0, 2) if corridor else 0
				var local := front - Layout.center(corridor, j)
				var heading: float = deg_to_rad(v.angle)
				var forward := Vector3(-sin(heading), 0, cos(heading))
				if local.dot(forward) >= 0 or local.length() > 12 or v.speed > 0.1: continue
				var arm := (0 if local.z > 0 else 2) if absf(forward.z) > 0.5 else (1 if local.x < 0 else 3)
				var distance: float = absf(local.z) if arm in [0, 2] else absf(local.x)
				check(distance >= Layout.stop_distance(corridor, j, arm) - 0.02, "Stopped front overlaps crossing or stop line")
				stop_checks += 1
				if not lanes.has(v.lane): lanes[v.lane] = []
				lanes[v.lane].append({"center": positions[v.id], "half": Layout.half_length(v.type), "order": v.lane_position})
			for lane in lanes.values():
				lane.sort_custom(func(a, b): return a.order > b.order)
				for i in range(1, lane.size()):
					if lane[i].center.distance_to(lane[i-1].center) < lane[i].half + lane[i-1].half: overlaps += 1
			for ped in packet.pedestrians:
				if not ped.has("crossing_progress"): continue
				var j: int = int(ped.edge.substr(2, 1)) if corridor else 0
				var spec := Layout.crossing(corridor, j, int(ped.crossing_index))
				var point := Layout.pedestrian(ped, corridor)
				var a: Vector3 = spec.start
				var b: Vector3 = spec.end
				var closest := a.lerp(b, clampf((point-a).dot(b-a)/(b-a).length_squared(),0,1))
				check(Vector2(point.x-closest.x,point.z-closest.z).length() < Layout.CROSSING_WIDTH * 0.5, "Pedestrian leaves zebra markings")
				crossing_checks += 1
		check(overlaps == 0, "Queued cars overlap after display spacing")
		var scene: Node3D = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
		scene.get_node("WebSocketClient").auto_connect = false
		root.add_child(scene)
		current_scene = scene
		await process_frame
		var vm: Node = scene.get_node("VehicleManager")
		vm.set_process(false)
		var pm: Node = scene.get_node("PedestrianManager")
		pm.set_process(false)
		# A vanished pedestrian retires after playback reaches the exit sample.
		pm.update_crossing_pedestrians([{"id":"qa", "edge":":J0_c0", "x":1500, "y":1508.4, "crossing_index":0, "crossing_progress":0.5}], 100)
		pm.update_crossing_pedestrians([], 101)
		check(pm._crossing_peds.has("qa"), "Walker disappears ahead of playback")
		pm._snap_clock.render_t = 101
		pm._retire_crossing_pedestrians()
		check(not pm._crossing_peds.has("qa"), "Empty updates leave a frozen pedestrian")
		# Actual per-arm clearance states, not the requested policy phase.
		var signals := {"north":{"main":"red","arrow":false},"south":{"main":"green","arrow":true},"east":{"main":"yellow","arrow":false},"west":{"main":"red","arrow":false}}
		var sample := {"sim_time":200.0,"phase":0,"signals":signals}
		if corridor: sample = {"sim_time":200.0,"junctions":{"J0":{"phase":0,"signals":signals}}}
		scene.signal_playback.feed(sample)
		vm._clock.render_t = 200
		scene.signal_playback._process(0)
		var heads: Dictionary = scene.intersection._lights.J0 if corridor else scene.intersection._lights
		check(heads.north.red.on and heads.south.green.on and heads.east.yellow.on, "Signal heads ignore actual per-arm states")
		# A green received early must wait for its effective playback timestamp.
		var next: Dictionary = sample.duplicate(true)
		next.sim_time = 210.0
		var next_j: Dictionary = next.junctions.J0 if corridor else next
		next_j["signal_time"] = 209.0
		next_j.signals.north.main = "green"
		scene.signal_playback.feed(next)
		vm._clock.render_t = 208.9
		scene.signal_playback._process(0)
		check(heads.north.red.on, "Signal changed ahead of playback")
		vm._clock.render_t = 209.0
		scene.signal_playback._process(0)
		check(heads.north.green.on, "Signal missed effective simulation time")
		# Real lamp nodes respond to the clock and direct light downward.
		var lamp: Node3D = scene.intersection._street_lights[0]
		scene.get_node("TimeOfDayManager").set_time(21)
		lamp._find_environment()
		lamp._process(5.0)
		check(lamp.light.light_energy > 4 and (-lamp.light.global_basis.z).dot(Vector3.DOWN) > 0.99, "Lamp does not illuminate the roadway at night")
		scene.get_node("TimeOfDayManager").set_time(12)
		lamp._process(5.0)
		check(lamp.light.light_energy < 0.01, "Lamp remains on in clear daylight")
		check(stop_checks > 100 and crossing_checks > 100, "Insufficient traffic replay coverage")
		print("CROSSING GEOMETRY ", corridor, ": stopped fronts=", stop_checks, " pedestrian samples=", crossing_checks, " queue overlaps=", overlaps)
		scene.queue_free()
		await process_frame
	print("Crossings validation: ", failures, " failures")
	quit(0 if failures == 0 else 1)
