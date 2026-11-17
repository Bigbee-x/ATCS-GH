extends Node3D
## Original narrow-body airliner, parked pose; nose -Z, origin at pavement.
const G = preload("res://scripts/PropGeometry.gd")
var _white := G.solid(Color("d7dfdc"), 0.15, 0.32)
var _navy := G.solid(Color("245568"), 0.2, 0.4)
var _metal := G.solid(Color("89999c"), 0.8, 0.26)
var _dark := G.solid(Color("142127"), 0.1, 0.65)
var _glass := G.solid(Color("284653"), 0.6, 0.14)

func _ready() -> void:
	_fuselage()
	for side in [-1.0, 1.0]:
		_wing(side, 0.0, 1.04, 5.2, 2.2)
		_wing(side, 4.5, 1.55, 2.05, 1.1)
		_engine(Vector3(side * 1.85, 0.76, 0.05))
		for i in range(18):
			G.ellipsoid(self, Vector3(side * 0.533, 1.47, -3.80 + i * 0.42), Vector3(0.025, 0.115, 0.085), _glass, "CabinWindow")
		G.segment(self, Vector3(side * 0.533, 1.13, -4.0), Vector3(side * 0.533, 1.13, 3.85), 0.030, _navy, "LiveryStripe")
		for z in [-4.38, 3.98]:
			var door := G.rounded_box(self, Vector3(side * 0.53, 1.34, z), Vector3(0.35, 0.68, 0.014), 0.06, _metal, "DoorOutline")
			door.rotation.y = side * PI * 0.5
			var panel := G.rounded_box(self, Vector3(side * 0.542, 1.34, z), Vector3(0.30, 0.62, 0.014), 0.05, _white, "PassengerDoor")
			panel.rotation.y = side * PI * 0.5
		var brand := G.label(self, "ACCRA AIR", Vector3(side * 0.54, 1.63, -2.3), 2.1, 0.16, Color("224f5e"), "IllustrativeLivery")
		brand.rotation.y = side * PI * 0.5
		_gear(Vector3(side * 0.8, 0, 1.1), true)
	_gear(Vector3(0, 0, -4.2), false)
	# Swept vertical stabiliser, with a gold accent on the illustrated livery.
	_panel([Vector3(-0.08, 1.55, 3.8), Vector3(-0.06, 3.5, 5.15), Vector3(-0.035, 3.48, 5.8), Vector3(-0.07, 1.5, 5.6)], _navy, Vector3(0.14, 0, 0))
	for side in [-1.0, 1.0]:
		G.segment(self, Vector3(side * 0.09, 2.82, 4.75), Vector3(side * 0.09, 2.82, 5.8), 0.055, G.solid(Color("c2a458"), 0.3), "TailAccent")
	# Cockpit panes follow the tapered nose, with a centre pillar.
	for side in [-1.0, 1.0]:
		_panel([Vector3(side * 0.025, 1.60, -5.57), Vector3(side * 0.25, 1.58, -5.43), Vector3(side * 0.38, 1.61, -5.06), Vector3(side * 0.08, 1.71, -5.15)], _glass, Vector3.ZERO)
	# Simplified collision envelopes support the navigation drone, not flight dynamics.
	_collision(Vector3(0, 1.3, 0), Vector3(1.1, 1.12, 11.8))
	_collision(Vector3(0, 1.04, 1.0), Vector3(10.4, 0.20, 2.4))
	_bake()

func _fuselage() -> void:
	var rows: Array = []
	var sections: Array[Vector4] = [Vector4(-6.0, 0.015, 0.02, 1.10), Vector4(-5.7, 0.25, 0.23, 1.18),
		Vector4(-5.15, 0.47, 0.43, 1.28), Vector4(-4.4, 0.53, 0.53, 1.3), Vector4(3.8, 0.53, 0.53, 1.3),
		Vector4(4.85, 0.32, 0.35, 1.38), Vector4(6.1, 0.012, 0.025, 1.48)]
	for ring in sections:
		var points: Array[Vector3] = []
		for i in range(36):
			var a: float = i * TAU / 36.0
			points.append(Vector3(cos(a) * ring.y, sin(a) * ring.z + ring.w, ring.x))
		rows.append(points)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for j in range(rows.size() - 1):
		for i in range(36):
			var n: int = (i + 1) % 36
			G.triangle(st, rows[j][i], rows[j][n], rows[j + 1][i])
			G.triangle(st, rows[j][n], rows[j + 1][n], rows[j + 1][i])
	st.index()
	st.generate_normals()
	G.instance(self, st.commit(), Vector3.ZERO, _white, "ContouredFuselage")

func _wing(side: float, z: float, y: float, span: float, chord: float) -> void:
	var outline: Array[Vector3] = [Vector3(side * 0.33, y, z - 0.5), Vector3(side * span, y + 0.22, z + chord * 0.65),
		Vector3(side * span, y + 0.22, z + chord), Vector3(side * 0.33, y, z + chord)]
	_panel(outline, _white, Vector3(0, -0.10, 0))
	G.segment(self, outline[0], outline[1], 0.020, _metal, "LeadingEdge")
	G.segment(self, outline[3].lerp(outline[0], 0.22), outline[2].lerp(outline[1], 0.22), 0.009, _metal, "FlapLine")
	if span > 3.0:
		_panel([outline[1], outline[1] + Vector3(side * 0.17, 0.74, 0.25), outline[2] + Vector3(side * 0.17, 0.62, 0.18), outline[2]], _navy, Vector3(0.035, 0, 0))

func _panel(vertices: Array[Vector3], material: Material, thickness: Vector3) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for offset in [Vector3.ZERO, thickness]:
		G.triangle(st, vertices[0] + offset, vertices[1] + offset, vertices[2] + offset)
		G.triangle(st, vertices[0] + offset, vertices[2] + offset, vertices[3] + offset)
		G.triangle(st, vertices[2] + offset, vertices[1] + offset, vertices[0] + offset)
		G.triangle(st, vertices[3] + offset, vertices[2] + offset, vertices[0] + offset)
	for i in range(4):
		var n: int = (i + 1) % 4
		G.triangle(st, vertices[i], vertices[i] + thickness, vertices[n])
		G.triangle(st, vertices[n], vertices[i] + thickness, vertices[n] + thickness)
	st.index() # Match the indexed primitives before SurfaceTool.append_from batching.
	G.instance(self, st.commit(), Vector3.ZERO, material, "Airfoil")

func _engine(at: Vector3) -> void:
	G.segment(self, at + Vector3(0, 0, -0.68), at + Vector3(0, 0, 0.70), 0.37, _white, "EngineNacelle", 0.80)
	G.segment(self, at + Vector3(0, 0, -0.70), at + Vector3(0, 0, -0.75), 0.365, _metal, "IntakeLip")
	G.segment(self, at + Vector3(0, 0, -0.754), at + Vector3(0, 0, -0.77), 0.31, _dark, "IntakeDepth")
	for i in range(16):
		var a: float = i * TAU / 16.0
		G.segment(self, at + Vector3(cos(a) * 0.08, sin(a) * 0.08, -0.78), at + Vector3(cos(a + 0.23) * 0.28, sin(a + 0.23) * 0.28, -0.775), 0.018, _metal, "FanBlade")
	G.ellipsoid(self, at + Vector3(0, 0, -0.79), Vector3(0.15, 0.15, 0.19), _metal, "FanSpinner")
	G.segment(self, at + Vector3(0, 0, 0.67), at + Vector3(0, 0, 0.79), 0.24, _dark, "Exhaust")
	G.box(self, at + Vector3(0, 0.34, 0.22), Vector3(0.14, 0.25, 0.72), _metal, "EnginePylon")

func _gear(at: Vector3, twin: bool) -> void:
	G.segment(self, at + Vector3(0, 0.2, 0), at + Vector3(0, 1.0, 0), 0.045, _metal, "LandingStrut")
	for side in [-1.0, 1.0]:
		var x: float = side * (0.14 if twin else 0.10)
		G.segment(self, at + Vector3(x - 0.06, 0.19, 0), at + Vector3(x + 0.06, 0.19, 0), 0.19 if twin else 0.15, _dark, "Tyre")
		G.segment(self, at + Vector3(x - 0.065, 0.19, 0), at + Vector3(x + 0.065, 0.19, 0), 0.08, _metal, "WheelHub")

func _collision(at: Vector3, size: Vector3) -> void:
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = at
	body.add_child(shape)
	add_child(body)

func _bake() -> void:
	var groups: Dictionary = {}
	for node in get_children():
		if not node is MeshInstance3D:
			continue
		var material: Material = node.material_override
		if not groups.has(material):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			groups[material] = st
		groups[material].append_from(node.mesh, 0, node.transform)
		node.free()
	var mesh := ArrayMesh.new()
	for material in groups:
		groups[material].set_material(material)
		groups[material].commit(mesh)
	G.instance(self, mesh, Vector3.ZERO, null, "AirlinerGeometry")
