extends Node3D
## Shared curved bodywork and separately animated wheels. Front is local -Z.
## The root is at tyre contact height; traffic uses the existing compressed scale.
const G = preload("res://scripts/PropGeometry.gd")
const PAINTS = [Color("d7d6cb"), Color("334d62"), Color("6e3030"), Color("898f90"), Color("252b2d"), Color("435849")]
static var _body_cache: Dictionary = {}
static var _wheel_mesh: ArrayMesh
var kind: String = "car"
var variant: int = 0
var wheels: Array[Node3D] = []
var _door: Node3D
var _door_blend: float = 0.0
var _spin: float = 0.0
var _steer: float = 0.0
var _body: MeshInstance3D
var _route_label: Label3D
var _brakes: Array[MeshInstance3D] = []
var _lamps: Array[MeshInstance3D] = []
var _beam: SpotLight3D
var _fade_meshes: Array[GeometryInstance3D] = []

func configure(vehicle_kind: String, seed_value: int) -> void:
	kind = vehicle_kind
	variant = absi(seed_value) % 6
	var bus: bool = kind == "trotro"
	scale = Vector3.ONE*(1.4 if bus else 1.1)
	var key := kind + str(variant)
	if not _body_cache.has(key):
		var parts := Node3D.new()
		_build_body(parts, bus)
		_body_cache[key] = _bake(parts)
		parts.free()
	_body = G.instance(self, _body_cache[key], Vector3.ZERO, null, "Bodywork")
	var axle: float = 0.48 if bus else 0.34
	var track: float = 0.31 if bus else 0.248
	if _wheel_mesh == null:
		var parts := Node3D.new()
		var tyre := G.solid(Color("181c1c"), 0, 0.88)
		var alloy := G.solid(Color("989e9b"), 0.78, 0.23)
		G.segment(parts, Vector3(-0.038, 0, 0), Vector3(0.038, 0, 0), 0.112, tyre)
		for side in [-1.0, 1.0]:
			G.segment(parts, Vector3(side * 0.039, 0, 0), Vector3(side * 0.042, 0, 0), 0.076, alloy)
			G.segment(parts, Vector3(side * 0.043, 0, 0), Vector3(side * 0.045, 0, 0), 0.055, tyre)
			for i in range(6):
				var a: float = i * TAU / 6.0
				G.segment(parts, Vector3(side * 0.047, cos(a) * 0.018, sin(a) * 0.018), Vector3(side * 0.047, cos(a) * 0.068, sin(a) * 0.068), 0.008, alloy)
			G.segment(parts, Vector3(side * 0.045, 0, 0), Vector3(side * 0.05, 0, 0), 0.025, alloy)
		_wheel_mesh = _bake(parts)
		parts.free()
	for z in [-axle, axle]:
		for side in [-1.0, 1.0]:
			var pivot := Node3D.new()
			pivot.position = Vector3(side * track, 0.114, z)
			pivot.name = "FrontWheel" if z < 0 else "RearWheel"
			add_child(pivot)
			G.instance(pivot, _wheel_mesh, Vector3.ZERO, null, "Wheel")
			wheels.append(pivot)
	if bus:
		_build_door()
		_route_label = G.label(self, "CIRCLE • ACCRA", Vector3(0, 0.735, -0.744), 0.49, 0.07, Color("252d27"), "Destination")
		_route_label.rotation.y = PI
		_route_label.visibility_range_end = 28
		var plate := G.label(self, "GR %04d–24" % (1000 + absi(seed_value) % 8000), Vector3(0, 0.16, -0.774), 0.20, 0.034, Color("242921"), "Registration")
		plate.rotation.y = PI
		plate.visibility_range_end = 14
	_build_lights(bus)
	_collect_meshes(self)

func _build_body(parts: Node3D, bus: bool) -> void:
	var paint := G.solid(PAINTS[variant], 0.48, 0.34)
	var rubber := G.solid(Color("222b2c"), 0.1, 0.62)
	var chrome := G.solid(Color("a4acab"), 0.8, 0.2)
	var glass := G.solid(Color("172f3a"), 0.68, 0.13)
	var silver := G.solid(Color("8caaa9"), 0.65, 0.17)
	var red := G.solid(Color("641b17"), 0.3, 0.25)
	var amber := G.solid(Color("c8902e"), 0.2, 0.3)
	if bus:
		# Cab-over minibus: round corners, sloping windscreen and raised roof.
		_hull(parts, [Vector4(-0.76, 0.27, 0.15, 0.40), Vector4(-0.66, 0.31, 0.13, 0.46), Vector4(0.63, 0.31, 0.13, 0.46), Vector4(0.76, 0.27, 0.16, 0.44)], paint)
		_hull(parts, [Vector4(-0.67, 0.30, 0.40, 0.52), Vector4(-0.47, 0.295, 0.40, 0.77), Vector4(0.61, 0.295, 0.40, 0.77), Vector4(0.74, 0.27, 0.40, 0.71)], paint)
		_panel(parts, [Vector3(-0.256,0.51,-0.690),Vector3(0.256,0.51,-0.690),Vector3(0.246,0.71,-0.525),Vector3(-0.246,0.71,-0.525)], glass)
		# Continuous side glazing, separated by structural pillars.
		for side in [-1.0, 1.0]:
			for z in [-0.30, 0.045, 0.38]:
				_panel(parts, [Vector3(side*0.302,0.465,z-0.13),Vector3(side*0.302,0.465,z+0.13),Vector3(side*0.285,0.688,z+0.13),Vector3(side*0.285,0.688,z-0.13)], glass)
			G.box(parts, Vector3(side*0.314,0.345,0.02),Vector3(0.012,0.10,1.35), G.solid([Color("bb7837"),Color("bdc3b8"),Color("d0a34c")][variant%3],0.3,0.48),"LiveryStripe")
			G.box(parts,Vector3(side*0.316,0.24,0.02),Vector3(0.012,0.025,1.35),rubber,"SideRubber")
			G.segment(parts,Vector3(side*0.29,0.52,-0.58),Vector3(side*0.39,0.56,-0.58),0.012,rubber)
			G.rounded_box(parts,Vector3(side*0.39,0.59,-0.58),Vector3(0.035,0.11,0.075),0.012,rubber,"Mirror")
			G.box(parts,Vector3(side*0.32,0.415,-0.25),Vector3(0.016,0.018,0.065),chrome,"DoorHandle")
		G.rounded_box(parts,Vector3(0,0.735,-0.728),Vector3(0.54,0.095,0.025),0.013,G.solid(Color("d4c68b")),"RouteBoard")
		G.rounded_box(parts,Vector3(0,0.27,-0.76),Vector3(0.38,0.11,0.025),0.015,rubber,"Grille")
		for y in [0.24,0.275,0.31]:
			G.box(parts,Vector3(0,y,-0.778),Vector3(0.34,0.007,0.012),chrome)
		for side in [-1.0,1.0]:
			G.rounded_box(parts,Vector3(side*0.24,0.34,-0.743),Vector3(0.105,0.085,0.035),0.012,silver,"Headlamp")
			G.box(parts,Vector3(side*0.285,0.33,-0.727),Vector3(0.025,0.07,0.04),amber)
			G.rounded_box(parts,Vector3(side*0.25,0.34,0.752),Vector3(0.055,0.16,0.024),0.012,red,"RearLamp")
		_panel(parts,[Vector3(-0.23,0.47,0.751),Vector3(0.23,0.47,0.751),Vector3(0.22,0.65,0.745),Vector3(-0.22,0.65,0.745)],glass)
		G.rounded_box(parts,Vector3(0,0.155,-0.762),Vector3(0.22,0.055,0.02),0.008,G.solid(Color("d8b540")),"Plate")
		for z in [-0.755,0.755]:
			G.rounded_box(parts,Vector3(0,0.19,z),Vector3(0.61,0.08,0.065),0.025,rubber,"Bumper")
		# Roof rack rails and practical load bars.
		for side in [-1.0,1.0]:
			G.segment(parts,Vector3(side*0.25,0.81,-0.34),Vector3(side*0.25,0.81,0.59),0.012,chrome)
		for z in [-0.3,0.08,0.53]:
			G.segment(parts,Vector3(-0.25,0.81,z),Vector3(0.25,0.81,z),0.011,chrome)
	else:
		var roof: float = 0.52 if variant%3 == 1 else 0.44
		_hull(parts,[Vector4(-0.61,0.20,0.15,0.24),Vector4(-0.51,0.255,0.12,0.29),Vector4(-0.20,0.265,0.12,0.30),Vector4(0.36,0.26,0.12,0.30),Vector4(0.59,0.22,0.15,0.27)],paint)
		_hull(parts,[Vector4(-0.25,0.24,0.28,0.30),Vector4(-0.07,0.207,0.28,roof),Vector4(0.23,0.205,0.28,roof),Vector4(0.43,0.23,0.27,0.29)],paint)
		_panel(parts,[Vector3(-0.22,0.309,-0.249),Vector3(0.22,0.309,-0.249),Vector3(0.187,roof+0.006,-0.076),Vector3(-0.187,roof+0.006,-0.076)],glass)
		_panel(parts,[Vector3(-0.19,roof+0.005,0.24),Vector3(0.19,roof+0.005,0.24),Vector3(0.209,0.30,0.425),Vector3(-0.209,0.30,0.425)],glass)
		for side in [-1.0,1.0]:
			_panel(parts,[Vector3(side*0.247,0.31,-0.22),Vector3(side*0.245,0.31,0.075),Vector3(side*0.208,roof-0.02,0.075),Vector3(side*0.208,roof-0.02,-0.058)],glass)
			_panel(parts,[Vector3(side*0.245,0.31,0.10),Vector3(side*0.24,0.31,0.38),Vector3(side*0.208,roof-0.02,0.22),Vector3(side*0.208,roof-0.02,0.10)],glass)
			G.segment(parts,Vector3(side*0.245,0.315,-0.17),Vector3(side*0.31,0.335,-0.19),0.012,rubber)
			G.rounded_box(parts,Vector3(side*0.31,0.345,-0.19),Vector3(0.06,0.045,0.065),0.016,paint,"Mirror")
			for z in [0.035,0.29]:
				G.box(parts,Vector3(side*0.264,0.285,z),Vector3(0.012,0.014,0.052),chrome,"Handle")
			G.segment(parts,Vector3(side*0.264,0.15,0.10),Vector3(side*0.264,0.30,0.10),0.003,rubber,"DoorSeam")
			G.rounded_box(parts,Vector3(side*0.174,0.252,-0.567),Vector3(0.135,0.055,0.05),0.016,silver,"Headlamp")
			G.rounded_box(parts,Vector3(side*0.181,0.25,0.57),Vector3(0.12,0.06,0.035),0.013,red,"TailLamp")
		G.rounded_box(parts,Vector3(0,0.21,-0.61),Vector3(0.24,0.055,0.018),0.012,rubber,"Grille")
		for z in [-0.596,0.578]:
			G.rounded_box(parts,Vector3(0,0.16,z),Vector3(0.44,0.035,0.04),0.013,rubber,"Bumper")
		G.rounded_box(parts,Vector3(0,0.17,-0.628),Vector3(0.15,0.035,0.007),0.005,G.solid(Color("d6d5c8")),"RegistrationPlate")
		for side in [-1.0,1.0]:
			for axle in [-0.34,0.34]:
				for i in range(12):
					var a: float = i*PI/12
					var b: float = (i+1)*PI/12
					G.segment(parts,Vector3(side*0.267,0.114+sin(a)*0.122,axle+cos(a)*0.122),Vector3(side*0.267,0.114+sin(b)*0.122,axle+cos(b)*0.122),0.007,rubber,"WheelArch")
			G.segment(parts,Vector3(side*0.261,0.153,-0.18),Vector3(side*0.261,0.153,0.19),0.006,chrome,"SillTrim")
		# A restrained taxi variant uses yellow front/rear quarter panels.
		if variant == 5:
			for side in [-1.0,1.0]:
				G.box(parts,Vector3(side*0.264,0.225,-0.36),Vector3(0.009,0.10,0.18),amber,"TaxiQuarter")
			G.rounded_box(parts,Vector3(0,roof+0.03,0.05),Vector3(0.16,0.055,0.07),0.012,amber,"TaxiSign")
	# Windscreen wipers stay outside the glass plane.
	for side in [-1.0,1.0]:
		var base := Vector3(side*0.13,0.485,-0.687) if bus else Vector3(side*0.10,0.32,-0.241)
		G.segment(parts,base,base+Vector3(0.09,0.025,0.025),0.005,rubber,"Wiper")

func _build_door() -> void:
	_door = Node3D.new()
	_door.name = "SlidingDoor"
	add_child(_door)
	# Opening is represented by a dark inset; the panel slides rearward along rails.
	G.box(self,Vector3(0.316,0.44,0.04),Vector3(0.012,0.48,0.32),G.solid(Color("141d1d")),"DoorRecess")
	G.box(_door,Vector3(0.326,0.34,0.04),Vector3(0.02,0.26,0.32),G.solid(PAINTS[variant],0.48,0.34),"DoorPanel")
	G.box(_door,Vector3(0.327,0.57,0.04),Vector3(0.022,0.21,0.32),G.solid(Color("172f3a"),0.68,0.13),"DoorWindow")
	G.box(_door,Vector3(0.34,0.345,0.04),Vector3(0.012,0.10,0.32),G.solid([Color("bb7837"),Color("bdc3b8"),Color("d0a34c")][variant%3],0.3,0.48),"DoorStripe")
	for z in [-0.12,0.20]:
		G.box(_door,Vector3(0.341,0.57,z),Vector3(0.014,0.23,0.016),G.solid(PAINTS[variant],0.48,0.34),"DoorFrame")
	G.box(_door,Vector3(0.342,0.41,-0.065),Vector3(0.015,0.02,0.06),G.solid(Color("a4acab"),0.8,0.2),"DoorHandle")
	G.box(self,Vector3(0.36,0.17,0.04),Vector3(0.13,0.025,0.31),G.solid(Color("353d39")),"BoardingStep")

func _build_lights(bus: bool) -> void:
	for side in [-1.0,1.0]:
		var glow := G.solid(Color("fff0cf"),0.1,0.2).duplicate() as StandardMaterial3D
		glow.emission_enabled = true
		glow.emission = Color("fff0cf")
		glow.emission_energy_multiplier = 2.0
		var lamp := G.rounded_box(self,Vector3(side*(0.24 if bus else 0.174),0.34 if bus else 0.252,-0.763 if bus else -0.594),Vector3(0.085,0.045,0.008),0.012,glow,"Headlight")
		lamp.visible = false
		_lamps.append(lamp)
		var red := G.solid(Color("e52c19")).duplicate() as StandardMaterial3D
		red.emission_enabled = true
		red.emission = Color("e52c19")
		red.emission_energy_multiplier = 1.5
		var brake := G.rounded_box(self,Vector3(side*(0.25 if bus else 0.181),0.34 if bus else 0.25,0.767 if bus else 0.592),Vector3(0.04 if bus else 0.10,0.12 if bus else 0.04,0.008),0.008,red,"BrakeLight")
		brake.visible = false
		_brakes.append(brake)
	_beam = SpotLight3D.new()
	_beam.position = Vector3(0,0.31,-0.78 if bus else -0.62)
	_beam.rotation.x = -0.15
	_beam.light_color = Color("ffe7bc")
	_beam.light_energy = 1.5
	_beam.spot_range = 7
	_beam.spot_angle = 32
	_beam.distance_fade_enabled = true
	_beam.distance_fade_begin = 18
	_beam.distance_fade_length = 12
	_beam.visible = false
	add_child(_beam)

func animate(distance: float, yaw_delta: float, delta: float, lights: bool, braking: bool, boarding: bool) -> void:
	_spin = fposmod(_spin - distance / (0.112*scale.x), TAU)
	_steer = lerpf(_steer,clampf(yaw_delta/maxf(distance,0.015)*0.3,-0.42,0.42),1.0-exp(-delta*8))
	for i in range(wheels.size()):
		wheels[i].rotation.y = _steer if i < 2 else 0.0
		wheels[i].get_child(0).rotation.x = _spin
	_door_blend = move_toward(_door_blend,1.0 if boarding else 0.0,delta*1.5)
	if _door:
		_door.position = Vector3(0.02*_door_blend,0,0.34*_door_blend)
	for lamp in _lamps:
		lamp.visible = lights
	for brake in _brakes:
		brake.visible = lights or braking
	_beam.visible = lights

func set_destination(text: String) -> void:
	if _route_label:
		_route_label.text = text
		var font := ThemeDB.fallback_font
		_route_label.pixel_size = minf(0.49/maxf(font.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,64).x,1),0.07/font.get_height(64))

func set_opacity(value: float) -> void:
	for mesh in _fade_meshes:
		mesh.transparency = 1.0-value

func _collect_meshes(node: Node) -> void:
	if node is GeometryInstance3D:
		_fade_meshes.append(node)
	for child in node.get_children():
		_collect_meshes(child)

static func _bake(parts: Node3D) -> ArrayMesh:
	var groups: Dictionary = {}
	for node in parts.get_children():
		if not node is MeshInstance3D:
			continue
		var material: Material = node.material_override
		if not groups.has(material):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			groups[material] = st
		groups[material].append_from(node.mesh,0,node.transform)
	var mesh := ArrayMesh.new()
	for material in groups:
		groups[material].set_material(material)
		groups[material].commit(mesh)
	return mesh

static func _panel(parent: Node3D, vertices: Array[Vector3], material: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var normal := (vertices[1]-vertices[0]).cross(vertices[2]-vertices[0])
	var center := (vertices[0]+vertices[1]+vertices[2]+vertices[3])*0.25
	if normal.dot(center-Vector3(0,0.35,0)) < 0:
		vertices.reverse()
	G.triangle(st,vertices[0],vertices[1],vertices[2])
	G.triangle(st,vertices[0],vertices[2],vertices[3])
	# Panels occur on both sides and windscreens; double-sided glazing is intentional.
	var mat := material as StandardMaterial3D
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	G.instance(parent,st.commit(),Vector3.ZERO,mat,"Glazing")

static func _hull(parent: Node3D, rings: Array[Vector4], material: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows: Array = []
	for ring in rings:
		var w: float = ring.y
		var lo: float = ring.z
		var hi: float = ring.w
		var r: float = minf(0.035,(hi-lo)*0.2)
		rows.append([Vector3(-w+r,lo,ring.x),Vector3(w-r,lo,ring.x),Vector3(w,lo+r,ring.x),Vector3(w,hi-r,ring.x),Vector3(w-r,hi,ring.x),Vector3(-w+r,hi,ring.x),Vector3(-w,hi-r,ring.x),Vector3(-w,lo+r,ring.x)])
	for row in range(rows.size()-1):
		for i in range(8):
			var a: Vector3 = rows[row][i]
			var b: Vector3 = rows[row][(i+1)%8]
			var c: Vector3 = rows[row+1][i]
			var d: Vector3 = rows[row+1][(i+1)%8]
			G.triangle(st,a,b,c)
			G.triangle(st,b,d,c)
	for end in [0,rows.size()-1]:
		var center := Vector3(0,(rings[end].z+rings[end].w)*0.5,rings[end].x)
		for i in range(8):
			if end == 0:
				G.triangle(st,center,rows[end][(i+1)%8],rows[end][i])
			else:
				G.triangle(st,center,rows[end][i],rows[end][(i+1)%8])
	st.index()
	st.generate_normals()
	G.instance(parent,st.commit(),Vector3.ZERO,material,"Coachwork")
