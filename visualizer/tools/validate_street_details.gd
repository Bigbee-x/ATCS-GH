extends SceneTree
## Behavioural regression checks for the pedestrian and street-furniture rebuild.
const Actor = preload("res://scripts/PedestrianActor.gd")
const Layout = preload("res://scripts/StreetSignLayout.gd")
const PedSignals = preload("res://scripts/PedestrianSignals.gd")
var failures: int = 0
func _initialize() -> void:
	call_deferred("_validate")
func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)
func _validate() -> void:
	_check_gait()
	for corridor in [false, true]:
		var scene: Node3D = load("res://scenes/CorridorMain.tscn" if corridor else "res://scenes/Main.tscn").instantiate()
		scene.get_node("WebSocketClient").auto_connect = false
		root.add_child(scene)
		current_scene = scene
		await process_frame
		var roads: Node3D = scene.get_node("Intersection")
		_check_signals(roads, corridor)
		_check_sensors(scene, roads, corridor)
		_check_signs(scene, corridor)
		_check_walkers(scene.get_node("PedestrianManager"), corridor)
		_check_crossings(scene.get_node("PedestrianManager"))
		print("STREET DETAILS VALIDATED: ", "corridor" if corridor else "single junction")
		scene.queue_free()
		await process_frame
	print("Street-detail validation: ", failures, " failures")
	quit(0 if failures == 0 else 1)

func _check_gait() -> void:
	var a := Actor.new()
	var b := Actor.new()
	a.configure(71)
	b.configure(71)
	root.add_child(a)
	root.add_child(b)
	for i in range(30):
		a.animate(0.5 / 30.0, 0.5, 1.0 / 30.0)
	for i in range(120):
		b.animate(0.5 / 120.0, 0.5, 1.0 / 120.0)
	check(is_equal_approx(a.phase, b.phase), "Stride changes with frame rate")
	check(a.get("_shoes")[0].position.is_equal_approx(b.get("_shoes")[0].position), "Foot placement changes with frame rate")
	a.character_scale = 1.0
	a.scale = Vector3.ONE
	a.phase = TAU * 0.05
	a.stride_blend = 1.0
	a.animate(0, 0.5, 0)
	var foot_before: Vector3 = a.get("_shoes")[0].global_position
	for i in range(20):
		a.position.z += 0.005
		a.animate(0.005, 0.5, 0.01)
	var foot_after: Vector3 = a.get("_shoes")[0].global_position
	check(foot_before.distance_to(foot_after) < 0.002, "Planted foot slides across the pavement")
	var stopped_phase: float = a.phase
	for i in range(60):
		a.animate(0, 0, 1.0 / 60.0)
	check(is_equal_approx(a.phase, stopped_phase) and is_zero_approx(a.stride_blend), "Stopped pedestrian keeps walking")
	for foot in a.get("_shoes"):
		check(foot.position.y >= 0.041, "Foot goes below the ground")
	a.free()
	b.free()

func _check_signals(roads: Node3D, corridor: bool) -> void:
	var expected := [
		["green", "red", false, false], ["red", "red", true, false],
		["yellow", "red", false, false], ["red", "green", false, false],
		["red", "red", false, true], ["red", "yellow", false, false],
		["green", "red", true, false], ["red", "green", false, true]]
	var ped_groups: Array = roads.get("_peds").values() if corridor else [roads.get("_peds")]
	for phase in range(8):
		roads.update_lights({"phase": phase, "junctions": {"J0": {"phase": phase}, "J1": {"phase": phase}, "J2": {"phase": phase}}})
		var walk: Dictionary = PedSignals.phase_walk(phase)
		for peds in ped_groups:
			for arm in ["north", "east", "south", "west"]:
				for head: Dictionary in peds.heads[arm]:
					check(head["person"]["on"] == walk[arm] and head["hand"]["on"] != walk[arm], "Pedestrian head disagrees with phase %d on the %s crossing" % [phase, arm])
		var all_lights: Dictionary = roads.get("_lights")
		var groups: Array = all_lights.values() if corridor else [all_lights]
		for lights: Dictionary in groups:
			for approach in ["north", "south", "east", "west"]:
				var ns: bool = approach in ["north", "south"]
				var active: String = expected[phase][0 if ns else 1]
				var bulbs: Dictionary = lights[approach]
				check(bulbs.has("far"), "Approach has no far-side through head: " + approach)
				for color_name in ["red", "yellow", "green"]:
					for head: Dictionary in [bulbs, bulbs["pole"], bulbs["far"]]:
						var illuminated: float = head[color_name]["material"].get_shader_parameter("active")
						check(is_equal_approx(illuminated, 1.0 if color_name == active else 0.0), "Incorrect signal/repeater/far-side aspect in phase " + str(phase))
				check(bulbs["arrow"]["on"] == expected[phase][2 if ns else 3], "Protected-turn arrow disagrees with phase")
				check(bulbs["far"]["arrow"]["on"] == bulbs["arrow"]["on"], "Far-side arrow disagrees with the overhead arrow")
	# Signal and detector fronts must point toward each approaching road; each pole's
	# far-side head faces the opposite approach, whose far-left corner it stands on.
	var directions := {"north": Vector3.BACK, "south": Vector3.FORWARD, "east": Vector3.LEFT, "west": Vector3.RIGHT}
	var opposite := {"north": "south", "south": "north", "east": "west", "west": "east"}
	for pole in roads.get_children():
		if not pole.has_meta("arm_length"):
			continue
		var approach: String = String(pole.name).get_slice("_", 2 if corridor else 1)
		check(pole.global_basis.z.dot(directions[approach]) > 0.99, "Signal faces away from approaching traffic: " + pole.name)
		check(pole.has_node("FarSideHead") and pole.get_node("FarSideHead").global_basis.z.dot(directions[opposite[approach]]) > 0.99, "Far-side head missing or misaimed: " + pole.name)
	# Pedestrian heads: one at each end of every crossing, facing each other along it.
	for peds in ped_groups:
		for arm in ["north", "east", "south", "west"]:
			var heads: Array = peds.heads[arm]
			check(heads.size() == 2, "Crossing lacks a pedestrian head at each end: " + arm)
			if heads.size() == 2:
				var a: Vector3 = heads[0]["hand"]["mesh"].get_parent().global_basis.z
				var b: Vector3 = heads[1]["hand"]["mesh"].get_parent().global_basis.z
				var along: float = absf(a.x) if arm in ["north", "south"] else absf(a.z)
				check(along > 0.99 and a.dot(b) < -0.99, "Pedestrian heads do not face each other along the crossing: " + arm)
	# Live crossing states: WALK on green, a flashing hand while someone is still on
	# a crossing that has stopped walking, a steady hand otherwise.
	var live := {"phase": 0, "crossing_green": {"north": false, "east": true, "south": false, "west": false}}
	var walkers: Array = [{"id": "validation-walker", "edge": ":J0_c0"}]
	if corridor:
		roads.update_lights({"phase": 0, "pedestrians": walkers, "junctions": {"J0": live, "J1": live, "J2": live}})
	else:
		var packet: Dictionary = live.duplicate()
		packet["pedestrians"] = walkers
		roads.update_lights(packet)
	var j0: Node = ped_groups[0]
	check(j0.modes["north"] == "flash" and j0.modes["east"] == "walk" and j0.modes["south"] == "stop", "Live crossing states not shown: " + str(j0.modes))
	var before: bool = j0.heads["north"][0]["hand"]["on"]
	j0._process(0.5)
	check(j0.heads["north"][0]["hand"]["on"] != before, "Flashing hand does not flash")
	check(j0.heads["south"][0]["hand"]["on"] and not j0.heads["south"][0]["person"]["on"], "Steady hand went dark")
	check(j0.heads["east"][0]["person"]["on"] and not j0.heads["east"][0]["hand"]["on"], "WALK not shown on a green crossing")

func _check_sensors(scene: Node3D, roads: Node3D, corridor: bool) -> void:
	# One signal cabinet per junction (no per-pole boxes), beside its south pole.
	var cabinets: int = 0
	for child in roads.get_children():
		if String(child.name).begins_with("SignalCabinet_"):
			cabinets += 1
	check(cabinets == (3 if corridor else 1), "Expected one signal cabinet per junction, found " + str(cabinets))
	for jid in (["J0", "J1", "J2"] if corridor else ["J0"]):
		check(roads.has_node("SignalCabinet_" + jid), "Missing junction signal cabinet: " + jid)
		check(roads.has_node("CableRoutes_" + jid), "Missing cable routes for junction: " + jid)
		var south: Node3D = roads.get_node(("TL_%s_south" % jid) if corridor else "TrafficLight_south")
		check(roads.get_node("SignalCabinet_" + jid).global_position.distance_to(south.global_position) < 1.5, "Cabinet is not beside its south pole: " + jid)
	for pole in roads.get_children():
		if not pole.has_meta("arm_length"):
			continue
		check(not pole.has_node("Sensor_Cabinet"), "A per-pole cabinet is still built: " + pole.name)
		for sensor in ["Sensor_CCTV", "Sensor_Radar", "PullBox", "SightlinePivot"]:
			check(pole.has_node(sensor), "Missing sensor hardware: " + sensor)
		var camera: Node3D = pole.get_node("Sensor_CCTV")
		check(camera.global_basis.z.y < -0.1, "CCTV is not aimed down the approach")
		var lens_position := camera.to_global(Vector3(0, 0, 0.254))
		check(lens_position.distance_to(pole.get_node("SightlinePivot").global_position) < 0.001, "Coverage cone does not begin at the camera lens")
	var sensor_builder: Node = scene.get_node("SensorBuilder")
	sensor_builder.toggle_sightlines()
	for pivot in sensor_builder.get("_sightline_pivots"):
		check(pivot.visible, "Sensor sightline toggle failed")
	sensor_builder.toggle_sightlines()

func _check_signs(scene: Node3D, corridor: bool) -> void:
	var signs: Node3D = scene.get_node("BillboardBuilder")
	var count: int = 0
	for child in signs.get_children():
		if child.name.begins_with("DirectionSign"):
			count += 1
	check(count == (6 if corridor else 2), "Direction signs failed to build")
	var kit: Node3D = scene.get_node("EnvironmentBuilder/DetailedStreetscape")
	for spec in Layout.billboards(corridor):
		var plot: Rect2 = Layout.plot(spec)
		for body in kit.get_children():
			if not body is StaticBody3D:
				continue
			var collider: CollisionShape3D = body.get_child(0)
			var size: Vector3 = collider.shape.size
			var tx: Transform3D = collider.global_transform
			var half: Vector3 = (tx.basis.x.abs() * size.x + tx.basis.z.abs() * size.z) * 0.5
			var bounds := Rect2(tx.origin.x - half.x, tx.origin.z - half.z, half.x * 2.0, half.z * 2.0)
			check(not plot.intersects(bounds), "A building/wall occupies a billboard's reserved plot: " + str(bounds))
	scene.get_node("TimeOfDayManager").set_time(20.0)
	for material in signs.get("_print_materials"):
		check(material.emission_energy_multiplier > 0.0, "Billboard night lighting missing")
	scene.get_node("TimeOfDayManager").set_time(12.0)
	for material in signs.get("_print_materials"):
		check(is_zero_approx(material.emission_energy_multiplier), "Billboard glows in daylight")

func _check_walkers(manager: Node3D, corridor: bool) -> void:
	manager.set_process(false)
	var original: Array = manager.get("_ambient_peds")
	check(original.size() == (64 if corridor else 42), "Ambient pedestrians missing")
	var a: Dictionary = original[0]
	var b: Dictionary = original[1]
	a["path_idx"] = 0
	b["path_idx"] = 0
	a["progress"] = 0.4
	b["progress"] = 0.42
	a["forward"] = true
	b["forward"] = false
	for ped in [a, b]:
		ped["speed"] = 0.55
		ped["velocity"] = 0.55
		ped["pause"] = 0.0
		ped["next_pause"] = 100.0
		manager.call("_update_ambient_position", ped, 1.0, true)
	manager.set("_ambient_peds", [a, b])
	var closest: float = INF
	for frame in range(300):
		manager.call("_move_ambient", a, 1.0 / 60.0)
		manager.call("_move_ambient", b, 1.0 / 60.0)
		closest = minf(closest, a["node"].position.distance_to(b["node"].position))
		for ped in [a, b]:
			check(ped["progress"] >= 0.0 and ped["progress"] <= 1.0, "Walker leaves sidewalk path")
	check(closest > 0.31, "Opposing pedestrians overlap while passing")
	check(a["progress"] > b["progress"], "Opposing pedestrians could not pass")
	a["progress"] = 0.9999
	a["forward"] = true
	a["pause"] = 0.0
	manager.call("_update_ambient_position", a, 1.0, true)
	var yaw_before: float = a["node"].rotation.y
	manager.call("_move_ambient", a, 1.0 / 60.0)
	check(not a["forward"] and a["pause"] > 0.0, "Walker does not pause to turn at the path end")
	check(absf(angle_difference(yaw_before, a["node"].rotation.y)) < 0.3, "Walker snaps through a 180-degree turn")
	manager.set("_ambient_peds", original)
	manager.set_pedestrians_enabled(false)
	for ped in original:
		check(not ped["node"].visible, "Pedestrian toggle left a walker visible")
	manager.set_pedestrians_enabled(true)

func _check_crossings(manager: Node3D) -> void:
	# Exercise legacy packets too: new headings must not snap on packet arrival.
	var packet := {"id": "validation-ped", "x": 1500.0, "y": 1500.0, "angle": 0.0, "edge": ":J0_c0"}
	manager.update_crossing_pedestrians([packet])
	var actor: Node3D = manager.get("_crossing_peds")["validation-ped"]["node"]
	check(is_equal_approx(actor.position.y, 0.055), "Crossing pedestrian floats above the road")
	packet["x"] = 1501.0
	packet["angle"] = 90.0
	manager.update_crossing_pedestrians([packet])
	check(is_zero_approx(actor.rotation.y), "Incoming pedestrian packet snaps the heading")
	manager.call("_process", 1.0 / 60.0)
	check(actor.position.x < 0.0 and actor.rotation.y < 0.0 and actor.rotation.y > -0.3, "Crossing motion or smoothed heading is reversed")
	check(actor.get("stride_blend") > 0.0, "Moving crossing pedestrian is not animated")
	for i in range(180):
		manager.call("_process", 1.0 / 60.0)
	check(actor.get("stride_blend") < 0.001, "Stopped crossing pedestrian keeps walking")
	manager.update_crossing_pedestrians([])
	check(not actor.visible and manager.get("_crossing_peds").is_empty(), "Departed crossing pedestrian remains visible")
	packet["id"] = "validation-reuse"
	manager.update_crossing_pedestrians([packet])
	check(manager.get("_crossing_peds")["validation-reuse"]["node"] == actor and actor.visible, "Crossing pedestrian pool does not reuse its actor")
	manager.update_crossing_pedestrians([])
