extends Node3D
## Printed roadside advertising on reserved plots, plus legible wayfinding.
const G = preload("res://scripts/PropGeometry.gd")
const Layout = preload("res://scripts/StreetSignLayout.gd")
const ART = [preload("res://assets/signs/valiborn.svg"), preload("res://assets/signs/akwaaba.svg"), preload("res://assets/signs/connect.svg")]
const COPY = [
	["VALIBORN", "Smarter streets.\nBetter journeys.", "TECHNOLOGY FOR EVERYDAY LIFE"],
	["AKWAABA", "Made for\neveryday Accra.", "LOCAL SHOPS  /  LOCAL STORIES"],
	["ACCRA CONNECT", "Your city.\nConnected.", "PEOPLE  /  PLACES  /  POSSIBILITIES"]]
@export var corridor_mode: bool = true
var _print_materials: Array[StandardMaterial3D] = []
var _floodlights: Array[SpotLight3D] = []
var _lettering: Array[Label3D] = []
var _direction_count: int = 0

func _ready() -> void:
	for spec in Layout.billboards(corridor_mode):
		_billboard(spec)
	var centers: Array = [0.0, 30.0, 60.0] if corridor_mode else [0.0]
	var streets: Array = ["AGGREY ST", "ASYLUM DOWN", "NIMA ROAD"] if corridor_mode else ["AGGREY ST"]
	for i in range(centers.size()):
		var offset: float = 5.4 if corridor_mode else 6.3
		_wayfinding(Vector3(offset, 0, centers[i] + 10.0), 0.0, streets[i], "NSAWAM RD")
		_wayfinding(Vector3(-offset, 0, centers[i] - 10.0), PI, "ACHIMOTA", "ACCRA")
	var clock: Node = get_parent().get_node_or_null("TimeOfDayManager")
	if clock:
		clock.time_changed.connect(_time_changed)
		_time_changed(clock.time_of_day)
	print("[StreetSigns] ", Layout.billboards(corridor_mode).size(), " reserved billboard plots; ", centers.size() * 2, " direction signs")

func _billboard(spec: Dictionary) -> void:
	var root := Node3D.new()
	root.name = "Billboard_" + str(spec["design"])
	root.position = spec["position"]
	root.rotation.y = spec["yaw"]
	root.set_meta("reserved_plot", Layout.plot(spec))
	add_child(root)
	var steel := G.solid(Color("656b62"), 0.7, 0.48)
	var dark := G.solid(Color("303d37"), 0.5, 0.6)
	var w: float = 4.8
	var h: float = 2.25
	var cy: float = 3.775
	G.box(root, Vector3(0, -0.005, 0), Vector3(4.9, 0.075, 2.3), G.solid(Color("8d8877")), "ServiceApron")
	G.box(root, Vector3(0, 0.15, -0.16), Vector3(0.7, 0.32, 0.65), G.solid(Color("9c9786")), "Foundation")
	G.segment(root, Vector3(0, 0.3, -0.16), Vector3(0, cy + h * 0.38, -0.16), 0.13, steel, "Monopole", 0.85)
	for x in [-w * 0.4, w * 0.4]:
		G.segment(root, Vector3(0, 2.2, -0.16), Vector3(x, cy + 0.35, -0.16), 0.035, steel, "BackBrace")
	G.rounded_box(root, Vector3(0, cy, 0), Vector3(w + 0.15, h + 0.15, 0.16), 0.055, dark, "PanelFrame")
	var print_material := StandardMaterial3D.new()
	print_material.albedo_texture = ART[spec["design"]]
	print_material.roughness = 0.85
	print_material.emission_enabled = true
	print_material.emission_texture = ART[spec["design"]]
	print_material.emission = Color.WHITE
	print_material.emission_energy_multiplier = 0.0
	_print_materials.append(print_material)
	var quad := QuadMesh.new()
	quad.size = Vector2(w, h)
	G.instance(root, quad, Vector3(0, cy, 0.086), print_material, "PrintedArtwork")
	var ink: Color = Color("f2e8ce") if spec["design"] != 1 else Color("253f37")
	var content: Array = COPY[spec["design"]]
	_lettering.append(G.label(root, content[0], Vector3(-0.68, cy + 0.67, 0.094), 2.85, 0.24, ink, "Brand"))
	_lettering.append(G.label(root, content[1], Vector3(-0.68, cy - 0.02, 0.094), 2.9, 0.85, ink, "Headline"))
	_lettering.append(G.label(root, content[2], Vector3(-0.68, cy - 0.81, 0.094), 2.65, 0.12, ink, "Footer"))
	# Rear rails and a service ledge make the back of the panel a real structure.
	for y in [cy - h * 0.33, cy + h * 0.33]:
		G.box(root, Vector3(0, y, -0.14), Vector3(w, 0.09, 0.09), steel, "RearRail")
	G.box(root, Vector3(0, cy - h * 0.5 - 0.14, -0.3), Vector3(w * 0.85, 0.04, 0.4), steel, "ServiceLedge")
	for x in [-1.5, 1.5]:
		G.segment(root, Vector3(x, cy + h * 0.5, 0), Vector3(x, cy + h * 0.5 + 0.22, 0.65), 0.022, dark, "FloodlightArm")
		var fixture := G.rounded_box(root, Vector3(x, cy + h * 0.5 + 0.18, 0.68), Vector3(0.22, 0.065, 0.15), 0.02, dark, "Floodlight")
		fixture.rotation.x = -0.65
		var light := SpotLight3D.new()
		light.position = Vector3(x, cy + h * 0.5 + 0.16, 0.72)
		light.rotation.x = -atan2(h * 0.5, 0.72)
		light.spot_range = 4.0
		light.spot_angle = 55.0
		light.light_color = Color("ffe7bc")
		light.light_energy = 0.0
		root.add_child(light)
		_floodlights.append(light)
	for x in [-0.24, 0.24]:
		for z in [-0.37, 0.05]:
			G.segment(root, Vector3(x, 0.31, z), Vector3(x, 0.35, z), 0.025, dark, "FoundationBolt")

func _wayfinding(at: Vector3, yaw: float, street: String, through: String) -> void:
	var root := Node3D.new()
	root.position = at
	root.rotation.y = yaw
	root.name = "DirectionSign_%d" % _direction_count
	_direction_count += 1
	add_child(root)
	var steel := G.solid(Color("8b9388"), 0.7, 0.4)
	var green := G.solid(Color("214b3f"), 0.1, 0.7)
	var white := G.solid(Color("e4e2cf"), 0.15, 0.64)
	G.segment(root, Vector3(0, 0, 0), Vector3(0, 2.72, 0), 0.043, steel, "Signpost")
	G.rounded_box(root, Vector3(0, 2.17, 0.025), Vector3(2.15, 0.89, 0.07), 0.065, white, "ReflectiveBorder")
	G.rounded_box(root, Vector3(0, 2.17, 0.068), Vector3(2.08, 0.82, 0.025), 0.05, green, "DirectionPanel")
	G.label(root, "←", Vector3(-0.78, 2.37, 0.088), 0.32, 0.25, Color("efefdb"))
	G.label(root, street, Vector3(0.16, 2.37, 0.088), 1.43, 0.19, Color("efefdb"))
	G.label(root, "↑", Vector3(-0.78, 1.99, 0.088), 0.27, 0.27, Color("efefdb"))
	G.label(root, through, Vector3(0.16, 1.99, 0.088), 1.43, 0.19, Color("efefdb"))
	G.box(root, Vector3(0, 2.18, 0.09), Vector3(1.9, 0.009, 0.005), white)
	# Street-name blade sits above, physically attached rather than floating over lanes.
	G.rounded_box(root, Vector3(0, 2.83, 0), Vector3(1.6, 0.22, 0.05), 0.025, green, "StreetBlade")
	G.label(root, "ACHIMOTA · ACCRA", Vector3(0, 2.83, 0.032), 1.46, 0.12, Color("efefdb"))
	for y in [1.92, 2.45, 2.82]:
		G.segment(root, Vector3(-0.09, y, -0.035), Vector3(0.09, y, -0.035), 0.015, steel, "RearClamp")

func _time_changed(hour: float) -> void:
	var strength: float = smoothstep(17.3, 19.0, hour) if hour >= 12.0 else 1.0 - smoothstep(5.7, 7.0, hour)
	for material in _print_materials:
		material.emission_energy_multiplier = strength * 0.16
	for light in _floodlights:
		light.light_energy = strength * 1.4
