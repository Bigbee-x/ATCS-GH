extends Node3D
## Stations and passenger presentation; stops and boarding come from SUMO.
const Layout = preload("res://scripts/TransitLayout.gd")
const G = preload("res://scripts/PropGeometry.gd")
const Surfaces = preload("res://scripts/StreetscapeMaterials.gd")
const Person = preload("res://scripts/PedestrianActor.gd")
const Fleet = preload("res://scripts/VehicleActor.gd")
@export var corridor_mode: bool = false
var _stations: Dictionary = {}
var _passengers: Dictionary = {}
var _lights: Array[OmniLight3D] = []
var _enabled: bool = true
var boarded_total: int = 0
var _vehicle_manager: Node3D

func _ready() -> void:
	_vehicle_manager = get_parent().get_node("VehicleManager")
	for spec in Layout.stations(corridor_mode):
		_build_station(spec)
	var clock: Node = get_parent().get_node("TimeOfDayManager")
	clock.night_mode_changed.connect(_night)
	_night(clock.is_night())

func _build_station(spec: Dictionary) -> void:
	var s: float = spec["side"]
	var outer: float = spec["road_half"]+spec["sidewalk"]
	var root := Node3D.new()
	root.name = spec["id"]
	root.position = Vector3(s*(outer+2.7),0,spec["z"])
	root.rotation.y = -s*PI/2
	root.set_meta("reserved_plot",Layout.plot(spec))
	add_child(root)
	_stations[spec["id"]] = {"spec":spec,"root":root}
	var concrete := Surfaces.surface(2,Color("a8a18c"))
	var steel := G.solid(Color("4a6058"),0.65,0.5)
	var cream := G.solid(Color("ddd1aa"),0.1,0.65)
	var wood := G.solid(Color("77563a"),0,0.87)
	G.box(root,Vector3(0,0.045,-0.6),Vector3(12,0.11,6.0),Surfaces.surface(1,Color("5d6054")),"StationApron")
	G.box(root,Vector3(0,0.10,0.45),Vector3(7.8,0.20,2.1),concrete,"WaitingPlatform")
	for x in [-3.5,0.0,3.5]:
		for z in [-0.4,1.6]:
			G.segment(root,Vector3(x,0.2,z),Vector3(x,2.05,z),0.055,steel,"ShelterColumn")
		G.segment(root,Vector3(x,1.75,-0.4),Vector3(x,2.12,1.7),0.045,steel,"RoofRafter")
	var roof := G.box(root,Vector3(0,2.13,0.6),Vector3(8.2,0.08,2.8),Surfaces.surface(4,Color("74634e")),"CorrugatedCanopy")
	roof.rotation.x = -0.07
	for x in [-2.0,1.6]:
		G.box(root,Vector3(x,0.46,0.0),Vector3(2.3,0.09,0.34),wood,"BenchSeat")
		G.box(root,Vector3(x,0.70,-0.18),Vector3(2.3,0.30,0.055),wood,"BenchBack")
		for dx in [-0.85,0.85]:
			G.segment(root,Vector3(x+dx,0.2,0),Vector3(x+dx,0.45,0),0.045,steel)
	G.rounded_box(root,Vector3(0,1.79,1.68),Vector3(6.3,0.46,0.09),0.035,steel,"StationNameBoard")
	G.label(root,spec["name"],Vector3(0,1.85,1.735),5.6,0.22,Color("eee3c6"))
	G.label(root,"TROTRO • "+spec["destination"],Vector3(0,1.66,1.738),5.6,0.115,Color("d8bd68"))
	# Route desk and notice board sit behind the continuous walking strip.
	G.box(root,Vector3(-4.5,0.6,-0.3),Vector3(1.25,1.0,1.0),cream,"DispatchDesk")
	G.box(root,Vector3(-4.5,1.13,-0.3),Vector3(1.4,0.07,1.12),wood,"Counter")
	G.label(root,"ROUTE DESK",Vector3(-4.5,0.82,0.21),1.0,0.15,Color("384a41"))
	G.rounded_box(root,Vector3(4.6,1.15,0.6),Vector3(0.80,1.25,0.06),0.03,steel,"RouteTotem")
	G.label(root,"TRO\nTRO",Vector3(4.6,1.45,0.64),0.62,0.46,Color("efdeaa"))
	G.label(root,"BOARD\nHERE",Vector3(4.6,0.98,0.64),0.62,0.25,Color("efdeaa"))
	G.segment(root,Vector3(4.6,0.1,0.6),Vector3(4.6,1.9,0.6),0.04,steel)
	# Mark the curbside loading zone, keeping through lanes and crosswalks free.
	var bay_x: float = float(spec.get("bay_x", s*(spec["road_half"]-0.58)))
	var bay_y: float = 0.16 if spec.get("parking", false) else 0.064
	if spec.get("parking", false):
		G.box(self, Vector3(s*(spec["road_half"]+0.85),0.135,spec["z"]), Vector3(1.7,0.03,12), Surfaces.surface(1,Color("50564f")), "OffRoadBoardingBay")
	for z in [spec["z"]-2.6,spec["z"]+2.6]:
		G.box(self,Vector3(bay_x,bay_y,z),Vector3(1.12,0.012,0.055),G.solid(Color("d4b95b")),"BayEndMark")
	for i in range(7):
		G.box(self,Vector3(bay_x-s*0.56,bay_y,spec["z"]-2.4+i*0.8),Vector3(0.04,0.012,0.4),G.solid(Color("d4b95b")),"BayEdgeMark")
	# A spare minibus stands in the station yard, with a mate by the desk.
	var parked := Fleet.new()
	parked.configure("trotro",int(abs(spec["z"])*7))
	parked.position = Vector3(2.8,0.11,-2.1)
	parked.rotation.y = -0.3
	parked.set_destination(spec["destination"])
	root.add_child(parked)
	var mate := Person.new()
	mate.configure(83+int(abs(spec["z"])))
	mate.position = Vector3(-3.6,0.20,0.8)
	root.add_child(mate)
	_stations[spec["id"]]["mate"] = mate
	var light := OmniLight3D.new()
	light.position = Vector3(0,1.8,0.6)
	light.light_color = Color("ffe4a2")
	light.omni_range = 5
	light.shadow_enabled = false
	root.add_child(light)
	_lights.append(light)

func update_transit(data: Dictionary) -> void:
	if data.is_empty():
		return
	boarded_total = int(data.get("boarded_total",0))
	var seen: Dictionary = {}
	for state in data.get("stations",[]):
		var id: String = state["id"]
		if not _stations.has(id):
			continue
		var spec: Dictionary = _stations[id]["spec"]
		var index: int = 0
		for pid in state.get("waiting",[]):
			seen[pid] = true
			if not _passengers.has(pid):
				var actor := Person.new()
				actor.configure(str(pid).hash())
				var waiting_x: float = float(spec.get("bay_x", spec["side"]*spec["road_half"])) + spec["side"]*0.85
				actor.position = Vector3(waiting_x,0.205 if spec.get("parking",false) else 0.15,spec["z"]+(index+1)*0.52)
				actor.rotation.y = -spec["side"]*PI/2
				actor.visible = _enabled
				add_child(actor)
				_passengers[pid] = {"node":actor,"boarding":false,"vehicle":state["vehicle_id"],"delay":0.0}
			index += 1
		index = 0
		for pid in state.get("onboard",[]):
			seen[pid] = true
			if _passengers.has(pid) and not _passengers[pid]["boarding"]:
				_passengers[pid]["boarding"] = true
				_passengers[pid]["delay"] = index*0.65
				index += 1
	for pid in _passengers.keys():
		if not seen.has(pid):
			_passengers[pid]["node"].queue_free()
			_passengers.erase(pid)

func _process(delta: float) -> void:
	for station in _stations.values():
		station["mate"].animate(0,0,delta)
	for pid in _passengers.keys():
		var passenger: Dictionary = _passengers[pid]
		var actor: Node3D = passenger["node"]
		var before: Vector3 = actor.position
		if passenger["boarding"]:
			passenger["delay"] -= delta
			var fleet: Dictionary = _vehicle_manager.get("_active")
			if passenger["delay"] <= 0 and fleet.has(passenger["vehicle"]):
				var bus: Node3D = fleet[passenger["vehicle"]]["node"]
				# Wait for the delayed vehicle playback to reach the stop and open its door.
				var coach: Node3D = bus.get_node_or_null("Coach")
				if coach and coach.get("_door_blend") > 0.6:
					var door := coach.to_global(Vector3(0.35,0.17,0.04))
					actor.position = actor.position.move_toward(door,delta*0.6)
					if actor.position.distance_to(door) < 0.45:
						actor.scale.y = lerpf(actor.scale.y,actor.character_scale*0.78,1.0-exp(-delta*8))
						actor.rotation.x = lerpf(actor.rotation.x,0.12,1.0-exp(-delta*8))
					var d := door-before
					actor.rotation.y = lerp_angle(actor.rotation.y,atan2(d.x,d.z),1-exp(-delta*8))
					if actor.position.distance_to(door) < 0.06:
						actor.visible = false
		var distance: float = actor.position.distance_to(before)
		actor.animate(distance,distance/maxf(delta,0.001),delta)

func set_passengers_enabled(enabled: bool) -> void:
	_enabled = enabled
	for passenger in _passengers.values():
		passenger["node"].visible = enabled and not passenger["boarding"]
	for station in _stations.values():
		station["mate"].visible = enabled

func reset() -> void:
	for passenger in _passengers.values():
		passenger["node"].queue_free()
	_passengers.clear()
	boarded_total = 0

func _night(enabled: bool) -> void:
	for light in _lights:
		light.light_energy = 0.8 if enabled else 0.0
